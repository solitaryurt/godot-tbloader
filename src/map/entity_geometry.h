#ifndef LIBMAP_ENTITY_GEOMETRY_H
#define LIBMAP_ENTITY_GEOMETRY_H

#include "vector.h"
#include <stdlib.h>

typedef struct LMVertexUV {
	double u;
	double v;
} LMVertexUV;

typedef struct LMVertexTangent {
	double x;
	double y;
	double z;
	double w;
} LMVertexTangent;

typedef struct LMFaceVertex {
	vec3 vertex;
	vec3 normal;
	LMVertexUV uv;
	LMVertexTangent tangent;
} LMFaceVertex;

typedef struct LMFaceGeometry {
	int vertex_count = 0;
	LMFaceVertex *vertices = NULL;
	int index_count = 0;
	int *indices = NULL;
} LMFaceGeometry;

typedef struct LMBrushGeometry {
	int face_count = 0;
	LMFaceGeometry *faces = NULL;
} LMBrushGeometry;

// Tessellated patch mesh geometry (single surface with vertices + indices)
typedef struct LMPatchGeometry {
	int vertex_count = 0;
	LMFaceVertex *vertices = NULL;
	int index_count = 0;
	int *indices = NULL;
} LMPatchGeometry;

typedef struct LMEntityGeometry {
	int brush_count = 0;
	int patch_count = 0;
	LMBrushGeometry *brushes = NULL;
	LMPatchGeometry *patches = NULL;
} LMEntityGeometry;

#endif
