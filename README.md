# Milk

Milk is a native macOS GUI for coding agents, built with Swift, SwiftUI and AppKit.
It brings files, an editor, agent chat, sessions, Git/Diff, Terminal and web Preview
into one rearrangeable workspace.

The current development version is **0.7.0**, targeting **Apple Silicon and macOS
26 or newer**. Pi is the first and currently only production agent integration.

## What works today

- **Files and editor:** filesystem browsing, tabs and splits, syntax highlighting,
  find/replace, undo and unsaved-buffer recovery.
- **Chat and sessions:** streaming text and Thinking, tool activity, approvals,
  attachments, model/reasoning selection, slash commands, Queue/Steer/Stop, and
  retained sessions browsable by current project or all projects.
- **Git/Diff:** status, branches, unified and side-by-side diffs, file/hunk staging,
  commits and fetch/pull/push using your existing Git authentication.
- **Terminal:** a native SwiftTerm terminal running your interactive login shell.
- **Preview:** WebKit pages, local static HTML and project development servers.
  Framework previews use the project's own tools and dependencies.
- **Settings:** appearance/editor preferences, agent installation management and
  provider configuration.
- **Native Milk extensions:** trusted `.milkext` packages can add UI, commands
  and services through MilkExtensionKit.

Files, Git, Terminal, normal Preview and retained session browsing remain usable
without a coding agent. Agent chat and agent-assisted Preview require a working
agent and model provider.

## Agents

**Milk ships with no coding agent bundled.** Its agent-management architecture
supports Milk-managed Pi installations and explicitly selected existing Pi
installations. Pi uses native RPC through Milk's compiled `PiAdapter`; upstream
Pi is not patched. The current adapter supports **Pi 1.4.0**.

Managed executable revisions live outside Milk.app. Existing installations remain
externally owned. Executable ownership is separate from Pi's normal user data,
configuration, authentication and sessions; removing managed code preserves those
data. Milk does not silently select an executable from PATH or fall back to an
old bundled runtime. Additional agents are planned, not implemented.

See [runtime architecture](RUNTIME.md) for installation, compatibility, lifecycle
and data ownership details.

## Requirements

Development requires:

- Apple Silicon and macOS 26 or newer.
- Full Xcode with the macOS 26 SDK and Swift **6.2 or newer**, required by pinned
  SwiftTerm 1.99.2. The root package uses Swift 5 language mode.
- Python 3, Git and the standard macOS command-line build/signing tools.
- Network access for initial SwiftPM dependency resolution.

Building Milk does **not** require Pi, Bun, Node, npm, Homebrew or model weights.
Optional upstream integration-test fixtures separately require Python **3.12+**
and curl. See [developer setup](docs/DEVELOPMENT.md#tests) for tests and fixture setup.

## Build from source

From the repository root:

```sh
./scripts/build.sh
open output/Milk.app
```

The script builds Milk and its native extension SDK, stages Milk-owned integration
resources and notices, and signs the app ad hoc by default. It does not download
or bundle Pi. Generated output goes to ignored `.build/` and `output/` directories.
Private references, old source archives and local verification evidence are not
needed to build.

For toolchain selection, the optional `--disable-sandbox` build argument, and test
commands, see [developer setup](docs/DEVELOPMENT.md).

## Running with Pi

1. Launch Milk and open a project.
2. Open **Settings → Agents**.
3. Choose **Install** for Milk-managed Pi, or **Use Existing Installation** to
   select a compatible Pi executable. Milk verifies compatibility before use.
4. Configure a model provider if needed, then use Chat from your workspace.

Pi retains its ordinary provider configuration. Milk also offers an optional
**oMLX** connection in Settings → Agents: enter the external endpoint, optional
Keychain-stored token and model settings, then test/save the connection. Milk does
not install or run oMLX or manage its model weights. Milk has no OAuth/login setup
flow; agent authentication remains Pi's responsibility.

## Extensions

Native Milk extensions use MilkExtensionKit for host UI and services. Pi extensions
are separate resources loaded by Pi. Native extensions execute inside Milk with
user privileges and require explicit trust; capabilities are not an OS sandbox.
See the [extension developer guide](docs/EXTENSION_DEVELOPMENT.md) and the
[example source](Examples/Extensions/OMLXStatusExample/).

## Status and limitations

The [source-publication audit](docs/PRE_GITHUB_AUDIT.md) found the prospective
source snapshot ready. This is separate from a signed downloadable app release.
[Agent final acceptance](docs/AGENT_PHASE_FINAL_ACCEPTANCE.md) records the completed
156/156 regression pass and its limits.

- Developer ID signing, notarization, stapling and clean-machine release
  acceptance are not complete.
- Managed downloaded runtime provenance and Bun/native matching-source,
  reconstruction, relinking and distribution questions remain under review.
  Removing runtime binaries from Milk.app does not establish release clearance.
- Pi is the only production agent. A production self-updater, marketplace, LSP,
  Computer Use, orchestration and additional agent integrations are future work.

The [roadmap](docs/MILK_PLANNED_FEATURES.md) describes plans, not shipped features.
See the [documentation index](docs/README.md) for current references and historical
engineering records.

## License

Milk's original source is licensed under [MIT](LICENSE). Third-party components
retain their own licenses; see [third-party notices](ThirdPartyNotices/README.md)
and the [dependency inventory](ThirdPartyNotices/INVENTORY.md).
