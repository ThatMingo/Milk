# Milk application versioning

Milk uses stable Semantic Versioning (`MAJOR.MINOR.PATCH`). The root `VERSION`
file is the canonical product version; `BUILD_NUMBER` is the separate,
canonical positive integer build revision. Preserve the previously established
0.7.0 / build 7; this phase does not reset the product to 0.1.0 / build 1.

Change only these root files when bumping metadata. Increment PATCH for fixes,
MINOR for new compatible functionality, and MAJOR for incompatible changes;
pre-1.0 minor releases may introduce breaking changes. Increment BUILD_NUMBER
for each distributable build, including rebuilds of the same product version.
The current build-number policy accepts 1–9999 without leading zeroes.
Prerelease suffixes and build metadata are not accepted yet.

`scripts/build.sh` validates both files before compiling, generates Info.plist,
and stamps its `CFBundleShortVersionString` and `CFBundleVersion` from those
files before signing. Missing/malformed values fail the build without defaults.
Raw `swift build` produces an executable, not a Milk.app bundle.

`MilkApplicationVersion.current` centralizes runtime access in MilkExtensionHost.
Packaged apps read their actual bundle metadata. Unbundled SwiftPM development
executables/tests without application metadata can read the canonical checkout
files; unavailable metadata stays unavailable rather than inventing a version.
The existing About/Settings version, terminal environment and native extension
compatibility defaults consume this helper. Existing updater behavior is unchanged.
API examples, minimum supported extension versions and historical reports are not
sources of the current product version.

Future tags should use `vMAJOR.MINOR.PATCH` (for example `v0.7.0`). No tag,
release, artifact archive or updater implementation is created in this phase.

Verify with a clean `./scripts/build.sh --disable-sandbox`,
`python3 -m unittest discover -s Tests/Versioning`, and
`swift test --disable-sandbox --filter ApplicationVersionTests` with full Xcode selected.
