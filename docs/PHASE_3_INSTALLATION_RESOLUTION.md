# Phase 3 — installation resolution and compatibility

> Historical phase record. This document records its original scope and evidence;
> it is not the current implementation or acceptance status. See
> [Agent final acceptance](AGENT_PHASE_FINAL_ACCEPTANCE.md) and the
> [source-publication audit](PRE_GITHUB_AUDIT.md). Evidence paths under `output/`
> refer to generated local files excluded from the public source tree.

Scope: installation value types, immutable launch resolution, one Pi compatibility
policy and an isolated candidate probe. This builds on the
[Phase 2 lifecycle owner](PHASE_2_AGENT_LIFECYCLE.md),
[Phase 1 adapter](PHASE_1_AGENT_BOUNDARY.md) and
[Pi parity contract](PI_PARITY_CONTRACT.md). No installer, installation store,
runtime relocation, Agent Manager UI or session migration is implemented.

## Architecture implemented

- `AgentInstallationRecord` identifies an agent's executable, installation ID,
  ownership and source. Ownership distinguishes Milk-managed, user-selected
  external, and the transitional application bundle. Optional version/hash pins
  can describe an existing managed candidate. Records are values only: no
  installation discovery, persistence, downloading or mutation is performed.
- `AgentDataProfile` independently describes shared existing Pi storage or an
  ephemeral Milk probe directory. Executable ownership never grants ownership of
  credentials, user configuration, extensions or sessions. Existing preferences
  still use `PiRuntimeMode`; no preference or session schema migration occurs.
- `PiLaunchResolver` translates the existing explicit runtime choice into a
  `PiLaunchContext`: installation identity, executable, detected version,
  integration resource, installation-local support paths, environment, data
  profile and compatibility evidence. The environment is in-memory only.
- `PiAdapter` supplies the resolver through a Pi-specific closure to PiBackend.
  Backend startup consumes the resolved context rather than locating runtime
  files, reading manifests, checking versions or assembling search-tool paths.
  Generic agent APIs do not acquire Pi launch flags or provider configuration.
- `AgentCompatibilityResult` is distinct from connection state. It distinguishes
  supported, unsupported, untested, incompatible integration and invalid runtime.
  Evidence distinguishes a supported version from a completed RPC/integration
  handshake; `usable` requires both. Runtime status exposes compatibility and
  installation identity while retaining existing UI compatibility fields.

## Runtime and compatibility corrections

External resolution never reads the bundled manifest. It requires the explicitly
selected executable and Milk's own integration resource. It uses the selected
launcher directory (including shebang interpreter dependencies) and any recognized
installation-local `bin` search tools; it does not silently borrow tools from
Milk's bundled Pi. The same environment is used for its version check. No PATH
search chooses an agent executable.

Bundled resolution continues verifying its existing manifest, executable, tools,
native/wasm assets and version match. A supplied managed candidate requires pinned
version/hash metadata and executable verification, without installing anything.
This is resolution of an existing candidate, not a complete future managed
artifact/provenance validation implementation.

`PiCompatibilityPolicy` is the single app-side version policy, initially allowing
Pi 1.4.0. Older versions are unsupported; unknown newer versions are untested and
blocked; malformed versions are invalid. Settings no longer independently compares
version output with the bundle manifest. Both Settings validation/save and backend
startup use this policy. Build/packaging artifact pins remain unchanged.

Live startup validates the required state, command, model, thinking-level and
history reply shapes, plus Milk's integration-ready marker, before publishing
usable/ready. Initial command-discovery incompatibility fails startup; subsequent
dynamic refresh failures retain the existing empty-catalog behavior. No model
prompt or extra preflight RPC process is added to normal conversation startup.

Pi extension package actions now resolve the selected runtime through the same
resolver/lifecycle owner. ShellState supplies the existing configuration choice;
standalone ExtensionService defaults remain bundled for compatibility. Explicit
user-requested configuration/package operations remain permitted, preserving the
selected Pi data directory and local source files. External executable files are
never replaced, updated or deleted by these paths.

## Candidate probe

`PiCompatibilityProbe` registers a compatibility-purpose lease with the Phase 2
coordinator before doing runtime work. It resolves/version-checks the candidate,
then starts native RPC with no saved session, user extensions, MCP, skills or
templates, and read-only tools. Both version and RPC execution use an isolated
temporary cwd and `PI_CODING_AGENT_DIR`. Provider/native bridge overrides are
removed from the RPC environment. The probe sends only state/catalog/history
inspection requests, cancels interactive dialogs, and never sends a prompt.

It validates the same required reply shapes and integration marker as startup.
All return/error/cancellation paths await owned shutdown before removing the
temporary directory. Cleanup failure propagates and remains owned under Phase 2;
it cannot yield a usable result. There is no credential copying, Keychain change
or ordinary Pi configuration/history rewrite. This is a protocol health probe,
not an OS sandbox for an untrusted executable or proof of future model/provider
availability. External compatibility is point-in-time; live startup still
performs its handshake.

## Verification actually performed

Verified on 2026-10-31, using Xcode, workspace-local caches and elevated execution
for local process fixtures:

| Run | Result | Evidence under `output/phase3/` |
| --- | --- | --- |
| `swift test … --filter PiInstallationTests` | 6 tests, 0 failures | `focused.log` |
| `swift test … --filter PiParityTests` | 4 tests, 0 failures | `pi-parity.log` |

The first focused invocation compiled the changed application and tests, so no
separate build was needed. Neither successful group was repeated. No full suite,
native harness, screenshot generation, visual inspection, packaging or signing
verification ran. The PiJSONLFramer/PiRPCClient implementation was compared with
the Phase 2 snapshot and is unchanged.

The six focused tests cover:

1. Central version classifications and separation of executable/data ownership,
   including a pinned synthetic managed candidate and a missing executable.
2. Adapter-backed external RPC startup with no bundled metadata or tools,
   installation identity, version-only versus handshake evidence, and data retention.
3. Candidate rejection for version-only execution, missing integration marker,
   malformed required replies, and untested versions; startup/probe policy agrees.
4. A real bundled Pi probe with ordinary configuration containing an extension
   that must not load; ordinary data remains byte-for-byte unchanged.
5. Cancellation during an isolated RPC request, confirmed process exit and
   temporary-directory removal through the lifecycle owner.
6. Explicit extension package-command routing through the selected external
   executable without bundled metadata. A controlled CLI fixture tests routing;
   full real package mutation regression is intentionally deferred.

Existing SettingsTests received one optional-manifest assertion adjustment for
compilation; the Settings matrix was not run. Existing parity fixtures gained
opt-in compatibility fault/log controls; their default behavior is preserved.

## Exact source manifest

Added:

- `Sources/Milk/AgentInstallation.swift`
- `Sources/Milk/PiCompatibility.swift`
- `Sources/Milk/PiCompatibilityProbe.swift`
- `Sources/Milk/PiLaunchContext.swift`
- `Tests/MilkWorkspaceTests/PiInstallationTests.swift`
- `docs/PHASE_3_INSTALLATION_RESOLUTION.md`

Modified:

- `Sources/Milk/AgentAdapter.swift`
- `Sources/Milk/AgentModels.swift`
- `Sources/Milk/ExtensionService.swift`
- `Sources/Milk/PiAdapter.swift`
- `Sources/Milk/PiBackend.swift`
- `Sources/Milk/PiRuntimeService.swift`
- `Sources/Milk/SettingsService.swift`
- `Sources/Milk/ShellState.swift`
- `Tests/Fixtures/pi_parity_peer.py`
- `Tests/MilkWorkspaceTests/SettingsTests.swift`

## Deferred coupling and Phase 4 recommendation

The application still bundles Pi, uses existing bundled/external preferences and
Pi settings navigation, and retains native JSONL session references and current
external-session deletion restrictions. Legacy `bundled`/version display fields
remain compatibility shims. Only Pi is registered; MilkExtensionKit API 1 and the
TypeScript integration are unchanged.

No catalog/feed, installation persistence, download, update, rollback, repair,
removal, new managed data profile, project agent selection, Agent Manager,
session index, packaging or signing change is included. Managed artifact closure,
provenance/signature policy and distribution acceptance remain future work.

Phase 4 should add agent-owned session metadata and project selection through an
additive persistence migration, preserving integer editor linkage, native Pi
references and ordinary storage. Reuse installation IDs and compatibility results;
do not conflate missing installation, unsupported version, authentication or
session ownership. Keep executable-management work in its separately authorized
phase. No commit, push or GitHub action occurred.
