// Standalone ownership/semantic gate; same production parser, writer and geo sources.
#include "map_parser.h"
#include "map_writer.h"
#include "geo_generator.h"
#include "face.h"
#include "map_edit.h"
#include "brush_topology.h"
#include <cmath>
#include <cassert>
#include <cstring>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <set>
#include <map>
#include <algorithm>

static std::string fixture(const std::string &name) {
	std::ifstream file("tests/map_editor/fixtures/" + name + ".map");
	assert(file.good());
	return { std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>() };
}
static void equal_vector(vec3 a, vec3 b) { assert(a.x == b.x && a.y == b.y && a.z == b.z); }
static LMEditPrimitive pyramid(int sides, double apex_z, const std::string &texture) {
	LMEditPrimitive brush;
	std::vector<vec3> ring;
	for (int i = 0; i < sides; ++i) {
		const double angle = 6.28318530717958647692 * i / sides;
		ring.push_back({128 * std::cos(angle), 128 * std::sin(angle), 0});
	}
	LMEditFace base; base.texture = texture; base.plane.uv_extra = {0, 1, 1};
	base.plane.plane_points = {ring[0], ring[1], ring[2]};
	if (apex_z < 0) std::swap(base.plane.plane_points.v1, base.plane.plane_points.v2);
	brush.faces.push_back(base);
	for (int i = 0; i < sides; ++i) {
		LMEditFace side = base; const vec3 apex = {0, 0, apex_z};
		side.plane.plane_points = apex_z > 0 ? LMFacePoints{ring[i], apex, ring[(i + 1) % sides]} : LMFacePoints{ring[i], ring[(i + 1) % sides], apex};
		brush.faces.push_back(side);
	}
	return brush;
}
static void equal_maps(const LMMapData &a, const LMMapData &b) {
	assert(a.entity_count == b.entity_count);
	for (int i = 0; i < a.entity_count; ++i) {
		const auto &e = a.entities[i];
		const auto &o = b.entities[i];
		assert(e.property_count == o.property_count && e.brush_count == o.brush_count && e.patch_count == o.patch_count && e.primitive_count == o.primitive_count);
		for (int k = 0; k < e.property_count; ++k) {
			assert(!strcmp(e.properties[k].key, o.properties[k].key));
			assert(!strcmp(e.properties[k].value, o.properties[k].value));
		}
		for (int k = 0; k < e.primitive_count; ++k) assert(e.primitives[k].is_patch == o.primitives[k].is_patch && e.primitives[k].index == o.primitives[k].index);
		for (int k = 0; k < e.brush_count; ++k) {
			assert(e.brushes[k].face_count == o.brushes[k].face_count);
			for (int j = 0; j < e.brushes[k].face_count; ++j) {
				const auto &f = e.brushes[k].faces[j];
				const auto &g = o.brushes[k].faces[j];
				equal_vector(f.plane_points.v0, g.plane_points.v0); equal_vector(f.plane_points.v1, g.plane_points.v1); equal_vector(f.plane_points.v2, g.plane_points.v2);
				assert(!strcmp(a.textures[f.texture_idx].name, b.textures[g.texture_idx].name));
				assert(f.is_valve_uv == g.is_valve_uv);
				assert(f.uv_standard.u == g.uv_standard.u && f.uv_standard.v == g.uv_standard.v);
				equal_vector(f.uv_valve.u.axis, g.uv_valve.u.axis); equal_vector(f.uv_valve.v.axis, g.uv_valve.v.axis);
				assert(f.uv_valve.u.offset == g.uv_valve.u.offset && f.uv_valve.v.offset == g.uv_valve.v.offset);
				assert(f.uv_extra.rot == g.uv_extra.rot && f.uv_extra.scale_x == g.uv_extra.scale_x && f.uv_extra.scale_y == g.uv_extra.scale_y);
				assert(f.surface_flags.specified == g.surface_flags.specified && f.surface_flags.contents == g.surface_flags.contents && f.surface_flags.surface == g.surface_flags.surface && f.surface_flags.value == g.surface_flags.value);
			}
		}
		for (int k = 0; k < e.patch_count; ++k) {
			const auto &p = e.patches[k]; const auto &q = o.patches[k];
			assert(p.is_def3 == q.is_def3 && p.width == q.width && p.height == q.height && p.subdiv_x == q.subdiv_x && p.subdiv_y == q.subdiv_y);
			assert(!strcmp(a.textures[p.texture_idx].name, b.textures[q.texture_idx].name));
			for (int flag = 0; flag < 3; ++flag) assert(p.header_flags[flag] == q.header_flags[flag]);
			for (int cp = 0; cp < p.width * p.height; ++cp) {
				equal_vector(p.control_points[cp].position, q.control_points[cp].position);
				assert(p.control_points[cp].u == q.control_points[cp].u && p.control_points[cp].v == q.control_points[cp].v);
			}
		}
	}
}

static void check_topology_order(const LMBrush &brush, const LMBrushGeometry &geometry) {
	const auto topology = lm_extract_brush_topology(brush, geometry);
	std::vector<vec3> vertices;
	std::vector<std::pair<int, int>> edges;
	std::set<std::pair<int, int>> seen;
	assert(topology.faces.size() == static_cast<size_t>(brush.face_count));
	for (int f = 0; f < brush.face_count; ++f) {
		const auto &source = geometry.faces[f];
		assert(topology.faces[f].winding.size() == static_cast<size_t>(source.vertex_count));
		for (int v = 0; v < source.vertex_count; ++v) {
			const vec3 point = source.vertices[v].vertex;
			equal_vector(topology.faces[f].winding[v], point);
			int index = 0;
			for (; index < static_cast<int>(vertices.size()); ++index) {
				const vec3 delta = vec3_sub(vertices[index], point);
				if (vec3_dot(delta, delta) < 1e-10) break;
			}
			if (index == static_cast<int>(vertices.size())) vertices.push_back(point);
			assert(topology.faces[f].vertex_indices[v] == index);
		}
		for (int v = 0; v < source.vertex_count; ++v) {
			int a = topology.faces[f].vertex_indices[v], b = topology.faces[f].vertex_indices[(v + 1) % source.vertex_count];
			if (a > b) std::swap(a, b);
			if (seen.emplace(a, b).second) edges.emplace_back(a, b);
		}
	}
	assert(topology.vertices.size() == vertices.size() && topology.edges == edges);
	for (size_t i = 0; i < vertices.size(); ++i) equal_vector(topology.vertices[i], vertices[i]);
}

int main() {
	// A real bevel with a 1e-6 angle still has a crease. The old intersection
	// cutoff discarded that crease and generated an open top region.
	for (bool reverse : {false, true}) {
		auto cube = lm_edit_cuboid({4096, -2048, 1024}, {5120, -1024, 1088}, "bevel");
		auto bevel = cube.faces.back();
		bevel.plane.plane_points = {{4096, -2048, 1087.999488}, {4096, -1024, 1087.999488}, {5120, -2048, 1088.000512}};
		cube.faces.push_back(bevel);
		if (reverse) std::reverse(cube.faces.begin(), cube.faces.end());
		LMMapEdit edit(*std::make_shared<LMMapData>());
		edit.world().primitives.push_back(cube);
		auto data = std::make_shared<LMMapData>();
		assert(LMMapParser(data).load_from_text(edit.text()));
		LMGeoGenerator(data).run();
		const auto &brush = data->entities[0].brushes[0];
		const auto &geo = data->entity_geo[0].brushes[0];
		const auto topology = lm_extract_brush_topology(brush, geo);
		assert(topology.vertices.size() == 10 && topology.edges.size() == 15 && topology.faces.size() == 7);
		std::map<std::pair<int, int>, int> uses;
		for (const auto &face : topology.faces) {
			assert(face.vertex_indices.size() >= 3);
			for (size_t i = 0; i < face.vertex_indices.size(); ++i) {
				int a = face.vertex_indices[i], b = face.vertex_indices[(i + 1) % face.vertex_indices.size()];
				assert(a != b);
				if (a > b) std::swap(a, b);
				++uses[{a, b}];
			}
		}
		for (const auto &edge : uses) assert(edge.second == 2);
		for (double y : {-2048., -1024.}) {
			assert(std::any_of(topology.vertices.begin(), topology.vertices.end(), [y](vec3 p) {
				return vec3_length(vec3_sub(p, {4608, y, 1088})) < 1e-7;
			}));
		}
	}
	for (const auto *name : { "empty", "classic_cube", "valve_cube", "patches", "ownership" }) {
		const std::string source = fixture(name);
		auto map = std::make_shared<LMMapData>();
		LMMapParser parser(map);
		assert(parser.load_from_text(source));
		const std::string canonical = lm_write_map(*map);
		auto roundtrip = std::make_shared<LMMapData>();
		assert(LMMapParser(roundtrip).load_from_text(canonical));
		equal_maps(*map, *roundtrip);
		assert(lm_write_map(*roundtrip) == canonical);
		// Edit staging owns values independently of both source allocations and caches.
		LMMapEdit values(*map);
		assert(values.text() == canonical);
		auto value_copy = values;
		roundtrip->map_data_reset();
		assert(LMMapParser(roundtrip).load_from_text(value_copy.text()));
		equal_maps(*map, *roundtrip);
		// Inspect source semantics independently of serialization equality.
		if (!strcmp(name, "patches")) {
			const auto &p = map->entities[0].patches[1];
			assert(p.is_def3 && p.subdiv_x == 4 && p.subdiv_y == 6 && p.header_flags[0] == 7 && p.header_flags[2] == 9);
			assert(p.control_points[4].position.z == 48 && p.control_points[4].u == .5 && p.control_points[4].v == .5);
			assert(map->entities[0].patches[0].control_points[3].position.x == -16.5);
		}
		if (!strcmp(name, "ownership")) {
			assert(map->entities[0].brush_count == 0 && map->entities[1].brush_count == 1 && map->entities[2].brush_count == 0);
			const auto &f = map->entities[1].brushes[0].faces[0];
			assert(f.surface_flags.specified && f.surface_flags.contents == 1 && f.surface_flags.surface == 134217728 && f.surface_flags.value == -7);
			assert(f.plane_points.v0.x == 48.125 && f.uv_extra.scale_x == -.5);
		}
		LMGeoGenerator geo(map);
		geo.run();
		{
			auto clone = map->deep_clone();
			equal_maps(*map, *clone);
			assert(lm_write_map(*clone) == canonical);
			if (clone->entity_count && clone->entities[0].brush_count) {
				clone->entities[0].brushes[0].faces[0].plane_points.v0.x += 1;
				assert(clone->entities[0].brushes[0].faces[0].plane_points.v0.x != map->entities[0].brushes[0].faces[0].plane_points.v0.x);
			}
		}
		for (int e = 0; e < map->entity_count; ++e) for (int b = 0; b < map->entities[e].brush_count; ++b)
			check_topology_order(map->entities[e].brushes[b], map->entity_geo[e].brushes[b]);
		if (!strcmp(name, "patches")) {
			assert(map->entity_geo[0].patches[0].vertex_count == 25);
			assert(map->entity_geo[0].patches[1].vertex_count == 35);
			assert(map->entity_geo[0].patches[1].index_count == 144);
		}
		for (size_t length = 0; length < source.size(); ++length) {
			// Exercise every truncation, including partially allocated properties,
			// brush faces and patch grids. Some prefixes are valid complete maps.
			auto before_geo = map->entity_geo;
			std::string before = lm_write_map(*map);
			if (!parser.load_from_text(source.substr(0, length))) {
				assert(!parser.error.code.empty() && parser.error.line > 0 && parser.error.column > 0);
				assert(map->entity_geo == before_geo && lm_write_map(*map) == before);
			} else geo.run();
		}
		for (int repeat = 0; repeat < 100; ++repeat) {
			assert(parser.load_from_text(source));
			geo.run(); geo.run();
			// Cache disposal must not traverse document topology counts.
			int count = map->entity_count;
			map->entity_count = 0;
			map->map_data_free_geometry();
			map->entity_count = count;
			map->map_data_free_geometry();
			map->map_data_reset(); map->map_data_reset();
		}
		// Deterministic mutation corpus catches tokenizer state and unexpected NUL.
		for (size_t index = 0; index < source.size(); index += 3) {
			for (char value : std::string("\0\"{}()[]/-+e9", 13)) {
				std::string changed = source;
				changed[index] = value;
				parser.load_from_text(changed);
			}
		}
	}
	for (int repeat = 0; repeat < 200; ++repeat) {
		auto source = std::make_shared<LMMapData>();
		assert(LMMapParser(source).load_from_text(fixture("patches")));
		LMGeoGenerator(source).run();
		LMMapEdit edit(*source);
		const std::string preserved = edit.text();
		source.reset(); // staged patches and epairs must survive source destruction
		auto cube = lm_edit_cuboid({-16, -32, -8}, {48, 32, 24}, "baseline/checker");
		cube.id = 123;
		edit.world().primitives.push_back(cube);
		auto copy = edit;
		copy.world().primitives.back().faces[0].texture = "independent";
		assert(edit.brush(123)->faces[0].texture == "baseline/checker");
		auto map = std::make_shared<LMMapData>();
		assert(LMMapParser(map).load_from_text(edit.text()));
		LMGeoGenerator(map).run();
		assert(map->entities[0].brush_count == 1 && map->entities[0].patch_count == 2);
		assert(map->entities[0].primitive_count == 3 && !map->entities[0].primitives[2].is_patch);
		const auto &brush = map->entities[0].brushes[0];
		double volume = 0;
		for (int f = 0; f < brush.face_count; ++f) {
			const auto &face = map->entity_geo[0].brushes[0].faces[f];
			assert(face.vertex_count == 4 && face.index_count == 6);
			assert(std::abs(vec3_length(brush.faces[f].plane_normal) - 1) < 1e-10);
			for (int i = 0; i < face.index_count; i += 3) {
				vec3 a = vec3_sub(face.vertices[face.indices[i]].vertex, brush.center);
				vec3 b = vec3_sub(face.vertices[face.indices[i + 1]].vertex, brush.center);
				vec3 c = vec3_sub(face.vertices[face.indices[i + 2]].vertex, brush.center);
				assert(vec3_dot(vec3_cross(vec3_sub(b, a), vec3_sub(c, a)), brush.faces[f].plane_normal) < 0);
				volume -= vec3_dot(a, vec3_cross(b, c)) / 6;
			}
		}
		assert(std::abs(volume - 64 * 64 * 32) < 1e-8);
		// Slice at x=0; the old x-max plane becomes empty and must be pruned.
		auto cut = cube.faces[0]; cut.plane.plane_points = {{0, 0, 0}, {0, 0, 1}, {0, 1, 0}};
		cube.faces.push_back(cut);
		assert(lm_edit_prune_faces(cube) && cube.faces.size() == 6);
		*edit.brush(123) = cube;
		assert(LMMapParser(map).load_from_text(edit.text())); LMGeoGenerator(map).run();
		for (int f = 0; f < 6; ++f) {
			const auto &face = map->entity_geo[0].brushes[0].faces[f]; assert(face.vertex_count == 4);
			for (int v = 0; v < face.vertex_count; ++v) assert(face.vertices[v].vertex.x <= 0);
		}
		edit.world().primitives.pop_back();
		assert(edit.text() == preserved);
	}
	{
		auto cube = lm_edit_cuboid({0, 0, 0}, {16, 32, 8}, "rotate/material");
		cube.faces[0].plane.is_valve_uv = true;
		cube.faces[0].plane.uv_valve = {{{1, 2, 3}, 4}, {{5, 6, 7}, 8}};
		cube.faces[0].plane.uv_extra = {33, .5, -2};
		cube.faces[0].plane.surface_flags = {true, 1, 2, 3};
		const auto before = cube.faces[0];
		lm_edit_rotate_brush(cube, {8, 16, 4}, 2, 3.14159265358979323846 / 2);
		const auto &after = cube.faces[0];
		assert(after.texture == before.texture && after.plane.is_valve_uv == before.plane.is_valve_uv);
		equal_vector(after.plane.uv_valve.u.axis, before.plane.uv_valve.u.axis);
		equal_vector(after.plane.uv_valve.v.axis, before.plane.uv_valve.v.axis);
		assert(after.plane.uv_valve.u.offset == before.plane.uv_valve.u.offset && after.plane.uv_valve.v.offset == before.plane.uv_valve.v.offset);
		assert(after.plane.uv_extra.rot == before.plane.uv_extra.rot && after.plane.uv_extra.scale_x == before.plane.uv_extra.scale_x && after.plane.uv_extra.scale_y == before.plane.uv_extra.scale_y);
		assert(after.plane.surface_flags.specified && after.plane.surface_flags.contents == 1 && after.plane.surface_flags.surface == 2 && after.plane.surface_flags.value == 3);
		assert(std::abs(after.plane.plane_points.v0.x - (24 - before.plane.plane_points.v0.y)) < 1e-12);
		assert(std::abs(after.plane.plane_points.v0.y - (8 + before.plane.plane_points.v0.x)) < 1e-12);
		LMMapEdit edit(*std::make_shared<LMMapData>());
		edit.world().primitives.push_back(cube);
		auto rotated = std::make_shared<LMMapData>();
		assert(LMMapParser(rotated).load_from_text(edit.text()));
		LMGeoGenerator(rotated).run();
		assert(rotated->entities[0].brush_count == 1 && rotated->entities[0].brushes[0].face_count == 6);
		for (int face = 0; face < 6; ++face) assert(rotated->entity_geo[0].brushes[0].faces[face].vertex_count == 4);
	}
	{
		LMMapEdit source(*std::make_shared<LMMapData>());
		auto first = lm_edit_cuboid({0, 0, 0}, {16, 16, 16}, "first/material");
		first.faces[2].texture = "first/metadata";
		first.faces[2].plane.is_valve_uv = true;
		first.faces[2].plane.uv_valve = {{{1, 2, 3}, 4}, {{5, 6, 7}, 8}};
		first.faces[2].plane.uv_extra = {17, .5, -2};
		first.faces[2].plane.surface_flags = {true, 11, 22, -33};
		source.world().primitives.push_back(first);
		source.world().primitives.push_back(lm_edit_cuboid({16, 0, 0}, {32, 16, 16}, "second/material"));
		source.world().primitives.push_back(lm_edit_cuboid({32, 0, 0}, {48, 16, 16}, "third/material"));
		auto data = std::make_shared<LMMapData>();
		assert(LMMapParser(data).load_from_text(source.text())); LMGeoGenerator(data).run();
		LMMapEdit staged(*data);
		std::vector<const LMEditPrimitive *> inputs = {&staged.entities[0].primitives[0], &staged.entities[0].primitives[1], &staged.entities[0].primitives[2]};
		std::vector<LMBrushTopology> topology;
		for (int i = 0; i < 3; ++i) topology.push_back(lm_extract_brush_topology(data->entities[0].brushes[i], data->entity_geo[0].brushes[i]));
		LMEditPrimitive merged;
		assert(lm_edit_merge_brushes(inputs, topology, merged) == LMMergeBrushResult::OK && merged.faces.size() == 6);
		const auto metadata = std::find_if(merged.faces.begin(), merged.faces.end(), [](const LMEditFace &face) { return face.texture == "first/metadata"; });
		assert(metadata != merged.faces.end() && metadata->plane.is_valve_uv && metadata->plane.surface_flags.specified);
		assert(metadata->plane.uv_valve.u.offset == 4 && metadata->plane.uv_extra.rot == 17);
		assert(metadata->plane.surface_flags.contents == 11 && metadata->plane.surface_flags.surface == 22 && metadata->plane.surface_flags.value == -33);

		inputs = {&staged.entities[0].primitives[0], &staged.entities[0].primitives[2]};
		topology.erase(topology.begin() + 1);
		assert(lm_edit_merge_brushes(inputs, topology, merged) == LMMergeBrushResult::INVALID_GEOMETRY);

		LMMapEdit invalid(*std::make_shared<LMMapData>());
		invalid.world().primitives.push_back(lm_edit_cuboid({0, 0, 0}, {16, 16, 16}, "a"));
		invalid.world().primitives.push_back(lm_edit_cuboid({16, 0, 0}, {32, 8, 16}, "partial"));
		invalid.world().primitives.push_back(lm_edit_cuboid({0, 16, 0}, {16, 32, 16}, "l"));
		auto invalid_data = std::make_shared<LMMapData>();
		assert(LMMapParser(invalid_data).load_from_text(invalid.text())); LMGeoGenerator(invalid_data).run();
		LMMapEdit invalid_staged(*invalid_data); inputs.clear(); topology.clear();
		for (int i = 0; i < 3; ++i) {
			inputs.push_back(&invalid_staged.entities[0].primitives[i]);
			topology.push_back(lm_extract_brush_topology(invalid_data->entities[0].brushes[i], invalid_data->entity_geo[0].brushes[i]));
		}
		assert(lm_edit_merge_brushes({inputs[0], inputs[1]}, {topology[0], topology[1]}, merged) == LMMergeBrushResult::INVALID_GEOMETRY);
		assert(lm_edit_merge_brushes({inputs[0], inputs[2], &staged.entities[0].primitives[1]}, {topology[0], topology[2], lm_extract_brush_topology(data->entities[0].brushes[1], data->entity_geo[0].brushes[1])}, merged) == LMMergeBrushResult::INVALID_GEOMETRY);

		LMMapEdit many(*std::make_shared<LMMapData>());
		many.world().primitives.push_back(pyramid(63, 64, "upper"));
		many.world().primitives.push_back(pyramid(63, -64, "lower"));
		auto many_data = std::make_shared<LMMapData>();
		assert(LMMapParser(many_data).load_from_text(many.text())); LMGeoGenerator(many_data).run();
		LMMapEdit many_staged(*many_data);
		std::vector<LMBrushTopology> many_topology;
		for (int i = 0; i < 2; ++i) many_topology.push_back(lm_extract_brush_topology(many_data->entities[0].brushes[i], many_data->entity_geo[0].brushes[i]));
		assert(lm_edit_merge_brushes({&many_staged.entities[0].primitives[0], &many_staged.entities[0].primitives[1]}, many_topology, merged) == LMMergeBrushResult::LIMIT_EXCEEDED);
	}
	{
		const std::string source = fixture("tohunga");
		assert(source.size() == 3195820);
		auto map = std::make_shared<LMMapData>();
		assert(LMMapParser(map).load_from_text(source));
		assert(map->entity_count > 1 && map->entities[0].brush_count > 100);
		const size_t parsed_bytes = map->retained_bytes();
		LMGeoGenerator(map).run();
		assert(parsed_bytes > source.size() && map->retained_bytes() > parsed_bytes);
		for (int repeat = 0; repeat < 3; ++repeat) {
			LMMapEdit edit(*map);
			edit.world().primitives.push_back(lm_edit_cuboid({ -64, -64, -64 }, { 64, 64, 64 }, "common/caulk"));
			const std::string changed = edit.text();
			auto candidate = std::make_shared<LMMapData>();
			assert(LMMapParser(candidate).load_from_text(changed));
			LMGeoGenerator(candidate).run();
			map = std::move(candidate);
		}
		std::cout << "NATIVE_TOHUNGA_PASS\n";
	}
	std::cout << "NATIVE_DOCUMENT_PASS: semantic roundtrips, truncation/mutation corpus, 500 reset/1000 rebuild cycles; 200 detached edit/copy/cuboid/clip/patch-preservation cycles\n";
}
