# Device installation

## Supported target

- Kobo Elipsa 2E hardware family ID `389`
- firmware `4.38.23697`

This restriction is intentional. The navigation hook constructs a private
firmware widget. Matching symbol names do not prove a compatible class layout.

## Build

```sh
git submodule update --init --recursive
./scripts/build-release.sh
```

The build helper uses the pinned KOReader binary/runtime sources and the
NickelHook submodule. It builds the hook with
the digest-pinned `ghcr.io/pgaskin/nickeltc:1.0` image, then writes the archive
and SHA-256 file to `dist/`, along with a source-materials bundle and its
checksum. Generated binary archives are for local installation and testing;
see `THIRD_PARTY.md` before any redistribution.

The build refuses an uncommitted or dirty tree and embeds the exact BokOPDS
source commit in `SOURCE_REVISION`.

Configure Wi-Fi in the stock Kobo interface before opening BokOPDS. The package
intentionally excludes the upstream Wi-Fi configuration client because its
repository does not state redistribution terms.

## Verify without writing

```sh
./scripts/verify-package.sh dist/bokopds-local-device-0.5.8.tgz
BOKOPDS_INSTALL_DRY_RUN=1 ./scripts/install-to-reader.sh \
  dist/bokopds-local-device-0.5.8.tgz /path/to/KOBOeReader
```

The dry run checks the mounted reader identity, firmware, pending-update state,
archive layout/ABI, and available space. It writes nothing.

## Stage installation

```sh
./scripts/install-to-reader.sh \
  dist/bokopds-local-device-0.5.8.tgz /path/to/KOBOeReader
```

The script creates a mode-`0700` recovery directory containing checksums and
copies of relevant existing configuration/database/application files. It then
copies and byte-verifies the archive as `.kobo/KoboRoot.tgz`. Safely eject; the
stock updater applies it and restarts.

Do not manually overwrite an existing `.kobo/KoboRoot.tgz` or
`.kobo/KoboRoot.tgz.bokopds-part`.

## Recovery and uninstall

If the stock UI fails after installation, use the NickelHook failsafe behavior
documented by NickelHook and restore from the installer backup. Do not delete
the stock database blindly.

For normal uninstall:

```sh
./scripts/prepare-uninstall.sh /path/to/KOBOeReader
```

Safely eject and restart. Downloaded books remain in the configured publication
folder.
