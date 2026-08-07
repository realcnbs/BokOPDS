# Install BokOPDS

## Before you start

1. Find your exact model and firmware in [Supported devices](../COMPATIBILITY.md).
   Install only when the combination is marked **Device tested** or
   **Community tested**.
2. Back up books and settings that matter to you.
3. Charge the reader and connect it to Wi-Fi from the standard Kobo interface.

Installing `KoboRoot.tgz` changes system files. Do not disconnect or power off
the reader while it is applying an update.

## Download

Open the [latest release](https://github.com/realcnbs/BokOPDS/releases/latest)
and download:

- `KoboRoot.tgz`
- `SHA256SUMS` if you want to verify the download

Optional checksum commands:

```sh
# Linux
sha256sum -c SHA256SUMS

# macOS
shasum -a 256 KoboRoot.tgz

# Windows Command Prompt
certutil -hashfile KoboRoot.tgz SHA256
```

Compare the macOS or Windows result with the value in `SHA256SUMS`.

## Copy the update

1. Connect the reader by USB and choose **Connect** on its screen.
2. Open the reader drive, then open the `.kobo` folder.
3. Check whether `.kobo/KoboRoot.tgz` already exists.

> **Never overwrite a pending stock update.** If `KoboRoot.tgz` is already in
> `.kobo`, stop. Safely eject the reader and let it install that update before
> reconnecting and continuing.

4. Copy the downloaded `KoboRoot.tgz` into `.kobo`.
5. Safely eject the reader.

The reader should install the update and restart. On a supported device,
**BokOPDS** will then appear in the standard home navigation.

## If BokOPDS does not appear

- Confirm that the model and firmware match an entry marked **Device tested**
  or **Community tested**.
- Restart the reader once more.
- If the exact combination is supported, open a
  [GitHub issue](https://github.com/realcnbs/BokOPDS/issues). Include the model,
  firmware, and BokOPDS version, but not the serial number or catalog details.

Do not delete or replace the built-in library database while troubleshooting.

## Uninstall

The current uninstall helper is run from a cloned copy of the project:

```sh
./scripts/prepare-uninstall.sh /path/to/KOBOeReader
```

Safely eject and restart after the helper finishes. BokOPDS is removed;
downloaded books stay on the reader.

Developers building or testing local packages should use
[DEVELOPING.md](../DEVELOPING.md).
