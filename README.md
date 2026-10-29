# Milk

Milk is a native macOS GUI and coding environment for the Pi coding agent.

It is intended to provide a polished Codex-like desktop workflow for the user's existing local Pi + oMLX setup.

## Runtime

```text
Milk
  ↓
Pi
  ↓
existing Pi configuration
  ↓
oMLX
  ↓
Qwen3.8-27b-pi-oQ8e-mtp
```

Milk does not replace Pi and should not create a second model configuration.

## Development

Development happens locally on macOS.

Remote repository:

`ThatMingo/Milk`

Normal workflow:

```text
local Milk checkout
→ Codex edits/builds/tests locally
→ Git commit
→ push to ThatMingo/Milk
```

See `docs/` for the product handoff and planning context.

## Build and run

Requires Apple Silicon, macOS 26+, and full Xcode. Commands select Xcode for the process without changing the global developer directory.

```sh
./Scripts/build.sh
open build/DerivedData/Build/Products/Debug/Milk.app
./Scripts/test.sh
```

Open `Milk.xcodeproj` to develop in Xcode. The existing Pi/Node installation is discovered; Milk does not install or reconfigure Pi or oMLX. No GitHub login is needed for local work.

The current application establishes the complete top-level foundation, including the native shell, real Pi streaming/approval/session lifecycle, TextKit editor, file/Git/search services, terminal, previews, isolated extension host, persistence, GitHub adapters, and updater/release configuration. It is not feature-complete.

See [implemented architecture](docs/08_IMPLEMENTED_ARCHITECTURE.md) for ownership and limitations, and [validation](docs/09_VALIDATION.md) for automated and real-stack evidence.
