# Provider/profile final acceptance

Validated locally on `refactor/agent-provider-settings`, based on main commit
`7f8b2466bc8d8ae331ae5546ac697d3a977ad49b`. This is source/development acceptance,
not downloadable-release qualification.

1. **Architecture:** Milk → Coding Agent → Provider → Model. Pi alone supplies the
   production agent adapter. Installation ownership and canonical-path profile
   identity are separate. Managed Pi uses Milk/Agents/pi/profile; Existing Pi
   intentionally uses its existing setup. Two executables using one canonical
   profile share its provider settings and credentials; different paths isolate
   state. Managed runtime removal preserves profile data and produces no-runtime
   state; reinstall reuses it.
2. **Accumulated review:** reviewed the tracked diff against main and all new
   production files, fixtures/tests and current-facing docs. No parallel Milk
   inference stack, global provider/oMLX ownership or polling remains. Chat gets
   model/reasoning data from the active agent. Exact IDs, per-model optional
   capabilities, independent override → reported → omission limits, true None
   header omission and profile-scoped API-key transport remain verified. Native
   history/profile boundaries and extension ownership passed integration checks.
3. **Final defects corrected:** the refactor's idle-only provider guard had also
   blocked the pre-existing runtime selection operation from cancelling a pending
   start. Runtime selection now uses the common persistence/reconnect operation
   under its original running/approval guard; provider edits keep the stricter idle
   guard. The native acceptance helper now resolves managed Pi through its manager
   rather than bypassing profile selection. Developer verification provider fixtures
   use the final profile-scoped key. Stale tests were corrected for scoped credentials,
   managed profile requirements and the independent oMLX example's command name.
   Current docs were corrected to distinguish retained legacy development records
   from automatic selected-profile imports. No unrelated production cleanup occurred.
4. **Clean build:** `swift package --disable-sandbox clean`, then Xcode
   `swift build --disable-sandbox --cache-path "$PWD/.build/cache"`: passed.
   The corrected sources were rebuilt by targeted tests, the native development
   build and the subsequent complete regression run.
5. **Full suite:** final run **183 tests passed, 0 failures**. Initial full run:
   183 tests, 8 failing assertions/errors across 5 cases (2 unexpected errors).
   All five cases passed targeted reruns after the fixes above, then the entire
   suite passed again. No failure was waived.
6. **Native acceptance:** normal local `scripts/build.sh --disable-sandbox` passed
   with explicitly ad-hoc signing. `Milk --verify-agent-acceptance
   --acceptance-external <pinned-pi>` exited 0 with **12 PASS, 0 FAIL/BLOCKED**.
   It exercised fresh no-agent state, external isolated handshake, official managed
   download/hash/extraction/probe/activation, verify/repair/remove/reinstall and
   awaited owner cleanup. The required managed profile was selected correctly.
   No redundant screenshot/native-UI verifier sweep was run; this is the normal
   mechanical acceptance path used by the preceding source baseline.
7. **Focused branch acceptance:** **27 tests passed, 0 failures** across
   PiProfileOwnershipTests, PiProviderConsistencyTests, PiLocalProviderTests,
   PiProviderRoutingTests and PiProviderSettingsTests. These include actual pinned
   Pi inference, strict no-auth, exact profile-scoped API key, unknown/partial limits,
   independent precedence, shared/different Existing profile paths, managed profile
   retention, native history resume, Settings model/view wiring and source audit.
8. **Security/privacy/source:** no production model-limit constants or Milk
   inference routes remain; only discovery contacts Local from Swift. None-mode
   Authorization deletion is confined to Milk's Local provider through Pi's
   documented hook. Secrets stay in scoped Keychain and in-memory child/request
   transport; config uses environment references. Managed profile root and nested
   symlink rejection and foreign managed-session rejection are tested. A scan of
   prospective source text found no recognized private-key/provider/GitHub/AWS
   secrets, personal home paths or generated artifacts; fixture strings and
   reference material are not live credentials. The scope of a pattern scan is
   not forensic proof of every possible secret. `verify-runtime.py` passed pinned
   executable/tool verification. Development bundle inspection found the Milk
   bridge and no PiRuntime directory. `git diff --check` passed.
9. **User data:** real ~/.pi, the production Milk profile and user credentials were
   not modified. Full-suite/default Pi access was redirected to a disposable
   directory, with further explicit isolated roots in integration tests. Native
   acceptance used its own temporary root and defaults suite. Keychain writes used
   temporary test accounts and were cleaned up. No real model server was configured.
10. **Commit:** created only after the checks and staged-source review passed.
    The exact commit SHA is reported in the chat completion (a file cannot embed
    its own enclosing commit's hash).
11. **Merge:** local main must still equal the recorded branch base before the
    authorized merge. The final chat reports the actual result and resulting SHA.
12. **Feature branch:** retained after merge; no rebase/history rewrite.
13. **Remote:** no push, GitHub Actions, public repository edit or publication.
14. **Remaining limits:** Developer ID signing, notarization/stapling, clean-machine
    release qualification and downloaded Bun/native provenance/relink/distribution
    review remain release gates. One approved Pi version exists, so no real
    cross-version rollback claim is made. Tests use deterministic local providers,
    not paid/live providers. Pi supplies its own numeric defaults when Milk omits
    limits. Independently launched Terminal Pi does not implicitly inherit Milk's
    header hook or Keychain environment. Old ambiguous shared/registration-scoped
    development settings are retained, not assigned to an arbitrary profile. The
    legacy recovery loader is not part of current selected-profile startup. None
    of these are hidden failing acceptance checks. No chat/session stability
    workstream was started.

## Exact acceptance commands/evidence

All Swift commands used Xcode and workspace-local Clang/SwiftPM caches. Tests ran
with host access needed by native extensions, PTYs, loopback and temporary Keychain
items. `PI_CODING_AGENT_DIR` was set to disposable verification storage.

```sh
swift package --disable-sandbox clean
swift build --disable-sandbox --cache-path "$PWD/.build/cache"
swift test --disable-sandbox --cache-path "$PWD/.build/cache"
# Targeted rerun of the five failures; then the full command above repeated.
CODESIGN_IDENTITY=- ./scripts/build.sh --disable-sandbox
output/Milk.app/Contents/MacOS/Milk --verify-agent-acceptance --acceptance-external "$PWD/Runtime/PiRuntime/pi"
swift test --disable-sandbox --cache-path "$PWD/.build/cache" --filter 'PiProfileOwnershipTests|PiProviderConsistencyTests|PiLocalProviderTests|PiProviderRoutingTests|PiProviderSettingsTests'
python3 scripts/verify-runtime.py
git diff --check
```

Logs are local, untracked files in /tmp: milk-final-clean-build.log,
milk-final-full-tests.log, milk-final-targeted-tests.log,
milk-final-full-tests-rerun.log, milk-final-native-build.log,
milk-final-native-acceptance.log, milk-final-focused-tests.log and
milk-final-runtime-audit.log. Build/app/extension artifacts remain ignored.
No Developer ID signing, notarization, public-release packaging or clean-machine
qualification ran. Ad-hoc signing is an unavoidable part of the existing local
build recipe used for native acceptance.
