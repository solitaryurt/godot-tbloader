@tool
extends RefCounted

signal changed
signal message(text: String)
signal action_recorded(token: RefCounted)

const Action = preload("res://addons/tbloader/src/editor/map_action.gd")
var document = ClassDB.instantiate("TBMapDocument")
var selected = PackedInt64Array()
var points = PackedInt64Array()
var components: Array = []
var hidden: Dictionary = {}
var workzone = AABB(Vector3(-64, -64, -64), Vector3(128, 128, 128))
var loader: WeakRef = weakref(null)
var scene: WeakRef = weakref(null)
var baked_text = ""
var grid = 16.0
var texture = "common/caulk"
var manager: EditorUndoRedoManager

func capture() -> Dictionary:
	return {"native": document.snapshot().value, "selected_brush_ids": selected.duplicate(),
		"points": points.duplicate(), "components": components.duplicate(true), "workzone": workzone}

func restore(state: Dictionary) -> void:
	var result: Dictionary = document.restore_snapshot(state.native)
	if not result.ok:
		report(result)
		return
	selected = state.selected_brush_ids.duplicate()
	points = state.points.duplicate()
	components.clear() # Native restore always invalidates topology tokens.
	workzone = state.workzone
	prune()
	changed.emit()

func report(result: Dictionary) -> bool:
	if not result.ok:
		var e: Dictionary = result.error
		message.emit("%s: %s %s%s" % [e.code, e.message, e.path,
			(" (%d:%d)" % [e.line, e.column]) if e.line else ""])
	return result.ok

func transact(label: String, operation: Callable) -> bool:
	var before = capture()
	var result: Dictionary = operation.call()
	if not report(result):
		# Multi-command tools are atomic at the UI transaction boundary too.
		if document.export_text().value != before.native.text:
			restore(before)
		return false
	prune()
	var after = capture()
	if before.native.text == after.native.text:
		changed.emit()
		return false
	components.clear()
	var token = Action.new()
	token.session = self
	token.before = before
	token.after = after
	token.epoch = document.get_epoch()
	token.bytes = before.native.text.to_utf8_buffer().size() + after.native.text.to_utf8_buffer().size()
	manager.create_action(label, UndoRedo.MERGE_DISABLE, self)
	manager.add_do_method(token, "restore", true)
	manager.add_undo_method(token, "restore", false)
	manager.add_do_reference(token)
	manager.add_undo_reference(token)
	manager.commit_action(false)
	action_recorded.emit(token)
	changed.emit()
	return true

func brush(id: int) -> Dictionary:
	for item in document.get_draw_data():
		if item.id == id:
			return item
	return {}

func prune() -> void:
	var existing: Dictionary = {}
	for item in document.get_draw_data():
		existing[item.id] = true
	for id in hidden.keys():
		if not existing.has(id):
			hidden.erase(id)
	var valid = PackedInt64Array()
	for id in selected:
		if existing.has(id) and not hidden.has(id):
			valid.append(id)
	selected = valid
	var entities: Dictionary = {}
	for entity in document.get_entities():
		entities[entity.id] = true
	valid = PackedInt64Array()
	for id in points:
		if entities.has(id):
			valid.append(id)
	points = valid

func select(ids: PackedInt64Array, point_ids: PackedInt64Array = PackedInt64Array()) -> void:
	selected = ids
	points = point_ids
	components.clear()
	prune()
	var first = true
	for id in selected:
		var item = brush(id)
		var bounds = AABB(item.aabb_min, item.aabb_max - item.aabb_min)
		workzone = bounds if first else workzone.merge(bounds)
		first = false
	changed.emit()

func hide_selection(reveal: bool) -> void:
	if reveal:
		hidden.clear()
	else:
		for id in selected:
			hidden[id] = true
		selected.clear()
		components.clear()
	changed.emit()

func entity_targets() -> PackedInt64Array:
	var ids = points.duplicate()
	for id in selected:
		var owner_id: int = brush(id).get("entity_id", 0)
		if owner_id and not ids.has(owner_id):
			ids.append(owner_id)
	if ids.is_empty():
		for entity in document.get_entities():
			for pair in entity.epairs:
				if pair.key == "classname" and pair.value == "worldspawn":
					ids.append(entity.id)
					return ids
	return ids

func point_markers() -> Array:
	var markers: Array = []
	for entity in document.get_entities():
		if not entity.primitives.is_empty():
			continue
		var classname = ""
		var origin = Vector3.ZERO
		var have_origin = false
		for pair in entity.epairs:
			if pair.key == "classname" and classname.is_empty():
				classname = pair.value
			if pair.key == "origin" and not have_origin:
				var parts: PackedStringArray = pair.value.split(" ", false)
				if parts.size() == 3:
					origin = Vector3(float(parts[0]), float(parts[1]), float(parts[2]))
				have_origin = true
		if classname != "worldspawn":
			markers.append({"id": entity.id, "origin": origin, "classname": classname})
	return markers

func success() -> Dictionary:
	return {"ok": true, "changed": false, "value": null, "error": {}}
