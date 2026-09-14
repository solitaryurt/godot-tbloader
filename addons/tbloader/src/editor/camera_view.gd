@tool
extends Control

const OrientationGizmo = preload("res://addons/tbloader/src/editor/orientation_gizmo.gd")

signal camera_moved(map_position: Vector3, map_direction: Vector3)

var host: Control
var viewport: SubViewport
var camera: Camera3D
var geometry: Node3D
var map_geometry: Node3D
var overlays: Node3D
var grid_move_preview: Node3D
var grid_move_preview_key = ""
var candidate_offscreen := false
var candidate_indicator: Label
var preview_lights: Node3D
var flying = false
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
var rendered_key = ""
var rendered_material_key = ""
var geometry_chunks: Dictionary = {}
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
const CHUNK_TRIANGLES = 2048
const CHUNK_SIZE = 64.0
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
	geometry = Node3D.new()
	viewport.add_child(geometry)
	map_geometry = Node3D.new()
	geometry.add_child(map_geometry)
	overlays = Node3D.new()
	geometry.add_child(overlays)
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
	var environment = WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("18232e")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 0.75
	viewport.add_child(environment)
	preview_lights = Node3D.new()
	viewport.add_child(preview_lights)
	sync_scene_lighting(true)
	hint = Label.new()
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.position = Vector2(34, 3)
	add_child(hint)
	update_hint()
	orientation_gizmo = OrientationGizmo.new()
	orientation_gizmo.name = "CameraOrientation"
	orientation_gizmo.allow_orbit = true
	orientation_gizmo.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	orientation_gizmo.position = Vector2(-68, 4)
	orientation_gizmo.axis_selected.connect(snap_to_axis)
	orientation_gizmo.orbit_dragged.connect(orbit_from_gizmo)
	add_child(orientation_gizmo)
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
	frame_button.position = Vector2(-100, 4)
	frame_button.pressed.connect(frame_selection)
	add_child(frame_button)
	focus_exited.connect(cancel_interaction)
	visibility_changed.connect(func():
		if not is_visible_in_tree():
			cancel_interaction())

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
		sync_camera_marker(true)
		update_orientation_gizmo()
	update_hint()

func update_hint() -> void:
	if hint == null:
		return
	var fps := Engine.get_frames_per_second()
	if flying:
		hint.text = "FLY • %.0f FPS • speed %.1f • FOV %.0f° • WASD / Q E • Esc / RMB release" % [float(fps), float(fly_speed), float(camera_fov)]
	else:
		hint.text = "%.0f FPS • wheel dolly %.3f • Ctrl+wheel step • RMB fly" % [float(fps), float(dolly_step)]

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
		sync_camera_marker(true)
		update_orientation_gizmo()
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
	update_orientation_gizmo()

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
	sync_camera_marker(true)
	update_orientation_gizmo()
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
	sync_camera_marker(true)
	update_orientation_gizmo()

func refresh() -> void:
	if geometry == null:
		return
	sync_camera_marker()
	sync_scene_lighting()
	var hidden_ids: Array = host.session.hidden.keys()
	hidden_ids.sort()
	var scale_value := map_scale()
	var loader = host.session.loader.get_ref()
	var visual_layer: int = loader.option_visual_layer_mask if is_instance_valid(loader) else 1
	var key := "%d:%d:%d:%s:%s" % [host.session.document.get_instance_id(), host.session.preview_generation, host.session.visibility_generation, str(hidden_ids), scale_value]
	if key != rendered_key:
		rendered_key = key
		rebuild_geometry(scale_value)
	var material_key := "%d:%d:%d" % [host.session.document.get_instance_id(), host.material_generation, visual_layer]
	if material_key != rendered_material_key:
		rendered_material_key = material_key
		refresh_chunk_materials(visual_layer)
	for child in overlays.get_children():
		overlays.remove_child(child)
		child.queue_free()
	build_overlays(scale_value)

func candidate_material(color: Color, hidden: bool) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.no_depth_test = hidden
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	return material

func candidate_mesh_instance(vertices: PackedVector3Array, primitive: int, material: Material, name_value: String) -> MeshInstance3D:
	if vertices.is_empty():
		return null
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(primitive, arrays)
	var instance := MeshInstance3D.new()
	instance.name = name_value
	instance.mesh = mesh
	instance.material_override = material
	var loader = host.session.loader.get_ref()
	if is_instance_valid(loader):
		instance.layers = loader.option_visual_layer_mask
	grid_move_preview.add_child(instance)
	return instance

func set_candidate_preview(candidates: Array) -> void:
	clear_candidate_preview()
	if candidates.is_empty() or grid_move_preview == null:
		return
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
	# The hidden pass ignores depth; the visible pass depth-tests. Neither pass writes depth.
	candidate_mesh_instance(triangles, Mesh.PRIMITIVE_TRIANGLES, candidate_material(Color(1.0, 0.72, 0.38, 0.12), true), "HiddenHulls")
	candidate_mesh_instance(edges, Mesh.PRIMITIVE_LINES, candidate_material(Color(1.0, 0.78, 0.48, 0.42), true), "HiddenEdges")
	candidate_mesh_instance(triangles, Mesh.PRIMITIVE_TRIANGLES, candidate_material(Color(1.0, 0.52, 0.12, 0.24), false), "VisibleHulls")
	candidate_mesh_instance(edges, Mesh.PRIMITIVE_LINES, candidate_material(Color(1.0, 0.58, 0.14, 0.96), false), "VisibleEdges")
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
	if host.session.selected.is_empty():
		clear_candidate_preview()
		return
	var result: Dictionary = host.session.document.preview_translate_brushes(host.session.selected, delta)
	if result.get("ok", false):
		set_candidate_preview(result.get("value", []))
	else:
		clear_candidate_preview()

func clear_grid_move_preview() -> void:
	clear_candidate_preview()

func clear_candidate_preview() -> void:
	if grid_move_preview != null:
		for child in grid_move_preview.get_children():
			grid_move_preview.remove_child(child)
			child.queue_free()
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

func scene_directional_lights() -> Array[DirectionalLight3D]:
	var result: Array[DirectionalLight3D] = []
	var root = host.session.scene.get_ref()
	if not is_instance_valid(root):
		return result
	if root is DirectionalLight3D:
		result.append(root)
	for node in root.find_children("*", "DirectionalLight3D", true, false):
		result.append(node)
	return result

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
	var retained: Dictionary = {}
	for entry in manifest.get("chunks", []):
		var key: String = entry.chunk_id
		var category: String = entry.get("render_category", "opaque")
		var material: Material = host.preview_material(entry.texture, category)
		var cached: Dictionary = geometry_chunks.get(key, {})
		if not cached.is_empty() and cached.get("geometry_hash") == entry.geometry_hash and cached.get("geometry_version") == entry.geometry_version:
			apply_preview_material(cached.instance, material, category)
			var loader = host.session.loader.get_ref()
			cached.instance.layers = loader.option_visual_layer_mask if is_instance_valid(loader) else 1
			cached.texture = entry.texture
			cached.render_category = category
			retained[key] = cached
			continue
		if not cached.is_empty():
			map_geometry.remove_child(cached.instance)
			cached.instance.queue_free()
		var chunk: Dictionary = host.session.document.get_preview_chunk(key)
		if chunk.is_empty() or chunk.geometry_hash != entry.geometry_hash:
			continue
		var instance := add_preview_mesh(chunk.vertices, chunk.normals, chunk.uvs, material)
		apply_preview_material(instance, material, category)
		retained[key] = {"instance": instance, "texture": entry.texture, "render_category": category, "geometry_hash": entry.geometry_hash, "geometry_version": entry.geometry_version}
	for key in geometry_chunks:
		if not retained.has(key):
			var stale: Dictionary = geometry_chunks[key]
			map_geometry.remove_child(stale.instance)
			stale.instance.queue_free()
	geometry_chunks = retained

func refresh_chunk_materials(visual_layer: int) -> void:
	for cached in geometry_chunks.values():
		var category: String = cached.get("render_category", "opaque")
		apply_preview_material(cached.instance, host.preview_material(cached.texture, category), category)
		cached.instance.layers = visual_layer

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
	overlays.add_child(instance)

func append_face_triangles(target: PackedVector3Array, winding: PackedVector3Array, scale_value: float) -> void:
	for index in range(1, winding.size() - 1):
		target.append(transform_map_scaled(winding[0], scale_value))
		target.append(transform_map_scaled(winding[index], scale_value))
		target.append(transform_map_scaled(winding[index + 1], scale_value))

func build_overlays(scale_value: float) -> void:
	for marker in host.session.point_markers():
		if not host.session.marker_visible():
			continue
		var instance = MeshInstance3D.new()
		var mesh = SphereMesh.new()
		mesh.radius = 0.15
		mesh.height = 0.3
		instance.mesh = mesh
		instance.position = transform_map_scaled(marker.origin, scale_value)
		var material = StandardMaterial3D.new()
		material.albedo_color = Color("ffb657") if host.session.points.has(marker.id) else Color("83dfbd")
		instance.material_override = material
		overlays.add_child(instance)
	var brush_triangles := PackedVector3Array()
	var face_triangles := PackedVector3Array()
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
				append_face_triangles(face_triangles, face.winding, scale_value)
	add_selection_overlay("SelectedBrushFill", brush_triangles, Color(1.0, 0.48, 0.14, 0.14), 1)
	add_selection_overlay("SelectedFaceFill", face_triangles, Color(0.16, 0.5, 1.0, 0.38), 2)
	if host.tool in ["Face", "Edge", "Vertex"]:
		var handle_material = StandardMaterial3D.new()
		handle_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		handle_material.albedo_color = Color("ffb657")
		var selected_handle_material = StandardMaterial3D.new()
		selected_handle_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		selected_handle_material.albedo_color = Color("ffe6a6")
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
				var selected: bool = host.session.components.any(func(component):
					return component.brush_id == id and component.kind == host.tool.to_lower() and component.index == index and host.session.component_valid(component, brush))
				var handle = MeshInstance3D.new()
				var handle_mesh = SphereMesh.new()
				handle_mesh.radius = 0.1
				handle_mesh.height = 0.2
				handle.mesh = handle_mesh
				handle.position = transform_map_scaled(position, scale_value)
				handle.material_override = selected_handle_material if selected else handle_material
				overlays.add_child(handle)
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
		overlays.add_child(instance)
	rebuild_cut_overlay()

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
	for point in host.cut_points:
		var marker := MeshInstance3D.new()
		var marker_mesh := SphereMesh.new()
		marker_mesh.radius = 0.09
		marker_mesh.height = 0.18
		marker.mesh = marker_mesh
		marker.position = transform_map(point)
		marker.material_override = material
		root.add_child(marker)
	var plane: Array[Vector3] = host.cut_plane(-1, camera_map_direction())
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
			host.add_cut_point(cut_hit.position.snapped(Vector3.ONE * host.session.grid))
			host.preview_clip(false, -1, camera_map_direction(), self)
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
			start_fly()
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
		elif host.route_key(event, host.active_graph):
			accept_event()

func face_hit(position: Vector2) -> Dictionary:
	var scale_value := map_scale()
	var ray := camera.project_ray_origin(position)
	var direction := camera.project_ray_normal(position)
	var hits: Array = host.session.visible_ray_hits(preview_to_map(ray, scale_value), preview_direction_to_map(direction), 1e30)
	return hits[0] if not hits.is_empty() else {}

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
			host.session.changed.emit()
		else:
			ctrl_gesture = "click"
	else:
		ctrl_gesture = "paint_pending"
		ctrl_paint_select = not host.session.components.has(component)
		if host.session.selected.is_empty():
			apply_pick(component.brush_id, 0, component.index, false, false, true)

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
	var key := "%d:%d" % [component.brush_id, component.index]
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
	host.session.components = components.filter(func(item): return host.session.component_valid(item, host.session.brush(item.brush_id)))
	host.session.changed.emit()

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
		apply_pick(component.get("brush_id", 0), 0, component.get("index", -1), false, false, true)
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
	for hit in host.session.visible_ray_hits(map_ray, preview_direction_to_map(direction), max_distance):
		if hit.distance >= nearest:
			continue
		nearest = hit.distance
		id = hit.brush_id
		point_id = 0
		face_index = hit.face_index
		break
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
		if not ids.has(id):
			ids.append(id)
		host.session.select(ids)
		var component = {"brush_id": id, "kind": "face", "index": face_index, "topology_revision": host.session.brush(id).topology_revision}
		var existing := components.find(component)
		if additive and existing >= 0:
			components.remove_at(existing)
		else:
			components.append(component)
		host.session.components = components.filter(func(item): return host.session.component_valid(item, host.session.brush(item.brush_id)))
		host.session.changed.emit()
		return
	var ids = host.session.selected.duplicate() if additive else PackedInt64Array()
	if id:
		if ids.has(id):
			if not paint:
				ids.remove_at(ids.find(id))
		else:
			ids.append(id)
	host.session.select(ids)

func start_fly() -> void:
	cancel_gesture()
	flying = true
	crosshair.show()
	selection_painting = false
	held.clear()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	update_hint()

func stop_fly() -> void:
	cancel_gesture()
	if flying:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	flying = false
	if crosshair != null:
		crosshair.hide()
	selection_painting = false
	held.clear()
	update_hint()

func _input(event: InputEvent) -> void:
	if not flying:
		return
	if event is InputEventMouseButton:
		if handle_camera_wheel(event):
			get_viewport().set_input_as_handled()
			return
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			stop_fly()
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
		yaw -= event.relative.x * 0.003
		pitch = clampf(pitch - event.relative.y * 0.003, -1.55, 1.55)
		camera.rotation = Vector3(pitch, yaw, 0)
		if selection_painting:
			if event.shift_pressed:
				pick_crosshair(true, true)
			else:
				selection_painting = false
		orbit_target = camera.position - camera.global_basis.z * orbit_distance
	get_viewport().set_input_as_handled()

func _process(dt: float) -> void:
	update_hint()
	lighting_sync_delay -= dt
	if lighting_sync_delay <= 0:
		lighting_sync_delay = 0.25
		sync_scene_lighting()
	if flying:
		var direction = Vector3(float(held.get(KEY_D, false)) - float(held.get(KEY_A, false)),
			float(held.get(KEY_E, false)) - float(held.get(KEY_Q, false)),
			float(held.get(KEY_S, false)) - float(held.get(KEY_W, false)))
		camera.position += camera.basis * direction.normalized() * dt * fly_speed * (FAST_FLY_FACTOR if held.get(KEY_SHIFT, false) else 1.0)
		orbit_target = camera.position - camera.global_basis.z * orbit_distance
	sync_camera_marker()
	update_orientation_gizmo()

func _notification(what: int) -> void:
	if what in [NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_WM_WINDOW_FOCUS_OUT, NOTIFICATION_EXIT_TREE]:
		cancel_interaction()
