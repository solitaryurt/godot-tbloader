# Phase 1: Per-Document Map History PRD

## Status

Implemented, pending broader validation.

## Date

2026-09-18

## Product area

Radiant Map editor, external `.map` document editing.

## Related documents

- `HISTORY_NAVIGATION_PRD.md`: separate future enhancement for a visible history menu, direct state navigation, saved-state annotations, and explicit confirmation before discarding a historical future.
- `MAP_EDITOR_IMPLEMENTATION.md`: existing editor architecture and history context.
- `tests/map_editor/window_input.md`: current displayed-editor input and performance evidence.

## Summary

Each `MapSession` now owns a bounded linear timeline for its Map document. Undo and redo operate only on the active document, restore native content plus the selection/components/workzone UI envelope, and report the action label through the existing notice. A successful edit after undo applies standard linear-history behavior by truncating that session's redo tail before appending the new action.

Map content history is deliberately separate from Godot scene history. Loader-path changes and mesh bakes continue to use `EditorUndoRedoManager`; Map content transactions do not.

This phase is not the enhanced navigation design in `HISTORY_NAVIGATION_PRD.md`. Phase 1 has one-step undo/redo and conventional automatic redo truncation. The future feature proposes direct state selection and a branch-confirmation UX that preserves the future until the user explicitly chooses to discard it.

## Problem

The previous global editor history interleaved Map actions from multiple documents and scene actions. Undo from document B could mutate document A, and retained callback tokens duplicated ownership concerns between the Godot cursor and Map snapshots. The editor needs document-local history whose cursor, memory, lifecycle, and keyboard routing follow the active `MapSession` without changing scene undo behavior.

## Goals

- Give every open `MapSession` an independent linear undo/redo timeline.
- Restore exact native document state and the relevant editor UI envelope.
- Preserve existing transaction labels and show clear undo/redo/no-action notices.
- Truncate only the originating session's redo tail after a successful new edit.
- Keep Map content actions out of Godot scene history.
- Enforce 128-action, 64 MiB per-session, and 128 MiB editor-wide Map history budgets.
- Release history promptly on document close, epoch replacement, recovery replacement, and plugin shutdown.
- Cover document isolation, restoration, failure/no-op behavior, limits, and scene-history separation.

## Non-goals

- A history toolbar, event list, direct jump, branch tree, or branch preservation.
- Confirmation before replacing redo history. That belongs to `HISTORY_NAVIGATION_PRD.md`.
- Persisting history across editor restart, plugin shutdown, recovery, document close, New, Open, or a native epoch replacement.
- Undoing selection-only, visibility, hidden-brush, grid, camera, pane-layout, or browser state changes.
- Moving loader-path changes or mesh bakes out of Godot scene history.
- Changing `.map` serialization, native edit algorithms, save baselines, or recovery format.

## UX contract

- Ctrl/Cmd+Z undoes one action in the active Map session while a Map grid or camera owns focus.
- Ctrl/Cmd+Shift+Z and Ctrl/Cmd+Y redo one action in that same session.
- A successful move shows `Undid: {label}` or `Redid: {label}` in `notice` through `set_status()`.
- An unavailable move is consumed and shows `Nothing to undo.` or `Nothing to redo.`.
- Text fields, the material browser, file and dirty dialogs, and the entity inspector retain their own key handling.
- Active camera flight blocks ordinary Map shortcuts but still permits history shortcuts so a history command first passes through `cancel_interaction()`.
- Switching tabs changes which session the shortcuts address; it never transfers or merges timelines.
- Undo followed by a successful new content edit silently discards that document's redo tail, matching a standard bounded linear timeline.

## Functional requirements

1. `MapSession` owns one initial state, zero or more labeled actions, and a cursor for its current native epoch.
2. `transact(label, operation, kind)` records exactly one action for a successful content-changing operation and none for a no-op, failed operation, preview, selection-only change, or save.
3. Failed multi-command transactions roll back to their captured starting state before returning failure.
4. Undo restores state `cursor - 1`; redo restores state `cursor + 1`. The cursor moves only after a successful restore.
5. Before a successful append, `transact()` replaces the current state's outgoing UI envelope, truncates all actions/states after the cursor, and appends one after-state.
6. Action labels remain the labels supplied by existing call sites, including `Create map brush`, `Move map selection`, `Edit map UV`, and `Edit map entity property`.
7. Snapshots contain native history state, selected brush IDs, selected point IDs, valid component descriptors, and workzone.
8. Restoration rebinds valid component topology, prunes invalid selection, and emits the normal session change notification. Hidden IDs and visibility filters are not part of the history envelope.
9. An epoch mismatch or externally changed current native state reinitializes the session timeline at the current state rather than applying stale history.
10. Map actions never register with `EditorUndoRedoManager.GLOBAL_HISTORY`. Loader path and bake actions remain scene-history operations.
11. Limits are enforced after action recording: at most 128 actions and 64 MiB per session, then at most 128 MiB across all retained sessions.
12. Eviction preserves the current state and a contiguous navigable range. It removes the oldest past edge when possible, or the farthest redo edge when the cursor is at the low edge.
13. The current state is pinned document ownership, not optional history. If one
    current state exceeds the byte limit, or the sum of current states from open
    documents exceeds the editor-wide limit, all optional actions may be evicted
    while accounting remains above the soft limit; enforcement must never close
    documents or discard their current content.
13. Closing or disposing a session retires action metadata, clears states, disconnects signals, and releases cache references. Plugin shutdown and recovery replacement dispose all sessions.

## Architecture/data model

`map_session.gd` stores:

```text
_history_states: [{ id, snapshot, bytes }, ...]
_history_actions: [MapAction, ...]
_history_cursor: 0..action_count
_history_epoch: native document epoch
_history_next_state_id: monotonically increasing session-local ID
_history_retained_bytes: current logical retained-byte charge

MapAction:
  session
  label
  sequence                 # plugin-wide eviction order
  before_state_id
  after_state_id
  bytes
```

There is always one more state than action in a non-empty initialized timeline. State IDs are stable within a session; `history_navigate_state()` exists as a low-level restore primitive but Phase 1 exposes no direct-navigation UI.

Each snapshot is the dictionary returned by `capture()`: a native `TBMapDocumentState` plus the UI envelope. `_history_recount_bytes()` charges the first native state with `get_retained_bytes()`, later states with `get_additional_retained_bytes(previous)`, and every state with conservative GDScript envelope charges. `MapAction` carries lightweight metadata rather than duplicate before/after state ownership. Legacy fields and `restore()` behavior remain for direct callers but are not the authoritative Phase 1 timeline.

`map_editor.gd` owns policy budgets and listens to `action_recorded`. It first calls the originating session's `history_enforce_limits()`, then evicts the globally oldest eligible sequence until `history_total_bytes()` is within the editor budget. The `sessions` array continues to retain open/background documents independently of history entries.

## Detailed implementation by file

| File / symbol | Implemented responsibility |
|---|---|
| `addons/tbloader/src/editor/map_session.gd` | Adds timeline state/action/cursor/epoch storage; capture, restore, undo, redo, navigation, truncation, eviction, byte accounting, and limit APIs. `transact()` appends locally and truncates redo only after a successful content change. `dispose()` clears history and disconnects signals. |
| `addons/tbloader/src/editor/map_action.gd` | Serves as lightweight labeled transition metadata with sequence and before/after state IDs. `retire()` severs retained references; `restore()` can delegate ID-based restoration and preserves legacy direct-caller handling. |
| `addons/tbloader/src/editor/map_editor.gd::set_session()` | Connects each newly retained session's `action_recorded` signal to editor-level budget enforcement; no longer injects `EditorUndoRedoManager` into sessions. |
| `map_editor.gd::retain_action()` / `history_total_bytes()` | Enforces 128 actions and 64 MiB on the origin, then 128 MiB across sessions using oldest eligible sequence order. |
| `map_editor.gd::route_key()` | Uses `history_undo_name()`, `history_redo_name()`, `history_undo()`, and `history_redo()` for Map-focused shortcuts and existing notices. |
| `map_editor.gd::close_document()` / `shutdown()` / `restore_recovery()` | Relies on `MapSession.dispose()` instead of retaining or retiring global callback tokens. |
| `map_editor.gd::update_loader_path()` / `commit_bake()` | Remain on Godot scene history and do not enter or move Map timelines. |
| `tests/map_editor/editor_suite.gd` | Replaces global Map-history assumptions; tests independent sessions, labels/notices, restoration, redo truncation, no-op/failure atomicity, lifecycle, budgets, and scene-history isolation. |
| `tests/map_editor/window_input_observer.gd` | Reports the real active session action count/cursor rather than global-history state for displayed input assertions. |

No native implementation change is required: existing `TBMapDocument.capture_history_state()`, `restore_history_state()`, `is_history_state_current()`, epoch/generation checks, and retained-byte methods are reused.

## Edge cases

- A transaction that reports success but leaves the native state unchanged emits the normal refresh notification but records no action and does not truncate redo.
- A failed operation records nothing; if it partially changed native state, the transaction restores the before snapshot or emits the fatal rollback notice.
- Selection/components/workzone changed between content actions are captured as the current state's outgoing envelope before append.
- Invalid component descriptors are excluded during capture and pruned/rebound during restore.
- Undo at the first state and redo at the tip leave content/cursor unchanged and produce the corresponding `Nothing to...` notice through the router.
- A restore failure leaves the cursor unchanged and reports the native error.
- Epoch replacement or direct out-of-band document mutation invalidates the old timeline and establishes a new initial state at current content.
- Budget eviction at a historical cursor may remove far-future redo entries when no older past action can be removed; current content remains retained.
- A background session remains open, dirty-reportable, and saveable even if all eligible history around it is evicted.
- Closing a document must release weakly observed action metadata; stale actions cannot redirect restoration to another session.

## Accessibility/platform

- This phase adds no control. Existing keyboard routing and notice text provide the user-visible contract.
- Ctrl is accepted on Linux/Windows and Command through `meta_pressed` on macOS; Ctrl+Y remains available in addition to Ctrl/Cmd+Shift+Z.
- Text editing and modal surfaces are explicitly excluded from Map shortcut interception.
- The timeline and native restoration APIs are platform-neutral. Existing Linux editor and displayed X11/XWayland harnesses remain the release gate; this phase makes no broader platform claim.

## Performance/memory

- One-step undo/redo performs one native state restore and one normal session refresh.
- Each retained native state is stored once in the session timeline; transition metadata does not own duplicate snapshots.
- Limits default to 128 actions, 64 MiB per session, and 128 MiB across the editor. Tests may temporarily lower these values to force eviction.
- Byte limits are soft when pinned current document states alone exceed them. The
  invariant is that no evictable history remains over budget, not that open
  document ownership is destroyed to force the counter below its threshold.
- Byte accounting includes native retained/additional bytes and conservative charges for dictionaries, packed ID arrays, component arrays/dictionaries/entries, strings, and workzone.
- Limit scans are bounded by open session count and at most 128 retained actions per session under the action cap.
- Eviction and disposal call `retire()` and remove state references immediately; document/cache ownership remains independent.

## Test plan

- Run `tests/map_editor/editor_suite.gd` through the existing `editor`, `toolbar`, and `ui` harness paths.
- Verify two interleaved sessions retain independent action names, cursors, content, selection, and notices across tab switches.
- Verify Ctrl/Cmd+Z, Ctrl/Cmd+Shift+Z, and Ctrl/Cmd+Y operate on only the focused active session.
- Verify a successful post-undo edit truncates only that session's redo tail and leaves another session's cursor unchanged.
- Verify failed, no-op, canceled, degenerate, and focus-lost gestures add no action; failed multi-command work is atomic.
- Verify geometry, material, UV, entity, clip, merge, clone, paste, delete, rotate, and component transaction paths restore exact content and required envelopes through existing editor coverage.
- Lower action/session/editor budgets and assert contiguous retention, current-state survival, deterministic cross-session eviction, bounded byte totals, and released actions.
- Close a session and use a weak reference to prove retained action metadata is released; also cover recovery replacement and shutdown.
- Undo/redo loader-path and bake scene actions and assert Map action count/cursor do not move.
- Run the genuine displayed-input journey in `tests/map_editor/window_input_runner.py`; observer `history` and `actions` must follow the active session during real drag/undo/redo cycles.
- Retain native document tests for exact state restore, epoch rejection, dirty-baseline behavior, stable IDs, and retained-byte accounting.

## Acceptance criteria

1. Interleaved edits in documents A and B create independent labels and cursors; undo in B cannot change A and vice versa.
2. Undo/redo restores exact canonical content, stable IDs, selected brush/point IDs, valid components, and workzone.
3. Successful undo/redo shows the exact transaction label; exhausted history shows `Nothing to undo.` or `Nothing to redo.`.
4. After undo, a successful new edit removes only that session's redo entries and appends one new labeled action.
5. Failed, no-op, canceled, preview-only, and selection-only work neither appends history nor truncates redo.
6. Map content actions are absent from Godot global scene history; loader path and bake undo/redo leave Map count/cursor unchanged.
7. Default limits are 128 actions, 64 MiB per session, and 128 MiB editor-wide, with current state and a contiguous range retained under forced eviction.
8. Close, recovery replacement, epoch replacement, and shutdown release or invalidate the applicable history without affecting other live sessions or Godot scene history.
9. Existing save/dirty/recovery behavior remains correct while moving between retained states.
10. Editor, native, and displayed-input suites pass without new engine/script diagnostics.

## Rollout/dependencies

- Land the current GDScript and test changes together; no data migration, native API addition, feature flag, or recovery-version change is required.
- Validate first with the pinned editor suites, then the displayed Linux input journey and forced-budget tests.
- Keep `HISTORY_NAVIGATION_PRD.md` unimplemented until Phase 1 is stable. Its direct navigation and explicit branch confirmation must build on this timeline without changing Phase 1's documented current behavior retroactively.
- Rollback is code-only because history is transient and never serialized.

## Open questions/decisions

- **Decision:** Phase 1 uses conventional automatic redo truncation after a successful new edit.
- **Decision:** direct navigation and branch confirmation remain a separate future feature in `HISTORY_NAVIGATION_PRD.md`.
- **Decision:** native `is_dirty()` remains authoritative; cursor position does not imply dirty state.
- **Decision:** hidden IDs, visibility filters, camera/view state, and grid are not history-envelope fields.
- **Decision:** map history is session-local; Godot history remains authoritative only for scene operations.
- **Open validation:** run the complete pinned editor and displayed-input matrix against the implemented changes before changing status to fully validated.
- **Open validation:** confirm retained-byte behavior on representative large maps under repeated cross-session eviction, including allocator/cache observations that logical byte counters cannot measure.
