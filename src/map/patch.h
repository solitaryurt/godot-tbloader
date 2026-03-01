#ifndef LIBMAP_PATCH_H
#define LIBMAP_PATCH_H

#include <stdlib.h>
#include "vector.h"

// A single control point in a patch mesh
typedef struct LMPatchControlPoint {
	vec3 position;  // xyz world position
	double u;       // texture coordinate u
	double v;       // texture coordinate v
} LMPatchControlPoint;

// A bezier patch mesh (patchDef2 or patchDef3)
struct LMPatch {
	int texture_idx = -1;
	int width = 0;              // number of columns (must be odd >= 3)
	int height = 0;             // number of rows (must be odd >= 3)
	LMPatchControlPoint *control_points = NULL;  // width * height control points (column-major)

	// patchDef3 subdivision hints (0 means auto)
	int subdiv_x = 0;
	int subdiv_y = 0;
};

#endif
