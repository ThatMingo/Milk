# Pi profile ownership — Phase 1 report

1. **Previous behavior:** managed and external Pi selected different executable
   ownership but both inherited `PI_CODING_AGENT_DIR` or the normal `~/.pi/agent`.
   Provider settings and Extensions also resolved that shared path independently.
2. **New behavior:** Install Pi selects Milk-managed runtime plus Milk-managed
   persistent profile. Use Existing Pi selects external runtime plus existing setup.
   `AgentDataProfile.Ownership.milkManaged` makes this distinction explicit.
3. **Exact managed profile:**
   `~/Library/Application Support/Milk/Agents/pi/profile/`, beside state.json,
   versions/ and staging/. Tests inject a disposable agent root instead.
4. **Supported selection mechanism:** `PiInstallationManager` selects the profile;
   `PiLaunchResolver` sets `PI_CODING_AGENT_DIR` in the child environment before
   launching Pi. Managed launches require a managed profile. Ambient overrides
   cannot redirect a managed installation to the normal Terminal profile.
5. **Isolated state:** Pi's agent-directory configuration, models, native auth,
   extensions, skills, prompts, themes, tools, sessions/history and associated
   persistent agent state. The pinned source's `getAgentDir`, config/auth/models
   accessors, settings manager and session manager were inspected. This is profile
   selection, not a security sandbox: project configuration, explicitly referenced
   resources and trusted extension code keep Pi's normal behavior. Linked managed
   profile paths are rejected, including nested symlinks. A managed launch rejects
   resume files outside its profile; original files remain untouched.
6. **Existing Pi:** its ambient `PI_CODING_AGENT_DIR` continues to select its setup;
   otherwise its existing HOME/.pi/agent is used. No profile is copied or redirected
   into Milk. The UI states that changes may also affect Pi outside Milk.
7. **Settings follow ownership:** Pi provider settings and extension management use
   the selected profile. Package operations use the same location as launch.
   Managed provider drafts have their own UserDefaults key, scoped to Milk's agent
   root; Existing Pi retains the previous settings key. No existing draft or user
   profile is migrated/copied/deleted. The provider settings view resets its draft
   when installation selection changes. Local limits and auth mechanisms are
   unchanged, including the existing agent/provider/endpoint Keychain facility.
8. **Remove/reinstall:** existing removal operations delete version/runtime trees,
   never profile/. Removing the selected managed runtime still produces explicit
   no-runtime state; there is no executable fallback. Reinstall selects the same
   retained managed profile and settings. There is no Delete Pi Data feature.
9. **Files changed in this phase:** listed below. The earlier provider refactor is
   retained on the same branch; its historical report describes the earlier state.
10. **Focused verification:** only `PiProfileOwnershipTests` was executed, followed
    by a targeted rerun. Four tests cover managed launch/profile environment and
    real pinned Pi RPC startup; Existing setup and switching; provider writes;
    remove/reinstall retention; and root/nested symlink rejection. The first
    compile attempt used an incorrect test helper method name (corrected). The
    group then had three passing tests and one URL-equality assertion failure
    caused by a directory trailing slash. That assertion was corrected and its
    targeted rerun passed. No full suite, packaging or unrelated tests ran.
11. **Pi limitations:** `PI_CODING_AGENT_DIR` selects persistent agent state, not
    an entire sandboxed HOME. Explicit project resource references and extension
    behavior are not restricted by it. Existing native sessions outside the new
    managed profile must be resumed with their original Existing Pi setup; this
    phase deliberately adds no copying/migration framework. Compatibility checks
    continue to use disposable probe storage.
12. **Real user data:** verification did not modify the real `~/.pi`. Persistent
    writes used disposable fixture roots, UserDefaults suites and profiles. The
    real-Pi launch had explicit disposable HOME and PI_CODING_AGENT_DIR. External
    switching tests use a stub compatibility probe and do not write that profile.
13. **Git/scope:** continued `refactor/agent-provider-settings`. Nothing pushed,
    merged or rewritten. Work remains uncommitted. No Local-provider correction,
    chat rendering, session deletion work or other agent implementation was begun.

Changed/added files for this phase:

- `Sources/Milk/PiProfile.swift` (added)
- `Sources/Milk/AgentInstallation.swift`
- `Sources/Milk/PiInstallationManager.swift`
- `Sources/Milk/PiLaunchContext.swift`
- `Sources/Milk/PiBackend.swift`
- `Sources/Milk/PiAdapter.swift`
- `Sources/Milk/PiProviderConfiguration.swift`
- `Sources/Milk/PiSettings.swift`
- `Sources/Milk/ExtensionService.swift`
- `Sources/Milk/AgentsSettingsView.swift`
- `Sources/Milk/ShellState.swift`
- `Tests/MilkWorkspaceTests/PiProfileOwnershipTests.swift` (added)
- `README.md`
- `RUNTIME.md`
- `docs/README.md`
- `docs/AGENT_PROVIDER_SETTINGS.md`
- `docs/PI_PROFILE_OWNERSHIP.md` (added)

Commands used the Xcode toolchain, workspace-local module/cache directories and
`swift test --disable-sandbox --cache-path "$PWD/.build/cache" --filter
PiProfileOwnershipTests`, then the exact failing method filter
`PiProfileOwnershipTests/testManagedSelectionSettingsRemovalAndReinstallPreserveProfile`.
Local logs: `/tmp/milk-profile-tests.log`, `/tmp/milk-profile-rerun.log`.


## Profile-scoping correction

This correction supersedes the earlier report's statements about the shared
Existing-Pi settings key and agent/provider/endpoint-only Keychain namespace.

1. **Identity:** `PiProviderProfileIdentity` hashes a versioned structured tuple of
   canonical profile directory and external installation ID (for Existing Pi).
   Managed revisions use their preserved profile directory, so reinstall/update
   retains identity. Display names and runtime version numbers are not used.
2. **Settings:** managed drafts retain their already-unique agent-root namespace.
   External drafts use `Milk.agent.pi.providers.v1.profile.<identity>`, rather
   than one generic Existing Pi key. Standalone/test adapters also derive identity
   from the effective profile and runtime registration. Unavailable selection does
   not fall back to the old generic key. Settings models bind their originating
   profile and reject applying an old draft after switching.
3. **Keychain:** current Pi adapter accounts include agent + profile identity +
   provider + endpoint. Save, rollback, stored-key detection, discovery and Pi
   runtime translation all use the same identity. Secrets remain solely in
   Keychain and the existing in-memory child/request transport. Old unscoped
   credentials/settings are retained, but are not automatically attributed to an
   arbitrary profile. No secret is copied into UserDefaults.
4. **Two Existing installations:** distinct registration identities produce
   distinct Milk-side namespaces even when their effective directory happens to
   be the same. Switching restores each one's settings and scoped credential.
   If the user deliberately selects the same actual Pi directory for both,
   native Pi files remain physically shared as intended by Existing Pi behavior;
   this correction isolates Milk-owned state, not those existing files.
5. **Files changed for this correction:**
   `Sources/Milk/PiProfile.swift`, `Sources/Milk/AgentProviderCredentials.swift`,
   `Sources/Milk/PiAdapter.swift`, `Sources/Milk/PiBackend.swift`,
   `Sources/Milk/PiSettings.swift`, `Sources/Milk/PiProviderSupport.swift`,
   `Tests/MilkWorkspaceTests/PiProfileOwnershipTests.swift`,
   `docs/AGENT_PROVIDER_SETTINGS.md`, and this document.
6. **Verification:** `PiProfileOwnershipTests` passed all five tests, including
   the four previous isolation tests. A targeted rerun of
   `testProviderStateAndKeychainAreScopedToEachProfile` passed after adding stale
   draft protection. Tests check three independent credentials at the same
   provider/endpoint, switch/restore settings, runtime credential resolution,
   absence of secrets in defaults, and stale-draft rejection. Temporary Keychain
   entries were removed. Existing Pi files and real ~/.pi were not modified.
   Commands used Xcode, workspace caches, `--disable-sandbox` and only these
   focused filters. Logs: `/tmp/milk-profile-scope-tests.log` and
   `/tmp/milk-profile-scope-rerun.log`. `git diff --check` passed.
7. **Unchanged:** managed profile location, PI_CODING_AGENT_DIR selection,
   Existing Pi's actual profile behavior, remove/reinstall, extensions, sessions,
   Local model limits, and Local auth transport. No Phase 2 work began.
8. **Git:** still `refactor/agent-provider-settings`; nothing pushed or merged.
   All work remains local and uncommitted.


## Final Existing profile identity correction

This supersedes the earlier scoping section's inclusion of executable registration
identity. Runtime installation identity identifies executable/code ownership;
profile identity identifies the actual resolved persistent Pi directory.

- Existing profile identity hashes the canonical resolved directory path only,
  with the existing version/domain marker. No executable ID, version or display
  name is included. Symlink aliases resolve to the same identity.
- Two executables sharing a profile share Milk-side settings, drafts, overrides
  and the profile/provider/endpoint Keychain account, matching their shared native
  Pi files. Two different directories retain separate namespaces.
- Managed identity hashes and its retained settings namespace are unchanged.
  An Existing registration explicitly resolving to this manager's managed profile
  also uses that profile's retained settings key, avoiding competing namespaces.
- No launch, installation, session, extension, authentication or Local limit
  behavior changed. Existing registration-scoped development records are not
  deleted or automatically merged into the canonical namespace.

Verification and exact file inventory are in the final correction section of
[Phase 3](PROVIDER_PROFILE_PHASE_3.md#final-existing-profile-identity-correction).
