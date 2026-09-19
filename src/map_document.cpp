#include "map_document.h"
#include "map/brush.h"
#include "map/face.h"
#include "map/patch.h"
#include "map/map_parser.h"
#include "map/map_writer.h"
#include "map/brush_topology.h"
#include "map/brush_geometry_math.h"
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <atomic>
#include <algorithm>
#include <chrono>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <map>
#include <set>
#include <unordered_set>
#include <vector>
#ifndef _WIN32
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

using namespace godot;

namespace {
std::atomic<int64_t> epoch_counter{ 0 };
std::string utf8(const String &text) {
	auto bytes = text.utf8();
	return std::string(bytes.get_data(), bytes.length());
}
String string(const std::string &text) { return String::utf8(text.data(), text.size()); }
String absolute_path(const String &path) {
	String absolute = ProjectSettings::get_singleton()->globalize_path(path).simplify_path();
#ifndef _WIN32
	// Canonicalize aliases, including a not-yet-existing file's parent directory.
	// Save through a symlink targets its file, preserving the link itself.
	char *resolved = realpath(utf8(absolute).c_str(), nullptr);
	if (resolved) {
		absolute = String::utf8(resolved);
		free(resolved);
	} else {
		resolved = realpath(utf8(absolute.get_base_dir().is_empty() ? String(".") : absolute.get_base_dir()).c_str(), nullptr);
		if (resolved) {
			absolute = String::utf8(resolved).path_join(absolute.get_file());
			free(resolved);
		}
	}
#endif
	return absolute;
}
bool read_bytes(const String &path, std::string &bytes) {
	Ref<FileAccess> file = FileAccess::open(path, FileAccess::READ);
	if (file.is_null() || file->get_length() > LMMapParser::MAX_TEXT_BYTES) return false;
	auto buffer = file->get_buffer(file->get_length());
	if (static_cast<uint64_t>(buffer.size()) != file->get_length()) return false;
	bytes.assign(buffer.size() ? reinterpret_cast<const char *>(buffer.ptr()) : "", buffer.size());
	return true;
}
}

Dictionary TBMapDocument::success(bool changed, const Variant &value) {
	Dictionary result;
	result["ok"] = true; result["changed"] = changed; result["value"] = value; result["error"] = Dictionary();
	return result;
}
Dictionary TBMapDocument::failure(const StringName &code, const String &message, const StringName &operation, const String &error_path, int line, int column) {
	Dictionary error;
	error["code"] = code; error["message"] = message; error["operation"] = operation; error["path"] = error_path;
	error["line"] = line; error["column"] = column; error["entity_id"] = int64_t(0); error["brush_id"] = int64_t(0); error["face"] = -1;
	Dictionary result;
	result["ok"] = false; result["changed"] = false; result["value"] = Variant(); result["error"] = error;
	return result;
}

TBMapDocument::TBMapDocument() { new_map(); }

const LMBrush &TBMapDocument::current_brush(int entity, int brush) const {
	const LMBrush &base = map->entities[entity].brushes[brush];
	if (editor) {
		auto found = editor->brushes.find(base.id);
		if (found != editor->brushes.end()) return found->second->brush;
	}
	return base;
}

const char *TBMapDocument::current_face_texture_cstr(int entity, int brush, int face) const {
	const LMBrush &base = map->entities[entity].brushes[brush];
	if (editor) {
		auto found = editor->brushes.find(base.id);
		if (found != editor->brushes.end()) return found->second->materials[face].c_str();
	}
	const int texture = base.faces[face].texture_idx;
	return texture >= 0 && texture < map->texture_count ? map->textures[texture].name : "";
}

std::string TBMapDocument::current_face_texture(int entity, int brush, int face) const {
	const char *name = current_face_texture_cstr(entity, brush, face);
	return name ? std::string(name) : std::string();
}

TBMapDocument::BrushGeometryView TBMapDocument::current_brush_geometry(int entity, int brush) const {
	const LMBrush &base_brush = map->entities[entity].brushes[brush];
	if (editor) {
		auto found = editor->brushes.find(base_brush.id);
		if (found != editor->brushes.end()) return {&found->second->brush, found->second->geometry.get()};
	}
	auto found = base_geometry->brushes.find(base_brush.id);
	return {&base_brush, found == base_geometry->brushes.end() ? nullptr : found->second.get()};
}

std::shared_ptr<LMMapData> TBMapDocument::materialize_source_state(const std::shared_ptr<LMMapData> &base, const std::shared_ptr<const EditorState> &overlay) const {
	auto out = base->source_clone();
	if (translation_counter_scope) { ++last_operation.materializations; ++last_operation.source_clones; }
	if (overlay) for (int e = 0; e < out->entity_count; ++e) {
		auto &entity = out->entities[e];
		for (int b = 0; b < entity.brush_count; ++b) {
			auto found = overlay->brushes.find(entity.brushes[b].id);
			if (found == overlay->brushes.end()) continue;
			const auto &record = *found->second;
			auto &brush = entity.brushes[b];
			std::free(brush.faces);
			brush.face_count = static_cast<int>(record.faces.size());
			brush.faces = static_cast<LMFace *>(calloc(brush.face_count, sizeof(LMFace)));
			std::memcpy(brush.faces, record.faces.data(), record.faces.size() * sizeof(LMFace));
			for (int f = 0; f < brush.face_count; ++f) brush.faces[f].texture_idx = out->map_data_register_texture(record.materials[f].c_str());
			brush.center = record.brush.center;
			brush.topology_revision = record.brush.topology_revision;
		}
	}
	if (translation_counter_scope) last_operation.source_clone_retained_bytes = static_cast<int64_t>(out->retained_bytes());
	return out;
}

std::shared_ptr<LMMapData> TBMapDocument::materialize_current_source() const { return materialize_source_state(map, editor); }

const std::string &TBMapDocument::canonical_text(bool retain_materialized_view) const {
	(void)retain_materialized_view;
	if (!editor || editor->brushes.empty()) return *canonical;
	if (!materialized_canonical) {
		if (translation_counter_scope) ++last_operation.writer_calls;
		auto source = materialize_current_source();
		materialized_canonical = std::make_shared<const std::string>(lm_write_map(*source));
	}
	return *materialized_canonical;
}

void TBMapDocument::clear_editor_state() {
	editor.reset(); materialized_canonical.reset(); transition = {}; translation_counter_scope = false;
}

bool TBMapDocument::is_dirty() const { return !has_baseline || state_generation != saved_state_generation; }

Dictionary TBMapDocument::get_last_operation_counters() const {
	Dictionary out;
	out["brush_builds"] = last_operation.brush_builds; out["brush_source_copies"] = last_operation.brush_source_copies;
	out["compact_full_builds"] = last_operation.compact_full_builds; out["compact_uv_updates"] = last_operation.compact_uv_updates;
	out["compact_shared_brushes"] = last_operation.compact_shared_brushes; out["compact_uv_copy_bytes"] = last_operation.compact_uv_copy_bytes;
	out["parser_calls"] = last_operation.parser_calls; out["writer_calls"] = last_operation.writer_calls;
	out["lm_geo_generator_calls"] = last_operation.geo_generator_calls;
	out["parser_us"] = last_operation.parser_us; out["canonical_writer_us"] = last_operation.canonical_writer_us; out["compact_build_us"] = last_operation.compact_build_us; out["compact_uv_update_us"] = last_operation.compact_uv_update_us;
	out["source_retained_bytes"] = last_operation.source_retained_bytes; out["compact_retained_bytes"] = last_operation.compact_retained_bytes;
	out["materializations"] = last_operation.materializations; out["deep_clones"] = last_operation.deep_clones;
	out["source_clones"] = last_operation.source_clones; out["source_clone_retained_bytes"] = last_operation.source_clone_retained_bytes;
	out["operation"] = last_operation.operation;
	out["topology_dirty"] = last_operation.topology_dirty; out["positions_dirty"] = last_operation.positions_dirty;
	out["uv_dirty"] = last_operation.uv_dirty; out["material_dirty"] = last_operation.material_dirty;
	out["preview_dirty"] = last_operation.preview_dirty; out["spatial_dirty"] = last_operation.spatial_dirty;
	out["restore_touched_brushes"] = last_operation.restore_touched_brushes; out["restore_full_resets"] = last_operation.restore_full_resets;
	out["scope"] = StringName("local_brush_transaction");
	out["success"] = last_operation.success; out["committed"] = last_operation.committed;
	if (last_operation.success && last_operation.committed) out["completed"] = true;
	return out;
}

Dictionary TBMapDocument::get_cache_root_counters() const {
	Dictionary out;
	out["preview_active"] = preview_cache ? 1 : 0; out["preview_history"] = static_cast<int64_t>(preview_history.size());
	out["spatial_active"] = spatial_index ? 1 : 0; out["spatial_history"] = static_cast<int64_t>(spatial_history.size());
	append_spatial_cache_counters(out);
	return out;
}

Dictionary TBMapDocument::get_last_change() const {
	Dictionary out; PackedInt64Array ids, added, removed;
	for (int64_t id : last_change.brush_ids) ids.push_back(id);
	for (int64_t id : last_change.added_ids) added.push_back(id);
	for (int64_t id : last_change.removed_ids) removed.push_back(id);
	out["before_generation"] = last_change.before_generation; out["generation"] = last_change.generation;
	out["operation"] = last_change.operation; out["domains"] = static_cast<int>(last_change.domains); out["brush_ids"] = ids;
	out["added_ids"] = added; out["removed_ids"] = removed; out["topology_revision"] = topology; out["reset"] = last_change.reset;
	out["entities_changed"] = last_change.entities_changed; out["ownership_changed"] = last_change.ownership_changed; out["points_changed"] = last_change.points_changed;
	return out;
}

Dictionary TBMapDocument::prepare(const std::string &text, std::shared_ptr<LMMapData> &candidate, const StringName &operation, const String &error_path, std::string *normalized) const {
	candidate = std::make_shared<LMMapData>();
	if (translation_counter_scope) ++last_operation.parser_calls;
	const auto parser_begin = std::chrono::steady_clock::now();
	LMMapParser parser(candidate);
	if (!parser.load_from_text(text)) return failure(parser.error.code.c_str(), parser.error.message.c_str(), operation, error_path, parser.error.line, parser.error.column);
	if (translation_counter_scope) last_operation.parser_us += std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - parser_begin).count();
	if (translation_counter_scope) ++last_operation.writer_calls;
	const auto writer_begin = std::chrono::steady_clock::now();
	std::string written = lm_write_map(*candidate);
	if (translation_counter_scope) { last_operation.canonical_writer_us += std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - writer_begin).count(); last_operation.source_retained_bytes = candidate->retained_bytes(); }
	if (written.size() > LMMapParser::MAX_TEXT_BYTES) return failure("LIMIT_EXCEEDED", "Canonical map exceeds 16 MiB", operation, error_path);
	if (normalized) *normalized = std::move(written);
	resolve_texture_sizes(*candidate, texture_sizes);
	return success();
}

Dictionary TBMapDocument::build_base_editor_geometry(LMMapData &data, const Dictionary &sizes, std::shared_ptr<const TBMapDocumentState::BaseEditorGeometry> &out, const StringName &operation, const String &error_path) const {
	const auto build_begin = std::chrono::steady_clock::now();
	auto store = std::make_shared<TBMapDocumentState::BaseEditorGeometry>();
	size_t total_brushes = 0;
	for (int e = 0; e < data.entity_count; ++e) total_brushes += size_t(data.entities[e].brush_count);
	if (total_brushes) store->brushes.reserve(total_brushes);
	std::vector<LMEditorTextureSize> dimensions(data.texture_count);
	for (int t = 0; t < data.texture_count; ++t) {
		const Vector2i size = sizes.get(String::utf8(data.textures[t].name), Vector2i(1, 1));
		dimensions[t] = {size.x, size.y};
	}
	const LMEditorBrushBuildContext context{dimensions.data(), dimensions.size()};
	for (int e = 0; e < data.entity_count; ++e) {
		auto &entity = data.entities[e];
		for (int b = 0; b < entity.brush_count; ++b) {
			auto &brush = entity.brushes[b]; auto built = lm_build_editor_brush_geometry(brush, context);
			if (translation_counter_scope) { ++last_operation.brush_builds; ++last_operation.compact_full_builds; }
			if (!built || !lm_validate_editor_brush_geometry(brush, built.geometry)) return failure("INVALID_GEOMETRY", "Brush must be a finite, closed solid with nonempty faces", operation, error_path);
			brush.center = {}; size_t corners = 0;
			for (const auto &face : built.geometry.faces) for (uint32_t v = 0; v < face.corner_count; ++v) {
				brush.center = vec3_add(brush.center, built.geometry.positions[built.geometry.corners[face.corner_begin + v].position]); ++corners;
			}
			if (corners) brush.center = vec3_div_double(brush.center, corners);
			store->brushes[brush.id] = std::make_shared<const LMEditorBrushGeometry>(std::move(built.geometry));
		}
	}
	out = std::move(store);
	if (translation_counter_scope) { last_operation.compact_build_us += std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - build_begin).count(); last_operation.compact_retained_bytes = out->retained_bytes(); }
	return success();
}

Dictionary TBMapDocument::update_texture_context_geometry(const LMMapData &data,
		const std::shared_ptr<const TBMapDocumentState::BaseEditorGeometry> &source_base,
		const std::shared_ptr<const EditorState> &source_editor, const Dictionary &old_sizes, const Dictionary &new_sizes,
		std::shared_ptr<const TBMapDocumentState::BaseEditorGeometry> &out_base, std::shared_ptr<const EditorState> &out_editor,
		const StringName &operation) const {
	auto dimensions = [](const LMMapData &source, const Dictionary &sizes) {
		std::vector<LMEditorTextureSize> out(source.texture_count);
		for (int t = 0; t < source.texture_count; ++t) {
			const Vector2i size = sizes.get(String::utf8(source.textures[t].name), Vector2i(1, 1));
			out[t] = {size.x, size.y};
		}
		return out;
	};
	const auto old_base_dimensions = dimensions(data, old_sizes);
	const auto new_base_dimensions = dimensions(data, new_sizes);
	const LMEditorBrushBuildContext old_base_context{old_base_dimensions.data(), old_base_dimensions.size()};
	const LMEditorBrushBuildContext new_base_context{new_base_dimensions.data(), new_base_dimensions.size()};
	auto next_base = std::make_shared<TBMapDocumentState::BaseEditorGeometry>();
	if (source_base) next_base->brushes.reserve(source_base->brushes.size());
	for (int e = 0; e < data.entity_count; ++e) for (int b = 0; b < data.entities[e].brush_count; ++b) {
		const LMBrush &brush = data.entities[e].brushes[b];
		auto found = source_base ? source_base->brushes.find(brush.id) : decltype(source_base->brushes.find(brush.id)){};
		const std::shared_ptr<const LMEditorBrushGeometry> existing = source_base && found != source_base->brushes.end() ? found->second : nullptr;
		const auto uv_begin = std::chrono::steady_clock::now();
		auto updated = lm_update_editor_brush_uvs(brush, existing, old_base_context, new_base_context);
		last_operation.compact_uv_update_us += std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - uv_begin).count();
		if (!updated && updated.status != LMEditorBrushBuildStatus::SOURCE_TOKEN_MISMATCH) return failure("INVALID_GEOMETRY", "Cannot update compact brush UVs for texture dimensions", operation, path);
		if (!updated) {
			const auto build_begin = std::chrono::steady_clock::now();
			auto built = lm_build_editor_brush_geometry(brush, new_base_context); ++last_operation.brush_builds; ++last_operation.compact_full_builds;
			last_operation.compact_build_us += std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - build_begin).count();
			if (!built || !lm_validate_editor_brush_geometry(brush, built.geometry)) return failure("INVALID_GEOMETRY", "Cannot rebuild stale compact brush geometry for texture dimensions", operation, path);
			next_base->brushes[brush.id] = std::make_shared<const LMEditorBrushGeometry>(std::move(built.geometry));
		} else if (updated.geometry == existing) {
			++last_operation.compact_shared_brushes;
			next_base->brushes.emplace(brush.id, existing);
		} else {
			++last_operation.compact_uv_updates; last_operation.compact_uv_copy_bytes += updated.copied_bytes;
			next_base->brushes[brush.id] = std::move(updated.geometry);
		}
	}
	out_base = std::move(next_base);
	out_editor = source_editor;
	std::shared_ptr<EditorState> next_editor;
	if (source_editor) for (const auto &item : source_editor->brushes) {
		const auto &record = *item.second;
		std::vector<LMEditorTextureSize> old_dimensions(record.materials.size()), new_dimensions(record.materials.size());
		for (size_t f = 0; f < record.materials.size(); ++f) {
			const String name = String::utf8(record.materials[f].c_str());
			Vector2i old_size = old_sizes.get(name, Vector2i(1, 1)), new_size = new_sizes.get(name, Vector2i(1, 1));
			old_dimensions[f] = {old_size.x, old_size.y}; new_dimensions[f] = {new_size.x, new_size.y};
		}
		const LMEditorBrushBuildContext old_context{old_dimensions.data(), old_dimensions.size()};
		const LMEditorBrushBuildContext new_context{new_dimensions.data(), new_dimensions.size()};
		const auto uv_begin = std::chrono::steady_clock::now();
		auto updated = lm_update_editor_brush_uvs(record.brush, record.geometry, old_context, new_context, record.source_generation);
		last_operation.compact_uv_update_us += std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - uv_begin).count();
		std::shared_ptr<const LMEditorBrushGeometry> geometry;
		if (!updated && updated.status != LMEditorBrushBuildStatus::SOURCE_TOKEN_MISMATCH) return failure("INVALID_GEOMETRY", "Cannot update overridden compact brush UVs for texture dimensions", operation, path);
		if (!updated) {
			const auto build_begin = std::chrono::steady_clock::now();
			auto built = lm_build_editor_brush_geometry(record.brush, new_context); ++last_operation.brush_builds; ++last_operation.compact_full_builds;
			last_operation.compact_build_us += std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - build_begin).count();
			if (!built || !lm_validate_editor_brush_geometry(record.brush, built.geometry)) return failure("INVALID_GEOMETRY", "Cannot rebuild stale overridden compact geometry for texture dimensions", operation, path);
			built.geometry.source_generation = record.source_generation;
			geometry = std::make_shared<const LMEditorBrushGeometry>(std::move(built.geometry));
		} else if (updated.geometry == record.geometry) {
			++last_operation.compact_shared_brushes;
			continue;
		} else {
			++last_operation.compact_uv_updates; last_operation.compact_uv_copy_bytes += updated.copied_bytes;
			geometry = std::move(updated.geometry);
		}
		if (!next_editor) { next_editor = std::make_shared<EditorState>(*source_editor); out_editor = next_editor; }
		next_editor->brushes[item.first] = std::make_shared<const EditorState::BrushRecord>(record, std::move(geometry));
	}
	last_operation.compact_retained_bytes = out_base->retained_bytes();
	return success();
}

void TBMapDocument::assign_ids(LMMapData &candidate) {
	issued_ids.clear();
	size_t total_ids = 0;
	for (int i = 0; i < candidate.entity_count; ++i) total_ids += size_t(1) + size_t(candidate.entities[i].primitive_count);
	if (total_ids) issued_ids.reserve(total_ids);
	for (int i = 0; i < candidate.entity_count; ++i) {
		auto &e = candidate.entities[i];
		e.id = next_id++; issued_ids[e.id] = 'e';
		for (int k = 0; k < e.primitive_count; ++k) {
			const auto &p = e.primitives[k];
			int64_t id = next_id++;
			if (p.is_patch) e.patches[p.index].id = id;
			else e.brushes[p.index].id = id;
			issued_ids[id] = p.is_patch ? 'p' : 'b';
		}
	}
}
void TBMapDocument::rebuild_live_index() {
	live_ids.clear();
	size_t total_ids = 0;
	for (int e = 0; e < map->entity_count; ++e) total_ids += size_t(1) + size_t(map->entities[e].primitive_count);
	if (total_ids) live_ids.reserve(total_ids);
	for (int e = 0; e < map->entity_count; ++e) {
		const auto &entity = map->entities[e];
		live_ids[entity.id] = {'e', e, -1, -1};
		for (int p = 0; p < entity.primitive_count; ++p) {
			const auto &primitive = entity.primitives[p];
			const int64_t id = primitive.is_patch ? entity.patches[primitive.index].id : entity.brushes[primitive.index].id;
			live_ids[id] = {primitive.is_patch ? 'p' : 'b', e, primitive.index, p};
		}
	}
}
const TBMapDocument::LiveLocation *TBMapDocument::live_location(int64_t id, char kind) const {
	auto found = live_ids.find(id);
	return found != live_ids.end() && found->second.kind == kind ? &found->second : nullptr;
}
LMEditEntity *TBMapDocument::edit_entity(LMMapEdit &edit, int64_t id) const {
	const auto *location = live_location(id, 'e');
	return location && location->entity < static_cast<int>(edit.entities.size()) && edit.entities[location->entity].id == id ? &edit.entities[location->entity] : nullptr;
}
LMEditPrimitive *TBMapDocument::edit_brush(LMMapEdit &edit, int64_t id) const {
	const auto *location = live_location(id, 'b');
	if (!location) return nullptr;
	if (location->entity < static_cast<int>(edit.entities.size())) {
		auto &primitives = edit.entities[location->entity].primitives;
		if (location->primitive < static_cast<int>(primitives.size()) && !primitives[location->primitive].patch && primitives[location->primitive].id == id) return &primitives[location->primitive];
	}
	return edit.brush(id);
}
void TBMapDocument::commit(std::shared_ptr<LMMapData> candidate, std::shared_ptr<const TBMapDocumentState::BaseEditorGeometry> geometry, const std::string &text, bool was_dirty) {
	commit(std::move(candidate), std::move(geometry), std::make_shared<const std::string>(text), was_dirty);
}
void TBMapDocument::commit(std::shared_ptr<LMMapData> candidate, std::shared_ptr<const TBMapDocumentState::BaseEditorGeometry> geometry, std::shared_ptr<const std::string> text, bool was_dirty) {
	const int64_t before_generation = state_generation;
	size_t old_count = 0, new_count = 0;
	if (map) for (int e = 0; e < map->entity_count; ++e) old_count += size_t(map->entities[e].brush_count);
	for (int e = 0; e < candidate->entity_count; ++e) new_count += size_t(candidate->entities[e].brush_count);
	std::unordered_set<int64_t> old_brush_ids, new_brush_ids;
	if (old_count) old_brush_ids.reserve(old_count * 2 + 1);
	if (new_count) new_brush_ids.reserve(new_count * 2 + 1);
	if (map) for (int e = 0; e < map->entity_count; ++e) for (int b = 0; b < map->entities[e].brush_count; ++b) old_brush_ids.insert(map->entities[e].brushes[b].id);
	// Structural commits always reset derived roots; local transactions own the
	// only cache-compatible generation transitions.
	clear_spatial_caches();
	clear_preview_caches();
	++topology;
	// Fuse the new-id collection with the mandatory topology stamp: single pass.
	for (int i = 0; i < candidate->entity_count; ++i) for (int b = 0; b < candidate->entities[i].brush_count; ++b) {
		new_brush_ids.insert(candidate->entities[i].brushes[b].id);
		candidate->entities[i].brushes[b].topology_revision = topology;
	}
	map = std::move(candidate);
	base_geometry = std::move(geometry);
	clear_editor_state();
	transition = {};
	rebuild_live_index();
	canonical = std::move(text);
	state_generation = ++next_state_generation;
	last_change = {}; last_change.before_generation = before_generation; last_change.generation = state_generation; last_change.domains = LMEditorBrushDirtyDomain::ALL;
	last_change.reset = true;
	last_change.added_ids.reserve(new_count);
	last_change.removed_ids.reserve(old_count);
	for (int64_t id : new_brush_ids) if (old_brush_ids.find(id) == old_brush_ids.end()) last_change.added_ids.push_back(id);
	for (int64_t id : old_brush_ids) if (new_brush_ids.find(id) == new_brush_ids.end()) last_change.removed_ids.push_back(id);
	++revision;
	emit_signal("map_changed", revision);
	if (was_dirty != is_dirty()) emit_signal("dirty_changed", is_dirty());
}
Dictionary TBMapDocument::replace_text(const std::string &text, const StringName &operation, const String &new_path, bool saved) {
	last_document_change.unref();
	last_operation = {}; last_operation.operation = operation; translation_counter_scope = true;
	std::shared_ptr<LMMapData> candidate;
	std::string normalized;
	Dictionary result = prepare(text, candidate, operation, new_path, &normalized);
	if (!bool(result["ok"])) { translation_counter_scope = false; return result; }
	bool was_dirty = is_dirty();
	assign_ids(*candidate);
	std::shared_ptr<const TBMapDocumentState::BaseEditorGeometry> geometry;
	result = build_base_editor_geometry(*candidate, texture_sizes, geometry, operation, new_path);
	if (!bool(result["ok"])) { translation_counter_scope = false; return result; }
	clear_spatial_caches(); clear_preview_caches();
	epoch = ++epoch_counter;
	path = new_path;
	disk_path = saved ? absolute_path(new_path) : String();
	has_baseline = saved;
	baseline = saved ? normalized : "";
	disk_bytes = saved ? text : "";
	saved_state_generation = saved ? next_state_generation + 1 : -1;
	commit(candidate, geometry, normalized, was_dirty);
	last_operation.success = true; last_operation.committed = true; translation_counter_scope = false;
	return success(true);
}
Dictionary TBMapDocument::new_map() { return replace_text("{\n\"classname\" \"worldspawn\"\n}\n", "new_map", String(), false); }
Dictionary TBMapDocument::import_text(const String &text) { return replace_text(utf8(text), "import_text", String(), false); }
Dictionary TBMapDocument::load_map(const String &new_path) {
	if (new_path.is_empty()) return failure("INVALID_ARGUMENT", "Map path is empty", "load_map", new_path);
	if (!FileAccess::file_exists(new_path)) return failure("IO_NOT_FOUND", "Map does not exist", "load_map", new_path);
	Ref<FileAccess> file = FileAccess::open(new_path, FileAccess::READ);
	if (file.is_valid() && file->get_length() > LMMapParser::MAX_TEXT_BYTES) return failure("LIMIT_EXCEEDED", "Map exceeds 16 MiB", "load_map", new_path);
	std::string bytes;
	if (!read_bytes(new_path, bytes)) return failure("IO_READ", "Cannot read map", "load_map", new_path);
	return replace_text(bytes, "load_map", new_path, true);
}

Dictionary TBMapDocument::save_map(const String &target) {
	last_document_change.unref();
	if (target.is_empty()) return failure("INVALID_ARGUMENT", "Map path is empty", "save_map", target);
	String absolute = absolute_path(target);
	std::string original;
	bool exists = FileAccess::file_exists(absolute);
	bool same_path = !path.is_empty() && (absolute == disk_path || absolute == absolute_path(path));
	if (exists && !read_bytes(absolute, original)) return failure("IO_READ", "Cannot inspect destination", "save_map", target);
	if (same_path && (!exists || original != disk_bytes)) return failure("EXTERNAL_CHANGE", "Map changed or was removed outside this document", "save_map", target);
#ifdef _WIN32
	return failure("IO_WRITE", "Atomic saving is currently implemented for POSIX hosts", "save_map", target);
#else
	const std::string save_text = canonical_text(true);
	std::shared_ptr<LMMapData> consolidated;
	std::shared_ptr<const TBMapDocumentState::BaseEditorGeometry> consolidated_geometry;
	if (editor && !editor->brushes.empty()) {
		consolidated = materialize_current_source();
		Dictionary built = build_base_editor_geometry(*consolidated, texture_sizes, consolidated_geometry, "save_map", target);
		if (!bool(built["ok"])) return built;
	}
	std::string destination = utf8(absolute);
	std::string pattern = destination + ".tbmap-XXXXXX";
	std::vector<char> temporary(pattern.begin(), pattern.end());
	temporary.push_back('\0');
	int fd = mkstemp(temporary.data());
	if (fd < 0) return failure("IO_WRITE", "Cannot create sibling temporary file", "save_map", target);
	bool written = true;
	struct stat info;
	if (exists && stat(destination.c_str(), &info) == 0 && fchmod(fd, info.st_mode & 0777) != 0) written = false;
	size_t offset = 0;
	while (written && offset < save_text.size()) {
		ssize_t count = write(fd, save_text.data() + offset, save_text.size() - offset);
		if (count < 0 && errno == EINTR) continue;
		if (count <= 0) { written = false; break; }
		offset += count;
	}
	if (written && fsync(fd) != 0) written = false;
	if (close(fd) != 0) written = false;
	// Verify bytes before atomic replacement as well as before the potentially slow write.
	std::string now;
	bool still_exists = FileAccess::file_exists(absolute);
	bool external = exists != still_exists || (exists && (!read_bytes(absolute, now) || now != original));
	if (!written || external || rename(temporary.data(), destination.c_str()) != 0) {
		unlink(temporary.data());
		return failure(external ? "EXTERNAL_CHANGE" : "IO_WRITE", external ? "Destination changed while saving" : "Cannot write or atomically replace map", "save_map", target);
	}
	bool was_dirty = is_dirty();
	bool changed = path != target || was_dirty;
	path = target;
	disk_path = absolute;
	baseline = save_text; disk_bytes = save_text; has_baseline = true;
	saved_state_generation = state_generation;
	if (consolidated) {
		map = std::move(consolidated);
		base_geometry = std::move(consolidated_geometry);
		for (int e = 0; e < map->entity_count; ++e) for (int b = 0; b < map->entities[e].brush_count; ++b) map->entities[e].brushes[b].topology_revision = topology;
		canonical = std::make_shared<const std::string>(save_text);
		clear_editor_state();
		rebuild_live_index();
	}
	// Saving is an explicit consolidation boundary. Do not retain roots whose
	// source representation was the pre-save base plus overlay.
	clear_spatial_caches(); clear_preview_caches();
	if (was_dirty != is_dirty()) emit_signal("dirty_changed", is_dirty());
	return success(changed);
#endif
}

Dictionary TBMapDocument::export_text() const { return success(false, string(canonical_text())); }
bool TBMapDocument::copy_identities(const LMMapData &from, LMMapData &to) const {
	if (from.entity_count != to.entity_count) return false;
	for (int i = 0; i < from.entity_count; ++i) {
		const auto &src = from.entities[i];
		auto &dst = to.entities[i];
		if (src.primitive_count != dst.primitive_count) return false;
		dst.id = src.id;
		for (int k = 0; k < src.primitive_count; ++k) {
			const auto &sp = src.primitives[k];
			const auto &dp = dst.primitives[k];
			if (sp.is_patch != dp.is_patch) return false;
			if (sp.is_patch) dst.patches[dp.index].id = src.patches[sp.index].id;
			else dst.brushes[dp.index].id = src.brushes[sp.index].id;
		}
	}
	return true;
}

Dictionary TBMapDocument::identities(const LMMapData &data) const {
	Array entities;
	for (int i = 0; i < data.entity_count; ++i) {
		const auto &e = data.entities[i];
		Dictionary entity;
		entity["id"] = e.id;
		Array primitives;
		for (int k = 0; k < e.primitive_count; ++k) {
			const auto &p = e.primitives[k];
			Dictionary primitive;
			primitive["kind"] = StringName(p.is_patch ? "patch" : "brush");
			primitive["id"] = p.is_patch ? e.patches[p.index].id : e.brushes[p.index].id;
			primitives.push_back(primitive);
		}
		entity["primitives"] = primitives;
		entities.push_back(entity);
	}
	Dictionary out;
	out["entities"] = entities;
	return out;
}
Dictionary TBMapDocument::snapshot() const {
	Dictionary out;
	out["schema"] = 1; out["epoch"] = epoch; out["text"] = string(canonical_text()); out["identities"] = identities(*map);
	return success(false, out);
}
bool TBMapDocument::apply_identities(LMMapData &data, const Dictionary &ids) const {
	if (!ids.has("entities") || ids["entities"].get_type() != Variant::ARRAY) return false;
	Array entities = ids["entities"];
	if (entities.size() != data.entity_count) return false;
	std::set<int64_t> seen;
	auto read_id = [&](const Dictionary &entry, char kind, int64_t &id) {
		if (!entry.has("id") || entry["id"].get_type() != Variant::INT) return false;
		id = entry["id"];
		auto found = issued_ids.find(id);
		return id > 0 && found != issued_ids.end() && found->second == kind && seen.insert(id).second;
	};
	for (int i = 0; i < data.entity_count; ++i) {
		if (entities[i].get_type() != Variant::DICTIONARY) return false;
		Dictionary entity = entities[i];
		auto &e = data.entities[i];
		if (!read_id(entity, 'e', e.id) || !entity.has("primitives") || entity["primitives"].get_type() != Variant::ARRAY) return false;
		Array primitives = entity["primitives"];
		if (primitives.size() != e.primitive_count) return false;
		for (int k = 0; k < e.primitive_count; ++k) {
			if (primitives[k].get_type() != Variant::DICTIONARY) return false;
			Dictionary primitive = primitives[k];
			const auto &p = e.primitives[k];
			if (!primitive.has("kind") || (primitive["kind"].get_type() != Variant::STRING_NAME && primitive["kind"].get_type() != Variant::STRING)) return false;
			if (String(primitive["kind"]) != (p.is_patch ? "patch" : "brush")) return false;
			int64_t &id = p.is_patch ? e.patches[p.index].id : e.brushes[p.index].id;
			if (!read_id(primitive, p.is_patch ? 'p' : 'b', id)) return false;
		}
	}
	return true;
}
Dictionary TBMapDocument::restore_snapshot(const Dictionary &saved) {
	if (!saved.has("schema") || saved["schema"].get_type() != Variant::INT || int64_t(saved["schema"]) != 1 ||
			!saved.has("epoch") || saved["epoch"].get_type() != Variant::INT || int64_t(saved["epoch"]) != epoch ||
			!saved.has("text") || saved["text"].get_type() != Variant::STRING ||
			!saved.has("identities") || saved["identities"].get_type() != Variant::DICTIONARY) {
		return failure("SNAPSHOT_MISMATCH", "Snapshot schema or document epoch mismatch", "restore_snapshot");
	}
	std::shared_ptr<LMMapData> candidate;
	std::string normalized;
	Dictionary result = prepare(utf8(saved["text"]), candidate, "restore_snapshot", path, &normalized);
	if (!bool(result["ok"])) return result;
	if (!apply_identities(*candidate, saved["identities"])) return failure("SNAPSHOT_MISMATCH", "Snapshot identity shape, kind or issued ID mismatch", "restore_snapshot");
	std::shared_ptr<const TBMapDocumentState::BaseEditorGeometry> geometry;
	result = build_base_editor_geometry(*candidate, texture_sizes, geometry, "restore_snapshot", path); if (!bool(result["ok"])) return result;
	commit(candidate, geometry, normalized, is_dirty());
	return success(true);
}
Ref<TBMapDocumentState> TBMapDocument::capture_history_state() const {
	Ref<TBMapDocumentState> state;
	state.instantiate();
	state->map = map;
	state->canonical = canonical;
	state->base_geometry = base_geometry;
	state->editor = editor;
	state->texture_sizes = texture_sizes;
	state->epoch = epoch;
	state->state_generation = state_generation;
	return state;
}
bool TBMapDocument::is_history_state_current(const Ref<TBMapDocumentState> &state) const {
	// Texture dimensions are derived editor context, not semantic history state.
	return state.is_valid() && state->epoch == epoch && state->state_generation == state_generation;
}
Dictionary TBMapDocument::restore_history_state(const Ref<TBMapDocumentState> &state) {
	if (state.is_null() || state->epoch != epoch) return failure("SNAPSHOT_MISMATCH", "History state document epoch mismatch", "restore_history_state");
	if (is_history_state_current(state)) return success();
	last_document_change.unref();
	if (state->texture_sizes == texture_sizes) {
		const bool was_dirty = is_dirty();
		const auto old_map = map; const auto old_editor = editor; const int64_t old_generation = state_generation;
		retain_spatial_index(); retain_preview_cache();
		map = state->map; canonical = state->canonical; editor = state->editor; base_geometry = state->base_geometry;
		translation_counter_scope = false;
		materialized_canonical.reset();
		state_generation = state->state_generation;
		transition = {};
		if (old_map == map) {
			transition.from_generation = old_generation; transition.compatible = true;
			std::set<int64_t> ids;
			if (old_editor) for (const auto &item : old_editor->brushes) ids.insert(item.first);
			if (editor) for (const auto &item : editor->brushes) ids.insert(item.first);
			for (int64_t id : ids) {
				auto old_item = old_editor ? old_editor->brushes.find(id) : decltype(old_editor->brushes.find(id)){};
				auto new_item = editor ? editor->brushes.find(id) : decltype(editor->brushes.find(id)){};
				const bool old_found = old_editor && old_item != old_editor->brushes.end();
				const bool new_found = editor && new_item != editor->brushes.end();
				if (old_found != new_found || (old_found && old_item->second != new_item->second)) transition.brush_ids.push_back(id);
			}
		}
		LMEditorBrushDirtyDomain restored_domains = LMEditorBrushDirtyDomain::ALL;
		if (old_editor && old_editor->change.from_generation == state_generation) restored_domains = old_editor->change.domains;
		else if (editor && editor->change.from_generation == old_generation) restored_domains = editor->change.domains;
		last_change = {}; last_change.before_generation = old_generation; last_change.generation = state_generation;
		last_change.domains = restored_domains; last_change.brush_ids = transition.brush_ids; last_change.reset = !transition.compatible;
		last_change.entities_changed = !transition.compatible; last_change.ownership_changed = !transition.compatible; last_change.points_changed = !transition.compatible;
		last_operation = {}; last_operation.operation = "restore_history_state"; last_operation.restore_full_resets = transition.compatible ? 0 : 1;
		last_operation.restore_touched_brushes = transition.brush_ids.size(); last_operation.success = true; last_operation.committed = true;
		rebuild_live_index(); restore_spatial_index(); restore_preview_cache();
		++revision;
		if ((lm_editor_brush_dirty_dependencies(restored_domains) & LMEditorBrushDirtyDomain::TOPOLOGY) != LMEditorBrushDirtyDomain::NONE) ++topology;
		emit_signal("map_changed", revision); if (was_dirty != is_dirty()) emit_signal("dirty_changed", is_dirty());
		return success(true);
	} else {
		const bool was_dirty = is_dirty();
		const auto old_map = map; const auto old_editor = editor; const int64_t old_generation = state_generation;
		last_operation = {}; last_operation.operation = "restore_history_state"; translation_counter_scope = true;
		std::shared_ptr<const TBMapDocumentState::BaseEditorGeometry> rebuilt_base;
		std::shared_ptr<const EditorState> rebased;
		Dictionary update_result = update_texture_context_geometry(*state->map, state->base_geometry, state->editor,
				state->texture_sizes, texture_sizes, rebuilt_base, rebased, "restore_history_state");
		if (!bool(update_result["ok"])) { translation_counter_scope = false; return update_result; }
		retain_spatial_index();
		map = state->map; canonical = state->canonical; editor = std::move(rebased); base_geometry = std::move(rebuilt_base);
		transition = {};
		if (old_map == map) {
			transition.from_generation = old_generation; transition.compatible = true;
			std::set<int64_t> ids;
			if (old_editor) for (const auto &item : old_editor->brushes) ids.insert(item.first);
			if (state->editor) for (const auto &item : state->editor->brushes) ids.insert(item.first);
			for (int64_t id : ids) {
				auto old_item = old_editor ? old_editor->brushes.find(id) : decltype(old_editor->brushes.find(id)){};
				auto new_item = state->editor ? state->editor->brushes.find(id) : decltype(state->editor->brushes.find(id)){};
				const bool old_found = old_editor && old_item != old_editor->brushes.end();
				const bool new_found = state->editor && new_item != state->editor->brushes.end();
				if (old_found != new_found || (old_found && old_item->second != new_item->second)) transition.brush_ids.push_back(id);
			}
		}
		LMEditorBrushDirtyDomain restored_domains = LMEditorBrushDirtyDomain::ALL;
		if (old_editor && old_editor->change.from_generation == state->state_generation) restored_domains = old_editor->change.domains;
		else if (state->editor && state->editor->change.from_generation == old_generation) restored_domains = state->editor->change.domains;
		materialized_canonical.reset(); rebuild_live_index();
		state_generation = state->state_generation; ++revision;
		last_change = {}; last_change.before_generation = old_generation; last_change.generation = state_generation;
		last_change.operation = "restore_history_state"; last_change.domains = restored_domains; last_change.brush_ids = transition.brush_ids; last_change.reset = !transition.compatible;
		last_change.entities_changed = !transition.compatible; last_change.ownership_changed = !transition.compatible; last_change.points_changed = !transition.compatible;
		last_operation.restore_full_resets = transition.compatible ? 0 : 1; last_operation.restore_touched_brushes = transition.brush_ids.size();
		restore_spatial_index(); rebind_spatial_context(); clear_preview_caches();
		if ((lm_editor_brush_dirty_dependencies(restored_domains) & LMEditorBrushDirtyDomain::TOPOLOGY) != LMEditorBrushDirtyDomain::NONE) ++topology;
		last_operation.success = true; last_operation.committed = true; translation_counter_scope = false;
		emit_signal("map_changed", revision); if (was_dirty != is_dirty()) emit_signal("dirty_changed", is_dirty());
		return success(true);
	}
}

Ref<TBMapDocumentChange> TBMapDocument::get_last_document_change() const {
	if (last_document_change.is_valid() && last_document_change->epoch == epoch && last_document_change->after_generation == state_generation) return last_document_change;
	return Ref<TBMapDocumentChange>();
}

Dictionary TBMapDocument::apply_document_change(const Ref<TBMapDocumentChange> &change, bool use_after) {
	if (change.is_null() || change->epoch != epoch) return failure("CHANGE_MISMATCH", "Document change epoch mismatch", "apply_document_change");
	const int64_t expected = use_after ? change->before_generation : change->after_generation;
	const int64_t target_generation = use_after ? change->after_generation : change->before_generation;
	if (state_generation != expected) return failure("STALE_CHANGE", "Document change is stale or out of order", "apply_document_change");
	for (const auto &item : change->brushes) if (!live_location(item.id, 'b')) return failure("CHANGE_MISMATCH", "Document change brush identity mismatch", "apply_document_change");

	auto next = std::make_shared<EditorState>();
	if (editor) next->brushes = editor->brushes;
	auto base_equivalent = [&](int64_t id, const std::shared_ptr<const EditorState::BrushRecord> &record) {
		if (!record) return true;
		const auto *location = live_location(id, 'b'); const LMBrush &base = map->entities[location->entity].brushes[location->index];
		if (record->faces.size() != static_cast<size_t>(base.face_count)) return false;
		std::vector<LMFace> faces(base.faces, base.faces + base.face_count); std::vector<std::string> materials;
		for (int f = 0; f < base.face_count; ++f) materials.emplace_back(map->textures[base.faces[f].texture_idx].name);
		std::string record_text;
		for (size_t f = 0; f < record->faces.size(); ++f) record_text += lm_write_face(record->faces[f], record->materials[f]);
		std::string base_text;
		for (size_t f = 0; f < faces.size(); ++f) base_text += lm_write_face(faces[f], materials[f]);
		return record_text == base_text;
	};
	std::vector<int64_t> ids; ids.reserve(change->brushes.size());
	for (const auto &item : change->brushes) {
		auto record = use_after ? item.after : item.before;
		if (base_equivalent(item.id, record)) next->brushes.erase(item.id); else {
			if (change->texture_context_generation != texture_context_generation) {
				std::vector<LMEditorTextureSize> sizes(record->materials.size());
				for (size_t f = 0; f < record->materials.size(); ++f) {
					Vector2i size = texture_sizes.get(String::utf8(record->materials[f].c_str()), Vector2i(1, 1)); sizes[f] = {size.x, size.y};
				}
				const LMEditorBrushBuildContext context{sizes.data(), sizes.size()}; auto built = lm_build_editor_brush_geometry(record->brush, context);
				if (!built || !lm_validate_editor_brush_geometry(record->brush, built.geometry)) return failure("CHANGE_MISMATCH", "Document change brush cannot be rebuilt in the current texture context", "apply_document_change");
				built.geometry.source_generation = record->source_generation;
				record = std::make_shared<const EditorState::BrushRecord>(*record, std::make_shared<const LMEditorBrushGeometry>(std::move(built.geometry)));
			}
			next->brushes[item.id] = record;
		}
		ids.push_back(item.id);
	}
	next->canonical_size_delta = (use_after ? change->after_canonical_size : change->before_canonical_size) - int64_t(canonical->size());
	next->change = {expected, ids, change->domains, change->operation};
	const auto expanded = lm_editor_brush_dirty_dependencies(change->domains); const bool was_dirty = is_dirty();
	last_operation = {}; last_operation.operation = "apply_document_change"; last_operation.restore_touched_brushes = ids.size();
	const std::shared_ptr<const EditorState> installed = next->brushes.empty() ? std::shared_ptr<const EditorState>() : next;
	retain_spatial_index(); retain_preview_cache(); advance_spatial_index(installed, ids, expanded, target_generation);
	editor = installed;
	materialized_canonical.reset(); invalidate_preview_cache(); transition = {expected, ids, true}; state_generation = target_generation;
	if ((expanded & LMEditorBrushDirtyDomain::TOPOLOGY) != LMEditorBrushDirtyDomain::NONE) ++topology;
	last_change = {}; last_change.before_generation = expected; last_change.generation = target_generation; last_change.operation = change->operation;
	last_change.domains = change->domains; last_change.brush_ids = ids; last_change.reset = false;
	last_change.entities_changed = false; last_change.ownership_changed = false; last_change.points_changed = false;
	last_document_change = change; last_operation.success = true; last_operation.committed = true; ++revision;
	emit_signal("map_changed", revision); if (was_dirty != is_dirty()) emit_signal("dirty_changed", is_dirty());
	return success(true);
}
Dictionary TBMapDocument::rebuild() {
	std::shared_ptr<LMMapData> candidate;
	const std::string &current_text = canonical_text();
	const std::shared_ptr<const std::string> kept = (!editor || editor->brushes.empty()) ? canonical : materialized_canonical;
	Dictionary result = prepare(current_text, candidate, "rebuild", path);
	if (!bool(result["ok"])) return result;
	copy_identities(*map, *candidate);
	std::shared_ptr<const TBMapDocumentState::BaseEditorGeometry> geometry;
	result = build_base_editor_geometry(*candidate, texture_sizes, geometry, "rebuild", path); if (!bool(result["ok"])) return result;
	++topology;
	for (int i = 0; i < candidate->entity_count; ++i) for (int b = 0; b < candidate->entities[i].brush_count; ++b) candidate->entities[i].brushes[b].topology_revision = topology;
	map = candidate; base_geometry = std::move(geometry); canonical = kept ? kept : std::make_shared<const std::string>(current_text); clear_editor_state();
	rebuild_live_index();
	invalidate_spatial_index();
	invalidate_preview_cache();
	last_preview_change_reason = "rebuild";
	emit_signal("preview_changed");
	return success(true);
}
PackedStringArray TBMapDocument::get_texture_names() const {
	PackedStringArray out;
	for (int i = 0; i < map->texture_count; ++i) out.push_back(String::utf8(map->textures[i].name));
	if (editor) for (const auto &item : editor->brushes) for (const auto &material : item.second->materials) {
		const String name = String::utf8(material.c_str()); if (!out.has(name)) out.push_back(name);
	}
	return out;
}
Array TBMapDocument::get_entities() const {
	// LMEntity::center is runtime-derived (notably for tessellated patches) and is
	// intentionally not part of the semantic editor API.
	Dictionary ids = identities(*map);
	Array out = ids["entities"];
	for (int i = 0; i < map->entity_count; ++i) {
		Dictionary entity = out[i];
		Array epairs;
		for (int k = 0; k < map->entities[i].property_count; ++k) {
			Dictionary pair;
			pair["key"] = String::utf8(map->entities[i].properties[k].key);
			pair["value"] = String::utf8(map->entities[i].properties[k].value);
			epairs.push_back(pair);
		}
		entity["epairs"] = epairs;
	}
	return out;
}

void TBMapDocument::_bind_methods() {
	ClassDB::bind_method(D_METHOD("new_map"), &TBMapDocument::new_map);
	ClassDB::bind_method(D_METHOD("load_map", "path"), &TBMapDocument::load_map);
	ClassDB::bind_method(D_METHOD("save_map", "path"), &TBMapDocument::save_map);
	ClassDB::bind_method(D_METHOD("import_text", "text"), &TBMapDocument::import_text);
	ClassDB::bind_method(D_METHOD("export_text"), &TBMapDocument::export_text);
	ClassDB::bind_method(D_METHOD("snapshot"), &TBMapDocument::snapshot);
	ClassDB::bind_method(D_METHOD("restore_snapshot", "snapshot"), &TBMapDocument::restore_snapshot);
	ClassDB::bind_method(D_METHOD("capture_history_state"), &TBMapDocument::capture_history_state);
	ClassDB::bind_method(D_METHOD("restore_history_state", "state"), &TBMapDocument::restore_history_state);
	ClassDB::bind_method(D_METHOD("is_history_state_current", "state"), &TBMapDocument::is_history_state_current);
	ClassDB::bind_method(D_METHOD("get_last_document_change"), &TBMapDocument::get_last_document_change);
	ClassDB::bind_method(D_METHOD("apply_document_change", "change", "use_after"), &TBMapDocument::apply_document_change);
	ClassDB::bind_method(D_METHOD("rebuild"), &TBMapDocument::rebuild);
	ClassDB::bind_method(D_METHOD("is_dirty"), &TBMapDocument::is_dirty);
	ClassDB::bind_method(D_METHOD("get_path"), &TBMapDocument::get_path);
	ClassDB::bind_method(D_METHOD("get_revision"), &TBMapDocument::get_revision);
	ClassDB::bind_method(D_METHOD("get_topology_revision"), &TBMapDocument::get_topology_revision);
	ClassDB::bind_method(D_METHOD("get_epoch"), &TBMapDocument::get_epoch);
	ClassDB::bind_method(D_METHOD("get_state_generation"), &TBMapDocument::get_state_generation);
	ClassDB::bind_method(D_METHOD("get_last_operation_counters"), &TBMapDocument::get_last_operation_counters);
	ClassDB::bind_method(D_METHOD("get_last_change"), &TBMapDocument::get_last_change);
	ClassDB::bind_method(D_METHOD("get_draw_changes"), &TBMapDocument::get_draw_changes);
	ClassDB::bind_method(D_METHOD("get_preview_cache_counters"), &TBMapDocument::get_preview_cache_counters);
	ClassDB::bind_method(D_METHOD("get_cache_root_counters"), &TBMapDocument::get_cache_root_counters);
	ClassDB::bind_method(D_METHOD("get_last_preview_change_reason"), &TBMapDocument::get_last_preview_change_reason);
	ClassDB::bind_method(D_METHOD("get_texture_names"), &TBMapDocument::get_texture_names);
	ClassDB::bind_method(D_METHOD("get_entities"), &TBMapDocument::get_entities);
	ClassDB::bind_method(D_METHOD("get_draw_data"), &TBMapDocument::get_draw_data);
	ClassDB::bind_method(D_METHOD("get_preview_data"), &TBMapDocument::get_preview_data);
	ClassDB::bind_method(D_METHOD("get_face_preview_uvs", "targets", "texture"), &TBMapDocument::get_face_preview_uvs);
	ClassDB::bind_method(D_METHOD("summarize_faces", "targets"), &TBMapDocument::summarize_faces);
	ClassDB::bind_method(D_METHOD("prepare_preview_chunks", "scale", "hidden_ids", "filter_mask", "chunk_triangles", "chunk_size"), &TBMapDocument::prepare_preview_chunks, DEFVAL(2048), DEFVAL(64.0));
	ClassDB::bind_method(D_METHOD("get_preview_chunk", "chunk_id"), &TBMapDocument::get_preview_chunk);
	ClassDB::bind_method(D_METHOD("query_brushes_2d", "hidden_axis", "mins", "maxs"), &TBMapDocument::query_brushes_2d);
	ClassDB::bind_method(D_METHOD("query_brush_2d_hit", "hidden_axis", "point", "tolerance", "hidden_ids", "filter_mask", "selected_ids", "prefer_selected"), &TBMapDocument::query_brush_2d_hit);
	ClassDB::bind_method(D_METHOD("query_brush_camera_hit", "origin", "forward", "right", "up", "viewport_size", "vertical_fov", "position", "aperture", "hidden_ids", "filter_mask"), &TBMapDocument::query_brush_camera_hit);
	ClassDB::bind_method(D_METHOD("query_ray", "origin", "direction", "max_distance"), &TBMapDocument::query_ray, DEFVAL(1e30));
	ClassDB::bind_method(D_METHOD("query_ray_nearest_visible", "origin", "direction", "max_distance", "hidden_ids", "filter_mask"), &TBMapDocument::query_ray_nearest_visible);
	ClassDB::bind_method(D_METHOD("create_cuboid", "mins", "maxs", "texture"), &TBMapDocument::create_cuboid);
	ClassDB::bind_method(D_METHOD("duplicate_brushes", "ids"), &TBMapDocument::duplicate_brushes);
	ClassDB::bind_method(D_METHOD("merge_brushes", "ids"), &TBMapDocument::merge_brushes);
	ClassDB::bind_method(D_METHOD("delete_brushes", "ids"), &TBMapDocument::delete_brushes);
	ClassDB::bind_method(D_METHOD("translate_brushes", "ids", "delta"), &TBMapDocument::translate_brushes);
	ClassDB::bind_method(D_METHOD("rotate_brushes", "ids", "pivot", "axis", "radians"), &TBMapDocument::rotate_brushes);
	ClassDB::bind_method(D_METHOD("preview_translate_brushes", "ids", "delta"), &TBMapDocument::preview_translate_brushes);
	ClassDB::bind_method(D_METHOD("preview_rotate_brushes", "ids", "pivot", "axis", "radians"), &TBMapDocument::preview_rotate_brushes);
	ClassDB::bind_method(D_METHOD("translate_face", "id", "face", "delta", "topology_revision"), &TBMapDocument::translate_face);
	ClassDB::bind_method(D_METHOD("set_brush_texture", "ids", "name"), &TBMapDocument::set_brush_texture);
	ClassDB::bind_method(D_METHOD("set_face_texture", "id", "face", "name", "topology_revision"), &TBMapDocument::set_face_texture);
	ClassDB::bind_method(D_METHOD("get_face_uv", "id", "face", "topology_revision"), &TBMapDocument::get_face_uv);
	ClassDB::bind_method(D_METHOD("set_face_uv", "id", "face", "shift", "rotation", "scale", "topology_revision"), &TBMapDocument::set_face_uv);
	ClassDB::bind_method(D_METHOD("apply_face_edits", "edits"), &TBMapDocument::apply_face_edits);
	ClassDB::bind_method(D_METHOD("set_texture_sizes", "sizes"), &TBMapDocument::set_texture_sizes);
	ClassDB::bind_method(D_METHOD("export_selection", "ids"), &TBMapDocument::export_selection);
	ClassDB::bind_method(D_METHOD("import_selection", "text"), &TBMapDocument::import_selection);
	ClassDB::bind_method(D_METHOD("create_point_entity", "classname", "origin"), &TBMapDocument::create_point_entity);
	ClassDB::bind_method(D_METHOD("set_entity_property", "id", "key", "value"), &TBMapDocument::set_entity_property);
	ClassDB::bind_method(D_METHOD("remove_entity_property", "id", "key"), &TBMapDocument::remove_entity_property);
	ClassDB::bind_method(D_METHOD("translate_point_entities", "ids", "delta"), &TBMapDocument::translate_point_entities);
	ClassDB::bind_method(D_METHOD("group_brushes", "ids", "classname"), &TBMapDocument::group_brushes);
	ClassDB::bind_method(D_METHOD("return_brushes_to_worldspawn", "ids"), &TBMapDocument::return_brushes_to_worldspawn);
	ClassDB::bind_method(D_METHOD("delete_entities", "ids", "delete_owned_brushes"), &TBMapDocument::delete_entities);
	ClassDB::bind_method(D_METHOD("make_prism", "id", "sides", "axis"), &TBMapDocument::make_prism);
	ClassDB::bind_method(D_METHOD("translate_vertices", "id", "vertex_indices", "delta", "topology_revision"), &TBMapDocument::translate_vertices);
	ClassDB::bind_method(D_METHOD("translate_components", "components", "delta"), &TBMapDocument::translate_components);
	ClassDB::bind_method(D_METHOD("clip_brushes", "ids", "p0", "p1", "p2", "split"), &TBMapDocument::clip_brushes);
	ClassDB::bind_method(D_METHOD("preview_translate_components", "components", "delta"), &TBMapDocument::preview_translate_components);
	ClassDB::bind_method(D_METHOD("preview_clip_brushes", "ids", "p0", "p1", "p2", "split", "flip"), &TBMapDocument::preview_clip_brushes, DEFVAL(false));
	ADD_SIGNAL(MethodInfo("map_changed", PropertyInfo(Variant::INT, "revision")));
	ADD_SIGNAL(MethodInfo("preview_changed"));
	ADD_SIGNAL(MethodInfo("dirty_changed", PropertyInfo(Variant::BOOL, "dirty")));
}

void TBMapDocumentState::_bind_methods() {
	ClassDB::bind_method(D_METHOD("get_retained_bytes"), &TBMapDocumentState::get_retained_bytes);
	ClassDB::bind_method(D_METHOD("get_additional_retained_bytes", "already_counted"), &TBMapDocumentState::get_additional_retained_bytes);
	ClassDB::bind_method(D_METHOD("get_state_generation"), &TBMapDocumentState::get_state_generation);
}

void TBMapDocumentChange::_bind_methods() {
	ClassDB::bind_method(D_METHOD("get_epoch"), &TBMapDocumentChange::get_epoch);
	ClassDB::bind_method(D_METHOD("get_before_generation"), &TBMapDocumentChange::get_before_generation);
	ClassDB::bind_method(D_METHOD("get_after_generation"), &TBMapDocumentChange::get_after_generation);
	ClassDB::bind_method(D_METHOD("get_changed_brush_count"), &TBMapDocumentChange::get_changed_brush_count);
	ClassDB::bind_method(D_METHOD("get_retained_bytes"), &TBMapDocumentChange::get_retained_bytes);
	ClassDB::bind_method(D_METHOD("get_additional_retained_bytes", "already_counted"), &TBMapDocumentChange::get_additional_retained_bytes);
}

int64_t TBMapDocumentChange::get_retained_bytes() const {
	constexpr int64_t allocation_overhead = 4 * sizeof(void *);
	int64_t bytes = sizeof(*this) + brushes.capacity() * sizeof(BrushMemento);
	std::unordered_set<const BrushRecord *> records;
	std::unordered_set<const LMEditorBrushGeometry *> geometries;
	for (const auto &item : brushes) for (const auto &record : {item.before, item.after}) if (record && records.insert(record.get()).second) {
		bytes += sizeof(BrushRecord) + record->faces.capacity() * sizeof(LMFace) + record->materials.capacity() * sizeof(std::string) + allocation_overhead;
		for (const auto &material : record->materials) bytes += material.capacity() + 1;
		if (record->geometry && geometries.insert(record->geometry.get()).second) bytes += record->geometry->retained_bytes() + allocation_overhead;
	}
	return bytes;
}

int64_t TBMapDocumentChange::get_additional_retained_bytes(const Ref<TBMapDocumentChange> &other) const {
	constexpr int64_t allocation_overhead = 4 * sizeof(void *);
	int64_t bytes = sizeof(*this) + brushes.capacity() * sizeof(BrushMemento);
	std::unordered_set<const BrushRecord *> shared_records;
	std::unordered_set<const LMEditorBrushGeometry *> shared_geometries;
	if (other.is_valid()) for (const auto &item : other->brushes) for (const auto &record : {item.before, item.after}) if (record) {
		shared_records.insert(record.get()); if (record->geometry) shared_geometries.insert(record->geometry.get());
	}
	std::unordered_set<const BrushRecord *> records;
	std::unordered_set<const LMEditorBrushGeometry *> geometries;
	for (const auto &item : brushes) for (const auto &record : {item.before, item.after}) if (record && records.insert(record.get()).second) {
		if (!shared_records.count(record.get())) {
			bytes += sizeof(BrushRecord) + record->faces.capacity() * sizeof(LMFace) + record->materials.capacity() * sizeof(std::string) + allocation_overhead;
			for (const auto &material : record->materials) bytes += material.capacity() + 1;
		}
		if (record->geometry && !shared_geometries.count(record->geometry.get()) && geometries.insert(record->geometry.get()).second)
			bytes += record->geometry->retained_bytes() + allocation_overhead;
	}
	return bytes;
}

int64_t TBMapDocumentState::get_retained_bytes() const {
	constexpr int64_t allocation_overhead = 4 * sizeof(void *);
	int64_t bytes = sizeof(TBMapDocumentState) + (map ? map->retained_bytes() + allocation_overhead : 0) +
		(canonical ? sizeof(std::string) + canonical->capacity() + 1 + allocation_overhead : 0);
	if (base_geometry) bytes += base_geometry->retained_bytes() + allocation_overhead;
	Array texture_keys = texture_sizes.keys();
	bytes += sizeof(Dictionary) + texture_keys.size() * (2 * sizeof(Variant) + allocation_overhead);
	for (int i = 0; i < texture_keys.size(); ++i) bytes += String(texture_keys[i]).utf8().length() + 1;
	if (editor) {
		bytes += sizeof(EditorState) + allocation_overhead + editor->brushes.bucket_count() * sizeof(void *) +
			editor->brushes.size() * (sizeof(decltype(editor->brushes)::value_type) + 3 * sizeof(void *) + allocation_overhead) +
			editor->change.brush_ids.capacity() * sizeof(int64_t);
		std::unordered_set<const LMEditorBrushGeometry *> geometries;
		for (const auto &item : editor->brushes) {
			bytes += sizeof(EditorState::BrushRecord) + item.second->faces.capacity() * sizeof(LMFace) + item.second->materials.capacity() * sizeof(std::string) + allocation_overhead;
			for (const auto &material : item.second->materials) bytes += material.capacity() + 1;
			if (geometries.insert(item.second->geometry.get()).second) bytes += item.second->geometry->retained_bytes() + allocation_overhead;
		}
	}
	return bytes;
}

int64_t TBMapDocumentState::get_additional_retained_bytes(const Ref<TBMapDocumentState> &other) const {
	constexpr int64_t allocation_overhead = 4 * sizeof(void *);
	int64_t bytes = sizeof(TBMapDocumentState);
	if (map && (other.is_null() || map != other->map)) bytes += map->retained_bytes() + allocation_overhead;
	if (canonical && (other.is_null() || canonical != other->canonical)) bytes += sizeof(std::string) + canonical->capacity() + 1 + allocation_overhead;
	if (base_geometry && (other.is_null() || base_geometry != other->base_geometry)) bytes += base_geometry->additional_retained_bytes(other.is_valid() ? other->base_geometry.get() : nullptr) + allocation_overhead;
	if (other.is_null() || texture_sizes != other->texture_sizes) {
		Array texture_keys = texture_sizes.keys();
		bytes += sizeof(Dictionary) + texture_keys.size() * (2 * sizeof(Variant) + allocation_overhead);
		for (int i = 0; i < texture_keys.size(); ++i) bytes += String(texture_keys[i]).utf8().length() + 1;
	}
	if (editor && (other.is_null() || editor != other->editor)) {
		bytes += sizeof(EditorState) + allocation_overhead + editor->brushes.bucket_count() * sizeof(void *) +
			editor->brushes.size() * (sizeof(decltype(editor->brushes)::value_type) + 3 * sizeof(void *) + allocation_overhead) +
			editor->change.brush_ids.capacity() * sizeof(int64_t);
		std::unordered_set<const LMEditorBrushGeometry *> comparison_geometries;
		if (other.is_valid() && other->editor) for (const auto &item : other->editor->brushes) comparison_geometries.insert(item.second->geometry.get());
		std::unordered_set<const LMEditorBrushGeometry *> charged_geometries;
		for (const auto &item : editor->brushes) {
			bool shared_record = false;
			if (other.is_valid() && other->editor) {
				auto found = other->editor->brushes.find(item.first);
				shared_record = found != other->editor->brushes.end() && found->second == item.second;
			}
			if (!shared_record) {
				bytes += sizeof(EditorState::BrushRecord) + item.second->faces.capacity() * sizeof(LMFace) + item.second->materials.capacity() * sizeof(std::string) + allocation_overhead;
				for (const auto &material : item.second->materials) bytes += material.capacity() + 1;
			}
			if (!comparison_geometries.count(item.second->geometry.get()) && charged_geometries.insert(item.second->geometry.get()).second)
				bytes += item.second->geometry->retained_bytes() + allocation_overhead;
		}
	}
	return bytes;
}

size_t TBMapDocumentState::BaseEditorGeometry::retained_bytes() const {
	constexpr size_t allocation_overhead = 4 * sizeof(void *);
	size_t bytes = sizeof(*this) + brushes.bucket_count() * sizeof(void *) + brushes.size() * (sizeof(decltype(brushes)::value_type) + allocation_overhead);
	std::unordered_set<const LMEditorBrushGeometry *> seen;
	for (const auto &item : brushes) if (seen.insert(item.second.get()).second) bytes += item.second->retained_bytes() + allocation_overhead;
	return bytes;
}

size_t TBMapDocumentState::BaseEditorGeometry::additional_retained_bytes(const BaseEditorGeometry *other) const {
	constexpr size_t allocation_overhead = 4 * sizeof(void *);
	size_t bytes = sizeof(*this) + brushes.bucket_count() * sizeof(void *) + brushes.size() * (sizeof(decltype(brushes)::value_type) + allocation_overhead);
	std::unordered_set<const LMEditorBrushGeometry *> shared;
	if (other) for (const auto &item : other->brushes) shared.insert(item.second.get());
	std::unordered_set<const LMEditorBrushGeometry *> charged;
	for (const auto &item : brushes) if (!shared.count(item.second.get()) && charged.insert(item.second.get()).second) bytes += item.second->retained_bytes() + allocation_overhead;
	return bytes;
}
