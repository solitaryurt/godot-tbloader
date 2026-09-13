#ifndef TB_MAP_DOCUMENT_H
#define TB_MAP_DOCUMENT_H

#include "map/map_data.h"
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
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
};
}
#endif
