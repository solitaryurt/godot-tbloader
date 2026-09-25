# Phase 3: Map File Menu Commands PRD

## Status

Implementation-ready.

## Date

2026-09-19.

## Product area

Radiant Map editor toolbar command routing in `addons/tbloader/src/editor/`.

## Related documents

- `PHASE_1_PER_DOCUMENT_HISTORY_PRD.md`
- `PHASE_2_ACTIVE_PANES_PRD.md`
- `MAP_EDITOR_UI_IMPLEMENTATION.md`
- `HISTORY_NAVIGATION_PRD.md`
- `PHASE_4_PANE_MAXIMIZATION_PRD.md`
- `tests/map_editor/window_input.md`

## Summary

Keep every viewport slot's existing top-left triple-dot `MenuButton` as a
pane-type picker. Do not add framing, grid cycling, maximization, or pane
navigation rows there.

Expand the toolbar file `MenuButton` (today Open…, Save, Save As…) into the
discoverable Map command menu. After the existing file items, expose document
history, clipboard, duplication, deletion, and visibility commands when they
are meaningful.

The same Cut through Show Hidden commands also appear at the top of the existing
grid right-click menu (zero-movement RMB release, already used to spawn point
and brush entities). Undo/Redo and Open/Save stay on the file menu only.

Menu labels, enabled states, and accelerators are rebuilt immediately before
display. File menu, grid context menu, and keyboard invocation share one
dispatcher. Commands act on the active Map session and shared spatial
selection, not on the slot that happens to hold pointer focus.

## Problem

Important map commands are discoverable only through compact icon buttons or
keyboard knowledge. Expanding each slot's type picker would hide those radios
behind a long command list and duplicate chrome that already exists on the pane
(frame buttons, orientation gizmos) or on the keyboard (Alt+Arrow, F12).

The shortcut router still needs one place that names Undo/Redo from session
history, shows native Ctrl/Cmd accelerators, and cannot fire the same command
twice from a menu shortcut and `route_key()`.

## Goals

- Make common document commands discoverable from the existing toolbar file menu.
- Show Cut through Show Hidden on the existing grid right-click menu as well.
- Leave slot pane menus unchanged: pane-type radios, icons, compact hitbox.
- Use one command dispatcher for file-menu popup, grid context popup, and keyboard invocation.
- Show native platform-formatted accelerators through Godot menu APIs.
- Derive labels and enabled states from the current selection, hidden set,
  clipboard, active session history, and (for Duplicate) whether `active_slot`
  is a Grid.
- Preserve native text editing in `LineEdit`, `TextEdit`, `SpinBox` line edits,
  `Tree`, `ItemList`, the material browser, and dialogs.
- Establish the command and submenu structure needed by the future Transform
  submenu without implementing transform operations in this phase.

## Non-goals

- Adding command rows, Layers, or any second section to slot pane menus.
- Implementing Frame Selection/Content, Cycle Grid Angle, Maximize Pane,
  Restore Panes, Previous Pane, or Next Pane as menu items. Frame buttons,
  orientation gizmos, Phase 2 Alt+Arrow, and Phase 4 F12 remain the UI for
  those actions.
- Implementing Transform submenu actions such as rotate, flip, scale, or nudge.
- Changing map history semantics, snapshot limits, or scene undo history.
- Replacing the grid entity-spawn menu or changing camera right-click fly mode.
  Context commands are prepended to the existing click-RMB grid menu; RMB drag
  still pans, Shift+RMB still box-selects, and camera RMB still captures fly.
- Replacing the compact frame buttons or pane orientation gizmos.
- Adding commands that edit UV fields or entity properties contextually.
- Parsing arbitrary clipboard text while constructing the popup.
- Persisting the active slot or an open popup.
- Changing pane type, layout, or map shortcuts not listed here.

## UX contract

### File menu order

The toolbar `file_menu` uses this stable order. Separators are omitted when the
entire following group is absent.

```text
Open…                         Ctrl/Cmd+O
Save                          Ctrl/Cmd+S
Save As…                      Ctrl/Cmd+Shift+S
------------------------------------
Undo {action}                 Ctrl/Cmd+Z
Redo {action}                 Ctrl/Cmd+Shift+Z
------------------------------------
Cut                           Ctrl/Cmd+X
Copy                          Ctrl/Cmd+C
Paste                         Ctrl/Cmd+V
Duplicate                     Space
[Transform submenu insertion point]
Delete                        Delete
------------------------------------
Hide                          H
Show Hidden                   Shift+H
```

`Ctrl/Cmd` above describes behavior, not literal label text. The popup must let
Godot render the platform modifier glyph/name from a `Shortcut` or accelerator.
Do not append manually formatted shortcut strings to item labels.

Open… / Save / Save As… keep their current IDs and `file_command()` behavior.
Attach their existing accelerators so the menu matches the keyboard router.
Do not add New, document-tab, or layout commands to this menu.

### Grid right-click menu

The existing grid click-RMB `entity_menu` (`pan_candidate` with zero movement)
keeps Point:/Brush: spawn items. Phase 3 prepends the edit/visibility group
using the same command IDs, labels, enablement, and accelerators as the file
menu. Undo/Redo and Open/Save/Save As… are omitted here.

```text
Cut                           Ctrl/Cmd+X
Copy                          Ctrl/Cmd+C
Paste                         Ctrl/Cmd+V
Duplicate                     Space
[Transform submenu insertion point]
Delete                        Delete
------------------------------------
Hide                          H
Show Hidden                   Shift+H
------------------------------------
Point: light
…
------------------------------------
Brush: func_group
…
```

RMB drag with no modifiers still pans. Shift+RMB still box-selects. Ctrl/Alt/Cmd
RMB still pans. Camera RMB remains fly capture; UV, Entities, and Layers panes
do not gain this Map context menu.

Opening the context menu activates the grid slot (Phase 2 pointer activation)
before rebuild. Duplicate therefore sees that Grid as `active_slot`.

### Slot pane menus

Slot `PaneMenuN` controls remain pane-type radio pickers. Phase 3 must not add
rows, separators, Layers, or command IDs to them. Their compact top-left
hitbox, icons, and `set_slot_type()` behavior stay as implemented. Phase 6 may
enable a Layers radio on those menus later without this phase reserving the
row.

### Context labels and availability

| Command | Label and enabled rule |
|---|---|
| Undo/Redo | Labels are **Undo {history_undo_name()}** and **Redo {history_redo_name()}**. Use plain **Undo** or **Redo** and disable when the corresponding name is empty. |
| Cut/Copy | Enable only for a non-empty spatial brush selection. Point entities and Entity-pane rows are not clipboard serializable today. |
| Paste | Enable when `DisplayServer.clipboard_get()` is non-empty. Import validity remains authoritative at activation; an invalid payload reports the existing error and creates no history. |
| Duplicate | Enable only when `active_slot` is a Grid and the spatial brush selection is non-empty. Reuse `clone_selection(bound_graph.axes().x)` so behavior remains the Space-command grid-step clone. |
| Delete | Enable for a non-empty spatial brush or point-entity selection. It invokes the existing atomic `delete_selection()`. It does not delete the Entities pane's independently selected row. |
| Hide | Enable for a non-empty spatial brush selection. |
| Show Hidden | Enable when `session.hidden` is non-empty. |

The menu acts on the shared spatial selection and active Map session. Opening
it does not reinterpret Cut, Copy, Paste, Delete, or Hide as native child-control
operations, even if a UV, Entities, or Layers pane is active.

### Slot targeting

- Phase 2 remains the owner of hover, pointer, descendant-focus activation,
  the active-pane border, and Alt+Arrow `move_active_slot()`.
- The file menu does not bind a `popup_slot`. File and edit commands do not
  retarget if focus changes while the popup is open; they revalidate against
  the live session and selection at dispatch.
- Duplicate is the only command that reads `active_slot`, and only to require a
  visible Grid and to pick that grid's X axis. It does not fall back to the
  first graph.
- Pane cycling, framing, grid orientation, and maximization are not file-menu
  commands.

### Dispatch ownership

Define stable command IDs in `map_editor.gd` starting at a non-overlapping
value such as `100`, so they never collide with file items `0..2`, slot
pane-type IDs `0..5`, or grid entity-spawn IDs (`1..n`). `file_menu` popup
`id_pressed`, `entity_menu.id_pressed` for command-range IDs, and `route_key()`
all call `dispatch_map_command(command_id)`. This dispatcher is the only place
that invokes a Map edit/history/visibility command. File items `0..2` continue
to call `file_command()`. Entity-spawn IDs continue to call
`entity_menu_selected()` spawn behavior.

When the file popup or grid context popup is visible, `route_key()` must not
consume a matching event; the visible `PopupMenu` owns its non-global shortcut.
When no popup is visible, `route_key()` owns the shortcut and marks the
viewport input handled through the existing `_input()` path. Never register a
second `_shortcut_input` or per-pane key callback for these commands. One
physical event produces at most one transaction or view change.

## Functional requirements

1. The file popup is rebuilt in `about_to_popup`. The grid context menu is
   rebuilt in `open_entity_menu()` before spawn items are appended. Item
   activation rejects a missing session for edit/history/visibility commands.
   File items remain valid with the existing empty-document rules.
2. Slot pane popups are not rebuilt by this phase except through the existing
   `update_slot_menu()` type-radio path.
3. Menu state is a fresh snapshot of the active session at open time.
   Selection/history changes while open do not rewrite rows; command activation
   revalidates destructive preconditions before acting.
4. Undo and Redo use the active session's `history_undo_name()`,
   `history_redo_name()`, `history_undo()`, and `history_redo()`. They cancel
   interactions first and refresh exactly once. They never call Godot global
   history.
5. Cut, Copy, Paste, Duplicate, Delete, Hide, and Show Hidden reuse the existing
   editor methods and transaction labels. Menu invocation must not create a
   second code path or a different undo unit.
6. All destructive commands revalidate selection/session state at dispatch.
   Stale disabled-state assumptions must not cause deletion or mutation.
7. `cancel_interaction()` runs before history movement, paste, duplicate, and
   delete. Copy does not cancel interaction.
8. The Transform position is represented by a named command range/submenu
   insertion helper on the file menu and the grid context menu, not by a
   clickable empty submenu. Phase 7 populates both insertion points and routes
   menu items and transform shortcuts through this same
   `dispatch_map_command()` dispatcher; a toolbar affordance may open the
   submenu but must not implement a second command path.

## Architecture/data model

Keep ownership in `map_editor.gd`; do not add a new command service for this
bounded feature.

```gdscript
var map_shortcuts: Dictionary = {} # command ID -> Shortcut
```

Phase 2 already owns `active_slot`, the active border, visual ordering, protected
focus classification, and pane cycling. Phase 3 consumes those APIs only where
Duplicate needs a Grid and adds file-menu and context-menu metadata/dispatch.

Add small helpers with direct responsibilities:

- `build_file_menu() -> void`
- `append_edit_menu_items(popup: PopupMenu) -> void`
- `map_command_enabled(command_id: int) -> bool`
- `dispatch_map_command(command_id: int) -> bool`
- `shortcut_for(keycode, modifiers...) -> Shortcut`

Construct shared `Shortcut` resources once. Use an `InputEventKey` with Godot's
command-or-control autoremap facility for Ctrl/Cmd commands, then attach it with
`PopupMenu.add_shortcut()` or `set_item_shortcut(..., global=false)`. Use native
accelerator APIs for Space, H, Shift+H, and Delete as well. Verify the exact
pinned Godot 4.8 property/API names in the implementation; do not substitute
label text if an API differs.

Do not add `popup_slot`. `active_slot` remains workspace UI state and is not
added to `workspace_state()` in this phase.

## Detailed implementation by file

### `addons/tbloader/src/editor/map_editor.gd`

- Add command IDs, shortcut construction, `build_file_menu()`, and
  `append_edit_menu_items()`. Keep file items `0..2` on `file_command()`.
- Replace one-time file popup population in `_ready()` with
  `about_to_popup -> build_file_menu()`. Connect `id_pressed` once.
- In `open_entity_menu()`, prepend edit/visibility items via
  `append_edit_menu_items()`, then the existing Point:/Brush: spawn sections.
  Route command-range IDs to `dispatch_map_command()`; keep spawn IDs on
  `entity_menu_selected()`.
- Leave `slot_menus` construction, radio items, icons, compact offsets, and
  `slot_menu_command()` unchanged.
- Refactor matching branches in `route_key()` to call `dispatch_map_command()`.
  Keep all existing focus/dialog/browser guards and descendant text-control
  detection. Do not consume Ctrl+Tab for grid orientation; that chord cycles
  Map document tabs. Do not add F12, Alt+Arrow, or Cycle Grid Angle to this
  menu.
- Reuse `copy_selection()`, `cut_selection()`, `paste_text()`,
  `clone_selection()`, `delete_selection()`, and `session.hide_selection()`.

### `addons/tbloader/src/editor/graph_view.gd`

- Reuse Phase 2 activation behavior without adding another focus/pointer hook.
- Keep `cycle_orientation()` and `frame_selection()` on the pane chrome/gizmo.
  Keep click-RMB opening `open_entity_menu()`; do not add a second context menu
  or change pan/box-select RMB gestures.

### `addons/tbloader/src/editor/camera_view.gd`

- Reuse Phase 2 activation behavior without adding another focus/pointer hook.
- Keep `frame_selection()` as the framing implementation on the camera chrome.
- Do not intercept menu accelerators, duplicate host commands, or open the Map
  context menu from camera RMB (fly mode stays).

### `addons/tbloader/src/editor/uv_pane.gd`

- Reuse Phase 2 descendant-focus activation.
- Make no changes to native `LineEdit`/`SpinBox` editing behavior.

### `addons/tbloader/src/editor/entity_pane.gd`

- Reuse Phase 2 descendant-focus activation. Keep independent
  `selected_entity_id` semantics unchanged.
- Do not redirect menu Delete to `_delete_entity()`.

### `addons/tbloader/src/editor/layers_pane.gd`

- Phase 6 supplies this seventh pane type. Phase 3 does not add a Layers radio
  or layer commands.

### `tests/map_editor/editor_suite.gd`

- Add deterministic file-menu structure, IDs, labels, enablement, accelerators,
  and dispatch-count tests.
- Assert the grid context menu starts with the same Cut through Show Hidden IDs
  and then the existing Point:/Brush: spawn sections.
- Keep existing slot-menu tests that assert pane-type radios, icons, and the
  compact hitbox; they must still see only type items.
- Test session-local dynamic Undo/Redo labels before and after cursor movement.
- Cover Duplicate enabled only when `active_slot` is a Grid.
- Prove file menu, context menu, and keyboard each dispatch once and share
  transaction labels.

### `tests/map_editor/window_input_observer.gd`

- Expose read-only file-menu and grid-context-menu rows/enabled state,
  selection/history cursor, and per-command counters needed for genuine input
  assertions.

### `tests/map_editor/window_input_runner.py`

- Add real pointer opening of the toolbar file menu, a zero-movement grid RMB
  context menu, and keyboard accelerator cases, including macOS-independent
  semantic checks of emitted menu metadata where X11 can only exercise Ctrl.
  RMB drag must still pan and must not open the menu.

## Edge cases

- The file menu or grid context menu may remain open while selection/history
  changes. Dispatch revalidates; an invalid command becomes a no-op with
  existing status feedback.
- Grid RMB drag continues to pan; only a click with no movement opens the
  context menu. Spawn items remain after the edit/visibility group.
- Clipboard content can become empty or invalid between popup construction and
  Paste. The existing import result is authoritative and no history is added.
- If `active_slot` is not a Grid, Duplicate remains disabled even when brushes
  are selected; Cut/Copy/Paste/Delete/Hide remain document commands.
- Ctrl+Tab cycles Map documents, not Godot scene tabs and not grid orientation.
- Grid orientation continues to use the existing pane gizmo / `cycle_orientation()`
  until a replacement shortcut is chosen.
- Slot pane menus continue to activate their slot on hover/click (Phase 2) and
  must not grow a hitbox that covers viewport input.

## Accessibility/platform

- Keep the file menu's accessibility name and update its description to include
  that it contains Map file and edit commands.
- Keep each slot menu button's existing slot-specific accessibility name.
- Standard `PopupMenu` keyboard behavior provides arrows, Enter/Space, mnemonic
  handling where available, and Escape to close. Do not custom draw the menu.
- Command labels and disabled state must not rely on color alone.
- Use Godot `Shortcut`/`PopupMenu` accelerator rendering so Linux/Windows show
  Ctrl and macOS shows Command. `Ctrl+Y` may remain an accepted redo alias on
  Linux/Windows, but the displayed primary redo shortcut is
  Ctrl/Cmd+Shift+Z.
- Delete should accept both Delete and the existing Backspace alias through the
  keyboard router; display only the platform's standard Delete accelerator.
- Native text controls retain native Cut/Copy/Paste/Undo/Redo/Delete and page
  navigation. The host route returns false whenever the focus owner is a text
  editor or its embedded editor child.

## Performance

- Rebuilding the file menu is O(number of fixed commands) plus constant-time
  session queries. It performs no geometry rebuild, serialization, clipboard
  parsing, resource scan, or history-state capture.
- Shortcuts are allocated once, not on every popup.
- Focus tracking uses signals/weak references; do not recursively scan the full
  scene tree on each key event.
- Mutations retain their current costs and execute only on activation.

## Test plan

1. Headless editor tests inspect file-menu and grid-context-menu item order,
   separators, native shortcut resources, labels, and enabled state. Slot menus
   still contain only pane-type radios with icons. Context menus include spawn
   items after Hide/Show Hidden and omit Undo/Redo and file commands.
2. Open the file menu, move focus to another slot, and activate a command;
   prove one dispatch occurs and Duplicate still keys off live `active_slot`.
3. Build history, move its cursor, and verify dynamic Undo/Redo labels,
   enablement, one-step behavior, and no Godot scene-history movement.
4. Exercise every edit/visibility enablement transition and stale-state
   revalidation. Compare transaction count and canonical text.
5. Focus every UV/Entities text field and embedded SpinBox editor; verify native
   text Cut/Copy/Paste/Undo/Delete and arrows are not intercepted.
6. Run a genuine X11 journey that opens the toolbar file menu by pointer,
   opens the grid context menu with click-RMB, chooses a row from each, and
   invokes each accelerator class. Assert no double dispatch.
7. Run existing editor, displayed journey, recovery, and window-input suites
   with their strict stderr and timeout policy.

## Acceptance criteria

1. Every slot pane menu remains a pane-type radio picker with the current compact
   hitbox. No Frame, Cycle Grid Angle, Maximize, Previous/Next, Undo, or edit
   rows appear there.
2. The toolbar file menu starts with Open…, Save, Save As… and then the specified
   history, clipboard, and visibility groups in stable order.
3. Undo/Redo labels name the next active-session action, enable correctly, and
   menu and keyboard paths move session history once.
4. Cut/Copy/Paste/Duplicate/Delete/Hide/Show Hidden follow the capability table,
   reuse existing methods, appear on both the file menu and the grid context
   menu, and create no action on invalid or stale input.
5. Duplicate is enabled only for a Grid `active_slot` and a non-empty brush
   selection.
6. Accelerators are attached through Godot APIs and render with the platform's
   Command/Ctrl convention; labels contain no hard-coded modifier suffixes.
7. Focused text controls retain native editing and no shortcut reaches both a
   child control and the Map dispatcher.
8. Existing pane replacement, workspace persistence, camera capture,
   selection, history, and layout tests continue to pass.

## Dependencies/rollout

- Depends on Phase 1's session-local history API represented by
  `history_undo_name()`, `history_redo_name()`, `history_undo()`, and
  `history_redo()`.
- Depends on Phase 2's `active_slot` only for Duplicate's Grid requirement.
  Phase 3 must not duplicate or replace activation, borders, or Alt+Arrow.
- Phase 4 F12 maximization is independent of this menu. Do not add a disabled
  Maximize row as a placeholder.
- Phase 7 depends on this reserved Transform submenu and central dispatcher. It
  populates the submenu only after native/session transform operations define
  atomic transactions and selection capability; do not expose an empty submenu
  before then.
- Roll out behind no preference flag. The existing toolbar file menu is
  directly upgraded, with automated Linux as the release gate and manual
  macOS/Windows accelerator inspection before claiming those platforms verified.

## Decisions

- Slot triple-dot menus stay pane-type pickers. This phase does not turn them
  into command menus.
- Frame, Cycle Grid Angle, Maximize/Restore, and Previous/Next are not menu
  items in this phase.
- Map history commands live on the toolbar file `MenuButton`. Cut through Show
  Hidden live there and on the existing grid right-click menu.
- Commands target the active session and spatial selection, not a popup-bound
  slot.
- One central dispatcher owns file-popup, grid-context-popup, and keyboard
  behavior for those commands.
- Camera RMB remains fly mode. Grid RMB click-vs-drag behavior is unchanged.
- Menu edit commands operate on spatial Map selection, not UV text or the
  Entities pane's independent row selection.
- Duplicate retains the existing grid-axis, one-grid-step clone semantics and
  is therefore Grid-`active_slot` only.
- Accelerators are native Godot shortcut metadata, never hand-formatted labels.
- Transform is a Phase 7 dependency, not a placeholder action in this release;
  Phase 7 shares this dispatcher and inserts into the file menu and the grid
  context menu.
