# Manual chat findings — 2026-11-01

Status: **partial improvement; chat acceptance remains open**. Work stays on `fix/chat-rendering-stability`, with all Phase 1–3 changes preserved. This phase stops before a broad renderer change, as requested. The existing lazy transcript still produces blank viewports and unstable scroll extent under native wheel input.

## 1. Was disappearance reproduced?

Yes. A disposable native conversation exercised 12 submissions, streaming, composer edits, thinking/tools, long Markdown responses, small wheel input and repeated wheel input. The initial screenshot and JSON were captured before a recovery scroll: `output/chat-manual-fixes/after-12-before-fix.jpg` and `blank-observed-before-recovery.json`.

After the targeted changes, a second reproduction remains: new session → `chat-scroll-fixture` → wheel +12, −12, +100, −80, then a large downward wheel to the tail. The driver stopped on two successive empty visible-ID snapshots before any recovery action. See `final-blank-before-recovery.json` and `.jpg` in the same directory.

## 2. Disappearance root cause

The demonstrated failure is in scroll layout/materialization. Initially, resetting the bound `ScrollPosition` to `.init()` on each starting gesture discarded the native user-position state while the lazy layout was resolving variable-height rows. Removing that write improved the original stress path. It is **a contributor, not a complete root-cause fix**: the final reproduction has `ScrollPosition.Storage.positionedByUser` and still has no visible row IDs. Thus neither an unresolved application ID target nor the forced reset is necessary for every blank.

The remaining failure is localized to the current `ScrollView` / root `LazyVStack` / nested variable-height response structure: the model and projection survive, native document geometry changes sharply during materialization, and the viewport can land in an extent with no visible transcript geometry. The precise internal SwiftUI invalidation mechanism has not been established. This report does not claim otherwise.

## 3. Was state present while blank?

Yes. The original capture had session 0, 30 messages, 6 activities, 24 projected items, zero visible IDs, empty logical reading target, offset 114477, document height 115100 and viewport height 623. Follow was off; the active/latest assistant ID was `pi-EF273C3A-E24F-5929-A526-D75E6D7ABB82`. The transcript and native scroll identities did not change across composer updates.

The final capture had session 1, 2 messages / 23671 characters, 2 projected items, zero visible IDs, offset 9579, document height 10202, viewport 623, native scroller 1.0, follow on, and latest assistant ID `pi-4140A865-04BA-5780-8FBB-A7A24A98413A`. Both screenshots show an empty transcript with the composer and surrounding UI intact. No transcript deletion was observed.

## 4. Exact retained disappearance change

Removed the assignment of a fresh automatic `ScrollPosition` in `.onScrollPhaseChange`. Gesture handling still cancels pending resize restoration, advances the user-scroll generation, clears the pending restoration target and records intentional reading position. Native scrolling owns the position handoff. Added opt-in diagnostic snapshots, including identity, projected/visible IDs, reading target, local follow state, native extent and scroller values. Diagnostic teardown is scoped to its owning view so an old session cannot erase a new session's snapshot.

This mitigates one trigger; disappearance remains unresolved overall.

## 5. Scrollbar-jump root cause

Variable-height lazy estimation changes the document extent without corresponding viewport travel or data growth. In the no-reset control, one 25-point upward step changed document height from 101199 to 106176 and native scroller from 1.000 to approximately 0.953. Subsequent small steps inflated the extent further. The 31 samples span 101199–127221 points with unchanged messages. Native offset steps are small while the native indicator recalculates against the changing extent. The application's logical anchor does not determine the native scrollbar fraction.

A one-line, temporary eager-stack control replayed the same 30-message / 48426-character history. All 31 wheel samples had document height exactly 30046, and the viewport moved by the expected 25 points per step. This isolates estimation/materialization in the lazy layout as a source of the discontinuity. Eager-stack visibility callbacks are not comparable to lazy visibility callbacks; its screenshot was inspected separately.

## 6. Scroll-geometry correction and stop decision

**No complete scroll-geometry correction is retained.** The eager control was reverted before the final build. At 80 synthetic turns it used about 556.5 MiB with a 1.98-second maximum run-loop delay; at 300 turns about 941.8 MiB with a 4.42-second delay. It stabilizes extent at an unacceptable long-history cost. The scrollbar remains visible.

The evidence calls for a separate design of measured-height accounting / bounded materialization, including nested response layout and resize invalidation. It does not prove every possible SwiftUI implementation is incapable of stable geometry. Replacing the entire renderer or adding that larger geometry system exceeds this narrow fix phase, so work stops before that rewrite.

## 7. Previous follow behavior

The preceding implementation disabled following for any eligible upward movement greater than 0.5 points. Downward re-entry required a bottom gap of at most 2 points. The original stress path confirmed a tiny upward movement could disable it. An older 80-point enter band was not restored.

## 8. Final follow hysteresis

Enter at a gap of at most 24 points on downward user movement. Exit only after at least 48 points of accumulated upward travel and at least 48 points of bottom gap. Downward movement clears accumulated upward travel. Layout-only changes do not enter following; native shrink/resize clamping is excluded from upward intent.

In the settled portions of a five-cycle native probe, 12-point nudges retained follow, 100-point upward moves left it, and an 80-point downward return re-entered at a 20-point gap. This gives a practical wheel margin with separate enter/exit bands. Cold lazy extent changes still defeat dependable end-to-end activation: in the final probe, re-entry occurred near the old bottom, then estimated height grew to leave a 3440-point gap. Consequently Bug 2's intent logic is improved but cannot receive unconditional native acceptance until geometry is stable.

## 9. Composer typing / Send findings

The 12-turn final sequence used the real composer `NSTextView.insertText` path for 96 edits, plus the normal submission handler. Across the sequence, transcript identity and native scroll identity each remained constant. All populated samples retained visible row IDs. Generic shell invalidation causes reevaluation, but this run provides no evidence of a typing-triggered remount. No new composer-dependent `.id` or hierarchy workaround was added. The specific typing-only spontaneous disappearance reported by the user was not independently isolated; it must not be declared eliminated.

## 10. Files changed in this phase

- `Sources/Milk/ChatPanel.swift`: preserve native gesture position; verification-only snapshot lifecycle.
- `Sources/Milk/ChatFollowTail.swift`: hysteresis; diagnostic visible IDs and snapshot holder.
- `Sources/Milk/ChatQualityVerification.swift`: native scroller/identity snapshots, actual composer typing, disposable fixed-history replay and correctly positioned wheel events.
- `Tests/MilkWorkspaceTests/ChatQualityTests.swift`: two focused hysteresis / layout-only regressions.
- `Tests/MilkWorkspaceTests/ChatStabilityTests.swift`: use deliberate upward travel in the existing follow regression.
- This report.

All other Phase 1–3 files match their captured starting SHA-256 values. The temporary eager renderer is not retained. Reproduction drivers, screenshots and raw samples are local ignored artifacts under `output/chat-manual-fixes/`.

## 11. Focused tests and build

77 selected tests passed, zero failures: ChatQuality, ChatStability, ChatPresentation, Agent, AgentService, AgentLifecycle, AgentSessionMigration, SlashCommand, PiIntegration, PiParity, PiProviderRouting and PiProviderConsistency. The added regressions cover the enter/exit boundary, tiny accumulated upward input, layout growth and native clamp exclusion. Existing tests cover history/identity, stream buffering, stale events, checkpoints, projection, framing and provider integration. See `final-tests.log`.

The native self-verifier passed prompt/thinking/tools/output, repeated tool IDs and distinct outputs, atomic resume/identity/order, generation-following, intentional reading during streaming, session return, return-to-tail following and disposable-process cleanup. See `native-checks.txt`. The final source rebuilt successfully and its app passed strict deep code-signature verification. The last subsequent source adjustment only scoped diagnostic teardown to the owning view; it was rebuilt and exercised by the final native sequence.

## 12. Native stress results

The final 12-turn run completed with 30 messages and 6 activities. It used mixed short/tool/long responses, 96 actual AppKit composer edits and sequential wheel input. No populated sample in that path lost visible IDs; the final screenshot shows Markdown content. See `final-sequence.log`, `observations-final-native-typing.jsonl`, `final-twelve-turns.json` and `.jpg`.

The separate final cold-session/wheel probe failed visibility and stopped before recovery. See `hysteresis-native-final.json` and `final-blank-before-recovery.json`. Therefore positive stress and unit results do not close chat acceptance. Input was synthetic native mouse-wheel events delivered to the real AppKit scroll view; no physical trackpad coverage is claimed.

## 13. Explicit symptom retest status

| Reported symptom | Retest result |
| --- | --- |
| Transcript disappears | Reproduced before changes and again after targeted changes; unresolved overall. |
| Fragile follow activation | Settled-geometry enter/exit behavior improved and verified; cold-layout reliability remains limited by changing extent. |
| Scrollbar jumps | Reproduced and isolated with native metrics and an eager control; unresolved in retained lazy renderer. |

## 14. Remaining limitations

Blank materialization and scrollbar geometry still require work. Thresholds cannot compensate for a moving estimate of the bottom. The final failing probe deliberately uses a large downward wheel event as a stress step; it does not establish that every ordinary wheel gesture fails. The successful 12-turn path does not establish all real-world Send/typing cases are fixed. No broad rewrite, hidden scrollbar, forced reload recovery loop or eager production renderer was introduced.

## 15. Appearance

No typography, colors, spacing, padding, cards, icons, backgrounds, code, composer, Thinking, Activity or Changed Files styling was intentionally changed. The phase's view diff concerns behavior and opt-in diagnostics only. The final positive screenshot retains existing rendering styles; the unresolved blank viewport is itself a rendering defect.

## 16. Scope preservation

This phase did not change provider/profile/auth architecture, Local authentication, oMLX/sub-key behavior, model/context handling, Pi installation, Git implementation, editor or session deletion. Prior phase changes remain intact.

## 17. Git and completion boundary

Nothing was committed, pushed or merged. Branch remains `fix/chat-rendering-stability`; HEAD remains `24e3d5b24711a00fb3ca0f7601e40cc43b63621f`. The normal user app was not replaced or relaunched during this investigation; verification used a separately identified disposable app. Stop here before substantial renderer work. The three reported symptoms are **not collectively fixed**.
