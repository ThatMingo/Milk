# Native chat quality — Phase 2

Work continues on `fix/chat-rendering-stability`, retaining all uncommitted Phase 1
work. A 21-file Phase 1 snapshot and SHA-256 manifest are retained locally under
`output/chat-phase2/phase1-baseline/`. No push, merge or deletion work is authorized.

## Audit setup and evidence

The running product is a real AppKit/SwiftUI Milk window, real pinned Pi 1.4.0,
a loopback provider fixture, an ephemeral workspace and Pi directory, and a separate
UserDefaults suite. The audit copy uses bundle ID `dev.milk.chat-audit` to distinguish
it from an already-running production Milk. The first capture selected that other
window due to the shared original bundle ID; it was rejected/deleted and no controls
were used there. All accepted captures target the disposable audit app.

The Product Design audit skill informed screenshot-led inspection. Screenshots are
actual current-run Computer Use captures, saved and inspected locally. No comparator
UI was copied. All evidence below is generated local output, not a repository asset.

| Step | Native observation | Classification / outcome |
| --- | --- | --- |
| 1. Empty / Send | Empty state, composer focus, Send and startup state inspected. A short answer appears once with selectable prose, code and a link. Enter inserts a newline per the existing composer contract. | Working; no composer redesign. |
| 2. Short answer | Header, user alignment, code surface and final spacing remain stable. | Working. |
| 3. Thinking / output | Existing collapsed Thinking control keeps visible order with output. While running, AX exposes the disclosure as a busy indicator rather than an actionable button. | Accessibility/native interaction issue. The spinner's semantics must not replace the button. |
| 4. Long Markdown stream | A 160-section, approximately 72 KB response grows continuously at coalesced cadence. Partial inline delimiters can briefly remain literal until closed. | No transcript disappearance; incomplete inline styling is minor presentation scope, not a reason to rewrite Markdown. |
| 5. Reading / width change | Reading around Step 156, then narrowing 1060 → 760 pt, returned the viewport to the first prompt (scroll bar at zero). | Confirmed scroll/input and layout stability issue; a raw offset is insufficient through native lazy reflow. |
| 6. Native saved history | Real RPC resume of 800 turns / 1,600 messages remains ordered, but pauses the main run loop during transport processing. | Confirmed performance issue; measured and sampled below. |
| 7. Disclosure lifecycle | Source and native controls show that a running disclosure can be expanded, but completion resets explicit choices. Thinking and tool groups both have unconditional completion resets. | Interaction / abrupt layout issue; preserve explicit user choice while retaining collapsed-completed defaults for untouched controls. |

Accepted baseline screenshots:

- `output/chat-phase2/audit/01-empty-before.jpg`
- `output/chat-phase2/audit/02-short-before.jpg`
- `output/chat-phase2/audit/03-thinking-before.jpg`
- `output/chat-phase2/audit/04-stream-before.jpg` (pending Send state)
- `output/chat-phase2/audit/05-markdown-live-before.jpg`
- `output/chat-phase2/audit/06-narrow-reading-before.jpg`
- `output/chat-phase2/audit/07-large-history-before.jpg`
- `output/chat-phase2/audit/08-thinking-expanded-before.jpg` (previous completed section expanded; current live disclosure exposed as a busy indicator)
- `output/chat-phase2/audit/09-live-thinking-control-before.jpg` (completed-state comparison)

## Before measurements

Debug development build, same host/fixtures for comparisons. Timings are elapsed
operation durations, not FPS. Main-loop timer lateness is an interaction diagnostic,
not a rendered-frame counter. Accessibility scraping, sampling and fixture preparation
can themselves add work, so the isolated history comparison excludes UI scraping.

| Operation | Baseline |
| --- | ---: |
| Whole Markdown parse, 12,132 bytes | mean 0.372 ms |
| Whole Markdown parse, 48,612 bytes | mean 1.338 ms |
| Whole Markdown parse, 146,315 bytes | mean 4.019 ms |
| Projection update, 50 turns | mean 0.164 ms |
| Projection update, 300 turns | mean 0.937 ms |
| Projection update, 800 turns | mean 2.501 ms |
| Reconciliation, 800 turns | mean 3.871 ms |
| Isolated real history RPC JSON decode, 1,600 messages | 63.059 ms on main |
| Same history display reconstruction | 13.181 ms on main |
| Same history main-loop worst lateness | 618.324 ms |

`profile-baseline-profile.json` and `result-history-isolated-measured-before.json`
under `output/chat-phase2/` contain the raw measurements. The live Markdown run at
18.6 KB measured parse p95 0.627 ms; across its later 72 KB growth parse max was
2.381 ms. Unchanged native text updates were not the dominant work. Generic ShellState
still invalidates at the coalesced cadence; no model/provider/command rediscovery
was found on that path. These measurements do not justify an unrelated observation
rewrite or replacing the Markdown renderer.

A five-second `sample` of the disposable app during a repeat history load attributed
505 main-thread samples to RPC framing and 58 to JSON decoding. The framer searches
from the beginning of the unfinished record on each pipe read; fragmented large
history responses therefore incur repeated prefix scans. Sampling evidence:
`output/chat-phase2/baseline-main-sample.txt`.

## Confirmed fixes

1. **Performance — fragmented large history responses.** The LF framer scanned the
   whole unfinished prefix on each read. It now scans new bytes once and compacts
   the buffer once per batch. Framing and JSON decoding use the existing stdout
   reader queue. Main-actor request correlation, ordered domain events, generation
   guards, failure handling and state mutation stay on main. This introduces no
   additional worker/actor or async reconciliation barrier.
2. **Scroll/input — resize lost the reading area.** Remember visible logical targets
   within Markdown/thinking/activity, freeze the last settled target through width
   reflow, and materialize its owning response before restoring its inner target.
   Window, sidebar and coding-pane width changes use the same path. Per-pixel
   geometry remains in local reference storage, without application publication.
3. **Scroll/input — long-session return landed in another turn.** Lazy estimated
   heights could resolve a saved pixel dozens of turns away. Keep precise same-width
   restoration when it reaches the correct owning turn; use the logical fallback
   otherwise. Teardown callbacks no longer erase the last valid target. A user-gesture
   generation invalidates deferred restore/resize work even when the gesture ends
   before a layout wait completes; deferred work cannot later reclaim the viewport.
   The gesture also releases the programmatic ScrollPosition target. Ordinary
   same-width pixel restoration retains Phase 1's untyped point initializer so
   native gestures can take ownership and resume size-change following.
4. **Scroll/input — early follow.** The previous 80-point threshold could pull the
   reader across the last lines. Re-arm within 2 points of the tail. Stream growth
   retains native size-change anchoring without per-token scrolling. A one-shot
   return-to-tail experiment was rejected: the native regression check exposed a
   16-point gap after subsequent growth. The original native follow mechanism is
   preserved. Extreme synthetic wheel deltas can need continued gesture input as
   native lazy height estimates resolve; they are not treated as physical momentum
   input or a reason to force the viewport on each update.
5. **Thinking/activity interaction — completion reset explicit choices.** Remove
   completion resets. Untouched thinking stays collapsed; untouched activity retains
   its running-open/completed-collapsed default. Explicit choices persist for the
   lifetime of the mounted response. Session-return disclosure preferences are not
   newly persisted.
6. **Accessibility/native behavior — running disclosure lost button semantics.**
   Hide decorative spinner semantics and expose the containing disclosure as a
   button with an explicit label, expansion value and running/completed state.
   Native AX inspection and clicks verify it remains actionable while running.

## Streaming, Markdown and layout

The 33 ms coalescing cadence, 500 ms recovery checkpoints, projection cache and
unchanged-piece equality are retained. Short responses and 160-section continuous
Markdown streams remain one assistant turn. No duplicated prompt, disappearing
composer or blank transient transcript was observed in the exercised flows.

Whole-block Markdown parsing remains. Representative live parse durations are
sub-millisecond to a few milliseconds; the baseline 146 KB synthetic parse averaged
4.019 ms. An isolated sampled run had one 34 ms parse outlier under host scheduling
pressure; its p95 was 2.180 ms. That does not justify a concurrency-heavy parser
replacement. Incomplete Markdown delimiters can briefly display literally before
closing; existing styling/semantics are preserved.

Profiling a long single response also exposed native layout/focus traversal over
hundreds of Markdown children (`after-stream-main-sample.txt`). Several local
experiments were rejected after measurement and native inspection:

- Direct nested lazy Markdown layout lowered timer lateness (391.734 → 29.604 ms
  worst observed) but broke deep resize restoration.
- Grouped nested lazy layout still had inaccurate cold/remount behavior.
- Equatable eager groups retained geometry but did not consistently improve overall
  timing: worst observed 95.739 ms, p95 53.168 ms versus the initial AX-enabled eager
  run's 391.734 ms / 46.051 ms. Different run scheduling/sample windows mean the
  lower maximum alone is insufficient to accept the extra structure.

All three experiments were removed. The final renderer preserves the original
per-piece equality and eager geometry inside the existing lazy transcript. It
adds only the logical reading-target metadata and diagnostic hooks. A fresh
non-inspected process measurement is recorded below to distinguish normal streaming
from the AX/focus traversal seen after native automation attaches.

Read/write/bash operations, repeated tools and two thinking sections retain their
order and ownership. Running activity can be explicitly collapsed/reopened;
reopened activity remains expanded on completion. Changed-file cards use the same
width/padding as existing cards. No color, branding, typography, separator or card
redesign was made. A fixture notice/compaction message and restart/error card were
inspected for wrapping and alignment; this is geometry coverage, not a claim of a
live model-triggered compaction test.

## Before/after performance

The isolated 800-turn/1,600-message real Pi history load gives this comparison:

| Operation | Before | After |
| --- | ---: | ---: |
| JSON decode, largest record | 63.059 ms main | 61.160 ms reader queue |
| Framing, all 94 pipe reads | repeated-prefix scan; 505 sampled main frames | 0.386 ms total reader queue |
| Main delivery, max batch | included decoding/framing | 0.078 ms |
| Display history reconstruction | 13.181 ms main | 12.879 ms main |
| Reconciliation, max | 4.226 ms main | 3.686 ms main |
| Projection, max | 2.882 ms | 2.611 ms |
| Main-loop worst lateness, isolated load | 618.324 ms | 108.227 ms |
| Shell generic invalidations during load | 29 | 30 |

The reconstruction/reconciliation algorithms have not been moved off-main: their
measured one-time cost did not justify a new startup concurrency barrier. The
remaining 108 ms load delay includes layout and is a limitation, not a zero-stall
claim. Counts alone are not treated as proof of cost. Measured RSS differed between
runs retaining different histories, so no memory reduction or leak-free claim is
made from that uncontrolled comparison. Large histories stayed usable; arbitrary
multi-hour memory retention was not tested.

Raw comparison: `output/chat-phase2/result-history-isolated-measured-{before,after}.json`.
The mixed scroll/resize/AX-scraping stream measured parse p95 1.926 ms, max 2.525 ms,
projection p95 0.064 ms, native text update max 0.103 ms, and 361 conversation
publications for roughly 2,250 transport records. Shell invalidations were 376.
Its main-loop max 2.058 s includes intrusive AX scraping/large scroll/reflow and
must not be presented as isolated streaming latency or FPS.

## Native verification and evidence

All captures are from disposable native windows. Real Pi and loopback fixtures
exercise short output, multiple thinking sections, read/bash/write, repeated tool
IDs, changed files, a continuous ~70 KB stream, real saved 800-turn history, and
session switching. Computer Use mouse/wheel/keyboard actions complement the
AppKit developer-driver checks. Physical trackpad momentum was not available;
wheel/scroll gestures and native deceleration policy were checked without claiming
hardware-specific trackpad coverage.

Accepted follow-up captures (locally saved JPEGs under `output/chat-phase2/audit/`):

| Evidence | Check and outcome |
| --- | --- |
| `10-reading-wide-after.jpg`, `11-reading-narrow-after.jpg` | Initial same-response reflow check; prompted further long-session return testing. |
| `12-sidebar-reflow-after.jpg` | Sidebar toggle; same general reading area. |
| `13-thinking-choice-completed-after.jpg` | Explicitly opened live Thinking remains expanded with final output. |
| `14-grouped-tools-after.jpg` | Two thinking sections, read then bash, final output; no ownership/alignment change. |
| `15-final-reading-before-return.jpg`, `16-final-reading-return.jpg`, `17-final-reading-narrow.jpg` | Intermediate test exposed lazy long-session offset/reflow mismatch; superseded by captures 21/22 after correction. |
| `18-live-thinking-button-after.jpg` | Live AX button label/value and native click verified. |
| `19-write-changed-file-after.jpg` | Real Pi write and changed-file card, output/code/link alignment. |
| `20-code-selection-after.jpg` | Native mouse-selected code; exact ⌘C comparison passed. |
| `21-verified-narrow-reading.jpg`, `22-verified-cross-width-return.jpg` | Final logical owner retained through narrowing and return at another width; same response ID before/after. |
| `23-tool-expansion-complete.jpg` | Explicit Activity expansion retained after bash completion. |
| `24-stream-resize-reading.jpg` | Reads Step 51/52 while output grows elsewhere, after width change; same Markdown target retained as characters grew 30,148 → 58,149. |
| `25-notice-error-geometry.jpg` | Compaction-style notice and error/restart fixture layout. |

Exact copying of `let milk = true` and a selected assistant word `Fixture` passed
via native ⌘C and equality-only clipboard checks; no clipboard contents were logged.
AX selected-range automation is unsupported for SwiftUI Text, so those checks use
actual mouse selection. Full paragraph drag attempts were imprecise, and are not
reported as exact-copy passes. Additional selection/keyboard scroll checks and their coverage limits are recorded
in the final native results below.

## Final native and measurement results

The fresh final renderer process, before enabling Computer Use/AX inspection,
streamed the same 160 sections / 69,828 characters. It measured:

| Operation | Final fresh-process stream |
| --- | ---: |
| Main-loop worst lateness | 59.600 ms |
| Main-loop p95 lateness | 30.633 ms |
| Whole Markdown parse p95 / max | 2.356 / 2.546 ms |
| Conversation publications | 501 |

Raw data: `output/chat-phase2/result-uninspected-complete.json`. Sampling and AX
inspection can materially change native focus/layout work. The AX-enabled eager
stress run's 391.734 ms worst delay remains an explicit limitation; no claim of
perfect VoiceOver performance for enormous single responses is made. The final
parser/layout was kept because the tested alternatives added correctness risk or
failed to show consistent benefit. This does not erase measured native framework
work or imply arbitrary long responses have constant cost.

Final native verification: **12/12 assertions passed in each of three consecutive
runs** (`native-final-checks-1.txt`, `-2.txt`, `-3.txt` under `output/chat-phase2/`).
This includes real Pi thinking/read/bash, reused tool IDs, atomic resume/identity,
upward reading during generation, exact same-width return offset, resumed following
with a zero bottom gap, switching while running and process cleanup.

Final native interaction evidence:

- `30-final-wide-reading.jpg` → `31-final-narrow-reading.jpg`: a ~97 KB single
  response stays at Step 156 after narrowing; saved logical ID
  `quality-long-answer-text-markdown-930` is unchanged.
- `32-final-cross-width-return.jpg`: return at another width remains nearby
  (Step 154–156), rather than resetting to the start. This illustrates the stated
  logical-area guarantee and its pixel/line limitations.
- `33-final-keyboard-selection.jpg`: native Page Up moves offset 43,019 → 42,416.
  A selected assistant word still copies exactly after an unrelated footer update
  (`result-final-preserved-selection-end.json`, `lastCopyMatched: true`).
- Composer input/Send, focus and Stop/Queue were inspected in the short/live flows;
  no composer behavior was changed. AX disclosures remain actionable buttons.
- Final build, strict deep code-sign verification and `git diff --check` passed.
  All disposable native processes exited and their temporary state was cleaned.

The screenshot gallery is `output/chat-phase2/audit/index.html`. Captures 26–29
show rejected experiments; they do not represent the final renderer. Capture 31
was replaced with the actual settled final reading check after navigating into
history; an earlier cold-fixture-at-top capture was not accepted as resize proof.

## Exact source/file inventory

Phase 2 modifies these files on top of the Phase 1 snapshot:

| File | Phase 2 purpose |
| --- | --- |
| `Sources/Milk/PiRuntimeService.swift` | Linear LF framing and ordered background JSON batches; runtime installation/resolution untouched. |
| `Sources/Milk/ChatPanel.swift` | Logical reading targets/restoration, return-to-tail action, disclosure choices/AX labels, diagnostic hooks; Markdown geometry retained. |
| `Sources/Milk/ChatFollowTail.swift` | Actual-bottom threshold and local reading/resize bookkeeping. |
| `Sources/Milk/ChatReadingPosition.swift` | New local SwiftUI logical-target modifier/environment. |
| `Sources/Milk/AgentService.swift` | Optional Codable saved width/anchor-owner fields only. |
| `Sources/Milk/AgentHistory.swift` | Retain valid nested reading IDs during atomic reconciliation; timing hook. |
| `Sources/Milk/ChatRenderMetrics.swift` | New bounded, lock-protected, opt-in developer diagnostics; no normal-mode clock reads/sample retention. |
| `Sources/Milk/ChatQualityVerification.swift` | New opt-in disposable native audit, deterministic history/Markdown fixtures, measurement/copy driver. |
| `Sources/Milk/ChatStabilityVerification.swift` | Route explicit quality flag into the shared disposable setup/cleanup; original assertions retained. |
| `Sources/Milk/MilkApp.swift` | Explicit quality-verification entry flag. |
| `Sources/Milk/AgentTranscript.swift` | Projection timing hook only. |
| `Sources/Milk/PiBackend.swift` | History reconstruction timing hook only. |
| `Sources/Milk/SelectableContent.swift` | Native text-update timing hook only. |
| `Sources/Milk/ShellState.swift` | Opt-in generic agent invalidation count only. |
| `Tests/Fixtures/local_provider_fixture.py` | Continuous long Markdown/thinking audit fixtures. |
| `Tests/MilkWorkspaceTests/ChatQualityTests.swift` | Five concrete framer/decoder/reading/follow regressions. |
| `Tests/MilkWorkspaceTests/ChatStabilityTests.swift` | Keep prior follow regression, update its near-tail expectation to actual-tail semantics. |
| `docs/CHAT_QUALITY_PHASE_2.md` | This report. |

These existing Phase 1 files are byte-for-byte unchanged from the saved baseline:

- `Sources/Milk/AgentModels.swift`
- `Sources/Milk/AgentStreamBuffer.swift`
- `Sources/Milk/PiMessageDecoder.swift`
- `Tests/Fixtures/pi_parity_peer.py`
- `Tests/MilkWorkspaceTests/PiIntegrationTests.swift`
- `Tests/MilkWorkspaceTests/PiParityTests.swift`
- `Tests/MilkWorkspaceTests/PiProviderConsistencyTests.swift`
- `Tests/MilkWorkspaceTests/PiProviderRoutingTests.swift`
- `docs/CHAT_STABILITY_AUDIT.md`

The 27 paths above are the complete combined Phase 1/2 working-tree change list.
Generated app copies, screenshots, profiles and logs stay in ignored `output/`.
`output/chat-phase2/file-inventory.json` identifies Phase 2 versus retained Phase 1
files. The baseline manifest and `phase2-only.diff` help review the uncommitted work.

## Focused tests

75 targeted tests passed: the 69-test chat/runtime/lifecycle/slash/provider regression
selection and the six session-migration tests. After final scroll/layout changes,
the 27 chat presentation/stability/quality tests passed again (`final-chat-tests.log`). No new broad suite or
visual-judgment assertion set was manufactured. The five new tests cover:

- One-megabyte RPC line fragmented into 113-byte reads: each byte scanned once.
- Ordered worker decoding, split multibyte Unicode/U+2028, and valid records retained
  before malformed input in both fragmented and same-read batches.
- Finished/unfinished 32 MiB record-size bounds.
- Numeric logical reading order, freezing a target through reflow, and gesture-generation invalidation after a short gesture ends.
- Approaching the bottom without premature follow/snap, then resuming at the tail.

Logs: `output/chat-phase2/final-tests.log`, `migration-tests.log`, and final chat
rerun log. The regression tests retain atomic restoration, source identity,
repeated tool ownership, coalescing/checkpoints, cancellation/stale events,
partial recovery, slash separation and process cleanup.

## Limits and deferred design

- Very large history first layout still has measurable one-time main-thread cost;
  no FPS or zero-stall guarantee is made. A 70 KB single Markdown answer has native
  layout/focus cost even though parsing is cheap; AX-enabled stress timing is worse
  than the fresh-process run. This is explicitly retained as a performance limit,
  not relabeled as a visual redesign opportunity.
- Reflow restores a logical block/owning response and may align to its beginning;
  exact pixel preservation across width changes is not promised.
- Explicit disclosure choices survive the mounted response's lifecycle, not app
  relaunch or remount; untouched controls keep their intended default behavior.
- Incomplete Markdown may briefly show literal delimiters. Arbitrarily malformed
  Markdown and all third-party model-specific output patterns are not exhaustively
  covered by the fixture pass.
- This is a focused AX/native sanity pass, not a full VoiceOver navigation audit or
  physical trackpad/device compatibility certification.
- Typography hierarchy, content density, tool-detail discoverability, richer
  code-copy affordances, long-answer navigation and richer completed-turn hierarchy
  are potential dedicated design work. None was redesigned in this phase.

## Requested report coverage

| Item | Result |
| --- | --- |
| 1. Native audit findings | Screenshot-led baseline and follow-up tables above classify performance, scroll/input, layout and native interaction issues. |
| 2. Confirmed fixes | Six fix groups above; rejected experiments are separately identified. |
| 3. Streaming presentation | One growing turn, retained 33 ms cadence; Send/thinking/tools/output and read-above behavior exercised. |
| 4. Markdown | Timed whole parsing; no parser rewrite, retained equality/geometry after rejecting risky/unsupported experiments. |
| 5. Large transcripts | Real 800-turn history; linear framing/background decode, ordered main-actor delivery. |
| 6. Scroll/resize | Logical targets, long-return fallback, gesture cancellation/release, actual-bottom re-arm threshold. |
| 7. Thinking/tools | Explicit disclosure choice retained, actionable AX buttons while spinning, repeated-tool ownership unchanged. |
| 8. Main thread/observation | Before/after operation timings and update counts, measured residual native layout/focus costs. |
| 9. Small visual corrections | Interaction/semantic corrections only; no color, typography, spacing or card redesign. |
| 10. Exact files | Complete 27-path combined Phase 1/2 inventory with Phase 2 purposes above. |
| 11. Focused tests | 75 targeted regressions and final 27-test chat rerun; five new concrete tests. |
| 12. Native verification | Disposable real-Pi runs, Computer Use captures and final repeated native check results. |
| 13. Remaining limits | Large-load/AX stress timings, logical rather than pixel-perfect reflow, physical trackpad/full VoiceOver not certified. |
| 14. Deferred design | Hierarchy/density/navigation/code-copy affordances, deliberately separate from measured performance limits. |
| 15. Session deletion | Untouched. |
| 16. Provider/profile architecture | Untouched; fixture-only response additions. |
| 17. Push/merge | None; HEAD/main unchanged and changes uncommitted. |

## Scope confirmation

Session deletion semantics are untouched. Provider/profile architecture, Local
provider behavior, authentication, model/context behavior, Pi installation, Git and
editor implementations are untouched. Existing provider-related test changes are
retained Phase 1 work; Phase 2 changes only its loopback test fixture responses.
No new agent was added. No Phase 1 state mechanism was replaced: atomic restoration,
deterministic reconciliation, coalescing, ownership, stale guards, partial recovery,
bounded checkpoints, slash separation and local follow state remain.

The existing branch is `fix/chat-rendering-stability`; local `main` and branch HEAD
remain `24e3d5b24711a00fb3ca0f7601e40cc43b63621f`. Nothing was committed, pushed or
merged. Work stops at Phase 2.
