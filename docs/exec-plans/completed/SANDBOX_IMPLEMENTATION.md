# ExecPlan — Milk Sandbox / Runtime Hardening

**Status:** COMPLETE — Phases 1–7 technical acceptance passed under the approved normal login-Keychain/private-distribution policy. Optional distribution/coverage work remains explicitly unclaimed.
**Target design:** `docs/design-docs/SANDBOX_ARCHITECTURE.md`  
**Initial baseline:** `security/api-keychain` at `c00305f72821c04ae1f76cb0327d3a465bc7b7a5`

This is a living implementation plan. Update it as code inspection reveals constraints. Do not use chat memory as the only record of discoveries or decisions.

## Goal

Implement the approved Milk Sandbox architecture without regressing:

- Pi chat/RPC behavior;
- managed vs Existing Pi ownership;
- Local provider/oMLX behavior;
- ordinary macOS login/file-based Keychain storage (approved 2026-11-02 revision);
- Git;
- Preview;
- Terminal;
- native extensions;
- app build/signing.

Milk remains the trusted host. The sandbox belongs above the agent-adapter layer and must be reusable by future coding-agent adapters.

## Before implementation

Codex must:

- [x] Confirm current branch/working tree and compare current HEAD with the initial baseline above.
- [x] Read `AGENTS.md`.
- [x] Read `README.md`.
- [x] Read `RUNTIME.md`.
- [x] Read `docs/DEVELOPMENT.md`.
- [x] Read `docs/README.md`.
- [x] Read `docs/API_KEYCHAIN.md`.
- [x] Read `docs/design-docs/SANDBOX_ARCHITECTURE.md`.
- [x] Inspect current sandbox-adjacent runtime/tool/native-extension/Git code.
- [x] Update the "Current-state findings" section below with concrete code paths and current behavior.
- [x] Identify any requirement that cannot be implemented without changing an approved design decision.
- [x] Stop and report genuine blockers/decision points before silently changing the design.

Do not begin broad implementation until this plan reflects the current repository.

## Non-negotiable design decisions

These decisions are already approved and should not be re-litigated unless the current platform makes one technically impossible:

1. Sandbox ON/OFF is separate from Ask/Autonomous.
2. Sandbox defaults ON.
3. Sandbox belongs to Milk above `AgentAdapter`, not inside Pi-only state.
4. The long-running agent sandbox remains fixed; runtime grants are per-operation through Milk-controlled execution.
5. `Allow Once` applies only to one sibling-executor operation; expiry immediately prevents future reuse, without retroactively revoking a detached survivor's inherited profile.
6. `Allow for Session` is memory-only; revoke/lifecycle end closes future admission and initiates affected-operation cleanup. Reopening saved chat does not restore it. The accepted inherited-profile limitation applies.
7. Autonomous ordinary outside-project reads are allowed; outside-project writes require sandbox permission.
8. Ask outside-project reads/writes require sandbox permission and wait indefinitely.
9. Protected Locations are editable/removable recommended entries, not hidden permanent hard blocks.
10. Protected Locations offer Allow Once / Sandbox Settings / Deny, not session-wide access initially.
11. Restore Recommended Defaults adds missing recommendations and preserves custom entries.
12. Agent Project Access defaults Read & Write; Read Only blocks agent writes without prompting.
13. Only the active agent profile gets automatic profile access.
14. Milk-managed Pi may grant model/tool R/W to the active managed profile.
15. Existing Pi runtime may R/W its active profile, but model/tool execution gets no blanket access to it.
16. Milk Local keys remain in Data Protection Keychain and may enter the active Pi runtime. No credential broker/proxy is required. Pi-owned subprocesses/extensions may inherit/access the expected non-admin inference key. Milk-owned executor/extension-worker environments exclude it. Do not disable Pi spawning or add an MCP proxy solely to hide it. Future adapters keep their own authentication/OAuth.
17. The change must not alter normal oMLX/chat behavior.
18. Normal sandboxed execution protects resolved repository metadata; recognized legitimate Git operations may use controlled escalation outside the normal sandbox, preserving hooks/helpers. That exception never widens arbitrary shell/file operations.
19. Redesign the Milk Extension API without legacy compatibility: agent-callable tools/effects run in sandbox workers, not trusted Milk. Keep UI/layout/settings redesign limited to enforcement needs.
20. Different process purposes receive different minimal sandbox profiles.
21. Initial phase does not add broad network restrictions.
22. Do not add a second generic destructive-operation confirmation system.
23. Milk host features remain trusted and outside the agent sandbox.
24. Fail closed rather than silently run unrestricted.
25. Strongest-to-weakest precedence: Protected Locations → inactive profiles → Project Read Only → explicit persistent folder grants → active-profile permissions → normal project permissions → Autonomous outside-project default. Protected Locations override broader grants; ambiguous overlaps fail safely.

## Reconnaissance at current HEAD (2026-11-01)

HEAD is `c00305f72821c04ae1f76cb0327d3a465bc7b7a5`, exactly the initial
baseline, on `security/api-keychain`. The only incoming working-tree additions
are AGENTS.md and the new design/ExecPlan directories. No production edits,
branch changes, commits, or pushes are part of this planning task. The approved
design is unchanged. Phase 0 reconciliation is complete. D1–D4 are resolved by explicit user approval
on 2026-11-01. Phase 1 was subsequently authorized and the isolated harness below was run.
The earlier readiness statement is superseded by its measured gate outcomes.

## Current-state findings and exact boundaries

| Boundary | Current implementation / required work |
| --- | --- |
| Generic host → adapter | `AgentAdapter.swift`: `AgentBackendContext` carries permission/purpose/lifecycle only, not project grants or a sandbox context. `makeBackend` and `discoverPreview` both need an immutable Milk-owned execution context; keep generic types outside Pi. |
| Conversation | `AgentService.swift` creates an activation/lease in its backend-start path; `PiAdapter.makeBackend` → `PiBackend.start` → `PiLaunchResolver.resolve` → `PiRPCClient.launch` in `PiRuntimeService.swift`. Each conversation is a separate long-running process. `PiBackend` currently reduces purpose to `discoveryOnly`; preserve the full purpose in future launch requests. |
| Version probes | `PiLaunchResolver.resolve` invokes `PiRuntimeService.version` **before** the conversation/probe RPC is launched. `PiUtilityProcess.execute` launches arbitrary selected code with `--version`; protecting only `PiRPCClient.launch` leaves this earlier execution unrestricted. |
| Compatibility | `PiCompatibilityProbe.run/inspect` resolves a candidate (including a version child), then launches a separate `PiRPCClient` in ephemeral storage with extensions/MCP/skills/prompts disabled. Both children need purpose-specific containment. The isolated loader still reads runtime configuration: test startup-time commands as well as model tools. |
| Preview inspection | `PiAdapter.discoverPreview` → `PreviewPiAssistant.discover` → another backend, with `previewInspection` lease and read-tool restrictions. `PiBackend.start` still calls `PiProviderSupport.apply` against the selected profile (a host write). Current read-only promise is a Pi hook, not kernel containment. Distinguish read-only project content from required ephemeral/session/config writes. |
| Preview execution | `AgentService.authorizePreview` returns immediately in Autonomous; `PreviewService`/`DevServerService` execute the returned project command via login zsh in an owned process group with inherited environment. Agent-derived command startup is a separate host-effect boundary, not the inspection RPC. Explicit user-started normal Preview remains trusted. Track origin through startup/restart; do not let an agent-derived command acquire trusted-host status merely by passing the old Ask gate. |
| Pi package command | `ExtensionService.packageCommand/runPackageCommand` resolves the selected runtime (also version-probes), then `PiUtilityProcess.execute([install/remove, source, --no-approve])`. It explicitly resets `PI_CODING_AGENT_DIR` to `agentDirectory`. Permissions must use that actual directory and the selected local source, rather than assume the earlier resolved profile is sufficient. Local source is externally owned: read it, preserve it. |
| Install/update/repair | `PiInstallationManager.install/prepare`: URLSession download, Swift filesystem work and `PiInstallationFiles.extract` via `Sources/MilkArchive/MilkArchive.c`/libarchive; these run **inside trusted Milk**, not an installer subprocess. Candidate probes are real untrusted children. Keep the in-process trusted manager narrowly validated; isolating archive parsing would require a new helper, not attaching a profile to `AgentOperationResource`. |
| Environment | `PiLaunchResolver.resolve` copies `ProcessInfo.processInfo.environment`, merges overrides, prepends selected runtime support paths to inherited PATH. `PiUtilityProcess` permits nil env (inheritance); `DevServerService` uses inherited env plus login startup files. Resolve explicit Existing-profile selection before dropping ambient HOME/PI_CODING_AGENT_DIR, then construct separate allowlists for runtime, probes, tools and packages. Audit dynamic loader, shell startup, Git config and proxy variables as well as obvious API-key names. |
| Provider credentials | `AgentProviderCredentials` uses Data Protection Keychain and no-interaction normal access. `PiSettingsModel` does metadata-only existence checks; legacy import is explicit and verified. `PiProviderSupport.apply` writes `$MILK_PI_LOCAL_KEY` in models.json and injects the real key into Pi. `MilkPiIntegration.ts` overrides stale auth.json Authorization through `before_provider_headers`. D4 retains this scoped runtime injection/header behavior; Milk-owned worker/executor environment construction must not inherit the key; Pi-owned children may inherit it under the approved L2 adjustment. `PiLocalDiscovery.inspect` uses direct URLSession GET models and refuses redirects. |
| Profiles / settings | `PiProfile.managed`, `PiInstallationManager.profile/selectedProfile`, `PiProviderProfileIdentity`, `PiProfileIdentitySupport` distinguish managed/existing using canonical directories; managed revisions share a profile. Existing may be custom via environment. Keep current identity hashes/provider settings keys, preserve all native sessions/config/extension data, and classify aliases/overlaps before issuing roots. Existing executable shebang/interpreter/module roots may be outside its directory. |
| Tools and extension code | `MilkPiIntegration.ts` only gates `tool_call`, has exact-input ordinary approval allowances, and registers native proxy tools. Approved tools currently execute within Pi or its ordinary children. Pinned Pi docs/examples expose tool definitions/operation interfaces (`ssh.ts`, `bash-spawn-hook.ts`), `user_bash`, `pi.exec`, nested `ctx.executeTool`, MCP registrations and arbitrary extension code. A `tool_call` return can block/change input, **not** substitute a host-executed result. A supported tool override/operation bridge is necessary; unknown custom tools cannot be assumed covered by built-in overrides. |
| Native bridge | `PiBackend.handleUI` accepts `milkNativeBridge` JSON over extension UI requests; calls `NativeExtensionManager.invokePiTool` or `piPrompt`. `invokePiTool` checks contribution/workspace, asks ordinary authorization, then runs `tool.item.perform` **inside Milk**. Its arguments are opaque JSON, not an effect declaration. Treat all agent messages as untrusted requests, not authority to widen permissions. |
| Extension services | `Sources/MilkExtensionHost/ExtensionServices.swift`: `ScopedWorkspace.read` has no authorization callback; write does. `ScopedProcesses`, `ScopedGit` call `authorize`, then `ExtensionProcessHost.launch/run` uses `posix_spawn`. `ScopedStorage`, network, clipboard, secrets and direct native Foundation calls are additional effects. `ScopedSecrets` uses a separate legacy extension Keychain namespace; do not mistake provider-Keychain hardening for coverage of extension APIs. `ContributionRegistry` actions and `NativeExtensionManager.executeCommand` also execute trusted native closures. |
| Git | Milk `GitService` launches `/usr/bin/git` directly as a trusted host. Agent bash has no Git boundary; native extension `ScopedGit.run` accepts arbitrary writing arguments after ordinary approval. No `.git` containment exists. Handle real gitdir/commondir, linked worktrees, `.git` file vs directory, submodules, config, hooks, helpers and path overrides, not only `<project>/.git`. |
| Lifecycle / UI | `AgentLifecycleCoordinator` owns six purposes: conversation, previewInspection, versionProbe, packageCommand, compatibilityProbe, installationTransaction. Activation UUID/lease validity and `AgentActionOwnership` can bind new grants; saved session IDs and current UI selection alone cannot. `AgentService.approvals`, `PresentedAgentApproval`, `ComposerApprovalPopup` are ordinary dialogs with session/activation guards, no security request/path model/countdown. `SettingsService.sandbox` now owns durable policy settings and `SandboxSettingsView` exposes the dedicated page. These configure future enforcement only; runtime dialogs/routing still have no production sandbox request/countdown integration. |
| Cleanup | Phase 2 adds admission-only activation/grant invalidation to coordinator stop/start-failure/shutdown and stopped runtime events; actual cleanup remains unchanged. `PiRPCClient` and `PiUtilityProcess` terminate the owned PID, whereas Preview/native extension process hosts create groups. Neither groups nor inherited Seatbelt alone prove an Allow Once grant ends when the requested command returns: background/detached descendants can remain alive. The approved target now separates future-operation grant invalidation from aggressive best-effort descendant cleanup; deliberately detached survivors may retain their inherited permissions. Production cleanup has not been implemented. |
| Host exclusions | `GitService`, user Terminal (`TerminalProcess` → `MilkPTY.c` host → login shell), normal Preview, Editor, settings and installation management stay trusted. Audit their agent-callable entry points; do not globally sandbox Milk or apply agent Read Only to the Editor. Static Preview uses Milk's terminal-host/static-server entry points, so avoid blanket argument-based trust. |

Current-reference documentation lags this HEAD in places: RUNTIME.md's credential
summary omits profile scoping and modern Keychain/signing details, while
DEVELOPMENT.md does not describe the provisioned build path. `docs/API_KEYCHAIN.md`
and current code contain those facts. Do not restore older bundled-runtime or
legacy-Keychain assumptions. Updating those references belongs to implementation,
not this documentation-only decision update.

## D1–D4 — Resolved approved decisions (2026-11-01)

These are now incorporated into SANDBOX_ARCHITECTURE.md. They supersede the
previous unresolved alternatives; none requires another product decision to
start Phase 1. Current-state rows above describe HEAD, not the target API.

### D1 — Direct Milk Extension API redesign

No legacy API compatibility is required. Keep native UI trusted/in-process, but
move agent-callable tools/effects into sandbox workers using Milk's executor.
Redesign registration, execution context, IPC/results/cancellation, service calls
and package worker entry points as needed. Do not preserve `tool.item.perform`
in trusted Milk for agent calls, or treat effect declarations as OS enforcement.
Do not redesign unrelated extension UI/layout/settings. Preserve extension data;
update the SDK/example/tests to the new API rather than layering an unsafe fallback.

This decision governs Milk Extensions. Arbitrary Pi extensions remain code in Pi
and are covered by D4's trust limitation; supported tool/child paths still need
mediation and sanitization. Phase 1 must test built-ins, nested calls, pi.exec,
MCP and direct custom spawn paths and fail closed for unsupported containment
paths, without claiming that an in-process plugin is isolated from Pi privileges.

### D2 — Controlled native Git escalation

Use real Git with normal hooks/helpers. Normal sandboxed tools cannot arbitrarily
write `.git`, resolved gitdirs/worktree/common metadata or equivalent metadata.
Recognized legitimate Git operations needing such writes may run outside the
normal sandbox via controlled escalation. Scope that exception to the identified
Git execution, not surrounding shell syntax or subsequent commands; preserve
runtime/request ownership, normal approvals and sanitized child environments.
Do not implement a restrictive Git substitute or disable hooks for compatibility.

Hooks/helpers execute code as part of the escalated Git operation. Their elevated
access is an accepted trust exception, not a promise of normal tool containment
inside Git. Test that the exception does not become a generic shell escape.
Project Read Only still blocks agent project writes; trusted Milk Git is unchanged.
Executable/repository identity validation is required in production. Phase 1 proves exact structured real-Git argv escalation; broader safe recognition belongs to Phase 5. No generic shell parser or shell-text trust heuristic is required or approved; unsupported compound forms fail closed.

### D3 — Fixed policy precedence

Strongest to weakest:

1. Protected Locations
2. Inactive agent profiles
3. Project Read Only
4. Explicit persistent allowed-folder grants
5. Active-profile permissions
6. Normal project permissions
7. Autonomous outside-project default

Protected Locations override broader grants. Inactive profiles are not automatically
readable via Autonomous outside-read or broader grants. A lower-priority grant
cannot bypass Project Read Only. Classify real targets and fail safely on ambiguous
overlaps; temporary permissions follow the applicable policy flow rather than
silently changing this ordering. Add table-driven overlap tests across all seven
levels. Editable Protected Locations remain editable, not hidden permanent blocks.

### D4 / approved L2 adjustment — credential trust domains

Retain Data Protection Keychain and scoped Local injection/header precedence.
The expected key is non-admin inference-only. Pi, in-process Pi extensions,
pi.exec, Pi-launched subprocesses and stdio MCP form one credential-trusted runtime
domain and may access/inherit this key. Do not disable normal spawning or build an
MCP proxy solely to conceal it. This supersedes the initial direct-child secrecy
target; previous inheritance evidence remains valid but is no longer a failure.

Milk-owned sandbox executors and Milk Extension workers remain separate: independently
construct sanitized environments excluding the Local key, including their descendants.
Classify by execution ownership, not whether the process happens to be Node/Python.
No filesystem/profile/grant policy is relaxed by credential-domain membership.
Future agents retain their authentication/OAuth; no universal broker is introduced.

## Feasibility gates (engineering work, not product decisions)

1. **Seatbelt mechanism:** prefer a separate Milk-owned launcher using the host's
   `/usr/bin/sandbox-exec` with parameterized/private profiles as a candidate,
   not applying a sandbox to Milk. The installed manual marks sandbox-exec
   deprecated. Phase 1 now proves named kernel boundaries on macOS 26.5.2;
   other supported macOS releases, full deny-default closure and signed bundle
   helper integration are not established by that proof. Missing support must fail closed.
   Reference: [Apple discussion](https://developer.apple.com/forums/thread/661939).
2. **Sibling executor:** start operations from trusted Milk, outside the fixed Pi
   sandbox; a child spawned inside Pi cannot be assumed to shed its parent's
   restrictions. Authenticate/bind bridge traffic to live activation + operation,
   validate targets/arguments in Milk, constrain resources and cancellation;
   a bridge request or Pi-supplied tool name conveys no extra authority.
3. **Opaque shell access:** shell/Python/npm paths cannot be safely inferred by
   string parsing. Typed file tools can preflight exact targets. Opaque commands
   need explicit requested roots and structured denials; no promise of complete
   syscall path discovery or automatic interactive retry from Seatbelt logs.
   Never automatically rerun a partially executed mutating command after denial.
4. **Path races:** resolve non-existent targets through existing ancestors; check
   aliases, root replacement, symlink swaps and hard links/renames. Canonicalizing
   a String once is insufficient. Kernel rules plus safely opened paths/private
   roots and race tests must enforce the actual boundary. Profile lifetime must
   not turn a replaced inode/path into fresh authority.
5. **Environment domain separation:** preserve credential inheritance in the
   approved Pi-owned domain (normal pi.exec/child/MCP behavior). Prove Milk-owned
   worker/executor inputs are independently constructed and key-free. Do not pass
   arbitrary Pi-supplied env to trusted execution. No no-fork policy or MCP proxy
   solely for hiding the key. Preserve None/stale-auth/scoping/provider parity.
6. **Once/revocation (approved practical L1):** expire Once for future operations
   immediately at finish/cancel/timeout/end; revoke Session admission immediately.
   Never widen the fixed parent or reuse an expired grant. TERM the owned group,
   bound graceful drain, KILL remaining owned-group work and reap children; clean
   individually known descendants/orphans best effort using stable identity where
   safe. Ordinary children must clean up without touching unrelated processes.
   Deliberately detached survivors may retain their inherited operation profile
   and open handles until exit. No authoritative all-dead or retroactive revocation
   proof is required or claimed. Managed servers/watchers need explicit job ownership,
   policy and Preview/session/project lifetimes, not an implicit leaked-child lease.
7. **Execution closure:** selected external launchers, interpreters, dynamic
   libraries, tools and config sources need read/execute roots without exposing
   entire home directories. Startup code and profile-writable configuration can
   execute before a model tool event; probe this explicitly.

## Revised implementation phases and dependencies

Phases 1–6 are complete within their authorized scopes; measured results and
limitations are recorded below. The user authorized Phase 6 purpose closure and
default-ON rollout, preserving existing explicit OFF choices. Phase 7 acceptance
and release work requires separate authorization and has not started. The table
below retains the approved dependencies; earlier phase descriptions are scoped
deliverables, not claims that their historical partial-coverage status is current.

| Phase | Major files/components | Deliverables and exit gate |
| --- | --- | --- |
| 0 — Reconciliation and decisions | Approved design and this plan | Current launch/effect inventory complete; D1–D4 approved and incorporated. Phase 1 authorized; see measured outcomes below, not the earlier readiness assessment. |
| 1 — Executable boundary proof | Isolated tests/harness, new sandbox launcher/helper/profile prototypes; pinned Pi public tool-operation interfaces | Prove Seatbelt + descendants, sibling executor, Pi public built-in routing/results/cancellation feasibility, unknown-tool fail-closed handling, Existing-profile split, approved credential-domain separation and controlled Git escalation with hooks/helpers. Prove worker isolation for redesigned Milk extension tools; no legacy compatibility requirement. Prove future Once nonreuse and ordinary group cleanup; retain the accepted detached-survivor counterexample. Full stock parity is later acceptance, not a requirement to implement production in this phase. No rollout. |
| 2 — Milk policy, settings and scope (complete) | `SandboxModels`, `SandboxPathResolver`, `SandboxPolicy`, `SandboxSettingsStore`, `SandboxGrants`, `SandboxSettingsView`; settings/sidebar wiring and `AgentLifecycle` / `AgentService` | Canonical precedence matrix, separate global/project persistence, protected defaults/restore, project R/O, memory-only activation/operation grants. Existing adapter lifecycle seam reused; no Pi-specific generic state. Configured ON explicitly does not claim enforcement. See Phase 2 tests/build/limits below. |
| 3 — Launcher, executor and approval UI together | New executor/IPC/owned-process types; `PiLaunchContext.swift`, `PiRuntimeService.swift`, `PiUtilityProcess.swift`, `PiAdapter.swift`, `PiBackend.swift`, `MilkPiIntegration.ts`, `ComposerApprovalPopup.swift`, composer wording | Fixed purpose-specific Pi launch + sibling per-operation execution; all built-in paths including nested tools/user bash covered; structured requests, immediate once/session admission invalidation, TERM/bounded-drain/KILL/reap and identity-safe best-effort orphan cleanup, countdown/Ask wait, duplicate suppression, background-session prompts. Gate depends on phases 1–2; port ordinary approvals without conflating enums or granting twice. No unrestricted fallback. |
| 4 — Descendant environment hardening and provider parity (covered scope complete) | `PiLaunchContext.swift`, `PiRuntimeService.swift`, `PiUtilityProcess.swift`, `MilkPiIntegration.ts`; executor/worker launchers; `PiProviderSupport`, `PiLocalDiscovery`, `PiSettings` and credential tests | Retain Keychain and scoped key injection into the active Pi-owned runtime domain, including normal child/MCP inheritance. Independently construct clean Milk-owned worker/executor environments; verify their shell/Python/Node/npm descendants, None/stale-auth/replacement/scoping parity. No broker or provider-config proxy migration. Accepted Pi runtime-domain limitation documented. Integrate child sanitization from phase 1 onward, not as a permissive temporary default. |
| 5 — Git and agent-triggered host effects | Controlled real-Git escalation path; `GitService.swift` audited but host behavior preserved; `PiBackend.handleUI`, `NativeExtensionManager`, `ContributionRegistry`, `ExtensionServices`, extension SDK, worker entry points/package contract and example; `SlashCommands`, `AgentService.authorizePreview/authorizeExtensionAction`, `PreviewService`, `DevServerService` | Redesign the Milk Extension API directly: execute agent-callable code in sandbox workers; retain trusted UI. Implement controlled Git escalation with hooks/helpers, native host-effect mediation and origin propagation. Cover direct/nested tool calls, MCP/local children, extension commands and model-generated Preview startup. Represent expected persistent servers/watchers as explicit managed background jobs with policy/origin and Preview/session/project ownership, cancel/restart/stop handling, and no silent promotion of Once children. Fail closed for unsupported Sandbox-ON paths; no privileged bridge through Autonomous bypass. Re-test linked worktrees/hooks/helper/config attacks and normal host features. |
| 6 — All purpose profiles / rollout | `PiCompatibilityProbe`, `PiLaunchResolver`, `PiUtilityProcess`, `ExtensionService`, `PiInstallationManager`, `AgentInstallationStore`, `MilkArchive` audit; packaging/signing scripts | Tighten every inventory path including pre-RPC --version, package actual source/profile, candidate interpreter closure and ephemeral storage. Decide helper need for archive isolation only if stronger isolation is required; current trusted host manager is not a subprocess. Once phases 1–5 and all purpose gates pass, enable default ON with explicit OFF behavior. Settings/policy changes drain affected fixed runtimes before relaunch. |
| 7 — Acceptance and current-reference docs | Focused sandbox tests; existing provider/routing/profile/lifecycle/native-extension/Preview/Git suites, release tests/scripts; README, RUNTIME, DEVELOPMENT, docs index, API_KEYCHAIN, provider/profile/extension references | Real adversarial filesystem/process tests, manual popup/background concurrency/revocation, full Swift/Python regression, app/release/signing checks, explicitly authorized live provider acceptance. Record limitations; close/move plan only after acceptance. |

Compared with the initial proposal: move executable feasibility ahead of UI and
broad launch changes; make approval UX part of a usable executor rather than a
later permissive gap; include Git and native-effect feasibility at the start;
include agent-derived Preview execution; do not confuse host install extraction
with a missing installer child; require child environment isolation + all launch/effect coverage before
default-ON acceptance. Build/cache redirection belongs to executor/profile work
and is validated with actual Swift/Xcode/npm/Python use, not broad cache grants.


## Decision-update validation (2026-11-01)

Read both resulting documents and scan for obsolete broker requirements, demands
for a key-free Pi runtime, extension legacy-compatibility alternatives and
unresolved D1–D4 labels. Review the seven-level ordering and Git escalation trust
exception in both. Verify no production diff. No tests/build are needed for this
documentation-only change; no sandbox runtime properties have been verified.

## Security invariants to test continuously

- [x] Local key scoped to the active Pi credential-trusted runtime domain; its child/extension exposure is documented.
- [x] No Local key inherited in Milk-owned executor/extension-worker environments or their descendants.
- [x] No automatic cross-profile access.
- [x] No writable symlink escape.
- [x] No unrestricted fallback when Seatbelt/profile construction fails.
- [x] No runtime grant reuse across operation/session/runtime identity; invalidation precedes future admission.
- [x] Ordinary descendants cleaned with bounded TERM/KILL/reap; no unrelated-process kills.
- [x] Deliberate detached-survivor inherited-access limitation disclosed; no authoritative revocation claim.
- [x] Persistent development jobs explicitly owned and stopped with their Preview/session/project lifecycle.
- [x] No native extension agent-triggered bypass.
- [x] No generic Milk privileged filesystem bridge.
- [x] `.git` arbitrary mutation blocked while Git workflows still function.
- [x] Sandbox OFF is explicit and does not pretend protections are active.

The checks below refer to measured finite tests within the documented snapshot,
credential-domain, Git and detached-survivor limits. They are not universal or atomic
security certification. Phase 7 evidence and external gates are in
`docs/SANDBOX_ACCEPTANCE.md`.

## Acceptance matrix

### Sandbox policy

- [x] Global toggle defaults ON.
- [x] Ask and Autonomous remain separate.
- [x] Agent Project Access defaults R/W.
- [x] Project R/O blocks writes without prompting.
- [x] Global/project allowed-folder rules work.
- [x] Protected Locations are editable.
- [x] Restore defaults preserves custom entries.

### Runtime grants

- [x] Allow Once.
- [x] Allow for Session.
- [x] runtime restart clears.
- [x] Milk restart clears.
- [x] saved chat reopen does not restore.
- [x] Autonomous countdown.
- [x] Ask waits indefinitely.
- [x] protected paths do not offer session grant.
- [x] duplicate auto-denied requests are suppressed temporarily.

### Profiles

- [x] managed active profile isolated.
- [x] Existing active profile isolated.
- [x] managed does not auto-read Existing.
- [x] Existing does not auto-read managed.
- [x] Existing model tools have no blanket profile access.

### Credentials

- [x] Keychain remains the only persistent credential-store implementation; selector/no-fallback tests pass.
- [x] Provisioned Data Protection gate retired by explicit user decision; actual ordinary login-Keychain persistence/recovery measured without provisioning.
- [x] active Pi domain injection/provider parity retained; child/MCP/extension exposure documented.
- [x] Pi-owned child/MCP inheritance retained; no inherited Local key in Milk-owned worker/executor environments or their descendants.
- [x] Synthetic localhost OpenAI-compatible model discovery works through current Pi.
- [ ] Optional live oMLX coverage NOT RUN: no usable dedicated authorized inference credential established; not a technical-completion gate.
- [x] Actual Pi chat/inference against synthetic localhost providers works.
- [ ] Optional live Local/hosted-account coverage NOT RUN; ordinary Keychain app-restart persistence is independently measured, not inferred from fixtures.
- [x] Synthetic credential replacement/server revocation/no-auth/stale-auth precedence works; live service rotation is unclaimed.
- [x] profile/endpoint scoping preserved.

### Tool/process containment

- [x] shell.
- [x] Python.
- [x] Node/npm.
- [x] Swift compilation/xcrun and Xcode version output.
- [x] Real Xcode target/build phase with explicit TemporaryItems Once grant; private-only attempt fails closed, unrelated outside writes denied, Once expires (Phase 7 evidence).
- [x] ordinary descendants constrained; escalated Git/hooks/helpers tested as the explicit exception.
- [x] cache/build redirection works where configured.
- [x] symlink escape blocked.

### Git

- [x] status/diff.
- [x] add/stage.
- [x] commit.
- [x] checkout/switch.
- [x] merge/reset where existing workflow supports them.
- [x] arbitrary `.git` file mutation blocked.
- [x] `.git` deletion blocked in normal execution.
- [x] controlled escalation preserves Git hooks/helpers without widening arbitrary commands.

### Native extensions

- [x] trusted native extension UI preserved; no unnecessary layout/settings redesign.
- [x] new agent-callable API runs code/effects in sandbox workers; no in-process fallback.
- [x] agent-triggered filesystem action obeys sandbox.
- [x] protected path handling matches normal sandbox behavior.

### Purpose profiles

Production coverage and focused executable evidence are complete (Phase 6 record
below); this does not mark the broader Phase 7 acceptance matrix complete.

- [x] conversation.
- [x] Preview inspection.
- [x] version probe.
- [x] compatibility probe.
- [x] package/install transaction.
- [x] utility command paths currently present in code.

## Progress

- [x] Read repository instructions, current references, API_KEYCHAIN, approved design and initial plan.
- [x] Verify branch/HEAD/working tree and map current launch/effect boundaries.
- [x] Reconcile phase breakdown, record dependencies and genuine decision points.
- [x] Resolve D1–D4 with user; update approved design with the explicit 2026-11-01 decisions.
- [x] Phase 1 isolated harnesses and native/Pi runtime experiments implemented.
- [x] Focused proofs and existing Swift regressions run; negative evidence recorded.
- [x] L1 resolved by explicit accepted detached-survivor limitation; no authoritative revocation solution claimed.
- [x] L2 resolved by approved Pi credential trust domain; unchanged in this continuation.
- [x] Phase 1 complete: post-cleanup focused suite passes and feasibility gates reassessed.
- [x] User authorized Phase 2 policy/settings/scope implementation.
- [x] Phase 2 policy/settings/scope implemented, tested, built and documented.
- [x] Phase 3 separately authorized and completed within its launcher/executor/approval scope.
- [x] Phase 3 exit checks (record below).
- [x] Phase 4 covered environment construction and provider parity completed (record below).
- [x] Phase 5 Git and agent-triggered host effects completed (record below).
- [x] Phase 6 all-purpose containment and default-ON gates completed (record below).
- [x] Phase 7 technical acceptance complete after the approved normal login-Keychain revision; optional live/distribution/coverage items remain unclaimed.
- [ ] Optional distribution/live/additional-host/manual coverage remains unperformed; the approved revision retires these as mandatory technical-completion gates.

## Discoveries and decisions

2026-11-01 / c00305f: initial facts were generally correct but incomplete. Lifecycle
purpose is not a security policy. Current approval is not execution mediation.
Install extraction is in-process. Preview has a second, trusted-host command
execution boundary. Native and Pi extension handlers have privileges that cannot
be constrained by a pre-call dialog. Git helper execution and profile-readable
runtime code require explicit compatibility decisions, not wider sandbox roots.

The initial reconciliation changed no approved decisions. The subsequent explicit
user decisions D1–D4 are now incorporated in both documents. No production
implementation or fallback was added by the document update. Phase 0 is complete.
The subsequent authorized Phase 1 tests expose the limitations recorded below;
no production fallback or approved-design change has been made.

## Validation log

Planning-only inspection on 2026-11-01:

- `git branch --show-current`: security/api-keychain.
- `git rev-parse HEAD`: c00305f72821c04ae1f76cb0327d3a465bc7b7a5.
- `git status --short`: incoming untracked AGENTS.md, design-docs/, exec-plans/;
  no production modifications. Initial review edited only this ExecPlan; the
  approved decision update edits this plan and SANDBOX_ARCHITECTURE.md only.
- Read current source, process/spawn inventory, local pinned Pi public extension
  docs/examples, and installed `man sandbox-exec` (deprecated).
- No sandbox execution, prototype, production edit, credential operation, live
  provider call, tests or build performed for this planning task. Prior Keychain
  phase evidence is historical validation, not evidence for the proposed sandbox.
- Final validation: review plan text, `git diff --check`, and verify tracked
  production diff remains empty. New documents are untracked, so ordinary git
  diff alone does not display this plan; inspect its working-tree contents too.

## Historical Phase 1 execution record — 2026-11-01

**Historical scope:** records below, through the FSKit investigation, preserve the
then-required stronger L1 contract, failed candidates and contemporaneous blocked
conclusions. They are evidence, not current instructions to restart that research.
The later **Practical L1 approval and Phase 1 exit review** supersedes their lifetime
requirements/status. FSKit/ptrace runners were subsequently removed; missing file
references below describe historical artifacts, not runnable current instructions.
No authoritative descendant termination/revocation solution was established.

Environment: actual Apple Silicon host, macOS **26.5.2 / 25F84**, actual pinned
Pi **1.4.0** binary (`--version` asserted by the harness), clang-built disposable
native executables/dylib. All profiles, repositories, model replies, extension
code, MCP server and credentials are synthetic fixtures. No personal Keychain,
Pi profile, live oMLX or remote Git mutation is involved. Branch/HEAD unchanged.

### Artifacts and implemented prototypes

All new executable code is isolated under `Tests/SandboxPhase1/`; no app resources,
production launcher, extension SDK, provider code or Package.swift is changed.

- `test_boundaries.py`: SBPL builder/launcher, native worker and real Git harness.
- `probe.c`: file/fork/environment/native-plugin/detach probes.
- `worker_effect.c`: native agent worker payload; refuses an inherited Local key.
- `pi_bridge.ts`: public Pi factory-operation overrides for read/write/edit/bash,
  routing-only discovery wrappers, nested execution, user_bash, abort propagation,
  unknown-tool gate, and explicit pi.exec/custom-spawn probes.
- `test_pi_boundaries.py`: real RPC protocol, fake SSE model, concurrent sibling
  operation dispatch, per-tool typed Once grant, environment/cancellation/MCP tests.
- `operation.py`: disposable worker operation; clean env, constrained file/shell
  effects, structured results/errors, no unknown-operation fallback.
- `mcp_probe.py`: actual stdio initialization/tool-list handshake and inheritance
  marker, recording a Boolean rather than any credential value.
- `README.md`: reproducible invocation, proof scope, negative evidence and limits.

Profiles intentionally use **allow-default plus targeted denies for synthetic
roots**, not a proposed production profile. This isolates the kernel primitives
being tested; it does not prove a full default-deny launch closure, IPC/service
attack-surface closure, all path races, all OS versions, or packaging/signing.

### Measured gate outcomes

| Gate | Outcome | Executable evidence / limitation |
| --- | --- | --- |
| Seatbelt and inheritance | PASS for tested primitives on this host | Project write allowed; named outside read/write denied; shell descendant and symlink-target writes denied; invalid SBPL never executes payload; process-fork denied. Not a universal production sandbox certification. |
| Fixed runtime + sibling executor | PASS, narrow prototype | Nested attempt cannot gain the outer denied permission; independently launched sibling can. Actual long-running Pi retains its PID/profile through one approved typed read; following read denied. Tool invocation grant covers access/read substeps, not each transport message. No live settings/grant product UI implemented. |
| Pi result/nested routing | PASS for basic factory operations; PARTIAL overall | Fake model issues real read/write/edit/bash calls, receives results; write/edit bytes verified. Nested ctx.executeTool emits parentToolCallId. Grep/find/ls routing works but full stock semantics/images/truncation/performance are unproven. No upstream Pi patch. |
| Cancellation | PASS for ordinary tested groups | RPC abort_bash and model-tool abort reach the bridge AbortSignal and cancel sibling workers; delayed write does not occur. This is not proof for detached descendants. |
| Fail closed | PASS for tested paths | Unknown custom tool is blocked before profile read. The historical kernel no-fork experiment blocks direct spawning; this is not the current approved Pi runtime policy. No unrestricted fallback is taken. |
| Managed/Existing profile split | PASS for synthetic roots | Active Existing parent can access its profile, tool sibling cannot; active managed tool root allowed, inactive/other roots denied. Arbitrary code inside Pi still has the parent profile permissions; do not confuse it with an isolated model worker. Aliased/shared real-world profile configurations need later policy tests. |
| Credential trust domains (L2 adjustment) | PASS for tested domains; L2 resolved | Spawning-enabled Pi retains the key and pi.exec/custom spawn/stdio MCP may inherit it. Actual stdio MCP tool response verified. Milk-owned sibling shell/Python/Node/npm children stay sanitized. Historical no-fork experiment is not the current design. |
| Redesigned native worker boundary | PASS as native execution prototype | Same native payload denied outside worker roots and allowed inside; absent key required. Unsandboxed test host can execute that payload with host permissions, demonstrating why it must not be loaded into Milk. Trusted UI production code untouched; full SDK/package/IPC redesign is not implemented or claimed tested. |
| Controlled Git escalation | PASS for explicit tested argv | Normal sandbox cannot arbitrary-write repository metadata or git add; host-approved real add/commit works with pre-commit hook and editor helper. Linked-worktree .git file and resolved worktree/common metadata protected. Shell wrapper/unknown alias/global-config request forms rejected; subsequent arbitrary writes remain denied. Complete shell parsing/recognition, all Git options/helpers and elevated helper lifetime are not proven. Hooks/helpers have the explicitly approved elevated trust. |
| Allow Once / revocation lifetime | **FAIL for PID/process-group-only cleanup** | Sandboxed worker forks/setsid, leader exits; killing its original group cannot prevent detached child writing its operation-only outside root later. Fixed runtime still cannot write that root. The synthetic child then exits; no persistent daemon is left. A returned leader status is not grant expiry or verified operation completion. |

### Genuine incompatibilities and stopped affected paths

**L1 — Detached descendants invalidate the proposed cleanup proof.** Stop treating
PID/process-group termination as sufficient for command-wide Once expiry or
session revocation. Killing/awaiting ordinary groups remains useful, but passing
that happy path cannot authorize generic temporary shell grants.

Viable narrow primitive already demonstrated: perform exact typed filesystem
operations in no-fork leaf workers; own/await that worker through completion and
keep ordinary development commands under the fixed baseline permissions. This
does not satisfy general temporary outside-folder access for arbitrary shell/npm
commands. Applying that restriction as final product behavior would need explicit
approval; it has **not** been silently adopted.

For full arbitrary-command grants, investigate an ownership/isolation boundary
that can prove all descendants dead, including session escape/reparenting, before
expiry. A disposable VM/stronger execution boundary is a candidate architectural
alternative, with host toolchain compatibility and distribution costs; it is not
an implemented macOS solution here. Any kernel-backed supervisor proposal needs
an actual race/detachment proof and entitlement/support review; process polling
or group enumeration alone is not a proven alternative. If none meets the target,
return to the user with that evidence rather than weakening expiry semantics.

**L2 — Resolved by subsequent explicit approval.** The original tests proved
that direct pi.exec/custom-spawn/stdio-MCP inherit the configured key. This is now
permitted in the Pi-owned credential-trusted domain, not a compatibility blocker.
The earlier no-fork/MCP-gateway proposal is withdrawn as a key-hiding requirement.
New tests default to a spawning-enabled fixed Pi sandbox, verify actual MCP tool
execution, and keep sibling worker environments sanitized. Historical no-fork
primitive tests remain explicitly labeled as not the current runtime design.

### Validation commands/results and corrections

- `python3 -m unittest discover -s Tests/SandboxPhase1 -v`: **17 tests passed,
  zero failures**, 10.849 seconds, final run. Requires execution outside the tool's nested sandbox and
  loopback access. Expected counterexample assertions are marked as such above.
- First low-level run: 7/7 passed; expanded native/Git suite now covers linked
  metadata and operation-only detached-grant retention too.
- Initial Pi run: 3 failures caused by harness issues: status emitted before
  prompt response was consumed, and builtin:mcp was not explicitly loaded with
  --no-extensions. Corrected event correlation and explicit built-in loading;
  positive MCP counterpart now prevents a vacuous no-start claim.
- Expanded run exposed two more harness mistakes: per-read rather than per-tool
  Once consumption, and abort response arriving after agent_end. Corrected by
  binding access/read substeps to tool invocation and checking already delivered
  events. Requirements were preserved; no production behavior changed.
- Last pre-Node/npm expanded run: 16/16 passed. The final suite adds real Python/
  Node/npm descendants and verifies the actual Pi version. Its first run found
  npm rejecting the same file used for both user/global config; split them into
  two empty disposable files. The final 17/17 run passed without relaxing policy.
- `git diff --check` passed; HEAD remained c00305f and branch security/api-keychain.
  Tracked production diff is empty. The approved architecture is unchanged by
  this phase; the new untracked documents retain the previously approved content.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
  swift test --cache-path "$PWD/.build/cache" --disable-sandbox`:
  **219 tests passed, zero failures**, 86.637 seconds. Executed outside the tool
  sandbox because existing fixtures need loopback and host access.
- No normal/release app build: production/packaging inputs are unchanged. Native
  prototype compilation is performed and checked by the harness. No provisioned
  signing acceptance, UI acceptance or live provider test is claimed for Phase 1.

## Phase 1 continuation — L2 adjustment and L1 entitlement-free investigation

### Approved scope and design update

L2 is resolved by the user's explicit credential-domain adjustment. Architecture
§10/§26 and this plan now permit normal Pi spawning with the expected non-admin
inference key in the Pi-owned domain. `pi.exec`, Pi-launched children, Pi extensions
and stdio MCP may inherit/access it. Milk-owned executors/extension workers remain
independently sanitized. No MCP/provider proxy or no-fork Pi policy is required
solely to hide this key. `test_pi_boundaries.py` defaults to spawning-enabled Pi,
and its positive MCP test now invokes an actual MCP tool and checks its result.
The historical no-fork experiments are retained as labeled kernel primitives,
not production policy. Filesystem/profile isolation decisions remain unchanged.

L1 semantics and UX are **not changed**. No typed-only grant restriction, no
restricted Apple entitlement dependency, no reduced development-command set,
and no move to Phase 2 are authorized. The sibling executor and Seatbelt remain.

### Mechanisms investigated and exact evidence

| Candidate | Investigation / result | Can certify all temporary-grant holders dead? |
| --- | --- | --- |
| PID / process group | Prior counterexample expanded to live leader + synchronized child. Background control killed; setsid, new pgroup and double-fork descendants survive group kill and write after the leader is waited. Python double-fork, Node detached spawn, npm lifecycle chain and nested shells reproduce it. | No. Already rejected as the sole correctness boundary. |
| Seatbelt process-info-setcontrol | Candidate allow-default profile with explicit deny. Actual C setsid and setpgid succeed; the original leader is held alive during cleanup, avoiding PID-reuse assumptions. Detachment is acknowledged before supervisor kill. | No. This operation does not prohibit those group/session changes on macOS 26.5.2. |
| kqueue EVFILT_PROC + NOTE_TRACK | C monitor arms before unblocking root's first fork. Registration returns -1 / **errno 45 (ENOTSUP)**. SDK sys/event.h explicitly declares NOTE_TRACK/NOTE_TRACKERR/NOTE_CHILD unsupported since 10.5. Apple's XNU filt_procattach explicitly rejects those flags with ENOTSUP. NOTE_FORK alone is notification about a watched process, not an atomic recursive subtree membership/kill handle. | No public atomic follow-fork primitive here; polling for children would violate the requirement and miss reparenting races. |
| launchd job ownership | Created a unique temporary gui/UID job with AbandonProcessGroup=false, KeepAlive=false and ExitTimeOut=1. Job starts sandbox-exec → native leader → setsid/double-fork. Successful launchctl bootout still permits detached delayed write. Test always removes its job; bounded detached payload exits after the marker. Installed launchd.plist manual documents same-PGID cleanup only. | No. Public job teardown is not a subtree death certificate. |
| Inherited pipe / EOF lifetime latch | Pass a lifetime FD to native workload. Double-fork child closes inherited FDs and continues. After leader kill, supervisor observes EOF **before** the delayed filesystem effect. | No. Arbitrary development code can legitimately close/reassign FDs; EOF is not proof of descendant death. |
| XPC service transactions / security sessions | Public API/documentation review only. An XPC transaction tracks service work, not an untrusted transitive fork tree. Security AuthSession.h exposes SessionCreate but no public SessionDestroy that terminates all inherited processes; security sessions and POSIX setsid sessions are distinct. No undocumented service/coalition controls were adopted. | No documented entitlement-free guarantee identified. No separate XPC prototype or exhaustive impossibility proof claimed. |
| sandbox extensions / security-scoped URLs | Public Foundation access balancing is not process termination. Even a permissions-revocation design would not meet the user's explicit requirement that **all retaining processes terminate**. Per-process stopAccessing is not a documented recursive process-kill API. Static SBPL grants remain inherited. | Not a solution to the specified lifetime contract. No private extension API adopted. |
| Endpoint Security descendants client | Apple's current documentation explicitly requires com.apple.developer.endpoint-security.client, despite not requiring root/TCC for this newer API. The installed macOS 26 SDK does not declare it. No ES entitlement was added/requested, and no claim of guaranteed termination from notifications alone is made. | Excluded as required dependency by user. Research alternative only. |

The candidate profile intentionally remains a targeted primitive test, not a
production deny-default policy. `xcodebuild -version`, actual Swift compile/run,
Node/npm/Python and shell spawning work under it. Denying process-fork would avoid
the counterexample by breaking required workflows and is therefore **not** an L1
fix. Suppressing setsid through DYLD interposition is also not an enforcement
boundary against arbitrary native code/direct syscalls or protected executables;
no such interposer was implemented or presented as a solution.

### Technical conclusion and strongest alternatives

**L1 remains unresolved.** For the investigated native/public macOS 26 mechanisms,
there is no available operation-subtree handle combining immutable membership,
recursive termination and a reliable all-dead acknowledgment. Seatbelt attaches
permissions to processes and descendants but does not expose such a termination
handle. A process can change group/session and reparent before cleanup while
retaining its inherited profile. The public recursive kqueue tracking flags are
explicitly unsupported; job/FD lifetimes do not replace that missing primitive.
Combining these failed mechanisms or polling does not establish the required proof.
This is a concrete supported-API limitation, not a mathematical claim about every
possible future macOS mechanism.

Strongest alternative preserving arbitrary commands and a killable execution
boundary: evaluate a disposable **macOS VM** using Apple's public Virtualization
framework (standard virtualization entitlement, not Endpoint Security approval).
Guest lifecycle can supply a whole execution boundary independent of guest setsid/
reparenting; prove VM-stop completion, pending shared-filesystem I/O drainage and
grant teardown before claiming expiry. A macOS guest can carry native development
tools; costs include guest image/toolchain provisioning, Xcode compatibility,
resource use, filesystem semantics and startup latency. A Linux guest/container
would not preserve native macOS Swift/Xcode behavior equivalently. No guest image
was downloaded and no VM architecture change was made; this alternative requires
explicit design approval and a new proof, not automatic adoption.

Endpoint Security with Apple approval could be studied separately, but is not a
permitted correctness dependency here. Typed/no-fork workers remain a narrow
previously proven primitive, **not a proposed substitute** for the approved general
command grants. We did not silently replace the UX with persistent grants, extend
Once indefinitely, or report expiry while grant holders may survive.

### Public sources / local API evidence

- Installed SDK sys/event.h lines around NOTE_TRACK; local `man kqueue`.
- [Apple XNU process event implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_event.c), filt_procattach explicitly returns ENOTSUP for tracking flags.
- [Apple XNU setsid/setpgid implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_prot.c); observed host behavior is tested rather than inferred solely from another source revision.
- Installed `man launchd.plist`, AbandonProcessGroup; [Apple launchd guide](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html).
- Installed Security.framework AuthSession.h; [Apple runtime sessions guide](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPMultipleUsers/Concepts/SystemContexts.html).
- [Apple Endpoint Security descendants API](https://developer.apple.com/documentation/endpointsecurity/es_new_descendants_client(_:_:)): restricted entitlement requirement; not a required implementation dependency.
- [Apple Virtualization framework](https://developer.apple.com/documentation/virtualization) / [VZVirtualMachine](https://developer.apple.com/documentation/virtualization/vzvirtualmachine): alternative to investigate, not a proven shipped worker.

### Executable validation in this continuation

New artifacts: `Tests/SandboxPhase1/lifetime_probe.c`, `test_lifetime.py`.
Updated existing Pi harness/README to match approved L2 (no production changes).

- `python3 -m unittest discover -s Tests/SandboxPhase1 -p test_lifetime.py -v`:
  first 4/4 in 5.949s; expanded **6/6 in 14.621s**. Expanded cases exercise C
  setsid/setpgid/double fork/background, pipe EOF, kqueue, launchd bootout,
  Python/Node/npm/nested-shell detachment, Swift compile/run and xcodebuild version.
- `python3 -m unittest discover -s Tests/SandboxPhase1 -v`:
  **23/23 passed, zero failures, 20.881 seconds**; final strengthened rerun
  **23/23 passed in 20.701 seconds**. L1 negative assertions passing
  mean the proposed mechanisms failed the security contract, not that L1 passed.
  The strengthened run asserts the delayed effect is absent immediately after
  cleanup/EOF/bootout and appears afterward, requires exact ENOTSUP, and verifies
  the temporary launchd job is unregistered. Positive L2 tests confirm normal Pi spawn/custom spawn and actual MCP result
  with expected inheritance; Milk-owned worker descendants remain key-free.
- Actual host macOS 26.5.2 / 25F84; pinned Pi 1.4.0 asserted. Synthetic files and
  credentials only. No Keychain/personal profile/live provider access.
- Test execution outside the tool sandbox permits nested Seatbelt, temporary
  per-user launchd registration and loopback model fixtures. No root or restricted
  entitlements are used. Normal background descendants are group-cleaned; all
  deliberately detached fixtures exit after their bounded 600ms effect.
- No app build/production regression rerun in this continuation: app inputs are
  unchanged. Prior 219-test Swift result remains historical, not a new run.

## Bounded independent L1 pass (2026-11-01)

User requested one fresh, practical attempt using previous evidence, with no L2
reconsideration and no architecture/UX change. Considered three narrowly selected
possibilities; did not rerun the previously rejected group/kqueue/launchd/pipe
experiments or launch an exhaustive platform review.

### First-principles requirement

Treat each operation's inherited Seatbelt grant as membership in a kernel-owned
set of live processes, independent of parent PID, process group and session.
A sufficient mechanism would atomically attach every new fork to that set,
maintain stable identity across exec/reparenting, and provide authoritative
empty/dead acknowledgment. Alternatively it could seal creation, terminate every
member and wait for verified emptiness. A snapshot plus kill is not that primitive:
a still-live unseen member can fork just before/after the snapshot. Suspending
only the known root does not suspend already detached processes. PID-reuse-safe
audit tokens improve identity for known processes, not completeness of membership.

### Three candidates and disposition

1. **Kernel resource coalitions / responsibility ownership.** This is closer to
   the required inherited set than a process group. Local public spawn headers do
   not expose an ordinary per-operation coalition create/assign/terminate contract.
   Apple's `sys_coalition.c` syscall demultiplexer requires the caller to belong
   to a privileged coalition. More importantly, its termination contract expressly
   permits existing members to keep forking: requesting termination is not an
   atomic freeze/kill-all/death acknowledgment. Responsibility attribution is not
   an enforceable per-operation kill domain. No private coalition/responsibility
   SPI or restricted entitlement was adopted or invoked. Rejected on API/prerequisite
   evidence, not by pretending an entitlement failure proves all implementations
   impossible.
2. **Public libproc aggregate termination / stable audit identities.** The installed
   SDK surprisingly declares `proc_terminate_all_rsr`, so this was investigated as
   a genuinely new lead. Apple's implementation filters the system process list
   by `P_RSR` (Rapid Security Response), not operation ancestry or an application
   selected group; the wrapper takes only a signal, not a subtree handle. It is
   unrelated to Milk's grant holders and must not be experimentally invoked against
   system processes. `proc_signal_with_audittoken`/termination variants identify
   individual targets safely but supply neither recursive membership nor an
   admission barrier. Rejected without executing any system-wide signaling call.
3. **Pre-armed debugger supervision / suspended-root admission.** Public ptrace
   and Mach task suspension were considered as a way to catch forks before any
   descendant runs. The installed Darwin ptrace header has no advertised recursive
   fork-follow option. Task suspension concerns a known task, not a complete set
   of independently executing tasks. Added only a small self-tracing C experiment:
   root applies a disposable Seatbelt profile and stops for its parent tracer
   before any workload fork; a cleanup pipe releases a new setsid child or
   double-fork branch immediately when cleanup starts. The intended observation
   is descendant traced state plus a delayed marker after root death. **The
   experiment did not yield usable lifetime evidence:** both scenarios timed out
   (15s each), including after a bounded stop/continue event-loop correction.
   The exact stalled stage was not established. Do not interpret these timeouts
   as proof of recursive tracing support or of a successful escape. Stopped this
   candidate; no further debugger instrumentation project is planned.

### Focused artifacts, execution and validation

- Added `Tests/SandboxPhase1/trace_lifetime_probe.c` and manual runner
  `trace_lifetime_experiment.py`. They are not built/staged into Milk. The manual
  runner is deliberately excluded from unittest discovery so an inconclusive
  experiment cannot be counted as a passing security test.
- Initial unittest-style run: one test with single/double scenarios, **2 timeout
  errors**, 30.676s. A bounded event-loop correction also produced **2 timeout
  errors**, 30.108s. These are harness/experiment limitations, not a security-gate
  result. No descendant-lifetime claim is inferred from either run.
- Converted the experiment to a manual runner with a five-second deadline per
  scenario, an owned process group for cleanup, and output files rather than
  inherited capture pipes. This cleanup is test hygiene, not a proposed L1
  solution. The deliberately detached effect paths, if reached, exit after 700ms.
  The manual runner reported `timeout-inconclusive` / `validated:false` for
  both single and double scenarios at its five-second deadlines. Exact temporary-
  executable cleanup inspection found no retained trace probes.
- Only self-created children are traced/signaled; no unrelated app is attached,
  no real credential or personal profile is used, and no global RSR termination
  function is called. No restricted entitlement, root service or VM is introduced.
- Local API inspection: full Xcode macOS SDK `libproc.h`, `spawn.h`, `sys/ptrace.h`.
  No tests for already-rejected mechanisms or production regressions/builds were
  repeated. Phase 2 remains unstarted; branch/HEAD/production diff unchanged.

Primary source references:

- [Apple XNU coalition syscall](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/sys_coalition.c): privilege gate and terminate-versus-fork semantics.
- [Apple XNU proc_info implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/proc_info.c): `proc_terminate_all_rsr_filter` selects `P_RSR`, not a caller-defined subtree.
- [Apple libproc wrapper](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.c): the aggregate RSR wrapper accepts only SIGTERM/SIGKILL, no operation identity.

### Bounded conclusion

**No practical entitlement-free native candidate was established. L1 remains
unresolved.** This pass is not an exhaustive impossibility proof; it found no
supported immutable descendant-membership + zero-live acknowledgment primitive
that Milk can use to close the cleanup race under the stated constraints.
Pre-arming a monitor/suspending a root is insufficient without a proven kernel
fork-admission/tracking guarantee; none was demonstrated here.

There is no new best candidate meeting all constraints. The strongest realistic
remaining directions are a documented OS-provided descendant/job primitive
(including an Apple-supported entitlement-free API if made available), or a
stronger killable execution boundary. Only after the simpler native candidates
above were rejected/unvalidated does a disposable macOS VM remain an architectural
fallback to evaluate separately; no VM work was undertaken or approved. Endpoint
Security remains excluded as a required dependency. Typed-only grants, process
polling and declaring expiry before verified emptiness remain non-solutions to
this approved target, not silently adopted alternatives. L2 is untouched.

## FSKit revocable-boundary investigation (2026-11-01)

### Scope / status

User authorized a materially different **candidate invariant**: keep the operation
and detached descendants alive if necessary, but expose the additional folder only
through a revocable filesystem, with no direct access to the backing root. Expiry
would require authoritative loss of grant-mediated access, not proof of descendant
death. This is investigation only: no approved architecture/UX or production code
is changed and L2 remains settled. No VM work is performed.

**Result: distribution and passthrough are viable in principle; security revocation
is not proven. FSKit is not ruled out.** Missing signing/activation prevents a live
mounted proof on this host. `FSResource.revoke()` by itself is not documented as a
mounted-vnode/client-handle revocation barrier. Do not convert either limitation
into an unsupported claim that a custom FSKit filesystem cannot ever enforce it.

### Public APIs, distribution and activation

- Apple's official passthrough sample exports an existing directory through an
  FSKit filesystem. `FSPathURLResource` supports file URLs/security-scoped URLs on
  macOS 26.0+, within Milk's OS range. This is not a kernel extension or a VM.
- The filesystem runs as an app extension with
  `com.apple.developer.fskit.fsmodule` and App Sandbox. Apple's macOS supported-
  capabilities table marks FSKit Module available for ADP and **Developer ID**;
  it is not marked development-only. The sample enables the capability through
  normal Xcode signing. No Endpoint Security-style exceptional approval requirement
  was found in these public contracts. Actual account provisioning/notarization
  is not validated by reading the table.
- Apple's setup requires the user to enable the filesystem extension in System
  Settings → General → Login Items & Extensions → File System Extensions. That
  is an extension activation prerequisite, not a grant automatically provided by
  the existing Milk Allow Once popup. It cannot be silently bypassed.
- On macOS 26, the published integration is the system `mount` tool (including
  `-F` to force FSKit selection), followed by normal unmount tooling. Milk can
  construct explicit executable/argv calls as a host operation, not shell text
  substitution. Actual mounting/unmounting authorization, busy/forced-unmount
  behavior and error acknowledgment must be tested in the signed setup.
- Do not confuse module callback methods with client control APIs:
  `FSUnaryFileSystemOperations.unloadResource` is implemented **by the extension**,
  not a macOS 26 `FSClient` host command to revoke another mounted client.
  The installed macOS 26.5 SDK FSClient exposes extension discovery only.
- Apple's new `FSClient.mountSingleVolume` is **macOS 27+** and requires
  `com.apple.developer.fskit.mount`; it cannot be a dependency for the current
  macOS 26 target. Likewise `FSVolume.setCacheState(... action: .revoke)` and
  `KernelCacheCoherencyAction.revoke` are documented **macOS 27+**. Their more
  promising item/cache/vnode revocation semantics are not available in this SDK.

### What the three lifecycle operations actually establish

1. **FSResource.revoke:** public contract removes the resource object's underlying
   privileges / connection to its resource. `isRevoked` is an object state flag;
   proxy resources report it true even without a new revoke call. There is no
   documented global mounted-client FD/mmap invalidation or completed-I/O-drain
   acknowledgment in that method's contract. Calling it on an object transported
   into another process is not evidence that every mounted vnode is invalidated.
2. **Sample unloadResource:** Apple's implementation balances its security-scoped
   URL access and clears its resource reference. Its volume implementation keeps
   backing root/item descriptors and uses pread/pwrite. The callback itself does
   not implement a security revocation gate across those operations. Do not invoke
   one's own callback and call that a kernel unmount proof.
3. **Volume unmount/deactivate:** the macOS 26 FSVolume API describes synchronization
   before deactivation and reclaim of other file nodes before the deactivate
   callback. This is promising teardown evidence, but this review does not prove
   forced unmount invalidates existing client descriptors/mappings or establish
   every failure/race condition. A blocked/EBUSY/failed unmount must not be reported
   as revoked. Simply deleting/hiding a mount directory is explicitly insufficient.

A custom revocable filesystem would need to close admission on **all** backend
operations, drain in-flight backing I/O, prevent later forwarding through cached
backing FDs, and obtain kernel-side client invalidation/teardown acknowledgment.
Kernel caching, delayed writeback, directory handles, newly racing opens and mmap
cannot be discharged by checking a Boolean only in open(). Requests may run in
parallel; a reply must not acknowledge revocation while an earlier write can still
reach the backing folder. No such custom implementation was added in this task.

Data already copied into a process's memory cannot be unread; that is distinct
from continued access via an open/mapped live filesystem object. The acceptance
proof must block continuing backing access and delayed mutations, not pretend
that cached bytes are erased from arbitrary process memory.

### Minimal executable evidence (not a mounted acceptance test)

Added manual-only prototypes under `Tests/SandboxPhase1/`:

- `fskit_resource_probe.m` links Foundation/FSKit and creates an actual
  FSPathURLResource for a disposable, non-security-scoped directory. It opens a
  synthetic backing file/FD and shared mmap, calls revoke, then probes object
  state, existing FD I/O, a fresh backing-path open, and mmap/msync.
- `fskit_resource_experiment.py` compiles/runs it in a TemporaryDirectory using
  full Xcode and isolated module cache. No app extension or mount is installed;
  output expressly contains `mounted_test:false`.

Command: `python3 Tests/SandboxPhase1/fskit_resource_experiment.py`.
Actual macOS 26.5.2 result:

```json
{"fsclient_mount_api_present":false,"mounted_test":false,"resource_revoked_after":true,"resource_revoked_before":false,"underlying_existing_fd_read":true,"underlying_existing_fd_write":true,"underlying_mmap_msync":true,"underlying_new_open":true,"volume_cache_revoke_api_present":false}
```

**Interpretation limit:** this process has independent ambient access to the
backing path; it is not an FSKit mounted client and has no security-scoped token
as its sole access authority. The result prevents mistaking `isRevoked` for an
OS-wide FD-revoke primitive. It does **not** prove mounted passthrough handles
survive proper forced unmount or disprove a custom backend gate.

The optional newer-selector probes use Apple's exact Objective-C metadata names;
they are read-only availability checks, not invocation of private/new APIs.

### Why the required mounted proof stopped

Outside the tool sandbox, `security find-identity -p codesigning -v` reports
**0 valid identities**. `pluginkit -m -p com.apple.fskit.fsmodule` lists only the
system exfat/msdos/ftp modules, not a passthrough module. Thus no normally signed,
activated custom extension is available to mount. Do not fake this distribution
prerequisite by forging an entitlement or substituting APFS/FTP/non-FSKit mounts.
No developer account credentials were requested and no extension was installed
or enabled. Apple's sample source was inspected only in temporary storage.

| Required test | Status |
| --- | --- |
| Normal read/write through temporary FSKit mount | NOT RUN — signed/activated passthrough module unavailable |
| Shell, npm/Node, Python through mount | NOT RUN |
| setsid and double-fork clients retaining mounted handles | NOT RUN |
| Already-open mounted FD after revoke/force-unmount | NOT RUN; backing-file object-scope observation above is not a substitute |
| Delayed writes and new opens after authoritative revoke | NOT RUN |
| Rename/symlink traversal and mount-to-backing escape | Source reviewed; executable mounted test NOT RUN |
| mmap/page faults/writeback after revocation | NOT RUN on mount; direct backing mmap experiment only |
| Concurrent I/O racing with revoke and teardown completion | NOT RUN |

### Path semantics / structured bridge

There is a clean limited mapping at **structured boundaries**: canonical real
folder → grant-specific mounted root; translate a validated typed path, explicit
argv pathname or working-directory field before execution. Never send underlying
backing FDs to the untrusted operation. Seatbelt must permit the mount and deny
the backing root and its relevant aliases. For the proof, broad outside-read
permission must not accidentally provide independent direct backing access.
Revocation removes grant-derived access, not an independent authorization already
held by some unrelated path/domain.

Arbitrary command strings/scripts may contain absolute original paths. There is
no general safe rewrite into the mounted namespace without parsing programs.
Supply the explicit mounted path/cwd via structured executor context and let
commands use it; commands hardcoding the original path remain denied. This is
not transparent compatibility for every existing script. Symlinks to absolute
backing paths may resolve back to the denied original; relative symlinks may
escape the exported root unless module/client policy checks the actual target.
Cross-filesystem rename/hardlink and identity semantics also differ. The Apple
sample uses POSIX backing FDs and O_SYMLINK; it is an example filesystem, not
Milk's policy/security boundary. No unsafe shell parser or path rewriting was
implemented, and no path-semantics product change was silently approved.

### References and conclusion

Primary sources read: installed macOS 26.5 FSKit headers; Apple's passthrough
source download; current official Markdown/API availability metadata:

- [Passthrough sample](https://developer.apple.com/documentation/fskit/building-a-passthrough-file-system)
- [macOS capabilities / Developer ID support](https://developer.apple.com/help/account/reference/supported-capabilities-macos)
- [FSKit Module entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.fskit.fsmodule)
- [FSResource.revoke](https://developer.apple.com/documentation/fskit/fsresource/revoke())
- [FSPathURLResource](https://developer.apple.com/documentation/fskit/fspathurlresource)
- [New mount API](https://developer.apple.com/documentation/fskit/fsclient/mountsinglevolume(resource:bundleid:options:completionhandler:)) — availability 27.0+
- [Kernel cache state API](https://developer.apple.com/documentation/fskit/fsvolume/setcachestate(for:cachemode:coherencytype:action:)) — availability 27.0+

This changes the **candidate** missing proof: a revocable filesystem could remove
the need to enumerate/kill grant-inheriting processes, if it demonstrably revokes
live handles and drains backing access. We have not established that property on
macOS 26. `FSResource.revoke()` and the sample unload method alone do not establish
it; macOS 27 vnode/cache APIs cannot be assumed for Milk's current minimum OS.
**L1 remains unresolved, Phase 1 incomplete, Phase 2 unstarted.** The next useful
proof requires a properly signed, user-enabled passthrough extension and the
mounted matrix above, especially force-unmount, pre-opened FD/mmap and concurrent
I/O. This is a concrete verification prerequisite, not proof that FSKit is
impossible. No VM, production edits, UX change, grant fallback or Git mutation.


## Practical L1 approval and Phase 1 exit review — 2026-11-01

### Decision and scope

The user explicitly withdraws the all-grant-retaining-processes-dead expiry
requirement. L1 is resolved by an **accepted security limitation**, not by a new
macOS termination/revocation primitive. L2 remains resolved without reconsideration.
The fixed Pi sandbox, sibling executor, arbitrary development commands, temporary
folder grants, precedence, Protected Locations, Project R/O, controlled real Git,
native worker isolation and fail-closed policy remain unchanged.

Once belongs only to the operation-specific executor profile. Finish/cancel/timeout/
end immediately invalidates future admission, independent of cleanup outcome.
Session revoke/restart/end likewise prevents subsequent use and initiates affected
execution cleanup. Static profiles/open handles cannot be retroactively shrunk.
A deliberately detached setsid/new-group/double-fork/reparented survivor can retain
its old operation's access until exit (and pass that inherited profile to its own
descendants), but cannot widen Pi, escape inherited Seatbelt or authorize a newly
admitted Milk executor operation to reuse the expired grant.

Owned cleanup: TERM group → short bounded drain → KILL remaining group → reap owned
children; safely terminate individually known descendants and best-effort known
orphans using stable identity where available. Preserve owned identity through
final signalling; never target unrelated processes by reused PID/name/port. This
is resource hygiene, not a subtree-death certificate. Production implementation
of this lifecycle belongs to Phase 3, with integration acceptance in Phase 7.

Expected long-lived npm/Vite/Next/Python servers, watchers and Preview servers are
explicit managed jobs with identity, origin, authorized policy/profile/grant scope
and Preview/session/project ownership. Stop them with their owner, track restarts
and cancellation, and never silently turn a completed Once child into a persistent
job. Agent-generated jobs remain mediated/sanitized rather than acquiring trusted
Preview execution. Phase 5 implements host-effect/job integration on Phase 3's
owned-execution machinery; no such production changes occur here.

### Investigation cleanup and retained coverage

Removed research-only `trace_lifetime_probe.c`, `trace_lifetime_experiment.py`,
`fskit_resource_probe.m`, `fskit_resource_experiment.py`. Removed abandoned kqueue
NOTE_TRACK, inherited-EOF latch, launchd bootout and process-info-setcontrol
candidate code from the retained lifetime harness. Their actual historical results
above remain unchanged; no new FSKit/debugger/coalition/ES research was performed.
No filesystem extension, restricted entitlement, VM or typed-only fallback adopted.

Retained `lifetime_probe.c` / `test_lifetime.py`, simplified to useful regressions:
ordinary and TERM-resistant group cleanup, unrelated-process safety, deliberate
setsid/new-group/double-fork survivors with inherited filesystem denials and an
immediate fresh-operation denial of the old grant path, detached
Python/Node/npm/nested-shell limitation, ordinary shell/Python/Node/npm background
cleanup, Swift compilation/execution and xcodebuild startup. Synthetic detached
payloads exit after their delayed marker, leaving no intentional persistent job.
Readiness/marker polling is fixture synchronization, not a containment mechanism.

Kept all general kernel/Git/Pi/credential/native-worker tests. The real-Pi Once
read test retains a fixed parent PID, consumes a grant for one tool's access/read
substeps and rejects the next operation. The separate native counterexample
proves a surviving grant-holder can still write while the fixed runtime remains
denied. Together they test scope nonreuse and the accepted limitation; the typed
read fixture does not restrict arbitrary-command grants in the target design.
The README now documents the retained architecture and its test limits.

### Final revalidation and gate assessment

- Final command: `python3 -m unittest discover -s Tests/SandboxPhase1 -v`,
  on the actual macOS 26.5.2 / 25F84 host with pinned Pi 1.4.0, outside the nested
  tool sandbox for Seatbelt/loopback access: **22/22 passed, zero failures,
  23.939 seconds**, including fresh-operation denial while the detached holder
  survives. The retained set is eight kernel/Git/native tests, five lifetime/toolchain
  tests (with command/mode subtests), and nine real-Pi routing/credential tests.
- The first post-cleanup run reported 10 subtest errors from final group KILL
  returning EPERM after TERM exited the fixtures. A disposable sleep process
  reproduced this. The harness correction checks owned-leader exit with public
  `waitid(WNOWAIT)` without releasing its identity, then reaps and checks delayed
  effects. TERM-resistant fixtures still require successful force-kill. The next
  full run passed 22/22 in 24.105s; the final run above adds concurrent grant-nonreuse
  coverage. No assertion of ordinary-child cleanup or sandbox denial was removed.
- [Apple XNU killpg1](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_sig.c)
  filters zombies from group iteration and can return EPERM when none is counted.
  That source review corroborates the observed edge; EPERM alone is not evidence
  of successful cleanup and production must report real signalling failures.
- `git diff --check` passes; tracked production diff remains empty. Final branch/
  HEAD remain `security/api-keychain` / `c00305f72821c04ae1f76cb0327d3a465bc7b7a5`.
  The added documents/harness are still untracked; their working-tree contents
  were reviewed explicitly. No commit, push, merge, rebase or branch change.
- Prior Swift regression evidence remains 219/219 (86.637s), **not rerun** in this
  continuation. No app build is needed for these isolated tests/docs. No signed
  packaging, full macOS matrix, live provider, personal profile or Keychain test
  is claimed here.

| Phase 1 gate | Final feasibility disposition / later implementation boundary |
| --- | --- |
| Seatbelt + descendant containment | PASS on tested macOS 26.5.2 primitives; normal and detached children inherit denials. Deprecated mechanism risk and per-release fail-closed validation remain; full deny-default profiles/signing are Phases 6–7. |
| Fixed runtime + sibling operations | PASS; nested policy cannot widen, independent sibling can, Pi PID/profile stays fixed and next operation loses Once. Production authenticated IPC/path/grant ownership is Phases 2–3. |
| Pi built-ins/nested/user_bash/custom/MCP/cancel/results | PASS for executable routing feasibility using supported hooks, real factory results and aborts. Unknown tool paths fail closed; approved Pi-owned execution remains in its fixed sandbox/domain. Full discovery/image/truncation/stream/performance parity is Phases 3 and 7, not claimed proven here. |
| Managed / Existing / inactive profiles | PASS for synthetic root split; real-path overlap/race matrix and policy are Phases 2 and 7. |
| L2 | RESOLVED; spawning-enabled Pi/MCP inheritance and clean Milk executor/native-worker descendants verified. No credential-domain redesign. |
| Milk extension agent-worker boundary | PASS for native execution isolation; trusted host capability difference demonstrated. Actual SDK/package/host-effect integration is Phase 5. |
| Controlled real Git | PASS for structured exact-argv real operations, hooks/editor helper, linked metadata denial and no surrounding shell grant. Complete argv/config/repository validation/helper lifecycle is Phase 5; unsupported shell forms remain denied, no generic parser promised. |
| L1 practical lifetime | RESOLVED BY EXPLICIT ACCEPTANCE. Future-operation nonreuse, ordinary TERM/KILL/reap and unrelated-process safety pass. Detached survivors retain the inherited profile as documented; no all-dead or already-open-handle revocation guarantee. Known-orphan identity-safe cleanup and managed-job integration remain Phases 3/5/7. |

**Exit decision:** no other genuine Phase 1 feasibility blocker was identified.
At the Phase 1 exit, Phase 2 had not started and no production enforcement
was claimed. Phases 2/3 progress and validation are recorded below.
Later implementation/security acceptance obligations above remain mandatory.

## Remaining work / deferred work

Phases 2–4 are complete within their covered scopes; their implementation/validation
is recorded below. Phases 5–7 remain future production work and acceptance: authenticated IPC and safe path/grant handling, full stock
Pi tool semantics/images/truncation, deny-default purpose profiles and executable
closure, managed-job/UI integration, complete structured Git validation and helper
ownership, actual native SDK/worker packaging, signing and OS matrix/regression.
These are not claims of existing protection or reasons to repeat abandoned L1
research. The overall ExecPlan stays active because the sandbox is not shipped.


## Phase 2 execution record — 2026-11-01

Scope: reusable Milk-owned policy, durable settings, canonical path/scope snapshots,
in-memory activation/operation grants and environment-domain interfaces. No launch,
Seatbelt enforcement, Pi routing, popup/countdown, process cleanup, managed job,
Git escalation, extension worker or Preview execution changes. L1/L2 remain settled.

Current HEAD/branch still c00305f / security/api-keychain; incoming Phase 1 harness
and design/plan/instructions remain untracked and preserved. Existing SettingsService
owns UserDefaults, WorkspaceStore exposes the active project URL, and
AgentLifecycleCoordinator owns AgentActivation tokens and all stop/drain/shutdown
paths. Reuse these seams rather than persisted chat IDs for grant authority.

Implemented boundaries:
- New focused Sandbox models, path resolver, policy, settings store, grants and view.
- SettingsService/SettingsContent/MainWindow wire a dedicated Sandbox category.
- Lifecycle registers/invalidates in-memory scope only; no execution enforcement.
- Tests exercise policy precedence, filesystem aliases/missing targets and stale
  identities, durable settings/migration, temporary grant/lifecycle isolation.
- Settings states that enforcement is pending; configured ON is not a protection claim.

Progress:
- [x] Read current request, repository instructions/references, design and plan.
- [x] Inspect current settings, activation/lifecycle, adapter and workspace seams.
- [x] Implement policy/path/configuration/grant types and settings UI.
- [x] Focused tests, touched-code regressions and app build.
- [x] Final review, documentation and Phase 2 exit assessment.

### Implemented interfaces and persistence

- `SandboxModels.swift`: schema-1 durable DTOs (ON, R/W project defaults, RO/RW
  folders, editable registry and timeout), generic subject/profile/build-root/context
  types, explicit decision outcomes/reasons and environment-domain descriptors.
- `SandboxPathResolver.swift`: lstat/link walking before .. normalization; public
  O_EVTONLY/NOFOLLOW + fstat/F_GETPATH for actual spelling and identity snapshots,
  non-existent descendants through an existing ancestor, and revalidation.
- `SandboxPolicy.swift`: seven-level first-applicable precedence, distinct protected
  and normal approvals, profile ownership/subject split, safe ambiguous-root denial.
  Explicit purpose build roots remain below stronger restrictions. Read-only folder
  grants approve reads only; writes require approval, never lower-priority fallback.
- `SandboxSettingsStore.swift`: independent UserDefaults data key
  `Milk.sandbox.configuration.v1`, canonical project-path map, atomic in-memory
  publication after validated serialization, malformed/future state retained and
  policy denied. Empty protected registry is distinct from missing/migrated fields.
  Restore preserves custom/edited entries and avoids equivalent-directory duplicates.
- `SandboxGrants.swift`: fresh per-operation IDs under existing AgentActivation
  tokens; Once only for one operation, Session only for one activation, explicit
  revoke/end/invalidation, no fixed-runtime grant application and no Codable authority.
  Retired tokens cannot reopen admission. Grant matching rechecks snapshot, access,
  subject, rule and boundary IDs after fresh policy evaluation.
- `SandboxSettingsView.swift`: existing row/group conventions, add/edit/remove
  location sheets, native file importer, project access, timeout units, restore,
  temporary permission display/session revoke. Explicit pre-enforcement status.
- Existing settings/sidebar and lifecycle files wire these services only. No adapter
  implementation, Pi resources, provider secrets, process launching or execution
  effects were modified. AgentAdapter's existing lifecycle context supplies the
  generic ownership seam; no redundant Pi-specific sandbox state added to it.

### Path and enforcement limits for Phase 3

A snapshot is not an atomic open or a complete hard-link/inode-reuse defence.
Canonical spelling and explicit protected-file identities are tested; this is not
all-alias discovery for arbitrary contents of protected folders. Fresh host-owned
configuration/scope evaluation, descriptor-safe target handling, kernel enforcement
and authenticated activation/operation IPC remain later work. Cached policy results
cannot become indefinite authority. No Seatbelt or Git exception is applied here.
The accepted L1 inherited-survivor limitation and L2 credential domains are untouched.

### Validation and final assessment

- Initial compile succeeded; the earliest filter ran before new test files existed
  and matched zero tests (not counted as verification).
- First actual focused run: 26 tests, four failed assertions from test expectations
  using Foundation /var URLs vs kernel /private/var canonical spelling/directory
  URL markers. Corrected fixture expectations, not policy denials.
- Next focused run: 26/26, 0.284s.
- Full regression after that implementation: 245/245, 87.581s.
- After equivalent-directory restoration and injected-home migration fixes:
  `swift test --cache-path "$PWD/.build/cache" --disable-sandbox --filter
  'Sandbox|AgentLifecycleTests|SettingsTests'`: 64/64, 7.266s, including
  new policy/grant/settings tests and existing lifecycle/installation/provider settings.
- Final full regression after those persistence fixes: **246/246 passed**, zero
  failures, 79.762s, command `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" swift test --cache-path
  "$PWD/.build/cache" --disable-sandbox` (host access for existing loopback tests).
- One final OFF/unavailable-project edge correction was then covered by the final
  targeted command using the same environment and filter
  `'Sandbox|AgentLifecycleTests|SettingsTests'`: **65/65 passed**, zero failures,
  7.254s. This contains **28 new sandbox tests** (12 policy/path, 9 grant/lifecycle,
  7 settings) plus existing lifecycle/settings/provider/manager regressions. The
  broad suite was not rerun after this narrow, directly tested OFF correction.
- `./scripts/build.sh --disable-sandbox`: **PASS**, stages `output/Milk.app`,
  validates/stages normal resources/SDK and performs the script's ad hoc signing
  verification. Build compilation 3.81s; normal install_name_tool re-sign warning.
  No provisioning profile selected: existing API-key persistence signing requirement
  remains unchanged (see API_KEYCHAIN). No real provider/key operation tested.
- `git diff --check`: PASS. Reviewed tracked diffs and all new sources/tests/docs
  explicitly (they remain untracked). Branch/HEAD unchanged: security/api-keychain /
  c00305f72821c04ae1f76cb0327d3a465bc7b7a5. No commit/push/merge/rebase/branch change.
- New tests use only disposable files/preferences. No Phase 1 harness/research was
  changed or rerun. No production sandbox launch, IPC, Pi routing, popup/countdown,
  process cleanup, managed job, Git escalation, native worker or Preview effect added.
- Interactive/manual Settings UI acceptance was not performed. SwiftUI compilation,
  model persistence/policy tests and app packaging passed; full interaction and
  enforced security acceptance remain later-phase obligations.

Current-reference updates: README, RUNTIME, DEVELOPMENT, docs index and new
`docs/SANDBOX_POLICY.md` describe the exact preparation/enforcement distinction,
configuration key/migration, precedence, registry defaults and limitations.
The approved target design, L1/L2 decisions and Phase 1 evidence are preserved.

**Exit:** Phase 2 is complete. No genuine Phase 2 blocker or user decision remains.
Phase 3 is ready on separate user authorization, but has not begun. The configured
ON switch is not a claim of active protection. The active overall plan remains
open for Phases 3–7; no default-ON enforcement rollout is approved by this result.


## Phase 3 execution record — 2026-11-01

User authorized production launcher, sibling executor, authenticated live-operation
routing, anchored Sandbox approvals, grant use/revocation, owned cleanup and fail-closed
handling only. L1/L2 and policy remain settled. Branch security/api-keychain /
c00305f; prior Phase 1/2 changes preserved. No commit/push/branch mutation.

Implementation resumed from externally created checkpoint `be99984` (the agent did
not create that commit). Current branch remains `security/api-keychain`. No commit,
push, merge, rebase or branch change is part of this work.

### Implemented boundaries

- Generic `SandboxProfileBuilder` compiles policy partitions above Pi, with stronger
  nested protected/inactive/RO scopes excluded from broader permissions. File-data,
  xattr, metadata and writes outside the admitted scopes deny. Fixed runtime profiles
  never receive temporary grants. Invalid construction/application has no unrestricted
  fallback. Existing top-level Git worktree gitdir/commondir and `.git` write denial
  are minimum protection, not Phase 5 Git escalation/complete metadata inventory.
- `SandboxProcess` / `milk_sandbox_spawn` use `posix_spawn`, private standard pipes,
  close-on-exec defaults, reset signals and a dedicated process group. An owned C
  waitid(WNOWAIT) watcher reserves leader identity through TERM/100ms drain/KILL and
  waitpid reap, including ordinary completion. No Foundation competing reaper or
  unrelated PID/name/port cleanup is used. Detached stdout holders cannot hang reads.
  Deliberate setsid/double-fork survivors remain the accepted L1 limitation.
- `PiRPCClient` uses that process owner ON and preserves its original process path
  OFF. `SandboxLaunchAuthority` carries host-owned policy through pre-RPC backend
  resolution to the version probe's read-only work/private cache purpose. The broader
  compatibility/package/maintenance purpose inventory remains Phase 6.
- Per-activation `PiSandboxExecution` creates fresh operation IDs/capabilities under
  `SandboxGrantStore`. Its begin/next/cancel/finish protocol uses the host-owned Pi
  RPC/UI pipes. IDs supplied by Pi do not create permission. Stale/unknown/duplicate
  polling routes reject. Capacity/update bounds cancel rather than open a fallback.
  Fresh policy and grant scope are applied before each sibling launch. Once admission
  ends before drain; Session revoke closes future use and cancels all workers whose
  compiled profiles used that grant. Policy/runtime failure/restart invalidate scope.
- `MilkSandboxBridge.ts` installs public stock-tool overrides. `MilkSandboxWorker.ts`
  runs once in a sibling using the **selected** Pi executable, no model/provider
  call, no third-party extensions/MCP/skills/prompts, private worker HOME/TMP/profile,
  and a separately constructed key-free environment. No coding agent is bundled in
  Milk. Packaging stages only the three Milk-authored integration TS modules.
- Read/write/edit/bash/grep/find/ls, nested built-ins and `user_bash` route through
  this worker. Stock factories preserve result/images/search/edit/error/truncation
  behavior; updates and user-bash bytes return through the bridge. Bash's public
  operations hook is used to preserve Milk-owned group membership and cancellation.
  Structured paths resolve against the trusted workspace/HOME. Bash may declare
  exact `sandboxFolders`; no shell parser, command rewriting or automatic denied
  rerun exists. Opaque undeclared outside access receives the fixed kernel decision.
- `pi.exec`, custom direct spawning, Pi extensions and stdio MCP stay in Pi's fixed
  trusted credential domain. They cannot acquire a temporary sibling grant. Unknown
  model/custom/MCP tools reject ON; agent-callable native catalog and direct native
  bridge requests reject pending Phase 5. No native UI/layout/settings redesign,
  extension worker API, real-Git escalation or managed server implementation added.
- Preview inspection gets an ephemeral Milk profile, project RO, read tools only;
  the selected persistent profile remains inactive. Agent-suggested host server
  startup is blocked ON until the managed-job boundary. Trusted user Terminal,
  Editor, GitService and normal user Preview remain unchanged.
- Settings changes drain fixed runtimes (timeout-only edits affect future prompts).
  Ask/Autonomous permission changes use a generic adapter capability to require
  restart rather than silently changing an immutable kernel profile. Direct backend
  callers must explicitly supply Sandbox settings; compatibility tests select OFF
  explicitly instead of relying on an absent settings object as a bypass.

### Approval UI

`SandboxApprovalCenter` feeds the existing anchored `ComposerApprovalPopup`, not a
modal. It binds path/action/tool/command/workspace and activation. Ask uses
Once/Session/Deny without a timer; Autonomous uses the configured deadline and the
approved unavailable-user timeout denial. Immediate identical timeout retries are
suppressed narrowly; no fixed retry interval is disclosed. Protected flow offers
Once/Settings/Deny, never Session. Settings denies/closes that request and opens the
Sandbox page. Ordinary agent editing approvals retain their separate origin.

The actual child panel was rendered through AgentService/ComposerApprovalAnchor in
both light and dark appearance, inspected for path wrapping/context/buttons and
Settings handoff. This is automated AppKit interaction/render evidence, not a claim
of a complete physical-click/manual acceptance campaign. Disposable screenshots
are under `/private/tmp/milk-phase3-popup-{light,dark}.png`, outside source control.

### Discoveries corrected during runtime validation

1. macOS 26 dyld ignition requires a literal `/` directory read. Allowing only
   runtime/system subtrees prevented startup. The compiler permits literal `/`, not
   an Ask-mode outside subtree read, plus necessary ancestor metadata. Actual outside
   content/write denials and Protected overrides remain tested. Public root
   symlink objects `/var`, `/etc`, `/tmp` also require literal read permissions for
   developer shims such as xcode-select; their destination subtrees are not allowed
   by this exception. Ask-mode Python and outside-path-alias denial are tested. OS/developer RO
   dependencies are explicit; broader non-filesystem service closure remains later.
2. The bridge is a separate TS import, so it must have an exact read dependency in
   addition to Integration/Worker. No whole resource/home widening was used.
3. Pi 1.4's current edit contract is `edits:[{oldText,newText}]`; the host validates
   that actual contract. Images use a real synthetic PNG instead of malformed bytes.
   Stock Bash nonzero exit is an `isError` result, not necessarily a thrown error.
4. Stock Pi Bash internally uses `detached:true`, which escaped ordinary group
   cleanup even without explicit command detachment. The public operations hook now
   spawns non-detached shells, preserving arbitrary commands and L1. Delayed marker
   checks cover normal completion, abort and Session revoke after the write delay.
5. Foundation path normalization retained `/var` aliases on this host. Ask-mode
   Preview could not read its model catalog despite the canonical profile root.
   Ephemeral profiles/cache and runtime profile environment now use the existing
   lstat/F_GETPATH resolver's kernel paths. Actual read-only Preview and user bash
   pass without weakening outside read policy. Saved-session arguments and managed
   profile ownership checks use the same kernel canonical spelling; OFF launch
   environment/resource spelling remains unchanged.
6. Nested execution must be tested with a real ToolExecutionContext, not a command
   context. The integration test instruments only a disposable copy of Milk's own
   extension to invoke a nested read from the same extension owner. Upstream Pi and
   production tool allowlists are unchanged; real stock ls/search contracts have
   separate worker tests.

7. Final review found that an already-cancelled operation could skip the asynchronous
   RPC drain sleep. ON shutdown now awaits the owned C wait/reap without inheriting
   cancellation. Signals also target the directly owned, identity-reserved leader
   if it moved out of the original group. A focused Python fork/setpgid fixture
   verifies this leader cleanup; detached descendants retain the same accepted L1
   limitation. This does not introduce process enumeration or reopen L1 research.

### Validation and acceptance results

- `SandboxExecutionTests` cover launch/OFF/malformed failure, project R/W/RO,
  real Once/Session/Protected permissions, timeout/duplicate denial, stale authority,
  images/edit/search, independently clean shell/Python/Node/npm children, active
  Session revoke and settings invalidation, ordinary/TERM-resistant cleanup with
  unrelated-process safety, accepted detached survivors and fresh-operation denial,
  pre-RPC version denial/OFF parity, production user-bash bytes/abort/background work.
- `SandboxPiIntegrationTests` uses actual pinned Pi + synthetic localhost model and
  fake credential store to cover parent bridge to sibling write/read, Protected Once,
  nested read, unknown handler rejection, model-tool cancellation, fixed runtime
  denial after sibling permission, and Pi-owned `pi.exec`/spawn key inheritance.
- Existing native-extension/launch-wrapper/profile compatibility fixtures explicitly
  test OFF. Real API-key/None/provider-model-thinking/saved-resume tests also run ON. Existing Phase 1/2 tests remain intact. Final results are below.
- Fresh copied managed-style Pi `--version` and real managed/Existing/inactive
  profile access under compiled production profiles passed. Managed executor access
  succeeds; Existing executor access denies without approval; both runtime domains
  can access their selected active profile; an inactive profile overrides a broad
  persistent RW grant. This does not substitute for later full install-purpose coverage.
- `Tests/Fixtures/test_clean_app_resources.py`: 1 test passed; app resource recipe
  stages only Milk integration modules/notices and no coding-agent executable.

- [x] Read current request, instructions/references and Phase 2 implementation seams.
- [x] Launcher/profile/process ownership and sibling helper.
- [x] Policy/grant admission and anchored approval service.
- [x] Production Pi integration/routing and fail-closed deferred paths.
- [x] Focused/runtime regressions, full suite and app build final pass.
- [x] Final code/docs review and Phase 3 exit decision.

### Remaining scope / migration limits

No approved policy or L1/L2 decision changed. Unknown custom/MCP model tools, native
agent effects, real-Git metadata writes and agent-suggested Preview startup fail
closed ON until their later boundaries exist. Existing third-party `pi.exec`/spawn
code remains in the fixed Pi domain and does not automatically route to a sibling
for additional folders. Full developer-tool cache configuration and host service/
Mach/network/executable closure remain later purpose hardening; this profile is a
filesystem boundary, not full security certification.

ON Preview inspection was exercised with the adapter-owned Local provider in its
private ephemeral profile. Provider configuration and OAuth/auth files living only
in an Existing Pi profile are not copied into that profile. Such configured-provider
Preview parity needs Phase 4 validation/integration; the current code cannot assume
those provider definitions/credentials appear in the empty inspection profile.
No credential broker, weaker storage or silent fallback was added. No live Local/
oMLX provider, personal Keychain, notarized release or broad third-party provider
acceptance was exercised in this phase. Those remain explicitly separate acceptance.

### File/component map

| Boundary | Main files |
| --- | --- |
| Policy compiler and identity-safe process owner | `Sources/Milk/SandboxProfile.swift`, `SandboxProcess.swift`, `SandboxLaunchAuthority.swift`; `Sources/MilkPTY/MilkPTY.c` and header |
| Pi-owned runtime and sibling transport | `Sources/Milk/PiRuntimeService.swift`, `PiUtilityProcess.swift`, `PiSandboxExecution.swift`, `PiBackend.swift`, `PiAdapter.swift`; `Runtime/MilkPiIntegration.ts`, `MilkSandboxBridge.ts`, `MilkSandboxWorker.ts` |
| Core ownership / permission restart and presentation | `Sources/Milk/AgentAdapter.swift`, `AgentModels.swift`, `AgentService.swift`, `SandboxApprovalCenter.swift`, `ComposerApprovalPopup.swift`, `SandboxSettingsView.swift`, `ShellState.swift` |
| Resource staging / explicit acceptance construction | `scripts/stage-app-resources.py`, `Tests/Fixtures/test_clean_app_resources.py`, `Sources/Milk/AgentAcceptanceVerification.swift` |
| Focused runtime/UI proof | `Tests/MilkWorkspaceTests/SandboxExecutionTests.swift`, `SandboxPiIntegrationTests.swift`, `SandboxPopupTests.swift`, `SandboxLegacyTestSupport.swift`; synthetic `Tests/Fixtures/local_provider_fixture.py`; explicit OFF constructor/context changes in existing native/Pi compatibility tests |
| Current references / plan | `README.md`, `RUNTIME.md`, `docs/DEVELOPMENT.md`, `docs/README.md`, `docs/SANDBOX_POLICY.md`, `docs/EXTENSION_DEVELOPMENT.md`, this ExecPlan |

### Final measured result — 2026-11-02

Host: Apple Silicon, macOS **26.5.2 (25F84)**. No support claim for untested macOS
versions. Full Xcode toolchain selected with `DEVELOPER_DIR` and project module cache.

- Final full Swift command: `swift test --cache-path "$PWD/.build/cache" --disable-sandbox`
  with the documented Xcode/module-cache environment: **264 tests, 0 failures** in
  132.767 seconds. This includes the focused Sandbox families, actual Pi provider/
  resume tests, lifecycle/profile/native/Preview/terminal/Git/layout regressions and
  both owned-leader and accepted detached-survivor proofs. Log outside source:
  `/private/tmp/milk-phase3-acceptance-swift.log`.
- Preserved Phase 1 command: `python3 -m unittest discover -s Tests/SandboxPhase1 -v`:
  **22 tests, 0 failures** (29.332 seconds). Log:
  `/private/tmp/milk-phase3-phase1-regression.log`. No abandoned research was restarted.
- Resource recipe command: `python3 -m unittest discover -s Tests/Fixtures -p 'test_*.py' -v`:
  **1 test passed**; no agent executable staged.
- Final `./scripts/build.sh --disable-sandbox`: **passed**, including bundle staging
  and `codesign --verify --deep --strict`. Output `output/Milk.app`; three Milk TS
  integration resources present. Log `/private/tmp/milk-phase3-build-final.log`.
  This is the local development build, without a provisioning profile; live Keychain
  persistence/notarized distribution was not acceptance-tested.
- Actual AppKit anchored popup render/Settings response passed in both light/dark
  appearance and was visually inspected. Full human click/background concurrency
  acceptance remains Phase 7; no physical-click testing is claimed.
- Final working-tree/diff review and `git diff --check` passed. Branch remains
  `security/api-keychain`, HEAD `be99984e5bbc25015808a65f1a23003b9cf55316`. The agent did
  not commit, push, merge, rebase or switch branches. Generated builds/logs/personal
  data and credentials are not added to source control.

**Exit:** Phase 3 is complete for the authorized launcher/executor/approval scope.
ON actually enforces the covered filesystem/runtime/tool boundaries; OFF remains
explicitly unenforced. No genuine Phase 3 blocker or new product/security decision
remains. Phase 4 is ready for separate authorization and has **not begun**. The
remaining purpose/host-effect/provider/release gates and the accepted detached-
survivor/credential-domain limits remain explicit; the overall ExecPlan stays active.

## Phase 4 execution record — 2026-11-02

Authorized descendant environment hardening and provider parity only. Branch remains
`security/api-keychain`, HEAD `be99984`; all uncommitted Phase 3 work is preserved.
L1/L2 remain settled; no Phase 5 host effects, Git escalation or extension-worker
redesign. Existing helper resource staging/build workflow is reused.

Current-code findings: PiLaunchResolver still copies the entire ambient environment
before profile selection and version probing. Worker construction is already separate
but duplicated inline. Version probes can receive runtime credentials and startup
injection variables. Parent RPC stderr/errors have no credential redaction. Local
injection already clears stale Milk variables and reads the scoped Data Protection
Keychain only after resolution; keep that source of truth/header precedence behavior.
Preview Local works in a private profile; Existing-only configured-provider auth is
not automatically present there. Do not copy auth files or silently change profile
precedence to repair that parity gap.

Plan: reusable host environment construction with separate runtime and Milk execution
purposes; resolve original HOME/profile first, preserve documented provider inputs
and declared profile configuration references, strip loader/shell/Git injection;
independently build worker/probe environments. Verify real Pi credential inheritance
including stdio MCP, synthetic hostile ambient dictionaries and Local replacement/
revocation/None/endpoint/profile behavior. Keep diagnostics credential-free. Record
any unsupported configured-provider Preview seam explicitly. Full regressions and
app build before Phase 4 exit; current-reference docs updated alongside behavior.

- [x] Read current code, repository/reference/security/provider/Keychain documents.
- [x] Environment construction and launch integration.
- [x] Credential-domain / provider parity integration tests.
- [x] Focused and full regressions, app build, final review and exit decision.

### Implemented Phase 4 boundaries

- `SandboxEnvironment` / `SandboxToolchainEnvironment` provide an agent-agnostic,
  independently constructed Milk execution boundary. No ambient or Pi-supplied
  dictionary is accepted. HOME/TMPDIR are host-selected private work, PATH is selected
  support plus normal tool locations, locale/shell defaults are explicit. A separately
  validated existing absolute DEVELOPER_DIR preserves the user's selected Xcode;
  it adds no filesystem grant. Future native extension workers can reuse this base;
  no Phase 5 worker API/executable/integration was implemented.
- `PiEnvironment` owns Pi-specific runtime/probe/worker construction. Profile/HOME
  ownership is resolved before filtering; existing settings hashes and Keychain
  accounts remain unchanged. Runtime keeps Pi 1.4's documented provider variables,
  needed profile/process controls, TLS/proxy inputs, SSH-agent/XDG inputs and locale.
  Extra host variable references are admitted only from selected-profile API-key/
  header fields and MCP env/header/OAuth-secret fields. Model IDs/descriptions and
  project-controlled files are not environment authority. The selected user profile
  remains trusted runtime configuration; this is not a general host-secret isolation
  guarantee against Pi-owned code/configuration in that domain.
- Ambient Milk credential/authority flags, dynamic-loader injection, shell/interpreter
  startup injection and Git overrides are stripped. Runtime PATH retains only absolute
  nonempty entries, with selected support first and system fallbacks; no agent binary
  is selected from PATH. NUL/invalid metadata and support paths that cannot be encoded
  safely in PATH fail closed. Caller-supplied env/environment tool dictionaries reject.
  Sandbox OFF remains filesystem-unenforced while this environment hygiene still applies.
- Version and compatibility helpers have private HOME/TMP/profile and no provider
  credentials/proxy auth. `PiRuntimeService.probeEnvironmentOverrides` is separate
  from runtime overrides; raw custom runtime credentials are not copied to probes.
  Pi package code-location and validated toolchain metadata are preserved without
  copying provider dictionaries or granting extra filesystem access. Actual purpose
  filesystem closure for remaining install/package/utility paths stays Phase 6.
- `PiLaunchResolver`, `PiBackend`, `PiUtilityProcess`, `PiCompatibilityProbe` and
  `PiSandboxExecution` use those constructors. Local Keychain read/injection still
  occurs last through `PiProviderSupport`; no new storage or credential broker.
  `PiLaunchContext` retains only host-owned explicit launcher/toolchain metadata
  needed by these distinct purposes. No broad host-user environment reaches a child.
- `RuntimeDiagnosticRedactor` sanitizes admitted Local/provider credentials and custom
  authentication-reference values from RPC error fields, stderr and failures. Partial
  reads, UTF-8 boundaries and retained stderr windows are handled without exposing a
  key suffix. Each launch gets a fresh generation/redactor so retired callbacks cannot
  enter a replacement credential scope. This does not stop trusted Pi code deliberately
  disclosing a key via data, tool arguments or Pi-owned files (the approved L2 limit).

### Variable audit and compatibility

| Input family | Pi-owned runtime | Milk-owned executor/worker | Version/compatibility helpers |
| --- | --- | --- | --- |
| Local/oMLX key | Fresh exact profile/endpoint Keychain injection; normal Pi child/MCP inheritance | Never inherited; not a constructor input | Never inherited or loaded from Keychain |
| Other provider keys | Documented contract and supported selected-profile auth references | Not copied | Not copied from runtime overrides |
| PATH | Selected support, safe absolute host entries, standard tool dirs | Selected support + fixed standard dirs | Selected support + safe executable search paths |
| HOME / profile | Selected managed/Existing identity; Preview uses its covered private profile | Private operation HOME/profile | Private purpose HOME/profile |
| TMPDIR | Private runtime cache ON; resolved trusted runtime input OFF | Private work | Private purpose cache |
| Loader/shell/interpreter startup | Removed; system shell explicit | Absent | Absent |
| Git env overrides | Removed; normal Git command/config behavior remains inside its filesystem policy | Absent; no new escalation | Absent |
| Proxy/TLS/SSH inputs | Preserved explicitly for provider/helper compatibility in the Pi domain | No ambient credential/socket/proxy copy | No provider proxy credentials |
| Pi/Milk flags | Selected Pi controls retained; Milk policy/key flags written by host after filtering | Only private worker/offline controls | Offline/private controls, separate explicit non-secret probe inputs |

Native configured providers continue using their own auth.json and OAuth ownership;
no auth file is copied, no provider is re-registered by Milk, and future adapters are
not forced through Pi or a Milk broker. Local None does not read a saved key or fall
back to stale auth; current API-key headers override stale reserved auth as before.
Unknown opaque ambient extension variables are intentionally not copied wholesale.
Use supported user-profile configuration or explicit adapter-owned runtime inputs.
Launchers relying on removed injection/relative PATH need safe explicit setup; no
unrestricted retry or different-runtime substitution was added.

### Executable evidence and exact validation

Host: Apple Silicon / macOS 26.5.2 (25F84), full Xcode toolchain and project caches.
Synthetic credentials only, in-memory SecItem simulation; no personal Keychain,
real oMLX admin/sub-key operation, hosted OAuth refresh or live cloud provider used.

- `SandboxEnvironmentTests`: hostile ambient dictionaries, selected-profile reference
  fields, reserved Milk/loader/shell/Git stripping, safe PATH, NUL/HOME failure, typed
  Xcode selection, FIFO/unsafe-support rejection, actual RPC stderr/error redaction,
  and an executable custom runtime-token vs version/compatibility-helper proof.
- `SandboxProviderParityTests`: real Pi + strict synthetic localhost server verifies
  Local discovery/inference, exact Keychain scope, replacement, server revocation,
  Keychain deletion, wrong endpoint/profile, stale auth.json precedence and None.
  Scans generated configuration/session/request data for injected synthetic keys.
  A second real-Pi case verifies native custom-provider auth-file precedence and
  declared environment authentication without modifying its models/auth files.
- Existing actual Local provider tests cover model discovery, inference, model choice,
  thinking settings, unknown limits and saved-session resume with Sandbox ON.
  Existing main bridge test now starts a real stdio MCP server and records only the
  Boolean key-inheritance result. Pi extension/pi.exec/direct spawn inheritance still
  passes; no proxy or spawning ban. Executor shell/Python/Node/npm tests include hostile
  provider/startup canaries and prove those variables are absent in descendants.
- Final full command with documented Xcode/cache env:
  `swift test --cache-path "$PWD/.build/cache" --disable-sandbox`:
  **275 tests, 0 failures**, 142.400 seconds. Log:
  `/private/tmp/milk-phase4-acceptance-swift.log`.
- Added focused production-worker toolchain proof after that full run:
  `swift test --cache-path "$PWD/.build/cache" --disable-sandbox --filter SandboxExecutionTests.testSwiftAndXcode`:
  **1 test passed** (2.178 seconds). Compiled/ran a Swift program with a private module
  cache and ran `xcodebuild -version` through the actual sanitized sibling. No production
  feature code changed for this extra test; it is not counted in the 275 total.
  Final review additionally applied the same diagnostic redaction to pending-request
  failure continuations; the focused environment/RPC suite was rerun after that guard:
  **9 tests passed** in 0.612 seconds (`/private/tmp/milk-phase4-diagnostics-final.log`).
- `python3 -m unittest discover -s Tests/Fixtures -p 'test_*.py' -v`: **1 passed**;
  resource recipe still stages Milk integration modules only, no coding agent.
- `./scripts/build.sh --disable-sandbox`: **passed** including bundle staging and
  strict deep signature verification. Log `/private/tmp/milk-phase4-build.log`.
  Development/ad-hoc build without provisioning; real Data Protection Keychain CRUD
  and notarized release acceptance remain separate. Storage/selectors were unchanged.
- Full working-tree/diff review and `git diff --check`: passed. No commit, push,
  merge, rebase or branch switch. All prior Phase 3 local work remains present.
  Branch `security/api-keychain`, HEAD `be99984e5bbc25015808a65f1a23003b9cf55316`.

### Current limits and Phase 4 exit

The previously recorded Sandbox-ON inspection profile still covers Local Preview.
Existing-profile-only configured-provider models/auth do not appear in that empty
private profile. Current native RPC couples those sources to agentDir; the public SDK
has separate ModelRuntime auth/models paths, but that is not a supported source-path
switch in this current RPC integration. We did not copy credentials, relax inactive
profile precedence, add a broker, or change runtime transport to hide this seam.
It remains a recorded broader provider/purpose acceptance item, not a regression in
Phase 4's currently covered Preview path. Main runtime configured-provider parity is
proved. Full hosted/OAuth/provider/platform/release acceptance remains later work.

Phase 4 is **complete for its authorized covered execution paths and minimum provider
parity matrix**. No new user decision or blocker is required for those paths. L1/L2,
policy precedence and approved UX are unchanged. Phase 5 has **not begun**; native
agent workers, real-Git escalation, managed jobs and broad host effects remain deferred.
The overall ExecPlan remains active for the remaining target acceptance.

Phase 4 main files: new `Sources/Milk/SandboxEnvironment.swift`, `PiEnvironment.swift`,
`RuntimeDiagnosticRedactor.swift`; edits to `PiLaunchContext`, `PiRuntimeService`,
`PiUtilityProcess`, `PiCompatibilityProbe`, `PiBackend`, `PiSandboxExecution`; new
`SandboxEnvironmentTests` and `SandboxProviderParityTests`; strengthened real bridge/
executor fixtures and explicit non-secret probe controls in installation test fixtures;
current RUNTIME, Sandbox/provider/profile/Keychain/DEVELOPMENT references and this plan.

## Phase 5 execution record — 2026-11-02

Authorized Git escalation, native agent-worker redesign, host-effect mediation,
origin-safe Preview and explicit managed jobs only. Existing Phase 1–4 uncommitted
work remains on security/api-keychain / be99984. No commit/branch/history mutation.
No Phase 6 rollout/purpose inventory, restricted entitlement, VM, FSKit or L1/L2 work.

Current code: native tools/piCommand capture in-process closures; native bridge is
blocked ON. Preview assist returns only a command config and is blocked ON; trusted
DevServerService uses login zsh + inherited user environment. Pi sibling operations
already own policy/grants, private pipe capabilities, sanitized env and identity-safe
process groups. Reuse those boundaries; do not make DevServerService globally sandboxed.

Implementation boundaries: structured milk_git operation, real /usr/bin/git with
repository/config/metadata identity and argv recognition (no compound-shell parser);
independently signed Milk Extension worker executable and SDK agent entry point;
metadata-only native tool registration with no in-process fallback; bound worker IPC
with only explicitly mediated effects; explicit job IDs/scopes owning foreground
commands beyond the initiating RPC; Preview origin receipts retained through restart
and never persisted as trusted commands. Existing user host UI/services stay trusted.

- [x] Read request/current instructions/references and audit code boundaries.
- [x] Controlled Git metadata inventory / argv / process / policy integration.
- [x] Native SDK registration, sandbox worker, IPC and host-effect gates.
- [x] Managed jobs, lifecycle and Preview origin integration.
- [x] Focused/adversarial/regression/packaging tests, build/signature verification.
- [x] Current docs, final review and Phase 5 exit decision.

### Implemented Phase 5 boundaries

- `SandboxGit.swift`: bounded descriptor-validated worktree/gitdir/commondir + config/
  includes/hooks/attributes/excludes inventory and structured argv recognition. Normal
  profiles deny writes to those controls and `.git`, including tested hard-link aliases.
  Real Git preflight is sandboxed; only the exact recognized operation escalates.
  Read Only blocks mutation; stronger overlapping roots and canonical explicit paths
  are policy checked. Global `-c`/`-C`, shell wrappers, remote URL/exec overrides and
  ambiguous forms fail closed. Cached `apply --cached ... -` accepts a bounded patch
  on stdin only. No surrounding shell or later operation inherits elevation.
- `SandboxHostEffects.swift`: shared generic policy/approval/process controller. Git
  preserves host Git configuration, hooks/helper/editor execution and a validated
  canonical SSH socket as an explicit trust exception, with no ambient provider/
  loader/shell/Git injection dictionary. Control/config changes require reconnect;
  Git's own changes refresh snapshots, and new control roots invalidate the fixed
  activation. Bare/ambiguous repositories are unsupported, never silently elevated.
- API 2 `ExtensionAPI.swift`: metadata-only agent tools, `agentWorkerClass`, separate
  `MilkExtensionAgentWorker`, URL-value/typed-Git context and file declarations.
  Removed `piCommand` and agent handler closures. UI/layout/settings/user command/
  native-service APIs remain trusted and otherwise unchanged. API 1 packages require
  rebuild; there is no unsafe legacy fallback even OFF.
- `MilkExtensionWorker/Worker.swift`, `SandboxExtensionExecution.swift`: separate
  executable/signing identity, profile/env before bundle loading, bounded private
  newline-JSON result/error/Git IPC, current package/registry/owner checks, cancellation
  and revocation. No native host service facade, generic filesystem/process/network,
  clipboard or secret bridge. Direct worker effects inherit its sandbox/environment.
  Unknown frames fail closed. Worker success waits for owned process cleanup; no
  claim of detached-descendant death is made. A shared scope/profile grant receipt
  cancels active Git/extension operations on applicable Session revocation, including
  operations with no Once grant. Activation invalidation also closes these scopes.
- `ContributionRegistry` / `NativeExtensionManager`: metadata catalog and verified
  invocation preparation only, never trusted agent closure dispatch. Catalog withdrawal
  cancels active worker invocations. `PiSandboxExecution` copies the catalog into its
  private activation cache; host live registry remains authority. Native prompt lookup
  is static registry text, not code or arbitrary file I/O.
- `MilkSandboxBridge.ts` / `MilkPiIntegration.ts` / `PiBackend`: structured `milk_git`,
  `milk_job` and worker routes share private operation/capability transport ON/OFF.
  Unknown model routes remain denied ON. Host-controlled routes skip duplicate Pi
  ordinary approval; Milk merges required FS approval with the displayed action, or
  asks once for the ordinary action when no FS approval is needed. Git FS prompts
  disclose elevated configured helper trust. Legacy native invocation requests fail.
- `AgentManagedJob.swift`: explicit live stable host UUID, session/project/activation,
  immutable purpose/request, operation/grants/profile/env domain, state/output and
  stop/restart ownership. No PID/group/port adoption. Start registers an independent
  job operation; ordinary Once bash never becomes a daemon. Restart keeps job ID and
  opens fresh scope/profile/permissions; output generation prevents stale updates.
  Stop, owner invalidation, relevant Session revoke and runtime/settings/session/project
  lifecycle terminate owned execution. Deliberate detachment remains accepted L1.
- Preview preserves origin using an in-memory host receipt (session, existing
  activation, workspace generation, exact configuration). Inspection remains an
  independent auxiliary resource, connecting the owning session only at explicit
  launch. Assisted command bytes go unchanged to a nonlogin sibling shell; static
  suggestions use a Python loopback job. `DevServerService` rejects trusted launch of
  agent-origin configuration and wraps only a live host job receipt. Preview owns its
  jobs; generic model job restart cannot take over Preview. Agent commands/receipts
  never persist as trusted launch memory. Missing/stale origin fails closed. User
  Preview retains its login-shell/inherited environment path.
- `build.sh` stages/signs the Milk-owned helper with only library-validation exception,
  distinct identifier, no parent DP Keychain/app identity or provisioning profile.
  It still stages no coding agent. Example oMLX UI keeps Keychain/network in-process,
  publishes a nonsecret observation snapshot, and registers a worker to read that
  declared snapshot. No credential handoff or invented telemetry.

### Host-effect audit / execution inventory

| Entry | Current disposition |
| --- | --- |
| Pi built-in tools/user_bash ON | Existing sibling stock workers; no Git elevation from shell text |
| `milk_git` | Exact validated real-Git operation; configured helpers are the accepted exception |
| `milk_job` | Explicit current-activation job receipt; no adoption, caller env or Preview control |
| Native model tool | Verified separate worker, FS policy + typed Git only; no native closure |
| Legacy native tool/command bridge | Reject ON/OFF; static active prompt lookup only remains |
| Native user slash/UI/service | Trusted explicit host route, never selected by model bridge input |
| Native workspace/process/network/Git/clipboard/secrets facades | UI context only; absent from worker SDK |
| MCP/unknown model custom effects ON | Fail closed; Pi-owned trusted direct spawning remains L2 |
| Agent-assisted Preview | Origin receipt → backend-owned `.preview` job, sanitized environment |
| User Preview/Terminal/Editor/GitService | Existing trusted host paths remain |

### Discoveries and bounded fixes

1. Real Git identity preflight opens `/dev/null` read/write. Existing profiles only
   permitted reading `/dev`; a narrowly classified literal null-device allowance was
   necessary. No writable device subtree was added; stronger policy still overrides.
2. Connecting a main conversation before Preview inspection broke independent
   auxiliary lifecycle/quit behavior. Inspection is independent again; only explicit
   server launch connects its originating session, checking the receipt after await.
3. POSIX shell `wait` can return 0 after group termination. The ordinary cleanup test
   now verifies bounded cleanup, delayed-write absence after the write deadline and
   unrelated process survival rather than requiring a negative shell status.
4. Review found generic host operations needed compiled-profile grant receipts too,
   beyond the stock Pi worker job receipt. Shared grant tracking cancels active native/
   Git operations on Session revoke. Published notifications precede assignment, so
   cancellation store mutations are deferred until assignment completes.
5. Automatic review rejected an attempted success-cleanup ordering change. It was
   not applied; extension success retains stop-IPC → terminate/await → finish order.
   The accepted future-admission/detached-survivor semantics were not changed.

### Validation in progress

- Focused host-effect production tests: 7/7 passed, including real Git add/commit/amend/
  checkout/switch/branch/merge/reset/restore/cached patch/fetch/pull/push (local bare
  remote only), hooks/editor/diff helper, shell/metadata/hardlink/linked-worktree,
  Read Only/Protected/changed-config rejection, actual compiled separate worker,
  sanitized shell child, Protected Once/Session, cancel/disable, managed restart/
  revoke/shutdown and mediated Preview. Additional Session-revocation receipt check
  is running after final security review.
- Focused integration batch 41/41 passed; follow-up lifecycle/executor/host/Pi/native
  batch 34/34 passed. Real model-driven Pi Git/job tools and native workers run ON
  with disposable localhost provider data. No live Git/provider credential used.
- Preserved Phase 1: `python3 -m unittest discover -s Tests/SandboxPhase1 -v`:
  **22/22 passed**, `/private/tmp/milk-phase5-phase1.log`.
- Resource recipe: `python3 -m unittest discover -s Tests/Fixtures -p 'test_*.py' -v`:
  **1/1 passed**, `/private/tmp/milk-phase5-resources.log`.
- Initial full Swift run: 283 tests, 2 failures (independent Preview lifecycle and
  shell exit convention above); fixes verified in focused regression. Final full
  suite / build / signing and final exit decision pending below.

### Remaining scope / limitations

Accepted L1/L2 are unchanged. Deliberate detached descendants can retain inherited
static profiles; expiry/revoke closes future admission and cleans owned groups, not
all descendants. Real Git configured hooks/helpers remain elevated code by design.
Git recognition/inventory is intentionally bounded, bare/ambiguous forms fail closed,
and conservative bulk root checks can over-request/deny access. This does not claim
atomic protection against independent trusted filesystem/config edits during launch.
API 2 breaks old agent-extension source/ABI and requires rebuild. Worker stdout is
protocol-only; arbitrary unsolicited stdout fails the invocation. Pi profile-only
custom configured provider/auth Preview inspection still has Phase 4's recorded
private-profile seam; no credential copy or policy weakening was introduced.
No default-ON rollout, broad purpose/package/install closure, live remote/provider,
Developer ID/notarization/release or full manual app-quit acceptance is claimed here.


Final review follow-ups: native registrations now carry a fresh private nonce, so
withdrawing and re-registering the same public tool ID cannot revive an old worker
receipt. A dedicated test covers that case. Packaged apps require their own helper
and fail closed if it is missing; SwiftPM tests inject their explicit built helper
because XCTest's main app bundle is not Milk.app. Pi/native integration now asserts
the actual returned worker text as well as approval counts, rather than permitting
an unnoticed missing-helper error to satisfy an approval-only check. The active
Session-revocation worker proof passes with the kernel-canonical `/private/var` path
rather than Foundation's public `/var` spelling. These are Phase 5 boundary/validation
fixes; no purpose-rollout or L1/L2 decision changed.


### Final Phase 5 validation / exit — 2026-11-02

**Phase 5 complete. No new Phase 5 blocker remains. Phase 6 is ready for separate
user authorization and has not begun.** The overall Sandbox plan stays active
because its later purpose/rollout/release phases remain incomplete.

Final code validation:

- Full Swift command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" swift test --cache-path
  "$PWD/.build/cache" --disable-sandbox`: **284 tests, zero failures**,
  `/private/tmp/milk-phase5-final-suite.log` (166.9 seconds). This includes preserved
  Phase 1–4 Swift regressions, new registration nonce proof, main Pi Git/jobs/native
  worker transport, native UI/example build/install/update/restart/removal, Preview,
  trusted Git/Terminal and provider/profile/Keychain synthetic acceptance.
- Final host-effect suite: **7/7 passed**, including active extension Session revoke,
  `/private/tmp/milk-phase5-focused-final.log`. Follow-up actual Pi worker text and
  same-ID registration nonce checks: **2/2 passed**,
  `/private/tmp/milk-phase5-native-final.log`.
- Preserved Phase 1: **22/22 passed** (31.7 seconds),
  `/private/tmp/milk-phase5-phase1.log`. Resource recipe: **1/1 passed**,
  `/private/tmp/milk-phase5-resources.log`.
- `./scripts/build.sh --disable-sandbox`: **passed**,
  `/private/tmp/milk-phase5-build.log`. Staged Milk app, shared SDK and distinct
  Milk-owned worker helper; no coding-agent executable staged.
- `codesign --verify --deep --strict output/Milk.app`: **passed**. Actual helper
  entitlements equal `{com.apple.security.cs.disable-library-validation: true}`;
  signing identifier `dev.milk.extension-worker`; no Milk Keychain/application
  identity or helper provisioning profile. This is ad-hoc development signing,
  not provisioned Keychain persistence / Developer ID / notarization acceptance.
- Packaged hardened-runtime helper proof: set `MILK_TEST_WORKER_PATH` to
  `output/Milk.app/Contents/Helpers/MilkExtensionWorker` and run the focused actual
  extension-worker test via SwiftPM: **1/1 passed**,
  `/private/tmp/milk-phase5-packaged-worker.log`. The signed packaged helper loads
  the independently compiled fixture bundle, executes the real worker/process/Git
  routes, obeys Protected Once/Session and cancellation/disable/revocation, and
  its shell child stays key-free. This validates packaged loading beyond unsigned
  development-helper tests. The test-only selector does not affect production
  helper selection, provider environment or persisted settings.
- Practical UI/runtime inspection is executable: native SwiftUI/AppKit window and
  extension state tests, plus a live Python HTTP Preview job/readiness/rendering/
  stop test. No broad manual user-workspace or app-quit/release certification claimed.
- Final `git diff --check`: **passed**. Branch remains `security/api-keychain`, HEAD
  `be99984e5bbc25015808a65f1a23003b9cf55316`. No commit/push/merge/rebase/branch switch.
  Earlier uncommitted Phase 3/4 work remains preserved.

Earlier intermediate failures were corrected rather than hidden: Preview's eager
connection, shell exit convention, test `/var` vs kernel `/private/var` comparison,
missing XCTest helper selection and approval-only worker assertion. One overlapping
edit/rebuild was rejected by SwiftPM and rerun on stable code. The final full suite
and signed-helper run above are the completion evidence.

Main Phase 5 files:

- New `Sources/Milk/{SandboxGit,SandboxHostEffects,SandboxExtensionExecution,
  AgentManagedJob}.swift`, `Sources/MilkExtensionWorker/Worker.swift`,
  `scripts/milk-worker.entitlements`, `Tests/MilkWorkspaceTests/SandboxHostEffectsTests.swift`
  and `docs/SANDBOX_HOST_EFFECTS.md`.
- `SandboxProfile.swift`, `SandboxGrants.swift`, `SandboxApprovalCenter.swift`,
  `PiSandboxExecution.swift`, `PiBackend.swift`, `AgentModels.swift`,
  `Runtime/MilkSandboxBridge.ts`, `Runtime/MilkPiIntegration.ts`.
- `Packages/MilkExtensionKit/.../ExtensionAPI.swift`, host `ContributionRegistry.swift`,
  `NativeExtensionManager.swift`, `PackageInspection.swift`, the external oMLX example
  source/manifest, root `Package.swift`, `scripts/build.sh`.
- `AgentService.swift`, `PreviewModels.swift`, `PreviewService.swift`,
  `DevServerService.swift`, `ShellState.swift`; native/worker/Pi/lifecycle/Preview
  regression fixtures and tests. Current README/runtime/extension/sandbox/development
  references, repository map and this active plan are updated with actual behavior.

Remaining limits are the approved/bounded ones recorded above: deliberate detached
survivors, configured real-Git helper trust, bounded recognition/inventory and snapshot
race limits, API 2 rebuild migration, and the pre-existing Existing-only configured
provider Preview-inspection seam. Phase 6 must address its own broader purpose,
install/compatibility inventory and rollout gates before release claims. No L1/L2,
approved product/security decision, or user host privilege boundary was weakened.


## Phase 6 execution record — 2026-11-02

Authorized purpose closure and default-ON readiness only. Preserve existing Phase 1–5
work on security/api-keychain / be99984; no history/branch mutation. L1/L2, Git helper
exception, API 2, user host features and the Existing-only Preview provider seam stay
settled. No Phase 7 release/live-provider/adversarial-certification campaign.

Re-audit findings at entry: conversation, Preview inspection, stock workers, native
workers, managed jobs and typed Git have production boundaries. Version enforcement
is conditional on TaskLocal authority; standalone probes can miss it. Compatibility
RPC launches without a profile. Package CLI launches are unprofiled, use runtime env,
and do not distinguish read-only source from writable target. Installation extraction
is trusted in-process libarchive with validated paths/digests/platform/inventory;
only candidate version/RPC children need the new executable-purpose boundary, not a
new archive helper. Runtime policy settings already invalidate backends/jobs, but
automatic fresh-policy reconnection and auxiliary-purpose cancellation need closure.

Implementation: validate selected executable/interpreter/Mach-O/module dependencies
before executing; compile explicit per-purpose read/write ceilings intersected with
normal policy; independent private HOME/TMP/cache/profile for all non-user-data
purposes; typed local package source/target contract; default policy always resolved
at standalone entry points (never implicit unrestricted fallback). Preserve explicit
OFF and fail closed on malformed closure or missing dependencies. Wire Settings
snapshots/watchers to auxiliary processes and reconnect existing runtime owners after
old admission closes/drains. Keep a complete inventory and evidence below.

- [x] Read request/current code and identify remaining launches.
- [x] Executable/interpreter closure and purpose plans.
- [x] Version/compatibility/package/install wiring and private environment/storage.
- [x] Policy lifecycle and default-ON/OFF UI/reference reconciliation.
- [x] Focused tests/full regressions/preserved Phase 1/package/helper/build/signatures.
- [x] Final inventory/evidence, limits and Phase 6 exit decision.

### Final launch inventory and authority mapping

The detailed current contract is `docs/SANDBOX_PURPOSES.md`. This inventory covers
production agent launches; it distinguishes trusted host features and explicit
developer diagnostics rather than treating them as agent fallbacks.

| Launch boundary | Profile / filesystem authority | Environment, storage and ownership |
| --- | --- | --- |
| Conversation: `PiBackend` / `PiLaunchResolver` / `PiRPCClient` | Current project/profile policy plus validated selected executable, interpreter, code/module graph and named support inputs; code is read-only. | Existing approved Pi credential domain; selected HOME/profile, private activation TMP/cache; owned runtime lease. |
| Preview inspection: discovery `PiBackend` | Project Read Only, narrow runtime inputs, private active profile; selected source profile remains inactive. | ON private HOME/profile/TMP; approved Local injection remains Pi-owned. Auxiliary lease drains before deleting state. OFF keeps the explicit compatibility behavior. |
| Pre-RPC version: `PiRuntimeService` / `PiUtilityProcess` | Required version purpose plan even without task-local context; narrow validated dependencies, no ordinary project/profile grant. | Independently sanitized, key-free private HOME/TMP/cache/profile and writable scratch workspace; bounded output/deadline; cleanup awaited. |
| Compatibility: `PiCompatibilityProbe` | Explicit profiled RPC; selected closure, Milk integration/bridge, only discovery checks; original profile inactive. | Private HOME/TMP/cache/profile/workspace; no provider credential, user extension/MCP/skills/session loading or model prompt. Lifecycle/cancel/settings shutdown awaited. |
| Install/update/repair candidate: `PiInstallationManager` | Artifact platform/hash/notices/archive/inventory validation before candidate version/compatibility execution; candidate code read-only, inventory rechecked afterward. | Installation/compatibility purpose plans; private probe state, no provider key. Staging and cleanup remain owned through recovery. |
| Package install/remove: `ExtensionService` / `PiUtilityProcess` | Actual selected runtime; explicit local source read-only, exact selected target profile writable subject to stronger policy; purpose ceilings exclude unrelated grants. | Separate key-free environment/private HOME/TMP/cache; only PI_CODING_AGENT_DIR selects the persistent target. Fresh owned transaction, awaited cleanup. |
| Stock/nested tools and user_bash: `PiSandboxExecution` | Existing sibling executor/per-operation policy and grants; selected code/resources read-only. | Separate sanitized operation HOME/profile/TMP, no Local key; private bridge capabilities and owned process cleanup. |
| Background/watch/agent Preview jobs: `SandboxHostEffects` | Explicit immutable job request, current project/grants and development-tool dependencies; no Pi dependency tree borrowed for generic jobs. | Separate key-free HOME/TMP and explicit activation/session/project/job owner; revocation/stop/drain rules preserved. No silent adoption of arbitrary descendants. |
| Native API 2 agent tools: `SandboxExtensionExecution` / `MilkExtensionWorker` | Validated helper/library closure and verified package; capability-scoped file authority; minimal non-shell roots, development dependencies only for shell tools; code read-only. | Separate signed helper identity without Milk Keychain entitlement; private key-free HOME/TMP and bounded typed IPC. Trusted native UI stays in-process. |
| Controlled Git: `SandboxHostEffects.git` | Sandboxed preflight then exact recognized real Git escalation; configured hooks/helpers/editors remain the explicit exception. | Sanitized Git environment and explicit Git user HOME/validated SSH socket; no Local key, no surrounding shell elevation. |

`AgentInstallationStore`, downloads, libarchive extraction/inventory and installation
metadata remain trusted in-process Milk code. No archive helper was needed: existing
validation rejects traversal/link/special entries and validates the complete candidate
before executable validation. Trusted user Terminal/Editor/GitService/user Preview and
native extension UI remain host-owned. Explicit `--verify-*` diagnostic fixtures are
not production agent launch paths. The three production RPC launch callers are the
backend, compatibility probe and stock worker; all supply an explicit ON/OFF argument.
Unclassified utility purposes and ON RPC launches without a profile fail before spawn.

### Executable closure and discoveries

`SandboxExecutableClosure` inspects executable regular files with descriptor and
identity checks, bounded reads, thin/universal arm64 Mach-O validation, recursive
non-system dylib/rpath resolution and supported absolute shebang chains. It never
executes an inspection utility against an unvalidated candidate. Unknown/malformed,
missing, relative or embedded loader-environment forms reject ON. Universal slices
are inspected at their actual offsets. Selected code identities are rechecked at
admission; there is no implicit retry, ambient PATH runtime substitution or OFF fallback.

`env name` shebang resolution searches only selected installation/support and system
directories; ambiguous `env -S`, assignments and multi-argument forms reject ON.
Validated script interpreter/argument chains launch explicitly. Apple Python/Swift/
xcodebuild/xcrun shims resolve to the validated selected developer executable rather
than launching hidden Xcode helpers/global cache writers. Node module entry points
receive their real bounded node_modules graph. Native Pi uses named resources rather
than arbitrary external executable-parent access. Environment DEVELOPER_DIR and
PI_PACKAGE_DIR values do not themselves grant filesystem access.

Focused failures led to concrete fixes, not broader permissions:

- Apple Python's shim attempted undeclared Xcode helper/cache operations: execute
  the validated interpreter chain directly; no global-cache/Xcode helper fallback.
- Homebrew Node dylib aliases required literal symlink objects and ancestor metadata;
  these are declared without granting broad Homebrew data access. Homebrew libcrypto
  needs only its named OpenSSL config/certificate inputs, now declared explicitly.
- A pre-existing source/target hard link bypassed a pathname-only read-only source
  rule. `SandboxInputBoundary` now rejects contradictory existing inode aliases and
  source symlinks crossing into writable targets before package execution. Metadata
  inventory is bounded at 100,000 entries per tree and fails on inspection errors.
  It is admission validation, not atomic isolation from independent authorized writers.
- Old fixtures logged outside their declared private/target contracts. They now use
  permitted fixture storage or host-owned readonly execution metadata; ON was retained.
- Kernel `/private/var` canonical paths replaced `/var` string assumptions in assertions.

### Policy refresh and rollout

`SandboxLaunchAuthority` supplies current default/persisted policy and inactive profile
roots even at standalone probe entry points. Shared settings observers stop auxiliary
processes and recheck policy/identity before accepting results. Invalid settings fail
closed. A terminated lifecycle owner refuses new utility work.

Security-relevant policy edits close admission/invalidate grants, stop/drain old
runtimes and jobs, then reconnect only previously connected/starting conversations
through coordinator barriers under freshly compiled profiles. Unconnected history
stays lazy; jobs require a fresh explicit start. Timeout-only changes do not restart
immutable profiles. A gated lifecycle test proves no new backend is created before
old drain completes and Session grants are invalidated first.

Default/missing settings were already ON after Phase 2; Phase 6 closes the remaining
purpose gates and removes preparatory/partial-coverage UI wording. Explicit persisted
OFF remains OFF and is reported as unenforced. Ask/Autonomous stays independent.
No schema reset or override of saved user choice was introduced.

### Validation performed

All executable proofs use local/synthetic fixtures; no new live credential/provider
authorization is inferred. Direct Swift commands use the full Xcode toolchain and
repository module/cache directories. Actual Seatbelt tests ran outside the outer
tool sandbox with reviewed escalation, not with Milk Sandbox disabled.

- Focused purpose/lifecycle/install/host-effect gates: **33/33 passed**,
  `/private/tmp/milk-phase6-gates.log`.
- Final focused purpose/Preview/provider/transport regressions: **19/19 passed**,
  `/private/tmp/milk-phase6-preview-final.log`; includes **14 purpose tests**.
- Final full `swift test --cache-path "$PWD/.build/cache" --disable-sandbox`:
  **299/299 passed, zero failures**, 213.168 seconds,
  `/private/tmp/milk-phase6-full-final.log`.
- `python3 -m unittest discover -s Tests/SandboxPhase1 -v`: **22/22 passed**,
  26.373 seconds, `/private/tmp/milk-phase6-phase1.log`.
- Resource/package recipe: **1/1 passed**, `/private/tmp/milk-phase6-resources.log`;
  no coding-agent runtime bundled by the actual recipe.
- `./scripts/build.sh --disable-sandbox`: **passed**,
  `/private/tmp/milk-phase6-build.log`.
- `codesign --verify --deep --strict output/Milk.app`: **passed**. Actual worker
  identifier is `dev.milk.extension-worker`; its sole entitlement is
  `com.apple.security.cs.disable-library-validation = true`, without a Milk Keychain
  identity or helper provisioning profile. This is ad-hoc hardened-runtime development
  signing, not Developer ID/notarization/provisioned Keychain acceptance.
- Packaged worker: `MILK_TEST_WORKER_PATH` selects the actual staged helper for
  `SandboxHostEffectsTests.testActualExtensionWorkerIsolationProtectedOnceSessionGitCancellationAndNativeUI`:
  **1/1 passed**, `/private/tmp/milk-phase6-packaged-worker.log`. Signed helper loading,
  real worker/child/Git isolation, Protected Once/Session, cancellation/revocation and
  trusted native UI behavior remain covered.

Purpose executable proofs include system Mach-O and universal validation; invalid
interpreter/PATH/identity rejection; real Apple Python shim and script; real installed
Homebrew Node with env shebang, module and Intl inputs while malicious ambient PATH
is ignored; real pinned Pi compatibility; private Preview HOME/profile cleanup;
package target/source policy, Project Read Only/inactive/Protected roots and inode
alias rejection; a real local clang-compiled candidate installed from a hash-pinned
tar through the actual installation manager and default compatibility probe. The
candidate verifies private state, absence of synthetic MILK/OPENAI keys, denied outside
writes and five RPC discovery reply paths. No fake compatibility result substitutes
for candidate execution.

### Main files and exit decision

New purpose/closure boundaries are `Sources/Milk/{SandboxExecutableClosure,
SandboxPurposePlan,SandboxLaunchAuthority,SandboxInputBoundary}.swift`. Wiring affects
`PiRuntimeService`, `PiLaunchContext` (the resolver), `PiUtilityProcess`, `PiCompatibilityProbe`,
`PiBackend`, `PiSandboxExecution`, `SandboxProfile`, `SandboxHostEffects`,
`SandboxExtensionExecution`, `PiInstallationManager`, `ExtensionService`, `AgentService`,
`AgentLifecycle`, `ShellState` and `SandboxSettingsView`. Focused fixtures/tests live
in `SandboxPurposeTests`, `PiInstallationTests`, `AgentLifecycleTests` and the test-only
raw RPC overload. Current README/RUNTIME, purpose/policy/host-effect, profile/Keychain,
extension/development and repository-index references are updated. Approved architecture
and L1/L2 decisions are unchanged.

The interrupted Phase 6 work was checkpointed externally as
`0eb011390f54220656749922ee6682fd0aa91298`; continuation verified that clean baseline
and preserved it. No commit, push, merge, rebase or branch change was performed by this
implementation. Final diff/status review and `git diff --check` passed; new source
and purpose-reference files were reviewed too. Branch remains `security/api-keychain`.

**Phase 6 complete. No new production-containment blocker remains. Phase 7 is ready
for separate authorization and has not begun.** The plan remains active for that work.

Remaining limitations and acceptance concerns:

- Accepted L1 deliberate detached survivors may retain inherited static filesystem
  access; no authoritative all-descendant death or revocation claim is introduced.
- Accepted L2 Pi-owned children/MCP/extensions retain the inference-key trust domain;
  separate Milk executors/workers/jobs/probes remain key-free. Real Git hooks/helpers
  remain the explicit elevated exception.
- Closure and source/target alias checks are bounded admission snapshots, not atomic
  protection against independent concurrent filesystem writers. Opaque launchers with
  unsupported shebangs or undeclared dependencies fail ON with actionable errors.
- Existing-profile-only configured-provider Preview inspection remains explicit; no
  auth/profile copy, inactive-profile exception or universal broker was introduced.
- Phase 7 still owns manual/concurrent approval UX, broader supported-host/adversarial
  acceptance, authorized live-provider acceptance, release signing/notarization and
  provisioned Data Protection Keychain persistence. None is claimed by these tests.


## Phase 7 execution record — 2026-11-02

User authorized final acceptance, smallest defect corrections and current-reference
reconciliation. Baseline remains security/api-keychain at 0eb011390f54220656749922ee6682fd0aa91298
with the Phase 6 continuation changes preserved. No history or branch mutation.
L1/L2 and the approved architecture remain settled.

### Acceptance reconciliation before broad testing

The unchecked matrix above is a coverage request, not evidence of missing production
code. Existing evidence is mapped below; fresh final execution is required before
checking an item. Details/results are maintained in `docs/SANDBOX_ACCEPTANCE.md`.

| Matrix group | Existing executable evidence to rerun / strengthen | Claim boundary |
| --- | --- | --- |
| Policy/settings | SandboxPolicyTests, SandboxSettingsTests | Canonical precedence, defaults, independent modes, durable OFF, protected restore/edit, overlap rejection. |
| Grants/lifecycle | SandboxGrantTests, AgentLifecycleTests, SandboxExecutionTests | Once/Session admission, revoke/cancel/timeout, restart/reopen/new owner, drain barriers and unrelated-process safety; detached-survivor limitation retained. |
| Profiles/credentials | SandboxPolicyTests, SandboxEnvironmentTests, SandboxProviderParityTests, PiProfileOwnershipTests, AgentProviderCredentialTests | Managed/Existing and synthetic localhost discovery/inference/key replacement/scoping; no claim of live service or provisioned securityd success. |
| Tools/purposes | SandboxExecutionTests, SandboxPiIntegrationTests, SandboxPurposeTests, Phase 1 Python | Real stock tools/children/MCP, developer tools, malformed closure/no fallback, private state, installation/package containment. |
| Approval UX | SandboxPopupTests plus focused Phase 7 concurrent-session/queue/invalidation/window-close fixture | Real anchored AppKit/SwiftUI rendering and programmatic responses, not manual human clicks. |
| Git | SandboxHostEffectsTests and GitTests plus focused remaining Git metadata/branch cases | Real local repos/remotes/hooks/editors/helpers and exact elevated operation; no real repository history mutation. |
| Native API 2 | NativeExtensionTests, NativeExtensionIntegrationTests, packaged actual-worker test | Lifecycle/integrity/nonce/files/Protected/Git/cancel/revoke/native UI; synthetic Keychain deletion contract only. |
| Preview/jobs | PreviewTests, SandboxHostEffectsTests, lifecycle suites | Trusted user versus agent origins, static/dev server/readiness/rendering/stop/restart/owner receipts; explicit jobs only. |
| Release | Existing normal/release scripts, Python packaging/signing/version/resources, strict signatures and actual packaged worker | Current host local/ad-hoc artifact acceptance; Developer ID/notarization requires external signing access. |

Host inventory: Apple Silicon arm64, macOS 26.5.2 (25F84). Initial
`security find-identity -p codesigning -v` reports **0 valid identities**.
Provisioned Data Protection Keychain and Developer ID/notarization remain NOT RUN /
external prerequisite; never forge entitlements or add weaker storage. No additional
host is established. Live provider acceptance requires an available authorized
non-admin inference credential; synthetic localhost fixtures remain independently valid.

- [x] Reconcile every unchecked matrix group with existing tests before broad execution.
- [x] Focused adversarial/concurrency acceptance and any smallest defect corrections.
- [x] Fresh full Swift and Python regressions.
- [x] Normal/release builds, artifact inspection, strict signatures and packaged worker.
- [x] Current-reference reconciliation, final evidence and truthful release gate decision.


### Phase 7 discoveries and corrected boundaries

1. Explicit Protected regular files with pre-existing hard-link aliases could be read
   under a broader grant: policy inode recognition did not make Seatbelt pathname
   exclusions cover every name. ON now rejects multi-link explicit Protected files
   before compilation. Child creation of new aliases is separately denied. No global
   hard-link inventory or atomic admission claim is added.
2. Actual release artifact inspection found private build paths in debug/OSO records
   and two #filePath strings. Release-only compiler remapping/debug stripping plus
   checkout-diagnostic cwd fallbacks remove them. The actual packager now rejects
   private checkout/home prefixes before publishing metadata and after ZIP extraction;
   a regression covers source/object-path leaks and intentional synthetic verifier values.
3. A real Xcode target build, beyond previous version output, requires native
   item-replacement directories under per-user TemporaryItems on this host even with
   private HOME/TMPDIR and project-scoped DerivedData/cache settings. The private-only
   attempt fails closed; a separate explicit sandboxFolders request with Allow Once
   enables the build while unrelated outside writes and credentials stay denied.
   This shared folder may contain other applications' temporary data: it is extra
   user-approved authority, never a new default or Milk-private cache. No command is
   automatically retried by production. The final test corrects a Foundation `/var`
   spelling assertion with the kernel resolver, without changing production policy.

The new opt-in native diagnostic exercises the real app termination delegate with a
synthetic backend and anchored request pending. Quit and window-close both cancel the
continuation, remove grants before the first backend shutdown callback, reject stale
operation identity and preserve unrelated processes/project data. Light/Dark captures
were visually inspected. The initial diagnostic used inline AppKit termination and
hung; it was corrected to the repository's existing delayed-selector pattern. That
was a fixture defect, not evidence of a production termination failure.

Earlier current-reference index wording incorrectly said enforcement remained pending;
this is corrected. Approved architecture and historical phase records stay unchanged.


### Phase 7 final validation and exit decision

**Local campaign passed; Phase 7 and the overall Sandbox project are not complete.**
The plan remains active; it is not moved/archived while required external gates are
unpassed. No further production defect is known from this campaign within the stated
finite/accepted contract. The Xcode shared TemporaryItems dependency requires the
existing explicit user approval; default filesystem authority was not widened.

Final fresh Swift: **304/304 passed**, zero failures/skips, 237.593 seconds,
`/private/tmp/milk-phase7-full-final.log`. The entire run selected the actual stripped,
ad-hoc hardened-runtime release MilkExtensionWorker; its real compiled API 2 fixture
passed. Python: **32/32** (Phase 1 22; resource 1; signing 2; release 5; versioning 2),
`/private/tmp/milk-phase7-python-final.log`. Earlier 302/303-test runs and focused
30-test correction run remain intermediate evidence, not the final count.

`./scripts/build-release.sh --disable-sandbox` passed; actual ZIP extraction/CRC,
checksum/canonical metadata, nested signatures/architectures/entitlements and private
build-path rejection passed. Artifact is Milk-0.7.0-macOS-arm64.zip, build 7,
5,668,469 bytes; SHA256 52309a710ceb743a94c78ef48e943b96c3177f1fdb9e28a0e234d53e317f7801.
Final normal `./scripts/build.sh --disable-sandbox` and strict deep verification
passed afterward. Release-helper proof preceded debug bundle replacement. Exact
commands, provenance, logs and complete Phase 7 file list are in
`docs/SANDBOX_ACCEPTANCE.md`.

Six actual release-app scenarios passed: pending Sandbox popup Quit/Light and
window-close/Dark; Preview Quit/window-close; Terminal Quit/window-close. These
exercise the actual termination delegate, plus programmatic AppKit interactions;
no manual human click acceptance is claimed. Concurrency/queued background requests,
wrong-session/stale answers, timeout/suppression expiry/Ask no timer, grant revoke,
restart/settings/jobs and real tool/Git/native/Preview routes passed in the Swift
suite. Normal host Git/Terminal/Preview behavior remains covered.

Provider evidence is actual Pi against synthetic localhost providers, including
API-key/None, selection/reasoning, scoped replacement/revocation, stale auth and
managed/Existing boundaries. No live oMLX/hosted account or real stored-credential
restart acceptance is claimed. No usable dedicated live inference credential was
established. No personal auth/profile file was changed.

External prerequisites and unpassed gates:

- `security find-identity -p codesigning -v`: **0 valid identities**; signing/profile
  environment unconfigured, standard profile directories empty. A valid signing
  identity and matching explicit Milk App ID provisioning profile are required for
  real save/read/update/existence/scoping/delete, rebuild/restart and prompt acceptance.
  The actual ad-hoc app verification correctly exits 1 with no fallback; that is not
  a persistence PASS.
- Developer ID and authorized notarization/stapling access are unavailable. Local
  signatures/ZIP integrity pass, but Gatekeeper **rejects** the ad-hoc release (exit 3).
  Distribution acceptance remains unpassed.
- Dedicated authorized non-admin live inference credentials/services are needed for
  live Local replacement/revocation/restart persistence; hosted/OAuth only for accounts
  separately authorized/available. No admin credential was used.
- Only Apple Silicon macOS **26.5.2 (25F84)** was tested, with Xcode 26.6/Swift 6.3.3.
  Additional hosts and manual human interaction remain coverage limits, not inferred
  PASS claims or reasons to redesign production.

Accepted L1/L2, elevated Git helper trust, bounded path/executable/alias snapshots,
Existing configured-provider-only Preview seam and lack of global hard-link inventory
remain explicit. No restricted entitlement, universal credential broker, VM, FSKit,
upstream Pi patch or approved architecture/UX change was introduced. Current-reference
README/runtime/policy/purpose/host-effect/profile/Keychain/extension/development/index
and the 24-file campaign inventory were reconciled; historical reports stay historical.

Final branch remains security/api-keychain at checkpoint 0eb011390f54220656749922ee6682fd0aa91298;
all prior local work is preserved. Final diff/status and whitespace review passed.
No commit, push, merge, rebase or branch change was performed.


## Approved normal login-Keychain revision — 2026-11-02

The user superseded the provisioned Data Protection Keychain decision. Change only
Milk's persistent secret backend to ordinary macOS file-based/login Keychain through
SecItem. Keep all agent/profile/provider/exact-endpoint identity, normalization,
models.json indirection, stale-auth header behavior, None/replacement/deletion,
redaction and Pi/Milk execution-domain boundaries. No plaintext fallback, auto legacy
import, shared group, credential broker or filesystem authority change.

Ad-hoc/private distribution is the supported default. Developer ID, provisioning,
notarization/stapling and additional-host/manual-human/live-account coverage are no
longer completion prerequisites by themselves. Gatekeeper/Open Anyway behavior must
be reported honestly; no quarantine or trust bypass. Optional signing support remains.

At revision entry, AgentProviderCredentials selected Data Protection and used
DP accessibility/authentication-context attributes and provisioning-only errors.
Legacy import is explicit. ScopedSecrets for trusted native UI already uses normal
SecItem; worker Mach-service/environment isolation is unchanged. New backend uses a
fresh scoped service namespace; old file-Keychain namespaces remain explicit recovery
sources and DP items are neither automatically queried nor deleted.

Noninteractive ordinary Keychain access requires a synchronous, serialized and
restored SecKeychain user-interaction scope; per-query DP/LAContext controls are not
assumed to suppress file-Keychain UI. Default item ACLs stay untouched. Explicit
Settings recovery may request ordinary macOS authorization for a rebuilt app.
Measure current-build CRUD, separate launches, same-path rebuild and changed ad-hoc
signature access using only disposable verifier identities/values; never print values.

- [x] Reverify branch/working changes and audit current backend/recovery/signing paths.
- [x] Implement ordinary SecItem backend, scoped UI behavior and focused regressions.
- [x] Build actual app; measure CRUD, launch/rebuild and default ACL behavior/cleanup.
- [x] Fresh provider/profile/domain/full Swift/Python/build/release/artifact validation.
- [x] Reconcile current design/references and final completion criteria from evidence.
- [x] Complete/move plan only if required normal-Keychain and technical gates pass.


### Normal-Keychain revision measured results before final regressions

- Focused credentials/settings/environment: 29/29 passed; expanded provider/profile/
  domain suite: 43/43 passed. Source no longer uses the DP selector, accessibility/
  LAContext attributes or provisioning-only failure. New primary service is
  dev.milk.agent-provider.login.v1; current/older scoped recovery remains explicit.
- Actual ad-hoc app: ordinary Keychain save/read/update/existence/delete and
  agent/profile/provider/endpoint isolation passed; separate app process read passed.
  Real unchanged-code rebuild kept its CDHash and noninteractive access.
- A nonce-resigned bundle changed CDHash: normal access correctly failed -25293.
  The explicit production recovery path succeeded after the user confirmed authorizing
  the native macOS dialog; a separate subsequent process read noninteractively.
  Creator restored, retained value read, deletion and missing-item check all passed.
  No ACL edited in code; no password/secret logged; SecurityAgent automation was blocked
  and no attempt was made to bypass that restriction.
- Actual packaged API 2 fixture attempted ordinary SecItem read of a real disposable
  item created by Milk. ON and OFF worker attempts both denied; the Milk creator
  still read it before verified cleanup. Environment/domain isolation remains tested
  separately. The opt-in test needs MILK_TEST_KEYCHAIN_APP and MILK_TEST_WORKER_PATH;
  ordinary source-only test runs skip this real-Keychain acceptance instead of touching
  the personal store. The authorized final run supplies both selectors.
- No fresh authorized non-admin live oMLX/hosted credential was established. Existing
  earlier sub-key evidence stays historical; no new admin-key use or legacy-user secret
  read. Fresh live acceptance remains NOT RUN, optional under this approved decision.

Final full Swift/Python, normal/release/signature/private-path validation and the plan
completion decision follow below. Default ACL prompts remain possible for future
changed signatures; no silent-across-all-updates guarantee is made.


### Final ordinary-Keychain validation and completion — 2026-11-02

**Phase 7 COMPLETE. Overall Sandbox/security project technically COMPLETE within the
approved contract and accepted limitations. No unresolved production/security blocker
was found.** Earlier DP/provisioned/notarized mandatory gates are superseded by the
explicit user decision, not falsely converted into passed old tests. Optional live
provider, Developer ID/notarization/stapling, other hosts and broad manual-human
coverage remain NOT RUN/unclaimed. The plan is moved to completed status.

Final validation after backend changes:

- Focused credentials/settings/environment **29/29**; expanded provider/profile/
  credential-domain **43/43**; actual packaged worker/store isolation **1/1** passed.
- Final full Swift **308/308**, zero failures/skips, **236.340 seconds**,
  `/private/tmp/milk-login-keychain-full.log`. MILK_TEST_KEYCHAIN_APP and
  MILK_TEST_WORKER_PATH selected the actual stripped ad-hoc release app/helper.
  This includes real disposable normal-Keychain owner-versus-worker access under
  ON and OFF, real Pi child/MCP inheritance, key-free Milk processes, provider
  selection/None/stale-auth/rotation/scoping, Git/native/Preview/lifecycle/purpose
  regressions and the accepted Xcode TemporaryItems Once dependency.
- Full Python **32/32**: preserved Phase 1 **22**, resources **1**, optional signing
  **2**, release **5**, versioning **2**; `/private/tmp/milk-login-keychain-python.log`.
- Actual normal ad-hoc app and final release app passed save/read/update/existence/
  delete plus agent/profile/provider/endpoint isolation. Separate-launch and same-code
  rebuild reuse passed; the rebuild's CDHash was unchanged. A nonce-resigned same-path
  variant changed CDHash and was denied noninteractively (-25293). The user authorized
  native macOS recovery; exact production recovery and separate-process reuse then
  passed. Creator restoration/read/delete/missing-item checks verified cleanup.
  No ACL was relaxed in code, password observed or secret printed. The measured
  native prompt was user-authorized; other Sandbox UI coverage remains automated.
- Normal build `./scripts/build.sh --disable-sandbox`, release build
  `./scripts/build-release.sh --disable-sandbox`, strict deep/nested signatures,
  arm64/hardened-runtime checks, real archive extraction/checksum/canonical metadata,
  and private-build-path/auth-file/private-key-marker/runtime exclusions passed.
  Final normal build and real CRUD were repeated after the full suite. Optional
  signing identity support remains; default storage needs no entitlement/profile.
- Release ZIP Milk-0.7.0-macOS-arm64.zip, build 7, **5,674,576 bytes**, SHA256
  **69ff3cc283b8b0ffffe78a7c7c82983468164dd311a89897f9c2bf8d53426d4c**.
  Full-suite release-helper proof preceded replacement by the final debug app.
  Gatekeeper assessment rejects the ad-hoc release (exit 3), expected for this
  optional trust path. No quarantine or Gatekeeper bypass was attempted; private
  users may choose Open Anyway themselves.

Evidence logs: `/private/tmp/milk-login-keychain-{focused,provider-domain,worker-store,
full,python,release,artifact,release-crud,build-final,crud-final,recovery-final}.log`;
`persistence.log` records rebuild/hash behavior. One early explicit-authorization
fixture timed out; its creator-identity cleanup succeeded. The later user-assisted
run proves recovery and next-process access; failures were not relabeled as passes.

Current references/API guide and approved architecture record the normal backend,
explicit older-store recovery, optional distribution, measured ACL behavior and
unchanged L1/L2/Git/snapshot/Preview limitations. The existing native ScopedSecrets
facility was audited: it already uses ordinary SecItem under its distinct extension
namespace and remains trusted-UI-only; workers have no such facade. The new real
worker/store proof covers the changed primary provider store's default ACL/service
boundary. No filesystem sandbox implementation or upstream Pi change was made.

Fresh live oMLX/hosted-account acceptance is NOT RUN: no already available authorized
non-admin inference credential was established; the earlier one-off sub-key was
already deleted. No admin key or unrelated credential was read/modified. Existing
synthetic providers and historical live evidence are clearly distinguished. One
Apple Silicon host/macOS 26.5.2 (25F84), Xcode 26.6, Swift 6.3.3 was tested.

All pre-existing local work remains preserved on security/api-keychain at checkpoint
0eb011390f54220656749922ee6682fd0aa91298. No commit, push, merge, rebase or branch change.
Final source/diff/status/whitespace and current-reference link checks passed.
