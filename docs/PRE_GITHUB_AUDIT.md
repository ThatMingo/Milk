# GitHub Publication Phase 1 — repository audit and sanitization

Date: 2026-10-31. Scope: the current local Milk source tree, after the completed
agent refactor. Technical baseline: [Agent final acceptance](AGENT_PHASE_FINAL_ACCEPTANCE.md),
including the previously recorded **156/156** regression pass. Those tests were
not rerun for this audit.

## 1. Overall readiness

**READY — prospective public source snapshot.** No confirmed secret, private user
state, downloaded runtime binary or generated build product was found in the
prospective inclusion set after cleanup. This verdict does not authorize a push
or establish downloadable Milk.app release readiness.

This working folder has **no `.git` metadata**, and `git status`, branch and tracked
file inspection therefore report “not a git repository.” Actual tracked, staged,
untracked and ignored Git status, largest tracked files and past commits cannot
be established. No history was available to scan. “Prospective” below means files
that Git would offer for addition under the repository's ignore rules, using an
isolated temporary Git directory outside this project. No repository was
initialized here, and no source was staged or committed.

## 2. Prospective public size

- Files: **169** regular files, with no prospective symlinks.
- Uncompressed file-content size, including this report: **2,697,471** bytes
  (**2.5725** MiB). Directory entries, filesystem allocation and Git compression
  are excluded.
- Before this phase: 168 prospective files. No previously visible source file was
  dropped; this report is the one new public file.
- Initial full filesystem inventory: 7,566 regular files, 1,464,000,853 bytes
  (about 1.46 GB), plus three ignored symlinks. This includes local dependencies,
  private material and generated outputs; it is not the public repository size.

## 3. Excluded local material, preserved on disk

| Path or category | Initial local content | Publication treatment |
| --- | ---: | --- |
| `.build/` | 6,585 files; 1,206,262,947 bytes | SwiftPM checkouts, repositories, caches, executables, objects, indexes and test products ignored |
| `output/` | 564 files; 46,149,599 bytes | Milk.app, app staging, signing records, logs, screenshots, verification and test evidence ignored |
| `Runtime/PiRuntime/` | Runtime tree including a 77,151,074-byte Pi executable | Everything ignored except the source `runtime-manifest.json` pin |
| `Milk (preRefactor).zip` | 102,769,081 bytes | Old source/build archive ignored by `*.zip`; contains personal path references |
| `ThirdPartyNotices/pi-1.4.0-source.tar.gz` | 8,180,850 bytes | Exact local upstream source archive ignored; not an app resource |
| `docs/history/`, `docs/validation/`, `docs/internal/`, `docs/private-reference/` | Historical instructions, prior audits, private design HTML/PDF and Doom reference | Existing scoped local archive exclusions retained |
| `Examples/Extensions/*/build/`, `*.milkext/` | Compiled example bundle and signature | Ignored; example source/build script/manifest retained |
| `scripts/__pycache__/`, `.DS_Store` | Python bytecode and macOS metadata | Ignored |
| Local state and credentials | No actual user auth/session/credential exports identified | Defensive environment, signing, Pi/Milk state, extension data/staging and shell-history rules retained or strengthened |

The initial `docs/` total was 51 files / 6,691,955 bytes; that includes public docs
as well as the excluded archives. The runtime total includes Milk's own
`Runtime/MilkPiIntegration.ts` and the retained manifest, so that directory is
not ignored wholesale. No user-owned development/reference file was deleted.

## 4. Secret and privacy scan

**No confirmed real secret was identified.** The filesystem walk included hidden
and ignored content, without following symlinks. It inventoried all regular files,
inspected binary signatures and scanned 2,606 text-like files line by line for
recognizable provider/GitHub/AWS/Slack credential shapes, bearer/auth/secret
assignments, private-key/certificate markers, email addresses, personal home and
temporary paths, developer identifiers and private-network addresses. Sensitive
filename checks covered environment/auth/session files, key/certificate/profile
material and Keychain exports. Scan outputs contain locations/categories rather
than credential values and remain outside the source tree.

The two local ZIP/tar archives were also inspected without extracting them:
1,602 / 2,227 members, respectively, including 1,493 / 2,030 regular files.
Text-like member scans found personal path references but no recognized credential,
private-key or certificate markers. Both archives remain excluded. Binary payloads,
images/PDFs, nested container formats and encrypted material were not forensically
decoded; pattern scanning cannot prove that every possible secret is absent.

Reviewed prospective matches:

- `Runtime/MilkPiIntegration.ts` supplies an environment-variable reference for
  the provider key, not a stored credential.
- Upstream `Pi-Dependencies.txt` contains API examples, placeholder keys and
  environment reads. Those are notice/documentation material, not live credentials.
- `SettingsTests.swift`, migration/agent tests and fixtures contain explicit
  synthetic token strings, example-domain identities, a credential-bearing invalid
  URL used for rejection, and disposable Keychain test namespaces. They are source
  fixtures; no personal Keychain contents were exported or read for this audit.
- Email matches in notice texts are upstream copyright/author contacts. Git test
  identities use example domains. These remain to preserve attribution/fixtures.
- Loopback hosts/ports are documented defaults and isolated fixtures. No private
  endpoint or personal home directory was found in prospective source.
- One broad path-pattern match in `RUNTIME.md` was ordinary prose describing
  environment defaults, not an absolute personal path.

Personal path/machine references in local build indexes, generated logs and old
archives remain ignored. No `.env`, credential export, signing certificate,
provisioning profile or user Pi session store was found in the prospective set.
No secret value is reproduced in this report. No production privacy correction
was necessary.

## 5. Binary and artifact scan

**PASS for the prospective source snapshot.** All prospective files are UTF-8
text; none has executable/archive magic or a generated binary extension. There
are no prospective Mach-O/ELF executables, dylibs, `.node`, `.wasm`, `.app`, packaged
extensions, compiled object/module files or compressed archives.

Excluded local examples were positively identified by magic/type and path:

- `Runtime/PiRuntime/pi` — Mach-O standalone runtime (Bun embedded upstream).
- `Runtime/PiRuntime/bin/rg` and `bin/fd` — downloaded Mach-O tools.
- `Runtime/PiRuntime/native/darwin/prebuilds/darwin-arm64/darwin-platform.node`.
- `Runtime/PiRuntime/photon_rs_bg.wasm`.
- `docs/private-reference/pi-doom-overlay-222354da5ecc/doom/build/doom.wasm`.
- Generated Milk/SDK and example Mach-O products under `.build/`, `output/` and
  the example build directory. No separate prospective Bun executable exists.

The retained runtime manifest/catalog contain hashes, versions and official URLs,
not downloaded code. The Milk-authored integration, SDK, C transport/archive
wrappers and synthetic source fixtures remain visible. Static inspection of
`stage-app-resources.py` and `build.sh` confirms an allowlist of Milk integration,
notice metadata and Milk-owned SDK resources; no PiRuntime copy is in that recipe.
No app was rebuilt or executed during this phase.

## 6. Ignore changes and verification

Existing rules already excluded root builds/output/apps, local archives,
environment overrides, common signing files, Pi/Milk local state, private doc
archives, extension products/data and downloaded runtime content except its pin.
Changes in this phase:

- Match `.build/` and `.swiftpm/` at any package depth, preserving all real source.
- Add root `dist/`, coverage products (`profraw`, `profdata`, `gcda`, `gcno`), Python
  tooling caches and `node_modules/`.
- Add `.idea/`, local-only VS Code overrides and Xcode checkout/user metadata;
  shared editor configuration remains visible.
- Add certificate/request/DER and Keychain export suffixes to credential ignores.

Static Git checks passed for 47 representative real and synthetic ignored paths,
19 required existing source files and three shared/example configuration paths. Required files include Milk Swift/C/TypeScript, package
manifests/lock, SDK and example source, test fixtures, scripts, entitlements,
notices and `Runtime/PiRuntime/runtime-manifest.json`. Source directories were
not newly hidden. No `.gitattributes` change was needed for this all-text snapshot.
Ignore rules affect ordinary future additions; they do not sanitize existing
tracked history or protect files force-added with `git add -f`.

## 7. Root license

The existing root `LICENSE` is MIT, copyright 2026 Milk contributors, and remains
unchanged. It is appropriate as the project's chosen license for original Milk
contributions; this audit does not independently establish contributor ownership.
README and third-party notices explicitly preserve third-party licenses. Nothing
in the cleanup claims Pi, Bun, SwiftTerm or other upstream code is authored or
relicensed by Milk.

## 8. Third-party notices

Relevant notice texts and provenance locks are retained. The SwiftTerm notice is
byte-for-byte identical to the existing 1.99.2 checkout license. `Package.resolved`
remains unchanged; no dependency resolution, download or upgrade occurred.
Existing SwiftTerm manifest platform conditions support the inventory's distinction
between the linked terminal and its pinned non-macOS/tool dependencies.

`ThirdPartyNotices/INVENTORY.md` now distinguishes the source snapshot, optional
bootstrap fixtures, production managed downloads and clean Milk.app contents.
It previously described Pi/Bun/search/native/wasm runtime portions as packaged.
It now also records the system libarchive dependency and platform frameworks;
Milk's small C ABI declarations do not vendor libarchive implementation code.
`ThirdPartyNotices/README.md` clarifies the two runtime download paths and the
source/release boundary. Actual upstream license texts were not rewritten.

**Bun/native matching-source, reconstruction, relinking and runtime distribution
review remains unresolved.** Notices and hashes do not resolve it. Developer ID,
notarization, stapling and clean-machine trust acceptance also remain app-release
gates from final acceptance. They are not blockers to this source-only snapshot,
which contains no downloaded runtime binaries. No new legal clearance claim or
fresh external license determination is made by this static repository audit.

## 9. Documentation hygiene and Phase 2 work

Fixed now:

- Replaced the stale root audit with a compatibility pointer to this report and
  final acceptance. Its old bundled-Pi/publication-blocker claims are superseded;
  the complete previous file is preserved in ignored `docs/internal/`.
- Added historical banners to six earlier Agent phase reports, the Phase 0 parity
  record and the architecture planning handoff. Their earlier test counts, runtime
  assumptions, deferred work and local evidence paths describe those phases only.
- Updated the docs index, README acceptance references and a stale runtime gate
  statement. Extension authoring no longer refers to “bundled Pi” as current.
- Relative Markdown file/directory links resolve within the prospective snapshot.
  Generated `output/` evidence references are explicitly local records, not public
  download dependencies. No private design/reference file is needed to build.

Phase 2 should polish the overall documentation, streamline developer setup and
validation instructions, distinguish the older extension “Phase 7” terminology
from final Agent acceptance, and reconcile remaining detailed lifecycle prose in
`RUNTIME.md` with the completed lifecycle owner. Roadmap and planning documents
must not be used as implementation claims. Broader rewriting, screenshots,
release instructions and fresh behavior validation were deliberately deferred.
The current technical authority remains final acceptance and source code.

## 10. Largest prospective files

These are prospective additions, not verified tracked files (there is no index).

| File | Bytes | Reason retained |
| --- | ---: | --- |
| `ThirdPartyNotices/Pi-Dependencies.txt` | 715,950 | Upstream license/notice material |
| `ThirdPartyNotices/Runtime-Libraries.txt` | 340,680 | Native runtime license/notice material |
| `Sources/Milk/AgentService.swift` | 59,215 | Required application source |
| `ThirdPartyNotices/pi-install-package-lock.json` | 51,399 | Dependency provenance |
| `docs/EXTENSION_DEVELOPMENT.md` | 47,675 | SDK authoring guide |
| `Sources/Milk/ChatPanel.swift` | 32,455 | Required application source |
| `Sources/Milk/NativeCodeEditor.swift` | 30,283 | Required application source |
| `Sources/Milk/PiBackend.swift` | 29,756 | Required application source |
| `Sources/MilkExtensionHost/NativeExtensionManager.swift` | 27,141 | Required application source |
| `Tests/MilkExtensionTests/NativeExtensionTests.swift` | 26,671 | Source tests |

No prospective file is 1 MB or larger. Large notices are intentional text, not
concealed runtime binaries.

## 11. Exact changes made in this phase

Added to the prospective public set:

- `docs/PRE_GITHUB_AUDIT.md` — this report.

Modified:

- `.gitignore`
- `PRE_GITHUB_AUDIT.md`
- `README.md`
- `RUNTIME.md`
- `ThirdPartyNotices/INVENTORY.md`
- `ThirdPartyNotices/README.md`
- `docs/README.md`
- `docs/EXTENSION_DEVELOPMENT.md`
- `docs/MILK_AGENT_ARCHITECTURE.md`
- `docs/PI_PARITY_CONTRACT.md`
- `docs/PHASE_1_AGENT_BOUNDARY.md`
- `docs/PHASE_2_AGENT_LIFECYCLE.md`
- `docs/PHASE_3_INSTALLATION_RESOLUTION.md`
- `docs/PHASE_4_AGENT_SESSIONS.md`
- `docs/PHASE_5_MANAGED_INSTALLATIONS.md`
- `docs/PHASE_6_AGENTS_UI_AND_CLEAN_APP.md`

Added locally and ignored:

- `docs/internal/PRE_GITHUB_AUDIT_before_publication_phase1.md` — exact preserved
  copy of the root audit as received in this phase.

Removed/deleted/moved from the prospective set: **none**. No existing local
artifacts were deleted. No production Swift, TypeScript, C, scripts, tests,
package pins, entitlements, license text or final Agent acceptance content changed.
A before/after content-hash comparison verifies that boundary. Temporary scan
scripts and detailed inventories were kept outside the repository.

## 12. Before a future public push

No known source-content blocker remains in the ordinary prospective set.
Because there is no repository here, a future explicitly authorized publication
step must choose/inspect the actual Git repository and branch and check its staged
files. If an existing remote/history is later attached, audit that history and
tracked/ignored files separately: this filesystem assessment cannot certify
unseen commits. Review the concrete staged snapshot against this report before
pushing; do not force-add local archives, runtimes, private docs or user state.
Phase 2 documentation polish remains planned work, not an unresolved binary
redistribution blocker to source publication.

## 13. Verification and scope confirmation

Only static/filesystem checks ran: complete inventory, text/signature and archive
inspection, Git ignore/inclusion simulation, relative Markdown link validation,
license/manifest/resource-recipe inspection and before/after content hashes.
No full Swift suite, native verifier, GUI inspection, managed installation,
packaging acceptance, signing or notarization ran. Prior 156/156 acceptance is
quoted as baseline evidence, not a new result.

**No commit, push, GitHub release, GitHub settings change, upload or publication
occurred. No Git history was rewritten.** No GitHub service was contacted.
