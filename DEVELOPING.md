# Developing BokOPDS

This guide is for people who want to run the emulator, change the code, test a
device, or build a release. If you only want to install BokOPDS, start with the
[README](README.md).

## Project map

- `reader-shell/overlay/frontend/apps/bokopds` contains the Lua interface and
  OPDS client.
- `reader-shell` assembles the e-reader runtime used by the app.
- `device-hook` contains the small native integration that adds BokOPDS to the
  standard home navigation and asks the built-in library to scan downloads.
- `scripts` contains emulator, package, verification, and device helpers.
- `compatibility` contains the device and firmware data used by release builds.

For a deeper explanation, see [Architecture](docs/ARCHITECTURE.md).

## Requirements

Release builds need Docker or Podman, curl, unzip, GNU tar, gzip, `file`, and
`readelf`. The desktop emulator also needs these packages on Debian or Ubuntu:

```sh
sudo apt-get install curl unzip xz-utils python3 openssl xvfb imagemagick \
  libx11-6 libxext6 libxrender1 libxcb1 libgl1
```

Fetch the pinned source dependencies after cloning:

```sh
git submodule update --init --recursive
```

## Run the emulator

```sh
./scripts/run-emulator.sh
```

Run the automated emulator checks with:

```sh
./scripts/test-reader-shell-emulator.sh
```

The suite covers OPDS 1 and OPDS 2 parsing, navigation, search, authentication,
downloads, cancellation, TLS errors, different screen sizes, and screenshot
smoke tests.

To check the public catalogs listed by the bundled runtime:

```sh
./scripts/test-live-catalogs.sh
```

This command depends on external services. An unavailable catalog is reported
separately from a response that BokOPDS cannot parse. Set
`BOKOPDS_LIVE_STRICT=1` when an unavailable service should fail the run.

## Build a release

Run the emulator suite before building:

```sh
./scripts/test-reader-shell-emulator.sh
./scripts/build-release.sh
```

The release files are written to `dist/`:

- `KoboRoot.tgz`
- `SHA256SUMS`
- `COMPATIBILITY.md`
- `compatibility.json`

Verify the result with:

```sh
./scripts/verify-package.sh dist/KoboRoot.tgz
(cd dist && sha256sum -c SHA256SUMS)
```

Runtime downloads and checksums are pinned in `reader-shell/runtime.lock`.

## Test a local package on a reader

Read [Device testing](docs/DEVICE_TESTING.md) before testing new code on real
hardware.

The installer helper performs safety checks and keeps a local recovery backup:

```sh
BOKOPDS_INSTALL_DRY_RUN=1 ./scripts/install-to-reader.sh \
  dist/KoboRoot.tgz /path/to/KOBOeReader

./scripts/install-to-reader.sh \
  dist/KoboRoot.tgz /path/to/KOBOeReader
```

Never bypass the pending-update check and never overwrite an existing
`.kobo/KoboRoot.tgz`.

## Uninstall a development build

```sh
./scripts/prepare-uninstall.sh /path/to/KOBOeReader
```

Safely eject and restart the reader. Downloaded books remain in the configured
books folder.

## Compatibility data

Device support is intentionally explicit. After changing files under
`compatibility/`, regenerate the public table and native profiles:

```sh
./scripts/generate-compatibility.py
```

Physical test results belong in `compatibility/reports.json`. Never store a
serial number, catalog address, credential, or other personal information in a
report.

## Security and dependencies

[Architecture](docs/ARCHITECTURE.md) describes the network, storage, process,
and package boundaries. [THIRD_PARTY.md](THIRD_PARTY.md) lists the upstream
projects used by BokOPDS; `sbom.cdx.json` contains the machine-readable
component list.
