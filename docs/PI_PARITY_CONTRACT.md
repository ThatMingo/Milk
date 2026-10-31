# Pi parity contract — Phase 0

> Historical phase record. This document records its original scope and evidence;
> it is not the current implementation or acceptance status. See
> [Agent final acceptance](AGENT_PHASE_FINAL_ACCEPTANCE.md) and the
> [source-publication audit](PRE_GITHUB_AUDIT.md). Evidence paths under `output/`
> refer to generated local files excluded from the public source tree.

Established: 2026-10-31. Scope: current Pi behavior and regression protection before
the Pi-first agent refactor. No production behavior or agent architecture changed.

Product target: [agent architecture](MILK_AGENT_ARCHITECTURE.md).
[Planned features](MILK_PLANNED_FEATURES.md) remain roadmap context, not scope.
The current implementation is the source of truth for existing behavior.

## Fresh verification actually performed

| Run | Result | Evidence |
| --- | --- | --- |
| Baseline full XCTest, before new tests were compiled | 113 tests, 0 failures; test execution 51.112 seconds | `output/phase0/baseline.log` |
| Focused new `PiParityTests` | 4 tests, 0 failures; test execution 4.095 seconds | `output/phase0/characterization.log` |
| Freshly built Milk executable, `--verify-agent` | 24 PASS, 0 FAIL; process exited 0 | `output/phase0/native-agent.log`, `output/verification-sessions-agent/results.txt` |

The initial default `swift test` attempt failed before running tests because its
module cache was outside the writable sandbox; compiler/SDK diagnostics followed.
Selecting Xcode and a workspace-local module cache then hit SwiftPM's nested
sandbox restriction. The successful baseline used elevated execution with:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" \
swift test --cache-path "$PWD/.build/cache"
```

The focused run used the same environment and `--filter PiParityTests`.
These are the only successful XCTest runs for Phase 0; the full suite was not
repeated after adding tests. Swift test rebuilt the application, so a separate
build was unnecessary. No packaging/signing or unrelated native harness ran.

The native verifier used `.build/debug/Milk --verify-agent`, with generated
symlinks beside the executable to the existing source-tree `Runtime/PiRuntime`
and `Runtime/MilkPiIntegration.ts`. It did not use the pre-existing app binary or
repackage an app. Its inherited check label says "Packaged standalone Pi";
this run verifies the pinned runtime with the freshly built executable, not
release packaging. Native checks were automated; screenshots were generated,
but no manual visual review is claimed. Evidence directories are generated and
ignored, not source deliverables.

## Approved architectural interpretations

The twelve amendments from the planning review are accepted for later phases:

1. One active agent means one harness; concurrent Pi sessions and explicitly
   owned Preview/inspection/probe processes remain supported.
2. Activation is lazy: session creation/selection may connect for current
   capabilities; history/settings and a workspace without Pi must remain usable.
3. Installation ownership, connection, authentication and data ownership are
   separate concepts.
4. External installations permit explicit user-requested configuration/extension
   actions. Milk never silently updates, replaces, repairs by replacement, or
   deletes externally owned installation files.
5. Preserve ordinary Pi storage/auth/extensions/configuration locations by default,
   including an explicitly supplied `PI_CODING_AGENT_DIR`.
6. Retained history needs installation-independent metadata and readable cached
   presentation; supported offline native history reading belongs to Pi.
7. Runtime rollback does not automatically reverse upstream data migrations.
8. Advertise implemented Milk capabilities separately from upstream protocol APIs.
9. Keep the adapter compiled into Milk; downloadable adapters are future work.
10. Preserve MilkExtensionKit API 1 and existing `.pi` contributions through an
    internal compatibility bridge.
11. Lifecycle ownership must include auxiliary processes, pending starts and
    closing runtimes, not just visible conversation backends.
12. Downloaded artifact execution, provenance and notices are release gates;
    removing binaries from Milk.app alone establishes neither launchability nor
    licensing clearance.

These interpretations do not implement Phase 1. Other agents, Computer Use,
orchestration, public adapter SDKs and other roadmap features remain excluded.

## Required observable parity for Phases 1+

1. **Lifecycle/readiness:** use Pi's native RPC and required Milk integration.
   A process/version response alone is insufficient. Restore native session
   identity and content before publishing ready. Preserve local startup errors
   and workspace usability after failure.
2. **Concurrent ownership:** selecting one conversation does not stop another.
   Streams, drafts, models, approvals and history stay with their originating
   session. Stop/close affects the requested owned session. Auxiliary Preview
   inspection does not replace, settle or add history to user conversations.
3. **Transcript:** preserve streamed text/thinking/tool order, authoritative end
   content, continuation grouping and saved-history equivalence. Discard redacted
   thinking and opaque signatures. `agent_settled` is completion; `agent_end`
   alone is not. Preserve existing scroll/composer behavior.
4. **Tools/activity:** retain real arguments, output/errors/cancellation/duration,
   tool linkage and bounded output/full-output references. Changed-file summaries
   retain shared ignore rules and coverage limits; they do not claim authorship.
5. **Permissions/dialogs:** Approval and Autonomous keep current semantics.
   Known read-only built-ins pass; unknown/mutating tools are gated. Denial and
   cancellation block execution; exact-input session allowances remain scoped.
   Edit Command changes actual bash input and displayed activity. Preserve
   select/confirm/input/editor, values, booleans, multiline/Unicode text,
   cancellation, dismissal and nonmodal presentation. General extension dialogs
   must not be conflated with permission decisions or native bridge requests.
6. **Models/reasoning:** discover actual models, selected model, model-specific
   effort levels/fallback and image capability. No hard-coded sample catalog.
   Keep oMLX override/telemetry and existing Keychain secret handling.
7. **Attachments:** keep project/external source URLs and submitted snapshots;
   UTF-8 context and supported image payloads use native RPC. Enforce existing
   image-capability, supported-format and size limits; reject unsupported binary
   formats explicitly. Failed submission retains the originating draft/files.
8. **Queue/steer/stop:** use native follow-up/steering queues and frozen submitted
   payloads. Preserve queue conflict checks and visible failures. Clear pending
   messages before abort; interrupted queued instructions recover into drafts.
   Nonfatal errors must not hide Stop while the run remains active.
9. **Commands:** preserve Milk/native/Pi precedence, metadata, dynamic refresh,
   whitespace, templates/skills and handled-command semantics. Unknown or invalid
   slash input never falls through to the model. Keep attachments for the next
   ordinary prompt when executing a resource command.
10. **Compaction/retries:** retain compaction-start notice, retry attempt/error
    notice and exhausted-retry error. A successful retry end is not a failure or
    completion. Do not introduce manual controls merely because RPC supports them.
11. **Sessions:** preserve close versus delete, names, resume, current-project
    validation, archived IDs/editor linkage and draft recovery. Deletion retains
    filesystem/header checks and waits until owned writers exit. New generic
    metadata must not turn a Pi session into another agent's session.
12. **Extensions:** preserve Pi resources/trust/configuration behavior, explicit
    local registration actions, source-file preservation, and required integration
    protection. Keep native tools/prompts/commands, command collision checks,
    Milk-side authorization, cancellation and dynamic contribution withdrawal.
13. **Shutdown:** preserve RPC framing/deadlines/cancellation, bounded stderr and
    exact owned-process EOF → TERM → KILL teardown. Await writers where required.
    Never kill unrelated processes by name, directory or port.
14. **External use:** preserve explicit executable selection and ordinary data
    interoperability. Installation management must respect external ownership.
    Pi installation/removal must not silently reset sessions, settings or secrets.

Bundling, global runtime configuration, Pi-specific type names and current
project-only browsing are migration targets, not permanent parity rules.
The approved architecture explicitly allows the required UI changes for Agents,
project selection, unified sessions and absent-agent recovery.

## Coverage inventory and deliberate non-duplication

Paths below are relative to the repository root.

| Behavior | Existing protection retained; no duplicate test added |
| --- | --- |
| Streaming/order/redaction/grouping | `ChatPresentationTests`, real-Pi grouped continuation in `PiIntegrationTests`, Agent native verifier |
| Tools/change summaries | `PiIntegrationTests`, `AgentTests.testChangedFilesCountsAndSharedIgnoreTraversal` |
| Approval deny/allow/session allowance/edit/autonomous | `PiIntegrationTests.testVanillaPiStreamingApprovalsQueueSteerAbortHistoryAndTelemetry`, Agent native verifier |
| Models/efforts/oMLX | Same real-Pi integration test; provider and Keychain cases in `SettingsTests` |
| UTF-8 external attachment and binary rejection | Same real-Pi integration test; draft/file preservation in `AgentServiceTests` and `SlashCommandTests` |
| Follow-up/steer/clear/abort | Same real-Pi integration test; composer routing in `SlashCommandTests` |
| Queue recovery/failed send/session isolation | `AgentServiceTests.testCloseReopenAndRelaunchPreserveSessionDraftQueueAndEditorLinkage`, `testFailedSendKeepsOriginalSessionDraftAfterTabSwitch` |
| Dynamic commands/templates/skills/stale refresh | `SlashCommandPiTests`, `SlashCommandTests` |
| History/resume/delete/editor linkage | `PiIntegrationTests`, `SessionNavigationTests`, `AgentServiceTests`, Agent native verifier |
| Native Milk bridge/API compatibility | `NativeExtensionIntegrationTests.testActualPiNativeBridgeApprovalAndDynamicWithdrawal`, `NativeExtensionTests` |
| Preview read-only and ephemeral behavior | `PiIntegrationTests.testPreviewInspectionUsesRealPiReadOnlyEphemeralAndReturnsConfiguration`, `PreviewTests` |
| RPC framing/errors/deadlines/shutdown | `AgentTests`, including graceful/TERM/KILL and unrelated-process survival; `AgentServiceTests.testTerminationWaitsForOwnedBackend` |
| Existing runtime/settings | `SettingsTests.testRuntimeValidationAndExplicitBundledRecovery`, configuration persistence; missing external launch in Agent native verifier |

New protection in `Tests/MilkWorkspaceTests/PiParityTests.swift`:

| Test | Why needed |
| --- | --- |
| `testConcurrentSessionsAndAuxiliaryPreviewRemainIndependent` | Real Pi through AgentService: two simultaneous streams, background progress, distinct histories, overlapping read-only ephemeral Preview, independent stop/close and retained history. Existing tests switched sessions but did not establish this overlap. |
| `testRealPiSelectConfirmInputAndEditorRoundTrip` | A real Pi extension exercises all four dialog methods, reply forms, metadata, Unicode/multiline text and cancelled input. Existing permission tests covered select/editor but not the full general-dialog round trip. |
| `testMissingIntegrationHandshakeFailsBeforeReadyOrHistory` | A responsive controlled external RPC peer omits the integration marker. Startup must fail before ready/history; happy-path Pi tests cannot catch removal of this guard. |
| `testExternalPeerCompactionRetryAndSettledBoundary` | Controlled peer exercises external launch plus compaction/retry normalization, ignored compatible unknown events, and non-settling agent_end. Avoids network/provider retry timing and expensive compaction generation. |

The controlled peer is `Tests/Fixtures/pi_parity_peer.py`, not an additional
agent. It verifies Milk's protocol interpretation, not upstream retry algorithms.
Real Pi tests still supply the native integration evidence.

## Known risks and limits retained for later phases

- External resolution still requires the app's Pi manifest and benefits from
  bundled tools. Extension package removal still unconditionally launches bundled
  Pi. Neither dependency belongs in the final architecture.
- Runtime Settings validates exact pinned version, while PiBackend's external
  startup checks the handshake without enforcing the same version equality.
  Centralize this policy later; the positive peer uses supported 1.4.0 and does
  not freeze acceptance of arbitrary versions into a test.
- Restart/configuration changes do not consistently await old backend exit.
  Preview discovery's defer requests shutdown without awaiting it; its process
  is not owned by AgentService's backend table. Tests explicitly await cleanup;
  they do not claim application-wide auxiliary ownership is already solved.
- Native command reservations accumulate across runtime catalogs. Later
  activation-scoped reservations must preserve collision safety.
- Pi's queue-wide clear returns text, so recovery of independently extension-owned
  image queues is limited. This phase does not invent stronger guarantees.
- Attachment coverage is partial: successful image payloads/limits and every queue
  conflict permutation are not exhaustively tested. Avoid broad test inflation;
  add focused cases when changing those specific paths in a later phase.
- Time-bounded concurrent stream tests use the deterministic loopback fixture;
  they do not measure provider performance. No live model, paid credentials or
  production user's Pi configuration is used.
- No clean-machine, downloaded-runtime, release packaging/signature, full native
  matrix or licensing acceptance is claimed by Phase 0.

## Change boundary

Source deliverables are this contract, `PiParityTests.swift`, and
`pi_parity_peer.py`. Production Swift/TypeScript checksums captured before the
baseline matched after verification. No adapter migration, Phase 1 implementation,
commit, push or GitHub action was performed.
