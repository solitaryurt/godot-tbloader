#ifndef TB_MAP_DOCUMENT_H
#define TB_MAP_DOCUMENT_H

#include "map/map_data.h"
#include "map/map_edit.h"
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <memory>
#include <unordered_map>
#include <vector>

namespace godot {

class TBMapDocumentState : public RefCounted {
	GDCLASS(TBMapDocumentState, RefCounted);
	friend class TBMapDocument;
	std::shared_ptr<LMMapData> map;
	std::shared_ptr<const std::string> canonical;
	Dictionary texture_sizes;
	int64_t epoch = 0;

protected:
	static void _bind_methods();

public:
	int64_t get_retained_bytes() const;
	int64_t get_additional_retained_bytes(const Ref<TBMapDocumentState> &other) const;
};

class TBMapDocument : public RefCounted {
	GDCLASS(TBMapDocument, RefCounted);
	std::shared_ptr<LMMapData> map;
	String path;
	String disk_path;
	std::shared_ptr<const std::string> canonical = std::make_shared<const std::string>();
	std::string baseline, disk_bytes;
	bool has_baseline = false;
	int64_t epoch = 0, revision = 0, next_id = 1, topology = 0;
	std::unordered_map<int64_t, char> issued_ids;
	struct LiveLocation {
		char kind;
		int entity;
		int index;
		int primitive;
	};
	std::unordered_map<int64_t, LiveLocation> live_ids;
	struct SpatialIndex;
	mutable std::shared_ptr<SpatialIndex> spatial_index;
	struct PreviewCache;
	std::shared_ptr<PreviewCache> preview_cache;
	Dictionary texture_sizes;
	void rebuild_live_index();
	void invalidate_spatial_index();
	void invalidate_preview_cache();
	const SpatialIndex &get_spatial_index() const;
	const LiveLocation *live_location(int64_t id, char kind) const;
	LMEditEntity *edit_entity(LMMapEdit &edit, int64_t id) const;
	LMEditPrimitive *edit_brush(LMMapEdit &edit, int64_t id) const;
	Dictionary prepare_edit_candidate(const LMMapEdit &edit, const StringName &operation, std::shared_ptr<LMMapData> &candidate, std::string &normalized, int64_t &high) const;
	Dictionary finish_edit(const LMMapEdit &edit, const StringName &operation, const Variant &value = Variant());
	Dictionary preview_edit(const LMMapEdit &edit, const StringName &operation, const Dictionary &sources) const;
	Dictionary check_brushes(const PackedInt64Array &ids, const StringName &operation) const;
	Dictionary check_face(int64_t id, int face, int64_t token, const StringName &operation) const;
	Dictionary move_components(const Array &components, Vector3 delta, const StringName &operation);
	Dictionary stage_components(const Array &components, Vector3 delta, const StringName &operation, LMMapEdit &edit, Dictionary &sources) const;
	Dictionary stage_clip(const PackedInt64Array &ids, Vector3 p0, Vector3 p1, Vector3 p2, bool split, const StringName &operation, LMMapEdit &edit, PackedInt64Array &out, Dictionary &sources) const;
	Dictionary build_translation_candidate(const PackedInt64Array &ids, Vector3 delta, const StringName &operation, std::shared_ptr<LMMapData> &candidate, std::string &normalized) const;
	void resolve_texture_sizes(LMMapData &data, const Dictionary &sizes) const;

	Dictionary replace_text(const std::string &text, const StringName &operation, const String &new_path, bool saved);
	Dictionary prepare(const std::string &text, std::shared_ptr<LMMapData> &candidate, const StringName &operation, const String &error_path, std::string *normalized = nullptr) const;
	void assign_ids(LMMapData &candidate);
	void commit(std::shared_ptr<LMMapData> candidate, const std::string &text, bool was_dirty);
	Dictionary identities(const LMMapData &data) const;
	bool apply_identities(LMMapData &data, const Dictionary &ids) const;
	static Dictionary success(bool changed = false, const Variant &value = Variant());
	static Dictionary failure(const StringName &code, const String &message, const StringName &operation, const String &path = String(), int line = 0, int column = 0);

protected:
	static void _bind_methods();

public:
	TBMapDocument();
	Dictionary new_map();
	Dictionary import_text(const String &text);
	Dictionary load_map(const String &path);
	Dictionary save_map(const String &path);
	Dictionary export_text() const;
	Dictionary snapshot() const;
	Dictionary restore_snapshot(const Dictionary &snapshot);
	Ref<TBMapDocumentState> capture_history_state() const;
	Dictionary restore_history_state(const Ref<TBMapDocumentState> &state);
	bool is_history_state_current(const Ref<TBMapDocumentState> &state) const;
	Dictionary rebuild();
	bool is_dirty() const { return !has_baseline || *canonical != baseline; }
	String get_path() const { return path; }
	int64_t get_revision() const { return revision; }
	int64_t get_topology_revision() const { return topology; }
	int64_t get_epoch() const { return epoch; }
	PackedStringArray get_texture_names() const;
	// Copied ownership/property data for the future N inspector. Primitive IDs use
	// the same source order and schema as snapshot identities; no native pointers.
	Array get_entities() const;
	Array get_draw_data() const;
	Array get_preview_data() const;
	Dictionary prepare_preview_chunks(double scale, const PackedInt64Array &hidden_ids, int filter_mask, int chunk_triangles = 2048, double chunk_size = 64.0);
	Dictionary get_preview_chunk(const String &chunk_id) const;
	PackedInt64Array query_brushes_2d(int hidden_axis, Vector3 mins, Vector3 maxs) const;
	Array query_ray(Vector3 origin, Vector3 direction, double max_distance = 1e30) const;
	Dictionary query_ray_nearest_visible(Vector3 origin, Vector3 direction, double max_distance, const PackedInt64Array &hidden_ids, int filter_mask) const;
	Dictionary create_cuboid(Vector3 mins, Vector3 maxs, const String &texture);
	Dictionary duplicate_brushes(const PackedInt64Array &ids);
	Dictionary merge_brushes(const PackedInt64Array &ids);
	Dictionary delete_brushes(const PackedInt64Array &ids);
	Dictionary translate_brushes(const PackedInt64Array &ids, Vector3 delta);
	Dictionary rotate_brushes(const PackedInt64Array &ids, Vector3 pivot, int axis, double radians);
	Dictionary preview_translate_brushes(const PackedInt64Array &ids, Vector3 delta) const;
	Dictionary preview_rotate_brushes(const PackedInt64Array &ids, Vector3 pivot, int axis, double radians) const;
	Dictionary translate_face(int64_t id, int face, Vector3 delta, int64_t topology_revision);
	Dictionary set_brush_texture(const PackedInt64Array &ids, const String &name);
	Dictionary set_face_texture(int64_t id, int face, const String &name, int64_t topology_revision);
	Dictionary get_face_uv(int64_t id, int face, int64_t topology_revision) const;
	Dictionary set_face_uv(int64_t id, int face, Vector2 shift, double rotation, Vector2 scale, int64_t topology_revision);
	Dictionary set_texture_sizes(const Dictionary &sizes);
	Dictionary export_selection(const PackedInt64Array &ids) const;
	Dictionary import_selection(const String &text);
	Dictionary create_point_entity(const String &classname, Vector3 origin);
	Dictionary set_entity_property(int64_t id, const String &key, const String &value);
	Dictionary remove_entity_property(int64_t id, const String &key);
	Dictionary translate_point_entities(const PackedInt64Array &ids, Vector3 delta);
	Dictionary group_brushes(const PackedInt64Array &ids, const String &classname);
	Dictionary return_brushes_to_worldspawn(const PackedInt64Array &ids);
	Dictionary delete_entities(const PackedInt64Array &ids, bool delete_owned_brushes);
	Dictionary make_prism(int64_t id, int sides, int axis);
	Dictionary translate_vertices(int64_t id, const PackedInt32Array &vertex_indices, Vector3 delta, int64_t topology_revision);
	Dictionary translate_components(const Array &components, Vector3 delta);
	Dictionary clip_brushes(const PackedInt64Array &ids, Vector3 p0, Vector3 p1, Vector3 p2, bool split);
	Dictionary preview_translate_components(const Array &components, Vector3 delta) const;
	Dictionary preview_clip_brushes(const PackedInt64Array &ids, Vector3 p0, Vector3 p1, Vector3 p2, bool split, bool flip = false) const;
};
}
#endif
