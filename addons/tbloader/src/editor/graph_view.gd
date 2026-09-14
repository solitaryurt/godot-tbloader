@tool
extends Control

const OrientationGizmo = preload("res://addons/tbloader/src/editor/orientation_gizmo.gd")

var host: Control
var orientation = 2 # hidden axis: XY=2, XZ=1, YZ=0
var origin = Vector3.ZERO
var zoom = 1.0
var view_states: Dictionary = {}
var gesture = ""
var start = Vector2.ZERO
var cursor = Vector2.ZERO
var anchor = Vector3.ZERO
var delta = Vector3.ZERO
var resize_face: Dictionary = {}
var drag_component: Dictionary = {}
var clip_points: Array[Vector3]:
	get:
		return host.cut_points if is_instance_valid(host) else []
	set(value):
		if is_instance_valid(host):
			host.set_cut_points(value)
var clip_flip: bool:
	get:
		return host.cut_flip if is_instance_valid(host) else false
	set(value):
		if is_instance_valid(host):
			host.cut_flip = value
var shift_drag = false
var ctrl_drag = false
var rotation_pivot = Vector3.ZERO
var rotation_start_angle = 0.0
var rotation_angle = 0.0
var camera_position = Vector3.ZERO
var camera_direction = Vector3.ZERO
var camera_pose_valid = false
var dense_edge_cache_key = ""
var dense_unselected_edges := PackedVector2Array()
var dense_selected_edges := PackedVector2Array()
var orientation_gizmo: Control
var camera_views: Array[WeakRef] = []
const DENSE_EDGE_THRESHOLD = 1024

func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(240, 180)
	clip_contents = true
	tooltip_text = "Components: Shift-click adds/toggles; Alt-click cycles overlapping handles. Drag a selected handle to move the group; hold Shift during motion to constrain an axis."
	orientation_gizmo = OrientationGizmo.new()
	orientation_gizmo.name = "GridOrientation"
	orientation_gizmo.signed_axes = false
	orientation_gizmo.gizmo_size = 36.0
	orientation_gizmo.hide()
	orientation_gizmo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	orientation_gizmo.axis_selected.connect(func(axis: int, _positive: bool):
		host.active_graph = self
		grab_focus()
		set_orientation(axis))
	add_child(orientation_gizmo)
	var frame_button := compact_frame_button()
	frame_button.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	frame_button.position = Vector2(-72, 4)
	add_child(frame_button)
	update_orientation_gizmo()
	focus_exited.connect(cancel)
	focus_entered.connect(func(): host.active_graph = self; host.refresh_status(); queue_redraw())

func _notification(what: int) -> void:
	if what in [NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_WM_WINDOW_FOCUS_OUT]:
		cancel()

func axes() -> Vector2i:
	return Vector2i(1 if orientation == 0 else 0, 1 if orientation == 2 else 2)

func project(point: Vector3) -> Vector2:
	var a = axes()
	return size * 0.5 + Vector2(point[a.x] - origin[a.x], origin[a.y] - point[a.y]) * zoom

func set_camera_pose(position: Vector3, direction: Vector3) -> void:
	if camera_pose_valid and camera_position.is_equal_approx(position) and camera_direction.is_equal_approx(direction):
		return
	camera_position = position
	camera_direction = direction
	camera_pose_valid = true
	queue_redraw()

func set_camera_views(views: Array) -> void:
	camera_views.clear()
	for view in views:
		if is_instance_valid(view):
			camera_views.append(weakref(view))

func current_camera_views() -> Array:
	var result: Array = []
	for reference in camera_views:
		var view = reference.get_ref()
		if is_instance_valid(view):
			result.append(view)
	if not result.is_empty() or not is_instance_valid(host):
		return result
	# Legacy coordinators do not provide a collection yet. Discover every
	# compatible camera under this host rather than assuming one named instance.
	for candidate in host.find_children("*", "Control", true, false):
		if candidate != self and candidate.has_method("preview_grid_move") and candidate.has_method("clear_grid_move_preview"):
			result.append(candidate)
			camera_views.append(weakref(candidate))
	return result

func compact_frame_button() -> Button:
	var button := Button.new()
	button.name = "FrameSelection"
	button.custom_minimum_size = Vector2(28, 28)
	button.size = Vector2(28, 28)
	button.tooltip_text = "Frame selection"
	button.accessibility_name = "Frame selection"
	button.theme_type_variation = "FlatButton"
	var frame_icon: Texture2D = host.custom_icon("frame_selection") if is_instance_valid(host) else null
	button.icon = frame_icon
	button.text = ""
	button.pressed.connect(frame_selection)
	return button

func projected_camera_direction(direction: Vector3 = camera_direction) -> Vector2:
	var a := axes()
	return Vector2(direction[a.x], -direction[a.y]).normalized()

func unproject(point: Vector2) -> Vector3:
	var a = axes()
	var world = origin
	world[a.x] += (point.x - size.x * 0.5) / zoom
	world[a.y] -= (point.y - size.y * 0.5) / zoom
	world[orientation] = host.session.workzone.position[orientation]
	return world

func snap_point(point: Vector3) -> Vector3:
	return point.snapped(Vector3.ONE * host.session.grid)

func cycle_orientation() -> void:
	set_orientation({2: 1, 1: 0, 0: 2}[orientation])

func set_orientation(value: int) -> void:
	if value == orientation or value < 0 or value > 2:
		return
	cancel()
	view_states[orientation] = {"origin": origin, "zoom": zoom}
	orientation = value
	var state: Dictionary = view_states.get(orientation, {"origin": Vector3.ZERO, "zoom": 1.0})
	origin = state.origin
	zoom = state.zoom
	host.clear_cut_state()
	update_orientation_gizmo()
	queue_redraw()
	host.refresh_status()

func update_orientation_gizmo() -> void:
	if orientation_gizmo == null:
		return
	match orientation:
		2:
			orientation_gizmo.set_view_axes([Vector3.RIGHT, Vector3.UP, Vector3.BACK])
		1:
			orientation_gizmo.set_view_axes([Vector3.RIGHT, Vector3.BACK, Vector3.UP])
		0:
			orientation_gizmo.set_view_axes([Vector3.BACK, Vector3.RIGHT, Vector3.UP])

func zoom_at(position: Vector2, factor: float) -> void:
	var before = unproject(position)
	zoom = clampf(zoom * factor, 0.02, 64.0)
	var offset = before - unproject(position)
	offset[orientation] = 0
	origin += offset
	queue_redraw()

func frame_selection() -> void:
	var selected_items: Array = []
	var visible_items: Array = []
	for brush in host.session.draw_data():
		if not host.session.brush_visible(brush):
			continue
		visible_items.append([brush.aabb_min, brush.aabb_max])
		if host.session.selected.has(brush.id):
			selected_items.append([brush.aabb_min, brush.aabb_max])
	if host.session.marker_visible():
		for marker in host.session.point_markers():
			visible_items.append([marker.origin, marker.origin])
			if host.session.points.has(marker.id):
				selected_items.append([marker.origin, marker.origin])
	var items: Array = selected_items if not selected_items.is_empty() else visible_items
	if items.is_empty():
		return
	var a := axes()
	var low := Vector2(INF, INF)
	var high := Vector2(-INF, -INF)
	for item in items:
		for point in item:
			var projected := Vector2(point[a.x], point[a.y])
			low = low.min(projected)
			high = high.max(projected)
	var center := (low + high) * 0.5
	origin[a.x] = center.x
	origin[a.y] = center.y
	var extent := high - low
	var padding := 40.0
	var available := (size - Vector2.ONE * padding * 2.0).max(Vector2.ONE)
	var minimum_extent := maxf(host.session.grid * 4.0, 1.0)
	zoom = clampf(minf(available.x / maxf(extent.x, minimum_extent), available.y / maxf(extent.y, minimum_extent)), 0.02, 64.0)
	view_states[orientation] = {"origin": origin, "zoom": zoom}
	queue_redraw()

func cancel() -> void:
	gesture = ""
	delta = Vector3.ZERO
	rotation_angle = 0.0
	resize_face.clear()
	drag_component.clear()
	if is_instance_valid(host):
		host.clear_mutation_preview(self)
	queue_redraw()

func preview_result(result: Dictionary) -> void:
	if is_instance_valid(host):
		host.broadcast_mutation_preview(result, self)

func update_exact_preview() -> void:
	if host.session.selected.is_empty():
		host.clear_mutation_preview(self)
		return
	match gesture:
		"move":
			preview_result(host.session.document.preview_translate_brushes(host.session.selected, delta))
		"rotate":
			preview_result(host.session.document.preview_rotate_brushes(host.session.selected, rotation_pivot, orientation, rotation_angle))
		"resize":
			preview_result(host.session.document.preview_translate_components([resize_face], delta))
		"component":
			preview_result(host.session.document.preview_translate_components(host.session.components, delta))

func hit_brush(position: Vector2, prefer_selected := false) -> int:
	var p := unproject(position - Vector2.ONE * 6)
	var q := unproject(position + Vector2.ONE * 6)
	var candidates: PackedInt64Array = host.session.document.query_brushes_2d(orientation, p.min(q), p.max(q))
	var first_hit := 0
	for candidate in range(candidates.size() - 1, -1, -1):
		var brush: Dictionary = host.session.brush(candidates[candidate])
		if not host.session.brush_visible(brush):
			continue
		var bounds := Rect2(project(brush.aabb_min), project(brush.aabb_max) - project(brush.aabb_min)).abs().grow(6)
		if not bounds.has_point(position):
			continue
		var hit := false
		for face in brush.faces:
			var polygon = PackedVector2Array()
			for point in face.winding:
				polygon.append(project(point))
			if polygon.size() >= 3 and Geometry2D.is_point_in_polygon(position, polygon):
				hit = true
				break
		if not hit:
			for i in range(0, brush.edges.size(), 2):
				if position.distance_to(Geometry2D.get_closest_point_to_segment(position,
						project(brush.edges[i]), project(brush.edges[i + 1]))) < 6:
					hit = true
					break
		if hit:
			if prefer_selected and host.session.selected.has(brush.id):
				return brush.id
			if first_hit == 0:
				first_hit = brush.id
	return first_hit

func hit_point(position: Vector2) -> int:
	if not host.session.marker_visible():
		return 0
	for marker in host.session.point_markers():
		if project(marker.origin).distance_to(position) <= 12:
			return marker.id
	return 0

func selection_center() -> Vector3:
	var bounds: AABB
	var first = true
	for id in host.session.selected:
		var brush: Dictionary = host.session.brush(id)
		if brush.is_empty():
			continue
		var item = AABB(brush.aabb_min, brush.aabb_max - brush.aabb_min)
		bounds = item if first else bounds.merge(item)
		first = false
	return bounds.get_center() if not first else Vector3.ZERO

func rotate_point(point: Vector3, angle: float) -> Vector3:
	var a = axes()
	var relative = point - rotation_pivot
	var cosine = cos(angle)
	var sine = sin(angle)
	var result = point
	result[a.x] = rotation_pivot[a.x] + relative[a.x] * cosine - relative[a.y] * sine
	result[a.y] = rotation_pivot[a.y] + relative[a.x] * sine + relative[a.y] * cosine
	return result

func silhouette(position: Vector2) -> Dictionary:
	for id in host.session.selected:
		if host.session.hidden.has(id):
			continue
		var brush: Dictionary = host.session.brush(id)
		for face in brush.faces:
			if absf(face.normal[orientation]) > 0.001:
				continue
			for i in face.winding.size():
				var p = project(face.winding[i])
				var q = project(face.winding[(i + 1) % face.winding.size()])
				if p.distance_to(q) > 1 and position.distance_to(Geometry2D.get_closest_point_to_segment(position, p, q)) < 8:
					return {"brush_id": id, "index": face.index, "kind": "face", "topology_revision": brush.topology_revision}
	return {}

func pick_component(position: Vector2, mode: String, cycle = false) -> Dictionary:
	var hits: Array = []
	var face_bodies: Array = []
	for id in host.session.selected:
		if host.session.hidden.has(id):
			continue
		var brush: Dictionary = host.session.brush(id)
		if mode == "Face":
			for face in brush.faces:
				var component = {"brush_id": id, "index": face.index, "kind": "face", "topology_revision": brush.topology_revision}
				var polygon = PackedVector2Array()
				for p in face.winding:
					polygon.append(project(p))
				if absf(face.normal[orientation]) <= 0.001:
					for i in polygon.size():
						var p = polygon[i]
						var q = polygon[(i + 1) % polygon.size()]
						if p.distance_to(q) > 1 and position.distance_to(Geometry2D.get_closest_point_to_segment(position, p, q)) < 8:
							hits.append(component)
							break
				elif polygon.size() >= 3 and Geometry2D.is_point_in_polygon(position, polygon):
					face_bodies.append(component)
		else:
			var count: int = brush.vertices.size() if mode == "Vertex" else brush.edge_vertex_indices.size() / 2
			for i in count:
				var p: Vector3 = brush.vertices[i] if mode == "Vertex" else (brush.vertices[brush.edge_vertex_indices[i * 2]] + brush.vertices[brush.edge_vertex_indices[i * 2 + 1]]) * 0.5
				if project(p).distance_to(position) < 12:
					hits.append({"brush_id": id, "index": i, "kind": mode.to_lower(), "topology_revision": brush.topology_revision})
	hits.append_array(face_bodies)
	if hits.is_empty():
		return {}
	# Alt cycles coincident projected handles, including the far side of a brush.
	if cycle and not host.session.components.is_empty():
		var previous = hits.find(host.session.components.back())
		if previous >= 0:
			return hits[(previous + 1) % hits.size()]
	# Hull rebuilds can reorder coincident front/back handles. An ordinary grab
	# must keep the selected handle's depth; only Alt explicitly cycles it.
	if not cycle and mode in ["Vertex", "Edge"]:
		for hit in hits:
			if host.session.components.has(hit):
				return hit
	return hits[0]

func component_position(component: Dictionary, brush: Dictionary) -> Vector3:
	if component.kind == "face":
		return brush.faces[component.index].center
	if component.kind == "vertex":
		return brush.vertices[component.index]
	return (brush.vertices[brush.edge_vertex_indices[component.index * 2]] + brush.vertices[brush.edge_vertex_indices[component.index * 2 + 1]]) * 0.5

func map_edge_point(point: Vector3) -> Vector2:
	var a := axes()
	return Vector2(point[a.x], point[a.y])

func current_dense_edge_key() -> String:
	var hidden_ids: Array = host.session.hidden.keys()
	hidden_ids.sort()
	return "%d:%d:%d:%d:%s:%s" % [host.session.document.get_instance_id(),
		host.session.document.get_revision(), host.session.visibility_generation, orientation,
		str(hidden_ids), str(host.session.selected)]

func rebuild_dense_edge_cache() -> void:
	dense_unselected_edges.clear()
	dense_selected_edges.clear()
	for brush in host.session.draw_data():
		if not host.session.brush_visible(brush):
			continue
		for i in range(0, brush.edges.size(), 2):
			if host.session.selected.has(brush.id):
				dense_selected_edges.append(map_edge_point(brush.edges[i]))
				dense_selected_edges.append(map_edge_point(brush.edges[i + 1]))
			else:
				dense_unselected_edges.append(map_edge_point(brush.edges[i]))
				dense_unselected_edges.append(map_edge_point(brush.edges[i + 1]))
	dense_edge_cache_key = current_dense_edge_key()

func draw_dense_edges(dynamic_selection: bool) -> void:
	var key := current_dense_edge_key()
	if dense_edge_cache_key != key:
		rebuild_dense_edge_cache()
	var a := axes()
	var canvas_origin: Vector2 = size * 0.5 + Vector2(-origin[a.x], origin[a.y]) * zoom
	draw_set_transform(canvas_origin, 0.0, Vector2(zoom, -zoom))
	if not dense_unselected_edges.is_empty():
		draw_multiline(dense_unselected_edges, Color("9eb2c7"), 1.0 / zoom, true)
	if not dynamic_selection and not dense_selected_edges.is_empty():
		draw_multiline(dense_selected_edges, Color("ffb657"), 2.0 / zoom, true)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func apply_dense_translation(movement: Vector3) -> void:
	if dense_edge_cache_key.is_empty():
		return
	var projected := map_edge_point(movement)
	for i in dense_selected_edges.size():
		dense_selected_edges[i] += projected
	dense_edge_cache_key = current_dense_edge_key()

func _gui_input(event: InputEvent) -> void:
	if event is InputEventKey:
		if host.route_key(event, self):
			accept_event()
		return
	if event is InputEventMouseButton:
		# Window clears `focused` before Viewport drops mouse focus and sends
		# synthetic releases, BEFORE this Control receives FOCUS_OUT. Do not commit.
		# Viewport::_drop_mouse_focus tags these with DEVICE_ID_INTERNAL (-1).
		if not event.pressed and (event.device == -1 or (DisplayServer.get_name() != "headless" and not get_window().has_focus())):
			cancel()
			return
		if event.pressed:
			grab_focus()
			host.active_graph = self
			host.refresh_status()
		if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] and event.pressed:
			zoom_at(event.position, 1.25 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 0.8)
			accept_event()
			return
		if event.pressed and gesture != "":
			return
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				gesture = "box" if event.shift_pressed else "pan"
				start = event.position
				cursor = start
			elif gesture == "box":
				box_select(event.position)
				cancel()
			else:
				cancel()
			accept_event()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				begin_left(event)
			else:
				finish_left(event)
			accept_event()
	elif event is InputEventMouseMotion and gesture != "":
		cursor = event.position
		shift_drag = event.shift_pressed
		ctrl_drag = event.ctrl_pressed
		if gesture == "paint_select":
			if event.shift_pressed:
				paint_select(cursor)
			else:
				cancel()
			accept_event()
			return
		if gesture == "pan":
			var a = axes()
			origin[a.x] -= event.relative.x / zoom
			origin[a.y] += event.relative.y / zoom
		elif gesture == "rotate":
			var center = project(rotation_pivot)
			if cursor.distance_to(center) > 0.001:
				rotation_angle = snappedf(rotation_start_angle - (cursor - center).angle(), deg_to_rad(15.0))
		else:
			delta = snap_point(unproject(cursor) - anchor)
			delta[orientation] = 0
			var a = axes()
			if ctrl_drag and gesture == "move" and not host.session.selected.is_empty():
				var reference: Vector3 = host.session.workzone.position
				delta = snap_point(reference + unproject(cursor) - anchor) - reference
				delta[orientation] = 0
			if gesture in ["resize", "component"]:
				var component: Dictionary = resize_face if gesture == "resize" else drag_component
				var brush: Dictionary = host.session.brush(component.brush_id)
				if not host.session.component_valid(component, brush):
					cancel()
					return
				var reference := component_position(component, brush)
				delta = snap_point(reference + unproject(cursor) - anchor) - reference
				delta[orientation] = 0
			if shift_drag and gesture in ["move", "component", "resize"]:
				delta[a.y if absf(delta[a.x]) > absf(delta[a.y]) else a.x] = 0
		if gesture in ["move", "rotate", "resize", "component"]:
			update_exact_preview()
		queue_redraw()
		accept_event()

func begin_left(event: InputEventMouseButton) -> void:
	start = event.position
	cursor = start
	anchor = unproject(start)
	delta = Vector3.ZERO
	shift_drag = event.shift_pressed
	ctrl_drag = event.ctrl_pressed
	if host.tool == "Cut":
		host.add_cut_point(snap_point(anchor))
		host.preview_clip(false, orientation, Vector3.ZERO, self)
		return
	if host.tool == "Rotate":
		var id = hit_brush(start, not event.shift_pressed)
		if event.shift_pressed:
			var ids = host.session.selected.duplicate()
			if id and ids.has(id):
				ids.remove_at(ids.find(id))
			elif id:
				ids.append(id)
			host.session.select(ids)
			return
		if id and not host.session.selected.has(id):
			host.session.select(PackedInt64Array([id]))
		if not id:
			host.session.select(PackedInt64Array())
			return
		rotation_pivot = selection_center()
		var center = project(rotation_pivot)
		if start.distance_to(center) > 4:
			rotation_start_angle = (start - center).angle()
			gesture = "rotate"
		queue_redraw()
		return
	if (host.tool in ["Face", "Vertex", "Edge"] or event.ctrl_pressed) and not host.session.selected.is_empty():
		var component = pick_component(start, "Face" if event.ctrl_pressed else host.tool, event.alt_pressed)
		host.session.select_component(component, event.shift_pressed)
		if not component.is_empty() and not event.shift_pressed:
			drag_component = component.duplicate()
			gesture = "component"
		return
	var point_id = hit_point(start)
	var id = hit_brush(start, not event.shift_pressed)
	if event.shift_pressed:
		var ids = host.session.selected.duplicate()
		var points = host.session.points.duplicate()
		if point_id:
			if points.has(point_id):
				points.remove_at(points.find(point_id))
			else:
				points.append(point_id)
		elif id:
			if ids.has(id):
				ids.remove_at(ids.find(id))
			else:
				ids.append(id)
		host.session.select(ids, points)
		gesture = "paint_select"
		return
	if point_id:
		if not host.session.points.has(point_id):
			host.session.select(PackedInt64Array(), PackedInt64Array([point_id]))
		gesture = "move"
	elif host.session.selected.is_empty() and host.session.points.is_empty() and host.tool == "Brush":
		gesture = "create"
	else:
		resize_face = silhouette(start)
		if not resize_face.is_empty():
			gesture = "resize"
		elif host.session.selected.has(id):
			gesture = "move"
		else:
			host.session.select(PackedInt64Array([id]) if id else PackedInt64Array())
			gesture = "move" if id else ""

func paint_select(position: Vector2) -> void:
	var id = hit_brush(position)
	if not id or host.session.selected.has(id):
		return
	var ids = host.session.selected.duplicate()
	ids.append(id)
	host.session.select(ids, host.session.points)

func creation_bounds() -> AABB:
	var p = snap_point(anchor)
	var q = snap_point(unproject(cursor))
	var a = axes()
	if shift_drag or ctrl_drag:
		var extent = maxf(absf(q[a.x] - p[a.x]), absf(q[a.y] - p[a.y]))
		q[a.x] = p[a.x] + extent * (-1 if q[a.x] < p[a.x] else 1)
		q[a.y] = p[a.y] + extent * (-1 if q[a.y] < p[a.y] else 1)
	p[orientation] = snap_point(host.session.workzone.position)[orientation]
	q[orientation] = snap_point(host.session.workzone.end)[orientation]
	if q[orientation] <= p[orientation]:
		q[orientation] = p[orientation] + host.session.grid
	if ctrl_drag:
		q[orientation] = p[orientation] + absf(q[a.x] - p[a.x])
	return AABB(p.min(q), p.max(q) - p.min(q))

func finish_left(event: InputEventMouseButton) -> void:
	cursor = event.position
	var session = host.session
	if gesture == "create":
		var bounds = creation_bounds()
		if start.distance_to(cursor) > 4 and bounds.size.x > 0 and bounds.size.y > 0 and bounds.size.z > 0:
			session.transact("Create map brush", func():
				var r: Dictionary = session.document.create_cuboid(bounds.position, bounds.end, session.texture)
				if r.ok:
					session.select(PackedInt64Array([r.value]))
				return r)
		else:
			var id = hit_brush(cursor)
			session.select(PackedInt64Array([id]) if id else PackedInt64Array())
	elif gesture in ["move", "resize", "component"] and delta != Vector3.ZERO:
		var movement = delta
		if gesture == "move":
			var brush_only: bool = session.points.is_empty()
			var committed: bool = session.transact("Move map selection", func():
				var r: Dictionary = session.translate_brushes(session.selected, movement)
				if r.ok and not session.points.is_empty():
					r = session.document.translate_point_entities(session.points, movement)
				return r, "brush_translation" if brush_only else "")
			if committed and brush_only:
				host.apply_dense_translation(movement)
		elif gesture == "resize":
			var component = resize_face.duplicate()
			session.transact("Resize map face", func():
				return session.document.translate_face(component.brush_id, component.index, movement, component.topology_revision))
		else:
			session.transact("Move map components", func(): return session.move_components(movement))
	elif gesture == "rotate" and not is_zero_approx(rotation_angle):
		var angle = rotation_angle
		var pivot = rotation_pivot
		session.transact("Rotate map selection", func(): return session.document.rotate_brushes(session.selected, pivot, orientation, angle))
	cancel()

func box_select(end: Vector2) -> void:
	var rect = Rect2(start, end - start).abs()
	var ids = host.session.selected.duplicate()
	var point_ids = host.session.points.duplicate()
	var direction = end - start
	var add = direction.x >= 0 and direction.y <= 0
	var remove = direction.x <= 0 and direction.y >= 0
	var p := unproject(rect.position)
	var q := unproject(rect.end)
	for brush in host.session.visible_brushes_2d(orientation, p.min(q), p.max(q)):
		var contained = true
		for vertex in brush.vertices:
			if not rect.has_point(project(vertex)):
				contained = false
				break
		if contained:
			if ids.has(brush.id) and (remove or not add):
				ids.remove_at(ids.find(brush.id))
			elif not ids.has(brush.id) and not remove:
				ids.append(brush.id)
	for marker in host.session.point_markers():
		if rect.has_point(project(marker.origin)):
			if point_ids.has(marker.id) and (remove or not add):
				point_ids.remove_at(point_ids.find(marker.id))
			elif not point_ids.has(marker.id) and not remove:
				point_ids.append(marker.id)
	host.session.select(ids, point_ids)

func apply_clip(split: bool) -> void:
	host.apply_clip(split, orientation)

func draw_component_preview(component: Dictionary, movement: Vector3) -> void:
	var brush: Dictionary = host.session.brush(component.brush_id)
	if not host.session.component_valid(component, brush):
		return
	var color := Color("ffda8e")
	if component.kind == "face":
		var winding: PackedVector3Array = brush.faces[component.index].winding
		for i in winding.size():
			draw_line(project(winding[i] + movement), project(winding[(i + 1) % winding.size()] + movement), color, 2, true)
	elif component.kind == "edge":
		var p: Vector3 = brush.vertices[brush.edge_vertex_indices[component.index * 2]] + movement
		var q: Vector3 = brush.vertices[brush.edge_vertex_indices[component.index * 2 + 1]] + movement
		draw_line(project(p), project(q), color, 2, true)
		draw_circle(project((p + q) * 0.5), 5, Color("20252d"))
		draw_circle(project((p + q) * 0.5), 5, color, false, 2, true)
	else:
		draw_circle(project(brush.vertices[component.index] + movement), 5, Color("20252d"))
		draw_circle(project(brush.vertices[component.index] + movement), 5, color, false, 2, true)

func draw_manipulation_preview() -> void:
	var primary: Dictionary = resize_face if gesture == "resize" else drag_component
	var brush: Dictionary = host.session.brush(primary.get("brush_id", 0))
	if not host.session.component_valid(primary, brush):
		return
	var from := project(component_position(primary, brush))
	var to := project(component_position(primary, brush) + delta)
	draw_line(from, to, Color(1.0, 0.85, 0.56, 0.7), 1, true)
	draw_circle(to, 3, Color("ffda8e"))
	if gesture == "resize":
		draw_component_preview(resize_face, delta)
	else:
		for component in host.session.components:
			draw_component_preview(component, delta)

func draw_origin_compass() -> void:
	var center := project(Vector3.ZERO)
	var visible_axes := axes()
	var dimensions := [visible_axes.x, visible_axes.y]
	var directions := [Vector2.RIGHT, Vector2.UP]
	var font := get_theme_default_font()
	var font_size := 11
	for index in 2:
		var direction: Vector2 = directions[index]
		var axis: int = dimensions[index]
		var color: Color = OrientationGizmo.AXIS_COLORS[axis]
		draw_line(center, center + direction * 18.0, color, 2.0, true)
		var label: String = ["X", "Y", "Z"][axis]
		var label_position := center + direction * 23.0
		if direction == Vector2.RIGHT:
			label_position += Vector2(0, 4)
		else:
			label_position += Vector2(-3, 0)
		draw_string(font, label_position, label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)

func _draw() -> void:
	if host == null or host.session == null:
		return
	draw_rect(Rect2(Vector2.ZERO, size), Color("20252d"))
	var a = axes()
	var step: float = host.session.grid
	while step * zoom < 8:
		step *= 2
	var low = unproject(Vector2(0, size.y))
	var high = unproject(Vector2(size.x, 0))
	for axis in [a.x, a.y]:
		var v = floorf(low[axis] / step) * step
		while v <= high[axis]:
			var p = low
			var q = high
			p[axis] = v
			q[axis] = v
			var color = Color("303742") if not is_zero_approx(fmod(v, step * 8)) else Color("424c5b")
			if is_zero_approx(v):
				color = OrientationGizmo.AXIS_COLORS[axis].darkened(0.5)
			draw_line(project(p), project(q), color, 1.0, true)
			v += step
	draw_origin_compass()
	var visible_rect := Rect2(Vector2.ZERO, size).grow(10)
	var query_p := unproject(visible_rect.position)
	var query_q := unproject(visible_rect.end)
	var selected_ids: Dictionary = {}
	for id in host.session.selected:
		selected_ids[id] = true
	var candidate_ids: PackedInt64Array = host.session.document.query_brushes_2d(orientation, query_p.min(query_q), query_p.max(query_q))
	var dense_view := candidate_ids.size() > DENSE_EDGE_THRESHOLD
	var visible_brushes: Array = []
	var unselected_edges := PackedVector2Array()
	var selected_edges := PackedVector2Array()
	var dynamic_selected_edges := PackedVector2Array()
	var draw_brushes: Array = []
	if dense_view:
		for id in host.session.selected:
			var selected_brush: Dictionary = host.session.brush(id)
			if host.session.brush_visible(selected_brush):
				draw_brushes.append(selected_brush)
	else:
		for id in candidate_ids:
			var candidate: Dictionary = host.session.brush(id)
			if host.session.brush_visible(candidate):
				draw_brushes.append(candidate)
	for brush in draw_brushes:
		var projected_bounds := Rect2(project(brush.aabb_min), project(brush.aabb_max) - project(brush.aabb_min)).abs()
		if not dense_view and not visible_rect.intersects(projected_bounds):
			continue
		visible_brushes.append(brush)
		var selected: bool = selected_ids.has(brush.id)
		var offset = delta if selected and gesture == "move" else Vector3.ZERO
		for i in range(0, brush.edges.size(), 2):
			var p: Vector3 = brush.edges[i] + offset
			var q: Vector3 = brush.edges[i + 1] + offset
			if selected and gesture == "rotate":
				p = rotate_point(p, rotation_angle)
				q = rotate_point(q, rotation_angle)
			var projected_p := map_edge_point(p) if dense_view else project(p)
			var projected_q := map_edge_point(q) if dense_view else project(q)
			if selected and gesture in ["move", "rotate"]:
				dynamic_selected_edges.append(projected_p)
				dynamic_selected_edges.append(projected_q)
			elif selected:
				selected_edges.append(projected_p)
				selected_edges.append(projected_q)
			else:
				unselected_edges.append(projected_p)
				unselected_edges.append(projected_q)
	if dense_view:
		draw_dense_edges(gesture in ["move", "rotate"])
		if not dynamic_selected_edges.is_empty():
			var dense_axes := axes()
			var canvas_origin: Vector2 = size * 0.5 + Vector2(-origin[dense_axes.x], origin[dense_axes.y]) * zoom
			draw_set_transform(canvas_origin, 0.0, Vector2(zoom, -zoom))
			draw_multiline(dynamic_selected_edges, Color("ffb657"), 2.0 / zoom, true)
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	else:
		if not unselected_edges.is_empty():
			draw_multiline(unselected_edges, Color("9eb2c7"), 1, true)
		if not selected_edges.is_empty():
			draw_multiline(selected_edges, Color("ffb657"), 2, true)
		if not dynamic_selected_edges.is_empty():
			draw_multiline(dynamic_selected_edges, Color("ffb657"), 2, true)
	if host.tool in ["Vertex", "Edge"] or not host.session.components.is_empty():
		for brush in visible_brushes:
			var selected: bool = selected_ids.has(brush.id)
			var color = Color("ffb657") if selected else Color("9eb2c7")
			if selected and host.tool in ["Vertex", "Edge"]:
				var vertices: PackedVector3Array = brush.vertices
				if host.tool == "Edge":
					vertices = PackedVector3Array()
					for i in range(0, brush.edge_vertex_indices.size(), 2):
						vertices.append((brush.vertices[brush.edge_vertex_indices[i]] + brush.vertices[brush.edge_vertex_indices[i + 1]]) * 0.5)
				for p in vertices:
					draw_circle(project(p), 4, color)
			for component in host.session.components:
				if component.brush_id != brush.id or not host.session.component_valid(component, brush):
					continue
				if component.kind == "face":
					var polygon = PackedVector2Array()
					for p in brush.faces[component.index].winding:
						polygon.append(project(p))
					if polygon.size() >= 3 and absf(brush.faces[component.index].normal[orientation]) > 0.001:
						draw_colored_polygon(polygon, Color(0.16, 0.5, 1.0, 0.3))
					for i in polygon.size():
						draw_line(polygon[i], polygon[(i + 1) % polygon.size()], Color("69a7ff"), 3, true)
				elif component.kind == "vertex":
					draw_circle(project(brush.vertices[component.index]), 6, Color("ffe6a6"))
				else:
					var p: Vector3 = brush.vertices[brush.edge_vertex_indices[component.index * 2]]
					var q: Vector3 = brush.vertices[brush.edge_vertex_indices[component.index * 2 + 1]]
					draw_line(project(p), project(q), Color("ffe6a6"), 3, true)
					draw_circle(project((p + q) * 0.5), 6, Color("ffe6a6"))
	if host.session.marker_visible():
		for marker in host.session.point_markers():
			var p = project(marker.origin + (delta if gesture == "move" and host.session.points.has(marker.id) else Vector3.ZERO))
			var color = Color("ffb657") if host.session.points.has(marker.id) else Color("83dfbd")
			draw_rect(Rect2(p - Vector2.ONE * 6, Vector2.ONE * 12), color, false, 2)
			draw_string(ThemeDB.fallback_font, p + Vector2(10, -5), marker.classname, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, color)
	if camera_pose_valid:
		var camera_color := Color("62c7ff")
		var camera_center := project(camera_position)
		var view_direction := projected_camera_direction()
		draw_circle(camera_center, 7, Color("20252d"))
		draw_circle(camera_center, 7, camera_color, false, 2, true)
		if not view_direction.is_zero_approx():
			var tip := camera_center + view_direction * 28
			var side := Vector2(-view_direction.y, view_direction.x)
			draw_line(camera_center, tip, camera_color, 2, true)
			draw_colored_polygon(PackedVector2Array([tip, tip - view_direction * 9 + side * 5, tip - view_direction * 9 - side * 5]), camera_color)
	if gesture in ["create", "box"]:
		draw_rect(Rect2(start, cursor - start).abs(), Color("ffda8e"), false, 2)
	elif gesture in ["resize", "component"]:
		draw_manipulation_preview()
	if host.tool == "Rotate" and not host.session.selected.is_empty():
		var pivot = project(rotation_pivot if gesture == "rotate" else selection_center())
		draw_circle(pivot, 7, Color("20252d"))
		draw_circle(pivot, 7, Color("ffda8e"), false, 2, true)
		draw_line(pivot - Vector2(11, 0), pivot + Vector2(11, 0), Color("ffda8e"), 1, true)
		draw_line(pivot - Vector2(0, 11), pivot + Vector2(0, 11), Color("ffda8e"), 1, true)
		if gesture == "rotate":
			draw_line(pivot, cursor, Color("ffda8e"), 2, true)
			draw_string(ThemeDB.fallback_font, pivot + Vector2(12, -12), "%d°" % roundi(rad_to_deg(rotation_angle)), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("ffda8e"))
	for i in clip_points.size():
		var p = project(clip_points[i])
		draw_circle(p, 5, Color("fc7373"))
		draw_string(ThemeDB.fallback_font, p + Vector2(8, -8), str(i + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 14)
		if i:
			draw_line(project(clip_points[i - 1]), p, Color("fc7373"), 2, true)
	draw_rect(Rect2(0, 0, size.x, 36), Color(0.08, 0.1, 0.14, 0.95))
	draw_string(ThemeDB.fallback_font, Vector2(38, 23), "Ctrl+Tab  •  %.3f px/u%s" % [zoom, "  • ACTIVE" if has_focus() else ""], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("b9cfdf"))
