# Test BokOPDS on a reader

Use this checklist before reporting a new model or firmware as compatible.
Testing changes system files, so use a reader you can recover and back up
important data first.

## Check the package

```sh
./scripts/test-reader-shell-emulator.sh
./tests/package_layout_test.sh
./scripts/build-release.sh
./scripts/verify-package.sh dist/KoboRoot.tgz
```

These checks cover catalog parsing, HTTPS and authentication failures,
downloads, cancellation, navigation, different screen sizes, worker cleanup,
package contents, and the single-instance launcher.

## Test on the reader

Write down the model, firmware, BokOPDS version, archive checksum, and available
storage. Never record the serial number or catalog credentials.

1. Start with a charged reader and no pending stock update.
2. Install BokOPDS and confirm that one BokOPDS item appears in the standard
   home navigation.
3. Open, close, reopen, and force-stop BokOPDS once.
4. Add a public HTTPS catalog and, if available, a Basic-auth catalog.
5. Confirm that an invalid or untrusted HTTPS certificate shows an error.
6. Browse several levels, save a bookmark, reopen it, and try **Up**, **Back**,
   and **Home**.
7. Search in English and Russian and switch the keyboard layout.
8. Download one book, then several books, using both the default folder and a
   new folder.
9. Cancel a large download and check that no `.part` file remains.
10. Close BokOPDS and confirm that the downloaded books appear in the built-in
    library.
11. Leave the reader idle for at least 20 minutes, then check sleep, wake, and
    frontlight behavior.
12. Test a USB connection while idle and after cancelling a request.
13. Uninstall BokOPDS and confirm that the standard interface and downloaded
    books remain.

## Report the result

Add maintainer results to `compatibility/reports.json`. Community testers can
use the [compatibility report form](https://github.com/realcnbs/BokOPDS/issues/new?template=compatibility-report.yml).

- **Device tested** means the maintainer completed this checklist.
- **Community tested** means a user completed the checklist and the report was
  reviewed.
- **Untested** means support exists but no complete device report is available.
- **Known issue** means a reported failure prevents support.

Before sharing logs or photos, remove serial numbers, private catalog addresses,
credentials, book-library details, and other personal information.
