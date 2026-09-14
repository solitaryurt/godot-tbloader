#include "map_document.h"
#include "map/brush.h"
#include "map/face.h"
#include "map/brush_topology.h"
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <cmath>
#include <vector>

using namespace godot;
namespace {
Vector3 vector(vec3 v) { return Vector3(v.x, v.y, v.z); }
}

Array TBMapDocument::get_draw_data() const {
	Array out;
	for (int e = 0; e < map->entity_count; ++e) for (int b = 0; b < map->entities[e].brush_count; ++b) {
		const auto &brush = map->entities[e].brushes[b]; const auto &geo = map->entity_geo[e].brushes[b];
		const auto topology = lm_extract_brush_topology(brush, geo);
		Dictionary entry; Array faces; PackedVector3Array vertices, edges; PackedInt32Array edge_indices;
		for (const auto &point : topology.vertices) vertices.push_back(vector(point));
		for (const auto &edge : topology.edges) {
			edge_indices.push_back(edge.first); edge_indices.push_back(edge.second);
			edges.push_back(vector(topology.vertices[edge.first])); edges.push_back(vector(topology.vertices[edge.second]));
		}
		for (int f = 0; f < brush.face_count; ++f) {
			const auto &face = topology.faces[f]; Dictionary data; PackedVector3Array winding; PackedInt32Array indices;
			for (const auto &point : face.winding) winding.push_back(vector(point));
			for (int index : face.vertex_indices) indices.push_back(index);
			data["index"] = f; data["winding"] = winding; data["vertex_indices"] = indices;
			data["center"] = vector(face.center); data["normal"] = vector(brush.faces[f].plane_normal);
			data["texture"] = String::utf8(map->textures[brush.faces[f].texture_idx].name); faces.push_back(data);
		}
		entry["id"] = brush.id; entry["entity_id"] = map->entities[e].id; entry["topology_revision"] = brush.topology_revision;
		entry["aabb_min"] = vector(topology.mins); entry["aabb_max"] = vector(topology.maxs); entry["vertices"] = vertices; entry["edges"] = edges;
		entry["edge_vertex_indices"] = edge_indices; entry["faces"] = faces; out.push_back(entry);
	}
	return out;
}

Array TBMapDocument::get_preview_data() const {
	struct Surface {
		PackedVector3Array vertices, normals;
		PackedVector2Array uvs;
		PackedInt32Array indices, faces;
		PackedInt64Array brushes;
	};
	std::vector<Surface> surfaces(map->texture_count);
	for (int e = 0; e < map->entity_count; ++e) for (int b = 0; b < map->entities[e].brush_count; ++b) {
		const auto &brush = map->entities[e].brushes[b]; const auto &geo = map->entity_geo[e].brushes[b];
		for (int f = 0; f < brush.face_count; ++f) {
			const auto &face = geo.faces[f]; auto &s = surfaces[brush.faces[f].texture_idx]; int base = s.vertices.size();
			for (int v = 0; v < face.vertex_count; ++v) {
				s.vertices.push_back(vector(face.vertices[v].vertex));
				// Editor solid preview uses unambiguous outward plane normals, regardless of _phong.
				s.normals.push_back(vector(brush.faces[f].plane_normal)); s.uvs.push_back(Vector2(face.vertices[v].uv.u, face.vertices[v].uv.v));
			}
			for (int i = 0; i < face.index_count; ++i) s.indices.push_back(base + face.indices[i]);
			for (int i = 0; i < face.index_count / 3; ++i) { s.brushes.push_back(brush.id); s.faces.push_back(f); }
		}
	}
	Array out;
	for (int t = 0; t < map->texture_count; ++t) {
		const auto &s = surfaces[t]; if (s.indices.is_empty()) continue;
		Dictionary data; data["texture"] = String::utf8(map->textures[t].name); data["texture_size"] = Vector2i(map->textures[t].width, map->textures[t].height);
		data["vertices"] = s.vertices; data["normals"] = s.normals; data["uvs"] = s.uvs; data["indices"] = s.indices;
		data["triangle_brush_ids"] = s.brushes; data["triangle_face_indices"] = s.faces; out.push_back(data);
	}
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
		const auto &brush = map->entities[location->entity].brushes[location->index];
		if (brush.topology_revision != token || face_index < 0 || face_index >= brush.face_count ||
				String::utf8(map->textures[brush.faces[face_index].texture_idx].name) != texture) continue;
		const auto &face = map->entity_geo[location->entity].brushes[location->index].faces[face_index];
		for (int index = 0; index < face.index_count; ++index) {
			const auto &uv = face.vertices[face.indices[index]].uv;
			out.push_back(Vector2(uv.u - std::floor(uv.u), uv.v - std::floor(uv.v)));
		}
	}
	return out;
}
