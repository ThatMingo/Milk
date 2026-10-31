# Agent-owned provider settings

Milk manages coding agents. Coding agents own their providers, models,
authentication and provider-specific configuration. The runtime hierarchy is
**Milk → Coding Agent → Provider → Model**, currently **Milk → Pi → Local → Model**.
Local describes the OpenAI-compatible protocol, not an oMLX integration.

## Settings workflow and ownership

Install Pi or select an existing installation in Settings → Agents. Pi's native
configuration sections become available beneath its installation controls.
Installation/version/Verify/Update/Repair/Roll Back/Remove/Forget remain Milk-owned
code management. Provider configuration lives in a separate Pi-specific store;
changing it does not select, install or probe an executable.

Choose **Local**, enter an HTTP(S) endpoint, select **None** or **API key / bearer
token**, and use **Test Connection**. Pick an exact discovered ID or enter one.
Optionally configure per-model Advanced context/output overrides, then save.
Unknown limits do not block normal setup.
Only Local shows connection/authentication/discovery controls. **Pi configured
providers** leaves other provider setup to Pi, with no fabricated hosted-provider
or future-agent entries. Chat continues to offer Pi's live model/thinking choices.

A root URL such as `http://127.0.0.1:8000` expands to `/v1`; an explicit path such
as `/v1` or a custom proxy path is used as the API base. Embedded credentials,
queries and fragments are rejected. TLS, HTTP and authentication errors are
reported without echoing response bodies or secrets. Discovery rejects redirects
instead of forwarding credentials to another endpoint. Testing never writes Pi or
server configuration and schedules no polling.

## Adapter contract

`AgentAdapter` exposes:

```swift
var settingsProvider: (any AgentSettingsProviding)? { get }
```

The optional facet is native and deliberately opaque to core:

```swift
@MainActor protocol AgentSettingsProviding {
    var settingsSections: [AgentSettingsSection] { get }
    func settingsView(section: String, agent: AgentService) -> AnyView
}
struct AgentSettingsSection: Identifiable, Equatable {
    var id: String
    var title: String
}
```

Core hosts these sections for registered agents with a selected installation.
An adapter owns its SwiftUI form, schema, validation, connection actions and
persistence. A future adapter can expose sandbox, permission, authentication or
other controls without adding provider assumptions to Milk's settings host.
No other production coding agent is implemented.

`AgentService.applyAgentSettings(_:)` admits adapter persistence only while agent
work is idle. Running sessions, starts, pending actions, approvals, termination,
and live auxiliary work prevent replacement. It persists workspace recovery before
settings mutation and uses the existing invalidation/reconnect lifecycle. Generic
core never interprets Pi provider fields or credentials.

`PiAdapter` implements the facet with section `pi.configuration`, `PiSettingsModel`
and `PiSettingsContent`. `PiProviderConfiguration` and `PiLocalConfiguration` own
provider selection, endpoint, authentication mode, default model and optional
per-model capabilities. They are separate from `AgentConfiguration`'s legacy
runtime/default-permission preferences and the installation manager's records.

## Pi translation and persistence

The selected Pi profile is Milk's `Agents/pi/profile/` for managed installations.
Existing Pi retains the ambient `PI_CODING_AGENT_DIR`, otherwise `~/.pi/agent`.
See [profile ownership](PI_PROFILE_OWNERSHIP.md). Managed provider drafts use a
separate UserDefaults key scoped by Milk's agent root, so switching does not apply
the existing setup's draft to the isolated profile. `PiProviderSupport` merges only its reserved `milk-local` provider
entry in `<agent-dir>/models.json`. It uses Pi's `openai-completions` API, exact
model IDs and known per-model metadata. Unrelated providers/top-level fields are
preserved; malformed files and conflicting unowned `milk-local` entries are not
overwritten. JSONC/JSON5 is read, the changed document is normalized to JSON, and
original bytes are retained in `models.pre-milk-local.<UUID>.json` before writes.
Files/backups are restricted to the user. Equal configuration causes no rewrite
or additional backup. Choosing Pi configured providers removes only the
adapter-owned entry.

A successful save validates the draft, applies the supported Pi configuration,
persists settings at `Milk.agent.pi.providers.v1`, and reconnects idle runtimes.
The adapter restores the previous Pi configuration/credential after an ordinary
save failure. These stores cannot form a cross-process atomic transaction; a
force-quit or external simultaneous edit remains outside that rollback guarantee.

Startup applies the same configuration after resolving Pi's profile, launches its
unchanged native RPC process plus Milk's integration extension, and selects the
exact provider/model using `set_model`. The extension retains handshake,
permissions, approvals and the native bridge; it registers no provider. Chat's
catalog/current model and reasoning levels come from `get_available_models`,
`get_state`, and `get_available_thinking_levels`, never from direct discovery.
Existing available session-specific composer choices can override the startup
default; changing provider is not changing session ownership.

Milk sends no inference requests. Pi handles prompts, providers, context
accounting and compaction. No compaction defaults or thresholds are changed.

## Capabilities and limits

`PiModelCapabilities` stores optional values per exact model ID, separating server
values from explicit overrides. Discovery reads only explicit optional metadata:

| Meaning | Accepted fields / precedence |
| --- | --- |
| Effective context | explicit per-model `contextOverride`, then `effective_context_window`, then `context_window`, otherwise unknown |
| Effective output | explicit per-model `outputOverride`, then `effective_max_tokens`, then `max_tokens`, otherwise unknown |
| Reasoning | server `reasoning`, then explicit per-model declaration, otherwise unknown |
| Images | server `input` modalities, then explicit per-model declaration, otherwise unknown |

The standard OpenAI `/models` response guarantees none of these capability fields.
There is no guessing from model names or brands, no theoretical model catalog,
and no probing of brand-specific health/status endpoints. Other metadata shapes
stay unknown. Re-testing replaces effective server metadata while retaining
explicit overrides. An endpoint edit invalidates the previous endpoint's model
capabilities and secret draft. Explicit numeric overrides take precedence over
reported limits without changing the stored server metadata.

Pi 1.4.0's static configuration accepts omitted numeric limits and fills them with
its own defaults. Milk now leaves unknown contextWindow/maxTokens fields absent
from models.json and allows selection, saving and startup normally. It does not
copy Pi's defaults back into the settings draft as discovered metadata. Pi's live
RPC reports its effective runtime values to Chat. Optional per-model Advanced
fields default to Auto: use the reported value if available, otherwise omit the
field for Pi. Numeric overrides take precedence independently for context and
output; server metadata and overrides remain separate.

Unknown reasoning/image fields are omitted from Pi configuration; Pi currently
resolves them conservatively to no thinking/text input. They remain unknown in
Milk's settings metadata; Chat displays Pi's effective RPC result. `AgentModel`
now also carries optional Pi-reported context, output and reasoning metadata.

There is no production model-limit fallback of 32768/8192, or replacement universal
numeric fallback, in Milk. The remaining `8192` in `StaticPreviewServer` is a
network receive buffer byte count, unrelated to models. Upstream runtime reference
material and deterministic tests may contain numeric examples; they do not supply
Milk's production model limits.

## Credentials and migration

`AgentProviderCredentials` is a generic Keychain facility. All current Pi adapter
settings, discovery and runtime credential lookups supply the profile identity. Its service is
`dev.milk.agent-provider`; its structured account includes agent `pi`, a stable Pi profile identity, provider
`local` and the endpoint. The profile identity is based on the canonical resolved profile path alone.
Different Existing Pi executables sharing that directory share Milk-side provider
state, matching their shared native Pi state. Runtime registration identity is
separate and is not included in profile identity. Previous unscoped credentials
are retained but are not implicitly assigned to any isolated profile. Secrets never enter UserDefaults, session/workspace
metadata, logs, runtime manifests or Git. `models.json` stores
`$MILK_PI_LOCAL_KEY`, and the actual key enters only the owned Pi child's in-memory
environment. Discovery reads the scoped key only for API-key mode.

Pi's static catalog needs an availability key, but its documented
`before_provider_headers` extension hook accepts null to omit an SDK header.
For Local None mode, PiProviderSupport sets the non-secret launch flag
`MILK_PI_LOCAL_NO_AUTH=1`; MilkPiIntegration sets Authorization to null only for
the `milk-local` provider. No Authorization header is transmitted, including an
empty header. Discovery also omits it. API-key mode clears that flag and uses the
profile-scoped Keychain credential as before. No inference runs in Milk.

This request-header integration is loaded by Milk's Pi launch. A separately
launched Terminal Pi reading the same models.json does not automatically have
Milk's header hook or its Keychain-backed child environment. Configure that
independent launch through Pi's own setup. See [Phase 2 report](LOCAL_PROVIDER_PHASE_2.md)
for pinned-source evidence and strict wire-level verification.

The initial refactor retained a legacy loader for `Milk.agent.configuration.v3`'s
`omlx` object and the old endpoint-scoped Keychain item. It preserves original
bytes/items and discards global numeric guesses. That compatibility helper is
covered by its deterministic tests, but it is not an automatic selected-profile
import in the final architecture: current adapters load profile-specific keys.
Old shared/registration-scoped development state is retained rather than assigned
or merged into an arbitrary profile. Managed settings keep their already-unique
agent-root key. Existing Pi uses its canonical-directory namespace. This avoids
reusing an unscoped credential across isolated profiles.

No migration or provider save rewrites session IDs, `agentID`, project ownership,
drafts, cached history or native JSONL history. No user endpoint or server
configuration was modified during development verification.

## Documented Pi interfaces investigated

The pinned Pi 1.4.0 runtime's `docs/configuration.md`, `docs/models.md`,
`docs/models-configuration.md`, `docs/cli.md`, `docs/rpc.md` and matching source
archive were inspected. The important upstream rule is that a supported protocol
belongs in `models.json`, rather than a custom provider extension. Provider
replacement is startup/file configuration; model and thinking changes are RPC.
There is no documented RPC in this integration for configuring an endpoint or
performing hosted OAuth login, so this pass adds neither hosted-provider setup
nor hot endpoint mutation during an active run.

References: [Pi configuration](https://github.com/earendil-works/pi/blob/v1.4.0/packages/coding-agent/docs/configuration.md),
[models](https://github.com/earendil-works/pi/blob/v1.4.0/packages/coding-agent/docs/models.md),
[models reference](https://github.com/earendil-works/pi/blob/v1.4.0/packages/coding-agent/docs/models-configuration.md),
[RPC](https://github.com/earendil-works/pi/blob/v1.4.0/packages/coding-agent/docs/rpc.md).

## Original provider-refactor verification (before Phase 2)

The evidence below records the earlier implementation. Current Local behavior and
verification are in [Phase 2](LOCAL_PROVIDER_PHASE_2.md).

The app and all test targets compiled with the Xcode toolchain. Only these groups
were executed, followed by narrow reruns of actual failures:

- `PiProviderSettingsTests`: 13 distinct tests passed. Eight passed initially;
  five needed a host-access rerun because sandboxed Keychain calls returned -50.
  All five passed with temporary scoped Keychain accounts.
- `PiProviderRoutingTests`: two distinct tests passed against actual pinned Pi
  1.4.0 and an isolated Python loopback fixture. Authenticated routing passed
  initially. Empty-header no-auth failed; switching to Pi's documented placeholder
  key resolved it. The narrow final rerun also verified old-provider JSONL resume.
- Targeted final checks: save/credential failure handling and no-auth/legacy resume,
  two tests passed, zero failures; then the single migration test passed after
  moving the legacy Keychain namespace entirely into Pi migration code.
- `git diff --check` passed. Production-source searches found no legacy provider
  injection, oMLX telemetry, or arbitrary model-limit fallback. The independent
  extension example and migration identifiers remain intentionally recognizable.

The test environment used `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`,
a workspace-local Clang module cache, `swift test --disable-sandbox --cache-path
"$PWD/.build/cache" --filter ...`, and host access only for Keychain/loopback tests.
No full test suite, packaging, signing, notarization, installation matrix,
screenshots, broad UI inspection, or unrelated test groups were run.

No chat/session stability work was performed. Existing deletion restrictions for
externally owned Pi runtimes remain unchanged; that rule may be relevant to the
reported undeletable session, but no diagnosis was established. No cause for the
reported transcript/live-entry problems is claimed.
