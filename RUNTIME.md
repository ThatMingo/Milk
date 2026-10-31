# Runtime architecture

Milk ships without a coding agent. Pi is the only registered production agent;
its adapter is compiled into Milk, while the Pi executable is installed separately.
This document describes the current system. For verification evidence and its
limits, see [Agent final acceptance](docs/AGENT_PHASE_FINAL_ACCEPTANCE.md).

## Agent boundary

```text
Milk UI / AgentService
  → AgentAdapter
  → PiAdapter
  → PiBackend / PiRPCClient
  → native Pi RPC
  → selected model provider
```

`AgentAdapter` is Milk's internal capability/session boundary. `PiAdapter`
implements it without changing upstream Pi. `Runtime/MilkPiIntegration.ts` is a
Milk-authored extension using Pi's public hooks for approvals, provider registration
and the native extension bridge. It remains an app resource, not a coding-agent
runtime. There is no downloadable/public agent-adapter SDK or second production
agent implementation.

Each connected conversation has its own RPC process. Sessions can run concurrently;
switching the selected conversation does not stop another session. Connections are
lazy: restoring a workspace or browsing retained history does not launch Pi,
install a runtime, probe an executable or start provider polling. Agent work and
explicit verification/provider actions can start the relevant owned processes.

## Installation and compatibility

Settings → Agents is authoritative. The production app has three states:

| State | Code ownership and behavior |
| --- | --- |
| No selected runtime | Files, editor, Git, Terminal, normal Preview and retained history remain available; agent work asks for installation or verification |
| Milk-managed Pi | Milk owns immutable executable revisions under `~/Library/Application Support/Milk/Agents/pi/` |
| Existing Pi | The user selects an executable explicitly; Milk owns its registration, not its executable files |

Milk does not select Pi from PATH and has no implicit bundled fallback. Legacy
bundled preferences migrate to Pi with no selected runtime; existing external
references are retained and require verification. Neither migration installs code
or moves ordinary Pi user data. Fixture-only legacy paths in tests are not a
production fallback.

The compiled catalog and compatibility policy currently approve **Pi 1.4.0 on
Darwin arm64**. A version response alone does not establish compatibility.
`PiCompatibilityProbe` starts a candidate with temporary agent storage/workspace,
no saved session, and discovery of user extensions/skills/prompts/MCP disabled.
It checks required native RPC reply shapes and the Milk integration handshake,
then awaits shutdown before removing probe storage. It does not send a model
prompt or use a personal session. Live startup also validates the required
protocol and integration before publishing readiness.

### Managed revisions

Installations download only approved, hash-pinned artifacts. The manager validates
archive boundaries, platform/architecture, required file digests and notices;
then probes the candidate and checks that its inventory has not changed. Verified
code becomes a new immutable revision and is selected through atomic metadata
updates. Repair also creates a new revision rather than changing code in place.

Updates can stage while Pi is in use, then activate at a safe lifecycle boundary;
an explicit stop-and-activate action drains owned work first. Auto Update defaults
**off** and considers only approved catalog entries, not arbitrary upstream latest
releases. Roll Back requires an approved retained revision and compatible retained
session runtime metadata. It does not reverse upstream user-data migrations.
Only one real approved Pi version exists today; final acceptance does not claim
real cross-version update/rollback coverage.

Verify, Repair and Remove apply to managed code. Existing installations support
explicit compatibility verification and forgetting their registration; Milk does
not update, repair by replacement or delete their executable files. Removal of
managed code preserves Pi user data and Milk's retained session caches. Full-tree
managed integrity checks add startup I/O; that cost remains unbenchmarked.

## Lifecycle ownership

`AgentLifecycleCoordinator` owns conversation, Preview inspection, compatibility
probe, utility-command and installation-transaction leases. Ownership begins
before asynchronous startup and continues while work is closing. Each lease
carries activation identity and relevant writer/installation associations.

Restart, configuration/workspace handoff and matching session-file mutations
invalidate old work and await the required writers before replacement. Stale
callbacks cannot update a new activation. Unrelated conversations remain
concurrent. A failed resource exit retains ownership and blocks a conflicting
replacement until cleanup can be confirmed; cancellation does not silently drop
a process that is still starting.

Pi transport teardown closes stdin for graceful exit, then uses bounded TERM/KILL
fallback on the owned process. Utility commands and probes also participate in
awaited cleanup. The app's `terminateLater` path waits for four cleanup
participants: agent lifecycle, native extension work, Terminal and Preview. Main
window close uses that same termination path. Cleanup failures are reported;
force-quit/crashes do not provide the guarantees of normal shutdown.

Preview stops only its managed process groups; entering an external server URL
does not grant process ownership. Terminal owns a login-shell OS session and its
ordinary foreground/background jobs; hiding the panel preserves that session.
Neither feature requires Pi. Milk does not kill unrelated processes by name,
port or working directory. Deliberately daemonized processes can escape ordinary
process-group/session cleanup.

## Sessions and user data

Executable ownership is independent of data ownership:

| Data | Owner / storage |
| --- | --- |
| Pi auth, configuration, native sessions, extensions, skills and prompts | Ordinary Pi storage, normally `~/.pi/agent`, or the explicit `PI_CODING_AGENT_DIR` |
| Milk workspace/editor recovery, drafts and retained conversation metadata/cache | `~/Library/Application Support/Milk/Workspaces/` |
| Milk preferences and installation selection metadata | UserDefaults and the separate managed-installation store |
| Milk oMLX provider token | Keychain, keyed by endpoint; supplied to owned requests/child environment in memory |

These locations can contain private data and are not source repository contents.
Installing/removing executable revisions does not copy, convert or erase Pi's
ordinary profile. Provider settings and credentials survive installation changes.

Sessions retain their creating agent and workspace identity plus an adapter-owned
native reference. Milk caches presentation for offline browsing; an unavailable
runtime is shown as unavailable rather than starting it on inspection. Browsing
All Projects neither reassigns a session nor silently switches projects. Closing
preserves history; deleting native history is a separate guarded operation and is
unavailable for external Pi or running/pending sessions. Reopen/resume uses Pi's
native session identity rather than converting its files into a Milk-only format.

## RPC, approvals and providers

`PiRPCClient` frames and correlates native JSON RPC, bounds captured data and
handles request cancellation/deadlines and process failures. Pi events become
Milk transcript, activity, dialog and session state. The settled event marks the
completion boundary; an agent-end event alone does not rule out retries or
follow-up work. Queue, Steer and Stop use native Pi operations. Steering applies
between turns/tool batches, not inside an already running command.

Milk's integration gates mutating/unknown tools in Approval mode and allows tools
in Autonomous mode. Dialogs stay tied to their originating session/activation;
host Preview/native-extension approvals keep their own ownership. Exact-input
session allowances are not persistent blanket grants. Tool approval is not an
OS sandbox, and trusted native/Pi extension code runs with user permissions.
Models, reasoning levels and image support come from the live provider catalog;
Milk does not advertise a fixed sample capability set.

Pi keeps its existing provider configuration. Milk's optional oMLX adapter adds an
external HTTP(S) endpoint and model settings without replacing other Pi providers.
`OMLXService` performs read-only status/model requests; polling begins with agent
use or an explicit provider action, not workspace restoration. Milk does not
install, launch, stop or update oMLX or its model weights. Tokens stay in Keychain
and are not serialized into workspace recovery. Milk has no OAuth/login setup
flow; authentication remains Pi's responsibility where supported.

Native Milk extensions use the shared MilkExtensionKit library and the protected
Milk/Pi bridge; Pi extensions remain separately loaded Pi resources. Native
extensions run in process after explicit trust and can crash or block Milk.
Capabilities constrain supported services, not arbitrary native code. See the
[extension guide](docs/EXTENSION_DEVELOPMENT.md) for API, package and lifecycle
contracts.

## App resources and test fixtures

```text
Milk.app/Contents/
  MacOS/Milk
  Frameworks/libMilkExtensionKit.dylib
  Resources/
    MilkPiIntegration.ts
    ThirdPartyNotices/
    ExtensionSDK/
```

The resource staging allowlist excludes Pi, Bun, Pi-owned search executables,
`.node`, `.wasm`, upstream assets and runtime manifests. Building the app requires
no agent bootstrap. Optional upstream fixtures under ignored `Runtime/PiRuntime/`
are separate test inputs; they are not discovered by production runtime selection.
Build and fixture commands live in [developer setup](docs/DEVELOPMENT.md).

## Source publication and app releases

The [source-publication audit](docs/PRE_GITHUB_AUDIT.md) assesses the prospective
source snapshot, not app redistribution. Final acceptance records successful
managed and external Pi execution on the development host and 156/156 tests;
it does not establish clean-machine trust or complete GUI acceptance.

Developer ID signing, notarization, stapling and clean-machine acceptance remain
release gates. Bun/native matching-source, reconstruction, relinking, provenance
and downloaded-runtime distribution review remains unresolved. Hash verification,
retained notices and keeping binaries outside Milk.app do not establish release
clearance. See [third-party notices](ThirdPartyNotices/README.md) and
[final acceptance](docs/AGENT_PHASE_FINAL_ACCEPTANCE.md) for the recorded limits.
