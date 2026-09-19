@tool
extends RefCounted

signal changed
signal message(text: String)
signal action_recorded(token: RefCounted)

const Action = preload("res://addons/tbloader/src/editor/map_action.gd")
# Conservative logical ownership charges for Godot containers and Variant slots.
const UI_DICTIONARY_BYTES = 256
const UI_PACKED_ARRAY_BYTES = 64
const UI_COMPONENT_ARRAY_BYTES = 64
const UI_COMPONENT_DICTIONARY_BYTES = 128
const UI_COMPONENT_ENTRY_BYTES = 96
const UI_WORKZONE_BYTES = 48
var document = ClassDB.instantiate("TBMapDocument")
var selected = PackedInt64Array()
var points = PackedInt64Array()
var components: Array = []
var hidden: Dictionary = {}
var visibility_filters := {"entities": false, "caulk": false, "clips": false, "hint_skip": false}
var workzone = AABB(Vector3(-64, -64, -64), Vector3(128, 128, 128))
var loader: WeakRef = weakref(null)
var scene: WeakRef = weakref(null)
var baked_text = ""
var grid = 16.0
var texture = "common/caulk"
var texture_root = "res://textures"
var recovery_source = ""
var manager: EditorUndoRedoManager
var save_enabled = true # Successful Discard replacement suppresses Save All until resume/edit/undo.
var pristine_empty = true
var was_bound = false
var scene_managed = false
var preview_generation = 0
var selection_generation: int:
	get:
		_sync_selection_generation()
		return _selection_generation
var visibility_generation: int:
	get:
		_sync_visibility_generation()
		return _visibility_generation
var _selection_generation = 0
var _visibility_generation = 0
var _selected_generation_state := PackedInt64Array()
var _points_generation_state := PackedInt64Array()
var _components_generation_state: Array = []
var _hidden_generation_state: Dictionary = {}
var _filters_generation_state := {"entities": false, "caulk": false, "clips": false, "hint_skip": false}
var _draw_cache: Array = []
var _draw_index: Dictionary = {}
var _entity_cache: Array = []
var _brush_entity_ids: Dictionary = {}
var _marker_cache: Array = []
var _draw_valid = false
var _entity_valid = false
var _marker_valid = false
var _pending_brush_translation: Dictionary = {}
var _draw_generation = -1
var _draw_changed_entries = 0
var _draw_full_resets = 0
var _draw_full_reads = 0
var _draw_full_iterations = 0
var _draw_full_duplicates = 0
var _preview_uv_cache_retentions = 0
var _material_basename_cache: Dictionary = {}
var _brush_visibility_cache: Dictionary = {}
var _brush_visibility_doc_gen := -1
var _brush_visibility_vis_gen := -1
var _hidden_ids_cache := PackedInt64Array()
var _hidden_ids_cache_gen := -1
var change_kind = ""

func notify_changed(kind: String = "content") -> void:
	var previous: String = change_kind
	change_kind = kind
	changed.emit()
	change_kind = previous

func _init() -> void:
	document.map_changed.connect(_map_changed)
	document.preview_changed.connect(_preview_changed)

func _map_changed(_revision: int) -> void:
	pristine_empty = false
	var change: Dictionary = document.get_last_change()
	if not _pending_brush_translation.is_empty() and _draw_valid:
		patch_draw_translation(_pending_brush_translation.ids, _pending_brush_translation.delta)
		_draw_generation = change.generation
	elif (_draw_valid and not change.reset and change.added_ids.is_empty() and change.removed_ids.is_empty()
			and change.before_generation == _draw_generation):
		_patch_draw_changes(document.get_draw_changes())
	else:
		_invalidate_draw_cache(true)
	if change.entities_changed or change.ownership_changed:
		_entity_valid = false
		_entity_cache.clear()
		_brush_entity_ids = {}
	if change.entities_changed or change.points_changed:
		_marker_valid = false
		_marker_cache.clear()
	preview_generation += 1

func _invalidate_draw_cache(count_reset := false) -> void:
	if count_reset:
		_draw_full_resets += 1
	_draw_valid = false
	_draw_generation = -1
	_draw_cache.clear()
	_draw_index.clear()
	_brush_visibility_cache.clear()
	_brush_visibility_doc_gen = -1

func _patch_draw_changes(change: Dictionary) -> void:
	for item in change.brushes:
		var position: int = _draw_index.get(item.id, -1)
		if position < 0:
			continue
		_draw_cache[position] = item
		_draw_changed_entries += 1
	_draw_generation = change.generation

func has_unsaved_changes() -> bool:
	return document.is_dirty() and not (pristine_empty and document.get_path().is_empty() and recovery_source.is_empty())

func _sync_selection_generation() -> bool:
	if selected == _selected_generation_state and points == _points_generation_state and components == _components_generation_state:
		return false
	_selection_generation += 1
	_selected_generation_state = selected.duplicate()
	_points_generation_state = points.duplicate()
	_components_generation_state = components.duplicate(true)
	return true

func _sync_visibility_generation() -> bool:
	if hidden == _hidden_generation_state and visibility_filters == _filters_generation_state:
		return false
	_visibility_generation += 1
	_hidden_generation_state = hidden.duplicate()
	_filters_generation_state = visibility_filters.duplicate()
	_brush_visibility_cache.clear()
	_brush_visibility_vis_gen = -1
	_hidden_ids_cache_gen = -1
	return true

func patch_draw_translation(ids: PackedInt64Array, movement: Vector3) -> void:
	var patched: Dictionary = {}
	for id in ids:
		if patched.has(id):
			continue
		patched[id] = true
		var index: int = _draw_index.get(id, -1)
		if index < 0:
			continue
		var item: Dictionary = _draw_cache[index].duplicate(true)
		item.aabb_min += movement
		item.aabb_max += movement
		for key in ["vertices", "edges"]:
			var points: PackedVector3Array = item[key]
			for i in points.size():
				points[i] += movement
			item[key] = points
		for face in item.faces:
			face.center += movement
			var winding: PackedVector3Array = face.winding
			for i in winding.size():
				winding[i] += movement
			face.winding = winding
		_draw_cache[index] = item
		_draw_changed_entries += 1

func translate_brushes(ids: PackedInt64Array, movement: Vector3) -> Dictionary:
	_pending_brush_translation = {"ids": ids, "delta": movement}
	var result: Dictionary = document.translate_brushes(ids, movement)
	_pending_brush_translation.clear()
	return result

func _preview_changed() -> void:
	if document.get_last_preview_change_reason() == &"texture_uv":
		_preview_uv_cache_retentions += 1
		preview_generation += 1
		return
	# Rebuilds can replace topology caches without changing canonical map text.
	_invalidate_draw_cache(true)
	preview_generation += 1

func dispose() -> void:
	if document.map_changed.is_connected(_map_changed):
		document.map_changed.disconnect(_map_changed)
	if document.preview_changed.is_connected(_preview_changed):
		document.preview_changed.disconnect(_preview_changed)
	for connection in changed.get_connections():
		changed.disconnect(connection.callable)
	for connection in message.get_connections():
		message.disconnect(connection.callable)
	for connection in action_recorded.get_connections():
		action_recorded.disconnect(connection.callable)
	manager = null
	_draw_cache.clear()
	_draw_index.clear()
	_entity_cache.clear()
	_brush_entity_ids.clear()
	_marker_cache.clear()

func draw_data() -> Array:
	if not _draw_valid:
		_draw_cache = document.get_draw_data()
		_draw_full_reads += 1
		_draw_index.clear()
		for position in _draw_cache.size():
			_draw_full_iterations += 1
			var item: Dictionary = _draw_cache[position]
			_draw_index[item.id] = position
		_draw_valid = true
		_draw_generation = document.get_state_generation()
	return _draw_cache

func draw_cache_counters() -> Dictionary:
	return {"changed_draw_entries": _draw_changed_entries, "full_draw_resets": _draw_full_resets,
		"full_draw_reads": _draw_full_reads, "touched_draw_entries": _draw_changed_entries,
		"full_cache_iterations": _draw_full_iterations, "full_cache_duplicates": _draw_full_duplicates,
		"history_cache_retained_bytes": 0, "preview_uv_cache_retentions": _preview_uv_cache_retentions}

func entity_data() -> Array:
	if not _entity_valid:
		_entity_cache = document.get_entities()
		_brush_entity_ids.clear()
		for entity in _entity_cache:
			var classname := ""
			for pair in entity.epairs:
				if pair.key == "classname":
					classname = pair.value
					break
			if classname != "worldspawn":
				_brush_entity_ids[entity.id] = true
		_entity_valid = true
	return _entity_cache

func capture() -> Dictionary:
	var native = document.capture_history_state()
	var envelope := capture_ui_envelope()
	envelope["native"] = native
	return envelope

func capture_ui_envelope() -> Dictionary:
	var captured_components := components.filter(func(c): return component_valid(c, brush(c.brush_id))).duplicate(true)
	return {"selected_brush_ids": selected.duplicate(), "points": points.duplicate(),
		"components": captured_components, "workzone": workzone}

func ui_envelope_retained_bytes(envelope: Dictionary) -> int:
	var bytes := UI_DICTIONARY_BYTES + UI_WORKZONE_BYTES
	bytes += UI_PACKED_ARRAY_BYTES + envelope.get("selected_brush_ids", PackedInt64Array()).size() * 8
	bytes += UI_PACKED_ARRAY_BYTES + envelope.get("points", PackedInt64Array()).size() * 8
	var captured_components: Array = envelope.get("components", [])
	bytes += UI_COMPONENT_ARRAY_BYTES + captured_components.size() * 24
	for component in captured_components:
		bytes += UI_COMPONENT_DICTIONARY_BYTES
		for key in component:
			# The entry charge includes hash storage and both key/value Variant slots.
			bytes += UI_COMPONENT_ENTRY_BYTES
			if key is String or key is StringName:
				bytes += String(key).to_utf8_buffer().size() + 1
			var value = component[key]
			if value is String or value is StringName:
				bytes += String(value).to_utf8_buffer().size() + 1
			elif value is PackedInt64Array:
				bytes += UI_PACKED_ARRAY_BYTES + value.size() * 8
	return bytes

func restore(state: Dictionary) -> bool:
	var result: Dictionary = document.restore_history_state(state.native)
	if not result.ok:
		report(result)
		return false
	restore_ui_envelope(state)
	return true

func restore_ui_envelope(state: Dictionary) -> void:
	save_enabled = true
	selected = state.selected_brush_ids.duplicate()
	points = state.points.duplicate()
	# Only a matching native snapshot permits rebinding saved component indices.
	# Arbitrary live/stale tokens are never refreshed this way.
	components = state.components.duplicate(true)
	rebind_components()
	workzone = state.workzone
	prune(false)
	_sync_selection_generation()
	_sync_visibility_generation()
	notify_changed()

func restore_document_change(change: RefCounted, use_after: bool, envelope: Dictionary) -> void:
	var result: Dictionary = document.apply_document_change(change, use_after)
	if not report(result):
		return
	restore_ui_envelope(envelope)

func report(result: Dictionary) -> bool:
	if not result.ok:
		var e: Dictionary = result.error
		message.emit("%s: %s %s%s" % [e.code, e.message, e.path,
			(" (%d:%d)" % [e.line, e.column]) if e.line else ""])
	return result.ok

func history_action_bytes(before: Dictionary, after: Dictionary) -> int:
	# A fallback can become the final owner of its shared base after a later
	# structural edit, so conservatively charge one complete side.
	return (before.native.get_retained_bytes() + after.native.get_additional_retained_bytes(before.native)
		+ ui_envelope_retained_bytes(before) + ui_envelope_retained_bytes(after))

func transact(label: String, operation: Callable, kind := "") -> bool:
	var before_native = document.capture_history_state()
	var before_ui := capture_ui_envelope()
	var result: Dictionary = operation.call()
	if not report(result):
		# Multi-command tools are atomic at the UI transaction boundary too.
		if not document.is_history_state_current(before_native):
			var rollback := before_ui.duplicate()
			rollback.native = before_native
			if not restore(rollback):
				message.emit("FATAL_TRANSACTION_ROLLBACK: a failed multi-command map action could not restore its starting state.")
		return false
	prune()
	var after_ui := capture_ui_envelope()
	if document.is_history_state_current(before_native):
		notify_changed()
		return false
	var token = Action.new()
	save_enabled = true
	token.session = self
	token.epoch = document.get_epoch()
	token.before_generation = before_native.get_state_generation()
	token.after_generation = document.get_state_generation()
	var native_change = document.get_last_document_change()
	# A single native mutation spans this UI action only when its directional
	# generation starts at the captured state. Otherwise retain structural roots.
	if native_change != null and native_change.get_before_generation() == before_native.get_state_generation():
		token.change = native_change
		token.before_ui = before_ui
		token.after_ui = after_ui
		token.bytes = (native_change.get_retained_bytes() + ui_envelope_retained_bytes(before_ui)
			+ ui_envelope_retained_bytes(after_ui))
	else:
		var before := before_ui.duplicate()
		before.native = before_native
		var after := after_ui.duplicate()
		after.native = document.capture_history_state()
		token.before = before
		token.after = after
		token.bytes = history_action_bytes(before, after)
	manager.create_action(label, UndoRedo.MERGE_DISABLE)
	manager.add_do_method(token, "restore", true)
	manager.add_undo_method(token, "restore", false)
	manager.add_do_reference(token)
	manager.add_undo_reference(token)
	manager.commit_action(false)
	action_recorded.emit(token)
	notify_changed(kind if not kind.is_empty() else "content")
	return true

func brush(id: int) -> Dictionary:
	draw_data()
	var position: int = _draw_index.get(id, -1)
	return _draw_cache[position] if position >= 0 else {}

func visible_brushes_2d(hidden_axis: int, mins: Vector3, maxs: Vector3) -> Array:
	var result: Array = []
	for id in document.query_brushes_2d(hidden_axis, mins, maxs):
		var item := brush(id)
		if brush_visible(item):
			result.append(item)
	return result

func visible_ray_hits(origin: Vector3, direction: Vector3, max_distance: float = 1e30) -> Array:
	var result: Array = []
	for hit in document.query_ray(origin, direction, max_distance):
		if triangle_visible(hit.brush_id, hit.texture):
			result.append(hit)
	return result

func nearest_visible_ray_hit(origin: Vector3, direction: Vector3, max_distance: float = 1e30) -> Dictionary:
	return document.query_ray_nearest_visible(origin, direction, max_distance,
		hidden_brush_ids(), visibility_filter_mask())

func apply_face_edits(edits: Array) -> Dictionary:
	var result: Dictionary = document.apply_face_edits(edits)
	if result.ok and result.changed:
		rebind_components()
	return result

func hidden_brush_ids() -> PackedInt64Array:
	_sync_visibility_generation()
	if _hidden_ids_cache_gen == _visibility_generation:
		return _hidden_ids_cache
	_hidden_ids_cache = PackedInt64Array()
	_hidden_ids_cache.resize(hidden.size())
	var cursor := 0
	for id in hidden:
		_hidden_ids_cache[cursor] = id
		cursor += 1
	_hidden_ids_cache_gen = _visibility_generation
	return _hidden_ids_cache

func visibility_filter_mask() -> int:
	return (int(visibility_filters.entities) | int(visibility_filters.caulk) << 1
		| int(visibility_filters.clips) << 2 | int(visibility_filters.hint_skip) << 3)

func component_valid(component: Dictionary, item: Dictionary) -> bool:
	if item.is_empty() or not selected.has(component.brush_id) or not brush_visible(item):
		return false
	var count: int = item.faces.size() if component.kind == "face" else (item.vertices.size() if component.kind == "vertex" else item.edge_vertex_indices.size() / 2)
	return component.kind in ["face", "edge", "vertex"] and component.topology_revision == item.topology_revision and component.index >= 0 and component.index < count

func rebind_components() -> void:
	for component in components:
		var item = brush(component.brush_id)
		if not item.is_empty():
			component.topology_revision = item.topology_revision

func select_component(component: Dictionary, toggle: bool) -> void:
	prune_selection(false)
	if component.is_empty():
		if not toggle:
			components.clear()
	elif toggle:
		var index = components.find(component)
		if index >= 0:
			components.remove_at(index)
		else:
			components.append(component)
	elif not components.has(component):
		components = [component]
	_sync_selection_generation()
	notify_changed("selection")

func move_components(movement: Vector3) -> Dictionary:
	var old: Dictionary = {}
	for component in components:
		old[component.brush_id] = brush(component.brush_id)
	var result: Dictionary = document.translate_components(components, movement)
	if not result.ok or not result.changed:
		return result
	# Vertex ordering is cache-derived. Resolve moved positions, not old indices.
	for component in components:
		var item = brush(component.brush_id)
		var source: Dictionary = old[component.brush_id]
		if component.kind == "vertex":
			component.index = vertex_at(item, source.vertices[component.index] + movement)
		elif component.kind == "edge":
			var a = vertex_at(item, source.vertices[source.edge_vertex_indices[component.index * 2]] + movement)
			var b = vertex_at(item, source.vertices[source.edge_vertex_indices[component.index * 2 + 1]] + movement)
			component.index = -1
			for i in range(0, item.edge_vertex_indices.size(), 2):
				if (item.edge_vertex_indices[i] == a and item.edge_vertex_indices[i + 1] == b) or (item.edge_vertex_indices[i] == b and item.edge_vertex_indices[i + 1] == a):
					component.index = i / 2
					break
		component.topology_revision = item.topology_revision
	return result

func vertex_at(item: Dictionary, position: Vector3) -> int:
	for i in item.vertices.size():
		if item.vertices[i].distance_squared_to(position) < 0.00000001:
			return i
	return -1

func prune(sync_generations := true) -> void:
	draw_data()
	var existing: Dictionary = _draw_index
	for id in hidden.keys():
		if not existing.has(id):
			hidden.erase(id)
	var valid = PackedInt64Array()
	for id in selected:
		if existing.has(id) and brush_visible(brush(id)):
			valid.append(id)
	selected = valid
	components = components.filter(func(c): return component_valid(c, brush(c.brush_id)))
	var entities: Dictionary = {}
	for entity in entity_data():
		entities[entity.id] = true
	valid = PackedInt64Array()
	for id in points:
		if entities.has(id) and marker_visible():
			valid.append(id)
	points = valid
	var first = true
	for id in selected:
		var item = brush(id)
		var bounds = AABB(item.aabb_min, item.aabb_max - item.aabb_min)
		workzone = bounds if first else workzone.merge(bounds)
		first = false
	if sync_generations:
		_sync_selection_generation()
		_sync_visibility_generation()

func prune_selection(sync_generation := true) -> void:
	draw_data()
	var valid := PackedInt64Array()
	for id in selected:
		var item: Dictionary = brush(id)
		if brush_visible(item):
			valid.append(id)
	selected = valid
	components = components.filter(func(c): return component_valid(c, brush(c.brush_id)))
	var marker_ids: Dictionary = {}
	for marker in point_markers():
		marker_ids[marker.id] = true
	valid = PackedInt64Array()
	if marker_visible():
		for id in points:
			if marker_ids.has(id):
				valid.append(id)
	points = valid
	var first := true
	for id in selected:
		var item: Dictionary = brush(id)
		var bounds := AABB(item.aabb_min, item.aabb_max - item.aabb_min)
		workzone = bounds if first else workzone.merge(bounds)
		first = false
	if sync_generation:
		_sync_selection_generation()

func select(ids: PackedInt64Array, point_ids: PackedInt64Array = PackedInt64Array()) -> void:
	var previous_selected: PackedInt64Array = selected.duplicate()
	var previous_points: PackedInt64Array = points.duplicate()
	var previous_components := components.duplicate(true)
	selected = ids
	points = point_ids
	components.clear()
	prune_selection(false)
	_sync_selection_generation()
	if selected == previous_selected and points == previous_points and components == previous_components:
		return
	notify_changed("selection")

func hide_selection(reveal: bool) -> void:
	if reveal:
		hidden.clear()
	else:
		for id in selected:
			hidden[id] = true
		selected.clear()
		components.clear()
	_sync_selection_generation()
	_sync_visibility_generation()
	notify_changed("visibility")

func set_visibility_filter(category: String, hide: bool) -> void:
	if not visibility_filters.has(category) or visibility_filters[category] == hide:
		return
	visibility_filters[category] = hide
	prune(false)
	_sync_selection_generation()
	_sync_visibility_generation()
	notify_changed("visibility")

func material_basename(texture: String) -> String:
	var cached = _material_basename_cache.get(texture)
	if cached != null:
		return cached
	var name := texture.to_lower().replace("\\", "/").get_file().get_basename()
	_material_basename_cache[texture] = name
	return name

func material_filtered(texture: String) -> bool:
	var name := material_basename(texture)
	if visibility_filters.caulk and name == "caulk":
		return true
	if visibility_filters.hint_skip and name == "hint_skip":
		return true
	return visibility_filters.clips and (name == "clip" or name.begins_with("clip") or name.ends_with("clip"))

func brush_visible(item: Dictionary) -> bool:
	if item.is_empty() or hidden.has(item.id):
		return false
	var doc_gen: int = _draw_generation if _draw_valid else document.get_state_generation()
	_sync_visibility_generation()
	if doc_gen != _brush_visibility_doc_gen or _visibility_generation != _brush_visibility_vis_gen:
		_brush_visibility_cache.clear()
		_brush_visibility_doc_gen = doc_gen
		_brush_visibility_vis_gen = _visibility_generation
	if _brush_visibility_cache.has(item.id):
		return _brush_visibility_cache[item.id]
	var visible := true
	if visibility_filters.entities and brush_has_entity_owner(item):
		visible = false
	elif not item.faces.is_empty() and item.faces.all(func(face): return material_filtered(face.texture)):
		visible = false
	_brush_visibility_cache[item.id] = visible
	return visible

func triangle_visible(brush_id: int, texture: String) -> bool:
	var item := brush(brush_id)
	if item.is_empty() or hidden.has(brush_id) or visibility_filters.entities and brush_has_entity_owner(item):
		return false
	return not material_filtered(texture)

func marker_visible() -> bool:
	return not visibility_filters.entities

func brush_has_entity_owner(item: Dictionary) -> bool:
	var owner_id: int = item.get("entity_id", 0)
	entity_data()
	return _brush_entity_ids.has(owner_id)

func hidden_count() -> int:
	if not visibility_filters.entities and not visibility_filters.caulk and not visibility_filters.clips and not visibility_filters.hint_skip:
		return hidden.size()
	var ids: Dictionary = hidden.duplicate()
	for item in draw_data():
		if not brush_visible(item):
			ids[item.id] = true
	var count := ids.size()
	if not marker_visible():
		count += point_markers().size()
	return count

func entity_targets() -> PackedInt64Array:
	var ids = points.duplicate()
	for id in selected:
		var owner_id: int = brush(id).get("entity_id", 0)
		if owner_id and not ids.has(owner_id):
			ids.append(owner_id)
	if ids.is_empty():
		for entity in entity_data():
			for pair in entity.epairs:
				if pair.key == "classname" and pair.value == "worldspawn":
					ids.append(entity.id)
					return ids
	return ids

func point_markers() -> Array:
	if _marker_valid:
		return _marker_cache
	_marker_cache = []
	for entity in entity_data():
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
			_marker_cache.append({"id": entity.id, "origin": origin, "classname": classname})
	_marker_valid = true
	return _marker_cache

func success() -> Dictionary:
	return {"ok": true, "changed": false, "value": null, "error": {}}
