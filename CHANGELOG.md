# Changelog

## Unreleased

## 0.5.10 - 2026-10-14

- Fixed release archives changing the reader's root directory permissions to
  `0700`, which could prevent system services such as Wi-Fi from working.
- Added package verification that rejects an unsafe root-directory mode.

## 0.5.9 - 2026-08-07

- Added a public device and firmware compatibility table.
- Made the home-screen integration start only on explicitly supported model and
  firmware combinations.
- Added a first-launch warning for supported combinations that still need a
  complete device test.
- Simplified release downloads to `KoboRoot.tgz`, checksums, and compatibility
  information.

## 0.5.8 - 2026-08-07

- Rebuilt the interface on the KOReader runtime.
- Added BokOPDS to the standard home navigation on the tested firmware.
- Added OPDS 1/2 browsing, search, bookmarks, pagination, language filters,
  single and multi-book downloads, safe filenames and library refresh.
- Added HTTPS certificate and host-name checks and kept catalog passwords bound
  to their catalog address.
- Added response and cache limits, partial-download cleanup, request
  cancellation, and safer installation checks.
- Added worker cleanup after crashes, a component inventory, and third-party
  license documentation.
- Removed the obsolete standalone C++ app, custom keyboard data and duplicate
  runtime binary from the local package path.
