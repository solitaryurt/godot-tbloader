#include "map_document.h"
#include "map/brush.h"
#include "map/face.h"
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <set>
#include <vector>

using namespace godot;
namespace {
Vector3 vector(vec3 v) { return Vector3(v.x, v.y, v.z); }
}

Array TBMapDocument::get_draw_data() const {
	Array out;
	for (int e = 0; e < map->entity_count; ++e) for (int b = 0; b < map->entities[e].brush_count; ++b) {
		const auto &brush = map->entities[e].brushes[b]; const auto &geo = map->entity_geo[e].brushes[b];
		Dictionary entry; Array faces; PackedVector3Array vertices, edges; PackedInt32Array edge_indices;
		std::set<std::pair<int, int>> unique_edges;
		Vector3 lo, hi;
		for (int f = 0; f < brush.face_count; ++f) {
			const auto &face = geo.faces[f]; Dictionary data; PackedVector3Array winding; PackedInt32Array indices; Vector3 center;
			for (int v = 0; v < face.vertex_count; ++v) {
				Vector3 p = vector(face.vertices[v].vertex); winding.push_back(p); center += p;
				int index = 0; for (; index < vertices.size(); ++index) if (vertices[index].distance_squared_to(p) < 1e-10) break;
				if (index == vertices.size()) {
					if (vertices.is_empty()) lo = hi = p;
					else { lo = lo.min(p); hi = hi.max(p); }
					vertices.push_back(p);
				}
				indices.push_back(index);
			}
			for (int v = 0; v < indices.size(); ++v) {
				int a = indices[v], c = indices[(v + 1) % indices.size()]; if (a > c) std::swap(a, c);
				if (unique_edges.emplace(a, c).second) { edge_indices.push_back(a); edge_indices.push_back(c); edges.push_back(vertices[a]); edges.push_back(vertices[c]); }
			}
			data["index"] = f; data["winding"] = winding; data["vertex_indices"] = indices;
			data["center"] = center / face.vertex_count; data["normal"] = vector(brush.faces[f].plane_normal);
			data["texture"] = String::utf8(map->textures[brush.faces[f].texture_idx].name); faces.push_back(data);
		}
		entry["id"] = brush.id; entry["entity_id"] = map->entities[e].id; entry["topology_revision"] = brush.topology_revision;
		entry["aabb_min"] = lo; entry["aabb_max"] = hi; entry["vertices"] = vertices; entry["edges"] = edges;
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
