# Milk — Codex Instructions

Repository: `ThatMingo/Milk`
Local project folder: `Milk - Pi Coding Agent GUI`

Read all files in `docs/` before making product or architecture decisions.

## Working model

Development happens locally on the Mac.

GitHub is the remote repository for version history, backup, collaboration, and releases. It is not the primary execution environment.

## Product rules

- Milk is a native macOS GUI and coding environment for Pi.
- Pi remains the coding-agent runtime.
- Preserve the user's existing Pi installation and configuration.
- Preserve the user's existing oMLX configuration.
- Current model: `Qwen3.8-27b-pi-oQ8e-mtp`.
- Milk must not bypass Pi and talk directly to oMLX in the normal runtime path.
- Do not silently reduce or reinterpret requirements from the docs.
- Do not repeatedly ask for minor implementation choices already covered by the docs.

## Platform rules

- macOS 26.0+
- Apple Silicon only
- Swift
- SwiftUI primary
- AppKit/TextKit where appropriate
- no Electron
- no Catalyst
- native macOS design
- native Liquid Glass behavior where provided by the system

## Engineering rules

- Prefer native Apple frameworks.
- Keep external systems behind clear abstractions.
- Use Swift concurrency appropriately.
- Keep expensive work off the main thread.
- Avoid god objects and giant files.
- Build and test after meaningful implementation changes.
- Fix recoverable implementation problems instead of only reporting them.
- Keep documentation aligned with actual architecture.
