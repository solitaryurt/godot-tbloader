# Enhanced Undo/Redo History Navigation PRD

**Status:** Implementation-ready proposal  
**Date:** 2026-09-13  
**Product area:** Radiant Map editor  
**Target:** The Godot editor addon under `addons/tbloader/`

## 1. Summary

Add one history stack button to the Radiant Map toolbar. Activating it opens a
menu of retained, discrete map-edit events for the active Map document. A user
can select any older or newer event and move directly to that event's resulting
state. Merely navigating never deletes the newer states, so the same menu and
Ctrl+Z/Ctrl+Y can move backward and forward repeatedly.

History is a bounded, cursor-based linear timeline per Map document. Editing
while the cursor is behind the newest retained state is a different operation
from navigation: it creates a branch point. The recommended policy is to block
the first mutation attempt and require an explicit choice to discard the future,
return to the latest state, or cancel. Only the explicit **Edit Here** choice
performs conventional destructive branch truncation.

This feature applies to `.map` document content transactions. Loader path changes
and mesh bakes remain in Godot scene history and are not listed in the Map history
menu.

## 2. Goals

- Make long-distance undo and redo a single, discoverable operation.
- Preserve all retained future events during backward and forward navigation.
- Make the current position, available past, available future, saved baseline,
  and expired range understandable.
- Keep exact native geometry, stable identities, selection, component selection,
  and workzone restoration.
- Preserve current dirty/save, document ownership, recovery, and bounded-memory
  guarantees.
- Prevent accidental loss of a future sequence when editing an older state.
- Keep scene undo isolated from external `.map` content history.

## 3. Non-goals

- A branching history tree, named branches, merging, or recovery of a discarded
  branch.
- History persistence across plugin disable, editor restart, document close, New,
  Open, or a native document epoch replacement.
- Listing scene operations such as **Set TBLoader map path** or **Build TBLoader
  meshes** in the Map menu.
- Undo for view layout, camera, grid, visibility filters, hidden brushes, or
  material-browser navigation.
- Increasing the current history memory limits.
- Changing `.map` serialization, native mutation algorithms, or the atomic-save
  implementation.
- Product analytics or remote telemetry.

## 4. Repository Findings And Constraints

### 4.1 Document and mutation boundary

- `TBMapDocument` is the canonical content owner (`src/map_document.h`,
  `src/map_document.cpp`). Native edit methods build and validate a candidate,
  then `TBMapDocument::commit()` atomically replaces the map and canonical text,
  invalidates caches, increments topology/revision, and emits `map_changed`.
- `TBMapDocument::capture_history_state()` retains the parsed map, canonical text,
  texture-size context, and document epoch in `TBMapDocumentState`.
  `restore_history_state()` rejects another epoch, restores exact map/text/IDs,
  and still advances revision. Revision is therefore an activity counter, not a
  history cursor.
- `TBMapDocumentState::get_retained_bytes()` and
  `get_additional_retained_bytes()` expose native memory accounting. A map may be
  up to 16 MiB of source text and retain substantially more parsed/generated data.
- `map_session.gd::capture()` wraps a native state with selected brush IDs, point
  entity IDs, valid component descriptors, and workzone. `restore()` restores and
  prunes these values. Hidden IDs and visibility filters intentionally survive
  history restoration and are pruned against current geometry.
- `map_session.gd::transact(label, operation, kind)` is the UI mutation boundary.
  It captures before/after, rolls back a failed multi-command operation, omits
  no-ops, and creates one event per completed operation. Gesture motion in
  `graph_view.gd` and `camera_view.gd` is disposable preview; release is the
  transaction. Entity, UV, material, clip, prism, merge, clone, paste, and delete
  paths also converge on `transact()`.
- Existing labels such as **Create map brush**, **Move map selection**, **Edit map
  UV**, and **Edit map entity property** are already suitable menu event names.

### 4.2 Current history architecture

- Today, `map_session.gd::transact()` registers before/after callbacks with the
  plugin's `EditorUndoRedoManager` using global history, `MERGE_DISABLE`, the
  session as custom context, and `commit_action(false)` because the edit is already
  applied.
- `map_action.gd` is a lightweight callback token containing its originating
  session, before/after envelopes, epoch, retained byte estimate, and reporter.
  It refuses to redirect an expired action to another document.
- `map_editor.gd::tokens` strongly retains usable tokens. `retain_action()` applies
  limits of 128 actions and 64 MiB per session and 128 MiB across the plugin,
  retiring oldest payloads. `sessions` separately keeps current documents alive,
  including dirty background documents.
- `map_editor.gd::route_key()` intercepts Ctrl+Z/Y only while a Map graph/camera has
  focus and invokes global history exactly once. Text fields, dialogs, and other
  editor screens keep native Godot routing.
- Global history intentionally allows an undo performed while document B is active
  to mutate originating document A. This is tested in `editor_suite.gd`, but it is
  incompatible with an active-document indexed menu: direct restoration would
  desynchronize the global cursor, while repeated global undo would also replay
  interleaved scene and other-document actions.
- The pinned `UndoRedo` API exposes action count, current action, and action names,
  but `EditorUndoRedoManager` still represents shared ordering. It provides no safe
  selective cursor movement for one external Map document.

### 4.3 Save, dirty, and persistence behavior

- `TBMapDocument::save_map()` writes atomically on POSIX, checks external changes,
  and updates path and baseline only after success. Save does not create a content
  revision or history event.
- `is_dirty()` compares current canonical semantic text with the most recent
  successful baseline. Restoring the saved content clears dirty even though native
  revision increases; restoring another state sets dirty.
- `plugin.gd::_get_unsaved_status()` and `_save_external_data()` delegate to
  `map_editor.gd::unsaved_status()` and `save_all()`, including retained background
  sessions.
- Recovery (`map_editor.gd::store_recovery()` / `restore_recovery()`) stores current
  canonical text or clean paths in `user://tbloader-map-recovery.json`. Recovery
  deliberately creates a new epoch and restores no IDs, selection, binding, or
  history. This must remain true in the first release.
- New/Open create or activate sessions rather than silently replacing dirty tabs.
  Closing a document retires its tokens. Epoch changes make all old snapshots
  invalid.

### 4.4 UI and test conventions

- `map_editor.gd::_ready()` builds an `HFlowContainer` toolbar from grouped flat,
  icon-only controls. `file_menu`, `layout_menu`, and pane menus use `MenuButton`,
  `FlatMenuButton`, tooltips, accessibility names, and `PopupMenu.id_pressed`.
- `icon_button()` supplies matching tooltip and accessibility text for buttons.
  A history control should follow these conventions and use an editor Undo/History
  icon rather than introduce a text button or a new visual group style.
- The strict harness uses a pinned Godot editor and covers native document behavior,
  real editor integration, displayed UI, and genuine X11 input. Relevant files are
  `tests/map_editor/document_suite.gd`, `editor_suite.gd`,
  `window_input_observer.gd`, and `window_input_runner.py`.

## 5. Architecture Decision

### 5.1 Session-owned Map history

Make a session-owned timeline authoritative for `.map` content and stop registering
new Map content actions in `EditorUndoRedoManager.GLOBAL_HISTORY`. Continue using
Godot scene history for `update_loader_path()` and `commit_bake()`.

This is a deliberate change to the prior global-history rule documented in
`MAP_EDITOR_IMPLEMENTATION.md`. It is required because no implementation can both:

1. move one Map document directly to an indexed state,
2. leave unrelated global actions untouched,
3. preserve the selected document's future, and
4. keep the shared Godot history cursor truthful.

Map shortcuts already have a focused routing boundary, so Ctrl+Z/Y in Radiant can
operate on the active session timeline. Outside Radiant, Godot continues to undo
scene/resource work. A background Map document no longer changes because the user
pressed Undo in another document; the user activates its tab before navigating it.

Do not dual-write Map actions to both systems. Dual registration creates two cursors
and makes a direct jump, branch truncation, expiration, and dirty reporting
ambiguous.

### 5.2 Timeline model

For each session and epoch maintain:

```text
states: [S0, S1, ... Sn]
events: [E1, E2, ... En]
cursor: c, where 0 <= c <= n and current document state is Sc

Ei = {
  id: monotonically increasing session-local integer,
  label: String,
  before_state_id: S(i-1),
  after_state_id: Si,
  created_sequence: plugin-wide monotonic integer for eviction ordering,
  retained_bytes: integer
}
```

`S0` is captured when the session/epoch begins. Each state is the existing editor
snapshot envelope from `map_session.gd::capture()`. Store each state once; adjacent
events refer to state IDs rather than each owning duplicate before/after envelopes.
No wall-clock timestamp is required.

The state selected for event `Ei` is its **after** state `Si`. The menu also exposes
**Document opened** / **New document** as `S0`, allowing complete rollback.

Operations are:

- **Undo:** if `c > 0`, restore `S(c-1)` and decrement `c`.
- **Redo:** if `c < n`, restore `S(c+1)` and increment `c`.
- **Navigate to k:** restore `Sk` once and set `c = k`; do not loop through
  intermediate mutations and do not remove any state.
- **Append at tip:** require `c == n`, run one successful non-noop transaction,
  append its after state and event, and set `c = n + 1`.
- **Branch at historical state:** only after explicit confirmation, remove states
  `S(c+1)...Sn` and events `E(c+1)...En`, release them, then permit a new append.
- **Save:** keep states/events/cursor unchanged; update the latest saved-state marker
  after native save succeeds.
- **Epoch replacement:** expire the complete timeline and create a new `S0`.

`TBMapDocument::is_dirty()` remains authoritative. The timeline may track the state
ID at which the latest save succeeded for a **Saved baseline** menu annotation, but
must not infer dirty from cursor position: duplicate canonical states can occur and
the native baseline can change after Save As.

### 5.3 Navigation versus destructive branching

History navigation changes only `cursor` and restores a retained state. It is
non-destructive regardless of distance or direction. Backward navigation is not a
request to abandon redo; forward entries remain selectable immediately.

A content mutation at `c < n` requests a new line of development from an old state.
A linear timeline cannot retain both the old future and the new future without
becoming a history tree, which is out of scope. Therefore:

- The attempted mutation must not run.
- Cancel any disposable gesture preview.
- Show a modal confirmation with **Edit Here**, **Return to Latest**, and **Cancel**.
- **Edit Here** states that it will permanently discard `n - c` newer events. After
  confirmation, truncate the future and leave the user at the historical state; the
  user repeats the edit. Requiring a retry avoids executing a stale captured gesture
  or selection callback after a modal interaction.
- **Return to Latest** restores `Sn`, keeps every event, and requires the user to
  repeat the edit there.
- **Cancel** changes nothing.

Non-content actions are allowed at a historical cursor without a branch: selection,
hide/reveal, filters, camera/view changes, copying, Save/Save As, tab switching, and
inspection. Saving an older state changes the native saved baseline but does not
delete its future; newer states will then normally be dirty.

This policy is intentionally safer than conventional UndoRedo behavior, where
committing after Undo silently clears redo. The destructive behavior exists only
behind the explicit **Edit Here** decision.

## 6. User Stories

- As a mapper, I can open history and jump to the result of a much older brush edit
  without pressing Ctrl+Z repeatedly.
- As a mapper, I can inspect an old state and jump back to the latest state without
  losing any intervening work.
- As a keyboard user, Ctrl+Z and Ctrl+Y move one event around the same cursor shown
  in the menu.
- As a mapper with several Map tabs, I see and navigate only the active document's
  content history.
- As a mapper at an older state, I am warned before an edit would destroy future
  states and can return to the latest state instead.
- As a mapper, I can save any viewed state and dirty status remains accurate while I
  navigate around that baseline.
- As a user of a large map, history remains bounded and the UI explains when old
  states have expired.
- As a screen-reader or keyboard user, I can identify the control, open the menu,
  understand the current state and direction, and activate an event without a mouse.

## 7. UX Specification

### 7.1 Toolbar control

- Add one `MenuButton` in its own standard toolbar group immediately after the file
  command group and before edit modes.
- Use the Godot editor theme's closest history/undo icon; do not add a custom asset
  unless the pinned theme has no suitable icon.
- Tooltip: **Map edit history (Ctrl+Z / Ctrl+Y)**.
- Accessibility name: **Map edit history**.
- Disable the control only when no session is available. With only `S0`, keep it
  enabled so the menu can communicate **No map edits yet**; this is preferable to an
  unexplained disabled icon.
- Rebuild menu content immediately before popup so tab switches, save markers,
  cursor moves, branch truncation, and eviction are current.

### 7.2 Menu content

Use one `PopupMenu`, consistent with existing toolbar menus:

```text
Go back to
  Move map selection                 [most recent older state]
  Create map brush
Current
  Edit map UV                         [checked, disabled]
Go forward to
  Assign map material                 [nearest newer state]
  Edit map entity property
  Latest: Resize map face
```

- Older entries are nearest-first. Newer entries are nearest-first. This minimizes
  pointer travel for the common one-step case.
- The checked, disabled current row names `E[c]`, or **Document opened** / **New
  document** at `S0`, and includes **Saved baseline** when applicable.
- Use separators with labels **Go back to**, **Current**, and **Go forward to**.
  Omit an empty direction section.
- Prefix the newest state with **Latest:** when it is not current.
- If the saved state is retained, suffix its row with **(Saved baseline)**.
- If earlier states expired, include a disabled first row **Earlier history expired**.
  If future states expire due a hard budget while viewing history, include **Some
  newer history expired**.
- If there are no edit events, show disabled **No map edits yet** plus the current
  initial-state row.
- Menu IDs map to immutable state IDs, never array positions. Ignore an activation
  if the session, epoch, or state no longer matches the popup snapshot.
- Selecting the current row is impossible; selecting any other row closes the menu,
  cancels active previews, restores once, refreshes all views/status/tabs, and moves
  focus back to the previously focused Map pane when valid.

### 7.3 Status and branch warning

- While `cursor < tip`, append **History c/n • viewing an older state** to the bottom
  status and expose the same phrase as accessible text on the history control.
- At tip, show **History n/n** only in the history control tooltip/accessibility
  description; do not add persistent status noise.
- The branch dialog title is **Edit from older history?**.
- Dialog body: **You are viewing “{current label}”. Editing here will discard {N}
  newer history event(s).**
- Buttons: **Edit Here**, **Return to Latest**, **Cancel**. **Cancel** is default;
  **Edit Here** is never default.
- After **Edit Here**, show **Future history discarded. Repeat the edit to continue
  from this state.** in the existing notice label.
- On state restore failure or epoch mismatch, do not move the cursor. Retire the
  invalid timeline and report the existing explicit expiration/error style.

### 7.4 Keyboard and accessibility

- Ctrl+Z and Ctrl+Shift+Z/Ctrl+Y retain current meanings but target the active Map
  session timeline while a graph or camera pane has focus.
- Opening and navigating the `MenuButton` must work with Godot's standard keyboard
  menu controls (focus, Enter/Space, arrows, Escape); do not implement a custom drawn
  list.
- Every actionable event exposes its full label to accessibility APIs. Direction and
  saved/current state must not rely on color or icon alone.
- Menu order, labels, and focus restoration must remain usable at editor UI scaling
  and with long translated labels. Use normal PopupMenu truncation/tooltips rather
  than fixed pixel coordinates.
- No new global shortcut is required. A future shortcut to open the stack is a
  separate enhancement to avoid conflicts with Godot editor bindings.

## 8. Functional Requirements

### FR-1 Timeline ownership

Every open Map session owns exactly one timeline for its current native epoch. Tabs
do not share timelines, including tabs that originated from different loaders.

### FR-2 Atomic event recording

Every successful, non-noop `map_session.gd::transact()` at the tip records exactly
one labeled event and one new state. Failure, cancellation, preview, cache rebuild,
save, selection-only changes, and no-op operations record none.

### FR-3 Exact restoration

Navigation restores the existing native state, stable IDs, selected brush/point IDs,
valid component selection, and workzone through `map_session.gd::restore()`. Current
hidden/filter state remains session state and is pruned as it is today.

### FR-4 Cursor consistency

Menu activation, Ctrl+Z, Ctrl+Y, and programmatic tests use the same cursor methods.
After every successful move, the current native state equals `states[c]`. A failed
restore changes neither document nor cursor.

### FR-5 Future preservation

Undo and direct navigation never remove or rewrite events after the cursor. Repeated
back/forward navigation produces exact previously captured canonical text and IDs.

### FR-6 Historical edit guard

All content mutation entry points are guarded centrally before operation execution.
No mutation or history change occurs until the user explicitly truncates future
history and repeats the edit.

### FR-7 Save semantics

Save and Save As preserve timeline shape/cursor. Successful save updates native
baseline/path and the saved-state annotation. Failed or externally conflicted save
changes neither. Undoing/navigating to content equal to the latest baseline is clean;
other content is dirty.

### FR-8 Session lifecycle

New/Open/session close/epoch replacement/plugin teardown release the applicable
timeline without clearing shared Godot scene history. Tab switching preserves each
session's cursor and states.

### FR-9 Memory limits

Keep defaults of 128 events and 64 MiB retained history per session and 128 MiB
across Map sessions. Count each unique state once, using native retained/additional
byte methods; include a conservative estimate for GDScript envelope arrays or
document the native-only estimate in code.

Eviction must:

- never evict the current state;
- retain a contiguous navigable range;
- prefer expiring the oldest state/event at the low edge;
- if the cursor is at the low edge and the hard limit still requires space, expire
  the farthest future state at the high edge;
- expose which direction expired;
- retain the session/current document independently for dirty reporting and Save All;
- release references promptly and never leave selectable dead menu rows.

The 128-event limit counts transitions, so at most 129 states are retained before
byte/global limits apply. Budget-driven expiration is the only navigation-time case
where future states may disappear, and the UI must say so.

### FR-10 Scene history isolation

`map_editor.gd::update_loader_path()` and `commit_bake()` continue to use
`EditorUndoRedoManager` scene history and their existing validation. They do not
move the Map timeline cursor or appear in its menu.

### FR-11 Recovery

Version 1 stores only the currently viewed canonical state using the existing
recovery manifest. On restore, create a new epoch and initial state with no older or
newer history. If shutdown occurs while viewing an older state, that viewed content
is what recovery protects; retained future history is session-memory only.

## 9. Non-functional Requirements

- A direct jump performs one native restore regardless of distance.
- Opening the menu is O(retained events), bounded by 128 per session, and performs no
  native state restore, serialization, file I/O, resource scan, or geometry rebuild.
- The feature must not increase limits on map input, parser work, or snapshot memory.
- No remote calls, analytics, or content logging. Map names, paths, labels, and
  history remain local.
- A restore remains atomic and uses epoch/identity validation. No stale state may be
  redirected to the active/newer document.
- Existing Linux behavior remains the release gate. The history model itself is
  platform-neutral; save limitations on Windows remain unchanged.
- Existing strict test policy remains: bounded processes, empty stderr, no diagnostic
  allowlist, and exact completion markers.

## 10. Likely Implementation Touchpoints

No native API change is expected for the first implementation.

| File / symbol | Expected change |
|---|---|
| `addons/tbloader/src/editor/map_session.gd` | Add state/event storage, epoch, cursor, saved marker, expiration flags, append/navigate/undo/redo/truncate APIs, and a central `can_transact()`/historical-edit signal. Refactor `transact()` to append locally instead of calling `EditorUndoRedoManager`. Initialize `S0` after New/load/import session setup. |
| `addons/tbloader/src/editor/map_action.gd` | Replace or retire the per-global-action callback role. Reuse as a plain event/state metadata type only if that is simpler; remove dual before/after ownership. |
| `addons/tbloader/src/editor/map_editor.gd::_ready()` | Add the grouped history `MenuButton`, popup construction, accessibility text, and branch confirmation dialog. |
| `map_editor.gd::route_key()` | Route Map-focused Ctrl+Z/Y to session cursor methods; keep text/dialog and non-Map routing unchanged. |
| `map_editor.gd::retain_action()` / `tokens` | Replace token-list accounting with unique timeline-state accounting and edge eviction across sessions. Preserve strong `sessions` ownership. |
| `map_editor.gd::set_session()` / `_session_changed()` / `refresh_status()` | Bind timeline signals, refresh menu/status, preserve per-tab cursor, and stop background global-history mutation assumptions. |
| `map_editor.gd::save_path()` / `save_all()` | Mark a retained saved state after successful save without adding or truncating history. |
| `map_editor.gd::close_document()` / `shutdown()` | Release timeline states and dialogs without clearing Godot scene history. |
| `map_editor.gd::store_recovery()` / `restore_recovery()` | Keep current-state-only recovery and initialize a fresh timeline after restore; do not change manifest version solely for this feature. |
| `addons/tbloader/src/editor/graph_view.gd`, `camera_view.gd`, `entity_pane.gd` | Most mutations already use `transact()`. Verify any direct native mutation used only for fixtures/setup is not a user-facing bypass. Gesture attempts behind tip must cancel preview and trigger the central guard. |
| `src/map_document.h/.cpp` | Reuse `capture_history_state`, `restore_history_state`, byte accounting, epoch checks, and dirty baseline semantics unchanged. Add native functionality only if profiling proves envelope accounting or a fingerprint query is necessary. |
| `tests/map_editor/editor_suite.gd` | Replace global map-history assertions with per-session cursor tests; add menu, jump, branch guard, save, eviction, tabs, focus, and scene-history isolation coverage. |
| `tests/map_editor/window_input_observer.gd` | Expose read-only active timeline labels/count/cursor/menu state for external input assertions. |
| `tests/map_editor/window_input_runner.py` | Add genuine keyboard/mouse stack-menu navigation and branch-dialog journeys. |
| `tests/map_editor/document_suite.gd` | Retain native restore/dirty/epoch/large-map tests; add only any native API coverage introduced after profiling. |

The implementation must audit all calls to `TBMapDocument` mutation methods. Direct
calls in tests and session initialization are acceptable; interactive calls must pass
through `transact()` or an equally central guarded transaction.

## 11. Acceptance Criteria

1. After five distinct content edits, the menu lists all five labels plus the initial
   state, identifies the current/latest state, and exposes no scene bake/path action.
2. Selecting the result of event 2 restores its exact canonical text, identities,
   selection envelope, and workzone with cursor 2 while events 3-5 remain listed as
   forward history.
3. Selecting event 5 after criterion 2 restores the exact tip without recreating any
   event or changing history count.
4. Ctrl+Z and Ctrl+Y move one state on the same active-session cursor and update menu,
   toolbar accessibility description, viewport, tab dirty marker, and status.
5. An attempted geometry/material/UV/entity mutation at event 2 performs no native
   commit and opens the three-choice branch dialog. Cancel preserves all states.
6. **Return to Latest** restores event 5 and preserves all states. **Edit Here** at
   event 2 discards events 3-5 only after confirmation; no edit occurs until retried.
7. Retried editing after **Edit Here** creates one event 3 with the new label/state,
   and the discarded events cannot be selected or invoked.
8. Save at an older state preserves forward history, moves the saved marker, clears
   dirty there, and makes a different forward state dirty. Save failure/conflict
   changes no marker, cursor, path, baseline, or history.
9. Selection/hide/filter/view changes at an older state do not trigger branch
   confirmation or truncate future. A later state restore prunes selection against
   current hidden/filter state exactly as existing restoration does.
10. Switching Map tabs shows independent labels and cursors. Undo in one tab cannot
    mutate another tab.
11. Loader-path and bake actions still undo/redo through scene history and do not
    alter active Map cursor/count.
12. No-op, canceled, failed, and focus-lost previews create no event and do not move
    the cursor.
13. Per-session action/byte and global byte limits can be lowered in tests to force
    both backward and future-edge expiration. Current content survives, retained
    range is contiguous, dead states are absent from the menu, and dirty background
    sessions remain Save All eligible.
14. Epoch replacement and plugin teardown release old state payloads. Recovery
    restores only the currently viewed content as a fresh, history-empty epoch and
    never overwrites the source automatically.
15. Menu activation works by keyboard and genuine X11 pointer input; focus returns to
    the Map pane, Escape cancels, and accessible names identify current/direction/
    saved state without relying on color.
16. The existing native, editor, displayed UI, and fresh-process recovery suites pass
    under their strict stderr/error/timeout policy.

## 12. Testing Strategy

### 12.1 Session/model tests in the real editor suite

- Build deterministic timelines and assert every cursor transition and label.
- Jump multiple states in one restore and assert native revision increments once.
- Compare exported text and snapshot identities at every state.
- Cover initial state, tip, no history, duplicate-content states, invalid state IDs,
  epoch mismatch, and restore failure atomicity.
- Cover each transaction family and verify the historical-edit guard is central.
- Save at initial/middle/tip states; Save As; failed write; external conflict; undo
  to semantic baseline; duplicate canonical content.
- Verify separate sessions, tab switching, close, dirty background Save All, scene
  sessions, and scene history isolation.
- Force count/session/global budgets with the existing adjustable limit variables;
  inspect weak references after eviction and teardown.

### 12.2 UI integration tests

- Inspect toolbar grouping, icon-only style, tooltip, accessibility name, menu order,
  checked/disabled current row, saved/latest/expired labels, and immutable IDs.
- Trigger popup selection handlers rather than only calling model methods.
- Verify status/notice text, branch dialog defaults and all three outcomes.
- Verify focus routing: graph/camera versus LineEdit/TextEdit/browser/dialog and
  Map-hidden versus active main screen.

### 12.3 Display and OS-input tests

- Extend the displayed journey for menu rendering at initial, historical, and future
  states and branch-dialog rendering.
- Extend `window_input_runner.py` to click the toolbar stack, choose a distant event,
  perform real Ctrl+Y, attempt an edit, cancel, and return to latest.
- Preserve read-only observer discipline; input enters through XTest in that suite.

### 12.4 Native and performance regression

- Keep `document_suite.gd` coverage for Tohunga retained bytes, exact history restore,
  epoch rejection, stable identities, revision, and dirty baseline.
- Measure menu population and direct jump in the existing large-map fixture. The
  acceptance is one restore per jump and no menu-open restore/I/O, not an ungrounded
  frame-time promise.
- Run the existing native ASan/UBSan/leak suite to ensure no change in native state
  ownership if native code is touched.

## 13. Risks And Mitigations

| Risk | Mitigation |
|---|---|
| Moving Map content out of global history changes established behavior. | Keep focused Ctrl+Z/Y, provide per-tab history, update tests/documentation, and leave all scene actions global. Do not ship dual cursors. |
| An interactive mutation bypasses the branch guard. | Audit every native mutator and enforce append/guard in `transact()`; add one test per transaction family. |
| Popup state becomes stale during tab/epoch change. | Bind IDs to session+epoch+state ID and reject stale activation atomically. |
| Deferred branch confirmation executes stale gesture data. | Never auto-replay the attempted edit; cancel preview and require user retry. |
| Snapshot memory is double-counted or retained after eviction. | Store each state once, use native additional-byte accounting, test weak references and both edge-eviction directions. |
| Future expiration appears to violate preservation. | Preserve future for all navigation; allow loss only at documented hard limits and show an explicit disabled expiration row/status. |
| Saved marker and dirty state diverge. | Keep native canonical-vs-baseline comparison authoritative; marker is annotation only and changes only on successful save. |
| Recovery surprises a user viewing old history. | Document current-state-only recovery, checkpoint the viewed text, and never imply future survives restart. |
| Long menus or translated labels overflow. | Retained count is bounded; use standard PopupMenu sizing/truncation and full item tooltip/accessibility text. |

## 14. Telemetry

Do not add telemetry. This repository has no analytics pipeline, the addon edits local
project content, and event labels/paths may reveal project details. Quality should be
measured through deterministic tests and optional local profiling only.

## 15. Phased Delivery

### Phase 0: Compatibility spike

- Prototype a session timeline with existing native state envelopes and direct jump.
- Confirm pinned Godot PopupMenu accessibility/focus behavior and editor theme icon.
- Inventory all interactive native mutations and verify unique-state byte accounting.
- Exit criterion: no unresolved dual/global cursor requirement and a measured direct
  restore on the Tohunga fixture.

### Phase 1: Timeline core and shortcut migration

- Implement state/event/cursor model, initial state, append, undo/redo, direct jump,
  epoch retirement, signals, and unique-state budgets.
- Route focused Map Ctrl+Z/Y locally; stop global registration of Map content events.
- Preserve scene history unchanged.
- Exit criterion: headless editor model, dirty/save, tabs, scene isolation, eviction,
  and native regression tests pass.

### Phase 2: Toolbar menu and accessibility

- Add the stack MenuButton, dynamic sections, saved/latest/expired annotations,
  status, stale-ID rejection, and focus restoration.
- Exit criterion: editor and displayed UI tests cover mouse and keyboard menu jumps.

### Phase 3: Historical edit safety

- Add central mutation guard, dialog, preview cancellation, explicit truncation,
  retry policy, and all transaction-family tests.
- Exit criterion: no tested mutation can silently clear future history.

### Phase 4: Hardening and release gate

- Extend genuine X11 journey, large-map measurements, recovery/teardown tests, and
  user-facing documentation of per-document history and restart limits.
- Run native, document, editor, displayed UI, fresh-process recovery, and OS-input
  suites with existing strict policies.
- Exit criterion: all acceptance criteria pass with no diagnostic allowlists and no
  unexplained retained snapshot references.

## 16. Open Implementation Validation

These are spike validations, not product ambiguities:

- Select the exact editor theme icon available in the pinned engine.
- Determine whether plain GDScript envelope memory needs a fixed conservative charge
  beyond native `TBMapDocumentState` accounting; document the chosen estimate.
- Verify standard PopupMenu item tooltips expose untruncated labels to assistive
  technology in the pinned editor. If not, include the full text in accessibility
  descriptions rather than building a custom menu.

The product decisions are otherwise fixed: active-session linear history, direct
non-destructive cursor navigation, explicit destructive branch confirmation,
bounded in-memory retention, current-state-only recovery, and scene-history
isolation.
