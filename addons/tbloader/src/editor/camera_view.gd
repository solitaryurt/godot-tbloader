@tool
extends Control

var host: Control
var viewport: SubViewport
var camera: Camera3D
var geometry: Node3D
var flying = false
var held: Dictionary = {}
var pitch = -0.4
var yaw = 0.65
var triangle_count = 0
var hint: Label

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
	var light = DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, -35, 0)
	viewport.add_child(light)
	hint = Label.new()
	hint.text = " Camera • RMB fly • WASD / Q E • Shift fast"
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hint)
	focus_exited.connect(stop_fly)
	visibility_changed.connect(func():
		if not is_visible_in_tree():
			stop_fly())

func transform_map(point: Vector3) -> Vector3:
	var scale_value = 38.0
	var loader = host.session.loader.get_ref()
	if is_instance_valid(loader):
		scale_value = maxf(loader.map_inverse_scale, 0.001)
	return Vector3(point.y, point.z, point.x) / scale_value

func refresh() -> void:
	if geometry == null:
		return
	for child in geometry.get_children():
		geometry.remove_child(child)
		child.queue_free()
	triangle_count = 0
	for group in host.session.document.get_preview_data():
		var vertices = PackedVector3Array()
		var normals = PackedVector3Array()
		var uvs = PackedVector2Array()
		var colors = PackedColorArray()
		for triangle in group.triangle_brush_ids.size():
			var id: int = group.triangle_brush_ids[triangle]
			if host.session.hidden.has(id):
				continue
			triangle_count += 1
			for corner in 3:
				var index: int = group.indices[triangle * 3 + corner]
				vertices.append(transform_map(group.vertices[index]))
				var normal: Vector3 = group.normals[index]
				normals.append(Vector3(normal.y, normal.z, normal.x))
				uvs.append(group.uvs[index])
				colors.append(Color(1, 0.65, 0.25) if host.session.selected.has(id) else Color.WHITE)
		if vertices.is_empty():
			continue
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_COLOR] = colors
		var mesh = ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var instance = MeshInstance3D.new()
		instance.mesh = mesh
		instance.material_override = host.preview_material(group.texture)
		geometry.add_child(instance)
	for marker in host.session.point_markers():
		var instance = MeshInstance3D.new()
		var mesh = SphereMesh.new()
		mesh.radius = 0.15
		mesh.height = 0.3
		instance.mesh = mesh
		instance.position = transform_map(marker.origin)
		var material = StandardMaterial3D.new()
		material.albedo_color = Color("ffb657") if host.session.points.has(marker.id) else Color("83dfbd")
		instance.material_override = material
		geometry.add_child(instance)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		grab_focus()
		if event.button_index == MOUSE_BUTTON_RIGHT:
			start_fly()
			accept_event()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			pick(event.position, event.shift_pressed)
			accept_event()
	elif event is InputEventKey and host.route_key(event, host.active_graph):
		accept_event()

func pick(position: Vector2, additive: bool) -> void:
	var nearest = INF
	var point_id = 0
	for marker in host.session.point_markers():
		var p = transform_map(marker.origin)
		if not camera.is_position_behind(p) and camera.unproject_position(p).distance_to(position) < 14:
			var distance = camera.global_position.distance_to(p)
			if distance < nearest:
				nearest = distance
				point_id = marker.id
	if point_id:
		host.session.select(PackedInt64Array(), PackedInt64Array([point_id]))
		return
	var ray = camera.project_ray_origin(position)
	var direction = camera.project_ray_normal(position)
	var id = 0
	var face_index = -1
	for group in host.session.document.get_preview_data():
		for triangle in group.triangle_brush_ids.size():
			var brush_id: int = group.triangle_brush_ids[triangle]
			if host.session.hidden.has(brush_id):
				continue
			var p = transform_map(group.vertices[group.indices[triangle * 3]])
			var q = transform_map(group.vertices[group.indices[triangle * 3 + 1]])
			var r = transform_map(group.vertices[group.indices[triangle * 3 + 2]])
			var intersection = Geometry3D.ray_intersects_triangle(ray, direction, p, q, r)
			if intersection != null and ray.distance_to(intersection) < nearest:
				nearest = ray.distance_to(intersection)
				id = brush_id
				face_index = group.triangle_face_indices[triangle]
	var ids = host.session.selected.duplicate() if additive else PackedInt64Array()
	if id:
		if ids.has(id):
			ids.remove_at(ids.find(id))
		else:
			ids.append(id)
	host.session.select(ids)
	if id and host.tool == "Face":
		host.session.components = [{"brush_id": id, "kind": "face", "index": face_index, "topology_revision": host.session.brush(id).topology_revision}]
		host.session.changed.emit()

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
		hint.text = " Camera • RMB fly • WASD / Q E • Shift fast"

func _input(event: InputEvent) -> void:
	if not flying:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		stop_fly()
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
	if not flying:
		return
	var direction = Vector3(float(held.get(KEY_D, false)) - float(held.get(KEY_A, false)),
		float(held.get(KEY_E, false)) - float(held.get(KEY_Q, false)),
		float(held.get(KEY_S, false)) - float(held.get(KEY_W, false)))
	camera.position += camera.basis * direction.normalized() * dt * (30 if held.get(KEY_SHIFT, false) else 8)

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_EXIT_TREE:
		stop_fly()
