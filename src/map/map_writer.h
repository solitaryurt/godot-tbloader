#ifndef LM_MAP_WRITER_H
#define LM_MAP_WRITER_H
#include "map_data.h"
#include <string>

// Canonical semantic text: locale independent, double round-trip precision.
std::string lm_write_map(const LMMapData &map);
#endif
