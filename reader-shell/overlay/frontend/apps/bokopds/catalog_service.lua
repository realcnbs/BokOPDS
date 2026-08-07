local OPDSParser = require("apps/bokopds/opdsparser")
local SecureHttp = require("apps/bokopds/secure_http")
local socket_url = require("socket.url")
local util = require("util")

local CatalogService = {}

local CATALOG_TYPE = "application/atom%+xml"
local ACQUISITION_REL = "^http://opds%-spec%.org/acquisition"
local MAX_COVER_PIXELS = 2 * 1000 * 1000
local MAX_COVER_DIMENSION = 4096
local COVER_PART_SUFFIX = ".bokopds-cover.part"

CatalogService.COVER_PART_SUFFIX = COVER_PART_SUFFIX

local function u16be(data, offset)
    local a, b = data:byte(offset, offset + 1)
    if not b then return end
    return a * 256 + b
end

local function u16le(data, offset)
    local a, b = data:byte(offset, offset + 1)
    if not b then return end
    return a + b * 256
end

local function u24le(data, offset)
    local a, b, c = data:byte(offset, offset + 2)
    if not c then return end
    return a + b * 256 + c * 65536
end

local function u32be(data, offset)
    local a, b, c, d = data:byte(offset, offset + 3)
    if not d then return end
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local function jpegDimensions(data)
    local offset = 3
    while offset + 8 <= #data do
        if data:byte(offset) ~= 0xFF then
            offset = offset + 1
        else
            local marker = data:byte(offset + 1)
            while marker == 0xFF do
                offset = offset + 1
                marker = data:byte(offset + 1)
            end
            if marker == 0xD8 or marker == 0xD9 or marker == 0x01 or
                    (marker >= 0xD0 and marker <= 0xD7) then
                offset = offset + 2
            else
                local segment_length = u16be(data, offset + 2)
                if not segment_length or segment_length < 2 then return end
                if (marker >= 0xC0 and marker <= 0xC3) or
                        (marker >= 0xC5 and marker <= 0xC7) or
                        (marker >= 0xC9 and marker <= 0xCB) or
                        (marker >= 0xCD and marker <= 0xCF) then
                    return u16be(data, offset + 5), u16be(data, offset + 7)
                end
                offset = offset + 2 + segment_length
            end
        end
    end
end

local function imageDimensions(data)
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then
        return u32be(data, 17), u32be(data, 21), true
    end
    if data:sub(1, 6) == "GIF87a" or data:sub(1, 6) == "GIF89a" then
        return u16le(data, 7), u16le(data, 9), true
    end
    if data:byte(1) == 0xFF and data:byte(2) == 0xD8 then
        local width, height = jpegDimensions(data)
        return width, height, true
    end
    if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
        local chunk = data:sub(13, 16)
        if chunk == "VP8X" then
            return (u24le(data, 25) or -1) + 1, (u24le(data, 28) or -1) + 1, true
        elseif chunk == "VP8L" and data:byte(21) == 0x2F then
            local b1, b2, b3, b4 = data:byte(22, 25)
            if not b4 then return nil, nil, true end
            return 1 + b1 + (b2 % 64) * 256,
                1 + math.floor(b2 / 64) + b3 * 4 + (b4 % 16) * 1024, true
        elseif chunk == "VP8 " then
            local frame = data:find("\157\1\42", 21, true)
            if frame then
                local width, height = u16le(data, frame + 3), u16le(data, frame + 5)
                if width and height then return width % 16384, height % 16384, true end
            end
        end
        return nil, nil, true
    end
    return nil, nil, false
end

function CatalogService.coverDimensions(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read(256 * 1024) or ""
    file:close()
    local width, height, recognized = imageDimensions(data)
    if not recognized or not width or not height or width < 1 or height < 1 then
        return nil
    end
    if width > MAX_COVER_DIMENSION or height > MAX_COVER_DIMENSION or
            width * height > MAX_COVER_PIXELS then
        return nil
    end
    return width, height
end

local function validateCoverFile(path)
    local file = io.open(path, "rb")
    if not file then return nil, "cover file could not be opened" end
    local data = file:read(256 * 1024) or ""
    file:close()
    local width, height, recognized = imageDimensions(data)
    if not recognized then return nil, "cover file is not a supported image" end
    if recognized and (not width or not height or width < 1 or height < 1) then
        return nil, "cover image header is invalid"
    end
    if width and height and (width > MAX_COVER_DIMENSION or
            height > MAX_COVER_DIMENSION or width * height > MAX_COVER_PIXELS) then
        return nil, "cover image dimensions are too large"
    end
    return true
end

local function list(value)
    if type(value) ~= "table" then return {} end
    if value[1] ~= nil then return value end
    return { value }
end

local function relations(value)
    if type(value) == "table" then return value end
    local result = {}
    for relation in tostring(value or ""):gmatch("%S+") do
        table.insert(result, relation)
    end
    return result
end

local function hasRelation(value, expected)
    for _, relation in ipairs(relations(value)) do
        if relation == expected then return true end
    end
    return false
end

local function absolute(base, href)
    if not href or href == "" then return nil end
    return socket_url.absolute(base, href)
end

local function authorName(author)
    if type(author) ~= "table" then return "" end
    local name = author.name
    if type(name) == "string" then return name end
    if type(name) == "table" then return table.concat(name, ", ") end
    return ""
end

local function numberValue(value)
    local number = tonumber(value)
    if number and number >= 0 then return number end
end

local function languageList(value)
    local result, seen = {}, {}
    local values = type(value) == "table" and list(value) or { value }
    for _, language in ipairs(values) do
        if type(language) == "table" then language = language.value or language.name end
        for code in tostring(language or ""):gmatch("[^,%s]+") do
            code = code:lower():gsub("_", "-")
            if code ~= "" and not seen[code] then
                seen[code] = true
                table.insert(result, code)
            end
        end
    end
    return result
end

local function parseAtom(document, source_url)
    local feed = document.feed or document
    local result = {
        title = type(feed.title) == "string" and feed.title or "Catalog",
        source_url = source_url,
        entries = {},
        total_items = numberValue(feed["os:totalResults"] or
            feed["opensearch:totalResults"] or feed.totalResults),
        items_per_page = numberValue(feed["os:itemsPerPage"] or
            feed["opensearch:itemsPerPage"] or feed.itemsPerPage),
        start_index = numberValue(feed["os:startIndex"] or
            feed["opensearch:startIndex"] or feed.startIndex),
        language_facets = {},
    }

    for _, link in ipairs(list(feed.link)) do
        local rel = link.rel or ""
        local href = absolute(source_url, link.href)
        local media_type = (link.type or ""):lower()
        if href and hasRelation(rel, "next") then
            result.next_url = href
        elseif href and (hasRelation(rel, "previous") or hasRelation(rel, "prev")) then
            result.previous_url = href
        elseif href and hasRelation(rel, "first") then
            result.first_url = href
        elseif href and hasRelation(rel, "last") then
            result.last_url = href
        elseif href and hasRelation(rel, "up") then
            result.up_url = href
            result.up_title = link.title
        elseif href and hasRelation(rel, "start") then
            result.start_url = href
        elseif href and rel:find("search", 1, true) then
            if media_type:find("application/opensearchdescription+xml", 1, true) then
                result.search_descriptor_url = href
            else
                result.search_url = href:gsub("{searchTerms}", "%%s")
            end
        elseif href and rel:find("http://opds%-spec%.org/facet") and
                tostring(link["opds:facetGroup"] or link.facetGroup or ""):lower() == "language" then
            table.insert(result.language_facets, {
                title = link.title or "Language",
                url = href,
                active = tostring(link["opds:activeFacet"] or link.activeFacet) == "true",
                count = numberValue(link["thr:count"] or link.count),
            })
        end
    end

    if result.items_per_page and result.items_per_page > 0 and result.start_index then
        result.current_remote_page = math.floor(result.start_index / result.items_per_page) + 1
    end

    for _, entry in ipairs(list(feed.entry)) do
        local item = {
            title = type(entry.title) == "string" and entry.title or "Untitled",
            author = authorName(entry.author),
            summary = util.htmlToPlainTextIfHtml(entry.content or entry.summary or ""),
            acquisitions = {},
            related = {},
            languages = languageList(entry["dc:language"] or entry.language),
        }
        item.language = item.languages[1]
        for _, link in ipairs(list(entry.link)) do
            local href = absolute(source_url, link.href)
            local rel = link.rel or ""
            local media_type = link.type or ""
            if href and media_type:find(CATALOG_TYPE) and
                    (rel == "" or rel == "subsection" or rel:find("subsection", 1, true)) then
                item.url = href
            elseif href and rel:match(ACQUISITION_REL) then
                table.insert(item.acquisitions, {
                    href = href,
                    type = media_type,
                    title = link.title,
                    book_title = item.title,
                    book_author = item.author,
                })
            elseif href and rel == "related" and media_type:find(CATALOG_TYPE) then
                table.insert(item.related, { href = href, title = link.title })
            elseif href and (rel:find("image/thumbnail", 1, true) or rel == "x-stanza-cover-image-thumbnail") then
                item.thumbnail = href
            elseif href and (rel:find("image", 1, true) or rel == "x-stanza-cover-image") then
                item.image = href
            elseif href and media_type == "application/pdf" and rel ~= "subsection" then
                table.insert(item.acquisitions, {
                    href = href,
                    type = media_type,
                    title = link.title,
                    book_title = item.title,
                    book_author = item.author,
                })
            end
        end
        item.publication = #item.acquisitions > 0
        table.insert(result.entries, item)
    end

    -- Some OPDS 1 catalogs omit rel="up" but repeat the same related catalog
    -- link on every publication (for example, an author's alphabetic listing).
    -- A link common to every entry is a safe parent candidate; a link present
    -- on only some books is not.
    if not result.up_url and #result.entries >= 2 then
        local counts, ordered = {}, {}
        for _, item in ipairs(result.entries) do
            local seen = {}
            for _, related in ipairs(item.related or {}) do
                if not seen[related.href] then
                    seen[related.href] = true
                    if not counts[related.href] then
                        counts[related.href] = { count = 0, title = related.title }
                        table.insert(ordered, related.href)
                    end
                    counts[related.href].count = counts[related.href].count + 1
                end
            end
        end
        for _, href in ipairs(ordered) do
            if counts[href].count == #result.entries then
                result.up_url = href
                result.up_title = counts[href].title
                break
            end
        end
    end
    return result
end

local function parseJSON(document, source_url)
    local result = {
        title = document.metadata and document.metadata.title or "Catalog",
        source_url = source_url,
        entries = {},
        total_items = numberValue(document.metadata and document.metadata.numberOfItems),
        items_per_page = numberValue(document.metadata and document.metadata.itemsPerPage),
        current_remote_page = numberValue(document.metadata and document.metadata.currentPage),
        language_facets = {},
    }
    for _, link in ipairs(list(document.links)) do
        local rel = link.rel
        if hasRelation(rel, "next") then result.next_url = absolute(source_url, link.href) end
        if hasRelation(rel, "previous") or hasRelation(rel, "prev") then
            result.previous_url = absolute(source_url, link.href)
        end
        if hasRelation(rel, "first") then result.first_url = absolute(source_url, link.href) end
        if hasRelation(rel, "last") then result.last_url = absolute(source_url, link.href) end
        if hasRelation(rel, "up") then result.up_url = absolute(source_url, link.href) end
        if hasRelation(rel, "start") then result.start_url = absolute(source_url, link.href) end
        if hasRelation(rel, "search") then
            local href = absolute(source_url, link.href)
            if (link.type or ""):lower():find("application/opensearchdescription+xml", 1, true) then
                result.search_descriptor_url = href
            else
                result.search_url = href:gsub("{searchTerms}", "%%s")
            end
        end
    end
    for _, facet in ipairs(list(document.facets)) do
        local metadata = facet.metadata or {}
        if tostring(metadata.title or ""):lower() == "language" then
            for _, link in ipairs(list(facet.links)) do
                table.insert(result.language_facets, {
                    title = link.title or "Language",
                    url = absolute(source_url, link.href),
                    active = hasRelation(link.rel, "self"),
                    count = numberValue(link.properties and link.properties.numberOfItems),
                })
            end
        end
    end
    local function addItems(items, publication)
        for _, entry in ipairs(list(items)) do
            local metadata = entry.metadata or {}
            local item = {
                title = metadata.title or entry.title or "Untitled",
                author = "",
                summary = util.htmlToPlainTextIfHtml(metadata.description or ""),
                acquisitions = {},
                publication = publication,
                languages = languageList(metadata.language),
            }
            item.language = item.languages[1]
            local author = metadata.author
            if type(author) == "table" then
                if type(author.name) == "string" then
                    item.author = author.name
                elseif type(author[1]) == "table" then
                    local names = {}
                    for _, value in ipairs(author) do
                        if value.name then table.insert(names, value.name) end
                    end
                    item.author = table.concat(names, ", ")
                end
            end
            for _, link in ipairs(list(entry.links)) do
                local rel = type(link.rel) == "table" and link.rel[1] or link.rel or ""
                local href = absolute(source_url, link.href)
                if href and publication and (rel == "http://opds-spec.org/acquisition" or
                        rel == "http://opds-spec.org/acquisition/open-access" or
                        rel == "download" or rel == "publication") then
                    table.insert(item.acquisitions, {
                        href = href,
                        type = link.type,
                        title = link.title,
                        book_title = item.title,
                        book_author = item.author,
                    })
                elseif href and not publication then
                    item.url = item.url or href
                end
            end
            item.publication = #item.acquisitions > 0 or publication
            table.insert(result.entries, item)
        end
    end
    addItems(document.navigation, false)
    addItems(document.publications, true)
    return result
end

function CatalogService.parseSearchDescription(body, source_url)
    if type(body) ~= "string" or body == "" then
        return nil, "Search description returned no data"
    end
    local ok, document = pcall(OPDSParser.parse, OPDSParser, body)
    if not ok or type(document) ~= "table" then
        return nil, "Search description could not be parsed"
    end
    local description = document.OpenSearchDescription or document
    local fallback
    for _, url in ipairs(list(description.Url)) do
        if type(url) == "table" and url.template then
            local template = absolute(source_url, url.template)
            template = template:gsub("{searchTerms}", "%%s")
                :gsub("{searchTerms%?}", "%%s")
                :gsub("{[%w_]+%?}", "")
            fallback = fallback or template
            local media_type = (url.type or ""):lower()
            if media_type:find("atom+xml", 1, true) or
                    media_type:find("opds", 1, true) then
                return template
            end
        end
    end
    if fallback then return fallback end
    return nil, "Search description contains no OPDS template"
end

function CatalogService.parse(body, source_url)
    if type(body) ~= "string" or body == "" then return nil, "Catalog returned no data" end
    if body:match("^%s*<") then
        local ok, document = pcall(OPDSParser.parse, OPDSParser, body)
        if not ok or type(document) ~= "table" then return nil, "Catalog XML could not be parsed" end
        return parseAtom(document, source_url)
    elseif body:match("^%s*{") then
        local JSON = require("json")
        local ok, document = pcall(JSON.decode, body)
        if not ok or type(document) ~= "table" then return nil, "Catalog JSON could not be parsed" end
        local normalized, result = pcall(parseJSON, document, source_url)
        if not normalized or type(result) ~= "table" then
            return nil, "Catalog JSON has an invalid OPDS structure"
        end
        return result
    end
    return nil, "Catalog response is not OPDS"
end

function CatalogService.fetchTask(request_url, username, password, auth_origin)
    return function()
        local response = SecureHttp.request({
            url = request_url,
            headers = {
                ["Accept"] = "application/opds+json, application/atom+xml;profile=opds-catalog, */*",
                ["Accept-Encoding"] = "identity",
            },
            username = username,
            password = password,
            auth_origin = auth_origin or request_url,
            block_timeout = 15,
            total_timeout = 60,
            max_bytes = 4 * 1024 * 1024,
        })
        return response
    end
end

local MAX_FILENAME_BYTES = 180

local function extensionFor(media_type, remote_url)
    local media = tostring(media_type or ""):lower()
    if media:find("epub", 1, true) then return ".epub" end
    if media:find("pdf", 1, true) then return ".pdf" end
    if media:find("fb2+zip", 1, true) then return ".fb2.zip" end
    if media:find("fb2", 1, true) then return ".fb2" end
    if media:find("mobipocket", 1, true) then return ".mobi" end
    if media:find("html", 1, true) then return ".html" end
    if media:find("text/plain", 1, true) then return ".txt" end
    local parsed = socket_url.parse(remote_url or "") or {}
    local path = util.urlDecode(parsed.path or ""):lower()
    return path:match("(%.fb2%.zip)$") or path:match("(%.html%.zip)$") or
        path:match("(%.txt%.zip)$") or path:match("(%.[%w]+)$") or ".book"
end

local function truncateUtf8Bytes(value, maximum)
    if #value <= maximum then return value end
    local position, last_complete = 1, 0
    while position <= #value do
        local byte = value:byte(position)
        local length = byte < 0x80 and 1 or byte < 0xE0 and 2 or
            byte < 0xF0 and 3 or 4
        if position + length - 1 > maximum then break end
        last_complete = position + length - 1
        position = position + length
    end
    return value:sub(1, last_complete)
end

local function cleanFilenamePart(value)
    value = tostring(value or "")
        :gsub("[%c]", " ")
        :gsub("[/\\:*?\"<>|]", " ")
        :gsub("%s+", " ")
        :gsub("^[%.%s]+", "")
        :gsub("[%.%s]+$", "")
    return value
end

local function filenameBase(acquisition)
    local author = cleanFilenamePart(acquisition.book_author)
    local title = cleanFilenamePart(acquisition.book_title)
    local base
    if author ~= "" and title ~= "" then
        base = author .. " - " .. title
    elseif title ~= "" then
        base = title
    elseif author ~= "" then
        base = author
    else
        local parsed = socket_url.parse(acquisition.href or "") or {}
        base = cleanFilenamePart(util.urlDecode(
            (parsed.path or ""):match("([^/]+)$") or "Book"))
        local known_extension = extensionFor(acquisition.type, acquisition.href)
        if base:lower():sub(-#known_extension) == known_extension then
            base = base:sub(1, -#known_extension - 1)
        end
    end
    if base == "" then base = "Book" end
    return base
end

local function availablePath(directory, acquisition)
    local lfs = require("libs/libkoreader-lfs")
    local extension = extensionFor(acquisition.type, acquisition.href)
    local original_base = filenameBase(acquisition)
    local sequence = 1
    while true do
        local suffix = sequence == 1 and "" or "-" .. sequence
        local base = truncateUtf8Bytes(original_base,
            MAX_FILENAME_BYTES - #extension - #suffix):gsub("[%.%s]+$", "")
        if base == "" then base = "Book" end
        local path = directory:gsub("/+$", "") .. "/" .. base .. suffix .. extension
        if not lfs.attributes(path, "mode") then return path end
        sequence = sequence + 1
    end
end

function CatalogService.suggestedFilename(acquisition)
    local extension = extensionFor(acquisition.type, acquisition.href)
    local base = truncateUtf8Bytes(filenameBase(acquisition),
        MAX_FILENAME_BYTES - #extension):gsub("[%.%s]+$", "")
    return (base ~= "" and base or "Book") .. extension
end

function CatalogService.cleanupPartFiles(directory)
    local lfs = require("libs/libkoreader-lfs")
    local ok, iterator, state = pcall(lfs.dir, directory)
    if not ok or not iterator then return end
    for name in iterator, state do
        if name ~= "." and name ~= ".." and name:match("%.bokopds%.part$") then
            os.remove(directory:gsub("/+$", "") .. "/" .. name)
        end
    end
end

function CatalogService.planDownload(acquisition, directory)
    local planned = {}
    for key, value in pairs(acquisition or {}) do planned[key] = value end
    planned.destination_path = availablePath(directory, planned)
    planned.partial_path = planned.destination_path .. ".bokopds.part"
    return planned
end

function CatalogService.downloadTask(acquisition, directory, username, password, auth_origin)
    return function()
        local lfs = require("libs/libkoreader-lfs")
        local util_child = require("util")
        util_child.makePath(directory)
        local final_path = acquisition.destination_path or availablePath(directory, acquisition)
        local partial_path = acquisition.partial_path or (final_path .. ".bokopds.part")
        os.remove(partial_path)
        local response = SecureHttp.request({
            url = acquisition.href,
            output_path = partial_path,
            username = username,
            password = password,
            auth_origin = auth_origin or acquisition.href,
            block_timeout = 15,
            total_timeout = 300,
        })
        if not response.ok then
            os.remove(partial_path)
            return { ok = false, error = response.error }
        end
        local size = lfs.attributes(partial_path, "size") or 0
        local renamed, rename_error = os.rename(partial_path, final_path)
        if not renamed then
            os.remove(partial_path)
            return { ok = false, error = rename_error }
        end
        return { ok = true, path = final_path, size = size, headers = response.headers }
    end
end

function CatalogService.coverTask(remote_url, destination, username, password, auth_origin)
    return function()
        local partial = destination .. COVER_PART_SUFFIX
        os.remove(partial)
        local response = SecureHttp.request({
            url = remote_url,
            output_path = partial,
            username = username,
            password = password,
            auth_origin = auth_origin or remote_url,
            block_timeout = 15,
            total_timeout = 90,
            max_bytes = 8 * 1024 * 1024,
        })
        if not response.ok then
            os.remove(partial)
            return { ok = false, error = response.error }
        end
        local valid, validation_error = validateCoverFile(partial)
        if not valid then
            os.remove(partial)
            return { ok = false, error = validation_error }
        end
        local renamed, rename_error = os.rename(partial, destination)
        if not renamed then
            os.remove(partial)
            return { ok = false, error = rename_error }
        end
        return { ok = true, path = destination }
    end
end

function CatalogService.cleanupCoverPartFiles(directory)
    if type(directory) ~= "string" or directory == "" then return end
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(directory, "mode") ~= "directory" then return end
    for name in lfs.dir(directory) do
        if name:sub(-#COVER_PART_SUFFIX) == COVER_PART_SUFFIX then
            os.remove(directory .. "/" .. name)
        end
    end
end

function CatalogService.formatName(acquisition)
    local media_type = (acquisition.type or ""):lower()
    if media_type:find("epub", 1, true) then return "EPUB" end
    if media_type:find("pdf", 1, true) then return "PDF" end
    if media_type:find("fb2", 1, true) then return "FB2" end
    if media_type:find("mobipocket", 1, true) then return "MOBI" end
    if media_type:find("html", 1, true) then return "HTML" end
    if media_type:find("text/plain", 1, true) then return "TXT" end
    if acquisition.title and acquisition.title ~= "" then return acquisition.title:upper() end
    return "FILE"
end

return CatalogService
