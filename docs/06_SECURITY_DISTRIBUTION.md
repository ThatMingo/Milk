# Milk — Security, Privacy, Updates, Distribution

## Local-first

Milk is primarily local and should not require a Milk backend.

## Network policy

Network access is allowed when explicitly needed for:

- Git remotes
- GitHub
- update checks
- project dev servers
- existing Pi/model provider behavior
- extensions granted network access

Avoid unnecessary external requests.

## Telemetry

No telemetry by default.

## Secrets

Do not put credentials, tokens, or sensitive environment values into normal logs.

Use secure storage such as Keychain for Milk-owned secrets if necessary.

Prefer reusing existing secure authentication where practical.

## Untrusted input

Treat as untrusted:

- model output
- generated shell commands
- repository content
- external service responses
- extension output

## Diagnostics

Provide useful diagnostics for:

- Pi not found
- incompatible Pi version
- Pi crash
- protocol errors
- provider/model unavailable
- workspace permission problems
- Git errors
- merge conflicts
- preview failures
- language-server failures
- extension crashes
- updater failures

## Self-update

Built-in self-update support is required.

Support:

- update checks
- user-controlled automatic checks
- release notes
- secure verification
- installation
- restart when appropriate

## Direct distribution

Milk should become a normal macOS `.app` distributable to friends.

Architecture should support:

- Developer ID signing
- notarization
- release packaging
- updater/release infrastructure

Normal users should not need Xcode or Terminal.
