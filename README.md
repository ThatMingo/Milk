# Milk

Milk is a native macOS GUI for coding agents, built with Swift, SwiftUI and AppKit.
It brings files, an editor, agent chat, sessions, Git/Diff, Terminal and web Preview
into one rearrangeable workspace.

The canonical application version is in [VERSION](VERSION), targeting **Apple Silicon and macOS
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
  agent-owned provider configuration.
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
externally owned and use the existing Pi setup. Installing Pi uses a separate
Milk-owned profile at `~/Library/Application Support/Milk/Agents/pi/profile/`.
Configuration, providers, extensions and native sessions in that profile survive
runtime removal and are reused on reinstall. Existing Pi keeps its ordinary
profile; settings changes there may also affect Pi outside Milk. Milk does not silently select an executable from PATH or fall back to an
old bundled runtime. Additional agents are planned, not implemented.

See [runtime architecture](RUNTIME.md) for installation, compatibility, lifecycle
and data ownership details. See [Pi profile ownership](docs/PI_PROFILE_OWNERSHIP.md)
for the managed-versus-existing distinction.

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

Milk manages coding agents; each coding agent owns its providers, models and
provider authentication: **Milk → Pi → Provider → Model**. After installing or
selecting Pi, open its configuration under **Settings → Agents → Pi**. Choose
**Local** for a generic OpenAI-compatible server, enter its endpoint, choose None
or a Keychain-stored API key, and use **Test Connection** to discover models. Then
select a model and save. Local can point to oMLX, LM Studio, llama.cpp or another
compatible server; Milk does not install or run those servers.

Pi's supported `models.json` configuration handles the connection. Pi performs
inference, and Chat gets model/thinking choices from Pi RPC. Undiscovered model
capabilities stay unknown. Unknown context/output limits are omitted from Pi
configuration; Pi uses its own supported defaults. Optional per-model Advanced
overrides can supply otherwise unknown values. None authentication sends no
Authorization header through Pi's supported request-header hook. Legacy shared preferences and credentials remain retained for recovery; active
profile scopes do not automatically import ambiguous shared development state. Existing Pi providers remain available
through **Pi configured providers**; hosted sign-in flows are not added here.

See [agent provider settings](docs/AGENT_PROVIDER_SETTINGS.md) for the exact
adapter contract, migration, secure storage, and Pi limitations.

## Extensions

Native Milk extensions use MilkExtensionKit for host UI and services. Pi extensions
are separate resources loaded by Pi. Native extensions execute inside Milk with
user privileges and require explicit trust; capabilities are not an OS sandbox.
See the [extension developer guide](docs/EXTENSION_DEVELOPMENT.md) and the
[example source](Examples/Extensions/OMLXStatusExample/).

## Status and limitations

The [source-publication audit](docs/PRE_GITHUB_AUDIT.md) found the prospective
source snapshot ready. This is separate from a signed downloadable app release.
[Agent final acceptance](docs/AGENT_PHASE_FINAL_ACCEPTANCE.md) records the pre-provider-refactor
156/156 regression baseline and its limits. The completed provider/profile refactor passed
[final acceptance](docs/PROVIDER_FINAL_ACCEPTANCE.md): 183/183 regression tests,
27/27 focused checks and 12/12 native acceptance assertions.

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
