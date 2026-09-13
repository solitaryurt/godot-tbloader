#ifndef LIBMAP_BRUSH_H
#define LIBMAP_BRUSH_H

#include <stdlib.h>
#include <stdint.h>
#include "vector.h"

struct LMFace;

struct LMBrush {
	int64_t id = 0;
	int64_t topology_revision = 0;
	int face_count = 0;
	LMFace *faces = NULL;
	vec3 center;
};

#endif
