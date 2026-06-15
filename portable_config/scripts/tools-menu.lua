-- tools-menu.lua
-- A single uosc menu that surfaces the custom toggles scattered across this config (RIFE, info card,
-- sharpening, Voicemeeter audio-delay) so they're discoverable instead of being keybind-only.
-- Uses uosc's `open-menu` script message, so it's a standalone menu and does NOT replace uosc's
-- built-in right-click menu. Open it with the toolbar "Tools" button or the keybind in input.conf.

local mp    = require 'mp'
local utils = require 'mp.utils'

local function open()
    local menu = {
        type  = 'uosc_tools_menu',
        title = 'Tools',
        items = {
            { title = 'Toggle RIFE interpolation', hint = 'Ctrl+Shift+R',
              value = { 'script-message', 'toggle_rife' } },
            { title = 'Toggle movie info card', hint = 'Ctrl+I',
              value = { 'script-binding', 'tmdb_info/toggle' } },
            { title = 'Toggle sharpening (libplacebo)',
              value = { 'cycle-values', 'sharpen', '0.0', '0.35' } },
            { title = 'Audio delay (Voicemeeter)', selectable = false, muted = true, italic = true },
            { title = 'Re-sync to current output',
              value = { 'script-message', 'resync' } },
            { title = 'Save delay for current output', hint = 'Ctrl+Shift+S',
              value = { 'script-binding', 'voicemeeter_sync/save' } },
            { title = 'Diagnostics', selectable = false, muted = true, italic = true },
            { title = 'Toggle stats logging', hint = 'Ctrl+Shift+L',
              value = { 'script-message', 'statlog-toggle' } },
        },
    }
    mp.commandv('script-message-to', 'uosc', 'open-menu', utils.format_json(menu))
end

mp.add_key_binding(nil, 'open', open)
mp.register_script_message('open', open)
