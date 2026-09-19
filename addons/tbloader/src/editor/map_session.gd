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
var active_layer_id := 0
var layer_hidden: Dictionary = {}
var layer_locked: Dictionary = {}
var isolated_layer_id := 0
var layer_search := ""
var workzone = AABB(Vector3(-64, -64, -64), Vector3(128, 128, 128))
var loader: WeakRef = weakref(null)
var scene: WeakRef = weakref(null)
var baked_text = ""
var grid = 16.0
var texture = "common/caulk"
var texture_root = "res://textures"
var recovery_source = ""
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
var _layer_hidden_generation_state: Dictionary = {}
var _isolated_generation_state := 0
var _layer_epoch := -1
var _layer_generation := -1
var _layer_cache: Array = []
var _layer_ids: Dictionary = {}
var _worldspawn_layer_id := 0
var _pick_hidden_cache := PackedInt64Array()
var _pick_hidden_cache_gen := -1
var _pick_hidden_lock_state: Dictionary = {}
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
var _history_states: Array = []
var _history_actions: Array = []
var _history_cursor := 0
var _history_epoch := 0
var _history_next_state_id := 1
var _history_retained_bytes := 0
var _disposed := false
static var _history_next_sequence := 1

func notify_changed(kind: String = "content") -> void:
	var previous: String = change_kind
	change_kind = kind
	changed.emit()
	change_kind = previous

func _init() -> void:
	document.map_changed.connect(_map_changed)
	document.preview_changed.connect(_preview_changed)
	_layer_epoch = document.get_epoch()
	layers()

func _map_changed(_revision: int) -> void:
	pristine_empty = false
	_layer_generation = -1
	if document.get_epoch() != _layer_epoch:
		_reset_layer_transient()
		_layer_epoch = document.get_epoch()
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
	if (hidden == _hidden_generation_state and visibility_filters == _filters_generation_state
			and layer_hidden == _layer_hidden_generation_state and isolated_layer_id == _isolated_generation_state):
		return false
	_visibility_generation += 1
	_hidden_generation_state = hidden.duplicate()
	_filters_generation_state = visibility_filters.duplicate()
	_layer_hidden_generation_state = layer_hidden.duplicate()
	_isolated_generation_state = isolated_layer_id
	_brush_visibility_cache.clear()
	_brush_visibility_vis_gen = -1
	_hidden_ids_cache_gen = -1
	_pick_hidden_cache_gen = -1
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
	var locked := reject_locked_ids(ids, "translate_brushes")
	if not locked.ok:
		return locked
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
	_disposed = true
	history_clear()
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
	_draw_cache.clear()
	_draw_index.clear()
	_entity_cache.clear()
	_brush_entity_ids.clear()
	_marker_cache.clear()

func _history_state(snapshot: Dictionary) -> Dictionary:
	var state := {"id": _history_next_state_id, "snapshot": snapshot, "bytes": 0}
	_history_next_state_id += 1
	return state

func _history_recount_bytes() -> void:
	_history_retained_bytes = 0
	for index in _history_states.size():
		var snapshot: Dictionary = _history_states[index].snapshot
		var bytes := ui_envelope_retained_bytes(snapshot)
		if index == 0:
			bytes += snapshot.native.get_retained_bytes()
		else:
			bytes += snapshot.native.get_additional_retained_bytes(_history_states[index - 1].snapshot.native)
		_history_states[index].bytes = bytes
		_history_retained_bytes += bytes

func _history_initialize(snapshot: Dictionary) -> void:
	history_clear()
	_history_epoch = document.get_epoch()
	_history_states.append(_history_state(snapshot))
	_history_recount_bytes()

func _history_ensure(snapshot: Dictionary = {}) -> bool:
	if _disposed:
		return false
	if _history_states.is_empty() or _history_epoch != document.get_epoch():
		_history_initialize(capture() if snapshot.is_empty() else snapshot)
	elif not document.is_history_state_current(_history_states[_history_cursor].snapshot.native):
		_history_initialize(capture() if snapshot.is_empty() else snapshot)
	return true

func history_clear() -> void:
	for action in _history_actions:
		action.retire()
	_history_actions.clear()
	_history_states.clear()
	_history_cursor = 0
	_history_epoch = 0
	_history_retained_bytes = 0

func history_action_count() -> int:
	_history_ensure()
	return _history_actions.size()

func history_cursor() -> int:
	_history_ensure()
	return _history_cursor

func history_bytes() -> int:
	_history_ensure()
	return _history_retained_bytes

func history_action_names() -> PackedStringArray:
	_history_ensure()
	var names := PackedStringArray()
	for action in _history_actions:
		names.append(action.label)
	return names

func history_state_ids() -> PackedInt64Array:
	_history_ensure()
	var ids := PackedInt64Array()
	for state in _history_states:
		ids.append(state.id)
	return ids

func history_actions() -> Array:
	_history_ensure()
	return _history_actions.duplicate()

func history_undo_name() -> String:
	_history_ensure()
	return _history_actions[_history_cursor - 1].label if _history_cursor > 0 else ""

func history_redo_name() -> String:
	_history_ensure()
	return _history_actions[_history_cursor].label if _history_cursor < _history_actions.size() else ""

func history_undo() -> bool:
	if not _history_ensure() or _history_cursor == 0:
		return false
	if not restore(_history_states[_history_cursor - 1].snapshot):
		return false
	_history_cursor -= 1
	return true

func history_redo() -> bool:
	if not _history_ensure() or _history_cursor >= _history_actions.size():
		return false
	if not restore(_history_states[_history_cursor + 1].snapshot):
		return false
	_history_cursor += 1
	return true

func history_navigate_state(state_id: int) -> bool:
	if not _history_ensure():
		return false
	for index in _history_states.size():
		if _history_states[index].id == state_id:
			if index == _history_cursor:
				return true
			if not restore(_history_states[index].snapshot):
				return false
			_history_cursor = index
			return true
	return false

func _history_truncate_redo() -> void:
	while _history_actions.size() > _history_cursor:
		_history_actions.pop_back().retire()
		_history_states.pop_back()
	_history_recount_bytes()

func history_oldest_evictable_sequence() -> int:
	if _history_actions.is_empty():
		return 0
	if _history_cursor > 0:
		return _history_actions[0].sequence
	if _history_cursor < _history_actions.size():
		return _history_actions[-1].sequence
	return 0

func history_evict_oldest() -> bool:
	if _history_actions.is_empty():
		return false
	if _history_cursor > 0:
		_history_actions.pop_front().retire()
		_history_states.pop_front()
		_history_cursor -= 1
		if not _history_actions.is_empty():
			_history_actions[0].before_state_id = _history_states[0].id
	elif _history_cursor < _history_actions.size():
		_history_actions.pop_back().retire()
		_history_states.pop_back()
	else:
		return false
	_history_recount_bytes()
	return true

func history_enforce_limits(action_limit: int, byte_limit: int) -> void:
	while (_history_actions.size() > action_limit or _history_retained_bytes > byte_limit) and history_evict_oldest():
		pass

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
	var before := before_ui.duplicate()
	before.native = before_native
	_history_ensure(before)
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
	# Selection/components/workzone may change between content actions. The state
	# at the cursor owns the UI envelope immediately before its outgoing action.
	_history_states[_history_cursor].snapshot = before
	_history_truncate_redo()
	var token = Action.new()
	save_enabled = true
	token.session = self
	token.epoch = document.get_epoch()
	token.label = label
	token.sequence = _history_next_sequence
	_history_next_sequence += 1
	var after := after_ui.duplicate()
	after.native = document.capture_history_state()
	token.before_state_id = _history_states[-1].id
	var after_state := _history_state(after)
	token.after_state_id = after_state.id
	_history_states.append(after_state)
	_history_actions.append(token)
	_history_cursor = _history_actions.size()
	_history_recount_bytes()
	token.bytes = after_state.bytes
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
		if triangle_visible(hit.brush_id, hit.texture) and not layer_locked_for_brush(hit.brush_id):
			result.append(hit)
	return result

func nearest_visible_ray_hit(origin: Vector3, direction: Vector3, max_distance: float = 1e30) -> Dictionary:
	return document.query_ray_nearest_visible(origin, direction, max_distance,
		pick_hidden_brush_ids(), visibility_filter_mask())

func apply_face_edits(edits: Array) -> Dictionary:
	var result: Dictionary = document.apply_face_edits(edits)
	if result.ok and result.changed:
		rebind_components()
	return result

func hidden_brush_ids() -> PackedInt64Array:
	_sync_visibility_generation()
	if _hidden_ids_cache_gen == _visibility_generation:
		return _hidden_ids_cache
	var ids: Dictionary = hidden.duplicate()
	if isolated_layer_id != 0 or not layer_hidden.is_empty():
		layers()
		for item in draw_data():
			if not _layer_allows_owner(int(item.get("entity_id", 0))):
				ids[item.id] = true
	_hidden_ids_cache = PackedInt64Array()
	_hidden_ids_cache.resize(ids.size())
	var cursor := 0
	for id in ids:
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
	var ids := PackedInt64Array()
	for component in components:
		if not ids.has(component.brush_id):
			ids.append(component.brush_id)
	var locked := reject_locked_ids(ids, "translate_components")
	if not locked.ok:
		return locked
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
		if existing.has(id) and brush_visible(brush(id)) and not layer_locked_for_brush(id):
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
		if brush_visible(item) and not layer_locked_for_brush(id):
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
	if not _layer_allows_owner(int(item.get("entity_id", 0))):
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
	if item.is_empty() or hidden.has(brush_id) or not _layer_allows_owner(int(item.get("entity_id", 0))) or visibility_filters.entities and brush_has_entity_owner(item):
		return false
	return not material_filtered(texture)

func marker_visible() -> bool:
	return not visibility_filters.entities

func brush_has_entity_owner(item: Dictionary) -> bool:
	var owner_id: int = item.get("entity_id", 0)
	entity_data()
	return _brush_entity_ids.has(owner_id)

func hidden_count() -> int:
	if (not visibility_filters.entities and not visibility_filters.caulk and not visibility_filters.clips
			and not visibility_filters.hint_skip and layer_hidden.is_empty() and isolated_layer_id == 0):
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

func failure_result(code: String, message_text: String, operation: String) -> Dictionary:
	return {"ok": false, "changed": false, "value": null, "error": {
		"code": StringName(code), "message": message_text, "operation": StringName(operation),
		"path": "", "line": 0, "column": 0, "entity_id": 0, "brush_id": 0, "face": -1}}

func _reset_layer_transient() -> void:
	active_layer_id = 0
	layer_hidden.clear()
	layer_locked.clear()
	isolated_layer_id = 0
	layer_search = ""
	_layer_generation = -1
	_layer_cache.clear()
	_layer_ids.clear()
	_worldspawn_layer_id = 0
	_pick_hidden_cache_gen = -1

func layers() -> Array:
	var generation: int = document.get_state_generation()
	if _layer_generation == generation:
		return _layer_cache
	var result: Dictionary = document.get_world_geometry_owners()
	_layer_cache = result.value if result.ok else []
	_layer_generation = generation
	_layer_ids.clear()
	_worldspawn_layer_id = 0
	for layer in _layer_cache:
		_layer_ids[int(layer.id)] = true
		if String(layer.classname) == "worldspawn":
			_worldspawn_layer_id = int(layer.id)
	_prune_layer_transient()
	return _layer_cache

func _prune_layer_transient() -> void:
	for id in layer_hidden.keys():
		if not _layer_ids.has(id):
			layer_hidden.erase(id)
	for id in layer_locked.keys():
		if not _layer_ids.has(id):
			layer_locked.erase(id)
	if isolated_layer_id != 0 and not _layer_ids.has(isolated_layer_id):
		isolated_layer_id = 0
	if active_layer_id == 0 or not _layer_ids.has(active_layer_id):
		active_layer_id = _worldspawn_layer_id

func layer_by_id(entity_id: int) -> Dictionary:
	for layer in layers():
		if int(layer.id) == entity_id:
			return layer
	return {}

func layer_for_brush(brush_id: int) -> Dictionary:
	var result: Dictionary = document.get_brush_owner(brush_id)
	if not result.ok:
		return {}
	var owner: Dictionary = result.value
	if not owner.get("eligible", false):
		return owner
	return layer_by_id(int(owner.id))

func layer_display_name(layer: Dictionary) -> String:
	if String(layer.get("classname", "")) == "worldspawn":
		return "Worldspawn"
	var targetname := String(layer.get("targetname", "")).strip_edges()
	if not targetname.is_empty():
		return targetname
	return "Unnamed Layer #%d" % int(layer.id)

func _layer_allows_owner(owner_id: int) -> bool:
	layers()
	var is_layer: bool = _layer_ids.has(owner_id)
	if isolated_layer_id != 0:
		return is_layer and owner_id == isolated_layer_id
	if not is_layer:
		return true
	return not layer_hidden.get(owner_id, false)

func layer_visible(entity_id: int) -> bool:
	layers()
	if not _layer_ids.has(entity_id):
		return true
	if isolated_layer_id != 0 and entity_id != isolated_layer_id:
		return false
	return not layer_hidden.get(entity_id, false)

func worldspawn_layer_id() -> int:
	layers()
	return _worldspawn_layer_id

func is_layer_locked(entity_id: int) -> bool:
	return bool(layer_locked.get(entity_id, false))

func layer_locked_for_brush(brush_id: int) -> bool:
	var owner: Dictionary = layer_for_brush(brush_id)
	return not owner.is_empty() and bool(owner.get("eligible", true)) and is_layer_locked(int(owner.id))

func set_active_layer(entity_id: int) -> void:
	layers()
	if not _layer_ids.has(entity_id) or active_layer_id == entity_id:
		return
	active_layer_id = entity_id
	notify_changed("status")

func set_layer_eye(entity_id: int, visible: bool) -> void:
	layers()
	if not _layer_ids.has(entity_id):
		return
	var hidden_now: bool = layer_hidden.get(entity_id, false)
	if visible == (not hidden_now):
		return
	if visible:
		layer_hidden.erase(entity_id)
	else:
		layer_hidden[entity_id] = true
	prune(false)
	_sync_selection_generation()
	_sync_visibility_generation()
	notify_changed("visibility")

func set_layer_lock(entity_id: int, locked: bool) -> void:
	layers()
	if not _layer_ids.has(entity_id):
		return
	var locked_now: bool = is_layer_locked(entity_id)
	if locked == locked_now:
		return
	if locked:
		layer_locked[entity_id] = true
	else:
		layer_locked.erase(entity_id)
	_pick_hidden_cache_gen = -1
	prune_selection(false)
	_sync_selection_generation()
	notify_changed("selection")

func show_only_layer(entity_id: int) -> void:
	layers()
	if not _layer_ids.has(entity_id) or isolated_layer_id == entity_id:
		return
	isolated_layer_id = entity_id
	prune(false)
	_sync_selection_generation()
	_sync_visibility_generation()
	notify_changed("visibility")

func clear_layer_isolation() -> void:
	if isolated_layer_id == 0:
		return
	isolated_layer_id = 0
	prune(false)
	_sync_selection_generation()
	_sync_visibility_generation()
	notify_changed("visibility")

func set_layer_search(query: String) -> void:
	if layer_search == query:
		return
	layer_search = query
	notify_changed("status")

func pick_hidden_brush_ids() -> PackedInt64Array:
	_sync_visibility_generation()
	if _pick_hidden_cache_gen == _visibility_generation and _pick_hidden_lock_state == layer_locked:
		return _pick_hidden_cache
	var ids: Dictionary = {}
	for id in hidden_brush_ids():
		ids[id] = true
	for layer in layers():
		if not is_layer_locked(int(layer.id)):
			continue
		for brush_id in layer.brush_ids:
			ids[brush_id] = true
	_pick_hidden_cache = PackedInt64Array()
	_pick_hidden_cache.resize(ids.size())
	var cursor := 0
	for id in ids:
		_pick_hidden_cache[cursor] = id
		cursor += 1
	_pick_hidden_cache_gen = _visibility_generation
	_pick_hidden_lock_state = layer_locked.duplicate()
	return _pick_hidden_cache

func reject_locked_ids(ids: PackedInt64Array, operation: String) -> Dictionary:
	for id in ids:
		if layer_locked_for_brush(id):
			return failure_result("LOCKED_LAYER", "Locked layer members cannot be edited. Unlock the layer first.", operation)
	return success()

func reject_locked_edit(ids: PackedInt64Array, operation: String) -> bool:
	var locked := reject_locked_ids(ids, operation)
	if not locked.ok:
		report(locked)
		return true
	return false

func active_owner_locked() -> bool:
	layers()
	return is_layer_locked(active_layer_id)

func create_cuboid_in_active_layer(mins: Vector3, maxs: Vector3, texture_name: String) -> Dictionary:
	if active_owner_locked():
		return failure_result("LOCKED_LAYER", "The active layer is locked; unlock it or choose another layer before creating brushes.", "create_cuboid")
	return document.create_cuboid(mins, maxs, texture_name, active_layer_id)

func import_selection_in_active_layer(text_value: String) -> Dictionary:
	if active_owner_locked():
		return failure_result("LOCKED_LAYER", "The active layer is locked; unlock it or choose another layer before pasting.", "import_selection")
	return document.import_selection(text_value, active_layer_id)

func ineligible_move_category(ids: PackedInt64Array) -> String:
	for id in ids:
		var result: Dictionary = document.get_brush_owner(id)
		if not result.ok:
			return "unknown"
		if not result.value.get("eligible", false):
			var classname := String(result.value.get("classname", ""))
			return classname if not classname.is_empty() else "gameplay entity"
	return ""

func create_layer(targetname: String) -> bool:
	var created_id := 0
	var ok := transact("Create map layer", func():
		var result: Dictionary = document.create_func_group(targetname)
		if result.ok:
			created_id = int(result.value)
			active_layer_id = created_id
			layer_hidden.erase(created_id)
			layer_locked.erase(created_id)
		return result)
	return ok

func rename_layer(entity_id: int, targetname: String) -> bool:
	return transact("Rename map layer", func():
		var layer := layer_by_id(entity_id)
		if layer.is_empty() or String(layer.classname) != "func_group":
			return failure_result("INELIGIBLE_OWNER", "Only func_group layers can be renamed.", "rename_layer")
		if targetname.strip_edges().is_empty():
			return document.remove_entity_property(entity_id, "targetname")
		return document.set_entity_property(entity_id, "targetname", targetname))

func delete_layer(entity_id: int) -> bool:
	var ok := transact("Delete map layer", func():
		var result: Dictionary = document.delete_func_group_layer(entity_id)
		if result.ok:
			layer_hidden.erase(entity_id)
			layer_locked.erase(entity_id)
			if isolated_layer_id == entity_id:
				isolated_layer_id = 0
			if active_layer_id == entity_id:
				layers()
				active_layer_id = _worldspawn_layer_id
		return result)
	return ok

func move_selection_to_layer(owner_id: int) -> bool:
	var ids: PackedInt64Array = selected.duplicate()
	if ids.is_empty():
		return false
	var locked := reject_locked_ids(ids, "move_brushes_to_owner")
	if not locked.ok:
		report(locked)
		return false
	var category := ineligible_move_category(ids)
	if not category.is_empty():
		message.emit("Cannot move a mixed selection that includes %s; move only worldspawn or func_group brushes." % category)
		return false
	return transact("Move brushes to layer", func(): return document.move_brushes_to_owner(ids, owner_id))

func remove_selection_from_layer(owner_id: int) -> bool:
	var layer := layer_by_id(owner_id)
	if layer.is_empty() or String(layer.classname) != "func_group":
		message.emit("Remove Selection is only available on func_group layers.")
		return false
	var members: Dictionary = {}
	for brush_id in layer.brush_ids:
		members[int(brush_id)] = true
	var ids := PackedInt64Array()
	for id in selected:
		if members.has(id):
			ids.append(id)
	if ids.is_empty():
		return false
	var locked := reject_locked_ids(ids, "move_brushes_to_owner")
	if not locked.ok:
		report(locked)
		return false
	var category := ineligible_move_category(ids)
	if not category.is_empty():
		message.emit("Cannot move a mixed selection that includes %s; move only worldspawn or func_group brushes." % category)
		return false
	return transact("Remove brushes from layer", func(): return document.move_brushes_to_owner(ids, _worldspawn_layer_id))

func select_layer_members(owner_id: int, add := false) -> void:
	var layer := layer_by_id(owner_id)
	if layer.is_empty():
		return
	var ids := PackedInt64Array()
	var omitted_hidden := 0
	var omitted_locked := 0
	var locked_layer := is_layer_locked(owner_id)
	for brush_id in layer.brush_ids:
		var item := brush(int(brush_id))
		if locked_layer or layer_locked_for_brush(int(brush_id)):
			omitted_locked += 1
			continue
		if not brush_visible(item):
			omitted_hidden += 1
			continue
		ids.append(int(brush_id))
	if add:
		var combined: PackedInt64Array = selected.duplicate()
		for id in ids:
			if not combined.has(id):
				combined.append(id)
		select(combined)
	else:
		select(ids)
	if omitted_hidden > 0 or omitted_locked > 0:
		message.emit("Selected %d members; omitted %d hidden and %d locked." % [ids.size(), omitted_hidden, omitted_locked])
