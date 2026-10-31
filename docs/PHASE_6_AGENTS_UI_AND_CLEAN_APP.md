# Phase 6 — Settings → Agents and clean application packaging

> Historical phase record. This document records its original scope and evidence;
> it is not the current implementation or acceptance status. See
> [Agent final acceptance](AGENT_PHASE_FINAL_ACCEPTANCE.md) and the
> [source-publication audit](PRE_GITHUB_AUDIT.md). Evidence paths under `output/`
> refer to generated local files excluded from the public source tree.

Scope: final implementation wiring before Phase 7 acceptance. Pi remains the only
production agent. The approved architecture amendments and Phase 0–5 contracts
remain the technical basis. This report supersedes historical bundled-runtime UI
and packaging descriptions, without rewriting their dated validation evidence.

## Management and Settings

Settings → Agents is the authoritative coding-agent section. Its Pi page uses the
existing Settings rows, groups, switch and button styles. No future catalog rows
are added. The old Pi category remains only an internal navigation alias to the
same Agents page; the Agent menu's Agents action and legacy configuration sheet
also open these controls. The separate existing Agent defaults page remains.

`AgentManagerModel` derives state/actions from the Phase 5 installation manager,
not a second installation preference or UI-owned executable path. Installation
state and manager busy changes are observable. The screen shows ownership,
selected/detected and installed versions, running installation information,
compatibility/health, missing runtime, failures, staged activation and update
availability. Repeated same-version revisions have retained-installation choices.

Actions route to the actual backend:

- No runtime: Install (when this platform has an approved catalog release), or
  Use Existing Installation through NSOpenPanel. Installation is explicit.
- Managed: Verify, Repair, Remove, an approved newer Update when available, Auto
  Update, compatible retained Roll Back and retained-version selection. Staged
  updates expose Activate Update; running work remains on its old immutable code.
- External: Verify, choose/change an existing executable, Forget. No managed
  update/repair/rollback/executable-removal controls are offered. The picker probes
  a candidate before selecting it; a failed candidate preserves prior selection.
- Retry appears only for a known retryable operation/removal tombstone. Unsupported
  and incompatible results remain distinguishable. Store corruption is reported
  without offering mutations that would overwrite retained bytes.

Remove/Forget and runtime changes that stop owned work have normal macOS
confirmations describing the concrete effect. New update staging itself does not
stop work. Auto Update stays OFF by default; toggling it or visiting this page can
request the existing approved-update check/staging. There is no new daemon, timer,
upstream-latest feed or scheduler. The catalog still contains only Pi 1.4.0 Darwin
arm64, so a real newer-version action is currently absent rather than fabricated.

Global default and current project agent selection are shown using Phase 4 values.
Pi is implicit while it is the only registered production agent. Unknown retained
selection values can be explicitly reset for new sessions; existing session
ownership is unchanged. No hot switching to another harness is implemented.

## Legacy migration and provider separation

ShellState performs an idempotent metadata migration before restoring a workspace:

- Legacy bundled selection becomes Pi with no installed/selected runtime. It does
  not copy, download, probe, delete or adopt the old bundled runtime.
- Legacy external selection is retained as an externally owned registration and
  selected reference. It requires explicit compatibility verification before use.
  Missing paths remain recoverable through Verify / Choose / Forget; they are not
  silently replaced. Previously managed Phase 5 selections remain authoritative.
- Legacy AgentConfiguration bytes, provider settings, permission defaults,
  Keychain entries, native Pi data/configuration/extensions and Milk session data
  are not rewritten by installation preference migration.

The former Runtime executable controls and bundled/external toggle are removed.
`RuntimeSettingsModel` now edits provider configuration only (its internal type
name and test-compatible initializer remain). Saving providers neither probes nor
selects an executable. It continues preserving an unchanged endpoint Keychain
secret and explicit token replacement/removal behavior. Installed idle runtimes
can reconnect after an explicit provider save; no-runtime provider editing remains
possible without trying to launch Pi. Pi built-ins in Extensions are labelled as
Pi built-ins, without implying app-bundled installation ownership.

## No-agent startup and session browsing

Workspace restore no longer starts Pi or provider polling. ShellState's second
layout/session-selection callback also uses a cached-selection path, closing a
separate eager-launch trigger found during inspection. Restored queued work is
still recovered to drafts; session UUIDs, owners, native references and integer
editor linkage remain intact. Model/reasoning/command discovery remains available
before the first prompt through an explicit composer query. Restored slash drafts
and ordinary cache synchronization do not trigger that connection.

Sessions adds Current Project / All Projects. Current Project retains open/recent
rows, drag ordering and guarded actions, adds owner/unavailability information and
includes retained fileless records. All Projects lists indexed records with owner
and project identity; an inspector reads Milk's existing conversation/draft cache
without launching an agent. Current-project retained records can be opened into
existing editor/session linkage as cached work. Inspecting another project does
not rebind ownership, switch projects or imply the session is ready to resume.
All Projects remains usable with no current workspace.

This is the existing metadata index, not a new exhaustive scan of every historical
workspace or native Pi directory. Legacy workspaces join it when opened/migrated.
The inspector can report that a native session has no Milk transcript cache; it
does not manufacture content or launch Pi to fetch it.

Chat exposes useful unavailable/verification text and a Settings → Agents action.
Agent operations fail locally without installing Pi, destroying drafts or asking
for credentials on startup. Files/editor, Git/Diff, Terminal, normal Preview and
native extension/settings surfaces retain their independent services. Their
unrelated broad regression harnesses were intentionally not run in this phase.

## Release resource path and bundled fallback

`scripts/build.sh` no longer calls runtime bootstrap/integrity verification, copies
PiRuntime, signs nested Pi/tools/native modules, or rewrites Pi hashes after signing.
It delegates resources to the allowlisted `scripts/stage-app-resources.py`:

- Milk-authored `MilkPiIntegration.ts`.
- Required text/license/provenance notice metadata.
- The native extension SDK continues through its existing separate build steps.

No Pi executable, Bun binary, Pi-owned rg/fd, native agent modules, wasm, upstream
assets/examples/docs or bundled runtime manifest enters that resource recipe.
An old PiRuntime destination is rejected rather than retained. The release build
needs no Runtime/PiRuntime directory. Existing SDK/app signing commands remain;
no signing/notarization acceptance was performed here.

The production runtime service rejects legacy bundled resolution even if old
bundle files exist. The manager's authoritative no-runtime state cannot fall back
to bundled Pi. Explicit test resource roots retain a fixture-only bundled path,
including isolated probes carrying the same fixture permission; fixtures and the
optional bootstrap/verify scripts are preserved. No production developer-directory
or PATH fallback is introduced.

The resource test executes the same staging function used by build.sh against a
minimal source tree that deliberately lacks Runtime/PiRuntime, and checks exact
resource contents plus obsolete script dependencies. This proves the changed
resource path, not a fully signed app or clean-machine installation. Existing
`output/Milk.app` was not rebuilt/replaced; it may still be the old generated
bundled app. Build the changed recipe under Phase 7 acceptance before using that
artifact as release evidence.

## Focused verification actually run

Executed 2026-10-31 with Xcode and workspace-local Swift caches. Elevated execution
was used for SwiftPM/local fixtures and the isolated provider Keychain test. Logs
are generated evidence under `output/phase6/`.

| Log | Actual scope/result |
| --- | --- |
| `agent-settings.log` | `--filter AgentManagerSettingsTests`: 5 passed, 0 failures. |
| `no-agent-sessions.log` | `--filter NoAgentSessionTests`: 3 tests, 2 passed and 1 fixture failure. The failing case cleared AgentService without closing WorkspaceStore, so Current Project correctly still had a project. |
| `session-fixture-fix.log` | Only the failed Current/All Projects case: 1 passed after closing the workspace as the app does. |
| `shell-restore.log` | One additional case covering ShellState's second layout callback: 1 passed. |
| `explicit-discovery.log` | Only that strengthened case: 1 passed, adding explicit pre-prompt model discovery while keeping restoration offline. |
| `clean-resources.log` | `python3 Tests/Fixtures/test_clean_app_resources.py`: 1 passed. |

There are five new management/settings tests and four distinct new no-agent/session
tests. They verify metadata-only/idempotent bundled/external migration, explicit
external verification and protected action sets, transactional managed action
routing, staged/running revision separation, Auto Update persistence, valid Retry,
failed picker candidate retention, provider-only saving with unchanged Keychain
secret, offline restore/cache/draft recovery, current/all-project filtering,
immutable ownership/editor linkage, production fallback rejection despite old
files, and the shell restore versus explicit discovery boundary.

No successful group was repeated. Only the failed case and the subsequently
strengthened shell case were rerun. Compilation built the app; no separate build
ran. The resource recipe test did not invoke signing or a full packaging build.
No compiler warnings occurred in the successful runs. No full suite, general visual
inspection, screenshot sweep, native verifier/harness sweep, unrelated test matrix,
clean-machine or notarization acceptance ran. No commit, push or GitHub action
occurred.

## Remaining release issues and Phase 7 recommendation

No official network download was exercised here. Real managed artifact extraction,
launch/quarantine/signature behavior, moved clean app execution, and compatible
session/provider/extension behavior need the authorized acceptance pass. There is
only one approved Pi version; tests use local same-version immutable revisions,
not invented cross-version compatibility. Native harnesses and fixture setup need
acceptance reconciliation with clean packaging and explicit lazy startup.

Bun/native matching source, reconstruction/relink and downloaded-artifact
distribution obligations remain unresolved. Retaining notices and moving code out
of Milk.app does not establish legal or production distribution readiness. Managed
full-tree verification startup I/O and conservative cross-instance exclusion also
remain practical acceptance considerations.

Phase 7 should run the broad Pi parity and workspace regression matrix once,
exercise the actual clean build/package, verify no-runtime and external migration
on a clean/moved app, and check real managed install/update/repair/remove and owned
shutdown with retained data. Perform release signing/notarization/provenance review
under that phase's authorization. No Phase 7 work or other agent, Computer Use,
orchestration, marketplace, public adapter SDK or unrelated roadmap feature is
implemented here.

## Exact files added

- `Sources/Milk/AgentManagerModel.swift`
- `Sources/Milk/AgentsSettingsView.swift`
- `Tests/MilkWorkspaceTests/AgentManagerSettingsTests.swift`
- `Tests/MilkWorkspaceTests/NoAgentSessionTests.swift`
- `Tests/Fixtures/test_clean_app_resources.py`
- `scripts/stage-app-resources.py`
- `docs/PHASE_6_AGENTS_UI_AND_CLEAN_APP.md`

## Exact files modified

- `Sources/Milk/AgentDialogs.swift`
- `Sources/Milk/AgentInstallationStore.swift`
- `Sources/Milk/AgentService.swift`
- `Sources/Milk/ChatPanel.swift`
- `Sources/Milk/DesignSystem.swift`
- `Sources/Milk/ExtensionService.swift`
- `Sources/Milk/MainWindow.swift`
- `Sources/Milk/MilkApp.swift`
- `Sources/Milk/PiAdapter.swift`
- `Sources/Milk/PiCompatibilityProbe.swift`
- `Sources/Milk/PiInstallationManager.swift`
- `Sources/Milk/PiRuntimeService.swift`
- `Sources/Milk/SessionsSidebarView.swift`
- `Sources/Milk/SettingsComponents.swift`
- `Sources/Milk/SettingsService.swift`
- `Sources/Milk/SettingsView.swift`
- `Sources/Milk/ShellState.swift`
- `Sources/Milk/SlashCommands.swift`
- `scripts/build.sh`
- `README.md`
- `RUNTIME.md`
- `ThirdPartyNotices/README.md`

Generated logs, before-change snapshots, build caches and Python bytecode are not
source deliverables.
