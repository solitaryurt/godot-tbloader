# Vertex-editing investigation (2026-09-13)

## Reproduced failures

These are independently reproduced cases; the reporter's map, gesture and loaded
addon path have not been supplied.

Use `fixtures/vertex_prism.map`, a decimal-plane 12-sided prism at
`(4096, -2048, 1024)`–`(4160, -1984, 1088)`:

1. Native vertex edit: move the corner `(4155.712890625, -2032, 1024)` by
   `(16, 16, 0)` via `translate_vertices` or `translate_components`.
2. Actual editor edge edit: select the brush, use the Top view and Edge tool with
   the default 16-unit grid. Grab the midpoint of the bottom edge joining
   `(4144, -2043.7127685546875, 1024)` and
   `(4155.712890625, -2032, 1024)`. Move the cursor by `(16, 16)` map units and
   release. Midpoint snapping produces native delta
   `(10.1435546875, 21.8564453125, 0)`.

Both failed against a fresh build of the previous implementation with:

```
INVALID_GEOMETRY: Brush must be a finite, closed solid with nonempty faces
```

The edge case legitimately makes its first endpoint interior to the hull. The
result must commit, remove that endpoint/edge, retain the other extreme endpoint,
and clear the disappeared component selection. Undo restores the old edge and its
selection; redo restores the new solid and empty component selection.

A further precision case uses a 1024-unit 12-sided prism at the same origin:
move `(4864, -1979.405029296875, 1024)` by `(-16, -16, 0)`. Merely lowering the
intersection determinant cutoff still produced duplicate corners more than the
`1e-5` weld tolerance apart in this case.

## Causes and implementation

The exact error has one emitter: `TBMapDocument::prepare()` in
`src/map_document.cpp`, after parsing and native mesh generation. The parser's
other `INVALID_GEOMETRY` errors and the hull-builder's failure have different
messages. `map_data.cpp` manages document/cache ownership, not this validation.

The supporting planes from `rebuild_vertex_hull()` were valid in these cases.
`LMGeoGenerator::intersect_faces()` rejected determinants below `CMP_EPSILON`
(`1e-5`), conflating an angular/singularity threshold with positional welding.
Near-parallel supporting planes then lost real intersections. A face had only
two generated vertices, and boundary edges had only one incident face. Rejecting
that generated mesh was correct; failing to generate the corner was the bug.

The intersection solve now derives unnormalized normals from defining plane
points at extended precision and solves relative to a defining point. Its
singularity check is scaled by the product of normal lengths and machine
precision. Promoting previously rounded unit normals alone was insufficient.
Solid validation and vertex welding tolerances are not relaxed.

NetRadiant's `Brush::vertexModeBuildHull()`, `VertexModePlane` and
`vertex_mode_find_common_face()` reconstruct the convex hull, preserve common-face
metadata and retain untouched source planes. The existing hull reconstruction
already follows those semantics. This fix repairs the subsequent conversion from
those planes back to a closed mesh, including shallow faces and disappearing
corners.

The editor's sequential drag regression additionally exposed a picking bug:
regenerated winding order can reorder coincident front/back handles. Ordinary
grabs now prefer the selected vertex/edge handle; Alt remains explicit cycling.

## Editor-path audit

- Graph Vertex/Edge gestures use `map_session.move_components()` on release;
  motion only previews, with reference-position snapping and optional axis lock.
- Face mode and Ctrl quick-face picks move supporting planes. Silhouette resize
  uses `translate_face()`. These operations share final mesh validation but do
  not use the vertex hull reconstruction.
- Brush and point-entity movement are separate translation paths. The new editor
  regression asserts the gesture is actually an edge component deformation.
- The camera selects brushes/faces and supports fly navigation; it has no
  independent vertex drag/release implementation.
- Invalid native edits remain staged until validation succeeds. Existing
  collapse, crossing-face, stale-handle and multi-brush atomicity gates passed.

## Verification

Permanent regressions are in `document_suite.gd`, `editor_suite.gd`, and
`native_document_test.cpp`. They cover imported classic and reversed-face Valve
planes, expected extreme points and containment, manifold geometry, serialized
rebuild/round-trip, default-grid editor release/history, coincident picking, and a
native shallow bevel with a real crease.

Runs completed:

- `scons platform=linux target=template_debug arch=x86_64 -j2`: passed.
- Targeted real-editor regression with the previous native library: **failed**
  on the edge-release commit and resulting geometry assertions.
  `/tmp/opencode/vertex-editor-l5ulhan4/`
- Same real-editor regression with the fixed library: **417 checks, zero failures**.
  `/tmp/opencode/vertex-editor-259bkzp6/`
- Full document suite: **113579 checks, zero failures**.
  `artifacts/document-30tm4l48/`
- Full editor suite: **1080 checks, zero failures**.
  `artifacts/editor-jzu5udhb/`
- `bash tests/map_editor/run_native_tests.sh`: **NATIVE_DOCUMENT_PASS** and
  **NATIVE_TOHUNGA_PASS**, under ASan/UBSan with leak detection.
- Bounded exploratory native-extension probes: **1218** single-corner edits on
  cubes and 5/8/12-sided prisms at three sizes; **499** reference-snapped
  vertex/edge edits across all graph planes plus eight successive edits on each
  of eight sloped brushes extracted from `tohunga.map`. Passed after the fix.
- `git diff --check`: passed.

The first full editor run exposed the coincident-depth picking issue and an
incorrect assumption in the new test that the disappearing edge should survive.
The final test instead verifies the geometrically correct interior-point removal,
remaining extreme point, containment and history semantics.

## Binary identity and reload

The pre-fix reproduction library was built from the dirty working tree, including
the previous hull fixes. SHA-256:
`8e1a2dbf22bbe236f8a2bc6b129c2711c9219593379890a5680c11d30fcd5970`.

The verified fixed debug library has SHA-256:
`cd7cf4434f5a9a0f9c6d3493c9418055dd7432d56e1cbd5faf7c49ffc5a216db`.
`run_tests.py` copies this exact library into each isolated project's addon and
records matching source/staged hashes in `result.json`. This repository's
`tbloader.gdextension` selects `libtbloader.linux.template_debug.x86_64.so` for
the Linux editor. Legacy `libtbloader.linux.x86_64.so` and release artifacts also
exist and are not the tested library.

Several sibling project addon manifests still select the legacy filename. Their
existence does not establish which addon the reporter is using. To deploy this
fix to another project, install the complete addon using
`python install_addon.py /path/to/project`, then fully restart Godot. Rebuilding
this repository alone does not update another project's addon or an already
loaded native extension. Only the Linux debug target was rebuilt here.

If the report persists with the verified library and updated scripts, the next
needed evidence is the source map/brush, selected component(s), view/tool/grid,
drag destination (including modifiers), and the actual project addon path/hash.
