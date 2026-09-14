@tool
extends Control

signal axis_selected(axis: int, positive: bool)
signal orbit_dragged(relative: Vector2)

var view_axes: Array[Vector3] = [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
var signed_axes = true
var allow_orbit = false
var gizmo_size := 64.0
var hovered = -1
var pressed = false
var dragging = false
var press_position = Vector2.ZERO
var points: Array[Dictionary] = []

const AXIS_COLORS = [Color("f55264"), Color("87d606"), Color("298cf6")]

func _ready() -> void:
	custom_minimum_size = Vector2.ONE * gizmo_size
	focus_mode = Control.FOCUS_NONE
	tooltip_text = "View orientation"
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

func set_view_axes(value: Array) -> void:
	view_axes.clear()
	for axis in value:
		view_axes.append(axis)
	queue_redraw()

func _project_axes() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var center := size * 0.5
	var radius := maxf(8.0, minf(size.x, size.y) * 0.5 - 9.0)
	for axis in 3:
		var direction := view_axes[axis].normalized()
		for positive in ([true, false] if signed_axes else [true]):
			var sign_value := 1.0 if positive else -1.0
			result.append({
				"point": center + Vector2(direction.x, -direction.y) * radius * sign_value,
				"depth": direction.z * sign_value,
				"axis": axis,
				"positive": positive,
			})
	result.sort_custom(func(a, b): return a.depth < b.depth)
	return result

func _draw() -> void:
	points = _project_axes()
	var center := size * 0.5
	var endpoint_radius := clampf(minf(size.x, size.y) * 0.115, 4.0, 6.0)
	for index in points.size():
		var entry: Dictionary = points[index]
		var color: Color = AXIS_COLORS[entry.axis]
		var alpha := remap(float(entry.depth), -1.0, 1.0, 0.4, 1.0)
		color.a = alpha
		if index == hovered:
			color = color.lightened(0.25)
			color.a = 1.0
		if entry.positive:
			draw_line(center, entry.point, color, 2.0, true)
		draw_circle(entry.point, endpoint_radius, color, true, -1.0, true)
		if not entry.positive:
			draw_circle(entry.point, endpoint_radius * 0.6, color.darkened(0.4), true, -1.0, true)
		var label: String = ["X", "Y", "Z"][entry.axis]
		if entry.positive or index == hovered:
			var font := get_theme_default_font()
			var font_size := 10
			var label_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
			draw_string(font, entry.point + Vector2(-label_size.x * 0.5, label_size.y * 0.35), label,
				HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.08, 0.08, 0.08, color.a))

func _hit_axis(position: Vector2) -> int:
	var hit := -1
	for index in points.size():
		if position.distance_to(points[index].point) <= 8.0:
			hit = index
	return hit

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		hovered = _hit_axis(event.position)
		if pressed and allow_orbit:
			if not dragging and event.position.distance_to(press_position) > 4.0:
				dragging = true
			if dragging:
				orbit_dragged.emit(event.relative)
		queue_redraw()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			pressed = true
			dragging = false
			press_position = event.position
			accept_event()
		else:
			if pressed and not dragging:
				hovered = _hit_axis(event.position)
				if hovered >= 0:
					var entry: Dictionary = points[hovered]
					axis_selected.emit(entry.axis, entry.positive)
			pressed = false
			dragging = false
			queue_redraw()
			accept_event()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		pressed = false
		dragging = false
		queue_redraw()
		accept_event()

func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		hovered = -1
		queue_redraw()
	elif what in [NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_WM_WINDOW_FOCUS_OUT]:
		pressed = false
		dragging = false
