#!/usr/bin/env bash
# Run from repository root. Artifacts stay outside source and the addon library.
set -euo pipefail
suite="${1:-all}"
common=(
  -std=c++17 -g -O1 -fno-omit-frame-pointer
  -fsanitize=address,undefined -DLM_STANDALONE -Isrc/map
)
sources=(
  src/map/map_data.cpp src/map/map_parser.cpp src/map/map_writer.cpp src/map/map_edit.cpp
  src/map/brush_topology.cpp src/map/brush_geometry_math.cpp src/map/editor_brush_geometry.cpp
  src/map/geo_generator.cpp src/map/entity.cpp src/map/vector.cpp src/map/matrix.cpp
)
run_test() {
  local output="$1"
  shift
  "${CXX:-clang++}" "${common[@]}" "$@" "${sources[@]}" -o "$output"
  ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 "$output"
}

case "$suite" in
  worldspawn)
    run_test "${TB_NATIVE_OUTPUT:-/tmp/opencode/tbloader-native-worldspawn}" \
      tests/map_editor/worldspawn_partitioner_test.cpp src/map/worldspawn_partitioner.cpp src/map/surface_gatherer.cpp
    ;;
  document)
    run_test "${TB_NATIVE_OUTPUT:-/tmp/opencode/tbloader-native-document}" \
      tests/map_editor/native_document_test.cpp
    ;;
  all)
    run_test "${TB_NATIVE_OUTPUT:-/tmp/opencode/tbloader-native-worldspawn}" \
      tests/map_editor/worldspawn_partitioner_test.cpp src/map/worldspawn_partitioner.cpp src/map/surface_gatherer.cpp
    run_test "${TB_NATIVE_DOCUMENT_OUTPUT:-/tmp/opencode/tbloader-native-document}" \
      tests/map_editor/native_document_test.cpp
    ;;
  *)
    printf 'usage: %s [all|worldspawn|document]\n' "$0" >&2
    exit 2
    ;;
esac
