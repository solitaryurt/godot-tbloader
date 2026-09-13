# Map editor UI implementation and handoff

## Progress — 2026-09-13

- Implemented real Map main screen, camera/materials left and independent Top/Front
  grids right, resizable splitters, per-orientation pan/zoom, shared fractional grid.
- Graph handlers implement cuboid creation, click/Shift/directional box selection,
  rigid translation, silhouette plane resize, clone/paste/delete, hide/reveal,
  cancellation, axis constraint and AABB alignment.
- Native snapshots are committed to the real EditorUndoRedoManager global history
  with originating RefCounted sessions. Motion is a disposable visual preview;
  completion is one transaction, cancellation/no-op adds nothing. Tokens retain
  sessions across Open/New, with 128 actions/64 MiB per session and 128 MiB total.
  Eviction releases payloads and reports expiration when a token is invoked.
- Real indexed material browser reused without modification; shader assignment,
  classic UV controls, resolved texture dimensions and textured camera preview.
- N inspector edits ordered keyvals on worldspawn/selected owners/points; point
  and brush entity creation, point picking/movement, ownership and deletion.
- New/Open/Save/Save As, Save/Discard/Cancel replacement prompt, native external
  conflict reporting, Save All and editor unsaved-status hooks.
- Explicit loader binding is separate from spatial selection and toolbar.
  Checked bake is capability-gated, verifies scene/loader/path and clean saved
  source, reports saved versus baked states and marks successful bake scene dirty.
- Basic Phase 5 UI is present: face/edge/vertex modes and picks, constrained native
  component movement, selected-face assignment, 2/3-point clip/split/flip, prism
  toolbar and Ctrl+3…9. Full Phase 5 acceptance remains pending.

## Architecture / ownership

| File under `addons/tbloader/src/` | Responsibility |
|---|---|
| `plugin.gd` | Main-screen lifecycle, independent spatial toolbar and legacy materials, editor save hooks |
| `editor/map_editor.gd` | Quad layout, shortcut router, dialogs, binding, materials/UV and entity inspector, history budget |
| `editor/map_session.gd` | Native document, selection/hidden/workzone, transactions and snapshot envelopes |
| `editor/map_action.gd` | Retainable/expirable originating-session history token |
| `editor/graph_view.gd` | Map-space projection, drawing, picking, preview gestures, tools |
| `editor/camera_view.gd` | Disposable triangle preview, map-to-Godot conversion, ray picking and captured fly input |
| `editor/material_browser.gd` | Independently delivered browser; consumed through documented API |

`.map` remains canonical. Preview and baked nodes never feed edits back into the
document. Native and shared document-test files are owned by the native workstream.
This harness offers no subagent tool; UI implementation/testing is performed directly.

## Verification (work step 1)

Pinned engine: `/mnt/data/code/godot/bin/godot.linuxbsd.editor.x86_64`.

```sh
python tests/map_editor/run_tests.py --godot /mnt/data/code/godot/bin/godot.linuxbsd.editor.x86_64 --suite editor --timeout 60
```

PASS **93 checks**, `tests/map_editor/artifacts/editor-ythtc_vp/`;
summary `/tmp/opencode/tbloader-ui-editor.log`. Full stdout/stderr and hashes are
retained by the strict existing harness. Tests use real native documents and real
editor history; invoke actual graph handlers and dispatch Ctrl+Z through the viewport.
No errors/warnings allowlisted. Import and disable/re-enable are included.

The pinned 4.8 adapter creates an `EditorDock` for legacy main screens, then only
detaches it on disable. Plugin teardown explicitly frees that detached `_dock`
wrapper; it leaves an attached, editor-owned wrapper alone at editor shutdown.

## Remaining acceptance / limitations

- Display-backed screenshot/journey and explicit loader/scene/bake tests next.
- Phase 5 requires broader component deformation, clip direction and cap-material
  acceptance. Native clip caps inherit the source first face (not forced caulk).
- Graph component selection currently selects one handle at a time. Resize and
  component previews show the drag reference rather than rebuilding a live hull.
- Brush clipboard follows the native API (point-only clipboard unsupported).
- Patch primitives persist natively but have no graph/camera drawing or editing.
- Save All can save named maps synchronously; untitled maps need a Save As dialog.
  Godot's void `_save_external_data` hook cannot veto editor shutdown after an I/O
  failure or asynchronously finish an untitled Save As. The unsaved-status prompt
  explicitly asks users to Save As before exit. Full exit-failure UX remains open.
- Checked bake currently marks the scene dirty; scene-bake undo acceptance is pending.
- Blockout-scale full-document snapshots/rebuilds; no large-map performance claim.
