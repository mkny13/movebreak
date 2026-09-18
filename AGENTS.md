# Agent instructions — MoveBreak

This is the canonical repository instruction file; `CLAUDE.md` must remain the one-line
`@AGENTS.md` pointer. Keep this file below 4096 bytes so agents do not load product
documentation on every turn.

MoveBreak is a macOS menu-bar app built with Swift, AppKit, and SwiftUI. Detailed
documentation belongs in these sources of truth:

- [README.md](README.md) for user setup, behavior, tuning, and troubleshooting.
- [ARCHITECTURE.md](ARCHITECTURE.md) for the shipped runtime, data flow, module ownership,
  threading, persistence, and security boundaries.
- [ROADMAP.md](ROADMAP.md) for future work and migration status, including which legacy
  components remain live.

Do not add `DESIGN.md`. Put durable implementation decisions in `ARCHITECTURE.md` and
future-state sequencing in `ROADMAP.md`.

## Build and Verify

```bash
./scripts/build_app.sh
```

- Compiles `Sources/MoveBreak/*.swift` directly with `swiftc`; there is no Xcode project,
  SwiftPM manifest, or external dependency. CommandLineTools is sufficient.
- Runs the agent-context and architecture-inventory checks, compiles the app, verifies local
  documentation links and README CLI coverage, runs the complete `./build/MoveBreak --self-test`
  suite, packages `MoveBreak.app`, and ad-hoc signs it.

To run self-test directly:
```bash
./build/MoveBreak --self-test
```

## Mahler workflow

- [`.mahler/project.toml`](.mahler/project.toml) is the repository contract for verification,
  release, environment isolation, persistent data, rollback, and canary checks.
- Mahler owns job worktrees and `mahler/*` branches. Work only in the assigned worktree; never
  create or remove worktrees, edit the main checkout, or move work between checkouts.
- A job ends only after its changes are committed, the full verify command passes, and the branch
  is pushed. Reporting `STATUS: DONE` with nothing pushed is a failed attempt.
- Agents do not open, watch, merge, or otherwise manage pull requests. Mahler's conductor owns
  those mechanical steps after the agent exits.
- End the final response with exactly one Mahler status line: `STATUS: DONE <summary>`,
  `STATUS: NEEDS-YOU <question>`, `STATUS: BLOCKED <reason>`, or
  `STATUS: YIELDED <handoff>`.

## Conventions

- AppKit UI creation must stay on the main thread (see `MainThread.swift` and `FloatingPanel.swift`).
- Add test cases to the owning `*SelfTests.swift` suite. Register new suites in
  `SelfTest.swift` when necessary, and keep dedicated CLI checks behind explicit flags.
- Settings persist via `UserDefaults` under `com.mike.movebreak` (see `Preferences.swift`).
- `build/` and `MoveBreak.app/` are gitignored build artifacts.
- Update `ARCHITECTURE.md` in the same change when module ownership, runtime data flow,
  threading, persistence, or a trust boundary changes.
- Update `ROADMAP.md` in the same change when shipped/planned status, migration order, or
  the lifetime of a transitional component changes.

## Integrations and accounts

- Groundwork routine generation and durable completion sync are shipped (see
  [movebreak#2](https://github.com/mkny13/movebreak/issues/2) and [ROADMAP.md](ROADMAP.md)).
  Local static routines, editing, and history remain live fallbacks; legacy Notion data is
  preserved but no active Notion setup or request path remains.
- This repo is dual-use (`accounts = ["personal", "work"]`). Git hosting operations must
  use the personal GitHub identity `mkny13`.
