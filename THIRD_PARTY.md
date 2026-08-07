# Third-party dependencies

BokOPDS is built with the following open-source projects. Each project keeps
its own license and trademarks.

| Dependency | Version | License | How BokOPDS uses it |
|---|---|---|---|
| [KOReader](https://github.com/koreader/koreader) | `v2026.07.1` | AGPL-3.0 | Screen rendering, touch input, keyboard, networking, sleep, USB handling, and OPDS parsing. |
| [koreader-base](https://github.com/koreader/koreader-base) | `6e4bc81af4e04f78d81677a323a780a71b29702a` | AGPL-3.0 and component licenses | Native libraries used by the reader runtime. |
| [NickelHook](https://github.com/pgaskin/NickelHook) | `bcd90ba94d90d22562fb64ef2920ed3323c1dae5` | MIT | Adds BokOPDS to the standard home navigation. |
| [Lucide](https://lucide.dev/) and Feather-derived icons | Lucide `0.577.0` | ISC and MIT | Navigation and control icons. |
| Mozilla CA certificate data | Included with KOReader `v2026.07.1` | MPL-2.0 | HTTPS certificate validation. |

Exact source versions and checksums are recorded in
[`reader-shell/runtime.lock`](reader-shell/runtime.lock). A machine-readable
component list is available in [`sbom.cdx.json`](sbom.cdx.json).

The reader runtime contains additional libraries under their own licenses.
Anyone redistributing a release package must also follow those licenses and
their source-availability requirements.
