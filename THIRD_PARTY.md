# Third-party dependencies

BokOPDS is an independent project. Third-party projects keep their own
licenses and trademarks.

| Dependency | Version | License | How BokOPDS uses it |
|---|---|---|---|
| [KOReader](https://github.com/koreader/koreader) | `v2026.07.1` | AGPL-3.0 | E-ink rendering, input, keyboard, networking, suspend/USB handling and OPDS parsing. BokOPDS replaces the normal reader UI. |
| [koreader-base](https://github.com/koreader/koreader-base) | `6e4bc81af4e04f78d81677a323a780a71b29702a` | AGPL-3.0 and component licenses | Native libraries used by the KOReader runtime. |
| [NickelHook](https://github.com/pgaskin/NickelHook) | `bcd90ba94d90d22562fb64ef2920ed3323c1dae5` | MIT | Loads the small native extension that adds BokOPDS to the stock home navigation. |
| [Lucide](https://lucide.dev/) and Feather-derived icons | Lucide `0.577.0` | ISC and MIT | Navigation and control icons. |
| Mozilla CA certificate data | Included with KOReader `v2026.07.1` | MPL-2.0 | HTTPS certificate validation. |

Exact runtime downloads, source archives and checksums are pinned in
[`reader-shell/runtime.lock`](reader-shell/runtime.lock). The machine-readable
component list is in [`sbom.cdx.json`](sbom.cdx.json).

The KOReader runtime includes additional libraries under their respective
licenses. Generated device packages are intended for local testing; review all
upstream license and corresponding-source requirements before redistributing a
binary package.
