-- spatial.lua
-- Content-aware binaural virtual surround for headphones. When a file's SOURCE audio is multichannel
-- (>2 ch) AND the active output is headphones, render 5.1/7.1 -> spatialized stereo with the FFmpeg
-- `sofalizer` HRTF filter, so surround content "feels" placed on stereo headphones. Auto on/off by
-- content + output; manual toggle overrides. Needs a SOFA HRTF file (script-opts/spatial.conf).
--
-- Output detection reuses voicemeeter-sync.lua, which publishes the active hardware output name to the
-- `user-data/voicemeeter/output` property. HRTF is skipped on speakers (it sounds wrong there).

local mp      = require 'mp'
local msg     = require 'mp.msg'
local utils   = require 'mp.utils'
local options = require 'mp.options'

local opts = {
    enabled         = true,
    auto            = true,                 -- auto-apply on multichannel + headphone output
    sofa            = 'C:/Users/volta/mpv-hrtf/hrtf.sofa',  -- HRTF SOFA (space-free path!); see spatial.conf
    gain            = 8,                    -- dB makeup (sofalizer can be quiet); tune to taste
    lfe_gain        = 0,                    -- extra dB for the LFE channel
    interpolate     = 'yes',                -- sofalizer interpolate=yes|no
    -- Corrective EQ appended after sofalizer to counter the HRTF's measured tonal tilt (it boosts
    -- bass ~+4dB and rolls off treble ~-6dB; this flattens it back toward the crisp/balanced direct
    -- sound). Empty string = no EQ. See spatial.conf.
    eq              = 'lowshelf=g=-4.5:f=180:width_type=q:w=0.7,equalizer=f=380:width_type=q:w=1.0:g=-2,equalizer=f=2000:width_type=q:w=1.4:g=2,equalizer=f=4000:width_type=q:w=1.2:g=-1.5,equalizer=f=8000:width_type=q:w=1.2:g=2.5,equalizer=f=16000:width_type=q:w=0.7:g=-2.5',
    -- Comma-separated case-insensitive patterns. Apply HRTF only when the active output name matches
    -- one of these (your headphones). The Realtek "Högtalare" speakers won't match -> no HRTF.
    headphone_match = 'nura,buds,hörlurar,headphone,headset,earphone',
    -- Override virtual speaker ANGLES (azimuth degrees: 0=front, 90=left, 180=behind, 270=right).
    -- Pushing the surrounds toward 180 makes them feel more "behind" (default side position can sound
    -- in-front on headphones). Syntax: "CH AZIM|CH AZIM". Empty = sofalizer defaults. For 5.1(side)
    -- files the surrounds are SL/SR; for 5.1(back) they're BL/BR.
    speakers        = 'FL 30|FR 330|FC 0|SL 160|SR 200',
}
options.read_options(opts, 'spatial')

local manual = nil      -- nil=auto, true=forced on, false=forced off
local applied = false

local function sofa_path()
    return mp.command_native({'expand-path', opts.sofa})
end

local function sofa_exists()
    local p = sofa_path()
    local info = utils.file_info and utils.file_info(p)
    return info ~= nil and not info.is_dir
end

-- Build the lavfi af string. The Windows path has spaces and a drive colon, both special in an
-- FFmpeg filtergraph -- backslash-escape them (and use forward slashes) so the value is literal.
local function filter_string()
    -- FFmpeg parses the filtergraph in nested passes; a Windows drive colon must be double-escaped
    -- (\\:) to survive to the option parser as a literal ':'. Forward slashes; path must be space-free.
    local p = sofa_path():gsub('\\', '/'):gsub(':', '\\\\:')
    local chain = string.format('sofalizer=sofa=%s:gain=%s:lfegain=%s:interpolate=%s',
        p, opts.gain, opts.lfe_gain, (opts.interpolate == 'yes' or opts.interpolate == true) and 1 or 0)
    if opts.speakers and opts.speakers ~= '' then
        chain = chain .. ':speakers=' .. (opts.speakers:gsub(' ', '\\\\ '))   -- escape spaces for filtergraph
    end
    if opts.eq and opts.eq ~= '' then chain = chain .. ',' .. opts.eq end
    return '@spatial:lavfi=[' .. chain .. ']'
end

local function source_channels()
    return mp.get_property_number('current-tracks/audio/demux-channel-count') or 0
end

local function output_is_headphone()
    local out = mp.get_property('user-data/voicemeeter/output')
    -- Unknown output (voicemeeter-sync not yet resolved / disabled): wait rather than guess, so we
    -- don't briefly engage HRTF on speakers. The manual toggle works regardless of this.
    if not out or out == '' then return false end
    local low = out:lower()
    for pat in opts.headphone_match:gmatch('[^,]+') do
        pat = pat:gsub('^%s+', ''):gsub('%s+$', ''):lower()
        if pat ~= '' and low:find(pat, 1, true) then return true end
    end
    return false
end

local function want_on()
    if not opts.enabled then return false end
    if manual ~= nil then return manual end                 -- manual override
    if not opts.auto then return false end
    return source_channels() > 2 and output_is_headphone()
end

local function set(on)
    if on == applied then return end
    if on then
        if not sofa_exists() then
            msg.warn('SOFA file not found: ' .. sofa_path() .. ' -- skipping virtual surround')
            return
        end
        mp.commandv('af', 'add', filter_string())
    else
        mp.commandv('af', 'remove', '@spatial')
    end
    applied = on
    msg.verbose('virtual surround ' .. (on and 'ON' or 'OFF'))
end

local function refresh() set(want_on()) end

local function toggle()
    -- Cycle: auto -> forced on -> forced off -> auto
    if manual == nil then manual = not applied
    elseif manual == true then manual = false
    else manual = nil end
    refresh()
    local state = (manual == nil) and ('AUTO (' .. (applied and 'on' or 'off') .. ')')
        or (manual and 'ON (forced)' or 'OFF (forced)')
    mp.osd_message('Virtual surround: ' .. state .. '  [' .. source_channels() .. 'ch source]', 2.5)
end

mp.register_event('file-loaded', function() manual = nil; refresh() end)
mp.observe_property('current-tracks/audio/demux-channel-count', 'number', refresh)
mp.observe_property('user-data/voicemeeter/output', 'string', refresh)
mp.add_key_binding(nil, 'toggle', toggle)
mp.register_script_message('spatial-toggle', toggle)
