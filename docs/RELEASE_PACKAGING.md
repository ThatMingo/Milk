# Local release packaging

Run from the checkout on Apple Silicon with full Xcode selected:

```sh
./scripts/build-release.sh
# If nested SwiftPM sandboxing is unavailable:
./scripts/build-release.sh --disable-sandbox
```

This wraps the existing `scripts/build.sh --configuration release`; it does not
introduce another app builder. `VERSION` and `BUILD_NUMBER` remain authoritative.
The existing signing configuration is inherited unchanged, including optional
`CODESIGN_IDENTITY`; its default is ad hoc signing with hardened runtime.

The only published local outputs are in ignored `output/release/`:

- `Milk-<VERSION>-macOS-arm64.zip`, containing only the existing distributable `Milk.app`.
- `release.json`, containing version, integer build, platform, architecture,
  minimumSystemVersion, asset basename, SHA-256 and the future releaseTag.

The bundle retains the distributable extension SDK already staged by the normal
builder. The repository, test fixtures and developer state are not archived.
Ditto preserves executable permissions and bundle structure. Resource forks and
extended-attribute sidecars are excluded, avoiding an extra `__MACOSX` ZIP root.

The packager verifies canonical/bundle metadata, exact executable architecture
with `lipo`, and matching Info.plist/Mach-O deployment versions with `vtool`.
It tests ZIP integrity, extracts into temporary storage, and verifies the
unpacked metadata, executable permissions/architecture and deep strict signature.
It rechecks the ZIP hash and JSON consistency before publication.

Prior generated ZIP/JSON outputs are removed before building. Unknown files or
symlinked output directories are rejected. New artifacts are staged outside
`output/release/`; the verified ZIP is published first and its manifest last.
An unsuccessful build cannot leave a prior generated manifest looking current.
No Git commands, download URL, release notes, notarization, stapling, updater,
tagging or publishing operations are performed. A valid ad hoc signature verifies
local integrity; it is not Developer ID/notarization qualification.

Focused checks: `python3 -m unittest discover -s Tests/ReleasePackaging -v`.
The packaging command itself performs the native round-trip integration checks.
