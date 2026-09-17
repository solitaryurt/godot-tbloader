#!/usr/bin/env bash
set -euo pipefail
output="${TB_PARTITION_BENCH_OUTPUT:-/tmp/opencode/tbloader-partition-benchmark}"
"${CXX:-clang++}" -std=c++17 -O2 -DNDEBUG -DLM_STANDALONE -Isrc/map \
  tests/worldspawn_benchmark/partition_benchmark.cpp src/map/worldspawn_partitioner.cpp \
  -o "$output"
exec "$output" "$@"
