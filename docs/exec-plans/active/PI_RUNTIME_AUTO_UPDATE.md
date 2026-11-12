# ExecPlan — Automatic Pi Runtime Updates

Status: implemented and fixture-verified; live (real network / real Pi release)
acceptance and app-release packaging still open.

## Goal

Milk discovers, verifies, stages, activates, rolls back, and maintains newer
stable Pi runtime versions without requiring a Milk application update, while
keeping every existing integrity, sandbox, compatibility, rollback and
user-data guarantee.

## Scope

In scope:

- Upstream release discovery for the official `earendil-works/pi` repository.
- Release eligibility, integrity verification and provenance metadata.
- Compatibility separation between "eligible for the isolated probe" and
  "verified for ordinary sessions".
- Automatic staging of newer stable releases when Auto Update is enabled and
  Pi runtime work is quiescent.
- Persisted rejection records so a bad candidate is not retried endlessly.
- Settings → Agents surfacing of discovered releases, release-check status and
  update availability.
- Fixture-based tests for discovery, integrity, probing, staging, rollback,
  offline behaviour, interruption recovery and disabled Auto Update.

Out of scope:

- Signing/notarisation of upstream Pi artifacts (not published upstream).
- Automatic updates of existing (externally owned) Pi installations.
- Agent-agnostic generalisation of the update scheduler for other agents.

## Current-state findings (before this work)

- `PiInstallationCatalog.standard` shipped a **compiled list of approved
  releases** (Pi 1.4.0 darwin arm64) plus `pinnedNotices`. Update targets came
  from that list, so a new Pi release required a Milk release.
- `PiCompatibilityPolicy.evaluate(version:)` had a `supportedVersions` set
  (`["1.4.0"]`). Anything else was `.unsupported` or `.untested`.
- `AgentManagerModel.latestApprovedVersion` and `catalog.approved(...)` were the
  only update sources; Auto Update could only stage a version already compiled
  into Milk.
- Installation staging, integrity pinning, quiescent activation, rollback and
  repair already existed and were transactional (`AgentRuntimeLease`, staging
  directory, immutable revision directories).
- Verified revisions stored a `PiCatalogRelease` snapshot, but the snapshot was
  derived from the compiled catalog, and the session launch gate did not use
  the machine-local verification results.

## Architecture mapping

```text
Settings → Agents (AgentManagerModel / AgentsSettingsView)
  → PiInstallationManager        (lifecycle, staging, activation, rollback)
  → PiReleaseDiscovery           (HTTPS upstream metadata, eligibility)
  → PiInstallationCatalog        (platform/arch, Milk-pinned tool artifacts)
  → PiCatalogRelease + PiReleaseOrigin (self-validating, stored metadata)
  → PiInstallationFiles          (download, digest, extract, inventory, validate)
  → PiCompatibilityPolicy        (eligibility vs verification gates)
  → PiCompatibilityProbe         (isolated RPC handshake, sandbox purpose)
```

Discovery does not replace verification. `PiReleaseDiscovery` produces a
candidate `PiCatalogRelease` whose `files` digests are empty. Digests are
pinned from the bytes that were actually verified and extracted, then the
candidate is probed, then registered.

## Implementation phases

1. **Discovery** — `Sources/Milk/PiReleaseDiscovery.swift`
   - `PiSemanticVersion` with correct ordering (`1.10.0 > 1.9.0`), strict
     three-component parsing, stable/pre-release distinction.
   - `PiUpstreamRelease` fixes the only repository/asset names Milk reads.
   - `candidate(from:)` rejects drafts, pre-releases, missing tags, missing
     digests, non-official asset hosts, and releases below the baseline.
   - `release(for:)` builds the runtime metadata including Milk-pinned
     auxiliary tool artifacts.
   - `verifySums(...)` cross-checks the archive digest against the release's
     own `SHA256SUMS` manifest, which is itself authenticated by the release
     API asset digest.

2. **Self-validating metadata** — `Sources/Milk/PiInstallationCatalog.swift`
   - `PiCatalogRelease.validate()` is network-free: version, platform,
     architecture, artifact digests, safe paths, notices, origin consistency.
   - `paths` / `pinning(_ inventory:)` pin the verified layout.
   - `PiInstallationFiles.validate(_ root:, release:)` enforces required paths,
     pinned digests, no symlinks/special files, and thin native Mach-O
     executables for the selected architecture.
   - `PiInstallationCatalog.standard` is empty: it is no longer an approval
     list. Tool pins are architecture-aware (arm64 only).

3. **Compatibility gates** — `Sources/Milk/PiCompatibility.swift`
   - `minimumEligibleVersion` (1.4.0) and `baselineVersions`.
   - `evaluate(version:, verified:)` where `verified` is the set of versions
     whose probe handshake succeeded on this machine.
   - `requireProbeEligible` (probe may inspect eligible versions) versus
     `requireSupportedVersion` (ordinary sessions need verification).

4. **Manager** — `Sources/Milk/PiInstallationManager.swift`
   - `refreshReleases(force:)`, `availableReleases`, `releaseCheckProblem`,
     `lastReleaseCheck`.
   - `verifiedVersions()` from stored health results.
   - `rejection(for:)`, `isRejected(_:)`, `recordRejection(_:reason:)`.
   - `automaticCandidates(force:)`, `stageAutomaticUpdateIfEnabled(force:)`,
     `checkForAutomaticUpdate()`, `scheduleReleaseChecks()`,
     `stopReleaseSchedule()`, `installLatest()`, `rollbackToRetained(_:)`.
   - Integrity failure and probe failure record a rejection and leave the
     installed revision untouched.

5. **Persistence** — `Sources/Milk/AgentInstallationStore.swift`
   - Additive optional state: `rejected: [PiRejectedRelease]?`,
     `lastReleaseCheck: Date?`. Older state files load unchanged.

6. **UI** — `Sources/Milk/AgentManagerModel.swift`,
   `Sources/Milk/AgentsSettingsView.swift`
   - `check` action ("Check for Updates"), latest eligible release row,
     rejection notice, release-check timestamp/problem, revised Auto Update
     subtitle.

7. **Scheduling** — `Sources/Milk/ShellState.swift`
   - Persistent shells schedule periodic release checks; automatic staging only
     happens when Auto Update is enabled and Pi work is quiescent.

8. **Tests** — `Tests/MilkWorkspaceTests/PiAutoUpdateTests.swift`
   - Local tar/Mach-O fixtures only. No test downloads a real Pi artifact.

## Non-negotiable invariants

- Release metadata is read only over HTTPS from the official repository, and
  only from the exact official asset download path for the tag and platform.
- Integrity digests come from upstream metadata and are compared with the
  downloaded bytes before extraction or execution. A digest computed from an
  unverified download is never treated as proof of authenticity.
- No runtime is registered or selected without a successful isolated RPC
  compatibility probe on this machine.
- An active Pi session is never interrupted: newer code is staged, activation
  waits for quiescence.
- Rollback and launch of an already verified revision require no network.
- Automatic updating never touches Pi or Milk user data, and never mutates an
  externally owned Pi installation.
- Unknown runtimes are never silently chosen.

## Progress checklist

- [x] Upstream discovery and eligibility rules implemented.
- [x] Compiled approved-version list removed.
- [x] Architecture-aware tool pins.
- [x] Stored per-revision provenance and pinned file digests.
- [x] Verified-version session gate.
- [x] Automatic staging on schedule + quiescent activation.
- [x] Rejection memory and no automatic retry.
- [x] Settings surface for check/update/rejection/release-check status.
- [x] Fixture tests for discovery, integrity, probe, staging, offline,
      interruption, rollback and disabled Auto Update.
- [x] Manual "Check for Updates" no longer blocked by the model's own busy flag.
- [x] Successful checks persist the discovered release list; failed reads do not
      stamp the interval; restarts reuse the persisted metadata.
- [x] Concurrent checks join the in-flight read instead of returning stale cache.
- [x] `swift build`, `swift build --build-tests`, `./scripts/build.sh`.

## Decisions and discoveries

- **Discovery is not a trust anchor by itself.** GitHub's release API is the
  metadata trust source; this is documented explicitly in
  `PiReleaseDiscovery` and `PiRuntimeUpdates` docs. Upstream publishes no
  detached signature, so Milk relies on the official asset digest plus the
  release's own `SHA256SUMS` cross-check.
- **Discovered candidates start with empty `files`.** `validate()` therefore
  accepts an empty pinned-file map, requiring `pi` once digests are pinned.
- **`PiSemanticVersion.parse` is strict.** `1.4` and `nightly` are rejected, so
  a malformed tag is never eligible.
- **Tool artifacts are Milk-pinned, not inferred from the Pi archive.** Their
  digests are Milk trust anchors; tests supply fixture tool digests because a
  pinned production digest must match the bytes actually downloaded.
- **Verified sessions gate on stored health, not a compiled list.** The
  `verified` branch of `evaluate` now reports `integrationHandshake` evidence,
  otherwise `usable` would incorrectly stay false for a probed revision.
- **Repair requires the network** (it reconstructs from the upstream artifact);
  rollback does not. Both behaviours are tested.
- **A check is only "done" when the read succeeded.** `lastReleaseCheck` is
  stamped only on a successful feed read, and the discovered releases are stored
  with it. Otherwise a restart inside the window would report no releases, and a
  transient network failure would suppress retries for 24 hours.
- **Busy state is owned by the caller.** `perform(.check)` sets `performing`, so
  the release read itself must not re-guard on `busy`; the guarded public entry
  point is `refreshReleases()`.
- **In-flight checks are joined, not short-circuited.** The earlier `discovering`
  boolean made a second caller return the stale cache. `refreshReleases` now keeps
  the running read as `PendingReleaseCheck` (id + task), a concurrent caller awaits
  its completed value, and the handle is cleared when the pass finishes so a later
  check starts a fresh read. A cancelled pass returns the previous cache without
  recording a failure.

## Validation performed

- `swift build --cache-path .build/cache` — succeeds.
- `swift build --build-tests --cache-path .build/cache` — succeeds (warnings only).
- `./scripts/build.sh` — production app build succeeds.
- `swift test --filter "PiAutoUpdateTests"` — 12 tests, 0 failures.
- `swift test --filter "PiManagedInstallationTests|AgentManagerSettingsTests|SandboxPurposeTests|PiProviderConsistencyTests|PiAutoUpdateTests|AgentLifecycleTests"`
  — only the four pre-existing environment-dependent failures
  (`AgentLifecycleTests` ×2, `PiManagedInstallationTests.testManagedRecordProbeUsesNativeHandshakeAndIntegrityPins`,
  `PiProviderConsistencyTests.testRealManagedInstallLocalSwitchingResumeAndReinstall`).
- Full-suite failure set was compared against a pristine `HEAD` worktree run in
  the same environment: no test that passed before fails now; several
  previously failing fixture-dependent tests now pass.

## Not yet verified

- Live discovery against `api.github.com` from the built app (real network).
- A real end-to-end managed install/upgrade in the running app UI, including
  activation while a session is open and rollback afterwards.
- Behavior on x86_64 Macs (Milk ships Apple Silicon only; the tool pins are
  arm64-only by design and no tools are downloaded on other architectures).
- Packaging/notes for releases that list the discovered runtime version.

## Remaining / deferred work

- Live acceptance checklist for Auto Update in the shipped app.
- Optional: show the upstream release publish date and per-release provenance in
  Settings beyond the current provenance line.
- Optional: generalize the release schedule for future non-Pi adapters.
