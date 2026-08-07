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

    local capture_url = os.getenv("BOKOPDS_CAPTURE_CATALOG_URL")
    if capture_url then
        catalogs = {{
            id = "public-catalog-capture",
            title = os.getenv("BOKOPDS_CAPTURE_CATALOG_TITLE") or "Public catalog",
            url = capture_url,
            username = "",
            password = "",
            download_directory = DataStorage:getDataDir() .. "/downloads",
        }}
        bookmarks = {}
    end

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
    local compatibility_state = os.getenv("BOKOPDS_COMPATIBILITY_STATE")
    local compatibility_target = os.getenv("BOKOPDS_COMPATIBILITY_TARGET")
    if compatibility_state == "untested" and compatibility_target and
            settings:readSetting("compatibility_warning_ack") ~= compatibility_target then
        shell.compatibility_warning_id = compatibility_target
        shell:setStatus(
            "This model and firmware have not been physically tested. Please report the result.",
            true)
    end
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

    local capture_screenshot = os.getenv("BOKOPDS_CAPTURE_SCREENSHOT")
    if capture_screenshot then
        local capture_screen = os.getenv("BOKOPDS_CAPTURE_SCREEN") or "home"
        local function capture()
            UIManager:forceRePaint()
            Device.screen:shot(capture_screenshot)
            UIManager:scheduleIn(0.1, function() UIManager:quit(0) end)
        end
        local function waitFor(predicate, callback, attempts)
            attempts = attempts or 0
            if predicate() then
                callback()
            elseif attempts >= 150 then
                error("timed out preparing public catalog screenshot: " ..
                    tostring(shell.status or shell.offline_reason or "no status"))
            else
                UIManager:scheduleIn(0.2, function()
                    waitFor(predicate, callback, attempts + 1)
                end)
            end
        end
        local function finishPublicationFeed()
            if capture_screen == "selection" then
                shell:activate("selection-start")
                shell:activate("selection-page")
                capture()
                return
            end
            local publication_index
            for index, entry in ipairs((shell.current_feed or {}).entries or {}) do
                if entry.publication then publication_index = index; break end
            end
            assert(publication_index, "public catalog has no publication entry")
            shell:activate("entry:" .. publication_index)
            waitFor(function()
                return not shell.busy and shell.screen == "detail"
            end, capture)
        end
        local function openPublicationFeed()
            local root_url = shell.current_feed and shell.current_feed.source_url
            local publication_url = os.getenv("BOKOPDS_CAPTURE_PUBLICATION_URL")
            if publication_url then
                shell:loadFeed(publication_url, shell.current_catalog,
                    os.getenv("BOKOPDS_CAPTURE_PUBLICATION_TITLE") or "Books",
                    false, false, "child")
                waitFor(function()
                    return not shell.busy and shell.current_feed and
                        shell.current_feed.source_url ~= root_url
                end, finishPublicationFeed)
                return
            end
            local navigation_index
            for index, entry in ipairs((shell.current_feed or {}).entries or {}) do
                if not entry.publication and entry.url then
                    navigation_index = index
                    break
                end
            end
            assert(navigation_index, "public catalog has no navigation entry")
            shell:activate("entry:" .. navigation_index)
            waitFor(function()
                return not shell.busy and shell.current_feed and
                    shell.current_feed.source_url ~= root_url
            end, finishPublicationFeed)
        end
        UIManager:scheduleIn(0.1, function()
            if capture_screen == "home" then
                capture()
                return
            end
            shell:activate("open:1")
            waitFor(function()
                return not shell.busy and shell.screen == "feed" and shell.current_feed
            end, function()
                if capture_screen == "feed" then
                    capture()
                else
                    openPublicationFeed()
                end
            end)
        end)
        return
    end

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
