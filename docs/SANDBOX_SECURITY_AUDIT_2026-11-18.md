# Milk Sandbox Security Audit — commit `befaa31`

**Status:** read-only audit report (point-in-time evidence). Not a current reference; it does
not override `SANDBOX_POLICY.md`, `SANDBOX_ACCEPTANCE.md` or `design-docs/SANDBOX_ARCHITECTURE.md`.

| Field | Value |
|---|---|
| Audited ref | `befaa31` — "WIP: preserve Qwen work before branch comparison" |
| Baseline | `befaa31^` (`f03fcb5` — "Auto update fix") |
| Branch audited | `backup/qwen-work-2026-11-18` |
| Files in scope | `Sources/Milk/SandboxPathResolver.swift`, `Sources/Milk/SandboxPolicy.swift`, `Sources/Milk/SandboxProfile.swift`, `Tests/MilkWorkspaceTests/SandboxPolicyTests.swift` (+ supporting reads of `SandboxModels.swift`, `SandboxGrants.swift`, `SandboxProcess.swift`, `SandboxGit.swift`, `SandboxPurposePlan.swift`, `SandboxSettingsStore.swift`, `PiSandboxExecution.swift`, `PiBackend.swift`, `SandboxAcceptanceTests.swift`, `SandboxExecutionTests.swift`) |
| Repository state after audit | unchanged: `git status` clean, `git diff HEAD` empty, branch unchanged |
| Modifications made during audit | none to the audited checkout (no source, test, branch, commit, push, or agent-profile change) |

---

## 1. Executive verdict

**FAIL (as committed).**

The commit contains **one legitimate compatibility fix** (`SandboxPathResolver`) wrapped in **two
fail-open tolerances** (`SandboxPolicy`, `SandboxProfileBuilder`) that were proven to break an
invariant the code itself states. In executed probes, a protected location whose resolution fails
becomes **readable by a sandboxed child through an alias, with no approval prompt and a kernel
profile that permits it** — while the same situation on `befaa31^` produced `.deny` and refused to
generate a profile at all.

Recommendation: **keep the resolver fix (revised), withdraw/revise the `SandboxPolicy` and
`SandboxProfileBuilder` tolerance hunks.**

---

## 2. Change inventory

| File | Change | Stated purpose | Actual effect (verified) |
|---|---|---|---|
| `Sources/Milk/SandboxPathResolver.swift` (84–112) | `inspect()` no longer throws when `open(O_EVTONLY\|O_NOFOLLOW)` fails; falls back to `lstat()` + `canonicalEntry()`, which enumerates the parent directory to recover the volume spelling. New helper `canonicalEntry`. | Directories that "exist but refuse even an `O_EVTONLY` open" would make every legitimate grant fatal. | Any `open()` error (EACCES, EPERM, **ELOOP**, ENAMETOOLONG, …) on a `lstat`-able path now resolves. Canonical spelling is recovered **only if the parent is enumerable**; otherwise the caller-supplied spelling is returned verbatim. Canonical-path invariant is no longer guaranteed. |
| `Sources/Milk/SandboxPolicy.swift` (18, 26, 36–42) | `try resolver.resolve` → `try?` for protected locations; unresolved protected entries dropped from `snapshots`; new literal-string fallback `standardizedFileURL.path` comparison. | Inaccessible protected location must not abort policy compilation, must stay denied. | Protected enforcement silently downgrades to a **lexical prefix compare between a raw configured path and a kernel-canonical candidate path**. When the two differ the candidate falls through to inactive/folder/project/outside rules and may be `.allow`. |
| `Sources/Milk/SandboxProfile.swift` (20–29, 39, 114–116) | Catch **all** `SandboxPathError`s per protected location → `unverifiableProtected`; skip the hard-link rejection for them; **drop them from `roots`**; append `(deny file-read-data file-read-xattr file-read-metadata file-write* (subpath <raw url.path>))`. | "still denied by its literal path; it must not abort the launch". | Hard-link admission guard is skipped; the nested-exclusion carve-out the location used to contribute is removed; the compensating rule uses a **raw, non-canonical** path string that Seatbelt ignores in several spellings; appended deny outranks any allow (including an approved temporary grant). |
| `Tests/MilkWorkspaceTests/SandboxPolicyTests.swift` (187–218) | +2 tests. | Cover fail-closed behaviour and unopenable-directory resolution. | Only the **resolver** change is covered. Mutation tests (§5) show both policy and profile hunks are untested. |
| Other files in `befaa31` | Chat/memory rendering + docs only (`AgentService.swift` scroll-geometry flag; `AgentTranscript.swift` `reset()`/`retainedBytes()`). | — | No sandbox effect (both diffs read in full). Chat code was not modified. |

Diff used:

```sh
git diff befaa31^ befaa31 -- Sources/Milk/SandboxPathResolver.swift \
    Sources/Milk/SandboxPolicy.swift Sources/Milk/SandboxProfile.swift \
    Tests/MilkWorkspaceTests/SandboxPolicyTests.swift
```

---

## 3. Security findings

### F1 — Protected location that fails resolution stops being protected; its content is readable through an alias

**Severity: High (confirmed vulnerability, executed).**
`SandboxPolicy.swift:18`, `:36–42`; `SandboxProfile.swift:22–29`, `:39`.

**Mechanism.** `try?` makes *every* protected-resolution failure (`inaccessible`, `notDirectory`,
`tooManyLinks`, **`changedDuringResolution`** (TOCTOU), `invalidPath`) produce `nil`. The fallback
compares `path.canonicalURL.path` (descriptor/`F_GETPATH`-canonical, symlinks collapsed) against
`entry.1.standardizedFileURL.path` (raw configured string). If the candidate reaches the same
object under a different name — a hard link, or the real target of a symlinked/cyclic protected
entry — the prefix test fails and the candidate falls through to `.allowedFolder` / `.project` /
`.outsideProject`. Because the location was also removed from `roots`, no nested carve-out is
emitted.

**Evidence** (disposable replica, synthetic data, 4/4 deterministic runs + `sandbox-exec`):

```text
P1  protected = <tmp>/sealed/secret.txt   (chmod 000 sealed  -> resolve THREW inaccessible)
    hard link <tmp>/open/alias.txt (same inode, mode 0644), globalAllowedFolders = [<tmp> readWrite]
    policy:  outcome=allow rule=allowedFolder          (befaa31^: outcome=deny rule=unresolvedPath)
    make():  succeeded                                  (befaa31^: THREW inaccessible -> no launch)
    sandbox: cat <tmp>/open/alias.txt  -> "SYNTHETIC-SECRET" status=0   <-- protected content read
    emitted rule: (deny ... (subpath "<tmp>/sealed/secret.txt"))  ; direct path: Permission denied
```

`SandboxProfileBuilder.swift:15–17` states: *"Seatbelt pathname exclusions cannot follow
pre-existing hard-link aliases … reject admission rather than let a broader root expose another
name."* That guard is skipped precisely when the location cannot be resolved (`:26–29`), and
`SandboxAcceptanceTests.testKernelDeniesRetargetedAliasesTraversalAndStrongerOverlappingRoots`
enforces it only for **resolvable** protected files.

**Correction.** Do not let an unresolvable protected location fall through to weaker rules. When a
protected location cannot be verified, any candidate not provably outside it must be `.deny` (or at
minimum `.requireProtectedLocationApproval` with an explicit "unverifiable" boundary), never
`.allow`.

### F2 — The compensating Seatbelt deny is inert whenever the configured spelling is not canonical

**Severity: High (confirmed mechanism, `sandbox-exec` probes).**
`SandboxProfile.swift:27`, `:114–116` (`location.url.path`, never normalized/resolved).

Verified against the profile shape Milk actually generates (broad allow expression + appended deny):

| Deny rule spelling | Result |
|---|---|
| `(subpath ".../sb/secret")` | **enforced** (read/stat/write denied) |
| `(subpath ".../sb/SECRET")` (case variant, same dir) | enforced (volume is case-insensitive) |
| `(subpath ".../sb/secret/")` | enforced |
| `(subpath ".../sb/x/../secret")` (`x` exists) | **INERT — file readable and writable** |
| `(subpath ".../sb/OTHER")` (non-existent) | **INERT** |
| `(subpath ".../sb/link")` where `link → secret` | **INERT — secret readable** |
| `(subpath "//…/secret")`, `(subpath "…/sb//home")` | **INERT** |

The rule is only effective if `location.url.path` is already canonical — exactly the situation the
code has just declared impossible. End-to-end confirmation: probe P2 (protected entry = 45-hop
symlink chain under a broad readWrite folder; `resolve` threw `tooManyLinks`) produced
`allow`/`allowedFolder`, `make()` succeeded, the emitted carve-out was `(subpath "<tmp>/hop0")`, and
`cat <tmp>/targetsecret/data.txt` returned **`SYNTHETIC-TARGET`** (`befaa31^`: `.deny` + `make()`
threw).

**Correction.** Emit deny rules only from a canonical, resolved path (or refuse to launch as
before); lexically normalize (`//`, `.`, `..`); if the configured location traverses a symlink, deny
the resolved target instead of the link name.

### F3 — Appended deny outranks user approval; a protected location can become permanently ungrantable

**Severity: Medium (rule precedence confirmed; scenario plausible, not reproduced end-to-end).**
`SandboxProfile.swift:114–116`.

Seatbelt rule resolution is last-match-wins (verified: `(deny file-write* (require-not (require-any
(subpath A))))` followed by `(deny file-write* (subpath A/secret))` denies `A/secret` while `A/…`
stays writable). Because the carve-out is emitted **after** the allow expressions,
`SandboxGrantStore.admitting` → `.temporaryGrant` → `allowed()` cannot lift it. A user who approves
a protected location that landed in `unverifiableProtected` gets "approved" UI feedback and a kernel
denial. If the location is an ancestor of the project or of a nested allowed folder, legitimate
project access breaks silently. Pre-commit behaviour (launch refused with an actionable message) is
at least diagnosable.

### F4 — `canonicalEntry` abandons canonical spelling when parent enumeration fails; protected classification is lost

**Severity: Medium (confirmed).** `SandboxPathResolver.swift:106–112`
(`(try? contentsOfDirectory(atPath: parent)) ?? []` → `return path` at 111).

Probe P4 (`outer` mode 0111 containing `INNER` mode 0111 containing `deep.txt`; protected configured
as `outer/inner`):

```text
resolve(outer/inner)  -> "<…>/outer/inner"   <-- caller spelling, NOT the volume spelling
resolve(outer/INNER)  -> "<…>/outer/INNER"
resolve(…/deep.txt)   -> "<…>/outer/INNER/deep.txt"   (F_GETPATH, canonical)
policy: outcome=allow rule=allowedFolder    (expected requireProtectedLocationApproval/protectedLocation)
sandbox: read+write of <…>/outer/INNER/deep.txt -> Operation not permitted  (kernel carve-out held:
         Seatbelt matched the case-variant existing path; content unchanged)
```

No data leak here, but the approval flow is wrong: an operation Milk believes needs
Protected-Location approval is auto-approved and then fails at runtime. `befaa31^` threw
`inaccessible` for `outer` entirely (a real usability bug — §4).

At 109–110, `parent + "/" + name` yields **`//name`** when `parent == "/"` (verified string result
`//home`), and `//`-spellings produce inert SBPL rules (F2 table). Not reproducible on this host (no
top-level non-symlink directory refuses `O_EVTONLY`; `/home` is handled by the symlink branch →
`/System/Volumes/Data/home`), so this is a latent defect rather than a live one.

### F5 — Descriptor-pinned verification is replaced by pathname-based `lstat` + `readdir`

**Severity: Low–Medium (design weakening, confirmed by code + OS probes).**
`SandboxPathResolver.swift:87–104`.

`O_EVTONLY|O_NOFOLLOW` + `fstat` + `F_GETPATH` proves the returned path refers to the object
actually opened, in one descriptor-based step. The fallback is two independent pathname syscalls
with a window between them. The struct comment already concedes `revalidated()` is "Not an atomic
execution authorization", so practical exposure is limited (Seatbelt re-resolves at exec time and
**does** canonicalize targets — verified: accessing `sb/secret/data.txt` through `sb/link` was
denied by a deny rule naming the canonical path). Additionally, `open()` failures are no longer
classified, so `ELOOP`/`ENAMETOOLONG`/`EPERM` now resolve just like permission denial: the
"inaccessible" signal is broadly weakened, not only for the documented TCC case.

Minor: `contentsOfDirectory(atPath:)` inside the hot per-component path enumerates whole
directories (unbounded work for large parents). No errno-clobbering hazard found (the
`errno == ENOENT` test in `resolve()` reads `errno` immediately after its own `lstat`).

### F6 — `standardizedFileURL` makes the policy fallback structurally unable to match Milk's own canonical paths

**Severity: Medium (transformation confirmed; end-to-end leak not constructed).**
`SandboxPolicy.swift:40–41`.

`URL(fileURLWithPath: "/private/var/folders/…/open/../sealed").standardizedFileURL.path` →
`"/var/folders/…/sealed"` (observed in probe P5), while resolver-canonical candidate paths are
`"/private/var/folders/…/sealed/…"`. Every TMPDIR-derived root (`temporaryDirectory`,
`writableBuildRoots`, job work dirs) lives under `/private/var/…`. For such locations the literal
comparison can never match — the fallback is silently inert exactly where temp-based grants live. It
is also inconsistent with `SandboxProfileBuilder`, which uses the unstandardized `location.url.path`.

### F7 — Fail-open on TOCTOU detection

**Severity: Medium (code-confirmed).** `SandboxProfile.swift:26` catches
`changedDuringResolution` — a signal that a path was swapped mid-resolution — and converts it into
"treat literally / drop from roots". `SandboxPolicy.swift:18` does the same.
`changedDuringResolution` compares only `(st_dev, st_ino, S_IFMT)`, so a busy directory does **not**
trigger it; triggering requires an actual replacement of the object, which is the strongest possible
reason to refuse the launch, not to weaken protection.

### Protections that remained intact (verified)

- `inactiveProfiles`, `activeProfile`, `folders`, `writableBuildRoots` and `project` still propagate
  `try` → `.deny` on failure (`SandboxPolicy.swift:19–23`). Only protected locations were downgraded.
- The new deny op list (`file-read-data file-read-xattr file-read-metadata file-write*`) **is**
  sufficient when effective: mkdir/touch/rm/mv/chmod/`xattr -l`/`ls`/`stat`/`ln` inside the
  carved-out subtree were all denied.
- Git metadata rules unchanged and still enforced: `(deny file-write* (regex #"(^|/)\.git(/|$)"))`
  blocked `.git` writes, case-variant `.GIT` writes (Seatbelt matched case-insensitively on this
  volume), and writes through a `.git` symlink.
- Normal protected handling unchanged: probe P3 (readable protected dir inside a broad readWrite
  folder) → `requireProtectedLocationApproval`, kernel denied direct **and** `open/../sealed`
  traversal; `SandboxAcceptanceTests` (alias retargeting, `../` traversal, hard-link admission
  refusal, inactive/RO precedence) all pass.
- `SandboxProfileBuilder.quote` unchanged; NUL rejected; JSON-escaped quoting unchanged.

---

## 4. Compatibility and correctness assessment

**The premise is partly real, partly unverified on this host.**

- **Confirmed:** `open(O_EVTONLY)` **does** fail (EACCES) for directories that lack the read bit even
  for the owner (`mode 000` **and** `mode 0111`). Pre-commit, `resolve()` threw, so
  `SandboxPolicy.evaluate` returned `.deny` for **every** path in that context and `make()` refused
  to produce a profile. Probe P4 baseline shows a directory whose *contents* are perfectly reachable
  (`0111`) was previously unresolvable — a genuine fail-closed-but-unusable bug.
- **Not reproducible here:** the comment's examples. The per-user `TemporaryItems` folder opened fine
  (`mode 700`, `F_GETPATH → /private/var/folders/…/T/TemporaryItems`); no top-level directory
  refused `O_EVTONLY`; `/home` refuses only because it is a symlink (already handled). No real
  TCC-protected user directory was touched. The motivating case is plausible on other hosts/OS
  states but unverified here.
- `SandboxSettingsStore.putProtectedLocation` previously **could not add** an unopenable directory to
  Protected Locations (it calls `resolver.resolve(url)`); it can now. That is a genuine UX fix — but
  it can now persist a non-canonical spelling (F4).
- **New silent failure mode:** instead of a launch refusal with an actionable message, the agent now
  launches and hits runtime `Operation not permitted` for paths Milk auto-approved (F3, F4). Tool
  failures become harder to diagnose and approval dialogs no longer match enforcement.
- **No startup impact for the common case:** with readable protected locations,
  `unverifiableProtected` is empty and the emitted profile is byte-identical to the pre-commit
  profile (verified via profile dumps `p1/p3/p4/p5`).
- **Complexity/duplication:** `SandboxProfileBuilder` now constructs a second `SandboxPathResolver`
  (`:20`) while `SandboxPolicy` constructs its own, and the two layers normalize protected paths
  **differently** (`url.path` vs `standardizedFileURL.path`). That divergence is itself a defect
  source (F6).

**Safer design achieving the same compatibility win:** keep descriptor-based verification where
possible — open the **parent** (normally openable) with `O_EVTONLY`, verify it via `fstat` +
`F_GETPATH`, then enumerate that verified parent (or `fstatat` the child) to obtain the child's
spelling; require the enumeration to succeed (throw `.inaccessible` if it fails); fix the
`parent == "/"` slash case; tag such observations as `unpinned` and forbid unpinned observations
from justifying `.allow` for anything not strictly outside a protected root. Keep protected-resolution
failure fail-closed (refuse launch), and derive any deny rule from a canonical path only.

---

## 5. Test coverage

### Executed against the audited checkout (`swift test`, Xcode toolchain)

| Run | Result |
|---|---|
| `--filter SandboxPolicyTests` | **14 tests, 0 failures** (incl. the two new tests) |
| `--filter Sandbox` (AgentLifecycle, SandboxAcceptance, SandboxEnvironment, **SandboxExecution**, SandboxGrant, SandboxHostEffects, SandboxPiIntegration, SandboxPolicy, SandboxPopup, SandboxProviderParity, SandboxPurpose, SandboxSettings) | **86 tests, 0 failures, 1 skipped** (`SandboxHostEffectsTests.testActualWorkerCannotReadMilkNormalKeychainItem` — pre-existing conditional skip). Includes real `sandbox-exec`/Pi-backed execution tests. |
| Not run | full non-Sandbox suite; `scripts/bootstrap-runtime.py` fixture preparation was not performed. |

Commands used:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift test --cache-path "$PWD/.build/cache" --filter "SandboxPolicyTests"
swift test --cache-path "$PWD/.build/cache" --filter "Sandbox"
```

### New tests, scrutinized

- `testUnopenableExistingDirectoryResolvesAndItsDescendantsDoNot` — genuine coverage of the resolver
  fallback; it fails when the resolver change is reverted.
- `testUninspectableProtectedLocationIsFailClosedNotFatal` — **weak**: the asserted `.deny` comes
  from the *candidate* being unresolvable (outer `catch` → `.unresolvedPath`), not from the new
  literal fallback (the protected `blocked` dir resolves via the new fallback, so `entry.2 != nil`).
  The assertion `profile.contains(quoted)` is satisfied by an incidental **nested exclusion** of the
  path inside the `"/"` branch. It passes with the old resolver, with the new profile hunks removed,
  and with the new policy hunks removed.

### Mutation tests (disposable replica; each file reverted individually, then restored)

| Reverted file | `SandboxPolicyTests` result | Meaning |
|---|---|---|
| `SandboxProfile.swift` | 14/14 **pass** | `unverifiableProtected`, the `roots` filter and the appended deny rules have **no coverage** |
| `SandboxPolicy.swift` | 14/14 **pass** | `try?` + literal protected fallback has **no coverage** |
| `SandboxPathResolver.swift` | 1 **failure** (`testUnopenableExistingDirectoryResolves…`) | resolver change is covered by exactly one test |

### Missing cases (none present in the suite)

1. Protected location whose resolution **fails**, combined with a broad overlapping allowed folder —
   policy outcome *and* kernel read of an alias (F1/F2). This is the case the commit is about.
2. Protected file with a pre-existing hard-link alias in a granted area where the protected file
   itself is unresolvable (F1) — mirror of `SandboxAcceptanceTests` for the unverifiable branch.
3. Protected location expressed as a symlink chain/cycle, dangling link, or with `..` / `//` /
   case-variant spellings — assert the emitted carve-out is actually enforceable, not merely present
   as a substring (F2, F4, F6).
4. Protected location under `/private/var/…` (TMPDIR/build-root territory) (F6).
5. Approved protected location (`temporaryGrant` + `admitting`) against an unverifiable location —
   assert the approved access works (F3).
6. Nested allowed folder inside an unverifiable protected parent (F3 breakage direction).
7. A profile-shape assertion that the carve-out is a `deny` rule (not an incidental nested
   exclusion).
8. Deny-rule precedence test (appended deny vs broad allow).

### Non-repo verification executed

All probes used disposable data under `/tmp/milk-audit` and `FileManager.temporaryDirectory` with
synthetic contents. No production agent profile, credential, session, or user file was read or
modified.

- **OS semantics probes (C):** `lstat`/`open(O_EVTONLY|O_NOFOLLOW)`/`F_GETPATH` behaviour for mode
  `000` and `0111` directories, `/home`, the per-user `TemporaryItems` directory, and case-variant
  spellings (volume is case-insensitive; `F_GETPATH` returns the volume spelling).
- **Seatbelt probes (12 `sandbox-exec` profiles):** rule precedence, spelling inertness (`..`, `//`,
  symlink names, non-existent paths), case-variant enforcement, target-side symlink
  canonicalization, carve-out operation coverage, `.git` regex vs `.GIT` and `.git` symlinks.
- **Behavioural probes (7), run twice:** once with the three files at `befaa31`, once reverted to
  `befaa31^`, inside an out-of-repo APFS clone at `/tmp/milk-audit/repo` with an added scratch test
  file. The audited checkout was never used as the probe harness.

---

## 6. Recommendations per modification

| Modification | Recommendation |
|---|---|
| `SandboxPathResolver.inspect` lstat fallback (**84–105**) | **Revise, keep the intent.** It fixes a real fail-closed-but-unusable case. Require the parent enumeration to succeed (throw `.inaccessible` on failure) instead of returning the caller's spelling; base the returned path on the **descriptor-verified parent**; classify `errno` (EACCES/EPERM vs ELOOP/ENAMETOOLONG) rather than treating all failures alike; fix `parent == "/"` → `//name`; mark such observations as unpinned and forbid unpinned evidence from authorizing `.allow`. |
| `canonicalEntry` (**106–112**) | **Revise.** `(try? …) ?? []` swallowing enumeration failure is the fail-open inside the "fix". Treat empty/failed enumeration as an error. |
| `SandboxPolicy` `try?` for protected (**18, 26**) | **Revert.** Protected-location resolution failure must fail closed. All other roots correctly still throw. |
| `SandboxPolicy` literal protected fallback (**36–42**) | **Revert/replace.** Lexical compare against a raw configured path cannot match kernel-canonical candidates (`standardizedFileURL` even rewrites `/private/var`→`/var`). Replace with "unverifiable protected ⇒ deny (or approval-required with an explicit unverified boundary)", never fall through to allow. |
| `SandboxProfileBuilder` catch-all + skip of hard-link guard (**22–29**) | **Revert.** A protected file whose `st_nlink` cannot be verified must be treated as unsafe (refuse admission), exactly as the file's own comment demands. Do not catch `changedDuringResolution` here. |
| `roots` filter dropping unverifiable protected locations (**39**) | **Revert.** Removing the location removes the nested carve-out the broad grant relied on; the substitute deny is provably inert in the failing cases. |
| Appended `(deny … (subpath raw.path))` rules (**114–116**) | **Revise or drop.** Only valid if the path is canonical (normalize `//`, `.`, `..`; resolve symlink components); note it cannot be lifted by user approval (last-match-wins). Otherwise keep the pre-commit behaviour: refuse launch with the existing actionable message. |
| New tests | **Keep one, strengthen one, add the eight missing cases** (§5). Assert on emitted *deny rules*, not substrings, and add a kernel-execution assertion for the protected-alias case. |
| Chat/`AgentService`/`AgentTranscript` hunks in the same commit | Out of scope; no sandbox effect observed. Not modified. |

---

## 7. Final recommendation

**Do not retain `befaa31`'s Sandbox changes as-is.**

- **Confirmed vulnerabilities:** protected content becomes readable by a sandboxed child without
  approval when the protected location's resolution fails (F1, hard-link alias) or when the
  protected entry is expressed through a symlink/cycle (F2). Both were reproduced end-to-end
  (`policy allow` → `make()` succeeds → `cat` returns the protected bytes) and both were fail-closed
  on `befaa31^`.
- **Plausible risks, mechanism verified but not fully reproduced:** approval becoming ungrantable
  (F3), `/private/*` protected locations where the fallback is structurally inert (F6), TOCTOU
  tolerance (F7), `//`-spellings from a top-level fallback (F4 tail).
- **Cannot be verified here:** the real-world trigger rate of TCC-protected / `TemporaryItems`
  `O_EVTONLY` refusals (not reproducible on this host); behaviour on a case-sensitive volume; real
  Pi launch sessions against production profiles; purpose-profile (`SandboxPurposePlan`)
  instantiation of these rules; performance impact of `contentsOfDirectory` in `resolve()`.
- **Test evidence is not sufficient to accept the change:** 14/14 policy tests and 86 Sandbox tests
  pass with the policy hunks removed, with the profile hunks removed, and with the resolver hunks
  reverted except for one test. Passing tests do not certify these changes.

**Minimal safe path:** keep (revised) resolver fallback + revert the `SandboxPolicy.swift` and
`SandboxProfile.swift` hunks, then add the missing tests in §5.

---

## Appendix A — Key code as committed

`SandboxPathResolver.swift:84–112`

```swift
private func inspect(_ path: String) throws -> SandboxPathObservation {
    let fd = open(path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
    if fd >= 0 {
        defer { close(fd) }
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw SandboxPathError.inaccessible }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard buffer.withUnsafeMutableBufferPointer({ fcntl(fd, F_GETPATH, $0.baseAddress!) }) == 0 else { throw SandboxPathError.inaccessible }
        return .init(path: String(cString: buffer), identity: SandboxFileIdentity(value))
    }
    var value = stat()
    guard lstat(path, &value) == 0 else { throw SandboxPathError.inaccessible }
    return .init(path: canonicalEntry(path), identity: SandboxFileIdentity(value))
}
private func canonicalEntry(_ path: String) -> String {
    let parent = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []
    if entries.contains(name) { return parent + "/" + name }
    if let folded = entries.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return parent + "/" + folded }
    return path
}
```

`SandboxPolicy.swift:18`, `:26`, `:36–42`

```swift
let protected: [(String, URL, SandboxResolvedPath?)] = context.configuration.protectedLocations.map { ($0.id, $0.url, try? resolver.resolve($0.url)) }
let snapshots = [path, project] + protected.compactMap { $0.2 } + inactive.map(\.1) + folders.map(\.1) + builds + (active.map { [$0.1] } ?? [])
let matchingProtected = protected.filter { entry in
    if let resolved = entry.2 { return resolved.contains(path) }
    let literal = entry.1.standardizedFileURL.path
    return path.canonicalURL.path == literal || path.canonicalURL.path.hasPrefix(literal + "/")
}
```

`SandboxProfile.swift:20–29`, `:39`, `:114–116`

```swift
let locationResolver = SandboxPathResolver()
var unverifiableProtected: [String] = []
for location in context.configuration.protectedLocations {
    let path: SandboxResolvedPath
    do { path = try locationResolver.resolve(location.url) }
    catch let error where error is SandboxPathError { unverifiableProtected.append(location.url.path); continue }
    guard path.finalIdentity?.kind == S_IFREG else { continue }
    var info=stat()
    guard lstat(path.canonicalURL.path,&info) == 0, SandboxFileIdentity(info) == path.finalIdentity else { throw SandboxPathError.changedDuringResolution }
    guard info.st_nlink == 1 else { throw AgentError.message("Sandbox cannot safely isolate a Protected file with multiple hard links. …") }
}
roots += context.configuration.protectedLocations.filter { !unverifiableProtected.contains($0.url.path) }.map { Root(url: $0.url) }
for path in Set(unverifiableProtected).sorted() {
    sbpl += "(deny file-read-data file-read-xattr file-read-metadata file-write* (subpath \(try Self.quote(path))))\n"
}
```

## Appendix B — Representative generated rules

Unverifiable protected location (probe P1) — a single carve-out, no nested exclusion:

```text
(deny file-read-data file-read-xattr (require-not (…allow expression…)))
(deny file-read-metadata (require-not (require-any …metadata ancestors…)))
(deny file-write* (require-not (…allow expression…)))
(deny file-write* (regex #"(^|/)\.git(/|$)"))
(deny file-read-data file-read-xattr file-read-metadata file-write* (subpath "<tmp>/sealed/secret.txt"))
```

Resolvable protected location inside a broad readWrite folder (probe P3/P4/P5) — unchanged
nested-exclusion form:

```text
(require-all (subpath "<granted root>") (require-not (require-any (subpath "<project>") (subpath "<protected>"))))
```
