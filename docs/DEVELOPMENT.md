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
temporary directory under `output/`, signs both SDK copies and the app, verifies
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
