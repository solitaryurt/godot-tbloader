// Standalone ownership/semantic gate; same production parser, writer and geo sources.
#include "map_parser.h"
#include "map_writer.h"
#include "geo_generator.h"
#include "face.h"
#include <cassert>
#include <cstring>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>

static std::string fixture(const std::string &name) {
	std::ifstream file("tests/map_editor/fixtures/" + name + ".map");
	assert(file.good());
	return { std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>() };
}
static void equal_vector(vec3 a, vec3 b) { assert(a.x == b.x && a.y == b.y && a.z == b.z); }
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

int main() {
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
	std::cout << "NATIVE_DOCUMENT_PASS: semantic roundtrips, all-prefix truncation, mutation corpus, 500 load/reset and 1000 rebuild cycles\n";
}
