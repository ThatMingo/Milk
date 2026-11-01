# Releasing Milk

This is the workflow for a future, explicitly authorized publication. The build
scripts do not tag, push or create GitHub Releases automatically.

## Version and artifact policy

- `VERSION` is the canonical stable SemVer value: `MAJOR.MINOR.PATCH`. Use PATCH
  for fixes, MINOR for compatible features and MAJOR for incompatible changes.
  Before 1.0, minor releases may introduce breaking changes. Prerelease suffixes
  are not currently accepted by the build validator.
- `BUILD_NUMBER` is a separate, monotonically increasing positive integer
  (currently 1–9999, no leading zeroes). Increment it for every distributable
  build, including a rebuild of the same product version.
- Assets are named `Milk-<version>-macOS-arm64.zip` and contain `Milk.app`.
  Current builds target Apple Silicon (`arm64`) and require macOS **26.0**.
  Use the actual `release.json.minimumSystemVersion` for each release; the
  packager checks it against Info.plist and the executable's deployment target.
- `release.json` records version, integer build, platform, architecture,
  minimumSystemVersion, asset basename, SHA-256 and releaseTag. Keep it paired
  with its exact ZIP. SHA-256 detects a changed/corrupt download; it does not
  replace trusted metadata, code signing or notarization.

## Release checklist

1. Start from the intended local `main` commit. Update `VERSION` when appropriate.
   Use a new version if its release tag already exists; never move a published
   tag or silently replace published artifacts.
2. Increment `BUILD_NUMBER`. Change these canonical files only; do not edit
   generated bundle metadata manually.
3. Follow [developer verification](DEVELOPMENT.md): select full Xcode, prepare
   disposable test fixtures, perform a clean app build and run the relevant
   acceptance checks and Swift tests. Run the focused checks documented in
   [versioning](VERSIONING.md) and [packaging](RELEASE_PACKAGING.md). Review and
   commit the intended release-preparation changes before tagging.
4. Run `./scripts/build-release.sh`. This reuses the normal app builder in release
   configuration. If required by the host, use its supported
   `--disable-sandbox` option. Do not change source/version inputs during the build.
5. Inspect `output/release/Milk-<version>-macOS-arm64.zip` and
   `output/release/release.json`. Confirm canonical version/build, ZIP basename,
   `releaseTag = v<version>`, arm64 and minimum macOS version agree. Compare
   `shasum -a 256 output/release/Milk-<version>-macOS-arm64.zip` with `sha256`.
   The packager already tests ZIP integrity, extracts it and verifies the
   unpacked bundle's metadata, executable permissions, architecture and signature.
   These outputs are ignored; do not commit them to Git.
6. Verify and record signing/notarization status for the exact artifact. Inspect
   `codesign -d --verbose=4 output/Milk.app` and run
   `codesign --verify --deep --strict output/Milk.app`. Current signing is **ad hoc
   with hardened runtime**, and the current release is **not notarized**. Passing
   signature integrity verification does not establish Developer ID or notarization
   trust. Proper Developer ID signing and notarization can be added in a later,
   separately scoped workflow; the present packager performs neither notarization
   nor stapling. State the actual status in the release notes.
7. After acceptance, create an annotated Git tag `v<version>` at the exact source
   commit used for the artifacts. It must match `release.json.releaseTag`.
8. Push `main` to the intended GitHub remote.
9. Push that specific tag to the same remote; do not push unrelated tags.
10. Create the GitHub Release for that tag, titled `Milk <version>`, using reviewed
    notes prepared from the template below. Publish only with release authorization.
11. Attach the verified ZIP and its matching `release.json` to that GitHub Release.
    Check the uploaded filenames and that both assets are available.

## Release notes

Start with [RELEASE_NOTES_TEMPLATE.md](RELEASE_NOTES_TEMPLATE.md). Summarize
user-visible changes since the previous release, replace placeholders with the
actual version, compatibility requirements and asset filename, and accurately
state signing/notarization status. Omit empty sections. Keep notes concise; avoid
internal phase names, development terminology, raw commit history, diagnostics
and implementation details that do not help users.

## Future updater contract

The intended discovery/verification chain is:

```text
GitHub Release → release.json → version/build → compatible asset → SHA-256 verification
```

Future Milk update logic should read the release metadata, compare version/build,
check platform, architecture and minimum macOS compatibility, select the named
asset, and verify its downloaded bytes against SHA-256 before any installation.
Signing/trust and installation policy require their own implementation. This
document does not implement or activate update functionality.
