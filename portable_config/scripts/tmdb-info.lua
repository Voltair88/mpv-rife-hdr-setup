-- tmdb-info.lua
-- Shows an IMDb-style info card (poster + rating + genres + plot) for the playing movie,
-- by parsing the filename and querying TMDb. Standalone; no Jellyfin/ffmpeg dependency.
--   * Metadata via Windows' built-in curl.exe (TMDb API)
--   * The whole card (backdrop + panel + poster + text) is rendered into ONE BGRA bitmap by
--     tmdb_card.ps1 (System.Drawing) and blitted with a single overlay-add. This avoids mpv's
--     overlay-add-above-ASS layering (a backdrop behind ASS text is impossible).
-- Config: script-opts/tmdb-info.conf   Toggle: script-binding tmdb-info/toggle

local mp = require 'mp'
local utils = require 'mp.utils'
local msg = require 'mp.msg'
local options = require 'mp.options'

local opts = {
    api_key = '',
    language = 'en-US',
    poster_width = 200,
    display_seconds = 8,
    auto_show = true,
    position = 'top-left',
    margin = 60,
    -- HDR color: on HDR video the card is encoded to BT.2020+PQ so it isn't oversaturated.
    hdr_compensate = 'auto', -- auto (only HDR pq/hlg video) | yes (always) | no (never)
    card_nits = 203,         -- card brightness on HDR (lower = dimmer)
    show_backdrop = true,
}
options.read_options(opts, 'tmdb-info')

local CARD_ID = 50 -- single overlay-add for the whole composed card (mpv ids must be 0-63)

-- TMDb movie genre id -> name (stable list; avoids an extra API request)
local GENRES = {
    [28] = 'Action', [12] = 'Adventure', [16] = 'Animation', [35] = 'Comedy',
    [80] = 'Crime', [99] = 'Documentary', [18] = 'Drama', [10751] = 'Family',
    [14] = 'Fantasy', [36] = 'History', [27] = 'Horror', [10402] = 'Music',
    [9648] = 'Mystery', [10749] = 'Romance', [878] = 'Sci-Fi', [10770] = 'TV Movie',
    [53] = 'Thriller', [10752] = 'War', [37] = 'Western',
}

-- TMDb TV genre ids differ from movie ids (separate taxonomy)
local TV_GENRES = {
    [10759] = 'Action & Adventure', [16] = 'Animation', [35] = 'Comedy', [80] = 'Crime',
    [99] = 'Documentary', [18] = 'Drama', [10751] = 'Family', [10762] = 'Kids',
    [9648] = 'Mystery', [10763] = 'News', [10764] = 'Reality', [10765] = 'Sci-Fi & Fantasy',
    [10766] = 'Soap', [10767] = 'Talk', [10768] = 'War & Politics', [37] = 'Western',
}

local cache_dir = mp.command_native({ 'expand-path', '~~/tmdb-cache' })
local card_helper = mp.command_native({ 'expand-path', '~~/tmdb_card.ps1' })

-- state
local current = nil      -- current movie meta table (or false = confirmed no-match)
local visible = false
local req_id = 0         -- generation counter to discard stale async responses
local warned_key = false
local manual = false     -- Ctrl+i override: show even while playing
local fetching = false   -- a lookup is in flight (avoids duplicate fetches)
local compose_card       -- forward declaration (draw() calls it; defined in the data section)

-- the card is shown only while paused, unless the user forced it with the toggle key
local function is_paused() return mp.get_property_native('pause') == true end
local function want_show() return manual or is_paused() end

-- HDR detection: the video's transfer is the reliable signal (output is HDR exactly when video is)
local function is_hdr()
    local g = mp.get_property('video-params/gamma', '')
    return g == 'pq' or g == 'hlg'
end
local function hdr_on()
    local m = opts.hdr_compensate
    return m == 'yes' or (m ~= 'no' and is_hdr())
end

------------------------------------------------------------------- helpers

local function ensure_cache_dir()
    -- create only if missing; capture output so nothing leaks to mpv's console
    utils.subprocess({
        args = { 'cmd', '/c', 'if', 'not', 'exist', cache_dir, 'mkdir', cache_dir },
        capture_stdout = true, capture_stderr = true, playback_only = false,
    })
end

local function run_async(args, cb)
    return mp.command_native_async(
        { name = 'subprocess', playback_only = true, capture_stdout = true, capture_stderr = true, args = args },
        function(success, res) cb(success and res and res.status == 0, res) end)
end

local function urlencode(s)
    s = s:gsub('([^%w _%-%.~])', function(c) return string.format('%%%02X', string.byte(c)) end)
    s = s:gsub(' ', '+')
    return s
end

local function trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end

-- Parse a filename into a lookup spec:
--   movie: "Some.Movie.2026.2160p..."  -> { kind='movie', title=..., year=... }
--   tv:    "Show.Name.S04E08.Title..." -> { kind='tv', title=..., season=N, episode=N }
local function parse_filename()
    local path = mp.get_property('path', '')
    if path == '' or path:match('^%a[%w%+%-%.]*://') then return nil end -- skip streams/URLs
    local name = mp.get_property('filename/no-ext', '')
    if name == '' then return nil end

    local s = name:gsub('[._]+', ' '):gsub('%s+', ' ')

    -- TV episode marker SxxExx (also S4E8). Title is everything before it.
    local ep_pos, _, sn, en = s:find('[Ss](%d%d?)[Ee](%d%d?)')
    if ep_pos then
        local tvtitle = trim(s:sub(1, ep_pos - 1))
        tvtitle = trim((tvtitle:gsub('%s+%d%d%d%d$', ''))) -- drop a trailing year from the show name
        if tvtitle ~= '' then
            return { kind = 'tv', title = tvtitle, season = tonumber(sn), episode = tonumber(en) }
        end
    end

    local title, year

    -- first 4-digit token in 1900..2099 marks the year; title is everything before it
    for pos, yr in s:gmatch('()(%d%d%d%d)') do
        local n = tonumber(yr)
        if n >= 1900 and n <= 2099 then
            year = yr
            title = s:sub(1, pos - 1)
            break
        end
    end

    if not title then
        -- no year: cut at the first scene/quality tag
        local tags = { '2160p', '1080p', '720p', '480p', 'bluray', 'webrip', 'web-dl',
            'webdl', 'hdrip', 'hdtv', 'remux', 'x264', 'x265', 'hevc', 'brrip', 'dvdrip', 'xvid', 'bdrip' }
        local low = s:lower()
        local cut
        for _, t in ipairs(tags) do
            local p = low:find(t, 1, true)
            if p and (not cut or p < cut) then cut = p end
        end
        title = cut and s:sub(1, cut - 1) or s
    end

    title = trim(title)
    if title == '' then return nil end
    return { kind = 'movie', title = title, year = year }
end

local function cache_key(info)
    local base = info.title .. '_' .. (info.year or '')
    if info.kind == 'tv' then
        base = base .. string.format('_s%02de%02d', info.season or 0, info.episode or 0)
    end
    return base:lower():gsub('[^%w]+', '_'):gsub('^_+', ''):gsub('_+$', '')
end

------------------------------------------------------------------- rendering

-- cache filename encodes everything that changes the rendered card, so any change regenerates
local function card_path(key, W, H)
    return utils.join_path(cache_dir, string.format('%s_card_%dx%d_p%d_b%d_hdr%d_n%d.bgra',
        key, W, H, math.floor(opts.poster_width), opts.show_backdrop and 1 or 0,
        hdr_on() and 1 or 0, math.floor(opts.card_nits)))
end

local function hide()
    mp.command_native({ 'overlay-remove', CARD_ID })
    visible = false
    manual = false
end

local draw_tries = 0
local function draw(meta)
    local dim = mp.get_property_native('osd-dimensions')
    if not dim or not dim.w or dim.w == 0 then
        if draw_tries < 12 then
            draw_tries = draw_tries + 1
            mp.add_timeout(0.25, function() if current == meta then draw(meta) end end)
        end
        return
    end
    draw_tries = 0

    local W, H = dim.w, dim.h

    -- ensure the composed card for the current display size + style is ready
    local out = card_path(meta.key, W, H)
    if meta.card_out ~= out or not meta.card_bgra then
        compose_card(meta, req_id, W, H, out)
    end
    if not (meta.card_bgra and meta.card_out == out) then return end -- not ready; redraws on completion

    local cw, ch = meta.card_w, meta.card_h
    local m = opts.margin
    local pos = opts.position
    local X0 = (pos == 'top-right' or pos == 'bottom-right') and (W - m - cw) or m
    local Y0 = (pos == 'bottom-left' or pos == 'bottom-right') and (H - m - ch) or m
    if X0 < m then X0 = m end
    if Y0 < m then Y0 = m end

    mp.command_native({ 'overlay-remove', CARD_ID })
    mp.command_native_async(
        { 'overlay-add', CARD_ID, math.floor(X0), math.floor(Y0), meta.card_bgra, 0, 'bgra', cw, ch, (4 * cw) },
        function() end)
    visible = true
end

------------------------------------------------------------------- data

local function save_cache(key, meta)
    local f = io.open(utils.join_path(cache_dir, key .. '.json'), 'w')
    if f then f:write(utils.format_json(meta)); f:close() end
end

local function load_cache(key)
    local f = io.open(utils.join_path(cache_dir, key .. '.json'), 'r')
    if not f then return nil end
    local txt = f:read('*a'); f:close()
    local t = utils.parse_json(txt or '')
    return t
end

-- Render the whole card (backdrop + panel + poster + text) into one bitmap via tmdb_card.ps1.
-- Assigned into the forward-declared local so draw() can call it.
compose_card = function(meta, my_req, W, H, out)
    if not meta.key or W == 0 or H == 0 or meta.card_pending then return end
    -- cache hit: the file for this signature exists and we know its dimensions
    local dims = meta.card_dims and meta.card_dims[out]
    if dims and io_exists(out) then
        meta.card_bgra = out; meta.card_w = dims.w; meta.card_h = dims.h; meta.card_out = out
        if current == meta and visible then draw(meta) end
        return
    end
    meta.card_pending = true
    local function img(base, path) return path and (base .. path) or '' end
    local spec = {
        out = out, height = H, width_hint = W, poster_width = math.floor(opts.poster_width),
        -- room the card may occupy (window minus margins) so it scales to fit when not fullscreen
        max_w = math.max(120, W - 2 * opts.margin), max_h = math.max(120, H - 2 * opts.margin),
        hdr_encode = hdr_on() and true or false, ref_nits = opts.card_nits,
        show_backdrop = opts.show_backdrop and true or false,
        poster_url = img('https://image.tmdb.org/t/p/w342', meta.poster_path),
        backdrop_url = img('https://image.tmdb.org/t/p/w780', meta.backdrop_path),
        title = meta.title, year = meta.year, tagline = meta.tagline,
        rating = meta.rating, rating_note = meta.rating_note, genres = meta.genres, runtime = meta.runtime,
        overview = meta.overview, director = meta.director, cast = meta.cast,
    }
    local spec_path = utils.join_path(cache_dir, meta.key .. '_spec.json')
    local fsp = io.open(spec_path, 'w')
    if not fsp then meta.card_pending = false; return end
    fsp:write(utils.format_json(spec)); fsp:close()
    run_async({ 'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', card_helper, '-Spec', spec_path },
        function(ok, res)
            meta.card_pending = false
            if my_req ~= req_id then return end
            local o = res and res.stdout or ''
            local w, h = o:match('(%d+)%s+(%d+)')
            if ok and w then
                meta.card_bgra = out; meta.card_w = tonumber(w); meta.card_h = tonumber(h); meta.card_out = out
                meta.card_dims = meta.card_dims or {}
                meta.card_dims[out] = { w = meta.card_w, h = meta.card_h }
                save_cache(meta.key, meta)
                if current == meta and visible then draw(meta) end
            else
                msg.warn('card compose failed: ' .. (o ~= '' and o or 'unknown'))
            end
        end)
end

local function show_meta(meta, key, my_req, _poster_path)
    if my_req ~= req_id then return end
    fetching = false
    meta.key = key
    meta.card_bgra = nil; meta.card_out = nil -- force draw -> compose_card (re-validates the cache)
    current = meta
    -- prefetch the composed card now (if the display size is known) so pausing is instant
    local dim = mp.get_property_native('osd-dimensions')
    if dim and dim.w and dim.w > 0 then compose_card(meta, my_req, dim.w, dim.h, card_path(key, dim.w, dim.h)) end
    if want_show() then draw(meta) end
end

local function no_match(my_req, key)
    if my_req ~= req_id then return end
    fetching = false
    current = false
    if key then save_cache(key, { found = false }) end
    if want_show() then mp.osd_message('tmdb-info: no match for this file', 2) end
end

-- 2nd call: runtime + tagline + credits (director/cast) in one request, then show
local function fetch_details(id, meta, key, my_req, poster_path)
    local url = string.format('https://api.themoviedb.org/3/movie/%d?api_key=%s&language=%s&append_to_response=credits',
        id, opts.api_key, urlencode(opts.language))
    run_async({ 'curl', '-s', '-L', '--max-time', '10', url }, function(ok, res)
        if my_req ~= req_id then return end
        if ok and res and res.stdout then
            local d = utils.parse_json(res.stdout)
            if d then
                if d.runtime and d.runtime > 0 then meta.runtime = d.runtime end
                if d.tagline and d.tagline ~= '' then meta.tagline = d.tagline end
                if d.credits then
                    if d.credits.crew then
                        for _, c in ipairs(d.credits.crew) do
                            if c.job == 'Director' then
                                meta.director = meta.director and (meta.director .. ', ' .. c.name) or c.name
                            end
                        end
                    end
                    if d.credits.cast then
                        local names = {}
                        for _, c in ipairs(d.credits.cast) do
                            if #names < 4 then names[#names + 1] = c.name else break end
                        end
                        if #names > 0 then meta.cast = table.concat(names, ', ') end
                    end
                end
            end
        end
        save_cache(key, meta)
        show_meta(meta, key, my_req, poster_path)
    end)
end

-- TV: fetch the specific episode (name/plot/rating/runtime/credits) and merge over the show meta
local function fetch_tv_episode(show, info, key, my_req)
    local url = string.format(
        'https://api.themoviedb.org/3/tv/%d/season/%d/episode/%d?api_key=%s&language=%s&append_to_response=credits',
        show.id, info.season, info.episode, opts.api_key, urlencode(opts.language))
    run_async({ 'curl', '-s', '-L', '--max-time', '10', url }, function(ok, res)
        if my_req ~= req_id then return end
        local meta = {
            id = show.id,
            title = show.name,
            year = show.year,
            rating = show.rating,
            genres = show.genres,
            overview = show.overview,
            poster_path = show.poster_path,
            backdrop_path = show.backdrop_path,
        }
        local label = string.format('S%02dE%02d', info.season, info.episode)
        meta.tagline = label
        if ok and res and res.stdout and res.stdout ~= '' then
            local d = utils.parse_json(res.stdout)
            if d and not d.status_code then -- status_code => TMDb error (e.g. episode missing)
                if d.name and d.name ~= '' then meta.tagline = label .. '  \226\128\162  ' .. d.name end -- "S04E08 • Name"
                if d.overview and d.overview ~= '' then meta.overview = d.overview end
                -- episode rating only if it has enough votes (fresh episodes have noisy 1-4 vote scores)
                if d.vote_average and d.vote_average > 0 and (d.vote_count or 0) >= 5 then
                    meta.rating = d.vote_average; meta.rating_note = 'episode'
                end
                if d.runtime and d.runtime > 0 then meta.runtime = d.runtime end
                if d.credits then
                    if d.credits.crew then
                        for _, c in ipairs(d.credits.crew) do
                            if c.job == 'Director' then
                                meta.director = meta.director and (meta.director .. ', ' .. c.name) or c.name
                            end
                        end
                    end
                    local names = {}
                    for _, c in ipairs(d.credits.guest_stars or {}) do
                        if #names < 4 then names[#names + 1] = c.name else break end
                    end
                    if #names > 0 then meta.cast = table.concat(names, ', ') end
                end
            end
        end
        -- label the rating source so "8.5" isn't ambiguous (show avg vs this episode)
        if meta.rating and not meta.rating_note then meta.rating_note = 'series' end
        save_cache(key, meta)
        show_meta(meta, key, my_req, meta.poster_path)
    end)
end

local function lookup_tv(info, key, my_req)
    local url = string.format('https://api.themoviedb.org/3/search/tv?api_key=%s&query=%s&language=%s',
        opts.api_key, urlencode(info.title), urlencode(opts.language))
    run_async({ 'curl', '-s', '-L', '--max-time', '10', url }, function(ok, res)
        if my_req ~= req_id then return end
        if not ok or not res or not res.stdout or res.stdout == '' then no_match(my_req, key); return end
        local j = utils.parse_json(res.stdout)
        if not j or not j.results or #j.results == 0 then no_match(my_req, key); return end
        local r = j.results[1]
        local genre_names = {}
        if r.genre_ids then
            for _, gid in ipairs(r.genre_ids) do
                if TV_GENRES[gid] then genre_names[#genre_names + 1] = TV_GENRES[gid] end
            end
        end
        local show = {
            id = r.id,
            name = r.name or r.original_name or info.title,
            year = r.first_air_date and r.first_air_date:match('^(%d%d%d%d)') or nil,
            rating = (r.vote_average and r.vote_average > 0) and r.vote_average or nil,
            genres = table.concat(genre_names, ', '),
            overview = r.overview or '',
            poster_path = r.poster_path,
            backdrop_path = r.backdrop_path,
        }
        if r.id then
            fetch_tv_episode(show, info, key, my_req)
        else
            local meta = {
                title = show.name, year = show.year, rating = show.rating, genres = show.genres,
                overview = show.overview, poster_path = show.poster_path, backdrop_path = show.backdrop_path,
                tagline = string.format('S%02dE%02d', info.season, info.episode),
                rating_note = show.rating and 'series' or nil,
            }
            save_cache(key, meta)
            show_meta(meta, key, my_req, meta.poster_path)
        end
    end)
end

local function lookup_movie(info, key, my_req)
    local url = string.format('https://api.themoviedb.org/3/search/movie?api_key=%s&query=%s&language=%s',
        opts.api_key, urlencode(info.title), urlencode(opts.language))
    if info.year then url = url .. '&year=' .. info.year end

    run_async({ 'curl', '-s', '-L', '--max-time', '10', url }, function(ok, res)
        if my_req ~= req_id then return end
        if not ok or not res or not res.stdout or res.stdout == '' then
            no_match(my_req, key); return
        end
        local j = utils.parse_json(res.stdout)
        if not j or not j.results or #j.results == 0 then no_match(my_req, key); return end
        local r = j.results[1]
        local genre_names = {}
        if r.genre_ids then
            for _, gid in ipairs(r.genre_ids) do
                if GENRES[gid] then genre_names[#genre_names + 1] = GENRES[gid] end
            end
        end
        local meta = {
            id = r.id,
            title = r.title or r.original_title or info.title,
            year = (r.release_date and r.release_date:match('^(%d%d%d%d)')) or info.year,
            rating = (r.vote_average and r.vote_average > 0) and r.vote_average or nil,
            genres = table.concat(genre_names, ', '),
            overview = r.overview or '',
            poster_path = r.poster_path,
            backdrop_path = r.backdrop_path,
        }
        save_cache(key, meta)
        if r.id then
            fetch_details(r.id, meta, key, my_req, r.poster_path)
        else
            show_meta(meta, key, my_req, r.poster_path)
        end
    end)
end

local function lookup()
    req_id = req_id + 1
    local my_req = req_id

    if opts.api_key == nil or opts.api_key == '' then
        if not warned_key then
            warned_key = true
            mp.osd_message('tmdb-info: set api_key in script-opts/tmdb-info.conf', 4)
        end
        return
    end

    local info = parse_filename()
    if not info then current = nil; return end

    fetching = true
    local key = cache_key(info)

    -- cache (metadata). show_meta re-validates the composed-card bitmap cache itself.
    local cached = load_cache(key)
    if cached then
        if cached.found == false then no_match(my_req, nil); return end
        show_meta(cached, key, my_req, cached.poster_path)
        return
    end

    if info.kind == 'tv' then
        lookup_tv(info, key, my_req)
    else
        lookup_movie(info, key, my_req)
    end
end

-- helper used above (declared here to keep lookup readable)
function io_exists(p)
    local f = io.open(p, 'rb')
    if f then f:close(); return true end
    return false
end

------------------------------------------------------------------- events

mp.register_event('file-loaded', function()
    hide()
    current = nil
    fetching = false
    draw_tries = 0
    -- prefetch metadata + poster now so the first pause is instant; draw() is gated to paused
    if opts.auto_show then lookup() end
end)

mp.register_event('end-file', function() hide() end)

-- show the card only while paused; hide it on resume
mp.observe_property('pause', 'bool', function(_, paused)
    if paused then
        if current and current ~= false then
            draw(current)
        elseif current == nil and not fetching then
            lookup() -- e.g. api key was just added, or prefetch was skipped
        end
    elseif not manual then
        hide()
    end
end)

-- manual override: works regardless of pause state
mp.add_key_binding(nil, 'toggle', function()
    if visible then
        hide()
    else
        manual = true
        if current and current ~= false then
            draw(current)
        elseif not fetching then
            lookup()
        end
    end
end)

ensure_cache_dir()
