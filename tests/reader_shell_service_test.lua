require("setupkoenv")

G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):wrap({
    anti_alias_ui = true,
    color_rendering = false,
    language = "en",
})

local CatalogService = require("apps/bokopds/catalog_service")
local lfs = require("libs/libkoreader-lfs")

-- These are native service paths reached by USB insertion and suspend. They
-- must remain loadable even though the full file manager and reader are not
-- shipped in the BokOPDS runtime.
assert(require("ui/elements/mass_storage"), "USB mass-storage service did not load")
require("document/canvascontext"):init(require("device"))
local usb_confirmation = require("ui/widget/confirmbox"):new{
    text = "Share storage via USB?",
    ok_text = "Share",
}
assert(usb_confirmation:getSize().w > 0,
    "USB confirmation dialog dependency chain did not render")
usb_confirmation:free()
local shell_stub = {}
package.loaded["apps/reader/readerui"] = { instance = nil }
package.loaded["apps/filemanager/filemanager"] = { instance = shell_stub }
G_reader_settings:saveSetting("screensaver_type", "disable")
G_reader_settings:makeFalse("screensaver_show_message")
local Screensaver = require("ui/screensaver")
Screensaver:setup()
assert(Screensaver.ui == shell_stub and Screensaver:getMode() == "disable",
    "minimal suspend service did not bind to the BokOPDS shell")
Screensaver:show()
Screensaver:close()

local base_url = assert(os.getenv("BOKOPDS_TEST_BASE_URL"))
local download_dir = assert(os.getenv("BOKOPDS_TEST_DOWNLOAD_DIR"))
local tls_base_url = assert(os.getenv("BOKOPDS_TLS_BASE_URL"))
local tls_wrong_url = assert(os.getenv("BOKOPDS_TLS_WRONG_URL"))
local tls_unknown_url = assert(os.getenv("BOKOPDS_TLS_UNKNOWN_URL"))
local auth_base_url = assert(os.getenv("BOKOPDS_AUTH_BASE_URL"))
local mime = require("mime")

local tls_response = CatalogService.fetchTask(tls_base_url .. "/root.xml", "", "")()
assert(tls_response.ok, "trusted TLS catalog failed: " .. tostring(tls_response.error))
local wrong_host = CatalogService.fetchTask(tls_wrong_url .. "/root.xml", "", "")()
assert(not wrong_host.ok and tostring(wrong_host.error):find("does not match", 1, true),
    "wrong-host TLS certificate was accepted")
local unknown_ca = CatalogService.fetchTask(tls_unknown_url .. "/root.xml", "", "")()
assert(not unknown_ca.ok, "unknown TLS certificate authority was accepted")

local cross_origin = CatalogService.fetchTask(auth_base_url .. "/auth-check",
    "secret-user", "secret-password", base_url)()
assert(cross_origin.ok and cross_origin.body == "none",
    "catalog credentials leaked to a cross-origin URL")
local same_origin = CatalogService.fetchTask(auth_base_url .. "/auth-check",
    "user%25", "password%2Fvalue", auth_base_url)()
assert(same_origin.ok and same_origin.body ==
    "Basic " .. mime.b64("user%25:password%2Fvalue"),
    "catalog credentials were changed before same-origin Basic authentication")

-- Exercise the complete Basic-auth catalog flow, not only header construction.
local auth_missing = CatalogService.fetchTask(
    auth_base_url .. "/protected.xml", "", "", auth_base_url)()
assert(not auth_missing.ok and auth_missing.code == 401,
    "protected catalog accepted a request without credentials")
local auth_rejected = CatalogService.fetchTask(auth_base_url .. "/protected.xml",
    "catalog-user", "wrong-password", auth_base_url)()
assert(not auth_rejected.ok and auth_rejected.code == 403,
    "protected catalog accepted incorrect credentials")
local auth_catalog = CatalogService.fetchTask(auth_base_url .. "/protected.xml",
    "catalog-user", "catalog-password", auth_base_url)()
assert(auth_catalog.ok, "valid catalog credentials were rejected")
local protected_feed, protected_parse_error = CatalogService.parse(
    auth_catalog.body, auth_base_url .. "/protected.xml")
assert(protected_feed and #protected_feed.entries == 2, protected_parse_error)
local protected_download = CatalogService.downloadTask({
    href = auth_base_url .. "/protected-book.epub",
    type = "application/epub+zip",
    book_author = "Authenticated Author",
    book_title = "Authenticated Book",
}, download_dir, "catalog-user", "catalog-password", auth_base_url)()
assert(protected_download.ok and
    lfs.attributes(protected_download.path, "mode") == "file",
    "authenticated acquisition download failed")
local rejected_download = CatalogService.downloadTask({
    href = auth_base_url .. "/protected-book.epub",
    type = "application/epub+zip",
    book_author = "Rejected Author",
    book_title = "Rejected Book",
}, download_dir, "catalog-user", "wrong-password", auth_base_url)()
assert(not rejected_download.ok and
    not lfs.attributes(download_dir .. "/Rejected Author - Rejected Book.epub", "mode") and
    not lfs.attributes(download_dir .. "/Rejected Author - Rejected Book.epub.bokopds.part", "mode"),
    "failed authenticated download left a book or partial file")
local redirected = CatalogService.fetchTask(base_url .. "/redirect",
    "secret-user", "secret-password", base_url)()
assert(redirected.ok and redirected.body == "none",
    "catalog credentials leaked across a redirect")

local denied_remote_http = require("apps/bokopds/secure_http").validateUrl(
    "http://example.com/catalog")
assert(not denied_remote_http, "plain remote HTTP was accepted")

local unrelated_partial = assert(io.open(download_dir .. "/another-application.part", "w"))
unrelated_partial:write("keep")
unrelated_partial:close()
local owned_partial = assert(io.open(download_dir .. "/old.bokopds.part", "w"))
owned_partial:write("remove")
owned_partial:close()
CatalogService.cleanupPartFiles(download_dir)
assert(lfs.attributes(download_dir .. "/another-application.part", "mode") == "file",
    "cleanup removed an unrelated partial file")
assert(not lfs.attributes(download_dir .. "/old.bokopds.part", "mode"),
    "cleanup did not remove a BokOPDS-owned partial file")

local response = CatalogService.fetchTask(base_url .. "/root.xml", "", "")()
assert(response.ok, "catalog fetch failed: " .. tostring(response.status or response.code))
local feed, parse_error = CatalogService.parse(response.body, base_url .. "/root.xml")
assert(feed, parse_error)
assert(feed.title == "Test Library", "wrong feed title")
assert(#feed.entries == 2, "wrong feed entry count")
assert(feed.entries[1].title == "Newest books" and not feed.entries[1].publication,
    "navigation entry was not parsed")
assert(feed.entries[2].title == "A Test Book" and feed.entries[2].publication,
    "publication entry was not parsed")
assert(feed.entries[2].author == "Alex Author", "author was not parsed")
assert(#feed.entries[2].acquisitions == 2, "acquisitions were not parsed")
assert(feed.search_url == base_url .. "/opds/search?q=%s", "search template was not parsed")
assert(feed.next_url == base_url .. "/opds/page/2", "pagination link was not parsed")

local sorted_catalog, sorted_catalog_error = CatalogService.parse([[
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Sorted catalog navigation</title>
  <entry><title>Popular books</title>
    <link rel="http://opds-spec.org/sort/popular" href="/popular.atom"
          type="application/atom+xml;profile=opds-catalog;kind=acquisition"/>
  </entry>
  <entry><title>New books</title>
    <link rel="http://opds-spec.org/sort/new" href="/new.atom"
          type="application/atom+xml;profile=opds-catalog;kind=acquisition"/>
  </entry>
</feed>]], base_url .. "/sorted.xml")
assert(sorted_catalog, sorted_catalog_error)
assert(sorted_catalog.entries[1].url == base_url .. "/popular.atom" and
    sorted_catalog.entries[2].url == base_url .. "/new.atom",
    "OPDS sort navigation relations were not parsed as catalog links")

local empty_content_feed, empty_content_error = CatalogService.parse([[
<feed xmlns="http://www.w3.org/2005/Atom"
      xmlns:dcterms="http://purl.org/dc/terms/">
  <title>Empty content fallback</title>
  <entry><title>La Metamorfosis</title><content type="text"></content>
    <summary>Fallback summary</summary><dcterms:language>es</dcterms:language>
    <link rel="http://opds-spec.org/acquisition" href="/book.epub"
          type="application/epub+zip"/>
  </entry>
</feed>]], base_url .. "/empty-content.xml")
assert(empty_content_feed, empty_content_error)
assert(empty_content_feed.entries[1].summary == "Fallback summary" and
    empty_content_feed.entries[1].language == "es",
    "empty Atom content did not fall back to summary or dcterms language")

local metadata_feed, metadata_error = CatalogService.parse([[
<feed xmlns="http://www.w3.org/2005/Atom"
      xmlns:dc="http://purl.org/dc/terms/"
      xmlns:os="http://a9.com/-/spec/opensearch/1.1/">
  <title>Known total</title>
  <os:totalResults>63</os:totalResults>
  <os:startIndex>0</os:startIndex>
  <os:itemsPerPage>20</os:itemsPerPage>
  <link rel="next" href="?pageNumber=1"/>
  <entry><title>French book</title><dc:language>fr-CA</dc:language>
    <link rel="http://opds-spec.org/acquisition" href="/fr.epub" type="application/epub+zip"/>
  </entry>
</feed>]], base_url .. "/known.xml")
assert(metadata_feed, metadata_error)
assert(metadata_feed.total_items == 63 and metadata_feed.items_per_page == 20 and
    metadata_feed.current_remote_page == 1, "OpenSearch paging metadata was not parsed")
assert(metadata_feed.entries[1].language == "fr-ca",
    "OPDS 1 publication language was not normalized")

local json_metadata, json_metadata_error = CatalogService.parse([[
{
  "metadata": {"title":"Known JSON total","numberOfItems":21,"itemsPerPage":10,"currentPage":1},
  "publications": [{
    "metadata": {"title":"Ukrainian book","language":["uk"]},
    "links": [{"rel":"download","href":"/uk.epub","type":"application/epub+zip"}]
  }]
}
]], base_url .. "/known.json")
assert(json_metadata, json_metadata_error)
assert(json_metadata.total_items == 21 and json_metadata.entries[1].language == "uk",
    "OPDS 2 paging or language metadata was not parsed")

local json_navigation, json_navigation_error = CatalogService.parse([[
{
  "metadata": {"title":"OPDS 2 navigation"},
  "links": [{
    "rel":["search"],
    "href":"/all{?query,per-page,page}",
    "type":"application/opds+json",
    "templated":true
  }],
  "navigation": [{
    "title":"Newest books",
    "href":"/new-releases",
    "rel":["http://opds-spec.org/sort/new"],
    "type":"application/opds+json"
  }]
}
]], base_url .. "/opds2/root.json")
assert(json_navigation, json_navigation_error)
assert(json_navigation.entries[1].url == base_url .. "/new-releases",
    "direct OPDS 2 navigation URL was not parsed")
assert(json_navigation.search_url == base_url .. "/all?query=%s",
    "OPDS 2 query URI template was not normalized for search: " ..
        tostring(json_navigation.search_url))

for _, invalid_json in ipairs({
    [[{"metadata":1}]],
    [[{"links":[{"rel":"search"}]}]],
    [[{"publications":[1]}]],
    [[{"publications":[{"metadata":1}]}]],
}) do
    local invalid_feed, invalid_error = CatalogService.parse(invalid_json,
        base_url .. "/invalid.json")
    assert(not invalid_feed and invalid_error == "Catalog JSON has an invalid OPDS structure",
        "schema-invalid OPDS JSON did not return a controlled parse error")
end

local hierarchy_feed, hierarchy_error = CatalogService.parse([[
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Deep catalog page</title>
  <link rel="up" href="../authors" type="application/atom+xml;profile=opds-catalog"/>
  <link rel="start" href="/opds/root" type="application/atom+xml;profile=opds-catalog"/>
</feed>]], base_url .. "/opds/authors/clarke")
assert(hierarchy_feed, hierarchy_error)
assert(hierarchy_feed.up_url == base_url .. "/opds/authors",
    "catalog parent link was not resolved")
assert(hierarchy_feed.start_url == base_url .. "/opds/root",
    "catalog start link was not resolved")

local related_parent, related_parent_error = CatalogService.parse([[
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Books alphabetically</title>
  <entry>
    <title>Book one</title>
    <link rel="related" href="/opds/author/42" type="application/atom+xml"
          title="Books by Ada Author"/>
    <link rel="related" href="/opds/series/1" type="application/atom+xml"
          title="Series one"/>
  </entry>
  <entry>
    <title>Book two</title>
    <link rel="related" href="/opds/author/42" type="application/atom+xml"
          title="Books by Ada Author"/>
    <link rel="related" href="/opds/series/2" type="application/atom+xml"
          title="Series two"/>
  </entry>
</feed>]], base_url .. "/opds/author/42/alphabet")
assert(related_parent, related_parent_error)
assert(related_parent.up_url == base_url .. "/opds/author/42",
    "common related catalog link was not inferred as the parent")
assert(related_parent.up_title == "Books by Ada Author",
    "inferred catalog parent title was not retained")

local json_hierarchy, json_hierarchy_error = CatalogService.parse([[
{
  "metadata": { "title": "JSON deep page" },
  "links": [
    { "rel": ["up"], "href": "../authors" },
    { "rel": ["start"], "href": "/opds/root" }
  ]
}
]], base_url .. "/opds/authors/clarke")
assert(json_hierarchy, json_hierarchy_error)
assert(json_hierarchy.up_url == base_url .. "/opds/authors",
    "JSON catalog parent link was not resolved")
assert(json_hierarchy.start_url == base_url .. "/opds/root",
    "JSON catalog start link was not resolved")

local descriptor_response = CatalogService.fetchTask(
    base_url .. "/search-description.xml", "", "")()
assert(descriptor_response.ok, "OpenSearch description fetch failed")
local search_template, search_error = CatalogService.parseSearchDescription(
    descriptor_response.body, base_url .. "/search-description.xml")
assert(search_template, search_error)
assert(search_template == base_url .. "/opds/catalog?q=%s",
    "OpenSearch template was not resolved")

local descriptor_feed, descriptor_feed_error = CatalogService.parse([[
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Descriptor Search</title>
  <link rel="search" href="/search-description.xml"
        type="application/opensearchdescription+xml"/>
</feed>]], base_url .. "/descriptor-root.xml")
assert(descriptor_feed, descriptor_feed_error)
assert(descriptor_feed.search_descriptor_url == base_url .. "/search-description.xml",
    "OpenSearch descriptor link was not detected")
assert(not descriptor_feed.search_url, "descriptor URL was mistaken for a search template")

local cover_path = download_dir .. "/cover.jpg"
local cover = CatalogService.coverTask(feed.entries[2].image, cover_path, "", "")()
assert(cover.ok and lfs.attributes(cover_path, "mode") == "file", "cover was not cached")
local cover_width, cover_height = CatalogService.coverDimensions(cover_path)
assert(cover_width == 64 and cover_height == 64,
    "cover dimensions were not read before aspect-fit decoding")
local oversized_cover_path = download_dir .. "/oversized.png"
local oversized_cover = CatalogService.coverTask(base_url .. "/covers/oversized.png",
    oversized_cover_path, "", "")()
assert(not oversized_cover.ok and
    oversized_cover.error == "cover image dimensions are too large" and
    not lfs.attributes(oversized_cover_path, "mode"),
    "oversized cover image was accepted")
local invalid_cover_path = download_dir .. "/invalid.jpg"
local invalid_cover = CatalogService.coverTask(base_url .. "/covers/not-an-image.jpg",
    invalid_cover_path, "", "")()
assert(not invalid_cover.ok and
    invalid_cover.error == "cover file is not a supported image" and
    not lfs.attributes(invalid_cover_path, "mode") and
    not lfs.attributes(invalid_cover_path .. CatalogService.COVER_PART_SUFFIX, "mode"),
    "non-image cover or its partial file was retained")

local acquisition = feed.entries[2].acquisitions[1]
assert(acquisition.book_title == "A Test Book" and acquisition.book_author == "Alex Author",
    "publication metadata was not attached to the acquisition")
assert(CatalogService.suggestedFilename(acquisition) == "Alex Author - A Test Book.epub",
    "author and title were not used for the download filename")
local download = CatalogService.downloadTask(acquisition, download_dir, "", "")()
assert(download.ok, "download failed: " .. tostring(download.error))
assert(lfs.attributes(download.path, "mode") == "file", "downloaded file does not exist")
assert(download.path:match("Alex Author %- A Test Book%.epub$"),
    "downloaded file did not use author and title: " .. tostring(download.path))
local file = assert(io.open(download.path, "rb"))
local contents = file:read("*a")
file:close()
assert(contents == "BokOPDS emulator download fixture.\n", "download contents differ")

local second_download = CatalogService.downloadTask(acquisition, download_dir, "", "")()
assert(second_download.ok and second_download.path:match("Alex Author %- A Test Book%-2%.epub$"),
    "an existing filename was overwritten instead of receiving a collision suffix")
assert(lfs.attributes(download.path, "mode") == "file" and
    lfs.attributes(second_download.path, "mode") == "file",
    "collision-safe downloads did not preserve both files")

local unicode_name = CatalogService.suggestedFilename({
    href = base_url .. "/books/epub",
    type = "application/epub+zip",
    book_author = "Саган Франсуаза",
    book_title = "Здравствуй, грусть",
})
assert(unicode_name == "Саган Франсуаза - Здравствуй, грусть.epub",
    "Unicode author and title were not preserved")
local long_name = CatalogService.suggestedFilename({
    href = base_url .. "/books/epub",
    type = "application/epub+zip",
    book_author = "Author/With:Invalid*Characters?",
    book_title = string.rep("Very long title ", 30),
})
assert(#long_name <= 180 and long_name:match("%.epub$") and
    not long_name:find("[/\\:*?\"<>|]"),
    "long or filesystem-unsafe filename was not safely shortened")

print("reader-shell-service-test: ok")
