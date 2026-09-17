# MoveBreak architecture

This document is the canonical description of MoveBreak's shipped implementation. It
describes the current code, not the planned Groundwork integration. See [ROADMAP.md](ROADMAP.md)
for future work and [README.md](README.md) for user setup, operation, and troubleshooting.

## Runtime boundary and entry points

MoveBreak is a single, menu-bar-only macOS process. It uses AppKit for application and
window lifecycle, SwiftUI for panel content, CoreAudio for process stream state, and
Foundation/Security for persistence, networking, subprocesses, and Keychain access. It has
no service process, database, Xcode project, Swift package, or third-party dependency.

The executable first rejects command-line secrets and routes terminal-only commands before
starting `NSApplication`. The commands cover help/version, self-tests, browser-tab probing,
live diagnostics, Notion setup, update checks, demos, status checks, and same-user remote
control. Normal launch creates `AppDelegate`, selects accessory activation policy (no Dock
icon), and enters the AppKit run loop.

`AppDelegate` is the composition root. It creates the detector, routine store, three panel
controllers, status item, polling scheduler, session logger hooks, remote-control listener,
and updater safety predicate.

## Observation-to-completion data flow

1. A main-run-loop timer requests a poll at the configured interval. `SerialPollScheduler`
   admits only one poll at a time and drops ticks while one is in flight.
2. On its private utility queue, the detector reads CoreAudio's per-process input/output
   stream flags. Helper bundle IDs are resolved to their owning application.
3. Classification applies the three stages below. Browser AppleScript runs only when a
   supported browser owns a live output stream; recent tab results have a short cache.
4. The same serial scheduler accepts the observation into the debounced session lifecycle.
   A generation token discards work begun before pause, resume, or shutdown.
5. When one prompt is due for the open session, the callback crosses to the main queue and
   presents saved local routine choices. Decline and timeout choices update cooldown state on
   the detection queue.
6. Choosing a routine marks the session prompted, partitions a per-session shuffle into
   walk-safe work followed by pause-belt work, and opens the checklist panel.
7. Pressing Done captures the checked exercise IDs. The session logger appends a record to
   local JSONL before attempting optional Notion upload; a failed upload is added to the
   local pending queue and launch retries pending entries.

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

Unknown or ambiguous browser audio is deliberately classified as idle. Diagnostics sanitize
URLs to host-level output unless verbose mode is explicitly selected.

`SessionLifecycle` debounces state changes, preserves one logical session across short idle
gaps and meeting-to-video transitions, prompts at most once per session, and applies separate
decline and timeout cooldowns. After continuous idle exceeds the configured grace period,
the next active observation opens a new session.

## Concurrency and UI boundary

AppKit creation and mutation belong on the main thread. `FloatingPanel` asserts that its
initializer runs there, and detector callbacks use `onMain` before touching panel or status
UI. The polling scheduler owns slow CoreAudio/AppleScript inspection and serializes all
detector lifecycle mutations on one utility queue; accepted results return to the main queue.
The session logger has a separate serial queue for file and sync-queue mutation. Updater
downloads and verification run away from the UI thread, while installation is gated on the
app being idle with no MoveBreak panel visible.

The shared panel is non-activating, floating, and full-screen auxiliary. Prompt and checklist
windows therefore appear without proactively stealing focus and can join full-screen spaces.
The deliberately opened routine editor uses centered placement.

## Routine and catalog ownership

The bundled exercise catalog is the current source of exercise names, areas, dose text,
cues, posture, and treadmill-safety tags. The local routine store owns user-created routine
names and ordered catalog IDs, JSON-encoded in `UserDefaults`. On first launch it seeds three
editable routines. Empty routines remain editable but are omitted from the prompt and menu.

Resolved routines copy catalog exercises into the display model. Each launch shuffles
walk-safe and pause-belt partitions independently while keeping the safe partition first.
The checklist groups exercises by area in the resulting order and reports only explicitly
checked IDs. The static catalog, local routine editor, and saved routines are live product
behavior, not dead abstractions; their role during Groundwork migration is defined in the
roadmap.

## Configuration, credentials, and persistence

`Preferences` reads and normalizes tuning values from the `com.mike.movebreak`
`UserDefaults` domain. Numeric settings are bounded, URL patterns are normalized, and the
browser list cannot expand beyond implementations with a known AppleScript dialect.

The current optional remote integration is Notion. Interactive setup writes the integration
token to the device-local Keychain service `com.mike.MoveBreak.notion` and the non-secret
database ID to preferences. Tokens are not accepted as command-line values. The client sends
completed session summaries directly to Notion over HTTPS.

Local session data lives under `~/Library/Application Support/MoveBreak/`. The directory is
created or tightened to mode `0700`; contained files are tightened to `0600`.
`sessions.jsonl` is append-only local history and is written before a network request.
`pending-sync.json` is a JSON array replaced atomically within the same directory after a
Notion failure. The current queue is best-effort: a crash after the history append but before
failed delivery is enqueued is not reconciled automatically. Durable Groundwork outbox work
is intentionally future scope.

## Automatic-update trust boundary

The updater polls the latest GitHub release for `mkny13/movebreak`, but automatic
installation is disabled when the running app is ad-hoc signed. Before staging a candidate it
requires all of the following:

- a newer, well-formed release tag and exactly named `MoveBreak.app.zip` asset;
- an HTTPS GitHub release URL for the expected repository, tag, and asset;
- a release-provided SHA-256 digest matching the downloaded archive;
- extraction inside a mode-`0700`, random application-support staging directory, with the
  bundle and all symlinks contained there;
- matching bundle identifier, executable shape, and release/bundle version;
- strict code-signature verification and the same leaf signing certificate as the running
  app.

Fixed absolute executables and argument arrays are used for archive, signature, and xattr
operations; no shell evaluates downloaded input. Quarantine is removed only after all checks
pass. Replacement and relaunch occur only when detection is unpaused and idle and no prompt,
routine, or editor panel is visible. Any validation failure leaves the installed bundle
untouched.

## Build and test structure

`scripts/build_app.sh` compiles every source file directly with `swiftc`, targeting arm64
macOS 14.4 and linking only system frameworks. It runs the CLI self-test before assembling
and ad-hoc signing the application bundle. The self-test coordinator checks its suite
manifest and runs focused detection, persistence, credential/security, and updater suites
without requiring browser automation or network access. Each reporter records its case count;
the coordinator emits stable per-suite inventory and elapsed-time summaries plus a complete-run
total while retaining zero/nonzero process exit semantics.

The normal build gate deliberately performs one self-test run. The opt-in
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
| [`AppDelegate.swift`](Sources/MoveBreak/AppDelegate.swift) | Composition root, serialized poll scheduling, menu/status UI, callbacks, and updater idle gating. |
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
| [`Preferences.swift`](Sources/MoveBreak/Preferences.swift) | Owns validated defaults and `UserDefaults` overrides for detection and timing. |

### Routine domain and UI

| Module | Responsibility |
|---|---|
| [`ExerciseCatalog.swift`](Sources/MoveBreak/ExerciseCatalog.swift) | Defines exercise, posture, and treadmill models and the bundled static catalog. |
| [`Routines.swift`](Sources/MoveBreak/Routines.swift) | Defines resolved routines, session shuffling, and the user-facing disclaimer. |
| [`RoutineStore.swift`](Sources/MoveBreak/RoutineStore.swift) | Persists editable saved routines, seeds defaults, and resolves catalog IDs. |
| [`FloatingPanel.swift`](Sources/MoveBreak/FloatingPanel.swift) | Defines the non-activating AppKit host panel and full-screen placement behavior. |
| [`PromptPanel.swift`](Sources/MoveBreak/PromptPanel.swift) | Presents numbered routine choices and decline/timeout behavior. |
| [`RoutineWindow.swift`](Sources/MoveBreak/RoutineWindow.swift) | Presents the self-paced checklist and emits checked exercise IDs on Done. |
| [`RoutineBuilderWindow.swift`](Sources/MoveBreak/RoutineBuilderWindow.swift) | Presents local routine create/rename/delete and catalog selection UI. |

### Completion persistence and Notion

| Module | Responsibility |
|---|---|
| [`SessionRecord.swift`](Sources/MoveBreak/SessionRecord.swift) | Codable local completion summary model. |
| [`SessionLogger.swift`](Sources/MoveBreak/SessionLogger.swift) | Serial local JSONL writes, protected file modes, and atomic pending-sync queue updates. |
| [`NotionClient.swift`](Sources/MoveBreak/NotionClient.swift) | Builds and sends current Notion page-creation requests. |
| [`NotionSetup.swift`](Sources/MoveBreak/NotionSetup.swift) | Runs interactive token/database configuration. |
| [`Keychain.swift`](Sources/MoveBreak/Keychain.swift) | Wraps device-local Keychain storage behind typed errors and a testable backend. |
| [`SecretInput.swift`](Sources/MoveBreak/SecretInput.swift) | Reads terminal secrets with echo disabled and signal-safe restoration. |

### Updates and process execution

| Module | Responsibility |
|---|---|
| [`Updater.swift`](Sources/MoveBreak/Updater.swift) | Checks releases, stages verified bundles, swaps when idle, and relaunches. |
| [`UpdateValidation.swift`](Sources/MoveBreak/UpdateValidation.swift) | Validates releases, URLs, digests, bundle metadata, and semantic versions. |
| [`UpdateSecurity.swift`](Sources/MoveBreak/UpdateSecurity.swift) | Enforces staging containment, code-signature validity, and signer continuity. |
| [`ProcessRunner.swift`](Sources/MoveBreak/ProcessRunner.swift) | Executes fixed subprocesses without a shell, with output capture and timeouts. |

### Self-tests

| Module | Responsibility |
|---|---|
| [`SelfTest.swift`](Sources/MoveBreak/SelfTest.swift) | Declares and runs the complete CLI self-test suite manifest, timing each suite and the complete run. |
| [`SelfTestSupport.swift`](Sources/MoveBreak/SelfTestSupport.swift) | Supplies reporters, case counting, assertions, temporary directories, and cleanup checks. |
| [`DetectionSelfTests.swift`](Sources/MoveBreak/DetectionSelfTests.swift) | Tests identity resolution, tab rules, lifecycle policy, scheduling, and settings validation. |
| [`PersistenceSelfTests.swift`](Sources/MoveBreak/PersistenceSelfTests.swift) | Tests records, routine persistence, local history, permissions, and pending queues. |
| [`SecuritySelfTests.swift`](Sources/MoveBreak/SecuritySelfTests.swift) | Tests secret input, Keychain behavior, credential boundaries, and URL redaction. |
| [`UpdateSelfTests.swift`](Sources/MoveBreak/UpdateSelfTests.swift) | Tests release, archive, bundle, staging, signer, and subprocess update boundaries. |

<!-- architecture-module-inventory:end -->
