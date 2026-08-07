# BokOPDS

BokOPDS is a focused OPDS catalog client for Kobo e-readers. It adds a BokOPDS
item to the stock home navigation and opens directly into catalog browsing.
There is no separate KOReader or NickelMenu installation to manage.

The interface is intentionally limited to OPDS: browse and search catalogs,
bookmark catalog locations, filter by preferred publication language, inspect
book metadata, and download one or several books. Completed downloads request
a stock-library rescan.

> **Compatibility:** the installer currently accepts only the
> Kobo Elipsa 2E hardware family ID `389` running firmware `4.38.23697`. The
> home-navigation hook uses private firmware symbols. Do not bypass this check
> on another model or firmware.

## Highlights

- OPDS 1 Atom and OPDS 2 JSON catalogs
- Catalog search, pagination and full bookmark paths
- Single and multi-book selection across pages
- EPUB, PDF, FB2, MOBI, HTML and text acquisitions
- Unicode-safe `Author - Title.ext` filenames
- Russian and English keyboard layouts through the bundled reader runtime
- E-ink-specific layout, partial input refreshes, autosuspend and USB handling
- Verified HTTPS, hostname checking, origin-bound Basic authentication,
  cancellable requests and bounded feed/cover responses
- Main-library refresh request after downloads

## Install a locally built archive

Installing a system archive modifies software on the reader. Back up important
books and settings first. Charge the reader and do not interrupt an update.

1. Build `bokopds-local-device-<version>.tgz` and its SHA-256 file from a clean
   committed checkout as described below.
2. Connect the reader by USB and identify its mounted storage root. That root
   contains `.kobo/version`.
3. Verify and stage the archive from this source tree:

   ```sh
   (cd dist && sha256sum -c bokopds-local-device-<version>.tgz.sha256)
   ./scripts/install-to-reader.sh \
     dist/bokopds-local-device-<version>.tgz /path/to/KOBOeReader
   ```

4. Safely eject. The reader installs the update and restarts.

The installer is model/firmware gated, refuses an existing pending update,
checks compressed and unpacked space, verifies package layout/ABI, and saves a
private local recovery backup before writing `.kobo/KoboRoot.tgz`.

To uninstall, connect by USB and run:

```sh
./scripts/prepare-uninstall.sh /path/to/KOBOeReader
```

Safely eject and restart. NickelHook processes the uninstall marker and removes
the hook and application directory. Downloaded books are not removed.

More detail is in [device installation](docs/DEVICE_INSTALLATION.md) and
[device testing](docs/DEVICE_TESTING.md).

## Desktop emulator

The emulator tests function and appearance without a physical reader. On
Debian/Ubuntu, install:

```sh
sudo apt-get install curl unzip xz-utils python3 openssl xvfb imagemagick \
  libx11-6 libxext6 libxrender1 libxcb1 libgl1
```

Then run:

```sh
./scripts/run-emulator.sh
./scripts/test-reader-shell-emulator.sh
```

The test suite downloads the pinned desktop runtime, exercises OPDS parsing,
TLS trust and hostname failures, cross-origin authentication, downloads,
cancellation, responsive layouts and screenshot smoke tests. Device behavior
which depends on the stock UI still requires the exact supported reader.

## Build a local device package

Requirements: Docker or Podman, curl, unzip, GNU tar, gzip, `file`, `readelf`,
and the emulator test dependencies.

```sh
git submodule update --init --recursive
./scripts/test-reader-shell-emulator.sh
./scripts/build-release.sh
```

The device archive, source-materials bundle and checksums are written to
`dist/`. The build downloads only
archives pinned with SHA-256 in `reader-shell/runtime.lock`. Set
`SOURCE_DATE_EPOCH` to reproduce archive metadata; the release helper derives
it from Git. Reproducible builds require a clean committed tree and record that
exact commit in the installed `SOURCE_REVISION` file. Compilation and packaging run
from a detached immutable worktree, so concurrent edits cannot enter an archive
under the wrong revision.

## Architecture

BokOPDS has three active parts:

1. A Lua application shell in `reader-shell/overlay/frontend/apps/bokopds`.
2. A pinned, trimmed KOReader runtime providing mature e-ink rendering,
   keyboard, device/event, networking, suspend and USB infrastructure.
3. A small C++ NickelHook extension in `device-hook` which adds the stock-home
   navigation item and requests a library scan after the app exits.

The retired standalone C++ framebuffer application is not part of this source
tree or binary package. See [architecture](docs/ARCHITECTURE.md).

## Third-party code and licenses

BokOPDS uses KOReader and koreader-base for its e-ink runtime, NickelHook for
stock-home integration, Lucide/Feather-derived icons for controls, and Mozilla
CA data for HTTPS. [THIRD_PARTY.md](THIRD_PARTY.md) lists these dependencies,
their versions, licenses and purpose. Source URLs and checksums are pinned in
`reader-shell/runtime.lock`.

The upstream runtime's unlicensed `ffi/__gc.lua` and `lj-wpaclient` files are
explicitly removed. Configure Wi-Fi in the stock Kobo interface before opening
BokOPDS; the app detects and uses the existing connection.

## Project status and license

This is an early community source release with one deliberately narrow tested
device target. It is not affiliated with or endorsed by Rakuten Kobo, KOReader,
or the OPDS specification maintainers.

Generated device packages are currently intended for local testing. Review the
licenses and source-distribution requirements of all bundled runtime components
before publishing a binary package.

BokOPDS source is licensed under `AGPL-3.0-or-later`; see [LICENSE](LICENSE).
Third-party components keep their own licenses.
