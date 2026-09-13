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
  Budgets count serialized snapshot envelopes (including identities/selection).
  Eviction releases payloads and reports expiration when a token is invoked.
  A session picker exposes retained documents; background undo updates unsaved
  reporting and Save All. Explicit Discard suppresses saving a retired document
  until a history restore revives it.
- Real indexed material browser reused without modification; shader assignment,
  classic UV controls, resolved texture dimensions and textured camera preview.
- N inspector edits ordered keyvals on worldspawn/selected owners/points; point
  and brush entity creation, point picking/movement, ownership and deletion.
- New/Open/Save/Save As, Save/Discard/Cancel replacement prompt, native external
  conflict reporting, Save All and editor unsaved-status hooks.
- Explicit loader binding is separate from spatial selection and toolbar.
  Checked bake is capability-gated, verifies scene/loader/path and clean saved
  source, reports saved versus baked states and marks successful bake scene dirty.
  Both the Map Bake button and legacy spatial Build Meshes use **scene history**
  with packed before/after generated-child snapshots and validated weak targets.
  Explicit loader-path changes also use scene history. Global Map undo remains
  independent from these scene operations.
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
| `editor/bake_action.gd` | Scene-history packed child snapshots, weak loader/scene targets, ownership restoration |
| `editor/graph_view.gd` | Map-space projection, drawing, picking, preview gestures, tools |
| `editor/camera_view.gd` | Disposable triangle preview, map-to-Godot conversion, ray picking and captured fly input |
| `editor/material_browser.gd` | Independently delivered browser; consumed through documented API |

`.map` remains canonical. Preview and baked nodes never feed edits back into the
document. Native and shared document-test files are owned by the native workstream.
This harness offers no subagent tool; UI implementation/testing is performed directly.

## Verification

Pinned engine: `/mnt/data/code/godot/bin/godot.linuxbsd.editor.x86_64`.

```sh
python tests/map_editor/run_tests.py --godot /mnt/data/code/godot/bin/godot.linuxbsd.editor.x86_64 --suite editor --timeout 60
DISPLAY=:0 python tests/map_editor/ui_journey_runner.py --godot /mnt/data/code/godot/bin/godot.linuxbsd.editor.x86_64 --suite ui --timeout 90
python tests/map_editor/run_tests.py --godot /mnt/data/code/godot/bin/godot.linuxbsd.editor.x86_64 --suite document --timeout 90
```

Work step 1 (`72a3753`): real editor **93 checks**,
`tests/map_editor/artifacts/editor-ythtc_vp/`.

Work step 2 integration results:

| Gate | Result | Artifact beneath `tests/map_editor/artifacts/` |
|---|---|---|
| Headless editor | **149 checks**, zero failures | `editor-dyov3768/` |
| X11 display-backed editor journey | **152 checks**, zero failures | `journey-_7e2u0jq/ui-4utp7ok2/` |
| Fresh-process reopen and rebake | **8 checks**, zero failures | Same journey directory, `reopen.*` |
| Shared native document suite, unmodified | **2,307 checks**, zero failures | `document-c30ep9a9/` |

Full stdout/stderr, exact process arguments and source/library hashes are retained
by the strict harness. Summaries: `/tmp/opencode/tbloader-ui-{editor,journey,document}.log`.
Screenshot (visually inspected):
`tests/map_editor/artifacts/journey-_7e2u0jq/ui-4utp7ok2/editor-smoke.png`.
`ui_journey_runner.py` retains the staged project, saved maps, point prefab and baked
scene, then launches a separate real editor process to reopen and rebake them.

Tests use real native documents and editor history, invoke actual graph handlers,
and dispatch Ctrl+Z through the viewport. They cover both grids' focus routing,
cursor zoom, negative/fractional and rigid off-grid gestures, AABB snapping, invalid
resize/component rejection, hide/pick-through/hidden-save-and-bake, materials both
inside and outside the texture root, classic UVs, split/prism, N entity operations,
dirty prompts/conflicts, originating and expired history, fly state/movement/exits,
two explicit loaders, scene switches/deletion, checked bake failures, packed bake
scene undo/redo, legacy Build Meshes, path scene undo, and disable/re-enable.
Display tests run the same handlers with actual rendering/capture on X11; they do
not claim window-system mouse-injection or complete Phase 6 manual UX acceptance.
No errors/warnings are allowlisted.

The pinned 4.8 adapter creates an `EditorDock` for legacy main screens, then only
detaches it on disable. Plugin teardown explicitly frees that detached `_dock`
wrapper; it leaves an attached, editor-owned wrapper alone at editor shutdown.

Display validation also exposed recursive importer entry during immediate Save All
filesystem scans. Saves now debounce/coalesce scanning and wait until filesystem
scan/import is idle. The screenshot gate waits for import completion and forces
one rendered frame instead of waiting indefinitely for an idle redraw signal.

## Native/material integration

The checked native API landed in `83e844a`. The host uses `resolve_material(token)`
for both preview materials and texture dimensions, matching the native bake resolver.
The browser remains unchanged. Its root-relative mappings are reused; an otherwise
unresolved project resource can be assigned as an exact `res://...` token only when
native resolution succeeds. The status line shows the actual token; the document
writer quotes it canonically. Arbitrary ShaderMaterials receive a separate selected
brush wire outline; BaseMaterial previews also use vertex tint.

Save As never rewrites a loader path automatically. Use **Update loader path** to
commit that scene change. Bake on save defaults on but runs only for a clean,
successfully saved document with the same path and valid current-scene binding.
Missing point/entity prefab resources return a visible bake failure while preserving
previous output. The journey supplies `fixtures/info_player_start.tscn` deliberately.

## Remaining acceptance / limitations

- Phase 5 requires broader component deformation, clip direction and cap-material
  acceptance. Native clip caps inherit the source first face (not forced caulk).
- Graph component selection currently selects one handle at a time. Resize and
  component previews show the drag reference rather than rebuilding a live hull.
- Phase 5 tests should expand vertex/edge successful constrained deformations,
  multi-handle selection, clip flip/one-sided outcomes and all prism orientations.
  Current UI tests establish split, Ctrl+5, face assignment and invalid vertex
  rejection; native geometric cases are covered separately by the document suite.
- Brush clipboard follows the native API (point-only clipboard unsupported).
- Patch primitives persist natively but have no graph/camera drawing or editing.
- Save All can save named maps synchronously; untitled maps need a Save As dialog.
  Godot's void `_save_external_data` hook cannot veto editor shutdown after an I/O
  failure or asynchronously finish an untitled Save As. The unsaved-status prompt
  explicitly asks users to Save As before exit. Full exit-failure UX remains open.
- After changing loader texture/template configuration in the scene Inspector,
  rebind/refresh materials to invalidate preview resolution. Baked-current status
  currently compares canonical document content, not every external resource or
  loader option. Broader resource/configuration invalidation remains a follow-up.
- Blockout-scale full-document snapshots/rebuilds; no large-map performance claim.
- Release/other Godot versions/other platforms, full window-system input acceptance,
  and representative-map responsiveness/memory measurements remain Phase 6 work.
