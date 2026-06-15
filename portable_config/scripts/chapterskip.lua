-- chapterskip.lua
-- Auto-skip chapters whose title matches intro/recap/credits-style patterns. This is the local-file
-- equivalent of SponsorBlock (which only works on YouTube). It does nothing on files that have no
-- chapters or whose chapters are untitled -- which is many rips, so treat it as a bonus, not a given.

local mp      = require 'mp'
local msg     = require 'mp.msg'
local options = require 'mp.options'

local opts = {
    enabled = true,
    -- Semicolon-separated, case-insensitive Lua patterns matched against chapter titles.
    skip    = 'intro;opening;op ;ed ;recap;previously;preview;next time;credits;ending;outro',
    osd     = true,
}
options.read_options(opts, 'chapterskip')

local patterns = {}
local function rebuild_patterns()
    patterns = {}
    for p in opts.skip:gmatch('[^;]+') do
        p = p:lower():gsub('^%s+', ''):gsub('%s+$', '')
        if p ~= '' then patterns[#patterns + 1] = p end
    end
end
rebuild_patterns()

local function title_matches(title)
    if not title or title == '' then return false end
    local t = title:lower()
    for _, p in ipairs(patterns) do
        if t:find(p) then return true end
    end
    return false
end

local function on_chapter(_, ch)
    if not opts.enabled or ch == nil then return end
    local list = mp.get_property_native('chapter-list')
    if not list or #list == 0 then return end
    local cur = list[ch + 1]                 -- 'chapter' is a 0-based index into chapter-list
    if not cur or not title_matches(cur.title) then return end

    if ch + 1 < #list then
        mp.set_property_number('chapter', ch + 1)   -- jump to next chapter (re-fires; chains skips)
    else
        mp.command('playlist-next')                 -- last chapter: move to the next file
    end
    if opts.osd then
        mp.osd_message('Skipped chapter: ' .. (cur.title or ''), 1.5)
    end
    msg.verbose('skipped chapter ' .. ch .. ' "' .. tostring(cur.title) .. '"')
end

mp.observe_property('chapter', 'number', on_chapter)
