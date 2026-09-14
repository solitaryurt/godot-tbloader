#include "map_document.h"
#include "map/brush.h"
#include "map/patch.h"
#include "map/map_writer.h"
#include "map/map_parser.h"
#include "map/geo_generator.h"
#include "map/brush_topology.h"
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <algorithm>
#include <charconv>
#include <chrono>
#include <cctype>
#include <cmath>
#include <limits>
#include <map>
#include <set>

using namespace godot;
namespace {
std::string bytes(const String &s) { auto b = s.utf8(); return {b.get_data(), size_t(b.length())}; }
String text(const std::string &s) { return String::utf8(s.data(), s.size()); }
vec3 native(Vector3 v) { return {v.x, v.y, v.z}; }
Vector3 vector(vec3 v) { return Vector3(v.x, v.y, v.z); }
bool valid(Vector3 v) { return v.is_finite() && v.abs()[v.abs().max_axis_index()] <= 1e9; }
bool token(const String &s, bool empty = false) {
	if ((!empty && s.is_empty()) || s.utf8().length() > 65536) return false;
	for (int i = 0; i < s.length(); ++i) if (s[i] == 0) return false;
	return true;
}
std::vector<int64_t> unique(const PackedInt64Array &ids) {
	std::vector<int64_t> out; std::set<int64_t> seen;
	for (int64_t id : ids) if (seen.insert(id).second) out.push_back(id);
	return out;
}
size_t map_geometry_work(const LMMapData &data) {
	size_t work = 0;
	for (int e = 0; e < data.entity_count; ++e) {
		const auto &entity = data.entities[e];
		for (int b = 0; b < entity.brush_count; ++b) {
			const size_t faces = entity.brushes[b].face_count;
			work += faces * faces * faces;
		}
		for (int p = 0; p < entity.patch_count; ++p) work += size_t(entity.patches[p].width) * entity.patches[p].height * 33 * 33;
	}
	return work;
}
size_t edit_geometry_work(const LMMapEdit &edit) {
	size_t work = 0;
	for (const auto &entity : edit.entities) for (const auto &primitive : entity.primitives) if (!primitive.patch) {
		const size_t faces = primitive.faces.size();
		work += faces * faces * faces;
	}
	return work;
}
void move_face(LMEditFace &f, Vector3 delta) {
	auto &p = f.plane.plane_points;
	p.v0 = vec3_add(p.v0, native(delta)); p.v1 = vec3_add(p.v1, native(delta)); p.v2 = vec3_add(p.v2, native(delta));
}
struct HullPlane {
	int a, b, c;
	vec3 normal;
	double distance;
	bool transformed;
};
bool face_has_vertex(const LMBrushTopologyFace &face, int vertex) {
	return std::find(face.vertex_indices.begin(), face.vertex_indices.end(), vertex) != face.vertex_indices.end();
}
LMFace &source_face(LMFace &face) { return face; }
LMFace &source_face(LMEditFace &face) { return face.plane; }
template <typename Face>
bool rebuild_vertex_hull(std::vector<Face> &target, const LMBrushTopology &topology, const std::vector<vec3> &vertices, const std::set<int> &selected, std::vector<int> *source_indices = nullptr) {
	std::vector<HullPlane> planes;
	for (int a = 0; a < static_cast<int>(vertices.size()); ++a) for (int b = a + 1; b < static_cast<int>(vertices.size()); ++b) for (int c = b + 1; c < static_cast<int>(vertices.size()); ++c) {
		int ia = a, ib = b, ic = c;
		// Keep the native doubles throughout reconstruction. Godot Vector3 is
		// normally float: its roundoff can reject a plane's own defining points
		// or fail to merge identical normals, especially after successive drags.
		vec3 p = vertices[a], q = vertices[b], r = vertices[c];
		vec3 normal = vec3_cross(vec3_sub(q, p), vec3_sub(r, p));
		double length = vec3_length(normal);
		if (length <= 1e-8) continue;
		normal = vec3_div_double(normal, length);
		double distance = vec3_dot(normal, p), low = 0, high = 0;
		for (const vec3 &point : vertices) {
			// Classify relative to a point on the plane to avoid cancellation
			// between two large world-space plane distances.
			double side = vec3_dot(normal, vec3_sub(point, p));
			low = std::min(low, side); high = std::max(high, side);
			if (low < -1e-5 && high > 1e-5) break;
		}
		if (low < -1e-5 && high > 1e-5) continue;
		if (high > 1e-5) { normal = vec3_mul_double(normal, -1); distance = -distance; std::swap(ib, ic); }
		bool transformed = selected.count(a) || selected.count(b) || selected.count(c);
		bool duplicate = false;
		for (auto &plane : planes) if (vec3_dot(plane.normal, normal) > 1.0 - 1e-8 && std::abs(plane.distance - distance) < 1e-5) {
			plane.transformed |= transformed; duplicate = true; break;
		}
		if (!duplicate) planes.push_back({ia, ib, ic, normal, distance, transformed});
	}
	if (planes.size() < 4 || planes.size() > 64) return false;
	std::vector<Face> faces; std::vector<int> origins;
	faces.reserve(planes.size());
	for (const auto &plane : planes) {
		int source = -1;
		for (int f = 0; f < static_cast<int>(topology.faces.size()); ++f) {
			const auto &face = topology.faces[f];
			if (face_has_vertex(face, plane.a) && face_has_vertex(face, plane.b) && face_has_vertex(face, plane.c)) { source = f; break; }
		}
		bool transformed = plane.transformed || source < 0;
		if (source < 0) for (int f = 0; f < static_cast<int>(topology.faces.size()); ++f) if (face_has_vertex(topology.faces[f], plane.a)) { source = f; break; }
		if (source < 0 || source >= static_cast<int>(target.size())) return false;
		auto face = target[source]; auto &plane_source = source_face(face);
		// Like VertexModePlane, retain untouched source planes exactly. A merged
		// plane is transformed if any of its triangles used a selected vertex.
		if (transformed || vec3_dot(plane.normal, plane_source.plane_normal) < 0) {
			// LMFace normals use (p2 - p0) x (p1 - p0), opposite the winding above.
			plane_source.plane_points = {vertices[plane.a], vertices[plane.c], vertices[plane.b]};
		}
		faces.push_back(std::move(face)); origins.push_back(source);
	}
	target = std::move(faces); if (source_indices) *source_indices = std::move(origins);
	return true;
}
std::string origin_text(Vector3 v) {
	std::string out;
	for (double value : { double(v.x), double(v.y), double(v.z) }) {
		if (!out.empty()) out += ' ';
		char buffer[64]; auto converted = std::to_chars(buffer, buffer + sizeof(buffer), value, std::chars_format::general, std::numeric_limits<double>::max_digits10);
		out.append(buffer, converted.ptr);
	}
	return out;
}
std::string brush_source_text(const std::vector<LMFace> &faces, const std::vector<std::string> &materials) {
	std::string out;
	for (size_t f = 0; f < faces.size(); ++f) out += lm_write_face(faces[f], materials[f]);
	return out;
}
LMBrushTopology compact_topology(const LMEditorBrushGeometry &geometry) {
	LMBrushTopology out; out.vertices = geometry.positions; out.mins = geometry.mins; out.maxs = geometry.maxs;
	for (const auto &edge : geometry.edges) out.edges.emplace_back(edge.a, edge.b);
	for (const auto &face : geometry.faces) { LMBrushTopologyFace item; item.center = face.center;
		for (uint32_t v = 0; v < face.corner_count; ++v) { const auto &corner = geometry.corners[face.corner_begin + v]; item.vertex_indices.push_back(corner.position); item.winding.push_back(geometry.positions[corner.position]); }
		out.faces.push_back(std::move(item));
	}
	return out;
}
bool read_origin(const std::string &s, Vector3 &v) {
	if (s.empty()) { v = Vector3(); return true; }
	double values[3]; const char *next = s.data(), *last = next + s.size();
	for (double &value : values) {
		while (next != last && std::isspace(static_cast<unsigned char>(*next))) ++next;
		auto parsed = std::from_chars(next, last, value, std::chars_format::general);
		if (parsed.ec != std::errc() || parsed.ptr == next) return false;
		next = parsed.ptr;
	}
	while (next != last && std::isspace(static_cast<unsigned char>(*next))) ++next;
	v = Vector3(values[0], values[1], values[2]); return next == last && valid(v);
}
Array candidate_draw_data(const LMMapData &candidate, const Dictionary &sources, const std::unordered_map<int64_t, std::shared_ptr<const LMEditorBrushGeometry>> &geometries) {
	Array out;
	for (int e = 0; e < candidate.entity_count; ++e) for (int b = 0; b < candidate.entities[e].brush_count; ++b) {
		const auto &brush = candidate.entities[e].brushes[b];
		if (!sources.has(brush.id)) continue;
		const auto found = geometries.find(brush.id); if (found == geometries.end()) continue; const auto &geometry = *found->second;
		Dictionary entry; Array faces; PackedVector3Array vertices, edges; PackedInt32Array edge_indices;
		for (const auto &point : geometry.positions) vertices.push_back(vector(point));
		for (const auto &edge : geometry.edges) {
			edge_indices.push_back(edge.a); edge_indices.push_back(edge.b);
			edges.push_back(vector(geometry.positions[edge.a])); edges.push_back(vector(geometry.positions[edge.b]));
		}
		for (int f = 0; f < brush.face_count; ++f) {
			const auto &face = geometry.faces[f]; Dictionary data; PackedVector3Array winding; PackedInt32Array indices;
			for (uint32_t v = 0; v < face.corner_count; ++v) { const auto &corner = geometry.corners[face.corner_begin + v]; winding.push_back(vector(geometry.positions[corner.position])); indices.push_back(corner.position); }
			data["index"] = f; data["winding"] = winding; data["vertex_indices"] = indices;
			data["center"] = vector(face.center); data["normal"] = vector(brush.faces[f].plane_normal);
			data["texture"] = String::utf8(candidate.textures[brush.faces[f].texture_idx].name); faces.push_back(data);
		}
		entry["id"] = brush.id; entry["source_id"] = sources[brush.id]; entry["entity_id"] = candidate.entities[e].id;
		entry["aabb_min"] = vector(geometry.mins); entry["aabb_max"] = vector(geometry.maxs); entry["vertices"] = vertices; entry["edges"] = edges;
		entry["edge_vertex_indices"] = edge_indices; entry["faces"] = faces; out.push_back(entry);
	}
	return out;
}
}

Dictionary TBMapDocument::prepare_edit_candidate(const LMMapEdit &edit, const StringName &operation, std::shared_ptr<LMMapData> &candidate, std::shared_ptr<const TBMapDocumentState::BaseEditorGeometry> &geometry, std::string &normalized, int64_t &high) const {
	Dictionary result = prepare(edit.text(canonical_text().size() + 1024), candidate, operation, path, &normalized);
	if (!bool(result["ok"])) return result;
	high = next_id;
	for (const auto &e : edit.entities) { high = std::max(high, e.id + 1); for (const auto &p : e.primitives) high = std::max(high, p.id + 1); }
	for (int i = 0; i < candidate->entity_count; ++i) {
		auto &e = candidate->entities[i]; const auto &source = edit.entities[i];
		e.id = source.id ? source.id : high++;
		for (int k = 0; k < e.primitive_count; ++k) {
			const auto &p = e.primitives[k]; int64_t id = source.primitives[k].id;
			if (!id) id = high++;
			if (p.is_patch) e.patches[p.index].id = id; else e.brushes[p.index].id = id;
		}
	}
	result = build_base_editor_geometry(*candidate, texture_sizes, geometry, operation, path);
	if (!bool(result["ok"])) return result;
	return success();
}

Dictionary TBMapDocument::finish_edit(const LMMapEdit &edit, const StringName &operation, const Variant &value) {
	last_document_change.unref();
	last_operation = {}; last_operation.operation = operation; translation_counter_scope = true;
	std::shared_ptr<LMMapData> candidate;
	std::shared_ptr<const TBMapDocumentState::BaseEditorGeometry> geometry;
	std::string normalized;
	int64_t high = next_id;
	Dictionary result = prepare_edit_candidate(edit, operation, candidate, geometry, normalized, high);
	if (!bool(result["ok"])) { translation_counter_scope = false; return result; }
	if (normalized == canonical_text() && identities(*candidate) == identities(*map)) { last_operation.success = true; translation_counter_scope = false; return success(false, value); }
	next_id = high;
	for (int i = 0; i < candidate->entity_count; ++i) {
		const auto &e = candidate->entities[i]; issued_ids[e.id] = 'e';
		for (int k = 0; k < e.primitive_count; ++k) { const auto &p = e.primitives[k]; issued_ids[p.is_patch ? e.patches[p.index].id : e.brushes[p.index].id] = p.is_patch ? 'p' : 'b'; }
	}
	commit(candidate, geometry, normalized, is_dirty());
	last_operation.success = true; last_operation.committed = true; translation_counter_scope = false;
	return success(true, value);
}

Dictionary TBMapDocument::preview_edit(const LMMapEdit &edit, const StringName &operation, const Dictionary &sources) const {
	std::shared_ptr<LMMapData> candidate;
	std::shared_ptr<const TBMapDocumentState::BaseEditorGeometry> geometry;
	std::string normalized;
	int64_t high = next_id;
	Dictionary result = prepare_edit_candidate(edit, operation, candidate, geometry, normalized, high);
	if (!bool(result["ok"])) return result;
	return success(false, candidate_draw_data(*candidate, sources, geometry->brushes));
}

void TBMapDocument::stage_preview_brushes(const PackedInt64Array &ids, LMMapEdit &edit) const {
	const auto view = materialize_current_source();
	const auto list = unique(ids);
	const std::set<int64_t> selected(list.begin(), list.end());
	for (int e = 0; e < view->entity_count; ++e) {
		const auto &source = view->entities[e];
		LMEditEntity entity;
		entity.id = source.id;
		for (int k = 0; k < source.property_count; ++k) entity.epairs.emplace_back(source.properties[k].key, source.properties[k].value);
		for (int k = 0; k < source.primitive_count; ++k) {
			const auto &primitive = source.primitives[k];
			if (primitive.is_patch || !selected.count(source.brushes[primitive.index].id)) continue;
			const auto &brush = source.brushes[primitive.index];
			LMEditPrimitive staged;
			staged.id = brush.id;
			for (int f = 0; f < brush.face_count; ++f) staged.faces.push_back({brush.faces[f], view->textures[brush.faces[f].texture_idx].name});
			entity.primitives.push_back(std::move(staged));
		}
		if (!entity.primitives.empty()) edit.entities.push_back(std::move(entity));
	}
}

Dictionary TBMapDocument::preview_fragments(const LMMapEdit &before, const LMMapEdit &after, const StringName &operation, const Dictionary &sources) const {
	if (after.entities.empty()) return success(false, Array());
	const std::string old_text = before.text(), new_text = after.text();
	const size_t current_text_size = size_t(int64_t(canonical->size()) + (editor ? editor->canonical_size_delta : 0));
	if (new_text.size() > old_text.size() && new_text.size() - old_text.size() > LMMapParser::MAX_TEXT_BYTES - current_text_size)
		return failure("LIMIT_EXCEEDED", "Canonical map exceeds 16 MiB", operation, path);
	const size_t old_work = edit_geometry_work(before), new_work = edit_geometry_work(after), current_work = map_geometry_work(*map);
	if (new_work > old_work && new_work - old_work > 8000000 - current_work)
		return failure("LIMIT_EXCEEDED", "Geometry work budget exceeded", operation, path);
	std::shared_ptr<LMMapData> candidate;
	Dictionary result = prepare(new_text, candidate, operation, path); if (!bool(result["ok"])) return result;
	for (int e = 0; e < candidate->entity_count; ++e) {
		candidate->entities[e].id = after.entities[e].id;
		for (int k = 0; k < candidate->entities[e].primitive_count; ++k) {
			const auto &ref = candidate->entities[e].primitives[k];
			if (ref.is_patch) candidate->entities[e].patches[ref.index].id = after.entities[e].primitives[k].id;
			else candidate->entities[e].brushes[ref.index].id = after.entities[e].primitives[k].id;
		}
	}
	std::shared_ptr<const TBMapDocumentState::BaseEditorGeometry> geometry;
	result = build_base_editor_geometry(*candidate, texture_sizes, geometry, operation, path); if (!bool(result["ok"])) return result;
	return success(false, candidate_draw_data(*candidate, sources, geometry->brushes));
}
Dictionary TBMapDocument::check_brushes(const PackedInt64Array &ids, const StringName &operation) const {
	for (int64_t id : ids) if (!live_location(id, 'b')) {
		Dictionary r = failure("INVALID_ID", "Unknown brush handle", operation); Dictionary error = r["error"]; error["brush_id"] = id; return r;
	}
	return success();
}
Dictionary TBMapDocument::check_face(int64_t id, int face, int64_t token, const StringName &operation) const {
	if (const auto *location = live_location(id, 'b')) {
		const auto &brush = current_brush(location->entity, location->index);
		if (brush.topology_revision == token && face >= 0 && face < brush.face_count) return success();
		Dictionary r = failure(brush.topology_revision != token ? "STALE_COMPONENT" : "INVALID_ARGUMENT", "Stale topology token or invalid face index", operation);
		Dictionary error = r["error"]; error["brush_id"] = id; error["face"] = face; return r;
	}
	PackedInt64Array ids; ids.push_back(id); return check_brushes(ids, operation);
}
Dictionary TBMapDocument::create_cuboid(Vector3 mins, Vector3 maxs, const String &texture) {
	if (!valid(mins) || !valid(maxs) || mins.x >= maxs.x || mins.y >= maxs.y || mins.z >= maxs.z || !token(texture)) return failure("INVALID_ARGUMENT", "Expected finite increasing bounds and a texture name", "create_cuboid");
	LMMapEdit edit(*materialize_current_source()); auto p = lm_edit_cuboid(native(mins), native(maxs), bytes(texture)); p.id = next_id;
	edit.world().primitives.push_back(p); return finish_edit(edit, "create_cuboid", p.id);
}
Dictionary TBMapDocument::duplicate_brushes(const PackedInt64Array &ids) {
	auto r = check_brushes(ids, "duplicate_brushes"); if (!bool(r["ok"])) return r;
	LMMapEdit edit(*materialize_current_source()); PackedInt64Array out; int64_t id = next_id;
	for (int64_t source : unique(ids)) {
		const auto *location = live_location(source, 'b');
		auto &primitives = edit.entities[location->entity].primitives;
		auto copy = primitives[location->primitive]; copy.id = id++; out.push_back(copy.id); primitives.push_back(std::move(copy));
	}
	return finish_edit(edit, "duplicate_brushes", out);
}
Dictionary TBMapDocument::merge_brushes(const PackedInt64Array &ids) {
	auto r = check_brushes(ids, "merge_brushes"); if (!bool(r["ok"])) return r;
	const auto list = unique(ids);
	if (list.size() < 2) return failure("INVALID_ARGUMENT", "Expected at least two unique brushes", "merge_brushes");
	const auto *owner = live_location(list.front(), 'b');
	std::vector<LMBrushTopology> topologies; topologies.reserve(list.size());
	LMMapEdit edit(*materialize_current_source()); std::vector<const LMEditPrimitive *> sources; sources.reserve(list.size());
	for (int64_t id : list) {
		const auto *location = live_location(id, 'b');
		if (location->entity != owner->entity) return failure("INVALID_ARGUMENT", "All brushes must have the same owner", "merge_brushes");
		topologies.push_back(compact_topology(*current_brush_geometry(location->entity, location->index).compact));
		sources.push_back(edit_brush(edit, id));
	}
	LMEditPrimitive merged;
	const auto result = lm_edit_merge_brushes(sources, topologies, merged);
	if (result == LMMergeBrushResult::LIMIT_EXCEEDED) return failure("LIMIT_EXCEEDED", "Merged brush exceeds 64 supporting planes", "merge_brushes");
	if (result != LMMergeBrushResult::OK) return failure("INVALID_GEOMETRY", "Brushes must form a connected convex union through complete matching faces", "merge_brushes");
	merged.id = next_id;
	std::set<int64_t> selected(list.begin(), list.end());
	auto &primitives = edit.entities[owner->entity].primitives;
	auto insertion = std::find_if(primitives.begin(), primitives.end(), [&](const LMEditPrimitive &p) { return selected.count(p.id); });
	const size_t offset = insertion - primitives.begin();
	primitives.erase(std::remove_if(primitives.begin(), primitives.end(), [&](const LMEditPrimitive &p) { return selected.count(p.id); }), primitives.end());
	primitives.insert(primitives.begin() + offset, std::move(merged));
	return finish_edit(edit, "merge_brushes", next_id);
}
Dictionary TBMapDocument::delete_brushes(const PackedInt64Array &ids) {
	auto r = check_brushes(ids, "delete_brushes"); if (!bool(r["ok"])) return r;
	LMMapEdit edit(*materialize_current_source()); auto list = unique(ids); std::set<int64_t> selected(list.begin(), list.end());
	for (auto &e : edit.entities) e.primitives.erase(std::remove_if(e.primitives.begin(), e.primitives.end(), [&](const LMEditPrimitive &p) { return selected.count(p.id); }), e.primitives.end());
	return finish_edit(edit, "delete_brushes");
}
Dictionary TBMapDocument::translate_brushes(const PackedInt64Array &ids, Vector3 delta) {
	last_document_change.unref();
	auto r = check_brushes(ids, "translate_brushes"); if (!bool(r["ok"])) return r;
	if (!valid(delta)) return failure("INVALID_ARGUMENT", "Invalid translation", "translate_brushes");
	const auto selected = unique(ids);
	if (selected.empty() || delta == Vector3()) return success();
	return local_brush_transaction(selected, "translate_brushes", LMEditorBrushDirtyDomain::POSITIONS, [&](auto &drafts) {
		for (auto &draft : drafts) for (auto &face : draft.faces) for (vec3 *point : {&face.plane_points.v0, &face.plane_points.v1, &face.plane_points.v2}) {
			*point = vec3_add(*point, native(delta));
			if (!valid(vector(*point))) return failure("INVALID_ARGUMENT", "Translated brush exceeds finite map bounds", "translate_brushes");
		}
		return success();
	});
}

Dictionary TBMapDocument::local_brush_transaction(const std::vector<int64_t> &ids, const StringName &operation, LMEditorBrushDirtyDomain domains, const LocalBrushMutation &mutation) {
	last_document_change.unref();
	last_operation = {}; last_operation.operation = operation; translation_counter_scope = false;
	std::vector<LocalBrushDraft> drafts; drafts.reserve(ids.size()); std::vector<std::string> before;
	std::vector<std::shared_ptr<const EditorState::BrushRecord>> before_records; before_records.reserve(ids.size());
	std::vector<std::shared_ptr<const EditorState::BrushRecord>> base_records; base_records.reserve(ids.size());
	for (int64_t id : ids) {
		const auto *location = live_location(id, 'b'); const LMBrush &source = current_brush(location->entity, location->index);
		LocalBrushDraft draft; draft.id = id; draft.entity = location->entity; draft.index = location->index; draft.brush = source;
		draft.faces.assign(source.faces, source.faces + source.face_count); draft.materials.reserve(source.face_count);
		for (int f = 0; f < source.face_count; ++f) draft.materials.push_back(current_face_texture(location->entity, location->index, f));
		draft.brush.faces = draft.faces.data(); before.push_back(brush_source_text(draft.faces, draft.materials));
		auto existing = editor ? editor->brushes.find(id) : decltype(editor->brushes.find(id)){};
		const LMBrush &base = map->entities[location->entity].brushes[location->index];
		std::vector<LMFace> base_faces(base.faces, base.faces + base.face_count); std::vector<std::string> base_materials;
		for (int f = 0; f < base.face_count; ++f) { base_materials.emplace_back(map->textures[base.faces[f].texture_idx].name); base_faces[f].texture_idx = f; }
		auto geometry = base_geometry->brushes.find(id);
		base_records.push_back(std::make_shared<const EditorState::BrushRecord>(base, std::move(base_faces), std::move(base_materials),
				geometry == base_geometry->brushes.end() ? nullptr : geometry->second, 0));
		before_records.push_back(editor && existing != editor->brushes.end() ? existing->second : base_records.back());
		drafts.push_back(std::move(draft)); ++last_operation.brush_source_copies;
	}
	Dictionary applied = mutation(drafts); if (!bool(applied["ok"])) return applied;
	auto next = std::make_shared<EditorState>(); if (editor) next->brushes = editor->brushes;
	int64_t size_delta = editor ? editor->canonical_size_delta : 0; std::vector<int64_t> changed;
	for (size_t i = 0; i < drafts.size(); ++i) {
		auto &draft = drafts[i]; if (draft.faces.size() != draft.materials.size()) return failure("INVALID_GEOMETRY", "Brush source metadata is inconsistent", operation, path);
		if ((domains & (LMEditorBrushDirtyDomain::POSITIONS | LMEditorBrushDirtyDomain::TOPOLOGY)) != LMEditorBrushDirtyDomain::NONE) for (auto &face : draft.faces) {
			const vec3 normal = vec3_cross(vec3_sub(face.plane_points.v2, face.plane_points.v1), vec3_sub(face.plane_points.v1, face.plane_points.v0));
			face.plane_normal = vec3_normalize(normal); face.plane_dist = vec3_dot(face.plane_normal, face.plane_points.v0);
		}
		const std::string after = brush_source_text(draft.faces, draft.materials); if (after == before[i]) continue;
		size_delta += int64_t(after.size()) - int64_t(before[i].size()); changed.push_back(draft.id);
		std::vector<LMEditorTextureSize> sizes(draft.faces.size());
		for (size_t f = 0; f < draft.faces.size(); ++f) {
			draft.faces[f].texture_idx = f; Vector2i size = texture_sizes.get(String::utf8(draft.materials[f].c_str()), Vector2i());
			if (size.x <= 0 || size.y <= 0) size = Vector2i(1, 1);
			sizes[f] = {size.x, size.y};
		}
		draft.brush.face_count = draft.faces.size(); draft.brush.faces = draft.faces.data();
		const LMEditorBrushBuildContext context{sizes.data(), sizes.size()}; auto built = lm_build_editor_brush_geometry(draft.brush, context); ++last_operation.brush_builds; ++last_operation.compact_full_builds;
		if (!built || !lm_validate_editor_brush_geometry(draft.brush, built.geometry)) return failure("INVALID_GEOMETRY", "Brush must be a finite, closed solid with nonempty faces", operation, path);
		draft.brush.center = {}; size_t corners = 0;
		for (const auto &face : built.geometry.faces) for (uint32_t v = 0; v < face.corner_count; ++v) { draft.brush.center = vec3_add(draft.brush.center, built.geometry.positions[built.geometry.corners[face.corner_begin + v].position]); ++corners; }
		if (corners) draft.brush.center = vec3_div_double(draft.brush.center, corners);
		const LMBrush &base = map->entities[draft.entity].brushes[draft.index]; std::vector<LMFace> base_faces(base.faces, base.faces + base.face_count); std::vector<std::string> base_materials;
		for (int f = 0; f < base.face_count; ++f) base_materials.emplace_back(map->textures[base.faces[f].texture_idx].name);
		if ((domains & LMEditorBrushDirtyDomain::TOPOLOGY) != LMEditorBrushDirtyDomain::NONE) draft.brush.topology_revision = topology + 1;
		if (after == brush_source_text(base_faces, base_materials) &&
				(domains & LMEditorBrushDirtyDomain::TOPOLOGY) == LMEditorBrushDirtyDomain::NONE) next->brushes.erase(draft.id);
		else {
			const uint64_t generation = editor && editor->brushes.count(draft.id) ? editor->brushes.at(draft.id)->source_generation + 1 : 1;
			next->brushes[draft.id] = std::make_shared<const EditorState::BrushRecord>(draft.brush, std::move(draft.faces), std::move(draft.materials), std::move(built.geometry), generation);
		}
	}
	if (changed.empty()) { last_operation.success = true; return success(); }
	const int64_t projected_size = int64_t(canonical->size()) + size_delta;
	if (projected_size < 0 || uint64_t(projected_size) > LMMapParser::MAX_TEXT_BYTES) return failure("LIMIT_EXCEEDED", "Canonical map exceeds 16 MiB", operation, path);
	next->canonical_size_delta = size_delta; next->change = {state_generation, changed, domains, operation};
	const auto expanded = lm_editor_brush_dirty_dependencies(domains); const int64_t count = changed.size();
	if ((expanded & LMEditorBrushDirtyDomain::TOPOLOGY) != LMEditorBrushDirtyDomain::NONE) last_operation.topology_dirty = count;
	if ((expanded & LMEditorBrushDirtyDomain::POSITIONS) != LMEditorBrushDirtyDomain::NONE) last_operation.positions_dirty = count;
	if ((expanded & LMEditorBrushDirtyDomain::UVS) != LMEditorBrushDirtyDomain::NONE) last_operation.uv_dirty = count;
	if ((expanded & LMEditorBrushDirtyDomain::MATERIAL) != LMEditorBrushDirtyDomain::NONE) last_operation.material_dirty = count;
	if ((expanded & LMEditorBrushDirtyDomain::PREVIEW) != LMEditorBrushDirtyDomain::NONE) last_operation.preview_dirty = count;
	if ((expanded & LMEditorBrushDirtyDomain::SPATIAL) != LMEditorBrushDirtyDomain::NONE) last_operation.spatial_dirty = count;
	const bool was_dirty = is_dirty(); const int64_t old_generation = state_generation; const int64_t new_generation = ++next_state_generation;
	Ref<TBMapDocumentChange> document_change; document_change.instantiate(); document_change->epoch = epoch;
	document_change->before_generation = old_generation; document_change->after_generation = new_generation;
	document_change->texture_context_generation = texture_context_generation;
	document_change->before_canonical_size = int64_t(canonical->size()) + (editor ? editor->canonical_size_delta : 0);
	document_change->after_canonical_size = int64_t(canonical->size()) + size_delta;
	document_change->operation = operation; document_change->domains = domains;
	for (int64_t id : changed) {
		auto position = std::find(ids.begin(), ids.end(), id) - ids.begin();
		auto after_record = next->brushes.find(id);
		document_change->brushes.push_back({id, before_records[position], after_record == next->brushes.end() ? base_records[position] : after_record->second});
	}
	const std::shared_ptr<const EditorState> installed = next->brushes.empty() ? std::shared_ptr<const EditorState>() : next;
	retain_spatial_index(); retain_preview_cache(); advance_spatial_index(installed, changed, expanded, new_generation);
	editor = installed; materialized_canonical.reset(); translation_counter_scope = false;
	invalidate_preview_cache();
	if ((expanded & LMEditorBrushDirtyDomain::TOPOLOGY) != LMEditorBrushDirtyDomain::NONE) ++topology;
	transition = {old_generation, changed, true}; state_generation = new_generation;
	last_change = {}; last_change.before_generation = old_generation; last_change.generation = new_generation;
	last_change.operation = operation; last_change.domains = domains; last_change.brush_ids = changed; last_change.reset = false;
	last_change.entities_changed = false; last_change.ownership_changed = false; last_change.points_changed = false;
	last_document_change = document_change;
	last_operation.success = true; last_operation.committed = true; ++revision;
	emit_signal("map_changed", revision); if (was_dirty != is_dirty()) emit_signal("dirty_changed", is_dirty()); return success(true);
}

Dictionary TBMapDocument::preview_translate_brushes(const PackedInt64Array &ids, Vector3 delta) const {
	auto r = check_brushes(ids, "preview_translate_brushes"); if (!bool(r["ok"])) return r;
	if (!valid(delta)) return failure("INVALID_ARGUMENT", "Invalid translation", "preview_translate_brushes");
	LMMapEdit edit; stage_preview_brushes(ids, edit); LMMapEdit before = edit; Dictionary sources;
	for (int64_t id : unique(ids)) {
		sources[id] = id;
		if (delta == Vector3()) continue;
		for (auto &face : edit.brush(id)->faces) {
			move_face(face, delta);
			const auto &points = face.plane.plane_points;
			if (!valid(vector(points.v0)) || !valid(vector(points.v1)) || !valid(vector(points.v2))) return failure("INVALID_ARGUMENT", "Translated brush exceeds finite map bounds", "preview_translate_brushes");
		}
	}
	return preview_fragments(before, edit, "preview_translate_brushes", sources);
}

Dictionary TBMapDocument::rotate_brushes(const PackedInt64Array &ids, Vector3 pivot, int axis, double radians) {
	last_document_change.unref();
	auto r = check_brushes(ids, "rotate_brushes"); if (!bool(r["ok"])) return r;
	if (!valid(pivot) || axis < 0 || axis > 2 || !std::isfinite(radians) || std::abs(radians) > 1e9)
		return failure("INVALID_ARGUMENT", "Expected a finite pivot, axis 0..2 and finite angle", "rotate_brushes");
	radians = std::remainder(radians, 6.28318530717958647692);
	if (ids.is_empty() || std::abs(radians) < 1e-12) return success();
	const auto selected = unique(ids);
	return local_brush_transaction(selected, "rotate_brushes", LMEditorBrushDirtyDomain::POSITIONS, [=](auto &drafts) {
		const int u = axis == 0 ? 1 : 0, v = axis == 2 ? 1 : 2; const double cosine = std::cos(radians), sine = std::sin(radians);
		for (auto &draft : drafts) for (auto &face : draft.faces) for (vec3 *point : {&face.plane_points.v0, &face.plane_points.v1, &face.plane_points.v2}) {
			double values[] = {point->x, point->y, point->z}; const double center[] = {double(pivot.x), double(pivot.y), double(pivot.z)};
			const double x = values[u] - center[u], y = values[v] - center[v]; values[u] = center[u] + x * cosine - y * sine; values[v] = center[v] + x * sine + y * cosine; *point = {values[0], values[1], values[2]};
		}
		return success();
	});
}

Dictionary TBMapDocument::preview_rotate_brushes(const PackedInt64Array &ids, Vector3 pivot, int axis, double radians) const {
	auto r = check_brushes(ids, "preview_rotate_brushes"); if (!bool(r["ok"])) return r;
	if (!valid(pivot) || axis < 0 || axis > 2 || !std::isfinite(radians) || std::abs(radians) > 1e9)
		return failure("INVALID_ARGUMENT", "Expected a finite pivot, axis 0..2 and finite angle", "preview_rotate_brushes");
	radians = std::remainder(radians, 6.28318530717958647692);
	LMMapEdit edit; stage_preview_brushes(ids, edit); LMMapEdit before = edit; Dictionary sources;
	for (int64_t id : unique(ids)) { sources[id] = id; if (std::abs(radians) >= 1e-12) lm_edit_rotate_brush(*edit_brush(edit, id), native(pivot), axis, radians); }
	return preview_fragments(before, edit, "preview_rotate_brushes", sources);
}
Dictionary TBMapDocument::translate_face(int64_t id, int face, Vector3 delta, int64_t topology_revision) {
	last_document_change.unref();
	auto r = check_face(id, face, topology_revision, "translate_face"); if (!bool(r["ok"])) return r;
	if (!valid(delta)) return failure("INVALID_ARGUMENT", "Invalid translation", "translate_face");
	return local_brush_transaction({id}, "translate_face", LMEditorBrushDirtyDomain::TOPOLOGY | LMEditorBrushDirtyDomain::POSITIONS, [=](auto &drafts) {
		auto &f = drafts[0].faces[face]; Vector3 n = vector(f.plane_normal); const vec3 amount = native(n * n.dot(delta));
		f.plane_points.v0 = vec3_add(f.plane_points.v0, amount); f.plane_points.v1 = vec3_add(f.plane_points.v1, amount); f.plane_points.v2 = vec3_add(f.plane_points.v2, amount); return success();
	});
}
Dictionary TBMapDocument::set_brush_texture(const PackedInt64Array &ids, const String &name) {
	last_document_change.unref();
	auto r = check_brushes(ids, "set_brush_texture"); if (!bool(r["ok"])) return r;
	if (!token(name)) return failure("INVALID_ARGUMENT", "Invalid texture name", "set_brush_texture");
	const auto selected = unique(ids); const std::string material = bytes(name);
	return local_brush_transaction(selected, "set_brush_texture", LMEditorBrushDirtyDomain::MATERIAL, [=](auto &drafts) { for (auto &draft : drafts) for (auto &face : draft.materials) face = material; return success(); });
}
Dictionary TBMapDocument::set_face_texture(int64_t id, int face, const String &name, int64_t topology_revision) {
	last_document_change.unref();
	auto r = check_face(id, face, topology_revision, "set_face_texture"); if (!bool(r["ok"])) return r;
	if (!token(name)) return failure("INVALID_ARGUMENT", "Invalid texture name", "set_face_texture");
	const std::string material = bytes(name);
	return local_brush_transaction({id}, "set_face_texture", LMEditorBrushDirtyDomain::MATERIAL, [=](auto &drafts) { drafts[0].materials[face] = material; return success(); });
}
Dictionary TBMapDocument::get_face_uv(int64_t id, int face, int64_t topology_revision) const {
	auto r = check_face(id, face, topology_revision, "get_face_uv"); if (!bool(r["ok"])) return r;
	const auto *location = live_location(id, 'b');
	const auto &f = current_brush(location->entity, location->index).faces[face]; Dictionary uv;
	uv["projection"] = f.is_valve_uv ? "valve" : "classic";
	uv["shift"] = f.is_valve_uv ? Vector2(f.uv_valve.u.offset, f.uv_valve.v.offset) : Vector2(f.uv_standard.u, f.uv_standard.v);
	uv["rotation"] = f.uv_extra.rot; uv["scale"] = Vector2(f.uv_extra.scale_x, f.uv_extra.scale_y);
	uv["u_axis"] = vector(f.uv_valve.u.axis); uv["v_axis"] = vector(f.uv_valve.v.axis); return success(false, uv);
}
Dictionary TBMapDocument::set_face_uv(int64_t id, int face, Vector2 shift, double rotation, Vector2 scale, int64_t topology_revision) {
	last_document_change.unref();
	auto r = check_face(id, face, topology_revision, "set_face_uv"); if (!bool(r["ok"])) return r;
	if (!shift.is_finite() || !scale.is_finite() || !std::isfinite(rotation) || std::abs(rotation) > 1e9 || std::abs(shift.x) > 1e9 || std::abs(shift.y) > 1e9 || std::abs(scale.x) < 1e-9 || std::abs(scale.y) < 1e-9 || std::abs(scale.x) > 1e9 || std::abs(scale.y) > 1e9) return failure("INVALID_ARGUMENT", "Invalid UV transform", "set_face_uv");
	const auto *location = live_location(id, 'b'); const auto &f = current_brush(location->entity, location->index).faces[face];
	if (f.is_valve_uv) return failure("UNSUPPORTED_PROJECTION", "Valve projection is read-only", "set_face_uv");
	return local_brush_transaction({id}, "set_face_uv", LMEditorBrushDirtyDomain::UVS, [=](auto &drafts) { auto &face_source = drafts[0].faces[face]; face_source.uv_standard = {shift.x, shift.y}; face_source.uv_extra = {rotation, scale.x, scale.y}; return success(); });
}

Dictionary TBMapDocument::apply_face_edits(const Array &edits) {
	last_document_change.unref();
	struct FaceEdit {
		int64_t id;
		int face;
		bool has_texture = false, has_uv = false;
		std::string texture;
		Vector2 shift, scale;
		double rotation = 0;
	};
	std::vector<FaceEdit> validated;
	validated.reserve(edits.size());
	std::set<std::pair<int64_t, int>> targets;
	bool changed = false;
	for (int i = 0; i < edits.size(); ++i) {
		if (edits[i].get_type() != Variant::DICTIONARY) return failure("INVALID_ARGUMENT", "Expected face edit dictionary", "apply_face_edits");
		Dictionary item = edits[i];
		if (!item.has("brush_id") || !item.has("face") || !item.has("topology_revision") ||
				item["brush_id"].get_type() != Variant::INT || item["face"].get_type() != Variant::INT || item["topology_revision"].get_type() != Variant::INT)
			return failure("INVALID_ARGUMENT", "Invalid face edit target schema", "apply_face_edits");
		const int64_t face_value = item["face"];
		if (face_value < std::numeric_limits<int>::min() || face_value > std::numeric_limits<int>::max()) return failure("INVALID_ARGUMENT", "Invalid face index", "apply_face_edits");
		FaceEdit edit{int64_t(item["brush_id"]), int(face_value)};
		auto result = check_face(edit.id, edit.face, item["topology_revision"], "apply_face_edits"); if (!bool(result["ok"])) return result;
		if (!targets.insert({edit.id, edit.face}).second) return failure("INVALID_ARGUMENT", "Duplicate face edit target", "apply_face_edits");
		if (item.has("texture")) {
			if (item["texture"].get_type() != Variant::STRING || !token(String(item["texture"]))) return failure("INVALID_ARGUMENT", "Invalid texture name", "apply_face_edits");
			edit.has_texture = true; edit.texture = bytes(item["texture"]);
		}
		if (item.has("uv")) {
			if (item["uv"].get_type() != Variant::DICTIONARY) return failure("INVALID_ARGUMENT", "Invalid UV edit schema", "apply_face_edits");
			Dictionary uv = item["uv"];
			if (!uv.has("shift") || !uv.has("rotation") || !uv.has("scale") || uv["shift"].get_type() != Variant::VECTOR2 ||
					(uv["rotation"].get_type() != Variant::FLOAT && uv["rotation"].get_type() != Variant::INT) || uv["scale"].get_type() != Variant::VECTOR2)
				return failure("INVALID_ARGUMENT", "Invalid UV edit schema", "apply_face_edits");
			edit.shift = uv["shift"]; edit.rotation = uv["rotation"]; edit.scale = uv["scale"];
			if (!edit.shift.is_finite() || !edit.scale.is_finite() || !std::isfinite(edit.rotation) || std::abs(edit.rotation) > 1e9 ||
					std::abs(edit.shift.x) > 1e9 || std::abs(edit.shift.y) > 1e9 || std::abs(edit.scale.x) < 1e-9 || std::abs(edit.scale.y) < 1e-9 ||
					std::abs(edit.scale.x) > 1e9 || std::abs(edit.scale.y) > 1e9) return failure("INVALID_ARGUMENT", "Invalid UV transform", "apply_face_edits");
			const auto *location = live_location(edit.id, 'b');
			if (current_brush(location->entity, location->index).faces[edit.face].is_valve_uv) return failure("UNSUPPORTED_PROJECTION", "Valve projection is read-only", "apply_face_edits");
			edit.has_uv = true;
		}
		if (!edit.has_texture && !edit.has_uv) return failure("INVALID_ARGUMENT", "Face edit must include texture or UV", "apply_face_edits");
		const auto *location = live_location(edit.id, 'b');
		const auto &face = current_brush(location->entity, location->index).faces[edit.face];
		if (edit.has_texture && edit.texture != current_face_texture(location->entity, location->index, edit.face)) changed = true;
		if (edit.has_uv && (Vector2(face.uv_standard.u, face.uv_standard.v) != edit.shift || face.uv_extra.rot != edit.rotation || Vector2(face.uv_extra.scale_x, face.uv_extra.scale_y) != edit.scale)) changed = true;
		validated.push_back(std::move(edit));
	}
	if (!changed) return success();
	std::vector<int64_t> ids; for (const auto &edit : validated) if (std::find(ids.begin(), ids.end(), edit.id) == ids.end()) ids.push_back(edit.id);
	LMEditorBrushDirtyDomain domains = LMEditorBrushDirtyDomain::NONE;
	for (const auto &edit : validated) { if (edit.has_texture) domains = domains | LMEditorBrushDirtyDomain::MATERIAL; if (edit.has_uv) domains = domains | LMEditorBrushDirtyDomain::UVS; }
	return local_brush_transaction(ids, "apply_face_edits", domains, [&](auto &drafts) {
		for (const auto &edit : validated) { auto draft = std::find_if(drafts.begin(), drafts.end(), [&](const auto &item) { return item.id == edit.id; });
			if (edit.has_texture) draft->materials[edit.face] = edit.texture;
			if (edit.has_uv) { draft->faces[edit.face].uv_standard = {edit.shift.x, edit.shift.y}; draft->faces[edit.face].uv_extra = {edit.rotation, edit.scale.x, edit.scale.y}; }
		}
		return success();
	});
}
void TBMapDocument::resolve_texture_sizes(LMMapData &data, const Dictionary &sizes) const {
	for (int i = 0; i < data.texture_count; ++i) {
		Vector2i size = sizes.get(String::utf8(data.textures[i].name), Vector2i(1, 1));
		data.textures[i].width = size.x; data.textures[i].height = size.y;
	}
}
Dictionary TBMapDocument::set_texture_sizes(const Dictionary &sizes) {
	Dictionary normalized; Array keys = sizes.keys();
	for (int i = 0; i < keys.size(); ++i) {
		if ((keys[i].get_type() != Variant::STRING && keys[i].get_type() != Variant::STRING_NAME) || sizes[keys[i]].get_type() != Variant::VECTOR2I) return failure("INVALID_ARGUMENT", "Expected texture names mapped to Vector2i", "set_texture_sizes");
		Vector2i size = sizes[keys[i]]; String name = keys[i];
		if (!token(name) || size.x <= 0 || size.y <= 0) return failure("INVALID_ARGUMENT", "Texture dimensions must be positive", "set_texture_sizes");
		normalized[name] = size;
	}
	if (normalized == texture_sizes) return success();
	last_operation = {}; last_operation.operation = "set_texture_sizes";
	translation_counter_scope = true;
	std::shared_ptr<const TBMapDocumentState::BaseEditorGeometry> rebuilt_base;
	std::shared_ptr<const EditorState> rebuilt_editor;
	Dictionary updated = update_texture_context_geometry(*map, base_geometry, editor, texture_sizes, normalized, rebuilt_base, rebuilt_editor, "set_texture_sizes");
	if (!bool(updated["ok"])) { translation_counter_scope = false; return updated; }
	base_geometry = std::move(rebuilt_base);
	editor = std::move(rebuilt_editor);
	texture_sizes = normalized;
	++texture_context_generation;
	rebind_spatial_context();
	clear_preview_caches();
	last_operation.success = true; last_operation.committed = true; translation_counter_scope = false;
	last_preview_change_reason = "texture_uv";
	emit_signal("preview_changed"); return success(true);
}
Dictionary TBMapDocument::export_selection(const PackedInt64Array &ids) const {
	auto r = check_brushes(ids, "export_selection"); if (!bool(r["ok"])) return r;
	LMMapEdit edit(*materialize_current_source()); auto list = unique(ids); std::set<int64_t> selected(list.begin(), list.end());
	for (auto &e : edit.entities) e.primitives.erase(std::remove_if(e.primitives.begin(), e.primitives.end(), [&](const LMEditPrimitive &p) { return !selected.count(p.id); }), e.primitives.end());
	edit.entities.erase(std::remove_if(edit.entities.begin(), edit.entities.end(), [](const LMEditEntity &e) { return e.primitives.empty(); }), edit.entities.end());
	return success(false, text(edit.text()));
}
Dictionary TBMapDocument::import_selection(const String &source) {
	if (source.strip_edges().is_empty()) return success(false, PackedInt64Array());
	std::shared_ptr<LMMapData> candidate; auto r = prepare(bytes(source), candidate, "import_selection", path); if (!bool(r["ok"])) return r;
	LMMapEdit incoming(*candidate), edit(*materialize_current_source()); PackedInt64Array out; int64_t id = next_id;
	for (auto &e : incoming.entities) {
		for (auto &p : e.primitives) { if (p.patch) return failure("UNSUPPORTED_SYNTAX", "Patch clipboard import is unsupported", "import_selection"); p.id = id++; out.push_back(p.id); }
		if (e.primitives.empty()) continue;
		if (e.property("classname") == "worldspawn") { auto &world = edit.world(); world.primitives.insert(world.primitives.end(), e.primitives.begin(), e.primitives.end()); }
		else { e.id = id++; edit.entities.push_back(e); }
	}
	return finish_edit(edit, "import_selection", out);
}
Dictionary TBMapDocument::create_point_entity(const String &classname, Vector3 origin) {
	if (!token(classname) || classname == "worldspawn" || !valid(origin)) return failure("INVALID_ARGUMENT", "Expected non-world classname and finite origin", "create_point_entity");
	LMMapEdit edit(*materialize_current_source()); LMEditEntity e; e.id = next_id; e.epairs = {{"classname", bytes(classname)}, {"origin", origin_text(origin)}}; edit.entities.push_back(e);
	return finish_edit(edit, "create_point_entity", e.id);
}
Dictionary TBMapDocument::set_entity_property(int64_t id, const String &key, const String &value) {
	LMMapEdit edit(*materialize_current_source()); auto e = edit_entity(edit, id); if (!e) return failure("INVALID_ID", "Unknown entity handle", "set_entity_property");
	if (!token(key) || !token(value, true)) return failure("INVALID_ARGUMENT", "Invalid epair", "set_entity_property");
	if (key == "classname" && (value.is_empty() || (e->property("classname") == "worldspawn") != (value == "worldspawn"))) return failure("INVALID_ARGUMENT", "Cannot change worldspawn identity or empty classname", "set_entity_property");
	Vector3 origin; if (key == "origin" && (value.is_empty() || !read_origin(bytes(value), origin))) return failure("INVALID_ARGUMENT", "Origin must contain three finite coordinates", "set_entity_property");
	e->set_property(bytes(key), bytes(value)); return finish_edit(edit, "set_entity_property");
}
Dictionary TBMapDocument::remove_entity_property(int64_t id, const String &key) {
	LMMapEdit edit(*materialize_current_source()); auto e = edit_entity(edit, id); if (!e) return failure("INVALID_ID", "Unknown entity handle", "remove_entity_property");
	if (!token(key) || key == "classname") return failure("INVALID_ARGUMENT", "Cannot remove classname or use an invalid key", "remove_entity_property");
	e->epairs.erase(std::remove_if(e->epairs.begin(), e->epairs.end(), [&](const auto &p) { return p.first == bytes(key); }), e->epairs.end());
	return finish_edit(edit, "remove_entity_property");
}
Dictionary TBMapDocument::translate_point_entities(const PackedInt64Array &ids, Vector3 delta) {
	if (!valid(delta)) return failure("INVALID_ARGUMENT", "Invalid translation", "translate_point_entities");
	if (ids.is_empty() || delta == Vector3()) return success();
	LMMapEdit edit(*materialize_current_source());
	for (int64_t id : unique(ids)) {
		auto e = edit_entity(edit, id); if (!e) return failure("INVALID_ID", "Unknown entity handle", "translate_point_entities");
		Vector3 origin;
		if (!e->primitives.empty() || e->property("classname") == "worldspawn" || !read_origin(e->property("origin"), origin) || !valid(origin + delta)) return failure("INVALID_ARGUMENT", "Expected point entity with a valid origin", "translate_point_entities");
		if (delta != Vector3()) e->set_property("origin", origin_text(origin + delta));
	}
	return finish_edit(edit, "translate_point_entities");
}
Dictionary TBMapDocument::group_brushes(const PackedInt64Array &ids, const String &classname) {
	auto r = check_brushes(ids, "group_brushes"); if (!bool(r["ok"])) return r;
	if (!token(classname) || classname == "worldspawn") return failure("INVALID_ARGUMENT", "Expected non-world classname", "group_brushes");
	if (ids.is_empty()) return success();
	LMMapEdit edit(*materialize_current_source()); LMEditEntity group; group.id = next_id; group.epairs.emplace_back("classname", bytes(classname));
	for (int64_t id : unique(ids)) group.primitives.push_back(*edit_brush(edit, id));
	for (auto &e : edit.entities) e.primitives.erase(std::remove_if(e.primitives.begin(), e.primitives.end(), [&](const LMEditPrimitive &p) { return ids.has(p.id); }), e.primitives.end());
	edit.entities.push_back(group); return finish_edit(edit, "group_brushes", group.id);
}
Dictionary TBMapDocument::return_brushes_to_worldspawn(const PackedInt64Array &ids) {
	auto r = check_brushes(ids, "return_brushes_to_worldspawn"); if (!bool(r["ok"])) return r;
	if (ids.is_empty()) return success();
	LMMapEdit edit(*materialize_current_source()); edit.world(); std::vector<LMEditPrimitive> moved;
	for (int64_t id : unique(ids)) for (auto &e : edit.entities) if (e.property("classname") != "worldspawn") {
		auto it = std::find_if(e.primitives.begin(), e.primitives.end(), [&](const LMEditPrimitive &p) { return p.id == id; });
		if (it != e.primitives.end()) { moved.push_back(*it); e.primitives.erase(it); break; }
	}
	auto &world = edit.world(); world.primitives.insert(world.primitives.end(), moved.begin(), moved.end());
	return finish_edit(edit, "return_brushes_to_worldspawn");
}
Dictionary TBMapDocument::delete_entities(const PackedInt64Array &ids, bool delete_owned_brushes) {
	LMMapEdit edit(*materialize_current_source()); std::vector<LMEditPrimitive> moved;
	for (int64_t id : unique(ids)) {
		auto e = edit_entity(edit, id); if (!e) return failure("INVALID_ID", "Unknown entity handle", "delete_entities");
		if (e->property("classname") == "worldspawn") return failure("INVALID_ARGUMENT", "Cannot delete worldspawn", "delete_entities");
		for (const auto &p : e->primitives) if (p.patch) return failure("UNSUPPORTED_SYNTAX", "Cannot delete patch-owning entities", "delete_entities");
		if (!delete_owned_brushes) moved.insert(moved.end(), e->primitives.begin(), e->primitives.end());
	}
	edit.entities.erase(std::remove_if(edit.entities.begin(), edit.entities.end(), [&](const LMEditEntity &e) { return ids.has(e.id); }), edit.entities.end());
	if (!moved.empty()) { auto &world = edit.world(); world.primitives.insert(world.primitives.end(), moved.begin(), moved.end()); }
	return finish_edit(edit, "delete_entities");
}
Dictionary TBMapDocument::make_prism(int64_t id, int sides, int axis) {
	PackedInt64Array ids; ids.push_back(id); auto r = check_brushes(ids, "make_prism"); if (!bool(r["ok"])) return r;
	if (sides < 3 || sides > 62 || axis < 0 || axis > 2) return failure("INVALID_ARGUMENT", "Expected 3..62 sides and axis 0..2", "make_prism");
	const auto *location = live_location(id, 'b');
	const auto bounds = compact_topology(*current_brush_geometry(location->entity, location->index).compact);
	Vector3 lo = vector(bounds.mins), hi = vector(bounds.maxs);
	LMMapEdit edit(*materialize_current_source()); auto &brush = *edit_brush(edit, id); auto prototype = brush.faces.front();
	auto box = lm_edit_cuboid(native(lo), native(hi), prototype.texture);
	brush.faces.clear();
	for (int side = 0; side < 2; ++side) { auto f = prototype; f.plane.plane_points = box.faces[axis * 2 + side].plane.plane_points; brush.faces.push_back(f); }
	int u = (axis + 1) % 3, v = (axis + 2) % 3; Vector3 center = (lo + hi) / 2, radius = (hi - lo) / 2;
	for (int i = 0; i < sides; ++i) {
		double a = 6.283185307179586 * i / sides, b = 6.283185307179586 * (i + 1) / sides;
		Vector3 p = center, q = center; p[u] += radius[u] * std::cos(a); p[v] += radius[v] * std::sin(a); q[u] += radius[u] * std::cos(b); q[v] += radius[v] * std::sin(b);
		Vector3 up; up[axis] = hi[axis] - lo[axis]; auto f = prototype;
		f.plane.plane_points = {native(p), native(p + up), native(q)}; brush.faces.push_back(f);
	}
	return finish_edit(edit, "make_prism");
}

Dictionary TBMapDocument::translate_vertices(int64_t id, const PackedInt32Array &vertex_indices, Vector3 delta, int64_t topology_revision) {
	auto r = check_face(id, 0, topology_revision, "translate_vertices"); if (!bool(r["ok"])) return r;
	Array components;
	for (int index : vertex_indices) {
		Dictionary c; c["brush_id"] = id; c["kind"] = "vertex"; c["index"] = index; c["topology_revision"] = topology_revision; components.push_back(c);
	}
	return move_components(components, delta, "translate_vertices");
}

Dictionary TBMapDocument::translate_components(const Array &components, Vector3 delta) {
	return move_components(components, delta, "translate_components");
}

Dictionary TBMapDocument::move_components(const Array &components, Vector3 delta, const StringName &operation) {
	last_document_change.unref();
	if (!valid(delta)) return failure("INVALID_ARGUMENT", "Invalid translation", operation);
	std::map<int64_t, LMBrushTopology> brushes; std::map<int64_t, std::set<int>> selected_vertices, selected_faces;
	for (int i = 0; i < components.size(); ++i) {
		if (components[i].get_type() != Variant::DICTIONARY) return failure("INVALID_ARGUMENT", "Expected component dictionary", operation);
		Dictionary c = components[i];
		if (!c.has("brush_id") || !c.has("kind") || !c.has("index") || !c.has("topology_revision") || c["brush_id"].get_type() != Variant::INT || c["index"].get_type() != Variant::INT || c["topology_revision"].get_type() != Variant::INT || c["kind"].get_type() != Variant::STRING) return failure("INVALID_ARGUMENT", "Invalid component schema", operation);
		const int64_t id = c["brush_id"], index = c["index"]; const String kind = c["kind"]; auto checked = check_face(id, 0, c["topology_revision"], operation); if (!bool(checked["ok"])) return checked;
		if (!brushes.count(id)) { const auto *location = live_location(id, 'b'); brushes[id] = compact_topology(*current_brush_geometry(location->entity, location->index).compact); }
		const auto &topology_source = brushes.at(id); const int count = kind == "vertex" ? topology_source.vertices.size() : kind == "edge" ? topology_source.edges.size() : kind == "face" ? topology_source.faces.size() : 0;
		if (index < 0 || index >= count) return failure("INVALID_ARGUMENT", "Invalid component kind or index", operation);
		if (kind == "face") selected_faces[id].insert(index); else if (kind == "vertex") selected_vertices[id].insert(index); else { selected_vertices[id].insert(topology_source.edges[index].first); selected_vertices[id].insert(topology_source.edges[index].second); }
	}
	for (const auto &group : selected_faces) if (selected_vertices.count(group.first)) return failure("INVALID_ARGUMENT", "Cannot mix face and vertex/edge deformation on a brush", operation);
	if (components.is_empty() || delta == Vector3()) return success();
	std::vector<int64_t> ids; for (const auto &item : brushes) ids.push_back(item.first);
	const LMEditorBrushDirtyDomain move_domains = LMEditorBrushDirtyDomain::TOPOLOGY | LMEditorBrushDirtyDomain::POSITIONS;
	return local_brush_transaction(ids, operation, move_domains, [&](auto &drafts) {
		for (auto &draft : drafts) {
			for (int index : selected_faces[draft.id]) { auto &face = draft.faces[index]; Vector3 n = vector(face.plane_normal); const vec3 amount = native(n * n.dot(delta)); face.plane_points.v0 = vec3_add(face.plane_points.v0, amount); face.plane_points.v1 = vec3_add(face.plane_points.v1, amount); face.plane_points.v2 = vec3_add(face.plane_points.v2, amount); }
			auto selected = selected_vertices.find(draft.id); if (selected == selected_vertices.end()) continue;
			auto vertices = brushes.at(draft.id).vertices; for (int index : selected->second) { vertices[index] = vec3_add(vertices[index], native(delta)); if (!valid(vector(vertices[index]))) return failure("INVALID_ARGUMENT", "Vertex exceeds coordinate bounds", operation); }
			std::vector<int> origins; const auto old_materials = draft.materials;
			if (!rebuild_vertex_hull(draft.faces, brushes.at(draft.id), vertices, selected->second, &origins)) return failure("INVALID_GEOMETRY", "Vertex edit cannot form a bounded convex brush", operation);
			draft.materials.clear(); for (int source : origins) draft.materials.push_back(old_materials[source]);
		}
		return success();
	});
}

Dictionary TBMapDocument::stage_components(const Array &components, Vector3 delta, const StringName &operation, LMMapEdit &edit, Dictionary &sources) const {
	if (!valid(delta)) return failure("INVALID_ARGUMENT", "Invalid translation", operation);
	std::map<int64_t, LMBrushTopology> brushes;
	std::map<int64_t, std::set<int>> selected_vertices, selected_faces;
	for (int i = 0; i < components.size(); ++i) {
		Variant item = components[i];
		if (item.get_type() != Variant::DICTIONARY) return failure("INVALID_ARGUMENT", "Expected component dictionary", operation);
		Dictionary c = item;
		if (!c.has("brush_id") || !c.has("kind") || !c.has("index") || !c.has("topology_revision") ||
				c["brush_id"].get_type() != Variant::INT || c["index"].get_type() != Variant::INT ||
				c["topology_revision"].get_type() != Variant::INT || c["kind"].get_type() != Variant::STRING)
			return failure("INVALID_ARGUMENT", "Invalid component schema", operation);
		int64_t id = c["brush_id"], index = c["index"]; String kind = c["kind"];
		auto r = check_face(id, 0, c["topology_revision"], operation); if (!bool(r["ok"])) return r;
		if (!brushes.count(id)) {
			const auto *location = live_location(id, 'b');
			brushes.emplace(id, compact_topology(*current_brush_geometry(location->entity, location->index).compact));
			sources[id] = id;
		}
		const auto &brush = brushes.at(id);
		int count = kind == "vertex" ? brush.vertices.size() : kind == "edge" ? brush.edges.size() : kind == "face" ? brush.faces.size() : 0;
		if (index < 0 || index >= count) return failure("INVALID_ARGUMENT", "Invalid component kind or index", operation);
		if (kind == "face") selected_faces[id].insert(index);
		else if (kind == "vertex") selected_vertices[id].insert(index);
		else { selected_vertices[id].insert(brush.edges[index].first); selected_vertices[id].insert(brush.edges[index].second); }
	}
	// Face mode moves supporting planes; vertex/edge mode moves incident vertices.
	// Mixing these semantics in one brush is ambiguous and must never drop handles.
	for (const auto &group : selected_faces) if (selected_vertices.count(group.first)) return failure("INVALID_ARGUMENT", "Cannot mix face and vertex/edge deformation on a brush", operation);
	if (components.is_empty() || delta == Vector3()) return success();
	for (const auto &group : selected_faces) for (int index : group.second) {
		auto &f = edit_brush(edit, group.first)->faces[index]; Vector3 n = vector(f.plane.plane_normal); move_face(f, n * n.dot(delta));
	}
	for (const auto &group : selected_vertices) {
		int64_t id = group.first; const auto &selected = group.second;
		auto vertices = brushes.at(id).vertices;
		for (int index : selected) { vertices[index] = vec3_add(vertices[index], native(delta)); if (!valid(vector(vertices[index]))) return failure("INVALID_ARGUMENT", "Vertex exceeds coordinate bounds", operation); }
		if (!rebuild_vertex_hull(edit_brush(edit, id)->faces, brushes.at(id), vertices, selected)) return failure("INVALID_GEOMETRY", "Vertex edit cannot form a bounded convex brush", operation);
	}
	return success();
}

Dictionary TBMapDocument::preview_translate_components(const Array &components, Vector3 delta) const {
	PackedInt64Array ids;
	for (int i = 0; i < components.size(); ++i) if (components[i].get_type() == Variant::DICTIONARY) {
		Dictionary component = components[i];
		if (component.has("brush_id") && component["brush_id"].get_type() == Variant::INT) ids.push_back(component["brush_id"]);
	}
	LMMapEdit edit; stage_preview_brushes(ids, edit); LMMapEdit before = edit; Dictionary sources;
	auto r = stage_components(components, delta, "preview_translate_components", edit, sources); if (!bool(r["ok"])) return r;
	return preview_fragments(before, edit, "preview_translate_components", sources);
}

Dictionary TBMapDocument::clip_brushes(const PackedInt64Array &ids, Vector3 p0, Vector3 p1, Vector3 p2, bool split) {
	LMMapEdit edit(*materialize_current_source()); PackedInt64Array out; Dictionary sources;
	auto r = stage_clip(ids, p0, p1, p2, split, "clip_brushes", edit, out, sources); if (!bool(r["ok"])) return r;
	return finish_edit(edit, "clip_brushes", out);
}

Dictionary TBMapDocument::stage_clip(const PackedInt64Array &ids, Vector3 p0, Vector3 p1, Vector3 p2, bool split, const StringName &operation, LMMapEdit &edit, PackedInt64Array &out, Dictionary &sources) const {
	auto r = check_brushes(ids, operation); if (!bool(r["ok"])) return r;
	Vector3 normal = (p2 - p0).cross(p1 - p0);
	if (!valid(p0) || !valid(p1) || !valid(p2) || !normal.is_finite() || normal.length_squared() < 1e-10) return failure("INVALID_ARGUMENT", "Clip points must define a finite nondegenerate plane", operation);
	normal.normalize();
	int64_t fresh = next_id;
	for (int64_t id : unique(ids)) {
		const auto *location = live_location(id, 'b');
		const auto topology = compact_topology(*current_brush_geometry(location->entity, location->index).compact);
		bool front = false, back = false;
		for (const vec3 point : topology.vertices) { double d = normal.dot(vector(point) - p0); if (d > 1e-5) front = true; if (d < -1e-5) back = true; }
		if (!front || (split && !back)) { out.push_back(id); sources[id] = id; continue; }
		std::vector<LMEditPrimitive> pieces;
		if (back) {
			auto source = *edit.brush(id);
			if (source.faces.size() >= 64) return failure("LIMIT_EXCEEDED", "Clip candidate exceeds 64 supporting planes", operation);
			for (int side = 0; side < (split ? 2 : 1); ++side) {
				auto piece = source; LMEditFace cut{};
				cut.texture = "common/caulk";
				cut.plane.uv_extra = {0, 1, 1};
				cut.plane.plane_points = {native(p0), native(side ? p2 : p1), native(side ? p1 : p2)};
				piece.faces.push_back(cut);
				if (!lm_edit_prune_faces(piece)) return failure("INVALID_GEOMETRY", "Clip produced a degenerate solid", operation);
				piece.id = split ? fresh++ : id; out.push_back(piece.id); sources[piece.id] = id; pieces.push_back(std::move(piece));
			}
		}
		for (auto &e : edit.entities) {
			auto it = std::find_if(e.primitives.begin(), e.primitives.end(), [&](const LMEditPrimitive &p) { return p.id == id; });
			if (it != e.primitives.end()) { auto offset = it - e.primitives.begin(); e.primitives.erase(it); e.primitives.insert(e.primitives.begin() + offset, pieces.begin(), pieces.end()); break; }
		}
	}
	return success();
}

Dictionary TBMapDocument::preview_clip_brushes(const PackedInt64Array &ids, Vector3 p0, Vector3 p1, Vector3 p2, bool split, bool flip) const {
	if (flip) std::swap(p1, p2);
	LMMapEdit edit; stage_preview_brushes(ids, edit); LMMapEdit before = edit; PackedInt64Array out; Dictionary sources;
	auto r = stage_clip(ids, p0, p1, p2, split, "preview_clip_brushes", edit, out, sources); if (!bool(r["ok"])) return r;
	return preview_fragments(before, edit, "preview_clip_brushes", sources);
}
