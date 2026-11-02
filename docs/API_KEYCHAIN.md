# Local API credentials and macOS Keychain

## Current backend and private distribution

Milk uses ordinary macOS login/default file-based Keychain through Security.framework
`SecItemAdd`, `SecItemCopyMatching`, `SecItemUpdate` and `SecItemDelete`. It is the
primary and only persistent secret store. The approved 2026-11-02 decision replaces
the earlier provisioned Data Protection backend; this is not a fallback.

No Data Protection selector, accessibility class, authentication-context attribute,
shared access group, Touch ID/user-presence policy or provisioning check is part of
the production provider credential path. New items retain the normal creator ACL;
Milk does not install permissive ACLs or bypass macOS authorization. Normal Keychain
availability/locking and default ACL behavior apply. Milk does not opt into sync.

Ad-hoc development/private-distribution builds support credentials without Apple
Developer Program membership, Developer ID, a profile, notarization or App Store
submission. Optional `CODESIGN_IDENTITY` / `MILK_PROVISIONING_PROFILE` support remains
in build scripts, but does not select the storage backend. Developer ID/notarization/
stapling are optional distribution enhancements. An unnotarized private build may
require the user to choose macOS Open Anyway; Milk never removes quarantine or
bypasses Gatekeeper. Structural signature verification is still required.

## Identity, provider behavior and failures

The service is `dev.milk.agent-provider.login.v1`. Structured accounts preserve
agent + `PiProviderProfileIdentity` + provider + exact endpoint. Profile identity,
canonical profile selection, Local normalization and endpoint semantics are unchanged.
No implicit cross-profile/provider/endpoint import or merge occurs.

Keys are normalized consistently for Settings, discovery and runtime use. API-key
mode resolves the scoped key; None mode omits Authorization. `models.json` stores
`$MILK_PI_LOCAL_KEY`, never the literal key. Pi's `before_provider_headers` hook still
selects the current Local credential (or removes Authorization in None mode) after
stale `auth.json` defaults. User-owned auth files remain untouched.

A locked, unavailable, unauthorized or malformed Keychain item returns an actionable
error. There is no plaintext credential file, UserDefaults/config secret, legacy-store
automatic fallback or broker. Pending Settings/Test Connection values remain in memory.
Existence checks request no secret data; no current/legacy key is read merely to render
its presence. No key is printed in logs/diagnostics/arguments or persisted into settings.

## Noninteractive access and explicit recovery

Ordinary operations use a synchronous serialized `SecKeychainGet/SetUserInteractionAllowed`
scope, restoring the previous process state on completion/errors. This public legacy
UI control is deprecated but available on the supported host; per-query DP/LAContext
behavior is not assumed for the file-based implementation. No async suspension occurs
inside the scope. [Apple API distinctions](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)
and [the Chromium implementation's file-Keychain UI handling](https://chromium.googlesource.com/chromium/src/crypto/+/refs/heads/main/apple/scoped_keychain_user_interaction_allowed.cc)
provide context; actual macOS 26.5.2 behavior is measured below.

If a rebuilt app needs authorization, normal background access fails actionably rather
than prompting repeatedly. Settings → Agents → Pi → **Recover Stored Key…** is the
explicit user action that permits ordinary macOS authorization. It first authorizes
an existing current scoped entry without replacing it. If none exists, it may import
from the older `dev.milk.agent-provider` scoped/unscoped namespace or `dev.milk.omlx`
exact-endpoint account into the selected current scope, verifying the destination.
Originals remain; a current entry wins; startup never reads older entries automatically.
Older DP items are neither queried nor deleted by the new backend: re-enter a key or
recover it using its original authorized build if needed. Prefer a dedicated inference
sub-key over importing an old admin credential.

The native authorization dialog belongs to macOS. Enter a login password only there,
never in chat or logs. A changed ad-hoc signature can require renewed authorization;
no stable across-all-updates silent-access guarantee is claimed.

## Measured actual-app verification — 2026-11-02

On Apple Silicon macOS 26.5.2 (25F84), the actual ad-hoc app passed normal-Keychain
save/read/update/existence/delete and agent/profile/provider/endpoint isolation using
only UUID-scoped synthetic items. Separate app processes reused a retained item. An
actual unchanged-code ad-hoc rebuild retained the same CDHash and reused that item.

A deliberately nonce-resigned bundle at the same path changed the CDHash. Its normal
noninteractive read failed with `errSecAuthFailed` (-25293), as required by the old
item's default ACL. The explicit production recovery path then succeeded after the
user authorized the native macOS dialog. A separate subsequent process read the item
noninteractively. The exact creator build was restored for read/delete verification;
cleanup passed. No ACL was edited by code, no global protection weakened and no
password/credential was printed. SecurityAgent automation was blocked; the user
confirmed native authorization. This is measured same-code rebuild plus changed-
signature recovery, not a claim that arbitrary future ad-hoc updates never prompt.

Reproduce inside the actual built app:

```sh
./scripts/build.sh --disable-sandbox
output/Milk.app/Contents/MacOS/Milk --verify-provider-keychain
python3 Tests/Fixtures/verify_provider_keychain.py --rebuild --changed-signature
```

The default verifier deletes its disposable item. The driver retains one UUID-scoped
item across processes, measures default ACL behavior, restores generated app copies
and verifies cleanup. `--authorize` explicitly exercises Settings' recovery path and
may need native user authorization. The phased verifier's `--keychain-run-id` UUID is
a public test identifier, not a secret; synthetic values stay in app memory/Keychain.
Never pass a real key in argv or to this verifier. Unit tests use SecItem/UI-policy
simulations, not the user's Keychain. The final suite passed 308 Swift and 32 Python tests; normal/release builds and
strict signature/artifact checks passed. Phase 7 and the Sandbox/security project
are technically complete under the approved private-distribution policy. Exact evidence is in
[Sandbox acceptance](SANDBOX_ACCEPTANCE.md).

## Sandbox and live-provider scope

Pi, Pi extensions, pi.exec, Pi-owned children and stdio MCP keep the approved inference-
key trust domain. Milk-owned sibling executors, jobs, probes, candidate/package helpers
and extension workers construct independent sanitized environments. Worker signing/service
isolation remains intact. No filesystem permission, provider schema or auth-file copy
changed with the backend. See [runtime environments](../RUNTIME.md#purpose-specific-environments)
and [Sandbox policy](SANDBOX_POLICY.md).

Fresh live Local/oMLX and hosted/OAuth acceptance is NOT RUN in this revision: no
already available authorized non-admin inference key was established. The historical
one-off sub-key test below remains historical; it was deleted and is not reused.
Synthetic localhost discovery/inference/None/model/reasoning/rotation/revocation/
stale-auth/profile/endpoint tests remain valid. Missing live credentials, additional
hosts/manual-human coverage and optional Developer ID/notarization are not by themselves
Sandbox technical-completion blockers under the new decision.

## Historical Data Protection implementation evidence (superseded)

The following records the earlier backend and counts exactly as measured then. Its
provisioning requirement and failed ad-hoc Keychain gate are historical, not current
product requirements. Do not interpret its old service/attribute/signing assumptions
as the current implementation.

### Earlier implementation validation and exact changed files

- Full Swift suite: **219 tests passed**, zero failures. Run with Xcode's selected
  toolchain, workspace-local SwiftPM/Clang caches, and loopback/file access outside
  the tool sandbox. Initial sandbox runs failed to bind HTTP fixtures and write
  existing workspace-test state; the unrestricted rerun passed.
- Python: release packaging 4/4, versioning 2/2, clean resources 1/1, and new
  Keychain-signing configuration tests 2/2 passed.
- `scripts/build.sh --disable-sandbox` passed.
- `scripts/build-release.sh --disable-sandbox` passed, including release build,
  archive integrity, unpacked bundle checks, and strict deep codesign verification.
- The actual ad-hoc bundle's `--verify-provider-keychain` command returned
  `errSecMissingEntitlement` and the provisioning guidance, without a popup.
  Successful real Data Protection Keychain CRUD and prompt absence across
  provisioned rebuilds remain unverified because no signing identity is installed.
- A controlled before/after run against the supported real Pi runtime reproduced
  HTTP 401 from stale `auth.json` without the header fix; the same request completed
  without HTTP 401 with the fix. Regression tests seed that same stale credential.
- Live oMLX at loopback port 8000: with explicit user approval, used the existing
  admin key only to create/delete a disposable randomly generated sub-key. The
  sub-key alone returned `/v1/models` HTTP 200 (7 models), `/admin/api/stats` HTTP
  401, and successful Pi RPC inference using the already loaded `MarkItDown` model.
  The inference-side status route selected the loaded model without changing
  loading state. The sub-key was deleted and its subsequent discovery request
  returned HTTP 401. No actual key was printed or put in arguments/files by Milk.
  This live test covers real sub-key discovery and Pi inference, not the unavailable
  provisioned GUI Save/restart/Keychain path. It does not prove which defect caused
  the user's original failure; credential precedence is a reproduced failure mode.
- `git diff --check` passed. All work is on local `security/api-keychain`;
  no fetch/pull of this repository, push, remote branch, merge, or Seatbelt work.

Production changes:

- `Sources/Milk/AgentProviderCredentials.swift` — protected storage, normalization,
  non-secret existence query, explicit verified legacy import.
- `Sources/Milk/PiSettings.swift` — existence checks, replacement normalization,
  explicit import, and stale asynchronous result protection.
- `Sources/Milk/PiLocalDiscovery.swift` — consistent key normalization.
- `Sources/Milk/PiProviderSupport.swift` — consistent runtime key normalization.
- `Sources/Milk/PiProviderConfiguration.swift` — remove automatic legacy secret reads.
- `Runtime/MilkPiIntegration.ts` — active Local credential overrides stale Pi auth.
- `Sources/Milk/ProviderCredentialVerification.swift` — disposable real-store check.
- `Sources/Milk/MilkApp.swift` — opt-in verification command routing.
- `scripts/build.sh` — optional provisioned app identity, unchanged ad-hoc support.
- `scripts/keychain-signing.py` — validate profile and derive private app identity.
- `docs/API_KEYCHAIN.md` — design, limits, verification and this report.

Tests/fixtures:

- `Tests/MilkWorkspaceTests/AgentProviderCredentialTests.swift`
- `Tests/MilkWorkspaceTests/CredentialTestStore.swift`
- `Tests/MilkWorkspaceTests/PiProviderSettingsTests.swift`
- `Tests/MilkWorkspaceTests/PiProviderRoutingTests.swift`
- `Tests/MilkWorkspaceTests/PiLocalProviderTests.swift`
- `Tests/MilkWorkspaceTests/PiProviderConsistencyTests.swift`
- `Tests/MilkWorkspaceTests/PiProfileOwnershipTests.swift`
- `Tests/MilkWorkspaceTests/AgentManagerSettingsTests.swift`
- `Tests/Fixtures/local_provider_fixture.py`
- `Tests/KeychainSigning/test_keychain_signing.py`

The other pre-existing credential-using suites only
switch their test SecItem calls to the in-memory store. No provider/runtime/UI
architecture or unrelated feature is redesigned. This is a medium, contained
phase: roughly 500–600 added lines (including documentation and tests), with
about 140 net production Swift/TypeScript/shell/Python lines added.
