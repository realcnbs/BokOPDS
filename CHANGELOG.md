# Changelog

## 0.5.8 - 2026-08-07

- Replaced the retired custom framebuffer UI with a KOReader-based Lua shell.
- Added native home-navigation integration for the tested Kobo firmware.
- Added OPDS 1/2 browsing, search, bookmarks, pagination, language filters,
  single and multi-book downloads, safe filenames and library refresh.
- Added TLS peer and hostname verification, HTTPS-only remote links and
  origin-bound catalog authentication.
- Added bounded feed/cover responses, bounded caches, stale partial cleanup,
  request cancellation and safer device installation checks.
- Separated the bounded feed cache from ordinary settings, capped in-memory
  navigation/image state, and rejected oversized or unrecognized cover files.
- Added hard-crash process containment, a verified source-materials bundle,
  a CycloneDX SBOM and documented third-party dependencies.
- Removed the obsolete standalone C++ app, custom keyboard data and duplicate
  runtime binary from the local package path.
