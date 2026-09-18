# MoveBreak

MoveBreak is a macOS menu-bar app that notices when you enter a video call or start
watching a video, then offers a short movement routine in a floating panel. It was designed
for a treadmill desk, with exercises for sciatic, jaw/TMJ, trap, and plantar-fascia work.

> MoveBreak provides general movement prompts, not medical advice. Stop anything that
> increases pain, and defer to your physical therapist or other clinician.

## Quick start

### Requirements

- An Apple-silicon Mac running macOS 14.4 or later. Detection uses the CoreAudio
  per-process stream API introduced in macOS 14.4, and the build currently targets `arm64`.
- Xcode Command Line Tools (`xcode-select --install` if they are not already installed).
- A local clone of this repository. MoveBreak has no third-party dependencies and does not
  require the full Xcode app, an Xcode project, or Swift Package Manager.

From the repository root:

```bash
./scripts/build_app.sh
open ./MoveBreak.app
```

The build script checks repository documentation, compiles every Swift source, runs the
complete offline self-test suite, packages `MoveBreak.app`, and ad-hoc signs it. MoveBreak
runs as a menu-bar accessory and does not show a Dock icon. Look for the flexibility figure
or `MB` in the menu bar.

### First-run permission

MoveBreak does not request microphone, audio-recording, Accessibility, or screen-recording
permission. It reads only CoreAudio's per-process input/output-running flags; it does not tap,
record, or retain audio.

When MoveBreak needs to distinguish browser video from browser music or a web meeting, it
uses Apple Events to read browser tab URLs. macOS asks for Automation permission separately
for each supported browser: Google Chrome, Safari, Brave, Arc, and Microsoft Edge. Trigger
and verify that permission immediately with a supported browser running:

```bash
./MoveBreak.app/Contents/MacOS/MoveBreak --tabs
```

Approve the macOS prompt. If you previously denied it, enable the browser under **System
Settings → Privacy & Security → Automation → MoveBreak** and run `--tabs` again. An error
containing `-1743` means Automation is still denied. The normal detector queries tabs only
while a supported browser has live audio output; `--tabs` is the explicit one-shot exception.

An ad-hoc signature changes whenever the executable changes, so macOS may ask again after
each rebuild. See [Stable signing and updates](#stable-signing-and-updates) to keep the grant
stable across builds.

### Quick verification

These checks need no credentials or live meeting:

```bash
./build/MoveBreak --self-test
./MoveBreak.app/Contents/MacOS/MoveBreak --tabs
./MoveBreak.app/Contents/MacOS/MoveBreak --demo
```

The first command verifies classification, security, persistence, and updater behavior
offline. The second verifies browser Automation and displays the classification of current
tabs. The third opens the routine-choice panel without waiting for detection.

For a live end-to-end check, start this command and then play and pause a recognized video:

```bash
./build/MoveBreak --diagnose
```

It prints a host-level summary by default. Add `--verbose` only when you intentionally want
full browser URLs written to the terminal.

## Everyday operation

MoveBreak waits for two consecutive matching polls before changing state (normally about
four seconds with the defaults). It prompts once per continuous meeting/video session. From
the prompt, choose a routine or select **Not now**. A chosen routine opens a checklist; only
exercises you explicitly check are recorded when you finish it.

The menu provides:

- the current detection state;
- each nonempty saved routine, for starting one manually;
- **Edit Routines…** for adding, renaming, deleting, or changing local routines;
- **Pause Detection** / **Resume Detection**; and
- **Quit MoveBreak**.

The default lifecycle rules are:

- two matching polls are required for a state change;
- **Not now** suppresses prompts for 45 minutes;
- an unanswered prompt closes after 30 seconds and suppresses prompts for 15 minutes; and
- 60 seconds of continuous idle ends a session. Moving from a meeting directly into a video
  is still one session, so it does not produce a second prompt.

### Start at login

Keep the built app at a stable path, then install and start its per-user LaunchAgent:

```bash
./scripts/install_login_item.sh
```

The generated `~/Library/LaunchAgents/com.mike.movebreak.plist` points to the absolute path
of the app in the current checkout. If the checkout moves, rerun the install command from
the new location. To stop the LaunchAgent and remove its plist:

```bash
./scripts/install_login_item.sh --uninstall
```

### Uninstall and reset

1. Run `./scripts/install_login_item.sh --uninstall` from the checkout if start-at-login was
   installed.
2. Quit MoveBreak from its menu, or send `--quit` as shown below.
3. Delete `MoveBreak.app` and the checkout if they are no longer needed.

Those steps preserve preferences, saved routines, local history, and any Notion credential.
To remove them too, use the reset commands in [Configuration](#configuration), delete
`~/Library/Application Support/MoveBreak/`, and remove the Keychain item whose service is
`com.mike.MoveBreak.notion` and account is `integrationToken`. These data-removal steps are
permanent, so inspect or back up local history first.

## Detection behavior

Detection uses CoreAudio's per-process stream state in three stages:

| Stage | Signal | Classification |
|---|---|---|
| 1 | A configured meeting app or browser has a live input stream | `meeting` |
| 2 | A configured native player has live output | `video` |
| 3 | A supported browser has live output | Inspect tab URLs for meeting, video, or music |
| — | No rule matches | `idle` |

CoreAudio often reports audio against helper processes rather than the visible app. MoveBreak
resolves helpers such as Chrome renderers, Electron helpers, and Safari WebKit processes to
their owning app before applying the rules.

For a playing browser, a meeting URL outranks video and music. Otherwise, the active tab of
the front window is decisive: known music is ignored and known video is classified as video.
If that tab is inconclusive, MoveBreak examines the active tab of each browser window. It
accepts a call, or exactly one video match with no music matches; ambiguous browser audio is
deliberately ignored to avoid interrupting music. Paused video has no live output stream and
does not reach tab inspection.

The supported browser allowlist is fixed to Chrome, Safari, Brave, Arc, and Edge because
each has a known AppleScript implementation. Firefox and other browsers are not supported.

## Diagnostics and troubleshooting

### Browser tabs and live audio

```bash
./MoveBreak.app/Contents/MacOS/MoveBreak --tabs
./build/MoveBreak --diagnose
./build/MoveBreak --diagnose --verbose
```

`--tabs` is a one-shot Automation and URL-rule probe. `--diagnose` continuously shows live
CoreAudio processes, owning-app resolution, browser inspection, and the final verdict. Both
redact URLs to hosts by default; `--verbose` exposes full URLs.

A useful live sequence is:

1. Idle desktop → `idle`.
2. Recognized video open but paused → still `idle`.
3. Play it → `video` after the debounce.
4. Play a recognized music site in the active tab → `idle` with a music reason.
5. Join a call → `meeting`; mute and confirm your conferencing app still exposes either a
   live input stream or a recognized active meeting URL.
6. Leave or stop playback → `idle` after the debounce, with the session ending after the
   idle grace period.

### UI previews

```bash
./MoveBreak.app/Contents/MacOS/MoveBreak --demo
./MoveBreak.app/Contents/MacOS/MoveBreak --demo-pt
./MoveBreak.app/Contents/MacOS/MoveBreak --demo-builder
```

These launch the app and show the prompt, the seeded PT checklist (or first available
routine), or the routine editor. Demo launches do not start detection or automatic updates.

### Missing menu-bar icon

macOS can place a status item off-screen when the menu bar has no room. Launch with the
status diagnostic to inspect its geometry:

```bash
./MoveBreak.app/Contents/MacOS/MoveBreak --status-check
```

A negative `y` value in `window=(...)` indicates an off-screen status item. Free menu-bar
space in **System Settings → Control Center**, or control an already-running instance with:

```bash
./MoveBreak.app/Contents/MacOS/MoveBreak --show
./MoveBreak.app/Contents/MacOS/MoveBreak --toggle-pause
./MoveBreak.app/Contents/MacOS/MoveBreak --quit
```

These commands use same-user `DistributedNotificationCenter` messages and need no extra
permission. They report that the message was sent even if no MoveBreak instance is running.

### Unsupported system

On a system without the required CoreAudio property, the menu reports **Unsupported: needs
macOS 14.4+** and detection and updates do not start. Use an Apple-silicon Mac on macOS 14.4
or later; the current build script does not produce an Intel binary.

## Command-line reference

Run `./build/MoveBreak --help` for the executable's authoritative help. The shipped flags are:

| Flag | Behavior |
|---|---|
| `--help`, `-h` | Print help and exit. |
| `--version` | Print the bundle version and exit; use the app-bundle executable for a packaged version. |
| `--self-test` | Run all offline self-test suites and exit. |
| `--tabs` | Probe supported running browsers once and exit. |
| `--diagnose` | Continuously print live detection state. |
| `--verbose` | With `--tabs` or `--diagnose`, print full URLs instead of hosts. |
| `--demo` | Launch and show the routine-choice prompt. |
| `--demo-pt` | Launch and show the PT checklist. |
| `--demo-builder` | Launch and show the routine editor. |
| `--configure-notion` | Interactively configure optional Notion sync and exit. |
| `--configure-groundwork` | Interactively store Groundwork URL, location, duration, and an origin-bound Keychain token, then exit. |
| `--show` | Ask an already-running instance to show the prompt, then exit. |
| `--toggle-pause` | Ask an already-running instance to pause/resume, then exit. |
| `--quit` | Ask an already-running instance to quit, then exit. |
| `--status-check` | Launch normally and report status-item geometry to stderr after one second. |
| `--check-update-now` | Check once for an update and exit; installation requires stable signing. |

Secrets are rejected in command-line arguments. In particular, do not invent token flags;
use the appropriate interactive `--configure-notion` or `--configure-groundwork` flow.

The repository scripts are:

```bash
./scripts/build_app.sh                         # build and ad-hoc sign
./scripts/build_app.sh "MoveBreak Signing"     # build with a stable identity
./scripts/install_login_item.sh                # install/start login LaunchAgent
./scripts/install_login_item.sh --uninstall    # stop/remove login LaunchAgent
./scripts/test_health.sh --help                 # repeated self-test health options
./scripts/check_agent_context.sh --help         # repository documentation check options
```

`scripts/check_architecture_docs.sh` accepts an optional architecture-document path for
test fixtures; its normal repository invocation is `./scripts/check_architecture_docs.sh`.

## Configuration

Preferences use the `com.mike.movebreak` `UserDefaults` domain. List writes replace the
entire built-in list; they do not append to it. Examples:

```bash
defaults write com.mike.movebreak musicPatterns -array \
    "relisten.net" "phish.in" "siriusxm.com" "nugs.net" "archive.org/details"

defaults write com.mike.movebreak promptTimeout -float 45

# Reset one setting to its built-in default.
defaults delete com.mike.movebreak musicPatterns

# Reset every preference, including saved routines and non-secret integration settings.
# This does not delete local history or integration tokens in Keychain.
defaults delete com.mike.movebreak
```

The app also owns `savedRoutines` (JSON-encoded routine definitions),
`notionDatabaseID`, `groundworkBaseURL`, `groundworkLocationID`, and
`groundworkDurationMinutes` in this domain. Treat
`savedRoutines` as app-managed data rather than editing its encoded value with `defaults`.

Invalid numeric values fall back to their built-in defaults:

| Key | Accepted range | Default | Purpose |
|---|---:|---:|---|
| `pollInterval` | 0.5–60 seconds | 2 seconds | CoreAudio polling interval |
| `debouncePolls` | 1–20 polls | 2 polls | Consecutive classifications required |
| `sessionEndGrace` | 5–600 seconds | 60 seconds | Continuous idle before a session ends |
| `declineCooldown` | 60–86,400 seconds | 2,700 seconds | Suppression after **Not now** |
| `timeoutCooldown` | 60–86,400 seconds | 900 seconds | Suppression after prompt timeout |
| `promptTimeout` | 5–300 seconds | 30 seconds | Prompt countdown |
| `tabCacheLifetime` | 1–60 seconds | 5 seconds | Browser-tab result cache |

The configurable lists and complete built-in defaults are:

| Key | Built-in values |
|---|---|
| `meetingApps` | `us.zoom.xos`, `us.zoom.CptHost`, `us.zoom.aomhost`, `com.microsoft.teams2`, `com.microsoft.teams`, `com.cisco.webexmeetingsapp`, `com.apple.FaceTime`, `com.tinyspeck.slackmacgap`, `com.hnc.Discord`; supported browsers are also treated as meeting apps for live input |
| `nativePlayers` | `com.apple.QuickTimePlayerX`, `org.videolan.vlc`, `com.colliderli.iina` |
| `browsers` | `com.google.Chrome`, `com.apple.Safari`, `com.brave.Browser`, `company.thebrowser.Browser`, `com.microsoft.edgemac` |
| `ignoredApps` | `com.spotify.client`, `com.apple.Music` |
| `meetingPatterns` | `meet.google.com/`, `teams.microsoft.com/`, `teams.live.com/`, `zoom.us/wc`, `zoom.us/j/`, `whereby.com/`, `webex.com/meet`, `app.slack.com/huddle`, `discord.com/channels` |
| `videoPatterns` | `youtube.com/watch`, `youtube.com/shorts`, `youtube.com/live`, `vimeo.com`, `netflix.com/watch`, `twitch.tv`, `hulu.com/watch`, `max.com/video`, `disneyplus.com/video`, `coursera.org/lecture`, `udemy.com/course` |
| `musicPatterns` | `music.youtube.com`, `relisten.net`, `phish.in`, `siriusxm.com`, `player.siriusxm.com`, `bandcamp.com`, `soundcloud.com`, `open.spotify.com`, `music.apple.com`, `archive.org/details`, `nugs.net`, `mixcloud.com` |

List entries are trimmed, deduplicated in order, limited to 256 characters each and 100
items per list, and rejected when malformed. An empty normalized list falls back to its
built-in default. URL patterns match exact hosts or subdomains plus an optional path prefix;
lookalike suffixes do not match. The `browsers` setting can narrow the fixed allowlist but
cannot add an arbitrary AppleScript target. `ignoredApps` wins before every detection stage,
including for recognized helper processes.

## Routines and local history

MoveBreak seeds three editable local routines on first launch:

- **Do PT** (about 9 minutes);
- **Workout** (about 5 minutes); and
- **Just Stretch** (about 6 minutes).

The estimate is computed from the current exercise count, so edits change it. Empty routines
remain saved in the editor but are omitted from prompts and the menu. At the start of each
local routine, walk-safe exercises are shuffled first and pause-treadmill exercises are
shuffled after them. Heed the walk/pause marker and stop the treadmill for any exercise that
requires balance, floor work, or lifting a foot from the belt.

Finishing a checklist appends one JSON object per line to:

```text
~/Library/Application Support/MoveBreak/sessions.jsonl
```

The app creates/tightens the `MoveBreak` directory to owner-only mode `0700` and contained
files to `0600`. Failed Notion deliveries are stored atomically in `pending-sync.json` and
retried at app launch. The local JSONL append happens before any network attempt and remains
the source of truth.

Saved routine definitions and other non-secret preferences live in `UserDefaults`, not in
the Application Support directory. MoveBreak does not store audio or a general browser
history. Diagnostic commands print hosts unless `--verbose` is explicitly supplied.

## Groundwork transport setup

Groundwork transport, strict version-1 wire models, and an offline routine cache are shipped
as infrastructure for the later generated-routine HUD. The current prompt and checklist still
use local saved routines and do not poll Groundwork. Configuration therefore has no visible UI
effect yet and unconfigured startup performs no Groundwork request.

When a compatible Groundwork deployment is available, configure it interactively:

```bash
./MoveBreak.app/Contents/MacOS/MoveBreak --configure-groundwork
```

Enter an HTTPS deployment root, an existing Groundwork location ID, a default duration from
1 through 30 minutes, and the dedicated bearer token. HTTP is accepted only for an explicit
loopback host (`localhost`, `127.0.0.1`, or `::1`) used in local development. The token prompt
does not echo. Tokens use the separate Keychain service `com.mike.MoveBreak.groundwork` and an
account derived from the exact URL origin, so a token configured for one scheme/host/port is
not available to another. Non-secret settings remain in `UserDefaults`.

Only successfully validated, nonempty live routines are cached. Cache entries are isolated by
origin, location, duration, and schema version. A future offline HUD can label a cached copy
with its timestamp and “not revalidated” status, or use clearly labeled bundled/local defaults
when no cache exists. A valid empty live response remains empty. Authentication, unavailable,
malformed, corrupt-cache, and unconfigured states are kept separate.

## Optional Notion sync

Groundwork completion delivery and generated-routine UI are not shipped. The only current
remote completion integration is optional Notion sync; local history works without it.

Create a Notion internal integration and a database shared with that integration. The
database must have these properties with matching names and types: `Entry` (title), `Date`
(date), `Routine` (select), `Exercises Completed` (rich text), `Completed` (number), `Total`
(number), and `Est. Duration (min)` (number). Then run:

```bash
./MoveBreak.app/Contents/MacOS/MoveBreak --configure-notion
```

The interactive prompt disables terminal echo for the token. The token is stored only in
the device-local Keychain service `com.mike.MoveBreak.notion`, account `integrationToken`,
with `AfterFirstUnlockThisDeviceOnly` accessibility. It is never accepted as an argument,
written to `UserDefaults`, or included in app diagnostics. The non-secret database ID is
stored in `UserDefaults` as `notionDatabaseID`.

On completion, Notion receives the date, routine title, checked exercise names, checked and
total counts, and estimated duration. A network or configuration failure does not undo local
history; it adds the record to the local pending queue.

## Stable signing and updates

The default build is ad-hoc signed. This is sufficient for local execution, but Automation
grants may be requested after rebuilding and automatic update installation is disabled
because an ad-hoc build cannot establish signer continuity.

For a stable local identity, create a certificate in Keychain Access:

1. Choose **Keychain Access → Certificate Assistant → Create a Certificate…**.
2. Use the name `MoveBreak Signing`, identity type **Self Signed Root**, and certificate
   type **Code Signing**.
3. Rebuild with that exact identity:

```bash
./scripts/build_app.sh "MoveBreak Signing"
```

A certificate-signed normal launch checks the latest `mkny13/movebreak` GitHub release at
startup and every 24 hours. A newer `MoveBreak.app.zip` is installed only when the app is
idle and no prompt, checklist, or editor is visible. The updater fails closed: it requires
the official HTTPS release path, a release-provided SHA-256 digest, matching bundle ID,
executable and version, contained extraction paths, a strict valid code signature, and the
exact same leaf signing certificate as the running app. Failed verification leaves the
current app untouched. Staging uses owner-only directories under
`~/Library/Application Support/MoveBreak/Updates/`.

Use this only as a diagnostic one-shot check; it does not bypass any trust rule:

```bash
./MoveBreak.app/Contents/MacOS/MoveBreak --check-update-now
```

## Build and test details

`./scripts/build_app.sh` compiles `Sources/MoveBreak/*.swift` directly with `swiftc`, links
only macOS system frameworks, runs `./build/MoveBreak --self-test`, assembles the app, and
signs it. Build products are written to the ignored `build/` and `MoveBreak.app/` paths.

For an opt-in repeat-run health check against an already-built executable:

```bash
./scripts/test_health.sh
```

It performs five self-test runs by default, rejects changed suite/case inventories and
unexpected diagnostics, enforces a per-run timeout, and compares later timing with the first
run. `./scripts/test_health.sh --help` documents command options and the corresponding
`MOVEBREAK_HEALTH_*` environment variables. This stress check is not part of the ordinary
build.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the shipped runtime, data flow, threading,
persistence, security boundaries, and module inventory. See [ROADMAP.md](ROADMAP.md) for the
future-state sequence and ownership of transitional components.

## Historical implementation notes

These observations explain current choices; they are not universal setup promises:

- During early development on one machine, Zoom's `caphost` appeared well after Zoom started
  and then remained alive for more than a day, while the older `CptHost` behavior could not
  be confirmed. That investigation led MoveBreak to use stream state rather than process
  presence as the meeting signal.
- A test profile with dozens of tabs showed that scanning every tab made background music
  sites suppress detection indefinitely. The implementation therefore inspects the active
  tab in each window for its fallback, not every tab.
- Early builds created an `NSPanel` from the polling queue and crashed. UI creation and
  callbacks now cross an explicit main-thread boundary, covered by self-tests and assertions.
- An off-screen status-item frame was observed when a narrow menu bar was full. That result
  motivated `--status-check` and same-user remote-control flags; exact geometry varies by Mac.
- Full-screen auxiliary panel behavior can depend on the conferencing app and macOS version;
  use `--demo` and a real call to validate it on the target Mac.

## Planned Groundwork UI and completion integration

MoveBreak now has configurable Groundwork credentials, native request/response models, and a
durable offline routine cache, but the app does not yet fetch for its prompt, display generated
routines, or deliver completions. The bundled catalog, local routine editor and shuffle, local
JSONL history, and optional Notion sync remain active.

[ROADMAP.md](ROADMAP.md) is the authoritative shipped/planned boundary. The planned migration
is tracked by [issue #2](https://github.com/mkny13/movebreak/issues/2) and its dependent
issues; future behavior described there should not be read as current setup guidance.

## Agent workflows

This repository is managed by [Mahler](https://github.com/mkny13/mahler). See
[AGENTS.md](AGENTS.md) for repository build, verification, and autonomous-agent conventions.
