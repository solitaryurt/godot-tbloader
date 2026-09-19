#ifndef TB_MAP_DOCUMENT_H
#define TB_MAP_DOCUMENT_H

#include "map/map_data.h"
#include "map/map_edit.h"
#include "map/editor_brush_geometry.h"
#include "map/face.h"
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <memory>
#include <functional>
#include <string>
#include <unordered_map>
#include <vector>

namespace godot {

class TBMapDocumentState : public RefCounted {
	GDCLASS(TBMapDocumentState, RefCounted);
	friend class TBMapDocument;
	friend class TBMapDocumentChange;
	std::shared_ptr<LMMapData> map;
	std::shared_ptr<const std::string> canonical;
	struct BaseEditorGeometry {
		std::unordered_map<int64_t, std::shared_ptr<const LMEditorBrushGeometry>> brushes;
		size_t retained_bytes() const;
		size_t additional_retained_bytes(const BaseEditorGeometry *other) const;
	};
	std::shared_ptr<const BaseEditorGeometry> base_geometry;
	struct EditorState {
		struct ChangeSet {
			int64_t from_generation = 0;
			std::vector<int64_t> brush_ids;
			LMEditorBrushDirtyDomain domains = LMEditorBrushDirtyDomain::NONE;
			StringName operation;
		};
		struct BrushRecord {
			LMBrush brush{};
			std::vector<LMFace> faces;
			std::vector<std::string> materials;
			std::shared_ptr<const LMEditorBrushGeometry> geometry;
			uint64_t source_generation = 0;
			BrushRecord(const LMBrush &source, std::vector<LMFace> source_faces, std::vector<std::string> source_materials, LMEditorBrushGeometry built, uint64_t generation) :
					brush(source), faces(std::move(source_faces)), materials(std::move(source_materials)), source_generation(generation) {
				brush.faces = faces.data();
				built.brush_id = brush.id; built.source_generation = generation;
				geometry = std::make_shared<const LMEditorBrushGeometry>(std::move(built));
			}
			BrushRecord(const BrushRecord &source, std::shared_ptr<const LMEditorBrushGeometry> updated_geometry) :
					brush(source.brush), faces(source.faces), materials(source.materials), geometry(std::move(updated_geometry)), source_generation(source.source_generation) {
				brush.faces = faces.data();
			}
			BrushRecord(const LMBrush &source, std::vector<LMFace> source_faces, std::vector<std::string> source_materials,
					std::shared_ptr<const LMEditorBrushGeometry> source_geometry, uint64_t generation) :
					brush(source), faces(std::move(source_faces)), materials(std::move(source_materials)), geometry(std::move(source_geometry)), source_generation(generation) {
				brush.faces = faces.data();
			}
		};
		std::unordered_map<int64_t, std::shared_ptr<const BrushRecord>> brushes;
		int64_t canonical_size_delta = 0;
		ChangeSet change;
	};
	std::shared_ptr<const EditorState> editor;
	Dictionary texture_sizes;
	int64_t epoch = 0;
	int64_t state_generation = 0;

protected:
	static void _bind_methods();

public:
	int64_t get_retained_bytes() const;
	int64_t get_additional_retained_bytes(const Ref<TBMapDocumentState> &other) const;
	int64_t get_state_generation() const { return state_generation; }
};

class TBMapDocumentChange : public RefCounted {
	GDCLASS(TBMapDocumentChange, RefCounted);
	friend class TBMapDocument;
	using BrushRecord = TBMapDocumentState::EditorState::BrushRecord;
	struct BrushMemento {
		int64_t id = 0;
		std::shared_ptr<const BrushRecord> before;
		std::shared_ptr<const BrushRecord> after;
	};
	int64_t epoch = 0;
	int64_t before_generation = -1, after_generation = -1;
	int64_t texture_context_generation = 0;
	int64_t before_canonical_size = 0, after_canonical_size = 0;
	StringName operation;
	LMEditorBrushDirtyDomain domains = LMEditorBrushDirtyDomain::NONE;
	std::vector<BrushMemento> brushes;

protected:
	static void _bind_methods();

public:
	int64_t get_epoch() const { return epoch; }
	int64_t get_before_generation() const { return before_generation; }
	int64_t get_after_generation() const { return after_generation; }
	int64_t get_changed_brush_count() const { return static_cast<int64_t>(brushes.size()); }
	int64_t get_retained_bytes() const;
	int64_t get_additional_retained_bytes(const Ref<TBMapDocumentChange> &other) const;
};

class TBMapDocument : public RefCounted {
	GDCLASS(TBMapDocument, RefCounted);
	std::shared_ptr<LMMapData> map;
	String path;
	String disk_path;
	std::shared_ptr<const std::string> canonical = std::make_shared<const std::string>();
	using EditorState = TBMapDocumentState::EditorState;
	std::shared_ptr<const EditorState> editor;
	std::shared_ptr<const TBMapDocumentState::BaseEditorGeometry> base_geometry;
	mutable std::shared_ptr<const std::string> materialized_canonical;
	struct OperationCounters {
		int64_t brush_builds = 0, compact_full_builds = 0, compact_uv_updates = 0, compact_shared_brushes = 0, brush_source_copies = 0, parser_calls = 0, writer_calls = 0, geo_generator_calls = 0;
		int64_t parser_us = 0, canonical_writer_us = 0, compact_build_us = 0, compact_uv_update_us = 0, compact_uv_copy_bytes = 0, source_retained_bytes = 0, compact_retained_bytes = 0;
		int64_t materializations = 0, source_clones = 0, source_clone_retained_bytes = 0, deep_clones = 0;
		int64_t topology_dirty = 0, positions_dirty = 0, uv_dirty = 0, material_dirty = 0, preview_dirty = 0, spatial_dirty = 0;
		int64_t restore_touched_brushes = 0, restore_full_resets = 0;
		StringName operation;
		bool success = false, committed = false;
	};
	mutable OperationCounters last_operation;
	mutable bool translation_counter_scope = false;
	std::string baseline, disk_bytes;
	bool has_baseline = false;
	int64_t saved_state_generation = -1;
	int64_t epoch = 0, revision = 0, next_id = 1, topology = 0, state_generation = 0, next_state_generation = 0, texture_context_generation = 0;
	struct NativeChange {
		int64_t before_generation = -1;
		int64_t generation = -1;
		StringName operation;
		LMEditorBrushDirtyDomain domains = LMEditorBrushDirtyDomain::NONE;
		std::vector<int64_t> brush_ids;
		std::vector<int64_t> added_ids;
		std::vector<int64_t> removed_ids;
		bool reset = true;
		bool entities_changed = true;
		bool ownership_changed = true;
		bool points_changed = true;
	};
	NativeChange last_change;
	Ref<TBMapDocumentChange> last_document_change;
	std::unordered_map<int64_t, char> issued_ids;
	struct LiveLocation {
		char kind;
		int entity;
		int index;
		int primitive;
	};
	std::unordered_map<int64_t, LiveLocation> live_ids;
	struct BrushGeometryView {
		const LMBrush *brush = nullptr;
		const LMEditorBrushGeometry *compact = nullptr;
	};
	struct LocalBrushDraft {
		int64_t id = 0;
		int entity = 0;
		int index = 0;
		LMBrush brush{};
		std::vector<LMFace> faces;
		std::vector<std::string> materials;
	};
	using LocalBrushMutation = std::function<Dictionary(std::vector<LocalBrushDraft> &)>;
	struct CurrentTransition {
		int64_t from_generation = 0;
		std::vector<int64_t> brush_ids;
		bool compatible = false;
	};
	CurrentTransition transition;
	struct SpatialIndex;
	mutable std::shared_ptr<SpatialIndex> spatial_index;
	mutable std::vector<std::shared_ptr<SpatialIndex>> spatial_history;
	struct PreviewCache;
	std::shared_ptr<PreviewCache> preview_cache;
	std::vector<std::shared_ptr<PreviewCache>> preview_history;
	int64_t preview_history_evictions = 0;
	bool preview_history_restored = false;
	Dictionary texture_sizes;
	StringName last_preview_change_reason;
	void rebuild_live_index();
	void invalidate_spatial_index();
	void clear_spatial_caches();
	void advance_spatial_index(const std::shared_ptr<const EditorState> &next, const std::vector<int64_t> &ids, LMEditorBrushDirtyDomain domains, int64_t generation);
	void invalidate_preview_cache();
	void clear_preview_caches();
	void retain_spatial_index();
	void restore_spatial_index();
	void rebind_spatial_indexes(const std::shared_ptr<LMMapData> &previous);
	void rebind_spatial_context();
	void append_spatial_cache_counters(Dictionary &out) const;
	void retain_preview_cache();
	void restore_preview_cache();
	const SpatialIndex &get_spatial_index() const;
	const LiveLocation *live_location(int64_t id, char kind) const;
	LMEditEntity *edit_entity(LMMapEdit &edit, int64_t id) const;
	LMEditPrimitive *edit_brush(LMMapEdit &edit, int64_t id) const;
	Dictionary prepare_edit_candidate(const LMMapEdit &edit, const StringName &operation, std::shared_ptr<LMMapData> &candidate, std::shared_ptr<const TBMapDocumentState::BaseEditorGeometry> &geometry, std::string &normalized, int64_t &high) const;
	Dictionary finish_edit(const LMMapEdit &edit, const StringName &operation, const Variant &value = Variant());
	Dictionary preview_edit(const LMMapEdit &edit, const StringName &operation, const Dictionary &sources) const;
	void stage_preview_brushes(const PackedInt64Array &ids, LMMapEdit &edit) const;
	Dictionary preview_fragments(const LMMapEdit &before, const LMMapEdit &after, const StringName &operation, const Dictionary &sources) const;
	Dictionary check_brushes(const PackedInt64Array &ids, const StringName &operation) const;
	Dictionary check_face(int64_t id, int face, int64_t token, const StringName &operation) const;
	Dictionary move_components(const Array &components, Vector3 delta, const StringName &operation);
	Dictionary local_brush_transaction(const std::vector<int64_t> &ids, const StringName &operation, LMEditorBrushDirtyDomain domains, const LocalBrushMutation &mutation);
	Dictionary stage_components(const Array &components, Vector3 delta, const StringName &operation, LMMapEdit &edit, Dictionary &sources) const;
	Dictionary stage_clip(const PackedInt64Array &ids, Vector3 p0, Vector3 p1, Vector3 p2, bool split, const StringName &operation, LMMapEdit &edit, PackedInt64Array &out, Dictionary &sources) const;
	void resolve_texture_sizes(LMMapData &data, const Dictionary &sizes) const;
	Dictionary build_base_editor_geometry(LMMapData &data, const Dictionary &sizes, std::shared_ptr<const TBMapDocumentState::BaseEditorGeometry> &out, const StringName &operation, const String &error_path) const;
	Dictionary update_texture_context_geometry(const LMMapData &data, const std::shared_ptr<const TBMapDocumentState::BaseEditorGeometry> &source_base,
			const std::shared_ptr<const EditorState> &source_editor, const Dictionary &old_sizes, const Dictionary &new_sizes,
			std::shared_ptr<const TBMapDocumentState::BaseEditorGeometry> &out_base, std::shared_ptr<const EditorState> &out_editor,
			const StringName &operation) const;
	const LMBrush &current_brush(int entity, int brush) const;
	std::string current_face_texture(int entity, int brush, int face) const;
	const char *current_face_texture_cstr(int entity, int brush, int face) const;
	String intern_face_texture(int entity, int brush, int face, void *intern_state) const;
	Dictionary make_draw_brush_entry(int entity, int brush, void *intern_state) const;
	BrushGeometryView current_brush_geometry(int entity, int brush) const;
	std::shared_ptr<LMMapData> materialize_source_state(const std::shared_ptr<LMMapData> &base, const std::shared_ptr<const EditorState> &overlay) const;
	std::shared_ptr<LMMapData> materialize_current_source() const;
	const std::string &canonical_text(bool retain_materialized_view = false) const;
	void clear_editor_state();

	Dictionary replace_text(const std::string &text, const StringName &operation, const String &new_path, bool saved);
	Dictionary prepare(const std::string &text, std::shared_ptr<LMMapData> &candidate, const StringName &operation, const String &error_path, std::string *normalized = nullptr) const;
	void assign_ids(LMMapData &candidate);
	void commit(std::shared_ptr<LMMapData> candidate, std::shared_ptr<const TBMapDocumentState::BaseEditorGeometry> geometry, const std::string &text, bool was_dirty);
	void commit(std::shared_ptr<LMMapData> candidate, std::shared_ptr<const TBMapDocumentState::BaseEditorGeometry> geometry, std::shared_ptr<const std::string> text, bool was_dirty);
	Dictionary identities(const LMMapData &data) const;
	bool apply_identities(LMMapData &data, const Dictionary &ids) const;
	bool copy_identities(const LMMapData &from, LMMapData &to) const;
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
	Ref<TBMapDocumentChange> get_last_document_change() const;
	Dictionary apply_document_change(const Ref<TBMapDocumentChange> &change, bool use_after);
	Dictionary rebuild();
	bool is_dirty() const;
	String get_path() const { return path; }
	int64_t get_revision() const { return revision; }
	int64_t get_topology_revision() const { return topology; }
	int64_t get_epoch() const { return epoch; }
	int64_t get_state_generation() const { return state_generation; }
	std::shared_ptr<LMMapData> clone_map_for_build() const { return materialize_current_source(); }
	Dictionary get_last_operation_counters() const;
	Dictionary get_last_change() const;
	Dictionary get_draw_changes() const;
	Dictionary get_preview_cache_counters() const;
	Dictionary get_cache_root_counters() const;
	StringName get_last_preview_change_reason() const { return last_preview_change_reason; }
	PackedStringArray get_texture_names() const;
	// Copied ownership/property data for the future N inspector. Primitive IDs use
	// the same source order and schema as snapshot identities; no native pointers.
	Array get_entities() const;
	Array get_draw_data() const;
	Array get_preview_data() const;
	PackedVector2Array get_face_preview_uvs(const Array &targets, const String &texture) const;
	Dictionary summarize_faces(const Array &targets) const;
	Dictionary prepare_preview_chunks(double scale, const PackedInt64Array &hidden_ids, int filter_mask, int chunk_triangles = 2048, double chunk_size = 64.0);
	Dictionary get_preview_chunk(const String &chunk_id) const;
	PackedInt64Array query_brushes_2d(int hidden_axis, Vector3 mins, Vector3 maxs) const;
	Dictionary query_brush_2d_hit(int hidden_axis, Vector3 point, double tolerance, const PackedInt64Array &hidden_ids,
			int filter_mask, const PackedInt64Array &selected_ids, bool prefer_selected) const;
	Dictionary query_brush_camera_hit(Vector3 origin, Vector3 forward, Vector3 right, Vector3 up, Vector2 viewport_size,
			double vertical_fov, Vector2 position, double aperture, const PackedInt64Array &hidden_ids, int filter_mask) const;
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
	Dictionary apply_face_edits(const Array &edits);
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
