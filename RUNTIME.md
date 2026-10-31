# Runtime architecture

Milk ships without a coding agent. Pi is the only registered production agent;
its adapter is compiled into Milk, while the Pi executable is installed separately.
This document describes the current system. For verification evidence and its
limits, see [provider/profile final acceptance](docs/PROVIDER_FINAL_ACCEPTANCE.md)
and the earlier [agent baseline](docs/AGENT_PHASE_FINAL_ACCEPTANCE.md).

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
Milk-authored extension using Pi's public hooks for approvals, the integration
handshake and the native extension bridge. Provider registration is not part of
that extension. It remains an app resource, not a coding-agent
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
| Managed Pi auth, configuration, native sessions, extensions, skills and prompts | Milk-owned `~/Library/Application Support/Milk/Agents/pi/profile/` |
| Existing Pi state | Existing profile, normally `~/.pi/agent`, or its ambient `PI_CODING_AGENT_DIR` |
| Milk workspace/editor recovery, drafts and retained conversation metadata/cache | `~/Library/Application Support/Milk/Workspaces/` |
| Milk preferences and installation selection metadata | UserDefaults and the separate managed-installation store |
| Adapter-requested provider credentials | Keychain, scoped by agent, provider and endpoint; passed to Pi through its child environment in memory |
| Pi provider settings presented by Milk | Pi-specific UserDefaults key `Milk.agent.pi.providers.v1`; separate from installation state |

These locations can contain private data and are not source repository contents.
Installing/removing executable revisions does not copy, convert or erase Pi's
existing profile. Managed installs do not copy the existing profile. Runtime removal
preserves the managed profile for reinstall. Provider drafts are scoped separately
for managed and existing setups; see [profile ownership](docs/PI_PROFILE_OWNERSHIP.md).

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

Milk manages coding agents. Coding agents own provider/model configuration:
**Milk → Coding Agent → Provider → Model** (currently Pi only). Global Settings
has no provider or model configuration. `AgentAdapter.settingsProvider` is an
optional `AgentSettingsProviding` facet: core lists opaque native settings sections
and hosts adapter-supplied SwiftUI content. It assumes no endpoint, key, model or
reasoning schema. Installation management remains separate.

`PiAdapter` exposes its own provider selector and conditional Local fields. Local
means an OpenAI-compatible endpoint, independent of the serving application's
brand. Test Connection performs one read-only models request. There is no global
provider polling, status telemetry or Milk inference client. Chat models and
thinking levels still come exclusively from the active backend's Pi RPC replies.

`PiProviderSupport` merges the adapter-owned `milk-local` entry into Pi's documented
`models.json`, preserving unrelated providers and keeping original bytes in a
backup before changed writes. Secrets are environment references in that file;
the actual API key remains in agent/provider/endpoint-scoped Keychain storage.
For None authentication, Pi's documented `before_provider_headers` hook sets
Authorization to null for the adapter-owned Local provider. The static availability
key needed by Pi stays internal: no Authorization header reaches the Local server.
API-key mode retains the profile-scoped Keychain credential and normal bearer
transport. Milk does not perform inference or register a replacement provider.

Model discovery preserves exact IDs and optional per-model effective metadata.
Explicit per-model numeric overrides win over reported limits. Auto uses the
authoritative reported value if present, otherwise omits that field. Unknown limits stay unknown in Milk and are omitted from models.json. Pi accepts
these models and supplies its own effective defaults; Milk does not supply
universal numbers or require manual limits. Optional Advanced overrides remain
per-model. Unknown reasoning/image fields are omitted; Pi then reports its
conservative effective behavior through RPC. Milk does not change compaction or
infer token usage. Model selection uses exact `set_model` RPC, avoiding CLI fuzzy
matching or thinking suffix parsing.

Provider save uses the existing lifecycle guard: running/start/pending work,
approvals and auxiliary inspection/maintenance block reconfiguration. Successful
save persists the Pi-specific draft, applies Pi configuration, and reconnects idle
runtimes. It does not create or reassign sessions, move Pi data, or erase drafts
or history. Session-specific composer choices still restore when Pi reports them
as available. Legacy shared preferences and credentials remain for recovery;
active profile-scoped settings do not automatically import ambiguous shared
development state. The retained legacy decoder discards global token-limit guesses.

See [agent provider settings](docs/AGENT_PROVIDER_SETTINGS.md) for the settings
contract, source fields, migration details, and focused verification evidence.

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

## Pi profile selection

Managed runtime ownership requires a Milk-managed `AgentDataProfile`. The manager
validates `store.root/profile` (including rejecting links that escape ownership),
and the launch resolver sets `PI_CODING_AGENT_DIR` in the child environment before
any Pi probe or startup. Pi uses this supported agent directory for its complete
persistent profile, rather than just models.json. Existing installations retain
their ambient agent directory and setup. Compatibility probes remain ephemeral.
Provider settings, extension management and package commands use the same selected
profile. Managed launches reject native resume files outside it without modifying
those files. Runtime deletion removes versions only, preserving profile data.
This selects Pi's persistent profile; it is not an OS sandbox, and explicit
project configuration/resources and trusted extension code retain Pi's normal
behavior. No upstream Pi code is patched.
