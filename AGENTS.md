# Agent instructions — MoveBreak

Shared conventions for any AI tool (Claude Code, Mahler agents, etc.) working in this repo.
`CLAUDE.md` points here — keep this file as the single source of truth.

## What this is

A macOS menu-bar app (Swift, AppKit + SwiftUI) that detects sedentary sessions (video calls, watched videos) via CoreAudio stream state and browser tab inspection, offering short movement/PT routines in a floating overlay panel.
See [README.md](README.md) for architecture, detection stages, and design notes.

## Build and Verify

```bash
./scripts/build_app.sh
```

- Compiles `Sources/MoveBreak/*.swift` directly with `swiftc` (no Xcode project, no SwiftPM; CommandLineTools is sufficient).
- Automatically executes `./build/MoveBreak --self-test` as part of `build_app.sh`.
- Packages and ad-hoc signs `MoveBreak.app`.

To run self-test directly:
```bash
./build/MoveBreak --self-test
```

## Conventions

- No Xcode project, no SwiftPM manifest, no external dependencies.
- AppKit UI creation must stay on the main thread (see `MainThread.swift` and `FloatingPanel.swift`).
- Tests belong in `SelfTest.swift` or dedicated CLI flags, invoked by `--self-test`.
- Settings persist via `UserDefaults` under `com.mike.movebreak` (see `Preferences.swift`).
- `build/` and `MoveBreak.app/` are gitignored build artifacts.
