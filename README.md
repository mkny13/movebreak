# MoveBreak

A menu-bar macOS app that notices when you've entered a sedentary session — a video call,
or a video you're actually watching — and offers a short routine in a small window that
floats over the meeting.

Written for a treadmill desk, targeting sciatic, jaw/TMJ, trap, and plantar fascia work.

```bash
./scripts/build_app.sh
open ./MoveBreak.app
```

---

## How detection works

Everything keys off **CoreAudio's per-process stream state**
(`kAudioHardwarePropertyProcessObjectList`, macOS 14.4+). This reads whether a process
holds a live audio stream — it does not tap or record audio, so it needs no permission and
raises no prompt.

Three stages, cheapest and most certain first:

| Stage | Signal | Result |
|---|---|---|
| 1 | a meeting app holds a live **input** (mic) stream | `meeting` |
| 2 | a native player holds a live **output** stream | `video` |
| 3 | a browser holds a live **output** stream | ask its tabs → below |
| — | none of the above | `idle` |

Stage 1 covers Zoom, Meet, Teams, Slack, and FaceTime through one code path — a live mic
stream is unambiguous.

This is also what separates "a YouTube tab is open" from "a video is playing": a **paused**
tab holds no running output stream, so it never even reaches stage 3.

### Audio is reported against helper processes, not apps

This one is load-bearing, and it is not obvious. Chrome's playback is attributed to
**`com.google.Chrome.helper`**, never to `com.google.Chrome`. Electron apps (Slack, Teams,
Discord) behave the same way, and Safari's audio comes from `com.apple.WebKit.GPU`, which
doesn't even share Safari's bundle prefix.

So comparing raw process bundle IDs against an app list matches *nothing* — the browser
stage silently never fires. `BundleIdentity.owner(of:in:)` resolves helper → owning app,
and every stage goes through it. `--self-test` covers this specifically, because the
failure mode is silence rather than an error.

### Why not watch for Zoom's processes?

Because the signal everyone cites is wrong. `caphost` is widely recommended as the
"in a meeting" indicator, but on this machine it launched 29 seconds after Zoom itself and
then ran continuously for 30+ hours — it's a persistent helper, not a meeting marker.
Anything built on it fires permanently. `CptHost` (the older meeting-window host) could
not be confirmed as still in use by Zoom 7.0.5 at all.

Audio-stream state is both more robust and version-independent.

### Google Meet needs a URL check too

Zoom keeps its microphone stream open while muted, so stage 1 (mic-based) catches it
whether or not you're speaking. **Chrome does not do this for Meet** — muting a Meet call
releases the mic stream entirely, so stage 1 sees nothing.

`meetingPatterns` (`meet.google.com/`, `teams.microsoft.com/`, `zoom.us/wc`, etc.) is
checked in the same tab-inspection pass as video/music, and outranks both: a call is a
higher-value signal than a video, and a meeting tab active in its own window is trusted
even if a music tab is open elsewhere. Confirmed with a muted-Meet-plus-Relisten self-test
case.

### Telling music from video in a browser

CoreAudio attributes all browser audio to the browser process, so Relisten and a YouTube
video look identical at the bundle-ID level. Stage 3 resolves this by asking the browser
what's open, via AppleScript.

Chrome's scripting dictionary exposes `active tab`, `URL`, `title`, and `frontmost` — but
**no `audible` property**, so there's no way to ask which tab is the one making noise.
Hence the precedence rule:

```
1. Read the ACTIVE tab of the front window.
     matches musicPatterns -> ignore     (checked first: more specific)
     matches videoPatterns -> video
2. Otherwise read the ACTIVE tab of every window:
     exactly one video match AND zero music matches -> video
     anything else (none, or mixed)                 -> ignore
```

Checking the active tab first is what resolves the both-open case: if you're watching
something, it's the tab you're looking at. Relisten streaming in a background tab while you
work in the front tab correctly resolves to *ignore*.

**Step 2 reads per-window active tabs, not every tab.** Scanning all tabs was tried first
and proved useless on a real machine: with 72 tabs open, five long-lived phish.in tabs meant
the fallback always saw music and always suppressed, so the branch could never fire.
Per-window active tabs cut the candidate set from 72 to 15 and is a better model of reality
— audio almost always comes from the tab that's frontmost in its own window. A buried
background tab that autoplays with sound is rare, and missing it only costs one prompt.

Music is checked **before** video because its patterns are more specific — e.g.
`music.youtube.com/watch?v=…` also contains the `youtube.com/watch` video pattern.

The bias is deliberately toward **not** prompting. A missed prompt costs nothing; an
interruption mid-song is the thing worth avoiding.

---

## Verifying it

### Classification rules, offline

```bash
./build/MoveBreak --self-test
```

Covers helper-process → app resolution, the Relisten/YouTube combinations, active-vs-
background tabs, ambiguous mixes, and host-matching edge cases. No browser or permission
needed. Also runs automatically as part of `build_app.sh`, which refuses to package a
build that fails it.

### What your browsers have open, right now

```bash
./MoveBreak.app/Contents/MacOS/MoveBreak --tabs
```

Shows each running browser's active tab, the per-window fallback candidates, which list
each matched, and the verdict — without needing anything to be playing. This is the fastest
way to check the Automation grant and to see why a given tab did or didn't classify.

Prints hosts only by default since it reads your actual browsing; `--verbose` for full URLs.

### Live detection

```bash
./build/MoveBreak --diagnose
./build/MoveBreak --diagnose --verbose  # full URLs instead of host-level summary
```

Prints a live table of every process holding an audio stream (pid · bundle id · in · out),
the resolved browser tab URLs and which list they matched, and the final verdict. Redraws
whenever anything observable changes. Host-level summaries are printed by default to preserve
privacy; pass `--verbose` if full URLs are needed.

Walk through these to confirm real-world behavior:

1. Idle desktop → `idle`
2. YouTube tab open but **paused** → still `idle`
3. Press play → `video`
4. Relisten or SiriusXM playing, front tab → `idle`, matched `musicPatterns`
5. Relisten playing in a background tab while you work in the front tab → `idle`
6. Relisten **and** a YouTube video open, YouTube in front → `video`; switch front tab
   back to Relisten → `idle`
7. Join a real Zoom meeting → `meeting`; **mute yourself** and confirm it stays `meeting`
8. Leave → `idle`

Step 7 confirmed: Zoom's mute is software-level, the input stream stays open, `meeting`
holds. Confirmed live on this machine.

Any bundle ID or URL that shows up unclassified can be added to the lists — see Tuning. The
process table's `RESOLVES TO` column shows exactly which list (if any) each process landed
in, which is the fastest way to see why something wasn't detected.

### The UI

```bash
./MoveBreak.app/Contents/MacOS/MoveBreak --demo           # the routine-choice prompt
./MoveBreak.app/Contents/MacOS/MoveBreak --demo-pt         # the PT checklist
./MoveBreak.app/Contents/MacOS/MoveBreak --demo-builder    # the routine editor
```

Shows the panels immediately without waiting for a meeting. `NSFloatingWindowLevel`,
top-right of the active screen (the editor is centered instead — it's opened
deliberately, not tied to a meeting). The original fixed sizing here (360×296) no longer
applies to the prompt: its height now grows with however many routines are saved.

**Confirmed fixed — was a real crash.** The first build aborted (`SIGABRT`) every time
detection tried to show the prompt: `NSPanel` was being created from the background polling
queue, and AppKit windows must be built on the main thread. Three crash reports on first
run, all from `AppDelegate.startPolling() → SessionDetector.poll() → onPromptDue →
PromptPanelController.show → FloatingPanel.init`. Every path from the detector back to the
UI now hops through `onMain(...)`, and `FloatingPanel.init` asserts it's on the main thread
so a regression here fails loudly instead of silently aborting again. Verified by forcing
the exact crash path 12 times in a row afterward with zero new crash reports, and by
screenshotting the panel appearing live from real detection.

Floating over a genuinely full-screen Zoom window is the one thing that still needs a
real meeting to confirm — `.fullScreenAuxiliary` and `.nonactivatingPanel` are what should
make it work, but a plain window-level check can't fully stand in for that.

### If the menu bar icon doesn't appear

**This is expected, not a bug, if your menu bar is full.** macOS silently drops a status
item when there's no room — it parks the item's window off-screen (`y = −30` on this
machine) rather than erroring. `--status-check` reports this directly:

```bash
./MoveBreak.app/Contents/MacOS/MoveBreak --status-check
```

`window=(0.0, -30.0, 34.0, 30.0)` (negative y) means the icon was created but macOS has
nowhere to put it — usually because a rotated/narrow display plus Control Center plus other
menu-bar apps fill the available width. Confirmed this is the actual cause on this machine
via that check.

Rather than fight the menu bar for space, control the running instance directly:

```bash
./MoveBreak.app/Contents/MacOS/MoveBreak --show           # show the prompt now
./MoveBreak.app/Contents/MacOS/MoveBreak --toggle-pause   # pause / resume detection
./MoveBreak.app/Contents/MacOS/MoveBreak --quit           # quit the running instance
```

These work via `DistributedNotificationCenter` (same-user IPC, no extra permission) and
reach the running app regardless of whether its status item got a menu bar slot. Verified
`--show` (a panel appeared) and `--quit` (the process exited cleanly, no new crash) against
a live instance.

If you'd rather free up menu bar space instead, removing a couple of Control Center modules
(System Settings → Control Center) is the more permanent fix.

---

## Automation permission

Stage 3 sends Apple Events to Chrome/Safari, so macOS will prompt once per browser.

**TCC keys that grant to the code signature, and an ad-hoc signature changes on every
rebuild** — so by default Chrome re-prompts after each build. To make the grant stick,
create one self-signed code-signing certificate:

1. Keychain Access → *Certificate Assistant* → *Create a Certificate…*
2. Name: `MoveBreak Signing`, Identity Type: *Self Signed Root*,
   Certificate Type: *Code Signing*
3. Then build with it:

```bash
./scripts/build_app.sh "MoveBreak Signing"
```

If tab reads fail, `--diagnose` reports it explicitly as
`Automation permission not granted (error -1743)`.

---

## Start at login

```bash
./scripts/install_login_item.sh
```

Installs a LaunchAgent (not `SMAppService`, which is unreliable for locally-built,
non-notarized bundles). Remove with `--uninstall`.

---

## Tuning

All settings live in `UserDefaults` (`com.mike.movebreak`) and override built-in defaults:

```bash
defaults write com.mike.movebreak musicPatterns -array \
    "relisten.net" "phish.in" "siriusxm.com" "nugs.net" "archive.org/details"

defaults write com.mike.movebreak promptTimeout -float 45

# Reset an individual setting back to its built-in default:
defaults delete com.mike.movebreak musicPatterns

# Reset all MoveBreak configuration back to factory defaults:
defaults delete com.mike.movebreak
```

### Validated Timing & Bounds

User configuration is treated as untrusted input. Non-finite (`NaN`, `±Inf`), negative, non-positive, or out-of-range values are rejected deterministically, falling back to safe documented defaults to prevent tight poll loops, zero debounces, or unbounded suppression:

| Key | Safe Range | Default | Purpose |
|---|---|---|---|
| `pollInterval` | `0.5` – `60.0` s | `2.0` s | Audio process list polling interval |
| `debouncePolls` | `1` – `20` polls | `2` polls | Consecutive matching polls required before state changes |
| `sessionEndGrace` | `5.0` – `600.0` s | `60.0` s | Idle duration before a session is marked finished |
| `declineCooldown` | `60.0` – `86400.0` s | `2700.0` s (45m) | Prompt suppression after clicking "Not now" |
| `timeoutCooldown` | `60.0` – `86400.0` s | `900.0` s (15m) | Prompt suppression after an unanswered prompt timeout |
| `promptTimeout` | `5.0` – `300.0` s | `30.0` s | Floating prompt countdown duration |
| `tabCacheLifetime` | `1.0` – `60.0` s | `5.0` s | AppleScript tab read cache TTL |

### List Normalization & Denial-List Rules

- **Deterministic normalization**: Whitespace is trimmed, schemes (`https://`) and leading slashes are stripped, empty entries and oversized items (> 256 characters) are dropped, entries are deduplicated preserving order, and lists are capped at 100 items. If no valid items remain, the setting falls back to its built-in defaults.
- **URL host boundary matching**: Bare-domain patterns (e.g. `vimeo.com`, `twitch.tv`) match only that host or its subdomains (`www.vimeo.com`, `player.vimeo.com`). Deceptive host suffixes (`evilvimeo.com`, `notvimeo.com`) or host extensions (`vimeo.com.attacker.com`) are rejected. Host-plus-path patterns (`youtube.com/watch`) enforce both the host boundary and path prefix.
- **Fixed browser allowlist**: Configuring `browsers` is strictly constrained to the fixed internal allowlist with AppleScript dictionary support (`com.google.Chrome`, `com.apple.Safari`, `com.brave.Browser`, `company.thebrowser.Browser`, `com.microsoft.edgemac`). Arbitrary application bundle IDs cannot expand AppleScript targeting.
- **Ignored-app precedence**: Any process belonging to `ignoredApps` (or its helper processes, such as `com.spotify.client.helper` or `com.apple.WebKit.GPU`) is excluded before mic (Stage 1), native player (Stage 2), and browser tab inspection (Stage 3). Ignored apps never trigger AppleScript tab queries or session prompts.

Behavior worth knowing:

- The prompt fires **immediately** on joining, once per session.
- "Not now" suppresses for 45 min; an unanswered prompt suppresses for 15 min.
- A session ends after 60s of continuous idle. Meeting → video inside one stretch is not a
  new session, so you don't get a second prompt without having got up.

---

## Exercise content

All exercises live in one catalog (`ExerciseCatalog.swift`), written for **standing at a
treadmill desk**, each tagged for whether you need to stop walking:

- 🚶 fine while the belt is running — jaw, neck, trap, shoulder work
- ⏸ pause the treadmill — anything needing balance, the floor, or a foot off the belt

Routines are user-defined picks from that catalog (`RoutineStore.swift`), editable from
the menu bar's **Edit Routines…** item — pick exercises into as many named routines as you
want; a routine with nothing picked just doesn't show up in the prompt or menu. The app
ships with three starter routines seeded from the catalog, identical in content to what
used to be hardcoded:

**Do PT** (~8 min) — sciatic, jaw/TMJ, trap/levator, plantar fascia.

**Workout** (~10 min) — bodyweight strength at the desk.

**Just Stretch** (~4 min) — mostly walk-safe; the one to pick when you don't want to stop.

Each time a routine is started, `Routine.shuffledForSession()` reorders it: walk-safe
exercises are shuffled among themselves and shown first, pause-treadmill exercises are
shuffled among themselves and shown after. That's the one constraint kept from the old
hand-authored PT ordering — don't make someone stop the treadmill before the work that
doesn't need it — layered under a semi-randomized order so a routine doesn't play out
identically every session.

The `Exercise` model carries a `posture` field that MVP only populates with `.standing`, so
adding the "Sitting at Desk" mode later is a content change rather than a refactor.

> General movement prompts, not medical advice — stop anything that increases pain, and
> defer to your PT.

---

## Build notes

Compiles with `swiftc` directly rather than SwiftPM. The SwiftPM manifest API in this
machine's CommandLineTools is broken — `libPackageDescription.dylib` (Jun 8) is out of sync
with its `.swiftmodule` (Jul 16) and exports none of the expected symbols, so `swift build`
cannot parse a `Package.swift` at any tools version. `swiftc` itself is fine, and only full
Xcode (not installed) would provide `.xcodeproj` builds anyway.

```
Sources/MoveBreak/
  main.swift                  entry point; routes --self-test / --tabs / --diagnose / remote control
  AppDelegate.swift           menu bar item, polling, wiring
  AudioActivityMonitor.swift  CoreAudio per-process stream state
  BundleIdentity.swift        helper process → owning app (see note above)
  BrowserTabInspector.swift   AppleScript tab query + classification rules
  SessionDetector.swift       3-stage classify, debounce, session lifecycle
  FloatingPanel.swift         the NSPanel setup that floats over full-screen Zoom
  PromptPanel.swift           routine-choice popup (keys 1-9, esc for "Not now")
  RoutineWindow.swift         checklist window for a session's shuffled routine
  RoutineBuilderWindow.swift  "Edit Routines…" catalog picker
  ExerciseCatalog.swift       the full exercise library, Exercise/TreadmillTag/Posture
  RoutineStore.swift          user-defined routines: persistence, CRUD, default seeds
  Routines.swift              Routine model + shuffledForSession()
  Preferences.swift           UserDefaults-backed tuning
  Diagnose.swift              --diagnose live table
  TabProbe.swift              --tabs one-shot browser check
  SelfTest.swift              --self-test cases
  RunningAppLookup.swift      pid → bundle id, cached
  MainThread.swift            onMain() — routes detector callbacks back to the main thread
  URLDisplay.swift            privacy-preserving URL formatting for console and diagnostics
  RemoteControl.swift         --show / --toggle-pause / --quit for when the status item
                               doesn't get a menu bar slot
  SecretInput.swift           secure interactive terminal secret input with echo suppression
  Keychain.swift              device-local macOS Keychain wrapper with typed errors
  NotionSetup.swift           terminal workflow for configuring Notion credentials
  NotionClient.swift          API client pushing completed sessions to Notion
  SessionLogger.swift         owner-only (0700/0600) session history and atomic sync queue
  SessionRecord.swift         session completion data model (Codable)
```

Full Xcode is **not** needed — `swiftc` and the SwiftUI/AppKit SDKs in CommandLineTools are
sufficient, and installing Xcode would only restore SwiftPM, which this project doesn't use.

---

## Credential Security & Local Data Storage

MoveBreak enforces strict credential boundaries and owner-only local permissions to protect personal session and exercise completion data:

### Secrets vs. Non-Secret Configuration

- **Integration Secrets (Keychain):** API credentials (such as the Notion integration token or future Groundwork tokens) are stored exclusively in the macOS Keychain under service `com.mike.MoveBreak.notion` and account `integrationToken`. Items use the `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` accessibility class, ensuring they remain device-local (never synced to iCloud Keychain) and accessible across desktop screen locks. Secrets are never accepted as command-line arguments, never written to `UserDefaults`, and omitted from all logs and error diagnostics.
- **Interactive Secret Entry (`SecretInput`):** Configured via `MoveBreak --configure-notion`. Terminal echo (`ECHO`) is disabled during interactive input, and signal handlers guarantee terminal attributes are restored even if interrupted via `SIGINT` (Ctrl+C), `SIGTERM`, or error. Piped/non-interactive stdin continues to be supported for testing without echoing or logging token values.
- **Non-Secret Configuration (`UserDefaults`):** Database IDs (`notionDatabaseID`), audio bundle ID sets, and URL pattern matching lists are stored in `UserDefaults` under domain `com.mike.movebreak` with strict normalization, length limits, and numeric bounds validation.

### Local Session Data & Storage Permissions

- **Storage Location:** Local files reside in `~/Library/Application Support/MoveBreak/`.
- **Directory Permissions:** The `MoveBreak` Application Support directory is created and enforced with POSIX permissions `0700` (`drwx------`), restricting access solely to the current user.
- **Session History (`sessions.jsonl`):** Completed exercise routines are recorded in an append-only JSONL format with POSIX permissions `0600` (`-rw-------`).
- **Offline Sync Queue (`pending-sync.json`):** Sessions pending upload are maintained with mode `0600` (`-rw-------`) and updated using atomic replacement (write-to-temporary and `rename`) to prevent corrupt writes on power loss or termination.
- **Startup Hardening:** On initialization, `SessionLogger` tightens existing directory permissions to `0700` and scans contained files to enforce `0600`.
- **Persistence Observability:** Persistence failures to local storage are observable and surfaced directly to callers as typed errors, preventing silent data loss or premature upload attempts.

### Automatic Update Trust Boundary & Code Signing Policy

MoveBreak incorporates a fail-closed automatic update verification pipeline that prevents attacker-supplied, tampered, or mismatched binaries from replacing or executing within the installed application:

- **Provenance & URL Boundaries:** Only official releases from `mkny13/movebreak` are accepted. The asset name must match `MoveBreak.app.zip` and the download URL must be an HTTPS `github.com` endpoint matching `https://github.com/mkny13/movebreak/releases/download/<tag>/MoveBreak.app.zip`. Release tags are strictly validated to prevent directory traversal or malformed strings.
- **Release Asset Digest:** The release asset metadata from GitHub must include a parseable `sha256:` digest (64 hex characters). The downloaded archive is verified against this digest prior to extraction; any digest mismatch immediately deletes the staging folder and fails closed.
- **Isolated Staging & Symlink Containment:** Updates are staged in an app-owned, randomly named directory (`~/Library/Application Support/MoveBreak/Updates/<UUID>/`) with POSIX mode `0700`. The extracted bundle and all internal files are checked to guarantee no symlinks escape the staging directory.
- **Bundle Identity & Version Validation:** The extracted `Info.plist` is inspected to verify that `CFBundleIdentifier` matches `com.mike.movebreak`, `CFBundleExecutable` exists as an executable regular file, and `CFBundleShortVersionString` matches the release tag.
- **Strict Code Signing & Signer Continuity:** The candidate bundle undergoes strict code-signature validation (`/usr/bin/codesign --verify --deep --strict`). Signer continuity is enforced by comparing leaf signing certificates: the candidate bundle must match the exact leaf signing certificate of the currently running app (e.g. `MoveBreak Signing`).
- **Fail-Closed Ad-Hoc Build Behavior:** Local development builds signed ad-hoc (`identity: -`) cannot serve as a trust anchor. Automatic update checks report an actionable message (`automatic installation is disabled: running build is ad-hoc signed (requires "MoveBreak Signing" certificate)`) and refuse to download or stage updates.
- **Subprocess & Execution Boundaries:** All subprocess operations (`/usr/bin/ditto`, `/usr/bin/codesign`, `/usr/bin/xattr`) use fixed absolute executable paths and argument arrays without shell evaluation, protected by bounded execution timeouts. The quarantine flag (`com.apple.quarantine`) is stripped only after every integrity and certificate check has succeeded, and the existing app remains untouched if any step fails.

---

## Integration with Groundwork

MoveBreak is being integrated with [Groundwork](https://github.com/mkny13/groundwork) (rehabilitation and athletic training engine):
- **Desktop HUD & detection:** MoveBreak retains its low-overhead native macOS CoreAudio meeting/video detection and floating overlay HUD (`FloatingPanel`) over Zoom.
- **Clinical intelligence & persistence:** MoveBreak replaces its static catalog (`ExerciseCatalog.swift`) and legacy Notion client (`NotionClient.swift`) with Groundwork's dynamic desk-break session generation and Neon Postgres tracking.
- Tracked in [movebreak#2](https://github.com/mkny13/movebreak/issues/2).

## Automation & Agent Workflows

This repo is managed by [Mahler](https://github.com/mkny13/mahler). See [AGENTS.md](AGENTS.md) for build, verification, and autonomous agent conventions.
