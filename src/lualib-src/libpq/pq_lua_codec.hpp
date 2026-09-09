#pragma once
#include "lua.hpp"
#include "pq_data.hpp"
#include <algorithm>
#include <charconv>
#include <climits>
#include <cmath>
#include <cstring>
#include <system_error>

namespace moon::pq::codec {
inline void stack(lua_State* L, int n = 8) {
    if (!lua_checkstack(L, n))
        throw std::runtime_error("libpq Lua stack exhausted");
}
inline uint32_t uint_arg(lua_State* L, int index, bool zero = false) {
    if (!lua_isinteger(L, index))
        throw std::runtime_error("expected integer option");
    auto n = lua_tointeger(L, index);
    if (n < (zero ? 0 : 1) || n > UINT32_MAX)
        throw std::runtime_error("integer option outside uint32 range");
    return static_cast<uint32_t>(n);
}
inline bool is_null(lua_State* L, int index) {
    return lua_isnil(L, index)
        || (lua_islightuserdata(L, index) && lua_touserdata(L, index) == nullptr);
}
inline void rawfield(lua_State* L, int index, const char* key) {
    index = lua_absindex(L, index);
    lua_pushstring(L, key);
    lua_rawget(L, index);
}
inline bool valid_utf8(std::string_view s) {
    for (size_t i = 0; i < s.size();) {
        auto c = static_cast<unsigned char>(s[i++]);
        if (c < 0x80)
            continue;
        uint32_t value;
        unsigned count;
        if (c >= 0xc2 && c <= 0xdf) {
            value = c & 31;
            count = 1;
        } else if (c >= 0xe0 && c <= 0xef) {
            value = c & 15;
            count = 2;
        } else if (c >= 0xf0 && c <= 0xf4) {
            value = c & 7;
            count = 3;
        } else
            return false;
        if (s.size() - i < count)
            return false;
        for (unsigned j = 0; j < count; ++j) {
            c = static_cast<unsigned char>(s[i++]);
            if ((c & 0xc0) != 0x80)
                return false;
            value = (value << 6) | (c & 63);
        }
        if ((count == 2 && value < 0x800) || (count == 3 && value < 0x10000) || value > 0x10ffff
            || (value >= 0xd800 && value <= 0xdfff))
            return false;
    }
    return true;
}
inline std::string string_arg(lua_State* L, int index, bool binary = false) {
    if (lua_type(L, index) != LUA_TSTRING)
        throw std::runtime_error("expected string");
    size_t n;
    auto s = lua_tolstring(L, index, &n);
    if (n > static_cast<size_t>(INT_MAX))
        throw std::runtime_error("string exceeds libpq length range");
    std::string_view value(s, n);
    if (!binary && (value.find('\0') != value.npos || !valid_utf8(value)))
        throw std::runtime_error("text must be UTF-8 without NUL; use bytea for binary data");
    return std::string(value);
}
inline std::string sql_arg(lua_State* L, int index) {
    auto sql = string_arg(L, index);
    if (sql.empty())
        throw std::runtime_error("SQL must not be empty");
    return sql;
}
inline size_t sequence(lua_State* L, int index, size_t maximum = INT_MAX) {
    if (!lua_istable(L, index))
        throw std::runtime_error("expected a sequence");
    index = lua_absindex(L, index);
    auto n = lua_rawlen(L, index);
    if (n > maximum)
        throw std::runtime_error("sequence exceeds limit");
    size_t count = 0;
    lua_pushnil(L);
    while (lua_next(L, index)) {
        if (!lua_isinteger(L, -2) || lua_tointeger(L, -2) < 1
            || static_cast<size_t>(lua_tointeger(L, -2)) > n)
            throw std::runtime_error("sequence must not contain holes or hash keys");
        ++count;
        lua_pop(L, 1);
    }
    if (count != n)
        throw std::runtime_error("use libpq.NULL instead of a nil hole");
    return n;
}
inline Oid type_oid(lua_State* L, int index) {
    if (lua_isinteger(L, index))
        return uint_arg(L, index, true);
    const auto name = string_arg(L, index);
    static const std::pair<const char*, Oid> types[] = {
        { "bool", 16 },     { "boolean", 16 },     { "bytea", 17 },         { "char", 18 },
        { "name", 19 },     { "int8", 20 },        { "bigint", 20 },        { "int2", 21 },
        { "smallint", 21 }, { "int4", 23 },        { "integer", 23 },       { "text", 25 },
        { "oid", 26 },      { "json", 114 },       { "xml", 142 },          { "float4", 700 },
        { "float8", 701 },  { "money", 790 },      { "macaddr", 829 },      { "inet", 869 },
        { "cidr", 650 },    { "bpchar", 1042 },    { "varchar", 1043 },     { "date", 1082 },
        { "time", 1083 },   { "timestamp", 1114 }, { "timestamptz", 1184 }, { "interval", 1186 },
        { "timetz", 1266 }, { "bit", 1560 },       { "varbit", 1562 },      { "numeric", 1700 },
        { "uuid", 2950 },   { "jsonb", 3802 }
    };
    for (const auto& type: types)
        if (name == type.first)
            return type.second;
    throw std::runtime_error("unknown PostgreSQL type");
}
inline constexpr std::pair<Oid, Oid> array_types[] = {
    { 1000, 16 },   { 1001, 17 },   { 1002, 18 },   { 1003, 19 },   { 1016, 20 },   { 1005, 21 },
    { 1007, 23 },   { 1009, 25 },   { 1028, 26 },   { 199, 114 },   { 143, 142 },   { 1021, 700 },
    { 1022, 701 },  { 791, 790 },   { 1040, 829 },  { 1041, 869 },  { 651, 650 },   { 1014, 1042 },
    { 1015, 1043 }, { 1182, 1082 }, { 1183, 1083 }, { 1115, 1114 }, { 1185, 1184 }, { 1187, 1186 },
    { 1270, 1266 }, { 1561, 1560 }, { 1563, 1562 }, { 1231, 1700 }, { 2951, 2950 }, { 3807, 3802 }
};
// Reuse the framework's C JSON module (including its per-service configuration).
// pcall contains its Lua errors, so C++ temporary buffers are always unwound.
inline void json_call(lua_State* L, const char* method, int value) {
    value = lua_absindex(L, value);
    lua_getfield(L, LUA_REGISTRYINDEX, LUA_LOADED_TABLE);
    lua_getfield(L, -1, "json");
    if (!lua_istable(L, -1))
        throw std::runtime_error("json module is not loaded");
    lua_getfield(L, -1, method);
    lua_remove(L, -2);
    lua_remove(L, -2);
    lua_pushvalue(L, value);
    if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
        const char* message = lua_tostring(L, -1);
        throw std::runtime_error(message ? message : "JSON codec failed");
    }
}
inline std::optional<std::string> scalar(lua_State* L, int index, Oid oid) {
    if (lua_isnil(L, index))
        return {};
    if (oid == 114 || oid == 3802) {
        json_call(L, "encode", index);
        auto value = string_arg(L, -1);
        lua_pop(L, 1);
        return value;
    }
    if (is_null(L, index))
        return {};
    if (oid == 17)
        return string_arg(L, index, true);
    if (lua_isboolean(L, index))
        return lua_toboolean(L, index) ? "t" : "f";
    if (lua_type(L, index) == LUA_TNUMBER) {
        if (lua_isinteger(L, index))
            return std::to_string(lua_tointeger(L, index));
        auto n = lua_tonumber(L, index);
        if (std::isnan(n))
            return "NaN";
        if (std::isinf(n))
            return n > 0 ? "Infinity" : "-Infinity";
        char buf[64];
        auto result = std::to_chars(buf, buf + sizeof(buf), n, std::chars_format::general, 17);
        if (result.ec != std::errc())
            throw std::runtime_error("could not encode floating point parameter");
        return std::string(buf, result.ptr);
    }
    return string_arg(L, index);
}
inline parameter encode(lua_State* L, int index) {
    stack(L);
    index = lua_absindex(L, index);
    parameter p;
    bool wrapped = false;
    if (lua_istable(L, index)) {
        rawfield(L, index, "__libpq_type");
        wrapped = !lua_isnil(L, -1);
        if (wrapped) {
            if (lua_type(L, -1) == LUA_TSTRING && string_arg(L, -1) == "array") {
                lua_pop(L, 1);
                rawfield(L, index, "element_type");
                auto element = type_oid(L, -1);
                lua_pop(L, 1);
                for (const auto& a: array_types)
                    if (a.second == element)
                        p.oid = a.first;
                if (!p.oid)
                    throw std::runtime_error("unsupported array element type");
                rawfield(L, index, "value");
                auto items = lua_gettop(L);
                auto n = sequence(L, items);
                std::string data = "{";
                for (size_t i = 1; i <= n; ++i) {
                    if (i > 1)
                        data.push_back(',');
                    lua_rawgeti(L, items, static_cast<lua_Integer>(i));
                    auto value =
                        is_null(L, -1) ? std::optional<std::string>() : scalar(L, -1, element);
                    lua_pop(L, 1);
                    if (!value) {
                        data += "NULL";
                        continue;
                    }
                    if (element == 17) {
                        std::string hex = "\\x";
                        for (unsigned char c: *value) {
                            hex += "0123456789abcdef"[c >> 4];
                            hex += "0123456789abcdef"[c & 15];
                        }
                        value = std::move(hex);
                    }
                    data.push_back('"');
                    for (char c: *value) {
                        if (c == '\\' || c == '"')
                            data.push_back('\\');
                        data.push_back(c);
                    }
                    data.push_back('"');
                }
                data.push_back('}');
                lua_pop(L, 1);
                if (data.size() > static_cast<size_t>(INT_MAX))
                    throw std::runtime_error("array parameter too large");
                p.value = std::move(data);
                return p;
            }
            p.oid = type_oid(L, -1);
            lua_pop(L, 1);
            rawfield(L, index, "value");
            index = lua_gettop(L);
        } else
            lua_pop(L, 1);
    }
    if (!wrapped) {
        if (is_null(L, index))
            p.oid = 0;
        else if (lua_isboolean(L, index))
            p.oid = 16;
        else if (lua_type(L, index) == LUA_TNUMBER)
            p.oid = lua_isinteger(L, index) ? 20 : 701;
        else if (lua_type(L, index) == LUA_TSTRING)
            p.oid = 25;
        else if (lua_istable(L, index))
            p.oid = 3802;
        else
            throw std::runtime_error("unsupported libpq parameter type");
    }
    p.format = p.oid == 17 ? 1 : 0;
    p.value = scalar(L, index, p.oid);
    if (wrapped)
        lua_pop(L, 1);
    if (p.value && p.value->size() > static_cast<size_t>(INT_MAX))
        throw std::runtime_error("parameter too large");
    return p;
}
inline std::vector<parameter> parameters(lua_State* L, int index) {
    std::vector<parameter> out;
    if (lua_isnoneornil(L, index))
        return out;
    index = lua_absindex(L, index);
    auto n = sequence(L, index, 65535);
    out.reserve(n);
    for (size_t i = 1; i <= n; ++i) {
        lua_rawgeti(L, index, static_cast<lua_Integer>(i));
        out.push_back(encode(L, -1));
        lua_pop(L, 1);
    }
    return out;
}
inline std::vector<statement> statements(lua_State* L, int index) {
    index = lua_absindex(L, index);
    auto n = sequence(L, index);
    std::vector<statement> out;
    out.reserve(n);
    for (size_t i = 1; i <= n; ++i) {
        lua_rawgeti(L, index, static_cast<lua_Integer>(i));
        if (!lua_istable(L, -1))
            throw std::runtime_error("transaction statement must be a table");
        statement s;
        rawfield(L, -1, "sql");
        s.sql = sql_arg(L, -1);
        lua_pop(L, 1);
        validate_transaction_sql(s.sql);
        rawfield(L, -1, "params");
        s.params = parameters(L, -1);
        lua_pop(L, 2);
        out.push_back(std::move(s));
    }
    return out;
}
inline lua_Integer integer(std::string_view value) {
    lua_Integer n;
    auto parsed = std::from_chars(value.data(), value.data() + value.size(), n);
    if (parsed.ec != std::errc() || parsed.ptr != value.data() + value.size())
        throw std::runtime_error("invalid PostgreSQL integer or outside Lua int64 range");
    return n;
}
inline std::string bytea(std::string_view s) {
    std::string out;
    if (s.substr(0, 2) == "\\x") {
        if (s.size() % 2)
            throw std::runtime_error("invalid bytea hex length");
        out.reserve((s.size() - 2) / 2);
        auto hex = [](char c) -> unsigned {
            if (c >= '0' && c <= '9')
                return c - '0';
            if (c >= 'a' && c <= 'f')
                return c - 'a' + 10;
            if (c >= 'A' && c <= 'F')
                return c - 'A' + 10;
            throw std::runtime_error("invalid bytea hex digit");
        };
        for (size_t i = 2; i < s.size(); i += 2)
            out.push_back(static_cast<char>((hex(s[i]) << 4) | hex(s[i + 1])));
    } else {
        out.reserve(s.size());
        for (size_t i = 0; i < s.size();) {
            auto c = s[i++];
            if (c == '\\') {
                if (i < s.size() && s[i] == '\\') {
                    ++i;
                    c = '\\';
                } else {
                    if (s.size() - i < 3 || s[i] < '0' || s[i] > '3' || s[i + 1] < '0'
                        || s[i + 1] > '7' || s[i + 2] < '0' || s[i + 2] > '7')
                        throw std::runtime_error("invalid bytea escape");
                    c = static_cast<char>(
                        (s[i] - '0') * 64 + (s[i + 1] - '0') * 8 + s[i + 2] - '0'
                    );
                    i += 3;
                }
            }
            out.push_back(c);
        }
    }
    return out;
}
inline void push_value(lua_State* L, std::string_view value, Oid oid);
inline void push_array(lua_State* L, std::string_view s, size_t& i, Oid oid, size_t depth = 0) {
    if (depth >= 64)
        throw std::runtime_error("PostgreSQL array nesting exceeds 64");
    stack(L);
    if (i >= s.size() || s[i++] != '{')
        throw std::runtime_error("invalid PG array");
    lua_newtable(L);
    if (i < s.size() && s[i] == '}') {
        ++i;
        return;
    }
    lua_Integer n = 0;
    while (i < s.size()) {
        if (s[i] == '{')
            push_array(L, s, i, oid, depth + 1);
        else {
            const bool quoted = s[i] == '"';
            bool escaped = false, closed = !quoted;
            std::string value;
            if (quoted)
                ++i;
            while (i < s.size()) {
                char c = s[i];
                if (c == '\\') {
                    if (++i == s.size())
                        throw std::runtime_error("truncated array escape");
                    escaped = true;
                    value.push_back(s[i++]);
                } else if (quoted && c == '"') {
                    ++i;
                    closed = true;
                    break;
                } else if (!quoted && (c == ',' || c == '}'))
                    break;
                else {
                    value.push_back(c);
                    ++i;
                }
            }
            if (!closed || (!quoted && value.empty()))
                throw std::runtime_error("invalid array element");
            if (!quoted && !escaped && value == "NULL")
                lua_pushlightuserdata(L, nullptr);
            else
                push_value(L, value, oid);
        }
        lua_rawseti(L, -2, ++n);
        if (i >= s.size())
            break;
        if (s[i++] == '}')
            return;
        if (s[i - 1] != ',')
            throw std::runtime_error("invalid array delimiter");
    }
    throw std::runtime_error("unterminated PG array");
}
inline void push_value(lua_State* L, std::string_view value, Oid oid) {
    stack(L);
    switch (oid) {
        case 20:
        case 21:
        case 23:
        case 26:
            lua_pushinteger(L, integer(value));
            return;
        case 16:
            if (value != "t" && value != "f")
                throw std::runtime_error("invalid PostgreSQL boolean");
            lua_pushboolean(L, value == "t");
            return;
        case 700:
        case 701: {
            double n;
            if (value == "NaN")
                n = std::numeric_limits<double>::quiet_NaN();
            else if (value == "Infinity")
                n = std::numeric_limits<double>::infinity();
            else if (value == "-Infinity")
                n = -std::numeric_limits<double>::infinity();
            else {
                auto parsed = std::from_chars(value.data(), value.data() + value.size(), n);
                if (parsed.ec != std::errc() || parsed.ptr != value.data() + value.size())
                    throw std::runtime_error("invalid PostgreSQL float");
            }
            lua_pushnumber(L, n);
            return;
        }
        case 17: {
            auto bytes = bytea(value);
            lua_pushlstring(L, bytes.data(), bytes.size());
            return;
        }
        case 114:
        case 3802:
            lua_pushlstring(L, value.data(), value.size());
            json_call(L, "decode", -1);
            lua_remove(L, -2);
            return;
        default:
            break;
    }
    for (const auto& a: array_types) {
        if (a.first == oid && !value.empty() && value.front() != '[') {
            size_t i = 0;
            push_array(L, value, i, a.second);
            if (i != value.size())
                throw std::runtime_error("trailing PG array data");
            return;
        }
    }
    lua_pushlstring(
        L,
        value.data(),
        value.size()
    ); // numeric, dates and unknown types stay lossless text
}
inline void field(lua_State* L, const char* key, std::string_view value) {
    lua_pushlstring(L, value.data(), value.size());
    lua_setfield(L, -2, key);
}
inline void push_result(lua_State* L, const result_set& result, bool named) {
    stack(L, 12);
    lua_createtable(L, 0, 4);
    field(L, "command", result.command);
    lua_pushinteger(L, result.affected.empty() ? 0 : integer(result.affected));
    lua_setfield(L, -2, "rows_affected");
    lua_createtable(L, static_cast<int>(result.columns.size()), 0);
    for (size_t i = 0; i < result.columns.size(); ++i) {
        const auto& col = result.columns[i];
        lua_createtable(L, 0, 2);
        field(L, "name", col.name);
        lua_pushinteger(L, col.oid);
        lua_setfield(L, -2, "oid");
        lua_rawseti(L, -2, static_cast<lua_Integer>(i + 1));
    }
    lua_setfield(L, -2, "columns");
    lua_createtable(
        L,
        static_cast<int>((std::min)(result.row_count, static_cast<size_t>(INT_MAX))),
        0
    );
    size_t pos = 0;
    for (size_t row = 0; row < result.row_count; ++row) {
        int n = static_cast<int>(result.columns.size());
        lua_createtable(L, named ? 0 : n, named ? n : 0);
        for (size_t col = 0; col < result.columns.size(); ++col) {
            const auto& c = result.cells.at(pos++);
            if (c.is_null())
                lua_pushlightuserdata(L, nullptr);
            else
                push_value(L, result.value(c), result.columns[col].oid);
            if (named)
                lua_setfield(L, -2, result.columns[col].name.c_str());
            else
                lua_rawseti(L, -2, static_cast<lua_Integer>(col + 1));
        }
        lua_rawseti(L, -2, static_cast<lua_Integer>(row + 1));
    }
    lua_setfield(L, -2, "rows");
}
} // namespace moon::pq::codec
