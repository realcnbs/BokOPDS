# Device installation

## Compatibility

Use [the generated compatibility table](../COMPATIBILITY.md). The package is
universal, but the navigation hook activates only for an exact allowlisted
hardware/firmware target. Runtime support and matching symbol names do not
prove a compatible private class layout. Unknown combinations remain inert.

## Build

```sh
git submodule update --init --recursive
./scripts/build-release.sh
```

The helper uses the pinned KOReader runtime and NickelHook submodule. It writes
`KoboRoot.tgz`, `SHA256SUMS`, and the compatibility documents to `dist/`.

Configure Wi-Fi in the stock Kobo interface before opening BokOPDS. The package
intentionally excludes the upstream Wi-Fi configuration client because its
repository does not state redistribution terms.

## Verify without writing

```sh
./scripts/verify-package.sh dist/KoboRoot.tgz
BOKOPDS_INSTALL_DRY_RUN=1 ./scripts/install-to-reader.sh \
  dist/KoboRoot.tgz /path/to/KOBOeReader
```

The dry run checks the mounted reader identity, firmware, pending-update state,
archive layout/ABI, and available space. It writes nothing.

## Stage installation

```sh
./scripts/install-to-reader.sh \
  dist/KoboRoot.tgz /path/to/KOBOeReader
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
