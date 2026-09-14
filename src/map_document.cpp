#include "map_document.h"
#include "map/brush.h"
#include "map/face.h"
#include "map/patch.h"
#include "map/map_parser.h"
#include "map/map_writer.h"
#include "map/geo_generator.h"
#include "map/brush_topology.h"
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <atomic>
#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cmath>
#include <map>
#include <set>
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
bool valid_geometry(const LMMapData &map) {
	for (int e = 0; e < map.entity_count; ++e) {
		for (int b = 0; b < map.entities[e].brush_count; ++b) {
			const auto &brush = map.entities[e].brushes[b];
			const auto &geo = map.entity_geo[e].brushes[b];
			double volume = 0;
			int contributing_faces = 0;
			const auto topology = lm_extract_brush_topology(brush, geo);
			for (int f = 0; f < brush.face_count; ++f) {
				const auto &face = geo.faces[f];
				// Redundant planes occur in production Quake maps and are already
				// ignored by mesh generation. Preserve them for round-tripping.
				if (face.vertex_count < 3) continue;
				++contributing_faces;
				for (int v = 0; v < face.vertex_count; ++v) {
					const auto &vertex = face.vertices[v];
					const auto &p = vertex.vertex;
					if (!std::isfinite(p.x) || !std::isfinite(p.y) || !std::isfinite(p.z) || !std::isfinite(vertex.uv.u) || !std::isfinite(vertex.uv.v)) return false;
					if (std::abs(p.x) > 1e9 || std::abs(p.y) > 1e9 || std::abs(p.z) > 1e9) return false;
					if (topology.faces[f].vertex_indices[v] == topology.faces[f].vertex_indices[(v + 1) % face.vertex_count]) return false;
				}
				for (int v = 1; v + 1 < face.vertex_count; ++v) {
					vec3 a = vec3_sub(face.vertices[0].vertex, brush.center);
					vec3 c = vec3_sub(face.vertices[v].vertex, brush.center);
					vec3 d = vec3_sub(face.vertices[v + 1].vertex, brush.center);
					if (vec3_dot(vec3_cross(vec3_sub(c, a), vec3_sub(d, a)), brush.faces[f].plane_normal) >= -1e-10) return false;
					volume += std::abs(vec3_dot(a, vec3_cross(c, d))) / 6.0;
				}
			}
			if (contributing_faces < 4 || !std::isfinite(volume) || volume <= 1e-9) return false;
			std::map<std::pair<int, int>, int> edge_uses;
			for (const auto &face : topology.faces) {
				if (face.vertex_indices.size() < 3) continue;
				for (size_t v = 0; v < face.vertex_indices.size(); ++v) {
					int a = face.vertex_indices[v], b = face.vertex_indices[(v + 1) % face.vertex_indices.size()];
					if (a > b) std::swap(a, b);
					++edge_uses[{a, b}];
				}
			}
			for (const auto &edge : edge_uses) if (edge.second != 2) return false;
		}
	}
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

Dictionary TBMapDocument::prepare(const std::string &text, std::shared_ptr<LMMapData> &candidate, const StringName &operation, const String &error_path, std::string *normalized) const {
	candidate = std::make_shared<LMMapData>();
	LMMapParser parser(candidate);
	if (!parser.load_from_text(text)) return failure(parser.error.code.c_str(), parser.error.message.c_str(), operation, error_path, parser.error.line, parser.error.column);
	std::string written = lm_write_map(*candidate);
	if (written.size() > LMMapParser::MAX_TEXT_BYTES) return failure("LIMIT_EXCEEDED", "Canonical map exceeds 16 MiB", operation, error_path);
	if (normalized) *normalized = std::move(written);
	resolve_texture_sizes(*candidate, texture_sizes);
	LMGeoGenerator(candidate).run();
	if (!valid_geometry(*candidate)) return failure("INVALID_GEOMETRY", "Brush must be a finite, closed solid with nonempty faces", operation, error_path);
	return success();
}

void TBMapDocument::assign_ids(LMMapData &candidate) {
	issued_ids.clear();
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
	if (!location || location->entity >= static_cast<int>(edit.entities.size())) return nullptr;
	auto &primitives = edit.entities[location->entity].primitives;
	return location->primitive < static_cast<int>(primitives.size()) && !primitives[location->primitive].patch && primitives[location->primitive].id == id ? &primitives[location->primitive] : nullptr;
}
void TBMapDocument::commit(std::shared_ptr<LMMapData> candidate, const std::string &text, bool was_dirty) {
	++topology;
	for (int i = 0; i < candidate->entity_count; ++i) for (int b = 0; b < candidate->entities[i].brush_count; ++b) candidate->entities[i].brushes[b].topology_revision = topology;
	map = std::move(candidate);
	rebuild_live_index();
	invalidate_spatial_index();
	invalidate_preview_cache();
	canonical = std::make_shared<const std::string>(text);
	++revision;
	emit_signal("map_changed", revision);
	if (was_dirty != is_dirty()) emit_signal("dirty_changed", is_dirty());
}
Dictionary TBMapDocument::replace_text(const std::string &text, const StringName &operation, const String &new_path, bool saved) {
	std::shared_ptr<LMMapData> candidate;
	std::string normalized;
	Dictionary result = prepare(text, candidate, operation, new_path, &normalized);
	if (!bool(result["ok"])) return result;
	bool was_dirty = is_dirty();
	assign_ids(*candidate);
	epoch = ++epoch_counter;
	path = new_path;
	disk_path = saved ? absolute_path(new_path) : String();
	has_baseline = saved;
	baseline = saved ? normalized : "";
	disk_bytes = saved ? text : "";
	commit(candidate, normalized, was_dirty);
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
	while (written && offset < canonical->size()) {
		ssize_t count = write(fd, canonical->data() + offset, canonical->size() - offset);
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
	baseline = *canonical; disk_bytes = *canonical; has_baseline = true;
	if (was_dirty) emit_signal("dirty_changed", false);
	return success(changed);
#endif
}

Dictionary TBMapDocument::export_text() const { return success(false, string(*canonical)); }
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
	out["schema"] = 1; out["epoch"] = epoch; out["text"] = string(*canonical); out["identities"] = identities(*map);
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
	if (normalized == *canonical && identities(*candidate) == identities(*map)) return success();
	commit(candidate, normalized, is_dirty());
	return success(true);
}
Ref<TBMapDocumentState> TBMapDocument::capture_history_state() const {
	Ref<TBMapDocumentState> state;
	state.instantiate();
	state->map = map;
	state->canonical = canonical;
	state->texture_sizes = texture_sizes;
	state->epoch = epoch;
	return state;
}
bool TBMapDocument::is_history_state_current(const Ref<TBMapDocumentState> &state) const {
	return state.is_valid() && state->epoch == epoch && state->map == map && state->canonical == canonical;
}
Dictionary TBMapDocument::restore_history_state(const Ref<TBMapDocumentState> &state) {
	if (state.is_null() || state->epoch != epoch) return failure("SNAPSHOT_MISMATCH", "History state document epoch mismatch", "restore_history_state");
	if (is_history_state_current(state)) return success();
	std::shared_ptr<LMMapData> candidate;
	if (state->texture_sizes == texture_sizes) {
		candidate = state->map;
	} else {
		Dictionary result = prepare(*state->canonical, candidate, "restore_history_state", path);
		if (!bool(result["ok"])) return result;
		if (!apply_identities(*candidate, identities(*state->map))) return failure("SNAPSHOT_MISMATCH", "History state identities no longer match", "restore_history_state");
	}
	commit(candidate, *state->canonical, is_dirty());
	return success(true);
}
Dictionary TBMapDocument::rebuild() {
	std::shared_ptr<LMMapData> candidate;
	Dictionary result = prepare(*canonical, candidate, "rebuild", path);
	if (!bool(result["ok"])) return result;
	apply_identities(*candidate, identities(*map));
	++topology;
	for (int i = 0; i < candidate->entity_count; ++i) for (int b = 0; b < candidate->entities[i].brush_count; ++b) candidate->entities[i].brushes[b].topology_revision = topology;
	map = candidate;
	rebuild_live_index();
	invalidate_spatial_index();
	invalidate_preview_cache();
	emit_signal("preview_changed");
	return success(true);
}
PackedStringArray TBMapDocument::get_texture_names() const {
	PackedStringArray out;
	for (int i = 0; i < map->texture_count; ++i) out.push_back(String::utf8(map->textures[i].name));
	return out;
}
Array TBMapDocument::get_entities() const {
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
	ClassDB::bind_method(D_METHOD("rebuild"), &TBMapDocument::rebuild);
	ClassDB::bind_method(D_METHOD("is_dirty"), &TBMapDocument::is_dirty);
	ClassDB::bind_method(D_METHOD("get_path"), &TBMapDocument::get_path);
	ClassDB::bind_method(D_METHOD("get_revision"), &TBMapDocument::get_revision);
	ClassDB::bind_method(D_METHOD("get_topology_revision"), &TBMapDocument::get_topology_revision);
	ClassDB::bind_method(D_METHOD("get_epoch"), &TBMapDocument::get_epoch);
	ClassDB::bind_method(D_METHOD("get_texture_names"), &TBMapDocument::get_texture_names);
	ClassDB::bind_method(D_METHOD("get_entities"), &TBMapDocument::get_entities);
	ClassDB::bind_method(D_METHOD("get_draw_data"), &TBMapDocument::get_draw_data);
	ClassDB::bind_method(D_METHOD("get_preview_data"), &TBMapDocument::get_preview_data);
	ClassDB::bind_method(D_METHOD("prepare_preview_chunks", "scale", "hidden_ids", "filter_mask", "chunk_triangles", "chunk_size"), &TBMapDocument::prepare_preview_chunks, DEFVAL(2048), DEFVAL(64.0));
	ClassDB::bind_method(D_METHOD("get_preview_chunk", "chunk_id"), &TBMapDocument::get_preview_chunk);
	ClassDB::bind_method(D_METHOD("query_brushes_2d", "hidden_axis", "mins", "maxs"), &TBMapDocument::query_brushes_2d);
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
}

int64_t TBMapDocumentState::get_retained_bytes() const {
	return sizeof(TBMapDocumentState) + (map ? map->retained_bytes() : 0) +
		(canonical ? sizeof(std::string) + canonical->capacity() + 1 : 0);
}

int64_t TBMapDocumentState::get_additional_retained_bytes(const Ref<TBMapDocumentState> &other) const {
	int64_t bytes = sizeof(TBMapDocumentState);
	if (map && (other.is_null() || map != other->map)) bytes += map->retained_bytes();
	if (canonical && (other.is_null() || canonical != other->canonical)) bytes += sizeof(std::string) + canonical->capacity() + 1;
	return bytes;
}
