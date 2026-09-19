#include "map_document.h"
#include "map/brush.h"
#include "map/face.h"
#include "map/brush_topology.h"
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <cmath>
#include <map>
#include <string>
#include <unordered_map>
#include <vector>

using namespace godot;
namespace {
Vector3 vector(vec3 v) { return Vector3(v.x, v.y, v.z); }

void fill_positions(PackedVector3Array &out, const std::vector<vec3> &src) {
	out.resize(static_cast<int64_t>(src.size()));
	if (src.empty()) return;
	Vector3 *w = out.ptrw();
	for (size_t i = 0; i < src.size(); ++i) w[i] = vector(src[i]);
}

struct TextureIntern {
	std::unordered_map<int, String> by_idx;
	std::unordered_map<const char *, String> by_ptr;
	String from_idx(int idx, const char *name) {
		auto found = by_idx.find(idx);
		if (found != by_idx.end()) return found->second;
		String s = String::utf8(name ? name : "");
		by_idx.emplace(idx, s);
		return s;
	}
	String from_ptr(const char *name) {
		if (!name) name = "";
		auto found = by_ptr.find(name);
		if (found != by_ptr.end()) return found->second;
		String s = String::utf8(name);
		by_ptr.emplace(name, s);
		return s;
	}
};
}

String TBMapDocument::intern_face_texture(int entity, int brush, int face, void *intern_state) const {
	auto &intern = *static_cast<TextureIntern *>(intern_state);
	const LMBrush &base = map->entities[entity].brushes[brush];
	if (editor) {
		auto found = editor->brushes.find(base.id);
		if (found != editor->brushes.end()) return intern.from_ptr(found->second->materials[face].c_str());
	}
	const int texture = base.faces[face].texture_idx;
	const char *name = texture >= 0 && texture < map->texture_count ? map->textures[texture].name : "";
	return intern.from_idx(texture, name);
}

Dictionary TBMapDocument::make_draw_brush_entry(int entity, int brush, void *intern_state) const {
	const auto view = current_brush_geometry(entity, brush); const auto &source = *view.brush;
	Dictionary entry; Array faces; PackedVector3Array vertices, edges; PackedInt32Array edge_indices;
	vec3 mins{}, maxs{};
	if (view.compact) {
		const auto &geometry = *view.compact;
		fill_positions(vertices, geometry.positions);
		edge_indices.resize(static_cast<int64_t>(geometry.edges.size() * 2));
		edges.resize(static_cast<int64_t>(geometry.edges.size() * 2));
		if (!geometry.edges.empty()) {
			int32_t *ip = edge_indices.ptrw();
			Vector3 *ep = edges.ptrw();
			for (size_t i = 0; i < geometry.edges.size(); ++i) {
				const auto &edge = geometry.edges[i];
				ip[i * 2] = edge.a; ip[i * 2 + 1] = edge.b;
				ep[i * 2] = vector(geometry.positions[edge.a]);
				ep[i * 2 + 1] = vector(geometry.positions[edge.b]);
			}
		}
		faces.resize(source.face_count);
		for (int f = 0; f < source.face_count; ++f) {
			const auto &face = geometry.faces[f]; Dictionary data; PackedVector3Array winding; PackedInt32Array indices;
			winding.resize(static_cast<int64_t>(face.corner_count));
			indices.resize(static_cast<int64_t>(face.corner_count));
			if (face.corner_count) {
				Vector3 *wp = winding.ptrw();
				int32_t *idp = indices.ptrw();
				for (uint32_t v = 0; v < face.corner_count; ++v) {
					const auto &corner = geometry.corners[face.corner_begin + v];
					wp[v] = vector(geometry.positions[corner.position]);
					idp[v] = corner.position;
				}
			}
			data["index"] = f; data["winding"] = winding; data["vertex_indices"] = indices;
			data["center"] = vector(face.center); data["normal"] = vector(source.faces[f].plane_normal);
			data["texture"] = intern_face_texture(entity, brush, f, intern_state); faces[f] = data;
		}
		mins = geometry.mins; maxs = geometry.maxs;
	}
	entry["id"] = source.id; entry["entity_id"] = map->entities[entity].id; entry["topology_revision"] = source.topology_revision;
	entry["aabb_min"] = vector(mins); entry["aabb_max"] = vector(maxs); entry["vertices"] = vertices; entry["edges"] = edges;
	entry["edge_vertex_indices"] = edge_indices; entry["faces"] = faces;
	return entry;
}

Array TBMapDocument::get_draw_data() const {
	Array out;
	size_t brush_count = 0;
	for (int e = 0; e < map->entity_count; ++e) brush_count += size_t(map->entities[e].brush_count);
	out.resize(static_cast<int64_t>(brush_count));
	TextureIntern intern;
	int cursor = 0;
	for (int e = 0; e < map->entity_count; ++e) for (int b = 0; b < map->entities[e].brush_count; ++b) {
		out[cursor++] = make_draw_brush_entry(e, b, &intern);
	}
	return out;
}

Dictionary TBMapDocument::get_draw_changes() const {
	Dictionary out = get_last_change();
	Array brushes;
	if (!last_change.reset) {
		brushes.resize(static_cast<int64_t>(last_change.brush_ids.size()));
		TextureIntern intern;
		int cursor = 0;
		for (int64_t id : last_change.brush_ids) {
			const LiveLocation *location = live_location(id, 'b');
			if (!location) continue;
			brushes[cursor++] = make_draw_brush_entry(location->entity, location->index, &intern);
		}
		brushes.resize(cursor);
	}
	out["brushes"] = brushes;
	return out;
}

Array TBMapDocument::get_preview_data() const {
	struct Surface {
		PackedVector3Array vertices, normals;
		PackedVector2Array uvs;
		PackedInt32Array indices, faces;
		PackedInt64Array brushes;
	};
	std::map<std::string, Surface> surfaces;
	for (int e = 0; e < map->entity_count; ++e) for (int b = 0; b < map->entities[e].brush_count; ++b) {
		const auto view = current_brush_geometry(e, b); const auto &brush = *view.brush;
		for (int f = 0; f < brush.face_count; ++f) {
			const char *material = current_face_texture_cstr(e, b, f); auto &s = surfaces[material]; int base = s.vertices.size(); int index_count = 0;
			if (view.compact) {
				const auto &face = view.compact->faces[f]; index_count = face.index_count;
				for (uint32_t v = 0; v < face.corner_count; ++v) {
					const auto &corner = view.compact->corners[face.corner_begin + v];
					s.vertices.push_back(vector(view.compact->positions[corner.position])); s.normals.push_back(vector(brush.faces[f].plane_normal)); s.uvs.push_back(Vector2(corner.uv.u, corner.uv.v));
				}
				for (uint32_t i = 0; i < face.index_count; ++i) s.indices.push_back(base + view.compact->face_index(f, i) - face.corner_begin);
			}
			for (int i = 0; i < index_count / 3; ++i) { s.brushes.push_back(brush.id); s.faces.push_back(f); }
		}
	}
	Array out;
	out.resize(static_cast<int64_t>(surfaces.size()));
	int cursor = 0;
	for (const auto &item : surfaces) {
		const auto &s = item.second; if (s.indices.is_empty()) continue;
		String texture = String::utf8(item.first.c_str());
		Vector2i texture_size = texture_sizes.get(texture, Vector2i(1, 1));
		Dictionary data; data["texture"] = texture; data["texture_size"] = texture_size;
		data["vertices"] = s.vertices; data["normals"] = s.normals; data["uvs"] = s.uvs; data["indices"] = s.indices;
		data["triangle_brush_ids"] = s.brushes; data["triangle_face_indices"] = s.faces; out[cursor++] = data;
	}
	out.resize(cursor);
	return out;
}

PackedVector2Array TBMapDocument::get_face_preview_uvs(const Array &targets, const String &texture) const {
	PackedVector2Array out;
	for (int i = 0; i < targets.size(); ++i) {
		if (targets[i].get_type() != Variant::DICTIONARY) continue;
		const Dictionary target = targets[i];
		if (!target.has("brush_id") || !target.has("index") || !target.has("topology_revision") ||
				target["brush_id"].get_type() != Variant::INT || target["index"].get_type() != Variant::INT ||
				target["topology_revision"].get_type() != Variant::INT) continue;
		const int64_t id = target["brush_id"];
		const int face_index = target["index"];
		const int64_t token = target["topology_revision"];
		const LiveLocation *location = live_location(id, 'b');
		if (!location) continue;
		const auto view = current_brush_geometry(location->entity, location->index); const auto &brush = *view.brush;
		if (brush.topology_revision != token || face_index < 0 || face_index >= brush.face_count ||
				String::utf8(current_face_texture_cstr(location->entity, location->index, face_index)) != texture) continue;
		if (view.compact) {
			const auto &face = view.compact->faces[face_index];
			for (uint32_t index = 0; index < face.index_count; ++index) { const auto &uv = view.compact->corners[view.compact->face_index(face_index, index)].uv; out.push_back(Vector2(uv.u - std::floor(uv.u), uv.v - std::floor(uv.v))); }
		}
	}
	return out;
}
