#ifndef LM_MAP_EDIT_H
#define LM_MAP_EDIT_H

#include "map_data.h"
#include "face.h"
#include "brush_topology.h"
#include <string>
#include <vector>

// Value-only edit staging. No geometry pointers or owning C arrays are copied.
struct LMEditFace {
	LMFace plane{};
	std::string texture;
};
struct LMEditPrimitive {
	int64_t id = 0;
	bool patch = false;
	std::string patch_text;
	std::vector<LMEditFace> faces;
};
struct LMEditEntity {
	int64_t id = 0;
	std::vector<std::pair<std::string, std::string>> epairs;
	std::vector<LMEditPrimitive> primitives;
	std::string property(const std::string &key) const;
	void set_property(const std::string &key, const std::string &value);
};
struct LMMapEdit {
	std::vector<LMEditEntity> entities;
	LMMapEdit() = default;
	explicit LMMapEdit(const LMMapData &map);
	std::string text(size_t reserve = 0) const;
	LMEditEntity *entity(int64_t id);
	LMEditPrimitive *brush(int64_t id);
	LMEditEntity &world();
};
LMEditPrimitive lm_edit_cuboid(vec3 mins, vec3 maxs, const std::string &texture);
// Rotate only supporting-plane points; texture projection and surface metadata
// remain byte-for-byte owned by their original faces.
void lm_edit_rotate_brush(LMEditPrimitive &brush, vec3 pivot, int axis, double radians);
// Remove redundant/empty supporting planes after a cut. Uses disposable geometry;
// callers still validate the complete document before committing.
bool lm_edit_prune_faces(LMEditPrimitive &brush);
enum class LMMergeBrushResult {
	OK,
	INVALID_GEOMETRY,
	LIMIT_EXCEEDED,
};
// Merge only a connected convex union whose interior boundaries are complete,
// opposing face polygons. Retained faces keep the first source metadata.
LMMergeBrushResult lm_edit_merge_brushes(const std::vector<const LMEditPrimitive *> &brushes, const std::vector<LMBrushTopology> &topologies, LMEditPrimitive &merged);
#endif
