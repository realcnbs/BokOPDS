require("setupkoenv")

G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):wrap({
    anti_alias_ui = true,
    color_rendering = false,
    language = "en",
})

local CatalogService = require("apps/bokopds/catalog_service")
local SecureHttp = require("apps/bokopds/secure_http")

-- The public defaults shipped by the KOReader release pinned in
-- reader-shell/runtime.lock. Keep this list in sync when that runtime changes.
local catalogs = {
    { "Project Gutenberg", "https://m.gutenberg.org/ebooks.opds/?format=opds" },
    { "Standard Ebooks", "https://standardebooks.org/feeds/opds" },
    { "ManyBooks", "http://manybooks.net/opds/index.php" },
    { "Internet Archive", "https://bookserver.archive.org/" },
    { "textos.info", "https://www.textos.info/catalogo.atom" },
    { "Gallica", "https://gallica.bnf.fr/opds" },
}

local strict = os.getenv("BOKOPDS_LIVE_STRICT") == "1"
local passed, unavailable, failed = 0, 0, 0

local function request(url)
    return SecureHttp.request({
        url = url,
        headers = {
            ["Accept"] = "application/opds+json, application/atom+xml;profile=opds-catalog, */*",
            ["Accept-Encoding"] = "identity",
        },
        block_timeout = 8,
        total_timeout = 20,
        max_bytes = 4 * 1024 * 1024,
    })
end

local function validateFeed(feed)
    if #(feed.entries or {}) == 0 and not feed.search_url then
        return nil, "parsed feed has no entries or search"
    end
    local first_child
    for _, entry in ipairs(feed.entries or {}) do
        if not entry.publication then
            if not entry.url then return nil, "navigation entry has no URL" end
            first_child = first_child or entry.url
        end
    end
    return first_child
end

for _, catalog in ipairs(catalogs) do
    local name, url = catalog[1], catalog[2]
    local valid, policy_error = SecureHttp.validateUrl(url)
    if not valid then
        unavailable = unavailable + 1
        io.write(string.format("POLICY\t%s\t%s\n", name, policy_error))
    else
        local response = request(url)
        if not response.ok then
            unavailable = unavailable + 1
            io.write(string.format("UNAVAILABLE\t%s\t%s\n", name,
                tostring(response.code or response.error)))
        else
            local feed, parse_error = CatalogService.parse(response.body, response.final_url or url)
            if not feed then
                failed = failed + 1
                io.write(string.format("FAIL\t%s\t%s\n", name, tostring(parse_error)))
            else
                local first_child, validation_error = validateFeed(feed)
                if validation_error then
                    failed = failed + 1
                    io.write(string.format("FAIL\t%s\t%s\n", name, validation_error))
                else
                    local child_note = ""
                    local child_failed = false
                    if first_child then
                        local child_response = request(first_child)
                        if child_response.ok then
                            local child, child_parse_error = CatalogService.parse(
                                child_response.body, child_response.final_url or first_child)
                            if not child then
                                child_failed = true
                                child_note = tostring(child_parse_error)
                            else
                                local _, child_validation_error = validateFeed(child)
                                if child_validation_error then
                                    child_failed = true
                                    child_note = child_validation_error
                                else
                                    child_note = string.format("; child %s, %d entries",
                                        tostring(child.title or "Catalog"),
                                        #(child.entries or {}))
                                end
                            end
                        else
                            child_note = "; child unavailable: " ..
                                tostring(child_response.code or child_response.error)
                        end
                    end
                    if child_failed then
                        failed = failed + 1
                        io.write(string.format("FAIL\t%s\tchild feed: %s\n", name, child_note))
                    else
                        passed = passed + 1
                        io.write(string.format("PASS\t%s\t%s\t%d entries%s\n", name,
                            tostring(feed.title or "Catalog"), #(feed.entries or {}), child_note))
                    end
                end
            end
        end
    end
end

io.write(string.format("live-catalogs: %d passed, %d unavailable, %d failed\n",
    passed, unavailable, failed))

if failed > 0 or passed == 0 or (strict and unavailable > 0) then os.exit(1) end
