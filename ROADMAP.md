# MoveBreak roadmap

This document is the canonical boundary between shipped MoveBreak behavior and planned
work. [ARCHITECTURE.md](ARCHITECTURE.md) specifies the implementation that exists today;
[README.md](README.md) explains how to use it.

## Shipped today

MoveBreak currently:

- detects meetings and watched video from CoreAudio stream state plus selective browser-tab
  inspection;
- manages a debounced, one-prompt-per-session lifecycle on a serialized background path;
- offers locally saved routines from a bundled exercise catalog in native floating panels;
- lets the user edit those routines locally and records explicitly checked exercises;
- appends completion history locally, then optionally syncs summaries to Notion with a
  best-effort pending queue; and
- checks GitHub releases through a fail-closed digest, bundle, containment, and signer trust
  boundary.

Groundwork does not currently generate MoveBreak routines, receive MoveBreak completions,
or provide MoveBreak's active persistence. Any prose describing those behaviors is future
state until its implementation issue merges.

## Active Groundwork migration

[Issue #2](https://github.com/mkny13/movebreak/issues/2) is the umbrella. Its child work is
ordered by contract and dependency:

1. [#3 — Groundwork routine contract](https://github.com/mkny13/movebreak/issues/3): add
   the authenticated, versioned, read-only routine endpoint in Groundwork.
2. [#4 — Groundwork completion persistence](https://github.com/mkny13/movebreak/issues/4):
   add atomic and idempotent completion persistence, dependent on #3.
3. [#5 — MoveBreak transport and offline cache](https://github.com/mkny13/movebreak/issues/5):
   add the native client, separate credentials, strict response models, and labeled cache or
   bundled fallback, dependent on #3.
4. [#6 — Generated-routine HUD](https://github.com/mkny13/movebreak/issues/6): preserve
   clinical IDs, authored order, warnings, provenance, and honest actual-dose capture in the
   floating UI, dependent on #5.
5. [#7 — Durable completion sync and Notion retirement](https://github.com/mkny13/movebreak/issues/7):
   introduce a durable Groundwork outbox, connect completion receipts, and remove active
   Notion code paths without deleting historical local data, dependent on #4 and #6.

The native detection pipeline, session lifecycle, main-thread UI boundary, floating-panel
behavior, and local history remain MoveBreak responsibilities throughout this sequence.

## Live components during migration

These are not zombies and must not be removed early:

| Current component | Current role | Migration boundary |
|---|---|---|
| Static exercise catalog | Source of all current exercise content and default routine seeds. | #5 and #6 require bundled content to remain as a clearly labeled offline/local fallback. |
| Local routine store and editor | Source of prompt/menu choices and user customization. | #6 keeps editable saved routines as explicit local fallbacks; no current issue authorizes deleting the editor or saved data. |
| Local routine models and shuffle | Resolve and order all current checklist content. | #6 adds a generated path that preserves server order while retaining existing shuffle behavior for local routines. |
| Local JSONL history | First persistence step for every current completion. | #7 extends records backward-compatibly and keeps old history readable; it does not upload history automatically. |
| Notion client, setup, Keychain item, and pending queue | Optional current remote sync after local append. | They remain active through #5 and #6. Only #7 removes active Notion paths; legacy files and credentials remain untouched. |

Until the owning issue is merged, changes must preserve these components and their tests.
Migration work must label cached or local fallback content honestly and must not present it as
fresh Groundwork clinical validation.

## Completion criteria for the migration

The umbrella is complete only after all five child implementations merge in dependency
order, native and backend tests pass, generated routines retain warnings and provenance,
confirmed completions are locally durable before network I/O, retries are idempotent, and
Groundwork History/analytics reflect the work. Notion retirement occurs last, without
deleting or silently importing legacy data.
