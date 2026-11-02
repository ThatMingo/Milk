# Executable purpose contracts

Phase 6 classifies the current agent-related launch paths. Sandbox ON applies the
contract below; OFF is explicitly unenforced. The approved filesystem policy and
L1/L2 decisions remain authoritative. This is production-purpose coverage, not a
Phase 7 release, live-provider, supported-OS-matrix or final adversarial certification.

## Inventory

| Purpose / entry | Filesystem and runtime inputs | Environment / private state / lifetime |
| --- | --- | --- |
| Conversation: `PiBackend` → `PiLaunchResolver` → `PiRPCClient` | Current project policy, selected profile, inactive/Protected boundaries, validated selected executable/interpreter/module graph and named Pi resources. Code dependencies are read-only. | Pi-owned provider domain; selected HOME/profile, private activation TMP/cache. Keychain Local injection happens last. Runtime lease owns shutdown. |
| Preview inspection: `PiAdapter` → discovery `PiBackend` | Project Read Only; minimal outside dependencies and read tools, private active profile; source profile stays inactive. | ON uses private HOME/profile/TMP; configured Local inference may receive the approved Pi-domain key. Auxiliary inspection lease drains before deleting private data. OFF retains the existing explicit compatibility path. |
| Version: `PiRuntimeService.version` / `PiUtilityProcess` | Validated executable/interpreter/code/module dependencies and named adjacent Pi resources; no normal project/profile grant. | Secret-free private HOME/TMP/cache/profile/workspace. Timeout/cancel/settings changes terminate and await owned process cleanup, then remove storage. |
| Compatibility: `PiCompatibilityProbe` | Same narrow code closure plus Milk integration/bridge files and required RPC checks; no user extensions/MCP/skills/session/model prompt. | Private HOME/TMP/profile/workspace, no provider credential. Current policy applies even without task-local caller context. Owned lease retains code/state through cleanup. |
| Install/update/repair candidate: `PiInstallationManager` → version/compatibility | Hash-pinned, validated candidate tree read-only; approved artifact platform/architecture/notices/inventory checked before execution and inventory rechecked afterward. | Candidate's executable children use installation/compatibility purpose plans and private state, never an unrestricted validation step. Failed cleanup keeps lifecycle ownership/staging until recovery. |
| Package install/remove: `ExtensionService` → `PiUtilityProcess` | Actual selected runtime, explicit local source read-only, selected target profile writable under stronger policy. No implicit source/project write permission. | Independently sanitized, key-free private HOME/TMP/cache; only PI_CODING_AGENT_DIR points to selected target. Fresh package lease, cleanup awaited. |
| Stock tools / nested tools / user_bash: `PiSandboxExecution` | Selected validated Pi code/resources; existing per-operation project policy and temporary grant profile. | Milk-owned key-free private operation HOME/profile/TMP. Private pipe capabilities and owned cleanup; no implicit job adoption. |
| Explicit background/watcher/Preview jobs: `SandboxHostEffects` | Immutable job request and compiled current policy/grants; normal development tools use declared system/toolchain dependencies. | Independent sanitized HOME/TMP, host UUID/activation/session/project/purpose. Stop/restart/revocation/settings/session/project/runtime ownership from Phase 5. |
| API 2 native worker: `SandboxExtensionExecution` → `MilkExtensionWorker` | Validated helper/library closure, verified package, declared file access and current grant profile. Non-shell tools use minimal system roots; shell-capable tools retain development dependencies. Code is read-only. | Separate signing identity with no Milk Keychain entitlement; private sanitized HOME/TMP, bounded typed IPC, active registration nonce, cancellation/revoke/owner checks. |
| Controlled Git: `SandboxHostEffects.git` | Sandboxed repository preflight; exact recognized real Git operation may escalate. Hooks/helpers/editors remain the explicit accepted exception. | Sanitized Git environment with explicit user Git HOME and validated SSH socket; no Local key. Owned operation scope. No surrounding shell elevation. |

`AgentInstallationStore`, archive download/extraction/inventory and installation
metadata transactions run as trusted Milk host code. They do not launch an archive
helper: libarchive rejects traversal/link/special entries; platform, hash, notice and
inventory validation precede candidate execution. No concrete requirement for a new
archive-isolation process was found in this audit.

Trusted user Terminal, Editor, GitService, user-started Preview and native extension
UI/services remain trusted host features. Their process/posix_spawn paths are not
agent fallbacks. Developer `--verify-*` acceptance helpers are explicit host diagnostic
fixtures, not production agent execution. The only production `PiRPCClient` launch
callers are backend runtime, compatibility and stock worker; each must supply its
ON/OFF classification. Test-only transport overloads explicitly select unenforced raw
protocol fixtures and are absent from the app target.

## Closure rules

`SandboxExecutableClosure` resolves local paths with descriptor/identity checks,
requires executable regular files, inspects thin/universal arm64 Mach-O load commands,
and resolves non-system dylibs/rpaths recursively. It does not execute a utility to
inspect an untrusted candidate. Missing/unresolved, malformed, relative loader or
embedded loader-environment forms fail ON. Inspection has bounded recursion, file
reads and dependency count. It is admission validation, not an atomic transaction
against independent external filesystem modifications.

Absolute shebang interpreters and a supported optional argument are validated.
`#!/usr/bin/env name` resolves only through selected installation/support directories
and system `/usr/bin`/`/bin`, not ambient PATH. `env -S`, assignments and ambiguous
multi-argument forms reject ON. The validated interpreter/argument chain executes the
same selected script explicitly. Apple Python/Swift/xcodebuild/xcrun shims resolve to
the selected validated developer executable; no hidden global-cache or unclassified
Xcode-helper retry is admitted. The script/runtime identity remains selected rather
than silently substituted. npm-style module entry points receive their real bounded
node_modules graph; native Pi receives named adjacent resources, not its whole parent.

Declared dependency symlinks and required ancestor metadata are admitted literally.
Data access still needs the canonical dependency and stronger policy cannot be
bypassed. Homebrew libcrypto declares only its named OpenSSL config/certificate
inputs; other undeclared resources fail closed. No broad HOME/Homebrew grant, ambient
loader/shell/Git injection state or provider key is added to fix missing dependencies.
Environment path values do not themselves create filesystem permissions. Opaque
launchers requiring undeclared state are unsupported ON; OFF remains a user choice.

## Purpose ceilings and package inputs

`SandboxPurposePlan` intersects the general policy compiler with purpose read/write
ceilings. Private scratch state is writable; normal user/profile/project files are
not admitted merely because a process expects HOME or a cache. Protected, inactive,
Read Only and overlapping stronger roots continue to win. Compatibility discovery
has no persistent profile; package execution has only its explicit selected target.
Sources stay read-only, including under a normally writable project/target.

Seatbelt pathname rules alone cannot make one inode read-only under one name and
writable under another. Package admission rejects existing source/target hard-link
contradictions and source symlinks crossing into a writable target. Metadata inventory
is bounded at 100,000 entries per tree and fails on uninspectable input. This does not
claim an atomic filesystem transaction against independently authorized concurrent
writers. The child cannot use the read-only source as an implicit writable root.

## Policy changes and rollout

A security-relevant setting edit closes old grants/admission and stops/drains affected
runtime/jobs/probes. Previously connected conversations reconnect only after old
coordinator barriers finish, using current policy. Unconnected history stays lazy.
Managed jobs stop and require a fresh explicit start rather than reusing grants.
Timeout-only edits do not relaunch immutable profiles. Auxiliary plans observe the
shared Settings store and recheck policy/identity at admission and completion.

Default/missing settings are ON. Existing explicit OFF remains OFF; Ask/Autonomous
stays independent. Invalid settings, missing profiles and unsupported closure reject
instead of silently selecting OFF, a different runtime or unrestricted retry. Runtime
status says ON or OFF (unenforced); Settings no longer describes preparatory coverage.
No preference schema reset or overriding saved user choice is part of rollout.

The accepted detached-survivor limitation remains: future admission expires, owned
groups clean up, deliberately detached processes may retain inherited static access.
Pi and its own children/extensions/MCP retain the accepted inference-key domain;
Milk workers/jobs do not inherit it. Existing-profile-only configured-provider Preview
inspection remains explicit: no arbitrary auth/profile copy or universal broker was
introduced. The acceptance report records automated concurrency/runtime coverage;
manual-human, broader-host and live-provider coverage remains explicitly unclaimed
where unavailable; Developer ID/notarization are optional distribution improvements.


Final acceptance found that pathname exclusions alone cannot protect pre-existing
hard-link aliases of an explicitly Protected regular file. ON profile construction
now rejects that multi-link input before spawn. This is separate from the package
source/target alias check and does not claim global alias enumeration or atomic
protection against independent writers. Current-host evidence and remaining external
release gates are recorded in [Sandbox acceptance](SANDBOX_ACCEPTANCE.md).


Real Xcode builds can require the macOS per-user `TemporaryItems` item-replacement
folder even with private TMPDIR and project-scoped DerivedData/cache flags. Milk does
not admit that shared folder automatically: a command may explicitly request it
through the normal temporary folder approval flow. The acceptance build verifies
that an Allow Once grant enables the build while unrelated outside writes remain
denied and the grant expires for future admission. The folder can contain other
applications' temporary data, so this is extra reviewed authority, not private cache
redirection. Private-TMP-only Xcode builds are not claimed; Swift compilation with
private module caches is independently covered. See [acceptance](SANDBOX_ACCEPTANCE.md).
