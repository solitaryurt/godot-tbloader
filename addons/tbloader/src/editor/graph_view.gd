@tool
extends Control

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
var clip_points: Array[Vector3] = []
var clip_flip = false
var shift_drag = false
var ctrl_drag = false

func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(240, 180)
	clip_contents = true
	focus_exited.connect(cancel)

func axes() -> Vector2i:
	return Vector2i(1 if orientation == 0 else 0, 1 if orientation == 2 else 2)

func project(point: Vector3) -> Vector2:
	var a = axes()
	return size * 0.5 + Vector2(point[a.x] - origin[a.x], origin[a.y] - point[a.y]) * zoom

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
	cancel()
	view_states[orientation] = {"origin": origin, "zoom": zoom}
	orientation = {2: 1, 1: 0, 0: 2}[orientation]
	var state: Dictionary = view_states.get(orientation, {"origin": Vector3.ZERO, "zoom": 1.0})
	origin = state.origin
	zoom = state.zoom
	clip_points.clear()
	queue_redraw()
	host.refresh_status()

func zoom_at(position: Vector2, factor: float) -> void:
	var before = unproject(position)
	zoom = clampf(zoom * factor, 0.02, 64.0)
	var offset = before - unproject(position)
	offset[orientation] = 0
	origin += offset
	queue_redraw()

func cancel() -> void:
	gesture = ""
	delta = Vector3.ZERO
	resize_face.clear()
	queue_redraw()

func hit_brush(position: Vector2) -> int:
	var data: Array = host.session.document.get_draw_data()
	data.reverse()
	for brush in data:
		if host.session.hidden.has(brush.id):
			continue
		for face in brush.faces:
			var polygon = PackedVector2Array()
			for point in face.winding:
				polygon.append(project(point))
			if polygon.size() >= 3 and Geometry2D.is_point_in_polygon(position, polygon):
				return brush.id
		for i in range(0, brush.edges.size(), 2):
			if position.distance_to(Geometry2D.get_closest_point_to_segment(position,
					project(brush.edges[i]), project(brush.edges[i + 1]))) < 6:
				return brush.id
	return 0

func hit_point(position: Vector2) -> int:
	for marker in host.session.point_markers():
		if project(marker.origin).distance_to(position) <= 12:
			return marker.id
	return 0

func silhouette(position: Vector2) -> Dictionary:
	for id in host.session.selected:
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

func pick_component(position: Vector2, mode: String) -> Dictionary:
	for id in host.session.selected:
		var brush: Dictionary = host.session.brush(id)
		if mode == "Face":
			var edge = silhouette(position)
			if not edge.is_empty():
				return edge
			for face in brush.faces:
				var polygon = PackedVector2Array()
				for p in face.winding:
					polygon.append(project(p))
				if polygon.size() >= 3 and Geometry2D.is_point_in_polygon(position, polygon):
					return {"brush_id": id, "index": face.index, "kind": "face", "topology_revision": brush.topology_revision}
		else:
			var count: int = brush.vertices.size() if mode == "Vertex" else brush.edge_vertex_indices.size() / 2
			for i in count:
				var p: Vector3 = brush.vertices[i] if mode == "Vertex" else (brush.vertices[brush.edge_vertex_indices[i * 2]] + brush.vertices[brush.edge_vertex_indices[i * 2 + 1]]) * 0.5
				if project(p).distance_to(position) < 12:
					return {"brush_id": id, "index": i, "kind": mode.to_lower(), "topology_revision": brush.topology_revision}
	return {}

func _gui_input(event: InputEvent) -> void:
	if event is InputEventKey:
		if host.route_key(event, self):
			accept_event()
		return
	if event is InputEventMouseButton:
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
		if gesture == "pan":
			var a = axes()
			origin[a.x] -= event.relative.x / zoom
			origin[a.y] += event.relative.y / zoom
		else:
			delta = snap_point(unproject(cursor) - anchor)
			delta[orientation] = 0
			var a = axes()
			if shift_drag and gesture in ["move", "component", "resize"]:
				delta[a.y if absf(delta[a.x]) > absf(delta[a.y]) else a.x] = 0
			if ctrl_drag and gesture == "move" and not host.session.selected.is_empty():
				var reference: Vector3 = host.session.workzone.position
				delta = snap_point(reference + unproject(cursor) - anchor) - reference
				delta[orientation] = 0
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
		if clip_points.size() == 3:
			clip_points.clear()
		clip_points.append(snap_point(anchor))
		queue_redraw()
		return
	if (host.tool in ["Face", "Vertex", "Edge"] or event.ctrl_pressed) and not host.session.selected.is_empty():
		var component = pick_component(start, "Face" if event.ctrl_pressed else host.tool)
		host.session.components = [] if component.is_empty() else [component]
		if not component.is_empty():
			gesture = "component"
		host.session.changed.emit()
		return
	var point_id = hit_point(start)
	var id = hit_brush(start)
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
		return
	if point_id:
		if not host.session.points.has(point_id):
			host.session.select(PackedInt64Array(), PackedInt64Array([point_id]))
		gesture = "move"
	elif host.session.selected.is_empty() and host.session.points.is_empty() and host.tool != "Select":
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
			session.transact("Move map selection", func():
				var r: Dictionary = session.document.translate_brushes(session.selected, movement)
				if r.ok:
					r = session.document.translate_point_entities(session.points, movement)
				return r)
		else:
			var component: Dictionary = resize_face if gesture == "resize" else session.components[0]
			session.transact("Resize map face" if gesture == "resize" else "Move map component", func():
				if component.kind == "face":
					return session.document.translate_face(component.brush_id, component.index, movement, component.topology_revision)
				var indices = PackedInt32Array([component.index])
				if component.kind == "edge":
					var b: Dictionary = session.brush(component.brush_id)
					indices = PackedInt32Array([b.edge_vertex_indices[component.index * 2], b.edge_vertex_indices[component.index * 2 + 1]])
				return session.document.translate_vertices(component.brush_id, indices, movement, component.topology_revision))
		session.select(session.selected, session.points)
	cancel()

func box_select(end: Vector2) -> void:
	var rect = Rect2(start, end - start).abs()
	var ids = host.session.selected.duplicate()
	var point_ids = host.session.points.duplicate()
	var direction = end - start
	var add = direction.x >= 0 and direction.y <= 0
	var remove = direction.x <= 0 and direction.y >= 0
	for brush in host.session.document.get_draw_data():
		if host.session.hidden.has(brush.id):
			continue
		var contained = true
		for vertex in brush.vertices:
			if not rect.has_point(project(vertex)):
				contained = false
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
	if clip_points.size() < 2:
		host.set_status("Place two or three clip points first.")
		return
	var p: Vector3 = clip_points[0]
	var q: Vector3 = clip_points[1]
	var r: Vector3 = clip_points[2] if clip_points.size() > 2 else p
	if clip_points.size() == 2:
		r[orientation] -= p.distance_to(q)
	if clip_flip:
		var swap = q
		q = r
		r = swap
	var session = host.session
	if session.transact("Split map brushes" if split else "Clip map brushes", func():
		var result: Dictionary = session.document.clip_brushes(session.selected, p, q, r, split)
		if result.ok:
			session.select(result.value)
		return result):
		clip_points.clear()
	queue_redraw()

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
				color = Color("88605e") if axis == a.x else Color("527e93")
			draw_line(project(p), project(q), color)
			v += step
	for brush in host.session.document.get_draw_data():
		if host.session.hidden.has(brush.id):
			continue
		var selected: bool = host.session.selected.has(brush.id)
		var color = Color("ffb657") if selected else Color("9eb2c7")
		var offset = delta if selected and gesture == "move" else Vector3.ZERO
		for i in range(0, brush.edges.size(), 2):
			draw_line(project(brush.edges[i] + offset), project(brush.edges[i + 1] + offset), color, 2 if selected else 1, true)
		if selected and host.tool in ["Vertex", "Edge"]:
			var vertices: PackedVector3Array = brush.vertices
			if host.tool == "Edge":
				vertices = PackedVector3Array()
				for i in range(0, brush.edge_vertex_indices.size(), 2):
					vertices.append((brush.vertices[brush.edge_vertex_indices[i]] + brush.vertices[brush.edge_vertex_indices[i + 1]]) * 0.5)
			for p in vertices:
				draw_circle(project(p), 4, color)
		for component in host.session.components:
			if component.brush_id == brush.id and component.kind == "face":
				var polygon = PackedVector2Array()
				for p in brush.faces[component.index].winding:
					polygon.append(project(p))
				if polygon.size() >= 3 and absf(brush.faces[component.index].normal[orientation]) > 0.001:
					draw_colored_polygon(polygon, Color(1, 0.6, 0.1, 0.25))
	for marker in host.session.point_markers():
		var p = project(marker.origin + (delta if gesture == "move" and host.session.points.has(marker.id) else Vector3.ZERO))
		var color = Color("ffb657") if host.session.points.has(marker.id) else Color("83dfbd")
		draw_rect(Rect2(p - Vector2.ONE * 6, Vector2.ONE * 12), color, false, 2)
		draw_string(ThemeDB.fallback_font, p + Vector2(10, -5), marker.classname, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, color)
	if gesture in ["create", "box", "resize", "component"]:
		draw_rect(Rect2(start, cursor - start).abs(), Color("ffda8e"), false, 2)
	for i in clip_points.size():
		var p = project(clip_points[i])
		draw_circle(p, 5, Color("fc7373"))
		draw_string(ThemeDB.fallback_font, p + Vector2(8, -8), str(i + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 14)
		if i:
			draw_line(project(clip_points[i - 1]), p, Color("fc7373"), 2)
	draw_rect(Rect2(0, 0, size.x, 26), Color(0.08, 0.1, 0.14, 0.95))
	draw_string(ThemeDB.fallback_font, Vector2(9, 18), "%s  •  Ctrl+Tab  •  %.3f px/u%s" % [["Side YZ", "Front XZ", "Top XY"][orientation], zoom, "  • ACTIVE" if has_focus() else ""], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("b9cfdf"))
