# Package and device testing

## Automated package gate

```sh
./scripts/test-reader-shell-emulator.sh
./tests/package_layout_test.sh
./scripts/build-release.sh
./scripts/verify-package.sh dist/KoboRoot.tgz
```

The emulator gate covers OPDS 1/2 parsing, invalid JSON structures, trusted and
rejected TLS certificates, cross-origin credentials, downloads and collision
filenames, cancellation, navigation state, responsive screenshots and busy-view
coverage. Package verification walks all ELF files in the real runtime.
The gate also kills a worker parent with `SIGKILL` and verifies that the worker
cannot outlive it. The package contract separately kills the launcher and
verifies that its live runtime still owns the single-instance lock, then checks
stale-lock recovery after the runtime exits.

## Physical-reader checklist

Record model, hardware ID, firmware, archive SHA-256 and free storage.

1. Install from a fully charged reader with no pending stock update.
2. Confirm exactly one BokOPDS home-navigation item.
3. Launch, exit, relaunch and force-stop once; confirm stale-lock recovery.
4. Add public and Basic-auth HTTPS catalogs.
5. Confirm invalid-host or untrusted certificates fail visibly.
6. Browse deep catalog paths, bookmark, reopen, go Up, Back and Home.
7. Search in English and Russian; switch keyboard layout.
8. Download one book and several books into both configured and new folders.
9. Cancel a large download; confirm no `.part` remains.
10. Exit and confirm the books appear in the stock library after its rescan.
11. Suspend for at least 20 minutes and verify frontlight/power behavior.
12. Connect USB during idle and after cancelling a request; verify clean USBMS.
13. Uninstall and confirm the stock UI and downloaded books remain intact.

Record the result in `compatibility/reports.json`. Maintainer passes become
**Device tested**; reviewed user passes become **Community tested**. An enabled
profile without a physical report remains **Untested**. A failure disables the
target and becomes **Known issue**. Never record a device serial number or
catalog credentials.
