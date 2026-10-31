# Agent refactor — final acceptance

Date: 2026-10-31. **Overall: PASS WITH RELEASE BLOCKERS.**

## 1. Overall result

The single full Swift regression pass passed, a fresh production-recipe Milk.app
was built and mechanically checked, and its isolated acceptance entry point passed
12 checks, including real official managed installation and actual external Pi.
Production distribution readiness is not established. No screenshot sweep or
clean-machine/notarization acceptance is claimed.

## 2. Final architecture

Milk UI uses the generic adapter/session/lifecycle boundary; compiled PiAdapter
retains native Pi RPC and MilkExtensionKit compatibility. Settings → Agents owns
installation selection. Managed immutable revisions, external registrations and
ordinary Pi user data have separate ownership. Workspace restore/cache browsing
is offline. Only Pi is a production agent. The clean app keeps the Milk-authored
integration and extension SDK, not an upstream agent runtime.

## 3. Full suite

`swift test --cache-path "$PWD/.build/cache"` with Xcode and workspace-local module
cache: **156 tests, 0 failures**, 66.476 seconds of test execution. Run once, with
no targeted repair reruns and no second broad pass. This includes existing parity,
Pi integration, thinking/redaction, dialogs/approvals, queue/steering/stop,
concurrent sessions/Preview, native bridge, model/reasoning, session/history/delete,
lifecycle, Settings, migration and managed-transaction tests. Evidence:
`output/phase7/full-suite.log`. No production regression was found by this pass.

## 4. Fresh build

`./scripts/build.sh`: successful fresh production-recipe app, including current
acceptance entry point. The stale pre-Phase-6 app was replaced by the recipe.
`output/phase7/build.log` records the build and signing. The install_name_tool
signature-invalidation warning precedes the recipe's normal final signing; final
strict verification passed. No runtime bootstrap was invoked.

## 5. Bundle contents

A recursive mechanical file inspection found no `pi`, `bun`, `rg`, `fd`, PiRuntime
directory, runtime manifest, `.node` or `.wasm` files. Milk executable, integration
bridge, Frameworks SDK library and resource SDK library exist. Exact enumerated
contents: `output/phase7/bundle-contents.log`. Fresh executable SHA-256:
`3e4b166fa7e5924ad2fc7fb88486f02657a63cedeeed500a56432c2b661da7bc`.
Production fallback rejection is additionally covered by the full suite's explicit
old-bundle-files test. The recipe's resource helper does not require PiRuntime;
explicit upstream test fixtures remain separate from release resources.

## 6. No-agent acceptance

The freshly built executable's `--verify-agent-acceptance` branch creates AppKit
and isolated ShellState/temporary workspace storage. Workspace/editor opening,
Agents state, Extensions discovery and retained all-project metadata passed;
owned agent leases stayed empty, provider checkedAt stayed nil, unavailable/install
state appeared, and no install occurred until explicitly requested. No personal
preferences/provider credentials are used by this branch.

This is mechanical state/service verification in the actual app process, not a
manual window/interaction walkthrough. Git/Diff, Terminal, normal Preview and
editor regressions were covered by the full Swift suite; every surface was not
separately exercised through fresh-app UI automation. No clean-machine claim.

## 7. Legacy migration

The full pass includes the representative metadata-only/idempotent legacy bundled
and external migration tests, v3/v4 session/editor/draft/archive preservation,
provider-save isolation and unchanged endpoint Keychain token test. Bundled becomes
Pi with no runtime; external reference remains externally owned and requires
explicit verification. No ordinary Pi directory migration/copy occurs. Corrupt and
newer persisted payloads retain original bytes rather than being overwritten.

## 8. External Pi

The fresh app used the repository's actual supported upstream Pi executable as
an explicitly supplied existing installation, with temporary Pi storage. Its
isolated native integration probe and backend startup succeeded; startup performs
state/catalog/model/reasoning/history readiness checks. Awaited shutdown succeeded,
and the executable digest was unchanged. Registration/selection ownership and
failure behavior passed in the full suite. Normal prompt/streaming/resume behavior
was exercised by existing real Pi loopback-provider integration tests in that
same full pass; no paid/live provider or personal external data was used.

## 9. Real managed installation

The fresh app used default PiInstallationManager production downloading, catalog,
archive extraction, integrity checks, native probe and atomic selection against
actual approved Pi 1.4.0 Darwin arm64 artifacts. It succeeded. Thus official URL
fetches, pinned archive/file hashes, required notice copying, extraction, immutable
revision creation, native integration and selection-after-verification all passed.
No fake newer production release or weakened security checks were introduced.

The selected managed runtime actually started via PiBackend, then shut down.
Verify, same-version repair, removal, reinstall and final removal completed in
isolated temporary storage. This host allowed execution of these artifacts; this
does not establish Gatekeeper/quarantine behavior on a clean customer machine.

## 10. Sessions/data retention

The actual-app acceptance retained the Milk session UUID/draft through managed
remove/reinstall and explicit no-runtime selection. Its isolated ShellState cache
and managed-runtime owner are separate, so this simple assertion is not presented
as exhaustive integrated session-store validation. Stronger owning-adapter/index,
ordinary data/auth/config/extensions sentinel retention, archived reopen,
current/all-project cache, deletion failure/retry and install/remove/reinstall
identity tests all passed in the full Swift suite. No native session file was
converted or reassigned. Acceptance used disposable data; personal data untouched.

## 11. Lifecycle/shutdown

Actual external and managed backends and compatibility probes exited with awaited
cleanup. Both acceptance coordinators drained successfully before process exit.
Existing full-suite tests cover concurrent conversations, auxiliary Preview,
pending starts, cancellation, EOF/TERM/KILL cleanup, failed exits retaining
ownership, helper admission barriers, unrelated-process survival and failed-probe
staging retention. No redundant historical native verifier matrix was run.
Normal AppKit window-close/terminateLater was not separately automated in this
phase; the existing Swift shutdown tests and explicit fresh-app owner drain are
the evidence, not an unperformed GUI quit sweep.

## 12. Signing/notarization

`codesign --verify --deep --strict output/Milk.app`: successful. The recipe also
signs both Milk-owned SDK copies and verifies the final app. Signature inspection
reports arm64, ad-hoc hardened runtime, no TeamIdentifier. Developer ID release
signing, notarization, stapling and clean-machine trust acceptance were **not
performed**. These remain release gates.

## 13. Licensing/redistribution audit

[Pi's versioned MIT license](https://github.com/earendil-works/pi/blob/v1.4.0/LICENSE)
requires preservation of its notice. The app retains the relevant notices and
managed installs copy them. This does not resolve the complete runtime closure.

[Bun 1.3.14's license guidance](https://github.com/oven-sh/bun/blob/bun-v1.3.14/LICENSE.md)
identifies statically linked LGPL JavaScriptCore/WebKit and describes relinking.
The repository retains that guidance, dependency/license inventories and runtime
hashes, but does not establish exact matching patched native sources and complete
reconstruction/object/relink materials for the downloaded standalone artifact.
Moving-source notice collector URLs are not a version-locked native SBOM.

Milk.app redistribution now excludes those agent binaries. Milk downloading an
upstream runtime directly for a user is a different delivery path; no definitive
legal conclusion about that path follows from this technical change. Whether
Milk's particular facilitation/distribution role changes obligations needs release
legal/provenance review. Record this as an **unresolved release blocker**, not
clearance. The official GNU LGPL page lookup timed out; no claim based on that
unavailable lookup is made. Repository evidence and Bun's published guidance are
sufficient to identify uncertainty, not settle every obligation.

## 14. Production fixes

None. The full pass and real installation exposed no verified production defect.
The only executable additions are a mechanical acceptance entry point/helper;
ordinary launch behavior is unchanged. No architecture redesign was introduced.

## 15. Unresolved blockers and practical limits

- Developer ID/notarization/stapling and clean-machine/moved-app trust acceptance.
- Downloaded Bun/native matching-source/reconstruction/relink/distribution review.
- Actual GUI surface/window-quit walkthrough not separately performed here.
- One approved Pi version only: no claim of real cross-version update/rollback.
- No live paid provider exercised; real Pi prompt tests use controlled loopback.
- Full-tree integrity verification startup cost remains unbenchmarked. State/UI
  inspection uses metadata, not full inventories. Tests confirm no eager startup,
  redundant ordinary-use compatibility preflight, or persistent inactive harness.

These distinguish verified technical functionality from production release claims.

## 16. Exact checks run

1. One full `swift test` invocation with Xcode/workspace caches: 156/156 passed.
2. One `./scripts/build.sh` production build: success, final recipe signing passed.
3. One recursive Python bundle-content assertion/enumeration: passed.
4. Fresh `output/Milk.app/Contents/MacOS/Milk --verify-agent-acceptance
   --acceptance-external "$PWD/Runtime/PiRuntime/pi"`: exit 0, 12 PASS, no FAIL
   or BLOCKED. Log: `output/phase7/app-acceptance.log`.
5. `codesign --verify --deep --strict` and `codesign -d --verbose=2`: success;
   details in `output/phase7/signing.log`.
6. Local notice/audit inspection and versioned official Pi/Bun license lookups;
   GNU lookup failed as disclosed above.

No repeated successful filter, screenshots, native harness sweep, extra benchmark,
notarization attempt, or second full suite. The acceptance helper was built after
the broad pass; it was exercised from the new app rather than rerunning that pass.

## 17. Exact files changed

Added:
- `Sources/Milk/AgentAcceptanceVerification.swift`
- `docs/AGENT_PHASE_FINAL_ACCEPTANCE.md`

Modified:
- `Sources/Milk/MilkApp.swift` — isolated acceptance command dispatch only.

Generated evidence under `output/phase7/` and fresh `output/Milk.app` are build/test
artifacts, not source changes.

## 18. Scope confirmation

No other agent, Computer Use, orchestration, marketplace, public adapter SDK,
unrelated roadmap feature or next multi-agent implementation was added. No commit,
push or GitHub modification occurred. Acceptance is complete as documented;
release blockers remain open and are not disguised as verified readiness.
