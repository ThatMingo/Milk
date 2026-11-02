# Agent-triggered host effects

Phase 5 implements these boundaries without changing trusted user Terminal, Editor,
GitService, native extension UI/services or user-started Preview. This supplements
[Sandbox policy](SANDBOX_POLICY.md) and the approved architecture; Phase 6 purpose
closure, install coverage and rollout remain separate work.

## Controlled real Git

`SandboxGitRepository` captures the current associated worktree root, `.git` file or
directory, resolved gitdir, `commondir` and linked-worktree common metadata. It also
inventories global/worktree/repository config, recursively bounded includes and
configured hooks/attributes/excludes control paths. Ordinary runtime/executor/worker
profiles deny arbitrary writes to `.git` and these resolved controls, even under a
broad filesystem grant. New/unknown repositories are not silently adopted for escalation.

`SandboxGitCommand` recognizes a subcommand plus an explicit per-command option
allowlist. Current families: status/diff/log/show/rev-parse; add/restore/rm;
commit/amend (`-m` or configured editor); cached hunk staging/unstaging via `apply
--cached ... -` with a bounded structured patch on stdin (no external patch path); checkout/switch (including new branches);
branch list/create/delete/rename; merge/reset; fetch/pull/push by configured remote
name/refspec. Literal relative paths reject `..`, `.git`, absolute paths and Git magic.
Flags requiring a value are separately validated. Global `-c`, `-C`, executable/helper
flags, aliases, arbitrary remote URLs, shell wrappers and compound shell text are
rejected. Unsupported forms receive an actionable error, never unrestricted retry.
This is argv admission to real Git, not a replacement Git implementation.

The host validates filesystem snapshots/configuration digest, applies current policy
and grants to repository/control/explicit paths and stronger overlapping worktree
roots, then uses sandboxed real Git to confirm root/gitdir/common-dir identities.
Failure never retries elevated. A successful request runs exactly `/usr/bin/git
--no-pager --literal-pathspecs <recognized argv>` outside the normal filesystem
sandbox, with host-built environment and owned process cleanup. It restores no ambient
GIT_*/shell/loader/provider variables. The host user's Git HOME and absolute SSH-agent
socket (canonical existing socket only) are compatibility inputs; configured Git hooks, credential/remote/filter/diff/
editor helpers are the explicitly accepted elevated trust exception. They may execute
arbitrary configured code; this does not grant elevation to later shell commands.
Read Only blocks mutations and keeps read operations inside their filesystem profile.

Configuration changes outside the admitted operation require reconnect. After a
legitimate operation, controls are rediscovered; changed control roots invalidate
that activation so its fixed normal profile cannot miss a new metadata root. Bare
working directories and ambiguous/unsupported control-path syntax fail escalation.
Conservative bulk-root checks can require access to a protected subtree even when a
particular Git operation would not touch it. No live remote credentials are needed
for the local acceptance fixtures. Snapshot/recheck validation is not a claim of an
atomic transaction against independent trusted user edits during launch.

## Native worker and bridge

API 2 removes agent handler closures and `piCommand`. Native user `command`, view,
layout, settings and service contracts remain. Each invocation revalidates package
fingerprint/active registry/workspace, authorizes declared files using current policy,
and starts the separately signed `MilkExtensionWorker` before any worker bundle code
loads. HOME/TMPDIR/PATH are independently constructed, with no Local/oMLX key or
ambient provider, loader, shell, proxy or Git injection state. No Milk Keychain/app
identity entitlement or app provisioning profile is copied to the helper.

`ExtensionAgentContext` contains URL values and a typed Git request function. It has
no native service facades. Direct worker subprocesses inherit its OS sandbox and
sanitized environment. Capability declarations control worker network/process support
and typed Git requests; filesystem authority is independently decided by Sandbox.
Worker-specific AppleEvent and sensitive Mach-service denials supplement the separate
signing identity. Broad service/purpose closure remains Phase 6.

The private stdio invocation is host-created, bounded newline JSON. Results/failures
and serial Git requests are the supported frames; arbitrary service or generic launch
messages fail closed. Stdout belongs to the protocol. Cancellation terminates owned
execution; stale registration/activation/grants reject later effects. Disable/integrity
and workspace/session/runtime lifecycle withdraw the catalog and cancel active worker
invocations. No Sandbox-OFF or legacy in-process fallback remains.

The Pi catalog is copied into the activation's private cache; Pi need not read the
whole extension store. It is metadata only: host registry/package checks remain
authoritative even if Pi edits its copy. Static prompt-resource lookup reads active
registry text only. Pi stock/custom/MCP unsupported model paths remain fail closed ON.
`PiBackend.handleUI` never dispatches model input to trusted native slash/service,
filesystem, processes, network, clipboard or secrets facades. Explicit Milk user
slash commands retain native dispatch; agent tool messages use worker execution.

## Explicit jobs and Preview

`AgentManagedJob` is a live host receipt with stable UUID, activation/session/project,
immutable command/directory/purpose, owner, operation/grant scope, compiled profile,
environment domain, state/output and stop/restart callbacks. `milk_job start` explicitly
registers watcher/background work; ordinary bash/Python/Node/npm completion never
adopts descendants as jobs. It returns a host ID; control requests can address only
jobs in that activation. Requests cannot choose env dictionaries, PIDs or process groups.

The independent job operation owns its temporary grants until Stop/exit. Restart
closes old admission/owned execution and creates a new operation/profile/environment
under current policy and fresh approval where needed. Output callbacks carry a
generation, so old readers cannot update a replacement process. Relevant Session
revocation, settings changes, project/session/activation/runtime shutdown close job
admission and terminate owned groups. Preview jobs are controlled by Preview, not
restarted through the generic model job tool.

Preview detector/user commands keep the existing trusted launcher and login environment.
Assisted suggestions get an in-memory host receipt bound to workspace generation,
originating session and any existing activation. Inspection remains an independent
auxiliary resource; explicit launch connects the owning session if necessary, then
starts a `.preview` job through the backend. The trusted launcher rejects agent-origin
configurations. A missing/stale receipt fails rather than falling back. No shell-string
rewriting is used: an approved command is passed unchanged to a nonlogin sandbox shell;
static agent suggestions use the same job boundary with Python's loopback HTTP server.
Agent commands/receipt capabilities are excluded from durable Preview launch memory.
External endpoint reuse never grants process ownership. Stop/workspace departure and
owner invalidation stop owned jobs and rendering.

Owned groups use the Phase 3 exclusive wait/reap identity and TERM/drain/KILL path.
The accepted L1 limitation remains: deliberately detached descendants may survive
with their inherited static profile. Job completion/expiry ends future admission;
it does not claim authoritative retroactive revocation or all-descendants-dead.
The Pi credential domain (L2) is unchanged. No ES/FSKit/VM/restricted entitlement is
introduced, and no release/notarization or default-ON rollout acceptance is implied.
