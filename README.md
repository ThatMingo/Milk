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
