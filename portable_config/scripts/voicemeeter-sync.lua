-- voicemeeter-sync.lua
-- Automatic audio-delay that follows whichever physical output Voicemeeter is routing mpv to.
--
-- Why: mpv always outputs to the SAME Voicemeeter virtual input, so mpv can never see the real
-- playback device. The latency that matters comes from which hardware A-bus (A1/A2/A3...) Voicemeeter
-- sends mpv's strip to -- e.g. Nuraphone over Bluetooth (~350ms) vs the same headphones over cable
-- (~0ms). This script asks Voicemeeter directly (Remote API, in-process via LuaJIT FFI), builds a
-- stable "signature" of the active output device(s), looks up the right audio-delay, and re-applies
-- it live whenever the routing changes. Per-output values are seeded by rule and can be learned with
-- a save hotkey. See script-opts/voicemeeter-sync.conf and .json.

local msg     = require 'mp.msg'
local utils   = require 'mp.utils'
local options = require 'mp.options'

local opts = {
    enabled       = true,
    -- Full path to the 64-bit Voicemeeter Remote DLL.
    dll_path      = [[C:\Program Files (x86)\VB\Voicemeeter\VoicemeeterRemote64.dll]],
    -- Which virtual input mpv feeds: VAIO | AUX | VAIO3, or a numeric strip index.
    input_strip   = 'VAIO',
    -- Seconds between dirty-flag polls (cheap in-process call).
    poll_interval = 1.0,
    -- audio-delay applied when the output can't be determined / no rule or saved value matches.
    default_delay = 0.0,
    show_osd      = true,
}
options.read_options(opts, 'voicemeeter-sync')

if not opts.enabled then
    msg.verbose('disabled via config')
    return
end

----------------------------------------------------------------------------------------------------
-- Voicemeeter type -> strip/bus layout
--   type 1 = Voicemeeter, 2 = Banana, 3 = Potato
--   VAIO/AUX/VAIO3 are the virtual-input strip indices; a_buses = number of physical A buses
--   (A1..An map to Bus[0..n-1]).
----------------------------------------------------------------------------------------------------
local STRIP = {
    [1] = { VAIO = 2 },
    [2] = { VAIO = 3, AUX = 4 },
    [3] = { VAIO = 5, AUX = 6, VAIO3 = 7 },
}
local A_BUSES = { [1] = 1, [2] = 3, [3] = 5 }

----------------------------------------------------------------------------------------------------
-- FFI binding
----------------------------------------------------------------------------------------------------
local ok_ffi, ffi = pcall(require, 'ffi')
if not ok_ffi then
    msg.warn('LuaJIT FFI not available in this mpv build; cannot talk to Voicemeeter. Disabling.')
    return
end

ffi.cdef [[
    long VBVMR_Login(void);
    long VBVMR_Logout(void);
    long VBVMR_GetVoicemeeterType(long * pType);
    long VBVMR_IsParametersDirty(void);
    long VBVMR_GetParameterFloat(const char * szParamName, float * pValue);
    long VBVMR_GetParameterStringA(const char * szParamName, char * szString);
]]

local ok_load, lib = pcall(ffi.load, opts.dll_path)
if not ok_load then
    msg.warn('could not load Voicemeeter Remote DLL at "' .. opts.dll_path .. '": ' .. tostring(lib))
    msg.warn('Check dll_path in script-opts/voicemeeter-sync.conf. Disabling.')
    return
end

-- Login once. 0 = ok, 1 = ok but app not launched yet, -2 = already logged in (all fine).
-- -1 = cannot get the remote interface (treat as fatal for this session).
local lr = lib.VBVMR_Login()
if lr == -1 then
    msg.warn('VBVMR_Login returned -1 (no remote interface). Disabling.')
    return
end
msg.verbose('logged in to Voicemeeter Remote (code ' .. tostring(lr) .. ')')

local _pType = ffi.new('long[1]')
local _pf    = ffi.new('float[1]')
local _sbuf  = ffi.new('char[512]')

local function get_type()
    if lib.VBVMR_GetVoicemeeterType(_pType) ~= 0 then return nil end
    return tonumber(_pType[0])
end

local function get_float(name)
    if lib.VBVMR_GetParameterFloat(name, _pf) ~= 0 then return nil end
    return _pf[0]
end

local function get_string(name)
    ffi.fill(_sbuf, ffi.sizeof(_sbuf), 0)   -- avoid bleeding a previous read on a partial result
    if lib.VBVMR_GetParameterStringA(name, _sbuf) ~= 0 then return nil end
    return ffi.string(_sbuf)
end

----------------------------------------------------------------------------------------------------
-- Delay table (rules + learned exact entries), persisted as JSON next to the conf.
----------------------------------------------------------------------------------------------------
local function data_path()
    return mp.command_native({ 'expand-path', '~~/script-opts/voicemeeter-sync.json' })
end

local data = {
    -- ordered substring rules (first match wins); seeded for the Nuraphone Bluetooth case
    rules = { { match = 'nura', delay = -0.35 } },
    -- exact signature -> delay, written by the save hotkey (takes precedence over rules)
    exact = {},
}

local function load_data()
    local f = io.open(data_path(), 'r')
    if not f then return end
    local txt = f:read('*a'); f:close()
    local parsed = utils.parse_json(txt or '')
    if type(parsed) == 'table' then
        if type(parsed.rules) == 'table' then data.rules = parsed.rules end
        if type(parsed.exact) == 'table' then data.exact = parsed.exact end
    end
end

local function save_data()
    local p = data_path()
    local f = io.open(p, 'w')
    if not f then msg.warn('cannot write ' .. p); return end
    f:write(utils.format_json(data)); f:close()
end

load_data()

----------------------------------------------------------------------------------------------------
-- Resolve the active output signature and apply the matching delay.
----------------------------------------------------------------------------------------------------
local current_signature = nil
local last_delay        = nil

local function resolve_signature()
    local vmtype = get_type()
    if not vmtype then return nil end             -- engine not ready / not running
    local map = STRIP[vmtype]
    if not map then return nil end
    local idx = map[opts.input_strip] or tonumber(opts.input_strip)
    if not idx then
        msg.warn('input_strip "' .. tostring(opts.input_strip) .. '" invalid for Voicemeeter type '
            .. vmtype)
        return nil
    end
    local n = A_BUSES[vmtype] or 0
    local names = {}
    for a = 1, n do
        local on = get_float(string.format('Strip[%d].A%d', idx, a))
        if on == nil then return nil end          -- read error: bail, try again next poll
        if on > 0.5 then
            local dev = get_string(string.format('Bus[%d].device.name', a - 1))
            if dev and dev ~= '' then names[#names + 1] = dev end
        end
    end
    table.sort(names)
    return table.concat(names, ' + ')             -- '' when nothing is routed/bound
end

local function lookup(sig)
    if data.exact[sig] ~= nil then return data.exact[sig], 'saved' end
    local low = sig:lower()
    for _, r in ipairs(data.rules) do
        if r.match and low:find(r.match:lower(), 1, true) then return r.delay, 'rule' end
    end
    return opts.default_delay, 'default'
end

local function apply(sig)
    current_signature = sig
    mp.set_property('user-data/voicemeeter/output', sig)   -- consumed by spatial.lua (headphone gating)
    local delay, how = lookup(sig)
    if delay ~= last_delay then
        mp.set_property_number('audio-delay', delay)
        last_delay = delay
        local label = (sig ~= '' and sig) or 'unknown output'
        msg.info(string.format('audio-delay %+.3fs (%s) for: %s', delay, how, label))
        if opts.show_osd then
            mp.osd_message(string.format('Audio delay %+.3fs · %s', delay, label), 2)
        end
    end
end

local function force_resolve()
    local sig = resolve_signature()
    if sig ~= nil then apply(sig) end
end

local function poll()
    local dirty = lib.VBVMR_IsParametersDirty()
    -- >0: parameters changed (also the signal that the cache finished syncing after login)
    --  0: no change   |   <0: Voicemeeter not running/ready -> keep current delay
    if dirty and dirty > 0 then
        force_resolve()
    end
end

-- The Remote API's local parameter cache is stale on the first reads after login; Voicemeeter
-- signals it has synced by returning dirty>0 once. Poll quickly until then so the first *correct*
-- resolve lands in ~150ms, instead of trusting a premature (transient) read.
local prime_tries = 0
local function prime()
    local dirty = lib.VBVMR_IsParametersDirty()
    if dirty and dirty > 0 then
        force_resolve()                      -- cache synced: this read is trustworthy
        return
    end
    prime_tries = prime_tries + 1
    if prime_tries < 50 then                 -- give up after ~5s (e.g. Voicemeeter not running);
        mp.add_timeout(0.1, prime)           -- the slow poll will still catch it when it appears
    end
end

----------------------------------------------------------------------------------------------------
-- Calibrate-and-remember: save the CURRENT audio-delay against the CURRENT output signature.
----------------------------------------------------------------------------------------------------
local function save_current()
    local sig = current_signature
    if not sig then
        mp.osd_message('Voicemeeter output not detected yet', 2); return
    end
    if sig == '' then
        mp.osd_message('No active output to save (check Voicemeeter routing)', 2); return
    end
    local d = mp.get_property_number('audio-delay', 0)
    data.exact[sig] = d
    last_delay = d
    save_data()
    msg.info(string.format('saved audio-delay %+.3fs for: %s', d, sig))
    mp.osd_message(string.format('Saved %+.3fs for %s', d, sig), 2.5)
end

----------------------------------------------------------------------------------------------------
-- Wire up
----------------------------------------------------------------------------------------------------
-- Apply a sane baseline immediately, then prime against the Voicemeeter cache and let the first
-- trustworthy resolve correct it. The periodic poll re-validates continuously thereafter.
mp.set_property_number('audio-delay', opts.default_delay)
last_delay = opts.default_delay

prime()
mp.add_periodic_timer(opts.poll_interval, poll)
mp.register_event('file-loaded', force_resolve)
mp.add_key_binding(nil, 'save', save_current)
mp.register_script_message('resync', force_resolve)
mp.register_event('shutdown', function() pcall(function() lib.VBVMR_Logout() end) end)
