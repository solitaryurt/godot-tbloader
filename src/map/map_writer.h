#ifndef LM_MAP_WRITER_H
#define LM_MAP_WRITER_H
#include "map_data.h"
#include <string>

// Canonical semantic text: locale independent, double round-trip precision.
std::string lm_write_map(const LMMapData &map);
struct LMFace;
struct LMPatch;
std::string lm_write_face(const LMFace &face, const std::string &texture);
std::string lm_write_patch(const LMMapData &map, const LMPatch &patch);
std::string lm_quote(const std::string &text);
#endif
