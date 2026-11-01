# Local API credentials and macOS Keychain

Milk's Local provider remains generic OpenAI-compatible. Discovery calls only
`GET <apiBase>/models`; inference is performed by the supported Pi 1.4.0 runtime.
No oMLX admin API or admin key is required.

## Credential path and diagnosed failures

Settings' pending replacement is used by Test Connection and Save. Leading and
trailing whitespace/newlines are removed consistently; embedded whitespace and
control characters are rejected without including the input in an error.
Previously the input was used verbatim, so pasting a newline could invalidate an
otherwise correct sub-key.

The saved key is read using agent + profile + provider + exact endpoint identity,
then injected only into the active Local Pi process as `MILK_PI_LOCAL_KEY`.
`models.json` contains `$MILK_PI_LOCAL_KEY`, never its value, and `authHeader: true`.
Pi 1.4.0's bundled `docs/models.md` states that `auth.json` takes precedence over
`models.json`. Consequently a stale `milk-local` entry in `auth.json` could defeat
Milk's correctly saved replacement and cause discovery/runtime disagreement.
Milk's existing `before_provider_headers` hook now sets the active Local bearer
credential, or removes Authorization in None mode, after Pi resolves its defaults.
It does not alter other providers or modify/delete user-owned auth.json.

The old oMLX settings migration also copied a key into an unprofiled account,
whereas current runtime reads are profiled. This migration is now explicit and
writes to the selected profile. These are source-identified defects; without the
user's failing server/key we cannot establish which caused that particular failure.

## Storage and prompt behavior

All normal SecItem add/read/update/delete/existence operations explicitly select
`kSecUseDataProtectionKeychain: true`, disable synchronization, and use Milk's
private default app access group. New/updated values use
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. There is no shared access group,
Touch ID, userPresence, or authentication access control. Normal operations use
an LAContext with interactionNotAllowed; unavailable/locked storage reports an
error rather than displaying a permission prompt. Settings checks existence
without requesting secret bytes. Keys never enter Codable settings, arguments,
models.json, logs, or extensions' native API.

The previous implementation selected the legacy file-based Keychain implicitly.
Its ACL authorizes the signing requirement of the creating application. Ad-hoc
builds have no stable developer identity; rebuilding/re-signing may invalidate
that authorization and produce Allow/Deny/Always Allow dialogs. Settings read
secret bytes merely to display presence, and migration could read old entries on
load, increasing opportunities for those dialogs. This is the strongest supported
explanation; the user's actual item's ACL was not inspected or altered.

Legacy `dev.milk.agent-provider` and `dev.milk.omlx` entries are never read at
startup. In Local settings, **Import Legacy Key…** explicitly permits a legacy
ACL prompt. It tries the exact scoped account, then the old unscoped account,
then oMLX's endpoint account. A current new-store credential always wins. Import
copies and reads back the destination before reporting success. A successful
scoped destination is the durable completion marker; subsequent imports do not
read legacy entries. Missing/denied imports can be retried only by another
explicit click. Originals remain for recovery, including after removal of the
new entry. After import choose API-key mode and Save. Prefer pasting a new
Milk-specific sub-key if legacy entries contain an admin key.

## Signing: development and release

The bundle ID stays `dev.milk.phase1`. Data Protection Keychain authorization
requires an entitled, provisioned app identity. The previous ad-hoc bundle has
neither a team nor an application-identifier entitlement. Adding invented
restricted entitlements to it is unsupported and can prevent launch.

Ad-hoc builds remain available through `scripts/build.sh` and the release packager;
they can use unauthenticated Local providers and ordinary Pi-configured providers.
They deliberately fail closed for Milk API-key storage with an actionable error.
There is no plaintext or legacy-Keychain fallback. Silent private credential
persistence requires a real signing identity and provisioning profile, for both
development and distribution:

```sh
CODESIGN_IDENTITY='your signing identity' \
MILK_PROVISIONING_PROFILE='/absolute/path/Milk.provisionprofile' \
scripts/build.sh --disable-sandbox
```

Use an appropriate development profile/certificate locally and Developer ID
profile/certificate for distribution. The profile must authorize the explicit
Milk App ID. build.sh decodes the profile, validates its app/team identity,
embeds it, and derives only the application/team identifier entitlements. It
retains the existing native-extension entitlement and adds no shared groups.
Apple's signing tools validate signing; launch and the verification below must
also succeed. Release uses the same variables with `scripts/build-release.sh`.
No suitable signing identity was available in the implementation environment;
provisioned launch and real Data Protection Keychain success remain required
integration acceptance checks.

See [Apple TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains),
[Keychain entitlement troubleshooting](https://developer.apple.com/forums/thread/114456),
and [distribution signing](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/).

## Verification

Unit tests use an in-memory SecItem simulation, including the older migration
fixtures. They never add API keys to the developer's personal Keychain. The real
store verification runs inside the actual signed bundle:

```sh
output/Milk.app/Contents/MacOS/Milk --verify-provider-keychain
```

It uses random, disposable identities and synthetic values, verifies
save/read/update/existence/profile isolation/delete, and cleans up. Run twice
and after rebuilding with the same provisioned identity. Expect success and no
native prompts while the user session is unlocked. An ad-hoc build should report
the provisioning requirement and exit 1, with no fallback. It must also fail
without prompting while storage is unavailable. Unit tests validate selectors,
accessibility, non-synchronization and no-interaction policy; they cannot prove
securityd behavior or GUI prompt absence.

For full UI/Keychain oMLX acceptance in a provisioned build:

1. In oMLX create a new inference sub-key dedicated to Milk. Do not use the admin key.
2. Run a provisioned Milk build. Choose the intended Pi profile, Local provider,
   `http://127.0.0.1:8000/v1` (or the actual server URL), and API-key mode.
3. Paste the sub-key into the secure field. Test Connection must list models.
4. Select an advertised loaded model, Save, close and reopen Settings. Confirm
   Stored in Keychain, then Test Connection without re-entering the key.
5. Start a fresh chat and send a short prompt. Verify a normal inference reply.
6. Restart Milk and repeat a prompt. Generate a replacement sub-key, paste it,
   Test Connection, Save, revoke the old sub-key in oMLX, and repeat the prompt.
7. Verify the other profile/endpoint does not inherit this key. Do not put keys
   in screenshots, shell commands, logs, diagnostics, or bug reports.

No Seatbelt, subprocess isolation, credential broker, or broader provider redesign
is included. The active key remains in Pi's process environment as before; this
phase does not claim protection against arbitrary code executing inside Pi or
Milk. Native extensions receive no credential lookup API. Runtime hardening is a
separate phase.

## Implementation validation and exact changed files

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
