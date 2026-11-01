# Sandbox policy and settings (Phase 2)

Milk now has reusable policy/configuration types and a **Settings → Sandbox** page.
This is preparation for execution enforcement. The configured switch defaults ON,
but this build does **not** apply these settings to agent processes, Pi tools,
Preview, Git escalation or extension workers. The settings page states that clearly.
Ask/Autonomous behavior and the current runtime remain unchanged.

## Ownership and persistence

`SandboxSettingsStore`, owned by `SettingsService`, stores schema 1 JSON under
`Milk.sandbox.configuration.v1` in the same UserDefaults domain as other Milk
settings. It contains the global switch, timeout in seconds (default 30), global
folders, editable Protected Locations and project configurations keyed by canonical
project path. Each project defaults to Read & Write and has its own folder list.
The timeout UI supports seconds/minutes/hours; unit conversion does not change
its duration. None of these settings enter agent/provider configuration files.

Missing settings use defaults. An explicitly empty protected registry stays empty.
Unknown/malformed persisted schemas are retained without overwrite; the store
reports the problem and policy denies until an explicit settings save recovers it.
No runtime/activation/operation IDs, Once/Session grants or transient approvals are
Codable members of this schema or of workspace/chat persistence.

Initial recommendations are `~/.ssh`, `~/.gnupg`, `~/Library/Keychains`,
`~/Library/Safari`, `~/Library/Containers/com.apple.Safari`,
`~/Library/Application Support/Google/Chrome` and
`~/Library/Application Support/Firefox`. They are editable recommendations, not
an exhaustive credential inventory or hidden permanent restrictions. Restore adds
missing recommendations and preserves custom/edited entries. Custom profile paths
need explicit entries. Browser data-root references: [Chromium](https://chromium.googlesource.com/chromium/src.git/+/HEAD/docs/user_data_dir.md),
[Firefox](https://support.mozilla.org/en-US/kb/profiles-where-firefox-stores-user-data).
Apple documents the [user Keychains folder](https://support.apple.com/guide/keychain-access/copy-keychains-to-another-mac-kyca1121/mac).

## Policy contract

`SandboxPolicy.evaluate` returns `SandboxPolicyDecision` with outcome, rule, action,
subject, resolved path snapshot and boundary identifiers. Outcomes are allow, deny,
normal sandbox approval, Protected Location approval, or explicitly sandbox-disabled.
Invalid/ambiguous scopes fail closed. For valid scopes the first applicable rule is:

1. Protected Locations.
2. Inactive agent profiles.
3. Project Read Only (writes/deletes denied without a popup).
4. Explicit global/project folder grants.
5. Active profile permissions.
6. Normal project permissions.
7. Outside-project default: Autonomous reads allowed, writes/deletes require
   approval; Ask reads/writes/deletes require approval.

A read-only folder grant authorizes reads; writes/deletes require normal sandbox
approval rather than falling through to a lower-priority writable scope. Conflicting
RO/RW folder grants at the same priority fail closed instead of choosing a broader
or more-specific grant. Overlapping active/inactive or distinct inactive profiles
are ambiguous. Explicit Milk-owned writable build roots use normal purpose
permissions below stronger rules; a cache label cannot bypass Project Read Only
or protected/profile/folder restrictions. There is no Git escalation capability
in this general filesystem grant API; real Git recognition remains later work.

`SandboxScopeRoots` is supplied by trusted Milk with selected active/inactive
profiles, project and purpose-specific build roots. Managed active profiles allow
runtime/executor R/W. Existing active profiles automatically allow only the runtime;
executors/workers require permission. Inactive profiles never gain automatic access
from Autonomous or broad folder grants. The abstractions use `AgentID` and profile
ownership, without Pi paths or provider schema baked into the policy.

## Paths and admission limits

`SandboxPathResolver` walks absolute local paths with lstat/readlink semantics,
preserving symlink/.. traversal order. O_EVTONLY/NOFOLLOW descriptors, fstat and
F_GETPATH record actual filesystem path spelling and device/inode/type observations.
Nonexistent targets resolve through the last existing ancestor. Cycles, inaccessible
components, invalid traversals and ambiguous roots deny. Component boundaries avoid
prefix confusion. Explicit protected-file identities also recognize hard-linked
aliases; this is not a global inventory of every hard link into protected folders.

`SandboxResolvedPath.revalidated()` detects replacement/alias changes against its
observations. This is **not atomic authorization** or OS enforcement, and it does
not eliminate rename, hard-link, inode-reuse or check/use races. Later executors
must freshly evaluate trusted current configuration, revalidate identities at
admission and bind safe target opening and kernel policy to that execution. A
cached allow/approval decision must never become permanent authority. Filesystem
metadata access errors fail closed; no personal browser/profile contents are read
by the tests or needed to populate the recommendations.

## Temporary authority and environment domains

`AgentLifecycleCoordinator.sandboxGrants` owns a `SandboxGrantStore`. Lifecycle
begin registers a fresh `AgentActivation`; stop, failed start, stopped/failed runtime
and shutdown invalidate authority before asynchronous drain completion. Retired
activation tokens cannot be registered again. `SandboxOperationScope` adds a fresh
operation ID under the live activation; saved chat IDs confer no authority.

Once grants authorize only that operation. Finish/cancel/timeout/end removes their
future admission immediately. Session grants can authorize other operations only
under the same live activation. Explicit revoke removes them immediately; restart,
replacement and Milk quit cannot restore them. Protected approval permits Once
only. Grants bind access, subject, path/optional subtree and policy boundary IDs;
they cannot bypass a newly higher-priority rule or be applied to the fixed runtime.
Callers must re-evaluate current policy before applying a live grant. The model
tracks no process cleanup and makes no retroactive revocation claim for detached
survivors; the approved L1 limitation is unchanged.

`SandboxEnvironmentDomain` is an interface only: the agent runtime domain may
receive its configured provider credential; Milk executor/extension-worker domains
require independent sanitized environments. No environment launcher, credential
broker or change to the settled Pi credential domain is implemented here.

Execution, IPC, popup/countdown, TERM/KILL cleanup, managed jobs, real Git escalation,
worker execution and default-ON enforcement remain later phases in the
[active ExecPlan](exec-plans/active/SANDBOX_IMPLEMENTATION.md).
