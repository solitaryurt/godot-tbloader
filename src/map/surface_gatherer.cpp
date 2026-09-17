#include "surface_gatherer.h"

#include <stdint.h>
#include <cmath>
#include <climits>
#include <limits>
#include <map>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "brush.h"
#include "entity.h"
#include "face.h"
#include "map_data.h"
#include "patch.h"

namespace {
struct PositionKey {
	double x;
	double y;
	double z;

	bool operator<(const PositionKey &other) const {
		if (x != other.x) return x < other.x;
		if (y != other.y) return y < other.y;
		return z < other.z;
	}
};

bool checked_append_sizes(const LMOwnedSurface &output, size_t vertex_count, size_t index_count) {
	return output.vertices.size() <= static_cast<size_t>(INT_MAX) && vertex_count <= static_cast<size_t>(INT_MAX) - output.vertices.size() &&
			output.indices.size() <= static_cast<size_t>(INT_MAX) && index_count <= static_cast<size_t>(INT_MAX) - output.indices.size() &&
			vertex_count <= output.vertices.max_size() - output.vertices.size() &&
			index_count <= output.indices.max_size() - output.indices.size();
}

bool append_geometry(LMOwnedSurface &output, const LMFaceVertex *vertices, int vertex_count, const int *indices, int index_count, const LMEntity &entity) {
	if (vertex_count < 0 || index_count < 0 || (vertex_count > 0 && !vertices) || (index_count > 0 && !indices) ||
			!checked_append_sizes(output, static_cast<size_t>(vertex_count), static_cast<size_t>(index_count))) return false;
	const int index_offset = static_cast<int>(output.vertices.size());
	for (int i = 0; i < index_count; ++i)
		if (indices[i] < 0 || indices[i] >= vertex_count || indices[i] > INT_MAX - index_offset) return false;
	output.vertices.reserve(output.vertices.size() + static_cast<size_t>(vertex_count));
	output.indices.reserve(output.indices.size() + static_cast<size_t>(index_count));
	for (int i = 0; i < vertex_count; ++i) {
		LMFaceVertex vertex = vertices[i];
		if (entity.spawn_type == EST_ENTITY || entity.spawn_type == EST_GROUP) vertex.vertex = vec3_sub(vertex.vertex, entity.center);
		output.vertices.push_back(vertex);
	}
	for (int i = 0; i < index_count; ++i) output.indices.push_back(indices[i] + index_offset);
	return true;
}

bool append_owned(LMOwnedSurface &output, const LMOwnedSurface &source) {
	if (!checked_append_sizes(output, source.vertices.size(), source.indices.size())) return false;
	const int index_offset = static_cast<int>(output.vertices.size());
	for (int index : source.indices)
		if (index < 0 || static_cast<size_t>(index) >= source.vertices.size() || index > INT_MAX - index_offset) return false;
	output.vertices.insert(output.vertices.end(), source.vertices.begin(), source.vertices.end());
	output.indices.reserve(output.indices.size() + source.indices.size());
	for (int index : source.indices) output.indices.push_back(index + index_offset);
	return true;
}
}

LMSurface LMOwnedSurface::view() {
	LMSurface result;
	result.vertex_count = static_cast<int>(vertices.size());
	result.vertices = vertices.empty() ? nullptr : vertices.data();
	result.index_count = static_cast<int>(indices.size());
	result.indices = indices.empty() ? nullptr : indices.data();
	return result;
}

void LMOwnedSurface::clear() {
	vertices.clear();
	indices.clear();
}

bool LMEntitySurfacePlan::build(const LMMapData &map, int entity_index) {
	entries.clear();
	texture_entries.clear();
	brush_entries.clear();
	patch_entries.clear();
	if (entity_index < 0 || entity_index >= map.entity_count || entity_index >= map.geometry_entity_count ||
			map.entities == nullptr || map.entity_geo == nullptr || map.texture_count < 0) return false;
	const LMEntity &entity = map.entities[entity_index];
	const LMEntityGeometry &geometry = map.entity_geo[entity_index];
	if (entity.primitive_count < 0 || entity.primitive_count != entity.brush_count + entity.patch_count ||
			(entity.primitive_count > 0 && !entity.primitives) || entity.brush_count < 0 || entity.patch_count < 0 ||
			geometry.brush_count != entity.brush_count || geometry.patch_count != entity.patch_count ||
			(entity.brush_count > 0 && (!entity.brushes || !geometry.brushes)) ||
			(entity.patch_count > 0 && (!entity.patches || !geometry.patches))) return false;

	texture_entries.resize(map.texture_count);
	brush_entries.resize(entity.brush_count);
	patch_entries.resize(entity.patch_count);
	std::vector<int> brush_ordinals(entity.brush_count, -1);
	std::vector<int> patch_ordinals(entity.patch_count, -1);
	for (int ordinal = 0; ordinal < entity.primitive_count; ++ordinal) {
		const LMPrimitive primitive = entity.primitives[ordinal];
		if (primitive.is_patch) {
			if (primitive.index < 0 || primitive.index >= entity.patch_count || patch_ordinals[primitive.index] != -1) return false;
			patch_ordinals[primitive.index] = ordinal;
		} else {
			if (primitive.index < 0 || primitive.index >= entity.brush_count || brush_ordinals[primitive.index] != -1) return false;
			brush_ordinals[primitive.index] = ordinal;
		}
	}

	auto entry_for = [&](bool is_patch, int source_index, int texture_index, int ordinal) -> LMEntitySurfacePlanEntry * {
		if (texture_index < 0 || texture_index >= map.texture_count) return nullptr;
		auto &primitive_entries = is_patch ? patch_entries[source_index] : brush_entries[source_index];
		for (size_t entry_index : primitive_entries) {
			if (entries[entry_index].texture_index == texture_index) return &entries[entry_index];
		}
		const size_t entry_index = entries.size();
		entries.push_back({ { is_patch, source_index }, ordinal, texture_index, {} });
		primitive_entries.push_back(entry_index);
		texture_entries[texture_index].push_back(entry_index);
		return &entries.back();
	};

	// Keep legacy surface array order: brush array order, then patch array order.
	for (int brush_index = 0; brush_index < entity.brush_count; ++brush_index) {
		const LMBrush &brush = entity.brushes[brush_index];
		const LMBrushGeometry &brush_geometry = geometry.brushes[brush_index];
		if (brush.face_count < 0 || brush_geometry.face_count != brush.face_count ||
				(brush.face_count > 0 && (!brush.faces || !brush_geometry.faces))) return false;
		for (int face_index = 0; face_index < brush.face_count; ++face_index) {
			const LMFaceGeometry &face = brush_geometry.faces[face_index];
			if (face.vertex_count < 3) continue;
			const int64_t required_indices = (static_cast<int64_t>(face.vertex_count) - 2) * 3;
			if (required_indices > INT_MAX || !face.vertices || !face.indices || face.index_count < required_indices) return false;
			const int index_count = static_cast<int>(required_indices);
			LMEntitySurfacePlanEntry *entry = entry_for(false, brush_index, brush.faces[face_index].texture_idx, brush_ordinals[brush_index]);
			if (!entry) return false;
			if (!append_geometry(entry->surface, face.vertices, face.vertex_count, face.indices, index_count, entity)) return false;
		}
	}
	for (int patch_index = 0; patch_index < entity.patch_count; ++patch_index) {
		const LMPatch &patch = entity.patches[patch_index];
		const LMPatchGeometry &mesh = geometry.patches[patch_index];
		if (mesh.vertex_count < 3) continue;
		if (mesh.index_count < 0 || !mesh.vertices || (mesh.index_count > 0 && !mesh.indices)) return false;
		LMEntitySurfacePlanEntry *entry = entry_for(true, patch_index, patch.texture_idx, patch_ordinals[patch_index]);
		if (!entry) return false;
		if (!append_geometry(entry->surface, mesh.vertices, mesh.vertex_count, mesh.indices, mesh.index_count, entity)) return false;
	}
	return true;
}

bool LMEntitySurfacePlan::regenerate_tangents() {
	for (LMEntitySurfacePlanEntry &entry : entries) {
		auto &surface = entry.surface;
		if (surface.indices.size() % 3 != 0) return false;
		std::vector<vec3> tangent_sums(surface.vertices.size(), {0, 0, 0});
		std::vector<vec3> bitangent_sums(surface.vertices.size(), {0, 0, 0});
		for (size_t i = 0; i < surface.indices.size(); i += 3) {
			const int a = surface.indices[i], b = surface.indices[i + 1], c = surface.indices[i + 2];
			if (a < 0 || b < 0 || c < 0 || static_cast<size_t>(a) >= surface.vertices.size() ||
					static_cast<size_t>(b) >= surface.vertices.size() || static_cast<size_t>(c) >= surface.vertices.size()) return false;
			const LMFaceVertex &va = surface.vertices[a], &vb = surface.vertices[b], &vc = surface.vertices[c];
			const vec3 edge1 = vec3_sub(vb.vertex, va.vertex), edge2 = vec3_sub(vc.vertex, va.vertex);
			const double du1 = vb.uv.u - va.uv.u, dv1 = vb.uv.v - va.uv.v;
			const double du2 = vc.uv.u - va.uv.u, dv2 = vc.uv.v - va.uv.v;
			const double determinant = du1 * dv2 - dv1 * du2;
			if (!std::isfinite(determinant)) return false;
			if (std::abs(determinant) < 1e-12) continue;
			const vec3 tangent = vec3_div_double(vec3_sub(vec3_mul_double(edge1, dv2), vec3_mul_double(edge2, dv1)), determinant);
			const vec3 bitangent = vec3_div_double(vec3_sub(vec3_mul_double(edge2, du1), vec3_mul_double(edge1, du2)), determinant);
			for (int index : {a, b, c}) {
				tangent_sums[index] = vec3_add(tangent_sums[index], tangent);
				bitangent_sums[index] = vec3_add(bitangent_sums[index], bitangent);
			}
		}
		for (size_t i = 0; i < surface.vertices.size(); ++i) {
			LMFaceVertex &vertex = surface.vertices[i];
			vec3 normal = vec3_normalize(vertex.normal);
			vec3 tangent = vec3_sub(tangent_sums[i], vec3_mul_double(normal, vec3_dot(normal, tangent_sums[i])));
			bool used_previous = false;
			if (vec3_sqlen(tangent) < 1e-12) {
				tangent = vec3_sub({vertex.tangent.x, vertex.tangent.y, vertex.tangent.z},
						vec3_mul_double(normal, vec3_dot(normal, {vertex.tangent.x, vertex.tangent.y, vertex.tangent.z})));
				used_previous = vec3_sqlen(tangent) >= 1e-12;
			}
			if (vec3_sqlen(tangent) < 1e-12) tangent = vec3_cross(normal, std::abs(normal.y) < 0.99 ? vec3{0, 1, 0} : vec3{1, 0, 0});
			const double tangent_length = vec3_length(tangent);
			if (!std::isfinite(tangent_length) || tangent_length <= 0.0) return false;
			tangent = vec3_div_double(tangent, tangent_length);
			const double handedness = used_previous && vec3_sqlen(bitangent_sums[i]) < 1e-12 ? vertex.tangent.w :
					(vec3_dot(vec3_cross(normal, tangent), bitangent_sums[i]) < 0.0 ? -1.0 : 1.0);
			if (!std::isfinite(tangent.x) || !std::isfinite(tangent.y) || !std::isfinite(tangent.z) || !std::isfinite(handedness)) return false;
			vertex.tangent = {tangent.x, tangent.y, tangent.z, handedness};
		}
	}
	return true;
}

bool LMEntitySurfacePlan::smooth_normals_by_texture() {
	for (const auto &texture : texture_entries) {
		std::map<PositionKey, vec3> normal_sums;
		for (size_t entry_index : texture) {
			if (entry_index >= entries.size()) return false;
			for (const LMFaceVertex &vertex : entries[entry_index].surface.vertices) {
				if (!std::isfinite(vertex.vertex.x) || !std::isfinite(vertex.vertex.y) || !std::isfinite(vertex.vertex.z) ||
						!std::isfinite(vertex.normal.x) || !std::isfinite(vertex.normal.y) || !std::isfinite(vertex.normal.z)) return false;
				PositionKey key{vertex.vertex.x, vertex.vertex.y, vertex.vertex.z};
				auto found = normal_sums.find(key);
				if (found == normal_sums.end()) normal_sums.emplace(key, vertex.normal);
				else found->second = vec3_add(found->second, vertex.normal);
			}
		}
		for (size_t entry_index : texture) {
			for (LMFaceVertex &vertex : entries[entry_index].surface.vertices) {
				const vec3 sum = normal_sums.at({vertex.vertex.x, vertex.vertex.y, vertex.vertex.z});
				const double length = vec3_length(sum);
				if (!std::isfinite(length) || length <= 0.0) return false;
				vertex.normal = vec3_div_double(sum, length);
			}
		}
	}
	return true;
}

bool LMEntitySurfacePlan::combine_texture(int texture_index, LMOwnedSurface &output) const {
	output.clear();
	if (texture_index < 0 || texture_index >= static_cast<int>(texture_entries.size())) return false;
	for (size_t entry_index : texture_entries[texture_index])
		if (entry_index >= entries.size() || !append_owned(output, entries[entry_index].surface)) return false;
	return true;
}

bool LMEntitySurfacePlan::combine_texture(int texture_index, const std::vector<LMEntitySurfacePrimitive> &primitives, LMOwnedSurface &output) const {
	output.clear();
	for (const LMEntitySurfacePrimitive &primitive : primitives) {
		const auto &source_entries = primitive.is_patch ? patch_entries : brush_entries;
		if (primitive.source_index < 0 || primitive.source_index >= static_cast<int>(source_entries.size())) return false;
		for (size_t entry_index : source_entries[primitive.source_index]) {
			if (entry_index >= entries.size()) return false;
			if (entries[entry_index].texture_index == texture_index && !append_owned(output, entries[entry_index].surface)) return false;
		}
	}
	return true;
}

void LMSurfaceGatherer::surface_gatherer_set_split_type(SURFACE_SPLIT_TYPE new_split_type) {
	split_type = new_split_type;
}

void LMSurfaceGatherer::surface_gatherer_set_entity_index_filter(int entity_idx) {
	entity_filter_idx = entity_idx;
}

void LMSurfaceGatherer::surface_gatherer_set_texture_filter(const char *texture_name) {
	texture_filter_idx = map_data->map_data_find_texture(texture_name);
}

void LMSurfaceGatherer::surface_gatherer_set_brush_filter_texture(const char *texture_name) {
	brush_filter_texture_idx = map_data->map_data_find_texture(texture_name);
}

void LMSurfaceGatherer::surface_gatherer_set_face_filter_texture(const char *texture_name) {
	face_filter_texture_idx = map_data->map_data_find_texture(texture_name);
}

void LMSurfaceGatherer::surface_gatherer_set_worldspawn_layer_filter(bool filter) {
	filter_worldspawn_layers = filter;
}

bool LMSurfaceGatherer::surface_gatherer_filter_entity(int entity_idx) {
	// Omit filtered entity indices
	if (entity_filter_idx != -1 && entity_idx != entity_filter_idx) {
		return true;
	}

	return false;
}

bool LMSurfaceGatherer::surface_gatherer_filter_brush(int entity_idx, int brush_idx) {
	const LMEntity *ents = map_data->map_data_get_entities();
	LMBrush *brush_inst = &ents[entity_idx].brushes[brush_idx];

	// Omit brushes that are fully-textured with clip
	if (brush_filter_texture_idx != -1) {
		bool fully_textured = true;

		for (int f = 0; f < brush_inst->face_count; ++f) {
			LMFace *face_inst = &brush_inst->faces[f];
			if (face_inst->texture_idx != brush_filter_texture_idx) {
				fully_textured = false;
				break;
			}
		}

		if (fully_textured) {
			return true;
		}
	}

	// Omit brushes that are part of a worldspawn layer
	if (filter_worldspawn_layers) {
		for (int f = 0; f < brush_inst->face_count; ++f) {
			face *face_inst = &brush_inst->faces[f];
			for (int l = 0; l < map_data->worldspawn_layer_count; ++l) {
				LMWorldspawnLayer *layer = &map_data->worldspawn_layers[l];
				if (face_inst->texture_idx == layer->texture_idx) {
					return true;
				}
			}
		}
	}

	return false;
}

bool LMSurfaceGatherer::surface_gatherer_filter_face(int entity_idx, int brush_idx, int face_idx) {
	const LMEntity *ents = map_data->map_data_get_entities();
	LMFace *face_inst = &ents[entity_idx].brushes[brush_idx].faces[face_idx];
	LMFaceGeometry *face_geo_inst = &map_data->entity_geo[entity_idx].brushes[brush_idx].faces[face_idx];

	// Omit faces with less than 3 vertices
	if (face_geo_inst->vertex_count < 3) {
		return true;
	}

	// Omit faces that are textured with skip
	if (face_filter_texture_idx != -1 && face_inst->texture_idx == face_filter_texture_idx) {
		return true;
	}

	// Omit filtered texture indices
	if (texture_filter_idx != -1 && face_inst->texture_idx != texture_filter_idx) {
		return true;
	}

	return false;
}

void LMSurfaceGatherer::surface_gatherer_reset_state() {
	for (int s = 0; s < out_surfaces.surface_count; ++s) {
		LMSurface *surf = &out_surfaces.surfaces[s];
		if (surf->vertices != NULL) {
			free(surf->vertices);
			surf->vertices = NULL;
		}

		if (surf->indices != NULL) {
			free(surf->indices);
			surf->indices = NULL;
		}
	}

	if (out_surfaces.surfaces != NULL) {
		free(out_surfaces.surfaces);
		out_surfaces.surfaces = NULL;
	}

	out_surfaces.surface_count = 0;
}

void LMSurfaceGatherer::surface_gatherer_run() {
	surface_gatherer_reset_state();

	int index_offset = 0;
	LMSurface *surf_inst = NULL;

	if (split_type == SST_NONE) {
		index_offset = 0;
		surf_inst = surface_gatherer_add_surface();
	}

	for (int e = 0; e < map_data->entity_count; ++e) {
		if (surface_gatherer_filter_entity(e)) {
			continue;
		}

		const LMEntity *entity_inst = &map_data->entities[e];
		const LMEntityGeometry *entity_geo_inst = &map_data->entity_geo[e];

		if (split_type == SST_ENTITY) {
			if (entity_inst->spawn_type == EST_MERGE_WORLDSPAWN) {
				surface_gatherer_add_surface();
				surf_inst = &out_surfaces.surfaces[0];
				index_offset = surf_inst->vertex_count;
			} else {
				surf_inst = surface_gatherer_add_surface();
				index_offset = surf_inst->vertex_count;
			}
		}

		for (int b = 0; b < entity_inst->brush_count; ++b) {
			LMBrush *brush_inst = &entity_inst->brushes[b];
			LMBrushGeometry *brush_geo_inst = &entity_geo_inst->brushes[b];

			if (surface_gatherer_filter_brush(e, b)) {
				continue;
			}

			if (split_type == SST_BRUSH) {
				index_offset = 0;
				surf_inst = surface_gatherer_add_surface();
			}

			for (int f = 0; f < brush_inst->face_count; ++f) {
				LMFaceGeometry *face_geo_inst = &brush_geo_inst->faces[f];

				if (surface_gatherer_filter_face(e, b, f)) {
					continue;
				}

				for (int v = 0; v < face_geo_inst->vertex_count; ++v) {
					LMFaceVertex vertex = face_geo_inst->vertices[v];

					if (entity_inst->spawn_type == EST_ENTITY || entity_inst->spawn_type == EST_GROUP) {
						vertex.vertex = vec3_sub(vertex.vertex, entity_inst->center);
					}

					surf_inst->vertices = (LMFaceVertex *)realloc(surf_inst->vertices, (surf_inst->vertex_count + 1) * sizeof(LMFaceVertex));
					surf_inst->vertices[surf_inst->vertex_count] = vertex;
					surf_inst->vertex_count++;
				}

				for (int i = 0; i < (face_geo_inst->vertex_count - 2) * 3; ++i) {
					surf_inst->indices = (int *)realloc(surf_inst->indices, (surf_inst->index_count + 1) * sizeof(int));
					surf_inst->indices[surf_inst->index_count] = face_geo_inst->indices[i] + index_offset;
					surf_inst->index_count++;
				}

				index_offset += face_geo_inst->vertex_count;
			}
		}

		// Gather patch geometry
		for (int p = 0; p < entity_inst->patch_count; ++p) {
			LMPatch *patch_inst = &entity_inst->patches[p];
			LMPatchGeometry *patch_geo_inst = &entity_geo_inst->patches[p];

			if (patch_geo_inst == NULL || patch_geo_inst->vertex_count < 3) {
				continue;
			}

			// Apply texture filter for patches
			if (texture_filter_idx != -1 && patch_inst->texture_idx != texture_filter_idx) {
				continue;
			}

			// Apply face filter (skip texture) for patches
			if (face_filter_texture_idx != -1 && patch_inst->texture_idx == face_filter_texture_idx) {
				continue;
			}

			if (split_type == SST_BRUSH) {
				index_offset = 0;
				surf_inst = surface_gatherer_add_surface();
			}

			for (int v = 0; v < patch_geo_inst->vertex_count; ++v) {
				LMFaceVertex vertex = patch_geo_inst->vertices[v];

				if (entity_inst->spawn_type == EST_ENTITY || entity_inst->spawn_type == EST_GROUP) {
					vertex.vertex = vec3_sub(vertex.vertex, entity_inst->center);
				}

				surf_inst->vertices = (LMFaceVertex *)realloc(surf_inst->vertices, (surf_inst->vertex_count + 1) * sizeof(LMFaceVertex));
				surf_inst->vertices[surf_inst->vertex_count] = vertex;
				surf_inst->vertex_count++;
			}

			for (int i = 0; i < patch_geo_inst->index_count; ++i) {
				surf_inst->indices = (int *)realloc(surf_inst->indices, (surf_inst->index_count + 1) * sizeof(int));
				surf_inst->indices[surf_inst->index_count] = patch_geo_inst->indices[i] + index_offset;
				surf_inst->index_count++;
			}

			index_offset += patch_geo_inst->vertex_count;
		}
	}
}

const LMSurfaces *LMSurfaceGatherer::surface_gatherer_fetch() {
	return &out_surfaces;
}

LMSurface *LMSurfaceGatherer::surface_gatherer_add_surface() {
	out_surfaces.surfaces = (LMSurface *)realloc(out_surfaces.surfaces, (out_surfaces.surface_count + 1) * sizeof(LMSurface));
	LMSurface *surf_inst = &out_surfaces.surfaces[out_surfaces.surface_count];
	*surf_inst = { 0 };
	out_surfaces.surface_count++;

	return surf_inst;
}

void LMSurfaceGatherer::surface_gatherer_reset_params() {
	split_type = SST_NONE;
	entity_filter_idx = -1;
	texture_filter_idx = -1;
	brush_filter_texture_idx = -1;
	face_filter_texture_idx = -1;
	filter_worldspawn_layers = true;
}
