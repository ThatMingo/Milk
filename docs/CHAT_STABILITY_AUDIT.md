# Chat foundation / stability audit

Baseline: local `main` `24e3d5b24711a00fb3ca0f7601e40cc43b63621f` (clean).
Work branch: `fix/chat-rendering-stability`. No provider/profile or deletion changes.

## Baseline trace and behavior (before edits)

PiJSONLFramer / PiRPCClient → PiBackend / PiMessageDecoder → guarded
AgentService.receive(session:) → published conversations → ShellState forwarding →
AgentTranscript.items → ChatPanel / AgentResponseTurnView → Markdown / NSTextView.
WorkspaceStore snapshots AgentService into workspace recovery; AgentSessionIndex
stores metadata, not transcripts. Pi's shipped 1.4.0 `docs/json.md`,
`message-types.md`, `rpc-commands.md` and `session-format.md` define wire semantics.

| Scenario | Observed code path / baseline behavior |
| --- | --- |
| New session | Empty cache, native runtime starts on explicit action (or enabled direct selection), authoritative user message_start adds prompt; no optimistic duplicate. |
| Existing cache / app restore | Cache appears without starting Pi. Running activities become cancelled, but streaming messages are filtered out entirely: confirmed loss of partial recovery. |
| Native resume / reconnect | Backend requests full get_messages, emits historyBegin then individual messages/activities. Service clears both visible arrays. This exposes empty/partial states and creates unnecessary observation/persistence work. |
| Session switch | View identity is scoped to selected session. Browsing selection does not start execution. Runtime closures capture session ID plus workspace generation, activation and lease validity; background sessions correctly keep running. |
| Live response | Random UUID at message_start; updates/end use that ID in the same stream. Every text/thinking delta publishes the entire conversations dictionary. |
| Thinking + response | Indexed blocks preserve order and discard opaque/redacted thinking. Empty streaming thinking is removed by displayUnits although thinkingActive hides the header spinner: no indicator until text arrives. |
| Tool / multi-tool | Within an operation, toolCallId updates one activity and consecutive tools group across continuations. But IDs are assumed globally unique: reusing a call ID in a later message overwrites the earlier card/output. History result lookup also updates the first same-ID operation instead of its actual owner. Restored missing results become cancelled. |
| Compaction | Start notice persists forever; compaction_end ignored. get_messages is native authority; no refresh on each token. |
| Retry / error | Live failures surface; successful retry leaves old failure/notice visible. A failed assistant restored without a Milk cache loses its errorMessage. agent_end intentionally does not settle; agent_settled does. |
| Scroll up during generation | Geometry overwrites followsTail on every at-bottom transition, including content growth. scrollPosition writes scrollAnchor into published/persisted conversation state. Token changes trigger scrollTo while the top anchor independently attempts to preserve position. |
| Return near bottom | Geometry re-enables following, but only last message / last activity changes trigger scrolling; changed-file/notice growth and non-last tool updates are missed. |

## Classification / evidence

Confirmed defects:

- Visible native-history clear/replay (`PiBackend.start`, `AgentService.receive`).
- Reused raw toolCallIds across assistant messages overwrite earlier activities and
  restored results can attach to the wrong operation. A failing deterministic regression
  reproduced the lost card/output/order before the fix; the native real-Pi verifier also
  repeats the grouped fixture with distinct file contents and the same toolCallIds.
- Live UUIDs become history-N on reconnect; insertion/removal changes index IDs.
  Blocks/turn IDs and stored anchors therefore change for the same native content.
- Crash-cache restore removes partial assistant content rather than marking it stopped.
- Empty live thinking indicator is filtered out (`displayUnits`).
- Layout-only geometry changes can disable following; two scroll-position mechanisms
  compete; only last message/activity are watched, omitting other layout growth.
- Compaction completion and successful retry do not resolve stale notices/errors.
- Importing a native failed assistant without an existing Milk error drops its saved
  errorMessage, leaving only partial/empty output with no failure explanation.

Likely performance/rendering issues, with hot-path evidence (not a measured FPS claim):

- Every content delta runs conversations.didSet → persist → constructs and compares
  all metadata records via index.upsert and cancels/restarts a 500 ms workspace task.
  Index upsert avoids unchanged disk writes: per-token index *writes* are not proven.
- Continuous streaming can postpone that trailing-edge workspace checkpoint forever.
- Generic agent.objectWillChange queues ShellState.refreshSlashCommands each time.
  This merges catalogs, filters completion and can publish selectedID=nil repeatedly.
  It does not itself refresh models/providers/installations; those were not found on
  the token path. RPC command refresh occurs on explicit resources / ready / settled.
- Chat body builds/group-scans the whole transcript on each update (including draft
  and scroll changes); each assistant scans all activities. Markdown body reparses
  all text and inline spans when reevaluated; completed rows have no equality boundary.
- SelectableContent rebuilds attributed text and reapplies attributes even when
  characters and appearance are unchanged.

Harmless / working safeguards:

- Block indices and same-stream message IDs are stable; message_end is authoritative.
- Tool lifecycle and output events update an existing operation, not extra messages;
  the cross-message uniqueness assumption was the separate collision defect fixed here.
- Redacted thinking/signatures do not enter saved display content.
- No per-token row/layout animation exists in ChatPanel. Sidebar animation is keyed
  to sidebar visibility; useful application animations need not be disabled globally.
- PiRPCClient rejects old transport generations. AgentService additionally rejects
  old workspace, activation, closed-session and invalid lease callbacks. Preserve these.
- Changed-file snapshots run off-main after settlement and guard successful results
  by generation. The error callback lacked that local guard; the outer service activation/lease guard already prevented cross-session mutation. It now uses the same defensive check as successful results.

## Deletion observation (out of scope)

Deletion availability depends on the owning adapter, selected runtime ownership,
active reported history directory and absence of running/pending/dialog work.
External-Pi deletion is explicitly unverified. A retained session without its active
history directory may therefore be undeletable. The reported user's specific session
has not been inspected; no deletion semantics are changed in this phase.

## Final data / rendering flow

`get_messages` is reconstructed into one `AgentHistory` value in PiBackend. There
is no begin/clear/replay event. The service reconciles the complete native snapshot
with the cache, remaps activity ownership and native-to-local IDs, then assigns one
conversation value. The visible cache remains available during RPC startup, and a
failed startup leaves it available. Native content determines membership and order;
obsolete cached provider content is removed rather than appended or duplicated.
Milk-owned Preview activity survives the replacement.

Pi messages have a role and millisecond timestamp, but `get_messages` does not expose
the persisted JSONL entry ID. Live and restored IDs now derive from the same role /
timestamp / collision occurrence rule. Missing-timestamp fixtures have a canonical
content fingerprint fallback. An optional `sourceID` enables matching while retaining
existing view IDs; exact ordered content matches migrate legacy UUID/history-N caches.
Visible tool IDs now derive from the retained owning message ID plus Pi's raw
call ID. This separates different operations that reuse a raw ID, while lifecycle
updates still affect one row. The native history builder correlates results by ID
and owning assistant. Pi execution/approval IDs remain raw and unchanged. Legacy
raw activity references are accepted while reconciling caches. Completed message
and block identities are retained on repeat reconciliation. Live
start, deltas and authoritative end update one message. Opaque thinking/signatures
remain absent from display storage. Legacy partial content without source metadata
cannot always be matched safely to a different authoritative final message; native
replacement takes priority over guessing.

Text/thinking deltas and repeated running-tool updates accumulate in a value buffer.
Adjacent compatible deltas combine with correct replacement, completion and redaction
semantics. The display flushes at 33 ms; message/approval/tool-completion/settlement
boundaries flush immediately first. Explicit snapshots and runtime invalidation flush
accepted content too. Existing workspace/activation/lease guards remain ahead of this
buffer, and invalidation cancels pending flush tasks.

Transcript projection retains completed turns and rebuilds from the affected user
turn onward. Unlinked activity is moved with the tail on new turns, so the cache
matches the full reducer without retaining an old duplicate. Activity association is indexed once instead of scanning all activities
for each message. Equality boundaries skip unchanged user/assistant rows, Markdown
content blocks and parsed Markdown pieces. A growing Markdown block still parses
at display cadence; unchanged blocks and inline spans do not. The existing Markdown
syntax/output and visual styling are preserved. Selectable native text retains its
render inputs and avoids rebuilding attributed storage when text/font/source mode /
appearance are unchanged; appearance and enabled-state changes remain supported.

Follow-tail uses local `ScrollPosition` and native `.sizeChanges` bottom anchoring.
There are no token-triggered scrollTo calls or top-row binding written into global
state per pixel. Geometry bookkeeping stays local; only a changed follow decision
updates view state, and scroll recovery is saved at idle/disappearance. Upward user
input disables following, downward input near the bottom restores it, and idle
layout growth does neither. A native check exposed the two-callback LazyVStack case:
a content-height estimate shrinks, then the offset clamps to the new bottom. The
clamp is now distinguished from upward user intent and has a deterministic regression
test. Initial reading-position recovery initializes state before native idle callbacks
can arrive, and converts the saved padded viewport offset to content coordinates
using the existing top inset (legacy row anchors are still accepted). A native
same-width switch restores the measured offset exactly. Exact restoration across
a changed width/content reflow is not promised.

Composer refresh has a dedicated, run-loop-coalesced input signal for draft, selection,
models/efforts, commands, approvals and action state. Generic agent invalidation still
forwards UI changes but no longer rebuilds slash commands per token. No provider/model
catalog or installation discovery was found attached to generic token updates. Ready
runtime availability avoids reopening the same saved-session header from render/status
reads. Session-index updates stay on metadata changes, separate from transcript updates.
Conversation recovery uses a bounded 500 ms checkpoint instead of cancelling/restarting
a trailing timer per delta; continuous streams remain recoverable. Normal explicit
workspace/quit persistence remains in place.

Compaction end now resolves progress into success/cancel/failure notices. Successful
provider retry clears only the error captured when that retry began, preserves a newer
unrelated error, clears stale retry progress and restores the appropriate session state.
A saved final assistant provider error is carried by the atomic history snapshot
into the existing error notice even when no Milk error was cached. An empty
unredacted streaming thinking block now shows its existing thinking control /
spinner; whitespace-only completed and redacted blocks remain hidden.

## Exact files changed

| File | Change |
| --- | --- |
| `Sources/Milk/AgentHistory.swift` (new) | Complete history value, native-authoritative reconciliation, legacy identity migration, activity remapping and Preview preservation. |
| `Sources/Milk/AgentModels.swift` | Optional message source identity; scoped visible tool IDs; atomic history and retry-success events. |
| `Sources/Milk/AgentService.swift` | Atomic commit, source/local ID mapping, buffered streaming and boundary flushes, bounded recovery checkpoints, composer signals, retained interrupted content, retry resolution, ready-runtime availability fast path. |
| `Sources/Milk/AgentStreamBuffer.swift` (new) | Deterministic text/thinking/tool update coalescing. |
| `Sources/Milk/AgentTranscript.swift` | Indexed activity association, affected-turn projection cache, streaming finalization and empty-live-thinking visibility. |
| `Sources/Milk/ChatFollowTail.swift` (new) | User-input follow decisions, geometry/clamp handling and local bookkeeping. |
| `Sources/Milk/ChatPanel.swift` | Native layout anchoring/local scroll state; equality boundaries for transcript rows and Markdown pieces; preserves existing visual design. |
| `Sources/Milk/ChatStabilityVerification.swift` (new) | Opt-in native window verification with disposable Pi/workspace/defaults and loopback model fixture; no screenshots or deletion. |
| `Sources/Milk/MilkApp.swift` | Route the explicit `--verify-chat-stability` developer mode. |
| `Sources/Milk/PiBackend.swift` | Build one native history snapshot; associate repeated-ID results with their owner; retain saved failure text; compaction/retry completion; consistent snapshot-error generation guard. |
| `Sources/Milk/PiMessageDecoder.swift` | Shared deterministic live/history identity allocation and source identity. |
| `Sources/Milk/SelectableContent.swift` | Skip unchanged attributed-text reconstruction. |
| `Sources/Milk/ShellState.swift` | Move command catalog synchronization off generic agent objectWillChange. |
| `Tests/Fixtures/local_provider_fixture.py` | Long streaming Markdown fixture for native scrolling checks. |
| `Tests/Fixtures/pi_parity_peer.py` | Deterministic compaction completion/cancellation/failure events. |
| `Tests/MilkWorkspaceTests/ChatStabilityTests.swift` (new) | Focused history, identity, recovery, buffering, projection, stale-event, retry and follow/clamp regression tests. |
| `Tests/MilkWorkspaceTests/PiIntegrationTests.swift` | Consume atomic history; assert real live/restored message ID equality. |
| `Tests/MilkWorkspaceTests/PiParityTests.swift` | Handshake check consumes atomic history; compaction-end regression. |
| `Tests/MilkWorkspaceTests/PiProviderConsistencyTests.swift` | Adapt existing history assertions to the atomic history event only; no provider logic changes. |
| `Tests/MilkWorkspaceTests/PiProviderRoutingTests.swift` | Adapt existing resume assertion to atomic history only. |
| `docs/CHAT_STABILITY_AUDIT.md` (new) | This audit, implementation, verification and limitations report. |

## Verification actually performed

The complete test suite was not run. The final focused run passed **64 tests, zero
failures**, in 32.9 seconds (`output/chat-stability-final-tests.log`):

| Suite | Tests passed |
| --- | ---: |
| ChatStabilityTests | 16 |
| ChatPresentationTests | 6 |
| AgentLifecycleTests | 7 |
| AgentServiceTests | 8 |
| AgentSessionMigrationTests | 6 |
| SlashCommandTests | 9 |
| PiIntegrationTests | 2 |
| PiParityTests | 5 |
| PiProviderRoutingTests | 3 |
| PiProviderConsistencyTests | 2 |
| Total | 64 |

Command (Xcode selected, workspace-local module/cache directories):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" \
swift test --disable-sandbox --cache-path "$PWD/.build/cache" \
  --filter 'ChatStabilityTests|ChatPresentationTests|AgentServiceTests|AgentLifecycleTests|AgentSessionMigrationTests|SlashCommandTests|PiIntegrationTests|PiParityTests|PiProviderRoutingTests|PiProviderConsistencyTests'
```

`./scripts/build.sh --disable-sandbox` also passed, producing `output/Milk.app`
and passing the script's deep/strict code-sign verification. Build evidence:
`output/chat-stability-app-build.log`. `git diff --check` passed.

Both the native debug flow and the final packaged development build passed
**12/12 checks**. The packaged command was
`output/Milk.app/Contents/MacOS/Milk --verify-chat-stability`; results and measured
scroll offsets are in `output/chat-stability-native.txt` (console output in
`output/chat-stability-native.log`). The follow assertion checks that new streamed
text arrives while the actual bottom gap stays zero; an increasing numerical offset
is not required when a native lazy height estimate shrinks. Evidence files are local ignored build output, not committed source.

The first sandboxed wider run passed state/lifecycle/migration /
command cases but seven network-fixture cases could not bind loopback. Rerunning the
real-Pi subset with host access passed 9/9, including live/restored ID equality. These
were fixture-launch restrictions, not accepted failing application tests.

The new chat tests cover:

- cache visible throughout held startup and exactly one coherent history publication;
- native membership/order, repeated prompts, legacy ID migration, repeated reconciliation
  without duplicates and activity remapping;
- live/start/end/history identity equality, timestamp collisions, canonical fallback;
- sequential/coalesced delta equivalence, authoritative end and redaction;
- 500 deltas → one publication, no composer-input notification or command RPC refresh;
- pending-buffer flush into snapshots, stopped partial-content recovery, continuous
  checkpoints before streaming ends and unchanged metadata index;
- old-session routing and rejected invalidated callbacks;
- visible empty live thinking, grouping/order and existing cache compatibility;
- upward scroll hold, growth without user input, return near bottom, mixed layout/input
  and LazyVStack's separate height/offset clamp callbacks;
- affected-turn projection equality with the full reducer, including early activity
  changes, truncation and empty history;
- successful retry resolution without erasing a newer unrelated error; imported
  native error visibility; same raw toolCallId in different messages retaining both
  cards, outputs and owners through live updates and history reconciliation.

The explicit native mode launched the compiled development Milk binary with a real
AppKit/SwiftUI window, pinned upstream Pi 1.4.0 and loopback provider. It exercises
new prompt, two thinking blocks, read/bash tools, growing Markdown, native wheel-up
while generating, reading-position hold, returning to the tail, switching sessions,
returning to the original live conversation and native resume. It also switches
away/back while reading above the tail, and repeats tool IDs with distinct outputs
before restoring native history. It records native
scroll offsets and message/block IDs, checks no empty history was published, waits
for Pi processes to exit and removes all disposable state. This is an automated native
sanity check, not a claim of a human usability study or visual-polish acceptance.
No production Milk workspace/profile was opened and no screenshot was required.

## Remaining work / limits

This is the foundation/stability phase, not full chat polish. Generic ShellState UI
invalidation still occurs at the coalesced display cadence. A very large active
Markdown block still parses as a whole at that cadence, and RPC JSON/history decoding
and reconciliation still use the main actor. Huge-history performance needs profiling
before a larger observation/parser/off-main redesign. Pixel-based reading recovery
can differ after window-width changes or native-history reflow. The parser retains
its existing Markdown coverage rather than gaining tables, nested lists or other
new syntax in this phase. Mouse/trackpad momentum, resize/collapse combinations and
long sessions deserve broader human scroll-polish checks beyond the deterministic
native flow. Native identity uses ordered collision disambiguation because Pi RPC
has no session-entry IDs; pathological timestamp collisions combined with history
pruning remain a limit of that identity source.

Session deletion remains a separate known issue. The availability conditions above
were observed without identifying or changing the user's problematic session.
Provider/profile ownership, managed/existing Pi behavior, Local configuration,
model/context limits, authentication, installation architecture, Git and editor
functionality are unchanged. No other agent was added. Work stays on the requested
local branch; nothing was pushed or merged.


## Final scope / repository status

- Expected starting `main` was confirmed exactly before edits.
- Local branch: `fix/chat-rendering-stability`; edits remain uncommitted for review.
- `main` remains `24e3d5b24711a00fb3ca0f7601e40cc43b63621f`.
- 21 source/test/report files changed or added; generated development app/logs are ignored.
- Nothing pushed, merged or deployed. Provider/profile architecture and deletion
  semantics are untouched. Stop after this foundation/stability phase.
