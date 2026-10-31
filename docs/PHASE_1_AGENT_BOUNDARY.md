# Phase 1 — compiled agent adapter boundary

> Historical phase record. This document records its original scope and evidence;
> it is not the current implementation or acceptance status. See
> [Agent final acceptance](AGENT_PHASE_FINAL_ACCEPTANCE.md) and the
> [source-publication audit](PRE_GITHUB_AUDIT.md). Evidence paths under `output/`
> refer to generated local files excluded from the public source tree.

Scope: evolve the existing `AgentBackend` while preserving the
[Pi parity contract](PI_PARITY_CONTRACT.md). Pi is the only registered production
agent. No installation, packaging, settings-navigation or session-schema migration
is included.

## Implemented architecture

`AgentService → AgentAdapter → PiAdapter → PiBackend → PiRPCClient → native Pi RPC`

- `AgentRegistry.standard` registers Pi explicitly with an `AgentID`, display
  descriptor, compiled adapter version and implemented-capability set. Constructing
  the registry does not launch a backend. Existing deterministic backend factory
  overrides are wrapped in the same adapter seam.
- `PiAdapter` owns the runtime/configuration/native-extension dependencies used to
  construct conversation and Preview inspection backends. Per-session permission
  is supplied in a generic context. Pi provider configuration is bound at creation;
  `AgentBackend.start` no longer requires `AgentConfiguration` or another agent's
  future configuration type. A concrete Pi startup overload remains for direct
  Pi tests/tooling.
- Capability names cover Milk's implemented features only. Automatic compaction
  and retry support are explicitly notification capabilities. Model image support
  and reported reasoning levels refine `AgentService.effectiveCapabilities`.
  Model selection, command refresh and queue/steer routing honor adapter support.
- Generic command events/catalogs use `AgentCommand`, preserving extension/prompt/
  skill classification and every existing source-info field. Only
  `PiCommandDecoder` reads native command JSON. Core/native/agent precedence,
  labels, validation and execution remain unchanged.
- `AgentSubmissionIntent.prompt` and `.followUp` replace generic transport
  strings. Only PiBackend maps follow-up to RPC `streamingBehavior: "followUp"`.
  Existing native queue/steering/abort logic is retained.
- Dialog methods, responses and origins are typed. Origins distinguish ordinary
  agent extension dialogs, agent permission prompts, Milk Preview and native Milk
  extension approval. Pi's internal native-bridge input is intercepted before
  presentation and never becomes a user dialog. The presentation convenience
  method retains current call sites, options and UI behavior; the backend protocol
  receives typed values, confirmation or cancellation.
- `AgentConnectionPhase` is distinct from `AgentRuntimeIdentity` (executable,
  version, application-bundle/external code ownership). The legacy `bundled` and
  version presentation fields remain for existing settings and tests. These are
  not installation records, authentication status, or ownership of shared data.
- In-memory `AgentActivation` combines agent, workspace, session and unique
  activation token. Existing service event/command guards use it; startup model
  restoration checks activation after suspension. Pi refresh operations validate
  their generation, and maintenance/timeout tasks are retained and cancelled on
  shutdown. This is stale-work protection, not a hot-switch coordinator.
- File history is an optional adapter facet (`AgentFileSessionHistory`), keeping
  current Pi validation/deletion/import behavior. A future SDK/server adapter need
  not implement local-file history. Generic session indexing and native-reference
  migration remain deferred. Preview assistance is also optional at the adapter
  boundary and still uses the existing read-only ephemeral Pi inspection.

## Intentionally retained coupling

- Existing `AgentConfiguration`, Pi runtime preferences, oMLX provider/Keychain
  settings and Pi-specific labels remain unchanged. Provider settings are not a
  mandatory input to the generic backend contract.
- Native MilkExtensionKit API 1, `.pi` grants, catalog/bridge methods and Pi
  extension management remain compatible. Extension package removal's bundled
  runtime dependency is not changed here.
- Runtime resolution, manifest checks, search-tool PATH, version-policy mismatch
  between Settings and backend startup, launch arguments, authentication and
  ordinary Pi data locations remain as before.
- Session snapshots stay version 3 with current integer editor links and native
  JSONL paths. No per-project selection UI or global index is introduced.
- Existing restart/replace and auxiliary-process ownership limitations remain for
  Phase 2. The adapter does not add an intermediary process or serialization hop.

## Verification

Verified on 2026-10-31:

| Run | Result | Evidence under `output/phase1/` |
| --- | --- | --- |
| Initial boundary build | No tests ran: one Preview assertion still compared a typed method with a string; corrected to `.editor`. Also moved history protocol conformance onto its declaration to resolve a concurrency warning. | `focused-initial.log` |
| Focused boundary and Phase 0 parity | 23 tests, 0 failures | `focused-boundary.log` |
| Final relevant Agent/Pi set, including Phase 0 parity and native extension integration | 43 tests, 0 failures | `focused-final.log` |
| Single full XCTest pass, after focused tests were clean | 119 tests, 0 failures | `full-suite.log` |
| Single fresh `--verify-agent` | 24 PASS, 0 FAIL, exit 0 | `native-agent.log` |

No observed Pi parity regression remained. The compile-time assertion correction
did not change the expected Preview dialog behavior. Test commands used Xcode,
workspace-local caches and elevated execution, as in Phase 0. The full suite was
run only once. Swift test built the current app executable. Native verification
used temporary runtime/integration resource symlinks beside that executable;
the links were removed afterward. Its inherited "Packaged standalone Pi" label
does not constitute packaging verification. Screenshots were generated by the
automated harness; no separate manual visual review is claimed. No packaging,
signing or other native harness ran. Generated evidence is not a source
deliverable. No commit, push or GitHub action occurred.

## Exact source change manifest

Added:

- `Sources/Milk/AgentAdapter.swift`
- `Sources/Milk/PiAdapter.swift`
- `Tests/MilkWorkspaceTests/AgentAdapterTests.swift`
- `docs/PHASE_1_AGENT_BOUNDARY.md`

Modified:

- `Sources/Milk/AgentModels.swift`
- `Sources/Milk/AgentService.swift`
- `Sources/Milk/AgentVerification.swift`
- `Sources/Milk/ComposerApprovalPopup.swift`
- `Sources/Milk/MilkApp.swift`
- `Sources/Milk/PiBackend.swift`
- `Sources/Milk/PiSessionService.swift`
- `Sources/Milk/PreviewPiAssistant.swift`
- `Sources/Milk/ShellState.swift`
- `Sources/Milk/SlashCommandVerification.swift`
- `Sources/Milk/SlashCommands.swift`
- `Tests/MilkWorkspaceTests/AgentServiceTests.swift`
- `Tests/MilkWorkspaceTests/PiIntegrationTests.swift`
- `Tests/MilkWorkspaceTests/PiParityTests.swift`
- `Tests/MilkWorkspaceTests/PreviewTests.swift`
- `Tests/MilkWorkspaceTests/SlashCommandPiTests.swift`
- `Tests/MilkWorkspaceTests/SlashCommandTests.swift`

Most existing test/harness edits adapt method signatures or typed assertions.
The two new boundary tests verify the production registry/capability inventory,
generic factory context, model-dependent availability, unsupported queue gating
and rejection of events from a closed activation. Real Pi tests additionally
assert dialog origin and external runtime identity. No additional agent is
implemented; the boundary adapter in tests is a deterministic test double.

## Phase 2 recommendation

Use the adapter boundary to consolidate owned lifecycle transitions before any
runtime relocation: persist/cancel, invalidate activation, await pending starts
and old writers, then replace the backend. Include Preview inspections and
future probes/package operations in ownership tracking. Keep optional file
history separate from the later generic session index. Preserve host-owned
approval decisions when an agent disconnects. No Phase 2 implementation is part
of this change.
