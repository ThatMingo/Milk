# Publication inventory

This inventory distinguishes the public source snapshot, optional upstream test
fixtures, Milk-managed downloads and the clean app recipe. “Source snapshot”
describes prospective inclusion; this working folder has no Git metadata.

| Component | Pin / provenance | License / notice | Public source snapshot | Clean Milk.app |
| --- | --- | --- | --- | --- |
| Milk / MilkExtensionKit / host / example | 0.7.0, API 1, original source | Root MIT LICENSE | Source, tests, scripts | Compiled host and SDK; example excluded |
| Pi | 1.4.0 official release; hashes in runtime manifest and catalog | MIT, Pi-LICENSE; dependencies separately licensed | Manifest, catalog and notices; no executable | No executable or upstream runtime assets |
| Bun | 1.3.14 within downloaded Pi standalone | MIT plus native dependencies, Bun-LICENSE.md and Runtime-Libraries.txt | Notices only | No Bun runtime |
| JavaScriptCore / native runtime libraries | Exact standalone reconstruction not established | LGPL and other licenses in native notices | Notices; no native implementation or binaries | No downloaded agent native libraries |
| Pi npm dependencies | 119 name/version pairs from pi-install-package-lock.json | Individual texts in Pi-Dependencies.txt | Lock and notices | Notice metadata only |
| photon | @silvia-odwyer/photon-node 0.3.4; wasm digest in runtime manifest | Apache-2.0, Pi-Dependencies.txt | Notice and hash | No wasm |
| Darwin native module | Pi 1.4.0 native/darwin artifact; .node digest in runtime manifest | Native provenance review remains open; notices retained | Notice and hash | No .node |
| ripgrep / fd | 15.2.0 / 10.5.0 official releases; archive/executable pins | MIT/Unlicense / MIT/Apache-2.0 | Notices and pins | No search executables |
| SwiftTerm | 1.99.2, a183c15b52858530a17de57dcc72b93eeebc9857 | MIT, SwiftTerm-LICENSE.txt | Package pin and notice; no checkout | Linked native terminal |
| swift-argument-parser | 1.8.2, 6a52f3251125d74daf04fcbd5e6f08a75d074382 | Apache-2.0 with Swift runtime exception; upstream LICENSE.txt | Package.resolved pin; no checkout | Not linked in macOS app target |
| swift-png | 4.5.2, 2d17c6c51c098628574c0383f1119892655a73a2 | Apache-2.0; upstream LICENSE | Package.resolved pin; no checkout | Not linked in macOS app target |
| h | 1.0.1, aa3626829160917d4378330617971977cbd78f5b | Apache-2.0; upstream LICENSE | Package.resolved pin; no checkout | Not linked in macOS app target |
| macOS libarchive | System library linked by MilkArchive; SDK 26 ABI declarations | System implementation; libarchive text also retained in Runtime-Libraries.txt | Milk-owned C wrapper and ABI declarations; no library implementation | System dynamic dependency, not a copied dylib |
| Apple frameworks / system libraries | macOS 26 SDK (AppKit, SwiftUI, WebKit, Security, PTY and platform services) | Platform SDK/runtime terms | Imports and Milk source only | System dependencies; no SDK vendoring |
| Optional Doom reference | Local private reference only | Not assessed for redistribution | Excluded | Excluded |
| Original Pi source archive | SHA-256 12b14a5d812e049a0b22449e2589ee7647c31f00f93bb97d8d25aff0e71920da | Mixed upstream source/examples | Ignored local reference only | Excluded |

Swift package locations and complete revisions are in `Package.resolved`.
The source snapshot does not vendor SwiftPM checkouts. macOS dependency conditions
were inspected in the existing SwiftTerm checkout; no resolution or upgrade ran.
`scripts/stage-app-resources.py` allowlists notice metadata and Milk's integration;
`scripts/build.sh` adds the Milk-owned compiled SDK. Neither copies PiRuntime.

The bootstrap creates optional test fixtures under ignored `Runtime/PiRuntime/`;
production managed installation downloads into user Application Support storage,
not the source repository or app bundle. Both use pinned official artifacts.
Bun/native matching-source, reconstruction, relinking and distribution review
remains unresolved for downloaded runtimes. The notices and checksums do not
establish release clearance. See [final acceptance](../docs/AGENT_PHASE_FINAL_ACCEPTANCE.md)
and the [source-publication audit](../docs/PRE_GITHUB_AUDIT.md).
