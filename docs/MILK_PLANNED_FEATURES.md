# Milk — Planned Features

This is roadmap context for architecture decisions. These features are **not automatically in scope** for the Pi agent refactor.

## Multi-agent support

- Milk ships with no coding agent.
- Pi first.
- Later: Codex, OpenCode, Claude Code, Gemini, GitHub Copilot.
- Use the best native protocol/SDK per agent rather than forcing ACP everywhere.
- Custom ACP-compatible agents later.
- Multiple agents installed, one active.
- Per-project active agent + global default.
- Hot switching between agents.
- Unified Sessions view across agents, filterable by current project / all projects.
- Agent-specific capabilities and UI.
- Independent agent-adapter updates.
- Milk-managed agents plus Use Existing Installation.
- Install/update/auto-update/rollback/remove agents from Milk.

## Computer Use

Future feature only; do not implement in the current agent refactor.

- Milk-owned Computer Use usable by compatible agents.
- Whole-Mac control.
- Window-specific capture + full-screen fallback.
- Native macOS Accessibility + Screen Recording.
- Ask / Autonomous per session.
- Sensitive actions can always require approval.
- User can choose Milk Computer Use vs an agent's native Computer Use where both exist.
- Architecture may later allow local/remote/VM/browser targets.

## Orchestration / subagents

- Multiple subagents/workers.
- Agent delegation/orchestration.
- Supervisor/conductor workflows.
- Must not be hard-wired to Pi.

## Preview expansion

- Current web Preview already exists.
- Future native macOS app preview/run support.
- Potential iOS Simulator support.
- Potential Android emulator support.
- More general Run/Preview providers.

## Browser / DOM integration

- General browser capability beyond current WKWebView Preview.
- DOM inspection/interaction.
- Eventually usable by agents as tools.

## Editor improvements

- Project-wide/global Search.
- LSP integration.
- Richer code intelligence.
- Additional editor tooling/extensions.

## Git / GitHub expansion

- More advanced Git workflows.
- Richer GitHub integration.
- PR/issues/checks/review workflows beyond current Git/Diff foundation.

## Extensions ecosystem

- Standalone/versioned MilkExtensionKit SDK.
- Templates and tooling for extension developers.
- Possible milk-ext validator/builder/packager.
- Extension Creator GUI so extensions can be built without Milk source.
- Eventually marketplace/registry/publisher trust.
- Better crash isolation/sandboxing if required later.

## Agent adapter ecosystem

- Potential future MilkAgentAdapterKit.
- Third parties could add coding harness integrations without modifying Milk.
- Not part of the first Pi refactor.

## Updates

- Production-quality Milk self-updater.
- Signed/notarized release distribution.
- Update feed/install/rollback architecture.
- Agent and adapter updates remain independent from Milk updates.

## Start / workspace experience

- Start screen / recent workspaces.
- Recent projects.
- Faster workspace switching/opening.

## Session portability

- No automatic cross-agent session migration.
- Future option: Start new session with context from this session.

## Architectural groundwork expected now

During the Pi refactor, only lay groundwork where appropriate for:

- multi-agent adapters and capabilities
- generic future tool providers such as Computer Use
- orchestration/subagents
- generic Preview/Run providers
- extensibility

Do not implement these future features during the Pi refactor.
