# Changelog

## Unreleased

## 0.5.9 - 2026-08-07

- Added a generated compatibility catalog covering every Kobo model recognized
  by the pinned runtime and exact firmware-specific NickelHook targets.
- Reworked the stock-home hook into a universal guarded binary which remains
  inert on unknown, disabled, or symbol-incompatible firmware.
- Added persistent first-launch warnings for known but physically untested
  targets and a privacy-safe community compatibility report form.
- Changed release output to the OS-neutral `KoboRoot.tgz`, checksums, and public
  compatibility documents.

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
