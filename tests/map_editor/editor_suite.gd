@tool
extends EditorPlugin

const Checks = preload("res://checks.gd")
var checks = Checks.new()
var ui: Control
var manager: EditorUndoRedoManager
var history: UndoRedo

class MockSteamAudioProbeVolume extends Node3D:
	var size := Vector3.ZERO
	var spacing := 0.0
	var bake_threads := 0
	var reflection_threads := 0
	var generated := false

	func generate_probes() -> void:
		generated = true

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
	EditorInterface.set_main_screen_editor("Radiant")
	await get_tree().process_frame
	checks.check(Engine.is_editor_hint() and ClassDB.class_exists("TBMapDocument"), "actual editor and native document")
	checks.check(plugin._get_plugin_name() == "Radiant", "main screen is named Radiant")
	checks.check(plugin._has_main_screen() and ui.is_visible_in_tree(), "Radiant main screen attached and visible")
	checks.check(plugin.materials_panel.is_inside_tree() and plugin.uv_panel.is_inside_tree() and plugin.entities_panel.is_inside_tree(), "Map Materials, UV, and Entities bottom panels are retained")
	checks.check(plugin.built_materials_page.get_parent() == plugin.materials_panel and plugin.materials_grid.max_columns == 0
		and plugin.materials_tree.columns == 2 and plugin.materials_search.placeholder_text == "Search materials..."
		and plugin.material_picker_button.toggle_mode and plugin.materials_context_picker != null
		and plugin.open_context_scene_button.text == "Open Scene",
		"Map Materials retains contexts, search, picking, and the rich responsive grid/list UI")
	checks.check(plugin.uv_panel == ui.material_workspace and plugin.uv_panel.is_ancestor_of(ui.browser) and plugin.uv_panel.is_ancestor_of(ui.bottom_uv_pane), "UV is a persistent dedicated UVPane with a full material browser")
	ui.browser.set_search("shared-state")
	plugin.show_uv()
	checks.check(ui.material_workspace.get_parent() != null and ui.browser._query == "shared-state", "UV bottom panel keeps its browser and editor state")
	var shared_materials_panel = plugin.materials_panel
	plugin.show_materials()
	checks.check(plugin.materials_panel == shared_materials_panel and ui.material_workspace == plugin.uv_panel and ui.browser._query == "shared-state", "Map Materials opens its one plugin-owned panel without reparenting UV")
	ui.browser.set_search("")
	plugin.show_entities_panel()
	checks.check(plugin.entities_pane.session == ui.session and plugin.entities_pane.entity_list.item_count == ui.session.entity_data().size(), "Entities bottom panel lists every entity in the active session")
	plugin.show_materials()
	plugin.hide_bottom_panel()
	checks.check(ui.slot_types == ["Camera", "Side Grid", "Top Grid", "Front Grid"] and ui.camera_view.get_parent() == ui.view_slots[0] and ui.graph_a.get_parent() == ui.view_slots[2] and not ui.is_ancestor_of(ui.material_workspace), "three-view workspace starts with per-slot camera and grid types")
	checks.check(plugin.map_control.visible and plugin.map_control.get_child_count() == 2
		and plugin.map_control.get_child(0).text == "Build Meshes"
		and plugin.map_control.get_child(0).icon == ui.loader_actions.BuildMeshes.icon
		and plugin.map_control.get_child(1).text.is_empty() and plugin.map_control.get_child(1).icon != null
		and plugin.map_control.get_child(1).tooltip_text == "Open Radiant Editor",
		"spatial toolbar uses Build Meshes text and an accessible Radiant icon")
	checks.check(plugin.map_control.get_child(0).disabled and plugin.map_control.get_child(1).disabled, "spatial loader actions are disabled without a selected TBLoader")
	var map_toolbar: Control
	for child in ui.get_children():
		if child is HFlowContainer:
			map_toolbar = child
			break
	var toolbar_labels: Array[String] = []
	for child in map_toolbar.find_children("*", "Button", true, false):
		toolbar_labels.append(child.text)
	var tool_group: ButtonGroup = ui.tool_buttons.Select.button_group
	checks.check(["Select", "Brush", "Cut", "Rotate", "Face", "Edge", "Vertex", "Texture"].all(func(mode): return ui.tool_buttons[mode].icon != null and ui.tool_buttons[mode].text.is_empty() and ui.tool_buttons[mode].button_group == tool_group), "map toolbar exposes icon-only editing modes in one exclusive button group")
	checks.check(ui.tool_buttons.Vertex.tooltip_text == "Vertex Tool (V)" and ui.tool_buttons.Edge.tooltip_text == "Edge Tool (E)" and ui.tool_buttons.Texture.tooltip_text == "Texture Tool", "tooltips show existing shortcuts without inventing missing bindings")
	checks.check(["New", "Open…", "Save", "Save As…"].all(func(command): return not toolbar_labels.has(command)), "map toolbar omits redundant document controls")
	checks.check(map_toolbar.get_child(0).is_ancestor_of(ui.file_menu) and ui.file_menu.text.is_empty() and ui.file_menu.icon != null, "icon file command menu starts the grouped map toolbar")
	checks.check(ui.file_menu.get_popup().item_count == 3 and ui.file_menu.get_popup().get_item_text(0) == "Open…" and ui.file_menu.get_popup().get_item_text(1) == "Save" and ui.file_menu.get_popup().get_item_text(2) == "Save As…", "file menu contains only Open, Save, and Save As")
	checks.check(ui.document_tabs.get_index() == ui.scene_tabs.get_index() + 1 and ui.document_tabs.get_tab_title(ui.document_tabs.tab_count - 1) == "+", "document tabs sit below scene tabs with a trailing new tab")
	checks.check(not ui.rebuild_on_save.button_pressed, "Build meshes on save defaults off")
	checks.check(ui.rebuild_on_save is Button and ui.rebuild_on_save.toggle_mode and ui.rebuild_on_save.icon != null and ui.rebuild_on_save.tooltip_text == "Build meshes on save", "Build meshes on save is a compact independent icon toggle")
	checks.check(ui.loader_actions.BindLoader.disabled and ui.loader_actions.DetachLoader.disabled and ui.loader_actions.UpdateLoaderPath.disabled and ui.loader_actions.BuildMeshes.disabled and ui.rebuild_on_save.disabled, "unselected and unbound loader actions start disabled")
	checks.check(ui.loader_actions.BuildMeshes.tooltip_text == "Build Meshes from saved map" and ui.loader_actions.BuildMeshes.accessibility_name == "Build Meshes from saved map", "map toolbar exposes Build Meshes terminology to tooltip and accessibility APIs")
	checks.check(not ui.radiant_camera_behavior and not ui.camera_behavior_button.button_pressed
		and ui.camera_behavior_button.text == "Godot Camera" and not ui.camera_view.radiant_camera_behavior,
		"camera behavior defaults to Godot mode")
	checks.check(ui.camera_behavior_button.get_parent() == ui.layout_menu.get_parent()
		and ui.camera_behavior_button.get_index() == ui.layout_menu.get_index() + 1,
		"camera behavior toggle sits beside the layout menu")
	var godot_camera_transform: Transform3D = ui.camera_view.camera.transform
	var godot_camera_target: Vector3 = ui.camera_view.orbit_target
	mouse(ui.camera_view, ui.camera_view.size * 0.5, true, MOUSE_BUTTON_MIDDLE)
	motion(ui.camera_view, ui.camera_view.size * 0.5 + Vector2(20, 10), Vector2(20, 10))
	mouse(ui.camera_view, ui.camera_view.size * 0.5 + Vector2(20, 10), false, MOUSE_BUTTON_MIDDLE)
	checks.check(ui.camera_view.godot_navigation == "" and ui.camera_view.camera.transform != godot_camera_transform,
		"Godot camera mode orbits while MMB is held")
	ui.camera_view.begin_rmb()
	checks.check(ui.camera_view.flying, "Godot camera mode enters freelook while RMB is held")
	ui.camera_view.finish_rmb()
	checks.check(not ui.camera_view.flying, "Godot camera mode exits freelook when RMB is released")
	ui.camera_view.camera.transform = godot_camera_transform
	ui.camera_view.orbit_target = godot_camera_target
	ui.camera_view.camera_transform_changed()
	ui.set_radiant_camera_behavior(true)
	ui.active_graph.grab_focus()
	checks.check(ui.camera_behavior_button.button_pressed and ui.camera_behavior_button.text == "Radiant Camera"
		and ui.camera_view.radiant_camera_behavior, "camera behavior toggle enables Radiant controls")
	checks.check(ui.view_layout == 3 and ui.visible_graphs().size() == 2 and not ui.view_slots[1].visible, "three-view layout changes visibility without changing pane types")
	ui.apply_layout(2)
	ui.set_slot_type(2, "Camera")
	checks.check(ui.cameras.size() == 2 and ui.slot_views[0] != ui.slot_views[2] and ui.slot_types[0] == "Camera" and ui.slot_types[2] == "Camera", "two-view layout supports duplicate independent cameras")
	checks.check(ui.graphs.all(func(item): return item.current_camera_views().size() == 2), "every grid routes previews to the camera collection")
	ui.set_slot_type(0, "Top Grid")
	ui.set_slot_type(2, "Top Grid")
	checks.check(ui.visible_graphs().size() == 2 and ui.graph_a != ui.graph_b and ui.visible_graphs().all(func(item): return item.orientation == 2), "two-view layout supports duplicate independent same-orientation grids")
	ui.slot_menus[0].get_popup().id_pressed.emit(0)
	checks.check(ui.slot_types[0] == "Camera" and ui.slot_menus[0].get_popup().is_item_checked(0), "slot three-dot menu switches pane type")
	checks.check(ui.view_slots[0].get_class() == "Control" and ui.slot_menus[0].anchor_left == 0.0
		and ui.slot_menus[0].offset_left == 2.0 and ui.slot_menus[0].offset_right == 30.0,
		"slot pane menu keeps a compact hitbox instead of covering viewport input")
	var all_pane_icons := true
	for pane_index in ui.slot_menus[0].get_popup().item_count:
		all_pane_icons = all_pane_icons and ui.slot_menus[0].get_popup().get_item_icon(pane_index) != null
	checks.check(all_pane_icons,
		"slot pane menu displays pane-type icons")
	ui.set_slot_type(1, "Side Grid")
	ui.set_slot_type(2, "Top Grid")
	ui.set_slot_type(3, "Front Grid")
	ui.apply_layout(4)
	checks.check(ui.visible_graphs().size() == 3 and ui.graphs.map(func(item): return item.orientation) == [2, 1, 0], "four-view layout displays each configured slot")
	ui.workspace.split_offset = 17
	ui.left_views.split_offset = 11
	ui.graph_a.origin = Vector3(3, 4, 0)
	ui.camera_view.orbit_target = Vector3(1, 2, 3)
	var saved_workspace: Dictionary = ui.workspace_state()
	ui.graph_a.origin = Vector3.ZERO
	ui.camera_view.orbit_target = Vector3.ZERO
	ui.set_radiant_camera_behavior(false)
	ui.apply_layout(2)
	ui.restore_workspace_state(saved_workspace)
	checks.check(ui.view_layout == 4 and ui.slot_types == ["Camera", "Side Grid", "Top Grid", "Front Grid"] and ui.workspace.split_offset == 17 and ui.left_views.split_offset == 11
		and ui.radiant_camera_behavior and ui.camera_behavior_button.button_pressed,
		"workspace state restores per-slot types, splitter positions, and camera behavior")
	checks.check(ui.graph_a.origin == Vector3(3, 4, 0) and ui.camera_view.orbit_target == Vector3(1, 2, 3), "workspace state restores independent camera and grid state")
	ui.apply_layout(3)
	checks.check(ui.camera_view.get_parent() == ui.view_slots[0] and ui.visible_graphs().size() == 2, "layout changes restore camera-left three-view arrangement")
	checks.check(ui.camera_view.find_children("FrameSelection", "Button", true, false).size() == 1 and ui.graph_a.find_children("FrameSelection", "Button", true, false).size() == 1, "camera and grid panes expose compact frame buttons")
	checks.check(ui.camera_view.find_children("BuiltAppearance", "Button", true, false).size() == 1
		and ui.camera_view.built_appearance_button.toggle_mode and not ui.camera_view.built_appearance_button.button_pressed,
		"camera exposes a local Built appearance toggle which defaults off")
	checks.check(ui.camera_view.find_children("PreviewSunlight", "Button", true, false).size() == 1
		and ui.camera_view.find_children("PreviewWorldEnvironment", "Button", true, false).size() == 1
		and ui.camera_view.find_children("CameraGrid", "Button", true, false).size() == 1
		and ui.camera_view.preview_sunlight_button.icon != null and ui.camera_view.preview_environment_button.icon != null
		and ui.camera_view.camera_grid_button.icon != null and ui.camera_view.preview_sunlight_button.button_pressed
		and ui.camera_view.preview_environment_button.button_pressed and ui.camera_view.camera_grid_button.button_pressed,
		"camera titlebar exposes enabled sunlight, WorldEnvironment, and grid toggles")
	checks.check(ui.camera_view.preview_sunlight_button.get_parent() == ui.camera_view.preview_environment_button.get_parent()
		and ui.camera_view.preview_environment_button.get_parent() == ui.camera_view.camera_grid_button.get_parent()
		and ui.camera_view.preview_sunlight_button.get_parent().get_parent().name == "CameraPreviewControls"
		and ui.camera_view.preview_sunlight_button.get_parent().get_parent().position.x >= 30.0
		and ui.camera_view.preview_sunlight_button.get_index() < ui.camera_view.preview_environment_button.get_index()
		and ui.camera_view.preview_environment_button.get_index() < ui.camera_view.camera_grid_button.get_index(),
		"camera preview toggles share a visual button group beside the pane camera button")
	ui.camera_view.preview_sunlight_button.button_pressed = false
	checks.check(not ui.camera_view.preview_lights.visible
		and ui.camera_view.preview_sunlight_button.get_node("DisabledSlash").visible,
		"disabled sunlight toggle hides preview lighting and displays a slash")
	ui.camera_view.preview_sunlight_button.button_pressed = true
	checks.check(ui.camera_view.preview_lights.visible
		and not ui.camera_view.preview_sunlight_button.get_node("DisabledSlash").visible,
		"enabled sunlight toggle restores preview lighting and removes its slash")
	ui.camera_view.preview_environment_button.button_pressed = false
	checks.check(ui.camera_view.preview_world_environment.environment == null
		and ui.camera_view.preview_environment_button.get_node("DisabledSlash").visible,
		"disabled WorldEnvironment toggle detaches the preview and displays a slash")
	ui.camera_view.preview_environment_button.button_pressed = true
	checks.check(ui.camera_view.preview_world_environment.environment != null, "WorldEnvironment toggle restores the preview environment")
	ui.camera_view.camera_grid_button.button_pressed = false
	checks.check(not ui.camera_view.ground_grid.visible and ui.camera_view.camera_grid_button.get_node("DisabledSlash").visible,
		"disabled camera grid toggle hides the ground grid and displays a slash")
	ui.camera_view.camera_grid_button.button_pressed = true
	checks.check(ui.camera_view.ground_grid.visible, "camera grid toggle restores the ground grid")
	checks.check(ui.camera_view.preview_world_environment.environment.background_mode == Environment.BG_COLOR,
		"camera uses its studio environment when the active document has no bound scene sky")
	checks.check(ui.camera_view.find_child("FrameSelection", true, false).icon != null and ui.graph_a.find_child("FrameSelection", true, false).icon != null,
		"camera and grid frame-selection buttons use the custom frame icon")
	checks.check(ui.camera_view.find_child("FrameSelection", true, false).anchor_left == 1.0
		and ui.camera_view.find_child("FrameSelection", true, false).offset_right <= 0.0
		and ui.camera_view.find_child("FrameSelection", true, false).offset_left < 0.0
		and ui.graph_a.find_child("FrameSelection", true, false).anchor_left == 1.0
		and ui.graph_a.find_child("FrameSelection", true, false).offset_right <= 0.0
		and ui.graph_a.find_child("FrameSelection", true, false).offset_left < 0.0,
		"camera and grid frame-selection buttons sit at the far right of their titlebars")
	checks.check(ui.camera_view.orientation_gizmo.position.y >= 40.0,
		"camera orientation compass sits below the titlebar")
	ui.graph_a.orientation_gizmo.axis_selected.emit(0, true)
	checks.check(ui.graph_a.orientation == 0, "grid orientation gizmo selects the YZ side plane")
	ui.graph_a.set_orientation(2)
	var saved_camera_transform: Transform3D = ui.camera_view.camera.transform
	var saved_camera_target: Vector3 = ui.camera_view.orbit_target
	var saved_camera_distance: float = ui.camera_view.orbit_distance
	ui.camera_view.orbit_target = Vector3.ZERO
	ui.camera_view.orbit_distance = 5.0
	ui.camera_view.snap_to_axis(0, true)
	checks.check(ui.camera_view.camera.position.is_equal_approx(Vector3.BACK * 5.0) and ui.camera_view.camera_map_direction().is_equal_approx(Vector3.LEFT), "camera compass snaps to map-space cardinal axes around its target")
	var snapped_position: Vector3 = ui.camera_view.camera.position
	ui.camera_view.orbit_from_gizmo(Vector2(8, 0))
	checks.check(not ui.camera_view.camera.position.is_equal_approx(snapped_position) and is_equal_approx(ui.camera_view.camera.position.distance_to(ui.camera_view.orbit_target), 5.0), "camera compass drag orbits while preserving target distance")
	ui.camera_view.camera.transform = saved_camera_transform
	ui.camera_view.orbit_target = saved_camera_target
	ui.camera_view.orbit_distance = saved_camera_distance
	ui.camera_view.sync_camera_marker(true)
	checks.check((ui.status.text.begins_with("UNSAVED •") or ui.status.text.begins_with("saved •")) and ui.status.text.contains("meshes") and ui.status.text.contains("grid") and ui.status.text.contains("selected") and ui.status.text.contains("hidden"), "bottom status omits map title and retains editing state")
	var active_session = ui.session
	var background = load("res://addons/tbloader/src/editor/map_session.gd").new()
	checks.check(background.document.save_map("user://background-refresh.map").ok, "background refresh fixture starts clean")
	background.texture_root = "res://textures-other"
	ui.set_session(background)
	checks.check(plugin.entities_pane.session == background and plugin.entities_pane.entity_list.item_count == background.entity_data().size()
		and ui.browser._texture_root == "res://textures-other", "UV browser and all-entity pane follow a document-tab session switch")
	ui.set_session(active_session)
	ui.camera_view.rendered_key = "background-refresh-sentinel"
	background.document.create_cuboid(Vector3.ZERO, Vector3.ONE * 8, "background/material")
	background.changed.emit()
	var background_label_found := false
	for index in ui.document_tabs.tab_count - 1:
		background_label_found = background_label_found or ui.document_tabs.get_tab_title(index) == "background-refresh.map *"
	checks.check(ui.camera_view.rendered_key == "background-refresh-sentinel", "background session change skips active graphs and camera refresh")
	checks.check(background_label_found, "background session change still refreshes tab dirty status")
	background.save_enabled = false
	var before_plus = ui.session
	var before_plus_count = ui.sessions.size()
	ui.document_tab_changed(ui.document_tabs.tab_count - 1)
	checks.check(ui.session != before_plus and ui.session.document.get_path().is_empty() and ui.sessions.size() == before_plus_count + 1, "trailing plus creates and activates an untitled document tab")
	ui.session.save_enabled = false
	ui.set_session(before_plus)
	ui.camera_view.rendered_key = ""
	ui.refresh()
	camera_marker_regression()
	if suite == "toolbar":
		var graph = ui.graph_a
		ui.set_tool("Cut")
		for cut_graph in ui.graphs:
			cut_graph.clip_points.assign([Vector3.ZERO, Vector3.ONE])
			cut_graph.clip_flip = true
			cut_graph.gesture = "move"
		ui.set_tool("Select")
		checks.check(ui.graphs.all(func(cut_graph): return cut_graph.clip_points.is_empty() and not cut_graph.clip_flip and cut_graph.gesture.is_empty()), "leaving Cut clears markers and stale previews from every grid")
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
	checks.check(ui.graph_a.orientation == 2 and ui.graph_b.orientation == 1 and ui.graph_c.orientation == 0, "persistent grids start Top, Front, and Side")
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
	await get_tree().process_frame
	RenderingServer.force_draw()
	graph.reset_render_counters()
	graph.queue_selection_redraw()
	await get_tree().process_frame
	RenderingServer.force_draw()
	checks.check(graph.render_counters().selection_mask_points > 0 and graph.render_counters().static_edge_builds == 0,
		"sparse move gesture masks the original gray selection without rebuilding static edges")
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
	await get_tree().process_frame
	RenderingServer.force_draw()
	graph.reset_render_counters()
	graph.queue_selection_redraw()
	await get_tree().process_frame
	RenderingServer.force_draw()
	checks.check(graph.render_counters().selection_mask_points > 0 and graph.render_counters().static_edge_builds == 0,
		"sparse rotate gesture masks the original gray selection without rebuilding static edges")
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
	var merge_origin = ui.session
	var merge_session = load("res://addons/tbloader/src/editor/map_session.gd").new()
	ui.set_session(merge_session)
	var merge_a: Dictionary = ui.session.document.create_cuboid(Vector3(256, 0, 0), Vector3(288, 32, 32), "common/caulk")
	var merge_b: Dictionary = ui.session.document.create_cuboid(Vector3(288, 0, 0), Vector3(320, 32, 32), "common/caulk")
	ui.session.select(PackedInt64Array([merge_a.value, merge_b.value]))
	var pre_merge := text()
	ui.merge_selection()
	var merged_id: int = ui.session.selected[0] if ui.session.selected.size() == 1 else -1
	checks.check(merged_id > 0 and merged_id != merge_a.value and merged_id != merge_b.value and ui.session.brush(merge_a.value).is_empty(), "Merge UI selects the fresh merged brush ID")
	checks.check(history.undo() and text() == pre_merge and ui.session.selected == PackedInt64Array([merge_a.value, merge_b.value]), "Merge uses one undoable session transaction")
	var merge_token_count: int = ui.tokens.size()
	ui.session.select(PackedInt64Array([merge_a.value]))
	ui.merge_selection()
	checks.check(ui.tokens.size() == merge_token_count and ui.notice.text.contains("INVALID_ARGUMENT"), "invalid Merge reports without creating history")
	merge_session.save_enabled = false
	ui.set_session(merge_origin)
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
	ui.browser.set_search("")
	ui.browser.set_kind_filter("Materials")
	checks.check(ui.browser.get_visible_paths() == ["res://textures/baseline/surface.tres"], "UV browser can show only material resources")
	ui.browser.set_kind_filter("Textures")
	checks.check(ui.browser.get_visible_paths().has("res://textures/baseline/checker.png"), "UV browser can show only texture resources")
	ui.browser.set_kind_filter("All")
	checks.check(ui.browser.set_folder("res://textures/baseline"), "browser folder navigation")
	checks.check(ui.browser.select_path("res://textures/baseline/checker.png"), "real browser resource selection")
	checks.check(ui.texture_field.text == "baseline/checker", "browser exact map token handoff")
	brush = ui.session.brush(id)
	checks.check(brush.faces.all(func(face): return face.texture == "baseline/checker"), "material click assigns every selected brush face")
	checks.check(ui.texture_sizes.get("baseline/checker") == Vector2i(64, 32), "production preview resolver uses actual asymmetric texture dimensions")
	ui.browser.set_kind_filter("Materials")
	checks.check(ui.browser.select_path("res://textures/baseline/surface.tres"), "UV browser selects a native Material resource")
	checks.check(ui.texture_field.text == "baseline/surface.tres"
		and ui.session.brush(id).faces.all(func(face): return face.texture == "baseline/surface.tres"),
		"Material selection retains its extension and applies the Material token to selected faces")
	ui.browser.set_kind_filter("Textures")
	ui.browser.select_path("res://textures/baseline/checker.png")
	ui.browser.set_kind_filter("All")
	ui.set_slot_type(1, "UV")
	var uv_pane = ui.slot_views[1]
	checks.check(uv_pane.find_child("PaneHeader", false, false) != null
		and uv_pane.find_child("PaneHeader", false, false).custom_minimum_size.y == 36.0,
		"in-layout UV pane reserves a titlebar for its leading pane menu icon")
	checks.check(ui.uv_panes.size() == 1 and uv_pane.texture_field.text == "baseline/checker" and uv_pane.canvas.preview_texture != null, "UV pane receives selected face material and preview ownership")
	uv_pane.uv_transform_requested.emit(Vector2(5, -2), 15.0, Vector2(0.75, 1.5))
	var pane_uv: Dictionary = ui.session.document.get_face_uv(id, 0, ui.session.brush(id).topology_revision).value
	checks.check(pane_uv.shift == Vector2(5, -2) and pane_uv.rotation == 15.0 and pane_uv.scale == Vector2(0.75, 1.5), "UV pane uses the authoritative UV transaction path")
	uv_pane.match_grid_requested.emit()
	checks.check(ui.session.document.get_face_uv(id, 0, ui.session.brush(id).topology_revision).value.shift == Vector2.ZERO, "UV pane Match Grid snaps texture shifts to the map grid")
	uv_pane.reset_requested.emit()
	checks.check(ui.session.document.get_face_uv(id, 0, ui.session.brush(id).topology_revision).value.scale == Vector2.ONE, "UV pane Reset is wired")
	ui.set_slot_type(1, "Side Grid")
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
	checks.check(ui.camera_view.overlays.get_node_or_null("SelectedFaceFill") == null
		and ui.camera_view.overlays.get_node_or_null("SelectedFaceEdges") != null,
		"camera face selection uses blue boundary edges without a face fill")
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
	ui.set_slot_type(1, "Entities")
	ui.apply_layout(4)
	var entity_pane = ui.slot_views[1]
	checks.check(entity_pane.find_child("PaneHeader", false, false) != null
		and entity_pane.find_child("PaneHeader", false, false).custom_minimum_size.y == 36.0,
		"in-layout Entities pane reserves a titlebar for its leading pane menu icon")
	checks.check(entity_pane.entity_list.item_count == ui.session.entity_data().size() and entity_pane.property_tree.get_root().get_child_count() > 0, "Entity pane shows the all-entity list and one detail editor")
	ui.show_entities()
	checks.check(not ui.inspector.visible and plugin.entities_pane.entity_list.has_focus(), "N opens and focuses the persistent Entities bottom panel")
	ui.set_slot_type(1, "Side Grid")
	ui.apply_layout(3)
	graph.grab_focus()
	key(KEY_S)
	checks.check(ui.browser.is_visible_in_tree(), "S opens the persistent UV bottom panel")
	key(KEY_S)
	checks.check(not plugin.uv_panel.is_visible_in_tree(), "S closes the visible UV bottom panel")
	key(KEY_S)
	graph.grab_focus()
	key(KEY_N)
	checks.check(not ui.inspector.visible and plugin.entities_pane.entity_list.has_focus()
		and ui.session.entity_targets().size() == 1, "N replaces the legacy entity window with the bottom panel")
	key(KEY_N)
	checks.check(not plugin.entities_panel.is_visible_in_tree(), "N closes the visible Entities bottom panel")
	plugin.hide_bottom_panel()
	ui.entity_key.text = "message"
	ui.entity_value.text = "UI journey"
	ui.edit_property(false)
	checks.check(text().contains("UI journey"), "worldspawn keyval edited through inspector")
	graph.grab_focus()
	var entity_click: Vector2 = graph.project(Vector3(32, 48, 0))
	mouse(graph, entity_click, true, MOUSE_BUTTON_RIGHT)
	mouse(graph, entity_click, false, MOUSE_BUTTON_RIGHT)
	checks.check(ui.entity_menu.visible and ui.entity_menu_point == graph.snap_point(Vector3(32, 48,
		ui.session.workzone.get_center().z)) and ui.entity_menu.is_item_disabled(ui.entity_menu.get_item_index(5)),
		"RMB grid click opens entity menu at the snapped workzone point and disables brush classes without a brush selection")
	ui.entity_menu_selected(1)
	ui.entity_menu.hide()
	var point_id: int = ui.session.points[0]
	checks.check(ui.session.point_markers().size() == 1, "grid entity menu creates and selects a point entity")
	graph.grab_focus()
	var marker: Dictionary = ui.session.point_markers()[0]
	checks.check(graph.hit_point(graph.project(marker.origin)) == point_id, "point marker graph picking")
	drag(graph, marker.origin, marker.origin + Vector3(16, 32, 0))
	checks.check(ui.session.point_markers()[0].origin == marker.origin + Vector3(16, 32, 0), "graph moves point origin")
	key(KEY_Z, true)
	checks.check(ui.session.point_markers()[0].origin == marker.origin, "point movement undo")
	key(KEY_Y, true)
	ui.session.select(PackedInt64Array([id]))
	ui.open_entity_menu(graph, graph.project(ui.session.workzone.get_center()))
	checks.check(not ui.entity_menu.is_item_disabled(ui.entity_menu.get_item_index(6)), "grid entity menu enables brush classes for selected brushes")
	ui.entity_menu_selected(6)
	ui.entity_menu.hide()
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
	var open_count = ui.sessions.size()
	checks.check(ui.open_path("res://journey.map") and ui.session == original_session and ui.sessions.size() == open_count, "opening an existing path activates its tab without duplicating the document")
	var new_session = load("res://addons/tbloader/src/editor/map_session.gd").new()
	checks.check(new_session.document.import_text(journey).ok, "foreground history fixture imports canonical content")
	ui.set_session(new_session)
	new_session.save_enabled = false
	key(KEY_Z, true)
	checks.check(ui.session == new_session and text() == journey and original_session.document.export_text().value != journey, "background undo targets originating session only")
	checks.check(original_session.document.is_dirty() and not ui.unsaved_status().is_empty(), "background undo participates in editor unsaved reporting")
	checks.check(ui.document_tabs.tab_count >= 3, "retained sessions are accessible through document tabs")
	key(KEY_Y, true)
	checks.check(original_session.document.export_text().value == journey, "background redo returns originating session to saved baseline")
	token.retire()
	token.restore(false)
	checks.check(ui.notice.text.contains("expired") and text() == journey, "retired history explicit status and no redirection")
	ui.set_session(original_session)
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
	var dirty_session = ui.session
	ui.file_command("new")
	checks.check(ui.session != dirty_session and ui.session.document.get_path().is_empty() and dirty_session.document.export_text().value == dirty, "New opens an untitled tab without replacing the dirty document")
	ui.session.save_enabled = false
	ui.set_session(dirty_session)
	plugin._save_external_data()
	checks.check(not ui.session.document.is_dirty(), "actual Save All lifecycle hook saves known path")
	# Fly state and capture exit paths, with native display capture in UI suite.
	print("TB_UI_STAGE: entities/persistence complete")
	var camera = ui.camera_view
	checks.check(camera.crosshair != null and camera.crosshair.get_child_count() == 4 and not camera.crosshair.is_visible_in_tree(), "inactive map camera hides its centered crosshair")
	checks.check(camera.viewport.msaa_3d == Viewport.MSAA_4X, "camera preview enables multisample antialiasing")
	checks.check(camera.ground_grid != null and camera.ground_grid.get_parent() == camera.viewport
		and camera.ground_grid.get_child_count() >= 2,
		"camera shows a separate horizontal map-height-zero ground grid")
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
	ui.set_tool("Select")
	var face_click = InputEventMouseButton.new()
	face_click.pressed = true
	face_click.button_index = MOUSE_BUTTON_LEFT
	face_click.position = camera.size * 0.5
	face_click.ctrl_pressed = true
	camera._gui_input(face_click)
	checks.check(ui.session.components.size() == 1 and ui.session.components[0].kind == "face" and ui.session.components[0].index == expected_hits[0].face_index, "camera Ctrl+LMB quick-selects the pointed face")
	camera.grab_focus()
	var right = InputEventMouseButton.new()
	right.pressed = true
	right.button_index = MOUSE_BUTTON_RIGHT
	camera._gui_input(right)
	var right_release = right.duplicate()
	right_release.pressed = false
	camera._input(right_release)
	checks.check(camera.flying and camera.crosshair.is_visible_in_tree(), "RMB click-release enters persistent FLY mode")
	ui.session.select(PackedInt64Array())
	camera._input(left)
	checks.check(ui.session.selected == PackedInt64Array([expected_hits[0].brush_id]), "captured camera LMB selects the brush under the crosshair")
	var brush_ids := PackedInt64Array(ui.session.draw_data().map(func(brush): return brush.id))
	if brush_ids.size() >= 2:
		ui.session.select(PackedInt64Array())
		camera.apply_pick(brush_ids[0], 0, -1, true, true)
		camera.apply_pick(brush_ids[1], 0, -1, true, true)
		camera.apply_pick(brush_ids[0], 0, -1, true, true)
		checks.check(ui.session.selected == PackedInt64Array([brush_ids[0], brush_ids[1]]), "trace selection adds crossed brushes without toggling revisited brushes")
	var trace_press = left.duplicate()
	trace_press.shift_pressed = true
	camera._input(trace_press)
	checks.check(camera.selection_painting, "Shift+LMB starts crosshair trace selection in fly mode")
	var trace_release = trace_press.duplicate()
	trace_release.pressed = false
	camera._input(trace_release)
	checks.check(not camera.selection_painting, "releasing LMB stops crosshair trace selection")
	var movement_key = InputEventKey.new()
	movement_key.keycode = KEY_W
	movement_key.pressed = true
	camera._input(movement_key)
	var camera_position: Vector3 = camera.camera.position
	camera._process(0.25)
	checks.check(camera.camera.position.distance_to(camera_position) > 1, "fly movement frame delta")
	camera._input(right)
	camera._input(right_release)
	checks.check(not camera.flying and camera.held.is_empty() and not camera.crosshair.is_visible_in_tree(), "second RMB click-release exits FLY mode")
	var pan_start: Vector3 = camera.camera.position
	camera._gui_input(right)
	var pan_motion := InputEventMouseMotion.new()
	pan_motion.relative = Vector2(20, -12)
	camera._input(pan_motion)
	camera._input(right_release)
	checks.check(not camera.flying and camera.camera.position.distance_to(pan_start) > 0.01,
		"RMB hold-drag pans without leaving temporary FLY mode enabled")
	ui.session.select(PackedInt64Array([expected_hits[0].brush_id]))
	var grid_key := InputEventKey.new()
	grid_key.keycode = KEY_G
	grid_key.pressed = true
	camera._gui_input(grid_key)
	checks.check(camera.surface_grid_visible and camera.overlays.has_node("SelectedSurfaceGrid"),
		"G toggles map-grid lines across selected brush surfaces in the camera")
	camera._gui_input(grid_key)
	checks.check(not camera.surface_grid_visible and not camera.overlays.has_node("SelectedSurfaceGrid"),
		"second G hides selected-brush camera grid lines")
	if brush_ids.size() >= 2:
		ui.session.select(PackedInt64Array())
		var brush_trace = left.duplicate()
		brush_trace.position = camera.size * 0.5
		brush_trace.shift_pressed = true
		camera._gui_input(brush_trace)
		var first_brush := int(expected_hits[0].brush_id)
		var second_brush := int(brush_ids[0] if brush_ids[0] != first_brush else brush_ids[1])
		camera.paint_brush({"brush_id": second_brush})
		camera.paint_brush({"brush_id": first_brush})
		checks.check(camera.camera_gesture == "brush_paint" and ui.session.selected.has(first_brush)
			and ui.session.selected.has(second_brush) and ui.session.selected.size() == 2,
			"camera Shift+LMB drag paints crossed brushes without toggling revisits")
		brush_trace.pressed = false
		camera._gui_input(brush_trace)
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
	checks.check(plugin.built_materials_page.get_parent() == plugin.materials_panel, "leaving Radiant preserves the plugin-owned Map Materials UI")
	var loader = ClassDB.instantiate("TBLoader")
	loader.name = "SpatialMaterialContext"
	var material_mesh := MeshInstance3D.new()
	var material_fixture := StandardMaterial3D.new()
	material_fixture.resource_name = "IntegrationMaterial"
	var material_geometry := QuadMesh.new()
	material_geometry.material = material_fixture
	material_mesh.mesh = material_geometry
	loader.add_child(material_mesh)
	plugin._edit(loader)
	plugin.show_materials()
	checks.check(plugin.materials_panel == shared_materials_panel and plugin.materials_grid.item_count == 1 and plugin.materials_tree.get_root().get_child_count() == 1, "3D Map Materials opens the shared rich all-material grid/list")
	plugin.materials_search.text = "missing"
	plugin.filter_materials(plugin.materials_search.text)
	checks.check(plugin.materials_grid.item_count == 0 and plugin.materials_count_label.text == "0 of 1 materials", "Map Materials search filters grid and list entries")
	plugin.materials_search.text = "integration"
	plugin.filter_materials(plugin.materials_search.text)
	checks.check(plugin.materials_grid.item_count == 1 and plugin.materials_tree.get_root().get_child_count() == 1, "Map Materials search matches material names case-insensitively")
	plugin.materials_search.text = ""
	plugin.filter_materials(plugin.materials_search.text)
	plugin.hide_bottom_panel()
	plugin._make_visible(true)
	plugin.show_materials()
	checks.check(plugin.materials_panel == shared_materials_panel and plugin.materials_grid.item_count == 1, "Radiant Map Materials opens the identical rich panel and content")
	plugin.hide_bottom_panel()
	checks.check(plugin.map_control.visible and plugin.map_control.get_child(0).disabled and plugin.map_control.get_child(1).disabled, "spatial toolbar remains visible but disabled without a loader selection")
	# Explicit selection is separate from session binding.
	var selection_session = ui.session
	plugin._edit(loader)
	checks.check(ui.session == selection_session and ui.session.loader.get_ref() == null, "spatial selection never changes document/binding")
	checks.check(plugin.materials_panel == shared_materials_panel, "spatial selection cannot replace the shared Map Materials UI")
	plugin._edit(null)
	loader.free()
	await binding_journey(plugin)
	ui.set_scene_active(false)
	precision_journey()
	visibility_filter_journey()
	await grid_draw_batch_regression()
	step5_native_editor_journey()
	await phase5_journey()
	vertex_hull_drag_journey()
	shallow_prism_drag_journey()
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
	session_manifest_regression()
	var recovery = prepare_recovery_regression()
	var old_ui = weakref(ui)
	var old_panel = weakref(plugin.materials_panel)
	var old_uv_panel = weakref(plugin.uv_panel)
	var old_entities_panel = weakref(plugin.entities_panel)
	var old_toolbar = weakref(plugin.map_control)
	ui = null
	EditorInterface.set_plugin_enabled("tbloader", false)
	await get_tree().process_frame
	await get_tree().process_frame
	checks.check(old_ui.get_ref() == null and old_toolbar.get_ref() == null and old_panel.get_ref() == null
		and old_uv_panel.get_ref() == null and old_entities_panel.get_ref() == null, "disable frees all Map and bottom-panel controls")
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
	camera_view.camera_transform_changed()
	checks.check(graph.camera_position.is_equal_approx(Vector3(7, 3, 5) * camera_view.map_scale()) and ui.graph_b.camera_position.is_equal_approx(graph.camera_position), "camera movement updates every graph marker from the movement event")
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
	var source_world_environment := WorldEnvironment.new()
	source_world_environment.name = "WorldEnvironment"
	source_world_environment.environment = Environment.new()
	source_world_environment.environment.background_mode = Environment.BG_SKY
	source_world_environment.environment.sky = Sky.new()
	source_world_environment.environment.sky.sky_material = ProceduralSkyMaterial.new()
	source_world_environment.environment.background_energy_multiplier = 1.25
	source_world_environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_BG
	source_world_environment.environment.ambient_light_sky_contribution = 0.8
	source_world_environment.environment.reflected_light_source = Environment.REFLECTION_SOURCE_BG
	source_world_environment.environment.fog_enabled = true
	source_world_environment.environment.fog_density = 0.0125
	source.add_child(source_world_environment)
	source_world_environment.owner = source
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
	checks.check(plugin.map_control.visible and plugin.editing_loader.get_ref() == loader and not plugin.map_control.get_child(0).disabled and not plugin.map_control.get_child(1).disabled, "spatial toolbar enables selected-loader actions promptly")
	checks.check(not ui.loader_actions.BindLoader.disabled, "Map Bind enables promptly for the selected TBLoader")
	ui.bind_selected()
	checks.check(ui.session.loader.get_ref() == loader and ui.valid_binding() and not ui.loader_actions.DetachLoader.disabled and not ui.loader_actions.UpdateLoaderPath.disabled and not ui.loader_actions.BuildMeshes.disabled and not ui.rebuild_on_save.disabled, "explicit Bind loads the document and enables bound actions")
	var source_environment: Environment = root.get_node("WorldEnvironment").environment
	ui.camera_view.sync_scene_environment(true)
	var preview_environment: Environment = ui.camera_view.preview_world_environment.environment
	checks.check(loader.get_world_3d().environment == source_environment, "bound loader world exposes the effective scene environment")
	checks.check(preview_environment != source_environment and preview_environment.sky == source_environment.sky, "camera owns its environment and shares the effective scene sky read-only")
	checks.check(is_equal_approx(preview_environment.background_energy_multiplier, 1.25), "camera copies scene sky background energy")
	checks.check(preview_environment.ambient_light_source == Environment.AMBIENT_SOURCE_BG, "camera copies sky ambient-light source")
	checks.check(is_equal_approx(preview_environment.ambient_light_sky_contribution, 0.8), "camera copies sky ambient contribution")
	checks.check(preview_environment.reflected_light_source == Environment.REFLECTION_SOURCE_BG, "camera copies sky reflected-light source for PBR")
	checks.check(preview_environment.fog_enabled and is_equal_approx(preview_environment.fog_density, 0.0125),
		"camera copies the complete scene WorldEnvironment")
	var bound_loader = ui.session.loader
	var bound_scene = ui.session.scene
	ui.session.loader = weakref(null)
	ui.session.scene = weakref(null)
	ui.camera_view.inferred_scene_key.clear()
	var inferred_context: Dictionary = ui.camera_view.preview_scene_context()
	checks.check(inferred_context.get("root") == root and inferred_context.get("loader") == loader,
		"camera infers and caches its edited scene from the open map path before formal binding")
	ui.session.loader = bound_loader
	ui.session.scene = bound_scene
	ui.camera_view.preview_environment_button.button_pressed = false
	checks.check(ui.camera_view.preview_world_environment.environment == null,
		"WorldEnvironment toggle detaches the camera preview environment")
	ui.camera_view.preview_environment_button.button_pressed = true
	checks.check(ui.camera_view.preview_world_environment.environment.sky == source_environment.sky,
		"WorldEnvironment toggle restores the effective scene sky")
	var preview_geometry_ids: Array = ui.camera_view.map_geometry.get_children().map(func(node): return node.get_instance_id())
	ui.camera_view.environment_resource_changed()
	ui.camera_view.sync_scene_environment()
	checks.check(ui.camera_view.map_geometry.get_children().map(func(node): return node.get_instance_id()) == preview_geometry_ids,
		"environment refresh leaves camera geometry untouched")
	checks.check(loader.has_method("build_visual_preview_checked"), "native checked visual preview is available")
	ui.camera_view.set_built_appearance(true)
	checks.check(ui.camera_view.built_preview_valid and ui.camera_view.built_geometry.visible and not ui.camera_view.map_geometry.visible,
		"Built appearance atomically replaces authoring visuals after a successful build")
	var built_meshes: Array = ui.camera_view.built_geometry.find_children("*", "MeshInstance3D", true, false)
	checks.check(not built_meshes.is_empty() and ui.camera_view.built_geometry.find_children("*", "CollisionShape3D", true, false).is_empty()
		and ui.camera_view.built_geometry.find_children("*", "Area3D", true, false).is_empty(),
		"Built appearance contains visual meshes without collision or gameplay nodes")
	checks.check(built_meshes.all(func(node): return node.owner == null and node.mesh.get_surface_count() > 0),
		"Built appearance output is ownerless and contains generated surfaces")
	checks.check(built_meshes.all(func(node):
		for surface in node.mesh.get_surface_count():
			var arrays: Array = node.mesh.surface_get_arrays(surface)
			if arrays[Mesh.ARRAY_TANGENT].size() != arrays[Mesh.ARRAY_VERTEX].size() * 4:
				return false
		return true), "Built appearance supplies tangent-space data for PBR materials")
	var built_ids: Array = built_meshes.map(func(node): return node.get_instance_id())
	var invalid_preview: Dictionary = loader.build_visual_preview_checked(null, ui.camera_view.built_geometry)
	checks.check(not invalid_preview.ok and invalid_preview.error.code == "INVALID_ARGUMENT"
		and ui.camera_view.built_geometry.find_children("*", "MeshInstance3D", true, false).map(func(node): return node.get_instance_id()) == built_ids,
		"invalid visual preview generation preserves the exact previous target")
	var collision_only_document = ClassDB.instantiate("TBMapDocument")
	checks.check(collision_only_document.load_map("res://fixtures/classic_cube.map").ok, "collision-only preview fixture loads")
	var collision_brush: int = collision_only_document.get_draw_data()[0].id
	checks.check(collision_only_document.group_brushes(PackedInt64Array([collision_brush]), "area").ok, "collision-only preview fixture groups its brush")
	var collision_only_target := Node3D.new()
	var collision_only_preview: Dictionary = loader.build_visual_preview_checked(collision_only_document, collision_only_target)
	checks.check(collision_only_preview.ok and collision_only_target.find_children("*", "MeshInstance3D", true, false).is_empty(),
		"Built appearance omits common collision-only entity geometry")
	collision_only_target.free()
	ui.camera_view.camera.position += Vector3.ONE
	ui.camera_view.refresh()
	checks.check(ui.camera_view.built_geometry.find_children("*", "MeshInstance3D", true, false).map(func(node): return node.get_instance_id()) == built_ids,
		"camera movement reuses cached built geometry")
	ui.camera_view.set_built_appearance(false)
	checks.check(ui.camera_view.map_geometry.visible and not ui.camera_view.built_geometry.visible,
		"disabling Built appearance restores authoring geometry")
	var bound_session = ui.session
	var bound_session_count = ui.sessions.size()
	plugin.map_control.get_child(1).pressed.emit()
	checks.check(ui.session == bound_session and ui.sessions.size() == bound_session_count, "repeated Open in Map Editor activates the bound document without duplicating it")
	selection.clear()
	plugin.spatial_selection_changed()
	checks.check(plugin.map_control.visible and plugin.map_control.get_child(0).disabled and plugin.map_control.get_child(1).disabled and ui.loader_actions.BindLoader.disabled, "clearing spatial selection disables selected-loader actions promptly")
	selection.add_node(other)
	plugin.spatial_selection_changed()
	checks.check(ui.session.loader.get_ref() == loader and plugin.editing_loader.get_ref() == other, "second loader selection preserves explicit binding")
	ui.bind_loader(other)
	checks.check(ui.session.loader.get_ref() == other, "bind_loader opens the exact requested TBLoader independent of prior binding")
	ui.bind_loader(loader)
	checks.check(ui.session.loader.get_ref() == loader, "bind_loader can return to the exact Inspector loader")
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
	checks.check(ui.session.baked_text == text() and ui.status.text.contains("meshes current"), "saved/build state independently reported")
	checks.check(not loader.find_children("*", "MeshInstance3D", true, false).is_empty(), "real baked mesh output")
	var baked_meshes: Array = loader.find_children("*", "MeshInstance3D", true, false)
	checks.check(built_meshes.size() == baked_meshes.size(), "built camera and scene bake create the same visual mesh count")
	for mesh_index in mini(built_meshes.size(), baked_meshes.size()):
		var preview_mesh: MeshInstance3D = built_meshes[mesh_index]
		var baked_mesh: MeshInstance3D = baked_meshes[mesh_index]
		checks.check(preview_mesh.transform == baked_mesh.transform and preview_mesh.get_parent().transform == baked_mesh.get_parent().transform,
			"built camera transforms match bake %d" % mesh_index)
		checks.check(preview_mesh.layers == baked_mesh.layers, "built camera layers match bake %d" % mesh_index)
		checks.check(preview_mesh.gi_mode == baked_mesh.gi_mode, "built camera GI mode matches bake %d" % mesh_index)
		checks.check(preview_mesh.mesh.get_surface_count() == baked_mesh.mesh.get_surface_count(),
			"built camera surface count matches bake %d" % mesh_index)
		for surface in mini(preview_mesh.mesh.get_surface_count(), baked_mesh.mesh.get_surface_count()):
			var preview_arrays: Array = preview_mesh.mesh.surface_get_arrays(surface)
			var baked_arrays: Array = baked_mesh.mesh.surface_get_arrays(surface)
			for array_index in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TANGENT, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_INDEX]:
				checks.check(preview_arrays[array_index] == baked_arrays[array_index],
					"built camera array %d matches bake mesh %d surface %d" % [array_index, mesh_index, surface])
	var old_probe_volume := MockSteamAudioProbeVolume.new()
	old_probe_volume.name = "SteamAudioProbeVolume"
	var old_probe_branch := Node3D.new()
	root.add_child(old_probe_branch)
	old_probe_branch.add_child(old_probe_volume)
	var skybox_branch := Node3D.new()
	skybox_branch.name = "skybox"
	loader.add_child(skybox_branch)
	var skybox_mesh := MeshInstance3D.new()
	var skybox_box := BoxMesh.new()
	skybox_box.size = Vector3.ONE * 100000.0
	skybox_mesh.mesh = skybox_box
	skybox_branch.add_child(skybox_mesh)
	var probe_volume := MockSteamAudioProbeVolume.new()
	plugin.add_steam_audio_probe_volume(loader, probe_volume)
	checks.check(probe_volume.get_parent() == loader.get_parent() and probe_volume.get_index() + 1 == loader.get_index()
		and probe_volume.owner == root,
		"Steam Audio probe volume is the sibling immediately above TBLoader with scene ownership")
	checks.check(old_probe_volume.get_parent() == null and old_probe_volume.is_queued_for_deletion(),
		"Steam Audio probe generation removes an existing volume anywhere in the edited scene before replacement")
	checks.check(skybox_mesh.gi_mode == GeometryInstance3D.GI_MODE_DISABLED,
		"skybox meshes are excluded from GI")
	var map_bounds: AABB = baked_meshes[0].global_transform * baked_meshes[0].mesh.get_aabb()
	for mesh_index in range(1, baked_meshes.size()):
		var mesh_instance: MeshInstance3D = baked_meshes[mesh_index]
		map_bounds = map_bounds.merge(mesh_instance.global_transform * mesh_instance.mesh.get_aabb())
	checks.check(is_equal_approx(probe_volume.spacing, 3.0)
		and probe_volume.size.is_equal_approx(map_bounds.size)
		and probe_volume.global_position.is_equal_approx(map_bounds.get_center()),
		"Steam Audio probe volume uses spacing 3 and the generated map AABB")
	checks.check(probe_volume.bake_threads == OS.get_processor_count()
		and probe_volume.reflection_threads == OS.get_processor_count(),
		"Steam Audio probe baking uses all available processor threads")
	checks.check(probe_volume.generated, "Steam Audio probes are generated during map bake")
	skybox_branch.free()
	checks.check(not loader.find_children("*", "CollisionShape3D", true, false).is_empty(), "real baked collision output")
	var bake_action = ui.last_bake_action.get_ref()
	checks.check(bake_action != null and bake_action.get_retention_counters().packed_snapshot_count == 0
		and bake_action.get_retention_counters().detached_root_count == 1,
		"bake history retains one detached predecessor subtree and no packed generated snapshots")
	checks.check(ui.camera_view.triangle_count == 0 and not hidden_ids.is_empty(), "bake retains brushes hidden from editor preview")
	ui.session.hide_selection(true)
	checks.check(scene_history.undo() and loader.has_node("PreviousOutput"), "bake undo uses scene history and restores prior children")
	checks.check(not bake_action.get_retention_counters().live_is_after
		and bake_action.get_retention_counters().detached_root_count > 0,
		"bake undo swaps generated output into the single detached history subtree")
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
	checks.check(ui.status.text.contains("meshes stale") and not ui.bake(), "unsaved edits invalidate mesh build and prevent rebuild")
	key(KEY_Z, true)
	checks.check(ui.status.text.contains("meshes current"), "map undo to built content restores mesh status")
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
	checks.check(ui.loader_actions.DetachLoader.disabled and ui.loader_actions.UpdateLoaderPath.disabled and ui.loader_actions.BuildMeshes.disabled and ui.rebuild_on_save.disabled, "Detach disables all bound-session actions promptly")
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
	EditorInterface.set_main_screen_editor("Radiant")
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
	var delta_session = load("res://addons/tbloader/src/editor/map_session.gd").new()
	checks.check(delta_session.document.load_map("res://fixtures/tohunga.map").ok, "draw delta session loads Tohunga")
	var delta_draw: Array = delta_session.draw_data()
	var unchanged_id: int = delta_draw[2].id
	var unchanged_dictionary: Dictionary = delta_draw[2]
	var unchanged_data: Dictionary = unchanged_dictionary.duplicate(true)
	var first_id: int = delta_draw[0].id
	var second_id: int = delta_draw[1].id
	var token: int = delta_draw[0].topology_revision
	var delta_before: Dictionary = delta_session.capture()
	var duplicate_min: Vector3 = delta_session.brush(first_id).aabb_min
	var counters_before: Dictionary = delta_session.draw_cache_counters()
	checks.check(delta_session.translate_brushes(PackedInt64Array([first_id, first_id]), Vector3.RIGHT).ok
		and delta_session.brush(first_id).aabb_min == duplicate_min + Vector3.RIGHT,
		"duplicate session selection patches translated draw data exactly once")
	var counters_after: Dictionary = delta_session.draw_cache_counters()
	checks.check(counters_after.touched_draw_entries - counters_before.touched_draw_entries == 1
		and counters_after.full_cache_iterations == counters_before.full_cache_iterations
		and counters_after.full_cache_duplicates == counters_before.full_cache_duplicates,
		"connected one-brush translation touches one draw entry with no full-cache work")
	delta_session.restore(delta_before)
	counters_before = delta_session.draw_cache_counters()
	checks.check(delta_session.document.set_face_texture(first_id, 0, "delta/direct", token).ok,
		"direct connected local edit reaches MapSession draw delta")
	counters_after = delta_session.draw_cache_counters()
	checks.check(counters_after.touched_draw_entries - counters_before.touched_draw_entries == 1
		and counters_after.full_cache_iterations == counters_before.full_cache_iterations
		and counters_after.full_cache_duplicates == counters_before.full_cache_duplicates
		and delta_session.brush(first_id).faces[0].texture == "delta/direct",
		"direct local edit replaces one indexed draw entry only")
	var direct_after: Dictionary = delta_session.capture()
	for history_state in [delta_before, direct_after]:
		counters_before = delta_session.draw_cache_counters()
		delta_session.restore(history_state)
		counters_after = delta_session.draw_cache_counters()
		checks.check(counters_after.touched_draw_entries - counters_before.touched_draw_entries == 1
			and counters_after.full_cache_iterations == counters_before.full_cache_iterations
			and counters_after.full_cache_duplicates == counters_before.full_cache_duplicates,
			"one-brush undo/redo touches one draw entry with no full-cache work")
	delta_session.restore(delta_before)
	delta_session.select(PackedInt64Array([first_id, unchanged_id]))
	var first_component := {"brush_id": first_id, "kind": "face", "index": 0,
		"topology_revision": delta_session.brush(first_id).topology_revision}
	var unchanged_component := {"brush_id": unchanged_id, "kind": "face", "index": 0,
		"topology_revision": delta_session.brush(unchanged_id).topology_revision}
	delta_session.components = [first_component, unchanged_component]
	var component_before: Dictionary = delta_session.capture()
	checks.check(delta_session.document.translate_face(first_id, 0,
			delta_session.brush(first_id).faces[0].normal, first_component.topology_revision).ok,
		"connected topology edit changes the selected target brush")
	checks.check(not delta_session.component_valid(first_component, delta_session.brush(first_id))
		and delta_session.component_valid(unchanged_component, delta_session.brush(unchanged_id)),
		"independent selected component stays valid while changed brush token becomes stale")
	delta_session.rebind_components()
	var component_after: Dictionary = delta_session.capture()
	for history_state in [component_before, component_after]:
		counters_before = delta_session.draw_cache_counters()
		delta_session.restore(history_state)
		counters_after = delta_session.draw_cache_counters()
		checks.check(delta_session.components.size() == 2
			and delta_session.components.all(func(component): return delta_session.component_valid(component, delta_session.brush(component.brush_id)))
			and counters_after.touched_draw_entries - counters_before.touched_draw_entries == 1
			and counters_after.full_cache_iterations == counters_before.full_cache_iterations,
			"component selection undo/redo rebinds only against per-brush tokens")
	delta_session.restore(delta_before)
	checks.check(delta_session.document.apply_face_edits([
		{"brush_id": first_id, "face": 0, "topology_revision": token, "texture": "delta/one"},
		{"brush_id": second_id, "face": 0, "topology_revision": token, "texture": "delta/two"}]).ok,
		"two-brush metadata edit commits through draw delta")
	checks.check(delta_session.brush(first_id).faces[0].texture == "delta/one" and delta_session.brush(second_id).faces[0].texture == "delta/two",
		"two changed brush dictionaries cross into the session cache")
	checks.check(is_same(delta_session.brush(unchanged_id), unchanged_dictionary) and delta_session.brush(unchanged_id) == unchanged_data,
		"unchanged draw dictionary identity and data remain intact")
	var delta_after: Dictionary = delta_session.capture()
	var reads_before_history: int = delta_session.draw_cache_counters().full_draw_reads
	delta_session.restore(delta_before)
	delta_session.restore(delta_after)
	checks.check(delta_session.draw_cache_counters().full_draw_reads == reads_before_history
		and delta_session.brush(first_id).faces[0].texture == "delta/one", "local undo and redo patch without full get_draw_data")
	checks.check(not delta_session.get_property_list().any(func(property): return property.name in ["_history_caches", "_history_cache_order"])
		and delta_session.draw_cache_counters().history_cache_retained_bytes == 0, "session retains no full history cache payloads")
	var resets_before: int = delta_session.draw_cache_counters().full_draw_resets
	checks.check(delta_session.document.create_cuboid(Vector3(-8, -8, -8), Vector3(8, 8, 8), "common/caulk").ok
		and not delta_session._draw_valid and delta_session._draw_cache.is_empty(), "structural fallback clears the stale draw payload")
	delta_session.draw_data()
	checks.check(delta_session.draw_cache_counters().full_draw_resets == resets_before + 1, "structural fallback rebuilds on demand")
	var texture_cache_before: Dictionary = delta_session.draw_cache_counters()
	var retained_draw: Array = delta_session.draw_data()
	var retained_entities: Array = delta_session.entity_data()
	var retained_markers: Array = delta_session.point_markers()
	checks.check(delta_session.document.set_texture_sizes({"baseline/checker": Vector2i(64, 32)}).ok, "session applies UV-only texture dimensions")
	var texture_cache_after: Dictionary = delta_session.draw_cache_counters()
	checks.check(delta_session._draw_valid and delta_session._entity_valid and delta_session._marker_valid
		and is_same(delta_session.draw_data(), retained_draw) and is_same(delta_session.entity_data(), retained_entities)
		and is_same(delta_session.point_markers(), retained_markers)
		and texture_cache_after.full_draw_resets == texture_cache_before.full_draw_resets
		and texture_cache_after.full_draw_reads == texture_cache_before.full_draw_reads
		and texture_cache_after.preview_uv_cache_retentions == texture_cache_before.preview_uv_cache_retentions + 1,
		"texture dimensions retain draw/entity/marker caches with zero full draw resets or reads")
	checks.check(delta_session.document.rebuild().ok and not delta_session._draw_valid,
		"explicit preview rebuild still clears the session draw cache")
	delta_session.dispose()
	checks.check(ui.open_path("res://fixtures/tohunga.map"), "editor opens local Tohunga fixture")
	var canonical := text()
	var brushes: Array = ui.session.document.get_draw_data()
	checks.check(brushes.size() > 100 and ui.session.document.get_entities().size() > 1, "editor exposes Tohunga brush and entity topology")
	if brushes.size() >= 2:
		var graph = ui.graph_a
		ui.session.select(PackedInt64Array())
		graph.frame_selection()
		ui.session.select(PackedInt64Array([brushes[0].id]))
		graph.rebuild_dense_edge_cache()
		graph.gesture = "move"
		graph.delta = Vector3(ui.session.grid, 0, 0)
		await get_tree().process_frame
		RenderingServer.force_draw()
		graph.reset_render_counters()
		graph.queue_selection_redraw()
		await get_tree().process_frame
		RenderingServer.force_draw()
		checks.check(graph.render_counters().selection_mask_points > 0 and graph.render_counters().static_edge_builds == 0,
			"dense move gesture masks the original gray selection without rebuilding global static storage")
		graph.gesture = "rotate"
		graph.rotation_pivot = graph.selection_center()
		graph.rotation_angle = PI / 4.0
		await get_tree().process_frame
		RenderingServer.force_draw()
		graph.reset_render_counters()
		graph.queue_selection_redraw()
		await get_tree().process_frame
		RenderingServer.force_draw()
		checks.check(graph.render_counters().selection_mask_points > 0 and graph.render_counters().static_edge_builds == 0,
			"dense rotate gesture masks the original gray selection without rebuilding global static storage")
		graph.cancel()
		var dense_before: Dictionary = ui.session.capture()
		var dense_move := Vector3(ui.session.grid, 0, 0)
		checks.check(ui.session.translate_brushes(ui.session.selected, dense_move).ok, "prepare Tohunga dense cache translation state")
		graph.apply_dense_translation(dense_move)
		var dense_after: Dictionary = ui.session.capture()
		graph.reset_render_counters()
		for repeat in 2:
			ui.session.restore(dense_before)
			await get_tree().process_frame
			RenderingServer.force_draw()
			ui.session.restore(dense_after)
			await get_tree().process_frame
			RenderingServer.force_draw()
		var dense_history_counts: Dictionary = graph.render_counters()
		checks.check(dense_history_counts.static_edge_restores == 4 and dense_history_counts.static_edge_builds == 0
			and dense_history_counts.dense_cache_states == 2,
			"repeated Tohunga undo/redo redraws restore dense static arrays without a 5,060-brush rebuild")
		checks.check(dense_history_counts.dense_cache_retained_bytes > 0,
			"Tohunga dense two-state history accounts its bounded retained payload")
		ui.session.restore(dense_before)
		graph.restore_dense_edge_cache()
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
	var freshness = load("res://addons/tbloader/src/editor/map_session.gd").new()
	for generation in ui.BAKED_STATE_RECORD_LIMIT + 7:
		freshness.document.create_cuboid(Vector3(generation * 16, 0, 0), Vector3(generation * 16 + 8, 8, 8), "review/freshness")
		ui.remember_baked_state(freshness, freshness.document.export_text().value)
	var freshness_state: Dictionary = freshness.get_meta(ui.BAKED_STATE_META)
	checks.check(freshness_state.records.size() == ui.BAKED_STATE_RECORD_LIMIT
		and freshness_state.current_records.size() == 1 and ui.baked_state_is_current(freshness, freshness_state),
		"baked freshness records retain the current generation with a strict per-session bound")
	freshness.dispose()
	var Session = load("res://addons/tbloader/src/editor/map_session.gd")
	var Action = load("res://addons/tbloader/src/editor/map_action.gd")
	var direct = Session.new()
	var direct_before: Dictionary = direct.capture()
	direct.document.create_cuboid(Vector3.ZERO, Vector3.ONE * 8, "review/direct")
	var direct_after: Dictionary = direct.capture()
	var direct_token = Action.new()
	direct_token.session = direct
	direct_token.before = direct_before
	direct_token.after = direct_after
	direct_token.epoch = direct.document.get_epoch()
	direct_token.before_generation = direct_before.native.get_state_generation()
	direct_token.after_generation = direct_after.native.get_state_generation()
	direct_token.restore(false)
	direct.document.create_cuboid(Vector3.ONE * 16, Vector3.ONE * 24, "review/stale")
	var direct_stale_text: String = direct.document.export_text().value
	direct_token.restore(true)
	checks.check(direct_token.session == null and direct.document.export_text().value == direct_stale_text,
		"direct stale snapshot fallback callback retires without restoring out of order")
	direct.dispose()

	var global_stale = Session.new()
	ui.set_session(global_stale)
	checks.check(global_stale.transact("Global stale fallback fixture", func(): return global_stale.document.create_cuboid(Vector3.ZERO, Vector3.ONE * 8, "review/global")),
		"record actual global structural fallback action")
	var global_token = ui.tokens.back()
	global_stale.document.create_cuboid(Vector3.ONE * 16, Vector3.ONE * 24, "review/out-of-band")
	var global_stale_text: String = global_stale.document.export_text().value
	checks.check(history.undo() and global_token.session == null and global_stale.document.export_text().value == global_stale_text,
		"actual global stale history callback advances cursor as a safe retired no-op")
	ui.set_session(load("res://addons/tbloader/src/editor/map_session.gd").new())
	var accounting_before: Dictionary = ui.session.capture()
	var small_envelope_bytes: int = ui.session.ui_envelope_retained_bytes(accounting_before)
	ui.session.selected = PackedInt64Array(range(4096))
	ui.session.points = PackedInt64Array(range(8192))
	ui.session.components = []
	for index in 2048:
		ui.session.components.append({"brush_id": 0, "kind": "face", "index": index,
			"topology_revision": 1, "label": "large-component-selection"})
	var large_envelope := {"selected_brush_ids": ui.session.selected, "points": ui.session.points,
		"components": ui.session.components, "workzone": ui.session.workzone}
	var large_envelope_bytes: int = ui.session.ui_envelope_retained_bytes(large_envelope)
	checks.check(large_envelope_bytes > small_envelope_bytes + (4096 + 8192) * 8
		and large_envelope_bytes > 2048 * ui.session.UI_COMPONENT_DICTIONARY_BYTES,
		"UI envelope accounting scales with large brush/point selections and component dictionaries")
	ui.session.selected = PackedInt64Array()
	ui.session.points = PackedInt64Array()
	ui.session.components = []
	var accounting_id: int = ui.session.document.create_cuboid(Vector3.ZERO, Vector3.ONE * 32, "accounting/a").value
	var accounting_structural: Dictionary = ui.session.capture()
	var structural_bytes: int = ui.session.history_action_bytes(accounting_before, accounting_structural)
	var accounting_token: int = ui.session.brush(accounting_id).topology_revision
	var rollback_text: String = ui.session.document.export_text().value
	var rollback_generation: int = ui.session.document.get_state_generation()
	var rollback_tokens: int = ui.tokens.size()
	checks.check(not ui.session.transact("Atomic rollback review", func():
		var moved: Dictionary = ui.session.document.translate_brushes(PackedInt64Array([accounting_id]), Vector3.RIGHT)
		if not moved.ok:
			return moved
		return ui.session.document.set_face_texture(9223372036854775807, 0, "bad", accounting_token)
	) and ui.session.document.export_text().value == rollback_text
		and ui.session.document.get_state_generation() == rollback_generation and ui.tokens.size() == rollback_tokens,
		"failed second command rolls back the first mutation without recording history")
	var fatal_rollback = Session.new()
	var fatal_messages: Array[String] = []
	fatal_rollback.message.connect(func(value: String): fatal_messages.append(value))
	checks.check(not fatal_rollback.transact("Fatal rollback review", func():
		var replaced: Dictionary = fatal_rollback.document.import_text(FileAccess.get_file_as_string("res://fixtures/classic_cube.map"))
		if not replaced.ok:
			return replaced
		return fatal_rollback.document.set_entity_property(9223372036854775807, "bad", "value")
	) and fatal_messages.any(func(value): return value.begins_with("FATAL_TRANSACTION_ROLLBACK:")),
		"epoch-changing partial failure reports explicit fatal rollback instead of claiming atomic restoration")
	fatal_rollback.dispose()
	checks.check(ui.session.document.translate_brushes(PackedInt64Array([accounting_id]), Vector3.RIGHT).ok, "prepare first shared accounting state")
	var accounting_local_one: Dictionary = ui.session.capture()
	var local_one_bytes: int = ui.session.history_action_bytes(accounting_structural, accounting_local_one)
	checks.check(ui.session.document.translate_brushes(PackedInt64Array([accounting_id]), Vector3.RIGHT).ok, "prepare second shared accounting state")
	var accounting_local_two: Dictionary = ui.session.capture()
	var local_two_bytes: int = ui.session.history_action_bytes(accounting_local_one, accounting_local_two)
	checks.check(structural_bytes > ui.session.ui_envelope_retained_bytes(accounting_before) + ui.session.ui_envelope_retained_bytes(accounting_structural)
		and local_one_bytes < accounting_structural.native.get_retained_bytes() + accounting_local_one.native.get_retained_bytes()
			+ ui.session.ui_envelope_retained_bytes(accounting_structural) + ui.session.ui_envelope_retained_bytes(accounting_local_one)
		and local_two_bytes < accounting_local_one.native.get_retained_bytes() + accounting_local_two.native.get_retained_bytes()
			+ ui.session.ui_envelope_retained_bytes(accounting_local_one) + ui.session.ui_envelope_retained_bytes(accounting_local_two)
		and accounting_token > 0,
		"history actions charge symmetric unique roots while structural actions retain independent states")
	ui.set_session(load("res://addons/tbloader/src/editor/map_session.gd").new())
	checks.check(ui.save_path("res://discard-regression.map"), "discard regression establishes named baseline")
	for outcome in ["cancel", "invalid"]:
		review_edit("before " + outcome)
		var current = ui.session
		ui.file_command("open")
		checks.check(ui.file_dialog.visible and not ui.dirty_dialog.visible and current.save_enabled, "Open keeps the dirty document in its tab " + outcome)
		if outcome == "cancel":
			ui.file_dialog.canceled.emit()
		else:
			ui.file_selected("res://missing-review.map")
		ui.file_dialog.hide()
		review_edit("after " + outcome)
		checks.check(ui.session == current and current.save_enabled and ui.unsaved_status().contains("discard-regression.map"), "cancelled/invalid replacement keeps subsequent edits in unsaved reporting " + outcome)
		ui.save_all()
		checks.check(not current.document.is_dirty() and FileAccess.get_file_as_string("res://discard-regression.map") == text(), "Save All saves resumed edits " + outcome)
	review_edit("existing path reopen")
	var retained = ui.session
	var retained_count = ui.sessions.size()
	ui.file_command("open")
	ui.file_selected("res://discard-regression.map")
	ui.file_dialog.hide()
	checks.check(ui.session == retained and retained.save_enabled and ui.sessions.size() == retained_count and retained.document.is_dirty(), "opening a retained path preserves its unsaved document without duplication")
	retained.save_enabled = false
	review_edit("edit reactivates")
	checks.check(retained.save_enabled, "successful transaction reactivates retained session")
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
	for graph in [ui.graph_a, ui.graph_b]:
		ui.session.select(PackedInt64Array([ui.session.document.get_draw_data()[0].id]))
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
		checks.check(mesh_vertex_samples(loader) == mesh_vertex_samples(ui.camera_view.map_geometry), "camera/bake vertex-normal-UV parity for resolver %d" % index)
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

func session_manifest_regression() -> void:
	for origin in ui.sessions:
		origin.save_enabled = false
	var canonical := FileAccess.get_file_as_string("res://journey-bound.map")
	var clean_a = load("res://addons/tbloader/src/editor/map_session.gd").new()
	checks.check(clean_a.document.import_text(canonical).ok
		and clean_a.document.save_map("user://session-clean-a.map").ok, "session manifest clean path A fixture")
	ui.set_session(clean_a)
	var recovery_brush: int = clean_a.draw_data()[0].id
	checks.check(clean_a.transact("Recovery token lifetime", func(): return clean_a.document.translate_brushes(PackedInt64Array([recovery_brush]), Vector3.RIGHT)),
		"recovery lifetime fixture records local memento")
	var recovery_token = ui.tokens.back()
	var recovery_change_ref = weakref(recovery_token.change)
	var recovery_session_ref = weakref(clean_a)
	var recovery_document_ref = weakref(clean_a.document)
	recovery_token.restore(false)
	var dirty = load("res://addons/tbloader/src/editor/map_session.gd").new()
	checks.check(dirty.document.import_text(canonical).ok, "session manifest dirty fixture imports")
	dirty.document.create_cuboid(Vector3.ZERO, Vector3.ONE * 8, "common/caulk")
	var dirty_text: String = dirty.document.export_text().value
	ui.set_session(dirty)
	var pristine = load("res://addons/tbloader/src/editor/map_session.gd").new()
	ui.set_session(pristine)
	var clean_b = load("res://addons/tbloader/src/editor/map_session.gd").new()
	checks.check(clean_b.document.import_text(canonical).ok
		and clean_b.document.save_map("user://session-clean-b.map").ok, "session manifest clean path B fixture")
	ui.set_session(clean_b)
	var scene_clean = load("res://addons/tbloader/src/editor/map_session.gd").new()
	checks.check(scene_clean.document.import_text(canonical).ok
		and scene_clean.document.save_map("user://session-scene-clean.map").ok, "session manifest scene path fixture")
	scene_clean.scene_managed = true
	ui.set_session(scene_clean)
	ui.set_session(clean_a)
	ui.store_recovery()
	var manifest: Dictionary = EditorInterface.get_base_control().get_meta(ui.RECOVERY_META)
	checks.check(manifest.version == ui.RECOVERY_VERSION and manifest.active_tab == 0,
		"versioned session manifest retains the active clean path tab")
	checks.check(manifest.tabs.size() == 3 and manifest.tabs.map(func(record): return record.type) == ["path", "recovery", "path"]
		and manifest.tabs[0].path.ends_with("session-clean-a.map") and manifest.tabs[2].path.ends_with("session-clean-b.map"),
		"session manifest retains clean standalone paths and dirty text in tab order")
	checks.check(not manifest.tabs.any(func(record): return record.get("path", "").ends_with("session-scene-clean.map")),
		"session manifest omits pristine untitled and clean scene-managed tabs")
	var corrupt = FileAccess.open("user://session-corrupt.map", FileAccess.WRITE)
	corrupt.store_string("not a map")
	corrupt.close()
	EditorInterface.get_base_control().set_meta(ui.RECOVERY_META, {"version": ui.RECOVERY_VERSION, "active_tab": 0, "tabs": [
		{"type": "path", "path": "user://session-missing.map"},
		{"type": "path", "path": "user://session-clean-b.map"},
		{"type": "path", "path": "user://session-corrupt.map"},
		{"type": "recovery", "text": dirty_text, "source": "user://dirty-source.map"},
	]})
	clean_a = null
	ui.restore_recovery()
	checks.check(recovery_token.session == null and recovery_token.change == null, "recovery replacement retires removed-session history payload")
	recovery_token = null
	checks.check(recovery_change_ref.get_ref() == null, "recovery replacement releases removed local change lifetime")
	checks.check(recovery_session_ref.get_ref() == null, "recovery replacement releases removed session lifetime")
	checks.check(recovery_document_ref.get_ref() == null, "recovery replacement releases removed document lifetime")
	checks.check(ui.sessions.size() == 2 and ui.sessions[0].document.get_path().ends_with("session-clean-b.map")
		and ui.session == ui.sessions[0], "missing/corrupt active path falls forward to the next valid tab")
	checks.check(ui.sessions[1].document.export_text().value == dirty_text and ui.sessions[1].document.get_path().is_empty()
		and ui.sessions[1].recovery_source.ends_with("dirty-source.map") and ui.sessions[1].document.is_dirty(),
		"dirty manifest tab restores as a detached recovery document")
	EditorInterface.get_base_control().set_meta(ui.RECOVERY_META, [{"text": dirty_text,
		"source": "user://legacy-source.map", "root": "res://textures", "grid": 23.0, "texture": "legacy/texture"}])
	ui.restore_recovery()
	checks.check(ui.sessions.size() == 1 and ui.session.recovery_source.ends_with("legacy-source.map")
		and ui.session.grid == 23.0 and ui.session.texture == "legacy/texture"
		and ui.session.document.export_text().value == dirty_text,
		"legacy array recovery remains compatible")
	ui.session.save_enabled = false

func verify_recovery_regression(expected: Dictionary) -> void:
	checks.check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "disable releases captured mouse")
	checks.check(expected.named_ref.get_ref() == null and expected.untitled_ref.get_ref() == null and expected.document_ref.get_ref() == null, "disable releases original sessions and native documents even with expired history handles")
	checks.check(FileAccess.get_file_as_string("res://recovery-named.map") == expected.canonical, "disable/re-enable never overwrites named canonical file")
	checks.check(ui.session.document.export_text().value == expected.untitled,
		"disable/re-enable restores the previously active recovery tab")
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
	var recovered = ui.session
	var recovered_count = ui.sessions.size()
	ui.set_session(load("res://addons/tbloader/src/editor/map_session.gd").new())
	checks.check(ui.session.document.is_dirty(), "New has no saved baseline")
	checks.check(ui.open_path("res://recovered-copy.map") and ui.session == recovered and ui.session.document.is_dirty() and ui.sessions.size() == recovered_count + 1, "Open restores the retained dirty recovery tab instead of reloading its saved file")

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
	mixed_brush = scratch.brush(mixed)
	doc.set_face_texture(mixed, 1, "common/hint_skip", mixed_brush.topology_revision)
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
	ui.visibility_buttons.hint_skip.pressed.emit()
	checks.check(scratch.visibility_filters.hint_skip and ui.camera_view.triangle_count == 58
		and graph.hit_brush(graph.project(Vector3(416, 32, 0))) == mixed,
		"hint_skip toolbar toggle hides matching faces without hiding a mixed brush")
	ui.visibility_buttons.hint_skip.pressed.emit()
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
	mouse(graph, overlap_position, true, MOUSE_BUTTON_LEFT, true)
	motion(graph, graph.project(Vector3(220, 20, 0)), Vector2.ZERO, true)
	motion(graph, overlap_position, Vector2.ZERO, true)
	mouse(graph, overlap_position, false, MOUSE_BUTTON_LEFT, true)
	checks.check(scratch.selected == PackedInt64Array([second, contained]), "grid Shift+LMB trace-select adds crossed brushes without toggling revisited brushes")
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
	checks.check(graph.clip_contents and graph.static_layer.get_parent() == graph
		and graph.selection_layer.get_parent() == graph and graph.camera_layer.get_parent() == graph
		and graph.tool_layer.get_parent() == graph and [graph.static_layer, graph.selection_layer,
		graph.camera_layer, graph.tool_layer].all(func(layer): return layer.mouse_filter == Control.MOUSE_FILTER_IGNORE)
		and graph.static_layer.get_index() < graph.selection_layer.get_index()
		and graph.selection_layer.get_index() < graph.camera_layer.get_index()
		and graph.camera_layer.get_index() < graph.tool_layer.get_index(),
		"retained graph layers preserve clipping, mouse pass-through, and visual z-order")
	var selected: int = scratch.document.create_cuboid(Vector3(-48, -32, -16), Vector3(-16, 32, 16), "selected/material").value
	var unselected: int = scratch.document.create_cuboid(Vector3(16, -32, -16), Vector3(48, 32, 16), "unselected/material").value
	scratch.changed.emit()
	scratch.select(PackedInt64Array([selected]))
	graph.rebuild_dense_edge_cache()
	checks.check(graph.dense_base_edges.size() == 48 and graph.dense_edge_ranges[selected].y == 24
		and graph.dense_edge_ranges[unselected].y == 24 and graph.selected_edge_data().size() == 24,
		"dense grid stores every visible base edge once and derives selected edges separately")
	var dense_key: String = graph.dense_edge_cache_key
	var dense_base: PackedVector2Array = graph.dense_base_edges
	var selected_brush: Dictionary = scratch.brush(selected)
	checks.check(graph.selected_edge_data(false)[0].is_equal_approx(graph.project(selected_brush.edges[0])),
		"sparse selected visual data projects the same source edge as dense map-space data")
	scratch.select(PackedInt64Array([unselected]))
	checks.check(graph.current_dense_edge_key() == dense_key and graph.dense_base_edges == dense_base
		and graph.selected_edge_data().size() == 24,
		"selection changes preserve dense base storage while changing selected visual data")
	scratch.select(PackedInt64Array([selected]))
	graph.origin = Vector3(100, 200, 0)
	graph.zoom = 0.25
	checks.check(graph.current_dense_edge_key() == dense_key, "dense grid cache survives pan and zoom changes")
	scratch.hidden[selected] = true
	checks.check(graph.current_dense_edge_key() != dense_key, "dense grid cache invalidates when hidden brushes change")
	scratch.hidden.clear()
	graph.origin = Vector3.ZERO
	graph.zoom = 1
	graph.gesture = ""
	graph.queue_view_redraw()
	await get_tree().process_frame
	RenderingServer.force_draw()
	checks.check(graph.gesture == "" and scratch.selected == PackedInt64Array([selected]), "selected and unselected static grid edges redraw together")
	graph.reset_render_counters()
	scratch.select(PackedInt64Array([unselected]))
	await get_tree().process_frame
	RenderingServer.force_draw()
	var selection_counts: Dictionary = graph.render_counters()
	checks.check(selection_counts.static_redraws == 0 and selection_counts.static_edge_builds == 0
		and selection_counts.selection_redraws > 0 and selection_counts.camera_redraws == 0,
		"selection change redraws only selection/tool layer and never rebuilds static edges")
	graph.reset_render_counters()
	graph.set_camera_pose(Vector3(123, 45, 6), Vector3(1, 2, 3))
	await get_tree().process_frame
	RenderingServer.force_draw()
	var camera_counts: Dictionary = graph.render_counters()
	checks.check(camera_counts.static_redraws == 0 and camera_counts.static_edge_builds == 0
		and camera_counts.selection_redraws == 0 and camera_counts.camera_redraws > 0,
		"camera movement redraws only the lightweight camera marker layer")
	graph.rebuild_dense_edge_cache()
	graph.reset_render_counters()
	var cache_a: Dictionary = scratch.capture()
	var cache_a_edges: PackedVector2Array = graph.dense_base_edges.duplicate()
	var cache_a_ranges: Dictionary = graph.dense_edge_ranges.duplicate()
	var cache_movement := Vector3(16, 0, 0)
	var cache_move: Dictionary = scratch.translate_brushes(PackedInt64Array([unselected]), cache_movement)
	graph.apply_dense_translation(cache_movement)
	var cache_b: Dictionary = scratch.capture()
	var cache_b_edges: PackedVector2Array = graph.dense_base_edges.duplicate()
	var patched_counts: Dictionary = graph.render_counters()
	checks.check(cache_move.ok and cache_a_edges != cache_b_edges and patched_counts.static_edge_builds == 0
		and patched_counts.dense_cache_states == 2
		and patched_counts.dense_cache_retained_bytes == 2 * (48 * 8 + 2 * 16),
		"translation retains exactly two selection-independent base arrays and brush-range payloads")
	await get_tree().process_frame
	RenderingServer.force_draw()
	checks.check(graph.render_counters().dense_buffer_uploads <= 1,
		"translation resubmits at most the visible retained graph buffer containing changed edges")
	graph.reset_render_counters()
	for repeat in 3:
		scratch.restore(cache_a)
		checks.check(graph.restore_dense_edge_cache() and graph.dense_base_edges == cache_a_edges
			and graph.dense_edge_ranges == cache_a_ranges, "dense cache restores exact undo state %d" % repeat)
		scratch.restore(cache_b)
		checks.check(graph.restore_dense_edge_cache() and graph.dense_base_edges == cache_b_edges,
			"dense cache restores exact redo state %d" % repeat)
	var history_counts: Dictionary = graph.render_counters()
	checks.check(history_counts.static_edge_restores == 6 and history_counts.static_edge_builds == 0
		and history_counts.dense_cache_states == 2,
		"repeated dense undo/redo restores two-state history without rebuilding static edges")
	scratch.hidden[selected] = true
	graph.reset_render_counters()
	checks.check(not graph.restore_dense_edge_cache(), "visibility mismatch cannot restore a stale dense edge state")
	graph.rebuild_dense_edge_cache()
	checks.check(graph.render_counters().static_edge_builds == 1, "visibility mismatch rebuilds dense static edges")
	scratch.hidden.clear()
	graph.rebuild_dense_edge_cache()
	graph.orientation = 1
	graph.reset_render_counters()
	checks.check(not graph.restore_dense_edge_cache(), "orientation mismatch cannot restore an absent dense edge state")
	graph.rebuild_dense_edge_cache()
	checks.check(graph.render_counters().static_edge_builds == 1, "orientation mismatch rebuilds dense static edges")
	scratch.document.create_cuboid(Vector3(80, -16, -16), Vector3(112, 16, 16), "content/material")
	graph.reset_render_counters()
	checks.check(not graph.restore_dense_edge_cache(), "full content generation mismatch cannot restore a stale dense edge state")
	graph.rebuild_dense_edge_cache()
	checks.check(graph.render_counters().static_edge_builds == 1 and graph.render_counters().dense_cache_states == 2,
		"full content mismatch rebuilds while dense history remains bounded")
	graph.orientation = 2
	graph.rebuild_dense_edge_cache()
	scratch.select(PackedInt64Array([selected]))
	graph.queue_view_redraw()
	await get_tree().process_frame
	RenderingServer.force_draw()
	var static_before: Dictionary = graph.static_edge_signature()
	var brush_before: Vector3 = scratch.brush(selected).aabb_min
	var camera_movement := Vector3(16, 0, 0)
	graph.reset_render_counters()
	ui.camera_view.camera_gesture = "move"
	ui.camera_view.camera_delta = camera_movement
	ui.camera_view.finish_camera_left()
	scratch.select(PackedInt64Array())
	await get_tree().process_frame
	RenderingServer.force_draw()
	var camera_move_counts: Dictionary = graph.render_counters()
	var static_after: Dictionary = graph.static_edge_signature()
	checks.check(scratch.selected.is_empty() and scratch.brush(selected).aabb_min == brush_before + camera_movement
		and camera_move_counts.static_redraws > 0 and camera_move_counts.static_edge_builds > 0
		and static_after.generation == scratch.document.get_state_generation()
		and static_after.points == static_before.points
		and Vector2(static_after.sum).is_equal_approx(Vector2(static_before.sum) + graph.map_edge_point(camera_movement) * 24.0),
		"camera whole-brush move rebuilds current static gray geometry before deselection exposes it")
	scratch.select(PackedInt64Array([selected]))
	graph.gesture = "move"
	graph.delta = Vector3(16, 0, 0)
	ui.camera_view.reset_render_counters()
	ui.camera_view.preview_grid_move(graph.delta)
	await get_tree().process_frame
	checks.check(ui.camera_view.grid_move_preview.visible and ui.camera_view.grid_move_preview.get_child_count() == 4,
		"grid move coalesces the exact candidate into two hull/edge passes on the next frame")
	checks.check(ui.camera_view.render_counters().candidate_mesh_uploads == 2,
		"candidate hidden and visible passes share one hull and one edge mesh upload")
	var hidden_candidate: BaseMaterial3D = ui.camera_view.grid_move_preview.get_node("HiddenEdges").material_override
	var visible_candidate: BaseMaterial3D = ui.camera_view.grid_move_preview.get_node("VisibleEdges").material_override
	checks.check(hidden_candidate.no_depth_test and not visible_candidate.no_depth_test and
		hidden_candidate.depth_draw_mode == BaseMaterial3D.DEPTH_DRAW_DISABLED and visible_candidate.depth_draw_mode == BaseMaterial3D.DEPTH_DRAW_DISABLED and
		hidden_candidate.albedo_color.a < visible_candidate.albedo_color.a,
		"candidate hidden pass ignores depth while both orange passes disable depth writes")
	var exact_candidate: Dictionary = scratch.document.preview_translate_brushes(scratch.selected, graph.delta)
	var expected_first: Vector3 = ui.camera_view.transform_map(exact_candidate.value[0].vertices[0])
	var candidate_vertices: PackedVector3Array = ui.camera_view.grid_move_preview.get_node("VisibleHulls").mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	checks.check(candidate_vertices.has(expected_first) and ui.camera_view.grid_move_preview.position == Vector3.ZERO,
		"camera preview renders native candidate coordinates rather than offsetting source geometry")
	var duplicate_camera = ui.create_pane("Camera")
	ui.view_parking.add_child(duplicate_camera)
	await get_tree().process_frame
	ui.cameras.append(duplicate_camera)
	ui.broadcast_mutation_preview(exact_candidate, graph)
	checks.check(ui.camera_view.grid_move_preview.get_child_count() == 4 and duplicate_camera.grid_move_preview.get_child_count() == 4,
		"one exact graph candidate broadcasts to duplicate camera panes")
	graph.cancel()
	checks.check(not ui.camera_view.grid_move_preview.visible and not duplicate_camera.grid_move_preview.visible,
		"initiating graph cancellation clears exact previews in every camera")
	ui.cameras.erase(duplicate_camera)
	duplicate_camera.queue_free()
	graph.gesture = "move"
	graph.delta = Vector3(16, 0, 0)
	graph.queue_selection_redraw()
	await get_tree().process_frame
	RenderingServer.force_draw()
	checks.check(graph.gesture == "move" and graph.delta == Vector3(16, 0, 0), "move preview redraws with batched ordinary edges")
	graph.gesture = "rotate"
	graph.rotation_pivot = graph.selection_center()
	graph.rotation_angle = deg_to_rad(45)
	graph.queue_selection_redraw()
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
	var moved_brush: Dictionary = scratch.brush(selected)
	var moved_center: Vector3 = ui.camera_view.transform_map((moved_brush.aabb_min + moved_brush.aabb_max) * 0.5)
	ui.camera_view.camera.position = moved_center + Vector3(0, 0, 8)
	ui.camera_view.camera.look_at(moved_center)
	ui.set_tool("Vertex")
	var vertex_screen: Vector2 = ui.camera_view.camera.unproject_position(ui.camera_view.transform_map(moved_brush.vertices[0]))
	var camera_component: Dictionary = ui.camera_view.camera_handle_hit(vertex_screen, "Vertex")
	checks.check(camera_component.get("brush_id", 0) == selected and camera_component.get("kind", "") == "vertex",
		"camera handle hit-testing returns a topology-guarded selected-brush vertex")
	scratch.select_component(camera_component, false)
	var component_movement: Vector3 = (moved_brush.vertices[camera_component.index] - (moved_brush.aabb_min + moved_brush.aabb_max) * 0.5).sign() * 16.0
	var component_candidate: Dictionary = scratch.document.preview_translate_components(scratch.components, component_movement)
	var before_component_preview: String = scratch.document.export_text().value
	ui.broadcast_mutation_preview(component_candidate, ui.camera_view)
	checks.check(component_candidate.ok and ui.camera_view.grid_move_preview.get_child_count() == 4 and scratch.document.export_text().value == before_component_preview,
		"camera component preview consumes exact rebuilt hulls without mutating the document")
	ui.camera_view.camera_gesture = "component"
	ui.camera_view.cancel_gesture()
	checks.check(not ui.camera_view.grid_move_preview.visible and scratch.document.export_text().value == before_component_preview,
		"camera component cancellation clears preview without a transaction")
	var component_history_version: int = history.get_version()
	ui.camera_view.camera_component = camera_component
	ui.camera_view.camera_delta = component_movement
	ui.camera_view.camera_gesture = "component"
	ui.camera_view.finish_camera_left()
	checks.check(scratch.document.export_text().value != before_component_preview and history.get_version() > component_history_version,
		"camera component release commits exactly one editor transaction")
	checks.check(history.undo() and scratch.document.export_text().value == before_component_preview,
		"camera component transaction has exact undo")
	var offscreen_candidate: Dictionary = scratch.document.preview_translate_brushes(scratch.selected, Vector3(0, 32000, 0))
	if offscreen_candidate.ok:
		ui.camera_view.set_candidate_preview(offscreen_candidate.value)
	checks.check(offscreen_candidate.ok and ui.camera_view.candidate_offscreen and ui.camera_view.candidate_indicator.visible,
		"camera exposes deterministic offscreen candidate state and edge direction indicator")
	ui.camera_view.clear_candidate_preview()
	ui.set_tool("Cut")
	ui.set_cut_points([Vector3.ZERO, Vector3(0, 32, 0)], 2)
	checks.check(ui.cut_plane() == [Vector3.ZERO, Vector3(0, 32, 0), Vector3(0, 0, -32)],
		"two-point grid clip persists its synthesized plane")
	ui.add_cut_point(Vector3(16, 16, 0), 2)
	checks.check(ui.cut_points == [Vector3(16, 16, 0)] and ui.cut_plane().is_empty(),
		"third grid click starts a new two-point clip line")
	ui.set_cut_points([Vector3.ZERO, Vector3(32, 0, 0)], -1, Vector3(0.1, 0.9, 0.2))
	checks.check(ui.cut_plane() == [Vector3.ZERO, Vector3(32, 0, 0), Vector3(0, -32, 0)],
		"two-point camera clip persists a cardinalized view direction")
	graph.clip_flip = true
	checks.check(ui.graphs.all(func(item): return item.clip_points == ui.cut_points and item.clip_flip) and ui.camera_view.overlays.has_node("CutOverlay"),
		"grid and camera panes share one cut point/flip state")
	ui.active_graph = null
	ui.flip_clip()
	ui.set_tool("Brush")
	checks.check(ui.cut_points.is_empty() and not ui.cut_flip and not ui.camera_view.overlays.has_node("CutOverlay"),
		"no-grid clip routing is safe and leaving Cut clears shared camera state")
	scratch.save_enabled = false
	ui.set_session(original)
	graph.current_dense_edge_key()
	checks.check(graph.render_counters().dense_cache_states == 0 and graph.dense_base_edges.is_empty(),
		"detaching a document releases its dense edge history")
	ui.graph_a.grab_focus()

func vertex_hull_drag_journey() -> void:
	var original = ui.session
	var scratch = load("res://addons/tbloader/src/editor/map_session.gd").new()
	ui.set_session(scratch)
	var graph = ui.graph_a
	var origin := Vector3(4096, -2048, 1024)
	graph.orientation = 2
	graph.origin = origin + Vector3.ONE * 32
	graph.zoom = 2
	graph.grab_focus()
	scratch.grid = 8
	var id: int = scratch.document.create_cuboid(origin, origin + Vector3.ONE * 64, "baseline/checker").value
	scratch.select(PackedInt64Array([id]))
	ui.set_tool("Vertex")
	click_component(graph, origin + Vector3.ONE * 64)
	if checks.check(scratch.components.size() == 1, "sequential drag selects a projected corner"):
		# Use the actual picked depth; overlapping front/back vertices are valid
		# picks, but every subsequent native position must match in all 3 axes.
		var position: Vector3 = scratch.brush(id).vertices[scratch.components[0].index]
		for movement in [Vector3(16, 8, 0), Vector3(0, 8, 0), Vector3(-8, -16, 0), Vector3(-8, 0, 0), Vector3(-8, -8, 0), Vector3(8, 8, 0)]:
			var before := text()
			var count: int = ui.tokens.size()
			drag(graph, position, position + movement)
			position += movement
			checks.check(text() != before and ui.tokens.size() == count + 1, "sequential vertex drag commits one undo action")
			var b: Dictionary = scratch.brush(id)
			if not checks.check(scratch.components.size() == 1 and scratch.component_valid(scratch.components[0], b), "sequential drag rebinds selected vertex to fresh topology"):
				break
			checks.check(b.vertices[scratch.components[0].index].distance_to(position) < 0.001, "sequential graph drag reaches exact requested 3D corner")
			solid_volume(b)
			var after := text()
			key(KEY_Z, true)
			checks.check(text() == before and scratch.components.size() == 1, "sequential hull undo restores exact source and selection")
			key(KEY_Z, true, true)
			checks.check(text() == after and scratch.component_valid(scratch.components[0], scratch.brush(id)), "sequential hull redo restores exact result and live selection")
		checks.check(scratch.brush(id).faces.size() == 6 and scratch.brush(id).vertices.size() == 8, "graph corner return merges coplanar faces")
	scratch.save_enabled = false
	ui.set_session(original)
	graph.orientation = 1
	graph.origin = Vector3.ZERO
	graph.zoom = 1
	ui.set_tool("Brush")
	graph.grab_focus()
	var unsaved_before_pristine: String = ui.unsaved_status()
	var pristine_session = load("res://addons/tbloader/src/editor/map_session.gd").new()
	ui.set_session(pristine_session)
	checks.check(pristine_session.document.is_dirty() and not pristine_session.has_unsaved_changes()
		and ui.plugin._get_unsaved_status("") == unsaved_before_pristine,
		"pristine empty untitled session is not editor-unsaved despite lacking a native baseline")
	pristine_session.grid = 117
	ui.store_recovery()
	var pristine_manifest: Dictionary = EditorInterface.get_base_control().get_meta(ui.RECOVERY_META)
	checks.check(not pristine_manifest.tabs.any(func(record): return record.get("grid", -1) == 117),
		"pristine empty untitled session is omitted from plugin-close recovery")
	var pristine_tab = ui.document_tabs.current_tab
	ui.close_document_tab(pristine_tab)
	checks.check(not ui.sessions.has(pristine_session) and not ui.dirty_dialog.visible,
		"closing a pristine empty untitled tab bypasses save and discard confirmation")
	var modified_empty = load("res://addons/tbloader/src/editor/map_session.gd").new()
	ui.set_session(modified_empty)
	modified_empty.grid = 119
	var temporary_brush: int = modified_empty.document.create_cuboid(Vector3.ZERO, Vector3.ONE * 16, "common/caulk").value
	modified_empty.document.delete_brushes(PackedInt64Array([temporary_brush]))
	checks.check(modified_empty.document.get_draw_data().is_empty() and modified_empty.has_unsaved_changes()
		and ui.plugin._get_unsaved_status("").contains("Untitled"),
		"modified map remains unsaved after returning to empty untitled content")
	ui.store_recovery()
	var recovery_manifest: Dictionary = EditorInterface.get_base_control().get_meta(ui.RECOVERY_META)
	checks.check(recovery_manifest.tabs.any(func(record): return record.get("grid", -1) == 119),
		"modified empty untitled session remains eligible for plugin-close recovery")
	var modified_empty_tab = ui.document_tabs.current_tab
	ui.close_document_tab(modified_empty_tab)
	checks.check(ui.dirty_dialog.visible and ui.sessions.has(modified_empty),
		"closing a modified empty untitled tab still requests confirmation")
	ui.dirty_dialog.custom_action.emit("discard")
	checks.check(not ui.sessions.has(modified_empty), "discard closes the modified empty session")
	var named_dirty = load("res://addons/tbloader/src/editor/map_session.gd").new()
	ui.set_session(named_dirty)
	checks.check(named_dirty.document.save_map("user://named-close-regression.map").ok, "named close fixture establishes a clean path")
	named_dirty.document.create_cuboid(Vector3.ZERO, Vector3.ONE * 16, "common/caulk")
	var named_dirty_tab = ui.document_tabs.current_tab
	ui.close_document_tab(named_dirty_tab)
	checks.check(named_dirty.document.is_dirty() and named_dirty.has_unsaved_changes() and ui.dirty_dialog.visible,
		"closing a named dirty tab still requests confirmation")
	ui.dirty_dialog.custom_action.emit("discard")
	var close_session = load("res://addons/tbloader/src/editor/map_session.gd").new()
	checks.check(close_session.document.import_text(original.document.export_text().value).ok, "close-tab fixture imports canonical content")
	ui.set_session(close_session)
	var close_tab = ui.document_tabs.current_tab
	checks.check(ui.document_tabs.get_tab_button_icon(close_tab) != null, "document tabs expose close buttons")
	ui.close_document_tab(close_tab)
	checks.check(ui.dirty_dialog.visible and ui.sessions.has(close_session), "closing a dirty document requests confirmation")
	ui.dirty_dialog.custom_action.emit("discard")
	checks.check(not ui.sessions.has(close_session) and ui.session != close_session, "discard closes the document and activates a neighbor")
	ui.set_session(original)

func shallow_prism_drag_journey() -> void:
	var original = ui.session
	var scratch = load("res://addons/tbloader/src/editor/map_session.gd").new()
	ui.set_session(scratch)
	var graph = ui.graph_a
	graph.orientation = 2
	graph.origin = Vector3(4128, -2016, 1056)
	graph.zoom = 4
	graph.grab_focus()
	checks.check(scratch.grid == 16, "prism regression uses the editor default grid")
	var loaded: Dictionary = scratch.document.load_map("res://fixtures/vertex_prism.map")
	if checks.check(loaded.ok, "load imported shallow-plane prism in editor"):
		var b: Dictionary = scratch.document.get_draw_data()[0]
		var id: int = b.id
		scratch.select(PackedInt64Array([id]))
		ui.set_tool("Edge")
		var p := Vector3(4144, -2043.7127685546875, 1024)
		var q := Vector3(4155.712890625, -2032, 1024)
		var reference := (p + q) * 0.5
		var destination := reference + Vector3(16, 16, 0)
		var movement := destination.snapped(Vector3.ONE * scratch.grid) - reference
		var before := text()
		var count: int = ui.tokens.size()
		mouse(graph, graph.project(reference), true)
		checks.check(graph.gesture == "component" and graph.drag_component.kind == "edge" and scratch.components.size() == 1, "prism drag enters edge deformation, not brush translation")
		checks.check(graph.component_position(graph.drag_component, b).distance_to(reference) < 0.001, "prism regression picks the intended depth and edge")
		var expected: PackedVector3Array = b.vertices.duplicate()
		expected[expected.find(p)] += movement
		expected[expected.find(q)] += movement
		motion(graph, graph.project(destination), graph.project(destination) - graph.project(reference))
		checks.check(text() == before and graph.delta == movement, "default-grid edge preview snaps its midpoint without committing")
		mouse(graph, graph.project(destination), false)
		checks.check(text() != before and ui.tokens.size() == count + 1, "shallow-plane edge release commits exactly one action")
		b = scratch.brush(id)
		# The first moved endpoint is now inside the hull. Its edge genuinely
		# disappears, so the editor must discard that handle rather than retarget it.
		checks.check(not b.vertices.has(p + movement) and b.vertices.has(q + movement) and scratch.components.is_empty(), "edge disappearance clears selection and retains its extreme endpoint")
		for vertex in b.vertices:
			checks.check(Array(expected).any(func(v): return v.distance_to(vertex) < 0.001), "edge deformation retains only requested extreme points")
		for point in expected:
			for face in b.faces:
				checks.check(face.normal.dot(point - face.center) <= 0.001, "edited prism contains every requested point")
		solid_volume(b)
		var after := text()
		key(KEY_Z, true)
		checks.check(text() == before and scratch.components.size() == 1, "shallow-plane drag undo restores exact source and selection")
		key(KEY_Z, true, true)
		checks.check(text() == after and scratch.components.is_empty(), "shallow-plane drag redo restores exact solid and discarded edge selection")
		key(KEY_Z, true)
		ui.set_tool("Vertex")
		click_component(graph, q)
		# Explicitly cycle to the coincident far-side corner, then grab it normally.
		mouse(graph, graph.project(q), true, MOUSE_BUTTON_LEFT, false, false, true)
		mouse(graph, graph.project(q), false)
		var selected: Dictionary = scratch.components[0].duplicate()
		checks.check(graph.pick_component(graph.project(q), "Vertex") == selected, "ordinary grab preserves selected coincident vertex; only Alt cycles depth")
	scratch.save_enabled = false
	ui.set_session(original)
	graph.orientation = 1
	graph.origin = Vector3.ZERO
	graph.zoom = 1
	ui.set_tool("Brush")
	graph.grab_focus()

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
	ui.set_tool("Brush")
	ui.camera_view.apply_pick(id, 0, 0, false, false, true)
	checks.check(scratch.components.size() == 1 and scratch.components[0].kind == "face", "camera Ctrl-click quick-selects one face outside Face mode")
	ui.camera_view.ctrl_start_hit = {"brush_id": id, "face_index": 1}
	ui.camera_view.ctrl_gesture = "paint_pending"
	ui.camera_view.finish_ctrl_gesture()
	checks.check(scratch.components.size() == 2, "separate camera Ctrl-click adds to the existing face selection")
	ui.camera_view.ctrl_start_hit = {"brush_id": id, "face_index": 0}
	ui.camera_view.ctrl_gesture = "paint_pending"
	ui.camera_view.finish_ctrl_gesture()
	checks.check(scratch.components.size() == 1 and scratch.components[0].index == 1,
		"separate camera Ctrl-click toggles a selected face without starting a new selection")
	key(KEY_ESCAPE)
	checks.check(scratch.selected.is_empty() and scratch.points.is_empty() and scratch.components.is_empty(),
		"Escape clears the complete spatial and component selection in one action")
	ui.camera_view.apply_pick(id, 0, 0, false, false, true)
	checks.check(ui.camera_view.overlays.has_node("SelectedBrushFill") and ui.camera_view.overlays.has_node("SelectedFaceEdges")
		and ui.camera_view.overlays.get_node("SelectedFaceEdges").material_override.albedo_color.b > 0.9
		and ui.camera_view.overlays.get_node("SelectedFaceEdges").material_override.albedo_color.a == 1.0,
		"camera renders translucent orange brushes and opaque blue selected-face edges")
	ui.texture_field.text = "common/caulk"
	ui.assign_texture()
	checks.check(scratch.brush(id).faces[0].texture == "common/caulk", "camera quick-face selection scopes material assignment")
	checks.check(ui.browser.select_path("res://textures/baseline/checker.png"), "material browser click applies to camera-selected face")
	checks.check(scratch.brush(id).faces.all(func(face): return face.texture == "baseline/checker") and scratch.components.size() == 1, "material browser click changes only the camera-selected face")
	ui.set_tool("Face")
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
