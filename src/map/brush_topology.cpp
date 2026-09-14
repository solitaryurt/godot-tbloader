#include "brush_topology.h"
#include "brush.h"
#include <algorithm>
#include <set>

LMBrushTopology lm_extract_brush_topology(const LMBrush &brush, const LMBrushGeometry &geometry) {
	LMBrushTopology out;
	std::set<std::pair<int, int>> unique_edges;
	for (int f = 0; f < brush.face_count; ++f) {
		const auto &source = geometry.faces[f];
		LMBrushTopologyFace face;
		for (int v = 0; v < source.vertex_count; ++v) {
			const vec3 point = source.vertices[v].vertex;
			face.winding.push_back(point);
			face.center = vec3_add(face.center, point);
			int index = 0;
			for (; index < static_cast<int>(out.vertices.size()); ++index) {
				const vec3 delta = vec3_sub(out.vertices[index], point);
				if (vec3_dot(delta, delta) < 1e-10) break;
			}
			if (index == static_cast<int>(out.vertices.size())) {
				if (out.vertices.empty()) {
					out.mins = out.maxs = point;
				} else {
					out.mins = { std::min(out.mins.x, point.x), std::min(out.mins.y, point.y), std::min(out.mins.z, point.z) };
					out.maxs = { std::max(out.maxs.x, point.x), std::max(out.maxs.y, point.y), std::max(out.maxs.z, point.z) };
				}
				out.vertices.push_back(point);
			}
			face.vertex_indices.push_back(index);
		}
		if (source.vertex_count) face.center = vec3_div_double(face.center, source.vertex_count);
		for (int v = 0; v < source.vertex_count; ++v) {
			int a = face.vertex_indices[v], b = face.vertex_indices[(v + 1) % source.vertex_count];
			if (a > b) std::swap(a, b);
			if (unique_edges.emplace(a, b).second) out.edges.emplace_back(a, b);
		}
		out.faces.push_back(std::move(face));
	}
	return out;
}
