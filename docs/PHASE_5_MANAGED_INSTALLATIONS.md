# Phase 5 — Pi managed installation transactions

> Historical phase record. This document records its original scope and evidence;
> it is not the current implementation or acceptance status. See
> [Agent final acceptance](AGENT_PHASE_FINAL_ACCEPTANCE.md) and the
> [source-publication audit](PRE_GITHUB_AUDIT.md). Evidence paths under `output/`
> refer to generated local files excluded from the public source tree.

Scope: backend only. This builds on the approved architecture amendments, Pi
parity contract and Phases 1–4. PiAdapter remains compiled into Milk and uses
native RPC. No agent-management UI or release packaging migration is included.

## Installation architecture

`ShellState.agentInstallations` owns the Pi manager, installation store and the
same lifecycle coordinator used by AgentService and Pi extension helpers.
`PiAdapter` routes conversation/Preview resolution and offline availability through
that manager when supplied. Existing bundled/external preferences remain the
initial selection until an explicit backend management action selects something
else. Construction does not download or start an agent.

`AgentInstallationStore` persists schema 1 at the existing Application Support
convention, `Milk/Agents/pi/state.json`, with sibling `versions/` and `staging/`.
Each installed immutable revision has its own UUID directory and Phase 3
installation ID; same-version repair also gets a fresh identity. Records contain
version/platform/architecture, approved artifact URLs/hashes, source/provenance,
notices, complete installed file inventory, compatibility/adapter evidence and
last verification time. State independently tracks selected, pending and previous
known-good IDs, external registrations, Auto Update (default OFF), operation
status/failure detail and pending removal tombstones. Running installation/version
observations come from current lifecycle leases, never stale persisted PIDs.

Atomic state writes, file/directory fsync, user-only metadata permissions and a
lifetime advisory root lock protect registration. A second Milk instance can
inspect metadata but cannot manage or launch managed installations from that
root while it is owned. Corrupt/newer state remains untouched and blocks unsafe
management; an unexpected outside state-file write also blocks commits.

Ordinary Pi data stays at its existing location, including explicit
`PI_CODING_AGENT_DIR`. No environment, provider token, credential, transcript or
extension configuration is stored in installation state. Session UUIDs and owners
are independent from executable revision IDs.

## Catalog and verification

`PiInstallationCatalog.standard` contains only Pi 1.4.0 for Darwin arm64. Its
three official archive URLs and SHA-256 pins are taken from the repository's
`Scripts/bootstrap-runtime.py` and `Runtime/PiRuntime/runtime-manifest.json`:
Pi plus the existing rg/fd runtime tools. Required executable/native/wasm digests
also come from that manifest. Other versions/platforms fail clearly; there is no
upstream-latest feed, marketplace, guessed URL or invented digest.

Installation downloads each artifact into a unique staging directory, hashes it
before extraction, and checks the expected archive layout, executable permissions,
thin 64-bit Mach-O CPU/platform, required runtime files and notice materials.
The small `MilkArchive` C bridge uses system libarchive to decode tar/gzip, then
writes through rooted `openat`/`O_NOFOLLOW`/`O_EXCL` operations. It rejects traversal,
absolute paths, links, special files, duplicate files, excessive entry counts and
oversized unpacked content, and does not apply archive ownership/xattrs/setuid bits.
The SDK supplies the library stub but omits its headers; the bridge declares only
the opaque reader ABI used here, checked against Apple's published libarchive 3
[archive API](https://github.com/apple-oss-distributions/libarchive/blob/main/libarchive/libarchive/archive.h)
and [entry API](https://github.com/apple-oss-distributions/libarchive/blob/main/libarchive/libarchive/archive_entry.h).
No third-party implementation or binary is vendored.

The candidate gets a pinned Phase 3 record and passes the existing isolated native
RPC/integration probe. The probe now also accepts an explicit installation record,
so managed integrity/version pins are preserved instead of classifying a candidate
as external. It retains its temporary user-data isolation and awaited cleanup.
The inventory is checked again after the probe. Only then is the complete runtime
renamed into a version directory and atomically registered as a verified candidate.
No partially extracted runtime becomes selected.

## Management behavior

- **Install/update:** build independently of current runtime files. While Pi-owned
  work exists, the verified candidate remains pending and sessions keep their
  current immutable executable. Natural quiescence can activate it; explicit
  `activatePending(stopRunning: true)` can perform an authorized drain. No automatic
  update interrupts work. Previous healthy code remains retained.
- **Auto Update:** a separate persisted policy, OFF by default. An explicit
  lifecycle/UI caller can request staging only a newer Milk-approved release. It
  does nothing for external/legacy selections, an existing pending update, or a
  catalog without an approved newer version. No scheduler is installed.
- **Select/rollback:** revalidate retained code and compatibility, close admission,
  recover/persist session drafts, await every owned Pi start/helper/session exit,
  then atomically change selection. An unconfirmed exit blocks mutation. Rollback
  is restricted to managed code and conservatively rejects differing recorded
  session runtime versions. It never attempts user-data rollback/conversion.
- **Verify/repair:** verification checks inventory and reruns the probe, recording
  health results. Repair reconstructs approved code into a new immutable revision;
  it cannot overwrite an in-use directory or repair an external executable. A
  corrupt revision does not displace the retained healthy rollback reference.
- **Remove:** individual managed-revision removal or `removeManagedPi` drains
  Pi-owned work, atomically deselects/removes registrations into tombstones, then
  deletes only validated owned version directories. Failed cleanup can be retried.
  A removed selected runtime means explicit no-runtime, never implicit bundled
  fallback. Session/index/cache records, native Pi files, configuration, extensions
  and secrets survive. Reinstall does not reassign session identity or ownership.
- **External:** register/revalidate with the isolated probe, select/use, or forget
  a registration. Managed update/rollback/repair/verify/removal APIs reject external
  ownership; forgetting does not delete executable files. Explicit existing Pi
  configuration/extension actions remain available and use composite owned leases.

The admission barrier includes conversation, pending, Preview, version, package,
compatibility and installation work. Short-lived version resolution cannot leave a
package-command gap in which its chosen runtime could be removed. Runtime leases
associate with the exact selected installation before awaited launch work.
Selection changes invalidate AgentService runtime state without changing session
owners, native references or integer editor mappings; they do not eagerly relaunch.

## Failure recovery and limits

Operation action/stage/detail support later Retry, Repair, Roll Back and Remove
presentation. A failed download/hash/extraction/probe/state write retains the old
selection. Cancellation cancels and awaits owned work. If probe exit cannot be
confirmed, staging code remains in place under lifecycle ownership until recovery
can confirm exit. `recoverInterruptedTransactions` requires no live Pi work,
finishes removal tombstones, and removes known failed/interrupted staging roots.
Unknown/orphan version directories are neither adopted nor automatically deleted.

A crash before candidate registration can leave an unreferenced complete folder;
state still points at the prior runtime. A crash during removal leaves an explicit
no-runtime selection and retryable tombstone. This is practical crash recovery,
not a filesystem snapshot or guarantee against every power-loss/storage failure.

Only one supported release currently exists. Tests exercise retained immutable
revisions, including same-version reconstruction; they do not invent compatibility
for a different Pi release. Broader session-format compatibility must be approved
before allowing cross-version rollback. Cross-instance exclusion is deliberately
conservative. Full-tree verification adds startup I/O and should be measured in
final acceptance before considering a safe verification cache.

Official archive download/install was not exercised over the network in this
phase. The catalog uses existing repository evidence. Missing notices or unexpected
upstream archive structure fails closed. Bun/native matching source/relink and
binary-distribution obligations remain unresolved; downloading artifacts does not
constitute legal clearance. Download execution/quarantine/signature/notarization
acceptance and clean-machine installation remain release gates.

Existing Runtime settings retain their transitional bundled/external presentation;
Phase 6 must reconcile those controls with the new authoritative managed selection
while wiring Settings → Agents. No new UI action or background update scheduler is
introduced here. Bundled Pi and all release scripts are unchanged.

## Focused verification actually run

Executed on 2026-10-31 with Xcode, workspace-local caches and elevated local fixture
execution, using only `swift test --filter …`. Evidence: `output/phase5/`.

| Log | Scope and actual result |
| --- | --- |
| `focused.log` | Compilation only: SDK lacked libarchive headers; no tests ran. Fixed the opaque system-library bridge. |
| `focused-retry.log` | Initial 8 installation tests: 2 passed, 6 failed from rejecting the macOS `/var` alias. |
| `path-diagnosis.log` | One failing transaction case: confirmed the `/var` ancestor rejection. |
| `path-fixes.log` | Six affected cases still failed; physical-path normalization alone did not eliminate the system alias. |
| `path-boundary.log` | One transaction case exposed a second alias issue in relative inventory paths after scoping link checks to the owned subtree. |
| `inventory-fix.log` | One transaction case passed after normalizing both sides of relative path calculations. |
| `remaining-fixes.log` | Six affected/strengthened cases passed, including actual rejection-reason assertions. |
| `focused-final.log` | Eight installation cases passed, 0 failures, after candidate-mutation, operation-state and failed-shutdown checks. |
| `lifecycle-session.log` | One targeted group: 7 existing lifecycle tests, owner-routed resume, and external extension package ownership; 9 passed, 0 failures. |
| `probe-exit-retention.log` | One additional focused case for retaining failed-probe staging until confirmed exit: 1 passed, 0 failures. |

The nine new characterization/transaction tests protect persisted installation and
Auto Update policy; old-code retention across integrity/probe failure; unsafe
archive/platform/missing-notice rejection before execution; concurrent/helper
staging and lifecycle admission/drain; rollback compatibility and failed-exit
retention; natural safe activation; immutable repair with shared-data preservation;
remove/reinstall session/index/draft identity; external mutation protection;
cancellation/crash/tombstone/corrupt-state recovery; and the managed-record native
probe/failed-probe cleanup boundary. Related checks are grouped into nine tests,
not exhaustive permutations. Native artifact layout is represented by local tar
and Mach-O header fixtures with an injected health result; a separate local RPC
peer exercises the actual managed-record compatibility probe. These tests do not
claim a live model/provider or real official network installation.

Test compilation built the changed app; no separate build ran. No full suite,
PiParityTests run, native verifier/harness, screenshot/visual inspection,
packaging/signing/notarization, clean-machine install or unrelated tests ran.
No commit, push or GitHub modification occurred.

## Exact source manifest

Added:

- `Sources/Milk/AgentInstallationStore.swift`
- `Sources/Milk/PiInstallationCatalog.swift`
- `Sources/Milk/PiInstallationManager.swift`
- `Sources/MilkArchive/MilkArchive.c`
- `Sources/MilkArchive/MilkArchiveABI.h`
- `Sources/MilkArchive/include/MilkArchive.h`
- `Tests/MilkWorkspaceTests/PiManagedInstallationTests.swift`
- `docs/PHASE_5_MANAGED_INSTALLATIONS.md`

Modified:

- `Package.swift`
- `Sources/Milk/AgentAdapter.swift`
- `Sources/Milk/AgentInstallation.swift`
- `Sources/Milk/AgentLifecycle.swift`
- `Sources/Milk/AgentService.swift`
- `Sources/Milk/ExtensionService.swift`
- `Sources/Milk/PiAdapter.swift`
- `Sources/Milk/PiCompatibilityProbe.swift`
- `Sources/Milk/PiLaunchContext.swift`
- `Sources/Milk/ShellState.swift`

Logs and before-change snapshots under `output/phase5/` are generated evidence,
not production source changes.

## Phase 6 recommendation

Wire the backend into Settings → Agents with explicit Managed by Milk / Existing
installation / no-runtime states, installed/selected/running versions, compatibility
and update policy, pending activation and actionable failure/recovery controls.
Reconcile legacy Runtime selection, provider-only saves, session availability and
installation notifications without bypassing lifecycle barriers. Preserve the
compiled Pi adapter and native integration. Plan bundled-runtime release migration
and provenance/execution acceptance under their separately authorized scope, with
the broad regression pass reserved for Phase 7. No Phase 6+ work, other agent,
Computer Use, marketplace or public SDK is implemented.
