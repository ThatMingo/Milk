# Milk Sandbox Architecture

**Status:** Approved target design  
**Baseline reviewed:** `security/api-keychain` at commit `c00305f72821c04ae1f76cb0327d3a465bc7b7a5`  
**Purpose:** Durable design source of truth for the Milk agent-sandbox/runtime-hardening phase.

This document defines the approved target behavior. The repository may advance after the baseline above; implementation must always be reconciled against the current code before editing. Do not silently change these product/security decisions because the current implementation differs.

## 1. Goal

Milk remains a trusted native macOS host while coding agents run inside a constrained environment.

The sandbox must:

- let agents work autonomously inside the active project;
- constrain access outside the project;
- give sensitive locations stricter handling;
- support temporary runtime permissions without permanently widening a long-running agent process;
- protect Milk Local provider credentials at rest and prevent their inheritance by Milk-owned sandbox executors and Milk Extension workers;
- work for Pi first without making the Milk core Pi-specific;
- preserve Milk-owned Editor, Git, Terminal, Preview, Settings, installation management, and other host functionality.

Target hierarchy:

```text
Milk trusted host
  → Milk Sandbox System
  → AgentAdapter
  → agent runtime (Pi first)
  → provider
  → model
```

The Sandbox System belongs to Milk above the adapter layer.

## 2. Non-goals for the initial phase

- Do not add broad network restrictions yet.
- Do not redesign every provider or introduce a Milk-wide credential broker/proxy.
- Do not add a second destructive-operation confirmation system.
- Do not add a per-agent Sandbox ON/OFF toggle initially.
- Do not patch upstream Pi.
- Do not depend on Codex being installed.
- Do not turn Milk's host bridge into a generic privileged filesystem/command service.

Network remains available initially; therefore filesystem read restrictions around sensitive data still matter because data can be exfiltrated.

## 3. Two independent permission systems

Milk already has agent interaction modes:

- **Ask for approval**
- **Autonomous**

Add a separate Milk-owned:

- **Sandbox ON**
- **Sandbox OFF**

These are independent.

### Ask for approval

Controls ordinary agent/tool approval behavior.

### Autonomous

Skips ordinary Milk agent-approval prompts, but does **not** disable sandbox protections.

User-facing meaning should become:

> Autonomous allows agent actions without normal approval prompts. Sandbox protections still apply.

### Sandbox OFF

Milk applies no Milk Seatbelt/sandbox filesystem restrictions or sandbox grant UI. Existing Ask/Autonomous behavior still exists.

Default Sandbox state: **ON**.

## 4. Fixed runtime sandbox + per-operation sandbox executor

Do not try to mutate/expand the Seatbelt profile of a long-running agent process.

The long-running agent runtime receives a fixed sandbox for its lifetime.

Model-controlled operations are executed through a Milk-controlled per-operation boundary:

```text
Model
  → Agent
  → Milk tool bridge
  → Milk Sandbox Executor
  → short-lived sandboxed operation
```

The implementation may differ by adapter, but the security property is mandatory: runtime grants must apply to the specific operation/execution, not permanently widen the long-running agent.

This model is intentionally similar to Codex's per-execution sandbox/permission architecture.

### Allow Once

- issued only to the requested operation's sibling-executor sandbox profile;
- never widens the fixed long-running Pi runtime or a future operation;
- immediately removed from future-operation admission when the operation finishes,
  is cancelled, times out, or otherwise ends.

Expiry means the permission is no longer active for future operations. It does
**not** mean authoritative removal of permissions already inherited by a surviving
process. Milk performs the owned-process cleanup in §11. A deliberately detached
survivor may retain that operation's Seatbelt profile, including its temporary
folder permission, until it exits. This is an explicitly accepted security
limitation, not an escape from Seatbelt. Never reuse the expired grant because
such a survivor remains alive.

### Allow for Session

- stored only in memory;
- reused by later Milk sandbox-executor operations for the same live agent runtime/session scope;
- ends when Milk quits;
- ends when the relevant agent runtime crashes/restarts;
- ends when the runtime is deliberately restarted/replaced;
- must not be restored merely because a saved chat/session is reopened.

Session revocation closes admission immediately and cancels/drains affected
in-flight operations using §11 cleanup. Restart/replacement and Milk shutdown
likewise invalidate future use. Existing processes cannot have inherited static
Seatbelt profiles retroactively shrunk; the same accepted detached-survivor
limitation applies. Do not report authoritative revocation from those survivors
or delay grant invalidation until a best-effort process search succeeds.

The executor must receive a separately constructed, sanitized environment. It must not inherit provider secrets from the long-running agent process.

## 5. Sandbox Settings

Add a dedicated Milk-owned Sandbox settings page consistent with the existing native Settings design.

It contains:

### Global Sandbox

- Sandbox ON/OFF
- default ON

### Agent Project Access

- Read & Write
- Read Only
- default Read & Write

This setting controls the coding agent, **not Milk itself**.

Milk Editor, GitService, Preview, Settings, etc. remain trusted host features.

### Allowed Folders

Two persistent sections:

- Global Allowed Folders
- Project Allowed Folders

Each folder can be:

- Read Only
- Read & Write

Persistent entries are added/edited only through Settings.

### Temporary Permissions

Show current once/session grants where useful and allow revoking active session grants.

### Autonomous Permission Timeout

UI:

```text
[ 30 ] [ seconds ▾ ]
```

Units:

- seconds
- minutes
- hours

Default/recommended: **30 seconds**.

The runtime popup countdown displays live seconds.

### Protected Locations

Editable list of paths receiving stricter policy.

Allow:

- add;
- edit;
- remove;
- Restore Recommended Defaults.

Restore Recommended Defaults:

- adds back missing recommended paths;
- preserves all custom user-added entries;
- never deletes custom entries.

No protected location is permanently hardcoded. Recommended defaults are user-editable/removable.

## 6. Project policy

The active project is the primary agent workspace.

Default Agent Project Access: **Read & Write**.

### Read & Write

Agent-controlled operations may read/write project content according to sandbox policy.

### Read Only

- model/agent project writes are blocked;
- do not show a permission popup for those writes because the user explicitly selected Read Only;
- project reads remain available;
- Milk's own host features remain fully functional;
- Milk-controlled build/cache locations may remain writable where needed.

### Policy precedence (strongest to weakest)

Apply this order to canonical/real targets, including overlapping roots:

1. Protected Locations
2. Inactive agent profiles
3. Project Read Only
4. Explicit persistent allowed-folder grants
5. Active-profile permissions
6. Normal project permissions
7. Autonomous outside-project default

Protected Locations override broader grants. Inactive profiles do not become
automatically readable through Autonomous outside-read or a broader folder grant.
Project Read Only cannot be overridden by a lower-priority writable-folder grant.
Ambiguous overlapping roots must fail safely rather than choose broader access.
Temporary operation grants must follow the applicable higher-priority flow; they
do not permanently reorder policy. The Git escalation boundary in §13 remains a
separate explicit exception, not a general filesystem grant.

## 7. Outside-project policy

### Autonomous + Sandbox ON

Ordinary outside-project filesystem:

- **Read:** automatically allowed only after higher-priority rules, including inactive profiles and Protected Locations, have been applied.
- **Write/delete:** requires sandbox permission.

Protected Locations:

- reads require protected-location permission;
- writes require protected-location permission.

Outside-project write popup:

- Allow Once
- Allow for Session
- Deny

Autonomous popup has the configured countdown. At zero, deny automatically.

After automatic timeout denial, return a semantic message equivalent to:

> Access was denied because the user is temporarily unavailable. Do not immediately repeat the same request. Continue with other work and retry later only if still necessary.

Do not disclose a fixed retry interval to the model.

Milk should suppress/rate-limit immediate identical denied path/action requests to prevent popup spam while still allowing a genuinely necessary later retry.

### Ask + Sandbox ON

Ordinary outside-project reads and writes require a sandbox approval.

Options:

- Allow Once
- Allow for Session
- Deny

No countdown. Wait indefinitely for the user.

Protected Locations use the stricter protected-location flow below.

## 8. Protected Locations

Protected Locations are a user-editable registry, not a hidden immutable deny list.

Recommended defaults may include locations such as:

- `~/.ssh`
- `~/.gnupg`
- browser credential/profile locations
- other sensitive authentication/configuration roots

The exact recommended default set should be reviewed against current macOS behavior before implementation and documented.

Milk provider secrets are protected by Keychain; the Protected Locations list is not the mechanism securing Milk's API keys.

Protected access popup shows:

- exact protected path;
- exact requesting command/tool/action;
- warning that the location may contain credentials/authentication data.

Buttons:

- Allow Once
- Sandbox Settings
- Deny

Do **not** offer Allow for Session for Protected Locations initially.

In Autonomous mode:

- countdown applies;
- timeout automatically denies;
- duplicate-denial suppression applies.

In Ask mode:

- wait indefinitely.

Persistent exceptions belong in Sandbox Settings.

If the user removes a recommended path, that path follows the remaining precedence rules, including inactive-profile rules, then ordinary outside-project policy where applicable. There must be no hidden permanent hard block for a removed recommendation.

## 9. Active agent profile policy

Only the **active** agent profile receives automatic profile access. Never grant automatic cross-profile access.

### Milk-managed Pi selected

Milk-managed Pi's active managed profile receives automatic Read & Write.

Model-controlled tools may use that managed profile.

Do **not** automatically grant access to:

- `~/.pi/agent`
- a custom Existing Pi profile
- inactive managed/existing profiles

The managed profile is Milk-owned isolated runtime state. Damage there may corrupt sessions/settings/extensions/runtime behavior, but must not become a route into unrelated personal data.

### Existing Pi selected

The selected Existing Pi runtime receives Read & Write access to its own active profile so Pi can function normally.

Model-controlled tool executions do **not** receive blanket access to the Existing Pi profile.

If a model-controlled operation explicitly needs a path inside that profile, normal sandbox permission policy applies.

Do not automatically grant access to Milk's managed profile.

Rule:

> One active agent profile = one profile permission root. No cross-profile access by default.

## 10. Credentials and child environment isolation

Use ordinary macOS login/file-based Keychain through Security.framework SecItem APIs
as Milk’s primary and only persistent secret store. The approved 2026-11-02 decision
supersedes the earlier provisioned Data Protection Keychain design.
Milk Local/oMLX credentials remain in Keychain at rest, with no plaintext fallback
and no real key in Codable settings, logs, diagnostics, source, `models.json`, or
command-line arguments. Expected use is a non-admin Local/oMLX inference API key.

The sandbox phase does **not** require a credential broker/proxy. Milk may retain
today's scoped Keychain read and `MILK_PI_LOCAL_KEY` injection into the Pi runtime.
Preserve Local discovery/inference, None authentication, replacement/revocation,
profile/endpoint scoping, and protection against stale Pi auth.json precedence.
Ad-hoc/private builds must support credential storage without Apple Developer
Program membership, Developer ID, provisioning or notarization. Keep normal Keychain
ACLs intact; report changed-build authorization behavior rather than bypassing macOS
security. Developer ID/notarization remain optional distribution enhancements.
An unavailable/denied Keychain fails actionably with no plaintext/config fallback.

### Explicit Pi credential-trusted runtime domain (approved L2 adjustment)

Pi, Pi extensions running in its process, and Pi-owned subprocesses form one
trusted runtime domain for the configured Milk Local/oMLX credential. The expected
credential is a **non-admin inference API key**. `MILK_PI_LOCAL_KEY` may remain in
Pi's environment and may be inherited/accessed by `pi.exec`, Pi-launched children,
stdio MCP servers and Pi extensions. Do not disable normal Pi spawning or build
an MCP proxy solely to hide this key.

This is an explicit credential trust limitation: code in this domain may read,
use or disclose the configured key. This phase does not promise isolation of the
key from those processes. An admin/main key is not the expected configuration.

### Environment construction

Construct minimal purpose-specific environments rather than copying all of the
Milk/user environment. The active Pi runtime domain may receive its scoped Local
key. Milk-owned sandbox executor operations and Milk Extension workers are a
separate domain: construct their environments independently, without that key,
and preserve that clean environment through their shell/Python/Node/npm/Git
children. Do not source their environment from Pi's environment or a Pi-supplied
untrusted environment dictionary.

The distinction is **who owns the execution boundary**, not the executable name:
a Node process launched by Pi belongs to the Pi credential-trusted domain; a Node
process launched by Milk's sandbox executor must not inherit the Local key.

Credential-domain membership grants no extra filesystem permissions. Preserve
Seatbelt inheritance, operation policy, profile isolation, and the sibling-executor
boundary for model-controlled work. This adjustment resolves credential-inheritance
compatibility; it does not authorize a trusted host execution escape.

Future adapters such as Codex or Claude may retain their own authentication/OAuth
mechanisms. Do not force them, or existing Pi-owned authentication, through a
Milk-wide broker. Milk's Keychain-at-rest, scoping and no-secret-persistence
requirements are unchanged.

## 11. Descendant processes and development tools

The security boundary must include descendants:

```text
agent
  → tool execution
  → npm
  → node
  → postinstall
  → shell
```

Arbitrary tools/scripts remain untrusted.

Normal coding workflows must still support development tools such as:

- git
- swift
- xcodebuild
- python
- node
- npm
- shells

The sandbox must constrain what those tools can access, not ban common development tools solely because they can execute code.

### Owned-operation cleanup and accepted limitation

Separate two obligations:

- **Security scope:** invalidate Once at operation end and Session on revocation
  or lifecycle end; subsequent executor profiles must not contain that expired
  authority. Each operation remains bound to its live activation/operation identity.
- **Resource hygiene:** aggressively clean up the execution Milk owns. Send TERM
  to its owned process group, allow a short bounded graceful drain, then KILL
  remaining owned-group processes as necessary and reap owned children. Terminate
  individually known descendants where safe; perform best-effort cleanup of known
  orphans using stable process identity where available. Never kill by a stale
  numeric PID, process name or port, or touch unrelated user processes. Preserve
  group identity until final signalling/reaping to avoid PID/group reuse hazards.

Ordinary shell/npm/Node/Python/build/background descendants should clean up
normally. Deliberate `setsid()`, new process groups, double-forking or reparenting
can defeat group cleanup and descendant discovery. A survivor still has only its
inherited operation sandbox, including any temporary permission and open handles;
its inherited access may last until it exits, and descendants it creates can inherit
that same profile. “Future operations” means newly admitted Milk executor operations,
not retroactive control of that surviving fork tree. Milk makes no all-descendants-dead,
revocable-handle or race-free subtree-termination claim. This practical tradeoff
is explicitly approved for native macOS Seatbelt/process management. It does not
weaken policy precedence, filesystem denial or fail-closed execution admission.

### Managed background jobs

When Milk expects `npm run dev`, Vite/Next or Python servers, watchers, or
Preview-related servers to outlive a tool call, represent them as explicit
Milk-owned managed background jobs, not leaked operation children. Each job has
an identity, origin, explicit policy/profile and grant scope, and an owner tied
to its Preview/session/project lifecycle. Track start, cancellation, restart and
stop; terminate it when its owner no longer needs it, using the same cleanup model.

A tool result returning is not permission to silently promote its descendants to
managed jobs or extend its Allow Once grant. Establish a job's own authorized
execution/lifetime explicitly. Temporary permissions do not silently persist
through job restart, session replacement or saved-chat reopen. Agent-triggered
job creation remains policy-checked and separately sanitized; it does not acquire
trusted native Preview privileges merely because Milk manages its lifetime.


## 12. Milk-controlled build/cache roots

Development tools often need writable state outside the project.

Where practical, redirect tool caches/build output into Milk-controlled writable locations instead of broadly exposing the user's normal caches.

Examples:

- Xcode DerivedData
- SwiftPM build/cache state
- npm cache
- Gradle cache
- similar temporary/build state

Keep these roots narrow and purpose-specific.

## 13. `.git` policy

Treat `.git` as protected workspace metadata.

Do not treat it as a personal secret directory, and do not grant every model-controlled process blanket direct write access.

Normal Git commands must continue to work.

Examples that should work through controlled Git execution:

- `git add`
- `git commit`
- `git checkout`
- `git merge`
- `git reset`

Examples of arbitrary direct metadata mutation that should be blocked:

- `echo something > .git/config`
- `rm -rf .git`

Milk's own `GitService` remains a trusted host feature and continues to operate normally outside the agent sandbox.

Use a Codex-style controlled escalation path: normal sandboxed agent execution
keeps `.git`, resolved gitdirs, linked-worktree/common metadata and equivalent
repository metadata protected against arbitrary writes. Recognized legitimate
Git operations requiring metadata writes may execute outside the normal sandbox
through a Milk-controlled escalation path. Keep normal Git compatibility,
including hooks/helpers; do not build a restrictive custom Git implementation or
silently disable hooks to satisfy containment tests.

Escalation applies only to the recognized Git execution, never a surrounding
arbitrary shell pipeline, file operation or later operation. A command mentioning
Git, a renamed executable, or an untrusted claim that it is Git is not authority.
Resolve executable, arguments, working tree and metadata identity at this boundary.
Keep request/approval/lifecycle ownership and sanitized environments explicit.
Ordinary Ask/Autonomous and sandbox permission requirements still apply; this is
not an extra generic destructive-operation confirmation system.

Git hooks/helpers are part of that escalated Git execution and can execute code
with its elevated access. This is an explicit compatibility/trust exception:
normal sandbox containment is not promised inside the approved escalated Git
operation. It must not widen the long-running agent's or unrelated tool's sandbox.
Project Read Only still blocks agent project mutations without prompting; do not
use Git escalation to evade that setting. Milk's trusted GitService is unchanged.

## 14. Symlink and canonical-path handling

No user-facing symlink setting.

Before granting writable status:

- standardize/canonicalize;
- resolve real path components as appropriate;
- detect symlinked writable roots/escapes;
- apply policy to the real target;
- fail closed when a writable grant would escape its approved boundary.

Example:

```text
<Project>/Shared → ~/Desktop/Shared
```

The visible project path must not make the Desktop target implicitly writable.

Read-through behavior follows the real target's policy.

Write-through behavior requires the real target to be writable under policy.

## 15. Milk Extension API and sandbox workers

Redesign the current Milk Extension API directly for enforcement; there is no
legacy compatibility requirement. Limit the redesign to the execution/effect
boundary needed for sandboxing. Do not unnecessarily redesign extension UI,
layout or settings.

Native extension UI may remain trusted and in-process in Milk. Agent-callable
extension tools/effects must instead execute through Milk's sandbox worker /
per-operation executor architecture, without inheriting trusted Milk privileges.
An in-process callback wrapped in an approval or effect declaration is not enough.
Do not load agent-callable worker code into Milk and then claim it is isolated.

The host validates operation identity, requested effects/paths and applicable
policy. Worker filesystem/process effects and descendants are kernel-constrained;
worker requests for host effects must be narrow, policy-checked operations, not
arbitrary trusted closures or a generic privileged filesystem/command bridge.
Carry origin/activation through asynchronous calls and fail closed for unmapped
agent-callable paths. Ordinary trusted UI actions remain separate from worker
requests, including actions routed through an installed extension.

Apply the same policy flows: Ask waits for approval; Autonomous uses the applicable
timeout/denial rules; Protected Locations use their stricter flow. Capabilities
remain API contracts and do not replace OS enforcement. Preserve extension-owned
data without preserving an unsafe agent-callable API for compatibility.

Pi extensions and their Pi-owned child processes remain distinct from Milk
Extension workers; the credential trust limitation in §10 applies to them.
Milk-owned worker/executor environments require sanitization. Tool/effect
mediation must not silently fall back to unrestricted execution.

## 16. Purpose-specific sandbox profiles

Milk already distinguishes backend/process purposes. Use that distinction.

### Conversation

Normal conversation sandbox and runtime-grant policy.

### Preview inspection

- project Read Only;
- no arbitrary writes;
- minimal outside-project access;
- keep existing Preview ownership/lifecycle behavior.

### Version probe

Only the permissions required to launch the candidate and inspect version output.

### Compatibility probe

Only the permissions required for the ephemeral compatibility handshake and its temporary data/workspace.

### Package / installation operations

Access only the Milk-managed:

- staging;
- installation;
- temporary;
- package paths

required by that operation.

Do not grant normal project/general-user filesystem access without a concrete requirement.

Principle:

> Every Milk-launched agent-related process gets only the permissions required for its purpose.

## 17. Destructive project actions

Do not add a second heuristic approval layer for destructive actions inside an already permitted project scope.

Autonomous remains autonomous.

Operations such as mass delete, `rm -rf`, or destructive Git reset remain governed by the same sandbox boundaries and Git metadata policy rather than an extra generic "dangerous command" confirmation system.

## 18. Trusted Milk operations

Milk itself remains trusted and outside the coding-agent sandbox.

Trusted host functionality includes:

- Editor
- GitService
- normal Preview infrastructure
- Settings
- agent installation/update management
- sandbox management
- other Milk-owned workspace services

Agent Project Access does not make these host features Read Only.

Trusted host bridges callable by an agent must remain narrow and policy-checked.

## 19. Pi integration requirement

Pi is the first production adapter, not the architecture.

Implementation must preserve:

```text
Milk Sandbox System
  → AgentAdapter
  → PiAdapter
  → Pi runtime
```

Do not place generic sandbox state into `ComposerPermissionMode`.

Do not make Sandbox a Pi-only setting.

Pi-specific tool bridging may live in the Pi adapter/integration layer, but the policy/executor abstractions should be reusable by future adapters.

## 20. UI behavior

The existing composer Ask/Autonomous control remains the current-session agent permission control.

Do not add Sandbox to that enum/control.

Because Sandbox can still prompt while Autonomous is selected, update wording that currently implies Autonomous means "no Milk approval prompts" so it accurately distinguishes ordinary agent approvals from Sandbox security prompts.

Sandbox runtime prompts should use the established nonmodal anchored popup language/style where appropriate rather than introducing unrelated modal UI.

## 21. Fail-closed rules

If Milk cannot construct or apply the required sandbox securely:

- do not silently run unrestricted;
- do not silently fall back to weaker behavior;
- report an actionable error;
- preserve current user data and runtime selection.

The same principle applies to path canonicalization, worker setup, profile resolution, and permission construction.

## 22. Testing and acceptance

The implementation needs unit, integration, and runtime acceptance coverage.

At minimum cover:

### Project

- project read;
- project write;
- Agent Project Access = Read Only;
- symlink escape from project.

### Outside project

- Autonomous ordinary read;
- Autonomous denied write;
- Ask read prompt;
- Ask write prompt.

### Runtime grants

- Allow Once applies only to one operation and expires for future admission at
  finish/cancel/timeout/end without widening the fixed runtime;
- later operations cannot reuse an expired grant, including while a detached
  survivor retains the old profile;
- Session revocation immediately stops future admission and initiates affected
  operation/job cleanup; existing inherited access is not claimed revoked;
- Allow for Session applies only to the intended live runtime/session;
- runtime restart clears session grants;
- Milk restart clears session grants;
- saved-chat reopen does not restore them;
- duplicate timeout denial suppression works without permanently blocking later retry.

### Protected Locations

- protected read;
- protected write;
- Allow Once;
- Autonomous timeout denial;
- removed recommended entry follows ordinary policy;
- Restore Recommended Defaults adds missing recommendations while preserving custom entries.

### Profiles

- managed Pi receives only active managed profile access;
- managed Pi does not automatically access Existing Pi profile;
- Existing Pi runtime can use its active profile;
- Existing Pi model/tool execution has no blanket profile access;
- Existing Pi cannot automatically access Milk-managed profile;
- inactive profiles receive no automatic access, including Autonomous outside-read;
- precedence is tested across protected/profile/project/allowed-folder overlaps.

### `.git`

- legitimate Git commands work;
- arbitrary `.git` direct write fails in normal sandboxed execution;
- arbitrary `.git` delete fails in normal sandboxed execution;
- Milk `GitService` remains functional;
- recognized Git escalation preserves hooks/helpers;
- escalated Git access never propagates to arbitrary shell/file operations.

### Credentials

- Keychain remains persistent store;
- Local key injection into the active Pi runtime remains supported;
- the accepted Pi runtime-domain credential exposure (including extensions, pi.exec and stdio MCP) is documented;
- Pi-owned child/MCP inheritance remains supported;
- the Local/oMLX key is absent from Milk-owned executor/extension-worker environments and their descendants;
- no key is persisted into models/config/logs;
- Local/oMLX discovery and inference still work;
- replacement/revocation behavior still works.

### Descendants

- ordinary shell descendants remain constrained (escalated Git is the explicit §13 exception);
- Node/npm child scripts cannot escape their inherited filesystem sandbox;
- ordinary shell/Python/Node/npm/background children are cleaned up with bounded
  TERM/KILL/reap, including TERM-resistant cases, without killing unrelated work;
- deliberate setsid/new-group/double-fork survivors document the accepted lifetime
  limitation and remain subject to inherited Seatbelt denials;
- managed servers/watchers have explicit ownership, policy and lifecycle stops;
- descendant symlink attacks fail.

### Native extensions

- agent-callable Milk extension code runs in sandbox workers, not trusted Milk;
- worker descendants and host-effect requests cannot bypass sandbox policy;
- trusted native extension UI remains usable.

### Purpose profiles

- Preview inspection cannot write project content;
- probes receive only their minimal roots;
- install/package operations cannot access unrelated user files.

### Regression

- existing chat/session behavior;
- Ask/Autonomous behavior outside the new Sandbox boundary;
- model/reasoning selection;
- managed and Existing Pi selection/profile ownership;
- Git;
- Preview;
- Terminal;
- native extensions;
- provider settings;
- app build/signing.

Record what was actually verified. Do not claim live security properties from unit tests alone.

## 23. Documentation responsibilities

While this design is active:

- this file is authoritative for the approved target behavior;
- `docs/exec-plans/completed/SANDBOX_IMPLEMENTATION.md` records completed implementation, discoveries and measured acceptance.

When the phase ships:

- update `RUNTIME.md`, `README.md`, `docs/README.md`, `docs/DEVELOPMENT.md`, and security/provider docs as appropriate to describe the implemented behavior;
- keep this design document as an architectural record unless superseded by a newer explicit design;
- move/close the active ExecPlan according to repository convention.

## 24. Final principle

Milk should behave as:

> A trusted macOS host that gives coding agents a narrow, explicit execution environment.

Agents may operate autonomously inside the workspace, but crossing workspace boundaries, accessing sensitive data, spawning child processes, or invoking trusted Milk capabilities remains under Milk-owned policy. The Pi runtime-domain credential limitation and controlled Git escalation are explicit trust boundaries, not claims of universal containment.

## 25. Approved reconciliation decisions (2026-11-01)

D1: redesign the Milk Extension API directly; isolate agent-callable work in sandbox
workers, retaining trusted in-process UI. D2: preserve native Git/hooks/helpers
through controlled escalation outside the normal sandbox. D3: apply the explicit
seven-level precedence in §6. D4: no broker/proxy in this phase; retain Keychain
and Pi injection, sanitize Milk-owned executor/worker paths, and disclose the Pi runtime-domain
credential access. These decisions supersede the earlier draft's broker and
blanket in-process extension assumptions. No production implementation is implied.

## 26. Approved L2 domain and practical L1 lifetime decision (2026-11-01)

The Pi credential-trusted domain in §10 remains settled. Milk-owned executors and
Milk Extension workers stay separately sanitized. No credential/MCP proxy or
Pi spawning ban is required solely to hide this key.

The user explicitly withdrew the requirement to prove every grant-inheriting
process dead before Once expiry or Session revocation. Sections 4 and 11 now define
future-operation invalidation plus aggressive owned-process cleanup, accepting
that deliberately detached survivors may retain their operation's permissions
until exit. Authoritative descendant revocation was **not** technically solved.
The ExecPlan preserves the prior negative evidence and the reason for this choice.

Keep Seatbelt, sibling executors, arbitrary development commands, temporary folder
permissions and the existing permission UX. No typed-only restriction, FSKit,
Endpoint Security, filesystem extension, VM, restricted entitlement or replacement
execution architecture is adopted. All other approved product/security decisions
remain intact. This document describes the target; no production rollout is implied.


## 27. Approved login-Keychain/private distribution revision (2026-11-02)

The user explicitly replaces the Data Protection backend with ordinary macOS
login/file-based Keychain via SecItem. Only storage changes: credential identity,
PiProviderProfileIdentity, Local normalization, environment indirection, stale-auth
header precedence, None/replacement/deletion, diagnostics and all Sandbox/credential
execution domains remain intact. No broker, shared access group, user-presence/Touch ID
policy, plaintext fallback or weaker filesystem boundary is introduced.

Use default ordinary item ACLs. Normal access should be noninteractive where supported;
explicit user-requested recovery may invoke macOS authorization after an ad-hoc rebuild.
Measure save/read/update/existence/delete, launch/rebuild persistence and prompt/ACL
behavior rather than assuming DP semantics. Older entries remain explicit scoped
recovery sources; do not read them automatically or delete originals as a side effect.

Developer ID, provisioning, notarization/stapling and App Store distribution are
optional improvements, not credential-storage or Sandbox technical-completion gates.
Private users may choose macOS Open Anyway themselves; Milk must not bypass Gatekeeper
or remove quarantine. Actual normal-Keychain and regression/artifact gates still apply.
L1/L2, controlled Git, bounded snapshots and the Preview provider seam are unchanged.
