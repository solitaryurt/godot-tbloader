#ifndef LM_BRUSH_TOPOLOGY_H
#define LM_BRUSH_TOPOLOGY_H

#include "map_data.h"
#include <utility>
#include <vector>

struct LMBrushTopologyFace {
	std::vector<vec3> winding;
	std::vector<int> vertex_indices;
	vec3 center{};
};

struct LMBrushTopology {
	std::vector<vec3> vertices;
	std::vector<std::pair<int, int>> edges;
	std::vector<LMBrushTopologyFace> faces;
	vec3 mins{};
	vec3 maxs{};
};

LMBrushTopology lm_extract_brush_topology(const LMBrush &brush, const LMBrushGeometry &geometry);

#endif
