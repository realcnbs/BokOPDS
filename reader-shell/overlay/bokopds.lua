#!./luajit

io.stdout:setvbuf("line")
os.setlocale("C", "numeric")

require("setupkoenv")
require("apps/bokopds/subprocess_guard").install()

G_defaults = require("luadefaults"):open()

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
G_reader_settings = LuaSettings:open(DataStorage:getDataDir() .. "/settings.reader.lua")
local keyboard_layouts = G_reader_settings:readSetting("keyboard_layouts")
if type(keyboard_layouts) ~= "table" or #keyboard_layouts == 0 then
    local language = G_reader_settings:readSetting("language", "en")
    keyboard_layouts = language == "ru" and { "ru", "en" } or { "en", "ru" }
    G_reader_settings:saveSetting("keyboard_layouts", keyboard_layouts)
end
if G_reader_settings:hasNot("keyboard_layout_default") then
    G_reader_settings:saveSetting("keyboard_layout_default", keyboard_layouts[1])
end
if G_reader_settings:hasNot("keyboard_layout") then
    G_reader_settings:saveSetting("keyboard_layout", keyboard_layouts[1])
end
if G_reader_settings:hasNot("wifi_enable_action") then
    G_reader_settings:saveSetting("wifi_enable_action", "turn_on")
end
if G_reader_settings:hasNot("auto_disable_wifi") then
    G_reader_settings:makeTrue("auto_disable_wifi")
end
-- BokOPDS has no document cover to render while sleeping. Keeping the current
-- page on screen is both faster and less prone to e-ink ghosting.
G_reader_settings:saveSetting("screensaver_type", "disable")
G_reader_settings:makeFalse("screensaver_show_message")

local language = G_reader_settings:readSetting("language")
local gettext = require("gettext")
if language then gettext.changeLang(language) end

local Blitbuffer = require("ffi/blitbuffer")
local c_blitter_disabled = G_reader_settings:nilOrFalse("dev_no_c_blitter")
if not c_blitter_disabled then jit.opt.start("loopunroll=45") end
Blitbuffer:setUseCBB(c_blitter_disabled)
local c_blitter_enabled = Blitbuffer:enableCBB(c_blitter_disabled)
G_reader_settings:saveSetting("dev_no_c_blitter", not c_blitter_enabled)

local Device = require("device")
require("document/canvascontext"):init(Device)
require("ui/bidi").setup(language)

local UIManager = require("ui/uimanager")
local BokOPDS = require("apps/bokopds/main")
BokOPDS:show()
local exit_code = UIManager:run()

Device:exit()
os.exit(type(exit_code) == "number" and exit_code or 0, true)
