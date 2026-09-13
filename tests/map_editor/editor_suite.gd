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
	if suite not in ["editor", "ui", "reopen"]:
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
	if suite == "reopen":
		await reopen_journey(plugin)
		checks.finish(get_tree(), suite)
		return
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
	print("TB_UI_STAGE: graph/history complete; waiting for browser")
	while ui.browser.is_refreshing():
		await get_tree().process_frame
	ui.browser.set_search("icon")
	ui.browser.set_folder("res://addons")
	checks.check(ui.browser.select_path("res://addons/tbloader/icon.png"), "browser selects texture outside loader root")
	checks.check(ui.texture_field.text == "res://addons/tbloader/icon.png", "native exact project path resolves outside-root browser selection")
	ui.assign_texture()
	checks.check(ui.session.brush(id).faces[0].texture == "res://addons/tbloader/icon.png" and text().contains('"res://addons/tbloader/icon.png"'), "exact project token assigned and quoted in map")
	ui.browser.set_search("checker")
	ui.browser.set_folder("res://")
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
	print("TB_UI_STAGE: material/UV/clip/prism complete")
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
	checks.check(original_session.document.is_dirty() and not ui.unsaved_status().is_empty(), "background undo participates in editor unsaved reporting")
	checks.check(ui.session_picker.item_count >= 2, "retained sessions accessible through picker")
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
	print("TB_UI_STAGE: entities/persistence complete")
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
	await binding_journey(plugin)
	precision_journey()
	if suite == "ui":
		print("TB_UI_STAGE: capturing rendered quad")
		checks.check(DisplayServer.get_name() != "headless", "display-backed journey")
		ui.browser.set_search("")
		ui.browser.set_folder("res://")
		ui.session.select(PackedInt64Array())
		ui.camera_view.frame_selection()
		graph.origin = Vector3.ZERO
		graph.zoom = 1
		graph.grab_focus()
		ui.set_status("Journey complete • textured map + entities • graph tools and real editor undo verified")
		await get_tree().create_timer(1.0).timeout
		while EditorInterface.get_resource_filesystem().is_scanning() or EditorInterface.get_resource_filesystem().is_importing():
			await get_tree().process_frame
		# The editor can suspend redraw after the native inspector loses focus.
		# Force a current frame rather than awaiting a signal that needs new damage.
		RenderingServer.force_draw()
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

func binding_journey(plugin: EditorPlugin) -> void:
	print("TB_UI_STAGE: explicit binding and checked scene bake")
	var point_prefab = Node3D.new()
	point_prefab.name = "PlayerStart"
	var point_scene = PackedScene.new()
	point_scene.pack(point_prefab)
	checks.check(ResourceSaver.save(point_scene, "res://fixtures/info_player_start.tscn") == OK, "point entity has real bake prefab")
	point_prefab.free()
	var source = Node3D.new()
	source.name = "MapJourney"
	for name_value in ["BoundLoader", "OtherLoader"]:
		var loader = ClassDB.instantiate("TBLoader")
		loader.name = name_value
		loader.map_resource = "res://journey-copy.map"
		loader.texture_path = "res://textures"
		loader.entity_path = "res://fixtures"
		source.add_child(loader)
		loader.owner = source
		var sentinel = Node3D.new()
		sentinel.name = "PreviousOutput"
		loader.add_child(sentinel)
		sentinel.owner = source
	var packed = PackedScene.new()
	checks.check(packed.pack(source) == OK and ResourceSaver.save(packed, "res://journey-scene.tscn") == OK, "real fixture scene persisted")
	source.free()
	EditorInterface.open_scene_from_path("res://journey-scene.tscn")
	for frame in 6:
		await get_tree().process_frame
	var root = EditorInterface.get_edited_scene_root()
	checks.check(root != null, "actual scene opened in editor")
	var loader = root.get_node("BoundLoader")
	var other = root.get_node("OtherLoader")
	var selection = EditorInterface.get_selection()
	selection.clear()
	selection.add_node(loader)
	plugin.spatial_selection_changed()
	checks.check(plugin.map_control.visible and plugin.editing_loader.get_ref() == loader, "spatial toolbar follows selected loader")
	ui.bind_selected()
	checks.check(ui.session.loader.get_ref() == loader and ui.valid_binding(), "explicit Bind loads selected loader document")
	selection.clear()
	selection.add_node(other)
	plugin.spatial_selection_changed()
	checks.check(ui.session.loader.get_ref() == loader and plugin.editing_loader.get_ref() == other, "second loader selection preserves explicit binding")
	var scene_history = manager.get_history_undo_redo(manager.get_object_history_id(root))
	checks.check(loader.has_method("build_meshes_checked"), "native checked bake available")
	var hidden_ids = PackedInt64Array()
	for item in ui.session.document.get_draw_data():
		hidden_ids.append(item.id)
	ui.session.select(hidden_ids)
	ui.session.hide_selection(false)
	var baked: bool = ui.bake()
	checks.check(baked, "bound saved source checked bake succeeds: " + ui.notice.text)
	checks.check(not loader.has_node("PreviousOutput") and other.has_node("PreviousOutput"), "bake touches only bound loader")
	checks.check(ui.session.baked_text == text() and ui.status.text.contains("baked current"), "saved/baked state independently reported")
	checks.check(not loader.find_children("*", "MeshInstance3D", true, false).is_empty(), "real baked mesh output")
	checks.check(not loader.find_children("*", "CollisionShape3D", true, false).is_empty(), "real baked collision output")
	checks.check(ui.camera_view.triangle_count == 0 and not hidden_ids.is_empty(), "bake retains brushes hidden from editor preview")
	ui.session.hide_selection(true)
	checks.check(scene_history.undo() and loader.has_node("PreviousOutput"), "bake undo uses scene history and restores prior children")
	checks.check(scene_history.redo() and not loader.has_node("PreviousOutput"), "bake scene redo restores generated nodes")
	checks.check(loader.get_child(0).owner == root, "bake history restores scene ownership")
	var previous_output: Node = loader.get_child(0)
	loader.entity_path = "res://unavailable-prefabs"
	checks.check(not ui.bake() and loader.get_child(0) == previous_output, "checked entity-resource bake failure preserves exact previous output")
	checks.check(not ui.session.document.is_dirty() and ui.notice.text.contains("GENERATION_FAILED"), "bake failure distinct from saved source")
	loader.entity_path = "res://fixtures"
	ui.graph_a.grab_focus()
	ui.session.select(PackedInt64Array([ui.session.document.get_draw_data()[0].id]))
	key(KEY_SPACE)
	checks.check(ui.status.text.contains("bake stale") and not ui.bake(), "unsaved edits invalidate bake and prevent rebuild")
	key(KEY_Z, true)
	checks.check(ui.status.text.contains("baked current"), "map undo to baked content restores bake status")
	checks.check(ui.save_path("res://journey-bound.map"), "bound Save As saves separately")
	checks.check(loader.map_resource == "res://journey-copy.map" and not ui.bake(), "Save As cannot silently retarget bound loader")
	ui.update_loader_path()
	checks.check(loader.map_resource == "res://journey-bound.map", "explicit loader path update")
	checks.check(scene_history.undo() and loader.map_resource == "res://journey-copy.map", "loader path scene undo")
	checks.check(scene_history.redo() and loader.map_resource == "res://journey-bound.map", "loader path scene redo")
	checks.check(ui.bake(), "bake after explicit path update")
	EditorInterface.save_scene_as("res://journey-scene.tscn", false)
	checks.check(FileAccess.file_exists("res://journey-scene.tscn"), "baked Godot scene saved without headless thumbnail")
	# A deleted binding and scene change retain canonical document and global history.
	var kept_session = ui.session
	var kept_text = text()
	loader.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	ui._process(0)
	checks.check(not ui.valid_binding() and ui.session == kept_session and text() == kept_text, "deleted loader detaches and preserves map")
	checks.check(not ui.bake() and other.has_node("PreviousOutput"), "deleted binding never rebuilds selected other loader")
	plugin._edit(other)
	plugin.build_meshes()
	checks.check(not other.find_children("*", "MeshInstance3D", true, false).is_empty(), "legacy Build Meshes uses explicitly selected loader")
	checks.check(scene_history.undo() and other.has_node("PreviousOutput"), "legacy Build Meshes also uses scene undo history")
	var second = Node3D.new()
	second.name = "OtherScene"
	packed = PackedScene.new()
	packed.pack(second)
	ResourceSaver.save(packed, "res://other-scene.tscn")
	second.free()
	EditorInterface.open_scene_from_path("res://other-scene.tscn")
	for frame in 5:
		await get_tree().process_frame
	checks.check(ui.session == kept_session and text() == kept_text and not ui.valid_binding(), "scene switch preserves document and detaches")
	EditorInterface.set_main_screen_editor("Map")
	ui.graph_a.grab_focus()

func reopen_journey(plugin: EditorPlugin) -> void:
	checks.check(ui.open_path("res://journey-bound.map"), "fresh process opens canonical saved journey")
	checks.check(ui.session.document.get_draw_data().size() >= 2 and ui.session.point_markers().size() == 1, "fresh process retains brushes and point origin")
	checks.check(text().contains("unknown preserved") and text().contains("baseline/checker"), "fresh process retains entity and material properties")
	EditorInterface.open_scene_from_path("res://journey-scene.tscn")
	for frame in 6:
		await get_tree().process_frame
	var root = EditorInterface.get_edited_scene_root()
	var loader = root.get_node("BoundLoader")
	checks.check(not loader.find_children("*", "MeshInstance3D", true, false).is_empty(), "fresh scene restores baked meshes")
	checks.check(not loader.find_children("*", "CollisionShape3D", true, false).is_empty(), "fresh scene restores baked collision")
	plugin._edit(loader)
	ui.bind_selected()
	checks.check(ui.valid_binding() and ui.bake(), "fresh process binds and checked-rebakes saved file")
	checks.check(ui.session.baked_text == text(), "fresh process baked source equals map")

func precision_journey() -> void:
	print("TB_UI_STAGE: focused-pane, rigid/off-grid and hidden-target regressions")
	var original = ui.session
	var scratch = load("res://addons/tbloader/src/editor/map_session.gd").new()
	ui.set_session(scratch)
	ui.set_tool("Brush")
	var graph = ui.graph_b
	graph.grab_focus()
	var other_orientation: int = ui.graph_a.orientation
	for cycle in 3:
		key(KEY_TAB, true)
		checks.check(ui.graph_a.orientation == other_orientation and ui.active_graph == graph, "keyboard focus cycles only grid B %d" % cycle)
	graph.orientation = 2
	graph.origin = Vector3.ZERO
	graph.zoom = 2
	var document = scratch.document
	var one: int = document.create_cuboid(Vector3(-31.5, -31.5, -32), Vector3(32.5, 32.5, 32), "baseline/checker").value
	var two: int = document.create_cuboid(Vector3(96.5, -31.5, -32), Vector3(160.5, 32.5, 32), "baseline/checker").value
	scratch.select(PackedInt64Array([one, two]))
	var offset: Vector3 = scratch.brush(two).aabb_min - scratch.brush(one).aabb_min
	drag(graph, Vector3(0.5, 0.5, 0), Vector3(16.5, 16.5, 0))
	checks.check(scratch.brush(one).aabb_min == Vector3(-15.5, -15.5, -32), "ordinary move preserves imported half-unit offsets")
	checks.check(scratch.brush(two).aabb_min - scratch.brush(one).aabb_min == offset, "multi brush move is rigid")
	var moving_center: Vector3 = (scratch.brush(one).aabb_min + scratch.brush(one).aabb_max) * 0.5
	mouse(graph, graph.project(moving_center), true)
	motion(graph, graph.project(moving_center + Vector3(17, 4, 0)), Vector2.ZERO, false, true)
	mouse(graph, graph.project(moving_center + Vector3(17, 4, 0)), false)
	checks.check(is_zero_approx(fmod(scratch.brush(one).aabb_min.x, 16)) and is_zero_approx(fmod(scratch.brush(one).aabb_min.y, 16)), "Ctrl during drag aligns AABB reference")
	checks.check(scratch.brush(two).aabb_min - scratch.brush(one).aabb_min == offset, "AABB alignment preserves group spacing")
	var before = text()
	var count: int = ui.tokens.size()
	moving_center = (scratch.brush(one).aabb_min + scratch.brush(one).aabb_max) * 0.5
	mouse(graph, graph.project(moving_center), true)
	motion(graph, graph.project(moving_center + Vector3(32, 0, 0)))
	ui.texture_field.grab_focus()
	checks.check(graph.gesture == "" and text() == before and ui.tokens.size() == count, "focus loss cancels preview without content/history")
	graph.grab_focus()
	scratch.select(PackedInt64Array([one]))
	var brush: Dictionary = scratch.brush(one)
	var edge: Vector3 = (brush.aabb_min + brush.aabb_max) * 0.5
	edge.x = brush.aabb_max.x
	drag(graph, edge, edge - Vector3(128, 0, 0))
	checks.check(text() == before and ui.tokens.size() == count, "invalid inverted silhouette resize atomic and no history")
	ui.set_tool("Face")
	mouse(graph, graph.project(moving_center), true, MOUSE_BUTTON_LEFT, false, true)
	mouse(graph, graph.project(moving_center), false)
	checks.check(not scratch.components.is_empty(), "component selected before hide")
	key(KEY_H)
	checks.check(scratch.components.is_empty() and not scratch.selected.has(one), "H clears selected components and owner")
	var behind: int = document.create_cuboid(brush.aabb_min + Vector3(0, 0, 128), brush.aabb_max + Vector3(0, 0, 128), "baseline/checker").value
	scratch.changed.emit()
	checks.check(graph.hit_brush(graph.project(moving_center)) == behind, "visible geometry behind hidden brush remains pickable")
	scratch.select(PackedInt64Array([two, behind]))
	var all_text = text()
	key(KEY_H)
	checks.check(scratch.hidden.size() == 3 and ui.camera_view.triangle_count == 0, "multi hide filters all camera triangles")
	checks.check(ui.save_path("res://hidden.map") and text() == all_text, "hidden brushes remain in canonical saved map")
	var reopened = ClassDB.instantiate("TBMapDocument")
	reopened.load_map("res://hidden.map")
	checks.check(reopened.get_draw_data().size() == 3, "hidden save contains every brush")
	key(KEY_H, false, true)
	checks.check(scratch.selected.is_empty() and scratch.hidden.is_empty(), "multi reveal leaves no edit targets")
	ui.set_tool("Brush")
	scratch.select(PackedInt64Array([one]))
	# An invalid native vertex deformation must surface through the actual tool.
	ui.set_tool("Vertex")
	var vertex: Vector3 = scratch.brush(one).vertices[0]
	before = text()
	count = ui.tokens.size()
	drag(graph, vertex, vertex + Vector3(16, 16, 0))
	checks.check(text() == before and ui.tokens.size() == count and ui.notice.text.contains("INVALID_GEOMETRY"), "nonplanar vertex drag is rejected by real component handler")
	# Expiration on native epoch replacement must release payload and never restore.
	var old_token: RefCounted = ui.tokens.back()
	checks.check(old_token.session == scratch, "history token belongs to scratch session")
	document.new_map()
	var fresh = text()
	old_token.restore(false)
	checks.check(text() == fresh and old_token.session == null and old_token.bytes == 0, "epoch mismatch retires snapshot payload without redirect")
	scratch.save_enabled = false
	ui.set_session(original)
	graph.orientation = 1
	graph.zoom = 1
	ui.set_tool("Brush")
	ui.graph_a.grab_focus()
