# Chat geometry — Phase 5

2026-11-01. Branch: `fix/chat-rendering-stability`. Phase 1–4 changes remain intact. This phase replaces transcript geometry/materialization only; the existing history, stream, message, activity and projection models remain the source of truth.

## 1. Approaches evaluated

- Another SwiftUI lazy stack/list: rejected as a container substitution; it would leave estimated extent and nested materialization ownership unresolved.
- SwiftUI windowing with explicit top/bottom spacers and retained measurements: viable in principle, but still requires managing native wheel/scroll-position handoff, reflow anchoring and nested visibility through SwiftUI's scroll layout. No claim that all such implementations are impossible.
- `NSTableView` / `NSCollectionView` with explicit measured heights: viable, but introduces row/cell selection, intercell geometry and reuse machinery that the existing SwiftUI pieces do not need.
- Explicit AppKit scroll document with bounded SwiftUI hosting: implemented and profiled. It gives one owner for native document height, offset, materialization and user-input handoff while retaining the existing visual components.
- Full eager stack: the Phase 4 control already demonstrated stable extent but unacceptable costs. It remains a developer-only short-chat appearance reference, never the production renderer.

Only the chosen architecture was implemented as a production prototype in this phase; the alternatives above were evaluated against the established failure and native API behavior. The fixed-frame hosts disable automatic sizing constraints, and measurements use the public hosting-controller fitting API. See Apple's [hosting sizing options](https://developer.apple.com/documentation/swiftui/nshostingview/sizingoptions) and [sizeThatFits(in:)](https://developer.apple.com/documentation/swiftui/nshostingcontroller/sizethatfits(in:)).

## 2. Chosen architecture and rationale

`NSScrollView` → flipped native document → a bounded set of `NSHostingView`s for nearby transcript pieces. There is a real native scrollbar. There is no outer SwiftUI lazy stack, estimated native extent, fake scrollbar or reload recovery loop.

The existing logical turns are flattened for presentation into stable header, Markdown-piece, Thinking and Activity rows. Owners remain the original transcript turn IDs. Markdown piece IDs match the existing reading targets. Flattening prevents a single long Markdown response from creating every paragraph/code view at once. The existing SwiftUI visual components are reused.

## 3. Exact old geometry failure

Phase 4 captured a blank viewport with 30 messages, 6 activities and 24 projected items still present. No visible reading IDs remained. Removing a forced scroll-position reset improved one trigger, but another blank occurred with native user-position state intact. Lazy estimates changed native document height from 101199 to 106176 during a 25-point viewport movement, moving the native scroller approximately 1.000 → 0.953. The same unchanged history measured 30046 points in the eager control. Data loss was not the demonstrated failure.

## 4. New geometry model

Each physical piece has a stable ID, owner turn ID, reading order, exact measured height and preceding gap. A prefix index computes all row origins and total document height. It provides binary-search viewport lookup and stable-ID anchors. The document frame is assigned explicitly. Wheel scrolling queries the index and mounts views; it does not measure, estimate, or change document height.

Geometry replacement is atomic after content/reflow measurements are available. Existing geometry remains in place until replacement. Top inset 28, inter-turn gap 22, response gap 12, Markdown gap 10 and the existing tail spacing are preserved.

## 5. Height cache and materialization

Measured heights are retained by stable piece ID, content and exact content width. Scrolling offscreen does not invalidate them. Identical Markdown pieces additionally share measurements at the same width. Native measurement uses a bounded pool, at most fourteen visual kinds; eight were needed by the measured fixtures. The pool is reused and its roots are cleared after a measurement pass. It does not create one hidden native text view per history row.

Visible pieces plus at least 600 points / one viewport of overscan on each side receive native hosting views. A focused piece may remain pinned for selection; removed history IDs are never pinned, and pinned geometry also follows reflow. Native subviews are kept in logical order for accessibility. Four recently used sessions retain geometry caches; disclosure choices survive cache eviction.

## 6. Streaming behavior

The existing coalesced stream and projection cache feed the renderer unchanged. Matching completed piece heights remain cached; changed active pieces are measured again. Following keeps the native bottom offset at the exact new maximum. Reading above preserves the stable piece and its within-piece pixel offset. Content growth is explicitly excluded from user-intent transitions. Native tests passed streaming while reading above and resumed following after returning to the tail.

## 7. Width changes

Native clip-view bounds detect window, sidebar and pane-width changes. Live reflow is debounced by 80 ms; the current measured document remains mounted during the gesture. Replacement heights are measured at the new width and committed together, preserving the logical reading piece and proportional position within that piece. Mounted hosts receive updated narrow/wide inputs. Width changes do not enable following. Same-width session return preserves saved native offset; a different-width restore can resolve the saved logical piece.

## 8. Scrollbar evidence

Before: a 25-point wheel increment could change estimated document height by nearly 5000 points and move the thumb by roughly five percentage points.

After: each 80/300/800-turn trace contains 40 sequential upward 25-point increments. Document height stays constant; native offset changes by −25 each time; native scroller changes by `−25 / (documentHeight − viewportHeight)`, checked to within 0.00001. The earlier 800-turn prototype's measured proportional error was below 1e−16. Raw final values, ranges and mounted-view counts are in `output/chat-phase5/wheel-traces.json` and `geometry-observations.jsonl`.

Vertical native wheel deltas are applied directly to the outer document, including when the viewport contains horizontal code scrollers. Horizontal input retains native handling. The native scroller subclass declares overlay compatibility, avoiding an unintended 17-point gutter and spurious reflow. Input handoff accounts for completion of native scroll interaction.

## 9. Blank-viewport result

The 745-snapshot acceptance run passed with no blank viewport. It includes the exact failing Phase 4 sequence: fresh streamed long response → +12, −12, +100, −80, then a large downward wheel to the tail. It also covers wheel bursts, long single responses and large histories. Developer verification asserts that a nonempty document has a mounted native view intersecting the viewport. Diagnostics report actual mounted visible IDs, logical/projected counts and materialized ranges.

This is evidence for the exercised scenarios, not a claim about every possible future provider output or operating-system behavior.

## 10. Follow-tail result

The Phase 4 reducer remains unchanged: enter at 24 points on downward user movement; exit after 48 points of upward intent and at least a 48-point bottom gap. Five native cycles at each history size verified that +12 retains follow, +100 exits, and −80 re-enters at a 20-point gap. Layout growth, reflow and session return did not force follow while reading. The retained native verifier also passed stream-follow growth with zero bottom gap.

## 11. Performance measurements

Real disposable native app, same two-section mixed Markdown/thinking history fixture used for the earlier control. Elapsed time includes fixture work, command round trips and a 200 ms settling interval; it is not the layout CPU time. Maximum run-loop delay includes fixture publication / first layout. RSS is cumulative within the verification process, not an isolated per-session allocation measurement.

| Turns | Seed-to-settled elapsed | Initial document layout | Max run-loop delay | RSS | Mounted pieces at tail |
| --- | ---: | ---: | ---: | ---: | ---: |
| 80 | 0.462 s | 29.1 ms | 104.9 ms | 138.5 MiB | 26 |
| 300 | 0.478 s | 69.2 ms | 165.9 ms | 161.3 MiB | 26 |
| 800 | 0.585 s | 166.4 ms | 308.3 ms | 182.7 MiB | 26 |

The rejected eager control used approximately 556.5 MiB / 1.98 s maximum delay at 80 turns and 941.8 MiB / 4.42 s at 300 turns. The new renderer materially improves on that control.

| Turns | Wheel materialization p95 / max | Cached session-return layout work | Largest tested resize layout work |
| --- | ---: | ---: | ---: |
| 80 | 2.06 / 3.50 ms | 5.62 ms | 36.86 ms |
| 300 | 0.95 / 1.86 ms | 12.26 ms | 86.16 ms |
| 800 | 0.85 / 1.80 ms | 26.55 ms | 190.43 ms |

Materialization timings include initial mounting and the forty-step wheel trace. Session-return and resize numbers are accumulated native document-layout work for the operation, not end-to-end input latency; the reflow debounce is separate. Reading targets and follow state were checked after each operation. See `operation-layout-costs.json` and the raw observation log. In this app's tested sidebar path the window also resized to retain pane width, so toggling the sidebar did not require new row heights.

An additional fresh-process fixture varies response text per turn so shared-content cache hits do not hide cold costs:

| Distinct-text turns | Seed-to-settled elapsed | Document layout | Max run-loop delay | RSS |
| --- | ---: | ---: | ---: | ---: |
| 80 | 0.441 s | 138.5 ms | 203.3 ms | 196.3 MiB |
| 300 | 0.716 s | 452.2 ms | 543.9 ms | 204.3 MiB |
| 800 | 1.537 s | 1177.3 ms | 1203.1 ms | 222.4 MiB |

Distinct-text cold measurement remains noticeably slower. No measured case had a multi-second main-run-loop stall or near-gigabyte RSS. See `performance.json` and `varied-performance-final.json` in `output/chat-phase5/`.

## 12. Memory sanity

The 800-turn fixture has 12000 physical pieces, but only 26 at the tail have mounted hosts; wheel traces remain bounded. The acceptance driver rejects 150 or more mounted hosts and RSS of 600 MiB or more. Native measurement hosts are counted separately, with eight in these fixtures. Known heights and lightweight row values remain available for offscreen rows. Large responses do not require keeping all native text/code views alive.

## 13. Exact changed files in this phase

- `Sources/Milk/ChatPanel.swift`: native adapter, shared existing visual pieces, local render-session ownership and explicit developer appearance reference.
- `Sources/Milk/NativeChatTranscript.swift` — new: native scroll document, measurements, materialization, input, reading restoration and diagnostics.
- `Sources/Milk/ChatTranscriptLayout.swift` — new: exact prefix geometry and stable-ID lookup.
- `Sources/Milk/ChatTranscriptRows.swift` — new: projection-to-piece adapter, local disclosures and height caches.
- `Sources/Milk/ChatQualityVerification.swift`: wheel bursts, keyboard, appearance reference and distinct-text fixture support.
- `Tests/MilkWorkspaceTests/ChatGeometryTests.swift` — new: geometry and identity regressions.
- `scripts/verify-chat-geometry.py` — new: repeatable native acceptance driver.
- This report.

Other starting files match the Phase 5 baseline SHA-256 manifest in `output/chat-phase5/baseline/manifest.json`.

## 14. Tests and results

81 selected tests passed, zero failures. The filter includes geometry, quality, stability, presentation, agent/service/lifecycle/migration, slash commands and retained Pi integration/parity/routing/consistency suites. New tests cover 16000-piece extent invariance and viewport coverage, bounded ranges, reflow by stable piece identity, unchanged earlier origins during tail growth, ordering, unique IDs and disclosure retention. The full repository suite was not run.

The retained native verifier passed real-Pi fixture prompt/thinking/read/bash/output, repeated tool IDs with distinct outputs, native resume without blank history or ID/order changes, intentional reading during streaming, exact session-return offset and renewed tail following. See `retained-tests-final.log` and `native-resume.log`.

## 15. Native stress coverage

Passed: twelve mixed submissions with 96 actual `NSTextView.insertText` edits; long single response; 80/300/800-turn histories; sequential wheel input and bursts; deliberate upward reading; near-tail re-entry; streaming while reading above; narrow/wide resize; sidebar toggles; session switching and return; keyboard Page Up / End; and the retained native resume path. A final UI divider drag changed chat-pane width to 671 points while preserving the same logical reading piece and keeping follow off. A viewport-level UI wheel action then moved 125 points with zero extent change and visible native content. See `pane-resize.json` and `ui-wheel-state.json`.

Native selection plus ⌘C copied the exact selected paragraph, with the clipboard restored afterward. Thinking, Activity and tool-output disclosure clicks worked and retained choices after session return.

Input used real AppKit event handling in the disposable development app. No physical trackpad coverage is claimed. The normal user app and its workspace state were not used as test fixtures.

## 16. Appearance regression

Short-chat and Markdown/code native screenshots were compared with the retained prior-layout reference, each over a 1600 × 1196 pixel transcript region. All 1913600 pixels in each region matched exactly (mean channel error 0). The two cases cover user bubble, Pi header, collapsed Thinking, interleaved Activity, prose, headings, lists, code blocks, links and quotes. Source styles for fonts, colors, padding, cards, code, composer and Changed Files are reused without intentional design changes. Screenshots and comparison numbers are in `output/chat-phase5/appearance-*.jpg`, `appearance-short-comparison.json` and `appearance-long-comparison.json`.

## 17. Remaining limitations

Cold measurement is still linear in distinct content. The varied 800-turn case's approximately 1.2-second main-thread pause is the principal remaining performance limit; it occurs during first measurement, not ordinary wheel materialization. Height caches are local and are rebuilt after a cold process start or geometry-cache eviction. A single exceptionally large paragraph, expanded tool output or activity group remains one physical piece, so its own layout/selection cost is not subdivided. Screenshot equality is scenario-specific, not an exhaustive theme/extension matrix. The exercised blank/scrollbar failures no longer reproduced; further real-user manual acceptance is still useful.

## 18. Scope confirmation

Provider/profile/authentication, Local/oMLX keys, model/context behavior, Pi installation, Git implementation, editor and session deletion were untouched in this phase. Atomic history reconciliation, deterministic identities, tool ownership, stream coalescing, retry/recovery, stale-event guards, checkpoints, background RPC work and transcript projection remain unchanged. All Phase 1–4 work is preserved.

## 19. Git and stop boundary

Nothing was committed, pushed or merged. Branch remains `fix/chat-rendering-stability`, at the same starting HEAD `24e3d5b24711a00fb3ca0f7601e40cc43b63621f`. Work stops after this phase. The rebuilt app is `output/Milk.app`; normal-user-app relaunch was not part of this disposable verification run.
