local DataStorage = require("datastorage")
local Device = require("device")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local Shell = require("apps/bokopds/shell")
local AutoSuspend = dofile("plugins/autosuspend.koplugin/main.lua")
local NetworkListener = require("ui/network/networklistener")

local BokOPDS = {}

function BokOPDS:show()
    local settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/bokopds.lua")
    local catalogs = settings:readSetting("catalogs", {})
    local bookmarks = settings:readSetting("bookmarks", {})

    if os.getenv("BOKOPDS_DEMO") == "library" then
        catalogs = {
            {
                title = "Nightstand library",
                url = "https://books.example.invalid/opds",
            },
            {
                title = "Public domain shelf",
                url = "https://classics.example.invalid/catalog",
            },
        }
        bookmarks = {
            { title = "Arthur C. Clarke" },
            { title = "Modernist fiction" },
        }
    end

    local shell = Shell:new{
        catalogs = catalogs,
        bookmarks = bookmarks,
        settings = settings,
    }
    -- Screensaver and USB confirmation code share a few upstream service
    -- helpers with the full reader/file manager. Expose this shell as the
    -- active UI without loading either application.
    package.loaded["apps/reader/readerui"] = { instance = nil }
    package.loaded["apps/filemanager/filemanager"] = { instance = shell }

    shell:addService(NetworkListener:new{})
    -- Keep the upstream idle controller in the shell's widget tree so it sees
    -- Suspend/Resume broadcasts. It turns off the frontlight and enters real
    -- device suspend after 15 minutes without input (the upstream default).
    if not AutoSuspend.disabled then
        shell:addService(AutoSuspend:new{ ui = shell })
    end
    UIManager:show(shell, "full")

    local demo_screen = os.getenv("BOKOPDS_DEMO_SCREEN")
    if demo_screen then
        UIManager:scheduleIn(0.1, function() shell:showDemo(demo_screen) end)
    end

    local self_test = os.getenv("BOKOPDS_SELF_TEST")
    if self_test then
        UIManager:scheduleIn(0.1, function() shell:runSelfTest(self_test) end)
        return
    end

    local cancel_test = os.getenv("BOKOPDS_CANCELLATION_TEST")
    if cancel_test then
        local slow_url = assert(os.getenv("BOKOPDS_CANCELLATION_URL"))
        UIManager:scheduleIn(0.1, function()
            shell:runCancellationTest(cancel_test, slow_url)
        end)
        return
    end

    local paging_audit = os.getenv("BOKOPDS_PAGING_AUDIT")
    if paging_audit then
        local audit_url = assert(os.getenv("BOKOPDS_PAGING_AUDIT_URL"))
        UIManager:scheduleIn(0.1, function()
            shell:runPagingAudit(paging_audit, audit_url)
        end)
        return
    end

    local bookmark_audit = os.getenv("BOKOPDS_BOOKMARK_AUDIT")
    if bookmark_audit then
        UIManager:scheduleIn(0.1, function()
            shell:activate("bookmark-open:1")
        end)
        UIManager:scheduleIn(1.0, function()
            local report = assert(io.open(bookmark_audit, "w"))
            report:write(shell:feedBreadcrumb(), "\n")
            for index, parent in ipairs(shell.catalog_parents or {}) do
                report:write(index, "\t", parent.label or parent.title or "", "\t",
                    parent.url or "", "\n")
            end
            report:close()
            local screenshot = os.getenv("BOKOPDS_SCREENSHOT")
            if screenshot then Device.screen:shot(screenshot) end
            UIManager:scheduleIn(0.1, function() UIManager:quit(0) end)
        end)
        return
    end

    local screenshot = os.getenv("BOKOPDS_SCREENSHOT")
    if screenshot then
        UIManager:scheduleIn(0.8, function()
            Device.screen:shot(screenshot)
            UIManager:scheduleIn(0.1, function()
                UIManager:quit(0)
            end)
        end)
    end
end

return BokOPDS
