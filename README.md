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
```

Prints a live table of every process holding an audio stream (pid · bundle id · in · out),
the resolved browser tab URLs and which list they matched, and the final verdict. Redraws
whenever anything observable changes.

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

All lists live in `UserDefaults` and override the built-in defaults wholesale:

```bash
defaults write com.mike.movebreak musicPatterns -array \
    "relisten.net" "phish.in" "siriusxm.com" "nugs.net" "archive.org/details"

defaults write com.mike.movebreak promptTimeout -float 45
defaults delete com.mike.movebreak musicPatterns    # back to defaults
```

Keys: `meetingApps`, `nativePlayers`, `browsers`, `ignoredApps`, `videoPatterns`,
`musicPatterns`, `pollInterval`, `debouncePolls`, `sessionEndGrace`, `declineCooldown`,
`timeoutCooldown`, `promptTimeout`, `tabCacheLifetime`. See `Preferences.swift`.

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
  RemoteControl.swift         --show / --toggle-pause / --quit for when the status item
                               doesn't get a menu bar slot
```

Full Xcode is **not** needed — `swiftc` and the SwiftUI/AppKit SDKs in CommandLineTools are
sufficient, and installing Xcode would only restore SwiftPM, which this project doesn't use.
