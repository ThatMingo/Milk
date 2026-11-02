# Sandbox final acceptance — 2026-11-02

**Current status: Phase 7 and the overall Sandbox/security project are technically
COMPLETE under the approved ordinary login-Keychain/private-distribution policy.**
No unresolved production/security blocker remains in the tested contract. Developer
ID/provisioning/notarization, fresh live accounts, additional hosts and broad manual
coverage are optional/unclaimed, not falsely marked PASS. Earlier counts and the
failed DP gate below are historical and superseded by the current revision.

The [completed ExecPlan](exec-plans/completed/SANDBOX_IMPLEMENTATION.md) records the
final decision and evidence. The current backend results below supersede the earlier
Data Protection storage/signing requirements; accepted Sandbox limitations remain.

## Environment and scope

- One Apple Silicon arm64 host: macOS 26.5.2, build 25F84; full Xcode selected.
- Branch security/api-keychain, starting HEAD 0eb011390f54220656749922ee6682fd0aa91298;
  pre-existing Phase 6 working changes retained. No history/branch mutation.
- Disposable local repositories/remotes, profiles, compiled native extensions,
  selected Pi 1.4.0 test fixture and synthetic localhost provider credentials only.
- Actual Seatbelt runs need host execution outside the outer tool sandbox.
  SwiftPM `--disable-sandbox` disables its build sandbox, not Milk's runtime profiles.
- No other host/OS matrix is established. No manual human acceptance is claimed.

## Reconciled acceptance matrix

Existing automated coverage was mapped before broad execution. PASS below means
the stated finite current-host checks passed; external and untested claims remain separate.

| Area | Production-path evidence | Final result / claim limit |
| --- | --- | --- |
| Policy/settings | SandboxPolicyTests, SandboxSettingsTests; seven-level precedence, default ON, persisted OFF, Ask/Autonomous separation, folder grants, editable protected defaults/restore | PASS (final 304-test suite and applicable native/artifact checks) |
| Adversarial paths | SandboxAcceptanceTests, SandboxPolicyTests, SandboxPurposeTests; retargeted symlinks, traversal, nonexistent creation, inode aliases, `/var` canonical aliases, overlap and closure/identity replacement | PASS (final 304-test suite and applicable native/artifact checks); bounded snapshots, not atomic authorization |
| Once/Session/lifecycle | SandboxGrantTests, SandboxExecutionTests, AgentLifecycleTests, SessionNavigationTests; finish/cancel/timeout/revoke/restart/reopen/shutdown, drain barriers, unrelated process safety | PASS (final 304-test suite and applicable native/artifact checks); detached-survivor exception retained |
| Approval concurrency | SandboxPopupTests; actual anchored SwiftUI/AppKit panel, two sessions and queued requests, wrong-session response, Once/Session/Deny, timeout/suppression, restart/shutdown invalidation, Light/Dark captures | PASS (final 304-test suite and applicable native/artifact checks); programmatic responses, not physical human clicks |
| Profile/credential domains | SandboxEnvironmentTests, SandboxPiIntegrationTests, SandboxProviderParityTests and provider/profile suites; Pi child/extension/pi.exec/stdio MCP versus separate key-free Milk executors/jobs/workers | PASS (final 304-test suite and applicable native/artifact checks); synthetic credentials only |
| Tools and purposes | SandboxExecutionTests, SandboxPurposeTests, Phase 1; stock read/write/edit/search, nested tools/user_bash, shell/Python/Node/npm/Swift/Xcode, probes/packages/candidates | PASS; real Xcode build uses explicit TemporaryItems Once grant; unsupported forms reject ON |
| Git | SandboxHostEffectsTests and GitTests; actual local workflows/remotes/hooks/editor/diff helper, worktrees/metadata/config identity, mutation/deletion denial, shell/override rejection | PASS (final 304-test suite and applicable native/artifact checks); configured hooks/helpers/editors are elevated |
| Extension API 2 | NativeExtensionTests, NativeExtensionIntegrationTests, actual packaged-worker fixture; install/lifecycle/update/restart/data/integrity/nonce/files/Git/cancel/revoke/native UI | PASS (final 304-test suite and applicable native/artifact checks); no API 1 agent fallback |
| Preview/jobs | PreviewTests, SandboxHostEffectsTests, lifecycle tests; trusted user origin versus managed agent origin, readiness/server/static behavior, ownership/restart/stop/stale receipts | PASS (final 304-test suite and applicable native/artifact checks) |
| Packaging | Normal and release scripts, Python recipe/package/signing/version tests, archive integrity, strict signatures and packaged worker | PASS (final 304-test suite and applicable native/artifact checks); local/ad-hoc scope |
| Live providers | No usable dedicated non-admin live inference credential established in this campaign | NOT RUN / optional coverage; synthetic localhost tests are not live oMLX or hosted-account acceptance |
| Historical DP/provisioned Keychain (retired design) | `security find-identity -p codesigning -v`: 0 valid identities; no signing/profile environment configured; standard provisioning directories contain 0 files | Historical NOT RUN; provisioning is no longer a storage or technical-completion requirement |
| Developer ID/notarization/stapling | No valid code-signing identity available | NOT RUN / optional distribution improvement; not a private-build or technical-completion gate |
| Additional supported hosts | Only the current machine available | NOT RUN / coverage limitation |

## Acceptance defect and correction

The initial focused test found that an explicit Protected regular file with an
already-existing hard-link alias could be read through that alias under a broader
persistent allowed-folder grant. The policy evaluator recognized the inode, but a
Seatbelt pathname exclusion did not cover its other name. This was a real production
profile gap, not a test-only expectation failure.

`SandboxProfileBuilder` now rejects ON admission when an explicit Protected regular
file has multiple hard links. It validates the file identity/link count before
compiling the profile and gives an actionable error; it does not retry unrestricted,
copy content, remove protection or silently scan the whole disk for aliases. Existing
kernel rules also reject a child's attempt to create a new link to the protected
file; the focused test checks this separately. OFF remains an explicit user choice.

This preserves the existing bounded-snapshot limitation: independent authorized
writers can still change filesystem objects after admission, and the system does
not globally inventory every hard link into a protected directory. No atomic or
race-free filesystem authorization claim is made. Source/target package alias
contradictions continue to reject through their dedicated admission boundary.

Initial evidence: `/private/tmp/milk-phase7-focused.log` and
`milk-phase7-path-diagnosis.log` reproduce the alias read; `milk-phase7-link-creation.log`
shows child-created links already denied. Final fixed-suite evidence is recorded below.

## Actual Xcode build dependency

Version output was insufficient evidence of a full Xcode build. The additional
production-executor test creates a minimal Xcode aggregate target and executes a
real build phase. With private HOME/TMPDIR and explicit project DerivedData/module/
package caches, macOS 26.5.2 still attempts item-replacement directories under the
shared per-user `TemporaryItems` folder. Kernel messages identify denied
`file-write-create .../TemporaryItems/NSIRD_xcodebuild_*`; the build fails closed
before its phase. This is not a `/var` alias permission bypass.

A separate explicit request supplies that folder in `sandboxFolders` and exercises
the existing Allow Once flow. The build then executes a phase that verifies no
Local/OPENAI key, writes its permitted project result, and attempts an unrelated
outside write which must fail. Once admission is empty after completion. This does
not add a default grant, automatically retry a production command, broaden HOME,
change the approved UX, or grant the whole per-user temp directory. The test driver
explicitly issues a second request with the additional reviewed permission.

`TemporaryItems` is shared and can contain other applications' temporary data;
permission to it is additional user-approved authority, not Milk-private storage.
A private-TMP-only Xcode build is **not** claimed. Normal Swift compilation with
private module caches is separately covered. `CFFIXED_USER_HOME` and Xcode's explicit
cache options did not eliminate this item-replacement dependency on this host.
The bounded investigation used Apple's [item replacement API documentation](https://developer.apple.com/documentation/foundation/filemanager/searchpathdirectory/itemreplacementdirectory)
and [published CF home resolution](https://github.com/apple-oss-distributions/CF/blob/main/CFPlatform.c);
current-host kernel/executable results, rather than those sources alone, support
this finding. No restricted API/entitlement or new execution architecture was used.

The first successful grant run had only a fixture `/var` versus kernel
`/private/var` assertion mismatch; it was corrected with SandboxPathResolver, without
changing production permissions. Earlier private-only failures remain evidence in
`/private/tmp/milk-phase7-xcodebuild.log`; the final full suite includes the corrected
explicit-grant case.

## Release artifact defect and correction

The initial actual release contained the builder's absolute checkout/home paths in
linker debug records and two compile-time source-path strings. `build.sh` now maps
release source/debug paths and strips debug/OSO records before signing; debug builds
keep their development behavior. The two release-only checkout diagnostics resolve
fixture/version fallback from their explicit working directory; bundled versioning
still uses Info.plist. Normal app/provider/runtime behavior is unchanged.

`package-release.py` now rejects checkout/home prefixes anywhere in the built or
unpacked bundle. A regression distinguishes those private paths from intentional
synthetic Keychain verification values. Prefix mapping alone left two `#filePath`
strings; the strengthened guard caught them, and their release fallback was corrected.
No live credential was found or used. Known disposable verifier strings are synthetic
diagnostic inputs, not stored user credentials. Third-party notice directories named
for runtime tools are notices, not bundled executables.

## Initial Phase 7 campaign commands and results (historical baseline)

The focused correction suite passed **30/30**; the first full Swift campaign passed
**302/302** before the final opt-in native diagnostic and release privacy changes.
Final evidence after production corrections:

| Command / check | Actual result | Local evidence |
| --- | --- | --- |
| Full Xcode SwiftPM `swift test --cache-path "$PWD/.build/cache" --disable-sandbox`, with `MILK_TEST_WORKER_PATH` selecting the staged release helper | **304/304 passed**, zero failures/skips, 237.593 seconds; includes actual Xcode build/Once dependency and packaged API 2 worker | `/private/tmp/milk-phase7-full-final.log` |
| Python discovery: SandboxPhase1 | **22/22 passed**, 25.020 seconds | `/private/tmp/milk-phase7-python-final.log` |
| Python discovery: Fixtures / KeychainSigning / ReleasePackaging / Versioning | **1 + 2 + 5 + 2 passed**; total Python **32/32** | same log |
| `./scripts/build-release.sh --disable-sandbox` | **PASS**, real optimized build, private-path rejection gate, ZIP extraction/CRC/checksum/metadata verification | `/private/tmp/milk-phase7-release-final.log` |
| Whole release bundle inspection / `codesign --verify --deep --strict` | **PASS**; all four main/helper/SDK code images arm64, ad-hoc hardened runtime; worker sole entitlement disable-library-validation, distinct identity, no app Keychain entitlement/profile | `/private/tmp/milk-phase7-artifact.log` |
| `python3 Tests/Fixtures/verify_sandbox_shutdown.py` | **2/2 native app scenarios passed**: pending-popup Quit/Light and window-close/Dark; first shutdown callback observes closed admission, continuation cancelled, unrelated process/project preserved | `/private/tmp/milk-phase7-native-shutdown-final.log` |
| `python3 Tests/Fixtures/verify_preview_shutdown.py` | **2/2 passed**, real app Quit/window-close, owned group gone/private state removed/project preserved | same log |
| `python3 Tests/Fixtures/verify_terminal_shutdown.py` | **2/2 passed**, real app Quit/window-close, shell/foreground/background gone, unrelated process/project preserved | same log |
| `./scripts/build.sh --disable-sandbox` then strict deep signature verification | **PASS**, final normal development build after final tests | `/private/tmp/milk-phase7-build-final.log` |
| Packaged ad-hoc app `--verify-provider-keychain` | **Expected fail closed**, exit 1: provisioning/application-identifier required; **not** a real persistence PASS | `/private/tmp/milk-phase7-keychain.log` |
| `spctl --assess --type execute --verbose=2` on the release app | **Rejected**, exit 3; expected untrusted ad-hoc build, **not** distribution acceptance | `/private/tmp/milk-phase7-gatekeeper.log` |
| Final diff/status/whitespace review | **PASS**; branch/HEAD unchanged; generated/private evidence excluded | final repository review |

The full suite's worker selector pointed to the actual stripped release helper
**before** the normal development build replaced `output/Milk.app`. It is not a
claim that the later debug bundle is the release artifact. Reproduce release-helper
proof by building/unpacking the release first. The actual app scenarios used the
final release bundle. Responses in popup tests are programmatic AgentService routes;
app termination uses actual AppKit selectors/delegate. Neither is a manual human click.

Release artifact: `output/release/Milk-0.7.0-macOS-arm64.zip`, build **7**, minimum
macOS **26.0**, **5,668,469 bytes**. SHA-256:
`52309a710ceb743a94c78ef48e943b96c3177f1fdb9e28a0e234d53e317f7801`.
The packager verified the extracted app too. The artifact contains no coding-agent
executable or personal auth/profile files; whole-bundle scans reject build/home paths,
private-key markers and known runtime test-secret fixtures. Intentional synthetic
Keychain-verifier constants remain. This is bounded artifact inspection, not proof
of universal secret absence or notarized distribution clearance.

Current host tooling: Xcode **26.6 (17F113)**, Apple Swift **6.3.3**, Python **3.14.6**,
Node **26.5.0**. No additional host was tested. Evidence
files under `/private/tmp` and generated `output/` are local, ignored artifacts;
this report is the durable result, not a promise those files ship with source.

## Accepted limitations and unclaimed gates

- Deliberately detached survivors may retain inherited static filesystem access
  until exit. New admission closes immediately; authoritative descendant death or
  retroactive revocation is not claimed.
- Pi-owned processes/extensions/MCP share the approved non-admin inference-key domain.
  Milk-owned executors/jobs/native workers construct separate sanitized environments.
- Configured real-Git hooks/helpers/editors are the explicit elevated trust exception.
- Filesystem/executable checks are bounded admission snapshots, not atomic transactions.
- Existing-profile-only configured-provider Preview inspection remains limited;
  no arbitrary profile/auth copy or universal credential broker was introduced.
- Automated AppKit rendering/response routing is not manual human acceptance.
  Actual packaged-app Quit/window-close is additionally exercised with a synthetic
  backend and pending popup, through the real termination delegate. The driver checks
  cancellation and admission closure at the first backend shutdown callback, fresh
  empty in-memory grants in each app launch, and unrelated-process/project preservation.
  Preview and Terminal have separate real app termination fixtures. This does not
  establish provisioned credential persistence or manual human acceptance.
- Live provider, Developer ID/notarization and multiple-host acceptance remain unclaimed.
  They are optional coverage/distribution improvements under the revised policy;
  ordinary login-Keychain acceptance replaces the retired provisioned DP gate.


## Initial Phase 7 campaign file changes (before the storage revision)

Pre-existing Phase 6 working changes were preserved. Files edited/added specifically
for this campaign (repository-relative paths):

```text
Sources/Milk/SandboxProfile.swift
Sources/Milk/MilkApp.swift
Sources/Milk/SandboxAcceptanceVerification.swift
Sources/Milk/ChatStabilityVerification.swift
Sources/MilkExtensionHost/MilkApplicationVersion.swift
scripts/build.sh
scripts/package-release.py
Tests/MilkWorkspaceTests/SandboxAcceptanceTests.swift
Tests/MilkWorkspaceTests/SandboxPopupTests.swift
Tests/MilkWorkspaceTests/SandboxExecutionTests.swift
Tests/Fixtures/verify_sandbox_shutdown.py
Tests/ReleasePackaging/test_release_packaging.py
README.md
RUNTIME.md
docs/README.md
docs/DEVELOPMENT.md
docs/API_KEYCHAIN.md
docs/PI_PROFILE_OWNERSHIP.md
docs/SANDBOX_POLICY.md
docs/SANDBOX_PURPOSES.md
docs/SANDBOX_HOST_EFFECTS.md
docs/EXTENSION_DEVELOPMENT.md
docs/SANDBOX_ACCEPTANCE.md
docs/exec-plans/active/SANDBOX_IMPLEMENTATION.md
```

Approved architecture, upstream Pi and historical reports were not changed. No commit,
push, merge, rebase or branch switch was performed.


## Normal login-Keychain revision — current acceptance

The approved backend/distribution decision is in [API Keychain](API_KEYCHAIN.md) and
the updated architecture. Ordinary file-based SecItem is now the primary/only store;
no production DP selector, application-identifier requirement, LAContext/accessibility
class or plaintext/config fallback remains. Identity, Pi injection/stale-auth/None,
normalization/redaction and all filesystem/executor/environment boundaries are unchanged.
Optional profile/signing support remains in scripts; no Apple enrollment is required.

Actual ad-hoc native CRUD/isolation, separate launches and an unchanged-CDHash rebuild
passed. A changed-CDHash nonce-resigned bundle was denied noninteractively (-25293).
The user authorized the standard native Keychain recovery dialog; production recovery
and a subsequent separate-process read passed. Creator read/delete/missing-item cleanup
passed. This is user-confirmed native Keychain authorization, not automated SecurityAgent
interaction or a claim of silent access across arbitrary future updates. The automation
tool blocks SecurityAgent; no password was inspected, supplied or logged.

The new actual-worker test verifies that a compiled API 2 worker cannot read the same
real disposable Milk Keychain item, with ON service isolation or OFF default-ACL
isolation, while the creating app retains access. The item is deleted afterward.
Normal source-only tests opt out of real-store interaction unless the built-app and
worker selectors are explicitly supplied; this acceptance campaign opts in.

Evidence: `/private/tmp/milk-login-keychain-native-crud.log`,
`milk-login-keychain-persistence.log`, `milk-login-keychain-recovery-final.log`,
`milk-login-keychain-worker-store.log`, `milk-login-keychain-provider-domain.log`.
The first two private test drivers used short authorization windows and one timed out;
its creator-identity cleanup succeeded. The final user-assisted run verified recovery
and fresh-process reuse. No failure is presented as a PASS.

Final ordinary-Keychain validation passed:

| Gate | Actual result / evidence |
| --- | --- |
| Focused credentials/settings/environment | **29/29 passed**, `milk-login-keychain-focused.log` |
| Expanded provider/profile/domain | **43/43 passed**, `milk-login-keychain-provider-domain.log` |
| Full Swift with actual release app/worker selectors | **308/308 passed**, no failures/skips, **236.340 s**, `milk-login-keychain-full.log` |
| Full Python | **32/32 passed**: Phase 1 22 + resource 1 + optional signing 2 + release 5 + versioning 2, `milk-login-keychain-python.log` |
| Actual ordinary-Keychain CRUD/scoping | **PASS** in normal and stripped release app; no provisioning, `milk-login-keychain-native-crud.log`, `milk-login-keychain-release-crud.log`, `milk-login-keychain-crud-final.log` |
| Launch/rebuild/default ACL | **PASS** retained item across processes and unchanged-CDHash rebuild; changed signature denied, user-authorized recovery and next-process reuse passed; creator read/delete cleanup verified, `milk-login-keychain-persistence.log`, `milk-login-keychain-recovery-final.log` |
| Real worker versus real stored credential | **PASS** ON and OFF worker reads denied while creator reads; included in full suite, focused proof `milk-login-keychain-worker-store.log` |
| Normal/release build and strict signatures | **PASS**, `milk-login-keychain-build-final.log`, `milk-login-keychain-release.log`, `milk-login-keychain-artifact.log` |
| Release ZIP/privacy/architecture/runtime inventory | **PASS** checksum/extraction/metadata/signatures; arm64 hardened runtime; no private paths, auth/profile files, private-key markers or bundled coding agent; intentional synthetic verifier constants remain |
| Gatekeeper | Ad-hoc release **rejected**, exit 3; expected private-distribution limitation, no trust/quarantine bypass; optional Developer ID/notarization NOT RUN |
| Fresh live Local/oMLX/hosted OAuth | **NOT RUN**, no appropriate already-authorized inference credential; synthetic localhost provider parity passed |

Log filenames in this table are under `/private/tmp`. Current release artifact:
`output/release/Milk-0.7.0-macOS-arm64.zip`, build **7**, minimum macOS **26.0**,
**5,674,576 bytes**, SHA256
`69ff3cc283b8b0ffffe78a7c7c82983468164dd311a89897f9c2bf8d53426d4c`.
The release app/helper were selected throughout the full suite, before the final
normal build replaced `output/Milk.app`. The ZIP remains the verified release artifact.

**Completion:** Phase 7 and the overall Sandbox/security project are technically
complete. No required normal-Keychain or regression/artifact gate remains open.
All accepted L1/L2, elevated Git helper, bounded snapshot/hard-link inventory,
Existing configured-provider Preview and explicit shared TemporaryItems-grant limits
remain. Coverage is one Apple Silicon macOS 26.5.2 host; Sandbox UI is automated,
while the Keychain authorization dialog was manually authorized by the user. No
live-account, multi-host or notarized-distribution PASS is claimed. Optional future
coverage does not reopen a mandatory provisioning requirement.

The complete plan is archived under completed, not left misleadingly active. Current
references and architecture were reconciled; historical reports remain historical.
No commit/push/merge/rebase/branch switch was performed; all prior work is preserved.

## Exact files changed for the normal-Keychain revision

Prior Phase 3–7 local changes were retained. This revision edited these logical files;
the final entry was moved from active to completed (not discarded):

```text
Sources/Milk/AgentProviderCredentials.swift
Sources/Milk/PiSettings.swift
Sources/Milk/ProviderCredentialVerification.swift
Tests/MilkWorkspaceTests/AgentProviderCredentialTests.swift
Tests/MilkWorkspaceTests/CredentialTestStore.swift
Tests/MilkWorkspaceTests/PiProviderSettingsTests.swift
Tests/MilkWorkspaceTests/SandboxHostEffectsTests.swift
Tests/Fixtures/verify_provider_keychain.py
scripts/build.sh
scripts/keychain-signing.py
README.md
RUNTIME.md
docs/API_KEYCHAIN.md
docs/AGENT_PROVIDER_SETTINGS.md
docs/PI_PROFILE_OWNERSHIP.md
docs/SANDBOX_HOST_EFFECTS.md
docs/EXTENSION_DEVELOPMENT.md
docs/DEVELOPMENT.md
docs/SANDBOX_PURPOSES.md
docs/SANDBOX_POLICY.md
docs/README.md
docs/SANDBOX_ACCEPTANCE.md
docs/design-docs/SANDBOX_ARCHITECTURE.md
docs/exec-plans/completed/SANDBOX_IMPLEMENTATION.md
```
