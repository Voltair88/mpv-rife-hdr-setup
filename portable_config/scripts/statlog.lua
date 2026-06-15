-- statlog.lua
-- Opt-in diagnostic: while active, logs mpv playback-health metrics (native, gathered synchronously
-- and instantly, so the realtime budget isn't perturbed) once per second, AND samples nvidia-smi
-- once per second via a non-blocking async subprocess (written+flushed from Lua, so nothing is lost
-- to buffering). Each toggle-on writes a fresh timestamped pair of CSVs in %TEMP%:
--   mpv-statlog_<ts>.csv  (mpv side)   and   mpv-gpu_<ts>.csv  (nvidia-smi side, shared wall clock)
-- so separate capture scenarios never mix. OFF by default. Toggle: Ctrl+Shift+L / Tools menu /
-- `script-message statlog-toggle`. Built to verify RIFE realtime + GPU/VRAM headroom during playback.

local mp      = require 'mp'
local msg     = require 'mp.msg'
local options = require 'mp.options'

local opts = {
    interval   = 1.0,          -- seconds between samples
    out_dir    = '',           -- empty => %TEMP%
    nvidia_smi = 'nvidia-smi', -- on PATH for the NVIDIA driver
    gpu_log    = true,         -- also sample nvidia-smi
}
options.read_options(opts, 'statlog')

local active    = false
local timer     = nil
local file      = nil          -- mpv-side CSV
local gpu_file  = nil          -- nvidia-smi CSV

local COLS = {
    'iso', 'src_w', 'src_h', 'dynrange', 'hwdec', 'rife',
    'container_fps', 'target_fps', 'estimated_vf_fps', 'estimated_display_fps',
    'frame_drops', 'decoder_drops', 'vo_delayed', 'avsync',
}

local function out_dir()
    if opts.out_dir ~= '' then return opts.out_dir end
    return os.getenv('TEMP') or os.getenv('TMP') or '.'
end

local function q(v)
    if v == nil then return '' end
    local s = tostring(v)
    if s:find('[,"\n]') then s = '"' .. s:gsub('"', '""') .. '"' end
    return s
end

local function num(prop, fmt)
    local v = mp.get_property_number(prop)
    if v == nil then return nil end
    return fmt and string.format(fmt, v) or v
end

local function rife_active()
    local vf = mp.get_property_native('vf')
    if not vf then return '' end
    for _, f in ipairs(vf) do
        if f.label == 'rife' or f.name == 'vapoursynth' then
            return (f.enabled == false) and 'off' or 'on'
        end
    end
    return 'off'
end

local function gpu_sample()
    if not (opts.gpu_log and gpu_file) then return end
    mp.command_native_async({
        name = 'subprocess', playback_only = false, capture_stdout = true, capture_stderr = false,
        args = {
            opts.nvidia_smi,
            '--query-gpu=timestamp,utilization.gpu,utilization.decoder,memory.used,power.draw,clocks.current.sm',
            '--format=csv,noheader,nounits',
        },
    }, function(_, res)
        if gpu_file and res and res.stdout and res.stdout ~= '' then
            gpu_file:write(res.stdout)   -- nvidia-smi line already begins with its own timestamp
            gpu_file:flush()
        end
    end)
end

local function sample()
    if not file then return end
    local gamma = mp.get_property('video-params/gamma')
    local dyn = ''
    if gamma then dyn = (gamma == 'pq' or gamma == 'hlg') and 'HDR' or 'SDR' end
    local cfps = mp.get_property_number('container-fps')
    local row = {
        os.date('%Y-%m-%d %H:%M:%S'),
        mp.get_property_number('current-tracks/video/demux-w'),
        mp.get_property_number('current-tracks/video/demux-h'),
        dyn,
        mp.get_property('hwdec-current'),
        rife_active(),
        cfps and string.format('%.3f', cfps) or nil,
        cfps and string.format('%.3f', cfps * 2) or nil,   -- target = source x2 (fixed_multiplier(2))
        num('estimated-vf-fps', '%.3f'),
        num('estimated-display-fps', '%.3f'),
        num('frame-drop-count'),
        num('decoder-frame-drop-count'),
        num('vo-delayed-frame-count'),
        num('avsync', '%.4f'),
    }
    local parts = {}
    for i = 1, #COLS do parts[i] = q(row[i]) end
    file:write(table.concat(parts, ',') .. '\n')
    file:flush()
    gpu_sample()
end

local function start()
    if active then return end
    local ts = os.date('%Y%m%d_%H%M%S')
    local dir = out_dir()
    local stat_path = dir .. '\\mpv-statlog_' .. ts .. '.csv'
    local gpu_path  = dir .. '\\mpv-gpu_' .. ts .. '.csv'

    file = io.open(stat_path, 'w')
    if not file then
        mp.osd_message('statlog: cannot write ' .. stat_path, 3)
        msg.error('cannot open ' .. stat_path)
        return
    end
    file:write(table.concat(COLS, ',') .. '\n'); file:flush()

    if opts.gpu_log then
        gpu_file = io.open(gpu_path, 'w')
        if gpu_file then
            gpu_file:write('timestamp,gpu_util_pct,decoder_util_pct,mem_used_mib,power_w,sm_mhz\n')
            gpu_file:flush()
        end
    end

    timer = mp.add_periodic_timer(opts.interval, sample)
    sample()  -- one immediate row
    active = true
    msg.info('logging to ' .. stat_path .. (gpu_file and (' + ' .. gpu_path) or ''))
    mp.osd_message('Stats logging ON\n' .. stat_path, 3)
end

local function stop()
    if not active then return end
    active = false
    if timer then timer:kill(); timer = nil end
    if file then file:close(); file = nil end
    if gpu_file then gpu_file:close(); gpu_file = nil end
    msg.info('logging stopped')
    mp.osd_message('Stats logging OFF', 2)
end

local function toggle()
    if active then stop() else start() end
end

mp.add_key_binding(nil, 'toggle', toggle)
mp.register_script_message('statlog-toggle', toggle)
mp.register_event('shutdown', stop)
