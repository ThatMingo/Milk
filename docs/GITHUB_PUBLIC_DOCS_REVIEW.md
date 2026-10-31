# GitHub Publication Phase 2 — public documentation review

Date: 2026-10-31. **Documentation polish complete.** This is a documentation-only
review of the current Milk source tree; it does not publish the repository or
claim downloadable-app release readiness.

Authority: the [Phase 1 source audit](PRE_GITHUB_AUDIT.md),
[Agent final acceptance](AGENT_PHASE_FINAL_ACCEPTANCE.md), current package/build
scripts and the implemented adapter, installation, session and lifecycle code.
Both audit/acceptance files remain byte-for-byte unchanged. Their recorded test
results and the audit's file count/size describe their original snapshots, not a
new validation run or the later documentation additions.

## 1. Public documentation changes

The root README now serves as the product landing page. Detailed setup commands
have one reference in [Developer setup](DEVELOPMENT.md); runtime responsibilities
live in [Runtime architecture](../RUNTIME.md). The docs index separates current
references, planning and historical engineering records. No screenshot or release
link was invented, and no private archive is required by current setup instructions.

## 2. README structure and positioning

The README introduces Milk as a Swift/SwiftUI/AppKit macOS GUI for coding agents,
with the implemented workspace features and Apple Silicon/macOS 26 target.
Its structure is:

1. Milk and current development version.
2. What works today.
3. Agents and executable/data ownership.
4. Requirements.
5. Build from source.
6. Running with Pi.
7. Extensions.
8. Status and limitations.
9. License.

It states that no agent is bundled, Pi is the only production integration,
Pi 1.4.0 uses native RPC through the compiled adapter, and users choose managed or
existing installations in Settings → Agents. It distinguishes source readiness
from signed app releases, labels future features as plans, and preserves the
root MIT/third-party license boundary. Long feature minutiae and the native
verification command matrix were removed from the landing page.

## 3. Developer setup

Added `docs/DEVELOPMENT.md` as the build/test reference. Requirements were checked
against `Package.swift`, the pinned local SwiftTerm manifest, and existing build,
fixture and example scripts: Apple Silicon, macOS 26+, full Xcode/macOS 26 SDK,
Swift 6.2+, Python 3 and the existing command-line tools. The root package's Swift
5 language mode is explained separately from toolchain requirements.

The minimal build/run flow remains `./scripts/build.sh` followed by
`open output/Milk.app`. The guide documents Xcode selection, the existing optional
`--disable-sandbox` argument, generated output locations and default ad-hoc signing.
No new script, installation workaround or hidden app-file modification is needed.

Tests are opt-in developer instructions. A fixture-free layout test example is
separate from the full suite, which requires upstream fixtures first. The optional
bootstrap section specifies Python 3.12+ and curl, pinned Pi/rg/fd downloads,
checksum verification and ignored fixture storage. It explains that the bootstrap
already invokes the verifier and that these fixtures are neither app-build inputs
nor the production runtime selection mechanism. No documented build/test command
was executed in this phase.

## 4. Runtime corrections

Replaced the accumulated implementation narrative with the current system:

- `Milk UI / AgentService → AgentAdapter → PiAdapter → PiBackend / PiRPCClient
  → native Pi RPC`.
- Explicit no-runtime, Milk-managed and existing external installation states;
  no PATH discovery or implicit bundled fallback.
- Isolated compatibility probing of required RPC replies and Milk's integration
  handshake, beyond a version-only check.
- Hash-pinned staged downloads, immutable managed revisions, atomic metadata,
  safe activation, repair, guarded rollback and default-off Auto Update.
- Lifecycle leases covering pending/closing conversations, Preview inspections,
  probes, utility commands and installation transactions; conflicting writers
  wait for cleanup, and unconfirmed exits retain ownership.
- Current `terminateLater` cleanup participants: agent lifecycle, native extensions,
  Terminal and Preview. Removed the stale account describing only Preview and
  Terminal as the app's shutdown participants.
- Installation-independent session identity/cache, ordinary Pi user storage,
  provider/Keychain ownership and a clean app resource boundary.

Removed phase-specific schema migration detail, UI geometry, attachment/transcript
implementation minutiae and duplicate bootstrap commands from the runtime overview.
The detailed extension contract and historical records remain available separately.
Only one real Pi version is approved; the document does not claim real cross-version
update/rollback acceptance or independently downloadable adapters.

## 5. Extension guide and documentation index

Preserved the extension guide's detailed API, package, trust, lifecycle and example
material. Targeted changes identify **MilkExtensionKit API 1** as the current
contract, distinguish the old extension “Phase 7” from Agent Refactor acceptance,
and replace phase-specific wording about the current host/limitations.
Removed the obsolete Pi bootstrap prerequisite from native extension build steps.
Added a developer-setup link and clarified that Pi-backed functionality uses the
runtime selected through Settings → Agents.

The docs index now links all current references, architecture/roadmap documents,
and individual Phase 0–6 Agent Refactor records. It explains that historical
bundled-runtime assumptions and older test counts do not describe the current
product. No historical document was renamed or rewritten in this phase.

## 6. Stale and private references

Removed duplicated README verification commands and stale shutdown/current-phase
claims. Current-facing docs no longer depend on ignored historical validation or
private reference files. Generated `output/` locations are described as local
build products/evidence, not downloadable repository assets. Standard Xcode/app
locations and home-relative product data paths are intentional generic examples;
no personal absolute path or identifier was introduced.

## 7. Remaining limitations

- This is a static documentation review. Build commands, test examples, extension
  compilation and product flows were checked against source, not freshly executed
  or visually inspected. A fresh clean-machine/developer setup run is not claimed.
- No public screenshots were established; the README omits a screenshot section.
- External URLs were not fetched or verified live, in accordance with the request
  not to contact GitHub. Relative repository links were checked locally.
- Historical records retain point-in-time terminology and local evidence paths,
  clearly separated from current references. The roadmap includes both longer-term
  goals and related groundwork; it is not a shipped feature list.
- Developer ID/notarization/stapling/clean-machine release acceptance remains open.
  Bun/native provenance, matching-source, reconstruction, relinking and downloaded
  runtime distribution review remains unresolved. Neither documentation polish nor
  source-publication readiness establishes release clearance.
- The source folder still has no `.git`; the Phase 1 requirement to inspect a future
  actual repository/index/history before a push is unchanged.

## 8. Exact files changed

Modified:

- `README.md`
- `RUNTIME.md`
- `docs/README.md`
- `docs/EXTENSION_DEVELOPMENT.md`

Added:

- `docs/DEVELOPMENT.md`
- `docs/GITHUB_PUBLIC_DOCS_REVIEW.md`

Removed or renamed: **none**. The root audit pointer, Phase 1 report, final Agent
acceptance, roadmap, historical phase reports, third-party notices and license
texts are unchanged.

## 9. Static checks

- Relative Markdown file/directory links checked against the prospective public
  inclusion set; heading anchors checked where present.
- Modified/new docs scanned for personal absolute paths, private identifiers,
  credential markers and links into ignored private/evidence directories.
- UTF-8, final newlines, trailing whitespace and code-fence balance checked.
- Prospective inclusion checked using existing Phase 1 temporary Git metadata in
  read-only operations. No Git repository was initialized in this phase.
- Documented platform/toolchain/Pi versions, default-off Auto Update, four shutdown
  participants, layout test filter and native-extension build boundary checked
  against existing local source/scripts/manifests.
- Before/after hashes checked for the existing prospective source files, confirming
  that only the four listed Markdown documents changed and the two listed files
  were added. Audit/acceptance content, production code, scripts, tests, package
  manifests/pins, entitlements and ignore/license files are unchanged.

All static checks passed. The full Phase 1 filesystem/secret audit was not repeated.
Temporary check scripts/results were kept outside the source tree.

## 10. Scope confirmation

No production code or architecture was modified. No project Git repository was
created or changed; no commit, push, GitHub repository/release/settings operation,
upload or publication occurred, and GitHub was not contacted. No app build,
Swift test suite, native verifier, Pi installation, screenshot/visual inspection,
signing or notarization was run. Build/test commands shown in documentation are
instructions for future developer use only.
