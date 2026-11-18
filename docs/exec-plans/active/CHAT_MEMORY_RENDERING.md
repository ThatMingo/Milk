# ExecPlan — Native chat memory, scrolling and rendering stability

Status: active. Branch at start: `qwen-auto-update` at `f03fcb5`.

## 1. Goal

Fix the native chat transcript growth reported after long PI coding sessions:

- process memory growing from ~56 MB to ~1.4 GB while a session renders;
- the viewport repeatedly pulled to an arbitrary document position;
- text disappearing and large blank areas, especially with expanded Thinking while streaming.

Priority order for this plan: memory correctness and stable scrolling first, rendering
correctness second, performance third.

## 2. Scope

`ChatTranscriptRows.swift`, `NativeChatTranscript.swift`, `ChatFollowTail.swift`,
`ChatPanel.swift`, `SelectableContent.swift`, `AgentTranscript.swift` (projection reset),
`ChatRenderMetrics.swift` / `ChatQualityVerification.swift` (verification diagnostics),
`Tests/MilkWorkspaceTests/Chat*`.

Out of scope: the streaming model, projection semantics, tool-call/activity rendering,
session history/recovery, PI integration, the SwiftUI visual pieces, replacing the
renderer, and wholesale cache removal.

## 3. Established state (measured, before any fix)

Scratch native probes (temporary `ChatProbeTests.swift`, real production rows/views,
700×600 viewport; since consolidated into `ChatMemoryTests.swift`):

| Probe | Result |
| --- | --- |
| 400 streaming text flushes, one response growing to 195,200 characters | Markdown height cache held **3,408 entries / 84,759,910 cached characters** at peak (≈400× the response itself); in-process RSS grew from 83 → 368 MB; heights cache stayed at 2 entries |
| 400 streaming Thinking flushes | shared Markdown cache unused (0 entries); heights 2; **2 rows re-measured every frame** (response header + collapsed Thinking row) |
| Expanded Thinking while following the tail | offset moved **8078 → 11119** (absolute document bottom) on the disclosure click; `followsTail` stayed true; the clicked control left the viewport |
| Wheel up, then collapse | offset 9519 → 6478, i.e. the anchor row was preserved exactly (document shrank by 3041) — already correct |
| Expanded Thinking streamed to 38,042 points | measured height and mounted host frame matched at every frame (worst trailing blank 27 pt) |
| Actual pixels of a 22,842-point Thinking row | painted from 4 pt to 22,841 pt of a 22,842 pt frame — no truncated/blank tail at that size |
| `SelectableContent` measurement vs native `usedRect` | text ending in a newline measures one line-height taller (3842 vs 3823) because `boundingRect` counts the trailing empty line fragment; otherwise measurement is within the 4 pt padding |

Root causes established:

1. **`ChatTranscriptSession.sharedMarkdownHeights` retains streaming prefixes.**
   The inner dictionary is keyed by the whole `AgentMarkdownBlock` value, an entry is
   written on every measurement, and only width *buckets* are ever pruned
   (`> 3` widths). Every intermediate prefix of a live response is retained for the
   lifetime of the render session. This is the dominant memory growth.
2. **`ChatTranscriptStore` never releases a render session.** Evicted sessions keep
   `AgentTranscriptProjection`'s private copy of every message and activity, and
   sessions that were closed are never removed at all.
3. **Bottom follow treats any geometry change as tail movement.**
   `update()` uses `follow.followsTail → target = maximumOffset`, so a disclosure
   toggle (or any non-streaming layout change) jumps the reader to the absolute
   document bottom instead of preserving the reading position.
4. Verification mode has no rendered-content blank diagnostic: the only blank check is
   "some mounted host intersects the viewport" plus document-vs-host *frame*
   comparison, so a blank band inside a mounted piece is invisible to the verifiers.

## 4. Invariants that must survive

- Upstream Pi, stream coalescing, projection identities, tool activity and session
  history are unchanged.
- Exact per-piece document geometry, bounded native hosting and stable reading anchors
  (Phase 5) are preserved; the renderer is not replaced.
- Height caches keep their purpose: scrolling offscreen does not invalidate them,
  session return does not re-measure, identical settled Markdown still shares
  measurements, disclosure choices survive geometry eviction.
- Cache bounds must be explicit and testable; no invariant is weakened to pass a test.

## 5. Work items

- [x] A. Reproduce and quantify memory, scroll and render behaviour with probes.
- [x] B. Bound the shared Markdown height cache: `ChatMarkdownHeightCache` caps entries
      (64), retained UTF-8 bytes (256 KiB), and widths (3), evicting oldest first; oversized
      pieces are measured on demand; `ChatTranscriptRow.Content.markdown` now carries
      `streaming:` and only settled pieces are cached.
- [x] C. Release render-session state: `AgentTranscriptProjection.reset()` drops its
      transcript copy, `releaseGeometry()` clears heights + cache + cached rows, and
      `ChatTranscriptStore.retain(open:)` forgets sessions the workspace no longer opens.
- [x] D. `disclosureRevision` separates user disclosure changes from tail movement, so a
      disclosure toggle keeps the reader's anchor and re-adopts the tail only if the kept
      position still is the bottom.
- [x] E. `Coordinator.visibleCoverageAudit()` reports `unmountedGap` (a layout-placed piece
      inside the viewport that is not mounted), `clippedPoints` and `trailingBlank` from
      actual TextKit layout, emitted as `document.blank.band`, `document.text.clipped` and
      `document.text.blank`; `scripts/verify-chat-geometry.py` asserts all three plus a new
      expand/collapse disclosure scenario driven by `ChatScrollAudit.disclose`.
- [x] F. Regression tests in `Tests/MilkWorkspaceTests/ChatMemoryTests.swift` (11 tests):
      bounded streaming caches, cache eviction/oversize rules, geometry release with
      disclosure retention, closed-session eviction, both disclosure reading-position
      cases, tail-growth pinning, trailing-newline measurement, audit sensitivity.
- [x] G. Re-ran Chat suites (47 tests, 0 failures) and the full suite, and built the app.
- [ ] H. Native acceptance (`--verify-chat-quality` + `scripts/verify-chat-geometry.py`) on
      the disposable audit bundle — attempted this turn, blocked (see §7).
- [x] I. Current-reference documentation added: `docs/CHAT_TRANSCRIPT_RENDERING.md`
      (render-session ownership, bounded caches, tail/disclosure scrolling, diagnostics),
      linked from the `docs/README.md` current references. Phase reports are left as
      historical evidence.
- [x] J. Measurement now uses the renderer: `SelectableContent.sizeThatFits` asks the text
      view's `NSLayoutManager` for `usedRect` at the proposed width instead of measuring the
      string with `boundingRect(...)+4`, and `SelectableContent.visibleText` trims trailing
      newlines from the value the text view holds, so display and reservation are the same value.
- [x] K. Live-resize reflow in `NativeChatTranscript.Coordinator`: `activeContentWidth` is the
      width the layout, the measurements and the mounted pieces agree on; a width change arms a
      reflow commit instead of remeasuring per notification, and mounted pieces are never given
      a new width while keeping a height measured at the old one.
- [x] L. Regression tests for both: `ChatTextMeasurementTests` (reserved height versus laid-out
      height across a corpus, blank-line policy) and `ChatResizeTests` (drag while streaming,
      commit when the pane settles, a parked reader survives the reflow).
- [x] M. Temporary drift probes in `Tests/MilkWorkspaceTests/ChatDriftProbeTests.swift`
      (measurement corpus, scroll-state matrix, settled-height stability, live-resize window,
      width oscillation). Diagnostics, not regression tests.
- [x] N. Wheel/keyboard intent for tail following (§6 Turn 3): `TranscriptScrollView` reports the
      upward distance a real event asked for, `ChatFollowTailState` releases the tail from that
      cumulative request, and a layout commit keeps the reader's position while a request is
      outstanding. Regression tests in `Tests/MilkWorkspaceTests/ChatWheelTests.swift` (5),
      temporary reproduction in `ChatWheelProbeTests.swift` (4).

## 6. Validation (as executed)

- Focused: `ChatGeometryTests`, `ChatQualityTests`, `ChatStabilityTests`,
  `ChatPresentationTests`, new `ChatMemoryTests` → 47 tests, 0 failures.
- Full `swift test`: 338 tests, 1 skipped, 38 failures (29 unexpected) in 179 s. Every
  failing name is Pi/installation/provider/network/sandbox/extension-worker; no Chat suite
  appears. Three names absent from an earlier run (`NativeExtensionTests`
  `testNamespacedSecretsUseOnlyExtensionService` and
  `testRemoveDataClearsSecretsWithOrWithoutMarkerAndWithoutEntries`,
  `PiAutoUpdateTests testConcurrentChecksReturnTheFreshResultNotTheStaleCache`) pass in
  isolation and are load-sensitive, not regressions.
- Pre-change baseline on this host: 327 tests, 1 skipped, 35 failures.
- `./scripts/build.sh` → `Build complete!`, packaged bundle signed.
- Native verification: **not executed** — see §7. Nothing in this plan is claimed on the
  strength of the audit driver; its assertions are ready for the next host that can start
  a disposable Pi runtime.

### Turn 2 — measurement and live resize

Toolchain note, corrected during this turn: the SwiftPM failures earlier in this turn were a
toolchain-selection problem, not a repository defect. Run tests with the Xcode toolchain
exported, as `docs/DEVELOPMENT.md` says:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift test --cache-path "$PWD/.build/cache"
./scripts/build.sh
```

Without `DEVELOPER_DIR`, `swift test` picks `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`,
has no `XCTest` module (`error: no such module 'XCTest'`), and its scratch writes land where
this agent's file sandbox refuses them (`You don't have permission to save the file
"output-file-map.json" in the folder "MilkExtensionHost.build"`). With it, build and tests run
normally.

Fallback used while that was unclear: a direct XCTest driver under `.build/manual/` — the real
SwiftPM compile commands from `.build/arm64-apple-macosx/debug/description.json`, `Milk.o` and
`MilkWorkspaceTests.o` compiled with `@"quoted source list"` files (the repository path contains
a space), macros loaded with
`-load-plugin-library .../swift/host/plugins/libSwiftMacros.dylib` because `swift-plugin-server`
returns a malformed response for `SwiftMacros.TaskLocalMacro`, then `main.swift` plus a generated
static `TestClassNames` list linked against `-framework XCTest` with rpaths for the Xcode
developer frameworks. Runtime `objc_copyClassList` enumeration must not be used: it aborts on
AppKit classes that do not implement `methodSignatureForSelector:`. Tests in that driver that
write to `NSTemporaryDirectory` fail with permission errors the SwiftPM run does not hit, so its
results are only trustworthy for suites that touch no temp files.

Executed on this host:

- `ChatTextMeasurementTests` 2/2, `ChatResizeTests` 3/3, `ChatGeometryTests` 5/5,
  `ChatMemoryTests` 11/11, `ChatPresentationTests` 6/6, `ChatQualityTests` 7/7,
  `ChatStabilityTests` 16/16, `AgentServiceTests` 8/8, `ChatDriftProbeTests` 8/8 — 0 failures.
- `./scripts/build.sh` → `Build complete!`, `output/Milk.app` (adhoc + runtime hardened,
  `codesign --verify --deep --strict` clean), launched for visual checking. The installed
  Milk app was not replaced.
- Full `swift test`: 353 tests, 1 skipped, 5 failures (3 unexpected) in 310 s —
  `AgentTests testOwnedRPCShutdownGracefulTERMAndKILL` and
  `PiInstallationTests testProbeCancellationAwaitsExitAndRemovesItsIsolatedDirectory` /
  `testProbeRejectsVersionOnlyMissingMarkerMalformedRepliesAndUntestedVersion`. All are
  runtime/installation/probe paths, no Chat suite appears.
- Control run with the previous `boundingRect(...)+4` formula restored: `ChatTextMeasurementTests`
  reports 10 corpus mismatches (table in §7). These tests fail on the old code and pass on the
  new one, so they are not self-fulfilling.

### Turn 3 — the wheel that would not leave the bottom

Reported symptom: near the bottom of a growing transcript, the mouse wheel does nothing; several
notches are needed to "unstick" it, and short upward flicks snap back.

Reproduced with genuine AppKit wheel events in line units (`ChatWheelProbeTests`, temporary
diagnostic) against a streaming Thinking block, one notch every 0.15 s:

```text
notch 1  offset 297 (delta -10) max 307 followsTail 1
   after commit: offset 326 max 326      <- the notch was undone, reader dragged 29pt down
notch 2  offset 326 (delta 0)   max 326  <- nothing left to move: the pin already moved them
notch 3  offset 316 (delta -10) max 345
   after commit: offset 364 max 364
```

Mechanism, two parts that compounded:

1. A tail pin moves the offset *without* the reader, and it ran on every streaming commit, so it
   erased each notch (10 points at the default `verticalLineScroll`) and moved the reader down by
   the amount the new row added.
2. `ChatFollowTailState` decided intent from *observed* movement. A pin is also observed movement,
   and the exit rule additionally required `distanceFromBottom >= 48`. Because the pin kept putting
   the reader at the new bottom, the distance condition was almost never true when the accumulated
   travel crossed 48, so release was postponed until a notch happened to land far enough from the
   bottom — the "several notches to unstick" behaviour.

Fix (`Sources/Milk/ChatFollowTail.swift`, `Sources/Milk/NativeChatTranscript.swift`):

- `TranscriptScrollView.scrollWheel` reports the signed upward distance the event *asked* for,
  before any clamp, through `Coordinator.travel` → `ChatFollowTailState.noteRequest`. Cumulative
  requested upward distance ≥ `exitDistance` releases the tail; a downward event gives the request
  back. Keyboard Home/Page Up/End are accounted the same way.
- Release no longer depends on the distance from the bottom at the moment the threshold lands.
- While an upward request is unanswered and within `Coordinator.travelHoldWindow` (0.6 s) of the
  last event, `update()` keeps the reader's anchored position (`layout.offset(id:fraction:)` plus
  the within-piece delta) instead of pinning the new maximum offset.
- A commit calls `follow.rebaseline(metrics)` rather than disguising itself as a scroll event with
  `userScrolling = false` around `update(metrics)`.

Hysteresis deliberately survives: a single 10 point jog keeps `followsTail`, and once the request
expires the next commit pins the tail again (`testAbandonedJogIsAbsorbedByTheTail`).

Executed on this host:

- `ChatWheelTests` 5/5, `ChatWheelProbeTests` 4/4, and the Chat suites together with
  `AgentServiceTests`: 71 tests, 0 failures.
- Full `swift test`: 362 tests, 1 skipped, 7 failures (5 unexpected) — `AgentLifecycleTests`,
  `NativeExtensionTests` (Keychain -60006), `PiInstallationTests` (probe), `SandboxPurposeTests`
  (`SandboxPathError`). Re-running `NativeExtensionTests` and `SandboxPurposeTests` alone: 30 tests,
  0 failures, so those are host/environment flake under full-suite load. `AgentLifecycleTests
  testUtilityProcessQuitWaitsForOwnedChildAndLeavesUnrelatedProcessAlive` fails repeatably
  ("Missing executable launch plan"). No Chat suite fails.
- Control: with the pin-suppression line restored to `if follow.followsTail && !disclosure`, and
  again with `noteRequest` made a no-op, `testWheelNotchesAreNotUndoneByIncomingOutput` fails at
  every notch ("a layout commit dragged the reader back to the tail"). The test encodes the bug,
  not the fix.

### Turn 4 — native acceptance run, and the clipped-text class it found

The outstanding native acceptance run was executed with the current local implementation and
the disposable pinned runtime (Pi 1.4.0, `Runtime/PiRuntime`):

```sh
./scripts/build.sh
output/Milk.app/Contents/MacOS/Milk --verify-chat-quality &   # disposable audit bundle
python3 scripts/verify-chat-geometry.py
```

What the run found, in order, with the mechanism each time:

1. `document.text.clipped` on a user bubble (reserved 37 pt, laid out 38 pt) and on a code
   block (text view 696 pt wide, `NSTextContainer` 447 pt). `SelectableContent` held
   `widthTracksTextView = false` and set `containerSize` only inside `sizeThatFits`; SwiftUI
   proposes several widths (including tiny negotiation probes) before placing the view, and
   the container stayed at a probe width narrower than the mounted view. Text wrapped
   narrower than the row it was measured at. Fix: `widthTracksTextView = true` — the
   container always follows the view's real frame; measurement still pins `containerSize`
   explicitly at the proposal width. Regression: `SelectableContentWidthTests`.
2. The failing row was identified only after the audit snapshot gained `renderedRows` — the
   row IDs behind the worst hole/clip/blank band. Id-length metadata alone was not enough.
3. `document.text.blank` fired on the response **header** row mid-stream (1318 pt band). The
   audit was measuring pieces of the active streamed response while the session was busy:
   a mid-commit tail is a gap by definition. Fix: the audit skips pieces of
   `activeResponse` while `busy || pending`, and skips live markdown pieces. False positive,
   not a layout defect.
4. The disclosure phase asserted content taller than the viewport, but a single fixture turn
   (~570 pt) is shorter than the 623 pt viewport. Harness fix: the disclosure case seeds 20
   varied turns — seeded history carries real restored thinking blocks, which is exactly what
   the disclosure scenario toggles — and does not prompt a live fixture turn into a synthetic
   seeded history (the loopback fixture server stalls on a grouped turn inside reconstructed
   history).

Final executed result (clean binary, fresh app instance):

- `scripts/verify-chat-geometry.py` → **PASS** end to end: mixed conversation (grouped tool
  turns, streamed `chat-scroll-fixture`), hysteresis bursts, seeds 80/300/800 with per-notch
  wheel integrity, session switching, resize/appearance/copy phases, disclosure
  expand/collapse/repeat. `document.blank.band`, `document.text.clipped`, `document.text.blank`
  zero throughout; Markdown cache inside budget; 800-turn seed ~0.59 s, ~167 MiB RSS (limit
  600 MiB), main-loop delay under limit.
- `swift test --filter Chat`: 82 tests, 0 failures.
- Full `swift test`: 378 tests, 1 skipped, 2 failures — both pre-existing
  `PiInstallationTests` assertions from the uncommitted auto-update work, unrelated to chat.
- `./scripts/build.sh` → `Build complete!`.

Also noted while diagnosing: Swift `print` from the verification app is invisible unless
`setbuf(stdout, nil)` runs first (the process lives longer than the pipe buffer); the
verification driver now does that at startup.

## 7. Findings during implementation

- Streaming prefixes are useless cache keys: the next delta changes the key, so the
  cache costs a full-string hash plus retention and never hits.
- The measured-vs-rendered probes did **not** reproduce a large blank area: mounted
  piece frames track native text layout within one line. Blank-area reports therefore
  needed a real rendered-content signal before any geometry change was attempted.
- `NSHostingController.fittingSize`/`intrinsicContentSize` are unusable here for
  mounted hosts (`0` / `-1` in every probe): the coordinator assigns frames explicitly
  and SwiftUI lays out to the proposed size. Coverage and TextKit extents are the
  signals that work.
- `NSTextView` is always flipped but its SwiftUI superview chain is not, so the painted
  extent must be converted from the text view itself to the document, not relative to
  its immediate parent. Comparing against the parent silently produced a 3055 pt false
  "blank band" for a fully rendered Thinking block.
- A trailing newline measured through `sizeThatFits` reserved an extra empty line
  fragment that paints nothing. `SelectableContent` now sizes without trailing
  newlines, and the audit ignores `extraLineFragmentRect` so an empty final line is
  neither a blank band nor clipping.
- The suspected `boundingRect`-versus-`NSTextView` mismatch is real, and bounded. A control
  run with the previous formula restored, measured against the text view the same content
  installs:

  | piece | reserved (old) | laid out | delta |
  | --- | --- | --- | --- |
  | one line | 21 | 17 | +4 slack |
  | wrapped paragraph | 189 | 185 | +4 slack |
  | ends with one blank line | 21 | 42 | **21 under** |
  | ends with two blank lines | 21 | 63 | **42 under** |
  | thinking block ending blank | 266 | 304 | **38 under** |
  | newline only | 18 | 21 | 3 under |

  The old measurement over-reserved a flat 4 points on ordinary rows and under-reserved any
  piece whose text ends in a blank line. After the change the same corpus reserves the laid-out
  height exactly at both 624 pt and 420 pt (`under = 0` everywhere; empty and newline-only
  pieces reserve 1 instead of 18).
- The mismatch is not the whole story by itself. With the measurement fixed and the resize
  behaviour untouched, the probe matrix still showed a live drag breaking rendering:
  `[continuous resize, wide shrink] clip 399.0 staleWidthFrames 100` — 100 consecutive frames
  with mounted text rewrapped at a width its retained measured height did not fit. The
  scroll-state scenarios (tail following, user scroll-up, disclosure toggle, viewport change,
  settled-row stability) showed no drift at all: `worstAnchorDrift 0`, `worstOffsetDrift 0`,
  `originDrift 0`, 65 settled rows with only the streaming row changing per frame. Intermittent
  drift reports therefore point at resize/remeasure timing as much as measurement.
- After the reflow change the same probes report `clip 0.0 blank 0.0 hole 0.0
  staleWidthFrames 0` in every scenario including continuous resize and a wide shrink, and the
  oscillating-width probe keeps streaming (`measuredPerFrame 2`, `worstClip 0`).
- `ChatFollowTailState` needs a previous metrics snapshot to latch a user scroll: the first
  update after a fixture is built has none, so one synthetic jump does not release the tail. A
  real wheel gesture is a run of scroll events after the transcript has already committed
  geometry, so this is a fixture artifact; the resize test warms up tail following before
  parking a reader.
- Synthetic scroll tests must run the real `TranscriptScrollView` callbacks and spin the run
  loop until the deferred `input(false)` lands, otherwise the coordinator never observes the
  completed gesture and `followsTail` reports a state the reader never had.
- Closing the fixture `NSWindow` in `tearDown` segfaults the test process: the scroll view is
  still holding coordinator views. Releasing the reference is enough.
- `ChatRenderMetrics.aggregate` returns only peaks, so the audit reports its three
  channels as maxima; per-scenario zero-checks live in the geometry driver instead.
- Native acceptance is blocked on this host, and the cause is not Chat. Launching the
  rebuilt audit bundle fails closed in Milk's sandbox path resolution before Pi reaches
  `.ready`:

  ```sh
  ./scripts/build.sh
  open -n -g --stdout /tmp/a1.log --stderr /tmp/a2.log output/MilkChatAudit.app \
    --args --verify-chat-quality     # and the same when exec-ing Contents/MacOS/Milk
  # FAIL The operation couldn't be completed. (Milk.SandboxPathError error 1.)
  # PASS All disposable Pi processes exited
  ```

  `SandboxPathError.inaccessible` is thrown by `SandboxPathResolver`/`SandboxInputBoundary`
  when an `lstat`/`open` of a path in the launch or input-boundary closure fails; the
  disposable loopback model fixture itself is reachable (HTTP 200 on 127.0.0.1 in the
  unified log), so this is the enforcement layer, not the fixture. The same error appears
  on stashed baseline code (`SettingsTests testCanonicalLocalPiInstallDisableUninstallPreservesSource`),
  and `AgentLifecycleTests testSandboxPolicyChangeDrainsThenRelaunchesWhileTimeoutKeepsRuntime`
  fails with "This approval is stale or outside its permitted scope" there too. Diagnosing
  or fixing sandbox provisioning is a separate, security-sensitive task; no Chat invariant
  was weakened to work around it, and no native acceptance result is claimed here.
  `scripts/verify-chat-geometry.py` is ready to run once a host can start the runtime.
- Accident to disclose: preparing a clean evidence directory removed
  `output/chat-phase5/` (prior-phase verification evidence and a previous full-suite
  log). `output/` is gitignored, so it is not recoverable from the repository.
- **Scroll intent cannot be derived from position while the tail is being followed.** A tail pin
  moves the offset exactly the way a gesture does, and it also moves the reader *down* by however
  much the new row added. The old rule inferred intent from observed movement and then required
  `distanceFromBottom >= 48` to release, so with a streaming tail both halves fought the reader:
  each 10 pt wheel notch was erased before the next one, and the distance test was almost never
  true at the moment travel crossed 48. Intent now has to be reported by the event that caused it,
  before any clamp.
- A mouse wheel is line-unit (`NSScrollView.verticalLineScroll`, 10 pt at the default system
  setting), so `exitDistance = 48` is five notches. Trackpad deltas are pixel-unit and much larger,
  which is why the existing native check (`wheel(420)`) passed for a whole turn while a real mouse
  wheel did not work: one 420 px precise event clears the threshold in a single event.
- **Working tree discrepancy found while writing the Turn 3 validation.** The native stability
  harness that earlier turns of this plan read and quoted is not in the current working tree:
  `Sources/Milk/ChatPanel.swift` is 599 lines (HEAD 593) with no `chatStability*` hooks,
  `Sources/Milk/ChatStabilityVerification.swift` is the 149-line real-Pi mode (mtime Nov 5),
  `Tests/MilkWorkspaceTests/ChatMemoryTests.swift` is 374 lines (mtime Nov 13 02:46), and
  `scripts/verify-chat-geometry.py` has no scenario calls. `grep -rln ChatStabilityPageState`
  over the whole repository returns nothing, while `git log --all -S ChatStabilityPageState`
  points at branch `fix/chat-rendering-stability` (`c241a36`, 145-line stability harness,
  293-line `ChatPanel.swift` delta). `git reflog` shows three `reset: moving to HEAD` entries on
  Nov 13 (02:46, 07:11, 07:13) and the last branch checkout on Nov 12 into `qwen-auto-update`.
  Every Turn 3 change and test in this plan is therefore on the current `qwen-auto-update` working
  tree, and the scenario-driven audit harness would have to be restored or re-applied before the
  `runStabilityScenario`-style acceptance run described in earlier turns can happen.
- **Scroller auto-hide did not hold against AppKit (user report, live app).** Two independent
  causes. (1) `NSScrollView.tile` → `_setVerticalScrollerHidden:` reverts the transcript scroller
  to visible on every clip-view movement, including Milk's own tail pins, and it writes through
  the ordinary `isHidden` assignment — so the bar stayed up for the whole streamed answer. Probes
  confirm the call path and that a custom `NSScroller` override intercepts it; `TranscriptScroller`
  now blocks foreign hidden writes (`setMilkHidden` is the only path) and the fade always zeroes
  alpha because AppKit's overlay bookkeeping parks the bar at alpha 1 while hidden. (2) Each code
  block was a SwiftUI `ScrollView(.horizontal)`: its own horizontal indicator was a visible bar in
  the chat that the transcript visibility owner never touched, and the pointer over the block was
  inside that nested scroll view, so wheel events never reached `TranscriptScrollView` — vertical
  scrolling died over code, and SwiftUI proposed unlimited width so `Text` never wrapped. Code
  pieces are now wrapped `SelectableContent`. A scroller AppKit judges incompatible with overlay
  silently falls back to legacy style and reserves content width — `isCompatibleWithOverlayScrollers`
  is load-bearing, not cosmetic. `ChatScrollerTests` (previously added but failing) and the new
  `ChatCodeBlockTests` cover both.
- **Chat-screen audit (follow-up turn).** Fixed: (1) `ChatFollowTailState.update` compared
  `viewportHeight` with strict Double equality, so wheel intent recorded while a pane/sidebar
  animation was in flight was silently discarded — now a 1 pt tolerance, with real resize
  clamping still excluded. (2) `Coordinator.update` built the old-row index with
  `Dictionary(uniqueKeysWithValues:)`, a hidden `fatalError` on any duplicate row id — now
  `uniquingKeysWith`. (3) The turn header hardcoded "Pi" (agent-agnostic invariant) — it now
  takes the session adapter's display name with an "Assistant" fallback.
  (4) The `@`-references picker could keep showing the previous query's matches after the `@`
  trigger left the draft — a draft-opened picker now follows the draft; a button-opened picker
  still waits for the reader. Discovered while testing: an earlier suite can leave AppKit
  resolving the legacy scroller style, and a windowless `NSScrollView` fixture then reserves
  17 pt and trips the pane-width guard — transcript fixtures must pin overlay style and live
  in a window (`ChatFollowTailTests`). Deferred/observed, not changed: Enter submits only
  slash input (plain prompts insert a newline and use Send — product decision); Markdown parse
  is an intentional subset (multi-line quotes and list continuations split, nested fences
  toggle); the header row re-renders per streaming delta and joins the turn text for the
  extension context (cost grows with response length); `ChatScrollMemory`/`ChatReadingPosition`
  and `AgentMarkdown`/`AgentResponseTurnView` are dead in the live path (dev reference/tests
  only); disclosure `choices` keys are never pruned (bounded by history).

## 8. Decisions

- **Streaming pieces are never cache keys.** `streaming:` is part of the row content so
  the coordinator can tell a prefix that will change from a piece that will not. Budgets
  (64 entries, 256 KiB of retained Markdown text, 3 widths) bound settled-piece retention;
  a piece larger than the byte budget is measured on demand instead of evicting the rest.
- **Scroll geometry is presentation state.** `AgentWorkspaceState.recordScrollGeometry`
  updates the conversation without `scheduleConversationCheckpoint()`; the offset/anchor is
  still persisted by the next real transcript change, session event or quit. Recording it
  on every native scroll previously made every wheel tick a checkpoint candidate.
- **Disclosures are tracked by revision, not by row shape.** `disclosureRevision` lives on
  the render session and survives geometry eviction, because `choices` do; the coordinator
  compares it across updates instead of inferring intent from row equality.
- **Blank-area detection uses layout plus TextKit, not `fittingSize`.** A hole is a row the
  layout places in the viewport whose host is absent from the document; clipping and blank
  bands come from `usedRect` minus `extraLineFragmentRect`. Inter-row spacing is at most
  22 pt, so 40 pt is the smallest band that cannot be explained by design.
- **The verification driver names its disclosure.** The audit snapshot exposes
  `thinkingKeys` (visible thinking owners in reading order) so
  `scripts/verify-chat-geometry.py` expands a piece the reader can actually see and reuses
  the same key for collapse/repeat steps instead of relying on viewport luck.
- **Follow tolerance in the driver matches `ChatFollowTailState`** (24 pt), so the two
  cannot disagree about "at the bottom".
- **A row reserves what its own text view lays out.** Measurement goes through the
  renderer's `NSLayoutManager` (`ensureLayout` + `usedRect`, minus an empty final line
  fragment) rather than a second typesetter. No slack constant: a constant offset is
  invisible per row and accumulates into a document height no piece accounts for.
- **Trailing newlines are removed from the value the text view holds, not only from the
  measurement.** Trimming only the measurement leaves the view laying out a fragment the row
  refuses to reserve; trimming the displayed value makes measurement and rendering the same
  fact. Blank lines *inside* a piece are still reserved.
- **During a live drag the transcript keeps the width it measured.** Mounted pieces are not
  handed the pane's transient width; the reflow commit re-measures the visible range at the
  settled width and re-anchors the reader or the tail. Content keeps streaming into the
  retained layout, so deferral never hides output.

## 9. Remaining work

1. **Done (Turn 4).** Native acceptance passes end to end with the disposable runtime;
   results and the clipping-class fix are recorded above and in
   `docs/CHAT_TRANSCRIPT_RENDERING.md`.
2. One long live session RSS spot check (~1.4 GB report) to confirm the identified caches
   were the dominant growth; nothing in this plan measures real-user memory directly.
3. Optional: per-scenario (non-peak) channel values if a blank/clipping spike ever needs
   localization rather than a zero-tolerance assertion. Partly answered: the audit snapshot
   names the offending row IDs via `renderedRows`.
4. Visual/manual confirmation on the live app: a dragged pane holding its last measured width
   looks acceptable (text not horizontally clipped, not oddly centred during the drag), the
   removed 4 pt per row plus the removed trailing blank line does not change the spacing a user
   expects, wrapped code blocks read correctly, and the auto-hidden scrollbar behaves in daily
   use. `output/Milk.app` is built; the installed Milk app has not been replaced.
5. Move this plan out of `active/` when items 2 and 4 have evidence.
6. **Resolved (Turn 4).** The scenario-driven audit harness is on this branch
   (`scripts/verify-chat-geometry.py` + `--verify-chat-quality`) and green.
7. Visual/manual confirmation of the wheel fix on `output/Milk.app`: wheel up through a streaming
   answer with ordinary mouse notches, confirm each notch moves the reader, that about five notches
   release the tail, that a single small jog is still absorbed, and that scrolling back to the
   bottom resumes following. The scripted equivalent passes; a human check on real hardware
   (trackpad vs mouse) has not been done.
