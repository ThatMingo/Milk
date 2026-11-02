# Sandbox policy, settings and execution

Milk applies purpose-specific filesystem enforcement to current supported agent
execution when Sandbox is ON (the default). Version/compatibility checks, package
commands, installation candidates, conversation/Preview runtimes, sibling tools,
native workers and managed jobs have explicit contracts. OFF is an explicit
unenforced compatibility mode, independent of Ask/Autonomous. Final Phase 7
acceptance and release certification remain separate; see the
[acceptance report](SANDBOX_ACCEPTANCE.md) for measured scope and external gates.

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
in this general filesystem grant API; controlled real Git uses the separate validated host-effect path.

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
The kernel pathname profile cannot represent every name of a pre-existing hard-linked
Protected file. ON profile construction rejects an explicitly Protected regular file
with multiple hard links rather than exposing an alias through broader grants. Child
creation of a new link to the denied file is separately tested and blocked. This is
not an atomic link-count guarantee against independent concurrent host writers.

`SandboxResolvedPath.revalidated()` detects replacement/alias changes against its
observations. This is **not atomic authorization** or OS enforcement, and it does
not eliminate rename, hard-link, inode-reuse or check/use races. Executors
freshly evaluate trusted current configuration, revalidate identities at
admission and compile the current kernel path policy for that execution. This
path-based Seatbelt profile is not a descriptor-based race-free filesystem API. A
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

## Production execution boundary

`SandboxProfileBuilder` compiles trusted policy scopes to filesystem Seatbelt rules;
`SandboxProcess` owns `posix_spawn` children in dedicated groups with close-on-exec
file descriptors. Invalid policy/profile application fails without an unrestricted
retry. OS/developer runtime dependencies are read-only, with stronger protected and
profile roots excluded. The literal root directory read needed by macOS 26 dyld
and ancestor metadata permissions do not grant an Ask-mode outside subtree read.
Literal reads of the public `/var`, `/etc`, `/tmp` symlink objects support developer
shims; these do not authorize their destination subtrees.
Non-filesystem macOS services/network closure remains later hardening.

`PiSandboxExecution` binds each request to a live activation, fresh host operation
and random capability over the host-owned runtime RPC pipes. Pi-supplied identifiers
are correlation only. It re-evaluates policy and grant scope before launch. Read,
write, edit, bash, grep, find, ls, nested built-ins and user bash use a sibling
selected-Pi worker with stock public tool factories and only Milk's worker extension.
Bash uses the public operations hook to keep ordinary children in the owned group.
Results, images, errors and updates travel back over the same private transport.
Commands may explicitly declare `sandboxFolders`; Milk does not parse/rewrite shell
strings or automatically rerun a denied command. Undeclared outside access receives
the kernel decision. Unknown model/custom/MCP tools reject while ON. Native agent
effects use the separate extension worker route; legacy native bridge effects reject. Direct `pi.exec` and Pi extension children
remain in the fixed baseline sandbox; they receive no temporary sibling grant.

`SandboxApprovalCenter` presents requests through the existing composer child panel.
Ask has Once/Session/Deny without a countdown; Autonomous has the configured deadline
and timeout-deny. Protected requests offer Once/Settings/Deny, never Session. Settings
closes that request without granting access. Only identical immediate timeout retries
are suppressed with the approved unavailable-user message; no retry interval is
exposed to the model. Ordinary editing approvals remain separate.

Operations close future grant admission first, then TERM the owned group, drain
briefly, KILL and reap. `waitid(WNOWAIT)` retains the leader identity until final
signalling/reap, avoiding stale PID/group reuse. Session revoke cancels affected active
workers; policy changes close the runtime. Deliberately detached descendants can
survive with their inherited profile; no all-descendants-dead or retroactive
revocation guarantee is claimed. New operations cannot reuse an expired Once grant.

Milk workers receive independently constructed HOME/TMPDIR/profile/PATH environments
without Local/oMLX credentials. The Pi runtime and Pi-owned subprocesses/extensions
retain their approved inference-key domain. Version probes on backend resolution use
a separate private workspace/cache/profile purpose contract. Compatibility,
package and installation candidate children have separate contracts too. Preview inspection uses a private ephemeral profile,
project read-only rules and read tools; agent-suggested server startup retains a live host origin receipt and runs as an
explicit sandbox-managed job. Existing-profile-only configured
provider/auth discovery in the empty inspection profile still needs provider-parity
integration; Local inspection is covered. Trusted user-started Preview is
unchanged.

Git metadata writes are denied in ordinary profiles. Controlled real-Git escalation,
Native extension workers and explicit managed jobs are described in
[host-effect boundaries](SANDBOX_HOST_EFFECTS.md). The complete executable inventory
is in [purpose contracts](SANDBOX_PURPOSES.md); final acceptance remains in the
[completed implementation record](exec-plans/completed/SANDBOX_IMPLEMENTATION.md).

## Phase 4 environment admission

The shared `SandboxEnvironment` worker constructor accepts only host work, selected
support paths and typed toolchain state. Pi-specific provider/profile interpretation
lives in `PiEnvironment`, not generic Milk core. Workers receive no ambient provider,
proxy, SSH-agent, shell startup, dynamic-loader or Git configuration variables. Their
private HOME/TMPDIR/profile and fixed tool PATH are independent of the parent Pi
credential dictionary. A request containing an env/environment object fails closed.

The Pi runtime retains the documented provider environment contract and explicit
selected-profile authentication references. Its user-profile configuration is trusted
runtime configuration; project-controlled metadata and descriptions never select
extra host credentials. Reserved Milk authority/credential names cannot be imported
through references. Local Keychain injection happens after this filtering. Version/
compatibility helpers use a different, credential-free purpose projection and separate
explicit probe inputs. PATH entries must be absolute/nonempty; unsupported startup
and Git overrides are stripped. Invalid HOME/TMPDIR or unrepresentable support paths
fail instead of changing runtime/profile ownership. Configuration admission uses a
bounded regular-file descriptor/identity check; FIFOs/devices, malformed JSON and
oversized declarations do not trigger inherited-environment fallback.

The provider contract's known variables and API/header/MCP interpolation fields are
preserved, including proxy/CA settings in Pi. Opaque ambient extension-specific inputs
are not broadly inherited; use supported selected-profile configuration or explicit
adapter-owned runtime inputs. Worker proxy/auth/SDK startup state is not borrowed
from Pi. DEVELOPER_DIR is a separately validated host toolchain input. Other ambient
build configuration can be supplied explicitly by the development command within its
existing filesystem permissions. No read/write permission is added by an env value.

Runtime diagnostics redact known Local/environment credentials; this cannot prevent
Pi-owned trusted code from explicitly disclosing its credential. Native profile auth
and OAuth remain Pi-owned. The API-key/no-auth, discovery/inference/model/thinking,
replacement/revocation, stale-auth and scope contracts are exercised with synthetic
localhost providers, not a new credential broker or weaker storage.


## Phase 5 host effects

A native bridge message is a request, never authority. Active registration/package,
workspace, activation and operation are checked by Milk, including after awaits.
No generic privileged file/process/network/clipboard/secret service is available to
agent workers. User-only native UI/services/slash dispatch keep trusted contexts.
Static prompt resources are registry text, not code or arbitrary host file reads.

Git elevation is scoped to one exact recognized argv request against the captured
repository. Bulk operations check stronger roots overlapping the worktree; canonical
explicit paths and metadata/config controls receive policy checks too. Unsupported
argv/config forms, changed identity or failed sandboxed real-Git preflight fail closed.
FS approvals disclose the real-Git hooks/helpers trust exception. A required Sandbox
approval covers the displayed action; otherwise Ask uses one ordinary action approval.
Autonomous skips ordinary approval, never Protected/Read Only/inactive policy.

Managed jobs use a separate host operation scope. Once lasts for the explicit job
until Stop/owned cleanup; completing an ordinary shell operation never adopts a PID
as a daemon. Session revoke cancels jobs whose compiled profile used that grant.
Restart keeps job identity but closes the old operation and obtains fresh policy/
permissions/profile/environment. Future admission closes before owned cleanup, with
no claim that deliberate detached survivors lose inherited static access.

The filesystem compiler admits the `/dev/null` device required by Git's read/write
null descriptor only when its classification is ordinary outside-project dependency.
An explicitly stronger root still wins. No writable `/dev` subtree was added.


## All-purpose closure and default ON

Every current agent-related execution is classified by the caller. Missing RPC
profiles while ON, unclassified utility execution, missing interpreters and malformed
or unresolved closure fail before an unrestricted child can start. No automatic OFF,
runtime substitution or denied-command retry is used. Supported shebangs and Apple
shims launch the same validated script/interpreter chain explicitly; a probe never
searches ambient PATH. Helpers have private HOME/TMP/cache/profile state and no
provider credential. Selected runtime/module roots and named configuration inputs
are explicit read-only dependencies, with literal alias metadata where required.
An environment path value by itself grants no filesystem access.

Purpose ceilings intersect normal policy, including persistent grants and stronger
nested roots. Probes/candidates can write only their private storage; package CLI can
also write its explicit selected profile, and can only read the input source. Source
and writable-target inode/symlink contradictions reject before execution; alias
inventory is bounded at 100,000 entries per tree. Input inspection is admission
validation, not an atomic filesystem transaction against independent concurrent
writers. No new process-lifetime guarantee is claimed.

Security-relevant settings invalidate grants and stop/drain old owned processes.
Previously connected conversations reconnect with new authority after the coordinator
barrier. Jobs need fresh explicit starts. Timeout-only changes leave immutable
profiles running. Default/missing configuration is ON; an existing explicit persisted
OFF stays OFF. Corrupt/unsupported settings fail closed instead of selecting OFF.
Runtime status labels distinguish ON and OFF (unenforced). No schema reset or user
choice overwrite is part of rollout. See [purpose contracts](SANDBOX_PURPOSES.md).


Real Xcode builds can require the macOS per-user `TemporaryItems` item-replacement
folder even with private TMPDIR and project-scoped DerivedData/cache flags. Milk does
not admit that shared folder automatically: a command may explicitly request it
through the normal temporary folder approval flow. The acceptance build verifies
that an Allow Once grant enables the build while unrelated outside writes remain
denied and the grant expires for future admission. The folder can contain other
applications' temporary data, so this is extra reviewed authority, not private cache
redirection. Private-TMP-only Xcode builds are not claimed; Swift compilation with
private module caches is independently covered. See [acceptance](SANDBOX_ACCEPTANCE.md).


Milk's persistent provider store is now ordinary macOS login/file-based Keychain via
SecItem, not provisioned Data Protection Keychain. Private/ad-hoc builds need no Apple
membership/profile. This backend change adds no filesystem/environment permission:
Pi keeps the approved key domain; separate Milk executors/jobs/probes/workers remain
key-free. Default ACLs, scoped identity, noninteractive normal access, explicit native
recovery and no plaintext fallback are documented in [API Keychain](API_KEYCHAIN.md).
Optional Developer ID/notarization and unperformed live/multi-host/manual coverage
are limitations, not by themselves Sandbox technical-completion gates.
