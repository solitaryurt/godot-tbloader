#ifndef LM_MAP_EDIT_H
#define LM_MAP_EDIT_H

#include "map_data.h"
#include "face.h"
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
	explicit LMMapEdit(const LMMapData &map);
	std::string text() const;
	LMEditEntity *entity(int64_t id);
	LMEditPrimitive *brush(int64_t id);
	LMEditEntity &world();
};
LMEditPrimitive lm_edit_cuboid(vec3 mins, vec3 maxs, const std::string &texture);
// Remove redundant/empty supporting planes after a cut. Uses disposable geometry;
// callers still validate the complete document before committing.
bool lm_edit_prune_faces(LMEditPrimitive &brush);
#endif
