-- Standalone checks only: no Moon executable and no real PostgreSQL server.
local root = path.getabsolute("../..", _SCRIPT_DIR)
workspace "libpq_checks"
    configurations { "release" }
    architecture "x64"
    location (root .. "/target/libpq-tests")
    targetdir (root .. "/target/libpq-tests/bin")
    objdir (root .. "/target/libpq-tests/obj/%{prj.name}")
    optimize "Speed"
    symbols "On"
    filter "system:windows"
        systemversion "latest"
        defines { "_WIN32_WINNT=0x0A00", "_CRT_SECURE_NO_WARNINGS" }
    filter {}
project "libpq_engine_test"
    kind "ConsoleApp"
    language "C++"
    cppdialect "C++17"
    defines { "ASIO_STANDALONE", "ASIO_NO_DEPRECATED" }
    includedirs {root .. "/third", root .. "/src/lualib-src"}
    files {_SCRIPT_DIR .. "/engine_test.cpp"}
    filter "system:windows"
        links { "ws2_32", "mswsock" }
    filter "system:linux"
        links { "dl", "pthread" }
    filter {}
project "libpq_test_lua_runtime"
    kind "StaticLib"
    language "C"
    cdialect "C11"
    defines { "MAKE_LIB" }
    filter "system:windows"
        buildoptions { "/experimental:c11atomics" }
    filter {}
    includedirs {root .. "/third/lua"}
    files {root .. "/third/lua/onelua.c"}
project "libpq_lua_test"
    kind "ConsoleApp"
    language "C++"
    cppdialect "C++17"
    includedirs {root .. "/third", root .. "/third/lua", root .. "/src"}
    files {_SCRIPT_DIR .. "/lua_runner.cpp", root .. "/src/lualib-src/lua_json.cpp", root .. "/third/yyjson/yyjson.c"}
    links { "libpq_test_lua_runtime" }
