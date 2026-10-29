# Milk — Product Brief

## What Milk is

Milk is a native macOS desktop application that provides a graphical frontend and coding environment for the Pi coding agent.

The user currently runs Pi in Terminal with a local Qwen model through oMLX. The terminal workflow is functional but inconvenient for long prompt editing, copy/paste, inspecting changes, switching projects, managing multiple sessions, previewing work, and manually editing code.

Milk should keep Pi as the agent runtime while replacing the terminal-centric experience with a polished native macOS application.

## Product concept

Think:

**Codex-style desktop coding environment for Pi**

but:
- local-first
- native macOS
- optimized for Pi
- optimized for local models
- extensible over time

Milk is not a new coding agent and not a new model client.

## Existing local AI setup

- Pi coding agent
- oMLX
- `Qwen3.8-27b-pi-oQ8e-mtp`

Target runtime:

```text
Milk
  ↓
Pi programmatic/RPC interface
  ↓
existing Pi configuration
  ↓
oMLX
  ↓
Qwen3.8-27b-pi-oQ8e-mtp
```

## Primary goals

The user wants:

- easy long-form prompt editing
- easy copy/paste
- independent session tabs
- workspaces/projects
- built-in file browser
- full code editor
- visible changes and diffs
- Git integration
- GitHub integration
- previews
- optional integrated terminal
- native macOS design
- extension support
- direct `.app` distribution to friends
