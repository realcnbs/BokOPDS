# Architecture

This document explains how BokOPDS is put together. For build commands, see
[DEVELOPING.md](../DEVELOPING.md).

## The three parts

### BokOPDS application

The Lua application lives in
`reader-shell/overlay/frontend/apps/bokopds`.

- `shell.lua` draws the interface, handles navigation, and saves user settings.
- `catalog_service.lua` reads OPDS feeds, covers, and download links.
- `secure_http.lua` handles HTTPS, authentication, redirects, and response
  limits.
- `subprocess_guard.lua` stops network workers if the main app crashes.

### Reader runtime

BokOPDS uses a trimmed, pinned KOReader runtime for text rendering, fonts,
keyboard input, touch events, networking, sleep, and USB handling. The version
and download checksums are recorded in `reader-shell/runtime.lock`.

`device-runtime/launch.sh` starts one copy of BokOPDS, keeps its logs and state
in the application directory, and sets `/mnt/onboard/BokOPDS` as the default
books folder.

### Home-screen integration

`device-hook` is a small C++/Qt extension loaded by NickelHook. It adds the
BokOPDS item to the standard home navigation, starts the app, and asks the
built-in library to scan newly downloaded books after BokOPDS closes.

The extension is enabled only for model and firmware combinations listed in
the compatibility data. The technical profile includes the symbols and class
layout required by that firmware. If the profile does not match, the extension
does nothing.

## What happens when BokOPDS opens

1. The home-screen extension checks the reader and firmware.
2. The launcher prevents a second BokOPDS process from starting.
3. The Lua application loads catalogs, bookmarks, preferences, and cache data.
4. Network work runs in child processes that can be cancelled safely.
5. Completed downloads are recorded for a later library scan.
6. After BokOPDS closes, the home-screen extension asks the built-in library to
   scan those files.

## Network safety

- Remote catalog and download addresses must use HTTPS. Plain HTTP is allowed
  only for local emulator tests.
- Basic-auth credentials are sent only to the catalog origin they belong to.
  They are checked again after every redirect.
- The included Mozilla certificate bundle validates server certificates, and
  BokOPDS also checks the requested host name.
- Feed and cover responses have size limits.
- Downloads cannot escape the configured books directory.

## Saved data

BokOPDS stores catalogs, Basic-auth credentials, bookmarks, language choices,
and cache records in its application directory. These files are not encrypted.
Anyone who can read the device storage over USB can also read them.

Deleting a catalog removes its bookmarks and feed cache. **Clear cache** removes
saved feed and cover data.

Downloads are first written to a `.part` file. A completed file is renamed into
place in one step. Cancelled and abandoned partial downloads are cleaned up.

## Release package

`scripts/assemble-reader-shell-device.sh` combines the pinned runtime with the
BokOPDS files. `scripts/build-release.sh` builds the home-screen extension,
checks the package, and writes release checksums.

The resulting archive contains the BokOPDS application directory and the
NickelHook library needed to start it from the standard interface.
