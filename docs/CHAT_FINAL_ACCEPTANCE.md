# Final chat acceptance

2026-11-01. Starting branch: `fix/chat-rendering-stability`. Expected and verified starting `main` / branch HEAD: `24e3d5b24711a00fb3ca0f7601e40cc43b63621f`.

The user accepted Phase 5 performance, scrolling and appearance, and reported that the disappearing transcript, scrollbar jump and follow-tail symptoms no longer reproduce in normal use.

The accumulated Phase 1–5 source and tests were reviewed against `main`, including new files. Production retains atomic history snapshots/cache reconciliation, deterministic identities, scoped repeated tool ownership, interrupted-response recovery, stale-event guards, stream coalescing, bounded checkpoints, cached projection and background RPC framing/decoding. Its renderer remains `NSScrollView` → explicitly measured native document → bounded nearby SwiftUI hosts. Native scrollbar, logical reading positions, 24/48-point hysteresis, selection/copy and disclosure choices remain intact.

The only remaining eager transcript is the deliberate appearance-comparison reference, reachable through explicit disposable quality-verification commands. It is not an active production renderer. The remaining `LazyVStack` in ChatPanel belongs to the reference-file picker. Diagnostic collection, assertions and fixture commands are opt-in; normal launches use production state without them. Generated evidence is ignored under `output/`; no screenshots, logs, runtime downloads or hard-coded user home paths are included in this change. There are no intentional visual design changes.

Two concrete acceptance defects were corrected:

1. Restored the pre-existing bordered style on the error-card Restart button.
2. The retained native verifier reproduced a 6-point session-return displacement. A provisional native frame could consume the saved reading position as a different-width restore. Initialization now waits for the known pane width. A new native-coordinator regression verifies that a provisional frame cannot consume the saved offset. The native recheck preserved 1383 → 1383 points exactly.

Verification on the final source:

- Clean SwiftPM build and development app signature verification passed.
- Complete Swift suite: **212 tests, zero failures**.
- Focused chat/agent/Pi subset: **82 tests, zero failures**.
- Retained native Pi/chat verifier passed history identity/order, repeated tool ownership/output, native resume, intentional reading during streaming, session return and renewed following.
- Phase 5 native geometry verifier passed twelve mixed prompts, typing, long response, 80/300/800-turn histories, proportional wheel/scrollbar movement, bounded materialization, follow re-entry, resize, sidebar, keyboard and session checks, including streaming while reading above.
- `python3 scripts/verify-runtime.py` passed local pinned-runtime / notice checks.
- `git diff --check` passed. Disposable Pi processes and temporary state were cleaned up.

Evidence is local under `output/chat-acceptance/` and the geometry driver's `output/chat-phase5/`. The initially failing native run is preserved alongside its passing recheck. The documented synthetic distinct-text cold-measurement cost remains accepted and was not optimized further.

Provider/profile/authentication, Local/oMLX/Keychain, model/context policy, installation and session-deletion implementation were not changed. Existing full-suite tests exercised their own disposable fixtures; real Pi profiles and production Milk state were not used. No version, tag, push, release, notarization, stapling or clean-machine qualification belongs to this acceptance phase.

After these checks, the complete branch is to be committed as `Stabilize chat rendering, scrolling and session restoration` and fast-forwarded into local `main`, retaining the feature branch without rewriting history.
