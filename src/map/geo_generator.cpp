#include "geo_generator.h"

#include <cmath>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits>

#include "brush.h"
#include "entity.h"
#include "face.h"
#include "libmap_math.h"
#include "patch.h"

const vec3 UP_VECTOR = { 0.0, 0.0, 1.0 };
const vec3 RIGHT_VECTOR = { 0.0, 1.0, 0.0 };
const vec3 FORWARD_VECTOR = { 1.0, 0.0, 0.0 };

bool smooth_normals = false;

int wind_entity_idx = 0;
int wind_brush_idx = 0;
int wind_face_idx = 0;
vec3 wind_face_center;
vec3 wind_face_basis;
vec3 wind_face_normal;

static LMMapData *sort_map_data;
int sort_vertices_by_winding(const void *lhs_in, const void *rhs_in) {
	const vec3 *lhs = (const vec3 *)lhs_in;
	const vec3 *rhs = (const vec3 *)rhs_in;

	face *face_inst = &sort_map_data->entities[wind_entity_idx].brushes[wind_brush_idx].faces[wind_face_idx];
	LMFaceGeometry *face_geo_inst = &sort_map_data->entity_geo[wind_entity_idx].brushes[wind_brush_idx].faces[wind_face_idx];

	vec3 u = vec3_normalize(wind_face_basis);
	vec3 v = vec3_normalize(vec3_cross(u, wind_face_normal));

	vec3 local_lhs = vec3_sub(*lhs, wind_face_center);
	double lhs_pu = vec3_dot(local_lhs, u);
	double lhs_pv = vec3_dot(local_lhs, v);

	vec3 local_rhs = vec3_sub(*rhs, wind_face_center);
	double rhs_pu = vec3_dot(local_rhs, u);
	double rhs_pv = vec3_dot(local_rhs, v);

	double lhs_angle = atan2(lhs_pv, lhs_pu);
	double rhs_angle = atan2(rhs_pv, rhs_pu);

	if (lhs_angle < rhs_angle) {
		return -1;
	} else if (lhs_angle > rhs_angle) {
		return 1;
	}

	return 0;
}

void LMGeoGenerator::run() {
	map_data->map_data_free_geometry();
	map_data->geometry_entity_count = map_data->entity_count;
	map_data->entity_geo = (LMEntityGeometry *)calloc(map_data->entity_count, sizeof(LMEntityGeometry));

	for (int e = 0; e < map_data->entity_count; ++e) {
		LMEntity *ent_inst = &map_data->entities[e];

		LMEntityGeometry *entity_geo_inst = &map_data->entity_geo[e];
		*entity_geo_inst = { 0 };
		entity_geo_inst->brush_count = ent_inst->brush_count;
		entity_geo_inst->patch_count = ent_inst->patch_count;

		entity_geo_inst->brushes = (LMBrushGeometry *)malloc(ent_inst->brush_count * sizeof(LMBrushGeometry));

		for (int b = 0; b < ent_inst->brush_count; ++b) {
			LMBrush *brush_inst = &ent_inst->brushes[b];

			LMBrushGeometry *brush_geo_inst = &entity_geo_inst->brushes[b];
			*brush_geo_inst = { 0 };
			brush_geo_inst->face_count = brush_inst->face_count;

			brush_geo_inst->faces = (LMFaceGeometry *)malloc(brush_inst->face_count * sizeof(LMFaceGeometry));

			for (int f = 0; f < brush_inst->face_count; ++f) {
				LMFaceGeometry *face_geo_inst = &brush_geo_inst->faces[f];
				*face_geo_inst = { 0 };
			}
		}

		// Allocate patch geometry
		if (ent_inst->patch_count > 0) {
			entity_geo_inst->patches = (LMPatchGeometry *)malloc(ent_inst->patch_count * sizeof(LMPatchGeometry));
			for (int p = 0; p < ent_inst->patch_count; ++p) {
				LMPatchGeometry *patch_geo_inst = &entity_geo_inst->patches[p];
				*patch_geo_inst = { 0 };
			}
		}
	}

	for (int e = 0; e < map_data->entity_count; ++e) {
		LMEntity *ent_inst = &map_data->entities[e];
		ent_inst->center = { 0.0, 0.0, 0.0 };

		for (int b = 0; b < ent_inst->brush_count; ++b) {
			LMBrush *brush_inst = &ent_inst->brushes[b];
			brush_inst->center = { 0.0, 0.0, 0.0 };
			int vert_count = 0;

			generate_brush_vertices(e, b);

			LMBrushGeometry *brush_geo_inst = &map_data->entity_geo[e].brushes[b];
			for (int f = 0; f < brush_inst->face_count; f++) {
				LMFaceGeometry *face_geo_inst = &brush_geo_inst->faces[f];

				for (int v = 0; v < face_geo_inst->vertex_count; ++v) {
					brush_inst->center = vec3_add(brush_inst->center, face_geo_inst->vertices[v].vertex);
					vert_count++;
				}
			}

			if (vert_count > 0) {
				brush_inst->center = vec3_div_double(brush_inst->center, vert_count);
			}

			ent_inst->center = vec3_add(ent_inst->center, brush_inst->center);
		}

		// Generate patch geometry
		for (int p = 0; p < ent_inst->patch_count; ++p) {
			generate_patch_geometry(e, p);

			LMPatchGeometry *patch_geo_inst = &map_data->entity_geo[e].patches[p];
			vec3 patch_center = { 0.0, 0.0, 0.0 };
			for (int v = 0; v < patch_geo_inst->vertex_count; ++v) {
				patch_center = vec3_add(patch_center, patch_geo_inst->vertices[v].vertex);
			}
			if (patch_geo_inst->vertex_count > 0) {
				patch_center = vec3_div_double(patch_center, patch_geo_inst->vertex_count);
			}
			ent_inst->center = vec3_add(ent_inst->center, patch_center);
		}

		int total_geo_sources = ent_inst->brush_count + ent_inst->patch_count;
		if (total_geo_sources > 0) {
			ent_inst->center = vec3_div_double(ent_inst->center, total_geo_sources);
		}
	}

	// Wind face vertices
	for (int e = 0; e < map_data->entity_count; ++e) {
		LMEntity *entity_inst = &map_data->entities[e];
		LMEntityGeometry *entity_geo_inst = &map_data->entity_geo[e];
		for (int b = 0; b < entity_inst->brush_count; ++b) {
			LMBrush *brush_inst = &entity_inst->brushes[b];
			LMBrushGeometry *brush_geo_inst = &entity_geo_inst->brushes[b];

			for (int f = 0; f < brush_inst->face_count; ++f) {
				face *face_inst = &brush_inst->faces[f];
				LMFaceGeometry *face_geo_inst = &brush_geo_inst->faces[f];

				if (face_geo_inst->vertex_count < 3) {
					continue;
				}

				wind_entity_idx = e;
				wind_brush_idx = b;
				wind_face_idx = f;

				wind_face_basis = vec3_sub(face_geo_inst->vertices[1].vertex, face_geo_inst->vertices[0].vertex);
				wind_face_center = { 0 };
				wind_face_normal = face_inst->plane_normal;

				for (int v = 0; v < face_geo_inst->vertex_count; ++v) {
					wind_face_center = vec3_add(wind_face_center, face_geo_inst->vertices[v].vertex);
				}

				wind_face_center = vec3_div_double(wind_face_center, face_geo_inst->vertex_count);

				sort_map_data = map_data.get();
				qsort(face_geo_inst->vertices, face_geo_inst->vertex_count, sizeof(LMFaceVertex), sort_vertices_by_winding);

				wind_entity_idx = 0;
			}
		}
	}

	// Index face vertices
	for (int e = 0; e < map_data->entity_count; ++e) {
		LMEntity *entity_inst = &map_data->entities[e];
		LMEntityGeometry *entity_geo_inst = &map_data->entity_geo[e];
		for (int b = 0; b < entity_inst->brush_count; ++b) {
			LMBrush *brush_inst = &entity_inst->brushes[b];
			LMBrushGeometry *brush_geo_inst = &entity_geo_inst->brushes[b];

			for (int f = 0; f < brush_inst->face_count; ++f) {
				LMFaceGeometry *face_geo_inst = &brush_geo_inst->faces[f];

				if (face_geo_inst->vertex_count < 3) {
					continue;
				}

				face_geo_inst->indices = (int *)malloc((face_geo_inst->vertex_count - 2) * 3 * sizeof(int));
				for (int i = 0; i < face_geo_inst->vertex_count - 2; i++) {
					face_geo_inst->indices[face_geo_inst->index_count++] = 0;
					face_geo_inst->indices[face_geo_inst->index_count++] = i + 1;
					face_geo_inst->indices[face_geo_inst->index_count++] = i + 2;
				}
			}
		}
	}
}

void LMGeoGenerator::generate_brush_vertices(int entity_idx, int brush_idx) {
	LMEntity *ent_inst = &map_data->entities[entity_idx];
	LMBrush *brush_inst = &ent_inst->brushes[brush_idx];

	for (int f0 = 0; f0 < brush_inst->face_count; ++f0) {
		for (int f1 = 0; f1 < brush_inst->face_count; ++f1) {
			for (int f2 = 0; f2 < brush_inst->face_count; ++f2) {
				vec3 vertex = { 0 };
				if (intersect_faces(brush_inst->faces[f0], brush_inst->faces[f1], brush_inst->faces[f2], &vertex)) {
					if (vertex_in_hull(brush_inst->faces, brush_inst->face_count, vertex)) {
						face *face_inst = &map_data->entities[entity_idx].brushes[brush_idx].faces[f0];
						LMFaceGeometry *face_geo_inst = &map_data->entity_geo[entity_idx].brushes[brush_idx].faces[f0];

						vec3 normal;

						const char *phong_property = map_data->map_data_get_entity_property(entity_idx, "_phong");
						bool phong = phong_property != NULL && strcmp(phong_property, "1") == 0;
						if (phong) {
							const char *phong_angle_property = map_data->map_data_get_entity_property(entity_idx, "_phong_angle");
							if (phong_angle_property != NULL) {
								double threshold = cos((atof(phong_angle_property) + 0.01) * 0.0174533);
								normal = brush_inst->faces[f0].plane_normal;
								if (vec3_dot(brush_inst->faces[f0].plane_normal, brush_inst->faces[f1].plane_normal) > threshold) {
									normal = vec3_add(normal, brush_inst->faces[f1].plane_normal);
								}
								if (vec3_dot(brush_inst->faces[f0].plane_normal, brush_inst->faces[f2].plane_normal) > threshold) {
									normal = vec3_add(normal, brush_inst->faces[f2].plane_normal);
								}
								normal = vec3_normalize(normal);
							} else {
								normal = vec3_normalize(
										vec3_add(
												brush_inst->faces[f0].plane_normal,
												vec3_add(
														brush_inst->faces[f1].plane_normal,
														brush_inst->faces[f2].plane_normal)));
							}
						} else {
							normal = face_inst->plane_normal;
						}

						LMTextureData *texture = map_data->map_data_get_texture(face_inst->texture_idx);

						LMVertexUV uv;
						if (face_inst->is_valve_uv) {
							uv = get_valve_uv(vertex, face_inst, texture->width, texture->height);
						} else {
							uv = get_standard_uv(vertex, face_inst, texture->width, texture->height);
						}

						LMVertexTangent tangent;
						if (face_inst->is_valve_uv) {
							tangent = get_valve_tangent(face_inst);
						} else {
							tangent = get_standard_tangent(face_inst);
						}

						bool unique_vertex = true;
						int duplicate_index = -1;

						for (int v = 0; v < face_geo_inst->vertex_count; ++v) {
							vec3 comp_vertex = face_geo_inst->vertices[v].vertex;
							if (vec3_length(vec3_sub(vertex, comp_vertex)) < CMP_EPSILON) {
								unique_vertex = false;
								duplicate_index = v;
								break;
							}
						}

						if (unique_vertex) {
							face_geo_inst->vertex_count++;
							face_geo_inst->vertices = (LMFaceVertex *)realloc(face_geo_inst->vertices, face_geo_inst->vertex_count * sizeof(LMFaceVertex));
							face_geo_inst->vertices[face_geo_inst->vertex_count - 1] = { vertex, normal, uv, tangent };
						} else if (phong) {
							face_geo_inst->vertices[duplicate_index].normal = vec3_add(face_geo_inst->vertices[duplicate_index].normal, normal);
						}
					}
				}
			}
		}
	}

	for (int f = 0; f < brush_inst->face_count; ++f) {
		LMFaceGeometry *face_geo_inst = &map_data->entity_geo[entity_idx].brushes[brush_idx].faces[f];

		for (int v = 0; v < face_geo_inst->vertex_count; ++v) {
			face_geo_inst->vertices[v].normal = vec3_normalize(face_geo_inst->vertices[v].normal);
		}
	}
}

// Evaluate a quadratic bezier curve at parameter t (0..1)
static vec3 bezier_quad_vec3(const vec3 &p0, const vec3 &p1, const vec3 &p2, double t) {
	double it = 1.0 - t;
	// B(t) = (1-t)^2 * P0 + 2*(1-t)*t * P1 + t^2 * P2
	return vec3_add(vec3_add(
		vec3_mul_double(p0, it * it),
		vec3_mul_double(p1, 2.0 * it * t)),
		vec3_mul_double(p2, t * t));
}

static double bezier_quad_scalar(double p0, double p1, double p2, double t) {
	double it = 1.0 - t;
	return it * it * p0 + 2.0 * it * t * p1 + t * t * p2;
}

// Evaluate derivative of quadratic bezier at parameter t
static vec3 bezier_quad_deriv_vec3(const vec3 &p0, const vec3 &p1, const vec3 &p2, double t) {
	double it = 1.0 - t;
	// B'(t) = 2*(1-t)*(P1-P0) + 2*t*(P2-P1)
	return vec3_add(
		vec3_mul_double(vec3_sub(p1, p0), 2.0 * it),
		vec3_mul_double(vec3_sub(p2, p1), 2.0 * t));
}

void LMGeoGenerator::generate_patch_geometry(int entity_idx, int patch_idx) {
	LMEntity *ent_inst = &map_data->entities[entity_idx];
	LMPatch *patch = &ent_inst->patches[patch_idx];
	LMPatchGeometry *patch_geo = &map_data->entity_geo[entity_idx].patches[patch_idx];

	if (patch->width < 3 || patch->height < 3) {
		return;
	}

	// Number of 3x3 sub-patches in each direction
	int num_patches_x = (patch->width - 1) / 2;
	int num_patches_y = (patch->height - 1) / 2;

	// Tessellation level per sub-patch (number of subdivisions)
	// Use a fixed tessellation level; patchDef3 subdivision hints could override this
	int tess_level = 4;
	if (patch->subdiv_x > 0) {
		tess_level = patch->subdiv_x;
	}
	int tess_level_y = tess_level;
	if (patch->subdiv_y > 0) {
		tess_level_y = patch->subdiv_y;
	}

	// Total number of vertices in the tessellated mesh
	int tess_width = num_patches_x * tess_level + 1;
	int tess_height = num_patches_y * tess_level_y + 1;

	int total_verts = tess_width * tess_height;
	int total_indices = (tess_width - 1) * (tess_height - 1) * 6;

	patch_geo->vertices = (LMFaceVertex *)malloc(total_verts * sizeof(LMFaceVertex));
	memset(patch_geo->vertices, 0, total_verts * sizeof(LMFaceVertex));
	patch_geo->vertex_count = total_verts;

	patch_geo->indices = (int *)malloc(total_indices * sizeof(int));
	patch_geo->index_count = 0;

	// Helper macro to get control point at (col, row) in the grid
	// The grid is stored column-major: control_points[row * width + col]
	#define CP(col, row) patch->control_points[(row) * patch->width + (col)]

	// Tessellate each sub-patch and fill in the vertex grid
	for (int py = 0; py < num_patches_y; ++py) {
		for (int px = 0; px < num_patches_x; ++px) {
			// Control point indices for this 3x3 sub-patch
			int cp_x0 = px * 2;
			int cp_x1 = px * 2 + 1;
			int cp_x2 = px * 2 + 2;
			int cp_y0 = py * 2;
			int cp_y1 = py * 2 + 1;
			int cp_y2 = py * 2 + 2;

			// The 9 control points for this sub-patch
			LMPatchControlPoint cp00 = CP(cp_x0, cp_y0);
			LMPatchControlPoint cp10 = CP(cp_x1, cp_y0);
			LMPatchControlPoint cp20 = CP(cp_x2, cp_y0);
			LMPatchControlPoint cp01 = CP(cp_x0, cp_y1);
			LMPatchControlPoint cp11 = CP(cp_x1, cp_y1);
			LMPatchControlPoint cp21 = CP(cp_x2, cp_y1);
			LMPatchControlPoint cp02 = CP(cp_x0, cp_y2);
			LMPatchControlPoint cp12 = CP(cp_x1, cp_y2);
			LMPatchControlPoint cp22 = CP(cp_x2, cp_y2);

			int steps_u = tess_level;
			int steps_v = tess_level_y;

			// Don't re-generate the first row/column of subsequent sub-patches
			// (they share the boundary with the previous sub-patch)
			int start_u = (px == 0) ? 0 : 1;
			int start_v = (py == 0) ? 0 : 1;

			for (int iv = start_v; iv <= steps_v; ++iv) {
				double v = (double)iv / (double)steps_v;

				for (int iu = start_u; iu <= steps_u; ++iu) {
					double u = (double)iu / (double)steps_u;

					// Evaluate the bicubic bezier surface at (u, v)
					// First, evaluate 3 curves along v for x=0,1,2
					vec3 p0 = bezier_quad_vec3(cp00.position, cp01.position, cp02.position, v);
					vec3 p1 = bezier_quad_vec3(cp10.position, cp11.position, cp12.position, v);
					vec3 p2 = bezier_quad_vec3(cp20.position, cp21.position, cp22.position, v);

					// Then evaluate along u
					vec3 pos = bezier_quad_vec3(p0, p1, p2, u);

					// UV coordinates: same bezier interpolation
					double uv_u0 = bezier_quad_scalar(cp00.u, cp01.u, cp02.u, v);
					double uv_u1 = bezier_quad_scalar(cp10.u, cp11.u, cp12.u, v);
					double uv_u2 = bezier_quad_scalar(cp20.u, cp21.u, cp22.u, v);
					double tex_u = bezier_quad_scalar(uv_u0, uv_u1, uv_u2, u);

					double uv_v0 = bezier_quad_scalar(cp00.v, cp01.v, cp02.v, v);
					double uv_v1 = bezier_quad_scalar(cp10.v, cp11.v, cp12.v, v);
					double uv_v2 = bezier_quad_scalar(cp20.v, cp21.v, cp22.v, v);
					double tex_v = bezier_quad_scalar(uv_v0, uv_v1, uv_v2, u);

					// Compute tangent vectors for normal calculation
					// dP/du
					vec3 du0 = bezier_quad_vec3(cp00.position, cp01.position, cp02.position, v);
					vec3 du1 = bezier_quad_vec3(cp10.position, cp11.position, cp12.position, v);
					vec3 du2 = bezier_quad_vec3(cp20.position, cp21.position, cp22.position, v);
					vec3 dpdu = bezier_quad_deriv_vec3(du0, du1, du2, u);

					// dP/dv
					vec3 dv0 = bezier_quad_vec3(cp00.position, cp10.position, cp20.position, u);
					vec3 dv1 = bezier_quad_vec3(cp01.position, cp11.position, cp21.position, u);
					vec3 dv2 = bezier_quad_vec3(cp02.position, cp12.position, cp22.position, u);
					vec3 dpdv = bezier_quad_deriv_vec3(dv0, dv1, dv2, v);

					vec3 normal = vec3_cross(dpdv, dpdu);
					if (vec3_sqlen(normal) > CMP_EPSILON * CMP_EPSILON) {
						normal = vec3_normalize(normal);
					} else {
						normal = { 0.0, 0.0, 1.0 };
					}

					// Tangent (along u direction)
					LMVertexTangent tangent = { 0 };
					if (vec3_sqlen(dpdu) > CMP_EPSILON * CMP_EPSILON) {
						vec3 t = vec3_normalize(dpdu);
						// Compute bitangent sign
						vec3 bitangent = vec3_cross(normal, t);
						double w = (vec3_dot(bitangent, dpdv) < 0.0) ? -1.0 : 1.0;
						tangent = { t.x, t.y, t.z, w };
					}

					// Compute vertex grid position
					int grid_x = px * tess_level + iu;
					int grid_y = py * tess_level_y + iv;
					int vert_idx = grid_y * tess_width + grid_x;

					patch_geo->vertices[vert_idx].vertex = pos;
					patch_geo->vertices[vert_idx].normal = normal;
					patch_geo->vertices[vert_idx].uv = { tex_u, tex_v };
					patch_geo->vertices[vert_idx].tangent = tangent;
				}
			}
		}
	}

	#undef CP

	// Generate indices (two triangles per quad)
	for (int y = 0; y < tess_height - 1; ++y) {
		for (int x = 0; x < tess_width - 1; ++x) {
			int i00 = y * tess_width + x;
			int i10 = y * tess_width + (x + 1);
			int i01 = (y + 1) * tess_width + x;
			int i11 = (y + 1) * tess_width + (x + 1);

			// Triangle 1
			patch_geo->indices[patch_geo->index_count++] = i00;
			patch_geo->indices[patch_geo->index_count++] = i01;
			patch_geo->indices[patch_geo->index_count++] = i11;

			// Triangle 2
			patch_geo->indices[patch_geo->index_count++] = i00;
			patch_geo->indices[patch_geo->index_count++] = i11;
			patch_geo->indices[patch_geo->index_count++] = i10;
		}
	}
}

namespace {
// Intersections can be ill-conditioned even for ordinary grid edits. Derive
// planes from their defining points at extended precision: promoting already
// rounded unit normals cannot recover their lost incidence information.
struct IntersectionVector {
	long double x, y, z;
	IntersectionVector operator-(IntersectionVector b) const { return {x - b.x, y - b.y, z - b.z}; }
	IntersectionVector operator+(IntersectionVector b) const { return {x + b.x, y + b.y, z + b.z}; }
	IntersectionVector operator*(long double s) const { return {x * s, y * s, z * s}; }
	IntersectionVector cross(IntersectionVector b) const { return {y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x}; }
	long double dot(IntersectionVector b) const { return x * b.x + y * b.y + z * b.z; }
};
IntersectionVector precise(vec3 p) { return {p.x, p.y, p.z}; }
IntersectionVector intersection_normal(const face &f) {
	return (precise(f.plane_points.v2) - precise(f.plane_points.v0)).cross(precise(f.plane_points.v1) - precise(f.plane_points.v0));
}
}

bool LMGeoGenerator::intersect_faces(face f0, face f1, face f2, vec3 *o_vertex) {
	const auto normal0 = intersection_normal(f0);
	const auto normal1 = intersection_normal(f1);
	const auto normal2 = intersection_normal(f2);
	const auto cross01 = normal0.cross(normal1);
	const long double denom = cross01.dot(normal2);
	const long double scale = std::sqrt(normal0.dot(normal0) * normal1.dot(normal1) * normal2.dot(normal2));

	// The relative determinant is dimensionless, not a distance. Using the vertex weld
	// tolerance here drops real corners between shallow supporting planes (e.g.
	// a prism corner dragged along the default grid diagonal). Both orientations
	// of a nonsingular triple have the same intersection.
	if (std::abs(denom) <= 64 * std::numeric_limits<long double>::epsilon() * scale) {
		return false;
	}

	if (o_vertex) {
		// Solve around a defining point rather than subtracting large world-space
		// plane distances. The latter amplifies cancellation at shallow angles.
		const auto origin = precise(f0.plane_points.v0);
		const auto d1 = normal1.dot(precise(f1.plane_points.v0) - origin);
		const auto d2 = normal2.dot(precise(f2.plane_points.v0) - origin);
		const auto point = origin + (normal2.cross(normal0) * d1 + cross01 * d2) * (1 / denom);
		*o_vertex = {double(point.x), double(point.y), double(point.z)};
	}

	return true;
}

bool LMGeoGenerator::vertex_in_hull(face *faces, int face_count, vec3 vertex) {
	for (int f = 0; f < face_count; f++) {
		face face_inst = faces[f];

		double proj = vec3_dot(face_inst.plane_normal, vertex);

		if (proj > face_inst.plane_dist && fabs(face_inst.plane_dist - proj) > CMP_EPSILON) {
			return false;
		}
	}

	return true;
}

LMVertexUV LMGeoGenerator::get_standard_uv(vec3 vertex, const face *face, int texture_width, int texture_height) {
	LMVertexUV uv_out;

	double du = fabs(vec3_dot(face->plane_normal, UP_VECTOR));
	double dr = fabs(vec3_dot(face->plane_normal, RIGHT_VECTOR));
	double df = fabs(vec3_dot(face->plane_normal, FORWARD_VECTOR));

	if (du >= dr && du >= df) {
		uv_out = { vertex.x, -vertex.y };
	} else if (dr >= du && dr >= df) {
		uv_out = { vertex.x, -vertex.z };
	} else if (df >= du && df >= dr) {
		uv_out = { vertex.y, -vertex.z };
	}

	LMVertexUV rotated;
	double angle = DEG_TO_RAD(face->uv_extra.rot);
	rotated.u = uv_out.u * cos(angle) - uv_out.v * sin(angle);
	rotated.v = uv_out.u * sin(angle) + uv_out.v * cos(angle);
	uv_out = rotated;

	uv_out.u /= texture_width;
	uv_out.v /= texture_height;

	uv_out.u /= face->uv_extra.scale_x;
	uv_out.v /= face->uv_extra.scale_y;

	uv_out.u += face->uv_standard.u / texture_width;
	uv_out.v += face->uv_standard.v / texture_height;

	return uv_out;
}

LMVertexUV LMGeoGenerator::get_valve_uv(vec3 vertex, const face *face, int texture_width, int texture_height) {
	LMVertexUV uv_out;

	vec3 u_axis = face->uv_valve.u.axis;
	double u_shift = face->uv_valve.u.offset;
	vec3 v_axis = face->uv_valve.v.axis;
	double v_shift = face->uv_valve.v.offset;

	uv_out.u = vec3_dot(u_axis, vertex);
	uv_out.v = vec3_dot(v_axis, vertex);

	uv_out.u /= texture_width;
	uv_out.v /= texture_height;

	uv_out.u /= face->uv_extra.scale_x;
	uv_out.v /= face->uv_extra.scale_y;

	uv_out.u += u_shift / texture_width;
	uv_out.v += v_shift / texture_height;

	return uv_out;
}

double sign(double v) {
	if (v > 0) {
		return 1.0;
	} else if (v < 0) {
		return -1.0;
	}

	return 0.0;
}

LMVertexTangent LMGeoGenerator::get_standard_tangent(const face *face) {
	LMVertexTangent tangent_out;

	double du = vec3_dot(face->plane_normal, UP_VECTOR);
	double dr = vec3_dot(face->plane_normal, RIGHT_VECTOR);
	double df = vec3_dot(face->plane_normal, FORWARD_VECTOR);

	double dua = fabs(du);
	double dra = fabs(dr);
	double dfa = fabs(df);

	vec3 u_axis;
	double v_sign = 0;

	if (dua >= dra && dua >= dfa) {
		u_axis = FORWARD_VECTOR;
		v_sign = sign(du);
	} else if (dra >= dua && dra >= dfa) {
		u_axis = FORWARD_VECTOR;
		v_sign = -sign(dr);
	} else if (dfa >= dua && dfa >= dra) {
		u_axis = RIGHT_VECTOR;
		v_sign = sign(df);
	}

	v_sign *= sign(face->uv_extra.scale_y);
	u_axis = vec3_rotate(u_axis, face->plane_normal, -face->uv_extra.rot * v_sign);

	tangent_out.x = u_axis.x;
	tangent_out.y = u_axis.y;
	tangent_out.z = u_axis.z;
	tangent_out.w = v_sign;

	return tangent_out;
}

LMVertexTangent LMGeoGenerator::get_valve_tangent(const face *face) {
	LMVertexTangent tangent_out;

	vec3 u_axis = vec3_normalize(face->uv_valve.u.axis);
	vec3 v_axis = vec3_normalize(face->uv_valve.v.axis);

	double v_sign = -sign(vec3_dot(vec3_cross(face->plane_normal, u_axis), v_axis));

	tangent_out.x = u_axis.x;
	tangent_out.y = u_axis.y;
	tangent_out.z = u_axis.z;
	tangent_out.w = v_sign;

	return tangent_out;
}

void LMGeoGenerator::geo_generator_print_entities() {
	for (int e = 0; e < map_data->entity_count; ++e) {
		LMEntity *entity_inst = &map_data->entities[e];
		LMEntityGeometry *entity_geo_inst = &map_data->entity_geo[e];
		printf("Entity %d\n", e);
		for (int b = 0; b < entity_inst->brush_count; ++b) {
			LMBrush *brush_inst = &entity_inst->brushes[b];
			LMBrushGeometry *brush_geo_inst = &entity_geo_inst->brushes[b];
			printf("Brush %d\n", b);

			for (int f = 0; f < brush_inst->face_count; ++f) {
				LMFaceGeometry *face_geo_inst = &brush_geo_inst->faces[f];
				printf("Face %d\n", f);
				for (int i = 0; i < face_geo_inst->vertex_count; ++i) {
					LMFaceVertex vertex = face_geo_inst->vertices[i];
					printf("vertex: (%f %f %f), normal: (%f %f %f)\n",
							vertex.vertex.x, vertex.vertex.y, vertex.vertex.z,
							vertex.normal.x, vertex.normal.y, vertex.normal.z);
				}

				puts("Indices:");
				for (int i = 0; i < (face_geo_inst->vertex_count - 2) * 3; ++i) {
					printf("index: %d\n", face_geo_inst->indices[i]);
				}
			}

			putchar('\n');
			putchar('\n');
		}
	}
}

const LMEntityGeometry *LMGeoGenerator::geo_generator_get_entities() {
	return map_data->entity_geo;
}

int LMGeoGenerator::geo_generator_get_brush_vertex_count(int entity_idx, int brush_idx) {
	int vertex_count = 0;

	LMBrush *brush_inst = &map_data->entities[entity_idx].brushes[brush_idx];
	LMBrushGeometry *brush_geo_inst = &map_data->entity_geo[entity_idx].brushes[brush_idx];

	for (int i = 0; i < brush_inst->face_count; ++i) {
		LMFaceGeometry *face_geo_inst = &brush_geo_inst->faces[i];
		vertex_count = vertex_count + face_geo_inst->vertex_count;
	}

	return vertex_count;
}

int LMGeoGenerator::geo_generator_get_brush_index_count(int entity_idx, int brush_idx) {
	int index_count = 0;

	LMBrush *brush_inst = &map_data->entities[entity_idx].brushes[brush_idx];
	LMBrushGeometry *brush_geo_inst = &map_data->entity_geo[entity_idx].brushes[brush_idx];

	for (int i = 0; i < brush_inst->face_count; ++i) {
		LMFaceGeometry *face_geo_inst = &brush_geo_inst->faces[i];
		index_count = index_count + face_geo_inst->index_count;
	}

	return index_count;
}
