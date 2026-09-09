#!/usr/bin/env bash
# Compile only standalone checks; load system prebuilt libpq. No Moon or real DB.
set -euo pipefail
pq_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$pq_root"
pq_out=target/libpq-linux-checks
mkdir -p "$pq_out"
"${CXX:-g++}" -std=c++17 -O2 -DASIO_STANDALONE -DASIO_NO_DEPRECATED \
    -Ithird -Isrc/lualib-src tests/libpq/engine_test.cpp -ldl -pthread -o "$pq_out/engine_test"
"${CC:-gcc}" -std=c11 -O2 -DMAKE_LIB -DLUA_USE_LINUX -Ithird/lua -c third/lua/onelua.c -o "$pq_out/lua.o"
"${CC:-gcc}" -std=c11 -O2 -Ithird -c third/yyjson/yyjson.c -o "$pq_out/yyjson.o"
"${CXX:-g++}" -std=c++17 -O2 -Ithird -Ithird/lua -Isrc \
    tests/libpq/lua_runner.cpp src/lualib-src/lua_json.cpp "$pq_out/lua.o" "$pq_out/yyjson.o" \
    -ldl -pthread -lm -o "$pq_out/lua_test"
"$pq_out/engine_test"
"$pq_out/lua_test"
