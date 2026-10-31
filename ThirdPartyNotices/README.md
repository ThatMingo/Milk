# Milk dependency and managed-runtime notices

Milk no longer bundles a coding-agent executable or its runtime assets. These notices cover Milk dependencies plus the approved downloadable Pi 1.4.0 runtime and its dependencies. PiAdapter remains compiled into Milk; MilkPiIntegration.ts is a separate Milk-authored extension using public hooks. The artifact provenance below and the current inventory distinguish downloadable runtimes from Milk.app resources.

- `SwiftTerm-LICENSE.txt`: native terminal emulator, SwiftTerm 1.99.2 / `a183c15b52858530a17de57dcc72b93eeebc9857`, MIT; source https://github.com/migueldeicaza/SwiftTerm/tree/v1.99.2. SwiftPM portable PNG and command-line tooling dependencies are not linked into the macOS Milk target.
- `Pi-LICENSE`: Pi MIT license and copyright.
- `Pi-Dependencies.txt`: copyright/license/notice materials from all 119 unique packages in the release's verified npm install lock. Some extras are included conservatively.
- `pi-install-package-lock.json`: upstream pinned dependency/provenance inventory.
- `Bun-LICENSE.md`: Bun's upstream licensing, linked libraries, and JavaScriptCore relinking guidance.
- `Runtime-Libraries.txt`: native library copyright/license materials, including JavaScriptCore LGPL terms, Node's comprehensive third-party notices, and QuickJS.
- `modelcontextprotocol-typescript-sdk.txt`: upstream Pi's additional MCP attribution.
- `ripgrep/`, `fd/`: the tools' copyright and license texts.
- Local-only `pi-1.4.0-source.tar.gz` (not committed or packaged): original official Pi source release, SHA256 `12b14a5d812e049a0b22449e2589ee7647c31f00f93bb97d8d25aff0e71920da`.

Sources and reconstruction:

- Pi source/binary release: https://github.com/earendil-works/pi/releases/tag/v1.4.0
- Bun 1.3.14 source/build instructions: https://github.com/oven-sh/bun/tree/bun-v1.3.14
- Bun's patched WebKit/JavaScriptCore source: https://github.com/oven-sh/WebKit (use the WebKit revision recorded by Bun 1.3.14's build configuration).
- Bun license/relink instructions: https://github.com/oven-sh/bun/blob/bun-v1.3.14/LICENSE.md
- Pi source includes `scripts/build-binaries.sh`, its dependency locks, and bundled model data. Build a replacement standalone Pi with a modified Bun/JavaScriptCore and select it in Milk's external-runtime configuration. Milk does not restrict replacement runtimes.
- Native dependency versions and source revisions are specified by Bun's build configuration. The notice collector URLs identify the upstream copyright/license texts; they are not a native dependency version lock.

The Milk build copies allowlisted notice metadata (excluding the ignored full original source archive) into the app. Optional Pi integration-test artifacts are bootstrapped separately; the initial SwiftPM terminal dependency resolution needs network access, and cached builds can run offline. Notice collectors run only during deliberate runtime maintenance. Distribution builds must preserve corresponding source/relink availability and all notices. The clean development app and native extension SDK retain their signing flow; downloaded agent execution and release signing/notarization remain acceptance work.

## Public-source and binary distribution boundary

The prospective source repository includes Milk/SDK/example source and notice texts. The optional test-fixture bootstrap downloads runtime binaries from official versioned releases and checks SHA-256; production managed installs use the compiled pinned catalog and user Application Support storage. `Runtime/PiRuntime/runtime-manifest.json` pins Pi 1.4.0, rg 15.2.0, fd 10.5.0 and native/photon resource digests. The optional Doom example is excluded from bootstrap/package; the full original local runtime/source archive remains ignored reference material, not redistributed source.

Bun/native binary redistribution closure remains unresolved. The versioned [Bun license](https://github.com/oven-sh/bun/blob/bun-v1.3.14/LICENSE.md) describes static JavaScriptCore linkage and relinking requirements. Exact matching patched WebKit/native source and complete reconstruction/relink materials for the standalone artifact have not been established. Notice collection using moving upstream URLs is not a version-locked SBOM. Downloading rather than committing a binary does not establish permission to distribute managed artifacts or the final app. These are runtime/app release requirements, not evidence of a binary in the public source snapshot. See [the source-publication audit](../docs/PRE_GITHUB_AUDIT.md).

Milk original contributions are MIT under the root LICENSE; this does not relicense third-party material. No new third-party dependencies were introduced by Phase 7, its example, or slash commands. SwiftTerm is MIT; Pi is MIT; photon is Apache-2.0; ripgrep is MIT/Unlicense; fd is MIT/Apache-2.0. Preserve the actual bundled notice texts.

See [INVENTORY.md](INVENTORY.md) for committed/downloaded/packaged distinctions and exact Swift package revisions.
