# Milk — Agent Architecture Handoff

> Historical planning handoff. This document records its original scope and evidence;
> it is not the current implementation or acceptance status. See
> [Agent final acceptance](AGENT_PHASE_FINAL_ACCEPTANCE.md) and the
> [source-publication audit](PRE_GITHUB_AUDIT.md). Evidence paths under `output/`
> refer to generated local files excluded from the public source tree.

## Purpose

Milk is a native macOS GUI for coding agents. The long-term goal is for Milk itself to remain lightweight and agent-agnostic while supporting multiple coding-agent harnesses through the best integration method available for each harness.

This phase is **Pi only**. The architecture must make future agents possible without implementing them now.

## Core product rules

1. Milk ships **clean**, with no coding agent bundled or installed.
2. Users install agents from **Settings → Agents**.
3. Multiple agents may be installed, but only the active agent should run.
4. Active agent is remembered per project, with a global default for new projects.
5. Agent switching should ultimately be hot-swappable without restarting Milk.
6. Milk supports both:
   - **Milk-managed installations**
   - **Existing external installations**
7. Milk-managed installations can be installed, updated, auto-updated, rolled back, repaired and removed.
8. External installations are connect/use-only. Milk must not update, replace or delete them.
9. Sessions remain owned by the agent that created them.
10. Milk presents a unified Sessions UI, filterable by:
    - current project
    - all projects
11. Agent-specific capabilities and settings are allowed. Do not reduce all agents to the lowest common denominator.
12. Authentication remains owned by the agent where possible. Milk displays status and launches the agent's supported auth flow.
13. Custom agents are out of scope now. Future custom-agent support should initially target ACP-compatible agents.
14. Future Computer Use is out of scope. Only preserve architectural room for future Milk-owned tools/capabilities.
15. Do not implement future agents during this phase.

## Recommended architecture

Milk core should contain a small generic agent boundary rather than Pi-specific assumptions.

Conceptually:

```text
Milk UI
   │
   ▼
MilkAgent / MilkAgentAdapter API
   │
   ├── PiAdapter        ← current phase
   ├── CodexAdapter     ← future
   ├── OpenCodeAdapter  ← future
   ├── ClaudeAdapter    ← future
   ├── GeminiAdapter    ← future
   └── CopilotAdapter   ← future
```

Each adapter should use the richest official integration available for that agent rather than forcing every agent through ACP.

Current intended future direction:

```text
Pi          → Pi RPC
Codex       → Codex App Server
OpenCode    → OpenCode Server API
Claude Code → best supported official SDK/protocol chosen when implemented
Gemini      → ACP
Copilot     → Copilot SDK
```

These are roadmap choices, not implementations for this phase.

## Adapter distribution

Milk itself should remain small.

Agent integrations should be structured so that heavier agent-specific dependencies can live outside the core app and be installed only when needed.

Target conceptual storage:

```text
~/Library/Application Support/Milk/
    Agents/
        pi/
        codex/
        ...
    Adapters/
    Sessions/
    AgentData/
```

For this phase, do not over-engineer a public adapter package format. Internal managed adapter/runtime folders are sufficient.

Long term, adapters should be independently updateable from Milk.

## Generic agent capability model

The generic boundary must support capability discovery rather than assuming every agent supports every feature.

Examples of capabilities:

```text
streaming
thinking
tools
permissions
sessions
sessionResume
sessionFork
models
reasoningLevels
slashCommands
steering
followUpQueue
compaction
autoCompaction
autoRetry
subagents
mcp
computerUse
computerUseVision
computerUseInput
```

This list is intentionally extensible.

Milk UI should hide or adapt controls when a capability is unavailable.

Agent-specific capabilities may remain available through typed/agent-specific extensions rather than being discarded.

## Generic event model

The UI should consume normalized Milk-owned events instead of Pi-specific transport objects.

Examples:

```text
textStarted
textDelta
textFinished

thinkingStarted
thinkingDelta
thinkingFinished

toolStarted
toolUpdated
toolFinished

permissionRequested
fileChanged
commandExecuted
planUpdated
usageUpdated
sessionStarted
sessionUpdated
sessionFinished
agentStateChanged
error
```

Do not force exact names if the current codebase suggests a cleaner implementation. Preserve the architectural principle: transport-specific details stay behind the adapter.

## Agent installation ownership

### Milk-managed

Milk owns the installation and may:

- install
- verify
- update
- auto-update when enabled
- retain previous version
- roll back
- repair
- remove

Use official/Milk-approved sources only.

Before marking a managed installation usable:

- verify expected version
- verify integrity/signature/hash where supported
- verify architecture/platform
- perform a real launch/handshake/health check

### Existing installation

Milk may:

- discover or allow user selection
- inspect version
- test compatibility
- launch/connect
- report status

Milk must not:

- overwrite
- update
- remove
- silently change configuration

The UI should clearly distinguish **Managed by Milk** from **Existing installation**.

## Versioning and compatibility

Milk should track:

- agent identifier
- installation ownership
- installed version
- active version
- adapter version
- compatibility state

Future compatibility states may include:

```text
Supported
Untested
Unsupported
Update required
Adapter update required
```

Milk-managed agents should support version selection and rollback.

Do not silently adopt an upstream version that has not passed compatibility checks.

## Authentication

Default rule:

> The agent owns authentication; Milk observes and presents it.

Milk may show status and trigger the agent's supported login flow, but should avoid becoming the credential authority unless a future integration explicitly requires it.

## Sessions

Sessions must be generic at the Milk level while retaining agent ownership.

Minimum metadata should support:

- Milk session identity
- agent identity
- native agent session/thread identity
- workspace/project path or stable workspace identity
- agent version where relevant
- timestamps
- display title/status
- resumability/capabilities

Default Sessions UI should show sessions for the current project, with an All Projects view.

Do not automatically migrate a session between agents.

Future possibility:

> Start a new session with context from this session

That is not part of this phase.

If an agent is removed, retained session metadata/history should remain visible with an Agent not installed state.

## Switching agents

Target behavior is hot switching.

When switching:

1. persist current session state
2. stop the current owned agent process cleanly
3. unload/deactivate its runtime-specific integration
4. start the selected agent only when needed
5. update capability-driven UI
6. never leak process/session state between agents

Initial implementation may internally use a simpler transition while the abstraction is being proven, but the architecture must not require app restart as a permanent design constraint.

## Resource/performance requirements

Milk must remain lightweight.

- Do not bundle multiple agent runtimes into Milk.app.
- Do not start inactive agents.
- Avoid helper processes when a direct official protocol is available.
- Small shared transports such as JSON, JSON-RPC, stdio, HTTP and SSE helpers may live in core when useful.
- Heavy SDK/runtime dependencies should remain agent-specific and optional.
- Protocol normalization must not sit on the model's token-generation hot path in a way that adds meaningful latency.

## Current phase: Pi migration

Pi is the first and only agent to implement now.

The goal is architectural refactoring, not a Pi feature redesign.

### Requirements

1. Introduce the generic Milk agent boundary.
2. Place existing Pi integration behind a Pi-specific adapter.
3. Preserve existing Pi RPC as the preferred integration.
4. Preserve 100% of working Pi functionality.
5. Remove the assumption that Pi is bundled inside Milk.app.
6. Add Settings → Agents with Pi as the only catalog entry for now.
7. Support:
   - Install Pi
   - Use Existing Pi
   - version detection
   - compatibility validation
   - update availability
   - manual Update
   - optional Auto Update
   - version selection where supported by the managed catalog
   - rollback
   - repair/health check
   - remove managed Pi
8. Preserve sessions/settings when removing Pi unless explicitly deleted by the user.
9. Provide separate UI actions to delete sessions, reset settings or delete all Pi data.
10. Store Milk-managed Pi outside the signed Milk.app bundle under Application Support.
11. Launch Pi only when required.
12. Preserve per-project active-agent architecture even though Pi is currently the only agent.
13. Preserve the unified session architecture even though Pi is currently the only agent.
14. Build capability discovery/representation now.
15. Do not implement another agent yet.

## Pi functionality that must not regress

Inspect the current implementation and tests rather than relying only on this list.

Known functionality to preserve includes:

- Pi RPC lifecycle
- streaming assistant output
- thinking/reasoning stream and levels
- tool/activity reporting
- permission/approval workflow
- sessions
- resume
- model discovery/selection
- slash/dynamic commands
- steering
- follow-up/queue behavior
- compaction/auto-compaction if currently exposed
- retries/auto-retry if currently exposed
- Pi integration extension behavior
- changed-file/tool state integration
- clean owned-process shutdown
- existing Milk approval modes and UI behavior

The refactor is not successful if Pi becomes a lowest-common-denominator ACP-style experience.

## Packaging / release constraint

The current bundled Pi/Bun runtime has been a redistribution/licensing blocker for downloadable Milk.app builds.

The target architecture should remove third-party coding-agent binaries from Milk.app itself.

Do not claim that simply downloading upstream software automatically resolves all licensing obligations. Keep installation provenance, notices and verification explicit and auditable.

## Failure behavior

An agent failure must not break Milk itself.

Desired states/actions:

```text
Agent failed to start
Retry
Repair
Roll Back
Remove
```

Milk's editor, files, Git, terminal, preview, settings and extensions should remain usable without a working agent.

## Non-goals for this phase

Do NOT implement:

- Codex
- OpenCode
- Claude Code
- Gemini
- Copilot
- arbitrary custom agents
- public MilkAgentAdapterKit
- Computer Use
- browser/DOM agent tooling
- orchestration/subagents
- cross-agent session migration
- marketplace
- unrelated editor/Git/Preview roadmap items

Lay groundwork only where doing so prevents another architectural rewrite.

## Implementation strategy

Recommended sequence:

1. Inspect and document all current Pi-specific coupling.
2. Define the minimum generic MilkAgent/MilkAgentAdapter/capability/event/lifecycle contracts required by current Pi functionality.
3. Migrate Pi behind PiAdapter without changing behavior.
4. Run the full existing regression suite and repair any regressions.
5. Introduce installation ownership/runtime-location abstractions.
6. Move managed Pi out of Milk.app packaging.
7. Add Pi Agent Manager UI and managed/existing-install flows.
8. Add compatibility/version/update/rollback/remove flows.
9. Add per-project active-agent state and generic session metadata where needed.
10. Add hot-switch lifecycle groundwork.
11. Re-run full build/test/native verification and packaging checks.
12. Produce an updated audit of what changed, what remains deferred and any new risks.

Prefer incremental, test-backed changes over a large rewrite.

## Success criteria

This phase is complete when:

- Milk can launch with no coding agent installed.
- Milk remains usable without an agent.
- Pi can be installed and managed from Milk.
- An existing Pi installation can be selected without Milk taking ownership of it.
- Pi works through the new generic agent boundary with no known feature regression.
- Pi is no longer required to live inside Milk.app.
- Managed Pi can be updated/rolled back/removed safely.
- Pi sessions/settings survive agent removal unless explicitly deleted.
- only the active agent process runs.
- the codebase has a clean extension point for agent #2 without redesigning Milk UI/session/lifecycle architecture.
- future features remain unimplemented unless required as minimal architectural hooks.

## Working rule for Codex

Before implementing, inspect the current source and tests thoroughly.

Do not mechanically impose names or types from this document if the existing codebase supports a cleaner equivalent.

Preserve user-visible behavior unless this document explicitly requires a change.

When an architectural assumption conflicts with actual current implementation, document the conflict before changing behavior.
