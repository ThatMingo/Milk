# AGENTS.md — Milk Repository Guide

This file is the durable map for coding agents working on Milk. Keep it short, current, and phase-independent. Feature-specific requirements belong in design documents and active ExecPlans, not here.

## Start here

Before changing code:

1. Inspect the current branch, working tree, and relevant code. Do not assume an older phase document still describes the implementation.
2. Read:
   - `README.md`
   - `RUNTIME.md`
   - `docs/DEVELOPMENT.md`
   - `docs/README.md`
3. Read the current design document(s) relevant to the requested work.
4. For substantial, multi-subsystem, security-sensitive, or long-running work, read or create the matching file under `docs/exec-plans/active/` and keep it updated while working.
5. If a requested design conflicts with the current implementation, report the concrete conflict. Do not silently reinterpret the requirement.

Do not switch branches, discard work, rebase, merge, commit, or push unless the user explicitly asks.

## Product and platform

Milk is a native macOS workspace for coding agents.

- Apple Silicon only.
- macOS 26 or newer.
- Swift, SwiftUI, and AppKit are the primary app technologies.
- The root package currently uses Swift 5 language mode with a modern Xcode/Swift toolchain.
- Files, Editor, Git/Diff, Terminal, Preview, Settings, and workspace state are Milk-owned host features.
- Pi is currently the only production coding-agent integration, but Milk core must remain agent-agnostic.

Preserve the existing native macOS interaction model and visual language unless the requested work explicitly changes product design.

## Architecture invariants

The intended ownership chain is:

```text
Milk UI / workspace
  → AgentService
  → AgentAdapter
  → agent-specific adapter/backend
  → agent runtime / RPC
  → provider
  → model
```

Keep these boundaries intact:

- `AgentAdapter` is the internal coding-agent boundary. Do not bake Pi-specific concepts into generic Milk core when an adapter-owned implementation is sufficient.
- Milk owns workspace capabilities. Git, Editor, Terminal, Preview, layout, and Settings are not provider capabilities.
- Coding agents own their provider/model behavior. Milk may host adapter-supplied settings, but generic Milk core should not assume one provider schema.
- Upstream Pi must remain unmodified. Milk integrates through its compiled adapter, native RPC, and Milk-authored integration extension using supported Pi hooks.
- Milk ships without a coding-agent executable bundled in the app.
- Runtime code ownership and agent-data ownership are separate.
- Milk-managed and Existing installations/profiles must not silently bleed into each other.
- Never silently select an executable from `PATH`, revive an old bundled fallback, or substitute a different runtime when the selected runtime is unavailable.
- Lifecycle ownership, cancellation, restart, and cleanup must remain explicit. Stale callbacks must not update a new activation.

## Security invariants

Security-sensitive changes must fail closed.

- Provider secrets belong in the macOS Keychain. Never persist real secrets in source files, Codable settings, logs, diagnostics, command-line arguments, `models.json`, screenshots, or test fixtures.
- Do not introduce plaintext or weaker fallback storage when secure storage is unavailable.
- Treat filesystem paths, symlinks, archives, runtime artifacts, extension packages, and external executables as untrusted inputs until validated.
- Do not turn a trusted Milk bridge into a generic filesystem or command-execution escape for an agent.
- Native Milk extension UI/user handlers are trusted in-process. Agent-callable extension tools run in separate Milk workers; never restore an in-process fallback. Native UI capability contracts alone are not an OS sandbox.
- Existing Pi and user-owned data remain externally owned. Do not mutate or delete them as a side effect of managing Milk-owned runtime code.
- Tests for credential or security code must use disposable/synthetic data unless an explicit live acceptance task says otherwise.

When a security design document exists for the work, it is authoritative for the target behavior.

## Documentation precedence

Use documentation according to its purpose:

1. **Current code** is authoritative for what the app actually does now.
2. `README.md`, `RUNTIME.md`, `docs/DEVELOPMENT.md`, and the current-reference section of `docs/README.md` describe the shipped/current architecture.
3. Active design documents describe an approved target that may not be implemented yet.
4. Active ExecPlans describe how the approved target is being implemented and must evolve with discoveries.
5. Historical phase reports are evidence of past work only. They do not override current code or current-reference docs.

When implementation changes current behavior, update the relevant current-reference documentation in the same body of work. Do not rewrite historical reports to make them look current.

## ExecPlan discipline

Use an ExecPlan for work that is substantial, crosses multiple subsystems, changes security/runtime architecture, or is likely to span several Codex turns.

An active ExecPlan should contain:

- goal and scope;
- current-state findings;
- architecture mapping;
- implementation phases;
- affected code boundaries;
- non-negotiable invariants;
- progress checklist;
- discoveries;
- decisions;
- validation and acceptance criteria;
- remaining work / deferred work.

Keep it current while implementing. Record discovered constraints instead of relying on chat memory.

When work is complete, move/rename the plan according to the repository's documentation convention rather than leaving a misleading "active" plan indefinitely.

## Build and test

From the repository root, the normal development build is:

```sh
./scripts/build.sh
open output/Milk.app
```

If SwiftPM's nested sandbox prevents the build on the host:

```sh
./scripts/build.sh --disable-sandbox
```

For direct test commands, use the full Xcode toolchain:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift test --cache-path "$PWD/.build/cache"
```

Focused tests should be run while iterating. Run the broader relevant suite before calling a phase complete. Some integration tests require the optional pinned Pi fixture prepared by:

```sh
python3 scripts/bootstrap-runtime.py
```

Do not add generated `.build/`, `output/`, personal Pi data, credentials, signing exports, or private verification evidence to source control.

## Change quality

- Prefer small, explicit ownership boundaries over hidden global behavior.
- Preserve unrelated behavior.
- Add focused tests for new behavior and regressions.
- Security checks should validate canonical/real paths where path aliasing or symlinks matter.
- Do not claim verification that was not actually performed.
- Separate unit-test evidence from live/runtime/manual acceptance evidence.
- Keep error messages actionable without leaking secrets.
- Do not weaken an invariant merely to make a test pass; fix the design or test setup.

## Finishing work

Before presenting a substantial implementation as complete:

1. Review `git diff` and `git status`.
2. Run the relevant focused tests and broader regression suite appropriate to the change.
3. Build the app when the change affects production code or packaging.
4. Update current-reference docs and the ExecPlan.
5. Report:
   - what changed;
   - exact validation performed;
   - anything not verified;
   - remaining risks or deferred work.

Do not commit, push, merge, rebase, create a PR, or change branches unless explicitly requested.
