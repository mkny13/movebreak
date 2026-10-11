# MoveBreak architecture

This document is the canonical description of MoveBreak's shipped implementation. It
describes the current code, including the Groundwork-generated HUD and durable completion
path. See [ROADMAP.md](ROADMAP.md)
for future work and [README.md](README.md) for user setup, operation, and troubleshooting.

## Runtime boundary and entry points

MoveBreak is a single, menu-bar-only macOS process. It uses AppKit for application and
window lifecycle, SwiftUI for panel content, CoreAudio for process stream state, and
Foundation/Security for persistence, networking, subprocesses, and Keychain access. It has
no service process, database, Xcode project, Swift package, or third-party dependency.

The executable first rejects command-line secrets. Help, version, self-test, browser-tab
probe, live diagnostics, interactive Groundwork setup, one-shot update check, and same-user
remote-control flags terminate without entering the long-running app. Demo and status-check
flags instead modify an app launch. Normal launch creates `AppDelegate`, selects accessory
activation policy (no Dock icon), and enters the AppKit run loop.

`AppDelegate` is the composition root. It owns the detector, routine store and provider, three panel
controllers, status item, timer, and polling scheduler; wires prompt completion into the
shared session logger; registers the remote-control listener; and supplies the updater's
idle predicate. At launch it reconciles structured local history into the Groundwork outbox
and begins eligible delivery before checking CoreAudio support. Unsupported systems keep the status item and remote-control listener but
do not start polling or updates. The three demo modes also return before polling and updates.

## Observation-to-completion data flow

1. A main-run-loop timer requests a poll at the configured interval. `SerialPollScheduler`
   admits only one poll at a time and drops ticks while one is in flight.
2. On its private utility queue, the detector reads CoreAudio's per-process input/output
   stream flags first. It resolves PID and bundle identity only for objects with a live
   stream. Missing bundle IDs use a fallback identity cache keyed by CoreAudio object and
   PID; entries expire after 10 seconds and are removed when the object disappears, bounding
   reuse while preventing a recycled PID from silently inheriting stale identity.
3. Classification applies the three stages below. Browser AppleScript runs only when a
   supported browser owns a live output stream; recent tab results have a short cache.
4. The same serial scheduler accepts the observation into the debounced session lifecycle.
   A generation token discards work begun before pause, resume, or shutdown.
5. When one prompt is due for the open session, the callback crosses to the main queue and
   presents loading state while the provider requests one configured-duration Groundwork
   routine. Manual menu and remote `--show` requests use the same path; no request occurs in
   audio polling or at startup. Cancellation plus presentation generations discard results
   after close, timeout, replacement, or routine start.
6. A live or cached generated response becomes one numbered offer. Empty, auth, malformed,
   unavailable, unconfigured, and local-fallback states are labeled distinctly; saved local
   routines remain selectable fallback content. Generated items preserve server order, while
   local starts still partition-shuffle walk-safe work before pause-belt work.
7. The checklist displays authored dose/cues, inclusion reasons, treadmill safety, and warning
   message/rationale/source. A checked generated item explicitly confirms its displayed dose;
   editable deviation fields retain only entered observations, and warnings affecting checked
   work require a reason. Pressing Done emits one structured per-run completion with stable UUID,
   timestamps, snapshot, canonical checked IDs, actual dose, and warning overrides. The session
   logger durably appends the complete snapshot and destination origin to local JSONL, then
   atomically adds it to a separate versioned Groundwork outbox. Done closes the HUD only after
   both writes succeed; a disk error stays visible and retryable in the checklist. Delivery is
   asynchronous and never runs from the detector polling path.

## Detection and classification

CoreAudio's macOS 14.4 process-object API is the observation boundary. MoveBreak reads
whether a process has a running input or output stream; it does not capture audio. All
stages first exclude configured ignored applications, including their helpers:

1. A configured meeting application with live input is `meeting`.
2. A configured native player with live output is `video`.
3. A configured browser with live output is inspected through AppleScript. An active call
   tab outranks other content. Otherwise the active tab is trusted first, with music checked
   before video because music URL patterns can be more specific. If it is inconclusive, the
   active tab from each browser window is accepted only for an unambiguous call or one video
   with no music conflict.

Unknown or ambiguous browser audio is deliberately classified as idle. URL matching enforces
host boundaries and compares normalized host-plus-path values. Browser targets are limited to
five built-in AppleScript dialects even if preferences contain other bundle IDs. Diagnostics
sanitize URLs to host-level output unless verbose mode is explicitly selected; verbose output
is therefore an explicit browsing-data disclosure.

`SessionLifecycle` debounces state changes, preserves one logical session across short idle
gaps and meeting-to-video transitions, prompts at most once per session, and applies separate
decline and timeout cooldowns. After continuous idle exceeds the configured grace period,
the next active observation opens a new session.

## Concurrency and UI boundary

AppKit creation and mutation belong on the main thread. `FloatingPanel` asserts that its
initializer runs there, and detector callbacks use `onMain` before touching panel or status
UI. The polling scheduler owns slow CoreAudio/AppleScript inspection and serializes all
detector lifecycle mutations on one utility queue; accepted results return to the main queue.
Provider URLSession callbacks and cache resolution return through `onMain`; prompt presentation
IDs and provider generations suppress stale UI mutations. Prompt decline, timeout, and
routine-start mutations are sent to the detection queue. The session logger serializes history
writes, while the outbox serializes atomic state changes and one in-flight Groundwork request;
URLSession completions dispatch back to the outbox queue. Updater network callbacks return to the main queue,
while archive download and verification run on a utility queue. Download completion has one
locked terminal outcome; a timeout cancels and drains the URLSession callback before staging
cleanup, so late or repeated callbacks cannot write the archive. Installation is gated on the
app being unpaused and idle with no MoveBreak panel visible.

The shared panel is non-activating, floating, and full-screen auxiliary. Prompt and checklist
windows therefore appear without proactively stealing focus and can join full-screen spaces.
The deliberately opened routine editor uses centered placement.

## Routine and catalog ownership

The bundled exercise catalog is the current source of exercise names, areas, dose text,
cues, posture, and treadmill-safety tags. The local routine store owns user-created routine
names and ordered catalog IDs, JSON-encoded in `UserDefaults`. On first launch it seeds three
editable routines. An intentionally saved empty routine list remains empty; absent or
undecodable saved data restores the three seeds. Empty individual routines remain editable
but are omitted from the prompt and menu, and missing catalog IDs are skipped during
resolution.

Resolved local routines copy catalog exercises into the display model. Each local launch shuffles
walk-safe and pause-belt partitions independently while keeping the safe partition first.
The local checklist groups exercises by the order in which each area first appears and preserves
relative order within an area; this grouping can move later exercises next to earlier ones in
the same area. Generated routines bypass both shuffle and area grouping so canonical item order
survives display and completion. Unknown treadmill safety is treated conservatively as pause-belt.
The static catalog, local routine editor, and saved routines are live product behavior, not
dead abstractions; their role during Groundwork migration is defined in the roadmap.

## Configuration, credentials, and persistence

`Preferences` reads and normalizes detection lists, URL patterns, timing values, and non-secret
Groundwork settings from the app's `com.mike.movebreak` `UserDefaults` domain. Invalid or
empty normalized overrides fall back to built-in values; numeric settings are bounded, and
the browser list cannot expand beyond implementations with a known AppleScript dialect.
`RoutineStore` uses the same defaults domain under its JSON-encoded `savedRoutines` key.

Groundwork setup is available through `--configure-groundwork`, and prompt/manual invocations
use it to request generated routines. Setup accepts HTTPS deployment roots (or explicit loopback HTTP for
development), an existing location ID, and a 1–30 minute default. It commits non-secret values
to preferences only after writing the token to the separate
`com.mike.MoveBreak.groundwork` Keychain service, under an account derived from the exact
scheme/host/port origin. A newly selected origin therefore cannot retrieve another origin's
token. Tokens enter through echo-disabled terminal input, remain in device-only Keychain storage
and private client memory, and are attached only as an Authorization header. Setup never
reflects backend error text. No environment, process argument, or UserDefaults token path exists.
Base URLs reject user information, encoded or non-root paths, queries, fragments, encoded
hosts, and invalid ports. HTTP is limited to exact localhost, 127.0.0.1, or IPv6 loopback;
the client uses the validated canonical root.

The Groundwork client has injectable asynchronous transport, a bounded request timeout,
cancellation, typed authentication/retryable/permanent failures, strict version-1 model
validation, and GET/POST request construction. Its URLSession redirect delegate allows only
same-origin redirects and rejects cross-origin or HTTPS-to-HTTP redirects before credentials
can be forwarded. Both origins must validate and match scheme, lowercase host, and effective
port; redirect user information and fragments fail closed. Endpoint origins are checked before
authorization. The ephemeral session disables cookie storage, automatic cookies, URL caches,
and ambient credential storage. Request and total resource timeouts are capped at 30 seconds,
including non-finite timeout inputs, and cancellation reaches the underlying task. Response
bodies and arbitrary transport errors are never reflected into typed failures or diagnostics.
Offline tests use fake Keychain and transport backends, sentinel secrets, and the production
session configuration without accessing live credentials or Groundwork. Successful nonempty routines can be atomically cached under
`~/Library/Application Support/MoveBreak/GroundworkRoutineCache/`, keyed by schema, origin,
location, and duration. Offline cache labels include their timestamp and explicitly say they
were not revalidated; corrupt, absent, auth-failed, malformed, unavailable, live-empty, and
unconfigured states remain distinct. Live empty results are never replaced by cached or
bundled content. No routine refresh occurs at startup or from the audio polling loop.

Local session data lives under `~/Library/Application Support/MoveBreak/`. The directory is
created or tightened to mode `0700`; live history, outbox (including receipts), and cache
files are tightened to `0600` before access. `PrivateFileStore` walks directories using
`openat` with `O_NOFOLLOW`, pins the containing directory descriptor, verifies current-user
ownership and regular single-link files, removes extended ACLs, and checks all permission
changes. Only the fixed macOS `/var` and `/tmp` aliases are expanded to `/private`; other
symlink ancestors, symlink targets, hard-linked files, and special files fail closed.
Cache access also protects its MoveBreak parent. Unrelated legacy artifacts are not scanned.
Atomic updates use exclusive `0600` staging files in the pinned directory, synchronize before
`renameat`, then synchronize the directory. Failed staging/rename operations remove only the
temporary file; malformed outbox/cache originals are preserved. A post-rename sync failure
reports failure even though the replacement may already be visible. Reads and writes surface
boundary failures through throwing APIs, cache corrupt states/save diagnostics, and completion
callbacks. This protects against other users and path indirection, not malicious code already
running as the same user (which can alter owned directories or permissions).
`sessions.jsonl` is append-only local history and is synchronized before acknowledgement or
network work. New records embed the structured completion, stable client UUID, and destination
origin; missing optional fields keep old JSONL lines readable and prevent historical upload.
`groundwork-outbox-v1.json` is replaced atomically and contains origin-bound work plus a durable
receipt ledger. Launch reconciliation repairs a crash between history and outbox writes without
reinterpreting or touching the legacy `pending-sync.json` Notion queue. A validated matching
receipt removes work and records its UUID; a lost response safely retries the same UUID.

Network/429/5xx failures use bounded exponential backoff with jitter and honor `Retry-After`.
Authentication pauses until explicit retry after reconfiguration; permanent 400/409 and malformed
responses remain visible without a tight loop. The menu reports pending/failed counts and provides
explicit retry. Unconfigured records bind only on that explicit action; records already bound to
another origin are never reassigned. Legacy Notion files, preferences, and Keychain items are left
on disk but no active code reads, writes, or uploads them.

## Automatic-update trust boundary

For a certificate-signed normal launch, the updater checks the latest GitHub release for
`mkny13/movebreak` immediately and every 24 hours. Ad-hoc builds and builds without a leaf
signing certificate do not start automatic checking or installation; the one-shot CLI check
applies the same gate. Before staging a candidate it requires all of the following:

- a newer, well-formed release tag and exactly named `MoveBreak.app.zip` asset;
- an HTTPS GitHub release URL for the expected repository, tag, and asset;
- a release-provided SHA-256 digest matching the downloaded archive;
- extraction inside a canonical, mode-`0700`, random application-support staging directory,
  with the regular archive path, extracted tree, bundle, and all symlinks contained there;
- matching bundle identifier, executable shape, and release/bundle version;
- strict code-signature verification and the same leaf signing certificate as the running
  app.

The production subprocess surface is a closed command set containing only `/usr/bin/ditto`,
`/usr/bin/codesign`, and `/usr/bin/xattr`. Each command uses a fixed absolute executable, an
explicit argument array with option parsing terminated before paths, and an empty environment;
no shell or PATH lookup evaluates downloaded input. Quarantine is removed without following
symlinks and only after all checks pass. The updater removes abandoned staging directories at
the next staging attempt.
Replacement targets the running bundle's actual location and relaunches only when detection
is unpaused and idle and no prompt, routine, or editor panel is visible. A validation failure
leaves the installed bundle untouched. A reported replacement failure does not relaunch and
is retried from the staged candidate at a later safe moment.

Subprocess stdout and stderr use synchronously owned, nonblocking pipes and retain at most 1 MiB
per stream while continuing to drain excess output. The runner waits with
`poll(2)` for pipe readiness or the next timeout, SIGTERM, or SIGKILL deadline, alternating the
first stream drained on each wake to avoid starvation. A short maximum wait also rechecks direct
child exit when a descendant incorrectly inherits a pipe writer. Cleanup performs a final
nonblocking drain and sends a final SIGKILL if the direct child remains live, so inherited writers
cannot turn process completion into an unbounded EOF wait and no asynchronous pipe callback can
outlive the returned result.

## Security-surface review gate

`scripts/check_security_surface.sh` is an offline, standard-library-only Python 3 gate
invoked through Bash before any other build helper or compilation, so changed helper
hashes are rejected before those scripts can execute. The build runs its `--self-test`
fixtures as well.
It checks the working tree, including ignored/untracked inputs, excluding only `.git` and
the generated root `build/` and `MoveBreak.app/` trees. Symlinks, unexpected Swift inputs,
package manifests/lockfiles, environment files, vendored roots, and additional executable
scripts/libraries fail closed. The architecture module inventory remains the ownership
source of truth; the compiler receives a NUL-delimited Git-tracked array, never a shell glob.

The approved runtime imports are Apple's AppKit, SwiftUI, Foundation, CoreAudio, Security,
CryptoKit, and Darwin. Build/release tooling consists of macOS/CommandLineTools Bash,
Python 3 (standard library), Git, swiftc, xcrun, and the fixed system utilities present in
the reviewed scripts/workflow (including codesign, plutil, security, ditto, and xcode-select).
Runtime updater subprocesses remain the fixed `/usr/bin/ditto`, `/usr/bin/codesign`, and
`/usr/bin/xattr` invocations described above; browser inspection uses reviewed AppleScript.
No package manager, downloaded installer, third-party runtime, or environment-file loader
is approved.

`APPROVED` stores SHA-256 digests of the complete scripts and workflows, so new commands,
indirect download/execute sequences, alternate workflows, permission changes, or secret
references cannot slip through a partial shell/YAML parser. The workflows' reviewed Actions
are full commit SHA pins with human-readable version comments. Verification in
`.github/workflows/build.yml` is read-only and secret-free. Only the tag-gated release job in
`.github/workflows/release.yml` has `contents: write`; strict numeric tag validation and a
security check precede the step-scoped signing secrets. The certificate and password are
unset before building, and the ephemeral keychain is cleaned up on exit.
`.github/dependabot.yml` is also a reviewed workflow-adjacent surface: it requests weekly
GitHub Actions updates from `/`, groups minor and patch updates, and leaves major updates
ungrouped; no runtime package-manager ecosystem is configured.
`FRAMEWORKS` and `SWIFT_PRIMITIVES` separately constrain runtime imports and reviewed
process/AppleScript primitive lines, including their ordering and multiplicity.

For an intentional surface change, review the entire changed script/workflow and any new
Action commit, confirm tag validation precedes secret access and verification stays read-only,
and document the new dependency/tool or trust boundary here in the same change. Then edit
the gate's explicit allowlists: compute file digests with `shasum -a 256 PATH`, update only
the reviewed entries in `APPROVED`, and update runtime import/primitive entries if needed.
New dependency types also require a deliberate policy change to the rejection rules. There
is no automatic baseline regeneration or bypass switch. Run the gate, `--self-test`, and
the complete build before committing. Even cosmetic script/workflow edits require a digest
update; this conservative tradeoff keeps the small executable configuration reviewable.
The gate is a drift detector, not a proof against malicious Swift obfuscation or a reviewer
who approves an unsafe allowlist change. Its own implementation and allowlist require code
review like the build entrypoint itself.

GitHub branch protection on the default branch `main` requires the `verify` status check
from `.github/workflows/build.yml`; squash merging is enabled. Required pull request
reviews are unset (`null`), and no signature, deployment, or pull-request ruleset requirements
are configured, preserving Mahler's automated conductor merges (D18). Status checks do not
require the branch to be up to date (`strict: false`), administrator enforcement is disabled,
and push restrictions are unset. Force pushes and branch deletion remain disallowed.
This is a test gate, not mandatory human approval or protection against administrator bypass.
These settings live in GitHub, not in the checkout. The practices audit currently reports
branch protection as `unknown` and cannot establish this live configuration; the documented
settings are instead verified by read-only live GitHub API checks and a passing
`./scripts/build_app.sh`. Passing `verify` does not publish a release or grant signing-secret access:
release packaging and publication remain confined to the tag-gated release job described above.

### Security audit #72 verification

Verified on 2026-10-11 UTC (2026-10-10 America/New_York) for [#103](https://github.com/mkny13/movebreak/issues/103),
against source revision `599e9fc74dfdde12572ae515e4191dda86eb44fd` plus this report-only
change. Host: macOS 26.6.2 (25G83), Apple Swift 6.4 (`swiftlang-6.4.0.34.1`,
`clang-2100.3.34.1`), arm64; build target remains macOS 14.4.
The six rows below correspond to the completion criteria in [#72](https://github.com/mkny13/movebreak/issues/72).

| Criterion | Source and verification evidence | Result / scope |
|---|---|---|
| Child merge provenance | #73 → [PR #79](https://github.com/mkny13/movebreak/pull/79), `66a43de9fc7b6f6d6d5cdd292b5506f0a85702fd`; #74 → [PR #82](https://github.com/mkny13/movebreak/pull/82), `28daa2459b8f3a6de62013d82b02d7183ade07a5`; #75 → [PR #77](https://github.com/mkny13/movebreak/pull/77), `7cc761ab6d789cf2ab12c711c9f66aeb3164d5cc`; #76 → [PR #78](https://github.com/mkny13/movebreak/pull/78), `d50abcb20e013147fb8ca3173b03d464ba673cff`. | `git merge-base --is-ancestor <merge-sha> 599e9fc74dfdde12572ae515e4191dda86eb44fd` exited 0 for each of the four commits. This verifies inclusion, not merely issue closure. |
| Credentials | [GroundworkSetup.swift](Sources/MoveBreak/GroundworkSetup.swift) `execute` / `validateBaseURL`, [GroundworkClient.swift](Sources/MoveBreak/GroundworkClient.swift) `configured`, `authorizedRequest`, `GroundworkOrigin` and `GroundworkURLSessionTransport.redirectedRequest`, and [Keychain.swift](Sources/MoveBreak/Keychain.swift). [GroundworkSelfTests.swift](Sources/MoveBreak/GroundworkSelfTests.swift) `runBoundaryCases`, `runSetupCases` and request cases check HTTPS-or-explicit-loopback URLs, exact-origin Keychain isolation and Authorization headers, cross-origin/port and downgrade rejection, disabled ambient credentials/cookies/cache, and sentinel-free response/transport/setup errors and preferences. [SecuritySelfTests.swift](Sources/MoveBreak/SecuritySelfTests.swift) `runSecretRedactionCases` checks typed Keychain error redaction and terminal echo suppression. | Offline fake Keychain, injected transport and isolated preferences exercise the credential boundary; no production credential or live service is read. |
| Private storage | [PrivateFileStore.swift](Sources/MoveBreak/PrivateFileStore.swift) `protect`, `openFile`, `append`, `replace` back [SessionLogger.swift](Sources/MoveBreak/SessionLogger.swift), [GroundworkOutbox.swift](Sources/MoveBreak/GroundworkOutbox.swift) and [GroundworkRoutineCache.swift](Sources/MoveBreak/GroundworkRoutineCache.swift). [PersistenceSelfTests.swift](Sources/MoveBreak/PersistenceSelfTests.swift) `runPermissionCases`, `runDurabilityAndRecoveryCases`, `runFileBoundaryCases` check 0700 directories, 0600 history/outbox/receipt data, existing-mode tightening, symlink/hard-link/FIFO/directory rejection, ancestor indirection, and original-byte preservation on partial-write, rename and permission failures. [GroundworkSelfTests.swift](Sources/MoveBreak/GroundworkSelfTests.swift) `runCacheCases` checks private cache modes, corrupt-file preservation and symlink rejection without changing the destination. | Disposable filesystem fixtures exercise the shared file primitive and its consumers; no personal history, receipts or cache is accessed. |
| Updater execution | [ProcessRunner.swift](Sources/MoveBreak/ProcessRunner.swift) `UpdateToolCommand.invocation` fixes `/usr/bin/ditto`, `/usr/bin/codesign`, `/usr/bin/xattr`, structured arguments with `--` before paths, and empty environments; `ProcessRunner` assigns these directly to Foundation Process. [Updater.swift](Sources/MoveBreak/Updater.swift) orders archive/digest, extraction/tree, metadata, signature and signer checks before quarantine removal/replacement, using [UpdateSecurity.swift](Sources/MoveBreak/UpdateSecurity.swift) and [UpdateValidation.swift](Sources/MoveBreak/UpdateValidation.swift). [UpdateSelfTests.swift](Sources/MoveBreak/UpdateSelfTests.swift) `runUpdateTrustCases` checks hostile path strings remain arguments, fixed tools/environment, symlinked archives, escaped trees, digest/metadata/signer mismatch and strict-signature timeout rejection; `runProcessRunnerCases` exercises bounded output, timeout and pipe cleanup. | Command-construction assertions and offline trust fixtures cover fail-closed decisions; these are not a live signed-release installation. Existing updater timing assertions are unchanged. |
| Pre-compilation drift gating | [check_security_surface.sh](scripts/check_security_surface.sh) `fixtures` rejects mutable Action references, write permissions, verification secrets, release-validation changes, tracked/ignored manifests, vendor roots, untracked Swift, download-to-shell, runtime dependencies and new process primitives. Full-file `APPROVED` hashes cover release-secret scope as well as workflow changes. [build_app.sh](scripts/build_app.sh) invokes the gate and negative fixtures before helpers and compilation, then compiles the NUL-delimited tracked source inventory. [build.yml](.github/workflows/build.yml) stays read-only with explicit self-test; [release.yml](.github/workflows/release.yml) validates tags and gates before step-scoped signing secrets, unsets them before build, and cleans the temporary keychain. | Standalone gate passed all 20 emitted checks, including explicit-self-test ordering/failure-propagation fixtures. This is offline drift detection, not execution of the credentialed release workflow or proof against unsafe reviewed allowlist changes. |
| Combined verification | Commands and measured results below exercise all five suites, documentation gates and the ad-hoc packaged build together. | Results recorded below; production service, GUI and release deployment remain outside this offline audit. |

Verification commands (run from the repository root, with no health environment overrides
or explicit maximum-seconds override):

```bash
./scripts/check_security_surface.sh --self-test
./scripts/build_app.sh
./build/MoveBreak --self-test
./scripts/test_health.sh --runs 5 --timeout 120 --max-slowdown 3 --grace-seconds 5
```

All four commands exited 0 on their first attempt; no failed attempts or relaxed limits.
The security gate reported 20 passing checks. The packaged build passed security fixtures,
canonical agent context, tracked architecture inventory, documentation links/public CLI
coverage and its self-test, then assembled and ad-hoc signed `MoveBreak.app`.
`codesign --verify --strict MoveBreak.app` also succeeded; `codesign -dv MoveBreak.app`
reported `Signature=adhoc` and `Identifier=com.mike.movebreak`.

The separate self-test reported **5 suites, 447 cases, 0 failures in 5.985s**:
detection 80 (0.011s), security 110 (0.701s), persistence 52 (1.180s),
update 102 (4.058s), groundwork 103 (0.033s), each with zero failures.
The health command passed **5/5 runs**, preserving that exact suite/case inventory with
zero failures and no unexpected stderr/runtime diagnostics. Run durations were 6.019s,
6.223s, 5.797s, 6.084s and 6.006s. Its derived limit was 23.057s
(3 × 6.019s baseline + 5s grace), with the unchanged 120s watchdog;
slowest suite was update in run 1 (4.296s), slowest complete run was run 2 (6.223s).

No manual checks remain for this bounded offline verification. Live Groundwork behavior,
production Keychain access, GUI interaction, certificate-signed release installation and
post-merge evidence were not exercised or claimed; the conductor owns shipping and
post-merge tracking. The evidence change does not alter runtime code, tests or limits.

## Build and test structure

`scripts/build_app.sh` compiles the tracked, documented Swift inventory directly with `swiftc`, targeting arm64
macOS 14.4 and linking only system frameworks. It runs the CLI self-test before assembling
and ad-hoc signing the application bundle. The self-test coordinator checks its suite
manifest and runs focused detection, persistence, credential/security, and updater suites
without requiring browser automation or network access. Each reporter records its case count;
the coordinator emits stable per-suite inventory and elapsed-time summaries plus a complete-run
total while retaining zero/nonzero process exit semantics.

The normal build gate deliberately performs one self-test run; the CI `verify` job adds a
separate explicit `./build/MoveBreak --self-test` step after the build so test execution is
reported independently (the security-surface fixtures assert that step exists).
Locally, the build gate still performs one run. The opt-in
`scripts/test_health.sh` uses that already-built executable for repeated full-suite runs and
compares their suite/case inventory to the first run. It rejects nonzero exits, unexpected
stderr or runtime warnings, missing summaries, inventory drift, watchdog timeouts, and coarse
duration regressions. Its default duration bound derives from the first-run baseline with a
generous multiplier and fixed grace period; callers can override the repeat count, timeout,
relative bound, or an explicit ceiling for slower automation hosts. The runner remains entirely
offline and reports the slowest suite and complete run.

## Module inventory

<!-- architecture-module-inventory:start -->

Each tracked Swift source appears exactly once below.

### Startup and orchestration

| Module | Responsibility |
|---|---|
| [`main.swift`](Sources/MoveBreak/main.swift) | Validates arguments, routes CLI modes and remote commands, then starts the accessory AppKit app. |
| [`AppDelegate.swift`](Sources/MoveBreak/AppDelegate.swift) | Composition root for serialized polling, menu/status UI, panel/logger callbacks, remote control, and updater idle gating. |
| [`RemoteControl.swift`](Sources/MoveBreak/RemoteControl.swift) | Same-user distributed-notification commands for show, pause/resume, and quit. |
| [`MainThread.swift`](Sources/MoveBreak/MainThread.swift) | Main-queue handoff helper for AppKit-bound callbacks. |

### Detection and diagnostics

| Module | Responsibility |
|---|---|
| [`AudioActivityMonitor.swift`](Sources/MoveBreak/AudioActivityMonitor.swift) | Reads CoreAudio process objects and live input/output flags. |
| [`RunningAppLookup.swift`](Sources/MoveBreak/RunningAppLookup.swift) | Caches PID-to-bundle-ID fallback lookup through `NSWorkspace`. |
| [`BundleIdentity.swift`](Sources/MoveBreak/BundleIdentity.swift) | Resolves known helper bundle IDs and prefixes to owning applications. |
| [`BrowserTabInspector.swift`](Sources/MoveBreak/BrowserTabInspector.swift) | Queries supported browsers, caches results, and classifies call/video/music URLs. |
| [`SessionDetector.swift`](Sources/MoveBreak/SessionDetector.swift) | Applies three-stage classification plus debounce, cooldown, and session lifecycle policy. |
| [`Diagnose.swift`](Sources/MoveBreak/Diagnose.swift) | Runs the live audio/tab/classification diagnostic table. |
| [`TabProbe.swift`](Sources/MoveBreak/TabProbe.swift) | Runs one-shot inspection of supported running browsers. |
| [`URLDisplay.swift`](Sources/MoveBreak/URLDisplay.swift) | Sanitizes diagnostic URLs to privacy-preserving display strings. |
| [`Preferences.swift`](Sources/MoveBreak/Preferences.swift) | Owns validated detection/timing overrides plus non-secret Groundwork preferences. |

### Routine domain and UI

| Module | Responsibility |
|---|---|
| [`ExerciseCatalog.swift`](Sources/MoveBreak/ExerciseCatalog.swift) | Defines exercise, posture, and treadmill models and the bundled static catalog. |
| [`Routines.swift`](Sources/MoveBreak/Routines.swift) | Defines resolved routines, session shuffling, and the user-facing disclaimer. |
| [`RoutineCompletion.swift`](Sources/MoveBreak/RoutineCompletion.swift) | Builds idempotent structured per-run completions with explicit actual dose and warning reasons. |
| [`RoutineStore.swift`](Sources/MoveBreak/RoutineStore.swift) | Persists editable saved routines, seeds defaults, and resolves catalog IDs. |
| [`FloatingPanel.swift`](Sources/MoveBreak/FloatingPanel.swift) | Defines the non-activating AppKit host panel and full-screen placement behavior. |
| [`PromptPanel.swift`](Sources/MoveBreak/PromptPanel.swift) | Presents loading/error/offline/empty states, numbered choices, and generation-safe dismissal. |
| [`RoutineWindow.swift`](Sources/MoveBreak/RoutineWindow.swift) | Presents ordered clinical context, warning reasons, and actual-dose capture in the checklist. |
| [`RoutineBuilderWindow.swift`](Sources/MoveBreak/RoutineBuilderWindow.swift) | Presents local routine create/rename/delete and catalog selection UI. |

### Completion persistence and Groundwork

| Module | Responsibility |
|---|---|
| [`SessionRecord.swift`](Sources/MoveBreak/SessionRecord.swift) | Backward-compatible local summary plus optional structured completion and destination. |
| [`PrivateFileStore.swift`](Sources/MoveBreak/PrivateFileStore.swift) | Descriptor-relative owner-only file reads, durable appends, and atomic replacements. |
| [`SessionLogger.swift`](Sources/MoveBreak/SessionLogger.swift) | Serial durable JSONL writes and launch reconciliation into the outbox. |
| [`GroundworkOutbox.swift`](Sources/MoveBreak/GroundworkOutbox.swift) | Owns atomic origin-bound queue state, receipts, failure classification, backoff, and retry status. |
| [`Keychain.swift`](Sources/MoveBreak/Keychain.swift) | Wraps device-local Keychain storage behind typed errors and a testable backend. |
| [`SecretInput.swift`](Sources/MoveBreak/SecretInput.swift) | Reads terminal secrets with echo disabled and signal-safe restoration. |

### Groundwork transport infrastructure

| Module | Responsibility |
|---|---|
| [`GroundworkModels.swift`](Sources/MoveBreak/GroundworkModels.swift) | Defines and validates versioned routine, dose, warning, provenance, completion, and receipt wire models. |
| [`GroundworkClient.swift`](Sources/MoveBreak/GroundworkClient.swift) | Builds authenticated GET/POST requests, maps typed failures, supports cancellation, and enforces redirect-origin policy. |
| [`GroundworkRoutineCache.swift`](Sources/MoveBreak/GroundworkRoutineCache.swift) | Atomically stores validated nonempty routines and resolves explicit live, empty, offline, corrupt, and fallback states. |
| [`GroundworkRoutineProvider.swift`](Sources/MoveBreak/GroundworkRoutineProvider.swift) | Fetches on prompt/manual invocation and maps cancellable live/cache/local availability into HUD offers. |
| [`GroundworkSetup.swift`](Sources/MoveBreak/GroundworkSetup.swift) | Validates interactive Groundwork configuration and stores origin-bound credentials. |

### Updates and process execution

| Module | Responsibility |
|---|---|
| [`Updater.swift`](Sources/MoveBreak/Updater.swift) | Checks releases, owns race-free download completion and timeout cleanup, stages verified bundles, swaps when idle, and relaunches. |
| [`UpdateValidation.swift`](Sources/MoveBreak/UpdateValidation.swift) | Validates releases, URLs, digests, bundle metadata, and semantic versions. |
| [`UpdateSecurity.swift`](Sources/MoveBreak/UpdateSecurity.swift) | Enforces staging containment, code-signature validity, and signer continuity. |
| [`ProcessRunner.swift`](Sources/MoveBreak/ProcessRunner.swift) | Executes fixed subprocesses without a shell, with output capture and timeouts. |

### Self-tests

| Module | Responsibility |
|---|---|
| [`SelfTest.swift`](Sources/MoveBreak/SelfTest.swift) | Declares and runs the complete CLI self-test suite manifest, timing each suite and the complete run. |
| [`SelfTestSupport.swift`](Sources/MoveBreak/SelfTestSupport.swift) | Supplies reporters, case counting, assertions, temporary directories, and cleanup checks. |
| [`DetectionSelfTests.swift`](Sources/MoveBreak/DetectionSelfTests.swift) | Tests identity resolution, tab rules, lifecycle policy, scheduling, and settings validation. |
| [`PersistenceSelfTests.swift`](Sources/MoveBreak/PersistenceSelfTests.swift) | Tests record compatibility, persistence boundaries, recovery, retries, origin binding, and legacy isolation. |
| [`SecuritySelfTests.swift`](Sources/MoveBreak/SecuritySelfTests.swift) | Tests secret input, Keychain behavior, credential boundaries, and URL redaction. |
| [`UpdateSelfTests.swift`](Sources/MoveBreak/UpdateSelfTests.swift) | Tests download completion races plus release, archive, bundle, staging, signer, and subprocess update boundaries. |
| [`GroundworkSelfTests.swift`](Sources/MoveBreak/GroundworkSelfTests.swift) | Tests the offline wire contract, request/failure boundary, redirect policy, cache provenance, and setup isolation. |

<!-- architecture-module-inventory:end -->
