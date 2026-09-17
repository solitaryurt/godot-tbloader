#include "geo_generator.h"
#include "map_edit.h"
#include "map_parser.h"
#include "surface_gatherer.h"
#include "worldspawn_partitioner.h"

#include <algorithm>
#include <cassert>
#include <climits>
#include <cmath>
#include <cstring>
#include <fstream>
#include <iostream>
#include <iterator>
#include <limits>
#include <memory>
#include <string>
#include <vector>

static std::string fixture(const std::string &name) {
	std::ifstream file("tests/map_editor/fixtures/" + name + ".map");
	assert(file.good());
	return { std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>() };
}

static std::shared_ptr<LMMapData> generated(const std::string &source) {
	auto map = std::make_shared<LMMapData>();
	assert(LMMapParser(map).load_from_text(source));
	LMGeoGenerator(map).run();
	return map;
}

static void equal_vec(vec3 actual, vec3 expected) {
	assert(std::abs(actual.x - expected.x) < 1e-9 && std::abs(actual.y - expected.y) < 1e-9 &&
			std::abs(actual.z - expected.z) < 1e-9);
}

static std::vector<int> texture_indices(LMMapData &map, const std::vector<std::string> &names) {
	std::vector<int> result;
	for (const auto &name : names) {
		const int index = map.map_data_find_texture(name.c_str());
		if (index >= 0) result.push_back(index);
	}
	return result;
}

static LMWorldspawnItem partition_item(int ordinal, vec3 mins, vec3 maxs, int64_t triangles = 1,
		std::vector<int> textures = {}) {
	LMWorldspawnItem item;
	item.entity_index = 0;
	item.primitive_ordinal = ordinal;
	item.source_index = ordinal;
	item.mins = mins;
	item.maxs = maxs;
	item.visual_triangle_count = triangles;
	item.texture_indices = std::move(textures);
	return item;
}

static std::vector<std::vector<int>> chunk_members(const LMWorldspawnPartitionResult &result) {
	std::vector<std::vector<int>> members;
	for (const auto &chunk : result.chunks) {
		members.emplace_back();
		for (const auto &item : chunk.items) members.back().push_back(item.primitive_ordinal);
	}
	return members;
}

static void assert_conserved(const std::vector<LMWorldspawnItem> &items, const LMWorldspawnPartitionResult &result) {
	assert(result);
	std::vector<int> expected_items, actual_items, expected_textures, actual_textures;
	int64_t expected_triangles = 0, actual_triangles = 0;
	for (const auto &item : items) {
		expected_items.push_back(item.primitive_ordinal);
		expected_triangles += item.visual_triangle_count;
		expected_textures.insert(expected_textures.end(), item.texture_indices.begin(), item.texture_indices.end());
	}
	for (const auto &chunk : result.chunks) {
		actual_triangles += chunk.visual_triangle_count;
		actual_textures.insert(actual_textures.end(), chunk.texture_indices.begin(), chunk.texture_indices.end());
		for (const auto &item : chunk.items) actual_items.push_back(item.primitive_ordinal);
	}
	auto normalize = [](auto &values) {
		std::sort(values.begin(), values.end());
		values.erase(std::unique(values.begin(), values.end()), values.end());
	};
	std::sort(expected_items.begin(), expected_items.end());
	std::sort(actual_items.begin(), actual_items.end());
	normalize(expected_textures);
	normalize(actual_textures);
	assert(actual_items == expected_items);
	assert(actual_triangles == expected_triangles);
	assert(actual_textures == expected_textures);
}

int main() {
	{
		auto map = generated(fixture("classic_cube"));
		const auto result = lm_extract_worldspawn_items(0, map->entities[0], map->entity_geo[0]);
		assert(result && result.items.size() == 1);
		const auto &cube = result.items[0];
		assert(cube.entity_index == 0 && cube.primitive_ordinal == 0 && cube.source_index == 0);
		assert(cube.kind == LMWorldspawnPrimitiveKind::BRUSH && cube.visual_triangle_count == 12);
		assert(cube.texture_indices.size() == 1 && cube.texture_indices[0] == map->entities[0].brushes[0].faces[0].texture_idx);
		equal_vec(cube.mins, {-16, -32, -8});
		equal_vec(cube.maxs, {48, 32, 24});
	}
	{
		auto map = generated(fixture("patches"));
		const auto result = lm_extract_worldspawn_items(7, map->entities[0], map->entity_geo[0]);
		assert(result && result.items.size() == 2);
		assert(result.items[0].entity_index == 7 && result.items[0].primitive_ordinal == 0 && result.items[0].source_index == 0);
		assert(result.items[1].primitive_ordinal == 1 && result.items[1].source_index == 1);
		assert(result.items[0].kind == LMWorldspawnPrimitiveKind::PATCH && result.items[0].visual_triangle_count == 32);
		assert(result.items[1].kind == LMWorldspawnPrimitiveKind::PATCH && result.items[1].visual_triangle_count == 48);
		equal_vec(result.items[0].mins, {-16.5, -16, 0});
		equal_vec(result.items[0].maxs, {16, 16, 6});
	}
	{
		auto map = generated(fixture("interleaved"));
		const auto result = lm_extract_worldspawn_items(0, map->entities[0], map->entity_geo[0]);
		assert(result && result.items.size() == 3);
		assert(result.items[0].kind == LMWorldspawnPrimitiveKind::BRUSH && result.items[0].source_index == 0);
		assert(result.items[1].kind == LMWorldspawnPrimitiveKind::PATCH && result.items[1].source_index == 0);
		assert(result.items[2].kind == LMWorldspawnPrimitiveKind::BRUSH && result.items[2].source_index == 1);
		for (int i = 0; i < 3; ++i) assert(result.items[i].primitive_ordinal == i);
		int64_t item_triangles = 0;
		for (const auto &item : result.items) item_triangles += item.visual_triangle_count;
		int64_t source_triangles = 0;
		for (int b = 0; b < map->entity_geo[0].brush_count; ++b)
			for (int f = 0; f < map->entity_geo[0].brushes[b].face_count; ++f)
				source_triangles += map->entity_geo[0].brushes[b].faces[f].index_count / 3;
		for (int p = 0; p < map->entity_geo[0].patch_count; ++p) source_triangles += map->entity_geo[0].patches[p].index_count / 3;
		assert(item_triangles == source_triangles);
		const int texture = map->entities[0].patches[0].texture_idx;
		assert(lm_extract_worldspawn_items(0, map->entities[0], map->entity_geo[0], {texture}).items.empty());
	}
	{
		LMMapEdit edit(*std::make_shared<LMMapData>());
		edit.world().primitives.push_back(lm_edit_cuboid({0, 0, 0}, {16, 16, 16}, "plan/first"));
		edit.world().primitives.push_back(lm_edit_cuboid({32, 0, 0}, {48, 16, 16}, "plan/second"));
		auto map = generated(edit.text());
		LMEntitySurfacePlan plan;
		assert(plan.build(*map, 0));
		assert(plan.entries.size() == 2);
		for (int texture = 0; texture < map->texture_count; ++texture) {
			LMSurfaceGatherer legacy(map);
			legacy.surface_gatherer_set_entity_index_filter(0);
			legacy.surface_gatherer_set_texture_filter(map->textures[texture].name);
			legacy.surface_gatherer_run();
			LMOwnedSurface combined;
			assert(plan.combine_texture(texture, combined));
			LMSurface actual = combined.view();
			assert(legacy.out_surfaces.surface_count == 1);
			const LMSurface &expected = legacy.out_surfaces.surfaces[0];
			assert(actual.vertex_count == expected.vertex_count && actual.index_count == expected.index_count);
			assert(std::memcmp(actual.vertices, expected.vertices, actual.vertex_count * sizeof(LMFaceVertex)) == 0);
			assert(std::memcmp(actual.indices, expected.indices, actual.index_count * sizeof(int)) == 0);
		}
		LMOwnedSurface selected;
		const int first_texture = map->map_data_find_texture("plan/first");
		assert(plan.combine_texture(first_texture, {{false, 0}}, selected));
		assert(selected.vertices.size() == 24 && selected.indices.size() == 36);
		assert(plan.combine_texture(first_texture, {{false, 1}}, selected) && selected.vertices.empty() && selected.indices.empty());
		assert(!plan.combine_texture(first_texture, {{false, 2}}, selected));
	}
	{
		LMMapEdit edit(*std::make_shared<LMMapData>());
		for (int i = 0; i < 3; ++i)
			edit.world().primitives.push_back(lm_edit_cuboid({double(i * 16), 0, 0}, {double(i * 16 + 8), 8, 8}, "plan/arbitrary"));
		auto map = generated(edit.text());
		LMEntitySurfacePlan plan;
		assert(plan.build(*map, 0));
		const int texture = map->map_data_find_texture("plan/arbitrary");
		LMOwnedSurface first, third, arbitrary;
		assert(plan.combine_texture(texture, {{false, 0}}, first));
		assert(plan.combine_texture(texture, {{false, 2}}, third));
		assert(plan.combine_texture(texture, {{false, 2}, {false, 0}}, arbitrary));
		assert(arbitrary.vertices.size() == third.vertices.size() + first.vertices.size());
		assert(arbitrary.indices.size() == third.indices.size() + first.indices.size());
		assert(std::memcmp(arbitrary.vertices.data(), third.vertices.data(), third.vertices.size() * sizeof(LMFaceVertex)) == 0);
		assert(std::memcmp(arbitrary.vertices.data() + third.vertices.size(), first.vertices.data(), first.vertices.size() * sizeof(LMFaceVertex)) == 0);
		for (size_t i = 0; i < third.indices.size(); ++i) assert(arbitrary.indices[i] == third.indices[i]);
		for (size_t i = 0; i < first.indices.size(); ++i)
			assert(arbitrary.indices[third.indices.size() + i] == first.indices[i] + static_cast<int>(third.vertices.size()));
	}
	{
		auto map = generated(fixture("interleaved"));
		const auto extraction = lm_extract_worldspawn_items(0, map->entities[0], map->entity_geo[0]);
		assert(extraction && extraction.items.size() == 3);
		LMEntitySurfacePlan plan;
		assert(plan.build(*map, 0));
		int64_t selected_triangles = 0;
		for (int texture = 0; texture < map->texture_count; ++texture) {
			LMOwnedSurface selected;
			assert(plan.combine_texture(texture, {{true, 0}, {false, 1}}, selected));
			selected_triangles += selected.indices.size() / 3;
		}
		assert(selected_triangles == extraction.items[1].visual_triangle_count + extraction.items[2].visual_triangle_count);
	}
	{
		LMMapEdit edit(*std::make_shared<LMMapData>());
		edit.world().set_property("_phong", "1");
		edit.world().set_property("soft", "1");
		edit.world().primitives.push_back(lm_edit_cuboid({0, 0, 0}, {8, 8, 8}, "plan/smooth"));
		edit.world().primitives.push_back(lm_edit_cuboid({8, 0, 0}, {16, 8, 8}, "plan/smooth"));
		auto map = generated(edit.text());
		assert(map->entities[0].get_property_int("_phong", 0) == 1 && map->entities[0].has_property("soft"));
		LMEntitySurfacePlan plan;
		assert(plan.build(*map, 0));
		std::vector<vec3> source_normals;
		for (const auto &entry : plan.entries)
			for (const auto &vertex : entry.surface.vertices) source_normals.push_back(vertex.normal);
		assert(plan.smooth_normals_by_texture());
		bool changed_from_phong_source = false;
		size_t normal_index = 0;
		for (const auto &entry : plan.entries) {
			for (const auto &vertex : entry.surface.vertices) {
				if (!vec3_equals(vertex.normal, source_normals[normal_index])) changed_from_phong_source = true;
				++normal_index;
			}
		}
		assert(changed_from_phong_source);
		assert(plan.regenerate_tangents());
		const int texture = map->map_data_find_texture("plan/smooth");
		LMOwnedSurface left, right;
		assert(plan.combine_texture(texture, {{false, 0}}, left));
		assert(plan.combine_texture(texture, {{false, 1}}, right));
		int shared = 0;
		for (const LMFaceVertex &a : left.vertices) {
			for (const LMFaceVertex &b : right.vertices) {
				if (!vec3_equals(a.vertex, b.vertex) || std::abs(a.uv.u - b.uv.u) > 1e-9 || std::abs(a.uv.v - b.uv.v) > 1e-9) continue;
				if (!vec3_equals({a.tangent.x, a.tangent.y, a.tangent.z}, {b.tangent.x, b.tangent.y, b.tangent.z}) ||
						std::abs(a.tangent.w - b.tangent.w) >= 1e-9) continue;
				equal_vec(a.normal, b.normal);
				++shared;
				break;
			}
		}
		assert(shared > 0);
	}
	{
		LMEntitySurfacePlan plan;
		LMEntitySurfacePlanEntry hard;
		hard.texture_index = 0;
		hard.surface.vertices.resize(6);
		hard.surface.indices = {0, 1, 2, 3, 4, 5};
		hard.surface.vertices[0] = {{0, 0, 0}, {0, 0, 1}, {0, 0}, {1, 0, 0, 1}};
		hard.surface.vertices[1] = {{1, 0, 0}, {0, 0, 1}, {1, 0}, {1, 0, 0, 1}};
		hard.surface.vertices[2] = {{0, 1, 0}, {0, 0, 1}, {0, 1}, {1, 0, 0, 1}};
		hard.surface.vertices[3] = {{0, 0, 0}, {1, 0, 0}, {0, 0}, {0, 1, 0, 1}};
		hard.surface.vertices[4] = {{0, 1, 0}, {1, 0, 0}, {1, 0}, {0, 1, 0, 1}};
		hard.surface.vertices[5] = {{0, 0, 1}, {1, 0, 0}, {0, 1}, {0, 1, 0, 1}};
		plan.entries.push_back(hard);
		assert(plan.regenerate_tangents());
		const auto &hard_result = plan.entries[0].surface.vertices;
		assert(vec3_equals(hard_result[0].vertex, hard_result[3].vertex));
		assert(std::abs(hard_result[0].uv.u - hard_result[3].uv.u) < 1e-9 && std::abs(hard_result[0].uv.v - hard_result[3].uv.v) < 1e-9);
		assert(!vec3_equals({hard_result[0].tangent.x, hard_result[0].tangent.y, hard_result[0].tangent.z},
				{hard_result[3].tangent.x, hard_result[3].tangent.y, hard_result[3].tangent.z}));

		LMEntitySurfacePlan mirrored;
		LMEntitySurfacePlanEntry mirror;
		mirror.texture_index = 0;
		mirror.surface.vertices.resize(6);
		mirror.surface.indices = {0, 1, 2, 3, 4, 5};
		for (int i = 0; i < 6; ++i) mirror.surface.vertices[i].normal = {0, 0, 1};
		mirror.surface.vertices[0].vertex = mirror.surface.vertices[3].vertex = {0, 0, 0};
		mirror.surface.vertices[1].vertex = mirror.surface.vertices[4].vertex = {1, 0, 0};
		mirror.surface.vertices[2].vertex = mirror.surface.vertices[5].vertex = {0, 1, 0};
		mirror.surface.vertices[0].uv = mirror.surface.vertices[3].uv = {0, 0};
		mirror.surface.vertices[1].uv = {1, 0}; mirror.surface.vertices[2].uv = {0, 1};
		mirror.surface.vertices[4].uv = {-1, 0}; mirror.surface.vertices[5].uv = {0, 1};
		mirrored.entries.push_back(mirror);
		assert(mirrored.regenerate_tangents());
		const auto &mirror_result = mirrored.entries[0].surface.vertices;
		assert(mirror_result[0].tangent.x > 0.9 && mirror_result[3].tangent.x < -0.9);
		assert(mirror_result[0].tangent.w == -mirror_result[3].tangent.w);
	}
	{
		auto map = generated(fixture("classic_cube"));
		LMFaceGeometry &face = map->entity_geo[0].brushes[0].faces[0];
		const int vertex_count = face.vertex_count;
		face.vertex_count = INT_MAX;
		LMEntitySurfacePlan overflow;
		assert(!overflow.build(*map, 0));
		face.vertex_count = vertex_count;
		const int index = face.indices[0];
		face.indices[0] = face.vertex_count;
		assert(!overflow.build(*map, 0));
		face.indices[0] = index;
	}
	{
		LMMapEdit edit(*std::make_shared<LMMapData>());
		const std::vector<std::string> hidden = {
			"common/hint_skip", "common/player_clip", "common/ladder_clip",
			"common/cushion_clip", "common/nowalljump_clip"
		};
		for (size_t i = 0; i < hidden.size(); ++i)
			edit.world().primitives.push_back(lm_edit_cuboid({double(i * 32), 0, 0}, {double(i * 32 + 16), 16, 16}, hidden[i]));
		auto visible = lm_edit_cuboid({192, 0, 0}, {208, 16, 16}, "visual/z");
		visible.faces[1].texture = "visual/a";
		visible.faces[2].texture = "visual/z";
		edit.world().primitives.push_back(visible);
		auto map = generated(edit.text());
		const auto exclusions = texture_indices(*map, hidden);
		const auto result = lm_extract_worldspawn_items(0, map->entities[0], map->entity_geo[0], exclusions);
		assert(result && result.items.size() == 1 && result.items[0].source_index == 5);
		assert(result.items[0].texture_indices.size() == 2);
		assert(std::is_sorted(result.items[0].texture_indices.begin(), result.items[0].texture_indices.end()));
		assert(result.items[0].visual_triangle_count == 12);
	}
	{
		LMFaceVertex vertices[3] = {};
		vertices[0].vertex = {4, 4, 4};
		vertices[1].vertex = {4, 4, 4};
		vertices[2].vertex = {4, 4, 4};
		int indices[] = {0, 1, 2};
		LMPatch patch; patch.texture_idx = 3;
		LMPatchGeometry patch_geometry; patch_geometry.vertex_count = 3; patch_geometry.vertices = vertices; patch_geometry.index_count = 3; patch_geometry.indices = indices;
		LMPrimitive primitive{true, 0};
		LMEntity entity; entity.primitive_count = 1; entity.primitives = &primitive; entity.patch_count = 1; entity.patches = &patch;
		LMEntityGeometry geometry; geometry.patch_count = 1; geometry.patches = &patch_geometry;
		const auto degenerate = lm_extract_worldspawn_items(2, entity, geometry);
		assert(degenerate && degenerate.items.size() == 1 && degenerate.items[0].visual_triangle_count == 1);
		equal_vec(degenerate.items[0].mins, {4, 4, 4});
		equal_vec(degenerate.items[0].maxs, {4, 4, 4});
		patch_geometry.index_count = 0; patch_geometry.indices = nullptr;
		assert(lm_extract_worldspawn_items(2, entity, geometry).items.empty());
		patch_geometry.index_count = 3; patch_geometry.indices = indices;
		vertices[1].vertex.x = std::numeric_limits<double>::infinity();
		const auto nonfinite = lm_extract_worldspawn_items(2, entity, geometry);
		assert(!nonfinite && nonfinite.status == LMWorldspawnExtractionStatus::NONFINITE_GEOMETRY && nonfinite.items.empty());
		vertices[1].vertex.x = 4;
		indices[2] = 3;
		const auto malformed = lm_extract_worldspawn_items(2, entity, geometry);
		assert(!malformed && malformed.status == LMWorldspawnExtractionStatus::INVALID_GEOMETRY && malformed.items.empty());
	}
	{
		LMFaceVertex visual_vertices[3] = {}, excluded_vertices[3] = {};
		visual_vertices[0].vertex = {0, 0, 0}; visual_vertices[1].vertex = {1, 0, 0}; visual_vertices[2].vertex = {0, 1, 0};
		excluded_vertices[0].vertex = {100, 100, 100}; excluded_vertices[1].vertex = {101, 100, 100}; excluded_vertices[2].vertex = {100, 101, 100};
		int indices[] = {0, 1, 2};
		LMFace faces[2] = {}; faces[0].texture_idx = 9; faces[1].texture_idx = 4;
		LMFaceGeometry face_geometry[2] = {};
		face_geometry[0] = {3, visual_vertices, 3, indices};
		face_geometry[1] = {3, excluded_vertices, 3, indices};
		LMBrush brush; brush.face_count = 2; brush.faces = faces;
		LMBrushGeometry brush_geometry; brush_geometry.face_count = 2; brush_geometry.faces = face_geometry;
		LMPrimitive primitive{false, 0};
		LMEntity entity; entity.primitive_count = 1; entity.primitives = &primitive; entity.brush_count = 1; entity.brushes = &brush;
		LMEntityGeometry geometry; geometry.brush_count = 1; geometry.brushes = &brush_geometry;
		const auto result = lm_extract_worldspawn_items(0, entity, geometry, {4});
		assert(result && result.items.size() == 1 && result.items[0].visual_triangle_count == 1);
		assert(result.items[0].texture_indices == std::vector<int>{9});
		equal_vec(result.items[0].mins, {0, 0, 0}); equal_vec(result.items[0].maxs, {1, 1, 0});
		entity.primitives[0].index = 1;
		assert(lm_extract_worldspawn_items(0, entity, geometry).status == LMWorldspawnExtractionStatus::INVALID_SOURCE);
	}
	{
		const std::vector<LMWorldspawnItem> items = {
			partition_item(0, {0, 0, 0}, {1, 1, 1}, 2, {1, 3}),
			partition_item(1, {2, 0, 0}, {3, 1, 1}, 2, {3}),
			partition_item(2, {100, 0, 0}, {101, 1, 1}, 2, {2}),
			partition_item(3, {102, 0, 0}, {103, 1, 1}, 2, {1, 2}),
		};
		const auto result = lm_partition_worldspawn_items(items, {10, 100});
		assert_conserved(items, result);
		assert(chunk_members(result) == std::vector<std::vector<int>>({{0, 1}, {2, 3}}));
		assert(result.chunks[0].texture_indices == std::vector<int>({1, 3}));
		assert(result.chunks[1].texture_indices == std::vector<int>({1, 2}));
	}
	{
		const std::vector<LMWorldspawnItem> items = {
			partition_item(0, {0, 0, 0}, {1, 1, 1}, 5),
			partition_item(1, {3, 0, 0}, {4, 1, 1}, 5),
		};
		assert(lm_partition_worldspawn_items(items, {4, 10}).chunks.size() == 1);
		assert(lm_partition_worldspawn_items(items, {3.99, 10}).chunks.size() == 2);
		assert(lm_partition_worldspawn_items(items, {4, 9}).chunks.size() == 2);
	}
	{
		const std::vector<LMWorldspawnItem> items = {
			partition_item(0, {-100, -1, 0}, {100, 1, 0}, 20, {4}),
			partition_item(1, {-12, -1, 0}, {-10, 1, 0}, 2, {5}),
			partition_item(2, {10, -1, 0}, {12, 1, 0}, 2, {6}),
		};
		const auto result = lm_partition_worldspawn_items(items, {20, 10});
		assert_conserved(items, result);
		assert(result.chunks.size() >= 2);
		for (const auto &chunk : result.chunks)
			for (const auto &item : chunk.items)
				if (item.primitive_ordinal == 0) {
					equal_vec(item.mins, {-100, -1, 0});
					equal_vec(item.maxs, {100, 1, 0});
				}
	}
	{
		const std::vector<LMWorldspawnItem> flat = {
			partition_item(0, {0, 0, 7}, {1, 1, 7}),
			partition_item(1, {100, 0, 7}, {101, 1, 7}),
		};
		assert(chunk_members(lm_partition_worldspawn_items(flat, {10, 100})) == std::vector<std::vector<int>>({{0}, {1}}));
		const std::vector<LMWorldspawnItem> points = {
			partition_item(0, {0, 0, 0}, {0, 0, 0}),
			partition_item(1, {10, 0, 0}, {10, 0, 0}),
		};
		assert(chunk_members(lm_partition_worldspawn_items(points, {1, 100})) == std::vector<std::vector<int>>({{0}, {1}}));
		const std::vector<LMWorldspawnItem> coincident = {
			partition_item(0, {4, 4, 4}, {4, 4, 4}, 100),
			partition_item(1, {4, 4, 4}, {4, 4, 4}, 100),
		};
		assert(lm_partition_worldspawn_items(coincident, {1, 1}).chunks.size() == 1);
	}
	{
		std::vector<LMWorldspawnItem> items = {
			partition_item(0, {-10, -10, 0}, {-9, -9, 1}),
			partition_item(1, {-10, 10, 0}, {-9, 11, 1}),
			partition_item(2, {10, -10, 0}, {11, -9, 1}),
			partition_item(3, {10, 10, 0}, {11, 11, 1}),
		};
		const auto expected = lm_partition_worldspawn_items(items, {100, 2});
		assert(chunk_members(expected) == std::vector<std::vector<int>>({{0, 1}, {2, 3}})); // X wins an exact axis tie.
		do {
			assert(chunk_members(lm_partition_worldspawn_items(items, {100, 2})) == chunk_members(expected));
		} while (std::next_permutation(items.begin(), items.end(), [](const auto &left, const auto &right) {
			return left.primitive_ordinal < right.primitive_ordinal;
		}));
		const std::vector<LMWorldspawnItem> split_tie = {
			partition_item(0, {-8.5, -0.5, -0.5}, {-7.5, 0.5, 0.5}),
			partition_item(1, {-0.5, -0.5, -0.5}, {0.5, 0.5, 0.5}),
			partition_item(2, {7.5, -0.5, -0.5}, {8.5, 0.5, 0.5}),
		};
		// The symmetric candidates tie. The lower plane is chosen and the item
		// centered exactly on that plane is assigned to the right.
		assert(chunk_members(lm_partition_worldspawn_items(split_tie, {100, 2})) ==
				std::vector<std::vector<int>>({{0}, {1, 2}}));
	}
	{
		const double base = 1e300;
		const double offset = 1e290;
		const std::vector<LMWorldspawnItem> items = {
			partition_item(0, {base, base, base}, {base + offset, base + offset, base + offset}, 3),
			partition_item(1, {base + 10 * offset, base, base}, {base + 11 * offset, base + offset, base + offset}, 3),
		};
		const auto result = lm_partition_worldspawn_items(items, {5 * offset, 100});
		assert_conserved(items, result);
		assert(result.chunks.size() == 2);
	}
	{
		const std::vector<LMWorldspawnItem> items = {
			partition_item(0, {0, 0, 0}, {20, 2, 2}, 2),
			partition_item(1, {5, 0, 0}, {6, 1, 1}, 2),
		};
		const auto result = lm_partition_worldspawn_items(items, {10, 10, 10});
		assert_conserved(items, result);
		assert(chunk_members(result) == std::vector<std::vector<int>>({{0}, {1}}));
		assert(result.oversized_item_count == 1 && result.isolated_oversized_item_count == 1);
		assert(result.chunks_with_unmet_soft_limits == 1);
	}
	{
		const std::vector<LMWorldspawnItem> nearby = {
			partition_item(0, {0, 0, 0}, {1, 1, 1}, 11),
			partition_item(1, {1.1, 0, 0}, {2.1, 1, 1}, 11),
		};
		const auto grouped = lm_partition_worldspawn_items(nearby, {10, 10, 10});
		assert_conserved(nearby, grouped);
		assert(chunk_members(grouped) == std::vector<std::vector<int>>({{0, 1}}));
		assert(grouped.oversized_item_count == 2 && grouped.isolated_oversized_item_count == 0);
		assert(grouped.chunks_with_unmet_soft_limits == 1);
		auto distant = nearby;
		distant[1].mins.x = 100;
		distant[1].maxs.x = 101;
		const auto isolated = lm_partition_worldspawn_items(distant, {10, 10, 10});
		assert(chunk_members(isolated) == std::vector<std::vector<int>>({{0}, {1}}));
		assert(isolated.oversized_item_count == 2 && isolated.isolated_oversized_item_count == 2);
		assert(isolated.budget_merge_count == 0 && isolated.forced_nonadjacent_merge_count == 0);
	}
	{
		std::vector<LMWorldspawnItem> chain;
		for (int i = 0; i < 20; ++i)
			chain.push_back(partition_item(i, {double(i), 0, 0}, {double(i + 1), 1, 1}, 11));
		const auto result = lm_partition_worldspawn_items(chain, {10, 10, 20});
		assert_conserved(chain, result);
		assert(result.oversized_item_count == 20);
		assert(result.chunks.size() >= 5 && result.chunks.size() < chain.size());
		for (const auto &chunk : result.chunks) assert(chunk.maxs.x - chunk.mins.x <= 3.5);
	}
	{
		const std::vector<LMWorldspawnItem> items = {
			partition_item(0, {0, 0, 0}, {1, 1, 0}, 5),
			partition_item(1, {1, 0, 0}, {2, 1, 0}, 1),
			partition_item(2, {2, 0, 0}, {3, 1, 0}, 1),
			partition_item(3, {3, 0, 0}, {4, 1, 0}, 5),
		};
		const auto result = lm_partition_worldspawn_items(items, {10, 5, 10});
		assert_conserved(items, result);
		assert(chunk_members(result) == std::vector<std::vector<int>>({{0}, {1, 2}, {3}}));
		assert(result.sparse_merge_count == 1 && result.budget_merge_count == 0);
		assert(result.chunks_with_unmet_soft_limits == 0);
	}
	{
		std::vector<LMWorldspawnItem> items = {
			partition_item(0, {-31, 0, 0}, {-30, 1, 1}),
			partition_item(1, {-11, 0, 0}, {-10, 1, 1}),
			partition_item(2, {10, 0, 0}, {11, 1, 1}),
			partition_item(3, {30, 0, 0}, {31, 1, 1}),
		};
		const auto expected = lm_partition_worldspawn_items(items, {2, 10, 2});
		assert_conserved(items, expected);
		assert(expected.chunks.size() == 2 && expected.budget_merge_count == 0);
		assert(chunk_members(expected) == std::vector<std::vector<int>>({{0, 1}, {2, 3}}));
		assert(expected.forced_nonadjacent_merge_count == 0);
		do {
			const auto permuted = lm_partition_worldspawn_items(items, {2, 10, 2});
			assert(chunk_members(permuted) == chunk_members(expected));
			assert(permuted.budget_merge_count == expected.budget_merge_count);
			assert(permuted.forced_nonadjacent_merge_count == expected.forced_nonadjacent_merge_count);
		} while (std::next_permutation(items.begin(), items.end(), [](const auto &left, const auto &right) {
			return left.primitive_ordinal < right.primitive_ordinal;
		}));
	}
	{
		const std::vector<LMWorldspawnItem> items = {
			partition_item(0, {0, 0, 0}, {1, 1, 1}, 11),
			partition_item(1, {1, 0, 0}, {2, 100, 1}, 11),
			partition_item(2, {3, 0, 0}, {4, 1, 1}, 11),
		};
		const auto result = lm_partition_worldspawn_items(items, {10, 10, 2});
		assert_conserved(items, result);
		assert(chunk_members(result) == std::vector<std::vector<int>>({{0, 2}, {1}}));
		assert(result.budget_merge_count == 1 && result.forced_nonadjacent_merge_count == 1);
		assert(result.oversized_item_count == 3 && result.isolated_oversized_item_count == 1);
	}
	{
		std::vector<LMWorldspawnItem> items;
		for (int i = 0; i < 32; ++i)
			items.push_back(partition_item(i, {double(i * 10), 0, 0}, {double(i * 10 + 1), 1, 1}));
		const auto capped = lm_partition_worldspawn_items(items, {2, 100, 4});
		assert_conserved(items, capped);
		assert(capped.chunks.size() == 4 && capped.budget_merge_count == 0);

		items.push_back(partition_item(32, {-100, 0, 0}, {-80, 1, 1}));
		const auto with_oversized = lm_partition_worldspawn_items(items, {2, 100, 4});
		assert_conserved(items, with_oversized);
		assert(with_oversized.chunks.size() == 4 && with_oversized.budget_merge_count == 0);
		assert(with_oversized.oversized_item_count == 1 && with_oversized.isolated_oversized_item_count == 1);
	}
	{
		const std::vector<LMWorldspawnItem> items = {
			partition_item(0, {0, 0, 4}, {1, 1, 4}, 11),
			partition_item(1, {100, 0, 4}, {101, 1, 4}, 11),
		};
		const auto result = lm_partition_worldspawn_items(items, {10, 10, 1});
		assert_conserved(items, result);
		assert(chunk_members(result) == std::vector<std::vector<int>>({{0, 1}}));
		assert(result.budget_merge_count == 1 && result.forced_nonadjacent_merge_count == 1);
		assert(result.chunks_with_unmet_soft_limits == 1);
	}
	{
		const std::vector<LMWorldspawnItem> touching_flat = {
			partition_item(0, {0, 0, 7}, {10, 0, 7}),
			partition_item(1, {5, -5, 7}, {5, 5, 7}),
		};
		const auto result = lm_partition_worldspawn_items(touching_flat, {5, 5, 1});
		assert_conserved(touching_flat, result);
		assert(result.chunks.size() == 1 && result.budget_merge_count == 1);
		assert(result.forced_nonadjacent_merge_count == 0);
		assert(result.oversized_item_count == 2 && result.isolated_oversized_item_count == 0);
		assert(result.chunks_with_unmet_soft_limits == 1);
	}
	{
		const std::vector<LMWorldspawnItem> item = {partition_item(0, {0, 0, 0}, {1, 1, 1})};
		assert(lm_partition_worldspawn_items({}, {1, 1}).chunks.empty());
		for (double extent : {0.0, -1.0, std::numeric_limits<double>::infinity(), std::numeric_limits<double>::quiet_NaN()})
			assert(lm_partition_worldspawn_items(item, {extent, 1}).status == LMWorldspawnPartitionStatus::INVALID_SETTINGS);
		assert(lm_partition_worldspawn_items(item, {1, 0}).status == LMWorldspawnPartitionStatus::INVALID_SETTINGS);
		assert(lm_partition_worldspawn_items(item, {1, 1, 0}).status == LMWorldspawnPartitionStatus::INVALID_SETTINGS);
		assert(lm_partition_worldspawn_items(item, {1, 1, -1}).status == LMWorldspawnPartitionStatus::INVALID_SETTINGS);
		auto invalid = item;
		invalid[0].mins.x = std::numeric_limits<double>::infinity();
		assert(lm_partition_worldspawn_items(invalid, {1, 1}).status == LMWorldspawnPartitionStatus::INVALID_ITEM);
		invalid = item;
		invalid.push_back(item[0]);
		assert(lm_partition_worldspawn_items(invalid, {1, 1}).status == LMWorldspawnPartitionStatus::INVALID_ITEM);
		const std::vector<LMWorldspawnItem> triangle_overflow = {
			partition_item(0, {0, 0, 0}, {1, 1, 1}, std::numeric_limits<int64_t>::max()),
			partition_item(1, {2, 0, 0}, {3, 1, 1}, 1),
		};
		assert(lm_partition_worldspawn_items(triangle_overflow, {1, 1}).status ==
				LMWorldspawnPartitionStatus::CAPACITY_EXCEEDED);
		const double maximum = std::numeric_limits<double>::max();
		const std::vector<LMWorldspawnItem> derived_extent_overflow = {
			partition_item(0, {-maximum, 0, 0}, {maximum, 1, 1}),
		};
		assert(lm_partition_worldspawn_items(derived_extent_overflow, {1, 1}).status ==
				LMWorldspawnPartitionStatus::CAPACITY_EXCEEDED);
	}
	std::cout << "WORLDSPAWN_PARTITIONER_PASS\n";
}
