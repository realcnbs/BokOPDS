# Device compatibility

BokOPDS uses a pinned KOReader runtime, but its stock-home button also uses
firmware-private Nickel symbols. Runtime recognition does not by itself mean
that the BokOPDS hook is safe on a model or firmware.

| Device | Runtime | Hardware ID | Firmware | BokOPDS state | Last test |
|---|---|---:|---|---|---|
| Kobo Touch (A) | Recognized | 310 | — | Not available | — |
| Kobo Touch (B) | Recognized | 310 | — | Not available | — |
| Kobo Touch (C) | Recognized | 320 | — | Not available | — |
| Kobo Mini | Recognized | — | — | Not available | — |
| Kobo Aura ONE | Recognized | — | — | Not available | — |
| Kobo Aura H2O | Recognized | — | — | Not available | — |
| Kobo Aura HD | Recognized | — | — | Not available | — |
| Kobo Glo | Recognized | — | — | Not available | — |
| Kobo Aura | Recognized | — | — | Not available | — |
| Kobo Aura H2O Edition 2 | Recognized | — | — | Not available | — |
| Kobo Aura H2O Edition 2 (revision 2) | Recognized | 378 | — | Not available | — |
| Kobo Aura Edition 2 | Recognized | — | — | Not available | — |
| Kobo Aura Edition 2 (revision 2) | Recognized | 379 | — | Not available | — |
| Kobo Glo HD | Recognized | — | — | Not available | — |
| Kobo Touch 2.0 | Recognized | — | — | Not available | — |
| Kobo Clara HD | Recognized | — | — | Not available | — |
| Kobo Forma | Recognized | — | — | Not available | — |
| Kobo Libra H2O | Recognized | — | — | Not available | — |
| Kobo Nia | Recognized | — | — | Not available | — |
| Kobo Elipsa | Recognized | — | — | Not available | — |
| Kobo Sage | Recognized | — | — | Not available | — |
| Kobo Libra 2 | Recognized | — | — | Not available | — |
| Kobo Clara 2E | Recognized | — | — | Not available | — |
| Kobo Elipsa 2E | Recognized | 389 | `4.38.23697` | Device tested | 2026-08-07 / 0.5.8 |
| Kobo Libra Colour | Recognized | — | — | Not available | — |
| Kobo Clara BW | Recognized | — | — | Not available | — |
| Kobo Clara Colour | Recognized | — | — | Not available | — |

## State meanings

- **Device tested:** passed the maintainer physical-device checklist.
- **Community tested:** a user reported the exact model, firmware and BokOPDS version working.
- **Untested:** an allowlisted profile exists, but there is no physical-device report yet.
- **Not available:** the runtime knows the model, but no safe BokOPDS menu-hook profile exists.
- **Known issue:** the profile is disabled because a failure is known.

## Help test a device

If your exact combination is marked **Untested**, please [open a compatibility report](https://github.com/realcnbs/BokOPDS/issues/new?template=compatibility-report.yml).
Please include the model, hardware ID, firmware, BokOPDS version and checklist results.
Do not post the device serial number, catalog credentials, or other personal information.

Completely unknown combinations remain inert: the hook does not construct private
firmware widgets and BokOPDS does not appear in the stock menu.

This table is generated from the compatibility data for KOReader `v2026.07.1`.
