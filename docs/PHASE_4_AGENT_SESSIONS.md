# Phase 4 — agent-owned sessions and project selection

> Historical phase record. This document records its original scope and evidence;
> it is not the current implementation or acceptance status. See
> [Agent final acceptance](AGENT_PHASE_FINAL_ACCEPTANCE.md) and the
> [source-publication audit](PRE_GITHUB_AUDIT.md). Evidence paths under `output/`
> refer to generated local files excluded from the public source tree.

Scope: additive Milk session metadata, ownership-aware routing, persisted project/
global agent selection, and a minimal offline metadata index. This preserves the
[Pi parity contract](PI_PARITY_CONTRACT.md) and the Phase 1–3 adapter, lifecycle,
installation and compatibility boundaries. Pi remains the only production agent.

## Architecture implemented

`AgentSession` keeps its integer editor/session ID, title, state, native backend ID
and JSONL path. An additive `AgentSessionMetadata` contains:

- Stable Milk UUID and immutable owning `AgentID`.
- Workspace identity based on the canonical project path, with that path retained.
- Creation/modification/last-used timestamps where known; legacy creation time
  remains unknown rather than fabricated.
- Availability observations, last-used runtime/adapter versions, and diagnostic
  installation/data-profile association. Associations never change the selected
  executable, authentication, data-directory ownership or native file location.

Metadata IDs/owners cannot be reassigned through session mutation methods.
Legacy IDs derive deterministically from owner, workspace, integer editor ID and
native reference. Newly created sessions use new UUIDs. Existing integer IDs
continue to key editor panes/tabs, conversation dictionaries and runtime actions.

`AgentService` resolves resume/start, history and deletion through the session's
owner in `AgentRegistry`. Project selection is a separate property used to create
new sessions. Selecting another project agent does not reassign or restart an
existing session. No cross-harness hot-switch protocol is implemented.

`AgentSelectionPreferences` persists the global default under
`Milk.agents.default.v1`. Project choice is persisted in the workspace's agent
payload. Existing projects select Pi on migration; genuinely new projects use the
global default. Explicit project choice overrides subsequent global changes.
Selection setters accept only registered agents; the production registry still
contains only Pi. Retained unregistered owner identities never fall back to Pi.
There is no new settings/management UI.

## Persistence migration and safety

The inner agent payload advances from version 3 to version 4. The surrounding
`WorkspaceSnapshot` remains version 1, with the same recovery/layout/editor fields.
Open/archived records, integer IDs, native IDs, JSONL paths, titles, conversations,
drafts, file references and editor mappings stay in their existing structures.
Queued-draft recovery and interrupted-stream handling retain their existing
behavior. New IDs allocate beyond open, archived and existing editor mappings.

On first write of a v4 payload over a legacy workspace recovery file,
`WorkspacePersistence` saves the complete original bytes once as
`<workspace-hash>.json.before-agent-v4`, with user-only file permissions. Subsequent
saves do not overwrite that backup. Ordinary Pi data is not copied, rewritten,
relocated or converted by this migration. The backup intentionally retains the
pre-migration Milk recovery contents; it is not an active session/history source.

Recognized newer/unreadable agent payloads remain byte-for-byte in the snapshot
and block replacement session creation. A v4 session lacking ownership metadata
is unreadable, not a reason to infer Pi ownership. The existing older placeholder
fallback still adopts real editor IDs. A corrupted/newer index is retained without
overwriting it; authoritative workspace recovery remains independent.

## Offline index and availability

`AgentSessionIndex` stores metadata, native references, optional integer editor
mapping, title and open/archived state in
`Application Support/Milk/Sessions/index-v1.json`. Workspace snapshots remain the
authority for cached transcripts, drafts and editor recovery. The index points
back to those snapshots instead of duplicating conversation content per token.
Metadata writes occur only when indexed records change, with atomic writes and
user-only storage permissions.

The API lists current-project or all indexed-project records without launching an
agent. Legacy projects enter the index when opened/migrated; known native history
enters when discovered through the owning adapter. This is not an exhaustive scan
of every historical workspace or native agent directory. Native history records
without editor mappings acquire an editor ID only when opened.

Retained records can be opened from current workspace caches even if the owner
is unavailable. Owner lookup, runtime presence, native file/header/format checks
and compatibility observations remain separate. Availability can distinguish
unverified, connected, missing owner, missing runtime, incompatible runtime,
authentication required, missing/invalid data, unsupported format and wrong
workspace. Authentication is not guessed from error strings or connection state.
The authentication state is representable for explicit adapter observations;
this phase adds no auth flow or new provider authentication detector.

Pi's lightweight offline inspection reads a bounded header and recognizes the
same native format versions already supported by current Pi session validation.
Actual startup still performs Phase 3 resolution and compatibility checks. Cached
successful availability is downgraded to unverified when listing index records;
it does not prove the current installation can resume. No cross-version converter
is added. Project renames/relocation and automatic cross-project opening remain
outside this phase; retained metadata is not silently rebound to a different root.

## Resume, Close and Delete

Existing Sessions layout and native Pi JSONL import remain. Import explicitly tags
Pi ownership; generic resume/open uses the retained owner regardless of current
project selection. Current-project Recent can include retained saved-file metadata
without learning history from a fresh Pi process. Fileless retained records and
all-project browsing are available through model/index APIs; their final UI is
deferred.

Close retains native history, Milk metadata, drafts and editor linkage. Delete
resolves the owning adapter and preserves Pi's external-runtime restriction,
active-directory/header/path/link checks, confirmed writer drain and native
deletion revalidation. The index/conversation removal follows successful native
deletion. If deletion fails, retained metadata remains. An index persistence error
after native deletion is reported separately; it does not pretend the native file
still exists. No broader authority over shared/external Pi data is granted.

## Verification actually performed

Verified on 2026-10-31 using Xcode and workspace-local caches. Generated evidence
is under `output/phase4/`.

| Run | Result | Log |
| --- | --- | --- |
| Focused Phase 4 group | 6 tests: 5 passed, 1 deletion/history-refresh race found | `focused.log` |
| Targeted deletion fix and strengthened unreadable-ownership case | 2 tests, 0 failures | `targeted-fixes.log` |
| PiParityTests, once because session code changed | 4 tests, 0 failures | `pi-parity.log` |

The deletion test exposed an immediate retry rejecting a retained session after
Close but before asynchronous native history refresh. Membership now recognizes
the retained current-project record while keeping the existing native deletion
safety checks. The targeted test verifies native failure retains metadata and a
subsequent successful delete removes it through the owner, not the project agent.
No Pi parity issue remained. No compiler diagnostics occurred in these runs.

The six Phase 4 tests cover deterministic/idempotent v3 migration with original
backup bytes and editor/draft/archive/native-file preservation; project/global
selection and immutable ownership; owner-routed resume; offline cross-project
index/cache and missing owner/runtime/unsupported-format states; owner-routed
deletion/failure retention; and preservation of newer/corrupt ownership/index data.
Routing adapters in tests are deterministic doubles only, not additional agents.

Successful unrelated filters were not repeated. Test compilation built the
changed code, so no separate build ran. No full suite, native verifier, screenshot,
visual inspection, packaging/signing verification or unrelated test matrix ran.

## Exact source manifest

Added:

- `Sources/Milk/AgentSessionMetadata.swift`
- `Sources/Milk/AgentSessionIndex.swift`
- `Tests/MilkWorkspaceTests/AgentSessionMigrationTests.swift`
- `docs/PHASE_4_AGENT_SESSIONS.md`

Modified:

- `Sources/Milk/AgentAdapter.swift`
- `Sources/Milk/AgentModels.swift`
- `Sources/Milk/AgentService.swift`
- `Sources/Milk/MilkApp.swift`
- `Sources/Milk/PiAdapter.swift`
- `Sources/Milk/PiBackend.swift`
- `Sources/Milk/PiSessionService.swift`
- `Sources/Milk/WorkspaceServices.swift`
- `Sources/Milk/WorkspaceStore.swift`

## Deferred work and Phase 5 recommendation

Final Current Project/All Projects controls, project/global selection controls,
polished unavailable-agent UI, exhaustive historical indexing and automatic
project relocation/reconciliation remain deferred. Only Pi is selectable in
production. Before adding another harness, activation arbitration must enforce
the approved one-active-harness rule; owner routing here is not hot switching.

Phase 5 should implement explicitly authorized managed-installation transactions
and agent management against Phase 3 installation IDs and Phase 2 ownership,
preserving Phase 4 session identities/caches when an executable is unavailable or
removed. Session ownership must not become installation ownership, and shared Pi
data must remain separately protected. No Phase 5 implementation, downloading,
update/remove flow, Agent Manager UI, runtime relocation, bundled removal,
packaging/signing change, other agent or Computer Use is included. No commit,
push or GitHub action occurred.
