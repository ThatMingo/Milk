# Milk — Development Context

## Local project folder

`Milk - Pi Coding Agent GUI`

This is the authoritative development workspace.

Codex should edit, build, test, and run Milk locally on the Mac.

## GitHub repository

`ThatMingo/Milk`

GitHub is the remote repository for:

- version history
- backup
- collaboration
- pull requests
- CI/releases later

It is not the primary runtime for local Pi/Xcode/macOS integration.

## Current local AI configuration

Known product context:

- Pi coding agent
- oMLX
- `Qwen3.8-27b-pi-oQ8e-mtp`

Exact executable paths, versions, RPC behavior, and configuration paths must be verified locally.

## Product name

Current name: **Milk**

Avoid unnecessary hard-coding that would make future rebranding difficult.

## Implementation philosophy

This is intended to become a real product.

Avoid:

- demo-only fake behavior
- mock UI presented as complete functionality
- hard-coding one model into the architecture
- coupling the UI directly to oMLX
- giant monolithic SwiftUI views
- unnecessary setup conversations for decisions the coding agent can reasonably make

Prefer:

- working vertical slices
- native behavior
- modular architecture
- reliable local execution
- inspectable changes
- strong documentation of real architecture
