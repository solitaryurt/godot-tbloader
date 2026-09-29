#include "brush_geometry_math.h"

#include "libmap_math.h"

#include <cmath>
#include <limits>

namespace {
const vec3 UP_VECTOR = {0.0, 0.0, 1.0};
const vec3 RIGHT_VECTOR = {0.0, 1.0, 0.0};
const vec3 FORWARD_VECTOR = {1.0, 0.0, 0.0};

struct IntersectionVector {
	long double x, y, z;
	IntersectionVector operator-(IntersectionVector b) const { return {x - b.x, y - b.y, z - b.z}; }
	IntersectionVector operator+(IntersectionVector b) const { return {x + b.x, y + b.y, z + b.z}; }
	IntersectionVector operator*(long double s) const { return {x * s, y * s, z * s}; }
	IntersectionVector cross(IntersectionVector b) const { return {y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x}; }
	long double dot(IntersectionVector b) const { return x * b.x + y * b.y + z * b.z; }
};
IntersectionVector precise(vec3 point) { return {point.x, point.y, point.z}; }
IntersectionVector intersection_normal(const LMFace &face) {
	return (precise(face.plane_points.v2) - precise(face.plane_points.v0)).cross(precise(face.plane_points.v1) - precise(face.plane_points.v0));
}
}

bool lm_intersect_brush_faces(LMFace f0, LMFace f1, LMFace f2, vec3 *vertex) {
	const auto normal0 = intersection_normal(f0);
	const auto normal1 = intersection_normal(f1);
	const auto normal2 = intersection_normal(f2);
	const auto cross01 = normal0.cross(normal1);
	const long double denom = cross01.dot(normal2);
	const long double scale = std::sqrt(normal0.dot(normal0) * normal1.dot(normal1) * normal2.dot(normal2));
	if (std::abs(denom) <= 64 * std::numeric_limits<long double>::epsilon() * scale) return false;
	if (vertex) {
		const auto origin = precise(f0.plane_points.v0);
		const auto d1 = normal1.dot(precise(f1.plane_points.v0) - origin);
		const auto d2 = normal2.dot(precise(f2.plane_points.v0) - origin);
		const auto point = origin + (normal2.cross(normal0) * d1 + cross01 * d2) * (1 / denom);
		*vertex = {double(point.x), double(point.y), double(point.z)};
	}
	return true;
}

bool lm_brush_vertex_in_hull(const LMFace *faces, int face_count, vec3 vertex) {
	for (int f = 0; f < face_count; ++f) {
		const double projection = vec3_dot(faces[f].plane_normal, vertex);
		if (projection > faces[f].plane_dist && std::fabs(faces[f].plane_dist - projection) > CMP_EPSILON) return false;
	}
	return true;
}

LMVertexUV lm_standard_brush_uv(vec3 vertex, const LMFace *face, int texture_width, int texture_height) {
	LMVertexUV uv;
	const double du = std::fabs(vec3_dot(face->plane_normal, UP_VECTOR));
	const double dr = std::fabs(vec3_dot(face->plane_normal, RIGHT_VECTOR));
	const double df = std::fabs(vec3_dot(face->plane_normal, FORWARD_VECTOR));
	if (du >= dr && du >= df) uv = {vertex.x, -vertex.y};
	else if (dr >= du && dr >= df) uv = {vertex.x, -vertex.z};
	else uv = {vertex.y, -vertex.z};
	const double angle = DEG_TO_RAD(face->uv_extra.rot);
	const LMVertexUV rotated = {uv.u * std::cos(angle) - uv.v * std::sin(angle), uv.u * std::sin(angle) + uv.v * std::cos(angle)};
	uv = rotated;
	uv.u /= texture_width; uv.v /= texture_height;
	uv.u /= face->uv_extra.scale_x; uv.v /= face->uv_extra.scale_y;
	uv.u += face->uv_standard.u / texture_width; uv.v += face->uv_standard.v / texture_height;
	return uv;
}

LMVertexUV lm_valve_brush_uv(vec3 vertex, const LMFace *face, int texture_width, int texture_height) {
	LMVertexUV uv;
	uv.u = vec3_dot(face->uv_valve.u.axis, vertex);
	uv.v = vec3_dot(face->uv_valve.v.axis, vertex);
	uv.u /= texture_width; uv.v /= texture_height;
	uv.u /= face->uv_extra.scale_x; uv.v /= face->uv_extra.scale_y;
	uv.u += face->uv_valve.u.offset / texture_width; uv.v += face->uv_valve.v.offset / texture_height;
	return uv;
}

void lm_brushdef_axis_base(vec3 normal, vec3 &tex_s, vec3 &tex_t) {
	vec3 n = normal;
	if (std::fabs(n.x) < 1e-6) n.x = 0;
	if (std::fabs(n.y) < 1e-6) n.y = 0;
	if (std::fabs(n.z) < 1e-6) n.z = 0;
	const double rot_y = -std::atan2(n.z, std::sqrt(n.x * n.x + n.y * n.y));
	const double rot_z = std::atan2(n.y, n.x);
	const double sin_z = std::sin(rot_z), cos_z = std::cos(rot_z);
	const double sin_y = std::sin(rot_y), cos_y = std::cos(rot_y);
	tex_s = {-sin_z, cos_z, 0};
	tex_t = {-sin_y * cos_z, -sin_y * sin_z, -cos_y};
}

void lm_brushdef_world_axes(const LMFace *face, vec3 &u, vec3 &v) {
	vec3 tex_s, tex_t;
	lm_brushdef_axis_base(face->plane_normal, tex_s, tex_t);
	u = vec3_add(vec3_mul_double(tex_s, face->uv_valve.u.axis.x), vec3_mul_double(tex_t, face->uv_valve.u.axis.y));
	v = vec3_add(vec3_mul_double(tex_s, face->uv_valve.v.axis.x), vec3_mul_double(tex_t, face->uv_valve.v.axis.y));
}

LMVertexUV lm_brushdef_uv(vec3 vertex, const LMFace *face) {
	vec3 tex_s, tex_t;
	lm_brushdef_axis_base(face->plane_normal, tex_s, tex_t);
	const double s = vec3_dot(vertex, tex_s);
	const double t = vec3_dot(vertex, tex_t);
	return {
		face->uv_valve.u.axis.x * s + face->uv_valve.u.axis.y * t + face->uv_valve.u.axis.z,
		face->uv_valve.v.axis.x * s + face->uv_valve.v.axis.y * t + face->uv_valve.v.axis.z,
	};
}

LMVertexUV lm_face_brush_uv(vec3 vertex, const LMFace *face, int texture_width, int texture_height) {
	if (face->is_bp_uv) return lm_brushdef_uv(vertex, face);
	if (face->is_valve_uv) return lm_valve_brush_uv(vertex, face, texture_width, texture_height);
	return lm_standard_brush_uv(vertex, face, texture_width, texture_height);
}
