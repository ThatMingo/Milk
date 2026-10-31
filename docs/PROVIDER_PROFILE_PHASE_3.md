# Provider/profile consistency — Phase 3 completion report

Branch: `refactor/agent-provider-settings`. This phase added focused verification;
no production architecture or behavior was changed.

1. **Managed flow: passed end-to-end.** The test built a disposable local artifact
   from the repository's pinned Pi 1.4.0 executable, package metadata and runtime
   dependencies, verified pinned file hashes, and used the production installer,
   compatibility probe, installation manager, PiAdapter and native RPC backend.
   No upstream download or release matrix ran. Actual fixture inference passed
   from the installed managed executable under the isolated managed profile.
2. **Existing Pi: passed.** Two disposable external executable registrations were
   verified with real compatibility probes. Existing Pi retained the explicit
   disposable Terminal profile supplied by PI_CODING_AGENT_DIR. It was not
   redirected into the managed profile. The existing-profile runtime performed
   inference and wrote native history under that existing profile.
3. **Switching isolation: passed.** Managed and Existing settings were saved through
   PiAdapter, then switched and restored with full configuration equality. This
   includes provider selection, endpoint, authentication, selected ID, reported
   metadata and per-model overrides. Separate profile-scoped credentials resolved
   at the same endpoint. Extensions and native histories stayed in their respective
   profiles. The managed backend rejected an explicit foreign-profile resume file;
   neither native file was moved or deleted.
4. **Multiple Existing installations: passed with corrected profile identity.** Two
   external executable registrations using the same canonical directory share the
   same Milk-side profile identity, settings, model overrides and scoped credential.
   Writes through the second registration are visible through the first, matching
   their shared native Pi files. A separate focused ownership test uses a different
   resolved profile directory to verify isolation. Runtime registration identities
   remain distinct for executable lifecycle management.
5. **None authentication: passed through actual Pi.** The fixture rejected any
   Authorization header in None mode. Managed Pi inferred successfully, and the
   recorded wire-level requests contained no Authorization header. Milk's existing
   before_provider_headers implementation was not changed.
6. **API key: passed through actual Pi.** The same loopback endpoint switched its
   expected credential between a managed key and a distinct Existing-profile key.
   Wrong keys would return 401. Both profiles inferred successfully; requests had
   authentication only in API-key mode. Secrets were temporary Keychain entries
   and were deleted after testing; the request log contains no credential values.
7. **Limits: passed.** Actual discovery supplied reported metadata. The selected
   exact model ID `org/Qwen:Q4_K_M` had context/output intentionally cleared to
   unknown in the disposable draft. Both fields stayed absent from models.json,
   and actual Pi startup/inference worked. A second model used a context override
   with reported output; a third used reported context with an output override.
   Both serialized configuration and Pi's RPC catalog matched these independent
   choices. The focused 16-combination precedence test also passed. Pi's runtime
   defaults were not copied into Milk's settings or replaced by Milk constants.
8. **Remove/reinstall: passed.** Production managed runtime removal cleared runtime
   selection and selectedInstallation threw the explicit no-runtime error despite
   registered externals being present. Provider configuration, endpoint, model
   state, extensions, native JSONL and scoped credential survived. Reinstallation
   reused the same managed profile and stable identity; configuration equality
   and another native session resume passed. No data-delete feature was added.
9. **Managed session resume: passed.** The original managed JSONL path remained
   beneath the managed profile. After an Existing Pi inference and a switch back,
   native RPC resumed the original session ID and restored its prompt history.
   Its original JSONL bytes remained a prefix of the retained file. Resume also
   passed after managed remove/reinstall. A foreign Existing JSONL was rejected
   under the managed profile without altering it.
10. **Settings wiring: passed at model/native-view-construction and source level.**
    The test checked installation status, the Pi settings facet, provider selection
    and Local draft validation, and constructed the adapter's native settings view.
    The source check confirmed Agents hosts Pi settings; installation status and
    managed/existing clarification are wired; Local fields are conditional on
    Provider=Local; global Settings contains no oMLX/provider schema. The real
    integration test exercised actual provider save/load through the same adapter.
    No screenshot, rendered UI inspection, click automation or visual redesign ran.
11. **Architecture audit: passed for active production paths.** AgentService has no
    oMLX ownership, direct Local discovery or global provider telemetry. Production
    Swift contains no legacy oMLX configuration/service/injection, direct inference
    route, health/status polling, or universal model-limit defaults. The remaining
    8192 in StaticPreviewServer is a byte receive buffer. Pi's integration registers
    no provider or model limits. Adapter settings/discovery/save/rollback and runtime
    credential resolution all supply profile identity. Legacy unscoped Keychain
    recovery code remains in the old generic configuration loader, but current
    production adapters use profile-specific keys and do not enter that legacy
    branch; no selected-profile path reuses unscoped credentials. Migration strings,
    explicit developer verification modes and optional example extensions are not
    active global-provider architecture.
12. **Defects/fixes: no production defect found.** Test-fixture corrections were
    required: supply mandatory artifact notice metadata; include the pinned
    package.json (Pi reads its version from it, otherwise reports 0.0.0); and
    compare directory URL paths instead of trailing-slash-sensitive URL values.
    The fixture extension marker's Swift interpolation was also corrected before
    final execution. These changes did not alter the installed production system.
13. **Exact files changed during Phase 3:**
    - `Tests/MilkWorkspaceTests/PiProviderConsistencyTests.swift` — added focused
      real-installer/RPC flow and Settings/source audit tests.
    - `Tests/Fixtures/local_provider_fixture.py` — added an optional disposable
      auth-control file and alternate fixture credential for strict profile-switch
      testing at one endpoint. Existing fixture modes are preserved.
    - `docs/PROVIDER_PROFILE_PHASE_3.md` — this report.
    - `docs/README.md` — added this report to current references.
14. **Exact focused checks/results:** using Xcode, workspace-local Clang/SwiftPM
    caches and --disable-sandbox, the following filters ran:

    ```sh
    swift test --disable-sandbox --cache-path "$PWD/.build/cache" --filter 'PiProviderConsistencyTests|PiLocalProviderTests/testOverridePrecedenceIndependentlyForContextAndOutput'
    swift test --disable-sandbox --cache-path "$PWD/.build/cache" --filter PiProviderConsistencyTests
    git diff --check
    ```

    The first command passed the existing 16-combination precedence method and
    failed the integration fixture's missing notice metadata. Narrow integration
    reruns exposed the incomplete package.json fixture and URL assertion described
    above. Final PiProviderConsistencyTests execution: **2 tests passed, 0 failures**
    (real integration plus Settings/source audit). Together, **3 distinct focused
    methods passed**. No full Swift suite, broad regression, packaging/signing/
    notarization, screenshots or unrelated tests were run. Local logs:
    `/tmp/milk-phase3-integration.log`, `/tmp/milk-phase3-integration-rerun.log`,
    `/tmp/milk-phase3-final.log` (the last contains the final passing group).
15. **Real user data: untouched.** All installer roots, HOME, profile directories,
    workspaces, session files, defaults suites, Keychain accounts, fixture control
    files and request logs were disposable. No real ~/.pi, production Milk profile,
    user session, local model server configuration or endpoint was modified. The
    test also asserted that the disposable HOME/.pi was never created. No diagnosis
    or fix for transcript rendering, live entries or session deletion was attempted.
16. **Git/scope:** remained on `refactor/agent-provider-settings`, keeping Phase 1/2
    work. Nothing was pushed, merged or rewritten. Changes remain local and
    uncommitted. No additional agent/provider, architecture or migration machinery
    was added. Stopped after Phase 3.


## Final Existing profile identity correction

1. **Runtime vs profile:** runtime identity still names the installation/executable.
   Profile identity names the persistent resolved Pi directory. Executable
   registration is no longer included in Existing profile identity.
2. **Exact rule:** canonicalize the Pi profile URL using standardizedFileURL and
   resolvingSymlinksInPath, then hash the versioned structured path tuple. The
   existing domain marker is retained to keep managed hashes unchanged. Display
   names, executable paths and runtime versions do not affect profile identity.
3. **Shared directory:** distinct Existing executable registrations using one
   canonical directory share provider settings, drafts, model overrides and the
   profile/provider/endpoint credential account. A write through either registration
   is restored through the other; symlink aliases also identify the same profile.
4. **Different directories:** separate identities/settings/Keychain scopes. A test
   uses independently selected disposable environments with different profile paths
   but the same defaults store and endpoint, proving no provider-state bleed.
   Managed Pi remains separate and its original identity hash is explicitly checked.
5. **Exact files changed in this correction:**
   - `Sources/Milk/PiProfile.swift`
   - `Tests/MilkWorkspaceTests/PiProfileOwnershipTests.swift`
   - `Tests/MilkWorkspaceTests/PiProviderConsistencyTests.swift`
   - `Tests/MilkWorkspaceTests/PiProviderRoutingTests.swift` (identity constructor)
   - `Tests/MilkWorkspaceTests/PiLocalProviderTests.swift` (identity constructor)
   - `docs/AGENT_PROVIDER_SETTINGS.md`
   - `docs/PI_PROFILE_OWNERSHIP.md`
   - `docs/PROVIDER_PROFILE_PHASE_3.md`
6. **Focused verification:** `PiProfileOwnershipTests` (5 passed) and
   `PiProviderConsistencyTests` (2 passed): **7 tests, 0 failures**. The latter
   reruns the real pinned-Pi install → managed profile → Local inference → Existing
   profile switching → native resume → remove/reinstall path, plus Settings/source
   audit. The former covers shared vs genuinely different directory state,
   canonical aliases, scoped credentials and unchanged managed identity/isolation.
   Used Xcode, workspace caches and:

   ```sh
   swift test --disable-sandbox --cache-path "$PWD/.build/cache" --filter 'PiProfileOwnershipTests|PiProviderConsistencyTests'
   git diff --check
   ```

   `git diff --check` passed. Log: `/tmp/milk-existing-profile-identity.log`.
   No full suite ran; all persistent test state and credentials were disposable.
7. **Other behavior unchanged:** no managed profile, launch, installation, removal,
   session, extension, Chat, Settings layout, no-auth hook, API-key transport, Local
   limits, discovery or inference ownership change. Existing provisional
   registration-scoped development records were not deleted or merged; the
   canonical namespace is now the active Existing profile scope.
8. **Git:** still `refactor/agent-provider-settings`. Nothing pushed or merged;
   changes remain local and uncommitted. Stopped after this correction.
