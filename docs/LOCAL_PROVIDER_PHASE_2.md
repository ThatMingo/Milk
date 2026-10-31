# Local provider behavior — Phase 2 report

1. **Previous unknown-limit behavior:** Milk required complete positive context
   and output limits to save/start the selected model, excluded models with missing
   limits from Pi configuration, and exposed manual fields during normal setup.
2. **New behavior:** unknown limits remain nil in Milk, are omitted individually
   from each models.json entry, and do not block save, selection or startup.
   No universal context/output numbers were introduced in Milk.
3. **Pinned Pi support:** Pi 1.4.0's model schema accepts optional contextWindow and
   maxTokens. Its `modelFromJson` in `provider-composer.ts` fills omitted values
   with Pi-owned defaults. Milk now delegates this behavior rather than forcing
   manual metadata. Tests verify omission in the serialized file and actual Pi
   inference with both values omitted. Live RPC may report Pi's effective defaults;
   they are not written into Milk's draft as discovered server capabilities.
4. **Optional overrides:** collapsed Advanced model limits contain optional Auto
   fields. They are per exact model ID and separate from server metadata.
   Explicit user values take precedence over reported values. Auto uses a reported
   value when present, otherwise supplies no value. Context-only and output-only
   metadata are handled independently. Existing positive-value validation remains.
5. **Previous None behavior:** Pi's static availability key reached the inference
   server as a placeholder Bearer header. Empty-string headers had failed in the
   earlier investigation and did not implement no-auth.
6. **New None behavior:** actual inference requests contain no Authorization header,
   including no empty header. The deterministic fixture now rejects the presence
   of any Authorization header in None mode, and pinned Pi inference passes.
7. **Exact mechanism:** the documented `before_provider_headers` Pi extension hook
   mutates request headers; null deletes a header. MilkPiIntegration sets matching
   case-insensitive Authorization entries and `Authorization` itself to null only
   when `ctx.model.provider == "milk-local"` and the adapter's non-secret launch
   flag `MILK_PI_LOCAL_NO_AUTH` is set. Static model configuration remains owned
   by Pi; no provider re-registration or custom inference implementation was added.
   The static availability key remains internal to satisfy Pi's catalog/client.
8. **Pinned limitations:** Pi resolves omitted limits to its own effective defaults;
   it does not expose an unknown numeric runtime value. Its static JSON header
   schema accepts strings, not null, so true header omission uses the documented
   request hook instead. An independently launched Terminal Pi does not implicitly
   load Milk's integration hook or receive Milk's Keychain-backed environment.
   Trusted third-party extensions retain Pi's ordinary ability to alter requests.
9. **API-key mode:** still uses the selected profile's Keychain credential and Pi's
   normal bearer transport. The no-auth flag is cleared in this mode. The strict
   fixture validates the exact API key; no secret enters models.json, UserDefaults
   or new logs. A separate test verifies two profiles at the same endpoint resolve
   different credentials and remain isolated.
10. **Files changed in this phase:** listed below. Phase 1 profile architecture and
    state identity/scoping were not changed.
11. **Focused verification:** six distinct Local tests passed, zero failures:
    two existing actual-Pi routing methods (None and API key), three new
    PiLocalProviderTests methods (unknown/partial/discovered/override serialization,
    normal settings save, scoped key resolution), and one new actual-Pi unknown
    limits + strict None inference/resume method. No failure reruns were needed.
    Existing unknown-limit assertions in PiProviderSettingsTests were updated for
    the new contract; that broader group was not executed. `git diff --check`
    passed. No full suite, packaging, screenshots or unrelated groups ran.
12. **Phase 1 preserved:** managed profile path, PI_CODING_AGENT_DIR, Existing Pi
    setup, profile-scoped defaults/Keychain, removal/reinstall, extensions and
    session ownership remain intact. Tests used disposable directories/accounts;
    no real user server configuration or ~/.pi was modified.
13. **Inference ownership:** Milk still performs only configuration/discovery.
    Actual test responses are generated through the pinned Pi process's provider
    implementation. Chat model and reasoning controls still use native Pi RPC.
    No global oMLX, polling, inference client or unrelated stability fix was added.
14. **Git:** continued `refactor/agent-provider-settings`. Nothing pushed or merged;
    work remains local and uncommitted. Stopped after Phase 2.

## Exact changed files

- `Sources/Milk/PiProviderConfiguration.swift`
- `Sources/Milk/PiProviderSupport.swift`
- `Sources/Milk/PiSettings.swift`
- `Runtime/MilkPiIntegration.ts`
- `Tests/Fixtures/local_provider_fixture.py`
- `Tests/MilkWorkspaceTests/PiLocalProviderTests.swift` (added)
- `Tests/MilkWorkspaceTests/PiProviderRoutingTests.swift`
- `Tests/MilkWorkspaceTests/PiProviderSettingsTests.swift`
- `README.md`
- `RUNTIME.md`
- `docs/AGENT_PROVIDER_SETTINGS.md`
- `docs/README.md`
- `docs/LOCAL_PROVIDER_PHASE_2.md` (added)

## Source evidence and test commands

Inspected the pinned runtime's docs/extensions.md and docs/models-configuration.md,
plus matching Pi 1.4.0 source archive:

- `packages/coding-agent/src/core/model-config.ts`: optional numeric model fields.
- `packages/coding-agent/src/core/provider-composer.ts`: modelFromJson defaults.
- `packages/coding-agent/src/core/extensions/types.ts`: BeforeProviderHeadersEvent
  explicitly documents null as deletion and in-place mutation.
- `packages/coding-agent/src/core/extensions/runner.ts`: emits the header event
  with the active extension context.

Using Xcode and workspace-local caches, only these filters ran:

```sh
swift test --disable-sandbox --cache-path "$PWD/.build/cache" --filter PiProviderRoutingTests
swift test --disable-sandbox --cache-path "$PWD/.build/cache" --filter 'PiLocalProviderTests|PiProviderRoutingTests/testUnknownLimitsUsePiDefaultsAndTrueNoAuth'
git diff --check
```

First run: 2 passed. Second run: 4 passed. Logs:
`/tmp/milk-local-phase2-routing.log`, `/tmp/milk-local-phase2-limits.log`.
Host access was used for disposable Keychain accounts and loopback fixtures.


## Final override precedence correction

1. **Rule:** independently for context and maximum output, explicit per-model
   override → authoritative reported value → omit the field and defer to Pi.
2. **Auto:** no explicit override; use the reported value if available, otherwise
   omit that field from models.json.
3. **Numeric value:** overrides the automatically selected value, including a
   reported value. Both Advanced controls are available even with reported
   metadata. Reported metadata is displayed separately and is not overwritten.
4. **Verification:** three relevant test methods passed with zero failures. The
   new serialization matrix covers all sixteen independent context/output
   combinations (reported/absent × override/Auto for each field). Existing
   per-model serialization and discovered-metadata preservation checks also pass.
   No full suite ran. `git diff --check` passed.
5. **Files changed by this correction:**
   `Sources/Milk/PiProviderConfiguration.swift`, `Sources/Milk/PiSettings.swift`,
   `Tests/MilkWorkspaceTests/PiLocalProviderTests.swift`,
   `Tests/MilkWorkspaceTests/PiProviderSettingsTests.swift`, `RUNTIME.md`,
   `docs/AGENT_PROVIDER_SETTINGS.md`, and this report.
6. **Unchanged:** true no-auth/header hook, API keys, profile isolation and scoped
   credentials, discovery, exact IDs, Pi defaults, inference ownership, sessions
   and all other Phase 1/2 behavior.
7. **Git:** same `refactor/agent-provider-settings` branch; nothing pushed or
   merged. Stopped after the precedence correction.

Focused filter used with Xcode, workspace caches and --disable-sandbox:
`PiLocalProviderTests/(testOverridePrecedenceIndependentlyForContextAndOutput|testUnknownPartialAndExplicitLimitsAreSerializedPerModel)|PiProviderSettingsTests/testAPIKeyDiscoveryAndExplicitLimitOverridesPreserveReportedMetadata`.
Log: `/tmp/milk-local-override-tests.log`.
