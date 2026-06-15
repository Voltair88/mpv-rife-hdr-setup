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
    backdrop_blur = true,    -- frosted-glass blurred backdrop
    -- Visibility: the card behaves like a hover zone in its corner -- it shows while the cursor is
    -- inside the card's area (moving), and hides when the cursor moves outside it or leaves.
    fade = true,             -- smooth fade in/out
    fade_duration = 0.18,    -- seconds for a full fade
    fade_steps = 5,          -- opacity steps in the fade (more = smoother, bigger cache file)
    -- A small frosted "Loading…" pill (animated spinner) shown while the card is still being
    -- fetched/composed, so a mouse reveal isn't just empty. Hidden the instant the card appears.
    loading_indicator = true,
    loading_delay = 0.15,    -- seconds of "not ready" before the pill appears (avoids flashing)
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
local visible = false    -- target state: should the card be on screen right now?
local pinned = false     -- Ctrl+i override: stay visible, ignore the idle auto-hide
local req_id = 0         -- generation counter to discard stale async responses
local warned_key = false
local fetching = false   -- a lookup is in flight (avoids duplicate fetches)
local compose_card       -- forward declaration (reveal() calls it; defined in the data section)
local reveal             -- forward declaration (compose_card callback / events call it)
local lookup             -- forward declaration (reveal() / events call it)

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
local function fade_n() return (opts.fade and opts.fade_steps > 0) and opts.fade_steps or 0 end

local function card_path(key, W, H)
    return utils.join_path(cache_dir, string.format('%s_card_%dx%d_p%d_b%d_bl%d_hdr%d_n%d_f%d.bgra',
        key, W, H, math.floor(opts.poster_width), opts.show_backdrop and 1 or 0,
        opts.backdrop_blur and 1 or 0, hdr_on() and 1 or 0, math.floor(opts.card_nits), fade_n()))
end

-- Build the card silently in the background for the current display size, so hovering is instant.
-- Debounced so a burst of osd-dimensions changes (a resize drag) composes once, for the final size.
local prefetch_timer = nil
local function schedule_prefetch()
    if prefetch_timer then prefetch_timer:kill() end
    prefetch_timer = mp.add_timeout(0.25, function()
        prefetch_timer = nil
        local meta = current
        if not (meta and meta ~= false and meta.key) then return end
        local dim = mp.get_property_native('osd-dimensions')
        if not (dim and dim.w and dim.w > 0) then return end
        local out = card_path(meta.key, dim.w, dim.h)
        if meta.card_out ~= out or not meta.card_bgra then
            compose_card(meta, req_id, dim.w, dim.h, out) -- compose_card guards against overlaps
        end
    end)
end

-- The composed bitmap is bigger than the visible card by a shadow margin (meta.card_sm) on each
-- side, and (when fading) packs N+1 opacity frames. Frame 0 = full opacity; frame N = most
-- transparent; level N+1 = removed. The card reveals on mouse move and hides on idle, with fade.
local vis_rect = nil               -- {x,y,w,h} of the VISIBLE card on screen, for mouse hit-test
local cur_lvl                      -- current opacity level (nil/large = hidden)
local placed = false               -- is the overlay currently added?
local anim_token = 0               -- cancels an in-flight fade when a new one starts
local draw_tries = 0

local function point_in(x, y, r)
    return r and x and y and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
end

------------------------------------------------------------------- loading indicator
-- A transient frosted "Loading..." pill (ASS, so it's instant + color-managed by mpv) shown while
-- the card is still being fetched/composed, and removed the moment the card blits.
local SPIN = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
local loading_ov, loading_spin_timer, loading_delay_timer
local loading_shown = false
local loading_frame = 1
local loading_geo = nil

local function loading_render()
    if not (loading_ov and loading_geo) then return end
    local gp = loading_geo
    local bg = string.format(
        '{\\an7\\pos(%d,%d)\\bord1\\shad0\\1c&H1A1512&\\1a&H38&\\3c&HD8D8D8&\\3a&H70&\\p1}%s{\\p0}',
        gp.x, gp.y, gp.path)
    local tx = string.format(
        '{\\an4\\pos(%d,%d)\\fs%d\\b1\\bord1\\shad0\\1c&HFFFFFF&\\3c&H000000&}%s  Loading…',
        gp.tx, gp.ty, gp.fs, SPIN[loading_frame])
    loading_ov.data = bg .. '\n' .. tx
    loading_ov:update()
end

local function loading_actually_show()
    local dim = mp.get_property_native('osd-dimensions')
    if not dim or not dim.w or dim.w == 0 then return end
    local W, H = dim.w, dim.h
    local fs = math.max(14, math.floor(H * 0.022))
    local pad = math.floor(fs * 0.75)
    local r = math.max(6, math.floor(fs * 0.5))
    local h = fs + 2 * pad
    local w = math.floor(fs * 8.2) + 2 * pad
    local m, pos = opts.margin, opts.position
    local x = (pos == 'top-right' or pos == 'bottom-right') and (W - m - w) or m
    local y = (pos == 'bottom-left' or pos == 'bottom-right') and (H - m - h) or m
    -- rounded-rect path (origin at pill top-left via \an7\pos); corners are beziers to the vertex
    local path = string.format(
        'm %d 0 l %d 0 b %d 0 %d 0 %d %d l %d %d b %d %d %d %d %d %d l %d %d b 0 %d 0 %d 0 %d l 0 %d b 0 0 0 0 %d 0',
        r, w - r, w, w, w, r, w, h - r, w, h, w, h, w - r, h, r, h, h, h, h - r, r, r)
    if not loading_ov then loading_ov = mp.create_osd_overlay('ass-events') end
    loading_ov.res_x = W; loading_ov.res_y = H; loading_ov.z = 5
    loading_geo = { x = x, y = y, fs = fs, path = path, tx = x + pad + math.floor(fs * 0.2), ty = y + math.floor(h / 2) }
    loading_shown = true
    loading_render()
    if loading_spin_timer then loading_spin_timer:kill() end
    loading_spin_timer = mp.add_periodic_timer(0.09, function()
        loading_frame = (loading_frame % #SPIN) + 1
        loading_render()
    end)
end

local function loading_hide()
    if loading_delay_timer then loading_delay_timer:kill(); loading_delay_timer = nil end
    if loading_spin_timer then loading_spin_timer:kill(); loading_spin_timer = nil end
    if loading_ov and loading_shown then loading_ov:remove() end
    loading_shown = false
    loading_geo = nil
end

local function loading_request()
    if not opts.loading_indicator then return end
    if loading_shown or loading_delay_timer then return end
    loading_delay_timer = mp.add_timeout(opts.loading_delay, function()
        loading_delay_timer = nil
        loading_actually_show()
    end)
end

local function blit_level(meta, lvl)
    local N = fade_n()
    if lvl > N then
        if placed then mp.command_native({ 'overlay-remove', CARD_ID }); placed = false end
        return
    end
    if lvl < 0 then lvl = 0 end
    local bw, bh = meta.card_w, meta.card_h
    local offset = lvl * bw * bh * 4
    mp.command_native({ 'overlay-add', CARD_ID, meta._ox, meta._oy, meta.card_bgra,
        offset, 'bgra', bw, bh, (4 * bw) })
    placed = true
    loading_hide() -- the card is on screen now; drop the loading pill
end

-- top-left of a vcw x vch card for the configured anchor + margin
local function anchor_xy(W, H, vcw, vch)
    local m, pos = opts.margin, opts.position
    local x = (pos == 'top-right' or pos == 'bottom-right') and (W - m - vcw) or m
    local y = (pos == 'bottom-left' or pos == 'bottom-right') and (H - m - vch) or m
    if x < m then x = m end
    if y < m then y = m end
    return x, y
end

-- compute & store the overlay placement so the VISIBLE card (not its bleed) sits at the margin
local function position_overlay(meta, W, H)
    local sm = meta.card_sm or 0
    local vcw, vch = meta.card_w - 2 * sm, meta.card_h - 2 * sm
    local vx, vy = anchor_xy(W, H, vcw, vch)
    meta._ox = math.max(0, math.floor(vx - sm))
    meta._oy = math.max(0, math.floor(vy - sm))
    vis_rect = { x = meta._ox + sm, y = meta._oy + sm, w = vcw, h = vch }
end

-- The on-screen rectangle that triggers the card (its own area). Uses the real composed size when
-- known for the current display size; otherwise a sensible estimate so the corner is hoverable
-- before the first compose finishes.
local function card_rect()
    local dim = mp.get_property_native('osd-dimensions')
    if not (dim and dim.w and dim.w > 0) then return nil end
    local W, H = dim.w, dim.h
    local meta = current
    if meta and meta ~= false and meta.card_w and meta.card_out == card_path(meta.key, W, H) then
        local sm = meta.card_sm or 0
        local vcw, vch = meta.card_w - 2 * sm, meta.card_h - 2 * sm
        local x, y = anchor_xy(W, H, vcw, vch)
        return { x = x, y = y, w = vcw, h = vch }
    end
    local vcw = math.min(W - 2 * opts.margin, math.floor(opts.poster_width * 4))
    local vch = math.floor(opts.poster_width * 1.6)
    local x, y = anchor_xy(W, H, vcw, vch)
    return { x = x, y = y, w = vcw, h = vch }
end

local function anim_step(meta, target, tok)
    if tok ~= anim_token then return end
    if cur_lvl == target then return end
    cur_lvl = cur_lvl + (target > cur_lvl and 1 or -1)
    blit_level(meta, cur_lvl)
    if cur_lvl ~= target then
        local N = fade_n()
        local dt = (N > 0) and (opts.fade_duration / (N + 1)) or 0
        mp.add_timeout(math.max(0.01, dt), function() anim_step(meta, target, tok) end)
    end
end

local function animate_to(meta, target)
    anim_token = anim_token + 1
    local tok = anim_token
    if not (opts.fade and fade_n() > 0) then -- no fade: jump straight to the target level
        cur_lvl = target
        blit_level(meta, cur_lvl)
        return
    end
    if cur_lvl == nil then cur_lvl = fade_n() + 1 end -- start fully hidden
    anim_step(meta, target, tok)
end

-- bring the card on screen (fade in). Composes/looks up first if needed.
reveal = function()
    if not (current and current ~= false) then
        if current == nil then
            if not fetching then lookup() end
            loading_request() -- metadata is being fetched
        end
        return
    end
    local meta = current
    visible = true -- target state, set early so the compose/osd-retry callbacks finish the reveal
    local dim = mp.get_property_native('osd-dimensions')
    if not dim or not dim.w or dim.w == 0 then
        if draw_tries < 12 then
            draw_tries = draw_tries + 1
            mp.add_timeout(0.25, function() if current == meta and visible then reveal() end end)
        end
        loading_request()
        return
    end
    draw_tries = 0
    local W, H = dim.w, dim.h
    local out = card_path(meta.key, W, H)
    if meta.card_out ~= out or not meta.card_bgra then
        compose_card(meta, req_id, W, H, out) -- not ready yet; its callback re-calls reveal()
    end
    if not (meta.card_bgra and meta.card_out == out) then
        loading_request() -- bitmap is still composing
        return
    end
    position_overlay(meta, W, H)
    animate_to(meta, 0) -- level 0 = full opacity
end

-- take the card off screen (fade out)
local function conceal()
    visible = false
    loading_hide()
    if current and current ~= false and placed then
        animate_to(current, fade_n() + 1)
    else
        anim_token = anim_token + 1
        if placed then mp.command_native({ 'overlay-remove', CARD_ID }); placed = false end
        cur_lvl = fade_n() + 1
    end
end

-- hard remove (no fade) + reset, for file changes
local function hide_now()
    anim_token = anim_token + 1
    loading_hide()
    mp.command_native({ 'overlay-remove', CARD_ID })
    placed = false
    visible = false
    pinned = false
    cur_lvl = fade_n() + 1
    vis_rect = nil
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
-- Assigned into the forward-declared local so reveal() can call it.
compose_card = function(meta, my_req, W, H, out)
    if not meta.key or W == 0 or H == 0 or meta.card_pending then return end
    -- cache hit: the file for this signature exists and we know its dimensions
    local dims = meta.card_dims and meta.card_dims[out]
    if dims and io_exists(out) then
        meta.card_bgra = out; meta.card_w = dims.w; meta.card_h = dims.h; meta.card_sm = dims.sm; meta.card_out = out
        if current == meta and visible then reveal() end
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
        backdrop_blur = opts.backdrop_blur and true or false, fade_steps = fade_n(),
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
            local w, h, sm = o:match('(%d+)%s+(%d+)%s+(%d+)')
            if ok and w then
                meta.card_bgra = out; meta.card_w = tonumber(w); meta.card_h = tonumber(h)
                meta.card_sm = tonumber(sm or '0'); meta.card_out = out
                meta.card_dims = meta.card_dims or {}
                meta.card_dims[out] = { w = meta.card_w, h = meta.card_h, sm = meta.card_sm }
                save_cache(meta.key, meta)
                if current == meta and visible then reveal() end
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
    schedule_prefetch() -- build the card in the background (now or once the display size is known)
    if visible or pinned then reveal() end -- e.g. cursor is already over the area / pinned
end

local function no_match(my_req, key)
    if my_req ~= req_id then return end
    fetching = false
    current = false
    if key then save_cache(key, { found = false }) end
    loading_hide()
    if visible or pinned then mp.osd_message('tmdb-info: no match for this file', 2) end
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

lookup = function()
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
    hide_now()
    current = nil
    fetching = false
    draw_tries = 0
    -- prefetch metadata + poster now so the first reveal is instant
    if opts.auto_show then lookup() end
end)

mp.register_event('end-file', function() hide_now() end)

-- Rebuild the card in the background whenever the display size is known/changes (it's keyed on WxH):
-- catches the post-load moment dimensions first become valid, plus window resizes / fullscreen.
mp.observe_property('osd-dimensions', 'native', function() schedule_prefetch() end)

-- Visibility = the card is a hover zone in its corner: it shows while the cursor moves inside its
-- own area, and hides when the cursor moves outside it (or leaves the window).
mp.observe_property('mouse-pos', 'native', function(_, m)
    if not m then return end
    if pinned then return end
    if m.hover == false then                 -- cursor left the window
        if visible then conceal() end
        return
    end
    local r = card_rect()
    if r and point_in(m.x, m.y, r) then
        reveal()
    elseif visible then
        conceal()
    end
end)

-- Ctrl+i: pin the card visible (ignores hover); press again to unpin + hide
mp.add_key_binding(nil, 'toggle', function()
    if pinned then
        pinned = false
        conceal()
    else
        pinned = true
        if current and current ~= false then
            visible = true; reveal()
        elseif not fetching then
            visible = true; lookup()
        end
    end
end)

ensure_cache_dir()
