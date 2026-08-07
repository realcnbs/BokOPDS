local Blitbuffer = require("ffi/blitbuffer")
local CatalogService = require("apps/bokopds/catalog_service")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputText = require("ui/widget/inputtext")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local RenderImage = require("ui/renderimage")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local util = require("util")

local Screen = Device.screen
local Shell = InputContainer:extend{
    covers_fullscreen = true,
    is_always_active = true,
}

local LOGICAL_WIDTH = 758
local LOGICAL_HEIGHT = 1024
local PAPER = Blitbuffer.COLOR_WHITE
local INK = Blitbuffer.COLOR_BLACK
local MUTED = Blitbuffer.COLOR_DARK_GRAY
local LINE = Blitbuffer.COLOR_LIGHT_GRAY
local BUTTON_FONT_SIZE = 18
local BUTTON_ICON_SIZE = 18
local BUTTON_ICON_GAP = 6
local MAX_RENDERED_IMAGE_BYTES = 4 * 1024 * 1024
local MAX_FEED_HISTORY = 16
local MAX_PAGINATION_HISTORY = 8
local MAX_CATALOG_PARENTS = 128
local MAX_HISTORY_ENTRIES = 700
local MAX_AGGREGATED_ENTRIES = 140
local MAX_AUTO_APPEND_PAGES = 5
local LANGUAGE_OPTIONS = {
    { "en", "English" }, { "ru", "Russian" }, { "uk", "Ukrainian" },
    { "fr", "French" }, { "de", "German" }, { "es", "Spanish" },
    { "it", "Italian" }, { "pl", "Polish" }, { "pt", "Portuguese" },
    { "zh", "Chinese" }, { "ja", "Japanese" }, { "ko", "Korean" },
}
local WHITE_ICONS = {
    ["appbar.search"] = "bok-white-search",
    ["bookmark"] = "bok-white-bookmark",
    ["bok-download"] = "bok-white-download",
    ["bok-save"] = "bok-white-save",
    ["bok-trash"] = "bok-white-trash",
    ["wifi"] = "bok-white-wifi",
    ["chevron.left"] = "bok-white-back",
    ["check"] = "bok-white-check",
    ["close"] = "bok-white-close",
    ["plus"] = "bok-white-plus",
}

local function inside(rect, x, y)
    return x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h
end

local function clone(value)
    local copy = {}
    for key, item in pairs(value or {}) do copy[key] = item end
    return copy
end

local function cloneList(value)
    local copy = {}
    for _, item in ipairs(value or {}) do table.insert(copy, clone(item)) end
    return copy
end

local function pushBounded(items, value, maximum)
    table.insert(items, value)
    local removed
    while #items > maximum do removed = table.remove(items, 1) end
    return removed
end

local function trimInput(value)
    local text = tostring(value or "")
    local invisible = { "\239\187\191", "\226\128\139" } -- BOM and zero-width space
    local changed = true
    while changed do
        changed = false
        text = text:gsub("^%s+", ""):gsub("%s+$", "")
        for _, marker in ipairs(invisible) do
            if text:sub(1, #marker) == marker then
                text, changed = text:sub(#marker + 1), true
            end
            if text:sub(-#marker) == marker then
                text, changed = text:sub(1, -#marker - 1), true
            end
        end
    end
    return text
end

local function cacheKey(url, catalog)
    if type(catalog) ~= "table" then return (catalog or "") .. "\0" .. url end
    local fingerprint = require("ffi/sha2").md5(table.concat({
        catalog.username or "", catalog.password or "",
    }, "\0"))
    return table.concat({ catalog.id or "", fingerprint, url }, "\0")
end

local function sameUrl(left, right)
    if not left or not right then return false end
    return tostring(left):gsub("/+$", "") == tostring(right):gsub("/+$", "")
end

local function formatBytes(value)
    local bytes = tonumber(value) or 0
    if bytes >= 1024 * 1024 * 1024 then
        return string.format("%.1f GB", bytes / (1024 * 1024 * 1024))
    elseif bytes >= 1024 * 1024 then
        return string.format("%.1f MB", bytes / (1024 * 1024))
    elseif bytes >= 1024 then
        return string.format("%.1f KB", bytes / 1024)
    end
    return string.format("%d B", bytes)
end

function Shell:init()
    self.catalogs = self.catalogs or {}
    self.bookmarks = self.bookmarks or {}
    local cache_directory = DataStorage:getDataDir() .. "/cache"
    util.makePath(cache_directory)
    self.feed_cache_settings = LuaSettings:open(
        cache_directory .. "/bokopds-feed-cache.lua")
    local legacy_feed_cache = self.settings:readSetting("feed_cache")
    self.feed_cache = self.feed_cache_settings:readSetting("entries", {})
    if next(self.feed_cache) == nil and type(legacy_feed_cache) == "table" then
        self.feed_cache = legacy_feed_cache
    end
    self.cover_cache = self.settings:readSetting("cover_cache", {})
    self.preferred_languages = self.settings:readSetting("preferred_languages", {})
    self.known_languages = self.settings:readSetting("known_languages", {})
    self.targets = {}
    self.services = {}
    self.network_manager = self.network_manager or NetworkMgr
    self.network_connected = self:isInternetAvailable()
    self.network_connecting = false
    self.deferred_generation = 0
    self.screen = not Device:isEmulator() and not self.network_connected and
        "offline" or "catalogs"
    self.input_fields = {}
    self.selection_mode = false
    self.selected_entries = {}
    self.selection_order = {}
    self.feed_history = {}
    self.pagination_history = {}
    self.catalog_parents = {}
    self.feed_return_screen = "catalogs"
    self.bookmark_parent_url = nil
    self.bookmark_path = nil
    self.rendered_images = {}
    self.rendered_image_order = {}
    self.rendered_image_bytes = 0
    self.append_chain_count = 0
    self.scroll_offsets = {
        catalogs = 0, bookmarks = 0, feed = 0, detail = 0, preferences = 0,
    }
    self.detail_max_scroll = 0
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    self:normalizeCatalogs()
    local cache_changed = self:pruneFeedCache()
    if legacy_feed_cache ~= nil then
        -- Complete the one-time migration before removing the legacy copy.
        self:saveFeedCache()
        self.settings:delSetting("feed_cache")
        self.settings:flush()
    elseif cache_changed then
        self:scheduleFeedCacheSave()
    end
    for _, catalog in ipairs(self.catalogs) do
        CatalogService.cleanupPartFiles(self:catalogDownloadDirectory(catalog))
    end
    CatalogService.cleanupCoverPartFiles(
        DataStorage:getDataDir() .. "/cache/bokopds-covers")
end

function Shell:addService(service)
    table.insert(self.services, service)
    table.insert(self, service)
end

function Shell:isInternetAvailable()
    if self.network_manager.isOnline then
        local ok, online = pcall(self.network_manager.isOnline, self.network_manager)
        return ok and online and true or false
    end
    return self.network_manager:isConnected() and true or false
end

function Shell:showOffline(reason)
    self.network_connected = false
    self.network_connecting = false
    self.offline_reason = reason
    self.screen = "offline"
    self:invalidate("full")
end

function Shell:deferUntilConnected(callback)
    if self:isInternetAvailable() then
        self.network_connected = true
        self.network_connecting = false
        self.offline_reason = nil
        return false
    end
    self.network_connected = false
    self.network_connecting = false
    self.offline_reason = self.network_manager:isConnected() and
        "Internet access or DNS is unavailable." or
        "Configure Wi-Fi in the reader interface, then return to BokOPDS."
    self.screen = "offline"
    self:invalidate("full")
    if self.network_manager.bokopds_can_configure_wifi ~= false then
        self.deferred_generation = self.deferred_generation + 1
        local generation = self.deferred_generation
        self.network_connecting = true
        local run_when_online = self.network_manager.runWhenOnline or
            self.network_manager.runWhenConnected
        run_when_online(self.network_manager, function()
            if generation ~= self.deferred_generation then return end
            if self:isInternetAvailable() then
                self.network_connected = true
                self.network_connecting = false
                self.offline_reason = nil
                if self.screen == "offline" then self.screen = "catalogs" end
                self:invalidate("full")
                callback()
            else
                self:showOffline("Wi-Fi connected, but the internet check failed. Check DNS or the network connection.")
            end
        end)
    end
    return true
end

function Shell:onNetworkConnected()
    if self:isInternetAvailable() then
        self.network_connected = true
        self.network_connecting = false
        self.offline_reason = nil
        if self.screen == "offline" then self.screen = "catalogs" end
        self:invalidate("full")
    else
        self:showOffline("Wi-Fi connected, but internet access or DNS is unavailable.")
    end
end

function Shell:onNetworkDisconnected()
    self.network_connected = false
    self.network_connecting = false
    self:invalidate("ui")
end

function Shell:catalogFailureMessage(response)
    local detail = tostring(response and (response.status or response.code) or "")
    local lower = detail:lower()
    if lower:find("host or service", 1, true) or
            lower:find("resolve", 1, true) or
            lower:find("name or service", 1, true) then
        return "The catalog address could not be resolved. Check internet access and DNS.", true
    end
    if lower:find("timeout", 1, true) or lower:find("timed out", 1, true) then
        return "The catalog did not respond in time. Try again.", false
    end
    if detail == "" then detail = "network unavailable" end
    return "Catalog request failed: " .. detail, false
end

function Shell:defaultDownloadDirectory()
    local configured = os.getenv("BOKOPDS_DOWNLOAD_DIR") or
        self.settings:readSetting("download_directory",
            require("datastorage"):getDataDir() .. "/downloads")
    configured = trimInput(configured)
    if configured == "" then
        configured = require("datastorage"):getDataDir() .. "/downloads"
    end
    return configured
end

function Shell:safeDownloadDirectory(directory)
    directory = trimInput(directory):gsub("/+", "/"):gsub("/$", "")
    local root = trimInput(os.getenv("BOKOPDS_LIBRARY_ROOT") or ""):gsub("/+", "/"):gsub("/$", "")
    if root == "" then return directory ~= "" and directory or nil end
    if directory:find("/%.[^/]+") or directory:find("/%.%./", 1, true) or
            directory:match("/%.%.$") then
        return nil, "Download directory must not use hidden or parent folders"
    end
    if directory ~= root and directory:sub(1, #root + 1) ~= root .. "/" then
        return nil, "Download directory must be inside " .. root
    end
    return directory
end

function Shell:catalogDownloadDirectory(catalog)
    local directory = trimInput(catalog and catalog.download_directory or "")
    directory = directory ~= "" and directory or self:defaultDownloadDirectory()
    return self:safeDownloadDirectory(directory) or self:defaultDownloadDirectory()
end


function Shell:pruneFeedCache()
    local changed = false
    local entries, total = {}, 0
    local now = os.time()
    for key, cached in pairs(self.feed_cache) do
        local size = type(cached.body) == "string" and #cached.body or 0
        if size == 0 or now - (cached.stored_at or 0) > 86400 then
            self.feed_cache[key] = nil
            changed = true
        else
            total = total + size
            table.insert(entries, { key = key, stored_at = cached.stored_at or 0, size = size })
        end
    end
    table.sort(entries, function(a, b) return a.stored_at < b.stored_at end)
    while #entries > 30 or total > 4 * 1024 * 1024 do
        local oldest = table.remove(entries, 1)
        total = total - oldest.size
        self.feed_cache[oldest.key] = nil
        changed = true
    end
    return changed
end

function Shell:purgeCatalogCache(catalog)
    local prefix = (catalog.id or "") .. "\0"
    for key in pairs(self.feed_cache) do
        if key:sub(1, #prefix) == prefix then self.feed_cache[key] = nil end
    end
    self:scheduleFeedCacheSave()
end

local function retainedFeedEntries(feed)
    local total = #(feed and feed.entries or {})
    for _, page in ipairs(feed and feed._pagination_history or {}) do
        total = total + #(page.entries or {})
    end
    return total
end

function Shell:trimNavigationHistory()
    local total = 0
    for _, feed in ipairs(self.feed_history) do
        total = total + retainedFeedEntries(feed)
    end
    for _, feed in ipairs(self.pagination_history) do
        total = total + retainedFeedEntries(feed)
    end
    while total > MAX_HISTORY_ENTRIES do
        if #self.feed_history > 1 then
            local removed = table.remove(self.feed_history, 1)
            total = total - retainedFeedEntries(removed)
            if removed._catalog_parent_recorded then
                table.remove(self.catalog_parents, 1)
            end
        else
            local removed = false
            for _, feed in ipairs(self.feed_history) do
                local pages = feed._pagination_history
                if pages and #pages > 1 then
                    total = total - retainedFeedEntries(table.remove(pages, 1))
                    removed = true
                    break
                end
            end
            if not removed and #self.pagination_history > 1 then
                total = total - retainedFeedEntries(table.remove(self.pagination_history, 1))
                removed = true
            end
            if not removed then break end
        end
    end
end

function Shell:normalizeCatalogs()
    local changed = false
    for index, catalog in ipairs(self.catalogs) do
        if not catalog.id then
            catalog.id = string.format("catalog-%d-%d", os.time(), index)
            changed = true
        end
        catalog.title = catalog.title or catalog.name or "Untitled"
        local normalized_url = trimInput(catalog.url)
        if catalog.url ~= normalized_url then
            catalog.url = normalized_url
            changed = true
        end
        catalog.username = catalog.username or ""
        catalog.password = catalog.password or ""
        local download_directory = self:catalogDownloadDirectory(catalog)
        if catalog.download_directory ~= download_directory then
            catalog.download_directory = download_directory
            changed = true
        end
    end
    if changed then self:saveState() end
end

function Shell:getSize() return self.dimen end
function Shell:sx(value) return math.floor(value * self.dimen.w / LOGICAL_WIDTH + 0.5) end
function Shell:sy(value) return math.floor(value * self.dimen.h / LOGICAL_HEIGHT + 0.5) end
function Shell:ss(value)
    return math.max(1, math.floor(value * math.min(
        self.dimen.w / LOGICAL_WIDTH, self.dimen.h / LOGICAL_HEIGHT) + 0.5))
end
function Shell:rect(x, y, w, h)
    return Geom:new{ x = self:sx(x), y = self:sy(y), w = self:sx(w), h = self:sy(h) }
end

function Shell:keyboardTop()
    local input = self.active_input
    if not input or not input:isKeyboardVisible() then return nil end
    local keyboard = input:getKeyboardDimen()
    if not keyboard or not keyboard.h or keyboard.h <= 0 then return nil end
    return LOGICAL_HEIGHT - math.ceil(keyboard.h * LOGICAL_HEIGHT / self.dimen.h)
end

function Shell:anchoredInputY(input, keyboard_top)
    local input_height = math.ceil(input:getSize().h * LOGICAL_HEIGHT / self.dimen.h)
    return math.max(238, keyboard_top - input_height - 14), input_height
end

function Shell:drawAnchoredInput(bb, input, label, keyboard_top)
    if not input or not keyboard_top then return end
    local input_y = self:anchoredInputY(input, keyboard_top)
    self:drawText(bb, string.upper(label), 24, input_y - 32, 710, 24,
        16, false, MUTED, false)
    self:paintInput(bb, input, self:sx(24), self:sy(input_y))
end

function Shell:saveState()
    self.settings:saveSetting("catalogs", self.catalogs)
    self.settings:saveSetting("bookmarks", self.bookmarks)
    self.settings:saveSetting("cover_cache", self.cover_cache)
    self.settings:saveSetting("preferred_languages", self.preferred_languages)
    self.settings:saveSetting("known_languages", self.known_languages)
    self.settings:flush()
end


function Shell:saveFeedCache()
    if not self.feed_cache_settings then return end
    self.feed_cache_settings:saveSetting("entries", self.feed_cache)
    self.feed_cache_settings:flush()
end

function Shell:scheduleFeedCacheSave()
    if not self.feed_cache_settings then return end
    if self.feed_cache_save_task then
        UIManager:unschedule(self.feed_cache_save_task)
    end
    local task
    task = function()
        self.feed_cache_save_task = nil
        self:saveFeedCache()
    end
    self.feed_cache_save_task = task
    UIManager:scheduleIn(0.5, task)
end

function Shell:invalidate(refresh)
    self.input_repaint = nil
    UIManager:setDirty(self, refresh or "ui")
end

function Shell:paintInput(bb, input, x, y)
    input._bokopds_x, input._bokopds_y = x, y
    input:paintTo(bb, x, y)
end

function Shell:addTarget(rect, action)
    if self.target_offset_y then
        rect = Geom:new{
            x = rect.x,
            y = rect.y + self.target_offset_y,
            w = rect.w,
            h = rect.h,
        }
    end
    if self.target_clip_top then
        local top = math.max(rect.y, self.target_clip_top)
        local bottom = math.min(rect.y + rect.h, self.target_clip_bottom)
        if bottom <= top then return end
        rect = Geom:new{ x = rect.x, y = top, w = rect.w, h = bottom - top }
    end
    table.insert(self.targets, { rect = rect, action = action })
end

function Shell:resetScroll(screen)
    self.scroll_offsets[screen or self.screen] = 0
end

function Shell:preferredLanguageSet()
    local result = {}
    for _, language in ipairs(self.preferred_languages or {}) do result[language] = true end
    return result
end

function Shell:entryMatchesLanguages(entry)
    if not entry.publication or #(self.preferred_languages or {}) == 0 then return true end
    if #(entry.languages or {}) == 0 then return true end
    local preferred = self:preferredLanguageSet()
    for _, language in ipairs(entry.languages) do
        local base = language:match("^([a-z]+)") or language
        if preferred[language] or preferred[base] then return true end
    end
    return false
end

function Shell:visibleFeedEntries()
    local result = {}
    for index, entry in ipairs((self.current_feed and self.current_feed.entries) or {}) do
        if self:entryMatchesLanguages(entry) then
            table.insert(result, { entry = entry, index = index })
        end
    end
    return result
end

function Shell:rememberFeedLanguages(feed)
    local seen = {}
    for _, language in ipairs(self.known_languages or {}) do seen[language] = true end
    local changed = false
    for _, entry in ipairs(feed.entries or {}) do
        for _, language in ipairs(entry.languages or {}) do
            local base = language:match("^([a-z]+)") or language
            if not seen[base] then
                seen[base], changed = true, true
                table.insert(self.known_languages, base)
            end
        end
    end
    if changed then self:saveState() end
end

function Shell:entrySelectionKey(entry)
    local acquisition = self:preferredAcquisition(entry)
    return acquisition and acquisition.href or entry.url or
        ((entry.title or "") .. "\0" .. (entry.author or ""))
end

function Shell:preferredAcquisition(entry)
    local ranks = { EPUB = 1, PDF = 2, FB2 = 3 }
    local best, best_rank
    for _, acquisition in ipairs(entry.acquisitions or {}) do
        local rank = ranks[CatalogService.formatName(acquisition)] or 10
        if not best or rank < best_rank then best, best_rank = acquisition, rank end
    end
    return best
end

function Shell:downloadAcquisition(acquisition, entry)
    local result = clone(acquisition)
    result.book_title = entry and entry.title or acquisition.book_title
    result.book_author = entry and entry.author or acquisition.book_author
    return result
end

function Shell:selectedCount() return #self.selection_order end

function Shell:clearSelection()
    self.selection_mode = false
    self.selected_entries = {}
    self.selection_order = {}
end

function Shell:toggleEntrySelection(entry)
    local acquisition = self:preferredAcquisition(entry)
    if not acquisition then return end
    local key = self:entrySelectionKey(entry)
    if self.selected_entries[key] then
        self.selected_entries[key] = nil
        for index, selected_key in ipairs(self.selection_order) do
            if selected_key == key then table.remove(self.selection_order, index); break end
        end
    else
        self.selected_entries[key] = {
            entry = entry,
            acquisition = self:downloadAcquisition(acquisition, entry),
        }
        table.insert(self.selection_order, key)
    end
    self:invalidate("ui")
end

function Shell:newText(text, size, bold, color, max_width)
    return TextWidget:new{
        text = text,
        -- Font:getFace already scales by the native screen size. Geometry is
        -- scaled by this shell, so pre-scaling the font here would apply the
        -- physical-device factor twice (most visibly on 1404 px panels).
        face = Font:getFace("cfont", size),
        bold = bold or false,
        fgcolor = color or INK,
        max_width = max_width and self:sx(max_width) or nil,
        padding = 0,
    }
end

function Shell:drawText(bb, text, x, y, width, height, size, bold, color, centered)
    if not text or text == "" then return end
    local widget = self:newText(text, size, bold, color, width)
    local draw_x = self:sx(x)
    if centered then draw_x = draw_x + math.floor((self:sx(width) - widget:getWidth()) / 2) end
    local draw_y = self:sy(y) + math.floor((self:sy(height) - widget:getSize().h) / 2)
    widget:paintTo(bb, draw_x, draw_y)
    widget:free()
end

function Shell:drawParagraph(bb, text, x, y, width, size, color, max_height)
    if not text or text == "" then return 0 end
    local widget = TextBoxWidget:new{
        text = text,
        face = Font:getFace("cfont", size),
        fgcolor = color or INK,
        width = self:sx(width),
        height = max_height and self:sy(max_height) or nil,
    }
    widget:paintTo(bb, self:sx(x), self:sy(y))
    local height = widget:getSize().h
    widget:free(true)
    return math.ceil(height * LOGICAL_HEIGHT / self.dimen.h)
end

function Shell:drawFittedParagraph(bb, text, x, y, width, max_height,
        maximum_size, minimum_size, color, background)
    if not text or text == "" then return end
    local selected
    for size = maximum_size, minimum_size, -1 do
        local candidate = TextBoxWidget:new{
            text = text,
            face = Font:getFace("cfont", size),
            fgcolor = color or INK,
            bgcolor = background or INK,
            width = self:sx(width),
        }
        if candidate:getSize().h <= self:sy(max_height) then
            selected = candidate
            break
        end
        candidate:free(true)
    end
    if not selected then
        selected = TextBoxWidget:new{
            text = text,
            face = Font:getFace("cfont", minimum_size),
            fgcolor = color or INK,
            bgcolor = background or INK,
            width = self:sx(width),
            height = self:sy(max_height),
        }
    end
    selected:paintTo(bb, self:sx(x), self:sy(y))
    selected:free(true)
end

function Shell:drawIcon(bb, icon, rect, invert)
    if invert then icon = WHITE_ICONS[icon] or icon end
    local path = "resources/icons/mdlight/" .. icon .. ".svg"
    local rendered = self:renderImage(path, rect.w, rect.h, false)
    if not rendered then return end
    local widget = ImageWidget:new{
        image = rendered.bb,
        image_disposable = false,
        width = rect.w,
        height = rect.h,
        alpha = true,
        _is_straight_alpha = rendered.straight_alpha,
    }
    widget:paintTo(bb, rect.x, rect.y)
    widget:free()
end

function Shell:renderImage(path, width, height, keep_aspect)
    local decode_width, decode_height = width, height
    if keep_aspect and not path:lower():match("%.svg$") then
        local source_width, source_height = CatalogService.coverDimensions(path)
        if source_width and source_height then
            local scale = math.min(width / source_width, height / source_height)
            decode_width = math.max(1, math.floor(source_width * scale + 0.5))
            decode_height = math.max(1, math.floor(source_height * scale + 0.5))
        end
    end
    local key = string.format("%s|%d|%d|%s", path, decode_width, decode_height,
        keep_aspect and "aspect" or "fill")
    if self.rendered_images[key] then return self.rendered_images[key] end
    local image, straight_alpha
    if path:lower():match("%.svg$") then
        image, straight_alpha = RenderImage:renderSVGImageFile(path, width, height)
    else
        image = RenderImage:renderImageFile(path, false, decode_width, decode_height)
    end
    if image then
        local bytes = math.max(1, image:getWidth()) * math.max(1, image:getHeight()) * 4
        self.rendered_images[key] = {
            bb = image, straight_alpha = straight_alpha, bytes = bytes,
        }
        self.rendered_image_bytes = self.rendered_image_bytes + bytes
        table.insert(self.rendered_image_order, key)
        while #self.rendered_image_order > 1 and
                self.rendered_image_bytes > MAX_RENDERED_IMAGE_BYTES do
            local evicted_key = table.remove(self.rendered_image_order, 1)
            local evicted = self.rendered_images[evicted_key]
            if evicted then
                self.rendered_image_bytes = self.rendered_image_bytes - (evicted.bytes or 0)
                evicted.bb:free()
                self.rendered_images[evicted_key] = nil
            end
        end
    end
    return self.rendered_images[key]
end

function Shell:drawImage(bb, path, rect, keep_aspect)
    local rendered = self:renderImage(path, rect.w, rect.h, keep_aspect)
    if not rendered then return false end
    local widget = ImageWidget:new{
        image = rendered.bb,
        image_disposable = false,
        width = rect.w,
        height = rect.h,
        scale_factor = keep_aspect and 0 or nil,
        alpha = true,
        _is_straight_alpha = rendered.straight_alpha,
    }
    widget:paintTo(bb, rect.x, rect.y)
    widget:free()
    return true
end

function Shell:drawPanel(bb, rect, radius, border, fill, border_width)
    bb:paintRoundedRect(rect.x, rect.y, rect.w, rect.h, fill or PAPER, self:ss(radius))
    if border_width and border_width > 0 then
        bb:paintBorder(rect.x, rect.y, rect.w, rect.h, self:ss(border_width),
            border or INK, self:ss(radius), true)
    end
end

function Shell:drawButton(bb, logical, label, action, primary, icon, enabled)
    if enabled == nil then enabled = true end
    local rect = self:rect(logical.x, logical.y, logical.w, logical.h)
    local shadow = Geom:new{ x = rect.x, y = rect.y + self:sy(3), w = rect.w, h = rect.h }
    self:drawPanel(bb, shadow, 10, nil, enabled and MUTED or LINE, 0)
    self:drawPanel(bb, rect, 10, enabled and INK or LINE,
        primary and INK or PAPER, 1)
    local color = not enabled and MUTED or (primary and PAPER or INK)
    local side_padding = 8
    local label_widget = self:newText(label, BUTTON_FONT_SIZE, true, color)
    local label_width = label_widget:getWidth() * LOGICAL_WIDTH / self.dimen.w
    label_widget:free()
    local icon_size = label == "" and 26 or BUTTON_ICON_SIZE
    local icon_width = icon_size + (label == "" and 0 or BUTTON_ICON_GAP)
    local has_icon = icon ~= nil
    local show_icon = has_icon and enabled
    local group_width = label_width + (has_icon and icon_width or 0)
    local group_x = logical.x + math.floor((logical.w - group_width) / 2)
    if show_icon then
        self:drawIcon(bb, icon, self:rect(group_x,
            logical.y + math.floor((logical.h - icon_size) / 2),
            icon_size, icon_size), primary)
    end
    if has_icon then group_x = group_x + icon_width end
    -- Keep one type size and center the icon and label as a stable group.
    self:drawText(bb, label, group_x, logical.y + 6,
        label_width + 2, logical.h - 12, BUTTON_FONT_SIZE, true, color, false)
    if enabled then self:addTarget(rect, action) end
end

local function feedPageCount(feed, page_size)
    return math.max(1, math.ceil(#((feed and feed.entries) or {}) / page_size))
end

function Shell:cachedPaginationTailPages(url, page_size)
    local pages, visited = 0, {}
    while url do
        local normalized = tostring(url):gsub("/+$", "")
        if visited[normalized] then return nil end
        visited[normalized] = true
        local cached = self.feed_cache[cacheKey(url, self.current_catalog)]
        if not cached or not cached.body then return nil end
        local feed = CatalogService.parse(cached.body, url)
        if not feed then return nil end
        pages = pages + feedPageCount(feed, page_size)
        url = feed.next_url
    end
    return pages
end

function Shell:feedPaginationPosition(entry_count, page_size)
    local completed_pages = 0
    for _, feed in ipairs(self.pagination_history) do
        completed_pages = completed_pages + feedPageCount(feed, page_size)
    end
    local local_page_count = math.max(1, math.ceil(entry_count / page_size))
    local local_page = math.floor(self.scroll_offsets.feed / page_size) + 1
    local page = completed_pages + local_page
    local next_url = self.current_feed and self.current_feed.next_url
    local total
    if #(self.preferred_languages or {}) == 0 and self.current_feed and
            self.current_feed.total_items then
        total = math.max(1, math.ceil(self.current_feed.total_items / page_size))
    elseif next_url then
        local cached_tail = self:cachedPaginationTailPages(next_url, page_size)
        if cached_tail then total = completed_pages + local_page_count + cached_tail end
    else
        total = completed_pages + local_page_count
    end
    return page, total,
        page > 1,
        local_page < local_page_count or next_url ~= nil
end

function Shell:drawFeedPager(bb, entry_count, page_size)
    local page, total, has_previous, has_next =
        self:feedPaginationPosition(entry_count, page_size)
    if page == 1 and total == 1 and not has_next then return end
    self:drawButton(bb, { x = 24, y = 856, w = 224, h = 54 },
        "Previous", "feed-items-previous", false, "chevron.left", has_previous)
    self:drawText(bb, total and string.format("Page %d of %d", page, total) or
            string.format("Page %d", page),
        262, 862, 234, 42, 17, false, MUTED, true)
    self:drawButton(bb, { x = 510, y = 856, w = 224, h = 54 },
        "Next", "feed-items-next", false, "chevron.right", has_next)
end

function Shell:drawHeader(bb, title, back, context)
    local header_height = context and 124 or 96
    local header = self:rect(0, 0, LOGICAL_WIDTH, header_height)
    bb:paintRect(header.x, header.y, header.w, header.h, INK)
    local left = back and 68 or 22
    if back then
        self:drawIcon(bb, "chevron.left", self:rect(16, 34, 28, 28), true)
        self:addTarget(self:rect(0, 0, 68, 96), "back")
    end
    if context then
        self:drawFittedParagraph(bb, context, left, 8,
            LOGICAL_WIDTH - left - 22, 47, 14, 10, LINE)
        self:drawText(bb, title, left, 62, LOGICAL_WIDTH - left - 22, 46,
            28, true, PAPER, false)
    else
        self:drawText(bb, "OPDS LIBRARY", left, 13, LOGICAL_WIDTH - left - 22, 22,
            16, false, LINE, false)
        self:drawText(bb, title, left, 35, LOGICAL_WIDTH - left - 22, 48,
            28, true, PAPER, false)
    end
    -- Deep catalog headers reserve the entire top line for their breadcrumb.
    -- Connection state remains visible on every top-level/action screen and
    -- through the dedicated offline screen without truncating that path.
    if not context then self:drawNetworkIndicator(bb) end
end

function Shell:drawNetworkIndicator(bb)
    local label
    if self.network_connecting then label = "Connecting"
    elseif self.network_connected then label = "Online"
    else label = "Offline" end
    local color = self.network_connected and PAPER or LINE
    local dot = self:rect(636, 17, 10, 10)
    self:drawPanel(bb, dot, 5, color,
        self.network_connected and color or INK, self.network_connected and 0 or 1)
    self:drawText(bb, label, 652, 7, 84, 30, 13, false, color, false)
end

function Shell:drawBottomBack(bb)
    local bar_y = 928
    bb:paintRect(0, self:sy(bar_y), self.dimen.w, self:sy(96), PAPER)
    bb:paintRect(0, self:sy(bar_y), self.dimen.w, self:ss(1), LINE)
    self:drawButton(bb, { x = 18, y = bar_y + 14, w = 72, h = 60 },
        "", "home", false, "home")
    self:drawButton(bb, { x = 100, y = bar_y + 14, w = 640, h = 60 },
        "Back", "back", false, "chevron.left")
end

function Shell:drawBottomActions(bb, label, action, icon)
    local bar_y = 928
    bb:paintRect(0, self:sy(bar_y), self.dimen.w, self:sy(96), PAPER)
    bb:paintRect(0, self:sy(bar_y), self.dimen.w, self:ss(1), LINE)
    self:drawButton(bb, { x = 18, y = bar_y + 14, w = 72, h = 60 },
        "", "home", false, "home")
    local secondary = 188
    self:drawButton(bb, { x = 100, y = bar_y + 14, w = secondary, h = 60 },
        "Back", "back", false, "chevron.left")
    self:drawButton(bb, { x = 298, y = bar_y + 14,
        w = 442, h = 60 }, label, action, true, icon)
end

function Shell:catalogUpUrl()
    if not self.current_feed or not self.current_catalog then return nil end
    local source = (self.current_feed.source_url or ""):gsub("/+$", "")
    local stored_parent = self.catalog_parents[#self.catalog_parents]
    for index = 1, 3 do
        local candidate
        if index == 1 then candidate = stored_parent and stored_parent.url
        elseif index == 2 then candidate = self.current_feed.up_url
        else candidate = self.bookmark_parent_url end
        if candidate and candidate:gsub("/+$", "") ~= source then return candidate end
    end
end

function Shell:fullFeedPath()
    local parts = {}
    local function add(title)
        title = trimInput(title)
        if title ~= "" and parts[#parts] ~= title then table.insert(parts, title) end
    end
    if self.current_catalog then add(self.current_catalog.title) end
    if #self.catalog_parents > 0 then
        for _, parent in ipairs(self.catalog_parents) do add(parent.label or parent.title) end
    else
        -- Compatibility for bookmarks written before structured parents were
        -- introduced. New bookmarks never depend on this title-only path.
        for _, title in ipairs(self.bookmark_path or {}) do add(title) end
    end
    if self.current_feed then
        local current_title = trimInput(self.current_feed._path_title or self.current_feed.title)
        if parts[#parts] ~= current_title then
            -- up_title is only a fallback when no traversed/saved path exists.
            -- A structured parent stack is authoritative; adding the OPDS
            -- relation title here would invent an extra breadcrumb segment.
            if #self.catalog_parents == 0 and #(self.bookmark_path or {}) == 0 then
                add(self.current_feed.up_title)
            end
            add(current_title)
        end
    end
    return parts
end

function Shell:feedBreadcrumb()
    local parts = self:fullFeedPath()
    -- fullFeedPath always appends the current feed. The header renders that
    -- feed as its title, so the breadcrumb contains parents only even when the
    -- clicked entry label differs from the feed's own title.
    if self.current_feed and #parts > 0 then table.remove(parts) end
    return #parts > 0 and table.concat(parts, "  /  ") or "OPDS LIBRARY"
end

function Shell:repairCatalogParents(parents, catalog)
    local repaired = cloneList(parents)
    local changed = false
    for index, parent in ipairs(repaired) do
        local label = parent.title
        local previous = repaired[index - 1]
        -- A feed title is normally the clearest path segment. Some catalogs,
        -- however, reuse one generic title for every prefix page. In that case
        -- recover the exact entry label that led from the previous feed to this
        -- one (for example: C / Cu / Cur), using the cached OPDS document.
        if previous and trimInput(previous.title) == trimInput(parent.title) then
            local cached = self.feed_cache[cacheKey(previous.url, catalog)]
            if cached and cached.body then
                local feed = CatalogService.parse(cached.body, previous.url)
                if feed then
                    for _, entry in ipairs(feed.entries or {}) do
                        if sameUrl(entry.url, parent.url) then
                            label = entry.title
                            break
                        end
                    end
                end
            end
        end
        label = trimInput(label)
        if label ~= "" and parent.label ~= label then
            parent.label = label
            changed = true
        end
    end
    return repaired, changed
end

function Shell:feedBackControl()
    if #self.feed_history > 0 then return "Back", "chevron.left" end
    if self.feed_return_screen == "bookmarks" then return "Bookmarks", "bookmark" end
    return "Catalogs", "chevron.left"
end

function Shell:drawFeedActions(bb, bookmarked, has_search, has_publications)
    local bar_y = 928
    bb:paintRect(0, self:sy(bar_y), self.dimen.w, self:sy(96), PAPER)
    bb:paintRect(0, self:sy(bar_y), self.dimen.w, self:ss(1), LINE)
    local up_url = self:catalogUpUrl()
    local show_up = up_url and #self.feed_history == 0
    local button_y, button_height = bar_y + 28, 52
    local nav_x = 18
    self:drawText(bb, "NAVIGATION", nav_x, bar_y + 5, 220, 18,
        11, true, MUTED, false)
    self:drawButton(bb, { x = nav_x, y = button_y, w = 60, h = button_height },
        "", "home", false, "home")
    nav_x = nav_x + 70
    self:drawButton(bb, { x = nav_x, y = button_y, w = 60, h = button_height },
        "", "back", false, "chevron.left")
    nav_x = nav_x + 70
    if show_up and not self.selection_mode then
        self:drawButton(bb, { x = nav_x, y = button_y, w = 60, h = button_height },
            "", "catalog-up", false, "chevron.up")
    end

    if self.selection_mode then
        local action_x = 360
        bb:paintRect(self:sx(action_x - 16), self:sy(bar_y + 10), self:ss(1),
            self:sy(70), LINE)
        self:drawText(bb, "SELECTION", action_x, bar_y + 5, 360, 18,
            11, true, MUTED, false)
        self:drawButton(bb, { x = action_x, y = button_y, w = 60, h = button_height },
            "", "selection-cancel", false, "close")
        self:drawButton(bb, { x = action_x + 70, y = button_y, w = 60, h = button_height },
            "", "selection-page", false, "check")
        self:drawButton(bb, { x = action_x + 140, y = button_y, w = 240, h = button_height },
            "Download (" .. self:selectedCount() .. ")", "selection-download", true,
            "bok-download", self:selectedCount() > 0)
        return
    end

    local actions = {
        { action = "refresh", icon = "bok-refresh" },
    }
    if has_search then
        table.insert(actions, { action = "search", icon = "appbar.search" })
    end
    if has_publications then
        table.insert(actions, { action = "selection-start", icon = "check" })
    end
    table.insert(actions, {
        action = bookmarked and "remove-current-bookmark" or "bookmark-current",
        icon = "bookmark",
        primary = bookmarked,
    })
    local actions_width = #actions * 60 + (#actions - 1) * 10
    local action_x = 740 - actions_width
    bb:paintRect(self:sx(action_x - 16), self:sy(bar_y + 10), self:ss(1),
        self:sy(70), LINE)
    self:drawText(bb, "CATALOG ACTIONS", action_x, bar_y + 5, actions_width, 18,
        11, true, MUTED, false)
    for _, action in ipairs(actions) do
        self:drawButton(bb, { x = action_x, y = button_y, w = 60, h = button_height },
            "", action.action, action.primary or false, action.icon)
        action_x = action_x + 70
    end
end

function Shell:drawStatus(bb)
    if not self.status then return end
    local rect = self:rect(16, 840, 726, 70)
    self:drawPanel(bb, rect, 10, INK, self.status_error and INK or PAPER, 2)
    self:drawIcon(bb, self.status_error and "close" or "check",
        self:rect(30, 863, 24, 24), self.status_error)
    self:drawText(bb, self.status, 66, 850, 652, 52, 18, false,
        self.status_error and PAPER or INK, false)
    self:addTarget(rect, "dismiss-status")
end

function Shell:drawBusy(bb)
    if not self.busy then return end
    -- A blocking operation owns the whole screen. Catalog headers may be 96
    -- or 124 logical pixels tall, so retaining a fixed 96-pixel strip cuts a
    -- deep breadcrumb header in two. Repaint and block the complete viewport
    -- for every request instead of relying on call sites to opt in.
    bb:paintRect(0, 0, self.dimen.w, self.dimen.h, LINE)
    self:addTarget(self:rect(0, 0, LOGICAL_WIDTH, LOGICAL_HEIGHT), "busy-block")
    local box = self:rect(189, 410, 380, 204)
    self:drawPanel(bb, box, 14, INK, PAPER, 3)
    for index = 0, 4 do
        local block = self:rect(293 + index * 30, 432, 22, 7)
        self:drawPanel(bb, block, 3, nil, index < 3 and INK or LINE, 0)
    end
    self:drawText(bb, self.busy .. "…", 211, 457, 336, 38, 21, true, INK, true)
    self:drawText(bb, "Please wait", 211, 494, 336, 24, 16, false, MUTED, true)
    self:drawButton(bb, { x = 213, y = 536, w = 332, h = 54 },
        "Cancel request", "cancel-network", false, "close")
end

function Shell:drawCatalogs(bb)
    self:drawHeader(bb, "BokOPDS", false)
    self:drawText(bb, "YOUR CATALOGS", 24, 116, 710, 24, 16, false, MUTED, false)
    if #self.catalogs == 0 then
        local empty = self:rect(24, 150, 710, 224)
        self:drawPanel(bb, empty, 14, LINE, PAPER, 1)
        self:drawIcon(bb, "bok-folder", self:rect(354, 178, 50, 50))
        self:drawText(bb, "No catalogs yet", 48, 242, 662, 34, 23, true, INK, true)
        self:drawParagraph(bb, "Add an HTTPS OPDS address to start browsing your library.",
            62, 284, 634, 18, MUTED, 50)
    else
        local visible = 6
        local offset = math.min(self.scroll_offsets.catalogs,
            math.max(0, #self.catalogs - visible))
        self.scroll_offsets.catalogs = offset
        for slot = 1, math.min(visible, #self.catalogs - offset) do
            local index = offset + slot
            local catalog = self.catalogs[index]
            local card_y = 150 + (slot - 1) * 106
            local card = self:rect(18, card_y, 722, 96)
            self:drawPanel(bb, card, 12, LINE, PAPER, 1)
            self:drawIcon(bb, "bok-folder", self:rect(32, card_y + 24, 48, 48))
            self:drawText(bb, catalog.title, 94, card_y + 12, 374, 34, 23, true, INK, false)
            self:drawText(bb, catalog.url or "", 94, card_y + 49, 374, 24, 16, false, MUTED, false)
            self:addTarget(self:rect(18, card_y, 468, 96), "open:" .. index)
            self:drawButton(bb, { x = 496, y = card_y + 20, w = 112, h = 56 },
                "Edit", "edit:" .. index, false, "edit")
            self:drawButton(bb, { x = 618, y = card_y + 20, w = 112, h = 56 },
                "Delete", "delete:" .. index, false, "bok-trash")
        end
    end
    local footer_width = math.floor((LOGICAL_WIDTH - 56) / 3)
    self:drawButton(bb, { x = 18, y = 874, w = footer_width, h = 58 },
        "Add catalog", "add", true, "plus")
    self:drawButton(bb, { x = 28 + footer_width, y = 874, w = footer_width, h = 58 },
        "Bookmarks (" .. #self.bookmarks .. ")", "bookmarks", false, "bookmark")
    self:drawButton(bb, { x = 38 + footer_width * 2, y = 874, w = footer_width, h = 58 },
        "Settings", "preferences", false, "appbar.settings")
    self:drawButton(bb, { x = 18, y = 944, w = 722, h = 48 },
        "Exit BokOPDS", "quit", false, "exit")
end

function Shell:languageOptions()
    local result, seen = {}, {}
    for _, option in ipairs(LANGUAGE_OPTIONS) do
        table.insert(result, option)
        seen[option[1]] = true
    end
    for _, code in ipairs(self.known_languages or {}) do
        if not seen[code] then
            table.insert(result, { code, code:upper() })
            seen[code] = true
        end
    end
    return result
end

function Shell:drawPreferences(bb)
    self:drawHeader(bb, "Preferences", false)
    self:drawText(bb, "PREFERRED BOOK LANGUAGES", 24, 116, 710, 24,
        16, false, MUTED, false)
    self:drawText(bb, "Books without language metadata remain visible.", 24, 140, 710, 26,
        15, false, MUTED, false)
    local options = self:languageOptions()
    local preferred = self:preferredLanguageSet()
    local rows = 7
    local total_rows = #options + 1
    local offset = math.min(self.scroll_offsets.preferences,
        math.max(0, total_rows - rows))
    self.scroll_offsets.preferences = offset
    for slot = 1, math.min(rows, total_rows - offset) do
        local option_index = offset + slot
        local code, label
        if option_index == 1 then code, label = "all", "All languages"
        else code, label = options[option_index - 1][1], options[option_index - 1][2] end
        local checked = code == "all" and #(self.preferred_languages or {}) == 0 or preferred[code]
        local y = 174 + (slot - 1) * 92
        local card = self:rect(24, y, 710, 82)
        self:drawPanel(bb, card, 11, checked and INK or LINE, PAPER, checked and 2 or 1)
        local box = self:rect(42, y + 23, 36, 36)
        self:drawPanel(bb, box, 5, INK, checked and INK or PAPER, 2)
        if checked then self:drawIcon(bb, "check", self:rect(48, y + 29, 24, 24), true) end
        self:drawText(bb, label, 96, y + 12, 510, 34, 21, true, INK, false)
        self:drawText(bb, code == "all" and "No filtering" or code:upper(),
            96, y + 47, 510, 22, 15, false, MUTED, false)
        self:addTarget(card, "language:" .. code)
    end
    local can_previous = offset > 0
    local can_next = offset + rows < total_rows
    if can_previous or can_next then
        self:drawButton(bb, { x = 24, y = 836, w = 224, h = 54 },
            "Previous", "preferences-previous", false, "chevron.left", can_previous)
        self:drawButton(bb, { x = 510, y = 836, w = 224, h = 54 },
            "Next", "preferences-next", false, "chevron.right", can_next)
    end
    local bar_y = 928
    bb:paintRect(0, self:sy(bar_y), self.dimen.w, self:sy(96), PAPER)
    bb:paintRect(0, self:sy(bar_y), self.dimen.w, self:ss(1), LINE)
    self:drawButton(bb, { x = 18, y = bar_y + 14, w = 72, h = 60 },
        "", "home", false, "home")
    self:drawButton(bb, { x = 100, y = bar_y + 14, w = 548, h = 60 },
        "Back", "back", false, "chevron.left")
    self:drawButton(bb, { x = 658, y = bar_y + 14, w = 82, h = 60 },
        "", "clear-cache", false, "bok-database")
end

function Shell:drawOffline(bb)
    self:drawHeader(bb, "Internet required", false)
    local panel = self:rect(24, 154, 710, 346)
    self:drawPanel(bb, panel, 14, INK, PAPER, 2)
    self:drawIcon(bb, "wifi", self:rect(337, 188, 84, 84))
    self:drawText(bb, "Connect to browse catalogs", 52, 292, 654, 42,
        24, true, INK, true)
    self:drawParagraph(bb, self.offline_reason or
        "BokOPDS needs an internet connection to browse catalogs, search, and download books.",
        70, 348, 618, 18, INK, 76)
    self:drawParagraph(bb,
        "You can continue offline to use cached pages, bookmarks, and catalog settings.",
        70, 424, 618, 17, MUTED, 58)
    self:drawButton(bb, { x = 24, y = 536, w = 710, h = 66 },
        self.network_manager:isConnected() and "Retry internet check" or "Check connection",
        "connect-network", true, "wifi", not self.network_connecting)
    self:drawButton(bb, { x = 24, y = 620, w = 710, h = 62 },
        "Continue offline", "continue-offline", false, "chevron.right")
    self:drawButton(bb, { x = 24, y = 936, w = 72, h = 56 },
        "", "home", false, "home")
    self:drawButton(bb, { x = 106, y = 936, w = 628, h = 56 },
        "Exit BokOPDS", "quit", false, "exit")
end

function Shell:drawForm(bb)
    self:drawHeader(bb, self.editing_index and "Edit catalog" or "Add catalog", true)
    local labels = { "Name", "HTTPS OPDS URL", "Username", "Password", "Download directory" }
    local keyboard_top = self:keyboardTop()
    if keyboard_top then
        local active_index = 1
        for index, input in ipairs(self.input_fields) do
            if input == self.active_input then active_index = index; break end
        end
        self:drawText(bb, "EDITING " .. string.upper(labels[active_index]),
            24, 124, 710, 24, 16, false, MUTED, false)
        self:drawText(bb, "Press Return to hide the keyboard, review all fields, and save.",
            24, 160, 710, 56, 17, false, INK, false)
        self:drawAnchoredInput(bb, self.active_input, labels[active_index], keyboard_top)
        return
    end
    local y = 116
    for index, input in ipairs(self.input_fields) do
        self:drawText(bb, labels[index], 24, y, 710, 22, 16, false, MUTED, false)
        y = y + 27
        self:paintInput(bb, input, self:sx(24), self:sy(y))
        y = y + 72
    end
    self:drawBottomActions(bb, self.editing_index and "Save changes" or "Save catalog",
        "save-catalog", "bok-save")
end

function Shell:drawDelete(bb)
    self:drawHeader(bb, "Delete catalog", false)
    self:drawText(bb, "CONFIRM DELETION", 24, 124, 710, 24, 16, false, MUTED, false)
    local warning = self:rect(24, 164, 710, 252)
    self:drawPanel(bb, warning, 14, INK, PAPER, 2)
    self:drawText(bb, self.pending_delete.title, 48, 188, 662, 38, 23, true, INK, false)
    self:drawParagraph(bb,
        "This removes the catalog, its saved sign-in details, and bookmarks from this catalog.",
        48, 246, 662, 20, INK, 92)
    self:drawParagraph(bb, "Downloaded books stay on the device.", 48, 350, 662, 18, MUTED, 40)
    self:drawBottomActions(bb, "Delete catalog", "confirm-delete", "bok-trash")
end

function Shell:drawBookmarks(bb)
    self:drawHeader(bb, "Bookmarks", false)
    self:drawText(bb, "SAVED CATALOG PLACES", 24, 116, 710, 24, 16, false, MUTED, false)
    if #self.bookmarks == 0 then
        local empty = self:rect(24, 150, 710, 224)
        self:drawPanel(bb, empty, 14, LINE, PAPER, 1)
        self:drawIcon(bb, "bookmark", self:rect(354, 178, 50, 50))
        self:drawText(bb, "No bookmarks yet", 48, 242, 662, 34, 23, true, INK, true)
        self:drawParagraph(bb,
            "Open an author, series, genre, or another catalog page and save it from the bottom action.",
            62, 284, 634, 18, MUTED, 64)
    else
        local visible = 7
        local offset = math.min(self.scroll_offsets.bookmarks,
            math.max(0, #self.bookmarks - visible))
        self.scroll_offsets.bookmarks = offset
        for slot = 1, math.min(visible, #self.bookmarks - offset) do
            local index = offset + slot
            local bookmark = self.bookmarks[index]
            local y = 150 + (slot - 1) * 106
            local card = self:rect(18, y, 722, 96)
            self:drawPanel(bb, card, 12, LINE, PAPER, 1)
            self:drawIcon(bb, "bookmark", self:rect(32, y + 24, 48, 48))
            self:drawText(bb, bookmark.title, 94, y + 12, 330, 34, 22, true, INK, false)
            self:drawText(bb, bookmark.catalog_title or "Catalog", 94, y + 49, 330, 24,
                16, false, MUTED, false)
            self:addTarget(self:rect(18, y, 430, 96), "bookmark-open:" .. index)
            self:drawButton(bb, { x = 440, y = y + 20, w = 140, h = 56 },
                "Rename", "bookmark-rename:" .. index, false, "edit")
            self:drawButton(bb, { x = 590, y = y + 20, w = 140, h = 56 },
                "Remove", "bookmark-remove:" .. index, false, "close")
        end
    end
    self:drawBottomBack(bb)
end

function Shell:drawBookmarkRename(bb)
    self:drawHeader(bb, "Rename bookmark", true)
    local input = self.input_fields[1]
    local keyboard_top = self:keyboardTop()
    if keyboard_top then
        self:drawText(bb, "Choose a name for this saved catalog place.",
            24, 140, 710, 56, 18, false, INK, false)
        self:drawAnchoredInput(bb, input, "Bookmark name", keyboard_top)
        return
    end
    self:drawText(bb, "BOOKMARK NAME", 24, 124, 710, 24, 16, false, MUTED, false)
    if input then self:paintInput(bb, input, self:sx(24), self:sy(158)) end
    self:drawParagraph(bb,
        "Choose a name that helps you recognize this saved catalog place.",
        24, 236, 710, 18, MUTED, 56)
    self:drawBottomActions(bb, "Save name", "save-bookmark-name", "bok-save")
end

function Shell:drawFeed(bb)
    self:drawHeader(bb, self.current_feed.title or "Catalog", false, self:feedBreadcrumb())
    local has_search = self.current_feed.search_url or self.current_feed.search_descriptor_url
    local has_publications = false
    for _, entry in ipairs(self.current_feed.entries or {}) do
        if entry.publication and self:preferredAcquisition(entry) then
            has_publications = true; break
        end
    end
    local entries = self:visibleFeedEntries()
    local visible = 7
    local last_page_offset = math.max(0, (math.ceil(#entries / visible) - 1) * visible)
    local offset = math.min(self.scroll_offsets.feed, last_page_offset)
    self.scroll_offsets.feed = offset
    for slot = 1, math.min(visible, #entries - offset) do
        local index = offset + slot
        local item = entries[index]
        local entry = item.entry
        local y = 136 + (slot - 1) * 92
        local card = self:rect(24, y, 710, 82)
        self:drawPanel(bb, card, 11, LINE, PAPER, 1)
        if self.selection_mode and entry.publication then
            local selected = self.selected_entries[self:entrySelectionKey(entry)] ~= nil
            local box = self:rect(44, y + 23, 36, 36)
            self:drawPanel(bb, box, 5, INK, selected and INK or PAPER, 2)
            if selected then
                self:drawIcon(bb, "check", self:rect(50, y + 29, 24, 24), true)
            end
        else
            self:drawIcon(bb, entry.publication and "book.opened" or "bok-folder",
                self:rect(40, y + 19, 44, 44))
        end
        if entry.author and entry.author ~= "" then
            self:drawText(bb, entry.title, 98, y + 6, 584, 34, 22, true, INK, false)
            self:drawText(bb, entry.author, 98, y + 41, 584, 24, 16, false, MUTED, false)
        else
            self:drawText(bb, entry.title, 98, y + 17, 584, 48, 22, true, INK, false)
        end
        if not self.selection_mode or not entry.publication then
            self:drawIcon(bb, "chevron.right", self:rect(696, y + 29, 24, 24))
        end
        self:addTarget(card, self.selection_mode and entry.publication and
            ("selection-entry:" .. item.index) or ("entry:" .. item.index))
    end
    if #entries == 0 then
        local empty = self:rect(24, 136, 710, 102)
        self:drawPanel(bb, empty, 12, LINE, PAPER, 1)
        local filtered = #(self.preferred_languages or {}) > 0 and
            #(self.current_feed.entries or {}) > 0
        self:drawText(bb, filtered and "No preferred-language books" or "Nothing here yet",
            48, 156, 662, 36, 23, true, INK, true)
        self:drawText(bb, filtered and "Change languages in Settings." or
            "This feed contains no entries.", 48, 196, 662, 28, 18, false, MUTED, true)
    end
    self:drawFeedPager(bb, #entries, visible)
    local bookmarked = self:bookmarkIndex(self.current_catalog.id, self:currentBookmarkUrl())
    self:drawFeedActions(bb, bookmarked ~= nil, has_search, has_publications)
end

function Shell:drawDetail(bb)
    local entry = self.current_entry
    self:drawHeader(bb, entry.title or "Publication", false)
    local viewport_top = self:sy(96)
    local viewport_bottom = self:sy(928)
    local content_bb = bb:viewport(0, viewport_top, self.dimen.w,
        viewport_bottom - viewport_top)
    local offset = math.min(self.scroll_offsets.detail, self.detail_max_scroll)
    self.scroll_offsets.detail = offset
    local page_top_padding = offset > 0 and 42 or 0
    local function contentY(y) return y - 96 - offset + page_top_padding end
    self.target_offset_y = viewport_top
    self.target_clip_top = viewport_top
    self.target_clip_bottom = viewport_bottom
    local text_x, text_width = 24, 710
    if entry.cover_path then
        local frame = self:rect(24, contentY(142), 186, 246)
        self:drawPanel(content_bb, frame, 5, LINE, PAPER, 1)
        self:drawImage(content_bb, entry.cover_path,
            self:rect(30, contentY(148), 174, 234), true)
        text_x, text_width = 228, 506
    end
    local text_y = 132
    if entry.author and entry.author ~= "" then
        self:drawText(content_bb, "BY " .. entry.author, text_x, contentY(126),
            text_width, 26, 16, false, MUTED, false)
        text_y = 164
    end
    local summary_height = self:drawParagraph(content_bb, entry.summary or "", text_x,
        contentY(text_y), text_width, 20, INK)
    local formats_y = math.max(entry.cover_path and 410 or 330,
        text_y + summary_height + 28)
    self:drawText(content_bb, "AVAILABLE FORMATS", 24, contentY(formats_y),
        710, 24, 16, false, MUTED, false)
    local preferred, other = {}, {}
    for index, acquisition in ipairs(entry.acquisitions or {}) do
        acquisition._index = index
        local name = CatalogService.formatName(acquisition)
        if name == "EPUB" or name == "PDF" then table.insert(preferred, acquisition)
        else table.insert(other, acquisition) end
    end
    local button_y = formats_y + 34
    for _, acquisition in ipairs(preferred) do
        self:drawButton(content_bb, { x = 24, y = contentY(button_y), w = 710, h = 58 },
            "Download " .. CatalogService.formatName(acquisition),
            "download:" .. acquisition._index, true, "bok-download")
        button_y = button_y + 68
    end
    if #other > 0 then
        self:drawButton(content_bb, { x = 24, y = contentY(button_y), w = 710, h = 56 },
            self.other_formats and "Hide other formats" or ("Other formats (" .. #other .. ")"),
            "toggle-formats", false, self.other_formats and "chevron.up" or "chevron.right")
        button_y = button_y + 66
        if self.other_formats then
            for _, acquisition in ipairs(other) do
                self:drawButton(content_bb,
                    { x = 24, y = contentY(button_y), w = 710, h = 54 },
                    "Download " .. CatalogService.formatName(acquisition),
                    "download:" .. acquisition._index, false, "bok-download")
                button_y = button_y + 64
            end
        end
    elseif #preferred == 0 then
        local empty = self:rect(24, contentY(button_y), 710, 78)
        self:drawPanel(content_bb, empty, 10, LINE, PAPER, 1)
        self:drawText(content_bb, "No EPUB or PDF download available", 48,
            contentY(button_y + 10), 662, 58,
            20, false, MUTED, true)
        button_y = button_y + 88
    end
    self.target_offset_y = nil
    self.target_clip_top = nil
    self.target_clip_bottom = nil
    self.detail_max_scroll = math.max(0, button_y + 20 - 928)
    if self.scroll_offsets.detail > self.detail_max_scroll then
        self.scroll_offsets.detail = self.detail_max_scroll
    end
    self:drawBottomBack(bb)
end

function Shell:drawSearch(bb)
    self:drawHeader(bb, "Search catalog", true)
    self:drawText(bb, "Find your next read", 24, 124, 710, 38, 23, true, INK, false)
    self:drawText(bb, "Search by title, author, series, or keyword.", 24, 168, 710, 34,
        18, false, MUTED, false)
    local input = self.input_fields[1]
    local keyboard_top = self:keyboardTop()
    if keyboard_top then
        self:drawAnchoredInput(bb, input, "Search query", keyboard_top)
        return
    end
    self:drawText(bb, "SEARCH QUERY", 24, 230, 710, 24, 16, false, MUTED, false)
    if input then self:paintInput(bb, input, self:sx(24), self:sy(257)) end
    self:drawButton(bb, { x = 24, y = 344, w = 710, h = 62 },
        "Search catalog", "search-go", true, "appbar.search")
    self:drawBottomBack(bb)
end

function Shell:drawBatchDownload(bb)
    self:drawHeader(bb, self.batch_download_editing_location and
        "Save location" or "Download books", false)
    local count = self:selectedCount()
    if self.batch_download_editing_location then
        self:drawBatchLocationEditor(bb)
        return
    end
    local summary = self:rect(24, 132, 710, 142)
    self:drawPanel(bb, summary, 13, INK, PAPER, 2)
    self:drawIcon(bb, "bok-download", self:rect(48, 172, 54, 54))
    self:drawText(bb, string.format("%d selected book%s", count,
        count == 1 and "" or "s"), 126, 150, 576, 42, 25, true, INK, false)
    self:drawText(bb, "Review where the selected books will be saved.",
        126, 198, 576, 32, 17, false, MUTED, false)

    local destination = self:batchDownloadDirectory() or
        self:catalogDownloadDirectory(self.current_catalog)
    self:drawText(bb, "SAVE PATH", 24, 316, 710, 24, 16, false, MUTED, false)
    local path_panel = self:rect(24, 352, 710, 116)
    self:drawPanel(bb, path_panel, 11, LINE, PAPER, 1)
    self:drawIcon(bb, "bok-folder", self:rect(46, 386, 44, 44))
    self:drawFittedParagraph(bb, destination, 110, 370, 590, 76,
        17, 14, INK, PAPER)
    self:drawButton(bb, { x = 24, y = 492, w = 300, h = 56 },
        "Change save location", "batch-location-edit", false, "edit")
    self:drawText(bb, "Optional", 344, 503, 180, 34, 16, false, MUTED, false)
    self:drawBottomActions(bb, "Download " .. count .. " books",
        "batch-download-start", "bok-download")
end

function Shell:drawBatchLocationEditor(bb)
    local keyboard_top = self:keyboardTop()
    local folder_mode = self.batch_download_location == "folder"
    if keyboard_top and folder_mode then
        self:drawText(bb, "CREATE A FOLDER", 24, 132, 710, 24,
            16, false, MUTED, false)
        self:drawText(bb, "The folder will be created inside the configured download folder.",
            24, 170, 710, 56, 17, false, INK, false)
        self:drawAnchoredInput(bb, self.input_fields[1], "New folder name", keyboard_top)
        return
    end

    self:drawText(bb, "SAVE LOCATION", 24, 132, 710, 24, 16, false, MUTED, false)
    local function drawChoice(y, title, detail, action, selected)
        local card = self:rect(24, y, 710, 92)
        self:drawPanel(bb, card, 11, selected and INK or LINE, PAPER,
            selected and 2 or 1)
        local box = self:rect(44, y + 28, 36, 36)
        self:drawPanel(bb, box, 18, INK, selected and INK or PAPER, 2)
        if selected then
            self:drawIcon(bb, "check", self:rect(50, y + 34, 24, 24), true)
        end
        self:drawText(bb, title, 102, y + 12, 598, 34, 21, true, INK, false)
        self:drawFittedParagraph(bb, detail, 102, y + 49, 598, 28,
            15, 12, MUTED, PAPER)
        self:addTarget(card, action)
    end
    local base_directory = self:catalogDownloadDirectory(self.current_catalog)
    drawChoice(174, "Use configured folder", "Save path: " .. base_directory,
        "batch-location-current", not folder_mode)
    drawChoice(280, "Create a new folder",
        "Keep these selected books together in a subfolder.",
        "batch-location-folder", folder_mode)

    if folder_mode then
        self:drawText(bb, "NEW FOLDER NAME", 24, 406, 710, 24,
            16, false, MUTED, false)
        local input = self.input_fields[1]
        if input then self:paintInput(bb, input, self:sx(24), self:sy(440)) end
        local destination = self:batchDownloadDirectory()
        self:drawText(bb, "Save path: " .. (destination or base_directory),
            24, 516, 710, 50, 15, false, MUTED, false)
    end
    self:drawBottomActions(bb, "Use this location",
        "batch-location-done", "check")
end

function Shell:drawDownloadComplete(bb)
    local summary = self.download_summary or {
        files = {}, completed = 0, failed = 0,
    }
    local panel = self:rect(24, 32, 710, 226)
    self:drawPanel(bb, panel, 14, INK, PAPER, 3)
    local badge = self:rect(50, 66, 58, 58)
    self:drawPanel(bb, badge, 29, INK, INK, 0)
    self:drawIcon(bb, "check", self:rect(65, 81, 28, 28), true)
    local result_count = summary.completed + summary.failed
    local title = (summary.failed > 0 or (summary.refresh_failed or 0) > 0) and
        "Downloads finished with issues" or
        (result_count == 1 and "Download complete" or "Downloads complete")
    self:drawText(bb, title, 132, 52, 564, 46, 25, true, INK, false)
    local stats = string.format("%d downloaded  •  %s added",
        summary.completed, formatBytes(summary.total_bytes))
    if summary.failed > 0 then stats = stats .. string.format("  •  %d failed", summary.failed) end
    if (summary.refresh_failed or 0) > 0 then
        stats = stats .. string.format("  •  %d not queued for library scan", summary.refresh_failed)
    end
    self:drawText(bb, stats, 132, 101, 564, 34, 17, false, MUTED, false)
    self:drawText(bb, "SAVED TO", 50, 154, 120, 22, 13, true, MUTED, false)
    self:drawFittedParagraph(bb, summary.destination or "", 50, 181, 646, 56,
        17, 13, INK, PAPER)

    self:drawText(bb, "DOWNLOAD RESULTS", 24, 282, 710, 24,
        16, false, MUTED, false)
    local files = summary.files or {}
    local page_size = 6
    local offset = math.min(self.download_summary_offset or 0,
        math.max(0, (math.ceil(#files / page_size) - 1) * page_size))
    self.download_summary_offset = offset
    for slot = 1, math.min(page_size, #files - offset) do
        local file = files[offset + slot]
        local y = 314 + (slot - 1) * 82
        local card = self:rect(24, y, 710, 72)
        self:drawPanel(bb, card, 10, LINE, PAPER, 1)
        self:drawIcon(bb, "book.opened", self:rect(42, y + 17, 38, 38))
        self:drawText(bb, file.name or "Book", 98, y + 3, 500, 32,
            19, true, INK, false)
        self:drawText(bb, "Downloaded file",
            98, y + 34, 500, 25, 14, false, MUTED, false)
        self:drawText(bb, formatBytes(file.size), 604, y + 16, 104, 30,
            16, false, MUTED, true)
    end
    if #files == 0 then
        self:drawText(bb, "No completed files", 24, 342, 710, 42,
            20, true, MUTED, true)
    end
    local page = math.floor(offset / page_size) + 1
    local pages = math.max(1, math.ceil(#files / page_size))
    if pages > 1 then
        self:drawButton(bb, { x = 24, y = 828, w = 224, h = 54 },
            "Previous", "download-summary-previous", false, "chevron.left", page > 1)
        self:drawText(bb, string.format("Page %d of %d", page, pages),
            262, 834, 234, 42, 17, false, MUTED, true)
        self:drawButton(bb, { x = 510, y = 828, w = 224, h = 54 },
            "Next", "download-summary-next", false, "chevron.right", page < pages)
    end
    local bar_y = 928
    bb:paintRect(0, self:sy(bar_y), self.dimen.w, self:sy(96), PAPER)
    bb:paintRect(0, self:sy(bar_y), self.dimen.w, self:ss(1), LINE)
    self:drawButton(bb, { x = 18, y = bar_y + 14, w = 72, h = 60 },
        "", "home", false, "home")
    local finish_label = summary.completed > 0 and "Finish & update library" or "Done"
    local finish_action = summary.completed > 0 and
        "download-summary-finish" or "download-summary-done"
    self:drawButton(bb, { x = 100, y = bar_y + 14, w = 640, h = 60 },
        finish_label, finish_action, true, "check")
end

function Shell:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local input = self.input_repaint
    if input and input == self.active_input and input._bokopds_x then
        self.input_repaint = nil
        input:paintTo(bb, input._bokopds_x, input._bokopds_y)
        return
    end
    self.input_repaint = nil
    self.targets = {}
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, PAPER)
    if self.screen == "offline" then self:drawOffline(bb)
    elseif self.screen == "catalogs" then self:drawCatalogs(bb)
    elseif self.screen == "form" then self:drawForm(bb)
    elseif self.screen == "delete" then self:drawDelete(bb)
    elseif self.screen == "bookmarks" then self:drawBookmarks(bb)
    elseif self.screen == "preferences" then self:drawPreferences(bb)
    elseif self.screen == "bookmark-rename" then self:drawBookmarkRename(bb)
    elseif self.screen == "feed" then self:drawFeed(bb)
    elseif self.screen == "detail" then self:drawDetail(bb)
    elseif self.screen == "search" then self:drawSearch(bb)
    elseif self.screen == "batch-download" then self:drawBatchDownload(bb)
    elseif self.screen == "download-complete" then self:drawDownloadComplete(bb)
    end
    self:drawStatus(bb)
    self:drawBusy(bb)
end

function Shell:clearInputs()
    for _, input in ipairs(self.input_fields) do
        input:onCloseKeyboard()
        input:onCloseWidget()
        for index = #self, 1, -1 do
            if self[index] == input then table.remove(self, index) end
        end
    end
    self.input_fields = {}
    self.active_input = nil
end

function Shell:addInput(value, hint, secret)
    local input
    input = InputText:new{
        text = value or "",
        hint = hint or "",
        text_type = secret and "password" or nil,
        show_password_toggle = false,
        parent = self,
        focused = #self.input_fields == 0,
        width = self:sx(682),
        height = self:sy(30),
        face = Font:getFace("cfont", 21),
        padding = self:ss(10),
        margin = 0,
        bordersize = self:ss(1),
        scroll = false,
        enter_callback = function()
            if self.screen == "search" then
                self:activate("search-go")
            elseif self.active_input then
                self.active_input:onCloseKeyboard()
                self:invalidate("full")
            end
        end,
        edit_callback = function(edited)
            if edited and input._bokopds_x then self.input_repaint = input end
        end,
    }
    input._frame_textwidget.radius = self:ss(9)
    input._frame_textwidget.background = PAPER
    table.insert(self.input_fields, input)
    table.insert(self, input)
    if not self.active_input then self.active_input = input end
end

function Shell:showForm(index)
    self:clearInputs()
    self.screen = "form"
    self.editing_index = index
    local catalog = index and self.catalogs[index] or {}
    self:addInput(catalog.title, "Catalog name")
    self:addInput(catalog.url, "https://example.org/opds")
    self:addInput(catalog.username, "Optional")
    self:addInput(catalog.password, "Optional", true)
    self:addInput(catalog.download_directory,
        self:defaultDownloadDirectory())
    self.active_input:onShowKeyboard()
    self:invalidate("full")
end

function Shell:showSearch()
    self:clearInputs()
    self.screen = "search"
    self:addInput("", "Title, author, series, or keyword")
    self.active_input:onShowKeyboard()
    self:invalidate("full")
end

function Shell:showBookmarkRename(index)
    local bookmark = self.bookmarks[index]
    if not bookmark then return end
    self:clearInputs()
    self.screen = "bookmark-rename"
    self.editing_bookmark_index = index
    self:addInput(bookmark.title, "Bookmark name")
    self.active_input:onShowKeyboard()
    self:invalidate("full")
end

function Shell:suggestBatchFolderName()
    local name = trimInput(self.current_feed and self.current_feed.title or "Selected books")
    name = name:gsub('[%c<>:"/\\|%?%*]', "-")
        :gsub("%s+", " ")
        :gsub("^[%. ]+", "")
        :gsub("[%. ]+$", "")
    if name == "" or #name > 128 then name = "Selected books" end
    return name
end

function Shell:showBatchDownload()
    if self:selectedCount() == 0 then return end
    self:clearInputs()
    self.batch_download_location = "current"
    self.batch_folder_name = self:suggestBatchFolderName()
    self.batch_download_editing_location = false
    if self:selectedCount() == 1 then
        self.screen = "feed"
        self:downloadSelected(self:catalogDownloadDirectory(self.current_catalog))
        return
    end
    self.screen = "batch-download"
    self:invalidate("full")
end

function Shell:setBatchDownloadLocation(location)
    if self.input_fields[1] then
        self.batch_folder_name = trimInput(self.input_fields[1]:getText())
    end
    self:clearInputs()
    self.batch_download_location = location
    if location == "folder" then
        self:addInput(self.batch_folder_name or self:suggestBatchFolderName(), "Folder name")
        self.active_input:onShowKeyboard()
    end
    self:invalidate("full")
end

function Shell:batchDownloadDirectory()
    local base = self:catalogDownloadDirectory(self.current_catalog)
    if self.batch_download_location ~= "folder" then return base end
    local input = self.input_fields[1]
    local name = trimInput(input and input:getText() or self.batch_folder_name)
    if name == "" then return nil, "Folder name is required" end
    if name == "." or name == ".." or name:find('[%c<>:"/\\|%?%*]') or
            name:find("[%. ]$") then
        return nil, "Folder name contains unsupported characters"
    end
    if #name > 128 then return nil, "Folder name is too long" end
    return base:gsub("/+$", "") .. "/" .. name
end

function Shell:prepareSearch()
    if self.current_feed.search_url then
        self:showSearch()
        return
    end
    local descriptor_url = self.current_feed.search_descriptor_url
    if not descriptor_url then
        self:setStatus("This catalog does not provide search", true)
        return
    end
    if self:deferUntilConnected(function() self:prepareSearch() end) then return end
    self.busy = "Preparing search"
    self:invalidate("full")
    UIManager:forceRePaint()
    Trapper:wrap(function()
        local completed, response = Trapper:dismissableRunInSubprocess(
            CatalogService.fetchTask(descriptor_url, self.current_catalog.username,
                self.current_catalog.password, self.current_catalog.url), self)
        self.busy, self.dismiss_callback = nil, nil
        if not completed then
            self:setStatus("Search request cancelled", false)
            return
        end
        if not response or not response.ok then
            self:setStatus("Search description request failed", true)
            return
        end
        local template, error_message = CatalogService.parseSearchDescription(
            response.body, descriptor_url)
        if not template then
            self:setStatus(error_message, true)
            return
        end
        self.current_feed.search_url = template
        self:showSearch()
    end)
end

function Shell:onSwitchFocus(input)
    if self.active_input ~= input then
        if self.active_input then
            self.active_input:onCloseKeyboard()
            self.active_input:unfocus()
        end
        self.active_input = input
        input:focus()
    end
    input:onShowKeyboard()
    self:invalidate("ui")
    return true
end

-- InputText expects its parent to provide the small part of the focus-manager
-- contract used on desktop/D-pad capable devices. Our controls are painted
-- directly, so only text fields participate in that focus grid.
function Shell:getFocusableWidgetXY(widget)
    for index, input in ipairs(self.input_fields) do
        if input == widget then return 1, index end
    end
end

function Shell:moveFocusTo(_, row)
    local input = self.input_fields[row]
    if input then return self:onSwitchFocus(input) end
    return false
end

function Shell:onKeyboardHeightChanged() self:invalidate("full") end
function Shell:onCloseDialog() self:back() end

function Shell:setStatus(text, is_error)
    if self.status_timeout then
        UIManager:unschedule(self.status_timeout)
        self.status_timeout = nil
    end
    self.status, self.status_error = text, is_error
    self:invalidate("ui")
    if not is_error then
        local expected_text = text
        self.status_timeout = function()
            self.status_timeout = nil
            if self.status == expected_text and not self.status_error then
                self.status, self.status_error = nil, nil
                self:invalidate("ui")
            end
        end
        UIManager:scheduleIn(3, self.status_timeout)
    end
end

function Shell:clearStatus()
    if self.status_timeout then
        UIManager:unschedule(self.status_timeout)
        self.status_timeout = nil
    end
    self.status, self.status_error = nil, nil
    self:invalidate("ui")
end

function Shell:validateCatalog(catalog)
    if catalog.title == "" then return false, "Catalog name is required" end
    local loopback = os.getenv("BOKOPDS_ALLOW_INSECURE_LOOPBACK") == "1" and
        (catalog.url:match("^http://127%.0%.0%.1[:/]") or
            catalog.url:match("^http://localhost[:/]"))
    if not catalog.url:lower():match("^https://") and not loopback then
        return false, "Catalog URL must use HTTPS"
    end
    return true
end

function Shell:saveCatalog()
    local catalog = self.editing_index and clone(self.catalogs[self.editing_index]) or {
        id = string.format("catalog-%d-%d", os.time(), math.random(1000, 9999)),
    }
    catalog.title = trimInput(self.input_fields[1]:getText())
    catalog.url = trimInput(self.input_fields[2]:getText())
    catalog.username = trimInput(self.input_fields[3]:getText())
    catalog.password = self.input_fields[4]:getText()
    catalog.download_directory = trimInput(self.input_fields[5]:getText())
    if catalog.download_directory == "" then
        catalog.download_directory = self:defaultDownloadDirectory()
    end
    local valid, message = self:validateCatalog(catalog)
    if not valid then self:setStatus(message, true); return end
    local safe_directory, directory_error = self:safeDownloadDirectory(catalog.download_directory)
    if not safe_directory then self:setStatus(directory_error, true); return end
    catalog.download_directory = safe_directory
    if self.editing_index then self:purgeCatalogCache(self.catalogs[self.editing_index]) end
    if self.editing_index then self.catalogs[self.editing_index] = catalog
    else table.insert(self.catalogs, catalog) end
    self:saveState()
    self:clearInputs()
    self.screen = "catalogs"
    self.editing_index = nil
    self:setStatus("Catalog saved", false)
    self:invalidate("full")
end

local function cacheExpiry(headers, now)
    local control = tostring(headers and headers["cache-control"] or ""):lower()
    if control:find("no%-store") or control:find("no%-cache") or
            control:find("must%-revalidate") then return nil end
    local maximum = tonumber(control:match("max%-age%s*=%s*(%d+)"))
    if maximum == 0 then return nil end
    local age = tonumber(headers and headers.age) or 0
    return now + math.max(0, (maximum or 3600) - age)
end

function Shell:saveBookmarkName()
    local bookmark = self.bookmarks[self.editing_bookmark_index]
    local input = self.input_fields[1]
    if not bookmark or not input then return end
    local title = trimInput(input:getText())
    if title == "" then
        self:setStatus("Bookmark name is required", true)
        return
    end
    bookmark.title = title
    self:saveState()
    self:clearInputs()
    self.editing_bookmark_index = nil
    self.screen = "bookmarks"
    self:setStatus("Bookmark renamed", false)
    self:invalidate("full")
end

function Shell:bookmarkIndex(catalog_id, url)
    for index, bookmark in ipairs(self.bookmarks) do
        if bookmark.catalog_id == catalog_id and bookmark.url == url then return index end
    end
end

function Shell:currentBookmarkUrl()
    return self.current_feed and
        (self.current_feed.bookmark_url or self.current_feed.source_url)
end

function Shell:catalogById(id)
    for _, catalog in ipairs(self.catalogs) do if catalog.id == id then return catalog end end
end

function Shell:adoptFeed(feed, title, preserve_history, navigation_kind)
    local previous = self.current_feed
    local up_parent = self.pending_up_parent
    self:rememberFeedLanguages(feed)
    if navigation_kind == "append" and previous and
            #(previous.entries or {}) + #(feed.entries or {}) <= MAX_AGGREGATED_ENTRIES then
        self.append_chain_count = (self.append_chain_count or 0) + 1
        for _, entry in ipairs(feed.entries or {}) do
            table.insert(previous.entries, entry)
        end
        previous.next_url = feed.next_url
        previous.total_items = previous.total_items or feed.total_items
        previous.items_per_page = previous.items_per_page or feed.items_per_page
        previous.last_url = previous.last_url or feed.last_url
        local target_offset = self.pending_append_offset or
            math.max(0, #previous.entries - #(feed.entries or {}))
        self.pending_append_offset = nil
        self.current_feed = previous
        self.screen = "feed"
        local visible_count = #self:visibleFeedEntries()
        if previous.next_url and visible_count - target_offset < 7 and
                self.append_chain_count < MAX_AUTO_APPEND_PAGES then
            self.pending_append_offset = target_offset
            UIManager:scheduleIn(0, function()
                self:loadFeed(previous.next_url, self.current_catalog,
                    nil, false, true, "append")
            end)
            return
        end
        local last_offset = math.max(0, (math.ceil(visible_count / 7) - 1) * 7)
        self.scroll_offsets.feed = math.min(target_offset, last_offset)
        return
    end
    if navigation_kind == "append" then
        navigation_kind = "page"
        preserve_history = true
        self.pending_append_offset = nil
    else
        self.append_chain_count = 0
    end
    if navigation_kind ~= "page" then self:clearSelection() end
    local evicted_feed
    if navigation_kind == "page" and previous then
        pushBounded(self.pagination_history, previous, MAX_PAGINATION_HISTORY)
    elseif not preserve_history and previous then
        evicted_feed = pushBounded(self.feed_history, previous, MAX_FEED_HISTORY)
        if evicted_feed and evicted_feed._catalog_parent_recorded then
            table.remove(self.catalog_parents, 1)
        end
    end
    if navigation_kind == "child" and previous then
        previous._catalog_parent_recorded = true
        previous._pagination_history = cloneList(self.pagination_history)
        self.pagination_history = {}
        local preceding = self.catalog_parents[#self.catalog_parents]
        local path_label = previous.title or "Catalog"
        if preceding and trimInput(preceding.title) == trimInput(previous.title) then
            path_label = previous._path_title or path_label
        end
        pushBounded(self.catalog_parents, {
            title = previous.title or "Catalog",
            label = path_label,
            url = previous.source_url,
        }, MAX_CATALOG_PARENTS)
    elseif navigation_kind == "up" and up_parent then
        local stored_parent = self.catalog_parents[#self.catalog_parents]
        if stored_parent and stored_parent.url == up_parent.url then
            table.remove(self.catalog_parents)
        end
        self.pending_up_parent = nil
        self.pagination_history = {}
    end
    self:trimNavigationHistory()
    feed._navigation_kind = navigation_kind or
        (preserve_history and previous and previous._navigation_kind) or nil
    feed._pagination_page = navigation_kind == "page" or
        (navigation_kind == nil and preserve_history and previous and previous._pagination_page) or false
    feed.bookmark_url = navigation_kind == "page" and previous and
        (previous.bookmark_url or previous.source_url) or
        (navigation_kind == nil and preserve_history and previous and previous.bookmark_url) or nil
    if navigation_kind == "child" then
        feed._path_title = title
    elseif navigation_kind == "page" and previous then
        feed._path_title = previous._path_title
    elseif navigation_kind == "up" and up_parent then
        feed._path_title = up_parent.label or up_parent.title
    elseif navigation_kind == nil and preserve_history and previous then
        feed._path_title = previous._path_title
    end
    self.current_feed = feed
    if title and (not feed.title or feed.title == "Catalog") then feed.title = title end
    self.screen = "feed"
    self:resetScroll("feed")
end

function Shell:loadFeed(url, catalog, title, force, preserve_history, navigation_kind)
    if not url then return end
    self.current_catalog = catalog
    local key = cacheKey(url, catalog)
    local cached = self.feed_cache[key]
    if not force and cached and cached.body and os.time() <
            (cached.expires_at or ((cached.stored_at or 0) + 3600)) then
        local feed, error_message = CatalogService.parse(cached.body, url)
        if feed then
            self:adoptFeed(feed, title, preserve_history, navigation_kind)
            self:invalidate("full")
            return
        elseif error_message then
            self.feed_cache[key] = nil
            self:scheduleFeedCacheSave()
        end
    end
    if self:deferUntilConnected(function()
        self:loadFeed(url, catalog, title, force, preserve_history, navigation_kind)
    end) then return end
    self.busy = force and "Refreshing catalog" or
        (navigation_kind == "append" and "Loading more books" or "Opening catalog")
    self:invalidate("full")
    UIManager:forceRePaint()
    Trapper:wrap(function()
        local completed, response = Trapper:dismissableRunInSubprocess(
            CatalogService.fetchTask(url, catalog.username, catalog.password, catalog.url), self)
        self.busy = nil
        self.dismiss_callback = nil
        if not completed then
            self.pending_up_parent = nil
            self.pending_append_offset = nil
            self:setStatus("Network request cancelled", false)
            return
        end
        if not response or not response.ok then
            self.pending_up_parent = nil
            self.pending_append_offset = nil
            local message, resolver_failure = self:catalogFailureMessage(response)
            if resolver_failure then
                self:showOffline(message)
            else
                self:setStatus(message, true)
            end
            return
        end
        local feed, error_message = CatalogService.parse(response.body, url)
        if not feed then
            self.pending_up_parent = nil
            self.pending_append_offset = nil
            self:setStatus(error_message, true)
            return
        end
        local now = os.time()
        local expires_at = cacheExpiry(response.headers, now)
        if expires_at then
            self.feed_cache[key] = { body = response.body, stored_at = now,
                expires_at = expires_at }
            self:pruneFeedCache()
        else
            self.feed_cache[key] = nil
        end
        self:adoptFeed(feed, title, preserve_history, navigation_kind)
        self:saveState()
        self:invalidate("full")
        self:scheduleFeedCacheSave()
    end)
end

function Shell:download(acquisition, entry)
    if self:deferUntilConnected(function() self:download(acquisition, entry) end) then return end
    local catalog = self.current_catalog
    local planned = CatalogService.planDownload(
        self:downloadAcquisition(acquisition, entry), catalog.download_directory)
    Trapper:wrap(function()
        require("pluginshare").pause_auto_suspend = true
        self.busy = "Downloading " .. CatalogService.formatName(acquisition)
        self:invalidate("full")
        UIManager:forceRePaint()
        local completed, result = Trapper:dismissableRunInSubprocess(
            CatalogService.downloadTask(planned,
                catalog.download_directory, catalog.username, catalog.password, catalog.url), self)
        self.busy, self.dismiss_callback = nil, nil
        require("pluginshare").pause_auto_suspend = false
        if not completed then
            local size = require("libs/libkoreader-lfs").attributes(
                planned.destination_path, "size")
            if size then
                local refresh_ok, refresh_error = self:markLibraryRefresh(planned.destination_path)
                if refresh_ok then
                    self:setStatus("Download completed before cancellation", false)
                else
                    self:setStatus("Downloaded, but library refresh could not be queued: " .. refresh_error, true)
                end
            else
                os.remove(planned.partial_path)
                self:setStatus("Download cancelled", false)
            end
            return
        end
        if not result or not result.ok then
            self:setStatus("Download failed: " .. tostring(result and result.error or "unknown error"), true)
            return
        end
        local refresh_ok, refresh_error = self:markLibraryRefresh(result.path)
        if refresh_ok then
            self:setStatus("Downloaded: " .. result.path:match("([^/]+)$"), false)
        else
            self:setStatus("Downloaded, but library refresh could not be queued: " .. refresh_error, true)
        end
    end)
end

function Shell:markLibraryRefresh(path)
    local marker_path = os.getenv("BOKOPDS_LIBRARY_REFRESH_MARKER") or
        (require("datastorage"):getDataDir() .. "/library-refresh.pending")
    local marker, open_error = io.open(marker_path, "a")
    if not marker then return nil, tostring(open_error or "marker could not be opened") end
    local wrote, write_error = marker:write(path, "\n")
    local closed, close_error = marker:close()
    if not wrote or not closed then
        return nil, tostring(write_error or close_error or "marker could not be written")
    end
    return true
end

function Shell:runDownloadQueue(queue, catalog)
    local completed_count, failed_count, refresh_failed, cancelled = 0, 0, 0, false
    local completed_keys, completed_files = {}, {}
    require("pluginshare").pause_auto_suspend = true
    for index, queued in ipairs(queue) do
        self.busy = string.format("Downloading %d of %d", index, #queue)
        self:invalidate("full")
        UIManager:forceRePaint()
        local planned = CatalogService.planDownload(queued.value.acquisition,
            catalog.download_directory)
        local completed, result = Trapper:dismissableRunInSubprocess(
            CatalogService.downloadTask(planned,
                catalog.download_directory, catalog.username, catalog.password, catalog.url), self)
        self.dismiss_callback = nil
        if not completed then
            local size = require("libs/libkoreader-lfs").attributes(
                planned.destination_path, "size")
            if size then
                completed = true
                result = { ok = true, path = planned.destination_path, size = size }
            else
                os.remove(planned.partial_path)
                cancelled = true
                break
            end
        end
        if result and result.ok then
            table.insert(completed_keys, queued.key)
            local size = result.size or
                require("libs/libkoreader-lfs").attributes(result.path, "size") or 0
            table.insert(completed_files, {
                path = result.path,
                name = result.path:match("([^/]+)$") or result.path,
                size = size,
            })
            completed_count = completed_count + 1
            if not self:markLibraryRefresh(result.path) then refresh_failed = refresh_failed + 1 end
        else
            failed_count = failed_count + 1
        end
    end
    self.busy, self.dismiss_callback = nil, nil
    require("pluginshare").pause_auto_suspend = false
    return completed_count, failed_count, cancelled,
        completed_keys, completed_files, refresh_failed
end

function Shell:finishSelectedDownloads(completed_count, failed_count, cancelled,
        completed_keys, completed_files, destination, refresh_failed)
    for _, key in ipairs(completed_keys) do
        self.selected_entries[key] = nil
        for index = #self.selection_order, 1, -1 do
            if self.selection_order[index] == key then table.remove(self.selection_order, index) end
        end
    end
    if cancelled then
        local processed = completed_count
        self:setStatus(string.format("Cancelled after %d result%s", processed,
            processed == 1 and "" or "s"), false)
    elseif completed_count == 0 and failed_count > 0 then
        self:setStatus(string.format("Downloaded %d; %d failed", completed_count, failed_count), true)
    else
        self:clearStatus()
        if failed_count == 0 then self:clearSelection() end
        local total_bytes = 0
        for _, file in ipairs(completed_files or {}) do
            total_bytes = total_bytes + (file.size or 0)
        end
        self.download_summary = {
            completed = completed_count,
            failed = failed_count,
            refresh_failed = refresh_failed or 0,
            destination = destination,
            total_bytes = total_bytes,
            files = completed_files or {},
        }
        self.download_summary_offset = 0
        self.screen = "download-complete"
    end
    self:invalidate("full")
end

function Shell:downloadSelected(destination)
    if self:selectedCount() == 0 then return end
    if self:deferUntilConnected(function() self:downloadSelected(destination) end) then return end
    local queue = {}
    for _, key in ipairs(self.selection_order) do
        if self.selected_entries[key] then
            table.insert(queue, { key = key, value = self.selected_entries[key] })
        end
    end
    local catalog = clone(self.current_catalog)
    if destination then catalog.download_directory = destination end
    Trapper:wrap(function()
        local completed_count, failed_count, cancelled,
            completed_keys, completed_files, refresh_failed = self:runDownloadQueue(queue, catalog)
        self:finishSelectedDownloads(completed_count, failed_count, cancelled,
            completed_keys, completed_files, catalog.download_directory, refresh_failed)
    end)
end

function Shell:loadCover(entry)
    local remote_url = entry.image or entry.thumbnail
    if not remote_url then return false end
    local md5 = require("ffi/sha2").md5
    local clean_url = remote_url:gsub("%?.*$", "")
    local extension = clean_url:match("%.([%a%d]+)$") or "jpg"
    extension = extension:lower()
    if extension ~= "png" and extension ~= "jpg" and extension ~= "jpeg" and extension ~= "gif" then
        extension = "jpg"
    end
    local directory = require("datastorage"):getDataDir() .. "/cache/bokopds-covers"
    util.makePath(directory)
    local cover_scope = table.concat({ self.current_catalog.id or "",
        self.current_catalog.username or "", self.current_catalog.password or "", remote_url }, "\0")
    local path = directory .. "/" .. md5(cover_scope) .. "." .. extension
    if require("libs/libkoreader-lfs").attributes(path, "mode") == "file" then
        entry.cover_path = path
        return false
    end
    if self:deferUntilConnected(function() self:loadCover(entry) end) then return true end
    self.busy = "Loading cover"
    self:invalidate("full")
    UIManager:forceRePaint()
    Trapper:wrap(function()
        local completed, result = Trapper:dismissableRunInSubprocess(
            CatalogService.coverTask(remote_url, path, self.current_catalog.username,
                self.current_catalog.password, self.current_catalog.url), self)
        self.busy, self.dismiss_callback = nil, nil
        if completed and result and result.ok then
            entry.cover_path = path
            table.insert(self.cover_cache, path)
            while #self.cover_cache > 40 do
                os.remove(table.remove(self.cover_cache, 1))
            end
            self:saveState()
        elseif not completed then
            os.remove(path .. CatalogService.COVER_PART_SUFFIX)
            self:setStatus("Cover request cancelled", false)
        end
        self:invalidate("full")
    end)
    return true
end

function Shell:back()
    self:clearStatus()
    if self.screen == "catalogs" then return end
    if self.screen == "form" then
        self:clearInputs()
        self.screen = "catalogs"
    elseif self.screen == "search" then
        self:clearInputs()
        self.screen = "feed"
    elseif self.screen == "bookmark-rename" then
        self:clearInputs()
        self.editing_bookmark_index = nil
        self.screen = "bookmarks"
    elseif self.screen == "batch-download" then
        if self.batch_download_editing_location then
            if self.input_fields[1] then
                self.batch_folder_name = trimInput(self.input_fields[1]:getText())
            end
            self:clearInputs()
            self.batch_download_editing_location = false
            self:invalidate("full")
            return
        end
        self:clearInputs()
        self.batch_download_location = nil
        self.batch_download_editing_location = nil
        self.screen = "feed"
    elseif self.screen == "download-complete" then
        self.download_summary = nil
        self.download_summary_offset = 0
        self.screen = "feed"
    elseif self.screen == "feed" and #self.feed_history > 0 then
        if self.current_feed and self.current_feed._navigation_kind == "child" then
            table.remove(self.catalog_parents)
        end
        self.current_feed = table.remove(self.feed_history)
        self.current_feed._catalog_parent_recorded = nil
        self.pagination_history = cloneList(self.current_feed._pagination_history)
    elseif self.screen == "detail" then
        self.screen = "feed"
        self:resetScroll("detail")
    elseif self.screen == "bookmarks" or self.screen == "delete" or
            self.screen == "preferences" then
        self.screen = "catalogs"
    elseif self.screen == "feed" and self.feed_return_screen == "bookmarks" then
        self.screen = "bookmarks"
        self.current_feed = nil
        self.bookmark_parent_url = nil
        self.bookmark_path = nil
        self.catalog_parents = {}
        self.pagination_history = {}
    else
        self.screen = "catalogs"
        self.current_feed = nil
        self.feed_history = {}
        self.bookmark_parent_url = nil
        self.bookmark_path = nil
        self.catalog_parents = {}
        self.pagination_history = {}
    end
    self:invalidate("full")
end

function Shell:goHome()
    self:clearInputs()
    self:clearSelection()
    self:clearStatus()
    self.screen = "catalogs"
    self.current_feed = nil
    self.current_entry = nil
    self.feed_history = {}
    self.pagination_history = {}
    self.catalog_parents = {}
    self.feed_return_screen = "catalogs"
    self.bookmark_parent_url = nil
    self.bookmark_path = nil
    self.download_summary = nil
    self.download_summary_offset = 0
    self:resetScroll("catalogs")
    self:invalidate("full")
end

function Shell:activate(action)
    if action == "quit" then self:saveState(); UIManager:quit(0)
    elseif action == "home" then self:goHome()
    elseif action == "connect-network" then
        if not self:deferUntilConnected(function() end) then
            self.screen = "catalogs"; self:invalidate("full")
        end
    elseif action == "continue-offline" then
        self.deferred_generation = self.deferred_generation + 1
        self.screen = "catalogs"; self:invalidate("full")
    elseif action == "back" then self:back()
    elseif action == "add" then self:showForm(nil)
    elseif action == "bookmarks" then
        self.screen = "bookmarks"; self:resetScroll("bookmarks"); self:invalidate("full")
    elseif action == "preferences" then
        self.screen = "preferences"; self:resetScroll("preferences"); self:invalidate("full")
    elseif action == "clear-cache" then
        self.feed_cache = {}
        for _, path in ipairs(self.cover_cache) do os.remove(path) end
        self.cover_cache = {}
        self:saveFeedCache(); self:saveState(); self:setStatus("Catalog cache cleared", false)
    elseif action == "dismiss-status" then
        if self.compatibility_warning_id then
            self.settings:saveSetting("compatibility_warning_ack", self.compatibility_warning_id)
            self.settings:flush()
            self.compatibility_warning_id = nil
        end
        self:clearStatus()
    elseif action == "cancel-network" and self.dismiss_callback then self.dismiss_callback()
    elseif action == "save-catalog" then self:saveCatalog()
    elseif action == "save-bookmark-name" then self:saveBookmarkName()
    elseif action == "confirm-delete" then
        local catalog = table.remove(self.catalogs, self.pending_delete_index)
        self:purgeCatalogCache(catalog)
        for index = #self.bookmarks, 1, -1 do
            if self.bookmarks[index].catalog_id == catalog.id then table.remove(self.bookmarks, index) end
        end
        self.pending_delete, self.pending_delete_index = nil, nil
        self.screen = "catalogs"; self:saveState(); self:setStatus("Catalog deleted", false)
    elseif action == "refresh" then
        self:loadFeed(self.current_feed.source_url, self.current_catalog, self.current_feed.title, true, true)
    elseif action == "feed-items-previous" then
        if self.scroll_offsets.feed > 0 then
            self.scroll_offsets.feed = math.max(0, self.scroll_offsets.feed - 7)
            self:invalidate("full")
        elseif #self.pagination_history > 0 then
            self.current_feed = table.remove(self.pagination_history)
            local count = #(self.current_feed.entries or {})
            self.scroll_offsets.feed = math.max(0, (math.ceil(count / 7) - 1) * 7)
            self:invalidate("full")
        end
    elseif action == "feed-items-next" then
        local entry_count = #self:visibleFeedEntries()
        local last_page_offset = math.max(0, (math.ceil(entry_count / 7) - 1) * 7)
        if self.scroll_offsets.feed < last_page_offset then
            local target_offset = self.scroll_offsets.feed + 7
            local remaining = entry_count - target_offset
            if remaining < 7 and self.current_feed.next_url then
                self.append_chain_count = 0
                self.pending_append_offset = target_offset
                self:loadFeed(self.current_feed.next_url, self.current_catalog,
                    nil, false, true, "append")
            else
                self.scroll_offsets.feed = math.min(last_page_offset, target_offset)
                self:invalidate("full")
            end
        elseif self.current_feed.next_url then
            self.append_chain_count = 0
            self.pending_append_offset = self.scroll_offsets.feed + 7
            self:loadFeed(self.current_feed.next_url, self.current_catalog,
                nil, false, true, "append")
        end
    elseif action == "search" then self:prepareSearch()
    elseif action == "selection-start" then
        self.selection_mode = true; self:invalidate("full")
    elseif action == "selection-cancel" then
        self:clearSelection(); self:invalidate("full")
    elseif action == "selection-page" then
        local entries = self:visibleFeedEntries()
        local first = self.scroll_offsets.feed + 1
        local last = math.min(#entries, first + 6)
        local all_selected = first <= last
        for index = first, last do
            local entry = entries[index].entry
            if entry.publication and not self.selected_entries[self:entrySelectionKey(entry)] then
                all_selected = false; break
            end
        end
        for index = first, last do
            local entry = entries[index].entry
            if entry.publication then
                local selected = self.selected_entries[self:entrySelectionKey(entry)] ~= nil
                if selected == all_selected then self:toggleEntrySelection(entry) end
            end
        end
        self:invalidate("full")
    elseif action == "selection-download" then self:showBatchDownload()
    elseif action == "batch-location-edit" then
        self.batch_download_editing_location = true
        self:invalidate("full")
    elseif action == "batch-location-current" then
        self:setBatchDownloadLocation("current")
    elseif action == "batch-location-folder" then
        self:setBatchDownloadLocation("folder")
    elseif action == "batch-location-done" then
        if self.input_fields[1] then
            self.batch_folder_name = trimInput(self.input_fields[1]:getText())
        end
        local destination, directory_error = self:batchDownloadDirectory()
        if not destination then self:setStatus(directory_error, true); return end
        self:clearInputs()
        self.batch_download_editing_location = false
        self:invalidate("full")
    elseif action == "batch-download-start" then
        local destination, directory_error = self:batchDownloadDirectory()
        if not destination then self:setStatus(directory_error, true); return end
        if self.batch_download_location == "folder" then
            local created = pcall(util.makePath, destination)
            local mode = created and require("libs/libkoreader-lfs").attributes(
                destination, "mode")
            if mode ~= "directory" then
                self:setStatus("Could not create the selected save folder", true)
                return
            end
        end
        self:clearInputs()
        self.batch_download_location = nil
        self.batch_download_editing_location = nil
        self.screen = "feed"
        self:downloadSelected(destination)
    elseif action == "download-summary-previous" then
        self.download_summary_offset = math.max(0, (self.download_summary_offset or 0) - 6)
        self:invalidate("full")
    elseif action == "download-summary-next" then
        self.download_summary_offset = (self.download_summary_offset or 0) + 6
        self:invalidate("full")
    elseif action == "download-summary-done" then
        self.download_summary = nil
        self.download_summary_offset = 0
        self.screen = "feed"
        self:invalidate("full")
    elseif action == "download-summary-finish" then
        self:saveState()
        UIManager:quit(0)
    elseif action == "preferences-previous" then
        self.scroll_offsets.preferences = math.max(0, self.scroll_offsets.preferences - 7)
        self:invalidate("full")
    elseif action == "preferences-next" then
        self.scroll_offsets.preferences = self.scroll_offsets.preferences + 7
        self:invalidate("full")
    elseif action == "search-go" then
        local query = trimInput(self.input_fields[1]:getText())
        if query == "" then self:setStatus("Enter a search query", true); return end
        local search_url = self.current_feed and self.current_feed.search_url
        -- Leave the search screen before destroying its input. loadFeed forces
        -- an immediate busy repaint, so the view state must already be valid.
        self.screen = "feed"
        self:clearInputs()
        local url = search_url:gsub("%%s", function() return util.urlEncode(query) end)
        self:loadFeed(url, self.current_catalog, "Search results", false, false, "child")
    elseif action == "busy-block" then
        return
    elseif action == "catalog-up" then
        local stored_parent = self.catalog_parents[#self.catalog_parents]
        local up_url = stored_parent and stored_parent.url or self:catalogUpUrl()
        local up_title = stored_parent and stored_parent.title or
            (self.current_feed and self.current_feed.up_title) or "Parent catalog"
        if up_url then
            self.bookmark_parent_url = nil
            self.pending_up_parent = stored_parent
            self:loadFeed(up_url, self.current_catalog, up_title, false, true, "up")
        end
    elseif action == "bookmark-current" then
        local repaired_parents = self:repairCatalogParents(
            self.catalog_parents, self.current_catalog)
        self.catalog_parents = repaired_parents
        local stored_parent = repaired_parents[#repaired_parents]
        table.insert(self.bookmarks, {
            catalog_id = self.current_catalog.id,
            catalog_title = self.current_catalog.title,
            title = self.current_feed.title,
            url = self:currentBookmarkUrl(),
            parent_url = stored_parent and stored_parent.url or self.current_feed.up_url,
            path = self:fullFeedPath(),
            parents = cloneList(repaired_parents),
        })
        self:saveState(); self:setStatus("Bookmark saved", false)
    elseif action == "remove-current-bookmark" then
        local index = self:bookmarkIndex(self.current_catalog.id, self:currentBookmarkUrl())
        if index then table.remove(self.bookmarks, index); self:saveState() end
        self:setStatus("Bookmark removed", false)
    elseif action == "toggle-formats" then self.other_formats = not self.other_formats; self:invalidate("ui")
    else
        local language = action:match("^language:(.+)$")
        if language then
            if language == "all" then
                self.preferred_languages = {}
            else
                local existing
                for index, code in ipairs(self.preferred_languages) do
                    if code == language then existing = index; break end
                end
                if existing then table.remove(self.preferred_languages, existing)
                else table.insert(self.preferred_languages, language) end
            end
            self:saveState(); self:invalidate("full")
            return
        end
        local prefix, number = action:match("^([^:]+):(%d+)$")
        local index = tonumber(number)
        if prefix == "open" then
            local catalog = self.catalogs[index]
            self.current_feed, self.feed_history = nil, {}
            self.feed_return_screen = "catalogs"
            self.bookmark_parent_url = nil
            self.bookmark_path = nil
            self.catalog_parents = {}
            self.pagination_history = {}
            self:loadFeed(catalog.url, catalog, catalog.title, false, true)
        elseif prefix == "edit" then self:showForm(index)
        elseif prefix == "delete" then
            self.pending_delete_index, self.pending_delete = index, self.catalogs[index]
            self.screen = "delete"; self:invalidate("full")
        elseif prefix == "entry" then
            local entry = self.current_feed.entries[index]
            if entry.publication then
                self.current_entry, self.other_formats = entry, false
                self.screen = "detail"
                self:resetScroll("detail")
                if not self:loadCover(entry) then self:invalidate("full") end
            else
                self:loadFeed(entry.url, self.current_catalog, entry.title, false, false, "child")
            end
        elseif prefix == "selection-entry" then
            self:toggleEntrySelection(self.current_feed.entries[index])
        elseif prefix == "download" then
            self:download(self.current_entry.acquisitions[index], self.current_entry)
        elseif prefix == "bookmark-open" then
            local bookmark = self.bookmarks[index]
            local catalog = self:catalogById(bookmark.catalog_id)
            if not catalog then self:setStatus("Bookmark catalog no longer exists", true)
            else
                local repaired_parents, parents_changed =
                    self:repairCatalogParents(bookmark.parents, catalog)
                if parents_changed then
                    bookmark.parents = cloneList(repaired_parents)
                    bookmark.path = nil
                    self:saveState()
                end
                self.current_feed, self.feed_history = nil, {}
                self.feed_return_screen = "bookmarks"
                self.bookmark_parent_url = bookmark.parent_url
                self.bookmark_path = clone(bookmark.path or {})
                self.catalog_parents = cloneList(repaired_parents)
                self.pagination_history = {}
                self:loadFeed(bookmark.url, catalog, bookmark.title, false, true)
            end
        elseif prefix == "bookmark-rename" then
            self:showBookmarkRename(index)
        elseif prefix == "bookmark-remove" then
            table.remove(self.bookmarks, index); self:saveState(); self:invalidate("full")
        end
    end
end

function Shell:onTap(_, ges)
    local pos = ges.pos
    for index = #self.targets, 1, -1 do
        local target = self.targets[index]
        if inside(target.rect, pos.x, pos.y) then self:activate(target.action); return true end
    end
    return true
end

function Shell:onSwipe(_, ges)
    if self.busy then return true end
    local forward = ges.direction == "north" or ges.direction == "west"
    local backward = ges.direction == "south" or ges.direction == "east"
    if not forward and not backward then return true end

    local offset, maximum, step
    if self.screen == "catalogs" then
        offset, step = self.scroll_offsets.catalogs, 6
        maximum = math.max(0, #self.catalogs - 6)
    elseif self.screen == "bookmarks" then
        offset, step = self.scroll_offsets.bookmarks, 7
        maximum = math.max(0, #self.bookmarks - 7)
    elseif self.screen == "preferences" then
        offset, step = self.scroll_offsets.preferences, 7
        maximum = math.max(0, #self:languageOptions() + 1 - 7)
    elseif self.screen == "feed" then
        offset, step = self.scroll_offsets.feed, 7
        maximum = math.max(0,
            (math.ceil(#self:visibleFeedEntries() / 7) - 1) * 7)
    elseif self.screen == "detail" then
        offset, step = self.scroll_offsets.detail, 620
        maximum = self.detail_max_scroll
    else
        return true
    end

    local updated = forward and math.min(maximum, offset + step) or
        math.max(0, offset - step)
    if updated ~= offset then
        self.scroll_offsets[self.screen] = updated
        self:invalidate("full")
    end
    return true
end

function Shell:onClose()
    self.deferred_generation = self.deferred_generation + 1
    require("pluginshare").pause_auto_suspend = false
    if self.dismiss_callback then self.dismiss_callback() end
end

function Shell:onCloseWidget()
    if self.dismiss_callback then
        self.dismiss_callback()
        self.dismiss_callback = nil
    end
    for _, catalog in ipairs(self.catalogs) do
        CatalogService.cleanupPartFiles(self:catalogDownloadDirectory(catalog))
    end
    CatalogService.cleanupCoverPartFiles(
        DataStorage:getDataDir() .. "/cache/bokopds-covers")
    if self.status_timeout then UIManager:unschedule(self.status_timeout) end
    self.status_timeout = nil
    if self.feed_cache_save_task then
        UIManager:unschedule(self.feed_cache_save_task)
        self.feed_cache_save_task = nil
    end
    self:clearInputs()
    for _, service in ipairs(self.services) do
        if service.onCloseWidget then service:onCloseWidget() end
        for index = #self, 1, -1 do
            if self[index] == service then table.remove(self, index) end
        end
    end
    self.services = {}
    self:saveState()
    self:saveFeedCache()
    for _, rendered in pairs(self.rendered_images) do rendered.bb:free() end
    self.rendered_images = {}
    self.rendered_image_order = {}
    self.rendered_image_bytes = 0
end

function Shell:showDemo(screen_name)
    if screen_name == "offline" then
        self:clearInputs()
        self.network_connected = false
        self.network_connecting = false
        self.screen = "offline"
        self:invalidate("full")
    elseif screen_name == "" or screen_name == "home" or screen_name == "catalogs" then
        self:clearInputs()
        self.screen = "catalogs"
        self:resetScroll("catalogs")
        self:invalidate("full")
    elseif screen_name == "form" then
        self:showForm(nil)
    elseif screen_name == "search" then
        self.current_catalog = self.catalogs[1]
        self.current_feed = { title = "Example catalog", search_url = "https://example.invalid?q=%s" }
        self:showSearch()
    elseif screen_name == "preferences" then
        self:clearInputs()
        self.preferred_languages = { "en", "ru" }
        self.known_languages = { "en", "ru", "uk", "fr" }
        self.screen = "preferences"
        self:resetScroll("preferences")
        self:invalidate("full")
    else
        self:clearInputs()
        self.current_catalog = self.catalogs[1] or {
            id = "demo", title = "Demo library", username = "", password = "",
            download_directory = require("datastorage"):getDataDir() .. "/downloads",
        }
        self.current_feed = {
            title = "Example catalog",
            source_url = self.current_catalog.url or "https://example.invalid/opds",
            search_url = "https://example.invalid/search?q=%s",
            next_url = "https://example.invalid/opds?page=2",
            entries = {
                { title = "Новинки", author = "", url = "https://example.invalid/new", acquisitions = {}, publication = false },
                { title = "По авторам", author = "", url = "https://example.invalid/authors", acquisitions = {}, publication = false },
                { title = "По сериям", author = "", url = "https://example.invalid/series", acquisitions = {}, publication = false },
                { title = "По жанрам", author = "", url = "https://example.invalid/genres", acquisitions = {}, publication = false },
                { title = "Моя полка", author = "", url = "https://example.invalid/shelf", acquisitions = {}, publication = false },
            },
        }
        local selection_demo = screen_name == "selection" or
            screen_name == "batch-download" or screen_name == "batch-folder" or
            screen_name == "bulk-busy"
        if selection_demo then
            self.current_feed.title = "Search results"
            self.current_feed.total_items = 63
            self.current_feed.entries = {}
            for index = 1, 14 do
                table.insert(self.current_feed.entries, {
                    title = "Selected book example " .. index,
                    author = index % 2 == 0 and "Demo Author" or "Another Author",
                    publication = true,
                    languages = { index % 3 == 0 and "fr" or "en" },
                    acquisitions = {
                        { href = "https://example.invalid/book-" .. index .. ".epub",
                            type = "application/epub+zip" },
                    },
                })
            end
            self.selection_mode = true
            self:toggleEntrySelection(self.current_feed.entries[2])
            self:toggleEntrySelection(self.current_feed.entries[5])
            self.screen = "feed"
            if screen_name == "batch-download" then
                self:showBatchDownload()
            elseif screen_name == "batch-folder" then
                self:showBatchDownload()
                self.batch_download_editing_location = true
                self:setBatchDownloadLocation("folder")
                self.input_fields[1]:setText("Weekend reading")
            elseif screen_name == "bulk-busy" then
                self.busy = "Downloading 29 of 44"
            end
        elseif screen_name == "feed-scroll" then
            for index = 6, 14 do
                table.insert(self.current_feed.entries, {
                    title = "Catalog section " .. index,
                    author = "",
                    url = "https://example.invalid/section/" .. index,
                    acquisitions = {},
                    publication = false,
                })
            end
            self.scroll_offsets.feed = 7
            self.screen = "feed"
        elseif screen_name == "detail" or screen_name == "detail-scroll" then
            self.current_entry = {
                title = "Без помощи вашей",
                author = "Суржиков Роман Евгеньевич",
                cover_path = "resources/bokopds-demo-cover.svg",
                summary = "Полари — мир фантастического средневековья. Суровые нравы граничат с ростками будущего, мечи и арбалеты — с первыми электростанциями и поездами. Император ведет страну нелегким путем реформ.",
                acquisitions = {
                    { href = "https://example.invalid/book.epub", type = "application/epub+zip" },
                    { href = "https://example.invalid/book.fb2", type = "application/fb2+zip" },
                    { href = "https://example.invalid/book.txt", type = "text/plain" },
                },
            }
            if screen_name == "detail-scroll" then
                self.current_entry.summary = self.current_entry.summary .. "\n\n" ..
                    string.rep("This extended description verifies smooth page-based scrolling on e-ink. ", 28)
                self.other_formats = true
                self.detail_max_scroll = 10000
                self.scroll_offsets.detail = 620
            end
            self.screen = "detail"
        elseif screen_name == "busy" then
            self.screen = "catalogs"
            self.busy = "Opening catalog"
        elseif screen_name == "download-complete" or
                screen_name == "download-complete-page2" then
            self.screen = "download-complete"
            self.download_summary = {
                completed = 8,
                failed = 0,
                destination = "/mnt/onboard/Books/Françoise Sagan",
                total_bytes = 26361142,
                files = {
                    { name = "Françoise Sagan - Angel Guardian.epub", size = 3281140 },
                    { name = "Françoise Sagan - A Certain Smile.epub", size = 2942611 },
                    { name = "Françoise Sagan - Bonjour Tristesse.epub", size = 2710064 },
                    { name = "Françoise Sagan - Scars on the Soul.epub", size = 3807119 },
                    { name = "Françoise Sagan - The Painted Lady.epub", size = 3108072 },
                    { name = "Françoise Sagan - Silken Eyes.epub", size = 2994380 },
                    { name = "Françoise Sagan - Sunlight on Cold Water.epub", size = 4018712 },
                    { name = "Françoise Sagan - The Unmade Bed.epub", size = 3499044 },
                },
            }
            self.download_summary_offset = screen_name == "download-complete-page2" and 6 or 0
        elseif screen_name == "bookmarks" then
            self.screen = "bookmarks"
        elseif screen_name == "bookmark-rename" then
            if #self.bookmarks == 0 then
                table.insert(self.bookmarks, {
                    catalog_id = self.current_catalog.id,
                    catalog_title = self.current_catalog.title,
                    title = "Arthur C. Clarke",
                    url = "https://example.invalid/authors/clarke",
                })
            end
            self:showBookmarkRename(1)
        elseif screen_name == "bookmark-feed" then
            self.current_feed.title = "Arthur C. Clarke"
            self.current_feed.source_url = "https://example.invalid/opds/authors/clarke"
            self.current_feed.up_url = "https://example.invalid/opds/authors"
            self.current_feed.entries = {
                { title = "Childhood's End", author = "Arthur C. Clarke",
                    publication = true, acquisitions = {} },
                { title = "Rendezvous with Rama", author = "Arthur C. Clarke",
                    publication = true, acquisitions = {} },
                { title = "2001: A Space Odyssey", author = "Arthur C. Clarke",
                    publication = true, acquisitions = {} },
                { title = "The City and the Stars", author = "Arthur C. Clarke",
                    publication = true, acquisitions = {} },
                { title = "The Fountains of Paradise", author = "Arthur C. Clarke",
                    publication = true, acquisitions = {} },
            }
            self.feed_return_screen = "bookmarks"
            self.bookmark_parent_url = self.current_feed.up_url
            self.bookmark_path = nil
            self.catalog_parents = {
                { title = "Authors", url = "https://example.invalid/opds/authors" },
            }
            self.screen = "feed"
        else
            self.screen = "feed"
        end
        self:invalidate("full")
    end
end

function Shell:runSelfTest(report_path)
    local original_catalog_count = #self.catalogs
    local original_bookmark_count = #self.bookmarks
    assert(self.settings:hasNot("feed_cache"),
        "feed response bodies remained in the main application settings")
    table.insert(self.catalogs, {
        id = "legacy-empty-download-path", title = "Legacy catalog",
        url = "https://example.invalid/opds", download_directory = "   ",
    })
    self:normalizeCatalogs()
    assert(self.catalogs[#self.catalogs].download_directory == self:defaultDownloadDirectory(),
        "empty legacy download directory was not repaired to the safe default")
    table.remove(self.catalogs)
    self:saveState()
    local original_preferred_languages = {}
    for _, language in ipairs(self.preferred_languages or {}) do
        table.insert(original_preferred_languages, language)
    end
    self:setStatus("Transient confirmation", false)
    assert(self.status_timeout, "success status did not schedule dismissal")
    local status_timeout = self.status_timeout
    UIManager:unschedule(status_timeout)
    status_timeout()
    assert(not self.status, "success status did not dismiss")
    self:setStatus("Persistent error", true)
    assert(not self.status_timeout, "error status should not auto-dismiss")
    self:clearStatus()
    self.compatibility_warning_id = "self-test-target"
    self:setStatus("Untested compatibility warning", true)
    self:activate("dismiss-status")
    assert(self.settings:readSetting("compatibility_warning_ack") == "self-test-target",
        "dismissed compatibility warning was not acknowledged")
    self.settings:delSetting("compatibility_warning_ack")
    self.settings:flush()
    local original_network_manager = self.network_manager
    local connection_requested, connected_callback = false, false
    local mock_connected, mock_online = false, false
    self.network_manager = {
        isConnected = function() return mock_connected end,
        isOnline = function() return mock_online end,
        runWhenOnline = function(_, callback)
            connection_requested = true
            mock_connected, mock_online = true, true
            callback()
        end,
        runWhenConnected = function(_, callback)
            connection_requested = true
            mock_connected, mock_online = true, true
            callback()
        end,
    }
    assert(self:deferUntilConnected(function() connected_callback = true end),
        "offline action was not deferred")
    assert(connection_requested and connected_callback and self.network_connected,
        "deferred action did not resume after connection")
    connection_requested, connected_callback = false, false
    mock_connected, mock_online = true, false
    assert(self:deferUntilConnected(function() connected_callback = true end),
        "connected but offline action was not deferred")
    assert(connection_requested and connected_callback and self.network_connected,
        "connected but offline retry did not request internet access")
    self.network_manager = original_network_manager
    for index = 1, 9 do
        table.insert(self.bookmarks, {
            catalog_id = "paging-test", title = "Bookmark " .. index,
            url = "https://example.invalid/" .. index,
        })
    end
    self.screen = "bookmarks"
    self:onSwipe(nil, { direction = "north" })
    assert(self.scroll_offsets.bookmarks > 0, "bookmark paging did not advance")
    self:onSwipe(nil, { direction = "south" })
    assert(self.scroll_offsets.bookmarks == 0, "bookmark paging did not return")
    while #self.bookmarks > original_bookmark_count do table.remove(self.bookmarks) end
    self.current_feed = { entries = {} }
    for index = 1, 15 do
        table.insert(self.current_feed.entries, { title = "Entry " .. index })
    end
    self.screen = "feed"
    self:activate("feed-items-next")
    assert(self.scroll_offsets.feed == 7, "feed paging button did not advance")
    self:activate("feed-items-next")
    assert(self.scroll_offsets.feed == 14, "feed paging did not reach the final page")
    self:activate("feed-items-previous")
    assert(self.scroll_offsets.feed == 7, "feed paging button did not return")

    self.preferred_languages = {}
    self.pagination_history = {}
    self.current_feed.total_items = 63
    self.scroll_offsets.feed = 0
    local first_page, known_total = self:feedPaginationPosition(15, 7)
    assert(first_page == 1 and known_total == 9,
        "first-page OPDS total was not converted to UI pages")

    self.current_feed = { entries = {
        { title = "Russian", publication = true, languages = { "ru" }, acquisitions = {
            { href = "https://example.invalid/ru.fb2", type = "application/fb2+zip" },
        } },
        { title = "French Canadian", publication = true, languages = { "fr-ca" }, acquisitions = {
            { href = "https://example.invalid/fr.pdf", type = "application/pdf" },
        } },
        { title = "Unknown language", publication = true, languages = {}, acquisitions = {
            { href = "https://example.invalid/unknown.epub", type = "application/epub+zip" },
        } },
        { title = "Navigation", publication = false, url = "https://example.invalid/section" },
    } }
    self.preferred_languages = { "fr" }
    local filtered_entries = self:visibleFeedEntries()
    assert(#filtered_entries == 3 and filtered_entries[1].entry.title == "French Canadian" and
        filtered_entries[2].entry.title == "Unknown language" and
        filtered_entries[3].entry.title == "Navigation",
        "preferred-language filtering hid unknown/navigation entries or missed a regional match")

    self.preferred_languages = {}
    self.current_feed = { entries = {} }
    for index = 1, 15 do
        table.insert(self.current_feed.entries, {
            title = "Selectable " .. index,
            publication = true,
            acquisitions = {
                { href = "https://example.invalid/book-" .. index .. ".fb2",
                    type = "application/fb2+zip" },
                { href = "https://example.invalid/book-" .. index .. ".epub",
                    type = "application/epub+zip" },
            },
        })
    end
    self:resetScroll("feed")
    self:activate("selection-start")
    self:activate("selection-page")
    assert(self:selectedCount() == 7, "Select page did not select the first UI page")
    self:activate("feed-items-next")
    self:activate("selection-entry:8")
    assert(self.scroll_offsets.feed == 7 and self:selectedCount() == 8,
        "selection did not persist across UI pages")
    assert(CatalogService.formatName(
        self:preferredAcquisition(self.current_feed.entries[8])) == "EPUB",
        "bulk selection did not prefer EPUB when several formats were available")

    self.current_catalog = {
        id = "batch-location-test", username = "", password = "",
        download_directory = "/tmp/books",
    }
    self:showBatchDownload()
    assert(self.screen == "batch-download" and self.batch_download_location == "current",
        "multiple-book confirmation did not open with the configured save path")
    self.batch_download_location = "folder"
    self.batch_folder_name = "../escape"
    local unsafe_directory = self:batchDownloadDirectory()
    assert(unsafe_directory == nil, "unsafe selected-books folder name was accepted")
    self.batch_folder_name = "Weekend picks"
    local batch_directory = self:batchDownloadDirectory()
    assert(batch_directory == "/tmp/books/Weekend picks",
        "new folder was not resolved inside the configured download directory")
    self:back()
    assert(self.screen == "feed" and self:selectedCount() == 8,
        "backing out of download confirmation lost the current selection")

    self:clearSelection()
    self.selection_mode = true
    self.current_catalog = {
        id = "bulk-test", username = "", password = "", download_directory = "/tmp",
    }
    self:toggleEntrySelection(self.current_feed.entries[1])
    local original_download_selected = self.downloadSelected
    local direct_destination
    self.downloadSelected = function(_, destination) direct_destination = destination end
    self:showBatchDownload()
    self.downloadSelected = original_download_selected
    assert(self.screen == "feed" and direct_destination == "/tmp",
        "one selected book did not start a direct download to the configured folder")
    self:clearSelection()
    self.selection_mode = true
    self:toggleEntrySelection(self.current_feed.entries[1])
    self:toggleEntrySelection(self.current_feed.entries[8])
    local original_download_task = CatalogService.downloadTask
    local original_mark_library_refresh = self.markLibraryRefresh
    local original_bulk_network_manager = self.network_manager
    local refreshed_paths = {}
    CatalogService.downloadTask = function(acquisition)
        return function()
            return { ok = true, path = "/tmp/" ..
                (acquisition.href:match("([^/]+)$") or "book.epub") }
        end
    end
    self.markLibraryRefresh = function(_, path) table.insert(refreshed_paths, path) end
    self.network_manager = { isConnected = function() return true end }
    local queue = {}
    for _, key in ipairs(self.selection_order) do
        table.insert(queue, { key = key, value = self.selected_entries[key] })
    end
    local completed_count, failed_count, cancelled,
        completed_keys, completed_files = self:runDownloadQueue(queue, self.current_catalog)
    self:finishSelectedDownloads(completed_count, failed_count, cancelled,
        completed_keys, completed_files, self.current_catalog.download_directory)
    CatalogService.downloadTask = original_download_task
    self.markLibraryRefresh = original_mark_library_refresh
    self.network_manager = original_bulk_network_manager
    assert(#refreshed_paths == 2 and self:selectedCount() == 0 and
        self.screen == "download-complete" and self.download_summary and
        self.download_summary.completed == 2 and
        self.download_summary.failed == 0 and
        self.download_summary.destination == "/tmp" and #self.download_summary.files == 2,
        string.format("bulk download result mismatch: refreshed=%d selected=%d screen=%s",
            #refreshed_paths, self:selectedCount(), tostring(self.screen)))
    self:activate("download-summary-done")
    assert(self.screen == "feed" and self.download_summary == nil,
        "Done did not close the download summary")
    self:activate("home")
    assert(self.screen == "catalogs" and not self.selection_mode and self:selectedCount() == 0,
        "Home did not return to catalogs and clear transient selection")
    self.preferred_languages = original_preferred_languages
    local first_remote = { entries = {}, next_url = "https://example.invalid/opds/page-2" }
    local second_remote = { entries = {} }
    for index = 1, 20 do table.insert(first_remote.entries, { title = "First " .. index }) end
    for index = 1, 14 do table.insert(second_remote.entries, { title = "Second " .. index }) end
    self.current_catalog = { username = "" }
    self.current_feed = second_remote
    self.pagination_history = { first_remote }
    self.scroll_offsets.feed = 0
    local global_page, global_total, has_previous, has_next =
        self:feedPaginationPosition(#second_remote.entries, 7)
    assert(global_page == 4 and global_total == 5 and has_previous and has_next,
        "server pagination reset the visible page sequence")
    self.scroll_offsets.feed = 7
    global_page, global_total, has_previous, has_next =
        self:feedPaginationPosition(#second_remote.entries, 7)
    assert(global_page == 5 and global_total == 5 and has_previous and not has_next,
        "final server page did not expose the true global end")
    self:resetScroll("feed")
    self.feed_return_screen = "bookmarks"
    self.feed_history = {}
    local direct_label, direct_icon = self:feedBackControl()
    assert(direct_label == "Bookmarks" and direct_icon == "bookmark",
        "direct bookmark return control is incorrect")
    self.feed_history = { { title = "Bookmark page" } }
    local nested_label, nested_icon = self:feedBackControl()
    assert(nested_label == "Back" and nested_icon == "chevron.left",
        "nested bookmark Back control retained the bookmark icon")
    self.feed_history = {}
    self.feed_return_screen = "catalogs"
    self.pagination_history = {}
    self.feed_return_screen = "bookmarks"
    self.current_catalog = { id = "page-test", title = "Page test", url = "https://example.invalid/opds" }
    self.current_feed = {
        title = "Paged feed", source_url = "https://example.invalid/opds/list", entries = {},
        next_url = "https://example.invalid/opds/list/2",
        bookmark_url = "https://example.invalid/opds/list",
    }
    for index = 1, 20 do
        table.insert(self.current_feed.entries, { title = "First " .. index })
    end
    self.scroll_offsets.feed = 7
    local original_page_load = self.loadFeed
    local requested_kind
    self.loadFeed = function(_, _, _, _, _, _, navigation_kind)
        requested_kind = navigation_kind
    end
    self:activate("feed-items-next")
    self.loadFeed = original_page_load
    assert(requested_kind == "append" and self.pending_append_offset == 14,
        "a partial UI page did not request enough entries from the next OPDS response")
    local appended = { title = "Paged feed", entries = {} }
    for index = 1, 14 do table.insert(appended.entries, { title = "Second " .. index }) end
    self:adoptFeed(appended, nil, true, "append")
    assert(#self.current_feed.entries == 34 and self.scroll_offsets.feed == 14 and
        self.current_feed.entries[21].title == "Second 1",
        "server responses were not flattened into full UI pages")
    local flattened_page, flattened_total =
        self:feedPaginationPosition(#self.current_feed.entries, 7)
    assert(flattened_page == 3 and flattened_total == 5,
        "flattened pagination did not retain one global page sequence")
    assert(#self.feed_history == 0 and #self.pagination_history == 0,
        "server pagination leaked into catalog navigation history")
    assert(self:currentBookmarkUrl() == "https://example.invalid/opds/list",
        "server pagination changed the logical bookmark URL")
    local paged_back_label, paged_back_icon = self:feedBackControl()
    assert(paged_back_label == "Bookmarks" and paged_back_icon == "bookmark",
        "server pagination changed the bookmark footer")
    self:activate("feed-items-next")
    self:activate("feed-items-previous")
    assert(self.current_feed.source_url == "https://example.invalid/opds/list" and
        self.scroll_offsets.feed == 14,
        "Previous did not remain inside the flattened global page sequence")
    self.pagination_history = {}
    self.feed_return_screen = "catalogs"
    self.catalog_parents = {}
    self.feed_history = {}
    for history_index = 1, 3 do
        local entries = {}
        for entry_index = 1, 300 do entries[entry_index] = {} end
        table.insert(self.feed_history, {
            title = "History " .. history_index,
            entries = entries,
            _navigation_kind = "child",
            _catalog_parent_recorded = true,
        })
        table.insert(self.catalog_parents, {
            title = "Parent " .. history_index,
            url = "https://example.invalid/parent/" .. history_index,
        })
    end
    self.current_feed = { title = "Leaf", entries = {}, _navigation_kind = "child" }
    self.screen = "feed"
    self:trimNavigationHistory()
    local retained_entries = 0
    for _, history_feed in ipairs(self.feed_history) do
        retained_entries = retained_entries + retainedFeedEntries(history_feed)
    end
    assert(retained_entries <= MAX_HISTORY_ENTRIES,
        "navigation history exceeded its global entry budget")
    assert(#self.catalog_parents == #self.feed_history,
        "history trimming desynchronized catalog parents")
    while #self.feed_history > 0 do self:back() end
    assert(#self.catalog_parents == 0,
        "Back left stale catalog parents after history trimming")
    self.current_feed = {
        title = "Root feed", source_url = "https://example.invalid/opds", entries = {},
    }
    self:adoptFeed({
        title = "Child feed", source_url = "https://example.invalid/opds/child", entries = {},
    }, nil, false, "child")
    assert(#self.catalog_parents == 1 and
        self.catalog_parents[1].url == "https://example.invalid/opds",
        "child navigation did not record its real parent")
    self:back()
    assert(#self.catalog_parents == 0 and self.current_feed.title == "Root feed",
        "Back did not reverse the structured parent stack")
    self.catalog_parents = {
        { title = "Library root", label = "Library root", url = "https://example.invalid/opds" },
    }
    self.current_feed = {
        title = "Authors index", _path_title = "Authors",
        source_url = "https://example.invalid/opds/authors", entries = {},
    }
    self:adoptFeed({
        title = "Authors index", source_url = "https://example.invalid/opds/authors/A", entries = {},
    }, "A", false, "child")
    assert(self.catalog_parents[2].label == "Authors index",
        "a distinct section feed title was replaced by its entry label")
    self:adoptFeed({
        title = "Authors index", source_url = "https://example.invalid/opds/authors/Ar", entries = {},
    }, "Ar", false, "child")
    assert(self.catalog_parents[3].label == "A",
        "a repeated feed title did not retain its exact navigation label")
    assert(self:feedBreadcrumb():find("Library root  /  Authors index  /  A", 1, true),
        "breadcrumb omitted a repeated-title navigation level")
    self.current_catalog = {
        id = "search-test", title = "Search test", username = "", password = "",
        download_directory = require("datastorage"):getDataDir() .. "/downloads",
    }
    self.current_feed = {
        title = "Search test", source_url = "https://example.invalid/opds",
        search_url = "https://example.invalid/search?q=%s", entries = {},
    }
    self:showSearch()
    self.input_fields[1]:setText("author name")
    local original_load_feed = self.loadFeed
    local submitted_url
    self.loadFeed = function(instance, url)
        submitted_url = url
        assert(instance.screen == "feed", "search input was cleared before leaving search screen")
        assert(#instance.input_fields == 0, "search input was not released")
        UIManager:forceRePaint()
    end
    self:activate("search-go")
    self.loadFeed = original_load_feed
    assert(submitted_url and submitted_url:find("author", 1, true),
        "search action did not submit its query")
    self:showForm(nil)
    for _, service in ipairs(self.services) do
        local retained = false
        for _, child in ipairs(self) do
            if child == service then retained = true; break end
        end
        assert(retained, "persistent service was removed when form inputs changed")
    end
    local first_input = self.input_fields[1]
    local layouts = G_reader_settings:readSetting("keyboard_layouts", {})
    assert(#layouts >= 2 and layouts[1] == "en" and layouts[2] == "ru",
        "default keyboard layout cycle was not configured")
    local function findKey(widget, label, seen)
        if type(widget) ~= "table" then return nil end
        seen = seen or {}
        if seen[widget] then return nil end
        seen[widget] = true
        if widget.label == label and type(widget.callback) == "function" then return widget end
        for _, child in ipairs(widget) do
            local found = findKey(child, label, seen)
            if found then return found end
        end
    end
    first_input.keyboard:setKeyboardLayout("en")
    local globe_key = findKey(first_input.keyboard, "🌐")
    assert(globe_key, "native keyboard globe key was not found")
    globe_key.callback()
    assert(first_input.keyboard:getKeyboardLayout() == "ru",
        "native keyboard globe key did not advance to Russian")
    globe_key = findKey(first_input.keyboard, "🌐")
    assert(globe_key, "globe key disappeared after changing layout")
    globe_key.callback()
    assert(first_input.keyboard:getKeyboardLayout() == "en",
        "native keyboard globe key did not cycle back to English")
    local tap_ok, tap_error = pcall(first_input.onTapTextBox, first_input, nil, {
        pos = { x = self:sx(36), y = self:sy(154) },
    })
    assert(tap_ok, "interactive input focus failed: " .. tostring(tap_error))
    assert(first_input:isKeyboardVisible(), "keyboard was not visible before dismissal test")
    first_input.enter_callback()
    assert(not first_input:isKeyboardVisible(), "Enter did not dismiss keyboard from the first field")
    first_input:onShowKeyboard()
    local keyboard_top = self:keyboardTop()
    local anchored_y, anchored_height = self:anchoredInputY(first_input, keyboard_top)
    assert(keyboard_top and anchored_y + anchored_height + 14 <= keyboard_top,
        "active input was not anchored above the virtual keyboard")
    self.input_fields[1]:setText("Self-test library")
    self.input_fields[1]:goToEnd()
    self.input_fields[2]:setText("  http://127.0.0.1:18080/root.xml  ")
    self.input_fields[3]:setText("  catalog-user  ")
    self.input_fields[4]:setText("catalog-password")
    self.input_fields[5]:setText(require("datastorage"):getDataDir() .. "/self-test-downloads")
    -- The self-test mutates the field before the event loop has painted this
    -- form, so seed the coordinates normally recorded by paintInput().
    self.input_fields[1]._bokopds_x = self.input_fields[1]._bokopds_x or self:sx(24)
    self.input_fields[1]._bokopds_y = self.input_fields[1]._bokopds_y or self:sy(154)
    self.input_fields[1]:addChars("✓")
    assert(self.input_repaint == self.input_fields[1],
        "typing did not select the input-only repaint path")
    self.input_fields[1]:delChar()
    self.input_fields[1].keyboard:setKeyboardLayout("ru")
    assert(G_reader_settings:readSetting("keyboard_layout") == "ru", "keyboard layout did not change")
    self:saveCatalog()
    assert(#self.catalogs == original_catalog_count + 1, "catalog was not saved")
    local saved = self.catalogs[#self.catalogs]
    assert(saved.title == "Self-test library", "Unicode input/backspace failed")
    assert(saved.url == "http://127.0.0.1:18080/root.xml", "URL whitespace was not normalized")
    assert(saved.username == "catalog-user" and saved.password == "catalog-password",
        "catalog credentials were not saved from the form")
    local persisted_catalogs = self.settings:readSetting("catalogs", {})
    local persisted = persisted_catalogs[#persisted_catalogs]
    assert(persisted and persisted.username == "catalog-user" and
        persisted.password == "catalog-password",
        "catalog credentials were not persisted")
    local repeated_parents = {
        { title = "Library root", url = "https://example.invalid/opds" },
        { title = "Authors index", url = "https://example.invalid/opds/authors" },
        { title = "Authors index", url = "https://example.invalid/opds/authors/A" },
        { title = "Authors index", url = "https://example.invalid/opds/authors/Ar" },
    }
    local synthetic_cache_keys = {}
    local function cacheParent(url, entry_title, entry_url)
        local key = cacheKey(url, saved)
        table.insert(synthetic_cache_keys, key)
        self.feed_cache[key] = {
            stored_at = os.time(),
            body = '<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">' ..
                '<title>Authors index</title><entry><title>' .. entry_title ..
                '</title><link href="' .. entry_url ..
                '" type="application/atom+xml;profile=opds-catalog"/></entry></feed>',
        }
    end
    cacheParent(repeated_parents[2].url, "A", repeated_parents[3].url)
    cacheParent(repeated_parents[3].url, "Ar", repeated_parents[4].url)
    local repaired = self:repairCatalogParents(repeated_parents, saved)
    assert(repaired[1].label == "Library root" and
        repaired[2].label == "Authors index" and
        repaired[3].label == "A" and repaired[4].label == "Ar",
        "cached parent feeds did not repair every repeated-title path segment")
    for _, key in ipairs(synthetic_cache_keys) do self.feed_cache[key] = nil end
    self.current_catalog = saved
    self.catalog_parents = {
        { title = "Library root", url = saved.url },
        { title = "Authors index", url = "https://example.invalid/opds/authors" },
    }
    self.current_feed = {
        title = "Arthur C. Clarke",
        source_url = "https://example.invalid/opds/authors/clarke",
        entries = {},
    }
    local bookmarked_url = self.current_feed.source_url
    self.screen = "feed"
    self:activate("bookmark-current")
    local bookmark_index = self:bookmarkIndex(saved.id, bookmarked_url)
    assert(bookmark_index, "bookmark was not saved")
    assert(#self.bookmarks[bookmark_index].parents == 2 and
        self.bookmarks[bookmark_index].parents[1].url == saved.url and
        self.bookmarks[bookmark_index].parents[2].url == "https://example.invalid/opds/authors",
        "bookmark did not retain its structured parent stack")
    assert(type(self.bookmarks[bookmark_index].path) == "table" and
        self.bookmarks[bookmark_index].path[#self.bookmarks[bookmark_index].path] == "Arthur C. Clarke",
        "bookmark did not retain its catalog path")
    self:showBookmarkRename(bookmark_index)
    self.input_fields[1]:setText("Favorite authors")
    self:activate("save-bookmark-name")
    assert(self.bookmarks[bookmark_index].title == "Favorite authors",
        "bookmark was not renamed")
    self.current_feed = {
        title = "Arthur C. Clarke",
        source_url = "https://example.invalid/opds/authors/clarke",
        up_url = "https://example.invalid/opds/authors",
        up_title = "Authors index",
        entries = {},
    }
    self.catalog_parents = {}
    self.bookmark_path = nil
    assert(self:feedBreadcrumb():find("Authors index", 1, true),
        "feed parent title was not shown in the breadcrumb")
    self.catalog_parents = cloneList(self.bookmarks[bookmark_index].parents)
    assert(self:feedBreadcrumb():find("Library root", 1, true) and
        self:feedBreadcrumb():find("Authors index", 1, true),
        "bookmark breadcrumb did not restore all structured parents")
    local original_load_for_up = self.loadFeed
    local opened_parent
    self.loadFeed = function(instance, url, _, title, _, preserve_history, navigation_kind)
        opened_parent = url
        instance:adoptFeed({ title = title, source_url = url, entries = {} },
            title, preserve_history, navigation_kind)
    end
    self:activate("catalog-up")
    self.loadFeed = original_load_for_up
    assert(opened_parent == "https://example.invalid/opds/authors",
        "catalog Up did not open the OPDS parent")
    assert(#self.catalog_parents == 1 and self.catalog_parents[1].url == saved.url,
        "catalog Up did not pop exactly one structured parent")
    self.bookmark_path = nil
    self.current_feed = {
        title = "Arthur C. Clarke",
        source_url = "https://example.invalid/opds/authors/clarke",
        entries = {},
    }
    self:activate("remove-current-bookmark")
    assert(not self:bookmarkIndex(saved.id, bookmarked_url), "bookmark was not removed")
    self.pending_delete_index, self.pending_delete = #self.catalogs, saved
    self:activate("confirm-delete")
    assert(#self.catalogs == original_catalog_count, "catalog was not deleted")
    local report = assert(io.open(report_path, "w"))
    report:write("reader-shell-self-test: ok\n")
    report:close()
    UIManager:quit(0)
end

function Shell:runCancellationTest(report_path, slow_url)
    self.busy = "Opening catalog"
    self:invalidate("full")
    UIManager:forceRePaint()
    Trapper:wrap(function()
        local cancel_when_ready
        cancel_when_ready = function()
            if self.dismiss_callback then self.dismiss_callback()
            else UIManager:scheduleIn(0.05, cancel_when_ready) end
        end
        UIManager:scheduleIn(0.2, cancel_when_ready)
        local completed = Trapper:dismissableRunInSubprocess(
            CatalogService.fetchTask(slow_url, "", ""), self)
        self.busy, self.dismiss_callback = nil, nil
        assert(not completed, "slow network action was not cancelled")
        local report = assert(io.open(report_path, "w"))
        report:write("reader-shell-cancellation-test: ok\n")
        report:close()
        UIManager:quit(0)
    end)
end

function Shell:runPagingAudit(report_path, first_url)
    Trapper:wrap(function()
        local report = assert(io.open(report_path, "w"))
        local report_dir = report_path:match("^(.*)/[^/]+$") or "."
        local remote_pages = 1
        local ui_page = 0
        local final_total
        self.current_catalog = {
            id = "paging-audit", title = "Demo", url = "https://example.invalid/opds",
            username = "", password = "", download_directory = "/tmp",
        }
        self.feed_history = {}
        self.pagination_history = {}
        self.catalog_parents = {}
        self.feed_return_screen = "bookmarks"
        self.bookmarks = {
            {
                catalog_id = "paging-audit", catalog_title = "FB",
                title = "Saved author", url = first_url, parents = {},
            },
        }
        local response = CatalogService.fetchTask(first_url, "", "")()
        assert(response and response.ok, "paging audit request failed")
        local feed, parse_error = CatalogService.parse(response.body, first_url)
        assert(feed, parse_error)
        self.current_feed = feed
        feed.bookmark_url = first_url
        self.screen = "feed"
        self:resetScroll("feed")

        local function appendNext(target_offset)
            local next_url = assert(self.current_feed.next_url,
                "append requested without a next feed")
            local next_response = CatalogService.fetchTask(next_url, "", "")()
            assert(next_response and next_response.ok, "paging audit request failed")
            local next_feed, next_error = CatalogService.parse(next_response.body, next_url)
            assert(next_feed, next_error)
            remote_pages = remote_pages + 1
            self.pending_append_offset = target_offset
            self:adoptFeed(next_feed, nil, true, "append")
        end

        while true do
            ui_page = ui_page + 1
            local entries = self.current_feed.entries or {}
            local first = self.scroll_offsets.feed + 1
            local last = math.min(#entries, self.scroll_offsets.feed + 7)
            local shown_page, shown_total, _, has_next =
                self:feedPaginationPosition(#entries, 7)
            final_total = shown_total
            local back_label, back_icon = self:feedBackControl()
            local bookmarked = self:bookmarkIndex(
                self.current_catalog.id, self:currentBookmarkUrl()) ~= nil
            report:write(string.format(
                "UI %d page=%d/%s items=%d-%d count=%d next=%s footer=%s,%s,%s\n",
                ui_page, shown_page, shown_total and tostring(shown_total) or "?",
                first, last, last - first + 1, has_next and "enabled" or "disabled",
                back_label, self:catalogUpUrl() and "Up" or "No Up",
                bookmarked and "Remove bookmark" or "Bookmark this page"))
            assert(shown_page == ui_page,
                "visible pagination restarted at a server feed boundary")
            assert(last - first + 1 == 7 or not has_next,
                "a non-final UI page was left partially filled")
            assert(back_label == "Bookmarks" and back_icon == "bookmark",
                "pagination changed the bookmark return control")
            assert(bookmarked, "pagination changed the logical bookmark identity")
            for index = first, last do
                report:write(string.format("  %s\n", entries[index].title))
            end
            self:invalidate("full")
            UIManager:forceRePaint()
            Device.screen:shot(string.format("%s/ui-%02d.png", report_dir, ui_page))
            if not has_next then break end

            local target_offset = self.scroll_offsets.feed + 7
            local remaining = #entries - target_offset
            if self.current_feed.next_url and remaining < 7 then
                appendNext(target_offset)
            else
                self.scroll_offsets.feed = target_offset
            end
        end
        assert(final_total == ui_page,
            "final page count did not match the flattened audit sequence")
        report:write(string.format("paging-audit: ok screens=%d remote_pages=%d\n",
            ui_page, remote_pages))
        report:close()
        UIManager:quit(0)
    end)
end

return Shell
