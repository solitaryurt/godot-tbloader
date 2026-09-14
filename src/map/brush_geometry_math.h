#ifndef LM_BRUSH_GEOMETRY_MATH_H
#define LM_BRUSH_GEOMETRY_MATH_H

#include "entity_geometry.h"
#include "face.h"

bool lm_intersect_brush_faces(LMFace f0, LMFace f1, LMFace f2, vec3 *vertex);
bool lm_brush_vertex_in_hull(const LMFace *faces, int face_count, vec3 vertex);
LMVertexUV lm_standard_brush_uv(vec3 vertex, const LMFace *face, int texture_width, int texture_height);
LMVertexUV lm_valve_brush_uv(vec3 vertex, const LMFace *face, int texture_width, int texture_height);

#endif
