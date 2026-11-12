# Pi Runtime Updates

Current reference for how Milk discovers, verifies and maintains Pi runtime
code. This is what the compiled app does today.

## No approved-version list

Milk does not carry a list of approved Pi versions. `PiInstallationCatalog.standard`
ships no releases, and `PiReleaseDiscovery` reads the official upstream
repository:

```text
https://api.github.com/repos/earendil-works/pi/releases?per_page=50
```

A new Pi release becomes available to a running Milk build without a Milk
application update.

## Eligibility

A release is eligible only if all of the following hold:

- it is a stable release: not a draft, not a pre-release;
- its tag parses as a strict semantic version (`major.minor.patch`);
- it is not older than the adapter baseline, Pi 1.4.0
  (`PiCompatibilityPolicy.minimumEligibleVersion`);
- it publishes the official archive asset for this platform and architecture
  (`pi-darwin-arm64.tar.gz`, or `pi-darwin-x64.tar.gz` on x86_64);
- that asset is served from the exact official path
  `https://github.com/earendil-works/pi/releases/download/<tag>/<asset>`;
- the release API publishes a valid SHA-256 digest for that asset.

Releases are ordered by semantic version, not string order (`1.10.0` is newer
than `1.9.0`).

## Integrity and trust model

Trust source: the official GitHub release API for `earendil-works/pi`, fetched
over HTTPS. That is a metadata trust boundary, not a signature or notarisation.
Upstream Pi publishes no detached signature, so Milk:

1. takes the archive digest from upstream metadata (never from the download
   itself);
2. cross-checks it against the release's own `SHA256SUMS` manifest, which is
   itself verified against the digest the release API published for that
   manifest;
3. downloads the archive and compares the bytes with the expected digest
   **before** extraction or execution;
4. extracts with the bounded libarchive path, rejects symbolic links, special
   files, missing required paths, and any executable that is not a thin native
   Mach-O for the selected architecture;
5. pins the digest of every verified file in the revision, so later launches
   detect local modification without a network round trip.

Milk-pinned auxiliary tools (`bin/rg`, `bin/fd`) are separate Milk trust
anchors, downloaded only for arm64 and verified against Milk's own pins.

A digest computed from an unverified download is never treated as proof of
authenticity; it only becomes integrity metadata for code already installed.

## Eligibility is not verification

Two gates are kept deliberately separate:

| Gate | Meaning |
| --- | --- |
| `requireProbeEligible` | the isolated compatibility probe may inspect an eligible, structurally valid release |
| `requireSupportedVersion` | an ordinary user session may run only a revision whose probe handshake succeeded on this machine |

`PiCompatibilityPolicy.evaluate(version:, verified:)` uses the verified set
stored in the installation store, not a compiled allow-list. A discovered
release that has never been probed is `.untested` and is refused for sessions.

## Automatic updating

Auto Update (Settings → Agents) applies to Milk-managed runtimes only. A
candidate is staged automatically only when:

- Auto Update is enabled;
- no update is already pending;
- Pi runtime work is quiescent (no owned Pi runtime work in progress);
- the candidate is newer than the selected managed runtime;
- that exact release (version + asset digest) has not already been rejected on
  this machine.

Release checks run on launch and then periodically (`PiUpdateSchedule.interval`,
24 hours) for persistent workspace state. A check counts as complete only when
the feed read succeeded: the timestamp is stamped on success, and the discovered
release list is stored with it, so a restarted Milk still knows the eligible
releases without re-reading the network. A failed read leaves the timestamp
untouched, so the next scheduled pass retries instead of waiting out the
interval. Manual "Check for Updates" always refreshes the feed, even when Auto
Update is off or the automatic window has not elapsed; concurrent checks join the
read already running and receive its completed result rather than a stale cache.

Staging never replaces the running runtime. The verified revision is registered
as `pending` and activated when Pi work drains, or explicitly with
Activate Update. Rollback returns to the retained known-good revision using only
local code and metadata.

Failures are recorded, not fatal:

- an artifact digest mismatch records a rejection and leaves the installed
  runtime untouched;
- a probe failure records a rejection and the staged directory is discarded;
- a discovery/network failure is surfaced in Settings as
  "update check unavailable" and never affects an already verified runtime;
- an interrupted transaction cleans its staging directory on the next
  recovery pass and keeps the previous runtime selected.

Externally owned Pi installations are never updated automatically; they are
registered and verified only when the user explicitly selects them.

## State

`~/Library/Application Support/Milk/Agents/pi/` holds immutable revision
directories plus the installation state. Additive fields in the state file:

- `rejected`: releases this machine examined and refused, keyed by version and
  asset digest;
- `lastReleaseCheck`: when the upstream feed was last read successfully;
- `discoveredReleases`: the eligible release metadata from that successful read,
  used to answer Settings and update questions after a restart without a
  network round trip.

Older state files load unchanged; no destructive migration is required for an
existing Pi 1.4.0 managed installation.

## Tests

`Tests/MilkWorkspaceTests/PiAutoUpdateTests.swift` exercises the whole path with
local fixtures only: tar/Mach-O fixtures, a fake release feed, tampered bytes,
download gates, probe failures and offline mode. No test downloads a real Pi
artifact.
