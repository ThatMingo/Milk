# Milk — Foundation validation

Date: 2026-10-29. Local development and execution used this Mac, Xcode 26.6/Swift 6.3.3/macOS SDK 26.5, and the existing Pi 1.4.0 installation.

## Repeatable checks

```sh
./Scripts/build.sh
./Scripts/test.sh

# Explicit local language-server check, separate from the mock-based core suite:
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer MILK_TEST_LSP=1 \
  swift test --filter sourceKitInitialization

# Explicit real model/provider validation; creates disposable test-workspace sessions:
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run MilkProbe --live
```

Tests cover every split of UTF-8 JSONL records, Unicode separators, malformed/oversized/incomplete frames, out-of-order request correlation, cancellation/deadlines, process exit, independent clients, workspace persistence/reopen/schema compatibility, Git status/rename parsing, approval scopes, extension manifests/grants, LSP framing, Tree-sitter highlighting, document conflicts, shared undo/redo, preview routing, and GitHub remote detection. Node tests exercise the actual companion's denial, once/session grants, shutdown reset, Autonomous mode, absent UI, and direct bash behavior.

## Real Pi/provider validation

The live probe used the same MilkCore discovery/process/RPC code as the application and reported:

- Pi version: 1.4.0.
- Actual provider: `omlx`.
- Actual model: `Qwen3.8-27B-pi-oQ8e-mtp`.
- Streamed `MILK_LIVE_OK` in six text deltas.
- Created a second process with a distinct session identity and empty history.
- Aborted real generation after streamed deltas and confirmed Pi was idle.
- Shut down both processes, reopened the exact saved first session, recovered its history, and streamed `MILK_RESUMED_OK`.

No direct oMLX inference request was made by Milk or by a substitute model client.

## Native application checks

The actual built `.app` was launched and operated through native UI:

- Open Folder used the native folder picker and a disposable Git repository.
- Native composer submission produced `MILK_NATIVE_UI_OK` through the actual Pi/provider/model path.
- Native status displayed the provider/model from Pi state.
- A second tab was created and generation was stopped from the native Stop button.
- Approval mode displayed a pending `write` request while its target file did not exist. Deny produced a failed tool result; the target remained absent.
- Sustained streaming past the long-message threshold stayed responsive after moving long text to TextKit viewports and batching UI updates.
- A real file opened in TextKit 2; split panes shared edits and unsaved state.
- Git branch and the disposable repository's modified file appeared in Changes.
- SwiftTerm launched the user's shell in the selected workspace.
- The internal extension sample returned “JavaScript ran in the isolated XPC service.”

Final checks also verified native quit and relaunch with the intended workspace, both session associations, saved Pi history, editor paths/split state and terminal visibility restored without prompt replay. A command entered into the integrated PTY wrote its actual workspace cwd to a disposable fixture file. A dirty-file external change produced the native conflict controls, and Reload Disk synchronized both panes.

WebKit displayed the HTML fixture's “Milk preview works” heading. The native Markdown provider displayed the Markdown fixture. The explicit local SourceKit-LSP initialization test passed independently of the model tests.

Visual editor validation caught a line-number ruler painting outside its own bounds. Explicit clipping fixed the blank source rendering, and a bitmap regression test now protects source text outside the gutter. Split-pane representables are keyed by document identity to prevent stale coordinators when changing file tabs.

## Configuration preservation observation

Milk does not write Pi/oMLX configuration. Hashes before/after the first successful live test confirmed unchanged Pi settings, Pi model configuration, and oMLX global settings. The separate oMLX `model_settings.json` file changed during the wider test window (mtime 15:53:28), so a byte-for-byte unchanged claim for that file cannot be made. Milk has no write path to it; its changes were not reverted or reconstructed. No credential values are included in this record.

## Recoverable environment issues resolved

- SwiftPM's stalled Sparkle artifact download was recovered using the exact upstream archive; SHA-256 matched the pinned manifest checksum.
- Xcode's optional Metal Toolchain 17F109 was installed because SwiftTerm's native package contains Metal resources.
- Pipe reads were corrected to deliver available bytes immediately instead of delaying small long-lived RPC records.
- Swift 6 isolation/type errors and a native file-row selection problem were fixed.
- Long SwiftUI response drawing was replaced by viewport-based rendering for large messages.

Debug builds are locally signed. Developer ID signing/notarization and a live updater feed have not been validated and do not block local development.

## Final automated result

The final Xcode Debug app/XPC build succeeded. All 18 Swift tests passed with the explicit SourceKit-LSP check enabled, and all three Node companion tests passed. The default suite skips that opt-in language-server test. The model-dependent probe is separate and is never required by the automated suite.
