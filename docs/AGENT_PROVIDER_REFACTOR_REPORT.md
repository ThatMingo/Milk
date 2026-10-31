# Agent provider settings refactor report

Branch: `refactor/agent-provider-settings`, based on current local `main`, commit
`7f8b2466bc8d8ae331ae5546ac697d3a977ad49b`. Changes are local and uncommitted.

1. **Old architecture.** Global `AgentConfiguration` owned oMLX, model lists,
   global token/capability defaults and authentication. Milk's extension registered
   an `omlx` provider in Pi, while AgentService continuously polled server status.
   This made a serving application's brand part of Milk core and supplied false
   universal model limits.
2. **New ownership.** Milk → Coding Agent → Provider → Model. Pi is the only
   production agent. Milk retains installation/lifecycle/session ownership;
   PiAdapter owns provider configuration and uses Pi's supported configuration/RPC.
3. **Workflow.** Settings → Agents → Pi installation controls, then adapter-owned
   Pi configuration. Choose Local, endpoint, None/API key, Test Connection, model,
   any genuinely missing per-model limits, then Save. Local controls disappear
   for Pi configured providers. No future-agent placeholders were added.
4. **Exact boundary.** `AgentAdapter.settingsProvider: (any AgentSettingsProviding)?`;
   the facet exposes `[AgentSettingsSection]` and
   `settingsView(section: String, agent: AgentService) -> AnyView`. Each section
   has `id` and `title`. Core hosts opaque native views. Pi owns its complete
   schema/draft/validation; `AgentService.applyAgentSettings(_:)` supplies generic
   lifecycle admission/reconnect. See the [current contract](AGENT_PROVIDER_SETTINGS.md#adapter-contract).
5. **Local behavior.** Generic OpenAI-compatible HTTP(S), optional scoped API key,
   read-only `/models` discovery, exact IDs and explicit errors. No brand-specific
   health/status calls, constant polling, model management or inference client.
6. **Pi configuration.** PiAdapter/PiProviderSupport merge the reserved `milk-local`
   entry into the selected Pi profile's documented `models.json`; secrets are
   environment references. Unrelated entries survive, original bytes are backed
   up on changes, collisions/malformed files fail safely. Startup selects exact
   IDs through `set_model` RPC. The integration extension registers no providers.
7. **Migration.** First Pi configuration access automatically copies legacy
   enabled state, endpoint, selected/discovered IDs and positive user capability
   declarations into `Milk.agent.pi.providers.v1`. Disabled stays disabled.
   All global old numeric limits are discarded. Migration commits only after
   credential copy/validation; original data remains and retries are idempotent.
8. **Credentials.** Generic Keychain service `dev.milk.agent-provider`, scoped by
   agent/provider/endpoint. The old `dev.milk.omlx` item is copied without deleting
   it or overwriting an existing new credential. No secret enters settings,
   sessions, logs, manifests, source or backups created from Milk's new config.
   Keys are passed only to discovery when requested and Pi's child environment.
9. **Capability sources.** Optional per-model server values and explicit overrides
   are separate. Explicit effective context/output fields outrank general reported
   fields and user overrides. Unknown remains unknown. Pi-reported models,
   context/output metadata and reasoning levels remain Chat's authority. Unknown
   reasoning/images are omitted from Pi config; Pi reports its conservative
   effective behavior through RPC. No compaction policy changed.
10. **32768/8192 audit.** No production model-limit fallback remains in Milk, and
    no replacement universal numbers were introduced. `8192` remains solely as a
    Preview networking receive-buffer byte count. Legacy values are not migrated
    as capabilities. Unknown Local limits block launch until supplied explicitly.
11. **Removed/replaced components.** Removed OMLXConfiguration, OMLXService,
    OMLXProviderSettingsAdapter, PiProviderID.omlx, OMLXCredentials, the
    MILK_OMLX_CONFIG/TOKEN launch path, extension provider registration, global
    telemetry/status and global provider/model controls. Replaced them with
    Pi-specific Local configuration/discovery/support plus generic settings and
    scoped secure-storage facilities. The independently installable oMLX status
    extension example is unchanged; its opt-in poller is not core telemetry.
12. **Exact file inventory.** Listed below. Historical Phase/planning records were
    not rewritten. Existing tests/harnesses were adapted only where the removed
    API or renamed protocol fixture required it.
13. **Verification.** Build succeeded. Thirteen provider/settings and two actual-Pi
    startup/routing test methods passed; only those groups and targeted failure
    reruns executed. A two-test targeted rerun passed save rollback/key removal and
    no-auth/legacy-provider history resume; the final one-test migration rerun also
    passed after confining legacy Keychain namespace knowledge to Pi migration. Sandbox Keychain failures passed with
    host access; the initial empty-header no-auth failure was fixed using Pi's
    documented placeholder mechanism. `git diff --check` and source audits passed.
    No full suite, packaging/signing/notarization, installation matrix, screenshots,
    broad visual inspection or unrelated test execution occurred.
14. **Pi limitations.** Static model configuration supplies numeric defaults when
    absent; Milk therefore requires discovered or explicit positive per-model
    limits. Minimal OpenAI model listings require manual metadata. Static None
    authentication uses Pi's non-secret placeholder bearer key; endpoints that
    reject even that header are unsupported by this mechanism. Endpoint/auth
    changes reconnect idle runtimes; no active-run mutation or hosted OAuth setup
    was invented. Other providers remain configurable in Pi. A terminal-launched
    Pi does not inherit Milk's Keychain-backed child variable. Cross-process
    simultaneous edits/force-quit cannot be made atomic across file/Keychain/defaults.
    [Pinned Pi models documentation](https://github.com/earendil-works/pi/blob/v1.4.0/packages/coding-agent/docs/models.md)
    and the matching configuration/RPC docs/source were inspected.
15. **Separate stability issues.** No transcript/live-entry/deletion fixes were
    attempted. Existing PiAdapter policy refuses native-history deletion for
    external installations; this may relate to the reported undeletable session,
    but no diagnosis was established. No transcript cause is claimed.
16. **User data/session preservation.** No actual user endpoint, server config,
    workspace, Keychain credential or session file was changed during verification.
    Tests used disposable directories/accounts. Production migration is copy-only;
    provider changes retain session identity/agentID, projects, drafts, caches and
    JSONL history. The real-Pi test resumes legacy `omlx`-referencing JSONL under
    Local with the same native session ID and preserved history prefix.
17. **Git.** Nothing pushed, merged, rebased or rewritten. `main` and the local
    `origin/main` reference still point to the starting commit. No public GitHub
    changes were made. The requested branch contains the uncommitted work.

## Changed files

### Added

- `Sources/Milk/AgentProviderCredentials.swift`
- `Sources/Milk/AgentSettings.swift`
- `Sources/Milk/PiLocalDiscovery.swift`
- `Sources/Milk/PiProviderConfiguration.swift`
- `Sources/Milk/PiProviderSupport.swift`
- `Sources/Milk/PiSettings.swift`
- `Tests/Fixtures/local_provider_fixture.py`
- `Tests/MilkWorkspaceTests/PiProviderRoutingTests.swift`
- `Tests/MilkWorkspaceTests/PiProviderSettingsTests.swift`
- `docs/AGENT_PROVIDER_REFACTOR_REPORT.md`
- `docs/AGENT_PROVIDER_SETTINGS.md`

### Modified

- `README.md`
- `RUNTIME.md`
- `Runtime/MilkPiIntegration.ts`
- `Sources/Milk/AgentAcceptanceVerification.swift`
- `Sources/Milk/AgentAdapter.swift`
- `Sources/Milk/AgentConfiguration.swift`
- `Sources/Milk/AgentModels.swift`
- `Sources/Milk/AgentService.swift`
- `Sources/Milk/AgentVerification.swift`
- `Sources/Milk/AgentsSettingsView.swift`
- `Sources/Milk/ExtensionVerification.swift`
- `Sources/Milk/MainWindow.swift`
- `Sources/Milk/PiAdapter.swift`
- `Sources/Milk/PiBackend.swift`
- `Sources/Milk/PiCompatibilityProbe.swift`
- `Sources/Milk/PiLaunchContext.swift`
- `Sources/Milk/SettingsService.swift`
- `Sources/Milk/SettingsView.swift`
- `Sources/Milk/SlashCommandVerification.swift`
- `Tests/MilkWorkspaceTests/AgentLifecycleTests.swift`
- `Tests/MilkWorkspaceTests/AgentManagerSettingsTests.swift`
- `Tests/MilkWorkspaceTests/AgentTests.swift`
- `Tests/MilkWorkspaceTests/NativeExtensionIntegrationTests.swift`
- `Tests/MilkWorkspaceTests/NoAgentSessionTests.swift`
- `Tests/MilkWorkspaceTests/PiIntegrationTests.swift`
- `Tests/MilkWorkspaceTests/PiParityTests.swift`
- `Tests/MilkWorkspaceTests/SettingsTests.swift`
- `Tests/MilkWorkspaceTests/SlashCommandPiTests.swift`
- `docs/README.md`

### Removed

- `Sources/Milk/OMLXService.swift`
- `Sources/Milk/ProviderSettings.swift`
- `Tests/Fixtures/omlx_fixture.py`

The fixture was renamed from `omlx_fixture.py` to `local_provider_fixture.py`
and expanded for protocol/authentication testing; Git shows delete/add while the
new file is unstaged.

## Exact focused runs

All Swift commands used Xcode, a workspace-local Clang module cache,
`--disable-sandbox`, and `--cache-path "$PWD/.build/cache"`.

| Filter / check | Actual result |
| --- | --- |
| `swift build` | Successful with Xcode; initial default-toolchain/cache and nested-sandbox attempts failed before source verification |
| `PiProviderSettingsTests` | 13 executed: 8 passed, 5 failed because sandboxed Keychain returned -50 |
| `PiProviderSettingsTests/(testLegacyMigration\|testPermissionSaves\|testSaveClears\|testScopedKeychain\|testSettingsBoundary)` | Those 5 passed with host Keychain access |
| `PiProviderRoutingTests` | 2 executed: authenticated case passed; empty-header no-auth failed |
| `PiProviderRoutingTests/testNoAuthPiRPCStartupModelThinkingAndResume` | Passed after adopting Pi's documented placeholder mechanism |
| `PiProviderSettingsTests/testSaveClearsSecretDraftRetainsUnchangedCredentialAndInstallationState\|PiProviderRoutingTests/testNoAuthPiRPCStartupModelThinkingAndResume` | Both passed with additional rollback/removal and legacy-history assertions |
| `PiProviderSettingsTests/testLegacyMigrationCopiesCredentialAndFlagsDiscardsGlobalLimitsAndIsIdempotent` | Final rerun passed, 0 failures |
| `git diff --check` | Passed |
| Production-source audit | No oMLX injection/telemetry or universal model-limit fallback; remaining 8192 is a Preview receive-buffer byte count |

There are 15 distinct focused test methods with passing executions. This does not
claim that a full suite or broad regression pass ran. Raw local logs are in
`/tmp/milk-provider-settings-tests.log`, `/tmp/milk-provider-keychain-rerun.log`,
`/tmp/milk-provider-routing-tests.log`, `/tmp/milk-provider-noauth-rerun.log`,
`/tmp/milk-provider-targeted-final.log` and `/tmp/milk-provider-migration-final.log`.
