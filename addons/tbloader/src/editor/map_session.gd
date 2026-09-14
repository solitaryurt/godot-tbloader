@tool
extends RefCounted

signal changed
signal message(text: String)
signal action_recorded(token: RefCounted)

const Action = preload("res://addons/tbloader/src/editor/map_action.gd")
const HISTORY_CACHE_LIMIT = 4
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
var _draw_positions: Dictionary = {}
var _entity_cache: Array = []
var _brush_entity_ids: Dictionary = {}
var _marker_cache: Array = []
var _draw_valid = false
var _entity_valid = false
var _marker_valid = false
var _pending_brush_translation: Dictionary = {}
var _history_caches: Dictionary = {}
var _history_cache_order: Array = []
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
	if not _pending_brush_translation.is_empty() and _draw_valid:
		patch_draw_translation(_pending_brush_translation.ids, _pending_brush_translation.delta)
	else:
		_draw_valid = false
		_draw_index = {}
		_draw_positions = {}
		_entity_valid = false
		_brush_entity_ids = {}
		_marker_valid = false
	preview_generation += 1

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
	return true

func patch_draw_translation(ids: PackedInt64Array, movement: Vector3) -> void:
	var topology_revision: int = document.get_topology_revision()
	# Preserve the historical array before replacing translated entries. Revision
	# tokens are rebound whenever a cached state becomes current.
	_draw_cache = _draw_cache.duplicate()
	_draw_index = _draw_index.duplicate()
	for cached in _draw_cache:
		cached.topology_revision = topology_revision
		_draw_index[cached.id] = cached
	for id in ids:
		if not _draw_index.has(id):
			continue
		var item: Dictionary = _draw_index[id].duplicate(true)
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
		var index: int = _draw_positions.get(id, -1)
		if index >= 0:
			_draw_cache[index] = item
		_draw_index[id] = item

func translate_brushes(ids: PackedInt64Array, movement: Vector3) -> Dictionary:
	_pending_brush_translation = {"ids": ids, "delta": movement}
	var result: Dictionary = document.translate_brushes(ids, movement)
	_pending_brush_translation.clear()
	return result

func _preview_changed() -> void:
	# Rebuilds can replace topology caches without changing canonical map text.
	_draw_valid = false
	_draw_index = {}
	_draw_positions = {}
	preview_generation += 1

func dispose() -> void:
	if document.map_changed.is_connected(_map_changed):
		document.map_changed.disconnect(_map_changed)
	if document.preview_changed.is_connected(_preview_changed):
		document.preview_changed.disconnect(_preview_changed)
	_draw_cache.clear()
	_draw_index.clear()
	_draw_positions.clear()
	_entity_cache.clear()
	_brush_entity_ids.clear()
	_marker_cache.clear()
	_history_caches.clear()
	_history_cache_order.clear()

func draw_data() -> Array:
	if not _draw_valid:
		_draw_cache = document.get_draw_data()
		_draw_index.clear()
		_draw_positions.clear()
		for position in _draw_cache.size():
			var item: Dictionary = _draw_cache[position]
			_draw_index[item.id] = item
			_draw_positions[item.id] = position
		_draw_valid = true
	return _draw_cache

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
	var captured_components := components.filter(func(c): return component_valid(c, brush(c.brush_id))).duplicate(true)
	_remember_history_cache(native)
	return {"native": native, "selected_brush_ids": selected.duplicate(), "points": points.duplicate(),
		"components": captured_components, "workzone": workzone}

func _remember_history_cache(state: RefCounted) -> void:
	var state_id := state.get_instance_id()
	var cached := {}
	if _draw_valid:
		cached.draw = _draw_cache
		cached.draw_index = _draw_index
		cached.draw_positions = _draw_positions
	if _entity_valid:
		cached.entities = _entity_cache
		cached.brush_entity_ids = _brush_entity_ids
	if _marker_valid:
		cached.markers = _marker_cache
	if cached.is_empty():
		return
	if _history_caches.has(state_id):
		_history_cache_order.erase(state_id)
	_history_caches[state_id] = cached
	_history_cache_order.append(state_id)
	while _history_cache_order.size() > HISTORY_CACHE_LIMIT:
		_history_caches.erase(_history_cache_order.pop_front())

func _restore_history_cache(state: RefCounted) -> void:
	var cached: Dictionary = _history_caches.get(state.get_instance_id(), {})
	if cached.has("draw"):
		_draw_cache = cached.draw.duplicate()
		_draw_index = cached.draw_index.duplicate()
		_draw_positions = cached.draw_positions.duplicate()
		var topology_revision: int = document.get_topology_revision()
		for item in _draw_cache:
			item.topology_revision = topology_revision
		_draw_valid = true
	if cached.has("entities"):
		_entity_cache = cached.entities
		_brush_entity_ids = cached.brush_entity_ids.duplicate()
		_entity_valid = true
	if cached.has("markers"):
		_marker_cache = cached.markers
		_marker_valid = true

func restore(state: Dictionary) -> void:
	var result: Dictionary = document.restore_history_state(state.native)
	if not result.ok:
		report(result)
		return
	_restore_history_cache(state.native)
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

func report(result: Dictionary) -> bool:
	if not result.ok:
		var e: Dictionary = result.error
		message.emit("%s: %s %s%s" % [e.code, e.message, e.path,
			(" (%d:%d)" % [e.line, e.column]) if e.line else ""])
	return result.ok

func transact(label: String, operation: Callable, kind := "") -> bool:
	var before = capture()
	var result: Dictionary = operation.call()
	if not report(result):
		# Multi-command tools are atomic at the UI transaction boundary too.
		if not document.is_history_state_current(before.native):
			restore(before)
		return false
	prune()
	var after = capture()
	if document.is_history_state_current(before.native):
		notify_changed()
		return false
	var token = Action.new()
	save_enabled = true
	token.session = self
	token.before = before
	token.after = after
	token.epoch = document.get_epoch()
	token.bytes = before.native.get_retained_bytes() + after.native.get_additional_retained_bytes(before.native)
	manager.create_action(label, UndoRedo.MERGE_DISABLE, self)
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
	return _draw_index.get(id, {})

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
	var result := PackedInt64Array()
	for id in hidden:
		result.append(id)
	return result

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
		var item: Dictionary = _draw_index.get(id, {})
		if brush_visible(item):
			valid.append(id)
	selected = valid
	components = components.filter(func(c): return component_valid(c, _draw_index.get(c.brush_id, {})))
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
		var item: Dictionary = _draw_index[id]
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

func material_filtered(texture: String) -> bool:
	var name := texture.to_lower().replace("\\", "/").get_file().get_basename()
	if visibility_filters.caulk and name == "caulk":
		return true
	if visibility_filters.hint_skip and name == "hint_skip":
		return true
	return visibility_filters.clips and (name == "clip" or name.begins_with("clip") or name.ends_with("clip"))

func brush_visible(item: Dictionary) -> bool:
	if item.is_empty() or hidden.has(item.id):
		return false
	if visibility_filters.entities and brush_has_entity_owner(item):
		return false
	if item.faces.is_empty():
		return true
	return not item.faces.all(func(face): return material_filtered(face.texture))

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
