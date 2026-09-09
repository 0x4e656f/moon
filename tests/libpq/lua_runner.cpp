#include "lua.hpp"
#include "lualib-src/libpq/pq_lua_codec.hpp"
#include <cstdio>
extern "C" int luaopen_json(lua_State* L);
namespace codec = moon::pq::codec;
template<int (*Fn)(lua_State*)>
int protect(lua_State* L) {
    try {
        return Fn(L);
    } catch (const std::exception& e) {
        lua_pushstring(L, e.what());
    }
    return lua_error(L);
}
static void push_param(lua_State* L, const moon::pq::parameter& p) {
    lua_createtable(L, 0, 3);
    lua_pushinteger(L, p.oid);
    lua_setfield(L, -2, "oid");
    lua_pushinteger(L, p.format);
    lua_setfield(L, -2, "format");
    if (p.value)
        codec::field(L, "value", *p.value);
}
static int encode(lua_State* L) {
    push_param(L, codec::encode(L, 1));
    return 1;
}
static int encode_params(lua_State* L) {
    auto params = codec::parameters(L, 1);
    lua_createtable(L, static_cast<int>(params.size()), 0);
    lua_Integer n = 0;
    for (const auto& p: params) {
        push_param(L, p);
        lua_rawseti(L, -2, ++n);
    }
    return 1;
}
static int decode(lua_State* L) {
    if (codec::is_null(L, 1))
        lua_pushlightuserdata(L, nullptr);
    else
        codec::push_value(L, codec::string_arg(L, 1, true), codec::uint_arg(L, 2, true));
    return 1;
}
static int type_oid(lua_State* L) {
    lua_pushinteger(L, codec::type_oid(L, 1));
    return 1;
}
static int sql(lua_State* L) {
    codec::sql_arg(L, 1);
    lua_pushboolean(L, 1);
    return 1;
}
static int statements(lua_State* L) {
    auto statements = codec::statements(L, 1);
    lua_createtable(L, static_cast<int>(statements.size()), 0);
    lua_Integer i = 0;
    for (const auto& s: statements) {
        lua_createtable(L, 0, 2);
        codec::field(L, "sql", s.sql);
        lua_createtable(L, static_cast<int>(s.params.size()), 0);
        lua_Integer j = 0;
        for (const auto& p: s.params) {
            push_param(L, p);
            lua_rawseti(L, -2, ++j);
        }
        lua_setfield(L, -2, "params");
        lua_rawseti(L, -2, ++i);
    }
    return 1;
}
static int result(lua_State* L) {
    moon::pq::result_set r;
    codec::rawfield(L, 1, "columns");
    auto n = codec::sequence(L, -1);
    for (size_t i = 1; i <= n; ++i) {
        lua_rawgeti(L, -1, static_cast<lua_Integer>(i));
        codec::rawfield(L, -1, "name");
        auto name = codec::string_arg(L, -1);
        lua_pop(L, 1);
        codec::rawfield(L, -1, "oid");
        auto oid = codec::uint_arg(L, -1, true);
        lua_pop(L, 2);
        r.columns.push_back({ name, oid });
    }
    lua_pop(L, 1);
    codec::rawfield(L, 1, "rows");
    r.row_count = codec::sequence(L, -1);
    for (size_t i = 1; i <= r.row_count; ++i) {
        lua_rawgeti(L, -1, static_cast<lua_Integer>(i));
        for (size_t j = 1; j <= n; ++j) {
            lua_rawgeti(L, -1, static_cast<lua_Integer>(j));
            moon::pq::cell c;
            if (!codec::is_null(L, -1)) {
                auto value = codec::string_arg(L, -1, true);
                c = { r.data.size(), value.size() };
                r.data += value;
            }
            r.cells.push_back(c);
            lua_pop(L, 1);
        }
        lua_pop(L, 1);
    }
    lua_pop(L, 1);
    codec::rawfield(L, 1, "command");
    r.command = codec::string_arg(L, -1);
    lua_pop(L, 1);
    codec::rawfield(L, 1, "affected");
    r.affected = codec::string_arg(L, -1);
    lua_pop(L, 1);
    codec::push_result(L, r, lua_isnoneornil(L, 2) || codec::string_arg(L, 2) == "name");
    return 1;
}
static int open_codec(lua_State* L) {
    luaL_Reg functions[] = {
        { "encode", protect<encode> }, { "encode_params", protect<encode_params> },
        { "decode", protect<decode> }, { "type_oid", protect<type_oid> },
        { "sql", protect<sql> },       { "statements", protect<statements> },
        { "result", protect<result> }, { nullptr, nullptr }
    };
    luaL_newlib(L, functions);
    return 1;
}
int main(int argc, char** argv) {
    lua_State* L = luaL_newstate();
    if (!L)
        return 2;
    luaL_openlibs(L);
    luaL_requiref(L, "json", luaopen_json, 0);
    lua_pop(L, 1);
    luaL_requiref(L, "libpq.testcodec", open_codec, 0);
    lua_pop(L, 1);
    const char* script = argc > 1 ? argv[1] : "tests/libpq/unit.lua";
    int status = luaL_loadfile(L, script);
    if (!status)
        status = lua_pcall(L, 0, LUA_MULTRET, 0);
    if (status)
        std::fprintf(stderr, "%s\n", lua_tostring(L, -1));
    lua_close(L);
    return status ? 1 : 0;
}
