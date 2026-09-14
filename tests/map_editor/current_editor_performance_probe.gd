@tool
extends EditorPlugin
## Current Radiant editor baseline. frame_post_draw is used only as a completion
## boundary; none of these measurements are input-to-photon latency.

const MARKER = "TB_CURRENT_EDITOR_PERF_COMPLETE:PASS"
const FIXTURE = "res://fixtures/tohunga.map"
const FIXTURE_SHA256 = "1e9d250d26267ebda5ff52978ebacca23e37a686865fe47f950b0109e7ca8811"

var failed := false
var report := {}

func _enter_tree() -> void:
	if OS.get_environment("TB_TEST_SUITE") == "current_editor_performance":
		call_deferred("run")

func require(condition: bool, message: String) -> bool:
	if not condition:
		failed = true
		push_error("TB_CURRENT_EDITOR_PERF_FAIL: " + message)
	return condition

func find_tb_plugin(node: Node) -> EditorPlugin:
	if node is EditorPlugin and node.get_script() != null and node.get_script().resource_path == "res://addons/tbloader/src/plugin.gd":
		return node
	for child in node.get_children():
		var found := find_tb_plugin(child)
		if found != null:
			return found
	return null

func memory() -> Dictionary:
	var result := {
		"godot_static_bytes": OS.get_static_memory_usage(),
		"godot_static_peak_bytes": OS.get_static_memory_peak_usage(),
	}
	var status := FileAccess.open("/proc/self/status", FileAccess.READ)
	if not require(status != null, "Linux /proc/self/status opens"):
		return result
	while not status.eof_reached():
		var line := status.get_line()
		for key in ["VmRSS", "VmHWM"]:
			if line.begins_with(key + ":"):
				result[key + "_bytes"] = int(line.split(":")[1].strip_edges().split(" ", false)[0]) * 1024
	status.close()
	require(result.get("VmRSS_bytes", 0) > 0 and result.get("VmHWM_bytes", 0) > 0 and result.godot_static_bytes > 0,
		"RSS, HWM, and Godot static memory counters are positive")
	return result

func checkpoint(name: String, counts: Dictionary) -> void:
	report.checkpoints[name] = {"memory": memory(), "counts": counts.duplicate(true)}
	report.checkpoint_order.append(name)

func timed(operation: Callable) -> Dictionary:
	var started := Time.get_ticks_usec()
	var value = operation.call()
	return {"usec": Time.get_ticks_usec() - started, "value": value}

func samples(operation: Callable, count: int) -> Array:
	var values: Array = []
	for index in count:
		var measurement := timed(operation)
		values.append(measurement.usec)
	return values

func preview_samples(operation: Callable, count: int, name: String) -> Array:
	var values: Array = []
	for index in count:
		var measurement := timed(operation)
		var result = measurement.value
		require(result is Dictionary and result.get("ok", false) and not result.get("changed", true)
			and result.get("value", []).size() > 0, name + " returns read-only candidate geometry")
		values.append(measurement.usec)
	return values

func mutation_samples(document: RefCounted, base_state: RefCounted, topology_revision: int, operation: Callable, expected_operation: StringName, expected_ids: PackedInt64Array, count: int, name: String) -> Array:
	var values: Array = []
	for index in count:
		require(document.is_history_state_current(base_state), name + " sample starts from base state")
		var measurement := timed(func(): return operation.call(topology_revision))
		var result = measurement.value
		require(result is Dictionary and result.get("ok", false) and result.get("changed", false), name + " commits locally")
		var counters: Dictionary = document.get_last_operation_counters()
		var change: Dictionary = document.get_last_change()
		require(counters.operation == expected_operation and change.operation == expected_operation
			and change.brush_ids == expected_ids, name + " reports the exact operation and brush set")
		require(counters.parser_calls == 0 and counters.writer_calls == 0 and counters.lm_geo_generator_calls == 0 and counters.materializations == 0 and counters.deep_clones == 0, name + " avoids compatibility work")
		values.append(measurement.usec)
		var compatibility_restore := timed(func(): return document.restore_history_state(base_state))
		require(compatibility_restore.value.get("ok", false), name + " sample restores base state")
		if not report.timings_us.has("compatibility_restore_history_state"):
			report.timings_us.compatibility_restore_history_state = []
		report.timings_us.compatibility_restore_history_state.append(compatibility_restore.usec)
	return values

func require_local_draw_delta(session: RefCounted, before: Dictionary, name: String) -> void:
	var after: Dictionary = session.draw_cache_counters()
	require(after.touched_draw_entries - before.touched_draw_entries == 1
		and after.full_cache_iterations == before.full_cache_iterations
		and after.full_cache_duplicates == before.full_cache_duplicates,
		name + " touches one draw entry and performs no full-cache work")

func frame_post_draw_boundary() -> int:
	var state := {"drawn": false}
	var completed := func(): state.drawn = true
	RenderingServer.frame_post_draw.connect(completed, CONNECT_ONE_SHOT)
	var started := Time.get_ticks_usec()
	# Enter the next frame before forcing completion. Callers that queue a redraw
	# immediately before this function therefore include that redraw callback.
	await get_tree().process_frame
	RenderingServer.force_draw()
	var deadline := started + 5000000
	while not state.drawn and Time.get_ticks_usec() < deadline:
		await get_tree().process_frame
	if not state.drawn and RenderingServer.frame_post_draw.is_connected(completed):
		RenderingServer.frame_post_draw.disconnect(completed)
	require(state.drawn, "frame_post_draw completion boundary reached")
	return Time.get_ticks_usec() - started

func document_counts(session: RefCounted, manifest: Dictionary) -> Dictionary:
	var faces := 0
	var edges := 0
	var vertices := 0
	for brush in session.draw_data():
		faces += brush.faces.size()
		edges += brush.edges.size() / 2
		vertices += brush.vertices.size()
	return {
		"brushes": session.draw_data().size(), "faces": faces, "edges": edges,
		"brush_vertices": vertices, "entities": session.entity_data().size(),
		"point_markers": session.point_markers().size(),
		"preview_chunks": manifest.get("chunks", []).size(),
		"preview_triangles": manifest.get("triangle_count", 0),
		"textures": session.document.get_texture_names().size(),
	}

func graph_candidates(graph: Control, position: Vector2) -> PackedInt64Array:
	var p: Vector3 = graph.unproject(position - Vector2.ONE * 6)
	var q: Vector3 = graph.unproject(position + Vector2.ONE * 6)
	return graph.host.session.document.query_brushes_2d(graph.orientation, p.min(q), p.max(q))

func fit_graph(graph: Control, data: Array) -> void:
	if data.is_empty():
		return
	var low: Vector3 = data[0].aabb_min
	var high: Vector3 = data[0].aabb_max
	for brush in data:
		low = low.min(brush.aabb_min)
		high = high.max(brush.aabb_max)
	graph.origin = (low + high) * 0.5
	var axes: Vector2i = graph.axes()
	var extent := Vector2(maxf(high[axes.x] - low[axes.x], 1.0), maxf(high[axes.y] - low[axes.y], 1.0))
	graph.zoom = clampf(minf(maxf(graph.size.x - 24, 1) / extent.x, maxf(graph.size.y - 36, 1) / extent.y), 0.02, 64.0)
	graph.queue_view_redraw()

func finish(code: int) -> void:
	if not failed:
		var file := FileAccess.open("res://current-editor-performance-result.json", FileAccess.WRITE)
		if require(file != null, "result output opens"):
			file.store_string(JSON.stringify(report, "\t") + "\n")
			file.close()
	if not failed:
		var counts: Dictionary = report.checkpoints.populated_production_caches.counts
		print("TB_CURRENT_EDITOR_PERF_COUNTS:%d:%d:%d:%d" % [counts.brushes, counts.faces, counts.preview_triangles, counts.entities])
		print(MARKER)
	get_tree().quit(1 if failed else code)

func run() -> void:
	for frame in 10:
		await get_tree().process_frame
	while EditorInterface.get_resource_filesystem().is_scanning() or EditorInterface.get_resource_filesystem().is_importing():
		await get_tree().process_frame
	var plugin := find_tb_plugin(get_tree().root)
	if not require(plugin != null and plugin.map_editor != null, "current production Radiant editor is active"):
		finish(1)
		return
	var ui: Control = plugin.map_editor
	EditorInterface.set_main_screen_editor("Radiant")
	plugin._make_visible(true)
	await get_tree().process_frame
	# No redraw is explicitly requested for this baseline boundary.
	var empty_boundary_us := await frame_post_draw_boundary()
	if failed:
		finish(1)
		return
	report = {
		"schema": 2,
		"scope": "current_editor_tohunga",
		"fixture": FIXTURE,
		"fixture_sha256": FileAccess.get_file_as_string(FIXTURE).sha256_text(),
		"engine": Engine.get_version_info(),
		"display_driver": DisplayServer.get_name(),
		"rendering_method": RenderingServer.get_current_rendering_method(),
		"debug_build": OS.is_debug_build(),
		"clock": "Time.get_ticks_usec (monotonic)",
		"samples": int(OS.get_environment("TB_CURRENT_EDITOR_PERF_SAMPLES")),
		"timings_us": {"empty_editor_frame_post_draw_boundary": empty_boundary_us},
		"checkpoints": {},
		"checkpoint_order": [],
		"limitations": [
			"frame_post_draw is only a render synchronization boundary, not input-to-photon latency",
			"RSS includes the editor, renderer, extension, native allocations, and allocator retention",
			"Godot static memory excludes some native malloc allocations",
			"local mutation samples run after every memory checkpoint; base restoration and topology-token refresh are outside timed intervals",
		],
		"local_mutation_order": "after_full_visible_grids_camera_after_render_sync",
	}
	if not require(report.fixture_sha256 == FIXTURE_SHA256, "Tohunga fixture identity matches") or not require(report.samples > 0, "positive sample count"):
		finish(1)
		return
	checkpoint("empty_editor", {
		"brushes": ui.session.document.get_draw_data().size(),
		"entities": ui.session.document.get_entities().size(),
		"map_ui_visible": int(ui.is_visible_in_tree()),
	})
	var Session = load("res://addons/tbloader/src/editor/map_session.gd")
	var candidate: RefCounted = Session.new()
	var loaded := timed(func(): return candidate.document.load_map(FIXTURE))
	report.timings_us.load_native_document = loaded.usec
	report.load_counters = candidate.document.get_last_operation_counters().duplicate(true)
	if not require(loaded.value is Dictionary and loaded.value.get("ok", false), "native Tohunga load succeeds"):
		candidate.dispose()
		finish(1)
		return
	# Take this memory sample before any session draw/entity or native chunk accessor.
	checkpoint("loaded_native_document", {
		"path_set": int(not candidate.document.get_path().is_empty()),
		"revision": candidate.document.get_revision(),
		"session_draw_cache_valid": int(candidate._draw_valid),
	})
	var cache_build := timed(func():
		candidate.draw_data()
		candidate.entity_data()
		candidate.point_markers())
	report.timings_us.populate_production_session_caches = cache_build.usec
	var manifest: Dictionary = candidate.document.prepare_preview_chunks(38.0, PackedInt64Array(), 0)
	var counts := document_counts(candidate, manifest)
	require(report.load_counters.parser_calls == 1 and report.load_counters.writer_calls == 1
		and report.load_counters.lm_geo_generator_calls == 0 and report.load_counters.brush_builds == counts.brushes,
		"native load parses/canonicalizes once and builds one compact geometry per brush")
	report.timings_us.production_session_cache_hits = samples(func():
		candidate.draw_data()
		candidate.entity_data()
		candidate.point_markers(), report.samples)
	checkpoint("populated_production_caches", counts)
	var attach := timed(func(): ui.set_session(candidate))
	report.timings_us.attach_session_and_initial_camera_rebuild = attach.usec
	await get_tree().process_frame
	var data: Array = candidate.draw_data()
	var preview_brush: Dictionary = data[0]
	var preview_ids := PackedInt64Array([preview_brush.id])
	var preview_component := [{"brush_id": preview_brush.id, "kind": "face", "index": 0,
		"topology_revision": preview_brush.topology_revision}]
	var preview_revision: int = candidate.document.get_revision()
	var preview_text: String = candidate.document.export_text().value
	report.timings_us.native_preview_translate_one_brush = preview_samples(func():
		return candidate.document.preview_translate_brushes(preview_ids, Vector3(candidate.grid, 0, 0)), report.samples, "one-brush translation preview")
	report.timings_us.native_preview_rotate_one_brush = preview_samples(func():
		return candidate.document.preview_rotate_brushes(preview_ids,
			(preview_brush.aabb_min + preview_brush.aabb_max) * 0.5, 2, PI / 2), report.samples, "one-brush rotation preview")
	report.timings_us.native_preview_translate_face_component = preview_samples(func():
		return candidate.document.preview_translate_components(preview_component,
			preview_brush.faces[0].normal * candidate.grid), report.samples, "face component translation preview")
	require(candidate.document.get_revision() == preview_revision and candidate.document.export_text().value == preview_text,
		"native preview samples preserve document revision and canonical text")
	fit_graph(ui.graph_a, data)
	fit_graph(ui.graph_b, data)
	ui.camera_view.frame_selection()
	ui.camera_view.rendered_key = ""
	var camera_rebuild := timed(func(): ui.camera_view.refresh())
	report.timings_us.camera_rebuild_cache_reconcile = camera_rebuild.usec
	var pick_position := Vector2.ZERO
	var pick_id := 0
	for brush in data:
		pick_position = ui.graph_a.project((brush.aabb_min + brush.aabb_max) * 0.5)
		pick_id = ui.graph_a.hit_brush(pick_position)
		if pick_id:
			break
	var miss_position: Vector2 = ui.graph_a.project(data[0].aabb_max + Vector3.ONE * 1000000)
	var hit_candidates := graph_candidates(ui.graph_a, pick_position)
	var miss_candidates := graph_candidates(ui.graph_a, miss_position)
	if require(pick_id != 0 and not hit_candidates.is_empty(), "a visible 2D brush candidate is available for picking") and require(miss_candidates.is_empty() and ui.graph_a.hit_brush(miss_position) == 0, "representative 2D miss has no broad-phase candidates"):
		report.graph_hit_candidates = {
			"hit": {"count": hit_candidates.size(), "result": pick_id},
			"miss": {"count": miss_candidates.size(), "result": 0},
		}
		report.timings_us.graph_candidate_query_hit = samples(func(): return graph_candidates(ui.graph_a, pick_position), report.samples)
		report.timings_us.graph_hit_brush_hit = samples(func(): return ui.graph_a.hit_brush(pick_position), report.samples)
		report.timings_us.graph_candidate_query_miss = samples(func(): return graph_candidates(ui.graph_a, miss_position), report.samples)
		report.timings_us.graph_hit_brush_miss = samples(func(): return ui.graph_a.hit_brush(miss_position), report.samples)
	var camera_pick_hits: Array = []
	var camera_pick_misses: Array = []
	for index in report.samples:
		candidate.select(PackedInt64Array(), PackedInt64Array())
		var camera_pick := timed(func(): ui.camera_view.pick(ui.camera_view.size * 0.5, false))
		if not candidate.selected.is_empty() or not candidate.points.is_empty():
			camera_pick_hits.append(camera_pick.usec)
		else:
			camera_pick_misses.append(camera_pick.usec)
	if not camera_pick_hits.is_empty():
		report.timings_us.camera_pick_and_selection_refresh_hit = camera_pick_hits
	if not camera_pick_misses.is_empty():
		report.timings_us.camera_pick_full_scan_miss = camera_pick_misses
	# Flush redraws queued by selection changes, then isolate one explicit full-grid
	# redraw through the next rendering completion boundary.
	await frame_post_draw_boundary()
	ui.graph_a.queue_view_redraw()
	ui.graph_b.queue_view_redraw()
	report.timings_us.grid_redraw_queue_to_frame_post_draw = await frame_post_draw_boundary()
	ui.graph_a.reset_render_counters()
	candidate.select(PackedInt64Array([data[1].id]))
	report.timings_us.selection_layer_queue_to_frame_post_draw = await frame_post_draw_boundary()
	var selection_layer_counts: Dictionary = ui.graph_a.render_counters()
	require(selection_layer_counts.static_redraws == 0 and selection_layer_counts.static_edge_builds == 0
		and selection_layer_counts.selection_redraws > 0 and selection_layer_counts.camera_redraws == 0,
		"isolated selection change does not redraw or rebuild static graph edges")
	ui.graph_a.reset_render_counters()
	ui.graph_a.set_camera_pose(Vector3(1234, 5678, 90), Vector3(1, 2, 3))
	report.timings_us.camera_marker_queue_to_frame_post_draw = await frame_post_draw_boundary()
	var camera_layer_counts: Dictionary = ui.graph_a.render_counters()
	require(camera_layer_counts.static_redraws == 0 and camera_layer_counts.static_edge_builds == 0
		and camera_layer_counts.selection_redraws == 0 and camera_layer_counts.camera_redraws > 0,
		"isolated camera marker change redraws only its graph layer")
	report.graph_render_boundaries = {"selection_change": selection_layer_counts,
		"camera_marker": camera_layer_counts}
	# Break down the synchronous path used when a grid move is committed.
	candidate.select(PackedInt64Array([data[0].id]))
	report.timings_us.selection_refresh_cache_hit = samples(func(): ui.refresh_selection(), report.samples)
	require(candidate.document.get_revision() == preview_revision and candidate.document.export_text().value == preview_text,
		"selection refresh samples preserve document revision and canonical text")
	# Real drags begin from an already rendered selection. Establish that A-state
	# dense cache before measuring the A -> B -> A -> B history cycle.
	await frame_post_draw_boundary()
	var before_move_text: String = candidate.document.export_text().value
	var dense_before_generation: int = candidate.document.get_state_generation()
	var move_capture_before := timed(func(): return candidate.capture())
	report.timings_us.move_capture_before = move_capture_before.usec
	var move_draw_before: Dictionary = candidate.draw_cache_counters()
	var move_connected := timed(func(): return candidate.translate_brushes(candidate.selected, Vector3(candidate.grid, 0, 0)))
	report.timings_us.move_connected_session_translation = move_connected.usec
	require_local_draw_delta(candidate, move_draw_before, "connected production translation")
	var native_change: Dictionary = candidate.document.get_last_change()
	require(native_change.before_generation == dense_before_generation and native_change.generation == candidate.document.get_state_generation()
		and native_change.operation == &"translate_brushes" and native_change.generation == dense_before_generation + 1,
		"translation exposes its exact dense-cache predecessor")
	var empty_point_move := timed(func(): return candidate.document.translate_point_entities(PackedInt64Array(), Vector3(candidate.grid, 0, 0)))
	report.timings_us.move_empty_point_translation = empty_point_move.usec
	var move_capture_after := timed(func(): return candidate.capture())
	report.timings_us.move_capture_after = move_capture_after.usec
	var after_move_text: String = candidate.document.export_text().value
	ui.graph_a.reset_render_counters()
	var move_refresh := timed(func():
		candidate.change_kind = "brush_translation"
		candidate.changed.emit()
		candidate.change_kind = "")
	report.timings_us.move_session_refresh = move_refresh.usec
	ui.graph_a.apply_dense_translation(Vector3(candidate.grid, 0, 0))
	ui.graph_b.apply_dense_translation(Vector3(candidate.grid, 0, 0))
	report.timings_us.move_following_frame = await frame_post_draw_boundary()
	var grid_move_layer_counts: Dictionary = ui.graph_a.render_counters()
	require(grid_move_layer_counts.static_redraws > 0 and grid_move_layer_counts.static_edge_builds == 0,
		"grid translation patches the queued dense static redraw without rebuilding all edges")
	report.graph_render_boundaries.grid_translation = grid_move_layer_counts
	var undo_restore_samples: Array = []
	var undo_frame_samples: Array = []
	var redo_restore_samples: Array = []
	var redo_frame_samples: Array = []
	for index in report.samples:
		var undo_draw_before: Dictionary = candidate.draw_cache_counters()
		var undo := timed(func(): candidate.restore(move_capture_before.value))
		undo_restore_samples.append(undo.usec)
		require_local_draw_delta(candidate, undo_draw_before, "connected production undo")
		require(candidate.document.export_text().value == before_move_text, "session undo restores exact Tohunga text")
		undo_frame_samples.append(await frame_post_draw_boundary())
		var redo_draw_before: Dictionary = candidate.draw_cache_counters()
		var redo := timed(func(): candidate.restore(move_capture_after.value))
		redo_restore_samples.append(redo.usec)
		require_local_draw_delta(candidate, redo_draw_before, "connected production redo")
		require(candidate.document.export_text().value == after_move_text, "session redo restores exact Tohunga text")
		redo_frame_samples.append(await frame_post_draw_boundary())
	report.timings_us.undo_session_restore = undo_restore_samples
	report.timings_us.undo_following_frame = undo_frame_samples
	report.timings_us.redo_session_restore = redo_restore_samples
	report.timings_us.redo_following_frame = redo_frame_samples
	if failed:
		finish(1)
		return
	counts.camera_triangles = ui.camera_view.triangle_count
	counts.camera_geometry_chunks = ui.camera_view.geometry_chunks.size()
	counts.camera_mesh_instances = ui.camera_view.map_geometry.get_child_count()
	counts.graph_a_width = roundi(ui.graph_a.size.x)
	counts.graph_a_height = roundi(ui.graph_a.size.y)
	counts.graph_b_width = roundi(ui.graph_b.size.x)
	counts.graph_b_height = roundi(ui.graph_b.size.y)
	counts.camera_width = roundi(ui.camera_view.size.x)
	counts.camera_height = roundi(ui.camera_view.size.y)
	counts.camera_pick_hits = camera_pick_hits.size()
	counts.camera_pick_misses = camera_pick_misses.size()
	counts.visible_graphs = int(ui.graph_a.is_visible_in_tree()) + int(ui.graph_b.is_visible_in_tree())
	counts.visible_camera = int(ui.camera_view.is_visible_in_tree())
	checkpoint("full_visible_grids_camera_after_render_sync", counts)
	if not require(counts.brushes > 100 and counts.faces > 0 and counts.preview_triangles > 0 and counts.entities > 1,
		"representative document counts are positive") or not require(counts.camera_triangles == counts.preview_triangles,
		"camera contains every visible preview triangle") or not require(counts.visible_graphs == 2 and counts.visible_camera == 1,
		"both grids and camera are visible"):
		finish(1)
		return
	# Local mutations are intentionally last so none of their allocations or cache
	# invalidations can alter the historical memory checkpoints above.
	candidate.restore(move_capture_before.value)
	var measured_sizes := {}
	for texture_name in candidate.document.get_texture_names():
		measured_sizes[texture_name] = Vector2i(64, 32)
	var texture_sizes_memory_before := memory()
	var texture_draw_before: Dictionary = candidate.draw_cache_counters()
	var texture_sizes_measurement := timed(func(): return candidate.document.set_texture_sizes(measured_sizes))
	var texture_draw_after: Dictionary = candidate.draw_cache_counters()
	var texture_sizes_memory_after := memory()
	report.timings_us.set_texture_sizes_uv_only = texture_sizes_measurement.usec
	report.set_texture_sizes_counters = candidate.document.get_last_operation_counters().duplicate(true)
	report.set_texture_sizes_memory = {
		"before": texture_sizes_memory_before,
		"after": texture_sizes_memory_after,
		"delta_godot_static_bytes": texture_sizes_memory_after.godot_static_bytes - texture_sizes_memory_before.godot_static_bytes,
		"delta_VmRSS_bytes": texture_sizes_memory_after.VmRSS_bytes - texture_sizes_memory_before.VmRSS_bytes,
	}
	report.set_texture_sizes_draw_counters = {
		"full_draw_resets": texture_draw_after.full_draw_resets - texture_draw_before.full_draw_resets,
		"full_draw_reads": texture_draw_after.full_draw_reads - texture_draw_before.full_draw_reads,
		"preview_uv_cache_retentions": texture_draw_after.preview_uv_cache_retentions - texture_draw_before.preview_uv_cache_retentions,
	}
	require(texture_sizes_measurement.value.get("ok", false) and texture_sizes_measurement.value.get("changed", false)
		and report.set_texture_sizes_counters.source_clones == 0 and report.set_texture_sizes_counters.materializations == 0
		and report.set_texture_sizes_counters.deep_clones == 0 and report.set_texture_sizes_counters.parser_calls == 0
		and report.set_texture_sizes_counters.writer_calls == 0 and report.set_texture_sizes_counters.lm_geo_generator_calls == 0
		and report.set_texture_sizes_counters.brush_builds == 0
		and report.set_texture_sizes_counters.compact_full_builds == 0
		and report.set_texture_sizes_counters.compact_uv_updates > 0
		and report.set_texture_sizes_counters.compact_uv_copy_bytes > 0,
		"isolated texture-size change updates UV payloads and shares unaffected compact geometry")
	require(report.set_texture_sizes_draw_counters.full_draw_resets == 0
		and report.set_texture_sizes_draw_counters.full_draw_reads == 0
		and report.set_texture_sizes_draw_counters.preview_uv_cache_retentions == 1,
		"isolated texture-size change retains the populated session draw cache")
	var mutation_base: RefCounted = candidate.document.capture_history_state()
	require(candidate.document.is_history_state_current(mutation_base), "local mutation base state is restored under measured texture dimensions")
	var metric_draw_cache: Array = candidate.draw_data()
	var metric_first_brush: Dictionary = metric_draw_cache[0]
	var metric_second_brush: Dictionary = metric_draw_cache[1]
	var metric_first: int = metric_first_brush.id
	var metric_second: int = metric_second_brush.id
	var metric_initial_token: int = metric_first_brush.topology_revision
	var metric_normal: Vector3 = metric_first_brush.faces[0].normal
	var metric_center: Vector3 = (metric_first_brush.aabb_min + metric_first_brush.aabb_max) * 0.5
	var metric_uv_result: Dictionary = candidate.document.get_face_uv(metric_first, 0, metric_initial_token)
	require(metric_second_brush.topology_revision == metric_initial_token and metric_uv_result.get("ok", false),
		"local mutation inputs use the restored session draw cache topology")
	var metric_uv: Dictionary = metric_uv_result.get("value", {})
	var metric_uv_shift: Vector2 = metric_uv.get("shift", Vector2.ZERO)
	var metric_uv_rotation: float = metric_uv.get("rotation", 0.0)
	var metric_uv_scale: Vector2 = metric_uv.get("scale", Vector2.ONE)
	metric_draw_cache = []
	metric_first_brush = {}
	metric_second_brush = {}
	metric_uv_result = {}
	metric_uv = {}
	var metric_first_ids := PackedInt64Array([metric_first])
	var metric_both_ids := PackedInt64Array([metric_first, metric_second])
	report.timings_us.native_rotate_one_brush_local = mutation_samples(candidate.document, mutation_base, metric_initial_token, func(_token: int):
		return candidate.document.rotate_brushes(metric_first_ids, metric_center, 2, PI / 2), &"rotate_brushes", metric_first_ids, report.samples, "Tohunga rotate")
	report.timings_us.native_translate_one_face_local = mutation_samples(candidate.document, mutation_base, metric_initial_token, func(token: int):
		return candidate.document.translate_face(metric_first, 0, metric_normal, token), &"translate_face", metric_first_ids, report.samples, "Tohunga face translation")
	report.timings_us.native_texture_one_face_local = mutation_samples(candidate.document, mutation_base, metric_initial_token, func(token: int):
		return candidate.document.set_face_texture(metric_first, 0, "metrics/material", token), &"set_face_texture", metric_first_ids, report.samples, "Tohunga face texture")
	report.timings_us.native_uv_one_face_local = mutation_samples(candidate.document, mutation_base, metric_initial_token, func(token: int):
		return candidate.document.set_face_uv(metric_first, 0, metric_uv_shift + Vector2.ONE, metric_uv_rotation, metric_uv_scale, token), &"set_face_uv", metric_first_ids, report.samples, "Tohunga face UV")
	report.timings_us.native_atomic_two_face_local = mutation_samples(candidate.document, mutation_base, metric_initial_token, func(token: int):
		return candidate.document.apply_face_edits([{"brush_id": metric_first, "face": 0, "topology_revision": token, "texture": "metrics/one"}, {"brush_id": metric_second, "face": 0, "topology_revision": token, "texture": "metrics/two"}]), &"apply_face_edits", metric_both_ids, report.samples, "Tohunga atomic face batch")
	report.timings_us.native_move_face_component_local = mutation_samples(candidate.document, mutation_base, metric_initial_token, func(token: int):
		return candidate.document.translate_components([{"brush_id": metric_first, "kind": "face", "index": 0, "topology_revision": token}], metric_normal), &"translate_components", metric_first_ids, report.samples, "Tohunga component move")
	candidate.document.restore_history_state(mutation_base)
	require(candidate.document.translate_brushes(metric_first_ids, Vector3.RIGHT).ok, "history counter local mutation succeeds")
	var history_change: RefCounted = candidate.document.get_last_document_change()
	report.local_history = {"retained_bytes_per_action": history_change.get_retained_bytes(), "changed_brushes": history_change.get_changed_brush_count()}
	var memento_undo_samples: Array = []
	var memento_redo_samples: Array = []
	for _sample in report.samples:
		var memento_undo := timed(func(): return candidate.document.apply_document_change(history_change, false))
		if not require(memento_undo.value.ok, "timed local memento undo succeeds"):
			break
		memento_undo_samples.append(memento_undo.usec)
		var memento_redo := timed(func(): return candidate.document.apply_document_change(history_change, true))
		if not require(memento_redo.value.ok, "timed local memento redo succeeds"):
			break
		memento_redo_samples.append(memento_redo.usec)
	report.timings_us.apply_document_change_undo_local = memento_undo_samples
	report.timings_us.apply_document_change_redo_local = memento_redo_samples
	report.local_history.merge(candidate.document.get_last_operation_counters())
	require(report.local_history.retained_bytes_per_action > 0 and report.local_history.changed_brushes == 1
		and report.local_history.restore_touched_brushes == 1 and report.local_history.restore_full_resets == 0,
		"local history reports retained bytes, touched brushes, and no full reset")
	# This legacy API remains supported, but is deliberately measured only after
	# production cache and memory checkpoints because the editor no longer uses it.
	var compatibility_preview := timed(func(): return candidate.document.get_preview_data())
	report.draw_delta_counters = candidate.draw_cache_counters()
	require(report.draw_delta_counters.touched_draw_entries > 0 and report.draw_delta_counters.full_draw_resets >= 0
		and report.draw_delta_counters.full_cache_duplicates == 0
		and report.draw_delta_counters.history_cache_retained_bytes == 0, "draw delta counters report changes, resets, and zero retained history cache bytes")
	var compatibility_triangles := 0
	var compatibility_vertices := 0
	for group in compatibility_preview.value:
		compatibility_triangles += group.indices.size() / 3
		compatibility_vertices += group.vertices.size()
	report.timings_us.compatibility_get_preview_data = compatibility_preview.usec
	report.compatibility_preview = {"groups": compatibility_preview.value.size(), "triangles": compatibility_triangles, "vertices": compatibility_vertices}
	require(compatibility_triangles == counts.preview_triangles, "compatibility preview triangle count matches native chunks")
	finish(0)
