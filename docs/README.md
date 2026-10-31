# Documentation

## Current references

Start with the README for an overview and Developer setup to build from source.

- [Milk](../README.md): current features, agents, requirements and release status.
- [Developer setup](DEVELOPMENT.md): build/run commands, test requirements and
  optional upstream Pi fixtures.
- [Runtime architecture](../RUNTIME.md): compiled adapter, installation selection,
  lifecycle, sessions and code/data ownership.
- [Provider/profile final acceptance](PROVIDER_FINAL_ACCEPTANCE.md): final clean
  build, full regression, native acceptance and merge-gate evidence.
- [Provider/profile Phase 3](PROVIDER_PROFILE_PHASE_3.md): focused real-Pi
  integration, switching/retention, Settings wiring and architecture audit.
- [Local provider Phase 2](LOCAL_PROVIDER_PHASE_2.md): omitted model limits and
  true no-auth transport through pinned Pi.
- [Pi profile ownership](PI_PROFILE_OWNERSHIP.md): managed isolation versus Existing
  Pi setup, retention and focused verification.
- [Agent provider settings](AGENT_PROVIDER_SETTINGS.md): current ownership, Pi Local
  setup, adapter settings contract, capability sources and safe migration.
- [Extension development](EXTENSION_DEVELOPMENT.md): MilkExtensionKit API 1,
  native packages, trust, services and the independent example.
- [Agent final acceptance](AGENT_PHASE_FINAL_ACCEPTANCE.md): completed technical
  baseline, 156/156 tests, exact evidence scope and remaining app-release gates.
- [Source-publication audit](PRE_GITHUB_AUDIT.md): Phase 1 source hygiene,
  exclusions and the source/app-release distinction. Its size/counts are the
  recorded Phase 1 snapshot, before later documentation additions.
- [Public documentation review](GITHUB_PUBLIC_DOCS_REVIEW.md): publication Phase 2
  changes and static verification.
- [Third-party notices](../ThirdPartyNotices/README.md) and
  [dependency inventory](../ThirdPartyNotices/INVENTORY.md): licenses, pins and
  source/download/app-resource boundaries.

## Architecture and planning

- [Agent architecture handoff](MILK_AGENT_ARCHITECTURE.md): original design intent,
  including targets beyond the implemented product. Current runtime behavior is
  described in the runtime reference and final acceptance above.
- [Planned features](MILK_PLANNED_FEATURES.md): future directions; not a delivered
  feature list or commitment to implementation dates.

## Historical implementation records

These are point-in-time Agent Refactor records. Earlier test counts, bundled
runtime assumptions, deferred work and recommendations belong to their original
phase; they do not override current references or final acceptance.

- [Phase 0 — Pi parity contract](PI_PARITY_CONTRACT.md)
- [Phase 1 — adapter boundary](PHASE_1_AGENT_BOUNDARY.md)
- [Phase 2 — lifecycle ownership](PHASE_2_AGENT_LIFECYCLE.md)
- [Phase 3 — installation resolution](PHASE_3_INSTALLATION_RESOLUTION.md)
- [Phase 4 — sessions](PHASE_4_AGENT_SESSIONS.md)
- [Phase 5 — managed installations](PHASE_5_MANAGED_INSTALLATIONS.md)
- [Phase 6 — Agents UI and clean app](PHASE_6_AGENTS_UI_AND_CLEAN_APP.md)

The older native-extension implementation also used “Phase 7.” That chronology
is distinct from the Agent Refactor's final acceptance and from GitHub Publication
Phases 1–2. Current extension behavior is documented as **MilkExtensionKit API 1**.

Evidence paths under `output/` in historical/acceptance reports refer to generated
local files excluded from the public source tree, not downloadable GitHub assets.
Ignored private references, older briefs and validation archives are not required
for building Milk or reading its current public documentation.
