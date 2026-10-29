# Milk — Technical Requirements

## Local environment

Primary development/runtime target:

- local Mac
- macOS 26.0+
- Apple Silicon
- Xcode / current macOS SDK
- Swift

Codex must verify the actual local environment rather than assume paths or versions.

## Pi discovery

Milk must use the user's existing Pi installation.

Support:

- automatic discovery
- common executable locations / user environment
- manual selection if needed
- version validation
- diagnostics

Milk should not silently install or replace Pi.

## Pi integration

Use Pi's supported programmatic/RPC interface.

Codex must verify the installed Pi version and actual local RPC contract before finalizing the implementation.

Keep Pi transport isolated from UI code.

Conceptual structure:

```text
PiProcess
  ↓
PiTransport
  ↓
PiClient
  ↓
PiSessionController
  ↓
Milk UI
```

Expected concerns:

- process lifecycle
- async stdin/stdout/stderr
- structured framing
- request/response correlation
- streaming events
- cancellation
- graceful shutdown
- crash detection
- restart/recovery
- diagnostics
- independent sessions

Be careful that GUI apps may have a different PATH/environment than Terminal.

## Persistence

Persist Milk-owned state such as:

- recent workspaces
- folder access/bookmarks
- window/panel state
- workspace UI state
- editor state
- session associations
- extension configuration
- preferences

Avoid unnecessarily duplicating Pi-owned session history.

## Filesystem

Use appropriate native macOS folder-access mechanisms.

Observe external changes.

Design for Pi editing files while Milk has them open.

## Concurrency

Use Swift concurrency.

Prefer:

- actors for shared mutable services
- structured concurrency
- AsyncSequence for streams
- MainActor only for UI state

Keep expensive work off the main thread:

- Pi/process I/O
- Git
- file enumeration
- search
- diffing
- LSP
- extension IPC
- heavy parsing/highlighting

## Editor

Use AppKit/TextKit where SwiftUI alone is insufficient.

Separate:

- text rendering/editing
- file state
- syntax highlighting
- editor commands
- filesystem synchronization
- language intelligence

## Language services

Design a general LSP layer.

Use SourceKit-LSP for Swift where appropriate.

## Git

Prefer system Git behind a service abstraction unless there is a strong reason not to.

Git operations must be asynchronous.

## GitHub

Keep local Git independent of GitHub.

Prefer existing secure authentication such as an authenticated `gh` session when practical.

## Preview

Prefer native frameworks such as:

- WKWebView
- PDFKit
- native image APIs

Design previews so new providers can be added later.

## Terminal

Do not casually build a terminal emulator from scratch.

Evaluate a maintained native-compatible approach.

## Updates

Use a proven direct-distribution updater mechanism.

Sparkle is an acceptable candidate, subject to verification.

## Distribution

Support:

- native `.app`
- Developer ID signing
- notarization
- direct distribution

## Testing

Automated tests must not require the real Qwen model.

Use mocks for Pi process/RPC integration tests.

Use the real Pi/oMLX/Qwen stack for explicit end-to-end validation.
