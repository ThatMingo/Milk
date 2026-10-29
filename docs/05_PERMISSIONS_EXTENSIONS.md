# Milk — Permissions and Extensions

## Agent permission modes

### Autonomous

Pi may perform its normal supported actions without per-action approval.

Milk still shows activity and resulting file/Git changes.

### Approval

Supported mutating or potentially dangerous actions should require approval before execution.

Examples may include:

- file writes
- file deletion
- shell commands
- package installation
- destructive Git actions
- external network actions where interception is technically possible

Approval must occur before execution.

Codex must inspect Pi's actual tool/extension hooks to determine the right implementation.

A Milk companion Pi extension is acceptable if necessary.

Possible choices:

- Deny
- Allow once
- Allow for session

Future:

- scoped allowlists
- safe-command patterns

This is workflow protection, not a full OS sandbox.

## Pi extensions

Existing Pi extensions should remain functional where Pi's programmatic/RPC interface supports them.

Where Pi extensions request user interaction, Milk should bridge supported interactions into native UI where practical.

## Milk extensions

Milk also needs its own extension system.

Future extensions may add:

- commands
- sidebar content
- inspector content
- toolbar actions
- context menus
- preview providers
- language services
- service integrations
- Pi-related features
- Git/GitHub features
- status items

## Permissions

Potential extension permissions:

- workspace.read
- workspace.write
- process.execute
- network
- pi.interact
- git
- github
- UI contribution permissions
- preview permissions

Permissions should be explicit and centrally enforced.

## Isolation

Avoid arbitrary untrusted in-process plugin code as the main extension model.

Prefer a process-isolated native design such as XPC, ExtensionKit, or another suitable versioned protocol.

Extension crashes must not crash Milk.

## Lifecycle

Support architecture for:

- install
- enable
- disable
- uninstall
- update compatibility
- diagnostics
- permission review

A public marketplace is not required initially.
