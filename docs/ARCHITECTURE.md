# Architecture

## Runtime layers

`device-hook` is a small C++/Qt NickelHook module loaded by the stock interface.
Generated data gives it an allowlist of exact hardware/firmware targets and
their private `MainNavButton` ABI. All listed symbols are resolved optionally.
The hook reads `.kobo/version`, selects one exact enabled target, verifies every
required symbol, and only then constructs the menu item. Unknown combinations
remain inert. The hook launches `device-runtime/launch.sh` and calls the stock
library workflow when a completed-download marker is pending.

`device-runtime/launch.sh` owns the single-instance lock and persistent runtime
directory. It launches the bundled reader runtime, preserves logs, constrains
the default publication directory to `/mnt/onboard/BokOPDS`, provides the CA
bundle path, and keeps the lock until the runtime exits.

`reader-shell/overlay` is the BokOPDS application. `shell.lua` owns navigation,
rendering and persisted user state. `catalog_service.lua` parses OPDS and
performs feed, cover and acquisition tasks. `secure_http.lua` validates URLs,
authenticates TLS peers and hostnames, binds credentials to the configured
catalog origin, handles redirects explicitly, and enforces response limits.
`subprocess_guard.lua` makes network workers die with a crashed parent.

The rest of the device tree is assembled from the exact KOReader release in
`reader-shell/runtime.lock`. BokOPDS uses its renderer, fonts, shaping,
keyboard, event loop, network manager, task wrapper, suspend and USB services.

## Security boundaries

- Remote traffic must use HTTPS. Plain HTTP is accepted only on loopback for
  deterministic emulator tests.
- Basic credentials are sent only to the configured scheme/host/effective-port
  origin and are recomputed after each redirect.
- The packaged Mozilla CA bundle validates the chain; BokOPDS separately checks
  DNS/IP subject alternative names.
- Device downloads are constrained under `BOKOPDS_LIBRARY_ROOT` and hidden or
  parent-directory paths are rejected.
- Feed and decoded/disk cover caches are bounded and scoped by catalog account.
- Packages reject traversal, links, special files, obsolete payloads and
  non-ARM runtime ELFs.
- The firmware hook activates only for an exact generated target because it
  uses a private C++ ABI. Runtime model recognition alone is insufficient.

## Persistence

Catalogs, Basic-auth credentials, bookmarks, language preferences and bounded
feed-cache records are stored in the application state directory on the
reader. They are not encrypted at rest. Anyone with USB/storage access can read
them. Deleting a catalog purges its feed cache and bookmarks; Clear cache
removes feed and cover data.

Downloads use a `.part` file and atomic rename. Cancellation and startup sweep
BokOPDS-owned partial files. A successful download appends its path to
`library-refresh.pending`; the hook consumes that marker only after the runtime
lock disappears.

## Package build

`assemble-reader-shell-device.sh` verifies and overlays the pinned runtime.
`build-release.sh` builds the hook and runtime package, verifies the archive,
and writes SHA-256 checksums. The archive is rooted only at the application
directory and the one NickelHook library path.
