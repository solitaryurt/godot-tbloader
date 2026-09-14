@tool
extends Control

signal camera_moved(map_position: Vector3, map_direction: Vector3)

var host: Control
var viewport: SubViewport
var camera: Camera3D
var geometry: Node3D
var map_geometry: Node3D
var overlays: Node3D
var grid_move_preview: Node3D
var grid_move_preview_key = ""
var preview_lights: Node3D
var flying = false
var held: Dictionary = {}
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
var marker_transform := Transform3D()
var marker_scale = 0.0
const CHUNK_TRIANGLES = 2048
const CHUNK_SIZE = 64.0

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
	viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	container.add_child(viewport)
	geometry = Node3D.new()
	viewport.add_child(geometry)
	map_geometry = Node3D.new()
	geometry.add_child(map_geometry)
	overlays = Node3D.new()
	geometry.add_child(overlays)
	grid_move_preview = Node3D.new()
	viewport.add_child(grid_move_preview)
	camera = Camera3D.new()
	viewport.add_child(camera)
	camera.position = Vector3(8, 7, 12)
	camera.rotation = Vector3(pitch, yaw, 0)
	camera.far = 10000
	camera.current = true
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
	hint.text = " Camera • LMB select • Shift+LMB multi-select • RMB fly"
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hint)
	var crosshair_center = CenterContainer.new()
	crosshair_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	crosshair_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(crosshair_center)
	crosshair = Control.new()
	crosshair.custom_minimum_size = Vector2(22, 22)
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	crosshair_center.add_child(crosshair)
	var crosshair_color = Color(1.0, 0.88, 0.63, 0.9)
	for rect in [Rect2(0, 10, 8, 2), Rect2(14, 10, 8, 2), Rect2(10, 0, 2, 8), Rect2(10, 14, 2, 8)]:
		var segment = ColorRect.new()
		segment.position = rect.position
		segment.size = rect.size
		segment.color = crosshair_color
		segment.mouse_filter = Control.MOUSE_FILTER_IGNORE
		crosshair.add_child(segment)
	var frame_button = Button.new()
	frame_button.text = "Frame"
	frame_button.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	frame_button.position.x = -70
	frame_button.pressed.connect(frame_selection)
	add_child(frame_button)
	focus_exited.connect(stop_fly)
	visibility_changed.connect(func():
		if not is_visible_in_tree():
			stop_fly())

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
	camera.position = center + Vector3(1, 0.8, 1.2).normalized() * maxf(bounds.size.length() * 1.4, 2)
	camera.look_at(center)
	pitch = camera.rotation.x
	yaw = camera.rotation.y

func refresh() -> void:
	if geometry == null:
		return
	clear_grid_move_preview()
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

func preview_grid_move(delta: Vector3) -> void:
	if grid_move_preview == null or host.session.selected.is_empty():
		clear_grid_move_preview()
		return
	var scale_value := map_scale()
	var key := "%d:%d:%s:%s" % [host.session.document.get_instance_id(),
		host.session.document.get_revision(), str(host.session.selected), scale_value]
	if key != grid_move_preview_key:
		for child in grid_move_preview.get_children():
			grid_move_preview.remove_child(child)
			child.queue_free()
		var vertices := PackedVector3Array()
		var normals := PackedVector3Array()
		for id in host.session.selected:
			var brush: Dictionary = host.session.brush(id)
			if not host.session.brush_visible(brush):
				continue
			for face in brush.faces:
				var winding: PackedVector3Array = face.winding
				for i in range(1, winding.size() - 1):
					for point in [winding[0], winding[i], winding[i + 1]]:
						vertices.append(transform_map_scaled(point, scale_value))
						normals.append(preview_direction_to_map(face.normal))
		if not vertices.is_empty():
			var arrays: Array = []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = vertices
			arrays[Mesh.ARRAY_NORMAL] = normals
			var mesh := ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			var instance := MeshInstance3D.new()
			instance.mesh = mesh
			var material := StandardMaterial3D.new()
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			material.albedo_color = Color(1.0, 0.71, 0.34, 0.62)
			instance.material_override = material
			grid_move_preview.add_child(instance)
		grid_move_preview_key = key
	grid_move_preview.position = transform_map_scaled(delta, scale_value)
	grid_move_preview.visible = true

func clear_grid_move_preview() -> void:
	if grid_move_preview != null:
		grid_move_preview.visible = false
		grid_move_preview.position = Vector3.ZERO

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
	if host.tool in ["Face", "Edge"]:
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
			var count: int = brush.faces.size() if host.tool == "Face" else brush.edge_vertex_indices.size() / 2
			for index in count:
				var position: Vector3
				if host.tool == "Face":
					if host.session.material_filtered(brush.faces[index].texture):
						continue
					position = brush.faces[index].center
				else:
					var edge: int = index * 2
					position = (brush.vertices[brush.edge_vertex_indices[edge]] + brush.vertices[brush.edge_vertex_indices[edge + 1]]) * 0.5
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

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		grab_focus()
		if event.button_index == MOUSE_BUTTON_RIGHT:
			start_fly()
			accept_event()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			pick_crosshair(event.shift_pressed)
			accept_event()
	elif event is InputEventKey and host.route_key(event, host.active_graph):
		accept_event()

func pick_crosshair(additive: bool) -> void:
	pick(size * 0.5, additive)

func pick(position: Vector2, additive: bool) -> void:
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
	apply_pick(id, point_id, face_index, additive)

func apply_pick(id: int, point_id: int, face_index: int, additive: bool) -> void:
	if point_id:
		host.session.select(PackedInt64Array(), PackedInt64Array([point_id]))
		return
	if host.tool == "Face":
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
			ids.remove_at(ids.find(id))
		else:
			ids.append(id)
	host.session.select(ids)

func start_fly() -> void:
	flying = true
	held.clear()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	hint.text = " FLY • WASD / Q E • Shift fast • Esc / RMB release"

func stop_fly() -> void:
	if flying:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	flying = false
	held.clear()
	if hint != null:
		hint.text = " Camera • LMB select • Shift+LMB multi-select • RMB fly"

func _input(event: InputEvent) -> void:
	if not flying:
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			stop_fly()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			pick_crosshair(event.shift_pressed)
	elif event is InputEventKey:
		if event.keycode == KEY_ESCAPE:
			stop_fly()
		else:
			held[event.physical_keycode if event.physical_keycode else event.keycode] = event.pressed
	elif event is InputEventMouseMotion:
		yaw -= event.relative.x * 0.003
		pitch = clampf(pitch - event.relative.y * 0.003, -1.55, 1.55)
		camera.rotation = Vector3(pitch, yaw, 0)
	get_viewport().set_input_as_handled()

func _process(dt: float) -> void:
	lighting_sync_delay -= dt
	if lighting_sync_delay <= 0:
		lighting_sync_delay = 0.25
		sync_scene_lighting()
	if flying:
		var direction = Vector3(float(held.get(KEY_D, false)) - float(held.get(KEY_A, false)),
			float(held.get(KEY_E, false)) - float(held.get(KEY_Q, false)),
			float(held.get(KEY_S, false)) - float(held.get(KEY_W, false)))
		camera.position += camera.basis * direction.normalized() * dt * (30 if held.get(KEY_SHIFT, false) else 8)
	sync_camera_marker()

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_EXIT_TREE:
		stop_fly()
