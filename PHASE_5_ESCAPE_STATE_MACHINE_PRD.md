# Phase 5: Escape State Machine PRD

**Status:** Implementation-ready proposal  
**Date:** 2026-09-18  
**Product area:** Radiant Map editor input and interaction lifecycle  
**Related documents:** `MAP_EDITOR_PRD.md`, `MAP_EDITOR_IMPLEMENTATION.md`, `MAP_EDITOR_UI_IMPLEMENTATION.md`, `HISTORY_NAVIGATION_PRD.md`, `tests/map_editor/window_input.md`

## Summary

Replace the current distributed Escape handling with one authoritative
`map_editor.gd::handle_escape() -> bool` state machine. One non-repeated Escape
keypress consumes at most one visible interaction layer, in a fixed order. When
no Radiant state can be reduced, it returns `false` so Godot can handle Escape.

This is a focused routing change. Lifecycle cancellation remains broad and is
not redefined as repeated Escape handling.

## Problem

Escape is currently handled in both `map_editor.gd::route_key()` and
`camera_view.gd::_gui_input()`. The editor router directly reads view internals
such as `graph.gesture` and `camera.camera_gesture`; camera-local handling covers
some, but not all, camera states. The current final branch also consumes Escape
by calling an empty selection operation even when there is nothing to clear.

As a result, precedence is implicit, simultaneous states can be cleared too
broadly, captured mouse handling differs from gesture handling, and an idle
Escape does not reliably reach Godot. Component selection, clip staging, layout
maximization, and editor-owned popups also have no complete layered contract.

## Goals

- Make Escape behavior deterministic and centralized.
- Consume exactly one state layer per keypress.
- Preserve native text-edit and Godot behavior outside an active Radiant layer.
- Give graph and camera views semantic query/cancel methods instead of exposing
  their state variables to the host.
- Keep focus-loss, tab-switch, document-switch, dialog-open, shutdown, and other
  lifecycle cancellation broad and safe.
- Exhaustively test every state, precedence pair, and no-op boundary.

## Non-goals

- Changing mouse gestures, tool shortcuts, selection rules, undo history, or
  document content.
- Making Escape undo a completed map transaction.
- Treating `cancel_interaction()` as a user-visible state stack.
- Closing arbitrary Godot editor windows not owned by Radiant.
- Overriding `LineEdit`, `TextEdit`, spin-box editors, search fields, or other
  text controls' native Escape behavior.
- Adding a configurable Escape order or a new shortcut preference.

## UX Contract

For each non-echo Escape keypress, close or clear the first applicable layer:

1. Topmost Radiant-owned popup or dialog.
2. Fly/captured navigation.
3. Active graph or camera gesture.
4. Maximized view layout, restoring panes from the current `view_layout`.
5. Staged cut points/plane/preview.
6. Component selection, retaining primitive brush and point-entity selection.
7. Brush and point-entity selection together.
8. A non-Brush tool, returning to **Brush**.
9. Nothing: return `false` and leave the key available to Godot.

Every successful step returns `true`, requests only the refresh needed by that
step, and does not continue to a lower layer. Repeated Escape presses therefore
peel visible state predictably. Key-repeat events never advance the stack.

If a text-editing control owns focus, Radiant does not enter this state machine.
The control or its containing standard Godot popup retains native Escape,
composition, completion, and edit-revert behavior. A standard popup may close
itself through Godot; Radiant must not also clear the next layer from the same
event.

## Functional Requirements

### Central routing

- Add `handle_escape() -> bool` to `map_editor.gd`; it is the sole coordinator
  for user-initiated Escape state reduction.
- Central `map_editor.gd::_input()` is the sole owner of a pressed, non-echo,
  unmodified `KEY_ESCAPE`. After native popup and protected text-input guards, it
  calls `handle_escape()` while the Radiant main screen owns the relevant focus
  context. No pane `_gui_input()` path independently routes Escape.
- `camera_view.gd::_gui_input()` must stop implementing a parallel Escape branch.
  Other non-Escape keys may continue to delegate to `host.route_key()`.
- `orientation_gizmo.gd` must stop implementing or consuming a parallel Escape
  branch. Its active gesture is exposed through the owning view's semantic gesture
  query/cancel API and participates in the central gesture layer.
- If `handle_escape()` returns `true`, `_input()` immediately calls
  `Viewport.set_input_as_handled()` exactly once and returns. If false, no Radiant
  path marks the event handled.
- Modifier+Escape is not a Radiant command and returns false.

### Popup and dialog layer

- Track Radiant-owned transient windows/popups in explicit topmost order rather
  than walking the whole editor tree. Include the entity context `PopupMenu`,
  file and dirty dialogs, entity inspector, layout/file/slot menus, and future
  registered Radiant popups.
- A visible modal or popup closes using its native cancellation method
  (`hide()`, `cancelled` path, or popup-specific close callback) so pending file
  and dirty-dialog state follows the same rules as clicking Cancel.
- Do not invoke a confirmation's accepted action, discard pending operations,
  or close a non-Radiant Godot popup.
- Godot-native popup and protected text processing takes priority. The central
  `_input()` handler runs only after those guards; when it closes a registered
  Radiant popup itself, it marks the event handled immediately and returns, so the
  same event cannot peel a lower layer.

### View state queries

- `graph_view.gd` exposes `has_active_gesture() -> bool` and
  `cancel_active_gesture() -> bool`. The cancel method returns false without
  mutation when idle; otherwise it performs the current preview-safe `cancel()`
  work and returns true.
- `camera_view.gd` exposes `has_captured_navigation() -> bool`,
  `stop_captured_navigation() -> bool`, `has_active_gesture() -> bool`, and
  `cancel_active_gesture() -> bool`.
- Captured navigation includes `flying`, an active RMB capture sequence, or
  `Input.mouse_mode == MOUSE_MODE_CAPTURED` owned by that camera. Stopping it
  releases capture, held movement keys, RMB state, selection painting, and the
  crosshair, but does not clear selection, cut state, layout, or tool.
- Camera gestures include `camera_gesture`, `ctrl_gesture`, and
  `godot_navigation`; their cancel method clears disposable mutation previews
  and gesture-local fields without stopping a separate fly state.
- If multiple views report the same layer, cancel the focused view first, then
  the active graph, then the first visible matching view in stable slot order.
  One Escape cancels one view only.
- The host does not read `gesture`, `camera_gesture`, `ctrl_gesture`,
  `godot_navigation`, `flying`, or RMB internals when making Escape decisions.

### Layout, cut, selection, and tool layers

- Maximization is exactly Phase 4's `maximized_slot >= 0` state. Escape calls the
  idempotent `restore_panes()`, which sets `maximized_slot = -1` and derives normal
  visibility from the current `view_layout`. There is no pre-maximize workspace
  token.
- Escape restoration never restores slot types, active-slot/focus snapshots,
  splitter snapshots, or pane/view state. Those values remain live and untouched
  during maximization under Phase 4's visibility-only contract. The restore is a
  transient view change and creates no map history.
- Staged cut exists when `cut_points`, `cut_plane_points`, clip flip, or a
  cut-owned mutation preview is non-default. Escape calls `clear_cut_state()`
  but retains the Cut tool and all selection.
- Component Escape clears only `session.components`, synchronizes selection
  generation, and emits one `selection` change. It retains `session.selected`
  and `session.points` exactly.
- Primitive Escape calls `session.select(PackedInt64Array(),
  PackedInt64Array())`, clearing brush and point selection together.
- Tool Escape calls `set_tool("Brush")`. It occurs only after all prior layers
  are absent, so `set_tool()`'s broad internal cancellation must be a no-op with
  respect to higher layers at this point.
- Idle Escape performs no selection notification, redraw, status rewrite,
  revision change, or history change.

### Lifecycle separation

- Keep `cancel_interaction()` as the broad safety operation. It cancels all graph
  gestures, all camera gestures/navigation, all mutation previews, and capture
  in one call.
- Focus loss, application/window focus loss, hidden/suspended panes, slot or tab
  replacement, document replacement, undo/redo preparation, plugin exit,
  shutdown, and recovery continue to call broad cancellation.
- Broad lifecycle cancellation does not restore a maximized layout, clear
  selection, clear staged cut data unless the existing caller explicitly does
  so, or change the current tool.
- Never implement lifecycle behavior by looping over `handle_escape()`.

## Architecture And Data Model

The coordinator owns ordering; views own interpretation of their local state.
No document/native state is added.

`map_editor.gd` adds:

```gdscript
var _radiant_popup_stack: Array[WeakRef] = []

func handle_escape() -> bool
func register_escape_popup(popup: Window) -> void
func unregister_escape_popup(popup: Window) -> void
func close_top_escape_popup() -> bool
```

Maximize queries use Phase 4's `maximized_slot`; restoration calls Phase 4's
existing `restore_panes()` directly. Phase 5 adds no alternate maximize API.

Popup entries are weak, pruned when invalid/hidden, and ordered by most recent
`about_to_popup`/visibility activation. The stack is editor-global because only
one Radiant popup can be topmost; layout and all lower layers are active-session
state. There is no cross-callback consumed flag: central `_input()` is the only
Radiant Escape owner and marks a consumed event handled before returning.

`handle_escape()` is a straight ordered series of semantic predicates. It must
not call a broad helper before deciding which layer owns the key.

## Detailed Implementation By File / Native API

| File / symbol | Required implementation |
|---|---|
| `addons/tbloader/src/editor/map_editor.gd::_input()` / `route_key()` | Make `_input()` the sole Escape owner after popup/text guards; call `handle_escape()`, mark handled immediately on success, and do not pass Escape through pane routing. Preserve other key routing and remove direct reads of graph/camera gesture fields and the unconditional empty `select()` fallback. |
| `map_editor.gd::handle_escape()` | Implement the nine-step order literally with early returns. Prefer focused/visible views in stable slot order and perform one refresh path per result. |
| `map_editor.gd::_ready()` and popup construction | Register all owned `Window`/`Popup` instances and menu popups; connect visibility/about-to-popup/hide/tree-exit signals without duplicate connections. |
| `map_editor.gd::cancel_interaction()` | Retain broad lifecycle semantics. Use the new view cancellation APIs, iterating every view; do not call `handle_escape()`. |
| `map_editor.gd` layout methods | Reuse Phase 4's `maximized_slot` query and idempotent `restore_panes()`. Escape only clears maximization and reapplies visibility derived from `view_layout`; it never captures or restores workspace state. |
| `addons/tbloader/src/editor/graph_view.gd` | Add semantic gesture query/cancel wrappers. Keep `cancel()` as the broad/idempotent compatibility implementation used by lifecycle paths. |
| `addons/tbloader/src/editor/camera_view.gd` | Add separate captured-navigation and gesture query/cancel methods; remove local Escape handling; keep `cancel_interaction()` as `cancel_active_gesture()` plus `stop_captured_navigation()`. |
| `addons/tbloader/src/editor/orientation_gizmo.gd` | Remove local Escape consumption/routing. Ensure an active gizmo gesture is represented by the owning graph/camera semantic gesture methods so central Escape cancels it exactly once. |
| `addons/tbloader/src/editor/map_session.gd` | Optionally add `clear_components() -> bool` and `clear_primitive_selection() -> bool` to centralize generation/notification correctness. These are transient operations and never enter `transact()`. |
| `tests/map_editor/editor_suite.gd` | Add direct state-machine, ordering, notification, revision/history, multi-view, text-focus, popup, and lifecycle tests. |
| `tests/map_editor/window_input_observer.gd` | Expose read-only popup stack/top popup, `maximized_slot`, cut/component counts, camera/navigation/orientation-gizmo gesture summaries, and last Escape result. |
| `tests/map_editor/window_input_runner.py` | Add real keyboard journeys for popup, capture, gesture, maximization, cut, component, primitive, tool, text field, and idle Godot handoff. |
| Native C++ API | No native API or `.map` format change. |

## Edge Cases

- If a popup disappears between query and close, prune it and retry within the
  popup layer; do not consume unless a visible popup was actually closed.
- A popup above fly mode closes first and leaves capture intact until the next
  Escape.
- Fly mode above an active edit gesture stops capture first; the gesture remains
  for the next Escape. Normal view code should avoid creating this combination,
  but the state machine remains deterministic if it occurs.
- A cut preview owned by an active drag is canceled as a gesture first. Staged
  cut points clear only on a later keypress.
- Component descriptors may be stale; clearing them remains safe and retains
  currently valid primitive IDs without attempting a rebind.
- Hidden/filtered primitive selections are already pruned by session rules;
  Escape does not reveal them.
- An empty Cut tool has no staged-cut layer and falls through to selection, then
  tool fallback on subsequent presses.
- Pane replacement while maximized is already represented by current slot state.
  Escape reveals the current layout with that replacement intact; it never tries
  to resolve or resurrect a replaced view.
- Plugin teardown with a native popup open uses normal broad teardown and popup
  cleanup, not user Escape callbacks.

## Accessibility And Platform

- Use standard Godot `Window`, `PopupMenu`, and text controls so Escape behavior,
  focus restoration, screen-reader roles, and keyboard navigation remain native.
- Closing a popup restores focus to its invoking control or previous Map view;
  it must not move focus to a hidden pane.
- State changes cannot rely on animation or color. Status text may identify
  restored layout or canceled mode but is not required to understand the result.
- Validate embedded single-window dialogs and separate native windows. Linux is
  the existing release gate; macOS/Windows tests must at least cover input routing
  and mouse-capture release when those runners are available.
- IME composition and text-field Escape are never intercepted by Radiant.

## Performance

- Escape checks at most the bounded popup stack and four view slots; no document
  query, serialization, geometry rebuild, file I/O, or native mutation occurs.
- Query methods are O(1). Popup cleanup is O(number of Radiant popups), which is
  small and bounded.
- One consumed layer emits at most one session notification and does not trigger
  duplicate full refreshes.

## Test Plan

### State and precedence matrix

- Test each layer alone and assert exact post-state, return value, notification
  count, focus, mouse mode, document revision, canonical text, and history cursor.
- For every ordered pair of layers, activate both, press Escape once, and assert
  only the higher layer changed. Press again and assert the lower layer changes.
- Test three-layer chains including popup + fly + gesture and cut + components +
  primitive selection.
- Test two matching graph gestures and two matching camera gestures; focused view
  is canceled first and stable slot order breaks ties.

### Input and native behavior

- Send pressed, released, echo, modified, and repeated Escape events through
  `_input` and pane/gizmo `_gui_input` paths; only central `_input()` may consume
  one plain press.
- Start an orientation-gizmo gesture and verify one Escape cancels it through the
  owning view's semantic gesture API, with no second handler and no lower-layer
  change.
- Focus every Radiant `LineEdit`, `TextEdit`, spin-box editor, browser search,
  entity property field, file-dialog filename, and any IME-capable field. Assert
  no lower Radiant layer changes.
- Exercise actual menu/dialog cancellation callbacks, pending New/Open/close
  operations, and nested menu/dialog ordering.
- With no layer active, assert `route_key()`/`handle_escape()` return false and
  the viewport event is not marked handled.

### Lifecycle regression

- For each focus-loss, tab/document switch, layout/slot replacement, undo/redo,
  shutdown, and pane suspension path, create simultaneous gestures in multiple
  views plus capture. Assert broad cancellation clears all unsafe interactions
  in one call without changing selection/tool/layout unexpectedly.
- Run existing editor, toolbar, UI, recovery, window-input, performance, and
  native suites under their strict stderr and timeout policy.

## Acceptance Criteria

1. One central `handle_escape() -> bool` implements the documented order with an
   early return after one changed layer.
2. A visible topmost Radiant popup/dialog closes before fly, gesture, layout,
   cut, selection, or tool state, without accepting its pending action.
3. Fly/captured navigation releases the mouse and held keys on one Escape while
   preserving a simultaneous edit gesture for the next Escape.
4. Graph and camera gestures are queried/canceled only through semantic view
   methods; one matching focused view is canceled per keypress.
5. Maximized layout calls `restore_panes()`, sets `maximized_slot = -1`, and
   derives visibility from current `view_layout` before staged cut is considered;
   it restores no slot-type or focus snapshot.
6. Staged cut clears without leaving Cut or changing primitive selection.
7. Component selection clears while brush and point selection remain byte-for-
   byte unchanged.
8. Brush and point selection clear together on the next applicable Escape.
9. A non-Brush tool returns to Brush only after all higher layers are absent.
10. Idle Escape returns false, performs no redraw/notification/content/history
    mutation, and remains available to Godot.
11. Text controls and browser search retain native Escape behavior and cannot
    peel any Radiant state in the same event.
12. Broad lifecycle cancellation still clears every unsafe interaction at once
    and is not implemented through the Escape state machine.
13. Exhaustive single-layer, pairwise precedence, multi-view, real-input, popup,
    focus, and lifecycle tests pass.

## Dependencies And Rollout

- Implement after Phase 4's `maximized_slot` and `restore_panes()` APIs exist; do
  not introduce a maximize token in this phase.
- Land semantic view query methods and tests, then central routing, then popup
  registration and displayed input tests.
- No data migration, feature flag, or native extension rebuild is required.
- During rollout, retain temporary assertions that no handled Escape reaches two
  branches and that capture ownership is released on focus loss. Remove only
  after displayed tests are stable.

## Decisions

- Escape is a priority state machine, not a broad cancel command.
- Exactly one layer is consumed per physical keypress.
- Popup/dialog cancellation is first; idle fallback belongs to Godot.
- Text controls are an exclusion boundary and retain native semantics.
- Captured navigation and edit gestures are separate layers.
- Component clearing preserves primitive selection.
- Brush and point selection form one primitive-selection layer.
- Cut staging is separate from the Cut tool.
- Lifecycle cancellation remains broad, explicit, and distinct.
- No native document API or persisted state is needed.
