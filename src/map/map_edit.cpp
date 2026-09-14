#include "map_edit.h"
#include "map_writer.h"
#include "brush.h"
#include "patch.h"
#include "map_parser.h"
#include "geo_generator.h"
#include <algorithm>
#include <cmath>
#include <queue>

std::string LMEditEntity::property(const std::string &key) const {
	for (const auto &p : epairs) if (p.first == key) return p.second;
	return "";
}
void LMEditEntity::set_property(const std::string &key, const std::string &value) {
	for (auto &p : epairs) if (p.first == key) { p.second = value; return; }
	epairs.emplace_back(key, value);
}
LMMapEdit::LMMapEdit(const LMMapData &map) {
	for (int i = 0; i < map.entity_count; ++i) {
		const auto &source = map.entities[i];
		LMEditEntity e; e.id = source.id;
		for (int k = 0; k < source.property_count; ++k) e.epairs.emplace_back(source.properties[k].key, source.properties[k].value);
		for (int k = 0; k < source.primitive_count; ++k) {
			const auto &ref = source.primitives[k];
			LMEditPrimitive p; p.patch = ref.is_patch;
			if (p.patch) {
				p.id = source.patches[ref.index].id;
				p.patch_text = lm_write_patch(map, source.patches[ref.index]);
			} else {
				const auto &b = source.brushes[ref.index]; p.id = b.id;
				for (int f = 0; f < b.face_count; ++f) p.faces.push_back({b.faces[f], map.textures[b.faces[f].texture_idx].name});
			}
			e.primitives.push_back(std::move(p));
		}
		entities.push_back(std::move(e));
	}
}
std::string LMMapEdit::text(size_t reserve) const {
	std::string out;
	out.reserve(reserve);
	for (const auto &e : entities) {
		out += "{\n";
		for (const auto &p : e.epairs) out += lm_quote(p.first) + " " + lm_quote(p.second) + "\n";
		for (const auto &p : e.primitives) {
			if (p.patch) out += p.patch_text;
			else {
				out += "{\n";
				for (const auto &f : p.faces) out += lm_write_face(f.plane, f.texture);
				out += "}\n";
			}
		}
		out += "}\n";
	}
	return out;
}
LMEditEntity *LMMapEdit::entity(int64_t id) {
	for (auto &e : entities) if (e.id == id) return &e;
	return nullptr;
}
LMEditPrimitive *LMMapEdit::brush(int64_t id) {
	for (auto &e : entities) for (auto &p : e.primitives) if (!p.patch && p.id == id) return &p;
	return nullptr;
}
LMEditEntity &LMMapEdit::world() {
	for (auto &e : entities) if (e.property("classname") == "worldspawn") return e;
	LMEditEntity e; e.epairs.emplace_back("classname", "worldspawn");
	entities.insert(entities.begin(), std::move(e));
	return entities.front();
}
LMEditPrimitive lm_edit_cuboid(vec3 mins, vec3 maxs, const std::string &texture) {
	LMEditPrimitive brush;
	// Parser normal is (p2-p0) cross (p1-p0). Each plane points outward.
	for (int axis = 0; axis < 3; ++axis) for (int side = 0; side < 2; ++side) {
		double lo[] = {mins.x, mins.y, mins.z}, hi[] = {maxs.x, maxs.y, maxs.z};
		double a[3] = {lo[0], lo[1], lo[2]}, b[3], c[3];
		a[axis] = side ? hi[axis] : lo[axis];
		for (int j = 0; j < 3; ++j) b[j] = c[j] = a[j];
		b[(axis + 1) % 3] = hi[(axis + 1) % 3];
		c[(axis + 2) % 3] = hi[(axis + 2) % 3];
		LMEditFace f; f.texture = texture; f.plane.uv_extra = {0, 1, 1};
		f.plane.plane_points = {{a[0], a[1], a[2]}, {b[0], b[1], b[2]}, {c[0], c[1], c[2]}};
		if (side) std::swap(f.plane.plane_points.v1, f.plane.plane_points.v2);
		brush.faces.push_back(f);
	}
	return brush;
}

void lm_edit_rotate_brush(LMEditPrimitive &brush, vec3 pivot, int axis, double radians) {
	const int u = axis == 0 ? 1 : 0;
	const int v = axis == 2 ? 1 : 2;
	const double cosine = std::cos(radians), sine = std::sin(radians);
	auto rotate = [&](vec3 &point) {
		double values[] = {point.x, point.y, point.z};
		const double center[] = {pivot.x, pivot.y, pivot.z};
		const double x = values[u] - center[u], y = values[v] - center[v];
		values[u] = center[u] + x * cosine - y * sine;
		values[v] = center[v] + x * sine + y * cosine;
		point = {values[0], values[1], values[2]};
	};
	for (auto &face : brush.faces) {
		rotate(face.plane.plane_points.v0);
		rotate(face.plane.plane_points.v1);
		rotate(face.plane.plane_points.v2);
	}
}

bool lm_edit_prune_faces(LMEditPrimitive &brush) {
	std::string source = "{\n\"classname\" \"worldspawn\"\n{\n";
	for (const auto &f : brush.faces) source += lm_write_face(f.plane, f.texture);
	source += "}\n}\n";
	auto candidate = std::make_shared<LMMapData>();
	if (!LMMapParser(candidate).load_from_text(source)) return false;
	LMGeoGenerator(candidate).run();
	std::vector<LMEditFace> kept;
	for (size_t f = 0; f < brush.faces.size(); ++f) if (candidate->entity_geo[0].brushes[0].faces[f].vertex_count >= 3) kept.push_back(brush.faces[f]);
	if (kept.size() < 4) return false;
	brush.faces = std::move(kept);
	return true;
}

namespace {
constexpr double MERGE_POINT_EPSILON = 1e-5;
constexpr double MERGE_NORMAL_EPSILON = 1e-8;

bool merge_same_point(vec3 a, vec3 b) {
	const vec3 delta = vec3_sub(a, b);
	return vec3_dot(delta, delta) <= MERGE_POINT_EPSILON * MERGE_POINT_EPSILON;
}
bool merge_same_plane(const LMFace &a, const LMFace &b, bool opposing) {
	const double direction = opposing ? -1.0 : 1.0;
	return vec3_dot(a.plane_normal, b.plane_normal) * direction > 1.0 - MERGE_NORMAL_EPSILON &&
		std::abs(a.plane_dist - b.plane_dist * direction) <= MERGE_POINT_EPSILON;
}
bool merge_same_polygon(const LMBrushTopologyFace &a, const LMBrushTopologyFace &b) {
	if (a.winding.size() < 3 || a.winding.size() != b.winding.size()) return false;
	std::vector<bool> used(b.winding.size());
	for (const vec3 point : a.winding) {
		size_t match = 0;
		for (; match < b.winding.size(); ++match) if (!used[match] && merge_same_point(point, b.winding[match])) break;
		if (match == b.winding.size()) return false;
		used[match] = true;
	}
	return true;
}
}

LMMergeBrushResult lm_edit_merge_brushes(const std::vector<const LMEditPrimitive *> &brushes, const std::vector<LMBrushTopology> &topologies, LMEditPrimitive &merged) {
	if (brushes.size() < 2 || brushes.size() != topologies.size()) return LMMergeBrushResult::INVALID_GEOMETRY;
	std::vector<std::vector<bool>> interior(brushes.size());
	std::vector<std::vector<int>> links(brushes.size());
	for (size_t i = 0; i < brushes.size(); ++i) {
		if (!brushes[i] || brushes[i]->patch || brushes[i]->faces.size() != topologies[i].faces.size()) return LMMergeBrushResult::INVALID_GEOMETRY;
		interior[i].resize(brushes[i]->faces.size());
	}
	for (size_t i = 0; i < brushes.size(); ++i) for (size_t j = i + 1; j < brushes.size(); ++j) {
		bool linked = false;
		for (size_t a = 0; a < brushes[i]->faces.size(); ++a) {
			if (topologies[i].faces[a].winding.size() < 3) continue;
			for (size_t b = 0; b < brushes[j]->faces.size(); ++b) {
				if (!merge_same_plane(brushes[i]->faces[a].plane, brushes[j]->faces[b].plane, true) ||
						!merge_same_polygon(topologies[i].faces[a], topologies[j].faces[b])) continue;
				// A contributing face cannot be the complete boundary of two different solids.
				if (interior[i][a] || interior[j][b]) return LMMergeBrushResult::INVALID_GEOMETRY;
				interior[i][a] = interior[j][b] = true;
				linked = true;
			}
		}
		if (linked) { links[i].push_back(j); links[j].push_back(i); }
	}
	std::vector<bool> reached(brushes.size());
	std::queue<size_t> pending; pending.push(0); reached[0] = true;
	while (!pending.empty()) {
		const size_t i = pending.front(); pending.pop();
		for (int next : links[i]) if (!reached[next]) { reached[next] = true; pending.push(next); }
	}
	if (std::find(reached.begin(), reached.end(), false) != reached.end()) return LMMergeBrushResult::INVALID_GEOMETRY;

	merged = {};
	for (size_t i = 0; i < brushes.size(); ++i) for (size_t f = 0; f < brushes[i]->faces.size(); ++f) {
		if (topologies[i].faces[f].winding.size() < 3 || interior[i][f]) continue;
		const auto &source = brushes[i]->faces[f];
		for (const auto &topology : topologies) for (const vec3 point : topology.vertices) {
			// This is NetRadiant's winding concavity test extended to all source vertices.
			if (vec3_dot(source.plane.plane_normal, vec3_sub(point, source.plane.plane_points.v0)) > MERGE_POINT_EPSILON)
				return LMMergeBrushResult::INVALID_GEOMETRY;
		}
		const bool duplicate = std::any_of(merged.faces.begin(), merged.faces.end(), [&](const LMEditFace &face) {
			return merge_same_plane(source.plane, face.plane, false);
		});
		if (!duplicate) {
			if (merged.faces.size() == 64) return LMMergeBrushResult::LIMIT_EXCEEDED;
			merged.faces.push_back(source);
		}
	}
	return merged.faces.size() >= 4 ? LMMergeBrushResult::OK : LMMergeBrushResult::INVALID_GEOMETRY;
}
