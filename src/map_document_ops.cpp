#include "map_document.h"
#include "map/brush.h"
#include "map/patch.h"
#include "map/map_writer.h"
#include "map/geo_generator.h"
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <algorithm>
#include <charconv>
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
void move_face(LMEditFace &f, Vector3 delta) {
	auto &p = f.plane.plane_points;
	p.v0 = vec3_add(p.v0, native(delta)); p.v1 = vec3_add(p.v1, native(delta)); p.v2 = vec3_add(p.v2, native(delta));
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
}

Dictionary TBMapDocument::finish_edit(const LMMapEdit &edit, const StringName &operation, const Variant &value) {
	std::shared_ptr<LMMapData> candidate;
	std::string normalized;
	Dictionary result = prepare(edit.text(canonical->size() + 1024), candidate, operation, path, &normalized);
	if (!bool(result["ok"])) return result;
	// Reserve locally; failure/no-op never consumes handles or changes the live namespace.
	int64_t high = next_id;
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
	if (normalized == *canonical && identities(*candidate) == identities(*map)) return success(false, value);
	next_id = high;
	for (int i = 0; i < candidate->entity_count; ++i) {
		const auto &e = candidate->entities[i]; issued_ids[e.id] = 'e';
		for (int k = 0; k < e.primitive_count; ++k) { const auto &p = e.primitives[k]; issued_ids[p.is_patch ? e.patches[p.index].id : e.brushes[p.index].id] = p.is_patch ? 'p' : 'b'; }
	}
	commit(candidate, normalized, is_dirty());
	return success(true, value);
}
Dictionary TBMapDocument::check_brushes(const PackedInt64Array &ids, const StringName &operation) const {
	std::set<int64_t> live;
	for (int e = 0; e < map->entity_count; ++e) for (int b = 0; b < map->entities[e].brush_count; ++b) live.insert(map->entities[e].brushes[b].id);
	for (int64_t id : ids) if (!live.count(id)) {
		Dictionary r = failure("INVALID_ID", "Unknown brush handle", operation); Dictionary error = r["error"]; error["brush_id"] = id; return r;
	}
	return success();
}
Dictionary TBMapDocument::check_face(int64_t id, int face, int64_t token, const StringName &operation) const {
	for (int e = 0; e < map->entity_count; ++e) for (int b = 0; b < map->entities[e].brush_count; ++b) {
		const auto &brush = map->entities[e].brushes[b]; if (brush.id != id) continue;
		if (brush.topology_revision == token && face >= 0 && face < brush.face_count) return success();
		Dictionary r = failure(brush.topology_revision != token ? "STALE_COMPONENT" : "INVALID_ARGUMENT", "Stale topology token or invalid face index", operation);
		Dictionary error = r["error"]; error["brush_id"] = id; error["face"] = face; return r;
	}
	PackedInt64Array ids; ids.push_back(id); return check_brushes(ids, operation);
}
Dictionary TBMapDocument::create_cuboid(Vector3 mins, Vector3 maxs, const String &texture) {
	if (!valid(mins) || !valid(maxs) || mins.x >= maxs.x || mins.y >= maxs.y || mins.z >= maxs.z || !token(texture)) return failure("INVALID_ARGUMENT", "Expected finite increasing bounds and a texture name", "create_cuboid");
	LMMapEdit edit(*map); auto p = lm_edit_cuboid(native(mins), native(maxs), bytes(texture)); p.id = next_id;
	edit.world().primitives.push_back(p); return finish_edit(edit, "create_cuboid", p.id);
}
Dictionary TBMapDocument::duplicate_brushes(const PackedInt64Array &ids) {
	auto r = check_brushes(ids, "duplicate_brushes"); if (!bool(r["ok"])) return r;
	LMMapEdit edit(*map); PackedInt64Array out; int64_t id = next_id;
	for (int64_t source : unique(ids)) for (auto &e : edit.entities) {
		auto it = std::find_if(e.primitives.begin(), e.primitives.end(), [&](const LMEditPrimitive &p) { return p.id == source; });
		if (it != e.primitives.end()) { auto copy = *it; copy.id = id++; out.push_back(copy.id); e.primitives.push_back(std::move(copy)); break; }
	}
	return finish_edit(edit, "duplicate_brushes", out);
}
Dictionary TBMapDocument::delete_brushes(const PackedInt64Array &ids) {
	auto r = check_brushes(ids, "delete_brushes"); if (!bool(r["ok"])) return r;
	LMMapEdit edit(*map); auto list = unique(ids); std::set<int64_t> selected(list.begin(), list.end());
	for (auto &e : edit.entities) e.primitives.erase(std::remove_if(e.primitives.begin(), e.primitives.end(), [&](const LMEditPrimitive &p) { return selected.count(p.id); }), e.primitives.end());
	return finish_edit(edit, "delete_brushes");
}
Dictionary TBMapDocument::translate_brushes(const PackedInt64Array &ids, Vector3 delta) {
	auto r = check_brushes(ids, "translate_brushes"); if (!bool(r["ok"])) return r;
	if (!valid(delta)) return failure("INVALID_ARGUMENT", "Invalid translation", "translate_brushes");
	LMMapEdit edit(*map); for (int64_t id : unique(ids)) for (auto &f : edit.brush(id)->faces) move_face(f, delta);
	return finish_edit(edit, "translate_brushes");
}
Dictionary TBMapDocument::rotate_brushes(const PackedInt64Array &ids, Vector3 pivot, int axis, double radians) {
	auto r = check_brushes(ids, "rotate_brushes"); if (!bool(r["ok"])) return r;
	if (!valid(pivot) || axis < 0 || axis > 2 || !std::isfinite(radians) || std::abs(radians) > 1e9)
		return failure("INVALID_ARGUMENT", "Expected a finite pivot, axis 0..2 and finite angle", "rotate_brushes");
	radians = std::remainder(radians, 6.28318530717958647692);
	if (ids.is_empty() || std::abs(radians) < 1e-12) return success();
	LMMapEdit edit(*map);
	for (int64_t id : unique(ids)) lm_edit_rotate_brush(*edit.brush(id), native(pivot), axis, radians);
	return finish_edit(edit, "rotate_brushes");
}
Dictionary TBMapDocument::translate_face(int64_t id, int face, Vector3 delta, int64_t topology_revision) {
	auto r = check_face(id, face, topology_revision, "translate_face"); if (!bool(r["ok"])) return r;
	if (!valid(delta)) return failure("INVALID_ARGUMENT", "Invalid translation", "translate_face");
	LMMapEdit edit(*map); auto &f = edit.brush(id)->faces[face];
	// Tangential motion does not resize the supporting plane or create history.
	Vector3 n = vector(f.plane.plane_normal); move_face(f, n * n.dot(delta));
	return finish_edit(edit, "translate_face");
}
Dictionary TBMapDocument::set_brush_texture(const PackedInt64Array &ids, const String &name) {
	auto r = check_brushes(ids, "set_brush_texture"); if (!bool(r["ok"])) return r;
	if (!token(name)) return failure("INVALID_ARGUMENT", "Invalid texture name", "set_brush_texture");
	LMMapEdit edit(*map); for (int64_t id : unique(ids)) for (auto &f : edit.brush(id)->faces) f.texture = bytes(name);
	return finish_edit(edit, "set_brush_texture");
}
Dictionary TBMapDocument::set_face_texture(int64_t id, int face, const String &name, int64_t topology_revision) {
	auto r = check_face(id, face, topology_revision, "set_face_texture"); if (!bool(r["ok"])) return r;
	if (!token(name)) return failure("INVALID_ARGUMENT", "Invalid texture name", "set_face_texture");
	LMMapEdit edit(*map); edit.brush(id)->faces[face].texture = bytes(name); return finish_edit(edit, "set_face_texture");
}
Dictionary TBMapDocument::get_face_uv(int64_t id, int face, int64_t topology_revision) const {
	auto r = check_face(id, face, topology_revision, "get_face_uv"); if (!bool(r["ok"])) return r;
	const LMFace *source = nullptr;
	for (int e = 0; e < map->entity_count; ++e) for (int b = 0; b < map->entities[e].brush_count; ++b) {
		const auto &brush = map->entities[e].brushes[b]; if (brush.id == id) source = &brush.faces[face];
	}
	const auto &f = *source; Dictionary uv;
	uv["projection"] = f.is_valve_uv ? "valve" : "classic";
	uv["shift"] = f.is_valve_uv ? Vector2(f.uv_valve.u.offset, f.uv_valve.v.offset) : Vector2(f.uv_standard.u, f.uv_standard.v);
	uv["rotation"] = f.uv_extra.rot; uv["scale"] = Vector2(f.uv_extra.scale_x, f.uv_extra.scale_y);
	uv["u_axis"] = vector(f.uv_valve.u.axis); uv["v_axis"] = vector(f.uv_valve.v.axis); return success(false, uv);
}
Dictionary TBMapDocument::set_face_uv(int64_t id, int face, Vector2 shift, double rotation, Vector2 scale, int64_t topology_revision) {
	auto r = check_face(id, face, topology_revision, "set_face_uv"); if (!bool(r["ok"])) return r;
	if (!shift.is_finite() || !scale.is_finite() || !std::isfinite(rotation) || std::abs(rotation) > 1e9 || std::abs(shift.x) > 1e9 || std::abs(shift.y) > 1e9 || std::abs(scale.x) < 1e-9 || std::abs(scale.y) < 1e-9 || std::abs(scale.x) > 1e9 || std::abs(scale.y) > 1e9) return failure("INVALID_ARGUMENT", "Invalid UV transform", "set_face_uv");
	LMMapEdit edit(*map); auto &f = edit.brush(id)->faces[face].plane;
	if (f.is_valve_uv) return failure("UNSUPPORTED_PROJECTION", "Valve projection is read-only", "set_face_uv");
	f.uv_standard = {shift.x, shift.y}; f.uv_extra = {rotation, scale.x, scale.y}; return finish_edit(edit, "set_face_uv");
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
	std::shared_ptr<LMMapData> candidate; auto r = prepare(*canonical, candidate, "set_texture_sizes", path); if (!bool(r["ok"])) return r;
	resolve_texture_sizes(*candidate, normalized); LMGeoGenerator(candidate).run();
	apply_identities(*candidate, identities(*map));
	for (int e = 0; e < map->entity_count; ++e) for (int b = 0; b < map->entities[e].brush_count; ++b) candidate->entities[e].brushes[b].topology_revision = map->entities[e].brushes[b].topology_revision;
	map = candidate; texture_sizes = normalized; emit_signal("preview_changed"); return success(true);
}
Dictionary TBMapDocument::export_selection(const PackedInt64Array &ids) const {
	auto r = check_brushes(ids, "export_selection"); if (!bool(r["ok"])) return r;
	LMMapEdit edit(*map); auto list = unique(ids); std::set<int64_t> selected(list.begin(), list.end());
	for (auto &e : edit.entities) e.primitives.erase(std::remove_if(e.primitives.begin(), e.primitives.end(), [&](const LMEditPrimitive &p) { return !selected.count(p.id); }), e.primitives.end());
	edit.entities.erase(std::remove_if(edit.entities.begin(), edit.entities.end(), [](const LMEditEntity &e) { return e.primitives.empty(); }), edit.entities.end());
	return success(false, text(edit.text()));
}
Dictionary TBMapDocument::import_selection(const String &source) {
	if (source.strip_edges().is_empty()) return success(false, PackedInt64Array());
	std::shared_ptr<LMMapData> candidate; auto r = prepare(bytes(source), candidate, "import_selection", path); if (!bool(r["ok"])) return r;
	LMMapEdit incoming(*candidate), edit(*map); PackedInt64Array out; int64_t id = next_id;
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
	LMMapEdit edit(*map); LMEditEntity e; e.id = next_id; e.epairs = {{"classname", bytes(classname)}, {"origin", origin_text(origin)}}; edit.entities.push_back(e);
	return finish_edit(edit, "create_point_entity", e.id);
}
Dictionary TBMapDocument::set_entity_property(int64_t id, const String &key, const String &value) {
	LMMapEdit edit(*map); auto e = edit.entity(id); if (!e) return failure("INVALID_ID", "Unknown entity handle", "set_entity_property");
	if (!token(key) || !token(value, true)) return failure("INVALID_ARGUMENT", "Invalid epair", "set_entity_property");
	if (key == "classname" && (value.is_empty() || (e->property("classname") == "worldspawn") != (value == "worldspawn"))) return failure("INVALID_ARGUMENT", "Cannot change worldspawn identity or empty classname", "set_entity_property");
	Vector3 origin; if (key == "origin" && (value.is_empty() || !read_origin(bytes(value), origin))) return failure("INVALID_ARGUMENT", "Origin must contain three finite coordinates", "set_entity_property");
	e->set_property(bytes(key), bytes(value)); return finish_edit(edit, "set_entity_property");
}
Dictionary TBMapDocument::remove_entity_property(int64_t id, const String &key) {
	LMMapEdit edit(*map); auto e = edit.entity(id); if (!e) return failure("INVALID_ID", "Unknown entity handle", "remove_entity_property");
	if (!token(key) || key == "classname") return failure("INVALID_ARGUMENT", "Cannot remove classname or use an invalid key", "remove_entity_property");
	e->epairs.erase(std::remove_if(e->epairs.begin(), e->epairs.end(), [&](const auto &p) { return p.first == bytes(key); }), e->epairs.end());
	return finish_edit(edit, "remove_entity_property");
}
Dictionary TBMapDocument::translate_point_entities(const PackedInt64Array &ids, Vector3 delta) {
	if (!valid(delta)) return failure("INVALID_ARGUMENT", "Invalid translation", "translate_point_entities");
	LMMapEdit edit(*map);
	for (int64_t id : unique(ids)) {
		auto e = edit.entity(id); if (!e) return failure("INVALID_ID", "Unknown entity handle", "translate_point_entities");
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
	LMMapEdit edit(*map); LMEditEntity group; group.id = next_id; group.epairs.emplace_back("classname", bytes(classname));
	for (int64_t id : unique(ids)) group.primitives.push_back(*edit.brush(id));
	for (auto &e : edit.entities) e.primitives.erase(std::remove_if(e.primitives.begin(), e.primitives.end(), [&](const LMEditPrimitive &p) { return ids.has(p.id); }), e.primitives.end());
	edit.entities.push_back(group); return finish_edit(edit, "group_brushes", group.id);
}
Dictionary TBMapDocument::return_brushes_to_worldspawn(const PackedInt64Array &ids) {
	auto r = check_brushes(ids, "return_brushes_to_worldspawn"); if (!bool(r["ok"])) return r;
	if (ids.is_empty()) return success();
	LMMapEdit edit(*map); edit.world(); std::vector<LMEditPrimitive> moved;
	for (int64_t id : unique(ids)) for (auto &e : edit.entities) if (e.property("classname") != "worldspawn") {
		auto it = std::find_if(e.primitives.begin(), e.primitives.end(), [&](const LMEditPrimitive &p) { return p.id == id; });
		if (it != e.primitives.end()) { moved.push_back(*it); e.primitives.erase(it); break; }
	}
	auto &world = edit.world(); world.primitives.insert(world.primitives.end(), moved.begin(), moved.end());
	return finish_edit(edit, "return_brushes_to_worldspawn");
}
Dictionary TBMapDocument::delete_entities(const PackedInt64Array &ids, bool delete_owned_brushes) {
	LMMapEdit edit(*map); std::vector<LMEditPrimitive> moved;
	for (int64_t id : unique(ids)) {
		auto e = edit.entity(id); if (!e) return failure("INVALID_ID", "Unknown entity handle", "delete_entities");
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
	Vector3 lo, hi; Array draw = get_draw_data();
	for (int i = 0; i < draw.size(); ++i) { Dictionary b = draw[i]; if (int64_t(b["id"]) == id) { lo = b["aabb_min"]; hi = b["aabb_max"]; break; } }
	LMMapEdit edit(*map); auto &brush = *edit.brush(id); auto prototype = brush.faces.front();
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
	if (!valid(delta)) return failure("INVALID_ARGUMENT", "Invalid translation", operation);
	std::map<int64_t, Dictionary> brushes;
	Array draw = get_draw_data();
	for (int i = 0; i < draw.size(); ++i) { Dictionary b = draw[i]; brushes[int64_t(b["id"])] = b; }
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
		Dictionary b = brushes.at(id); PackedVector3Array vertices = b["vertices"]; PackedInt32Array edges = b["edge_vertex_indices"]; Array faces = b["faces"];
		int count = kind == "vertex" ? vertices.size() : kind == "edge" ? edges.size() / 2 : kind == "face" ? faces.size() : 0;
		if (index < 0 || index >= count) return failure("INVALID_ARGUMENT", "Invalid component kind or index", operation);
		if (kind == "face") selected_faces[id].insert(index);
		else if (kind == "vertex") selected_vertices[id].insert(index);
		else { selected_vertices[id].insert(edges[index * 2]); selected_vertices[id].insert(edges[index * 2 + 1]); }
	}
	// Face mode moves supporting planes; vertex/edge mode moves incident vertices.
	// Mixing these semantics in one brush is ambiguous and must never drop handles.
	for (const auto &group : selected_faces) if (selected_vertices.count(group.first)) return failure("INVALID_ARGUMENT", "Cannot mix face and vertex/edge deformation on a brush", operation);
	if (components.is_empty() || delta == Vector3()) return success();
	LMMapEdit edit(*map);
	for (const auto &group : selected_faces) for (int index : group.second) {
		auto &f = edit.brush(group.first)->faces[index]; Vector3 n = vector(f.plane.plane_normal); move_face(f, n * n.dot(delta));
	}
	std::map<int64_t, PackedVector3Array> expected;
	for (const auto &group : selected_vertices) {
		int64_t id = group.first; const auto &selected = group.second;
		Dictionary brush = brushes.at(id); PackedVector3Array vertices = brush["vertices"];
		for (int index : selected) { vertices.set(index, vertices[index] + delta); if (!valid(vertices[index])) return failure("INVALID_ARGUMENT", "Vertex exceeds coordinate bounds", operation); }
		expected[id] = vertices;
		auto &target = *edit.brush(id); Array faces = brush["faces"];
		for (int f = 0; f < faces.size(); ++f) {
			Dictionary face = faces[f]; PackedInt32Array indices = face["vertex_indices"];
			bool affected = false; for (int index : indices) if (selected.count(index)) affected = true;
			if (!affected) continue;
			Vector3 a = vertices[indices[0]], b, c, n;
			for (int i = 1; i + 1 < indices.size(); ++i) {
				b = vertices[indices[i]]; c = vertices[indices[i + 1]]; n = (c - a).cross(b - a);
				if (n.length_squared() > 1e-10) break;
			}
			if (n.length_squared() <= 1e-10) return failure("INVALID_GEOMETRY", "Vertex edit collapses a face", operation);
			n.normalize();
			for (int index : indices) if (std::abs(n.dot(vertices[index] - a)) > 1e-5) return failure("INVALID_GEOMETRY", "Vertex edit makes a nonplanar face", operation);
			target.faces[f].plane.plane_points = {native(a), native(b), native(c)};
		}
	}
	// Ensure the convex candidate has exactly the requested vertices, not a different
	// hull produced by intersecting changed supporting planes.
	std::shared_ptr<LMMapData> candidate; auto r = prepare(edit.text(), candidate, operation, path); if (!bool(r["ok"])) return r;
	for (int e = 0; e < candidate->entity_count; ++e) for (int b = 0; b < candidate->entities[e].brush_count; ++b) {
		auto found = expected.find(map->entities[e].brushes[b].id); if (found == expected.end()) continue;
		const auto &vertices = found->second;
		std::set<int> matched; const auto &geo = candidate->entity_geo[e].brushes[b];
		for (int f = 0; f < geo.face_count; ++f) for (int v = 0; v < geo.faces[f].vertex_count; ++v) {
			Vector3 p = vector(geo.faces[f].vertices[v].vertex); int index = 0;
			for (; index < vertices.size(); ++index) if (p.distance_squared_to(vertices[index]) < 1e-8) break;
			if (index == vertices.size()) return failure("INVALID_GEOMETRY", "Vertex edit changes the convex hull unexpectedly", operation);
			matched.insert(index);
		}
		if (matched.size() != size_t(vertices.size())) return failure("INVALID_GEOMETRY", "Vertex edit removes a hull vertex", operation);
	}
	return finish_edit(edit, operation);
}

Dictionary TBMapDocument::clip_brushes(const PackedInt64Array &ids, Vector3 p0, Vector3 p1, Vector3 p2, bool split) {
	auto r = check_brushes(ids, "clip_brushes"); if (!bool(r["ok"])) return r;
	Vector3 normal = (p2 - p0).cross(p1 - p0);
	if (!valid(p0) || !valid(p1) || !valid(p2) || !normal.is_finite() || normal.length_squared() < 1e-10) return failure("INVALID_ARGUMENT", "Clip points must define a finite nondegenerate plane", "clip_brushes");
	normal.normalize();
	LMMapEdit edit(*map); Array draw = get_draw_data(); PackedInt64Array out; int64_t fresh = next_id;
	for (int64_t id : unique(ids)) {
		PackedVector3Array vertices;
		for (int i = 0; i < draw.size(); ++i) { Dictionary b = draw[i]; if (int64_t(b["id"]) == id) { vertices = b["vertices"]; break; } }
		bool front = false, back = false;
		for (Vector3 v : vertices) { double d = normal.dot(v - p0); if (d > 1e-5) front = true; if (d < -1e-5) back = true; }
		if (!front || (split && !back)) { out.push_back(id); continue; }
		std::vector<LMEditPrimitive> pieces;
		if (back) {
			auto source = *edit.brush(id);
			if (source.faces.size() >= 64) return failure("LIMIT_EXCEEDED", "Clip candidate exceeds 64 supporting planes", "clip_brushes");
			for (int side = 0; side < (split ? 2 : 1); ++side) {
				auto piece = source; LMEditFace cut{};
				cut.texture = "common/caulk";
				cut.plane.uv_extra = {0, 1, 1};
				cut.plane.plane_points = {native(p0), native(side ? p2 : p1), native(side ? p1 : p2)};
				piece.faces.push_back(cut);
				if (!lm_edit_prune_faces(piece)) return failure("INVALID_GEOMETRY", "Clip produced a degenerate solid", "clip_brushes");
				piece.id = split ? fresh++ : id; out.push_back(piece.id); pieces.push_back(std::move(piece));
			}
		}
		for (auto &e : edit.entities) {
			auto it = std::find_if(e.primitives.begin(), e.primitives.end(), [&](const LMEditPrimitive &p) { return p.id == id; });
			if (it != e.primitives.end()) { auto offset = it - e.primitives.begin(); e.primitives.erase(it); e.primitives.insert(e.primitives.begin() + offset, pieces.begin(), pieces.end()); break; }
		}
	}
	return finish_edit(edit, "clip_brushes", out);
}
