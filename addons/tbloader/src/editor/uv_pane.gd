@tool
extends VBoxContainer

signal texture_token_requested(token: String)
signal uv_transform_requested(shift: Vector2, rotation: float, scale: Vector2)
signal match_grid_requested
signal texture_axis_requested(axis: String)
signal reset_requested
signal fit_requested(scale: Vector2)
signal projection_requested(mode: String)

class UVCanvas extends Control:
	var preview_texture: Texture2D
	var triangle_uvs := PackedVector2Array()

	func _init() -> void:
		custom_minimum_size = Vector2(0, 96)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_preview(texture: Texture2D, uvs: PackedVector2Array) -> void:
		preview_texture = texture
		triangle_uvs = uvs.duplicate()
		queue_redraw()

	func _draw() -> void:
		var area := Rect2(Vector2.ONE, size - Vector2.ONE * 2.0)
		draw_rect(area, Color(0.12, 0.13, 0.14))
		if preview_texture != null:
			draw_texture_rect(preview_texture, area, false)
		if triangle_uvs.size() < 3:
			return
		for index in range(0, triangle_uvs.size() - 2, 3):
			var points := PackedVector2Array()
			for offset in 3:
				var uv := triangle_uvs[index + offset]
				points.append(area.position + Vector2(uv.x, uv.y) * area.size)
			draw_polyline(PackedVector2Array([points[0], points[1], points[2], points[0]]), Color(1.0, 0.78, 0.24), 1.5, true)

var texture_field: LineEdit
var shift_x: SpinBox
var shift_y: SpinBox
var scale_x: SpinBox
var scale_y: SpinBox
var rotation_field: SpinBox
var shift_step: SpinBox
var scale_step: SpinBox
var rotation_step: SpinBox
var fit_scale_x: SpinBox
var fit_scale_y: SpinBox
var status_label: Label
var canvas: UVCanvas
var projection_buttons: Dictionary = {}

var _state: Dictionary = {}
var _syncing := false

func _ready() -> void:
	if texture_field == null:
		_build_ui()
	refresh()

# State keys: texture, shift, rotation, scale, projection, mixed, editable,
# texture_resource, and triangle_uvs (packed normalized UV triangle points).
func set_state(value: Dictionary) -> void:
	_state = value.duplicate(true)
	refresh()

func refresh() -> void:
	if texture_field == null:
		return
	_syncing = true
	texture_field.text = str(_state.get("texture", ""))
	var shift: Vector2 = _state.get("shift", Vector2.ZERO)
	var scale_value: Vector2 = _state.get("scale", Vector2.ONE)
	shift_x.set_value_no_signal(shift.x)
	shift_y.set_value_no_signal(shift.y)
	scale_x.set_value_no_signal(scale_value.x)
	scale_y.set_value_no_signal(scale_value.y)
	rotation_field.set_value_no_signal(float(_state.get("rotation", 0.0)))
	var fit_scale: Vector2 = _state.get("fit_scale", Vector2.ONE)
	fit_scale_x.set_value_no_signal(fit_scale.x)
	fit_scale_y.set_value_no_signal(fit_scale.y)
	var editable: bool = bool(_state.get("editable", false)) and str(_state.get("projection", "classic")) != "valve"
	for field in [shift_x, shift_y, scale_x, scale_y, rotation_field]:
		field.editable = editable
	texture_field.editable = bool(_state.get("texture_editable", editable))
	var projection := str(_state.get("projection", "classic"))
	if projection == "valve":
		status_label.text = "Valve projection is read-only"
	elif bool(_state.get("mixed", false)):
		status_label.text = "Mixed UVs; an edit applies the displayed transform"
	elif not editable:
		status_label.text = "No editable face selection"
	else:
		status_label.text = "Classic UV"
	var texture: Texture2D = _state.get("texture_resource")
	var uvs: PackedVector2Array = _state.get("triangle_uvs", PackedVector2Array())
	canvas.set_preview(texture, uvs)
	_syncing = false

func clear() -> void:
	set_state({})

func set_texture_preview(texture: Texture2D, triangle_uvs: PackedVector2Array) -> void:
	_state["texture_resource"] = texture
	_state["triangle_uvs"] = triangle_uvs.duplicate()
	if canvas != null:
		canvas.set_preview(texture, triangle_uvs)

# Projection mutations are unavailable in today's native API. Coordinators may
# explicitly enable a mode when they can service projection_requested themselves.
func set_projection_supported(mode: String, supported: bool) -> void:
	if not projection_buttons.has(mode):
		return
	var control: Button = projection_buttons[mode]
	control.disabled = not supported
	control.tooltip_text = "Request %s projection" % mode.capitalize() if supported else "%s projection is not supported by the native map API" % mode.capitalize()

func current_transform() -> Dictionary:
	return {
		"shift": Vector2(shift_x.value, shift_y.value),
		"rotation": rotation_field.value,
		"scale": Vector2(scale_x.value, scale_y.value),
	}

func _build_ui() -> void:
	name = "UVPane"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var texture_row := HBoxContainer.new()
	add_child(texture_row)
	_add_label(texture_row, "Texture")
	texture_field = LineEdit.new()
	texture_field.placeholder_text = "Map texture token"
	texture_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texture_field.text_submitted.connect(_request_texture)
	texture_row.add_child(texture_field)
	var assign := Button.new()
	assign.text = "Set"
	assign.pressed.connect(func(): _request_texture(texture_field.text))
	texture_row.add_child(assign)

	var grid := GridContainer.new()
	grid.columns = 4
	add_child(grid)
	shift_x = _add_value_row(grid, "Horizontal shift", 0.125)
	shift_step = _add_step(grid, 8.0, 0.125)
	shift_y = _add_value_row(grid, "Vertical shift", 0.125)
	_add_step_proxy(grid, shift_step)
	scale_x = _add_value_row(grid, "Horizontal stretch", 0.01)
	scale_step = _add_step(grid, 0.5, 0.01)
	scale_y = _add_value_row(grid, "Vertical stretch", 0.01)
	_add_step_proxy(grid, scale_step)
	rotation_field = _add_value_row(grid, "Rotate", 0.25)
	rotation_step = _add_step(grid, 45.0, 0.25)
	for field in [shift_x, shift_y, scale_x, scale_y, rotation_field]:
		field.value_changed.connect(func(_value): _request_transform())
	shift_step.value_changed.connect(func(value): shift_x.step = value; shift_y.step = value)
	scale_step.value_changed.connect(func(value): scale_x.step = value; scale_y.step = value)
	rotation_step.value_changed.connect(func(value): rotation_field.step = value)

	var match_row := HBoxContainer.new()
	match_row.alignment = BoxContainer.ALIGNMENT_END
	add_child(match_row)
	_add_button(match_row, "Match Grid", func(): match_grid_requested.emit())

	var separator := HSeparator.new()
	add_child(separator)
	var sizing := HBoxContainer.new()
	add_child(sizing)
	_add_button(sizing, "Width", func(): texture_axis_requested.emit("width"))
	_add_button(sizing, "Height", func(): texture_axis_requested.emit("height"))
	var fit_row := HBoxContainer.new()
	add_child(fit_row)
	_add_button(fit_row, "Reset", func(): reset_requested.emit())
	_add_button(fit_row, "Fit", func(): fit_requested.emit(Vector2(fit_scale_x.value, fit_scale_y.value)))
	fit_scale_x = _add_compact_spin(fit_row, 1.0)
	fit_scale_x.tooltip_text = "Horizontal fit scale"
	fit_scale_y = _add_compact_spin(fit_row, 1.0)
	fit_scale_y.tooltip_text = "Vertical fit scale"

	var project := HBoxContainer.new()
	add_child(project)
	_add_label(project, "Project:")
	for mode in ["axial", "ortho", "cam"]:
		var mode_value: String = mode
		var control := _add_button(project, mode.capitalize(), func(): projection_requested.emit(mode_value))
		projection_buttons[mode] = control
		set_projection_supported(mode, false)

	canvas = UVCanvas.new()
	canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(canvas)
	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(status_label)

func _add_label(parent: Control, text_value: String) -> Label:
	var label := Label.new()
	label.text = text_value
	parent.add_child(label)
	return label

func _add_value_row(parent: GridContainer, label_text: String, step_value: float) -> SpinBox:
	_add_label(parent, label_text)
	var field := SpinBox.new()
	field.min_value = -65536.0
	field.max_value = 65536.0
	field.step = step_value
	field.custom_minimum_size.x = 84.0
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(field)
	return field

func _add_step(parent: GridContainer, value: float, minimum_step: float) -> SpinBox:
	_add_label(parent, "Step")
	var field := SpinBox.new()
	field.min_value = minimum_step
	field.max_value = 65536.0
	field.step = minimum_step
	field.value = value
	field.custom_minimum_size.x = 58.0
	parent.add_child(field)
	return field

func _add_step_proxy(parent: GridContainer, source: SpinBox) -> void:
	_add_label(parent, "Step")
	var field := SpinBox.new()
	field.min_value = source.min_value
	field.max_value = source.max_value
	field.step = source.step
	field.value = source.value
	field.custom_minimum_size.x = 58.0
	field.value_changed.connect(func(value): source.value = value)
	source.value_changed.connect(func(value): field.set_value_no_signal(value))
	parent.add_child(field)

func _add_button(parent: Control, text_value: String, callback: Callable) -> Button:
	var control := Button.new()
	control.text = text_value
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control.pressed.connect(callback)
	parent.add_child(control)
	return control

func _add_compact_spin(parent: Control, value: float) -> SpinBox:
	var field := SpinBox.new()
	field.min_value = 0.001
	field.max_value = 65536.0
	field.step = 0.125
	field.value = value
	field.custom_minimum_size.x = 68.0
	parent.add_child(field)
	return field

func _request_texture(token: String) -> void:
	if not _syncing:
		texture_token_requested.emit(token.strip_edges())

func _request_transform() -> void:
	if _syncing:
		return
	var value := current_transform()
	uv_transform_requested.emit(value.shift, value.rotation, value.scale)
