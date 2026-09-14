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
