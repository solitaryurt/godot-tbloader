@tool
extends EditorPlugin
## Current Map editor baseline. frame_post_draw is used only as a completion
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
	graph.queue_redraw()

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
	if not require(plugin != null and plugin.map_editor != null, "current production Map editor is active"):
		finish(1)
		return
	var ui: Control = plugin.map_editor
	EditorInterface.set_main_screen_editor("Map")
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
		],
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
	report.timings_us.production_session_cache_hits = samples(func():
		candidate.draw_data()
		candidate.entity_data()
		candidate.point_markers(), report.samples)
	checkpoint("populated_production_caches", counts)
	var attach := timed(func(): ui.set_session(candidate))
	report.timings_us.attach_session_and_initial_camera_rebuild = attach.usec
	await get_tree().process_frame
	var data: Array = candidate.draw_data()
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
	ui.graph_a.queue_redraw()
	ui.graph_b.queue_redraw()
	report.timings_us.grid_redraw_queue_to_frame_post_draw = await frame_post_draw_boundary()
	# Break down the synchronous path used when a grid move is committed.
	candidate.selected = PackedInt64Array([data[0].id])
	var move_capture_before := timed(func(): return candidate.capture())
	report.timings_us.move_capture_before = move_capture_before.usec
	var move_native := timed(func(): return candidate.translate_brushes(candidate.selected, Vector3(candidate.grid, 0, 0)))
	report.timings_us.move_native_translation = move_native.usec
	var empty_point_move := timed(func(): return candidate.document.translate_point_entities(PackedInt64Array(), Vector3(candidate.grid, 0, 0)))
	report.timings_us.move_empty_point_translation = empty_point_move.usec
	var move_capture_after := timed(func(): return candidate.capture())
	report.timings_us.move_capture_after = move_capture_after.usec
	var move_refresh := timed(func():
		candidate.change_kind = "brush_translation"
		candidate.changed.emit()
		candidate.change_kind = "")
	report.timings_us.move_session_refresh = move_refresh.usec
	ui.graph_a.apply_dense_translation(Vector3(candidate.grid, 0, 0))
	ui.graph_b.apply_dense_translation(Vector3(candidate.grid, 0, 0))
	report.timings_us.move_following_frame = await frame_post_draw_boundary()
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
	# This legacy API remains supported, but is deliberately measured only after
	# production cache and memory checkpoints because the editor no longer uses it.
	var compatibility_preview := timed(func(): return candidate.document.get_preview_data())
	var compatibility_triangles := 0
	var compatibility_vertices := 0
	for group in compatibility_preview.value:
		compatibility_triangles += group.indices.size() / 3
		compatibility_vertices += group.vertices.size()
	report.timings_us.compatibility_get_preview_data = compatibility_preview.usec
	report.compatibility_preview = {"groups": compatibility_preview.value.size(), "triangles": compatibility_triangles, "vertices": compatibility_vertices}
	require(compatibility_triangles == counts.preview_triangles, "compatibility preview triangle count matches native chunks")
	finish(0)
