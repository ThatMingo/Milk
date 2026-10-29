# Milk — Locked Decisions

These choices are already decided unless a concrete technical blocker requires revisiting them.

## Platform

- macOS only
- minimum macOS 26.0
- Apple Silicon only
- native application
- Swift
- SwiftUI primary
- AppKit/TextKit where needed
- no Electron
- no Catalyst

## Design

- native Apple macOS design
- native Liquid Glass behavior
- system light/dark mode
- first-party macOS feel
- avoid fake custom glass when system controls already provide it

## Pi/model

- use existing Pi installation
- use existing Pi configuration
- use existing oMLX configuration
- current model: `Qwen3.8-27b-pi-oQ8e-mtp`
- Milk integrates with Pi through Pi's supported programmatic/RPC interface
- Milk must not bypass Pi and use oMLX directly as the normal path

## Workspaces

- a workspace is a local folder
- remember previous workspaces
- local Mac is the development/runtime environment
- GitHub is only the remote repository

## Sessions

- multiple tabs
- every Pi session is independent
- sessions do not share conversation context

## Editor

The user explicitly wants a **full-fledged code editor**, not a basic text area.

## Terminal

- include an optional integrated terminal
- normal Pi usage should not require Terminal

## Permissions

Two user-selectable modes:

### Autonomous
Pi works without per-action approval.

### Approval
Supported mutating/dangerous actions require approval before execution.

## Git

- Git is core functionality
- background Git refresh/automation is allowed and configurable

## GitHub

- GitHub integration is required
- Milk repository: `ThatMingo/Milk`

## Preview

Support, where practical:

- HTML/web
- localhost web apps
- Markdown
- images
- SVG
- PDF
- JSON
- text/code

Prefer the simplest reliable dev-server preview approach first.

## Extensibility

Milk must support extensions/plugins.

Extensions may need permissions for:

- workspace read/write
- process execution
- network
- Pi interaction
- Git/GitHub
- UI contributions
- preview/language/integration features

Extension crashes must not crash Milk.

## Networking

- core app is local-first
- no telemetry by default
- no unnecessary external requests
- explicit networked features are allowed
- extensions may use network when permitted

## Distribution

- built-in self-update support
- direct `.app` distribution
- Developer ID signing/notarization architecture
- friends should not need Xcode or Terminal for normal use
