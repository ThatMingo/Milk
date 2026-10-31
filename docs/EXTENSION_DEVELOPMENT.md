# Milk Extension development — API 1

This guide describes MilkExtensionKit API 1 in Milk 0.7.0. The authoritative public sources are [`MilkExtensionKit`](../Packages/MilkExtensionKit/Sources/MilkExtensionKit/). The separately built [`OMLXStatusExample`](../Examples/Extensions/OMLXStatusExample/) is a complete working extension.

The historical extension implementation’s “Phase 7” is separate from the completed
Agent Refactor acceptance. API 1 is the current extension contract.

> **Milk extensions NEVER patch or modify Milk source code.** Do not edit `MainWindow.swift`, sidebar, Settings, toolbar source, core enums, upstream Pi source, or any other Milk application source to implement or install an extension. All integration uses MilkExtensionKit contribution APIs. If an extension point is missing, stop and extend MilkExtensionKit/core intentionally first; do not patch around it from the extension.

# Instructions for AI Agents

These instructions apply to Codex, Claude Code, Pi/Qwen and other coding agents receiving this guide and the Milk source.

1. Read `Packages/MilkExtensionKit/Sources/MilkExtensionKit/ExtensionAPI.swift` and `ExtensionUI.swift` before coding. Treat their signatures as authoritative.
2. Read `Examples/Extensions/OMLXStatusExample/OMLXStatusExample.swift`, its manifest and build script.
3. Create the extension in its own directory. Never patch Milk core to install it.
4. Integrate only through `context.contributions`; use the existing host registries.
5. Choose a permanent reverse-DNS extension ID and stable local contribution IDs. Milk namespaces local IDs under the owner; slash names are globally collision-checked.
6. Declare only real manifest capabilities used by the extension; handle unavailable optional service facades.
7. Store mutable state with scoped storage and secrets with scoped Keychain.
8. Launch subprocesses through `context.processes`, and cooperate with service cancellation.
9. Preserve Light/Dark/System using public semantic UI values.
10. Never hardcode Milk internal/support paths; use context services and packaged resources.
11. Never create a parallel sidebar, layout engine or Settings system.
12. Never bypass Pi or host action approval.
13. Do not invent metadata fields, lifecycle hooks, capabilities or SDK methods.
14. Build the package and run focused extension tests; use the checklist below.
15. Verify disable/uninstall withdraw contributions, stop managed work and preserve/remove data as requested.
16. If the SDK cannot implement the requested behavior, report the missing extension point and stop that part. Do not modify Milk source as a workaround.

## Architecture and choosing a resource

```text
Milk.app
├── Milk core (shell, sessions, approval, layout, lifecycle)
├── MilkExtensionKit (public shared native SDK)
└── user-installed .milkext packages (stored outside the app)
```

| Resource | Use it for |
| --- | --- |
| Native Swift Milk Extension | Native SwiftUI destinations, panels, Settings, controlled UI actions and managed backend services |
| Pi Extension | Pi runtime behavior written against Pi's own extension API; not native Milk UI |
| Pi tool | Model-callable structured operation; a native extension can supply one through the bridge |
| Pi slash command | Explicit user action registered by a Pi resource; discovered by RPC `get_commands` |
| Prompt resource | Reusable prompt text; Pi templates and native bridge prompt resources have different delivery mechanisms |
| Skill | Pi-discovered task instructions/resources, invoked using Pi's supported skill mechanism |

Choose native Milk for host UI; choose Pi resources for agent-only behavior. A native `command` is local Milk dispatch; a native `piCommand` also supplies a model-callable bridge tool. Neither requires editing upstream Pi.

## Boundaries and terminology

A **Milk Extension** is a native `.milkext` macOS bundle linked dynamically to MilkExtensionKit. Its UI is SwiftUI, with AppKit usable through native representables. A **Pi Extension** is a separate resource loaded by vanilla Pi. Milk presents both in Extensions, but does not convert one into the other.

Extensions register through the supplied context. They must never patch Milk Swift files, sidebar definitions, Settings source, toolbar source, `MilkPiIntegration.ts`, or upstream Pi. Installing an extension never rebuilds Milk. A missing contribution point requires a deliberate Milk API addition; it is not permission to modify source from an installer.

MilkExtensionKit is a separate Swift package and dynamic library. Milk links its product dynamically, ships one runtime copy in `Contents/Frameworks`, and ships an author SDK in `Contents/Resources/ExtensionSDK`. Do not statically compile a second copy of the SDK into an extension. The host implementation module, MilkExtensionHost, is not an extension-facing SDK.

## Trust model

Native extensions execute **inside Milk with Milk's process privileges**. Capabilities constrain supported host services; they do not sandbox malicious Swift, Foundation, AppKit, or C code. A native crash, memory corruption, or code that blocks the main thread can crash or freeze Milk. Recoverable Swift lifecycle errors can be reported and disabled; arbitrary crashes cannot be isolated.

Installation displays a warning about native executable code, the signature state, all requested capabilities, and the package fingerprint. Update displays newly requested capabilities separately. Unsigned and ad-hoc signed local packages are permitted after explicit trust. A valid developer signature is reported with its team identifier when available; Milk does not yet approve publishers or run a marketplace.

The reviewed fingerprint covers relative entry names, types, POSIX permissions, explicit lengths, and executable/resource bytes using SHA-256. It survives package relocation, including macOS `/var` aliases. It is an integrity check, not a signature or proof that a publisher is trustworthy. Milk verifies installed packages before activation and observes installed-code changes. Modified packages are disabled and require review/re-trust. Unchanged trusted packages do not prompt every launch.

## Package format

A `.milkext` is a native directory bundle, not a ZIP or an arbitrary script:

```text
MyExtension.milkext/
└── Contents/
    ├── Info.plist
    ├── MacOS/
    │   └── MyExtension
    └── Resources/
        ├── manifest.json
        └── ... optional resources
```

The manifest is under `Contents/Resources` so ordinary macOS bundle signing can seal it. A top-level manifest is not the API 1 format.

The current host accepts arm64 Mach-O **MH_BUNDLE** executables for macOS 26+. It rejects missing/non-executable entries, script executables, symlinks, hard-linked files, special files, over 10,000 entries, or packages over 128 MB. Manifests and Info.plist are limited to 64 KB each. Fat/universal and Intel packages are not supported in API 1's current host.

### Manifest

```json
{
  "id": "com.example.status",
  "name": "Status",
  "version": "1.0.0",
  "milkApi": "1",
  "minimumMilkVersion": "0.7.0",
  "principalClass": "StatusExtension.StatusExtension",
  "executable": "MyExtension",
  "capabilities": ["network", "keychain"],
  "author": "Example",
  "description": "A native status destination",
  "icon": "Icon.png",
  "update": "https://example.com/future-update-metadata.json"
}
```

`id` must be a lowercase reverse-DNS identifier with at least three components. IDs are unique, and lowercase avoids filesystem case collisions. Versions use semantic version precedence, including prereleases. `milkApi` must be exactly `"1"`; an unsupported API or a minimum Milk version above the host is rejected before loading code.

`author`, `description`, `icon`, and `update` are optional. `icon` is a contained resource path and must exist when declared. `update` reserves metadata for future tooling; Milk does not fetch it or infer online updates. The current list uses the native Milk Extension type icon.

Info.plist must declare:

```xml
<key>CFBundleIdentifier</key><string>com.example.status</string>
<key>CFBundleName</key><string>Status</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleExecutable</key><string>MyExtension</string>
<key>NSPrincipalClass</key><string>StatusExtension.StatusExtension</string>
```

Identity, executable and principal class must match the manifest. Use the exact Swift `Module.Class` name of a public subclass. Milk resolves the declared class explicitly and checks that it comes from the inspected bundle; it does not accept Foundation's fallback principal class.

## Build a native extension

Milk's build does not build or enable the example automatically. From the repository root:

```sh
./scripts/build.sh
./Examples/Extensions/OMLXStatusExample/build.sh
```

The result is `Examples/Extensions/OMLXStatusExample/build/OMLXStatusExample.milkext`.
Neither build requires Pi runtime fixtures. See [developer setup](DEVELOPMENT.md)
for toolchain requirements and the separate optional fixtures used by real-Pi
integration tests. Pi-backed extension features require a compatible runtime
selected through Settings → Agents; do not copy Pi into Milk.app.

An external author can compile against the packaged SDK without a Milk source checkout:

```sh
export MILK_EXTENSION_SDK="/Applications/Milk.app/Contents/Resources/ExtensionSDK"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx26.0 \
  -parse-as-library -emit-library -Xlinker -bundle \
  -module-name StatusExtension \
  -I "$MILK_EXTENSION_SDK/Modules" -L "$MILK_EXTENSION_SDK" \
  -lMilkExtensionKit StatusExtension.swift \
  -o MyExtension.milkext/Contents/MacOS/MyExtension
codesign --force --sign - MyExtension.milkext
```

Create the manifest, Info.plist and Resources first. Do not embed MilkExtensionKit in the extension. The binary references `@rpath/libMilkExtensionKit.dylib`, which Milk resolves to its shared library. The packaged SDK includes textual Swift interfaces built with library evolution enabled. API version checks are required in addition to Swift ABI compatibility; compatibility with every future compiler has not been established.

For the example, `MILK_EXTENSION_SDK` can point at the shipped SDK. `MILK_EXAMPLE_VERSION=1.1.0` builds update fixtures without modifying source. The example's script accepts an optional output bundle path.

## Lifecycle and context

```swift
import SwiftUI
import MilkExtensionKit

@MainActor
public final class StatusExtension: MilkExtension {
    public override func activate(context: any ExtensionContext) async throws {
        try context.contributions.sidebar(.init(
            id: "status", title: "Status", systemImage: "server.rack"
        ) { _ in
            AnyView(Text("Native extension content"))
        })
        try context.contributions.command(.init(
            name: "status", summary: "Open Status"
        ) { _ in
            try context.focusSidebar("status")
        })
    }

    public override func deactivate() async {
        // Release extension-owned references and cooperative custom work.
        // Milk removes registrations and cancels managed services independently.
    }
}
```

The inherited required initializer is available automatically unless you introduce your own designated initialization. A principal needs a no-argument initializer.

All UI, registration and service interfaces are `@MainActor`. Network and process operations are asynchronous. Do not block the main actor with synchronous polling, unbounded computation or waits. Activation has a recoverable 10-second asynchronous deadline and deactivation a 2-second deadline. These deadlines cannot preempt synchronous native code.

`ExtensionContext` exposes the extension ID, granted capability set, contributions, namespaced storage, optional gated service interfaces, `focusSidebar(_:)`, and `reportProblem(_:)`. It exposes no Milk implementation objects. A recoverable reported runtime problem disables the owning extension. Retained contexts and service facades reject operations after revocation; retaining a token does not keep a contribution alive.

## Contribution registry

Each method below registers under the current extension ID. Milk owns removal even when the extension forgets to unregister.

| Registration | Value and behavior |
| --- | --- |
| `sidebar(_:)` | `ExtensionViewContribution`; icon, title, optional badge, lazy native content |
| `panel(_:)` | Same value; participates in the existing recursive workspace layout |
| `settings(_:)` | Same value; a category in the existing Settings takeover |
| `status(_:)` | Same value; compact native status item, priority ordered |
| `view(at:_:)` | Lazy native controls in an explicit existing-screen slot |
| `action(at:_:)` | `ExtensionActionContribution`; title/icon and async contextual handler |
| `command(_:)` | `ExtensionCommand`; native slash autocomplete and dispatch |
| `piTool(_:)` | `ExtensionPiTool`; capability-gated Pi bridge tool |
| `piCommand(_:)` | A slash command plus a model-callable Pi command tool; requires `pi` |
| `prompt(id:text:)` | A namespaced Pi prompt resource; requires `pi` |
| `service(_:)` | `ExtensionBackgroundService`; a cancellable host-owned task |
| `remove(_:)` | Explicitly withdraw a returned token early |

View content factories take an `ExtensionActionContext` snapshot and return `AnyView`. Context contains the current workspace URL, a file URL where applicable, and message/selection text where applicable. Do not infer internal objects or mutate a view tree.

Identifiers look like `extension:com.example.status/sidebar:status` or `extension:com.example.status/panel:notes`. Local IDs begin with an ASCII letter and contain letters, digits, `_`, or `-` (maximum 100 characters). A duplicate in the same contribution namespace throws. The host limits an extension to 100 total registrations. Slash names additionally cannot collide with core, Pi, or another native extension's commands. Newly discovered Pi collisions disable the conflicting native owner with a diagnostic. Pi tool names are also checked after normalization.

### Sidebar

Register with `sidebar`, then use `context.focusSidebar("status")` to select your own destination. Core Files, Sessions and Git destinations remain. Removing a selected destination switches safely to Files. The normal collapsed sidebar and badge behavior remain available. Titles/icons and IDs are independent.

### Workspace panels

`ExtensionViewContribution.minimumSize` controls the panel minimum; allowed dimensions are 180–2000 points wide and 100–2000 points high. `topbar` controls whether a visibility toggle is shown in the workspace toolbar. Extension panels appear in Layout Edit assignment/split/drag choices and use the same resizing and persistence as core panels.

Layout Codable values store stable panel IDs. Missing/disabled panel leaves are pruned from the **rendered** tree, without destroying their saved placement. Returning the registration restores the panel where the current saved tree still references it. If the user resets or edits away that tree, restoration is not guaranteed. There is no second extension layout engine.

### Existing-screen injection points

| Swift enum case | Stable point | Context |
| --- | --- | --- |
| `workspaceToolbar` | `workspace.toolbar` | Workspace/current file |
| `chatToolbar` | `chat.toolbar` | Workspace |
| `chatMessageActions` | `chat.messageActions` | Assistant response text |
| `composerLeading` | `composer.leadingActions` | Workspace/current file |
| `composerTrailing` | `composer.trailingActions` | Workspace/current file |
| `codeToolbar` | `code.toolbar` | Workspace/current file |
| `codeContextMenu` | `code.contextMenu` | Editor file and native selected text; tab menus supply file |
| `fileContextMenu` | `file.contextMenu` | Explorer entry |
| `gitToolbar` | `git.toolbar` | Workspace |
| `gitFileActions` | `git.fileActions` | Changed file |
| `previewToolbar` | `preview.toolbar` | Workspace |
| `terminalToolbar` | `terminal.toolbar` | Workspace |

Toolbars/composer/message slots accept view and action registrations. The three context-menu locations accept **actions**, not arbitrary view factories. The native AppKit editor appends active registered actions to its existing menu. Toolbar slots display at most eight views and eight actions per location to protect core controls.

### Settings, theme, and status

Use `ExtensionTheme` semantic text, secondary text, surface, selected, hover, separator, and accent values. Text and surfaces resolve through native appearance; accent is always Milk orange `#FF4D00`, independent of the macOS user accent. `ExtensionSettingsRow`, `ExtensionSettingsSection`, `ExtensionStatusBadge`, `ExtensionEmptyState`, and `ExtensionButtonStyle` are the small public UI surface. Respect the user's System/Light/Dark setting; do not set `NSApp.appearance` from extension code.

Settings pages are lazy factories. Persist settings through `context.storage`; put secrets in `context.secrets`. Milk removes a selected Settings category by switching to General.

Keep status views concise. Milk allows two status registrations per extension and displays the first four overall by priority, with a 200-point maximum width each. Your content may conditionally show nothing, as the example does by default. Avoid expensive view construction and start polling through a managed service rather than every view instance.

## Capabilities and services

A service property is `nil` unless its corresponding capability was granted. Each operation also checks the specific permission and active lease. API 1 requests the full declared set on installation; there is no partial-grant UI. Newly requested permissions must be accepted during update.

| Capability | Supported interface |
| --- | --- |
| `workspace.read` | `workspace.url`, bounded file reads, workspace/file-change observation |
| `workspace.write` | Workspace file writes through Milk approval policy; observation and workspace URL |
| `network` | Generic ephemeral HTTP(S) `network.data(for:)`; no Milk credentials/cookies |
| `shell` | `processes.launch(executable:arguments:workspaceScoped:)`, `stop(_:)` |
| `git.read` | Fixed read-only Git operations through `git.run(arguments:writing:)` |
| `git.write` | Arbitrary Git arguments through the same method with approval |
| `pi` | Tools, Pi commands, prompt resources |
| `keychain` | Namespaced `secrets.read(_:)`, `write(_:for:)` |
| `clipboard.read` / `clipboard.write` | Corresponding clipboard operation |
| `notifications` | Local notifications, also subject to macOS authorization |

Storage needs no extra capability: `read(_:)`, `write(_:to:)`, and `remove(_:)` use contained relative paths under this extension's data directory. Reads/writes are limited to 8 MB per stored file. `workspace.read` is limited to 8 MB per file. Traversal and symlink escape are rejected. Workspace observation fires for workspace changes and the existing file-change stream; it is not an event-by-event filesystem log.

Network supports HTTP(S) without credentials embedded in URLs, an ephemeral session, 15-second request/30-second resource defaults and a 16 MB response acceptance limit. Disable cancels the session. Keep tokens in Keychain and apply them to your own requests. Keychain service names are `dev.milk.extension.<extensionID>`. Extensions receive no API for Milk's provider secrets or another extension's service.

Read-only Git accepts exactly `status --porcelain=v1 --branch`, `diff --no-ext-diff --no-textconv`, or `log -20 --oneline`. Other operations require `git.write`, `writing: true`, and approval. Git runs with a 30-second limit and bounded output, through the same owned process host.

### Background services and process ownership

```swift
try context.contributions.service(.init(id: "poll", workspaceScoped: false) { _ in
    while !Task.isCancelled {
        // await network service, update a @MainActor ObservableObject
        try await Task.sleep(nanoseconds: 15_000_000_000)
    }
})
```

Services receive cancellation on disable, uninstall and quit. Workspace-scoped services receive their workspace URL, cancel on departure, and start for the next workspace. Cooperate with cancellation, including inside loops. Retained host services check task cancellation and revocation. Milk cannot preempt arbitrary custom native tasks that ignore cancellation.

Use the process service for subprocesses. Milk records extension owner, PID/group and workspace scope, starts a fresh group with closed inherited descriptors and a minimal environment, and stops only those owned groups. A reaper keeps the leader unreaped while bounded TERM/KILL cleanup runs, preventing PID/group reuse. It does not kill by port, process name or cwd. Workspace changes stop workspace-scoped processes; disable/uninstall/quit stop all managed processes for the owner. Daemonizing or deliberately escaping the owned process group is unsupported. Generic launch discards stdout/stderr in API 1; it is not an interactive terminal or streaming-output API.

File writes, shell launches and Git writes pass through Milk's permission policy and composer approval model. Approval uses the originating Pi session where applicable. In the app, those operations require an available workspace/session for the approval flow; a missing policy fails closed. Autonomous session policy permits supported actions without a prompt. Installation trust alone does not bypass action approvals.

## Pi bridge

No extension author writes TypeScript or patches Pi. Milk's protected `MilkPiIntegration.ts` reads a host-owned active catalog and registers native tools via Pi's documented APIs. Catalog updates withdraw tools using Pi 1.4's `hidden` exposure and refresh before tool calls. The bridge uses the existing RPC extension-UI transport to call Swift handlers; it is not a JavaScript UI runtime.

`ExtensionPiTool` contains a local ID, description, object JSON Schema as `Data`, required capabilities, and an async handler taking JSON argument `Data` plus contextual values. Required capabilities must be a subset of granted permissions. JSON schemas are limited to 64 KB. Tool names become `milk_<normalized-extension-id>_<normalized-local-id>`; normalized collisions are rejected.

Native tools still pass Pi's ordinary Milk approval gate. The Swift bridge independently applies the host's originating-session policy before executing any native handler. A stale bridge request after disable is rejected even before Pi's catalog watcher has run. No weaker file/shell tool route is introduced. Approval mode may therefore show both Pi's tool approval and the host's native-action approval.

`piCommand(_:)` adds a native Milk slash command and a model-callable command tool with an `arguments` string. Milk dispatches its slash form locally; Pi can call the bridged tool. API 1 does not attempt to dynamically unregister Pi slash commands, which vanilla Pi cannot do. Independent Pi extension slash commands still come from `get_commands` and remain separate in autocomplete.

`prompt(id:text:)` exposes namespaced prompt text through the active `milk_native_prompt_resource` bridge tool. It does not write into Pi's prompt directories. Disabled owners disappear from the catalog. The required Milk Pi integration stays protected and non-removable. Ordinary Pi extension management retains its existing new-runtime/reconnect semantics.

## Install, enable, update, removal

The Extensions takeover supports `.milkext` drag/drop, Install Extension file selection, and file-open handling. Inspection happens without calling `Bundle.load` or resolving native classes. Duplicate IDs require the explicit Update action in Details. Cards remain selection-only; native Enable/Disable, Update, Uninstall, Reveal and diagnostics are in the right inspector.

Milk stores user extensions outside the signed app:

```text
Application Support/Milk/
├── Extensions/<extensionID>/
│   ├── state.json
│   └── versions/<fingerprint>.milkext/
├── ExtensionData/<extensionID>/
├── ExtensionStaging/
└── ExtensionBridge/catalog.json
```

Installation rechecks the reviewed fingerprint, copies to staging, inspects the copy, moves it into immutable version storage and atomically writes `state.json`. Only then may activation load code. User data is separate. Temporary staged data is removed on a normal failure; an interrupted process can leave an unreferenced staging/version directory, never a partially selected current package.

Disable revokes registrations and service access, removes all owned UI/commands/Pi resources, cancels managed tasks/network, and stops owned processes. Package and data stay installed. Re-enable verifies bytes and recreates contributions. Native binaries remain mapped until exit; Milk never calls bundle unload.

Update requires the same ID and a strictly newer version, validates compatibility, and asks for trust and the capability delta. It stages/validates before deactivating the current version. The atomic pointer retains a previous package reference, so a failed replacement never exposes a half-installed package. Data survives. If no native code has been mapped, the new version can activate immediately. If the old binary was mapped, contributions are removed and the new package is marked **Restart Milk required**. The next launch loads the new version. A recoverable activation failure restores the previous package reference where available and disables it when native residency makes immediate reactivation unsafe; the problem is persisted rather than retried in a loop.

Uninstall first revokes contributions and managed work, then removes the entire installed code/version directory. The confirmation's **Also remove extension data** checkbox is off by default. When selected, Milk deletes that extension's data/settings files and its entire namespaced Keychain service, even if `.milk-keychain-used` is missing. Default uninstall retains both. Reinstall can reuse retained settings.

### Development builds

Use **Add Development Extension…** to select a built `.milkext`. Milk visibly marks it Development and remembers its author-source path. It still executes a reviewed controlled copy. Rebuild externally and use **Review Development Build…** in Details; no repeated Finder copying is needed. Equal-version rebuilds are allowed only for marked development extensions, with fresh fingerprint/capability approval. An already mapped changed binary still requires restart. Milk does not silently execute live edits from a development folder.

## Example and validation

The external oMLX Status example registers a sidebar screen, workspace panel, Settings, optional status view, Chat toolbar button, `/omlx`, a Pi status tool, prompt resource and a cancellable poller. It declares `network`, `keychain` and `pi`. Endpoint, interval and status visibility use scoped JSON storage; the optional token uses scoped Keychain. Available model IDs do not imply loaded models. Loaded state and memory are displayed only when the endpoint actually supplies those fields. No server/model management or invented token-per-second statistics is implemented.

Tests in `NativeExtensionTests.swift` cover malformed/incompatible packages, duplicate IDs, missing executables, no execution before trust, capability approval, integrity and path aliases, ownership, services, process cleanup, data preservation/removal, update rollback, restart staging, layout roundtrip and Pi authorization. `NativeExtensionIntegrationTests.swift` compiles a real bundle, installs/disables/re-enables/updates it, loads the update in a fresh process, checks dynamic shell state and hashes Milk source before/after removal. Its real pinned Pi fixture also verifies native dispatch, approvals and tool withdrawal.

See [Agent final acceptance](AGENT_PHASE_FINAL_ACCEPTANCE.md) for technical validation and [the publication audit](PRE_GITHUB_AUDIT.md) for source hygiene. There is no marketplace, automatic extension update feed, publisher allowlist, native crash isolation, or arbitrary view-tree injection in the current product.

## Complete minimal package, from source to installation

The package tree, manifest, Info.plist and `StatusExtension` class above form one complete minimal skeleton. Save that class as `StatusExtension.swift`; use executable `MyExtension`, module `StatusExtension`, principal `StatusExtension.StatusExtension`, and ID `com.example.status` consistently. The minimal class needs no capabilities; the sample manifest's `network` and `keychain` may be removed when not used. Its two registrations demonstrate activation, sidebar content and command dispatch; deactivation is provided explicitly.

Create `MyExtension.milkext/Contents/MacOS` and `Contents/Resources`, save the JSON manifest under Resources and wrap the shown plist keys in a normal XML plist dictionary. Compile with the `swiftc` invocation above, then sign the assembled bundle. Do not copy an SDK library inside it. `Bundle(for: StatusExtension.self)` can locate immutable bundled resources without assuming an installation path.

There is no standalone package-validation CLI. Open Milk → Extensions → Install Extension, select the bundle and inspect compatibility, signature, fingerprint and capabilities before accepting trust. Inspection validates without activation. For local iteration use Add Development Extension and Review Development Build as described above. For activation failures select the extension and read its Details diagnostic and the Problems UI; fix the extension, rebuild and explicitly review it again. Do not edit host files to force activation.

## Which contribution point should I use?

All methods in this table are on `ExtensionContributions` unless stated otherwise.

| Goal | Exact API |
| --- | --- |
| Sidebar screen | `sidebar(ExtensionViewContribution)` |
| Workspace panel | `panel(ExtensionViewContribution)` |
| Chat toolbar | `view(at: .chatToolbar, ...)` or `action(at: .chatToolbar, ...)` |
| Composer button | `action(at: .composerLeading, ...)` / `.composerTrailing` |
| Settings category | `settings(ExtensionViewContribution)` |
| Bottom status | `status(ExtensionViewContribution)` |
| Native `/foo` | `command(ExtensionCommand)` |
| Editor menu action | `action(at: .codeContextMenu, ExtensionActionContribution)` |
| Polling/background task | `service(ExtensionBackgroundService)` |
| Owned CLI/server | `ExtensionContext.processes` → `ExtensionProcesses.launch` |
| Model-callable Pi tool | `piTool(ExtensionPiTool)` |
| Native command plus Pi tool | `piCommand(ExtensionCommand)` |
| Native bridge prompt | `prompt(id:text:)` |

### Sidebar recipe

Inside `activate(context:)`, register:

```swift
try context.contributions.sidebar(.init(
    id: "status", title: "Service", systemImage: "server.rack", badge: "Local"
) { _ in AnyView(Text("Service status").foregroundStyle(ExtensionTheme.text)) })
try context.contributions.command(.init(name: "service-status", summary: "Open service status") { _ in
    try context.focusSidebar("status")
})
```

Basic UI registration requires no extra capability. Add `network` for fetching remote status, not merely for showing a screen. Milk dynamically merges Files | Sessions | Git | Service without source edits or insertion indices. `badge` is optional registration metadata; use observable view state for live content. There is no general badge-mutation API. `focusSidebar` selects your own local ID. Disable/uninstall removes both entries and selects Files if necessary.

### Workspace panel recipe

```swift
try context.contributions.panel(.init(
    id: "notes", title: "Notes", systemImage: "note.text",
    minimumSize: CGSize(width: 360, height: 240), topbar: true
) { _ in AnyView(Text("NotesPanel").padding()) })
```

The full identity is `extension:<your-extension-ID>/panel:notes`. The topbar toggle controls visibility; users can also assign/split/drag it in Layout Edit. Native content participates in the existing recursive tree and minimum-size constraints. There is no public imperative focus-panel API. Layout persistence retains stable IDs. On disable or an unavailable extension, rendered leaves are pruned safely; saved references remain available for restoration on re-enable unless the user changes/resets that saved layout. Store actual notes through scoped storage, outside the replaceable package.

### Existing-screen injection recipe

The slot table above is exhaustive for API 1, including `file.contextMenu`. To add a button beside the composer controls:

```swift
try context.contributions.action(at: .composerTrailing, .init(
    id: "open-status", title: "Service status", systemImage: "server.rack"
) { _ in try context.focusSidebar("status") })
```

This assumes the sidebar recipe registered `status`. Controlled slots are the supported way to change existing screens. They do not grant arbitrary access to composer text, message mutation, private view hierarchies or new slot identifiers.

### Settings, scoped configuration and secrets recipe

Retain a `@MainActor ObservableObject` model for the activation, as the oMLX example does. Create it from `context.storage.read("settings.json")`, decode a small Codable configuration, and register its view with `settings`. For example, the view can contain:

```swift
ExtensionSettingsSection("Connection") {
    ExtensionSettingsRow("Endpoint") {
        TextField("https://service.example", text: $endpoint)
    }
    ExtensionSettingsRow("Token") { SecureField("Optional token", text: $token) }
    Button("Save") {
        do {
            try context.storage.write(Data(endpoint.utf8), to: "endpoint.txt")
            guard let secrets = context.secrets else { return }
            try secrets.write(token.isEmpty ? nil : token, for: "api-token")
        } catch { errorText = error.localizedDescription }
    }
    Text(errorText).foregroundStyle(ExtensionTheme.secondaryText)
}
```

This fragment belongs in a view with `@State` strings `endpoint`, `token`, `errorText` and a retained `context`. Declare `keychain` for token storage. Load the endpoint and token in model initialization, and surface missing services/errors instead of pretending a save succeeded. The complete oMLX `StatusSettings`/`StatusModel` implementation supplies a working version with validation and persistence.

Storage is extension-global; API 1 has no separate workspace settings API. If needed, implement a versioned per-workspace map in scoped storage using the workspace URL from the action context or the gated workspace service. Handle no open workspace and avoid assuming a URL is a permanent project identity. Do not use Milk's private preferences.

### Slash-command recipe

```swift
try context.contributions.command(.init(name: "foo", summary: "Open service status") { arguments in
    // Validate arguments here; API 1 has no argument-schema/arity field.
    guard arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    try context.focusSidebar("status")
})
```

Register `foo`, without the slash. Choose a distinctive globally available name; core/Pi/native collisions are rejected. Milk's composer discovers the active native registry, shows `/foo` and the summary, and completes it with a trailing space because argument arity is unknown. The next explicit Return/Send dispatches locally and passes argument text to the handler. Implement meaningful argument validation and feedback in your own view/model; do not silently perform an unintended action. Owner disable removes autocomplete and rejects stale dispatch.

A Pi dynamic slash command is independently reported by Pi `get_commands`, with real extension/prompt/skill metadata, and runs through supported Pi RPC. `piCommand` is instead a native Milk command plus bridge tool. Do not invent Pi command-unregister APIs or edit Pi source.

### Pi tool recipe

Declare `pi` in the manifest and register this in activation:

```swift
try context.contributions.piTool(.init(
    id: "echo", description: "Return the supplied text",
    parameters: Data(#"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"],"additionalProperties":false}"#.utf8),
    requiredCapabilities: []
) { arguments, _ in
    let object = try JSONSerialization.jsonObject(with: arguments) as? [String: Any]
    guard let text = object?["text"] as? String else {
        throw NSError(domain: "com.example.status", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Expected text"])
    }
    return text
})
```

Import Foundation. Validate handler input even with a schema. For networking or file/shell work, declare the corresponding manifest capabilities and list those required by the tool in `requiredCapabilities`; use the gated context services. Milk checks the originating session policy before native execution, and Pi's normal approval remains in effect. Destructive file/shell/Git operations must additionally use their approved service APIs.

> An extension tool must not create a bypass around Milk's Pi approval policy.

Disable withdraws the tool catalog and rejects retained/stale handlers. A capability declaration is never an excuse to execute unrestricted destructive Foundation or shell calls behind the approval system.

### Status-bar recipe

```swift
try context.contributions.status(.init(
    id: "connection", title: "Service", systemImage: "server.rack", priority: 0
) { _ in AnyView(ExtensionStatusBadge("Service · Offline")) })
```

For live telemetry, return a view observing your activation-owned model; the managed poller updates `@Published` properties on the main actor. Registration priority controls ordering; keep items compact and sparse. Show a model or `8.4 tok/s` only when actually measured/reported. Do not infer throughput from a model listing. Disable removes the item and cancels managed polling; clear retained model references in `deactivate`.

### External REST and managed polling recipe

Declare `network`, plus `keychain` if using a token. Inside activation, a service can capture the gated interfaces and publish into an observable model:

```swift
guard let network = context.network else { return }
try context.contributions.service(.init(id: "poll", workspaceScoped: false) { _ in
    while !Task.isCancelled {
        do {
            let endpoint = try context.storage.read("endpoint.txt")
                .flatMap { String(data: $0, encoding: .utf8) } ?? "https://service.example/status"
            guard let url = URL(string: endpoint), ["https", "http"].contains(url.scheme),
                  url.host != nil, url.user == nil, url.password == nil else {
                throw URLError(.badURL)
            }
            var request = URLRequest(url: url)
            if let token = try context.secrets?.read("api-token"), !token.isEmpty {
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await network.data(for: request)
            guard (200..<300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
            try Task.checkCancellation()
            // Decode your service schema and assign model @Published state here.
            _ = data
        } catch is CancellationError { return }
        catch {
            if Task.isCancelled { return }
            // Publish an offline/error state; clear stale telemetry in your model.
        }
        try await Task.sleep(nanoseconds: 15_000_000_000)
    }
})
```

This is a transport recipe; the complete oMLX model above is the concrete observable UI/error implementation. Prefer `context.network` over a private URLSession so revocation cancels requests; it uses an ephemeral URLSession internally. The endpoint is extension configuration. Milk does not own, start, bundle or manage that external server merely because an extension polls it.

### Background Swift service versus owned process

Use `service` for Swift polling, timers and API state. Use `processes` for a CLI or server subprocess, with `shell` capability:

```swift
guard let processes = context.processes else { return }
let child = try await processes.launch(
    executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], workspaceScoped: false)
// Retain the handle if you need to stop it before disable:
await processes.stop(child)
```

Use an explicitly configured executable or your own contained resource executable, never a guessed Milk internal path. Launch is approval-gated and requires the host workspace/session policy. Milk tracks exact owned process groups; disable/uninstall/app quit stops them. Workspace-scoped processes also stop on workspace departure. Never kill by name, port or cwd. Daemonized escape from the owned group is unsupported; don't build an extension around it. Managed Swift services are cancellable tasks, not subprocesses or a guarantee of isolation.

## State evolution and migration

API 1 has no migration callback. In activation/model initialization, read a versioned Codable envelope from scoped storage, validate it and explicitly migrate supported older versions. Write atomically through `storage.write`, retain a backup where appropriate, and leave unknown newer formats intact with a useful diagnostic. Package update rollback restores code references, not arbitrary mutated extension data. Prefer additive/backward-readable changes so the previous package can still operate. Never put mutable settings or migration state inside `.milkext`: code/resources may be replaced; ExtensionData remains.

Normal uninstall keeps ExtensionData (including settings) and Keychain secrets. Remove Data always attempts deletion of the complete `dev.milk.extension.<extensionID>` Keychain service before deleting the data directory, independent of marker presence. The deletion query explicitly matches all accounts in that service, not just one secret. An empty namespace succeeds idempotently; a real Keychain error is reported instead of claiming complete deletion. The marker may still be written for bookkeeping but is not authorization or evidence required for deletion.

## Theme and UI rules

| Public semantic value | Meaning |
| --- | --- |
| `ExtensionTheme.accent` | Fixed sRGB Milk orange `#FF4D00` in Light, Dark and System |
| `text`, `secondaryText` | Native appearance-aware label colors |
| `surface` | Native control background |
| `selected`, `hover` | Semantic selection and hover surfaces |
| `separator` | Native separator/border color |

API 1 does not expose separate `background`, `success`, `warning` or `destructive` theme properties. Do not invent them or reach into private MilkTheme. Use supported SwiftUI semantic roles/native colors when extra status semantics are necessary, and check both appearances. Do not use `.accentColor` as a substitute for Milk accent, hardcode light-only backgrounds, set application appearance or invent independent application styling unless custom content deliberately requires it. Use `ExtensionButtonStyle`, `ExtensionSettingsRow`, `ExtensionSettingsSection`, `ExtensionStatusBadge` and `ExtensionEmptyState` where appropriate.

# Where to Make Each Kind of Change

These are inspection/reference locations; an extension author changes their own package, not these host sources.

| Goal | Milk API / Example / Primary source |
| --- | --- |
| Protocol, manifest values, service interfaces | `Packages/MilkExtensionKit/Sources/MilkExtensionKit/ExtensionAPI.swift` |
| Public theme and Settings primitives | `Packages/MilkExtensionKit/Sources/MilkExtensionKit/ExtensionUI.swift` |
| Manifest/package parsing, compatibility, signatures | `Sources/MilkExtensionHost/PackageInspection.swift` — `NativePackageInspector` |
| Install/update/development/uninstall | `Sources/MilkExtensionHost/NativeExtensionManager.swift` — `NativeExtensionManager` |
| Sidebar/panel/Settings/status/slot registrations | `Sources/MilkExtensionHost/ContributionRegistry.swift`; public `ExtensionContributions` |
| Native UI slot rendering | `Sources/Milk/ExtensionSlots.swift` |
| Shell sidebar integration | `Sources/Milk/MainWindow.swift` |
| Recursive panel layout | `Sources/Milk/WorkspaceGrid.swift`; `Sources/MilkLayout/WorkspaceLayout.swift` |
| Native management UI/diagnostics | `Sources/Milk/NativeExtensionsUI.swift`, `ExtensionsView.swift` |
| Composer slash discovery and dispatch | `Sources/Milk/SlashCommands.swift`; SDK `ExtensionCommand` |
| Native Pi tool dispatch/catalog | `NativeExtensionManager.swift`, `ContributionRegistry.swift` in `Sources/MilkExtensionHost/` |
| Protected Pi transport (read only) | `Runtime/MilkPiIntegration.ts` |
| Storage, Keychain, network, process services | `Sources/MilkExtensionHost/ExtensionServices.swift` — `ScopedSecrets` and scoped facades |
| Exact process ownership implementation | `Sources/MilkPTY/MilkPTY.c` |
| Integrity monitoring | `Sources/MilkExtensionHost/ExtensionIntegrityWatcher.swift` |
| Broad working extension | `Examples/Extensions/OMLXStatusExample/OMLXStatusExample.swift`, `manifest.json`, `build.sh` |
| Package/lifecycle/security tests | `Tests/MilkExtensionTests/NativeExtensionTests.swift` |
| Real bundle/Pi/source-preservation integration | `Tests/MilkWorkspaceTests/NativeExtensionIntegrationTests.swift` |

## Extension author testing checklist

- [ ] Package builds against the shared SDK; identity, plist and manifest agree.
- [ ] Inspect/install validates compatibility, trust, capabilities and integrity.
- [ ] Enable shows each intended contribution without editing host source.
- [ ] Light, Dark and System remain readable with Milk orange.
- [ ] Workspace switching updates context and cancels workspace-scoped work.
- [ ] Disable removes UI, commands and Pi resources; stops managed services/processes.
- [ ] Re-enable recreates contributions and preserves scoped state.
- [ ] A newer-version update preserves data and requests any capability delta.
- [ ] Resident binary update requests restart; fresh launch loads the new version.
- [ ] Recoverable failed activation/rollback behaves safely; state remains backward-readable.
- [ ] Default uninstall removes package/contributions and preserves files/settings/secrets.
- [ ] Remove Data removes files/settings and all namespaced secrets, including with the marker deleted.
- [ ] No-secrets removal succeeds.
- [ ] Milk source snapshots are unchanged by install/update/removal.
- [ ] Focused tests pass: `swift test --filter NativeExtension` (use the managed-environment flags in the root README if needed).

## Do Not Do This

- Do not edit Milk source, patch core enum cases or hardcode sidebar insertion indices.
- Do not store secrets in manifests, plain settings or UserDefaults.
- Do not kill by process name, port or cwd, or bypass Pi approval.
- Do not write mutable data into `.milkext` or depend on private Milk implementation types.
- Do not invent capabilities, metadata, migration hooks or contribution points.
- Do not assume native code hot-unloads or synchronously blocking code is cancellable.
- Do not bundle oMLX/another provider into Milk. If your own product includes an external process, own it explicitly through the supported process API.

## Current limitations

Trusted native extensions are not sandboxed; native crashes cannot be isolated. The current loader accepts arm64/macOS 26+ bundles. Already mapped native code requires restart for replacement. There is no marketplace, automatic update feed or enforced publisher authority. Signature reporting and integrity checks do not establish publisher trust. API 1 may evolve; unsupported contribution points require an intentional SDK/core change. Native code has cooperative cancellation limits and cannot be safely hot-unloaded. The oMLX example demonstrates broad integration with external infrastructure; it does not make oMLX part of Milk core.
