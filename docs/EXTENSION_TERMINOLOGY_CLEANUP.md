# Extension terminology and commit-readiness cleanup

Baseline: security/api-keychain at 24a6c8b13aba572667c4a3b5f52957d696e33415 (external interrupted checkpoint). No history or branch mutation by this cleanup.

Only terminology, comments and visible UI/error text changed. Worker execution, security boundaries, protocols and manifest values are unchanged. MilkExtensionAPI, milkApi and the equality check predate Sandbox work (verified at c00305f); their current compatibility marker is retained. This is package compatibility metadata, not a product generation or migration system.

Historical earlier extension-version references in five pre-Sandbox phase/publication reports remain historical. Azure API version environment names in provider code and upstream third-party notices have unrelated technical meaning and are untouched.

## Complete shorthand occurrence inventory

Each location below is the original baseline line; replacement text is the final wording. Multiple replacements on one line are included together.

| File | Original line | Replacement |
| --- | --- | --- |
| `Packages/MilkExtensionKit/Sources/MilkExtensionKit/ExtensionAPI.swift` | 4 | /// Native UI is trusted/in-process. Agent code uses the separate extension worker. |
| `README.md` | 27 | and services through MilkExtensionKit. Agent-callable tools run in separate |
| `README.md` | 117 | agent-callable extension tools execute in separate sandbox workers. Native UI capabilities |
| `RUNTIME.md` | 66 | Native tools use metadata-only extension worker registrations and MilkExtensionWorker, a |
| `Sources/MilkExtensionHost/NativeExtensionManager.swift` | 349 | guard let worker=saved.manifest.agentWorkerClass else { throw NativeExtensionError.invalid("Agent tools require an extension worker entry point. No in-process fallback exists.") } |
| `Tests/MilkExtensionTests/NativeExtensionTests.swift` | 320 | // The extension worker contract rejects a UI-only package for agent execution, even with ordinary approval. |
| `docs/API_KEYCHAIN.md` | 108 | and extension workers construct independent sanitized environments. Worker signing/service |
| `docs/DEVELOPMENT.md` | 158 | not a bundled coding agent. Rebuild native packages affected by the worker execution contract; view/layout/ |
| `docs/EXTENSION_DEVELOPMENT.md` | 1 | # Milk Extension development |
| `docs/EXTENSION_DEVELOPMENT.md` | 3 | This guide describes MilkExtensionKit in Milk 0.7.0. The authoritative public sources are [MilkExtensionKit](../Packages/MilkExtensionKit/Sources/MilkExtensionKit/). The separately built [OMLXStatusExample](../Examples/Extensions/OMLXStatusExample/) is a complete working extension. |
| `docs/EXTENSION_DEVELOPMENT.md` | 6 | Agent Refactor acceptance. Agent-callable tools execute in extension worker processes. |
| `docs/EXTENSION_DEVELOPMENT.md` | 50 | Agent-callable tools use extension tool metadata plus a separate worker class; piCommand |
| `docs/EXTENSION_DEVELOPMENT.md` | 93 | The manifest is under Contents/Resources so ordinary macOS bundle signing can seal it. A top-level manifest is not the extension package format. |
| `docs/EXTENSION_DEVELOPMENT.md` | 95 | The current host accepts arm64 Mach-O **MH_BUNDLE** executables for macOS 26+. It rejects missing/non-executable entries, script executables, symlinks, hard-linked files, special files, over 10,000 entries, or packages over 128 MB. Manifests and Info.plist are limited to 64 KB each. Fat/universal and Intel packages are not supported in the current extension host. |
| `docs/EXTENSION_DEVELOPMENT.md` | 259 | A service property is nil unless its corresponding capability was granted. Each operation also checks the specific permission and active lease. Milk requests the full declared set on installation; there is no partial-grant UI. Newly requested permissions must be accepted during update. |
| `docs/EXTENSION_DEVELOPMENT.md` | 293 | Use the process service for subprocesses. Milk records extension owner, PID/group and workspace scope, starts a fresh group with closed inherited descriptors and a minimal environment, and stops only those owned groups. A reaper keeps the leader unreaped while bounded TERM/KILL cleanup runs, preventing PID/group reuse. It does not kill by port, process name or cwd. Workspace changes stop workspace-scoped processes; disable/uninstall/quit stop all managed processes for the owner. Daemonizing or deliberately escaping the owned process group is unsupported. Generic launch discards stdout/stderr in the current process service; it is not an interactive terminal or streaming-output API. |
| `docs/EXTENSION_DEVELOPMENT.md` | 431 | The slot table above is exhaustive for the current SDK, including file.contextMenu. To add a button beside the composer controls: |
| `docs/EXTENSION_DEVELOPMENT.md` | 464 | Storage is extension-global; MilkExtensionKit has no separate workspace settings API. If needed, implement a versioned per-workspace map in scoped storage using the workspace URL from the action context or the gated workspace service. Handle no open workspace and avoid assuming a URL is a permanent project identity. Do not use Milk's private preferences. |
| `docs/EXTENSION_DEVELOPMENT.md` | 470 | // Validate arguments here; MilkExtensionKit has no argument-schema/arity field. |
| `docs/EXTENSION_DEVELOPMENT.md` | 490 | Add "agentWorkerClass": "MyExtension.AgentWorker" to the extension manifest: |
| `docs/EXTENSION_DEVELOPMENT.md` | 571 | MilkExtensionKit has no migration callback. In activation/model initialization, read a versioned Codable envelope from scoped storage, validate it and explicitly migrate supported older versions. Write atomically through storage.write, retain a backup where appropriate, and leave unknown newer formats intact with a useful diagnostic. Package update rollback restores code references, not arbitrary mutated extension data. Prefer additive/backward-readable changes so the previous package can still operate. Never put mutable settings or migration state inside .milkext: code/resources may be replaced; ExtensionData remains. |
| `docs/EXTENSION_DEVELOPMENT.md` | 585 | MilkExtensionKit does not expose separate background, success, warning or destructive theme properties. Do not invent them or reach into private MilkTheme. Use supported SwiftUI semantic roles/native colors when extra status semantics are necessary, and check both appearances. Do not use .accentColor as a substitute for Milk accent, hardcode light-only backgrounds, set application appearance or invent independent application styling unless custom content deliberately requires it. Use ExtensionButtonStyle, ExtensionSettingsRow, ExtensionSettingsSection, ExtensionStatusBadge and ExtensionEmptyState where appropriate. |
| `docs/EXTENSION_DEVELOPMENT.md` | 642 | Trusted native UI is not sandboxed; its crashes cannot be isolated. Agent workers use a separate process and OS profile. The current loader accepts arm64/macOS 26+ bundles. Already mapped native code requires restart for replacement. There is no marketplace, automatic update feed or enforced publisher authority. Signature reporting and integrity checks do not establish publisher trust. MilkExtensionKit may evolve; unsupported contribution points require an intentional SDK/core change. Native code has cooperative cancellation limits and cannot be safely hot-unloaded. The oMLX example demonstrates broad integration with external infrastructure; it does not make oMLX part of Milk core. |
| `docs/EXTENSION_DEVELOPMENT.md` | 649 | granted write access. Native worker load/cancel/signing boundaries and the extension worker contract remain |
| `docs/README.md` | 28 | - [Extension development](EXTENSION_DEVELOPMENT.md): MilkExtensionKit, |
| `docs/README.md` | 41 | - [Sandbox host effects](SANDBOX_HOST_EFFECTS.md): real-Git escalation, extension |
| `docs/README.md` | 75 | Phases 1–2. Current extension behavior is documented as **MilkExtensionKit**. |
| `docs/SANDBOX_ACCEPTANCE.md` | 39 | \| Extension workers \| NativeExtensionTests, NativeExtensionIntegrationTests, actual packaged-worker fixture; install/lifecycle/update/restart/data/integrity/nonce/files/Git/cancel/revoke/native UI \| PASS (final 304-test suite and applicable native/artifact checks); no in-process agent fallback \| |
| `docs/SANDBOX_ACCEPTANCE.md` | 131 | \| Full Xcode SwiftPM swift test --cache-path "$PWD/.build/cache" --disable-sandbox, with MILK_TEST_WORKER_PATH selecting the staged release helper \| **304/304 passed**, zero failures/skips, 237.593 seconds; includes actual Xcode build/Once dependency and packaged extension worker \| /private/tmp/milk-phase7-full-final.log \| |
| `docs/SANDBOX_ACCEPTANCE.md` | 241 | The new actual-worker test verifies that a compiled extension worker cannot read the same |
| `docs/SANDBOX_HOST_EFFECTS.md` | 51 | The extension worker contract removes agent handler closures and piCommand. Native user command, view, |
| `docs/SANDBOX_POLICY.md` | 134 | effects use the separate extension worker route; legacy native bridge effects reject. Direct pi.exec and Pi extension children |
| `docs/SANDBOX_POLICY.md` | 163 | Native extension workers and explicit managed jobs are described in |
| `docs/SANDBOX_PURPOSES.md` | 20 | \| Native extension worker: SandboxExtensionExecution → MilkExtensionWorker \| Validated helper/library closure, verified package, declared file access and current grant profile. Non-shell tools use minimal system roots; shell-capable tools retain development dependencies. Code is read-only. \| Separate signing identity with no Milk Keychain entitlement; private sanitized HOME/TMP, bounded typed IPC, active registration nonce, cancellation/revoke/owner checks. \| |
| `docs/exec-plans/completed/SANDBOX_IMPLEMENTATION.md` | 1589 | - Extension worker contract in ExtensionAPI.swift: metadata-only agent tools, agentWorkerClass, separate |
| `docs/exec-plans/completed/SANDBOX_IMPLEMENTATION.md` | 1698 | The worker execution contract changed agent-extension source/ABI and requires rebuilding affected extensions. Worker stdout is |
| `docs/exec-plans/completed/SANDBOX_IMPLEMENTATION.md` | 1789 | race limits, extension worker rebuild requirements, and the pre-existing Existing-only configured |
| `docs/exec-plans/completed/SANDBOX_IMPLEMENTATION.md` | 1799 | exception, extension workers, user host features and the Existing-only Preview provider seam stay |
| `docs/exec-plans/completed/SANDBOX_IMPLEMENTATION.md` | 1844 | \| Native extension worker tools: SandboxExtensionExecution / MilkExtensionWorker \| Validated helper/library closure and verified package; capability-scoped file authority; minimal non-shell roots, development dependencies only for shell tools; code read-only. \| Separate signed helper identity without Milk Keychain entitlement; private key-free HOME/TMP and bounded typed IPC. Trusted native UI stays in-process. \| |
| `docs/exec-plans/completed/SANDBOX_IMPLEMENTATION.md` | 2012 | \| Native extension workers \| NativeExtensionTests, NativeExtensionIntegrationTests, packaged actual-worker test \| Lifecycle/integrity/nonce/files/Protected/Git/cancel/revoke/native UI; synthetic Keychain deletion contract only. \| |
| `docs/exec-plans/completed/SANDBOX_IMPLEMENTATION.md` | 2074 | ad-hoc hardened-runtime release MilkExtensionWorker; its real compiled extension worker fixture |
| `docs/exec-plans/completed/SANDBOX_IMPLEMENTATION.md` | 2183 | - Actual packaged extension worker fixture attempted ordinary SecItem read of a real disposable |
Total: 42 original lines in 14 files.

Additional normalization: current ThirdPartyNotices/INVENTORY.md drops the stale numbered SDK label; docs/DEVELOPMENT.md and EXTENSION_DEVELOPMENT.md describe affected-package rebuilds without a numbered migration taxonomy. NativeExtensionsUI.swift uses compatibility/package compatibility labels; PackageInspection.swift reports an unsupported package compatibility marker. The checks themselves remain identical.

## Final state and validation

Phase 7 and Sandbox/security technical acceptance remain complete. Ordinary login/file-based Keychain is primary/only persistent secret storage; Data Protection is retired. No Apple enrollment/profile is needed; no plaintext fallback exists. Developer ID/notarization are optional; private/ad-hoc builds may require user-selected Open Anyway. Fresh live provider acceptance remains NOT RUN. Accepted limitations are unchanged.

Normal `./scripts/build.sh --disable-sandbox` passed (including signing verification); `git diff --check` passed. Tracked-path and full-milestone introduced-line scans found no generated/build/evidence files, private machine paths or credential-pattern findings. The complete milestone diff since c00305f spans 126 files; the externally checkpointed prior work is preserved. Current cleanup status is 17 modified files plus this new inventory document, with nothing staged. The full 308 Swift/32 Python suite was intentionally not repeated: no production control flow, identifiers, schema, values or behavior changed. Earlier completed acceptance remains the evidence for the milestone.


The current compatibility marker changed during the earlier worker-contract implementation to prevent incompatible packages from loading. Its field, type and enforcement already existed before that work; this cleanup does not reset the marker or weaken its check. No generation-specific type, function or migration subsystem was found. Production Swift changes here are only a comment and visible UI/error strings; normalized code comparison confirms control flow is identical. No identifiers were renamed, so focused tests were unnecessary. Normal build passed; full tests intentionally not rerun.

Historical references retained: docs/PHASE_1_AGENT_BOUNDARY.md:65, docs/PHASE_2_AGENT_LIFECYCLE.md:154, docs/PHASE_3_INSTALLATION_RESOLUTION.md:159, docs/PI_PARITY_CONTRACT.md:69 and docs/GITHUB_PUBLIC_DOCS_REVIEW.md:96. These predate the shorthand mistake and describe their original snapshots, not the current product.

The completed ExecPlan remains under docs/exec-plans/completed; no active Sandbox plan remains. No commit, push, merge, rebase or branch change. Recommended milestone commit message: `Implement sandboxed agent execution and login-Keychain credentials`.
