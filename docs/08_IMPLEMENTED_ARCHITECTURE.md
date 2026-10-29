# Milk — Implemented Foundation

Status: native foundation implemented on 2026-10-29. This is an implementation record, not a claim that the full feature roadmap is complete. Documents 01–07 remain the product requirements.

## Build and ownership

`Milk.xcodeproj` builds the arm64 macOS 26+ SwiftUI application and its sandboxed `MilkExtensionHost.xpc`. The root Swift package contains `MilkCore`, `MilkKit`, automated tests, and the explicit `MilkProbe` live validator. The committed Xcode project is sufficient to build; Ruby/xcodeproj is needed only when regenerating it.

Use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. The global developer directory is not changed. Debug builds use local ad-hoc signing. Release configuration enables Developer ID signing and Hardened Runtime; release credentials are not part of the repository.

| Owner | Implemented responsibilities |
|---|---|
| `MilkModel` | Workspace selection/restoration, native shell service composition, sessions, file/Git refresh, persistence coordination, coordinated shutdown |
| `WorkspaceStore` | Core Data SQLite store containing versioned Milk metadata, folder bookmarks, session associations, open editor paths, selected document, panel flags |
| `ChildProcess` | Subprocess lifetime, dedicated pipe readers/writer, exit delivery after stream draining, bounded shutdown support |
| `PiClient` | Byte-based JSONL framing, request IDs, deadlines/cancellation, event stream, queue clearing, abort and shutdown |
| `PiSessionController` | One process per conversation, transcript projection, bridge readiness, native extension dialogs, model/provider state, streaming UI batching |
| `DocumentBuffer` / `EditorController` | Shared TextKit 2 content, native undo manager with document-owned transactions, tabs/splits, disk baselines, external edit detection, save conflict checks |
| `HighlightingService` | Background Tree-sitter JSON parsing and a lexical fallback for other source files; independent of LSP |
| `LanguageServerClient` / manager | General LSP framing and process transport, initialization, requests/notifications, SourceKit-LSP connection, document synchronization and hover hooks |
| `FileService` / watcher / search | Background file enumeration and I/O, native filesystem operations, FSEvents observation, cancellable ripgrep search |
| `GitService` | System Git abstraction, repository/branch/status, staged/unstaged changes, diffs, stage/unstage, remotes |
| `GitHubService` | GitHub remote parsing, optional authenticated gh adapter, native HTTP adapter, Keychain credentials, repository/PR/issues/Actions endpoints, device-auth configuration points |
| `TerminalController` | SwiftTerm AppKit view and independent PTY shell, workspace cwd, terminal resize/input/output through SwiftTerm, termination on workspace close/quit |
| Preview registry | HTML/localhost/SVG through WebKit, native Markdown, images, PDFKit, JSON/text providers |
| Extension registry/client/host | Validated manifests, versioned envelopes, permission grants, atomic registry persistence, sandboxed XPC JavaScriptCore evaluation, bounded output and runaway-JS watchdog |
| `UpdateService` | Sparkle 2 wiring, preferences, explicit unavailable state until feed/public key are configured |

UI state is MainActor-owned. Process I/O, file I/O, Git, search, parsing, and protocol work use actors/background queues. Long streamed responses use bounded-height TextKit viewports rather than enormous SwiftUI text layouts.

## Pi runtime and permissions

The sole normal model path is:

```text
Milk → existing Pi 1.4.0 executable in RPC mode
     → existing Pi configuration → existing oMLX provider → configured model
```

Milk does not have an oMLX model client, copy provider credentials, or create model/provider configuration. Discovery resolves Pi and Node through the child PATH and supports an executable preference. Current compatibility validation is intentionally Pi 1.4.0, rather than assuming an untested version is compatible.

New tabs receive distinct session UUIDs and processes. Resume uses the exact saved Pi session file. Milk stores references, not a second transcript database. Opening a restored session loads history without replaying prompts. Files remain shared between sessions in one workspace.

The bundled `milk-companion.mjs` is passed using Pi's explicit extension flag. It is not installed into the user's Pi directory. Read-only built-ins pass; other tool calls pause before execution in Approval mode. Direct Pi shell execution also passes through `user_bash`. Exact-action session grants live only in the Pi process.

**Implementation refinement from the plan:** the companion uses Pi's existing RPC `select` dialogs and a non-model readiness command/status acknowledgement. A second Unix socket protocol is unnecessary for this foundation. Milk refuses normal prompting until the companion acknowledges the requested mode. Mode changes stop/relaunch the process at idle, clearing grants. Stop cancels pending dialogs, clears queued work, and aborts. `agent_settled`, not `agent_end`, drives final idle state.

Project trust is a separate native decision when protected project resources are present. Milk stores its own decision and passes a process-local trust flag; it does not edit Pi's trust/configuration files. Existing Pi extensions still run with Pi's user-level authority; the gate is workflow protection, not an OS sandbox.

Supported extension dialogs, text widgets/status, composer changes, and notifications are bridged. Pi's custom terminal components cannot be reproduced through its current RPC contract.

## Editor and filesystem behavior

Each open file has one authoritative `DocumentBuffer` and content store. Each split pane uses its own native TextKit 2 view/content projection, synchronized by document revision while preserving its independent selection. Document-owned undo transactions operate on the shared canonical content. UTF-8 files are the initial supported editing format. External changes reload clean buffers; dirty buffers preserve the working text and expose compare/reload/keep choices. Saves recheck the baseline and use atomic writes.

FSEvents are notifications, not locks. Pi and other editors do not participate in Milk's coordination; there remains a narrow concurrent-write race between a disk-baseline check and atomic replacement. Stronger merge/versioning behavior remains required before claiming lossless collaboration in every race.

## Extension isolation and security

The app does not load arbitrary native plugin code. The bundled XPC service has App Sandbox and JavaScriptCore JIT entitlements, without general workspace/network permissions. It receives source bytes and returns JSON. The internal sample demonstrates actual execution across this boundary.

The registry denies ungranted permissions and disables incompatible manifests. The current host exposes computation and declarative results only; general workspace/network/process capability brokers and the public extension SDK remain unfinished. A three-second watchdog terminates the helper for runaway JavaScript. A helper failure is reported through XPC without terminating Milk.

Milk-owned credentials use Keychain. No telemetry is implemented. Raw subprocess stderr, prompts, provider credentials, and file contents are not written to normal application logs. Static file previews disable JavaScript and block HTTP subresources; interactive URL previews have no privileged native bridge.

## Dependencies and distribution

Direct dependencies are exact-pinned in Package.swift; transitive revisions are committed in Package.resolved and Xcode's resolution file. They include SwiftTreeSitter 0.25.0, TreeSitterJSON 0.24.8, LanguageServerProtocol 0.14.2, JSONRPC 0.9.2, Swift Markdown 0.9.0, SwiftTerm 1.20.0, and Sparkle 2.10.1. STTextView is not used.

System Git and installed ripgrep are used during development. Distribution still needs bundled tool fallbacks and license/source materials. Native GitHub sign-in needs a registered client ID; public repository access and the service layer do not require registration. Sparkle remains inactive until a valid HTTPS feed and public key are supplied.

`Configuration/Release.xcconfig`, export options, entitlements, and `Scripts/release.sh` establish archive/export/notarize/staple/verify structure. Final credentials, appcast hosting/signing, DMG packaging, and clean-machine release validation remain release work.

## Remaining feature work

The foundation is usable but is not a finished full editor or a finished Git client. Advanced multicursor commands, folding presentation, completion/navigation/code-action UI, full Git mutation/history/conflict workflows, side-by-side diffs, full GitHub workflows, extension installation/update UX and capability brokers, image attachments, complete Markdown chat rendering, crash recovery drafts, large-repository/performance hardening, and release onboarding remain on the product roadmap.

The file browser currently uses native SwiftUI outline/list controls with bounded initial enumeration. Deeper lazy expansion, complete file-operation UI, configurable search filters, and exact-result navigation need further work. Language server lifecycle/framing is real; full document/version recovery after a server crash is not yet implemented.
