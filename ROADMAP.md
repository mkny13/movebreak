# MoveBreak roadmap

This document is the canonical boundary between shipped MoveBreak behavior and planned
work. [ARCHITECTURE.md](ARCHITECTURE.md) specifies the implementation that exists today;
[README.md](README.md) explains how to use it.

## Shipped today

MoveBreak currently:

- detects meetings and watched video from CoreAudio stream state plus selective browser-tab
  inspection;
- manages a debounced, one-prompt-per-session lifecycle on a serialized background path;
- offers Groundwork-generated routines, with explicitly labeled cached or saved-local fallback,
  in native floating panels;
- lets the user edit those routines locally and records explicitly checked exercises;
- appends completion history locally, then optionally syncs summaries to Notion with a
  best-effort pending queue;
- provides configurable Groundwork transport with strict versioned models, separate origin-bound
  credentials, an atomically persisted labeled offline routine cache, and clinical HUD context; and
- checks GitHub releases through a fail-closed digest, bundle, containment, and signer trust
  boundary.

Groundwork feeds the MoveBreak offer/checklist UI but does not yet receive MoveBreak completions
or provide active persistence. The existing local/Notion completion path remains live through #7.

## Planned Groundwork migration

[Issue #2](https://github.com/mkny13/movebreak/issues/2) is the open umbrella. The first two
backend stages belong to `mkny13/groundwork` even though their coordinating issues are tracked
in this repository; the remaining stages change `mkny13/movebreak`. Issue #5's client-side
infrastructure and HUD wiring are shipped, while completion delivery remains planned.

| Issue | Implementation repository | Depends on | Planned boundary |
|---|---|---|---|
| [#3 — Groundwork routine contract](https://github.com/mkny13/movebreak/issues/3) | `mkny13/groundwork` | — | Authenticated, versioned, read-only routine endpoint and shared wire contract. |
| [#4 — Groundwork completion persistence](https://github.com/mkny13/movebreak/issues/4) | `mkny13/groundwork` | #3 | Atomic, idempotent completion persistence into existing History and load accounting. |
| [#5 — MoveBreak transport and offline cache](https://github.com/mkny13/movebreak/issues/5) | `mkny13/movebreak` | #3 | Native client, separate credentials, strict response models, and labeled cache or bundled fallback; no HUD wiring yet. |
| [#6 — Generated-routine HUD](https://github.com/mkny13/movebreak/issues/6) | `mkny13/movebreak` | #5 | **Shipped:** generated prompt/checklist path preserving IDs, authored order, warnings, provenance, and honest actual-dose capture; no new sync path yet. |
| [#7 — Durable completion sync and Notion retirement](https://github.com/mkny13/movebreak/issues/7) | `mkny13/movebreak` | #4 and #6 | Durable Groundwork outbox and receipts, followed by removal of active Notion paths without deleting historical local data or credentials. |

The dependency shape is #3 → (#4 and #5), #5 → #6, and (#4 and #6) → #7. Thus #4 and
#5 may proceed independently after #3; #7 remains the final cutover.

The native detection pipeline, session lifecycle, main-thread UI boundary, floating-panel
behavior, and local history remain MoveBreak responsibilities throughout this sequence.

## Live components during migration

These are not zombies and must not be removed early:

| Current component | Current role | Migration boundary |
|---|---|---|
| Static exercise catalog | Source of all current exercise content and default routine seeds. | #5 establishes bundled content as a labeled no-cache fallback; #6 displays that fallback alongside the generated path. |
| Local routine store and editor | Source of prompt/menu choices and user customization. | #6 keeps editable saved routines as explicit local fallbacks; no current issue authorizes deleting the editor or saved data. |
| Local routine models and shuffle | Resolve and order all current checklist content. | #6 extends the display/completion models and adds a generated path that preserves server order while retaining existing shuffle behavior for local routines. |
| Local JSONL history | First persistence step for every current completion. | #7 extends records backward-compatibly and keeps old history readable; it does not upload history automatically. |
| Notion client, setup, Keychain item, and pending queue | Optional current remote sync after local append. | They remain active through #5 and #6. Only #7 removes active Notion paths; legacy files and credentials remain untouched. |

Until the owning issue is merged, changes must preserve these components and their tests.
Migration work must label cached or local fallback content honestly and must not present it as
fresh Groundwork clinical validation.

## Completion criteria for the migration

The umbrella is complete only after all five child implementations merge with their
dependency gates satisfied, native and backend tests pass, generated routines retain warnings
and provenance, confirmed completions are locally durable before network I/O, retries are
idempotent, and Groundwork History/analytics reflect the work. Notion retirement occurs last,
without deleting or silently importing legacy data.
