# Native transcript rendering and render-session memory

Current reference for how the Chat transcript holds rendering state, how it decides to
scroll, and what limits its memory. Phase history lives in
[`CHAT_GEOMETRY_PHASE_5.md`](CHAT_GEOMETRY_PHASE_5.md) and
[`CHAT_MANUAL_RENDERING_FINDINGS.md`](CHAT_MANUAL_RENDERING_FINDINGS.md); this file
describes the code as it is now.

## Ownership

```text
ChatPanel (workspace session)
  → ChatTranscriptStore → ChatTranscriptSession (one per workspace session)
  → ChatTranscriptRow pieces (stable IDs)
  → NativeChatTranscript.Coordinator → ChatTranscriptLayout → NSScrollView document
```

Rendering state is local to Chat. It never enters `AgentService` conversation data, the
transcript projection's semantics, or Pi. `AgentTranscriptProjection` still owns the
messages/blocks/activities it builds; `ChatTranscriptSession` owns only derived render
state: projected rows, measured heights, shared Markdown heights and user disclosures.

## Activity grouping

Consecutive visible thinking blocks and tool operations in the same assistant response
are shown in one Activity card, with the original order preserved. User-facing
assistant text separates Activity cards. A run containing only thinking keeps the
standalone Thinking disclosure. Each thinking step and tool output inside an
expanded Activity card has its own disclosure; collapsed cards remain one stable
transcript row. Empty/redacted thinking never creates a visible step. Grouping is a
presentation-only projection; Pi events and native history are unchanged.

## Render-session memory

- `ChatTranscriptSession.heights` keeps one `(content, width, height)` per **live** piece,
  keyed by stable piece ID. Scrolling a piece offscreen does not drop it; a piece whose
  content changed (or whose measured width changed) is measured again.
- `ChatMarkdownHeightCache` shares heights between identical **settled** Markdown pieces.
  It is bounded: 64 entries, 256 KiB of retained Markdown text, 3 content widths, oldest
  first eviction, and a single piece larger than the byte budget is measured on demand
  instead of being retained.
- `ChatTranscriptRow.Content.markdown` carries `streaming:`. A streaming Markdown piece is
  measured on every update and deliberately never enters the shared cache: each delta is a
  new key, so retaining prefixes cost memory and never hit. This was the dominant growth
  in a long live session (peak of 3,408 entries / ~85 MB of retained Markdown text for one
  195k-character response).
- Four recently used sessions keep geometry. `ChatTranscriptStore.releaseGeometry(except:)`
  evicts the rest, and `ChatPanel` calls `retain(open:)` so sessions the workspace closed
  are forgotten outright. `releaseGeometry()` clears heights, the Markdown cache, projected
  rows and the projection's retained copy (`AgentTranscriptProjection.reset()`); user
  disclosure choices survive, because they are the reader's state, not layout.
- `retainedBytes` (Markdown cache + projection) is reported in verification snapshots as
  `markdownCacheBytes`, `markdownCacheEntries` and `projectionBytes`.

## Scrolling and following the tail

`ChatFollowTailState` plus `ChatReadingPosition` own the decision, and the coordinator
applies it after each atomic geometry commit.

- Tail growth with `followsTail` set pins the exact new maximum offset.
- A scroll or keyboard gesture that leaves the bottom disables following; coming back
  within 24 points re-adopts it (exit threshold 48 points).
- Intent is measured from the reader's own events, not from position. A tail pin moves the
  offset *without* the reader, so observed movement alone cannot tell a gesture apart from
  the transcript putting them back at the bottom, and the two fight each other.
  `TranscriptScrollView` reports the signed upward distance a genuine wheel or key event
  asked for, before any clamp, and `ChatFollowTailState.noteRequest` accumulates it:
  cumulative requested upward distance of 48 points releases the tail. Release does not
  depend on how far from the bottom the reader happens to be when the threshold lands.
- While an upward request is unanswered — and within `Coordinator.travelHoldWindow` (0.6 s)
  of the last such event — a layout commit keeps the reader's anchored position instead of
  pinning the new bottom. Every notch therefore moves the reader. Without this, each mouse
  wheel notch (10 points at the default line scroll) was undone by the next streaming
  commit, which is what reads as a wheel stuck near the bottom.
- A jog the reader abandons is still absorbed: the pending request expires, following is
  unaffected, and the next commit pins the tail again.
- A commit re-baselines the follow state (`rebaseline`) so the next observation measures the
  reader rather than the offset the commit chose.
- A **disclosure** change (Thinking, Activity group, tool output) is not tail movement.
  `ChatTranscriptSession.disclosureRevision` changes only on user disclosure choices; when
  it moves, the reader's anchor is preserved and following is re-adopted only if the kept
  position genuinely is the bottom. Content growth never flips user intent. In practice:
  expanding while reading above leaves the reader on the same text with following off;
  expanding while pinned to the tail keeps the tail piece under the reader, so the kept
  position still is the bottom and following survives.
- Reading above the tail keeps the stable piece ID and its within-piece pixel offset, so
  expanding or collapsing a block above the reader moves the reader with the layout
  instead of jumping them to the end.

## Measurement fidelity

- A piece reserves exactly the height its own renderer lays out. `SelectableContent` asks
  the `NSTextView`'s `NSLayoutManager` for `usedRect` at the proposed width instead of
  measuring the string with `boundingRect`. The two disagree: the string measurement added
  a flat 4 points to every row, and for text that ends in blank lines it reserved far less
  than the view laid out (a fixture thinking block measured 266 while laying out 304).
  A row shorter than its own text is what a reader meets as clipped output, and a row
  taller than its text is a document height no piece accounts for.
- The text container tracks the view: `SelectableContent` sets
  `textContainer.widthTracksTextView = true`. With tracking off, `containerSize` kept
  whatever width the last `sizeThatFits` negotiation probe passed in — SwiftUI proposes
  several widths (including tiny ones) before placing a view — and the mounted text then
  wrapped narrower than the row actually rendered: `usedRect` ran past the frame the same
  content had measured at, which the acceptance audit caught as `document.text.clipped`
  on user bubbles and code blocks (a 343 pt container inside a 540 pt text view). Tests:
  `Tests/MilkWorkspaceTests/SelectableContentWidthTests.swift`.
- Measurement proposes each row's own ceiling width (`Coordinator.maxTextWidth`): a row
  capped at 240 pt (notice, turn summary, activity row) is measured at 240, and a row
  containing a `SelectableContent` is measured at the content width. Measuring a capped
  row at 720 while placing it at 240 over-reserves height; measuring a wrapping row at a
  cap it never uses under-reserves. The proposal must match the width placement gives the
  text, or the cache stores a height no layout reproduces.
- `SelectableContent.visibleText` trims trailing newlines from the value the text view
  actually holds. TextKit reserves a full line fragment for a trailing `\n`, which paints
  nothing and left a blank band under every thinking block and tool output that ended in a
  newline. Blank lines *inside* a piece stay part of the piece and are still reserved.
- Measurement uses a bounded pool of hosting views (one per visual kind, at most 14), not
  one hidden view per history row.
- `Coordinator.visibleCoverageAudit()` is the structural check behind the
  `document.blank.band`, `document.text.clipped` and `document.text.blank` channels: a
  piece the layout places inside the viewport that is not mounted, native text extending
  past its assigned frame, and blank space inside a mounted piece. Text extents are
  measured from real `NSLayoutManager` layout converted into document coordinates; empty
  final line fragments are excluded. The audit skips pieces of the *active streamed
  response* while the session is busy or pending: its tail is mid-commit by definition,
  and measuring it reports a transient gap as a layout defect (this false positive fired
  as `document.text.blank` on the response header row during live streaming). The audit
  snapshot also names the offenders — `renderedRows` carries the row IDs behind the worst
  hole, clip and blank band — so a failing run identifies the piece without guessing.
  `scripts/verify-chat-geometry.py` asserts all three channels are zero, that the Markdown
  cache stays inside its budget, and drives an expand/collapse disclosure scenario through
  `ChatScrollAudit.disclose`.

## Resizing while output is streaming

`Coordinator.activeContentWidth` is the width the layout, the measurements and the mounted
pieces agree on. While a pane is being dragged it is *not* the width the pane currently has.

- A width change wider than 0.5 points arms a reflow commit instead of remeasuring the
  whole transcript on every resize notification. Content keeps streaming into the retained
  layout during the drag, so nothing is hidden while the reader drags.
- Mounted pieces are never handed a new width while keeping the height measured at the old
  one: text rewraps taller than its reserved frame, which reads as clipping. During a drag
  the mounted hosts keep `activeContentWidth`.
- When the pane stops moving the commit re-measures the visible range at the settled width
  and re-anchors the reader or the tail onto the reflowed geometry. If the pane is still
  moving when the commit lands, the commit re-arms itself rather than racing the drag.

## Scrollbar visibility

`ChatScrollerVisibility` plus `TranscriptScroller` own the transcript bar. AppKit
cannot be left in charge: `NSScrollView.tile` → `_setVerticalScrollerHidden:`
reverts the scroller to visible on **every** clip-view movement, including Milk's
tail pins and layout commits, so left to AppKit the bar stays up for the whole
streamed answer. `TranscriptScroller` blocks foreign `isHidden` writes; only
`setMilkHidden` moves the state. A gesture (`readerGesture`, knob drag, keyboard)
reveals the bar for `ChatScrollerVisibility.visibleFor`; the idle fade
(`fadeScrollerIfIdle`, `fadeWhenIdle`) takes it back, and a faded bar is hidden
and alpha 0 so a later reveal starts from invisible. AppKit's overlay machinery
also writes `alphaValue` itself (it parks the bar at alpha 1 while hidden), so
the fade always zeroes alpha even when the bar is already hidden. A scroller
whose style resolves to legacy (system "Show scroll bars" setting, or a scroller
AppKit judges incompatible with overlay) reserves content width — that is why
`TranscriptScroller.isCompatibleWithOverlayScrollers` is overridden and the
fixture asserts the clip width never changes.

## Code blocks

A `.code` Markdown piece is a wrapped `SelectableContent` monospaced piece
(`AgentMarkdownPiece`), not a SwiftUI `ScrollView(.horizontal)`. A nested scroll
view inside the transcript drew its own visible horizontal bar in the chat, and
the pointer over it was inside that scroll view, so wheel events never reached
the transcript scroller — the reader could not scroll vertically or horizontally
while over a code block. Wrapping at the row width removes the horizontal axis
entirely; wheel gestures over a code block hit plain `NSTextView` and reach
`TranscriptScrollView` through the responder chain.

## Regression coverage

`Tests/MilkWorkspaceTests/ChatFollowTailTests.swift` covers wheel intent that
overlaps a pane animation (sub-pixel viewport jitter must not discard reader
intent; a real multi-point viewport change is still treated as a resize), a
duplicate transcript row id degrading to a layout quirk instead of crashing the
commit, and the turn header naming the session's agent instead of a provider
constant. Transcript view fixtures must pin `scrollerStyle = .overlay`: another
suite can leave AppKit resolving the legacy style, which silently reserves 17 pt
and changes clip width.

`Tests/MilkWorkspaceTests/ChatMemoryTests.swift` covers streaming Markdown retention,
streaming Thinking render-state bounds, cache eviction/oversize/width rules, geometry
release with disclosure retention, closed-session eviction, both disclosure
reading-position cases, tail pinning while following, trailing-newline sizing, and audit
sensitivity to holes, clipping and blank bands.

`Tests/MilkWorkspaceTests/ChatTextMeasurementTests.swift` compares the height a row
reserves with the height the same content lays out inside it, across a corpus (short
lines, wrapped paragraphs, CJK, emoji, tabs, long tokens, monospaced code, activity
output, empty and newline-only text) at two widths, and pins the blank-line policy: an
interior blank line costs the same as a real line, trailing newlines cost nothing.

`Tests/MilkWorkspaceTests/ChatResizeTests.swift` drags the pane while a Thinking block
streams and asserts that output keeps arriving, that no mounted piece exceeds its measured
width or gets clipped by its own text, that a remeasure commits once the pane settles, and
that a reader who scrolled up stays on the piece they were reading through the reflow.

`Tests/MilkWorkspaceTests/ChatWheelTests.swift` drives real AppKit wheel events in line
units against a streaming transcript: every notch moves the reader and the commit that
follows it keeps their position, a deliberate gesture releases the tail within a few
notches and stays released while output arrives, an abandoned jog is absorbed, wheeling
back to the bottom resumes following and its pinning, and keyboard scrolling is honored
the same way. `Tests/MilkWorkspaceTests/ChatWheelProbeTests.swift` is the temporary
diagnostic that first reproduced the stuck wheel and prints the per-notch offsets.

`Tests/MilkWorkspaceTests/ChatCodeBlockTests.swift` asserts a mounted code piece
contains no nested `NSScrollView`, that a long code line grows the row when the
width halves (it wraps instead of scrolling sideways), and that a wheel gesture
hit-tested over the code block moves the transcript. `Tests/MilkWorkspaceTests/ChatScrollerTests.swift`
covers streamed commits not revealing the bar, a reader gesture revealing it and
fading back, the knob tracking the reader, and hiding the bar not moving content.
`Tests/MilkWorkspaceTests/SelectableContentWidthTests.swift` asserts a mounted
`SelectableContent` never lays out taller than the height its content measured at the
host width, and that the text container agrees with the resolved view width after layout
negotiation has probed other widths.

Native acceptance with a real disposable Pi runtime
(`--verify-chat-quality` plus `scripts/verify-chat-geometry.py`) **passes end to end**:
mixed fixture conversation (grouped tool turns, streamed `chat-scroll-fixture`, plain
turns), wheel/hysteresis bursts, 80/300/800-turn seeded history with per-notch wheel
integrity checks, resize/appearance/copy phases and the expand/collapse disclosure
scenario, with `document.blank.band`, `document.text.clipped` and `document.text.blank`
zero throughout. The 800-turn seed ran in ~0.6 s at ~167 MiB RSS (budget 600 MiB).
Two harness facts discovered while running it: the disclosure case needs a transcript
larger than one fixture turn, so it now seeds 20 varied turns (seeded history carries
restored thinking blocks, which is what the disclosure scenario toggles); and a live
fixture prompt must not be issued into a synthetic seeded history — the loopback fixture
server stalls on a grouped turn inside reconstructed history, so the disclosure case uses
seeded content instead of a fresh grouped prompt.
