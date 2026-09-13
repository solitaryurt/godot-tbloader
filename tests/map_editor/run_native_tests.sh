#!/usr/bin/env bash
# Run from repository root. Artifacts stay outside source and the addon library.
set -euo pipefail
output="${TB_NATIVE_OUTPUT:-/tmp/opencode/tbloader-native-document}"
"${CXX:-clang++}" -std=c++17 -g -O1 -fno-omit-frame-pointer \
  -fsanitize=address,undefined -DLM_STANDALONE -Isrc/map \
  tests/map_editor/native_document_test.cpp \
  src/map/map_data.cpp src/map/map_parser.cpp src/map/map_writer.cpp src/map/map_edit.cpp \
  src/map/geo_generator.cpp src/map/entity.cpp src/map/vector.cpp src/map/matrix.cpp \
  -o "$output"
ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 "$output"
