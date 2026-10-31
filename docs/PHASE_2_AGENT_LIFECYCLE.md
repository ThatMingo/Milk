# Phase 2 — agent lifecycle ownership

> Historical phase record. This document records its original scope and evidence;
> it is not the current implementation or acceptance status. See
> [Agent final acceptance](AGENT_PHASE_FINAL_ACCEPTANCE.md) and the
> [source-publication audit](PRE_GITHUB_AUDIT.md). Evidence paths under `output/`
> refer to generated local files excluded from the public source tree.

Scope: deterministic ownership and handoff around the compiled adapter boundary,
preserving the [Pi parity contract](PI_PARITY_CONTRACT.md) and
[Phase 1 boundary](PHASE_1_AGENT_BOUNDARY.md). No Phase 3+ feature is implemented.

## Architecture

`AgentService → AgentLifecycleCoordinator → activation lease → AgentOwnedResource`

Conversation resources still use
`AgentAdapter → PiAdapter → PiBackend → PiRPCClient → native Pi RPC`.

The coordinator owns a lease before scheduling its start, including pending
factory work. A lease retains activation identity, runtime purpose, writer keys,
start task, resource, exit task and lifecycle phase (starting/running/stopping/
stopped/failed). No PID, process signal or RPC assumption exists in the generic
resource contract; it requires shutdown request and confirmed asynchronous exit.

Writer identities include the agent/workspace/native session ID and canonical
native file path when known. Runtime-reported identities are added as startup
learns them. Closing work stays retained without a session file. Reopening,
restarting or deleting a matching session waits for all retained matching writers.
Unrelated active conversations do not enter that handoff barrier.

An explicit configuration/workspace drain invalidates all current leases and
sets a barrier inherited by new launches. Replacement factories run only after
predecessor cleanup succeeds. A failed exit retains its resource and writer keys;
replacement reports the failure without creating a new writer. Retry rechecks
the retained exit. Application termination closes admission before awaiting all
owned work, so late callers cannot launch a new resource after the quit snapshot.
Cancelled callers are also rejected before registration, preventing a cancelled
parent from creating a child that waits on its own parent's shutdown barrier.

## Coordinated transitions

1. Recover queued Milk instructions into the original draft and persist restart
   state before invalidating the current runtime.
2. Invalidate activation and session-action epochs; cancel that session's work.
3. Remove executable runtime dialogs and request resource shutdown immediately.
4. Await the original start task, including a start that ignores cancellation;
   request shutdown again to cover a resource created during unwinding.
5. Await confirmed shutdown. Retain failures for retry; do not bypass them.
6. Start replacement and accept events only from its valid activation.

Configuration persistence and existing UI entry points remain synchronous; the
actual backend handoff is asynchronous and serialized. Existing running-session
and approval restrictions remain. Programmatic reconfiguration can invalidate a
pending startup instead of letting it publish into the replacement. No session
schema, per-project agent selection or global session index changes occur.

## Auxiliary work and host decisions

- Preview assistance is routed through AgentService into the same coordinator.
  PiAdapter registers a separate Preview lease and awaits its exit on success,
  error and cancellation. Existing read-only/no-session flags and discovery
  helper behavior remain; user conversation history is independent.
- Existing Pi version checks and local extension-package commands use an owned
  `PiUtilityProcess`. Conversation and Preview startup pass the coordinator through
  their launch context; Settings and Pi extension management use the same owner.
  Existing version/package deadlines remain 8/20 seconds. Cancellation requests
  TERM then bounded KILL of that exact utility Process, and awaits its output/
  exit completion. No compatibility checks, installer or package feature is added.
- The PiRPCClient section is unchanged: stdin EOF, TERM at two seconds, KILL at
  five seconds, and the existing bounded wait still implement RPC cleanup.
- Runtime dialogs carry activation identity. A stale reply cannot reach a
  replacement backend or dismiss its current editor. Runtime failure invalidates
  its authority immediately. Host Preview/native-extension decisions survive a
  runtime restart/disconnect when their own session/decision remains valid;
  closing the session or workspace still cancels them. Native bridge requests
  remain subject to backend task cancellation and existing host policy.
- User-action mutations after suspension validate a task-local workspace/session
  epoch. Old submission/queue/permission completions cannot clear replacement
  drafts, notices or pending-action flags. Existing command refresh and Pi
  maintenance generation checks remain in use.

## Tests added

Seven tests in `Tests/MilkWorkspaceTests/AgentLifecycleTests.swift`:

| Test | Protection |
| --- | --- |
| Restart waits for writer | Gated exit blocks replacement factory; another conversation continues; queued draft recovers; late events are ignored. |
| Configuration during startup | A deliberately cancellation-ignoring start cannot publish ready into a new activation; replacement waits for exit and retains draft/configuration. |
| Quit with closed pending start and Preview | A session without a history path remains owned after Close; quit awaits both that start and auxiliary inspection. |
| Failed exit/retry | No replacement is constructed while shutdown is unconfirmed; retained resource can be retried. |
| Runtime versus host dialogs | Restart drops runtime authority, rejects the old reply, and preserves a valid host Preview decision. |
| Utility-process cleanup | Real isolated utility ignores TERM, is killed/awaited, and an unrelated process survives; terminated owner rejects new work. |
| Cancelled parent/child barrier | Cancelled work cannot register a child behind its own handoff barrier. |

Critical ordering tests use release gates rather than sleep-duration comparisons.
Bounded yielding observes entry/exit milestones; the real utility test exercises
the two-second escalation. Existing real Pi tests cover concurrency, ephemeral
read-only Preview, native bridge, dialogs, queues, history and process ownership.

## Verification

Verified on 2026-10-31. Generated logs live under `output/phase2/` and are not
source deliverables.

| Run | Result | Log |
| --- | --- | --- |
| Existing focused integration after initial wiring | 23 tests, 0 failures | `focused-integration.log` |
| Initial gated lifecycle tests | 5 tests, 1 fixture failure: temporary path alias did not match WorkspaceStore's canonical root | `lifecycle-fixed.log` |
| Failed quit test after fixture correction, plus utility cleanup test | 2 tests, 0 failures | `lifecycle-retry.log` |
| Final relevant Agent/Pi/lifecycle/runtime-settings/package/Preview set, including all PiParityTests | 55 tests, 0 failures | `focused-final.log` |
| Lifecycle-only check after the cancelled-parent admission guard | 7 tests, 0 failures | `lifecycle-final.log` |
| Single full XCTest pass after focused tests were clean | 126 tests, 0 failures | `full-suite.log` |
| Single fresh Agent native verifier | 24 PASS, 0 FAIL; exit 0 | `native-agent.log` |

Two earlier compile attempts ran no tests: the generic resource factory needed
an existential backend bridge (`focused-initial.log`), and new test teardown
needed explicit MainActor isolation (`lifecycle.log`). These were corrected
before execution. The path-alias failure was corrected in the test fixture;
production Preview still receives the existing canonical workspace URL.
No observed Pi parity regression remained.

Commands used Xcode, workspace-local caches and elevated execution as in prior
phases. The full suite ran once. The native verifier used the freshly built
executable with temporary runtime/integration resource symlinks, removed after
exit. Its inherited "Packaged standalone Pi" label is not packaging evidence.
Native checks were automated; screenshots were generated but no separate manual
visual review is claimed. No packaging, signing or unrelated native harness ran.
The PiJSONLFramer/PiRPCClient source section was compared with the Phase 1
snapshot and is unchanged.

## Exact source manifest

Added:

- `Sources/Milk/AgentLifecycle.swift`
- `Sources/Milk/PiUtilityProcess.swift`
- `Tests/MilkWorkspaceTests/AgentLifecycleTests.swift`
- `docs/PHASE_2_AGENT_LIFECYCLE.md`

Modified:

- `Sources/Milk/AgentAdapter.swift`
- `Sources/Milk/AgentModels.swift`
- `Sources/Milk/AgentService.swift`
- `Sources/Milk/ExtensionService.swift`
- `Sources/Milk/PiAdapter.swift`
- `Sources/Milk/PiBackend.swift`
- `Sources/Milk/PiRuntimeService.swift`
- `Sources/Milk/SettingsService.swift`
- `Sources/Milk/ShellState.swift`

MilkExtensionKit API 1, native extension host API, TypeScript integration,
packaging scripts and existing session persistence formats are unchanged.

## Deferred behavior and Phase 3 recommendation

The coordinator deliberately retains unconfirmed resources instead of assuming
they exited. Resource implementations must finish or report cleanup failure;
the coordinator cannot safely force an arbitrary future SDK to stop. Pi's
existing bounded process cleanup remains the implementation for this phase.
Existing trusted native-extension/daemon escape limits are not redesigned.

Cross-agent switching, installation ownership/records, compatibility catalogs,
downloads/updates/rollback, runtime/data relocation, Settings → Agents, session
indexing/migration, packaging/signing and other agents remain out of scope.
The external-version policy mismatch and extension package command's explicit
bundled selection also remain for their planned phases.

Phase 3 should inject resolved runtime/compatibility information into PiAdapter
and existing utility resources through this owner. Preserve writer keys, drain
barriers and failure retention; do not turn a successful version command into a
claim of integration compatibility. Continue preserving external installation
and shared Pi data ownership. No commit, push or GitHub change was made.
