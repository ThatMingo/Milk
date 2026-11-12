# Pi Auto-Update Bug Fix Report

## 1. Root causes

**Manual "Check for Updates" never ran** (`Sources/Milk/AgentManagerModel.swift`)

- `perform(.check)` set `performing = true`, then called `refreshReleases()`.
- `refreshReleases()` guards on `busy`, which is `performing || manager.busy`.
- The action therefore blocked on its own busy flag and never reached `manager.checkForUpdates()`.
- Secondary issue: after the switch, `perform` overwrote the check's own feedback with the generic "Done. User data and session ownership are preserved." line.

**Automatic checks were skipped after restarting Milk** (`Sources/Milk/PiInstallationManager.swift`)

- The discovered release list lived only in the in-memory `availableReleases` array.
- Only `lastReleaseCheck` was persisted to the state file.
- A new manager therefore started with an empty cache plus a recent timestamp, so the interval gate returned `[]` and Settings/Install reported no available releases.

**Failed network checks blocked retries for 24 hours** (`Sources/Milk/PiInstallationManager.swift`)

- `lastReleaseCheck` was stamped unconditionally, including after a discovery exception.
- A failed feed read was recorded as a completed check, suppressing the next scheduled attempt until the interval elapsed.

## 2. Files changed

- `Sources/Milk/AgentManagerModel.swift` — split the release read into a private `checkReleases()`; `refreshReleases()` keeps the busy guard for direct UI calls; `perform(.check)` calls the read directly; `.check` no longer overwrites its own feedback.
- `Sources/Milk/PiInstallationManager.swift` — `refreshReleases(force:)` now seeds from persisted metadata, stamps the timestamp only after a successful read, keeps the existing cache on failure, and tracks `checkedThisSession`.
- `Sources/Milk/AgentInstallationStore.swift` — additive `discoveredReleases: [PiCatalogRelease]?` state field (schemaVersion unchanged; older state files still load).
- `Tests/MilkWorkspaceTests/PiAutoUpdateTests.swift` — fixture refactor (`fixtureManager`, `retiredManager`, `restartedManager`, dynamic feed JSON, `feed.fetches` counter) plus five new regression tests.
- `docs/PI_RUNTIME_UPDATES.md` — scheduling and state sections updated.
- `docs/exec-plans/active/PI_RUNTIME_AUTO_UPDATE.md` — progress checklist and decisions updated.

## 3. Summary of fixes

- Manual checks always read the feed: `checkForUpdates()` calls `refreshReleases(force: true)`, bypassing the 24-hour window and working whether Auto Update is on or off.
- A successful read writes both `lastReleaseCheck` and `discoveredReleases` (capped at 20 entries) to the state file. On restart, the manager seeds its cache from that list, filtered to entries that still self-validate and name the official repository.
- A failed read leaves the timestamp unset and the previous cache intact, so the next scheduled pass retries immediately instead of waiting 24 hours.
- The interval gate never short-circuits when there is no release list to reuse, so a restart can never end up with "no releases available" because a previous check happened.
- Overlapping checks are still collapsed by the existing `discovering` flag: exactly one upstream request per concurrent group.
- Staging, integrity verification, isolated probing, rollback, rejection memory, and the Settings UI behaviour are unchanged.

## 4. Tests added and results

New tests in `Tests/MilkWorkspaceTests/PiAutoUpdateTests.swift` (fixtures only; no real Pi artifact is downloaded):

- `testManualCheckForUpdatesRunsThroughTheModelAction` — `perform(.check)` fetches, reports "Pi 1.5.2 is available and eligible for this adapter…", status becomes "Update available", the selected runtime is unchanged, and a second manual check refetches.
- `testManualCheckReportsAnUnavailableFeedWithoutBreakingTheRuntime` — an offline feed surfaces the problem, the verified version stays valid, and `needsVerification` stays false.
- `testRestartAfterASuccessfulCheckKeepsReleaseMetadataWithoutRefetching` — two releases persisted; restart returns them with zero extra fetches; ageing the timestamp forces one fresh read; the stored revision still validates offline against on-disk digests; the update path still installs 1.5.2 with 1.4.0 retained for rollback.
- `testFailedReleaseCheckIsRetriedInsteadOfBlockingTheInterval` — an offline pass records a problem and no timestamp; the next pass recovers; a non-forced pass inside the window makes no request; the recovered feed then completes an automatic update.
- `testConcurrentReleaseChecksShareOneUpstreamRead` — two overlapping forced checks produce exactly one upstream request.

Results actually executed:

- `swift test --filter "PiAutoUpdateTests"` → 17 tests, 0 failures.
- `swift test --filter "PiAutoUpdateTests|AgentManagerSettingsTests|PiManagedInstallationTests|SandboxPurposeTests|PiProviderConsistencyTests"` → 53 tests, 13 failures; the same suites fail 14 times on a pristine `HEAD` worktree in the same environment (all environment/fixture-dependent sandbox tests, none introduced here).
- Full suite → 325 tests, 31 distinct failing tests vs 39 on the pristine `HEAD` worktree; no previously passing test now fails. The extra name `SandboxPurposeTests testPythonScriptVersionExecutesWithinDeclaredClosure` passes when run alone, so it is a full-suite flake unrelated to these changes.

## 5. Build result

- `./scripts/build.sh` succeeded and produced `output/Milk.app` (only the usual `install_name_tool` re-signing warnings).
- `swift build --build-tests` compiles cleanly (pre-existing deprecation and unused-variable warnings elsewhere in the codebase).

## 6. Concurrency fix (follow-up)

**Bug** — `Sources/Milk/PiInstallationManager.swift` kept a `discovering` boolean. A second caller arriving while a check was running hit `if discovering { return availableReleases }` and received the previous cached list, so a manual "Check for Updates" could report stale availability while an automatic check was in progress.

**Fix** — the boolean is replaced by `PendingReleaseCheck` (`id` + `Task<[PiCatalogRelease], Never>`). `refreshReleases()` checks the in-flight handle before the cache-interval gate; a joining caller awaits the running task's completed value, so every caller gets the freshly read list and no second upstream request is started. The handle is cleared after the task returns (guarded by the id so a later pass cannot be clobbered), and the task always returns — success, feed error, or cancellation — so no stale in-flight state is left behind. A cancelled pass returns the existing cache without recording a check problem; a failed pass still leaves `lastReleaseCheck` unset so the next scheduled pass retries. The 24-hour automatic interval, the manual force path, and the persisted release cache are unchanged.

**Tests added**

- `testConcurrentChecksReturnTheFreshResultNotTheStaleCache` — warm cache of 1.4.0/1.5.2, upstream publishes 1.6.0, a forced manual check and a scheduled pass run concurrently; both return [1.6.0, 1.5.2, 1.4.0] and exactly one upstream read occurs (a stale return or a duplicate request would fail the test).
- `testFailedSharedCheckIsRetriedRatherThanCachedAsCompleted` — two concurrent forced checks against an offline feed both return the empty cache, the problem is recorded, no timestamp is stored, and the next forced check recovers and repopulates the cache; a later non-forced pass inside the interval reuses it without refetching.
- `testConcurrentReleaseChecksShareOneUpstreamRead` (existing) still passes.

**Results** — `swift test --filter "PiAutoUpdateTests"`: 19 tests, 0 failures. Full suite: 31 distinct failing tests, identical to the pre-change run, and the one extra `SandboxPurposeTests` name in that list passes when run alone. `./scripts/build.sh`: Build complete, `output/Milk.app` produced. `LICENSE` untouched.

## 7. Remaining issues and limitations

- The restart test models a restart by releasing the store's flock and rebuilding a manager over the same state file; it does not launch a second Milk process.
- Persisted release metadata is treated like any other local state: it is re-validated and origin-checked before use, and every download is still digest-verified, but the state file itself is the local trust anchor.
- `PiUpdateSchedule.interval` remains a fixed 24-hour constant and is not user-configurable.
- End-to-end Auto Update in the running app against the real GitHub feed (real download, staging while a session is open, activation, rollback, repair) is still unverified.
- Nothing has been committed. Working tree: 16 modified files plus `PiReleaseDiscovery.swift`, `PiAutoUpdateTests.swift`, `docs/PI_RUNTIME_UPDATES.md`, `docs/exec-plans/active/`.
