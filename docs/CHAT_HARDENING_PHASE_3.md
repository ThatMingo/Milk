# Phase 3 — renderer hardening, appearance locked

Branch: `fix/chat-rendering-stability`. Phase 1/2 changes remain uncommitted. Baseline
snapshot: `output/chat-phase3/baseline/manifest.json` (27 paths).

## 1–3. Findings, Milk-owned costs, fixes

The measured avoidable cost was repeated transcript-wide assistant-ID construction
for text-only updates with **no activities**. Projection still needs prefix identity
comparison and cached-prefix selection, but activity association needs neither of
those assistant-ID sets when there is no activity to associate. The fix guards those
passes and constructs sets from lazy filtered sequences when they are needed. No
new cache, background task, publication channel, or identity scheme was added.

Native verification also reproduced initial follow positioning remaining at offset
zero after an answer grew beyond the viewport. The resulting upward-read/session
return checks could not succeed. A native initial bottom edge target now initializes following conversations.
The existing invisible 1-point tail and 16-point bottom space are combined into a
17-point transparent tail inside positioned content, rather than leaving the 16
points outside its bounds. Net layout height and intended spacing are unchanged;
the edge target now includes the full inset. A gesture still releases programmatic
positioning. Saved reading positions and the 2-point follow threshold remain intact.
An intermediate persistent-edge version left a 16-point discrepancy; an attempted
early release reintroduced the follow failure. Both were rejected. Final native
runs and the long-answer gap check are recorded below. No per-token scroll
command, cadence change, or visual navigation control is introduced.

## 4–5. Measurements

Same-host debug native benchmark, 30 projection iterations per history size. These
are operation timings, not FPS or proof of an equivalent whole-app speedup.

| Projection update | Before mean | After mean |
| --- | ---: | ---: |
| 50 turns | 0.165 ms | 0.091 ms |
| 300 turns | 0.890 ms | 0.504 ms |
| 800 turns / 1,600 messages | 2.356 ms | 1.306 ms |

The 800-turn operation is about 45% shorter in this run. This result applies to the
text-only, activity-free path. Tool ownership/association still executes when needed.
Raw benchmarks: `output/chat-phase2/profile-p3-{baseline,after}.json`.

The real 800-turn history resumed through Pi RPC, with 1,015,890 visible characters.
Reconstruction was 13.76 ms and reconciliation max 3.83 ms. Three subsequent same-
history resumes measured a representative reconstruction 13.86 ms and reconciliation
3.74 ms. These costs were not rewritten; there is no claimed history-load speedup
from Phase 3. Initial-load run-loop lateness reached 151 ms, while a later resume
reached 46 ms. Scheduling/layout differences make a before/after claim inappropriate.

A new ~70 KB Markdown response was appended to the existing 800-turn history during
switching, wheel input, resize and sidebar toggles. Combined stress metrics:

- Conversation publications: 490; generic ShellState invalidations: 516.
- Projection mean 1.55 ms, p95 1.96 ms, max 2.43 ms across 550 queries.
- Markdown parse p95 0.070 ms in the **visible old rows**; the offscreen growing tail
  was not parsed for display. This is not the whole-active-answer parse cost.
- Native text-update max 0.155 ms, p95 0.121 ms (448 calls, including view remounts).
- Combined run-loop max 1.36 s includes rapid switching/reflow and AX-enabled native
  view work. It is a real stress limitation, not isolated stream timing or FPS.

Prior Phase 2 active-answer measurements remain relevant because the parser and
native layout implementation are unchanged. Phase 3 does not claim to remove all
native SwiftUI/AppKit focus/layout cost for enormous visible single answers.

## 6. Observation and publication

Each buffered flush still applies accepted deltas to a conversation value and
publishes once; dictionary/array copy-on-write preserves snapshot correctness.
Generic ShellState forwarding remains at coalesced cadence. The composer/slash
signal stays separate. Code inspection found no token-driven provider discovery,
installation lookup, slash refresh, metadata/index rewrite or Settings mutation.
The editor's underlying view depends on WorkspaceStore; no editor implementation
was changed. Broad ShellState observation was not rewritten without attributable
expensive downstream work. Body invalidation counts alone are not a cost finding.

## 7–8. Native text/layout and completed rows

The native text representable keeps its existing input equality guard and avoids
reapplying identical text. Stable row IDs and equatable response/Markdown pieces
remain. The projection retains completed prefix values and rebuilds only the
changed turn. The existing oracle regression checks equality against the full
reducer and asserts two rebuilt messages for an active tail, then zero on an
unchanged query; orphan activity and changed activity owners are covered too.

During switching/reflow, old rows legitimately mounted and parsed. Between the
settled read-above snapshot and stream completion, parse count changed only
378 → 379 while character count grew 1,034,837 → 1,085,718. This supports quiet
completed content after layout settles, not a claim that old rows never lay out.
No per-row instrumented body count or native allocation-stack census was added.

## 9. Scroll/session stress

The driver switched between an existing completed session and the live large
session six times, exercised rapid wheel input, narrowed 1060 → 760, toggled the
sidebar, then widened again. The saved visible owning target stayed the same while
following remained disabled. Pixel offsets changed as lazy heights/reflow resolved;
those changes alone are not evidence of scroll fighting. Real-Pi resume and native
regression results are recorded below. Physical trackpad momentum was not tested.

## 10. Persistence/recovery

The 500 ms bounded checkpoint remains unchanged, and snapshot/close paths still
flush accepted buffered content. Session index persistence is outside stream flush.
The existing persistence-enabled regression continuously emits deltas and reads
actual recovery storage; snapshot/recovery and stale-session tests also pass.
The native audit uses persistence-disabled disposable state, so its timings must
not be presented as production checkpoint serialization benchmarks. No recovery
promise was weakened and no serialization concurrency was introduced.

## 11. Memory sanity

One controlled same-process sequence in MiB RSS:

| State | RSS |
| --- | ---: |
| Before large history | 121.5 |
| Loaded history | 236.3 |
| Same-history resume 1 / 2 / 3 | 241.0 / 241.4 / 241.6 |
| Combined stream/switch/reflow observed high sample | 641.7 |
| Stream finished | 602.6 |
| After reconciliation | 602.3 |

Repeated reconciliation alone did not show runaway duplicate transcript retention.
The combined stress retained substantially more process memory. RSS does not
identify ownership or prove a leak; native view/cache retention versus Milk-owned
retention needs allocation/heap tracing before assigning a cause. The projection
retains one input snapshot and one cached projection, not an accumulating history
of projections; Phase 3 adds no retained structures. No flat-memory/leak-free claim
is made. Raw sequence: `output/chat-phase3/stress.json`, `post-reconcile.json`.

## 12. Exact Phase 3 files

- `Sources/Milk/AgentTranscript.swift`: skip empty activity association work.
- `Sources/Milk/ChatPanel.swift`: initial bottom target and equivalent invisible inset placement; no style declarations changed.
- `docs/CHAT_HARDENING_PHASE_3.md`: this report.

Everything else in the 27-path Phase 1/2 snapshot remains byte-for-byte unchanged.
Generated measurements, captures, scripts and logs stay in ignored `output/`.

## 13–14. Tests/native verification

75 retained chat, lifecycle, migration, slash and real-Pi integration regressions
passed (`output/chat-phase3/tests.log`). The existing projection oracle directly
covers the modified fast path, including activity changes and orphan ownership;
no redundant implementation-mirroring tests were added. The final 27 chat tests also passed after the initial-position fix
(`final-chat-tests.log`). Native results are recorded below. Failed exploratory native runs are retained, not represented
as passes. Build/signature/diff validation is performed on the final bundle.

## 15. Appearance regression

Pre-Phase-3 code was rebuilt from the saved source snapshot for native comparison.
Captures under `output/chat-phase3/` cover user prompt, assistant prose, Thinking,
Activity, code, Changed Files, error/notice and composer/transcript relationship.
Before/after write and notice captures preserve the control/text styling for the
same fixtures. Native viewport offsets and selection may differ; they are not
represented as padding or typography changes. The accepted final short-transcript pair is `before-tools.jpg` /
`after-tools-final.jpg`; user/prose/Thinking/Activity/composer appearance is unchanged.
The write and notice final pairs cover code, Changed Files and error/notice.
OS capture chrome, native scrolling/selection and fixture state are excluded from
style judgments; no pixel-identical image assertion is made.
An incomplete after-tools capture containing only a window corner was rejected.
No appearance result is inferred from that capture. No typography, colors, icons, materials, borders or card styling were changed.
No net spacing/padding amount was changed: the bottom-space placement adjustment
is required for native anchor bounds and preserves its 17-point total.

## 16–20. Limits and scope

Remaining native framework layout/focus work, first-layout latency, stress RSS
retention, physical trackpad coverage and full VoiceOver performance remain limits.
The stress latency/memory samples must not be relabeled as a design opportunity or
claimed fixed by this narrow projection change. Continuous streams still use 33 ms
coalescing, deterministic identity, ownership, stale guards, logical reading targets,
local follow state, explicit disclosure choices and background RPC framing/decoding.

**No intentional UI/design changes. Session deletion untouched. Provider/profile,
Local provider, authentication, model/context, Pi installation, Git, editor and
Settings implementations untouched. No agent added. No commit, push or merge.**
Work stops after Phase 3; limitations are reported rather than hidden by a redesign.

## Final native results and evidence

- `native-final-checks-1.txt`, `-2.txt`, `-3.txt`: **12/12 passes per run**.
  Initial growth, upward wheel input, reading while generation continues, exact
  same-width session return offset, return-to-tail with zero gap, repeated tool
  identity, atomic resume and disposable process cleanup all pass.
- Earlier failed initial-follow/return runs remain in `native-isolated.log` and
  `native-unique.log`; bundle isolation alone did not fix them. The accepted
  initial bottom-target/inset fix addressed the reproduced failure.
- `result-p3-final-copy-end.json` under `output/chat-phase2/`: exact selected-code
  ⌘C check. No clipboard data was logged. AX exposes Thinking/Activity as buttons
  with expansion/completion values. Native selection remains active during wheel
  input. Page Up was delivered while code selection had focus; its immediate
  snapshot did not move the outer viewport, so that attempt is not reported as a
  successful keyboard-scroll distance assertion. Full keyboard/VoiceOver coverage
  is not claimed.
- Final build, strict deep signature verification and diff whitespace checks pass.
  No tests asserting visual judgment or copying implementation details were added.

The final inset correction also matches the original notice-card/composer spacing
in the paired native captures. The net bottom space remains 17 points.

Raw evidence is local under `output/chat-phase3/`; the comparison gallery is
`output/chat-phase3/appearance.html`. Final visible-stream metrics follow below.

## Final visible active answer

The final AX-enabled native window followed a 69,828-character Markdown answer
without scrolling away. It finished with a **zero native bottom gap**, 401
conversation publications and 385 Markdown parses. Parse p95/max were 2.108/2.662 ms.
Main-loop lateness p95/max were 56.158/109.959 ms. These are same-run observations,
not a claimed before/after whole-app improvement or FPS. Native framework work for
a very large visible answer remains measurable. The 3 `native.text.update` calls
(max 0.105 ms) instrument Milk's SelectableContent representables; they do **not**
count SwiftUI Text's internal native layout.

Raw data: `output/chat-phase3/visible-stream.json`. Final signature and diff checks
passed. The disposable processes exited and temporary state was removed. Local
HEAD and main remain `24e3d5b24711a00fb3ca0f7601e40cc43b63621f`. No commit, push
or merge was made. The production Milk process was not used as the audit target.
