@tool
extends EditorPlugin

const Checks = preload("res://checks.gd")
var checks = Checks.new()
var ui: Control
var manager: EditorUndoRedoManager
var history: UndoRedo

func _enter_tree() -> void:
	call_deferred("run")

func find_tb_plugin(node: Node) -> EditorPlugin:
	if node is EditorPlugin and node.get_script() != null:
		if node.get_script().resource_path == "res://addons/tbloader/src/plugin.gd":
			return node
	for child in node.get_children():
		var found = find_tb_plugin(child)
		if found != null:
			return found
	return null

func mouse(graph: Control, position: Vector2, pressed: bool, button_index: int = MOUSE_BUTTON_LEFT, shift = false, ctrl = false) -> void:
	var event = InputEventMouseButton.new()
	event.position = position
	event.button_index = button_index
	event.pressed = pressed
	event.shift_pressed = shift
	event.ctrl_pressed = ctrl
	graph._gui_input(event)

func motion(graph: Control, position: Vector2, relative = Vector2.ZERO, shift = false, ctrl = false) -> void:
	var event = InputEventMouseMotion.new()
	event.position = position
	event.relative = relative
	event.shift_pressed = shift
	event.ctrl_pressed = ctrl
	graph._gui_input(event)

func drag(graph: Control, p: Vector3, q: Vector3, button_index: int = MOUSE_BUTTON_LEFT, shift = false, ctrl = false) -> void:
	var start: Vector2 = graph.project(p)
	var end: Vector2 = graph.project(q)
	mouse(graph, start, true, button_index, shift, ctrl)
	motion(graph, end, end - start, shift, ctrl)
	mouse(graph, end, false, button_index, shift, ctrl)

func key(code: int, ctrl = false, shift = false) -> void:
	var event = InputEventKey.new()
	event.keycode = code
	event.pressed = true
	event.ctrl_pressed = ctrl
	event.shift_pressed = shift
	ui._input(event)

func text() -> String:
	return ui.session.document.export_text().value

func select_none() -> void:
	ui.session.select(PackedInt64Array())
	ui.set_tool("Brush")

func run() -> void:
	var suite = OS.get_environment("TB_TEST_SUITE")
	if suite == "import":
		for frame in 5:
			await get_tree().process_frame
		while EditorInterface.get_resource_filesystem().is_scanning():
			await get_tree().process_frame
		await get_tree().create_timer(1.0).timeout
		print("TB_TEST_COMPLETE:import:PASS")
		get_tree().quit(0)
		return
	if suite not in ["editor", "ui"]:
		return
	for frame in 8:
		await get_tree().process_frame
	var plugin = find_tb_plugin(get_tree().root)
	if not checks.check(plugin != null, "actual addon entered editor tree"):
		checks.finish(get_tree(), suite)
		return
	ui = plugin.map_editor
	manager = plugin.get_undo_redo()
	history = manager.get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)
	EditorInterface.set_main_screen_editor("Map")
	await get_tree().process_frame
	checks.check(Engine.is_editor_hint() and ClassDB.class_exists("TBMapDocument"), "actual editor and native document")
	checks.check(plugin._has_main_screen() and ui.is_visible_in_tree(), "Map main screen attached and visible")
	checks.check(plugin.materials_panel.is_inside_tree(), "legacy materials panel retained")
	checks.check(plugin.map_control.get_child(0).text == "Build Meshes", "legacy build toolbar retained")
	checks.check(ui.graph_a.orientation == 2 and ui.graph_b.orientation == 1, "quad starts camera/top/materials/front")
	var graph = ui.graph_a
	graph.grab_focus()
	var point = Vector3(-23.5, 17.25, 0)
	checks.check(graph.project(graph.unproject(graph.project(point))).distance_to(graph.project(point)) < 0.001, "graph projection round trip")
	var pixel = Vector2(70, 90)
	var under_cursor: Vector3 = graph.unproject(pixel)
	graph.zoom_at(pixel, 1.25)
	checks.check(graph.unproject(pixel).is_equal_approx(under_cursor), "cursor anchored zoom")
	var old_origin: Vector3 = graph.origin
	mouse(graph, pixel, true, MOUSE_BUTTON_RIGHT)
	motion(graph, pixel + Vector2(20, 10), Vector2(20, 10))
	mouse(graph, pixel + Vector2(20, 10), false, MOUSE_BUTTON_RIGHT)
	checks.check(graph.origin != old_origin, "RMB graph pan")
	var state_origin: Vector3 = graph.origin
	var state_zoom: float = graph.zoom
	key(KEY_TAB, true)
	checks.check(graph.orientation == 1 and ui.graph_b.orientation == 1, "Ctrl Tab cycles only focused pane")
	key(KEY_TAB, true)
	checks.check(graph.orientation == 0, "side orientation")
	key(KEY_TAB, true)
	checks.check(graph.orientation == 2 and graph.origin == state_origin and graph.zoom == state_zoom, "orientation restores pan and zoom")
	graph.origin = Vector3.ZERO
	graph.zoom = 1
	var before = text()
	mouse(graph, graph.project(Vector3.ZERO), true)
	checks.check(text() == before, "press inserts no geometry")
	mouse(graph, graph.project(Vector3.ZERO), false)
	checks.check(text() == before and ui.tokens.is_empty(), "degenerate click adds no history")
	drag(graph, Vector3(-65, -49, 0), Vector3(63, 47, 0))
	checks.check(ui.session.selected.size() == 1, "actual graph drag creates and selects")
	var id: int = ui.session.selected[0]
	var brush: Dictionary = ui.session.brush(id)
	checks.check(brush.aabb_min == Vector3(-64, -48, -64) and brush.aabb_max == Vector3(64, 48, 64), "snapped negative cuboid and default workzone thickness")
	checks.check(ui.tokens.size() == 1, "one gesture one action")
	checks.check(manager.get_object_history_id(ui.session) == EditorUndoRedoManager.GLOBAL_HISTORY, "map session uses real global editor history")
	checks.check(ui.camera_view.triangle_count == 12, "camera generated from native preview")
	var created = text()
	key(KEY_Z, true)
	checks.check(text() == before and ui.session.selected.is_empty(), "router undo restores geometry and selection")
	key(KEY_Y, true)
	checks.check(text() == created and ui.session.selected == PackedInt64Array([id]), "router redo uses origin snapshot")
	# A real viewport dispatch must not execute the global editor shortcut twice.
	var dispatched = InputEventKey.new()
	dispatched.keycode = KEY_Z
	dispatched.ctrl_pressed = true
	dispatched.pressed = true
	get_viewport().push_input(dispatched)
	await get_tree().process_frame
	checks.check(text() == before, "actual viewport Ctrl Z dispatch undoes exactly once")
	key(KEY_Y, true)
	var count: int = ui.tokens.size()
	mouse(graph, graph.project(Vector3.ZERO), true)
	motion(graph, graph.project(Vector3(32, 0, 0)))
	checks.check(text() == created, "gesture motion is disposable preview")
	key(KEY_ESCAPE)
	checks.check(text() == created and ui.tokens.size() == count and graph.gesture == "", "Esc cancel no history")
	for orientation in [2, 1, 0]:
		graph.orientation = orientation
		var center: Vector3 = (ui.session.brush(id).aabb_min + ui.session.brush(id).aabb_max) / 2
		var movement = Vector3.ZERO
		movement[graph.axes().x] = 16
		movement[graph.axes().y] = 16
		var original_min: Vector3 = ui.session.brush(id).aabb_min
		drag(graph, center, center + movement)
		checks.check(ui.session.brush(id).aabb_min.is_equal_approx(original_min + movement), "move preserves hidden axis %d" % orientation)
	graph.orientation = 2
	brush = ui.session.brush(id)
	var edge: Vector3 = (brush.aabb_min + brush.aabb_max) / 2
	edge.x = brush.aabb_max.x
	var original_max: Vector3 = brush.aabb_max
	drag(graph, edge, edge + Vector3(16, 0, 0))
	checks.check(ui.session.brush(id).aabb_max == original_max + Vector3(16, 0, 0), "silhouette resizes supporting plane")
	var resized = text()
	key(KEY_SPACE)
	checks.check(ui.session.selected[0] != id and ui.session.document.get_draw_data().size() == 2, "Space clone fresh ID")
	var clone: int = ui.session.selected[0]
	checks.check(ui.session.brush(clone).aabb_min == ui.session.brush(id).aabb_min + Vector3(16, 0, 0), "clone nudged on active horizontal axis")
	var clipboard: String = ui.session.document.export_selection(ui.session.selected).value
	ui.paste_text(clipboard)
	checks.check(ui.session.document.get_draw_data().size() == 3 and ui.session.selected[0] != clone, "paste imports native map clipboard in place")
	key(KEY_DELETE)
	checks.check(ui.session.document.get_draw_data().size() == 2, "Delete handler")
	key(KEY_Z, true)
	checks.check(ui.session.document.get_draw_data().size() == 3, "Delete undo")
	# Roll back paste and clone to a single deterministic brush.
	key(KEY_Z, true)
	key(KEY_Z, true)
	checks.check(text() == resized, "global action ordering")
	ui.session.select(PackedInt64Array([id]))
	var hidden_text = text()
	var was_dirty: bool = ui.session.document.is_dirty()
	key(KEY_H)
	checks.check(ui.session.hidden.has(id) and ui.session.selected.is_empty(), "H hides and clears selection")
	checks.check(graph.hit_brush(graph.project(Vector3(40, 20, 0))) == 0 and ui.camera_view.triangle_count == 0, "hidden excluded from graph picking and camera triangles")
	checks.check(text() == hidden_text and ui.session.document.is_dirty() == was_dirty, "hide is noncontent session state")
	key(KEY_H, false, true)
	checks.check(ui.session.hidden.is_empty() and ui.camera_view.triangle_count == 12 and ui.session.selected.is_empty(), "Shift H reveal without selection")
	# Directional box select/deselect through RMB handler.
	drag(graph, Vector3(-180, -180, 0), Vector3(180, 180, 0), MOUSE_BUTTON_RIGHT, true)
	checks.check(ui.session.selected.has(id), "right up box selects")
	drag(graph, Vector3(180, 180, 0), Vector3(-180, -180, 0), MOUSE_BUTTON_RIGHT, true)
	checks.check(ui.session.selected.is_empty(), "left down box deselects")
	var center: Vector3 = (ui.session.brush(id).aabb_min + ui.session.brush(id).aabb_max) / 2
	mouse(graph, graph.project(center), true, MOUSE_BUTTON_LEFT, true)
	mouse(graph, graph.project(center), false, MOUSE_BUTTON_LEFT, true)
	checks.check(ui.session.selected.has(id), "Shift click adds")
	mouse(graph, graph.project(center), true, MOUSE_BUTTON_LEFT, true)
	mouse(graph, graph.project(center), false, MOUSE_BUTTON_LEFT, true)
	checks.check(ui.session.selected.is_empty(), "Shift click toggles off")
	# Fractional creation at two zooms is identical in map coordinates.
	ui.session.grid = 0.5
	for zoom in [2.0, 8.0]:
		graph.zoom = zoom
		select_none()
		drag(graph, Vector3(-12.2, -11.8, 0), Vector3(-3.1, -2.9, 0))
		var fractional: Dictionary = ui.session.brush(ui.session.selected[0])
		checks.check(fractional.aabb_min.x == -12 and fractional.aabb_min.y == -12 and fractional.aabb_max.x == -3 and fractional.aabb_max.y == -3, "fractional negative creation independent of zoom %.1f" % zoom)
		key(KEY_Z, true)
	graph.zoom = 1
	ui.session.grid = 16
	ui.session.select(PackedInt64Array([id]))
	# Save baseline, no-op and text focus routing.
	ui.rebuild_on_save.button_pressed = false
	checks.check(ui.save_path("res://journey.map") and not ui.session.document.is_dirty(), "real atomic Save clears dirty")
	var saved = text()
	key(KEY_SPACE)
	checks.check(ui.session.document.is_dirty(), "clone after save dirty")
	key(KEY_Z, true)
	checks.check(not ui.session.document.is_dirty() and text() == saved, "undo saved baseline clears dirty")
	ui.texture_field.grab_focus()
	key(KEY_H)
	key(KEY_SPACE)
	key(KEY_Z, true)
	checks.check(text() == saved and ui.session.hidden.is_empty(), "text focus protects graph shortcuts and global undo")
	graph.grab_focus()
	# Material browser uses real EditorFileSystem and actual imported texture.
	while ui.browser.is_refreshing():
		await get_tree().process_frame
	ui.browser.set_search("checker")
	checks.check(ui.browser.get_visible_paths().has("res://textures/baseline/checker.png"), "real browser search discovers checker")
	checks.check(ui.browser.set_folder("res://textures/baseline"), "browser folder navigation")
	checks.check(ui.browser.select_path("res://textures/baseline/checker.png"), "real browser resource selection")
	checks.check(ui.texture_field.text == "baseline/checker", "browser exact map token handoff")
	ui.assign_texture()
	brush = ui.session.brush(id)
	checks.check(brush.faces.all(func(face): return face.texture == "baseline/checker"), "UI assigns every brush face")
	checks.check(ui.session.document.get_preview_data()[0].texture_size == Vector2i(64, 32), "preview uses actual asymmetric texture dimensions")
	ui.uv_fields[0].value = 7
	ui.uv_fields[1].value = -3
	ui.uv_fields[2].value = 30
	ui.uv_fields[3].value = 0.5
	ui.uv_fields[4].value = 2
	ui.apply_uv()
	brush = ui.session.brush(id)
	var uv: Dictionary = ui.session.document.get_face_uv(id, 0, brush.topology_revision).value
	checks.check(uv.shift == Vector2(7, -3) and uv.rotation == 30 and uv.scale == Vector2(0.5, 2), "UV controls write classic projection")
	# Component and clip/prism entry points are real tools, not placeholders.
	ui.set_tool("Face")
	graph.grab_focus()
	mouse(graph, graph.project(center), true, MOUSE_BUTTON_LEFT, false, true)
	mouse(graph, graph.project(center), false, MOUSE_BUTTON_LEFT, false, true)
	checks.check(ui.session.components.size() == 1, "graph face component pick")
	var face_index: int = ui.session.components[0].index
	ui.texture_field.text = "common/caulk"
	ui.assign_texture()
	var changed_faces = 0
	for face in ui.session.brush(id).faces:
		if face.texture == "common/caulk":
			changed_faces += 1
	checks.check(changed_faces == 1 and ui.session.brush(id).faces[face_index].texture == "common/caulk", "per-face material assignment isolated")
	ui.set_tool("Cut")
	graph.clip_points.clear()
	mouse(graph, graph.project(center + Vector3(0, -200, 0)), true)
	mouse(graph, graph.project(center + Vector3(0, -200, 0)), false)
	mouse(graph, graph.project(center + Vector3(0, 200, 0)), true)
	mouse(graph, graph.project(center + Vector3(0, 200, 0)), false)
	key(KEY_ENTER, false, true)
	checks.check(ui.session.selected.size() == 2 and ui.session.document.get_draw_data().size() == 2, "two-point split handler creates complementary brushes")
	key(KEY_Z, true)
	checks.check(ui.session.selected == PackedInt64Array([id]), "split undo stable brush identity")
	ui.set_tool("Brush")
	key(KEY_5, true)
	checks.check(ui.session.brush(id).faces.size() == 7, "Ctrl 5 prism handler")
	key(KEY_Z, true)
	# Entity inspector worldspawn, point marker/movement, owning brush properties.
	select_none()
	key(KEY_N)
	checks.check(ui.inspector.visible and ui.session.entity_targets().size() == 1, "N targets worldspawn with no selection")
	ui.entity_key.text = "message"
	ui.entity_value.text = "UI journey"
	ui.edit_property(false)
	checks.check(text().contains("UI journey"), "worldspawn keyval edited through inspector")
	ui.entity_class.text = "info_player_start"
	ui.create_point()
	var point_id: int = ui.session.points[0]
	checks.check(ui.session.point_markers().size() == 1, "point entity created through inspector")
	ui.inspector.hide()
	graph.grab_focus()
	var marker: Dictionary = ui.session.point_markers()[0]
	checks.check(graph.hit_point(graph.project(marker.origin)) == point_id, "point marker graph picking")
	drag(graph, marker.origin, marker.origin + Vector3(16, 32, 0))
	checks.check(ui.session.point_markers()[0].origin == marker.origin + Vector3(16, 32, 0), "graph moves point origin")
	key(KEY_Z, true)
	checks.check(ui.session.point_markers()[0].origin == marker.origin, "point movement undo")
	key(KEY_Y, true)
	ui.session.select(PackedInt64Array([id]))
	ui.entity_class.text = "func_group"
	ui.group_brushes()
	var owner_id: int = ui.session.brush(id).entity_id
	checks.check(ui.session.entity_targets() == PackedInt64Array([owner_id]), "N targets selected brush owner")
	ui.entity_key.text = "custom_key"
	ui.entity_value.text = "unknown preserved"
	ui.edit_property(false)
	checks.check(text().contains("unknown preserved"), "unknown owner property retained")
	ui.delete_entities(false)
	checks.check(not ui.session.brush(id).is_empty() and ui.session.brush(id).entity_id != owner_id, "delete entity keep brushes returns ownership")
	key(KEY_Z, true)
	checks.check(ui.session.brush(id).entity_id == owner_id, "entity delete undo restores ownership")
	checks.check(ui.save_path("res://journey.map"), "save entity/material journey")
	var journey = text()
	var original_session = ui.session
	var token: RefCounted = ui.tokens.back()
	checks.check(not ui.open_path("res://missing.map") and ui.session == original_session, "failed open keeps active session")
	checks.check(ui.open_path("res://journey.map") and text() == journey, "real reopen preserves entity ownership and UVs")
	var new_session = ui.session
	key(KEY_Z, true)
	checks.check(ui.session == new_session and text() == journey and original_session.document.export_text().value != journey, "background undo targets originating session only")
	key(KEY_Y, true)
	checks.check(original_session.document.export_text().value == journey, "background redo returns originating session to saved baseline")
	token.retire()
	token.restore(false)
	checks.check(ui.notice.text.contains("expired") and text() == journey, "retired history explicit status and no redirection")
	# Failed save and external conflict must never launch a destructive bake.
	checks.check(not ui.save_path("res://no_such_directory/map.map"), "Save As failure surfaced")
	checks.check(ui.session.document.get_path() == "res://journey.map", "failed Save As preserves path")
	var file = FileAccess.open("res://journey.map", FileAccess.WRITE)
	file.store_string(journey + "\n// external edit\n")
	file.close()
	checks.check(not ui.save_path("res://journey.map") and ui.notice.text.contains("EXTERNAL_CHANGE"), "external file conflict visible")
	checks.check(ui.save_path("res://journey-copy.map"), "Save As resolves conflict without overwrite")
	graph.grab_focus()
	ui.session.select(PackedInt64Array([ui.session.document.get_draw_data()[0].id]))
	key(KEY_SPACE)
	var dirty = text()
	ui.file_command("new")
	checks.check(ui.dirty_dialog.visible, "dirty New asks Save Discard Cancel")
	ui.dirty_dialog.canceled.emit()
	ui.dirty_dialog.hide()
	checks.check(text() == dirty, "dirty replacement cancel preserves edits")
	plugin._save_external_data()
	checks.check(not ui.session.document.is_dirty(), "actual Save All lifecycle hook saves known path")
	# Fly state and capture exit paths, with native display capture in UI suite.
	var camera = ui.camera_view
	camera.grab_focus()
	var right = InputEventMouseButton.new()
	right.pressed = true
	right.button_index = MOUSE_BUTTON_RIGHT
	camera._gui_input(right)
	checks.check(camera.flying, "RMB camera capture toggles on")
	var movement_key = InputEventKey.new()
	movement_key.keycode = KEY_W
	movement_key.pressed = true
	camera._input(movement_key)
	var camera_position: Vector3 = camera.camera.position
	camera._process(0.25)
	checks.check(camera.camera.position.distance_to(camera_position) > 1, "fly movement frame delta")
	camera._input(right)
	checks.check(not camera.flying and camera.held.is_empty(), "second RMB releases capture and keys")
	camera.start_fly()
	var escape = InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	camera._input(escape)
	checks.check(not camera.flying, "Esc releases camera")
	camera.start_fly()
	camera._notification(Control.NOTIFICATION_APPLICATION_FOCUS_OUT)
	checks.check(not camera.flying, "application focus loss releases camera")
	camera.start_fly()
	plugin._make_visible(false)
	checks.check(not camera.flying, "Map tab hide releases camera")
	plugin._make_visible(true)
	checks.check(not plugin.map_control.visible, "main screen visibility does not show spatial toolbar")
	# Explicit selection is separate from session binding.
	var loader = ClassDB.instantiate("TBLoader")
	plugin._edit(loader)
	checks.check(ui.session == new_session and ui.session.loader.get_ref() == null, "spatial selection never changes document/binding")
	plugin._edit(null)
	loader.free()
	if suite == "ui":
		checks.check(DisplayServer.get_name() != "headless", "display-backed journey")
		ui.browser.set_search("")
		ui.browser.set_folder("res://")
		ui.session.select(PackedInt64Array())
		graph.origin = Vector3.ZERO
		graph.zoom = 1
		graph.grab_focus()
		ui.set_status("Journey complete • textured map + entities • graph tools and real editor undo verified")
		await get_tree().create_timer(1.0).timeout
		await RenderingServer.frame_post_draw
		var image = EditorInterface.get_base_control().get_viewport().get_texture().get_image()
		checks.check(not image.is_empty(), "rendered Map quad")
		checks.check(image.save_png("res://editor-smoke.png") == OK, "Map journey screenshot saved")
	# Disposable project's history may be cleared only by this harness.
	manager.clear_history(EditorUndoRedoManager.GLOBAL_HISTORY, false)
	var old_ui = weakref(ui)
	var old_panel = weakref(plugin.materials_panel)
	var old_toolbar = weakref(plugin.map_control)
	ui = null
	EditorInterface.set_plugin_enabled("tbloader", false)
	await get_tree().process_frame
	await get_tree().process_frame
	checks.check(old_ui.get_ref() == null and old_toolbar.get_ref() == null and old_panel.get_ref() == null, "disable frees all Map controls")
	EditorInterface.set_plugin_enabled("tbloader", true)
	await get_tree().process_frame
	plugin = find_tb_plugin(get_tree().root)
	checks.check(plugin != null and plugin.map_editor.is_inside_tree(), "re-enable creates one fresh Map screen")
	checks.finish(get_tree(), suite)
