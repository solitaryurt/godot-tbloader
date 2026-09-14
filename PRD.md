# TBLoader Product Requirements

Status: Draft

## Product Direction

TBLoader should make TrenchBroom-authored maps feel native inside Godot without turning generated
scene content into fragile hand-authored data. The main workflow is:

1. Build structural geometry in TrenchBroom.
2. Inspect, validate, and apply Godot-specific presentation or runtime overrides in Godot.
3. Regenerate repeatedly without losing those overrides.

The product should clearly distinguish source data, persistent overrides, and generated output.
Generated children remain disposable. Any user-authored operation that must survive regeneration must
be stored on the `TBLoader`, in the source map, or in an explicit resource referenced by the loader.

## Goals

- Make regeneration safe and predictable.
- Add useful mesh-authoring operations that TrenchBroom does not provide, starting with normal
  smoothing for selected faces and edges.
- Make map materials easy to inspect, locate, validate, and replace.
- Surface import problems before they become visual, collision, lighting, or runtime bugs.
- Reduce repetitive scene setup after map changes.
- Keep generated scenes deterministic and suitable for source control.

## Non-Goals

- Replace TrenchBroom as the primary brush geometry editor.
- Support arbitrary destructive edits to generated `ArrayMesh` resources.
- Preserve edits made directly to generated child nodes.
- Become a general-purpose Godot modeling package.

## Core Requirement: Persistent Overrides

### Problem

`TBLoader.build_meshes()` clears and recreates generated children. Directly edited normals,
materials, transforms, metadata, and generated nodes are therefore lost on every regeneration.

### Requirements

- Add an override resource referenced by each `TBLoader`.
- Create an embedded override resource automatically on the first persistent edit.
- Allow users to save it as an external `.tres` for explicit sharing and version control.
- Apply overrides during generation, before lightmap unwrap or other operations that may duplicate or
  reorder vertices.
- Never silently apply an override to geometry that cannot be matched confidently.
- Report unmatched overrides as orphans and provide actions to inspect, remap, or delete them.
- Support Undo/Redo for every override edit.
- Mark the scene or external resource dirty when overrides change.
- Keep the serialized format deterministic and human-diffable where practical.

### Stable Geometry Identity

Transient entity, brush, and face indices are insufficient because source ordering can change.
TBLoader should derive canonical identifiers:

- Entity ID: explicit source ID or target name when unique; otherwise a canonical entity signature.
- Face ID: hash of a quantized plane, texture, and texture axes.
- Brush ID: hash of its sorted face IDs.
- Edge ID: sorted pair of adjacent face IDs, with quantized endpoints as validation data.

Exact IDs should be resolved first. A geometric fallback may suggest remaps, but applying a fuzzy
match must require user confirmation when it is ambiguous.

## Feature: Face and Edge Normal Smoothing

### User Problem

Curved or beveled brushwork is rendered with hard face normals unless smoothing is applied broadly.
Users need to smooth intentional transitions while retaining hard corners, and those decisions must
survive map regeneration.

### Interaction Model

- Add a **Normals** edit mode to the TBLoader 3D editor tools.
- Support **Face** and **Edge** selection modes.
- Ray-pick generated triangles and resolve them back to their source entity, brush, and face.
- Render selected faces and edges as viewport overlays without modifying map materials.
- Support click, Shift-add, Ctrl-remove, box selection where practical, and clear selection.
- Provide **Smooth**, **Harden**, and **Clear Override** actions.
- Provide an angle threshold for bulk selection and smoothing.
- Face-mode smoothing marks edges shared by selected faces as smooth. Selection boundary edges remain
  hard by default.
- Edge mode changes only the selected edges and is the precise underlying operation.
- Offer an explicit option to smooth across material boundaries; default it off.
- Display hard, smooth, inherited, and orphaned states distinctly.

### Normal Generation

- Preserve face and corner provenance through surface gathering and mesh construction.
- Build adjacency across render surfaces, including duplicated vertices at material boundaries.
- For a smooth edge, calculate shared corner normals from incident faces.
- Use angle- or area-weighted normals rather than an unweighted position-only average.
- Respect explicit hard-edge overrides even when an entity-wide smoothing option is enabled.
- Recalculate tangents after changing normals.
- Apply smoothing before lightmap unwrap.
- Do not alter collision geometry.
- Preserve patch normals unless patch-specific editing is added later.

### Precedence

From highest to lowest priority:

1. Explicit hard edge override.
2. Explicit smooth edge override.
3. Source map smoothing properties such as `_phong` and `_phong_angle`.
4. Default flat shading.

### Regeneration Behavior

- Smoothing overrides are stored in the loader's override resource, never on generated mesh nodes.
- Regeneration automatically reapplies all resolvable overrides.
- Moving an entire brush without changing its shape should retain smoothing when identity can be
  resolved safely.
- Changing a face plane, splitting a brush, or deleting geometry may orphan affected overrides.
- After regeneration, show a concise result: applied, changed, and orphaned override counts.

### Acceptance Criteria

- A user can select two adjacent faces, smooth their shared edge, regenerate, and see the same result.
- A user can mark one edge hard inside an otherwise smoothed entity.
- Smoothing works across separate material surfaces when explicitly enabled.
- Tangent-space normal maps remain visually correct after smoothing.
- Undo and redo update both the viewport and serialized override data.
- Source face reordering does not lose valid overrides.
- Deleted or substantially changed source geometry does not receive stale overrides silently.
- Reloading the Godot project restores all saved smoothing overrides.

## Feature: Material Workspace

The Map Materials panel should grow from a browser into a focused map-material workflow.

### Requirements

- Show usage counts by face, brush, and generated surface.
- Filter to unused, missing, invalid, overridden, or duplicated materials.
- Highlight missing textures, invalid resource paths, and failed material loads.
- Replace one material with another across a loader, with a preview and Undo/Redo.
- Support multi-select and bulk editing of compatible material properties.
- Pin favorites and show recently inspected materials.
- Double-click a material to select or frame geometry that uses it.
- Distinguish generated, inherited, source-defined, and locally overridden materials.
- Compare a local override with its source or template values.
- Audit oversized textures, missing normal maps, inconsistent filtering, and duplicate resources.

## Feature: Regeneration and Source Sync

- Watch the source `.map` and offer automatic, prompted, or manual rebuild modes.
- Debounce repeated file changes from TrenchBroom saves.
- Show what changed before rebuilding: entities, brushes, materials, and overrides at risk.
- Preserve viewport focus, selected source geometry, and active material context after rebuild.
- Provide a build report with duration and counts for geometry, collision, entities, warnings, and
  orphaned overrides.
- Avoid rewriting unchanged generated resources where possible.
- Support build profiles such as Preview, Gameplay, Lighting, and Release.
- Add a deterministic build fingerprint so users can tell whether output is stale.

## Feature: Map Validation

- Detect invalid or degenerate brushes and faces.
- Detect duplicate planes, zero-area triangles, non-manifold output, and extreme coordinates.
- Report missing entity scenes, unknown properties, type conversion failures, and duplicate target
  names.
- Validate texture and material references.
- Detect likely collision leaks, unexpectedly collisionless geometry, and invalid layer masks.
- Validate lightmap UV generation and report surfaces that fail unwrap.
- Group diagnostics by source entity, brush, and face.
- Clicking a diagnostic should focus the relevant source geometry in Godot.
- Export reports for CI and fail headless builds at a configurable severity.

## Feature: Geometry Inspection

- Face, brush, entity, collision, and material selection modes.
- View source IDs and generated provenance in an inspector panel.
- Overlay face normals, smoothed normals, tangents, lightmap density, and collision geometry.
- Isolate or hide selected entities, brushes, layers, or materials.
- Measure distances, face area, brush volume, and texel density.
- Copy source coordinates and identifiers for debugging.

## Feature: Collision and Gameplay Surfaces

- Preview collision by type and physics layer.
- Report visual faces with no expected collision and hidden collision with no visual counterpart.
- Configure gameplay surface types through data rather than hard-coded texture-name checks.
- Bulk assign footsteps, impact effects, penetration values, navigation costs, or audio materials by
  source material.
- Persist per-material gameplay mappings independently of regenerated meshes.
- Preview special volumes such as clip, ladder, water, triggers, and navigation exclusions.

## Feature: Entities and Scene Integration

- Add an entity browser with class, target name, source layer, and generated-node filters.
- Focus the source entity from a generated node and vice versa.
- Validate entity properties against FGD and Godot scene properties.
- Provide property presets and bulk property editing.
- Preserve safe user-authored child nodes through explicit attachment slots rather than by relying on
  generated hierarchy paths.
- Support post-build extension hooks for project-specific generation without forking TBLoader.
- Show broken target links and a graph of entity relationships.

## Feature: Lighting and Optimization

- Visualize lightmap texel density and unwrap failures.
- Configure lightmap density per material, entity, or source layer.
- Preview portals, occluders, visibility ranges, and LOD grouping.
- Report high triangle counts, excessive material surfaces, and collision complexity.
- Merge or split geometry using configurable policies while retaining source provenance.
- Cache intermediate parse and geometry results to accelerate iterative rebuilds.
- Provide before/after build metrics when settings change.

## Feature: Export and Team Workflow

- Store project-wide defaults in a shared TBLoader settings resource.
- Allow per-loader overrides without duplicating the full settings set.
- Export and import material mappings, gameplay surface mappings, and build profiles.
- Provide deterministic diagnostics and override files suitable for code review.
- Add a headless validate/build command for CI.
- Include override schema versions and non-destructive migrations.

## Delivery Plan

### Phase 1: Safe Authoring Foundation

- Persistent override resource and schema versioning.
- Stable entity, brush, face, and edge identifiers.
- Provenance retained through generated mesh construction.
- Orphan detection and regeneration summary.

### Phase 2: Normal Editing MVP

- Face and edge picking with viewport overlays.
- Smooth, harden, clear, and angle-threshold operations.
- Normal and tangent regeneration.
- Undo/Redo and persistence across regeneration and editor restart.

### Phase 3: Material and Validation Tools

- Usage counts, unused filters, missing-resource diagnostics, and bulk replacement.
- Click-to-focus material usage.
- Core brush, entity, collision, and lightmap validation.

### Phase 4: Iteration Workflow

- Source watching, change summaries, build profiles, and build fingerprints.
- Selection/focus restoration and incremental build caching.
- Headless validation and build support.

### Phase 5: Advanced Integration

- Gameplay surface mappings, extension hooks, relationship graphs, and optimization overlays.
- Team presets, import/export, and override migrations.

## Risks and Open Questions

- Geometry fingerprints must tolerate harmless source changes without matching unrelated geometry.
- Cross-material smoothing requires coordinated normals across separate Godot mesh surfaces.
- Lightmap unwrap can reorder vertices, so provenance and smoothing must be applied beforehand.
- Embedded override resources are convenient, while external resources are easier to share; both
  should use the same schema.
- Direct synchronization back into TrenchBroom is limited by the `.map` format. Entity-wide settings
  can live in map properties, but precise edge state should remain a TBLoader override unless a
  durable source-side ID extension is introduced.
- The editor must remain responsive on large maps; picking and adjacency data may need compact caches
  built during generation.
- Moving a brush challenges geometry-derived IDs. The implementation must decide whether translation
  should preserve identity through secondary shape matching or intentionally orphan the override.

## Success Measures

- Zero loss of supported persistent overrides during ordinary regeneration.
- Normal-editing changes can be reproduced deterministically after project reload and on another
  machine.
- Most import problems can be reached directly from one validation report.
- Common material replacement and geometry-inspection tasks require no manual generated-node edits.
- Rebuild feedback makes stale output and orphaned customization immediately visible.
