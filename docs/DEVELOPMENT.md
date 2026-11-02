# Developer setup

This is the setup reference for building Milk from a public source checkout.
Commands below are developer instructions, not checks performed during the
publication documentation review.

## Platform and tools

Use Apple Silicon, macOS 26 or newer, and full Xcode with the macOS 26 SDK and
Swift 6.2 or newer. `Package.swift` declares macOS 26.0 and Swift 5 language mode;
pinned SwiftTerm 1.99.2 requires the newer toolchain. Python 3, Git, zsh and the
standard Xcode/macOS tools (`swift`, `xcrun`, `install_name_tool`, `codesign`) are
used by the existing scripts. Initial SwiftPM resolution needs network access;
`Package.resolved` records the dependency pins.

The build script selects `/Applications/Xcode.app/Contents/Developer` when it
exists and `DEVELOPER_DIR` is unset. For another Xcode location, set
`DEVELOPER_DIR` to that installation's `Contents/Developer` directory before
running commands. A Command Line Tools-only selection is insufficient.

## Build and launch

Run from the repository root:

```sh
./scripts/build.sh
open output/Milk.app
```

The script builds the app and dynamic MilkExtensionKit SDK, stages resources in a
temporary directory under `output/`, signs both SDK copies, the separate agent-extension helper and the app, verifies
the signature, then replaces `output/Milk.app`. Development signing is ad hoc by
default. `CODESIGN_IDENTITY` can select an identity; this does not perform
notarization or establish release acceptance.

If the host cannot run SwiftPM's nested sandbox, use the existing argument:

```sh
./scripts/build.sh --disable-sandbox
```

Pi is not a build prerequisite. The app contains Milk's integration bridge,
notice metadata and extension SDK, without Pi/Bun/search executables or upstream
runtime assets. Install or select Pi through Settings → Agents after launch.
Neither a local runtime download nor ignored private/design/history material is
needed to build or launch Milk without an agent.

| Location | Purpose |
| --- | --- |
| `.build/` | SwiftPM products, dependencies and workspace-local caches |
| `output/Milk.app` | Generated development app and packaged extension SDK |
| `output/` | Other generated staging, logs and verifier evidence |
| `Runtime/PiRuntime/` | Optional upstream test fixtures; only the manifest is source |
| `Examples/Extensions/OMLXStatusExample/build/` | Separately built example bundle |

Generated/local contents are ignored. Do not add credentials, user Pi data or
signing exports to the source tree.

## Tests

Tests run on macOS with full Xcode selected. For commands invoked directly,
select Xcode in the shell as well; the build script's environment is local to
that script. For the standard installation:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
```

Adjust the Xcode selection if installed elsewhere. A focused layout-only example
requires no downloaded Pi fixture:

```sh
swift test --cache-path "$PWD/.build/cache" --filter WorkspaceLayoutTests
```

For the complete suite, prepare the upstream fixtures in the next section first,
then run:

```sh
swift test --cache-path "$PWD/.build/cache"
```

`--disable-sandbox` can also be passed to `swift test` on hosts with the nested
sandbox restriction. Some tests use AppKit, Keychain, loopback networking, PTYs,
process inspection and a compiled native extension; they need a normal macOS user
session and host access. Real-Pi tests use temporary agent storage and controlled
loopback provider fixtures, without paid credentials or live model weights.

The completed [Agent final acceptance](AGENT_PHASE_FINAL_ACCEPTANCE.md) records
156/156 tests and the separate app/runtime checks actually performed. Native
verification commands are acceptance tools, not part of the minimal build flow;
they may generate local logs/screenshots and require a logged-in WindowServer.
Their exit status alone is insufficient: inspect their PASS/FAIL results. No
public checkout is expected to contain the historical `output/` evidence.

## Optional upstream Pi integration fixtures

Tests such as `PiIntegrationTests`, real-Pi cases in `PiParityTests`, and the
native bridge integration need upstream executables under `Runtime/PiRuntime/`.
Prepare these separately from app building with Python **3.12+** and curl:

```sh
python3 scripts/bootstrap-runtime.py
```

Ensure `python3` selects Python 3.12 or newer. The script downloads pinned official
Darwin arm64 Pi 1.4.0, ripgrep 15.2.0 and fd 10.5.0 artifacts, checks archive hashes,
extracts them, omits the optional Doom example, and invokes `verify-runtime.py`.
To recheck existing fixtures without downloading, run
`python3 scripts/verify-runtime.py`.

These ignored fixtures are test inputs. They are not bundled with Milk.app and
are not selected automatically by the production app. Settings → Agents uses the
compiled approved catalog and stores managed code outside the checkout.
Downloads/checksums do not resolve the runtime provenance and distribution review
recorded in [final acceptance](AGENT_PHASE_FINAL_ACCEPTANCE.md) and the
[source-publication audit](PRE_GITHUB_AUDIT.md).

For native extension authoring and the independent example build, use the
[extension guide](EXTENSION_DEVELOPMENT.md). No Pi bootstrap is required merely
to compile Milk or a native Milk extension.

## Sandbox policy tests

Sandbox policy, path, settings, grants and execution tests use disposable files/preferences:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" \
swift test --cache-path "$PWD/.build/cache" --filter Sandbox
```

Add `--disable-sandbox` if the host's nested SwiftPM sandbox blocks the build.
The `SandboxExecutionTests` and `SandboxPiIntegrationTests` launch the production
Seatbelt/worker paths on macOS 26+, use the optional pinned Pi fixture, and require
host child-process permissions and a disposable localhost provider. They use
synthetic credentials through a fake credential store, never personal Keychain data.
`SandboxPopupTests` renders the real anchored child panel in light/dark appearance;
its disposable captures are written under `/private/tmp`. Older provider/native
extension tests explicitly select Sandbox OFF to preserve their compatibility scope.
The opt-in Phase 1 native/Pi harness is separate under `Tests/SandboxPhase1/`.
See [Sandbox policy](SANDBOX_POLICY.md) for the current implementation and its limits.

Phase 4 adds `SandboxEnvironmentTests` and `SandboxProviderParityTests`: hostile
ambient/startup inputs, bounded configuration admission, actual RPC diagnostic
redaction, custom runtime-vs-helper credential scope, typed Xcode selection, Local
key rotation/revocation/None and native configured-provider auth/env precedence.
The existing actual Pi/MCP and shell/Python/Node/npm tests now cover both domains.
All keys/providers are synthetic; personal Keychain or live oMLX access is unnecessary.
Fixture-only probe controls must use the separate `probeEnvironmentOverrides` input.


Phase 5 adds the Milk-owned `MilkExtensionWorker` SwiftPM product under
`Contents/Helpers`. It is signed with `scripts/milk-worker.entitlements` (library
validation exception only), a distinct identifier, and no Milk Keychain identity or
provisioning profile. The app and SDK signing flow is otherwise unchanged. It is
not a bundled coding agent. Rebuild API 1 native packages for API 2; view/layout/
settings registrations remain, while agent handlers must move to the worker entry.
See [extension development](EXTENSION_DEVELOPMENT.md) and
[host-effect boundaries](SANDBOX_HOST_EFFECTS.md).


Phase 6 adds `SandboxPurposeTests` and lifecycle relaunch checks. They execute real
Seatbelt plans, system scripts/shims, optional local Node/module dependencies, local
package commands and a locally compiled hash-pinned native candidate through the
actual installation transaction. No candidate is run unrestricted as a test setup
step. Candidate fixture compilation/archive creation are trusted test preparation;
candidate version/RPC execution uses the production contract. The new tests need
full Xcode and permission to run sandbox-exec, as do the existing integration suites.
See [purpose contracts](SANDBOX_PURPOSES.md) for supported closure and boundaries.
Default ON preserves existing saved OFF; the app build remains ad-hoc development
signing by default, with ordinary login-Keychain credentials. See [Sandbox acceptance](SANDBOX_ACCEPTANCE.md)
for exact final evidence and optional distribution/coverage limitations.


Phase 7 adds `SandboxAcceptanceTests` and concurrent anchored-popup routing tests.
`python3 Tests/Fixtures/verify_sandbox_shutdown.py` runs the packaged app's opt-in
`--verify-sandbox-quit` / `--verify-sandbox-window-close` diagnostics with a pending
Sandbox popup. They use a synthetic backend, disposable preferences/workspace and
the real app termination delegate; normal launch never runs this fixture. Captures
and shutdown metadata go to ignored `output/verification-sandbox/`. This is automated
AppKit interaction, not manual human acceptance or live-provider validation.


Release packaging remaps source/debug paths and strips debug/OSO records before
signing. The packager rejects the builder's checkout/home prefixes in the built and
unpacked bundle. Debug builds retain source locations; release-only checkout
verification modes must be launched with the repository as their working directory.
Bundled product versioning always uses Info.plist. This artifact hygiene is independent
of optional Developer ID/notarization; neither is required for private builds or credentials.


Real Xcode builds can require the macOS per-user `TemporaryItems` item-replacement
folder even with private TMPDIR and project-scoped DerivedData/cache flags. Milk does
not admit that shared folder automatically: a command may explicitly request it
through the normal temporary folder approval flow. The acceptance build verifies
that an Allow Once grant enables the build while unrelated outside writes remain
denied and the grant expires for future admission. The folder can contain other
applications' temporary data, so this is extra reviewed authority, not private cache
redirection. Private-TMP-only Xcode builds are not claimed; Swift compilation with
private module caches is independently covered. See [acceptance](SANDBOX_ACCEPTANCE.md).


Ordinary Keychain acceptance: build ad-hoc, then run the bundled
`--verify-provider-keychain` check and optional
`python3 Tests/Fixtures/verify_provider_keychain.py --rebuild --changed-signature`.
Only disposable UUID identities/synthetic values are used and deleted. Adding
`--authorize` permits the explicit recovery flow and may require native user action;
never automate a login password or put it in logs. User-confirmed native authorization
and a subsequent separate-process read were measured in this revision. See
[API Keychain](API_KEYCHAIN.md). Optional signing/profile support remains available;
no profile is needed for default credential storage. Do not bypass Gatekeeper.
