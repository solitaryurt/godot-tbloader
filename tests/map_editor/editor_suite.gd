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

func mouse(graph: Control, position: Vector2, pressed: bool, button_index: int = MOUSE_BUTTON_LEFT, shift = false, ctrl = false, alt = false) -> void:
	var event = InputEventMouseButton.new()
	event.position = position
	event.button_index = button_index
	event.pressed = pressed
	event.shift_pressed = shift
	event.ctrl_pressed = ctrl
	event.alt_pressed = alt
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
	if suite not in ["editor", "toolbar", "ui", "reopen"]:
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
	checks.check(plugin.materials_grid is ItemList and plugin.materials_grid.icon_mode == ItemList.ICON_MODE_TOP and plugin.materials_grid.visible, "materials panel defaults to rendered grid")
	checks.check(plugin.map_control.get_child(0).text == "Build Meshes", "legacy build toolbar retained")
	var map_toolbar: Control
	for child in ui.get_children():
		if child is HFlowContainer:
			map_toolbar = child
			break
	var toolbar_labels: Array[String] = []
	for child in map_toolbar.get_children():
		if child is Button:
			toolbar_labels.append(child.text)
	checks.check(["Select", "Brush", "Cut", "Rotate", "Face", "Edge", "Vertex", "Texture"].all(func(mode): return toolbar_labels.count(mode) == 1 and ui.tool_buttons[mode].get_parent() == map_toolbar), "map toolbar exposes each established editing mode once")
	checks.check(["New", "Open…", "Save", "Save As…"].all(func(command): return not toolbar_labels.has(command)), "map toolbar omits redundant document controls")
	checks.check(not ui.rebuild_on_save.button_pressed, "Bake on save defaults off")
	checks.check((ui.status.text.begins_with("UNSAVED •") or ui.status.text.begins_with("saved •")) and ui.status.text.contains("baked") and ui.status.text.contains("grid") and ui.status.text.contains("selected") and ui.status.text.contains("hidden"), "bottom status omits map title and retains editing state")
	var active_session = ui.session
	var background = load("res://addons/tbloader/src/editor/map_session.gd").new()
	checks.check(background.document.save_map("user://background-refresh.map").ok, "background refresh fixture starts clean")
	ui.set_session(background)
	ui.set_session(active_session)
	ui.camera_view.rendered_key = "background-refresh-sentinel"
	background.document.create_cuboid(Vector3.ZERO, Vector3.ONE * 8, "background/material")
	background.changed.emit()
	var background_label_found := false
	for index in ui.session_picker.item_count:
		background_label_found = background_label_found or ui.session_picker.get_item_text(index) == "background-refresh.map *"
	checks.check(ui.camera_view.rendered_key == "background-refresh-sentinel", "background session change skips active graphs and camera refresh")
	checks.check(background_label_found, "background session change still refreshes picker dirty status")
	background.save_enabled = false
	ui.camera_view.rendered_key = ""
	ui.refresh()
	camera_marker_regression()
	if suite == "toolbar":
		var graph = ui.graph_a
		graph.grab_focus()
		graph.origin = Vector3.ZERO
		graph.zoom = 1
		var created: Dictionary = ui.session.document.create_cuboid(Vector3(-32, -16, -16), Vector3(32, 16, 16), "rotate/material")
		ui.session.select(PackedInt64Array([created.value]))
		var before_rotate: String = text()
		key(KEY_R)
		checks.check(ui.tool == "Rotate" and ui.tool_buttons.Rotate.button_pressed, "R activates toolbar Rotate tool")
		mouse(graph, graph.project(Vector3(24, 0, 0)), true)
		motion(graph, graph.project(Vector3(0, 24, 0)))
		checks.check(graph.gesture == "rotate" and is_equal_approx(rad_to_deg(graph.rotation_angle), 90) and text() == before_rotate, "Rotate provides snapped disposable grid preview")
		mouse(graph, graph.project(Vector3(0, 24, 0)), false)
		var rotated: String = text()
		checks.check(rotated != before_rotate and ui.session.brush(created.value).aabb_min.is_equal_approx(Vector3(-16, -32, -16)), "Rotate release commits valid brush geometry")
		checks.check(history.undo() and text() == before_rotate, "Rotate action uses exact editor undo")
		checks.finish(get_tree(), suite)
		return
	checks.check(ui.camera_view.preview_lights.get_child_count() == 1 and ui.camera_view.preview_lights.get_child(0).shadow_enabled, "standalone camera uses shadowed fallback sun")
	var scene_root = Node3D.new()
	get_tree().root.add_child(scene_root)
	var scene_light = DirectionalLight3D.new()
	scene_light.rotation_degrees = Vector3(-20, 35, 5)
	scene_light.light_color = Color("d8e6ff")
	scene_light.light_energy = 2.5
	scene_light.shadow_enabled = true
	scene_root.add_child(scene_light)
	ui.session.scene = weakref(scene_root)
	ui.camera_view.sync_scene_lighting()
	var preview_light: DirectionalLight3D = ui.camera_view.preview_lights.get_child(0)
	checks.check(ui.camera_view.preview_lights.get_child_count() == 1 and preview_light.light_color == scene_light.light_color and preview_light.light_energy == scene_light.light_energy and preview_light.shadow_enabled and preview_light.global_basis.is_equal_approx(scene_light.global_basis), "camera mirrors scene DirectionalLight3D lighting and shadows")
	ui.session.scene = weakref(null)
	scene_root.free()
	ui.camera_view.sync_scene_lighting(true)
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
	var preview_nodes: Array[Node] = ui.camera_view.map_geometry.get_children()
	var caulk_preview: BaseMaterial3D = preview_nodes[0].material_override
	checks.check(caulk_preview.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA and caulk_preview.depth_draw_mode == BaseMaterial3D.DEPTH_DRAW_ALWAYS and is_equal_approx(caulk_preview.albedo_color.a, 0.26), "camera caulk preview uses depth-writing alpha transparency")
	checks.check(ui.preview_material("common/caulk", "caulk") == caulk_preview and ui.preview_material("common/caulk") != caulk_preview, "camera reuses category material cache without changing opaque variant")
	var shader_instance := MeshInstance3D.new()
	ui.camera_view.apply_preview_material(shader_instance, ShaderMaterial.new(), "entity")
	checks.check(is_equal_approx(shader_instance.transparency, 0.52), "camera applies entity transparency to custom shader materials")
	shader_instance.free()
	ui.camera_view.camera.position.x += 1
	ui.camera_view._process(0)
	checks.check(ui.camera_view.map_geometry.get_children() == preview_nodes, "camera marker update does not rebuild preview geometry")
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
	var rotation_before: String = text()
	var rotation_bounds: Dictionary = ui.session.brush(id)
	var rotation_center: Vector3 = (rotation_bounds.aabb_min + rotation_bounds.aabb_max) * 0.5
	key(KEY_R)
	checks.check(ui.tool == "Rotate" and ui.tool_buttons.Rotate.button_pressed, "R activates toolbar Rotate tool")
	mouse(graph, graph.project(rotation_center + Vector3(32, 0, 0)), true)
	motion(graph, graph.project(rotation_center + Vector3(0, 32, 0)))
	checks.check(graph.gesture == "rotate" and is_equal_approx(rad_to_deg(graph.rotation_angle), 90) and text() == rotation_before, "rotate drag shows snapped disposable preview around selection pivot")
	mouse(graph, graph.project(rotation_center + Vector3(0, 32, 0)), false)
	var rotation_after: String = text()
	var rotated_brush: Dictionary = ui.session.brush(id)
	checks.check(rotated_brush.aabb_min.is_equal_approx(Vector3(-48, -64, -64)) and rotated_brush.aabb_max.is_equal_approx(Vector3(48, 64, 64)), "top-grid rotate swaps projected brush extents and preserves hidden axis")
	checks.check(rotation_after != rotation_before and ui.tokens.size() == count + 1, "rotate release commits one action")
	key(KEY_Z, true)
	checks.check(text() == rotation_before and ui.session.brush(id).aabb_min == rotation_bounds.aabb_min, "rotate undo restores exact text and geometry")
	key(KEY_Y, true)
	checks.check(text() == rotation_after, "rotate redo restores exact canonical result")
	key(KEY_Z, true)
	ui.set_tool("Brush")
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
	# Material browser uses the loader texture root and actual imported texture.
	print("TB_UI_STAGE: graph/history complete; waiting for browser")
	while ui.browser.is_refreshing():
		await get_tree().process_frame
	ui.browser.set_search("icon")
	checks.check(not ui.browser.set_folder("res://addons") and not ui.browser.select_path("res://addons/tbloader/icon.png"), "browser cannot leave loader texture root")
	checks.check(ui.texture_field.text != "res://addons/tbloader/icon.png" and ui.session.brush(id).faces[0].texture != "res://addons/tbloader/icon.png", "outside-root texture is never assigned")
	ui.browser.set_search("checker")
	ui.browser.set_folder("res://")
	checks.check(ui.browser.get_visible_paths().has("res://textures/baseline/checker.png"), "real browser search discovers checker")
	checks.check(ui.browser.set_folder("res://textures/baseline"), "browser folder navigation")
	checks.check(ui.browser.select_path("res://textures/baseline/checker.png"), "real browser resource selection")
	checks.check(ui.texture_field.text == "baseline/checker", "browser exact map token handoff")
	ui.assign_texture()
	brush = ui.session.brush(id)
	checks.check(brush.faces.all(func(face): return face.texture == "baseline/checker"), "UI assigns every brush face")
	checks.check(ui.texture_sizes.get("baseline/checker") == Vector2i(64, 32), "production preview resolver uses actual asymmetric texture dimensions")
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
	checks.check(camera.crosshair != null and camera.crosshair.get_child_count() == 4 and camera.crosshair.is_visible_in_tree(), "active map camera displays a centered crosshair")
	var target_brush: Dictionary = ui.session.draw_data()[0]
	var target_center: Vector3 = camera.transform_map(target_brush.aabb_min + (target_brush.aabb_max - target_brush.aabb_min) * 0.5)
	camera.camera.position = target_center + Vector3(0, 0, 5)
	camera.camera.look_at(target_center)
	var expected_hits: Array = ui.session.visible_ray_hits(camera.camera_map_position(), camera.camera_map_direction(), 1e30)
	var left = InputEventMouseButton.new()
	left.pressed = true
	left.button_index = MOUSE_BUTTON_LEFT
	left.position = Vector2.ZERO
	ui.session.select(PackedInt64Array())
	camera._gui_input(left)
	checks.check(not expected_hits.is_empty() and ui.session.selected == PackedInt64Array([expected_hits[0].brush_id]), "camera LMB selects the brush under the crosshair instead of the mouse position")
	camera.grab_focus()
	var right = InputEventMouseButton.new()
	right.pressed = true
	right.button_index = MOUSE_BUTTON_RIGHT
	camera._gui_input(right)
	checks.check(camera.flying, "RMB camera capture toggles on")
	ui.session.select(PackedInt64Array())
	camera._input(left)
	checks.check(ui.session.selected == PackedInt64Array([expected_hits[0].brush_id]), "captured camera LMB selects the brush under the crosshair")
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
	ui.set_scene_active(false)
	precision_journey()
	visibility_filter_journey()
	await grid_draw_batch_regression()
	step5_native_editor_journey()
	await phase5_journey()
	await review_regressions(plugin)
	await tohunga_editor_journey()
	ui.set_scene_active(true)
	await automatic_scene_journey(plugin)
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
	var recovery = prepare_recovery_regression()
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
	ui = plugin.map_editor
	verify_recovery_regression(recovery)
	checks.finish(get_tree(), suite)

func camera_marker_regression() -> void:
	var graph = ui.graph_a
	var camera_view = ui.camera_view
	var camera_updates: Array[Vector3] = []
	var observe = func(position: Vector3, _direction: Vector3): camera_updates.append(position)
	camera_view.camera_moved.connect(observe)
	camera_view.camera.position = Vector3(2, 3, 4)
	camera_view.camera.rotation = Vector3.ZERO
	camera_view.sync_camera_marker()
	checks.check(graph.camera_position.is_equal_approx(Vector3(4, 2, 3) * camera_view.map_scale()) and graph.camera_direction.is_equal_approx(Vector3(-1, 0, 0)), "camera pose converts preview coordinates back to map coordinates")
	var projected_directions := {2: Vector2(1, -2).normalized(), 1: Vector2(1, -3).normalized(), 0: Vector2(2, -3).normalized()}
	for orientation in [2, 1, 0]:
		graph.orientation = orientation
		checks.check(graph.projected_camera_direction(Vector3(1, 2, 3)).is_equal_approx(projected_directions[orientation]), "%s camera direction projection" % [["Side", "Front", "Top"][orientation]])
	graph.orientation = 2
	camera_view.sync_camera_marker()
	checks.check(camera_updates.size() == 1, "unchanged camera pose does not request another graph update")
	var preview_sentinel = Node3D.new()
	camera_view.map_geometry.add_child(preview_sentinel)
	camera_view.camera.position += Vector3(1, 2, 3)
	camera_view._process(0)
	checks.check(graph.camera_position.is_equal_approx(Vector3(7, 3, 5) * camera_view.map_scale()) and ui.graph_b.camera_position.is_equal_approx(graph.camera_position), "camera movement updates every graph marker on the camera frame")
	checks.check(camera_updates.size() == 2, "camera movement emits one graph update")
	checks.check(preview_sentinel.get_parent() == camera_view.map_geometry, "camera marker update leaves map geometry untouched")
	camera_view.map_geometry.remove_child(preview_sentinel)
	preview_sentinel.free()
	camera_view.camera_moved.disconnect(observe)

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
	# Reproduce the enclosing scene-save order, not just the plugin hook.
	ui.rebuild_on_save.button_pressed = true
	ui.session.select(PackedInt64Array([ui.session.document.get_draw_data()[0].id]))
	ui.clone_selection(0)
	var old_signature = mesh_signature(loader)
	EditorInterface.save_scene_as("res://journey-scene.tscn", false)
	checks.check(not ui.session.document.is_dirty() and mesh_signature(loader) == old_signature, "external save writes map but defers bake beyond enclosing scene save")
	var saving_origin = ui.session
	ui.discover_scene_loaders()
	ui.set_session(load("res://addons/tbloader/src/editor/map_session.gd").new())
	ui.session.save_enabled = false
	for frame in 3:
		await get_tree().process_frame
	checks.check(mesh_signature(loader) != old_signature and EditorInterface.get_unsaved_scenes().has("res://journey-scene.tscn"), "post-save bake changes output and explicitly leaves actual editor scene dirty")
	checks.check(ui.session != saving_origin and saving_origin.baked_text == saving_origin.document.export_text().value, "deferred bake retains origin across active session switch")
	ui.set_session(saving_origin)
	EditorInterface.save_scene_as("res://journey-scene.tscn", false)
	checks.check(not EditorInterface.get_unsaved_scenes().has("res://journey-scene.tscn"), "second enclosing scene save serializes bake and clears dirty")
	var disk_scene: PackedScene = ResourceLoader.load("res://journey-scene.tscn", "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	var disk_root = disk_scene.instantiate()
	checks.check(mesh_signature(disk_root.get_node("BoundLoader")) == mesh_signature(loader), "saved scene reopen without rebake has exact mesh UV/material content")
	var evidence = FileAccess.open("res://expected-bake.bin", FileAccess.WRITE)
	evidence.store_var(mesh_signature(loader))
	evidence.close()
	disk_root.free()
	ui.rebuild_on_save.button_pressed = false
	checks.check(FileAccess.file_exists("res://journey-scene.tscn"), "baked Godot scene saved without headless thumbnail")
	# A deleted binding and scene change retain canonical document and global history.
	var kept_session = ui.session
	var kept_text = text()
	loader.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	ui._process(0)
	checks.check(ui.session != kept_session and ui.session.loader.get_ref() == other and ui.valid_binding(), "deleted loader removes its tab and selects the remaining mapped loader")
	checks.check(ui.scene_tabs.tab_count == 1 and not ui.scene_tabs.visible, "single remaining loader opens directly without a switcher")
	plugin._edit(other)
	plugin.build_meshes()
	checks.check(not other.find_children("*", "MeshInstance3D", true, false).is_empty(), "legacy Build Meshes uses explicitly selected loader")
	checks.check(scene_history.undo(), "legacy Build Meshes also uses scene undo history")
	checks.check(ui.open_path("res://journey-bound.map"), "standalone scene-switch fixture opens")
	ui.detach()
	var retained_standalone = ui.session
	var second = Node3D.new()
	second.name = "OtherScene"
	packed = PackedScene.new()
	packed.pack(second)
	ResourceSaver.save(packed, "res://other-scene.tscn")
	second.free()
	EditorInterface.open_scene_from_path("res://other-scene.tscn")
	for frame in 5:
		await get_tree().process_frame
	checks.check(ui.scene_tabs.tab_count == 0 and not ui.scene_tabs.visible and ui.session == retained_standalone, "scene switch removes stale loader tabs and preserves the intentional standalone session")
	EditorInterface.set_main_screen_editor("Map")
	ui.graph_a.grab_focus()

func automatic_scene_journey(plugin: EditorPlugin) -> void:
	print("TB_UI_STAGE: automatic scene-loader sessions")
	var automatic = Node3D.new()
	automatic.name = "AutomaticMapJourney"
	var branch = Node3D.new()
	branch.name = "Maps"
	automatic.add_child(branch)
	branch.owner = automatic
	var nested_branch = Node3D.new()
	nested_branch.name = "Nested"
	branch.add_child(nested_branch)
	nested_branch.owner = automatic
	var automatic_loader = ClassDB.instantiate("TBLoader")
	automatic_loader.name = "OnlyLoader"
	automatic_loader.map_resource = "res://journey-copy.map"
	automatic_loader.texture_path = "res://textures-other"
	nested_branch.add_child(automatic_loader)
	automatic_loader.owner = automatic
	var empty_loader = ClassDB.instantiate("TBLoader")
	empty_loader.name = "EmptyLoader"
	branch.add_child(empty_loader)
	empty_loader.owner = automatic
	var automatic_scene = PackedScene.new()
	checks.check(automatic_scene.pack(automatic) == OK and ResourceSaver.save(automatic_scene, "res://automatic-scene.tscn") == OK, "single-loader scene persisted")
	automatic.free()
	var standalone = ui.session
	checks.check(not standalone.scene_managed, "zero-loader scene keeps an intentional standalone session")
	EditorInterface.open_scene_from_path("res://automatic-scene.tscn")
	for frame in 8:
		await get_tree().process_frame
	var automatic_root = EditorInterface.get_edited_scene_root()
	var nested = automatic_root.get_node("Maps/Nested/OnlyLoader")
	var empty = automatic_root.get_node("Maps/EmptyLoader")
	checks.check(ui.same_path(ui.session.document.get_path(), "res://journey-copy.map"), "Map tab opens the only TBLoader map in the current scene")
	checks.check(ui.session.loader.get_ref() == nested and ui.valid_binding(), "automatic discovery includes nested TBLoader nodes")
	checks.check(ui.browser._texture_root == "res://textures-other", "automatic scene map parses textures from its TBLoader Texture Path")
	checks.check(ui.scene_tabs.tab_count == 1 and not ui.scene_tabs.visible and not ui.scene_sessions.has(empty.get_instance_id()), "empty map resources are ignored and one mapped loader opens directly")
	var first_session = ui.session
	empty.map_resource = "res://journey-bound.map"
	for frame in 3:
		await get_tree().process_frame
	checks.check(ui.scene_tabs.visible and ui.scene_tabs.tab_count == 2, "map property signal exposes a switcher when a second loader becomes mapped")
	checks.check(ui.scene_tabs.get_tab_title(0) == "Maps/Nested/OnlyLoader" and ui.scene_tabs.get_tab_title(1) == "Maps/EmptyLoader", "loader tabs use unambiguous scene-relative node paths")
	ui.session.grid = 8
	ui.scene_tab_changed(1)
	var second_session = ui.session
	checks.check(second_session != first_session and second_session.loader.get_ref() == empty and ui.same_path(second_session.document.get_path(), empty.map_resource), "second loader owns a separate bound map session")
	ui.session.grid = 32
	ui.scene_tab_changed(0)
	checks.check(ui.session == first_session and ui.session.grid == 8 and second_session.grid == 32, "tab switching preserves independent loader editing state")
	ui.scene_tab_changed(1)
	ui.queue_scene_discovery()
	await get_tree().process_frame
	checks.check(ui.session == second_session and ui.scene_tabs.current_tab == 1, "rediscovery preserves the selected loader tab")
	checks.check(ui.scene_sessions.size() == 2 and ui.scene_sessions.values().count(first_session) == 1 and ui.scene_sessions.values().count(second_session) == 1, "rediscovery creates no duplicate loader sessions")
	var replaced_session = ui.session
	empty.map_resource = "res://journey-copy.map"
	for frame in 3:
		await get_tree().process_frame
	checks.check(ui.session != replaced_session and ui.session.loader.get_ref() == empty and ui.same_path(ui.session.document.get_path(), empty.map_resource), "mapped loader path changes reopen only that loader session")
	checks.check(ui.scene_tabs.current_tab == 1 and not ui.scene_sessions.values().has(replaced_session), "loader path replacement preserves the selected tab without duplicate scene sessions")
	automatic_root.get_node("Maps").name = "RenamedMaps"
	for frame in 3:
		await get_tree().process_frame
	checks.check(ui.scene_tabs.get_tab_title(0) == "RenamedMaps/Nested/OnlyLoader" and ui.scene_tabs.get_tab_title(1) == "RenamedMaps/EmptyLoader", "scene ancestor renames refresh node-identifying loader labels")
	EditorInterface.open_scene_from_path("res://other-scene.tscn")
	for frame in 6:
		await get_tree().process_frame
	checks.check(ui.scene_tabs.tab_count == 0 and ui.session == standalone, "switching to a zero-loader scene removes stale tabs and restores the intentional standalone session")

func tohunga_editor_journey() -> void:
	print("TB_UI_STAGE: local Tohunga editor regression")
	var previous_session = ui.session
	checks.check(ui.open_path("res://fixtures/tohunga.map"), "editor opens local Tohunga fixture")
	var canonical := text()
	var brushes: Array = ui.session.document.get_draw_data()
	checks.check(brushes.size() > 100 and ui.session.document.get_entities().size() > 1, "editor exposes Tohunga brush and entity topology")
	if brushes.size() >= 2:
		var preview_nodes: Array[Node] = ui.camera_view.map_geometry.get_children()
		ui.camera_view.apply_pick(brushes[0].id, 0, -1, false)
		ui.camera_view.apply_pick(brushes[1].id, 0, -1, true)
		checks.check(ui.session.selected == PackedInt64Array([brushes[0].id, brushes[1].id]), "camera Shift-click adds a second Tohunga brush")
		ui.camera_view.apply_pick(brushes[0].id, 0, -1, true)
		checks.check(ui.session.selected == PackedInt64Array([brushes[1].id]), "camera Shift-click toggles one brush out of a multi-selection")
		checks.check(ui.camera_view.map_geometry.get_children() == preview_nodes, "camera selection reuses large-map preview meshes")
		ui.clone_selection(0)
		checks.check(ui.session.document.get_draw_data().size() == brushes.size() + 1 and text() != canonical, "editor transaction edits Tohunga with native snapshots")
		var edited_preview_nodes: Array[Node] = ui.camera_view.map_geometry.get_children()
		print("TB_TOHUNGA_CHUNKS:%d:%d:%d" % [preview_nodes.size(), edited_preview_nodes.size(), preview_nodes.filter(func(node): return edited_preview_nodes.has(node)).size()])
		checks.check(preview_nodes.any(func(node): return edited_preview_nodes.has(node)), "localized Tohunga edit retains unaffected camera preview chunks")
		checks.check(history.undo() and text() == canonical, "editor undo restores exact Tohunga document")
	ui.set_session(previous_session)

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
	var evidence = FileAccess.open("res://expected-bake.bin", FileAccess.READ)
	checks.check(mesh_signature(loader) == evidence.get_var(), "fresh-process serialized bake equals final authoring output BEFORE any rebake")
	evidence.close()
	plugin._edit(loader)
	ui.bind_selected()
	checks.check(ui.valid_binding() and ui.bake(), "fresh process binds and checked-rebakes saved file")
	checks.check(ui.session.baked_text == text(), "fresh process baked source equals map")
	var recovery_evidence = FileAccess.open("res://expected-recovery.bin", FileAccess.READ)
	var expected: Array = recovery_evidence.get_var()
	recovery_evidence.close()
	for value in expected:
		checks.check(ui.sessions.any(func(origin): return origin.document.export_text().value == value and origin.document.is_dirty()), "fresh process restores unresolved recovery content")

func mesh_signature(loader: Node) -> Array:
	var result: Array = []
	for instance in loader.find_children("*", "MeshInstance3D", true, false):
		if instance.mesh == null:
			continue
		for surface in instance.mesh.get_surface_count():
			var arrays: Array = instance.mesh.surface_get_arrays(surface)
			var material = instance.mesh.surface_get_material(surface)
			var path = ""
			if material is BaseMaterial3D and material.albedo_texture != null:
				path = material.albedo_texture.resource_path
			result.append([instance.transform, arrays[Mesh.ARRAY_VERTEX], arrays[Mesh.ARRAY_NORMAL], arrays[Mesh.ARRAY_TEX_UV], arrays[Mesh.ARRAY_INDEX], path])
	return result

func review_edit(label: String) -> void:
	var id: int = ui.session.entity_targets()[0]
	ui.session.transact("Review regression " + label, func(): return ui.session.document.set_entity_property(id, "review", label))

func review_regressions(plugin: EditorPlugin) -> void:
	print("TB_UI_STAGE: independent-review lifecycle regressions")
	var original = ui.session
	ui.set_session(load("res://addons/tbloader/src/editor/map_session.gd").new())
	checks.check(ui.save_path("res://discard-regression.map"), "discard regression establishes named baseline")
	for outcome in ["cancel", "invalid"]:
		review_edit("before " + outcome)
		var current = ui.session
		ui.file_command("open")
		ui.dirty_dialog.custom_action.emit("discard")
		checks.check(ui.file_dialog.visible and current.save_enabled, "Discard waits for successful Open replacement " + outcome)
		if outcome == "cancel":
			ui.file_dialog.canceled.emit()
		else:
			ui.file_selected("res://missing-review.map")
		ui.file_dialog.hide()
		review_edit("after " + outcome)
		checks.check(ui.session == current and current.save_enabled and ui.unsaved_status().contains("discard-regression.map"), "cancelled/invalid replacement keeps subsequent edits in unsaved reporting " + outcome)
		ui.save_all()
		checks.check(not current.document.is_dirty() and FileAccess.get_file_as_string("res://discard-regression.map") == text(), "Save All saves resumed edits " + outcome)
	review_edit("successful discard")
	var retired = ui.session
	ui.file_command("open")
	ui.dirty_dialog.custom_action.emit("discard")
	ui.file_selected("res://discard-regression.map")
	ui.file_dialog.hide()
	checks.check(not retired.save_enabled and ui.session != retired, "successful replacement alone retires discarded session")
	ui.set_session(retired)
	checks.check(retired.save_enabled and not ui.unsaved_status().is_empty(), "session picker resume reactivates discarded document")
	retired.save_enabled = false
	review_edit("edit reactivates")
	checks.check(retired.save_enabled, "successful transaction reactivates discarded session")
	ui.save_all()
	# No incidental strong reference remains to the background document/token.
	var background = make_budget_background()
	ui.set_session(load("res://addons/tbloader/src/editor/map_session.gd").new())
	checks.check(history.undo(), "actual global history makes background document dirty")
	var expected: String = background.get_ref().document.export_text().value
	ui.history_total_budget = 1
	review_edit("evict all payloads")
	ui.history_total_budget = 128 * 1024 * 1024
	checks.check(ui.tokens.is_empty() and background.get_ref() != null, "real total-budget enforcement expires every token but retains background document")
	checks.check(background.get_ref().document.is_dirty() and background.get_ref().document.export_text().value == expected, "eviction preserves exact current background undo content")
	ui.session.save_enabled = false
	ui.save_all()
	checks.check(FileAccess.get_file_as_string("res://budget-regression.map") == expected and not background.get_ref().document.is_dirty(), "evicted background document remains Save All eligible")
	ui.set_session(load("res://addons/tbloader/src/editor/map_session.gd").new())
	ui.history_action_budget = 2
	for n in 3:
		review_edit("action budget %d" % n)
	checks.check(ui.tokens.size() == 2, "controlled per-session action budget actually enforces eviction")
	ui.history_action_budget = 128
	ui.history_session_budget = 1
	review_edit("byte budget")
	checks.check(ui.tokens.is_empty() and ui.session.document.is_dirty(), "controlled per-session byte budget retains dirty document without snapshots")
	ui.history_session_budget = 64 * 1024 * 1024
	ui.session.save_enabled = false
	ui.set_session(original)
	await focus_regression()
	await resolver_regression(plugin)
	ui.set_session(original)
	ui.graph_a.grab_focus()

func make_budget_background() -> WeakRef:
	ui.set_session(load("res://addons/tbloader/src/editor/map_session.gd").new())
	review_edit("budget before")
	review_edit("budget saved")
	ui.save_path("res://budget-regression.map")
	return weakref(ui.session)

func focus_regression() -> void:
	ui.set_tool("Brush")
	ui.session.select(PackedInt64Array([ui.session.document.get_draw_data()[0].id]))
	for graph in [ui.graph_a, ui.graph_b]:
		var bounds: Dictionary = ui.session.brush(ui.session.selected[0])
		var center: Vector3 = (bounds.aabb_min + bounds.aabb_max) * 0.5
		graph.origin = center
		graph.zoom = 1
		for notification in [Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT, Node.NOTIFICATION_APPLICATION_FOCUS_OUT]:
			var before = text()
			var revision: int = ui.session.document.get_revision()
			var version = history.get_version()
			mouse(graph, graph.project(center), true)
			motion(graph, graph.project(center) + Vector2(32, 0))
			checks.check(graph.gesture == "move" and graph.delta != Vector3.ZERO, "focus regression starts moved preview in pane %s" % graph.orientation)
			# Exact pinned Viewport::_drop_mouse_focus event precedes Control notification.
			var synthetic = InputEventMouseButton.new()
			synthetic.device = -1
			synthetic.position = graph.project(center) + Vector2(32, 0)
			synthetic.button_index = MOUSE_BUTTON_LEFT
			graph._gui_input(synthetic)
			checks.check(graph.gesture == "" and text() == before, "synthetic release cancels BEFORE focus notification in pane %s" % graph.orientation)
			graph.notification(notification)
			mouse(graph, synthetic.position, false)
			checks.check(text() == before and ui.session.document.get_revision() == revision and history.get_version() == version, "window/application focus cancellation has no doc/revision/history mutation in pane %s" % graph.orientation)
		# Invoke actual native Viewport notification with mouse_focus acquired via input.
		var press = InputEventMouseButton.new()
		press.position = graph.global_position + graph.project(center)
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		get_viewport().push_input(press)
		motion(graph, graph.project(center) + Vector2(32, 0))
		var before = text()
		var version = history.get_version()
		checks.check(graph.gesture == "move" and graph.delta != Vector3.ZERO, "viewport dispatch acquired moved graph gesture")
		get_viewport().propagate_notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
		checks.check(graph.gesture == "" and text() == before and history.get_version() == version, "native viewport release then propagated window focus-out cancels without committing")
		await get_tree().process_frame

func resolver_regression(plugin: EditorPlugin) -> void:
	var root = EditorInterface.get_edited_scene_root()
	var origins: Array = []
	for folder in ["res://textures", "res://textures-other"]:
		var loader = ClassDB.instantiate("TBLoader")
		loader.texture_path = folder
		root.add_child(loader)
		loader.owner = root
		var origin = load("res://addons/tbloader/src/editor/map_session.gd").new()
		origin.document.create_cuboid(Vector3.ZERO, Vector3(64, 64, 64), "baseline/checker")
		origin.loader = weakref(loader)
		origin.scene = weakref(root)
		origin.was_bound = true
		ui.set_session(origin)
		ui.save_path("res://resolver-%d.map" % origins.size())
		loader.map_resource = origin.document.get_path()
		origins.append(origin)
	var signatures: Array = []
	for index in [0, 1, 0]:
		ui.set_session(origins[index])
		var loader = ui.session.loader.get_ref()
		while ui.browser.is_refreshing():
			await get_tree().process_frame
		var native: Dictionary = loader.resolve_material("baseline/checker")
		var preview: Material = ui.preview_material("baseline/checker")
		var size_value = Vector2i(64, 32) if index == 0 else Vector2i(16, 128)
		checks.check(ui.texture_root.text == loader.texture_path and ui.browser._texture_root == loader.texture_path, "session switch synchronizes root field and browser %d" % index)
		checks.check(ui.texture_sizes.get("baseline/checker") == size_value and preview.albedo_texture == native.texture, "A-B-A production preview uses exact native texture and dimensions %d" % index)
		var image = preview.albedo_texture.get_image()
		if image.is_compressed():
			image.decompress()
		var pixel = image.get_pixel(0, 0)
		checks.check(pixel.r > 0.9 if index == 0 else pixel.g > 0.8, "A-B-A preview texture color %d" % index)
		checks.check(ui.bake(), "resolver parity checked bake %d" % index)
		var signature = mesh_signature(loader)
		checks.check(signature[0][5] == native.resource_path, "baked material resolves same resource as preview %d" % index)
		checks.check(mesh_vertex_samples(loader) == mesh_vertex_samples(ui.camera_view.geometry), "camera/bake vertex-normal-UV parity for resolver %d" % index)
		signatures.append(signature)
	checks.check(signatures[0] == signatures[2] and signatures[0] != signatures[1], "A-B-A baked mesh UV/material parity restored")
	ui.configure_browser("res://textures-other")
	checks.check(ui.texture_root.text == "res://textures", "bound root UI rejects resolver disagreement")
	var previous_texture: String = ui.texture_field.text
	ui.material_selected(load("res://textures-other/baseline/checker.png"), "res://textures-other/baseline/checker.png", "baseline/checker", {"resolved": true})
	checks.check(ui.texture_field.text == previous_texture and ui.notice.text.contains("Cannot resolve"), "stale cross-root token is rejected without absolute fallback")
	ui.session.loader.get_ref().texture_path = "res://textures-other"
	ui._process(0)
	checks.check(ui.texture_root.text == "res://textures-other" and ui.preview_material("baseline/checker").albedo_texture.get_size() == Vector2(16, 128), "Inspector root change invalidates preview config")
	var detached_loader = ui.session.loader.get_ref()
	ui.detach()
	checks.check(ui.texture_root.text == "res://textures" and ui.preview_material("baseline/checker").albedo_texture.get_size() == Vector2(64, 32), "detach returns to standalone resolver and invalidates caches")
	for origin in origins:
		var loader = origin.loader.get_ref()
		if loader != null:
			loader.queue_free()
	detached_loader.queue_free()
	plugin._edit(null)

func mesh_vertex_samples(root: Node) -> Array:
	var samples: Dictionary = {}
	for instance in root.find_children("*", "MeshInstance3D", true, false):
		for surface in instance.mesh.get_surface_count():
			var arrays: Array = instance.mesh.surface_get_arrays(surface)
			for i in arrays[Mesh.ARRAY_VERTEX].size():
				var position: Vector3 = instance.global_transform * arrays[Mesh.ARRAY_VERTEX][i]
				var normal: Vector3 = instance.global_basis * arrays[Mesh.ARRAY_NORMAL][i]
				var uv: Vector2 = arrays[Mesh.ARRAY_TEX_UV][i]
				samples[str([position.snapped(Vector3.ONE * 0.0001), normal.snapped(Vector3.ONE * 0.0001), uv.snapped(Vector2.ONE * 0.0001)])] = true
	var result = samples.keys()
	result.sort()
	return result

func prepare_recovery_regression() -> Dictionary:
	ui.set_session(load("res://addons/tbloader/src/editor/map_session.gd").new())
	ui.session.document.import_text(FileAccess.get_file_as_string("res://journey-bound.map"))
	review_edit("named saved baseline")
	ui.save_path("res://recovery-named.map")
	var canonical = text()
	review_edit("named UNSAVED exact content")
	var named = text()
	var named_ref = weakref(ui.session)
	var named_document = weakref(ui.session.document)
	var old_snapshot: Dictionary = ui.session.document.snapshot().value
	ui.set_session(load("res://addons/tbloader/src/editor/map_session.gd").new())
	ui.session.document.import_text(canonical)
	review_edit("untitled UNSAVED exact content")
	var untitled = text()
	var untitled_ref = weakref(ui.session)
	ui.camera_view.start_fly()
	return {"named": named, "untitled": untitled, "canonical": canonical, "named_ref": named_ref, "document_ref": named_document, "untitled_ref": untitled_ref, "old_snapshot": old_snapshot}

func verify_recovery_regression(expected: Dictionary) -> void:
	checks.check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "disable releases captured mouse")
	checks.check(expected.named_ref.get_ref() == null and expected.untitled_ref.get_ref() == null and expected.document_ref.get_ref() == null, "disable releases original sessions and native documents even with expired history handles")
	checks.check(FileAccess.get_file_as_string("res://recovery-named.map") == expected.canonical, "disable/re-enable never overwrites named canonical file")
	for value in [expected.named, expected.untitled]:
		var matches = ui.sessions.filter(func(origin): return origin.document.export_text().value == value)
		checks.check(matches.size() == 1, "re-enable restores exact unresolved named/untitled content once")
		if matches.is_empty():
			continue
		var origin = matches[0]
		ui.set_session(origin)
		checks.check(origin.document.is_dirty() and origin.document.get_path().is_empty() and origin.save_enabled, "recovery is a dirty Save As copy with no canonical overwrite target")
		checks.check(origin.loader.get_ref() == null and origin.selected.is_empty() and origin.components.is_empty(), "recovery has no stale scene resources or native selection IDs")
		checks.check(not origin.document.restore_snapshot(expected.old_snapshot).ok, "recovery new epoch rejects old snapshot identities")
		# Bare IDs are document-local and may numerically coincide in a new epoch.
		# Recovery carries none across; truly unissued IDs must still reject.
		checks.check(not origin.document.set_entity_property(9223372036854775807, "stale", "bad").ok and text() == value, "recovery rejects unknown entity identity without mutating content")
	var evidence = FileAccess.open("res://expected-recovery.bin", FileAccess.WRITE)
	evidence.store_var([expected.named, expected.untitled])
	evidence.close()
	# Exercise Save As on the actual restored untitled session, not a surrogate.
	checks.check(ui.save_path("res://recovered-copy.map") and not ui.session.document.is_dirty(), "recovery Save As establishes clean native baseline")
	review_edit("after recovery save")
	checks.check(ui.session.document.is_dirty() and history.undo() and not ui.session.document.is_dirty(), "recovered Save As undo returns to actual clean baseline")
	checks.check(history.redo() and ui.save_path("res://recovered-copy.map") and history.undo(), "recovered session supports save at a new history baseline then undo")
	checks.check(ui.session.document.is_dirty() and text() == expected.untitled, "background recovery checkpoint retains original untitled content after undo past new saved baseline")
	ui.set_session(load("res://addons/tbloader/src/editor/map_session.gd").new())
	checks.check(ui.session.document.is_dirty(), "New has no saved baseline")
	checks.check(ui.open_path("res://recovered-copy.map") and not ui.session.document.is_dirty(), "load establishes native saved baseline after recovery")

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
	# A nonplanar cuboid corner rebuilds through the actual tool.
	ui.set_tool("Vertex")
	var vertex: Vector3 = scratch.brush(one).vertices[0]
	before = text()
	count = ui.tokens.size()
	drag(graph, vertex, vertex + Vector3(16, 16, 0))
	checks.check(text() != before and ui.tokens.size() == count + 1, "nonplanar vertex drag commits rebuilt convex hull")
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

func visibility_filter_journey() -> void:
	print("TB_UI_STAGE: quick visibility filters")
	var original = ui.session
	var scratch = load("res://addons/tbloader/src/editor/map_session.gd").new()
	ui.set_session(scratch)
	var graph = ui.graph_a
	graph.orientation = 2
	graph.origin = Vector3(256, 32, 0)
	graph.zoom = 1
	graph.grab_focus()
	var doc = scratch.document
	var caulk: int = doc.create_cuboid(Vector3(0, 0, 0), Vector3(64, 64, 64), "common/caulk").value
	var clip: int = doc.create_cuboid(Vector3(128, 0, 0), Vector3(192, 64, 64), "common/playerclip").value
	var visible: int = doc.create_cuboid(Vector3(256, 0, 0), Vector3(320, 64, 64), "baseline/checker").value
	var mixed: int = doc.create_cuboid(Vector3(384, 0, 0), Vector3(448, 64, 64), "baseline/checker").value
	var mixed_brush: Dictionary = scratch.brush(mixed)
	doc.set_face_texture(mixed, 0, "common/caulk", mixed_brush.topology_revision)
	var entity_brush: int = doc.create_cuboid(Vector3(512, 0, 0), Vector3(576, 64, 64), "baseline/checker").value
	doc.group_brushes(PackedInt64Array([entity_brush]), "func_group")
	var point: int = doc.create_point_entity("info_player_start", Vector3(640, 32, 0)).value
	scratch.changed.emit()
	checks.check(ui.camera_view.triangle_count == 60 and scratch.point_markers().size() == 1, "filter fixture renders five brushes and one point entity")
	var canonical: String = text()
	var revision: int = doc.get_revision()
	var history_version: int = history.get_version()
	scratch.select(PackedInt64Array([caulk]))
	ui.visibility_buttons.caulk.pressed.emit()
	checks.check(scratch.visibility_filters.caulk and ui.visibility_buttons.caulk.button_pressed, "Caulk quick toggle enables session filter")
	checks.check(scratch.selected.is_empty() and graph.hit_brush(graph.project(Vector3(32, 32, 0))) == 0, "caulk filter clears hidden selection and graph picking")
	checks.check(graph.hit_brush(graph.project(Vector3(416, 32, 0))) == mixed and ui.camera_view.triangle_count == 46, "mixed brush stays editable while its caulk face is camera-filtered")
	scratch.select(PackedInt64Array([mixed]))
	ui.set_tool("Face")
	checks.check(camera_handle_count(Color("ffb657")) == 5, "camera omits the handle for a material-filtered face on a mixed brush")
	ui.visibility_buttons.caulk.pressed.emit()
	ui.visibility_buttons.clips.pressed.emit()
	checks.check(graph.hit_brush(graph.project(Vector3(160, 32, 0))) == 0 and graph.hit_brush(graph.project(Vector3(288, 32, 0))) == visible, "clip filter hides clip brushes without affecting ordinary materials")
	checks.check(ui.camera_view.triangle_count == 48, "clip filter removes matching camera triangles")
	ui.visibility_buttons.clips.pressed.emit()
	scratch.select(PackedInt64Array([entity_brush]), PackedInt64Array([point]))
	ui.visibility_buttons.entities.pressed.emit()
	checks.check(scratch.selected.is_empty() and scratch.points.is_empty(), "entity filter clears brush-entity and point-entity selection")
	checks.check(graph.hit_brush(graph.project(Vector3(544, 32, 0))) == 0 and graph.hit_point(graph.project(Vector3(640, 32, 0))) == 0, "entity filter excludes entities from graph picking")
	checks.check(ui.camera_view.triangle_count == 48 and ui.camera_view.overlays.get_child_count() == 0, "entity filter excludes brush geometry and point overlays from camera")
	checks.check(text() == canonical and doc.get_revision() == revision and history.get_version() == history_version, "quick filters do not edit content or history")
	ui.visibility_buttons.entities.pressed.emit()
	checks.check(ui.camera_view.triangle_count == 60 and graph.hit_point(graph.project(Vector3(640, 32, 0))) == point, "quick toggles restore all filtered geometry without selecting it")
	scratch.save_enabled = false
	ui.set_session(original)
	checks.check(ui.visibility_buttons.values().all(func(control): return not control.button_pressed), "visibility controls follow the active document session")
	ui.graph_a.grab_focus()

func step5_native_editor_journey() -> void:
	print("TB_UI_STAGE: native spatial and preview editor integration")
	var original = ui.session
	var scratch = load("res://addons/tbloader/src/editor/map_session.gd").new()
	ui.set_session(scratch)
	var graph = ui.graph_a
	graph.orientation = 2
	graph.origin = Vector3(150, 0, 0)
	graph.zoom = 1
	graph.grab_focus()
	var doc = scratch.document
	var first: int = doc.create_cuboid(Vector3.ZERO, Vector3.ONE * 64, "baseline/checker").value
	var second: int = doc.create_cuboid(Vector3.ZERO, Vector3.ONE * 64, "baseline/checker").value
	var contained: int = doc.create_cuboid(Vector3(200, 0, 0), Vector3(240, 40, 40), "baseline/checker").value
	doc.create_cuboid(Vector3(230, 0, 0), Vector3(300, 40, 40), "baseline/checker")
	scratch.changed.emit()
	var overlap_position: Vector2 = graph.project(Vector3(32, 32, 0))
	checks.check(graph.hit_brush(overlap_position) == second, "native 2D candidates retain reverse-source overlap pick order")
	scratch.select(PackedInt64Array([first]))
	ui.set_tool("Brush")
	mouse(graph, overlap_position, true)
	checks.check(graph.gesture == "move" and scratch.selected == PackedInt64Array([first]), "selected overlapping brush retains direct-manipulation priority")
	graph.cancel()
	scratch.hidden[second] = true
	checks.check(graph.hit_brush(overlap_position) == first, "hidden broad-phase hit passes through to the next visible brush")
	scratch.hidden.clear()
	doc.group_brushes(PackedInt64Array([second]), "func_group")
	scratch.set_visibility_filter("entities", true)
	checks.check(graph.hit_brush(overlap_position) == first, "entity-filtered broad-phase hit passes through to the next visible brush")
	scratch.set_visibility_filter("entities", false)
	scratch.select(PackedInt64Array())
	graph.start = graph.project(Vector3(190, -10, 0))
	graph.box_select(graph.project(Vector3(270, 70, 0)))
	checks.check(scratch.selected == PackedInt64Array([contained]), "native box broad phase retains exact all-vertices containment")

	var ray_front: int = doc.create_cuboid(Vector3(400, -16, -16), Vector3(420, 16, 16), "common/caulk").value
	var ray_back: int = doc.create_cuboid(Vector3(440, -16, -16), Vector3(460, 16, 16), "baseline/checker").value
	var ray_origin := Vector3(350, 0, 0)
	scratch.hidden[ray_front] = true
	var hits: Array = scratch.visible_ray_hits(ray_origin, Vector3.RIGHT)
	checks.check(not hits.is_empty() and hits[0].brush_id == ray_back, "ordered native ray passes through a hidden front brush")
	scratch.hidden.clear()
	scratch.set_visibility_filter("caulk", true)
	hits = scratch.visible_ray_hits(ray_origin, Vector3.RIGHT)
	checks.check(not hits.is_empty() and hits[0].brush_id == ray_back, "ordered native ray passes through a filtered front face")
	scratch.set_visibility_filter("caulk", false)

	var marker_session = load("res://addons/tbloader/src/editor/map_session.gd").new()
	ui.set_session(marker_session)
	var marker_doc = marker_session.document
	var marker: int = marker_doc.create_point_entity("info_player_start", Vector3(350, 0, 0)).value
	var target: int = marker_doc.create_cuboid(Vector3(400, -16, -16), Vector3(420, 16, 16), "baseline/checker").value
	var loader = ClassDB.instantiate("TBLoader")
	loader.map_inverse_scale = 10.0
	marker_session.loader = weakref(loader)
	marker_session.changed.emit()
	ui.camera_view.camera.position = ui.camera_view.transform_map(Vector3(300, 0, 0))
	ui.camera_view.camera.look_at(ui.camera_view.transform_map(Vector3(450, 0, 0)))
	ui.camera_view.sync_camera_marker(true)
	checks.check(ui.camera_view.preview_to_map(ui.camera_view.camera.position).is_equal_approx(Vector3(300, 0, 0)), "camera ray origin converts through non-default map scale")
	var pick_position: Vector2 = ui.camera_view.camera.unproject_position(ui.camera_view.transform_map(Vector3(350, 0, 0)))
	ui.camera_view.pick(pick_position, false)
	checks.check(marker_session.points == PackedInt64Array([marker]) and marker_session.selected.is_empty(), "nearer marker has priority over an ordered native brush hit")
	marker_session.set_visibility_filter("entities", true)
	ui.camera_view.pick(pick_position, false)
	checks.check(marker_session.selected.has(target) and marker_session.points.is_empty(), "filtered marker passes through to native map-space ray hit")
	marker_session.set_visibility_filter("entities", false)
	ui.camera_view.rendered_key = ""
	ui.camera_view.refresh()
	var instances: Array = ui.camera_view.geometry_chunks.values().map(func(chunk): return chunk.instance)
	ui.camera_view.rendered_key = ""
	ui.camera_view.refresh()
	checks.check(not instances.is_empty() and ui.camera_view.geometry_chunks.values().all(func(chunk): return instances.has(chunk.instance)), "unchanged preview manifest reuses MeshInstances")
	checks.check(ui.camera_view.geometry_chunks.values().all(func(chunk): return not chunk.has("vertices") and not chunk.has("normals") and not chunk.has("uvs")), "integrated preview chunks retain no packed geometry arrays in GDScript")
	var replacement_material = StandardMaterial3D.new()
	replacement_material.albedo_color = Color("e34f4f")
	ui.material_cache["baseline/checker"] = replacement_material
	ui.material_generation += 1
	ui.camera_view.refresh()
	checks.check(ui.camera_view.geometry_chunks.values().all(func(chunk): return instances.has(chunk.instance)), "material-only camera refresh preserves MeshInstance identity")
	checks.check(ui.camera_view.geometry_chunks.values().all(func(chunk): return chunk.instance.material_override == replacement_material), "material-only camera refresh changes material overrides")
	scratch.save_enabled = false
	marker_session.save_enabled = false
	ui.set_session(original)
	loader.free()
	ui.graph_a.grab_focus()

func grid_draw_batch_regression() -> void:
	var original = ui.session
	var scratch = load("res://addons/tbloader/src/editor/map_session.gd").new()
	ui.set_session(scratch)
	var graph = ui.graph_a
	graph.orientation = 2
	graph.origin = Vector3.ZERO
	graph.zoom = 1
	var selected: int = scratch.document.create_cuboid(Vector3(-48, -32, -16), Vector3(-16, 32, 16), "selected/material").value
	scratch.document.create_cuboid(Vector3(16, -32, -16), Vector3(48, 32, 16), "unselected/material")
	scratch.changed.emit()
	scratch.select(PackedInt64Array([selected]))
	graph.rebuild_dense_edge_cache()
	checks.check(graph.dense_selected_edges.size() == 24 and graph.dense_unselected_edges.size() == 24, "dense grid cache separates selected and unselected cube edges")
	var dense_key: String = graph.dense_edge_cache_key
	graph.origin = Vector3(100, 200, 0)
	graph.zoom = 0.25
	checks.check(graph.current_dense_edge_key() == dense_key, "dense grid cache survives pan and zoom changes")
	scratch.hidden[selected] = true
	checks.check(graph.current_dense_edge_key() != dense_key, "dense grid cache invalidates when hidden brushes change")
	scratch.hidden.clear()
	graph.origin = Vector3.ZERO
	graph.zoom = 1
	graph.gesture = ""
	graph.queue_redraw()
	await get_tree().process_frame
	RenderingServer.force_draw()
	checks.check(graph.gesture == "" and scratch.selected == PackedInt64Array([selected]), "selected and unselected static grid edges redraw together")
	graph.gesture = "move"
	graph.delta = Vector3(16, 0, 0)
	ui.camera_view.preview_grid_move(graph.delta)
	checks.check(ui.camera_view.grid_move_preview.visible and ui.camera_view.grid_move_preview.get_child_count() == 1,
		"grid move immediately builds a visible camera preview")
	checks.check(ui.camera_view.grid_move_preview.position.is_equal_approx(ui.camera_view.transform_map_scaled(graph.delta, ui.camera_view.map_scale())),
		"camera move preview follows the snapped grid delta")
	graph.queue_redraw()
	await get_tree().process_frame
	RenderingServer.force_draw()
	checks.check(graph.gesture == "move" and graph.delta == Vector3(16, 0, 0), "move preview redraws with batched ordinary edges")
	graph.gesture = "rotate"
	graph.rotation_pivot = graph.selection_center()
	graph.rotation_angle = deg_to_rad(45)
	graph.queue_redraw()
	await get_tree().process_frame
	RenderingServer.force_draw()
	checks.check(graph.gesture == "rotate" and is_equal_approx(graph.rotation_angle, deg_to_rad(45)), "rotate preview redraws with batched ordinary edges")
	var cached_min: Vector3 = scratch.brush(selected).aabb_min
	var cached_move: Dictionary = scratch.translate_brushes(PackedInt64Array([selected]), Vector3(16, 0, 0))
	checks.check(cached_move.ok and scratch._draw_valid and scratch.brush(selected).aabb_min == cached_min + Vector3(16, 0, 0),
		"whole-brush translation patches the populated session draw cache")
	checks.check(scratch.brush(selected).topology_revision == scratch.document.get_topology_revision(),
		"translated draw cache receives the current native topology token")
	var translated_oracle = ClassDB.instantiate("TBMapDocument")
	var oracle_loaded: Dictionary = translated_oracle.import_text(scratch.document.export_text().value)
	checks.check(oracle_loaded.ok and draw_geometry_approx(translated_oracle.get_draw_data(), scratch.document.get_draw_data()),
		"incremental brush translation matches fully reparsed draw geometry")
	checks.check(preview_geometry_approx(translated_oracle.get_preview_data(), scratch.document.get_preview_data()),
		"incremental brush translation matches fully regenerated preview vertices and UVs")
	graph.cancel()
	checks.check(not ui.camera_view.grid_move_preview.visible, "ending a grid gesture clears the camera move preview")
	scratch.save_enabled = false
	ui.set_session(original)
	ui.graph_a.grab_focus()

func click_component(graph: Control, position: Vector3, toggle = false) -> void:
	mouse(graph, graph.project(position), true, MOUSE_BUTTON_LEFT, toggle)
	mouse(graph, graph.project(position), false, MOUSE_BUTTON_LEFT, toggle)

func packed_approx(a: Variant, b: Variant) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if a[i] is Vector2 or a[i] is Vector3:
			if not a[i].is_equal_approx(b[i]):
				return false
		elif a[i] != b[i]:
			return false
	return true

func draw_geometry_approx(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if not a[i].aabb_min.is_equal_approx(b[i].aabb_min) or not a[i].aabb_max.is_equal_approx(b[i].aabb_max):
			return false
		if not packed_approx(a[i].vertices, b[i].vertices) or not packed_approx(a[i].edges, b[i].edges) or a[i].edge_vertex_indices != b[i].edge_vertex_indices or a[i].faces.size() != b[i].faces.size():
			return false
		for f in a[i].faces.size():
			if not a[i].faces[f].center.is_equal_approx(b[i].faces[f].center) or not a[i].faces[f].normal.is_equal_approx(b[i].faces[f].normal) or not packed_approx(a[i].faces[f].winding, b[i].faces[f].winding):
				return false
	return true

func preview_geometry_approx(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if a[i].texture != b[i].texture or a[i].indices != b[i].indices or a[i].triangle_face_indices != b[i].triangle_face_indices:
			return false
		if not packed_approx(a[i].vertices, b[i].vertices) or not packed_approx(a[i].normals, b[i].normals) or not packed_approx(a[i].uvs, b[i].uvs):
			return false
	return true

func solid_volume(b: Dictionary) -> float:
	var center = Vector3.ZERO
	for p in b.vertices:
		center += p
	center /= b.vertices.size()
	var volume = 0.0
	var valid = b.vertices.size() - b.edge_vertex_indices.size() / 2 + b.faces.size() == 2
	for face in b.faces:
		valid = valid and face.winding.size() >= 3 and face.normal.is_normalized() and face.normal.dot(face.center - center) > 0
		for p in b.vertices:
			valid = valid and face.normal.dot(p - face.center) <= 0.001
		for p in face.winding:
			valid = valid and absf(face.normal.dot(p - face.center)) < 0.001
		for i in range(1, face.winding.size() - 1):
			var a: Vector3 = face.winding[0] - center
			var c: Vector3 = face.winding[i] - center
			var d: Vector3 = face.winding[i + 1] - center
			valid = valid and (c - a).cross(d - a).dot(face.normal) < 0
			volume -= a.dot(c.cross(d)) / 6.0
	checks.check(valid and volume > 0, "UI result has bounded convex planar outward clockwise solid")
	return volume

func camera_handle_count(color := Color()) -> int:
	var count = 0
	for child in ui.camera_view.overlays.get_children():
		if child is MeshInstance3D and child.mesh is SphereMesh and (color == Color() or child.material_override.albedo_color == color):
			count += 1
	return count

func phase5_journey() -> void:
	print("TB_UI_STAGE: Phase5 component batches, cap/clip direction and all prism axes")
	var original = ui.session
	var scratch = load("res://addons/tbloader/src/editor/map_session.gd").new()
	ui.set_session(scratch)
	var graph = ui.graph_a
	graph.grab_focus()
	graph.orientation = 2
	graph.origin = Vector3(32, 32, 32)
	graph.zoom = 2
	var doc = scratch.document
	var id: int = doc.create_cuboid(Vector3.ZERO, Vector3.ONE * 64, "baseline/checker").value
	scratch.select(PackedInt64Array([id]))
	var baseline: Dictionary = scratch.capture()
	scratch.select(PackedInt64Array())
	for component_tool in ["Face", "Edge"]:
		ui.set_tool(component_tool)
		drag(graph, Vector3(-128, -128, 32), Vector3(-64, -64, 32))
		checks.check(doc.get_draw_data().size() == 1, "%s tool cannot fall through to box creation" % component_tool)
	scratch.select(PackedInt64Array([id]))
	ui.set_tool("Face")
	checks.check(camera_handle_count() == 6, "camera shows face grab handles for selected brush")
	ui.camera_view.apply_pick(id, 0, 0, false)
	ui.camera_view.apply_pick(id, 0, 1, true)
	checks.check(scratch.selected == PackedInt64Array([id]) and scratch.components.size() == 2, "camera Shift-click adds a face without deselecting its brush")
	ui.camera_view.apply_pick(id, 0, 1, true)
	checks.check(scratch.selected == PackedInt64Array([id]) and scratch.components.size() == 1 and scratch.components[0].index == 0, "camera Shift-click toggles only the face component")
	mouse(graph, graph.project(Vector3(0, 32, 32)), true)
	checks.check(graph.gesture == "component" and graph.drag_component.kind == "face", "face grab handle starts component edit, not box creation")
	mouse(graph, graph.project(Vector3(0, 32, 32)), false)
	checks.check(camera_handle_count(Color("ffe6a6")) == 1, "camera highlights selected face handle")
	click_component(graph, Vector3(0, 32, 32))
	click_component(graph, Vector3(64, 32, 32), true)
	checks.check(scratch.components.size() == 2, "Shift adds second face")
	click_component(graph, Vector3(64, 32, 32), true)
	checks.check(scratch.components.size() == 1, "Shift toggles selected face off")
	click_component(graph, Vector3(64, 32, 32), true)
	await capture_phase5("faces")
	var before = text()
	var count: int = ui.tokens.filter(func(token): return token.session == scratch).size()
	drag(graph, Vector3(0, 32, 32), Vector3(128, 32, 32))
	checks.check(scratch.brush(id).aabb_min.x == 128 and scratch.brush(id).aabb_max.x == 192, "graph moves all selected planes atomically past invalid intermediate hull")
	checks.check(ui.tokens.filter(func(token): return token.session == scratch).size() == count + 1, "multi-face gesture records exactly one originating-session action")
	checks.check(scratch.components.size() == 2, "successful face batch retains both selections")
	var moved = text()
	key(KEY_Z, true)
	checks.check(text() == before and scratch.components.size() == 2 and scratch.components.all(func(c): return scratch.component_valid(c, scratch.brush(c.brush_id))), "face batch undo restores selection with fresh topology guards")
	key(KEY_Y, true)
	checks.check(text() == moved and scratch.components.size() == 2, "face batch redo restores geometry and selected faces")
	key(KEY_Z, true)
	# Assign to a selected face and compare every other plane, winding and UV.
	click_component(graph, Vector3(64, 32, 32), true)
	var selected_face: int = scratch.components[0].index
	var source: Dictionary = scratch.brush(id)
	var uvs: Array = []
	for face in source.faces:
		uvs.append(doc.get_face_uv(id, face.index, source.topology_revision).value)
	ui.texture_field.text = "common/caulk"
	ui.assign_texture()
	var textured: Dictionary = scratch.brush(id)
	for face in textured.faces:
		checks.check(face.winding == source.faces[face.index].winding and face.normal == source.faces[face.index].normal and doc.get_face_uv(id, face.index, textured.topology_revision).value == uvs[face.index], "selected-face material preserves every plane and UV")
		checks.check(face.texture == ("common/caulk" if face.index == selected_face else "baseline/checker"), "selected-face material affects only selected index")
	key(KEY_Z, true)
	checks.check(text() == before and scratch.components.size() == 1, "material undo restores selected face")
	# A stale component cannot be silently rebound by material or deformation tools.
	var stale: Array = scratch.components.duplicate(true)
	doc.rebuild()
	scratch.components = stale
	count = ui.tokens.size()
	ui.assign_texture()
	checks.check(text() == before and ui.tokens.size() == count and ui.notice.text.contains("STALE_COMPONENT"), "material assignment rejects stale selection")
	checks.check(not scratch.transact("Stale component test", func(): return scratch.move_components(Vector3(16, 0, 0))) and text() == before and ui.tokens.size() == count, "batch deformation rejects stale selection without history")
	scratch.transact("Create beside stale selection", func(): return doc.create_cuboid(Vector3(128, 0, 0), Vector3(192, 64, 64), "baseline/checker"))
	key(KEY_Z, true)
	checks.check(text() == before and scratch.components.is_empty(), "unrelated edit undo never revives a stale component as a fresh index")
	scratch.restore(baseline)
	ui.set_tool("Edge")
	checks.check(camera_handle_count() == 12, "camera shows edge grab handles for selected brush")
	mouse(graph, graph.project(Vector3(64, 0, 32)), true)
	checks.check(graph.gesture == "component" and graph.drag_component.kind == "edge", "edge grab handle starts component edit, not box creation")
	mouse(graph, graph.project(Vector3(64, 0, 32)), false)
	checks.check(camera_handle_count(Color("ffe6a6")) == 1, "camera highlights selected edge handle")
	click_component(graph, Vector3(64, 0, 32))
	click_component(graph, Vector3(64, 64, 32), true)
	checks.check(scratch.components.size() == 2, "Shift adds second edge")
	click_component(graph, Vector3(64, 64, 32), true)
	checks.check(scratch.components.size() == 1, "Shift toggles edge off")
	click_component(graph, Vector3(64, 64, 32), true)
	count = ui.tokens.size()
	mouse(graph, graph.project(Vector3(64, 64, 32)), true)
	motion(graph, graph.project(Vector3(96, 80, 32)), Vector2.ZERO, true)
	checks.check(graph.delta == Vector3(32, 0, 0) and text() == before, "axis constraint applies after component reference snapping; preview is disposable")
	mouse(graph, graph.project(Vector3(96, 80, 32)), false)
	checks.check(scratch.brush(id).aabb_max == Vector3(96, 64, 64) and scratch.components.size() == 2 and ui.tokens.size() == count + 1, "all selected edges move together with one constrained commit")
	checks.check(is_equal_approx(solid_volume(scratch.brush(id)), 96 * 64 * 64), "edge batch expected expanded volume")
	await capture_phase5("edges")
	key(KEY_Z, true)
	checks.check(text() == before and scratch.components.size() == 2, "edge batch undo selection")
	key(KEY_Y, true)
	checks.check(scratch.components.size() == 2 and scratch.components.all(func(c): return scratch.component_valid(c, scratch.brush(id))), "edge batch redo safely remaps edge handles")
	key(KEY_Z, true)
	# A single cuboid corner rebuilds the convex hull, splitting nonplanar sides.
	ui.set_tool("Vertex")
	mouse(graph, graph.project(Vector3(32, 32, 32)), true, MOUSE_BUTTON_LEFT, false, true)
	mouse(graph, graph.project(Vector3(32, 32, 32)), false, MOUSE_BUTTON_LEFT, false, true)
	checks.check(scratch.components.size() == 1 and scratch.components[0].kind == "face", "Ctrl LMB retains quick-face selection in component modes")
	ui.set_tool("Vertex")
	click_component(graph, Vector3(64, 64, 0))
	mouse(graph, graph.project(Vector3(64, 64, 0)), true, MOUSE_BUTTON_LEFT, true, false, true)
	mouse(graph, graph.project(Vector3(64, 64, 0)), false, MOUSE_BUTTON_LEFT, true, false, true)
	checks.check(scratch.components.size() == 2 and scratch.components[0].index != scratch.components[1].index, "Shift Alt adds coincident far-side vertex without losing near-side selection")
	drag(graph, Vector3(64, 64, 0), Vector3(80, 64, 0))
	checks.check(scratch.brush(id).vertices.has(Vector3(80, 64, 0)) and scratch.brush(id).vertices.has(Vector3(80, 64, 64)), "incident grouped cube vertices move as a valid constrained edge")
	key(KEY_Z, true)
	ui.set_tool("Vertex")
	var revision: int = doc.get_revision()
	count = ui.tokens.size()
	drag(graph, Vector3(64, 64, 0), Vector3(80, 80, 0))
	checks.check(text() != before and Array(scratch.brush(id).vertices).any(func(point): return point.x == 80 and point.y == 80) and doc.get_revision() > revision and ui.tokens.size() == count + 1, "single quad corner rebuilds and commits convex hull")
	key(KEY_Z, true)
	checks.check(text() == before, "single-corner hull edit undo restores brush")
	# A valid first brush and invalid second brush must both remain untouched.
	var second: int = doc.create_cuboid(Vector3(128, 0, 0), Vector3(192, 64, 64), "baseline/checker").value
	scratch.select(PackedInt64Array([id, second]))
	ui.set_tool("Edge")
	click_component(graph, Vector3(64, 64, 32))
	click_component(graph, Vector3(160, 64, 0), true)
	checks.check(scratch.components.size() == 2 and scratch.components[0].brush_id != scratch.components[1].brush_id, "multi-brush edge selection")
	before = text()
	revision = doc.get_revision()
	count = ui.tokens.size()
	drag(graph, Vector3(64, 64, 32), Vector3(80, 80, 32))
	checks.check(text() != before and doc.get_revision() > revision and ui.tokens.size() == count + 1 and scratch.components.size() == 2, "multi-brush component group rebuilds every convex hull atomically")
	scratch.restore(baseline)
	# Triangular incident faces permit constrained single and grouped vertex edits.
	doc.clip_brushes(PackedInt64Array([id]), Vector3(64, 0, 0), Vector3(0, 0, 64), Vector3(0, 64, 0), false)
	scratch.select(PackedInt64Array([id]))
	ui.set_tool("Vertex")
	before = text()
	drag(graph, Vector3(64, 0, 0), Vector3(80, 0, 0))
	checks.check(scratch.brush(id).vertices.has(Vector3(80, 0, 0)) and scratch.components.size() == 1, "constrained tetrahedron vertex drag succeeds")
	checks.check(is_equal_approx(solid_volume(scratch.brush(id)), 80 * 64 * 64 / 6.0), "single vertex expected volume")
	key(KEY_Z, true)
	checks.check(text() == before and scratch.components.size() == 1, "vertex undo restores selected corner")
	click_component(graph, Vector3(0, 64, 0), true)
	checks.check(scratch.components.size() == 2, "Shift adds vertex")
	click_component(graph, Vector3(0, 64, 0), true)
	checks.check(scratch.components.size() == 1, "Shift toggles vertex off")
	click_component(graph, Vector3(0, 64, 0), true)
	drag(graph, Vector3(64, 0, 0), Vector3(80, 0, 0))
	checks.check(scratch.brush(id).vertices.has(Vector3(80, 0, 0)) and scratch.brush(id).vertices.has(Vector3(16, 64, 0)) and scratch.components.size() == 2, "graph deforms both selected vertices")
	await capture_phase5("vertices")
	key(KEY_Z, true)
	checks.check(text() == before and scratch.components.size() == 2, "multi-vertex undo selection")
	key(KEY_Y, true)
	checks.check(scratch.components.size() == 2 and scratch.components.all(func(c): return scratch.component_valid(c, scratch.brush(id))), "multi-vertex redo resolves fresh handles")
	before = text()
	key(KEY_H)
	checks.check(scratch.components.is_empty() and scratch.hidden.has(id) and graph.pick_component(graph.project(Vector3(80, 0, 0)), "Vertex").is_empty() and text() == before, "hide clears component owners without editing geometry")
	key(KEY_Z, true)
	checks.check(scratch.selected.is_empty() and scratch.components.is_empty() and scratch.hidden.has(id), "snapshot undo respects current hidden-owner filter")
	key(KEY_H, false, true)
	# Real 2D placement + Enter/Ctrl+Enter/Shift+Enter in every orientation.
	for axis in [2, 1, 0]:
		graph.orientation = axis
		var u: int = graph.axes().x
		var v: int = graph.axes().y
		for split in [false, true]:
			for flipped in [false, true]:
				scratch.restore(baseline)
				ui.set_tool("Cut")
				graph.clip_points.clear()
				graph.clip_flip = false
				var p = Vector3.ONE * 32
				var q = p
				p[v] = -16.2
				q[v] = 80.2
				click_component(graph, p)
				click_component(graph, q)
				checks.check(graph.clip_points.size() == 2 and graph.clip_points[0][v] == -16 and graph.clip_points[1][v] == 80, "2D clip points use shared grid")
				var normal: Vector3 = Vector3.ZERO
				var extrusion = Vector3.ZERO
				extrusion[axis] = -96
				normal = extrusion.cross(graph.clip_points[1] - graph.clip_points[0]).normalized()
				if flipped:
					key(KEY_ENTER, true)
					normal = -normal
				before = text()
				count = ui.tokens.size()
				key(KEY_ENTER, false, split)
				var ids: PackedInt64Array = scratch.selected.duplicate()
				checks.check(ids.size() == (2 if split else 1) and graph.clip_points.is_empty() and ui.tokens.size() == count + 1, "2D clip/split/flip commits one action axis %d" % axis)
				var volume = 0.0
				var normals: Array = []
				for piece_id in ids:
					var piece: Dictionary = scratch.brush(piece_id)
					volume += solid_volume(piece)
					if not split:
						checks.check(piece.aabb_max[u] == 32 if normal[u] > 0 else piece.aabb_min[u] == 32, "flip retains expected half-space")
					for face in piece.faces:
						if absf(face.center[u] - 32) < 0.001 and absf(face.normal[u]) > 0.99:
							normals.append(face.normal)
							var uv: Dictionary = doc.get_face_uv(piece_id, face.index, piece.topology_revision).value
							checks.check(face.texture == "common/caulk" and uv.projection == "classic" and uv.shift == Vector2.ZERO and uv.rotation == 0 and uv.scale == Vector2.ONE, "UI clip cap uses caulk identity UV")
				checks.check(is_equal_approx(volume, 64 * 64 * 64 * (1.0 if split else 0.5)), "UI clip volume conservation")
				checks.check(normals.size() == ids.size() and (not split or normals[0] == -normals[1]), "UI cap counts and complementary orientation")
				if axis == 2 and split and not flipped:
					await capture_phase5("split")
				moved = text()
				key(KEY_Z, true)
				checks.check(text() == before and scratch.selected == PackedInt64Array([id]), "clip undo topology and selection")
				key(KEY_Y, true)
				checks.check(text() == moved and scratch.selected == ids, "clip redo result identities and selection")
		for sides in range(3, 10):
			scratch.restore(baseline)
			ui.set_tool("Brush")
			key(KEY_0 + sides, true)
			var prism: Dictionary = scratch.brush(id)
			checks.check(prism.faces.size() == sides + 2 and prism.vertices.size() == sides * 2 and prism.aabb_min[axis] == 0 and prism.aabb_max[axis] == 64, "Ctrl %d prism expected axis %d caps and depth" % [sides, axis])
			checks.check(is_equal_approx(solid_volume(prism), sides * sin(TAU / sides) / 8.0 * 64 * 64 * 64), "UI prism analytic volume")
			var roundtrip = ClassDB.instantiate("TBMapDocument")
			checks.check(roundtrip.import_text(text()).ok and roundtrip.export_text().value == text(), "UI prism canonical round-trip")
			key(KEY_Z, true)
			checks.check(scratch.brush(id).faces.size() == 6 and scratch.selected == PackedInt64Array([id]), "prism undo restores selected cube")
	scratch.save_enabled = false
	ui.set_session(original)
	graph.orientation = 2
	graph.origin = Vector3.ZERO
	graph.zoom = 1
	graph.clip_flip = false
	ui.set_tool("Brush")
	graph.grab_focus()

func capture_phase5(label: String) -> void:
	if OS.get_environment("TB_TEST_SUITE") != "ui":
		return
	ui.camera_view.frame_selection()
	ui.set_status("Phase 5 acceptance • " + label)
	await get_tree().process_frame
	await get_tree().process_frame
	RenderingServer.force_draw()
	var image = EditorInterface.get_base_control().get_viewport().get_texture().get_image()
	checks.check(not image.is_empty(), "rendered Phase5 " + label)
	checks.check(image.save_png("res://phase5-" + label + ".png") == OK, "Phase5 overlay screenshot " + label)
