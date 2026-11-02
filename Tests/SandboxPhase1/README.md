# Phase 1 executable boundary prototypes

These opt-in tests exercise actual macOS Seatbelt and the actual pinned Pi RPC
binary against disposable native code, a fake loopback model and synthetic
credentials. They are not imported by Milk, staged into Milk.app, or enabled by
SwiftPM's normal suite. They do not read personal Pi profiles or Keychain.

Run on Apple Silicon/macOS 26+ with the pinned Pi fixture already prepared:

```sh
python3 -m unittest discover -s Tests/SandboxPhase1 -v
```

The caller needs permission to run sandbox-exec and bind a loopback HTTP server;
a nested agent/tool sandbox may reject these. Such rejection is an environment
failure, never a simulated pass. Clang builds disposable C executables/dylib in
TemporaryDirectory; all Git repositories, hooks, MCP configuration and profiles
are temporary. No network requests leave loopback. No generated binaries/logs
belong in source control. This harness does not run a live oMLX model or use a
real provider key.

## What is prototyped

- `test_boundaries.py`: kernel file/descendant/symlink denials, sibling-vs-nested
  profiles, profile roots, synthetic environment, native dylib worker separation,
  exact-argv real Git escalation with hooks/editor helpers and linked worktrees,
  malformed-profile failure and a detached-child lifetime counterexample.
- `pi_bridge.ts`: Pi public read/write/edit/bash operation-interface overrides,
  sibling dispatch through RPC extension UI, discovery-tool routing prototypes,
  nested tool call, user_bash operations, cancellation, unknown-tool gate and
  direct pi.exec/custom-spawn probes. Explicitly loading builtin:mcp is necessary
  with --no-extensions; otherwise a no-spawn assertion would be vacuous.
- `test_pi_boundaries.py`: fake SSE model issues real tool calls. The test host
  launches sanitized sandbox worker siblings, propagates aborts, and approves one
  exact typed read for one tool invocation (including its access/read substeps).
  This preserves the long-running runtime PID/profile; the next read is denied.
- `operation.py`: one worker invocation; typed file/discovery operations or shell
  execution under the worker's profile. Unknown operation has no fallback.
- `probe.c` / `worker_effect.c`: native worker can load agent code without loading
  it into Milk; kernel file denial and absent credential are observable. Running
  the same library in the trusted test host demonstrates the privilege difference.
- `mcp_probe.py`: synthetic stdio server demonstrates MCP child startup inheritance
  and the fixed runtime's fail-closed fork denial.

## Scope and limits

The SBPL profiles intentionally **allow default and deny named synthetic roots**.
They prove those kernel primitives, not a production deny-default policy, complete
macOS attack surface closure, trusted IPC authentication or race-free production
path grants. The UI request dispatcher is a test harness, not a new public host
execution service. Grant identity/schema/target validation needs production work.
The C worker entry point is an architecture proof, not the redesigned shipped SDK
or its packaging/UI integration. Grep/find/ls wrappers prove routing but do not
claim full stock tool semantics, binary/image behavior, truncation or performance.

Git recognition is deliberately limited to exact /usr/bin/git argv requests for
known test verbs; it is **not** a production command parser or a restrictive Git
replacement. It does not recognize arbitrary shell syntax. Hooks/editor helpers
run elevated as approved; their effects are not normally sandbox-contained.
Broader recognition, config/path override handling and asynchronous elevated
helper ownership remain unproven. No git fetch/push occurs in these tests.

## Current L2 credential trust boundary

The approved runtime domain includes Pi, pi.exec, Pi-owned children, stdio MCP
and Pi extensions. They may inherit/access the configured non-admin Local key.
The prototype now defaults to spawning-enabled Pi. Tests verify actual pi.exec,
custom spawn and stdio MCP tool execution with synthetic key inheritance.
Historical no-fork experiments remain explicitly named as historical primitives;
they are not the proposed runtime design or a key-hiding requirement.

Milk-owned executor/native-worker environments remain independently constructed
and sanitized, including their shell/Python/Node/npm children. No MCP proxy was
built. Credentials at rest and filesystem policy are not weakened by L2.

## Temporary grants and process cleanup

The approved L1 contract separates future-operation scope from resource hygiene:
Once is removed from future admission at operation end. Session revocation likewise
stops future use and initiates cleanup. No fixed Pi profile is widened. TERM the
owned group, allow a bounded drain, KILL remaining group work and reap owned
children; clean individually known descendants/orphans best effort with safe identity.

A deliberately detached process may survive with its inherited operation profile,
including temporary folder access, until it exits. This is an explicitly accepted
limitation. It remains sandboxed; these tests do not claim retroactive permission
revocation or an all-descendants-dead guarantee. No FSKit, ES, VM, restricted
entitlement or replacement executor architecture is used.

`lifetime_probe.c` / `test_lifetime.py` retain focused regression evidence:

- Ordinary and TERM-resistant owned groups clean up with TERM/bounded-drain/KILL/
  wait; a separate unrelated process stays alive.
- Native setsid, new process groups and double-fork survivors can perform their
  delayed allowed effect after cleanup, while inherited denied-root writes fail.
  A later operation with a fresh baseline profile cannot use the old grant path.
- Python double-fork, nested shells and detached Node/npm chains reproduce the
  accepted limitation; ordinary shell/Python/Node/npm background chains clean up.
- Swift compiles/runs a synthetic program and xcodebuild -version works. This is
  toolchain startup evidence, not full arbitrary project build acceptance.
- The real-Pi test independently consumes Once for one typed tool invocation,
  denies the next read and keeps the long-running Pi PID/profile unchanged. Typed
  read is a small fixture, not a restriction of grants to typed-only operations.

Fixtures use readiness markers and bounded delayed effects, not a process-membership
oracle. Synthetic detached payloads exit after their marker. The supervisor keeps
its owned leader unreaped through final group signalling to avoid reuse. Darwin
can return EPERM for a zombie-only group; this fixture confirms owned-leader exit
with waitid(WNOWAIT) before tolerating that final KILL result, then reaps and checks
delayed effects. It does not treat arbitrary EPERM as production cleanup success.

Expected persistent dev servers/watchers are explicit managed background jobs with
policy and Preview/session/project ownership in the target design. They are not
implicitly promoted leaked tool children. Production job management, grant UI,
identity-safe orphan cleanup and authenticated IPC are later-phase work.

## Validation

Run the full focused command above on macOS 26+ with pinned Pi 1.4.0. Latest results
and historical investigation conclusions are recorded in the active ExecPlan.
The abandoned debugger/FSKit runners and isolated alternative-mechanism probes
have been removed; they are not required for this architecture.

No app build, production rollout, live keys, Keychain or personal Pi state are
involved. Evidence on the current macOS 26.5.2 host does not establish all releases.
