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

namespace godot {

class TBMapDocument : public RefCounted {
	GDCLASS(TBMapDocument, RefCounted);
	std::shared_ptr<LMMapData> map;
	String path;
	String disk_path;
	std::string canonical, baseline, disk_bytes;
	bool has_baseline = false;
	int64_t epoch = 0, revision = 0, next_id = 1, topology = 0;
	std::unordered_map<int64_t, char> issued_ids;
	Dictionary texture_sizes;
	Dictionary finish_edit(const LMMapEdit &edit, const StringName &operation, const Variant &value = Variant());
	Dictionary check_brushes(const PackedInt64Array &ids, const StringName &operation) const;
	Dictionary check_face(int64_t id, int face, int64_t token, const StringName &operation) const;
	Dictionary move_components(const Array &components, Vector3 delta, const StringName &operation);
	void resolve_texture_sizes(LMMapData &data, const Dictionary &sizes) const;

	Dictionary replace_text(const std::string &text, const StringName &operation, const String &new_path, bool saved);
	Dictionary prepare(const std::string &text, std::shared_ptr<LMMapData> &candidate, const StringName &operation, const String &error_path) const;
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
	Dictionary rebuild();
	bool is_dirty() const { return !has_baseline || canonical != baseline; }
	String get_path() const { return path; }
	int64_t get_revision() const { return revision; }
	int64_t get_epoch() const { return epoch; }
	PackedStringArray get_texture_names() const;
	// Copied ownership/property data for the future N inspector. Primitive IDs use
	// the same source order and schema as snapshot identities; no native pointers.
	Array get_entities() const;
	Array get_draw_data() const;
	Array get_preview_data() const;
	Dictionary create_cuboid(Vector3 mins, Vector3 maxs, const String &texture);
	Dictionary duplicate_brushes(const PackedInt64Array &ids);
	Dictionary delete_brushes(const PackedInt64Array &ids);
	Dictionary translate_brushes(const PackedInt64Array &ids, Vector3 delta);
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
};
}
#endif
