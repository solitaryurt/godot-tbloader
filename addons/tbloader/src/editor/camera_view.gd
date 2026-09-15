@tool
extends Control

const OrientationGizmo = preload("res://addons/tbloader/src/editor/orientation_gizmo.gd")

signal camera_moved(map_position: Vector3, map_direction: Vector3)

var host: Control
var viewport: SubViewport
var camera: Camera3D
var geometry: Node3D
var map_geometry: Node3D
var built_geometry: Node3D
var overlays: Node3D
var core_overlays: Node3D
var ground_grid: Node3D
var grid_move_preview: Node3D
var grid_move_preview_key = ""
var grid_move_preview_pending := false
var grid_move_preview_delta := Vector3.ZERO
var grid_move_preview_generation := 0
var candidate_offscreen := false
var candidate_indicator: Label
var preview_lights: Node3D
var preview_world_environment: WorldEnvironment
var environment_key: Array = []
var environment_resources: Array[Resource] = []
var environment_dirty := true
var inferred_scene_key: Array = []
var inferred_scene: WeakRef = weakref(null)
var inferred_loader: WeakRef = weakref(null)
var scene_nodes_key: Array = []
var scene_nodes_dirty := true
var scene_directional_light_refs: Array = []
var scene_world_environment_refs: Array = []
var built_appearance := false
var built_preview_key := ""
var built_preview_context_key := ""
var built_preview_attempt_key := ""
var built_preview_valid := false
var built_appearance_button: Button
var preview_sunlight_enabled := true
var preview_environment_enabled := true
var preview_sunlight_button: Button
var preview_environment_button: Button
var camera_grid_visible := true
var camera_grid_button: Button
var flying = false
var rmb_down := false
var rmb_was_flying := false
var rmb_drag_distance := 0.0
var rmb_dragging := false
var selection_painting = false
var ctrl_gesture := ""
var ctrl_press_position := Vector2.ZERO
var ctrl_start_hit: Dictionary = {}
var ctrl_paint_select := true
var ctrl_visited: Dictionary = {}
var ctrl_resize_components: Array = []
var ctrl_resize_origin := Vector3.ZERO
var ctrl_resize_normal := Vector3.ZERO
var ctrl_resize_delta := Vector3.ZERO
var held: Dictionary = {}
var fly_speed := 8.0
var camera_fov := 75.0
var dolly_step := 1.0
var pitch = -0.4
var yaw = 0.65
var triangle_count = 0
var hint: Label
var crosshair: Control
var rendered_key = []
var rendered_material_key = ""
var core_overlay_key: Array = []
var cut_overlay_context_key: Array = []
var geometry_chunks: Dictionary = {}
var chunk_reuse_count := 0
var chunk_mesh_upload_count := 0
var chunk_renderer_write_count := 0
var ground_grid_rebuild_count := 0
var candidate_mesh_upload_count := 0
var candidate_hull_mesh: ArrayMesh
var candidate_edge_mesh: ArrayMesh
var lighting_key: Array = []
var lighting_initialized = false
var lighting_sync_delay = 0.0
var orientation_gizmo: Control
var orbit_target = Vector3.ZERO
var orbit_distance = 10.0
var marker_transform := Transform3D()
var marker_scale = 0.0
var camera_gesture := ""
var camera_press_position := Vector2.ZERO
var camera_drag_anchor := Vector3.ZERO
var camera_delta := Vector3.ZERO
var camera_hit: Dictionary = {}
var camera_component: Dictionary = {}
var brush_paint_select := true
var brush_paint_visited: Dictionary = {}
var camera_rotation_axis := 2
var camera_rotation_pivot := Vector3.ZERO
var camera_rotation_start := 0.0
var camera_rotation_angle := 0.0
var surface_grid_visible := false
var surface_grid_key: Array = []
var ground_grid_key: Array = []
var ground_grid_extent_document_id := 0
var ground_grid_extent_generation := -1
var ground_grid_extent_spacing := 0.0
var ground_grid_extent_scale := 0.0
var ground_grid_extent_value := 0.0
var previous_ground_grid_extent_document_id := 0
var previous_ground_grid_extent_generation := -1
var previous_ground_grid_extent_spacing := 0.0
var previous_ground_grid_extent_scale := 0.0
var previous_ground_grid_extent_value := 0.0
const CHUNK_TRIANGLES = 2048
const CHUNK_SIZE = 64.0
const GROUND_GRID_MIN_EXTENT = 2048.0
const GROUND_GRID_MAJOR_INTERVAL = 8
const GROUND_GRID_MAX_VERTICES = 8192
const GROUND_GRID_MAX_VIEW_EXTENT = 5000.0
const DRAG_THRESHOLD = 4.0
const MIN_FLY_SPEED = 1.0
const MAX_FLY_SPEED = 64.0
const FLY_SPEED_FACTOR = 1.25
const FAST_FLY_FACTOR = 3.75
const MIN_CAMERA_FOV = 20.0
const MAX_CAMERA_FOV = 120.0
const CAMERA_FOV_STEP = 5.0
const MIN_DOLLY_STEP = 0.125
const MAX_DOLLY_STEP = 128.0
const DOLLY_STEP_FACTOR = 1.25
const SKY_ENVIRONMENT_PROPERTIES = [
	"background_mode",
	"sky",
	"sky_rotation",
	"sky_custom_fov",
	"background_energy_multiplier",
	"background_intensity",
	"ambient_light_source",
	"ambient_light_color",
	"ambient_light_energy",
	"ambient_light_sky_contribution",
	"reflected_light_source",
]

func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	custom_minimum_size = Vector2(240, 180)
	var container = SubViewportContainer.new()
	container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	container.stretch = true
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(container)
	viewport = SubViewport.new()
	viewport.own_world_3d = true
	viewport.handle_input_locally = false
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	container.add_child(viewport)
	_sync_suspension()
	geometry = Node3D.new()
	viewport.add_child(geometry)
	map_geometry = Node3D.new()
	map_geometry.name = "AuthoringGeometry"
	geometry.add_child(map_geometry)
	built_geometry = Node3D.new()
	built_geometry.name = "BuiltGeometry"
	built_geometry.hide()
	geometry.add_child(built_geometry)
	overlays = Node3D.new()
	geometry.add_child(overlays)
	core_overlays = overlays
	ground_grid = Node3D.new()
	ground_grid.name = "GroundGrid"
	viewport.add_child(ground_grid)
	grid_move_preview = Node3D.new()
	grid_move_preview.name = "ExactCandidatePreview"
	viewport.add_child(grid_move_preview)
	camera = Camera3D.new()
	viewport.add_child(camera)
	camera.position = Vector3(8, 7, 12)
	camera.rotation = Vector3(pitch, yaw, 0)
	camera.far = 10000
	camera.fov = camera_fov
	camera.current = true
	orbit_target = camera.position - camera.global_basis.z * orbit_distance
	preview_world_environment = WorldEnvironment.new()
	preview_world_environment.name = "PreviewWorldEnvironment"
	preview_world_environment.environment = studio_environment()
	viewport.add_child(preview_world_environment)
	preview_lights = Node3D.new()
	viewport.add_child(preview_lights)
	get_tree().node_added.connect(scene_tree_node_changed)
	get_tree().node_removed.connect(scene_tree_node_changed)
	sync_scene_environment(true)
	sync_scene_lighting(true)
	hint = Label.new()
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.position = Vector2(124, 3)
	add_child(hint)
	update_hint()
	var preview_controls: HBoxContainer = host.toolbar_group(self) if is_instance_valid(host) else HBoxContainer.new()
	var preview_panel := preview_controls.get_parent() as PanelContainer
	if preview_panel == null:
		preview_panel = PanelContainer.new()
		preview_panel.add_child(preview_controls)
		add_child(preview_panel)
	preview_panel.name = "CameraPreviewControls"
	preview_panel.position = Vector2(31, 1)
	preview_controls.add_theme_constant_override("separation", 0)
	preview_sunlight_button = Button.new()
	preview_sunlight_button.name = "PreviewSunlight"
	preview_sunlight_button.custom_minimum_size = Vector2(28, 28)
	preview_sunlight_button.icon = host.editor_icon("DirectionalLight3D") if is_instance_valid(host) else null
	preview_sunlight_button.toggle_mode = true
	preview_sunlight_button.button_pressed = true
	preview_sunlight_button.tooltip_text = "Preview sunlight"
	preview_sunlight_button.accessibility_name = "Preview sunlight"
	preview_sunlight_button.theme_type_variation = "FlatButton"
	preview_sunlight_button.toggled.connect(set_preview_sunlight)
	preview_controls.add_child(preview_sunlight_button)
	add_toggle_slash(preview_sunlight_button)
	preview_environment_button = Button.new()
	preview_environment_button.name = "PreviewWorldEnvironment"
	preview_environment_button.custom_minimum_size = Vector2(28, 28)
	preview_environment_button.icon = host.editor_icon("WorldEnvironment") if is_instance_valid(host) else null
	preview_environment_button.toggle_mode = true
	preview_environment_button.button_pressed = true
	preview_environment_button.tooltip_text = "Preview WorldEnvironment"
	preview_environment_button.accessibility_name = "Preview WorldEnvironment"
	preview_environment_button.theme_type_variation = "FlatButton"
	preview_environment_button.toggled.connect(set_preview_environment)
	preview_controls.add_child(preview_environment_button)
	add_toggle_slash(preview_environment_button)
	camera_grid_button = Button.new()
	camera_grid_button.name = "CameraGrid"
	camera_grid_button.custom_minimum_size = Vector2(28, 28)
	camera_grid_button.icon = host.custom_icon("grid_xy") if is_instance_valid(host) else null
	camera_grid_button.toggle_mode = true
	camera_grid_button.button_pressed = true
	camera_grid_button.tooltip_text = "Show camera grid"
	camera_grid_button.accessibility_name = "Show camera grid"
	camera_grid_button.theme_type_variation = "FlatButton"
	camera_grid_button.toggled.connect(set_camera_grid_visible)
	preview_controls.add_child(camera_grid_button)
	add_toggle_slash(camera_grid_button)
	orientation_gizmo = OrientationGizmo.new()
	orientation_gizmo.name = "CameraOrientation"
	orientation_gizmo.allow_orbit = true
	orientation_gizmo.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	orientation_gizmo.position = Vector2(-68, 40)
	orientation_gizmo.axis_selected.connect(snap_to_axis)
	orientation_gizmo.orbit_dragged.connect(orbit_from_gizmo)
	add_child(orientation_gizmo)
	update_orientation_gizmo()
	var crosshair_center = CenterContainer.new()
	crosshair_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	crosshair_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(crosshair_center)
	crosshair = Control.new()
	crosshair.custom_minimum_size = Vector2(22, 22)
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	crosshair.hide()
	crosshair_center.add_child(crosshair)
	candidate_indicator = Label.new()
	candidate_indicator.name = "CandidateOffscreen"
	candidate_indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	candidate_indicator.modulate = Color(1.0, 0.76, 0.48, 0.85)
	candidate_indicator.hide()
	add_child(candidate_indicator)
	var crosshair_color = Color(1.0, 0.88, 0.63, 0.9)
	for rect in [Rect2(0, 10, 8, 2), Rect2(14, 10, 8, 2), Rect2(10, 0, 2, 8), Rect2(10, 14, 2, 8)]:
		var segment = ColorRect.new()
		segment.position = rect.position
		segment.size = rect.size
		segment.color = crosshair_color
		segment.mouse_filter = Control.MOUSE_FILTER_IGNORE
		crosshair.add_child(segment)
	var frame_button = Button.new()
	frame_button.name = "FrameSelection"
	frame_button.custom_minimum_size = Vector2(28, 28)
	frame_button.size = Vector2(28, 28)
	frame_button.tooltip_text = "Frame selection"
	frame_button.accessibility_name = "Frame selection"
	frame_button.theme_type_variation = "FlatButton"
	var frame_icon: Texture2D = host.custom_icon("frame_selection") if is_instance_valid(host) else null
	frame_button.icon = frame_icon
	frame_button.text = ""
	frame_button.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	frame_button.position = Vector2(-32, 4)
	frame_button.pressed.connect(frame_selection)
	add_child(frame_button)
	built_appearance_button = Button.new()
	built_appearance_button.name = "BuiltAppearance"
	built_appearance_button.text = "Built appearance"
	built_appearance_button.toggle_mode = true
	built_appearance_button.tooltip_text = "Preview PBR materials and visual geometry using TBLoader build rules"
	built_appearance_button.accessibility_name = "Built appearance"
	built_appearance_button.theme_type_variation = "FlatButton"
	built_appearance_button.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	built_appearance_button.position = Vector2(-162, 4)
	built_appearance_button.size = Vector2(126, 28)
	built_appearance_button.toggled.connect(set_built_appearance)
	add_child(built_appearance_button)
	focus_exited.connect(cancel_interaction)

func _sync_suspension(force_suspended := false) -> void:
	var active := not force_suspended and is_inside_tree() and is_visible_in_tree()
	set_process(active)
	if viewport != null:
		viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE if active else SubViewport.UPDATE_DISABLED
	if not active:
		cancel_interaction()

func cancel_interaction() -> void:
	cancel_gesture()
	stop_fly()

func cancel_gesture() -> void:
	if (camera_gesture != "" or ctrl_gesture == "resize") and is_instance_valid(host):
		host.clear_mutation_preview(self)
	camera_gesture = ""
	camera_delta = Vector3.ZERO
	camera_rotation_angle = 0.0
	camera_hit.clear()
	camera_component.clear()
	brush_paint_visited.clear()
	ctrl_gesture = ""
	ctrl_start_hit.clear()
	ctrl_visited.clear()
	ctrl_resize_components.clear()
	ctrl_resize_origin = Vector3.ZERO
	ctrl_resize_normal = Vector3.ZERO
	ctrl_resize_delta = Vector3.ZERO

func get_camera_state() -> Dictionary:
	return {
		"camera_transform": camera.transform if camera != null else Transform3D(),
		"camera_target": orbit_target,
		"camera_distance": orbit_distance,
		"fly_speed": fly_speed,
		"camera_fov": camera_fov,
		"dolly_step": dolly_step,
		"preview_sunlight": preview_sunlight_enabled,
		"preview_environment": preview_environment_enabled,
		"camera_grid_visible": camera_grid_visible,
	}

func apply_camera_state(state: Dictionary) -> void:
	fly_speed = clampf(float(state.get("fly_speed", fly_speed)), MIN_FLY_SPEED, MAX_FLY_SPEED)
	camera_fov = clampf(float(state.get("camera_fov", camera_fov)), MIN_CAMERA_FOV, MAX_CAMERA_FOV)
	dolly_step = clampf(float(state.get("dolly_step", dolly_step)), MIN_DOLLY_STEP, MAX_DOLLY_STEP)
	orbit_target = state.get("camera_target", orbit_target)
	orbit_distance = maxf(float(state.get("camera_distance", orbit_distance)), 0.01)
	if camera != null:
		camera.transform = state.get("camera_transform", camera.transform)
		camera.fov = camera_fov
		pitch = camera.rotation.x
		yaw = camera.rotation.y
		camera_transform_changed()
	set_preview_sunlight(bool(state.get("preview_sunlight", preview_sunlight_enabled)))
	set_preview_environment(bool(state.get("preview_environment", preview_environment_enabled)))
	set_camera_grid_visible(bool(state.get("camera_grid_visible", camera_grid_visible)))
	update_hint()

func set_preview_sunlight(enabled: bool) -> void:
	preview_sunlight_enabled = enabled
	if preview_sunlight_button != null and preview_sunlight_button.button_pressed != enabled:
		preview_sunlight_button.set_pressed_no_signal(enabled)
	if preview_lights != null:
		preview_lights.visible = enabled
		if enabled:
			sync_scene_lighting(true)

func set_preview_environment(enabled: bool) -> void:
	preview_environment_enabled = enabled
	if preview_environment_button != null and preview_environment_button.button_pressed != enabled:
		preview_environment_button.set_pressed_no_signal(enabled)
	if preview_world_environment == null:
		return
	if enabled:
		environment_dirty = true
		sync_scene_environment(true)
	else:
		disconnect_environment_resources()
		environment_key.clear()
		environment_dirty = false
		preview_world_environment.environment = null

func set_camera_grid_visible(visible: bool) -> void:
	camera_grid_visible = visible
	if camera_grid_button != null and camera_grid_button.button_pressed != visible:
		camera_grid_button.set_pressed_no_signal(visible)
	if ground_grid != null:
		ground_grid.visible = visible
		if visible and ground_grid_key != ground_grid_signature():
			rebuild_ground_grid()

func add_toggle_slash(button: Button) -> void:
	var slash := Line2D.new()
	slash.name = "DisabledSlash"
	slash.points = PackedVector2Array([Vector2(5, 23), Vector2(23, 5)])
	slash.width = 2.0
	slash.default_color = Color("df5f5f")
	slash.antialiased = true
	slash.visible = not button.button_pressed
	slash.z_index = 1
	button.add_child(slash)
	button.toggled.connect(func(enabled: bool): slash.visible = not enabled)

func update_hint() -> void:
	if hint == null:
		return
	var fps := Engine.get_frames_per_second()
	if flying:
		hint.text = "FLY • %.0f FPS • speed %.1f • FOV %.0f° • WASD / Q E • mouse look • RMB drag pan • RMB click / Esc exit" % [float(fps), float(fly_speed), float(camera_fov)]
	else:
		hint.text = "%.0f FPS • wheel dolly %.3f • Ctrl+wheel step • RMB click fly • RMB drag pan" % [float(fps), float(dolly_step)]

func handle_camera_wheel(event: InputEventMouseButton) -> bool:
	if not event.pressed or event.button_index not in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		return false
	var upward := event.button_index == MOUSE_BUTTON_WHEEL_UP
	var feedback: String
	if flying:
		if event.ctrl_pressed:
			camera_fov = clampf(camera_fov + (-CAMERA_FOV_STEP if upward else CAMERA_FOV_STEP), MIN_CAMERA_FOV, MAX_CAMERA_FOV)
			if camera != null:
				camera.fov = camera_fov
			feedback = "Camera FOV: %.0f°" % camera_fov
		else:
			fly_speed = clampf(fly_speed * (FLY_SPEED_FACTOR if upward else 1.0 / FLY_SPEED_FACTOR), MIN_FLY_SPEED, MAX_FLY_SPEED)
			feedback = "Camera fly speed: %.1f" % fly_speed
	elif event.ctrl_pressed:
		dolly_step = clampf(dolly_step * (DOLLY_STEP_FACTOR if upward else 1.0 / DOLLY_STEP_FACTOR), MIN_DOLLY_STEP, MAX_DOLLY_STEP)
		feedback = "Camera dolly step: %.3f" % dolly_step
	else:
		var movement := -camera.global_basis.z * dolly_step * (1.0 if upward else -1.0)
		camera.global_position += movement
		orbit_target += movement
		orbit_distance = maxf(camera.global_position.distance_to(orbit_target), 0.01)
		camera_transform_changed()
		feedback = "Camera dolly: %.3f" % dolly_step
	update_hint()
	if is_instance_valid(host) and host.has_method("set_status"):
		host.set_status(feedback)
	return true

func transform_map(point: Vector3) -> Vector3:
	return transform_map_scaled(point, map_scale())

func map_scale() -> float:
	var scale_value = 38.0
	var loader = host.session.loader.get_ref()
	if is_instance_valid(loader):
		scale_value = maxf(loader.map_inverse_scale, 0.001)
	return scale_value

func transform_map_scaled(point: Vector3, scale_value: float) -> Vector3:
	return Vector3(point.y, point.z, point.x) / scale_value

func camera_map_position(scale_value := map_scale()) -> Vector3:
	return Vector3(camera.global_position.z, camera.global_position.x, camera.global_position.y) * scale_value

func camera_map_direction() -> Vector3:
	var direction := -camera.global_basis.z
	return Vector3(direction.z, direction.x, direction.y).normalized()

func preview_to_map(point: Vector3, scale_value := map_scale()) -> Vector3:
	return Vector3(point.z, point.x, point.y) * scale_value

func preview_direction_to_map(direction: Vector3) -> Vector3:
	return Vector3(direction.z, direction.x, direction.y).normalized()

func sync_camera_marker(force = false) -> void:
	if camera == null or host == null or host.session == null:
		return
	var scale_value := map_scale()
	if not force and camera.global_transform == marker_transform and is_equal_approx(scale_value, marker_scale):
		return
	marker_transform = camera.global_transform
	marker_scale = scale_value
	camera_moved.emit(camera_map_position(scale_value), camera_map_direction())

func camera_transform_changed() -> void:
	sync_camera_marker()
	update_orientation_gizmo()
	if is_instance_valid(host) and host.tool == "Cut" and host.cut_points.size() == 2:
		rebuild_cut_overlay()

func frame_selection() -> void:
	var bounds: AABB
	var first = true
	for brush in host.session.draw_data():
		if not host.session.brush_visible(brush) or (not host.session.selected.is_empty() and not host.session.selected.has(brush.id)):
			continue
		var box = AABB(transform_map(brush.aabb_min), transform_map(brush.aabb_max - brush.aabb_min))
		bounds = box if first else bounds.merge(box)
		first = false
	if first:
		return
	var center = bounds.get_center()
	orbit_target = center
	orbit_distance = maxf(bounds.size.length() * 1.4, 2)
	camera.position = center + Vector3(1, 0.8, 1.2).normalized() * orbit_distance
	camera.look_at(center)
	pitch = camera.rotation.x
	yaw = camera.rotation.y
	camera_transform_changed()

func map_axis_preview(axis: int) -> Vector3:
	return [Vector3.BACK, Vector3.RIGHT, Vector3.UP][axis]

func update_orientation_gizmo() -> void:
	if orientation_gizmo == null or camera == null:
		return
	var inverse := camera.global_basis.inverse()
	orientation_gizmo.set_view_axes([
		inverse * map_axis_preview(0),
		inverse * map_axis_preview(1),
		inverse * map_axis_preview(2),
	])

func snap_to_axis(axis: int, positive: bool) -> void:
	stop_fly()
	grab_focus()
	var direction := map_axis_preview(axis) * (1.0 if positive else -1.0)
	camera.position = orbit_target + direction * maxf(orbit_distance, 0.01)
	camera.look_at(orbit_target, Vector3.BACK if axis == 2 else Vector3.UP)
	pitch = camera.rotation.x
	yaw = camera.rotation.y
	camera_transform_changed()
	host.set_status("Camera aligned to %s%s" % ["+" if positive else "-", ["X", "Y", "Z"][axis]])

func orbit_from_gizmo(relative: Vector2) -> void:
	stop_fly()
	grab_focus()
	var offset: Vector3 = camera.position - orbit_target
	if offset.length_squared() < 0.0001:
		offset = camera.global_basis.z * orbit_distance
	offset = Basis(Vector3.UP, -relative.x * 0.012) * offset
	var candidate := Basis(camera.global_basis.x.normalized(), -relative.y * 0.012) * offset
	if absf(candidate.normalized().dot(Vector3.UP)) < 0.995:
		offset = candidate
	orbit_distance = offset.length()
	camera.position = orbit_target + offset
	camera.look_at(orbit_target)
	pitch = camera.rotation.x
	yaw = camera.rotation.y
	camera_transform_changed()

func refresh() -> void:
	if geometry == null:
		return
	sync_camera_marker()
	sync_scene_environment()
	sync_scene_lighting()
	var hidden_ids: Array = host.session.hidden.keys()
	hidden_ids.sort()
	var scale_value := map_scale()
	var loader = host.session.loader.get_ref()
	var visual_layer: int = loader.option_visual_layer_mask if is_instance_valid(loader) else 1
	var key: Array = [host.session.document.get_instance_id(), host.session.preview_generation,
		host.session.visibility_generation, hidden_ids, scale_value]
	if not rendered_key is Array or key != rendered_key:
		rendered_key = key
		rebuild_geometry(scale_value)
	var material_key := "%d:%d:%d" % [host.session.document.get_instance_id(), host.material_generation, visual_layer]
	if material_key != rendered_material_key:
		rendered_material_key = material_key
		refresh_chunk_materials(visual_layer)
	refresh_built_appearance()
	refresh_selection()

func render_counters() -> Dictionary:
	return {"chunk_reuses": chunk_reuse_count, "chunk_mesh_uploads": chunk_mesh_upload_count,
		"chunk_renderer_writes": chunk_renderer_write_count,
		"ground_grid_rebuilds": ground_grid_rebuild_count,
		"candidate_mesh_uploads": candidate_mesh_upload_count}

func reset_render_counters() -> void:
	chunk_reuse_count = 0
	chunk_mesh_upload_count = 0
	chunk_renderer_write_count = 0
	ground_grid_rebuild_count = 0
	candidate_mesh_upload_count = 0

func refresh_selection(force := false) -> void:
	if core_overlays == null or not is_instance_valid(host) or host.session == null:
		return
	var scale_value := map_scale()
	var loader = host.session.loader.get_ref()
	var visual_layer: int = loader.option_visual_layer_mask if is_instance_valid(loader) else 1
	var key: Array = [host.session.document.get_instance_id(), host.session.preview_generation,
		host.session.visibility_generation, host.session.selection_generation, host.tool,
		scale_value, visual_layer]
	if force or key != core_overlay_key:
		core_overlay_key = key
		for child in core_overlays.get_children():
			if child.name in ["SelectedSurfaceGrid", "CutOverlay"]:
				continue
			core_overlays.remove_child(child)
			child.queue_free()
		build_overlays(scale_value, visual_layer)
	var cut_key := [host.session.document.get_instance_id(), scale_value, visual_layer]
	if cut_key != cut_overlay_context_key:
		cut_overlay_context_key = cut_key
		rebuild_cut_overlay()
	if camera_grid_visible and ground_grid_key != ground_grid_signature():
		rebuild_ground_grid()
	if surface_grid_visible and surface_grid_key != surface_grid_signature():
		rebuild_surface_grid_overlay()

func candidate_material(color: Color, hidden: bool) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.no_depth_test = hidden
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	return material

func set_built_appearance(enabled: bool) -> void:
	built_appearance = enabled
	refresh_built_appearance()

func visual_loader_signature(loader: Object) -> String:
	var values: Array = []
	for property in loader.get_property_list():
		var property_name: String = property.name
		if not (property_name.begins_with("map_") or property_name.begins_with("lighting_")
				or property_name.begins_with("option_") or property_name.begins_with("entity_")
				or property_name.begins_with("texture_")):
			continue
		var value = loader.get(property_name)
		values.append([property_name, value.get_instance_id() if value is Object and is_instance_valid(value) else value])
	return str(values)

func refresh_built_appearance() -> void:
	if map_geometry == null or built_geometry == null:
		return
	if not built_appearance:
		map_geometry.show()
		built_geometry.hide()
		return
	var loader = host.session.loader.get_ref() if host != null and host.session != null else null
	var context_key := "%d:%d" % [host.session.document.get_instance_id(), loader.get_instance_id() if is_instance_valid(loader) else 0]
	if context_key != built_preview_context_key:
		built_preview_context_key = context_key
		built_preview_key = ""
		built_preview_attempt_key = ""
		built_preview_valid = false
		for child in built_geometry.get_children():
			built_geometry.remove_child(child)
			child.queue_free()
	if not is_instance_valid(loader) or not loader.has_method("build_visual_preview_checked"):
		map_geometry.show()
		built_geometry.hide()
		if is_instance_valid(host):
			host.set_status("Built appearance requires a bound TBLoader")
		return
	var key := "%d:%d:%d:%d:%s" % [host.session.document.get_instance_id(), host.session.preview_generation,
		host.material_generation, loader.get_instance_id(), visual_loader_signature(loader)]
	if key == built_preview_key and built_preview_valid:
		map_geometry.hide()
		built_geometry.show()
		return
	if key == built_preview_attempt_key:
		map_geometry.visible = not built_preview_valid
		built_geometry.visible = built_preview_valid
		return
	built_preview_attempt_key = key
	var result: Dictionary = loader.build_visual_preview_checked(host.session.document, built_geometry)
	if result.get("ok", false):
		built_preview_key = key
		built_preview_valid = true
		map_geometry.hide()
		built_geometry.show()
		return
	map_geometry.visible = not built_preview_valid
	built_geometry.visible = built_preview_valid
	var error: Dictionary = result.get("error", {})
	if error.get("code", "") == "BUSY":
		built_preview_attempt_key = ""
	if is_instance_valid(host):
		host.set_status("%s: %s" % [error.get("code", "PREVIEW_FAILED"), error.get("message", "Built appearance failed")])

func candidate_mesh_instance(mesh: ArrayMesh, material: Material, name_value: String) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = name_value
	instance.mesh = mesh
	instance.material_override = material
	grid_move_preview.add_child(instance)
	return instance

func ensure_candidate_preview() -> void:
	if grid_move_preview.get_child_count() != 0:
		return
	candidate_hull_mesh = ArrayMesh.new()
	candidate_edge_mesh = ArrayMesh.new()
	# The hidden pass ignores depth; the visible pass depth-tests. Neither pass writes depth.
	candidate_mesh_instance(candidate_hull_mesh, candidate_material(Color(1.0, 0.72, 0.38, 0.12), true), "HiddenHulls")
	candidate_mesh_instance(candidate_edge_mesh, candidate_material(Color(1.0, 0.78, 0.48, 0.42), true), "HiddenEdges")
	candidate_mesh_instance(candidate_hull_mesh, candidate_material(Color(1.0, 0.52, 0.12, 0.24), false), "VisibleHulls")
	candidate_mesh_instance(candidate_edge_mesh, candidate_material(Color(1.0, 0.58, 0.14, 0.96), false), "VisibleEdges")

func update_candidate_mesh(names: Array[String], mesh: ArrayMesh, vertices: PackedVector3Array, primitive: int, visual_layer: int) -> void:
	mesh.clear_surfaces()
	for name_value in names:
		var instance := grid_move_preview.get_node(name_value) as MeshInstance3D
		instance.visible = not vertices.is_empty()
		instance.layers = visual_layer
	if vertices.is_empty():
		return
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	mesh.add_surface_from_arrays(primitive, arrays)
	candidate_mesh_upload_count += 1

func set_candidate_preview(candidates: Array) -> void:
	if candidates.is_empty() or grid_move_preview == null:
		clear_candidate_preview()
		return
	ensure_candidate_preview()
	var triangles := PackedVector3Array()
	var edges := PackedVector3Array()
	var points := PackedVector3Array()
	var scale_value := map_scale()
	for brush in candidates:
		for point in brush.get("vertices", PackedVector3Array()):
			points.append(transform_map_scaled(point, scale_value))
		for face in brush.get("faces", []):
			var winding: PackedVector3Array = face.winding
			for i in range(1, winding.size() - 1):
				triangles.append(transform_map_scaled(winding[0], scale_value))
				triangles.append(transform_map_scaled(winding[i], scale_value))
				triangles.append(transform_map_scaled(winding[i + 1], scale_value))
		var brush_edges: PackedVector3Array = brush.get("edges", PackedVector3Array())
		for point in brush_edges:
			edges.append(transform_map_scaled(point, scale_value))
	var loader = host.session.loader.get_ref()
	var visual_layer: int = loader.option_visual_layer_mask if is_instance_valid(loader) else 1
	update_candidate_mesh(["HiddenHulls", "VisibleHulls"], candidate_hull_mesh, triangles, Mesh.PRIMITIVE_TRIANGLES, visual_layer)
	update_candidate_mesh(["HiddenEdges", "VisibleEdges"], candidate_edge_mesh, edges, Mesh.PRIMITIVE_LINES, visual_layer)
	grid_move_preview.visible = true
	candidate_offscreen = not points.is_empty()
	for point in points:
		if camera.is_position_in_frustum(point):
			candidate_offscreen = false
			break
	update_candidate_indicator(points)

func update_candidate_indicator(points: PackedVector3Array) -> void:
	if candidate_indicator == null:
		return
	candidate_indicator.visible = candidate_offscreen
	if not candidate_offscreen or points.is_empty():
		return
	var center := Vector3.ZERO
	for point in points:
		center += point
	center /= points.size()
	var projected := camera.unproject_position(center)
	if camera.is_position_behind(center):
		projected = size - projected
	var edge: Vector2 = projected.clamp(Vector2(12, 42), size - Vector2(32, 18))
	var direction := (projected - size * 0.5).normalized()
	candidate_indicator.text = "<" if absf(direction.x) > absf(direction.y) and direction.x < 0 else (">" if absf(direction.x) > absf(direction.y) else ("^" if direction.y < 0 else "v"))
	candidate_indicator.position = edge

func preview_grid_move(delta: Vector3) -> void:
	grid_move_preview_delta = delta
	if grid_move_preview_pending:
		return
	grid_move_preview_pending = true
	call_deferred("apply_grid_move_preview", grid_move_preview_generation)

func apply_grid_move_preview(generation: int) -> void:
	if generation != grid_move_preview_generation:
		return
	grid_move_preview_pending = false
	if host.session.selected.is_empty():
		clear_candidate_preview()
		return
	var result: Dictionary = host.session.document.preview_translate_brushes(host.session.selected, grid_move_preview_delta)
	if result.get("ok", false):
		set_candidate_preview(result.get("value", []))
	else:
		clear_candidate_preview()

func clear_grid_move_preview() -> void:
	clear_candidate_preview()

func clear_candidate_preview() -> void:
	grid_move_preview_generation += 1
	grid_move_preview_pending = false
	if grid_move_preview != null:
		for child in grid_move_preview.get_children():
			child.hide()
		grid_move_preview.visible = false
		grid_move_preview.position = Vector3.ZERO
	candidate_offscreen = false
	if candidate_indicator != null:
		candidate_indicator.hide()

func add_preview_mesh(vertices: PackedVector3Array, normals: PackedVector3Array, uvs: PackedVector2Array, material: Material) -> MeshInstance3D:
	if vertices.is_empty():
		return null
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var instance = MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	var loader = host.session.loader.get_ref()
	if is_instance_valid(loader):
		instance.layers = loader.option_visual_layer_mask
	map_geometry.add_child(instance)
	return instance

func apply_preview_material(instance: MeshInstance3D, material: Material, category: String) -> void:
	instance.material_override = material
	# ShaderMaterial has no generic alpha parameter; GeometryInstance3D provides the fallback.
	instance.transparency = 1.0 - host.preview_opacity(category) if category != "opaque" and not material is BaseMaterial3D else 0.0

func preview_scene_context() -> Dictionary:
	if host == null or host.session == null:
		return {}
	var root = host.session.scene.get_ref()
	var loader = host.session.loader.get_ref()
	if is_instance_valid(root) and is_instance_valid(loader) and (loader == root or root.is_ancestor_of(loader)):
		return {"root": root, "loader": loader}
	if is_instance_valid(root) and not is_instance_valid(loader):
		return {"root": root, "loader": null}
	root = EditorInterface.get_edited_scene_root()
	var map_path: String = host.session.document.get_path()
	var key: Array = [root.get_instance_id() if is_instance_valid(root) else 0, map_path]
	if key == inferred_scene_key:
		root = inferred_scene.get_ref()
		loader = inferred_loader.get_ref()
		return {"root": root, "loader": loader} if is_instance_valid(root) and is_instance_valid(loader) else {}
	inferred_scene_key = key
	inferred_scene = weakref(null)
	inferred_loader = weakref(null)
	if not is_instance_valid(root) or map_path.is_empty():
		return {}
	var candidates: Array[Node] = []
	if root is TBLoader:
		candidates.append(root)
	for node in root.find_children("*", "", true, false):
		if node is TBLoader:
			candidates.append(node)
	for candidate in candidates:
		if host.same_path(candidate.map_resource, map_path):
			inferred_scene = weakref(root)
			inferred_loader = weakref(candidate)
			return {"root": root, "loader": candidate}
	return {}

func scene_tree_node_changed(_node: Node) -> void:
	if viewport != null and (_node == viewport or viewport.is_ancestor_of(_node)):
		return
	scene_nodes_dirty = true
	inferred_scene_key.clear()

func cached_scene_nodes() -> Dictionary:
	var context := preview_scene_context()
	if context.is_empty():
		scene_nodes_key.clear()
		scene_directional_light_refs.clear()
		scene_world_environment_refs.clear()
		scene_nodes_dirty = false
		return {}
	var root: Node = context.root
	var loader: Node = context.loader
	var key := [root.get_instance_id(), loader.get_instance_id() if is_instance_valid(loader) else 0]
	var lights: Array[DirectionalLight3D] = []
	var environments: Array[WorldEnvironment] = []
	if not scene_nodes_dirty and key == scene_nodes_key:
		for reference in scene_directional_light_refs:
			var light = reference.get_ref()
			if not is_instance_valid(light):
				scene_nodes_dirty = true
				break
			lights.append(light)
		if not scene_nodes_dirty:
			for reference in scene_world_environment_refs:
				var environment = reference.get_ref()
				if not is_instance_valid(environment):
					scene_nodes_dirty = true
					break
				environments.append(environment)
	if scene_nodes_dirty or key != scene_nodes_key:
		lights.clear()
		environments.clear()
		if root is DirectionalLight3D:
			lights.append(root)
		if root is WorldEnvironment:
			environments.append(root)
		for node in root.find_children("*", "", true, false):
			if node is DirectionalLight3D:
				lights.append(node)
			elif node is WorldEnvironment:
				environments.append(node)
		scene_nodes_key = key
		scene_directional_light_refs.assign(lights.map(func(node): return weakref(node)))
		scene_world_environment_refs.assign(environments.map(func(node): return weakref(node)))
		scene_nodes_dirty = false
	return {"root": root, "loader": loader, "lights": lights, "environments": environments}

func scene_directional_lights() -> Array[DirectionalLight3D]:
	var context := cached_scene_nodes()
	if context.is_empty():
		return []
	var lights: Array[DirectionalLight3D] = context.lights
	return lights

func studio_environment() -> Environment:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("18232e")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 0.75
	return environment

func effective_scene_environment() -> Dictionary:
	var scene_context := cached_scene_nodes()
	if scene_context.is_empty():
		return {}
	var loader: Node = scene_context.loader
	var world: World3D = loader.get_world_3d() if is_instance_valid(loader) else null
	var environments: Array = scene_context.environments
	if world != null and world.environment != null:
		for node in environments:
			if node.environment == world.environment:
				return {"node": node, "environment": world.environment}
	# Editor worlds do not always expose the scene environment through child nodes.
	for node in environments:
		if node.environment != null and node.is_inside_tree():
			return {"node": node, "environment": node.environment}
	return {}

func resource_property(resource: Resource, property_name: StringName, fallback: Variant = null) -> Variant:
	for property in resource.get_property_list():
		if property.name == property_name:
			return resource.get(property_name)
	return fallback

func environment_signature(context: Dictionary) -> Array:
	if context.is_empty():
		return []
	var node: WorldEnvironment = context.node
	var source: Environment = context.environment
	var signature: Array = [node.get_instance_id(), source.get_instance_id()]
	for property_name in SKY_ENVIRONMENT_PROPERTIES:
		var value = resource_property(source, property_name)
		signature.append(value.get_instance_id() if value is Object and is_instance_valid(value) else value)
	return signature

func collect_environment_resource(resource: Resource, output: Array[Resource], visited: Dictionary, depth := 0) -> void:
	if resource == null or depth > 3 or visited.has(resource.get_instance_id()):
		return
	visited[resource.get_instance_id()] = true
	output.append(resource)
	for property in resource.get_property_list():
		if (int(property.usage) & PROPERTY_USAGE_STORAGE) == 0:
			continue
		var value = resource.get(property.name)
		if value is Resource:
			collect_environment_resource(value, output, visited, depth + 1)
		elif value is Array:
			for item in value:
				if item is Resource:
					collect_environment_resource(item, output, visited, depth + 1)
		elif value is Dictionary:
			for item in value.values():
				if item is Resource:
					collect_environment_resource(item, output, visited, depth + 1)

func disconnect_environment_resources() -> void:
	var callback := Callable(self, "environment_resource_changed")
	for resource in environment_resources:
		if is_instance_valid(resource) and resource.changed.is_connected(callback):
			resource.changed.disconnect(callback)
	environment_resources.clear()

func connect_environment_resources(source: Environment) -> void:
	disconnect_environment_resources()
	collect_environment_resource(source, environment_resources, {})
	var callback := Callable(self, "environment_resource_changed")
	for resource in environment_resources:
		if not resource.changed.is_connected(callback):
			resource.changed.connect(callback)

func environment_resource_changed() -> void:
	environment_dirty = true

func sync_scene_environment(force := false) -> void:
	if preview_world_environment == null:
		return
	if not preview_environment_enabled:
		return
	var context := effective_scene_environment()
	var key := environment_signature(context)
	if not force and not environment_dirty and key == environment_key:
		return
	environment_key = key
	environment_dirty = false
	if context.is_empty():
		disconnect_environment_resources()
		preview_world_environment.environment = studio_environment()
		return
	var source: Environment = context.environment
	var environment := source.duplicate(false) as Environment
	if environment == null:
		disconnect_environment_resources()
		preview_world_environment.environment = studio_environment()
		return
	preview_world_environment.environment = environment
	connect_environment_resources(source)

func copied_light_properties(light: DirectionalLight3D) -> Array:
	var result: Array = []
	for property in light.get_property_list():
		var property_name: String = property.name
		if property_name == "visible" or property_name == "editor_only" or property_name.begins_with("light_") or property_name.begins_with("shadow_") or property_name.begins_with("directional_") or property_name.begins_with("distance_fade_"):
			result.append([property.name, light.get(property.name)])
	return result

func sync_scene_lighting(force = false) -> void:
	if preview_lights == null or host == null or host.session == null:
		return
	if not preview_sunlight_enabled:
		return
	var sources := scene_directional_lights()
	var key: Array = []
	for source in sources:
		key.append([source.get_instance_id(), source.global_transform, copied_light_properties(source)])
	if not force and lighting_initialized and key == lighting_key:
		return
	lighting_key = key
	lighting_initialized = true
	for child in preview_lights.get_children():
		preview_lights.remove_child(child)
		child.queue_free()
	if sources.is_empty():
		var fallback = DirectionalLight3D.new()
		fallback.rotation_degrees = Vector3(-45, -35, 0)
		fallback.shadow_enabled = true
		preview_lights.add_child(fallback)
		return
	for source in sources:
		var light = DirectionalLight3D.new()
		for property in copied_light_properties(source):
			light.set(property[0], property[1])
		preview_lights.add_child(light)
		light.global_transform = source.global_transform

func rebuild_geometry(scale_value: float) -> void:
	var manifest: Dictionary = host.session.document.prepare_preview_chunks(scale_value,
		host.session.hidden_brush_ids(), host.session.visibility_filter_mask(), CHUNK_TRIANGLES, CHUNK_SIZE)
	triangle_count = manifest.get("triangle_count", 0)
	var active_keys: Dictionary = {}
	for entry in manifest.get("chunks", []):
		var key: String = entry.chunk_id
		active_keys[key] = true
		var category: String = entry.get("render_category", "opaque")
		var material: Material = host.preview_material(entry.texture, category)
		var cached: Dictionary = geometry_chunks.get(key, {})
		if not cached.is_empty() and cached.get("geometry_hash") == entry.geometry_hash and cached.get("geometry_version") == entry.geometry_version:
			var loader = host.session.loader.get_ref()
			var visual_layer: int = loader.option_visual_layer_mask if is_instance_valid(loader) else 1
			if cached.get("texture") != entry.texture or cached.get("render_category") != category:
				apply_preview_material(cached.instance, material, category)
				chunk_renderer_write_count += 1
			if cached.instance.layers != visual_layer:
				cached.instance.layers = visual_layer
				chunk_renderer_write_count += 1
			cached.texture = entry.texture
			cached.render_category = category
			geometry_chunks[key] = cached
			chunk_reuse_count += 1
			continue
		if not cached.is_empty():
			map_geometry.remove_child(cached.instance)
			cached.instance.queue_free()
		var chunk: Dictionary = host.session.document.get_preview_chunk(key)
		if chunk.is_empty() or chunk.geometry_hash != entry.geometry_hash:
			continue
		var instance := add_preview_mesh(chunk.vertices, chunk.normals, chunk.uvs, material)
		apply_preview_material(instance, material, category)
		chunk_mesh_upload_count += 1
		geometry_chunks[key] = {"instance": instance, "texture": entry.texture, "render_category": category, "geometry_hash": entry.geometry_hash, "geometry_version": entry.geometry_version}
	for key in geometry_chunks.keys():
		if not active_keys.has(key):
			var stale: Dictionary = geometry_chunks[key]
			map_geometry.remove_child(stale.instance)
			stale.instance.queue_free()
			geometry_chunks.erase(key)

func refresh_chunk_materials(visual_layer: int) -> void:
	for cached in geometry_chunks.values():
		var category: String = cached.get("render_category", "opaque")
		apply_preview_material(cached.instance, host.preview_material(cached.texture, category), category)
		if cached.instance.layers != visual_layer:
			cached.instance.layers = visual_layer
		chunk_renderer_write_count += 1

func selection_overlay_material(color: Color, priority: int) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	material.albedo_color = color
	material.render_priority = priority
	return material

func add_selection_overlay(name_value: String, triangles: PackedVector3Array, color: Color, priority: int) -> void:
	if triangles.is_empty():
		return
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = triangles
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var instance := MeshInstance3D.new()
	instance.name = name_value
	instance.mesh = mesh
	instance.material_override = selection_overlay_material(color, priority)
	var loader = host.session.loader.get_ref()
	if is_instance_valid(loader):
		instance.layers = loader.option_visual_layer_mask
	core_overlays.add_child(instance)


func add_selection_lines(name_value: String, lines: PackedVector3Array, color: Color, priority: int) -> void:
	if lines.is_empty():
		return
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = lines
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	var instance := MeshInstance3D.new()
	instance.name = name_value
	instance.mesh = mesh
	instance.material_override = selection_overlay_material(color, priority)
	var loader = host.session.loader.get_ref()
	if is_instance_valid(loader):
		instance.layers = loader.option_visual_layer_mask
	core_overlays.add_child(instance)

func append_face_triangles(target: PackedVector3Array, winding: PackedVector3Array, scale_value: float) -> void:
	for index in range(1, winding.size() - 1):
		target.append(transform_map_scaled(winding[0], scale_value))
		target.append(transform_map_scaled(winding[index], scale_value))
		target.append(transform_map_scaled(winding[index + 1], scale_value))

func build_overlays(scale_value: float, visual_layer: int) -> void:
	var marker_mesh := SphereMesh.new()
	marker_mesh.radius = 0.15
	marker_mesh.height = 0.3
	var marker_material := StandardMaterial3D.new()
	marker_material.albedo_color = Color("83dfbd")
	var selected_marker_material := StandardMaterial3D.new()
	selected_marker_material.albedo_color = Color("ffb657")
	for marker in host.session.point_markers():
		if not host.session.marker_visible():
			continue
		var instance = MeshInstance3D.new()
		instance.mesh = marker_mesh
		instance.position = transform_map_scaled(marker.origin, scale_value)
		instance.material_override = selected_marker_material if host.session.points.has(marker.id) else marker_material
		instance.layers = visual_layer
		core_overlays.add_child(instance)
	var brush_triangles := PackedVector3Array()
	var face_edges := PackedVector3Array()
	for id in host.session.selected:
		var brush: Dictionary = host.session.brush(id)
		if not host.session.brush_visible(brush):
			continue
		for face in brush.faces:
			if not host.session.material_filtered(face.texture):
				append_face_triangles(brush_triangles, face.winding, scale_value)
	for component in host.session.components:
		if component.kind != "face":
			continue
		var brush: Dictionary = host.session.brush(component.brush_id)
		if host.session.component_valid(component, brush) and host.session.brush_visible(brush):
			var face: Dictionary = brush.faces[component.index]
			if not host.session.material_filtered(face.texture):
				for index in face.winding.size():
					face_edges.append(transform_map_scaled(face.winding[index], scale_value))
					face_edges.append(transform_map_scaled(face.winding[(index + 1) % face.winding.size()], scale_value))
	add_selection_overlay("SelectedBrushFill", brush_triangles, Color(1.0, 0.48, 0.14, 0.14), 1)
	add_selection_lines("SelectedFaceEdges", face_edges, Color(0.16, 0.5, 1.0, 1.0), 2)
	if host.tool in ["Face", "Edge", "Vertex"]:
		var handle_material = StandardMaterial3D.new()
		handle_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		handle_material.albedo_color = Color("ffb657")
		var selected_handle_material = StandardMaterial3D.new()
		selected_handle_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		selected_handle_material.albedo_color = Color("ffe6a6")
		var handle_mesh := SphereMesh.new()
		handle_mesh.radius = 0.1
		handle_mesh.height = 0.2
		var selected_components: Dictionary = {}
		for component in host.session.components:
			var brush: Dictionary = host.session.brush(component.brush_id)
			if host.session.component_valid(component, brush):
				selected_components[[component.brush_id, component.kind, component.index]] = true
		for id in host.session.selected:
			var brush: Dictionary = host.session.brush(id)
			if not host.session.brush_visible(brush):
				continue
			var count: int = brush.faces.size() if host.tool == "Face" else (brush.vertices.size() if host.tool == "Vertex" else brush.edge_vertex_indices.size() / 2)
			for index in count:
				var position: Vector3
				if host.tool == "Face":
					if host.session.material_filtered(brush.faces[index].texture):
						continue
					position = brush.faces[index].center
				elif host.tool == "Edge":
					var edge: int = index * 2
					position = (brush.vertices[brush.edge_vertex_indices[edge]] + brush.vertices[brush.edge_vertex_indices[edge + 1]]) * 0.5
				else:
					position = brush.vertices[index]
				var selected := selected_components.has([id, host.tool.to_lower(), index])
				var handle = MeshInstance3D.new()
				handle.mesh = handle_mesh
				handle.position = transform_map_scaled(position, scale_value)
				handle.material_override = selected_handle_material if selected else handle_material
				handle.layers = visual_layer
				core_overlays.add_child(handle)
	var outline = ImmediateMesh.new()
	var outline_material = StandardMaterial3D.new()
	outline_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	outline_material.albedo_color = Color("ffb657")
	var has_lines = false
	for id in host.session.selected:
		var brush: Dictionary = host.session.brush(id)
		if not host.session.brush_visible(brush):
			continue
		if not has_lines:
			outline.surface_begin(Mesh.PRIMITIVE_LINES, outline_material)
			has_lines = true
		for edge in brush.edges:
			outline.surface_add_vertex(transform_map_scaled(edge, scale_value))
	if has_lines:
		outline.surface_end()
		var instance = MeshInstance3D.new()
		instance.mesh = outline
		instance.layers = visual_layer
		core_overlays.add_child(instance)

func ground_grid_signature() -> Array:
	if not is_instance_valid(host) or host.session == null:
		return []
	var scale_value := map_scale()
	var loader = host.session.loader.get_ref()
	var visual_layer: int = loader.option_visual_layer_mask if is_instance_valid(loader) else 1
	var extent := cached_ground_grid_extent(host.session.grid, scale_value) if host.session.grid > 0.0 else 0.0
	return [host.session.document.get_instance_id(), host.session.grid, scale_value, extent, visual_layer]

func cached_ground_grid_extent(spacing: float, scale_value := map_scale()) -> float:
	var document_id: int = host.session.document.get_instance_id()
	var generation: int = host.session.document.get_state_generation()
	if (ground_grid_extent_document_id == document_id and ground_grid_extent_generation == generation
			and is_equal_approx(ground_grid_extent_spacing, spacing)
			and is_equal_approx(ground_grid_extent_scale, scale_value)):
		return ground_grid_extent_value
	if (previous_ground_grid_extent_document_id == document_id
			and previous_ground_grid_extent_generation == generation
			and is_equal_approx(previous_ground_grid_extent_spacing, spacing)
			and is_equal_approx(previous_ground_grid_extent_scale, scale_value)):
		return previous_ground_grid_extent_value
	var extent := maxf(GROUND_GRID_MIN_EXTENT, spacing * GROUND_GRID_MAJOR_INTERVAL * 8.0)
	for brush in host.session.draw_data():
		for value in [brush.aabb_min.x, brush.aabb_min.y, brush.aabb_max.x, brush.aabb_max.y]:
			extent = maxf(extent, absf(value))
	var maximum_extent := maxf(GROUND_GRID_MIN_EXTENT, scale_value * GROUND_GRID_MAX_VIEW_EXTENT)
	extent = minf(extent, maximum_extent)
	var major_spacing := spacing * GROUND_GRID_MAJOR_INTERVAL
	previous_ground_grid_extent_document_id = ground_grid_extent_document_id
	previous_ground_grid_extent_generation = ground_grid_extent_generation
	previous_ground_grid_extent_spacing = ground_grid_extent_spacing
	previous_ground_grid_extent_scale = ground_grid_extent_scale
	previous_ground_grid_extent_value = ground_grid_extent_value
	ground_grid_extent_value = minf(ceilf((extent + major_spacing * 2.0) / major_spacing) * major_spacing, maximum_extent)
	ground_grid_extent_document_id = document_id
	ground_grid_extent_generation = generation
	ground_grid_extent_spacing = spacing
	ground_grid_extent_scale = scale_value
	return ground_grid_extent_value

func add_ground_grid_lines(name_value: String, lines: PackedVector3Array, color: Color, priority: int) -> void:
	if lines.is_empty():
		return
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = lines
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	var instance := MeshInstance3D.new()
	instance.name = name_value
	instance.mesh = mesh
	instance.material_override = selection_overlay_material(color, priority)
	var loader = host.session.loader.get_ref()
	if is_instance_valid(loader):
		instance.layers = loader.option_visual_layer_mask
	ground_grid.add_child(instance)

func build_ground_grid(scale_value: float) -> void:
	ground_grid_key = ground_grid_signature()
	var spacing: float = host.session.grid
	if spacing <= 0.0:
		return
	var extent := cached_ground_grid_extent(spacing, scale_value)
	var steps := ceili(extent / spacing)
	var max_steps := floori(float(GROUND_GRID_MAX_VERTICES - 4) / 8.0)
	var stride := maxi(1, ceili(float(steps) / max_steps))
	spacing *= stride
	steps = mini(floori(extent / spacing), max_steps)
	extent = steps * spacing
	var minor := PackedVector3Array()
	var major := PackedVector3Array()
	var x_axis := PackedVector3Array([
		transform_map_scaled(Vector3(-extent, 0, 0), scale_value),
		transform_map_scaled(Vector3(extent, 0, 0), scale_value),
	])
	var y_axis := PackedVector3Array([
		transform_map_scaled(Vector3(0, -extent, 0), scale_value),
		transform_map_scaled(Vector3(0, extent, 0), scale_value),
	])
	for index in range(-steps, steps + 1):
		if index == 0:
			continue
		var coordinate := index * spacing
		var horizontal := [
			transform_map_scaled(Vector3(-extent, coordinate, 0), scale_value),
			transform_map_scaled(Vector3(extent, coordinate, 0), scale_value),
			transform_map_scaled(Vector3(coordinate, -extent, 0), scale_value),
			transform_map_scaled(Vector3(coordinate, extent, 0), scale_value),
		]
		if index * stride % GROUND_GRID_MAJOR_INTERVAL == 0:
			major.append_array(horizontal)
		else:
			minor.append_array(horizontal)
	add_ground_grid_lines("MinorLines", minor, Color(0.68, 0.74, 0.8, 0.10), -3)
	add_ground_grid_lines("MajorLines", major, Color(0.72, 0.79, 0.86, 0.22), -2)
	add_ground_grid_lines("MapXAxis", x_axis, Color(0.88, 0.34, 0.3, 0.38), -1)
	add_ground_grid_lines("MapYAxis", y_axis, Color(0.36, 0.76, 0.48, 0.38), -1)

func rebuild_ground_grid() -> void:
	if ground_grid == null or not camera_grid_visible or not ground_grid.visible or not is_visible_in_tree():
		return
	for child in ground_grid.get_children():
		ground_grid.remove_child(child)
		child.queue_free()
	build_ground_grid(map_scale())
	ground_grid_rebuild_count += 1

func surface_grid_signature() -> Array:
	if not is_instance_valid(host) or host.session == null:
		return []
	var loader = host.session.loader.get_ref()
	var visual_layer: int = loader.option_visual_layer_mask if is_instance_valid(loader) else 1
	return [host.session.document.get_instance_id(), host.session.preview_generation,
		host.session.visibility_generation, host.session.selection_generation, host.session.grid,
		map_scale(), visual_layer]

func toggle_surface_grid() -> void:
	surface_grid_visible = not surface_grid_visible
	rebuild_surface_grid_overlay()
	if is_instance_valid(host) and host.has_method("set_status"):
		host.set_status("Camera selected-surface grid: %s" % ("on" if surface_grid_visible else "off"))

func rebuild_surface_grid_overlay() -> void:
	if overlays == null:
		return
	var existing := overlays.get_node_or_null("SelectedSurfaceGrid")
	if existing != null:
		overlays.remove_child(existing)
		existing.queue_free()
	build_surface_grid(map_scale())

func plane_polygon_segment(winding: PackedVector3Array, axis: int, coordinate: float) -> PackedVector3Array:
	var intersections := PackedVector3Array()
	var epsilon := maxf(host.session.grid * 0.00001, 0.00001)
	for index in winding.size():
		var a := winding[index]
		var b := winding[(index + 1) % winding.size()]
		var da := a[axis] - coordinate
		var db := b[axis] - coordinate
		if absf(da) <= epsilon:
			intersections.append(a)
		if (da < -epsilon and db > epsilon) or (da > epsilon and db < -epsilon):
			intersections.append(a.lerp(b, da / (da - db)))
	var unique := PackedVector3Array()
	for point in intersections:
		var duplicate := false
		for candidate in unique:
			if candidate.distance_squared_to(point) <= epsilon * epsilon:
				duplicate = true
				break
		if not duplicate:
			unique.append(point)
	if unique.size() < 2:
		return PackedVector3Array()
	var result := PackedVector3Array([unique[0], unique[1]])
	var longest := result[0].distance_squared_to(result[1])
	for a in unique.size():
		for b in range(a + 1, unique.size()):
			var distance := unique[a].distance_squared_to(unique[b])
			if distance > longest:
				longest = distance
				result[0] = unique[a]
				result[1] = unique[b]
	return result

func build_surface_grid(scale_value: float) -> void:
	surface_grid_key = surface_grid_signature()
	if not surface_grid_visible or host.session.selected.is_empty():
		return
	var spacing: float = host.session.grid
	if spacing <= 0.0:
		return
	var lines := PackedVector3Array()
	for id in host.session.selected:
		var brush: Dictionary = host.session.brush(id)
		if not host.session.brush_visible(brush):
			continue
		for face in brush.faces:
			var winding: PackedVector3Array = face.winding
			if winding.size() < 3 or host.session.material_filtered(face.texture):
				continue
			var offset: Vector3 = face.normal.normalized() * maxf(spacing * 0.0001, 0.001)
			for axis in 3:
				var minimum := winding[0][axis]
				var maximum := minimum
				for point in winding:
					minimum = minf(minimum, point[axis])
					maximum = maxf(maximum, point[axis])
				if maximum - minimum <= maxf(spacing * 0.00001, 0.00001):
					continue
				var first := ceili(minimum / spacing)
				var last := floori(maximum / spacing)
				for step in range(first, last + 1):
					var segment := plane_polygon_segment(winding, axis, step * spacing)
					if segment.size() == 2:
						lines.append(transform_map_scaled(segment[0] + offset, scale_value))
						lines.append(transform_map_scaled(segment[1] + offset, scale_value))
	if lines.is_empty():
		return
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = lines
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	var instance := MeshInstance3D.new()
	instance.name = "SelectedSurfaceGrid"
	instance.mesh = mesh
	instance.material_override = selection_overlay_material(Color(0.86, 0.92, 1.0, 0.62), 3)
	var loader = host.session.loader.get_ref()
	if is_instance_valid(loader):
		instance.layers = loader.option_visual_layer_mask
	overlays.add_child(instance)

func rebuild_cut_overlay() -> void:
	if overlays == null or not is_instance_valid(host):
		return
	var existing := overlays.get_node_or_null("CutOverlay")
	if existing != null:
		overlays.remove_child(existing)
		existing.queue_free()
	if host.tool != "Cut" or host.cut_points.is_empty():
		return
	var root := Node3D.new()
	root.name = "CutOverlay"
	overlays.add_child(root)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color("fc7373")
	material.no_depth_test = true
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	var marker_mesh := SphereMesh.new()
	marker_mesh.radius = 0.09
	marker_mesh.height = 0.18
	for point in host.cut_points:
		var marker := MeshInstance3D.new()
		marker.mesh = marker_mesh
		marker.position = transform_map(point)
		marker.material_override = material
		root.add_child(marker)
	var plane: Array[Vector3] = host.cut_plane()
	if plane.size() == 3:
		var lines := ImmediateMesh.new()
		lines.surface_begin(Mesh.PRIMITIVE_LINES, material)
		for pair in [[0, 1], [1, 2], [2, 0]]:
			lines.surface_add_vertex(transform_map(plane[pair[0]]))
			lines.surface_add_vertex(transform_map(plane[pair[1]]))
		lines.surface_end()
		var line_instance := MeshInstance3D.new()
		line_instance.mesh = lines
		root.add_child(line_instance)

func selection_center() -> Vector3:
	var bounds: AABB
	var first := true
	for id in host.session.selected:
		var brush: Dictionary = host.session.brush(id)
		if brush.is_empty():
			continue
		var item := AABB(brush.aabb_min, brush.aabb_max - brush.aabb_min)
		bounds = item if first else bounds.merge(item)
		first = false
	return bounds.get_center() if not first else Vector3.ZERO

func component_position(component: Dictionary, brush: Dictionary) -> Vector3:
	if component.kind == "face":
		return brush.faces[component.index].center
	if component.kind == "vertex":
		return brush.vertices[component.index]
	var edge: int = component.index * 2
	return (brush.vertices[brush.edge_vertex_indices[edge]] + brush.vertices[brush.edge_vertex_indices[edge + 1]]) * 0.5

func camera_handle_hit(position: Vector2, mode: String) -> Dictionary:
	var nearest := 12.0
	var result: Dictionary = {}
	for id in host.session.selected:
		var brush: Dictionary = host.session.brush(id)
		if not host.session.brush_visible(brush):
			continue
		var count: int = brush.vertices.size() if mode == "Vertex" else brush.edge_vertex_indices.size() / 2
		for index in count:
			var component := {"brush_id": id, "kind": mode.to_lower(), "index": index, "topology_revision": brush.topology_revision}
			var preview_position := transform_map(component_position(component, brush))
			if camera.is_position_behind(preview_position):
				continue
			var distance := camera.unproject_position(preview_position).distance_to(position)
			if distance <= nearest or (is_equal_approx(distance, nearest) and host.session.components.has(component)):
				nearest = distance
				result = component
	return result

func ray_plane_point(position: Vector2, plane_origin: Vector3, plane_normal: Vector3) -> Variant:
	var scale_value := map_scale()
	var origin := preview_to_map(camera.project_ray_origin(position), scale_value)
	var direction := preview_direction_to_map(camera.project_ray_normal(position))
	var denominator := plane_normal.dot(direction)
	if absf(denominator) < 0.00001:
		return null
	return origin + direction * plane_normal.dot(plane_origin - origin) / denominator

func begin_camera_left(event: InputEventMouseButton) -> void:
	cancel_gesture()
	camera_press_position = event.position
	camera_delta = Vector3.ZERO
	if host.tool == "Cut":
		var cut_hit := face_hit(event.position)
		if not cut_hit.is_empty():
			host.add_cut_point(cut_hit.position.snapped(Vector3.ONE * host.session.grid), -1, camera_map_direction())
			host.preview_clip(false, self)
		return
	if host.tool in ["Vertex", "Edge"]:
		var component := camera_handle_hit(event.position, host.tool)
		host.session.select_component(component, event.shift_pressed)
		if not component.is_empty() and not event.shift_pressed:
			camera_component = component.duplicate()
			camera_drag_anchor = component_position(component, host.session.brush(component.brush_id))
			camera_gesture = "component_pending"
		return
	if host.tool == "Rotate":
		camera_hit = face_hit(event.position)
		if camera_hit.is_empty():
			pick(event.position, event.shift_pressed)
			return
		if event.shift_pressed:
			apply_pick(camera_hit.brush_id, 0, camera_hit.face_index, true)
			return
		if not host.session.selected.has(camera_hit.brush_id):
			host.session.select(PackedInt64Array([camera_hit.brush_id]))
		camera_rotation_pivot = selection_center()
		var direction := camera_map_direction().abs()
		camera_rotation_axis = direction.max_axis_index()
		var pivot_screen := camera.unproject_position(transform_map(camera_rotation_pivot))
		camera_rotation_start = (event.position - pivot_screen).angle()
		camera_gesture = "rotate_pending"
		return
	if host.tool in ["Select", "Brush"]:
		camera_hit = face_hit(event.position)
		if event.shift_pressed:
			camera_gesture = "brush_paint"
			brush_paint_select = camera_hit.is_empty() or not host.session.selected.has(camera_hit.brush_id)
			paint_brush(camera_hit)
			return
		if not camera_hit.is_empty() and host.session.selected.has(camera_hit.brush_id) and not event.shift_pressed:
			camera_drag_anchor = camera_hit.position
			camera_gesture = "move_pending"
			return
		if not camera_hit.is_empty():
			apply_pick(camera_hit.brush_id, 0, camera_hit.face_index, event.shift_pressed)
		else:
			pick_crosshair(event.shift_pressed)
		return
	pick(event.position, event.shift_pressed, false, host.tool == "Face")

func update_camera_gesture(position: Vector2) -> void:
	if camera_gesture == "brush_paint":
		paint_brush(face_hit(position))
		return
	if camera_gesture.ends_with("_pending") and position.distance_to(camera_press_position) < DRAG_THRESHOLD:
		return
	if camera_gesture == "move_pending":
		camera_gesture = "move"
	elif camera_gesture == "component_pending":
		camera_gesture = "component"
	elif camera_gesture == "rotate_pending":
		camera_gesture = "rotate"
	if camera_gesture == "rotate":
		var pivot_screen := camera.unproject_position(transform_map(camera_rotation_pivot))
		if position.distance_to(pivot_screen) > 0.001:
			camera_rotation_angle = snappedf(camera_rotation_start - (position - pivot_screen).angle(), deg_to_rad(15.0))
		host.broadcast_mutation_preview(host.session.document.preview_rotate_brushes(host.session.selected,
			camera_rotation_pivot, camera_rotation_axis, camera_rotation_angle), self)
		return
	if camera_gesture not in ["move", "component"]:
		return
	var point = ray_plane_point(position, camera_drag_anchor, camera_map_direction())
	if point == null:
		return
	camera_delta = (Vector3(point) - camera_drag_anchor).snapped(Vector3.ONE * host.session.grid)
	var result: Dictionary
	if camera_gesture == "move":
		result = host.session.document.preview_translate_brushes(host.session.selected, camera_delta)
	else:
		result = host.session.document.preview_translate_components(host.session.components, camera_delta)
	host.broadcast_mutation_preview(result, self)

func paint_brush(hit: Dictionary) -> void:
	if hit.is_empty():
		return
	var id := int(hit.brush_id)
	if brush_paint_visited.has(id):
		return
	brush_paint_visited[id] = true
	var selected: PackedInt64Array = host.session.selected.duplicate()
	if brush_paint_select:
		if selected.has(id):
			return
		selected.append(id)
	elif selected.has(id):
		selected.remove_at(selected.find(id))
	else:
		return
	host.session.select(selected)

func finish_camera_left() -> void:
	var gesture := camera_gesture
	var movement := camera_delta
	var angle := camera_rotation_angle
	if gesture == "brush_paint":
		pass
	elif gesture == "move_pending" and not camera_hit.is_empty():
		apply_pick(camera_hit.brush_id, 0, camera_hit.face_index, false)
	elif gesture == "move" and not movement.is_zero_approx():
		host.session.transact("Move map selection", func(): return host.session.translate_brushes(host.session.selected, movement), "brush_translation")
	elif gesture == "component" and not movement.is_zero_approx():
		host.session.transact("Move map components", func(): return host.session.move_components(movement))
	elif gesture == "rotate" and not is_zero_approx(angle):
		var pivot := camera_rotation_pivot
		var axis := camera_rotation_axis
		host.session.transact("Rotate map selection", func(): return host.session.document.rotate_brushes(host.session.selected, pivot, axis, angle))
	cancel_gesture()

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if not event.pressed and (event.device == -1 or (DisplayServer.get_name() != "headless" and not get_window().has_focus())):
			cancel_gesture()
			return
		if event.pressed:
			grab_focus()
		if handle_camera_wheel(event):
			accept_event()
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			cancel_gesture()
			begin_rmb()
			accept_event()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			finish_rmb()
			accept_event()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if event.ctrl_pressed:
					begin_ctrl_gesture(event.position)
				else:
					begin_camera_left(event)
			else:
				if ctrl_gesture != "":
					finish_ctrl_gesture()
				else:
					finish_camera_left()
			accept_event()
	elif event is InputEventMouseMotion and ctrl_gesture != "":
		update_ctrl_gesture(event.position)
		accept_event()
	elif event is InputEventMouseMotion and camera_gesture != "":
		update_camera_gesture(event.position)
		accept_event()
	elif event is InputEventKey:
		if event.pressed and event.keycode == KEY_ESCAPE and (ctrl_gesture != "" or camera_gesture != ""):
			cancel_gesture()
			accept_event()
		elif event.pressed and not event.echo and event.keycode == KEY_G:
			toggle_surface_grid()
			accept_event()
		elif host.route_key(event, host.active_graph):
			refresh_selection()
			accept_event()

func face_hit(position: Vector2) -> Dictionary:
	var scale_value := map_scale()
	var ray := camera.project_ray_origin(position)
	var direction := camera.project_ray_normal(position)
	return host.session.nearest_visible_ray_hit(preview_to_map(ray, scale_value),
		preview_direction_to_map(direction), 1e30)

func face_component(hit: Dictionary) -> Dictionary:
	if hit.is_empty():
		return {}
	var brush: Dictionary = host.session.brush(hit.brush_id)
	if brush.is_empty():
		return {}
	return {"brush_id": hit.brush_id, "kind": "face", "index": hit.face_index, "topology_revision": brush.topology_revision}

func begin_ctrl_gesture(position: Vector2) -> void:
	cancel_gesture()
	ctrl_press_position = position
	ctrl_start_hit = face_hit(position)
	if ctrl_start_hit.is_empty():
		ctrl_gesture = "click"
		return
	var component := face_component(ctrl_start_hit)
	var has_face_components: bool = host.session.components.any(func(item): return item.kind == "face")
	if not host.session.selected.is_empty() and not has_face_components:
		if host.session.selected.has(ctrl_start_hit.brush_id):
			ctrl_gesture = "resize_pending"
			prepare_ctrl_resize(component, ctrl_start_hit.position)
			# Preserve press-time face feedback while keeping geometry untouched.
			host.session.components = [component]
			host.session.notify_changed("selection")
		else:
			ctrl_gesture = "click"
	else:
		ctrl_gesture = "paint_pending"
		ctrl_paint_select = not host.session.components.has(component)

func prepare_ctrl_resize(source: Dictionary, hit_position: Vector3) -> void:
	var source_brush: Dictionary = host.session.brush(source.brush_id)
	if not host.session.component_valid(source, source_brush):
		return
	var source_face: Dictionary = source_brush.faces[source.index]
	ctrl_resize_origin = hit_position
	ctrl_resize_normal = source_face.normal.normalized()
	var plane_distance := ctrl_resize_normal.dot(source_face.center)
	var epsilon := maxf(host.session.grid * 0.0001, 0.001)
	for id in host.session.selected:
		var brush: Dictionary = host.session.brush(id)
		if not host.session.brush_visible(brush):
			continue
		for face in brush.faces:
			if face.normal.normalized().dot(ctrl_resize_normal) > 0.9999 and absf(ctrl_resize_normal.dot(face.center) - plane_distance) <= epsilon:
				ctrl_resize_components.append({"brush_id": id, "kind": "face", "index": face.index, "topology_revision": brush.topology_revision})

func update_ctrl_gesture(position: Vector2) -> void:
	if ctrl_gesture.ends_with("_pending") and position.distance_to(ctrl_press_position) < DRAG_THRESHOLD:
		return
	if ctrl_gesture == "paint_pending":
		ctrl_gesture = "paint"
		paint_face(ctrl_start_hit)
	elif ctrl_gesture == "resize_pending":
		ctrl_gesture = "resize"
	if ctrl_gesture == "paint":
		paint_face(face_hit(position))
	elif ctrl_gesture == "resize":
		update_ctrl_resize(position)

func paint_face(hit: Dictionary) -> void:
	var component := face_component(hit)
	if component.is_empty():
		return
	var key := [component.brush_id, component.index]
	if ctrl_visited.has(key):
		return
	ctrl_visited[key] = true
	var components: Array = host.session.components.duplicate(true)
	var index := components.find(component)
	if ctrl_paint_select:
		if index >= 0:
			return
		if not host.session.selected.has(component.brush_id):
			host.session.selected.append(component.brush_id)
		components.append(component)
	elif index >= 0:
		components.remove_at(index)
	else:
		return
	var selected: PackedInt64Array = host.session.selected.duplicate()
	if not ctrl_paint_select and not components.any(func(item): return item.brush_id == component.brush_id):
		var selected_index := selected.find(component.brush_id)
		if selected_index >= 0:
			selected.remove_at(selected_index)
	set_face_selection(selected, components)

func update_ctrl_resize(position: Vector2) -> void:
	if ctrl_resize_normal.is_zero_approx() or ctrl_resize_components.is_empty():
		return
	var scale_value := map_scale()
	var ray_origin := preview_to_map(camera.project_ray_origin(position), scale_value)
	var ray_direction := preview_direction_to_map(camera.project_ray_normal(position))
	var between := ctrl_resize_origin - ray_origin
	var alignment := ctrl_resize_normal.dot(ray_direction)
	var denominator := 1.0 - alignment * alignment
	if denominator <= 0.00001:
		return
	var distance := (alignment * ray_direction.dot(between) - ctrl_resize_normal.dot(between)) / denominator
	distance = snappedf(distance, host.session.grid)
	ctrl_resize_delta = ctrl_resize_normal * distance
	host.broadcast_mutation_preview(host.session.document.preview_translate_components(ctrl_resize_components, ctrl_resize_delta), self)

func finish_ctrl_gesture() -> void:
	if ctrl_gesture in ["paint_pending", "resize_pending", "click"]:
		var component := face_component(ctrl_start_hit)
		if ctrl_gesture == "resize_pending":
			# The pending resize face is only press feedback; quick release toggles
			# against the selection that existed before that feedback.
			host.session.components.clear()
		apply_pick(component.get("brush_id", 0), 0, component.get("index", -1), true, false, true)
	elif ctrl_gesture == "resize" and not ctrl_resize_delta.is_zero_approx():
		var components := ctrl_resize_components.duplicate(true)
		var movement := ctrl_resize_delta
		var session = host.session
		session.transact("Resize map faces", func():
			var previous: Array = session.components.duplicate(true)
			session.components = components.duplicate(true)
			var result: Dictionary = session.move_components(movement)
			if not result.ok:
				session.components = previous
			return result)
	cancel_gesture()

func pick_crosshair(additive: bool, paint = false, face_pick = false) -> void:
	pick(size * 0.5, additive, paint, face_pick)

func pick(position: Vector2, additive: bool, paint = false, face_pick = false) -> void:
	var scale_value := map_scale()
	var ray := camera.project_ray_origin(position)
	var direction := camera.project_ray_normal(position)
	var map_ray := preview_to_map(ray, scale_value)
	var nearest = INF
	var point_id = 0
	for marker in host.session.point_markers():
		if not host.session.marker_visible():
			continue
		var p = transform_map(marker.origin)
		if not camera.is_position_behind(p) and camera.unproject_position(p).distance_to(position) < 14:
			var distance = map_ray.distance_to(marker.origin)
			if distance < nearest:
				nearest = distance
				point_id = marker.id
	var id = 0
	var face_index = -1
	var max_distance: float = nearest if is_finite(nearest) else 1e30
	var hit: Dictionary = host.session.nearest_visible_ray_hit(map_ray,
		preview_direction_to_map(direction), max_distance)
	if not hit.is_empty() and hit.distance < nearest:
		nearest = hit.distance
		id = hit.brush_id
		point_id = 0
		face_index = hit.face_index
	apply_pick(id, point_id, face_index, additive, paint, face_pick)

func apply_pick(id: int, point_id: int, face_index: int, additive: bool, paint = false, face_pick = false) -> void:
	if point_id:
		host.session.select(PackedInt64Array(), PackedInt64Array([point_id]))
		return
	if host.tool == "Face" or face_pick:
		var ids = host.session.selected.duplicate() if additive else PackedInt64Array()
		var components: Array = host.session.components.duplicate(true) if additive else []
		if not id:
			if not additive:
				host.session.select(PackedInt64Array())
			return
		var component = {"brush_id": id, "kind": "face", "index": face_index, "topology_revision": host.session.brush(id).topology_revision}
		var existing := components.find(component)
		if additive and existing >= 0:
			components.remove_at(existing)
			if not components.any(func(item): return item.brush_id == id) and ids.has(id):
				ids.remove_at(ids.find(id))
		else:
			if not ids.has(id):
				ids.append(id)
			components.append(component)
		set_face_selection(ids, components)
		return
	var ids = host.session.selected.duplicate() if additive else PackedInt64Array()
	if id:
		if ids.has(id):
			if not paint:
				ids.remove_at(ids.find(id))
		else:
			ids.append(id)
	host.session.select(ids)

func set_face_selection(ids: PackedInt64Array, components: Array) -> void:
	host.session.selected = ids
	host.session.points.clear()
	host.session.components = components.filter(func(item): return host.session.component_valid(item, host.session.brush(item.brush_id)))
	host.session.prune()
	host.session.notify_changed("selection")

func start_fly() -> void:
	cancel_gesture()
	flying = true
	crosshair.show()
	selection_painting = false
	held.clear()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	update_hint()

func begin_rmb() -> void:
	if rmb_down:
		return
	rmb_down = true
	rmb_was_flying = flying
	rmb_drag_distance = 0.0
	rmb_dragging = false
	if not flying:
		start_fly()

func finish_rmb() -> void:
	if not rmb_down:
		return
	var keep_flying := rmb_was_flying if rmb_dragging else not rmb_was_flying
	rmb_down = false
	rmb_drag_distance = 0.0
	rmb_dragging = false
	if not keep_flying:
		stop_fly()

func stop_fly() -> void:
	cancel_gesture()
	if flying:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	flying = false
	if crosshair != null:
		crosshair.hide()
	selection_painting = false
	held.clear()
	rmb_down = false
	rmb_was_flying = false
	rmb_drag_distance = 0.0
	rmb_dragging = false
	update_hint()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and (event.keycode in [KEY_BRACKETLEFT, KEY_BRACKETRIGHT] or event.keycode >= KEY_1 and event.keycode <= KEY_9):
		# The host applies grid shortcuts later in GUI dispatch; refresh every camera afterward.
		call_deferred("refresh_selection")
	if not flying:
		return
	if event is InputEventMouseButton:
		if handle_camera_wheel(event):
			get_viewport().set_input_as_handled()
			return
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				begin_rmb()
			else:
				finish_rmb()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			selection_painting = event.pressed and event.shift_pressed and not event.ctrl_pressed and host.session.components.is_empty()
			if event.pressed:
				if event.ctrl_pressed:
					pick_crosshair(false, false, true)
				elif not event.shift_pressed or selection_painting:
					pick_crosshair(event.shift_pressed, selection_painting)
	elif event is InputEventKey:
		if event.keycode == KEY_ESCAPE:
			stop_fly()
		else:
			held[event.physical_keycode if event.physical_keycode else event.keycode] = event.pressed
			if not event.shift_pressed:
				selection_painting = false
	elif event is InputEventMouseMotion:
		var previous_transform := camera.transform
		if rmb_down:
			rmb_drag_distance += event.relative.length()
			rmb_dragging = rmb_dragging or rmb_drag_distance >= DRAG_THRESHOLD
			var pan_scale := fly_speed * 0.01
			camera.position += camera.global_basis.x * event.relative.x * pan_scale
			camera.position += (-camera.global_basis.z if event.shift_pressed else camera.global_basis.y) * -event.relative.y * pan_scale
		else:
			yaw -= event.relative.x * 0.003
			pitch = clampf(pitch - event.relative.y * 0.003, -1.55, 1.55)
			camera.rotation = Vector3(pitch, yaw, 0)
		if selection_painting:
			if event.shift_pressed:
				pick_crosshair(true, true)
			else:
				selection_painting = false
		orbit_target = camera.position - camera.global_basis.z * orbit_distance
		if camera.transform != previous_transform:
			camera_transform_changed()
	get_viewport().set_input_as_handled()

func _process(dt: float) -> void:
	lighting_sync_delay -= dt
	if lighting_sync_delay <= 0:
		lighting_sync_delay = 0.25
		sync_scene_environment()
		sync_scene_lighting()
		if built_appearance:
			refresh_built_appearance()
	if flying:
		var direction = Vector3(float(held.get(KEY_D, false)) - float(held.get(KEY_A, false)),
			float(held.get(KEY_E, false)) - float(held.get(KEY_Q, false)),
			float(held.get(KEY_S, false)) - float(held.get(KEY_W, false)))
		if not direction.is_zero_approx():
			camera.position += camera.basis * direction.normalized() * dt * fly_speed * (FAST_FLY_FACTOR if held.get(KEY_SHIFT, false) else 1.0)
			orbit_target = camera.position - camera.global_basis.z * orbit_distance
			camera_transform_changed()

func _notification(what: int) -> void:
	if what == NOTIFICATION_EXIT_TREE:
		disconnect_environment_resources()
		_sync_suspension(true)
	elif what == NOTIFICATION_ENTER_TREE:
		call_deferred("_sync_suspension")
	elif what == NOTIFICATION_VISIBILITY_CHANGED:
		if is_visible_in_tree():
			set_process(true)
			call_deferred("_sync_suspension")
			call_deferred("rebuild_ground_grid")
		else:
			_sync_suspension()
	if what in [NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_WM_WINDOW_FOCUS_OUT]:
		cancel_interaction()
