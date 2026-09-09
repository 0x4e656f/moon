#include "libpq/pq_connection.hpp"
#include "libpq/pq_lua_codec.hpp"
#include "lua.hpp"
#include "server.h"
#include "services/lua_service.h"
#include "worker.h"
#include <limits>

namespace {
using moon::pq::connection;
constexpr const char* metaname = "moon.libpq.connection";
struct box {
    std::shared_ptr<connection>* value = nullptr;
    uint32_t owner = 0;
};

namespace codec = moon::pq::codec;
using codec::string_arg;
using codec::uint_arg;
box* checked(lua_State* L) {
    auto b = static_cast<box*>(luaL_testudata(L, 1, metaname));
    if (!b || lua_rawlen(L, 1) != sizeof(box) || !b->value)
        throw std::runtime_error("invalid or collected libpq connection");
    if (b->owner != lua_service::get(L)->id())
        throw std::runtime_error("connection belongs to another Lua service");
    return b;
}
template<int (*Fn)(lua_State*)>
int protect(lua_State* L) {
    try {
        return Fn(L);
    } catch (const std::exception& e) {
        lua_pushstring(L, e.what());
    }
    return lua_error(L); // unwind C++ objects before Lua's longjmp
}
void field(lua_State* L, const char* key, const std::string& value) {
    lua_pushlstring(L, value.data(), value.size());
    lua_setfield(L, -2, key);
}
void integer_field(lua_State* L, const char* key, lua_Integer value) {
    lua_pushinteger(L, value);
    lua_setfield(L, -2, key);
}
int load(lua_State* L) {
    auto path = lua_isnoneornil(L, 1) ? std::string() : string_arg(L, 1);
    lua_pushinteger(L, moon::pq::load_library(path));
    return 1;
}
int gc(lua_State* L) {
    auto b = static_cast<box*>(luaL_testudata(L, 1, metaname));
    if (b && lua_rawlen(L, 1) == sizeof(box) && b->value) {
        try {
            (*b->value)->close(false);
        } catch (...) {
        } // no exception may escape a Lua finalizer
        delete b->value;
        b->value = nullptr;
    }
    return 0;
}
int close(lua_State* L) {
    (*checked(L)->value)->close();
    lua_pushboolean(L, 1);
    return 1;
}
int connected(lua_State* L) {
    lua_pushboolean(L, (*checked(L)->value)->connected());
    return 1;
}
int busy(lua_State* L) {
    lua_pushboolean(L, (*checked(L)->value)->busy());
    return 1;
}

int connect(lua_State* L) {
    auto b = checked(L);
    if (!lua_istable(L, 2))
        throw std::runtime_error("connect options must be a table");
    const auto timeout = uint_arg(L, 3);
    std::map<std::string, std::string> options;
    lua_pushnil(L);
    while (lua_next(L, 2)) {
        auto key = string_arg(L, -2);
        auto value = string_arg(L, -1);
        options.emplace(std::move(key), std::move(value));
        lua_pop(L, 1);
    }
    const auto session = lua_service::get(L)->next_sequence();
    (*b->value)->connect(std::move(options), session, timeout);
    lua_pushinteger(L, session);
    return 1;
}

int submit(lua_State* L) {
    auto b = checked(L);
    auto kind = string_arg(L, 2);
    auto sql = codec::sql_arg(L, 3);
    auto timeout = uint_arg(L, 5);
    auto max_rows = uint_arg(L, 6, true);
    auto max_bytes = uint_arg(L, 7, true);
    auto name = lua_isnoneornil(L, 8) ? std::string() : string_arg(L, 8);
    auto cmd = kind == "query" ? connection::command::query
        : kind == "batch"      ? connection::command::batch
        : kind == "prepare"    ? connection::command::prepare
        : kind == "prepared"   ? connection::command::prepared
                               : throw std::runtime_error("unknown libpq command");
    std::vector<moon::pq::parameter> params;
    if (cmd == connection::command::prepare && !lua_isnoneornil(L, 4)) {
        auto n = codec::sequence(L, 4, 65535);
        params.reserve(n);
        for (size_t i = 1; i <= n; ++i) {
            lua_rawgeti(L, 4, static_cast<lua_Integer>(i));
            params.push_back({ codec::type_oid(L, -1), 0, {} });
            lua_pop(L, 1);
        }
    } else
        params = codec::parameters(L, 4);
    auto session = lua_service::get(L)->next_sequence();
    (*b->value)->submit(
        cmd,
        std::move(sql),
        std::move(params),
        std::move(name),
        session,
        timeout,
        max_rows,
        max_bytes
    );
    lua_pushinteger(L, session);
    return 1;
}

int transaction(lua_State* L) {
    auto b = checked(L);
    auto timeout = uint_arg(L, 3);
    auto max_rows = uint_arg(L, 4, true);
    auto max_bytes = uint_arg(L, 5, true);
    auto statements = codec::statements(L, 2);
    auto session = lua_service::get(L)->next_sequence();
    (*b->value)->transaction(std::move(statements), session, timeout, max_rows, max_bytes);
    lua_pushinteger(L, session);
    return 1;
}

int take(lua_State* L) {
    auto& state = **checked(L)->value;
    if (!state.ready())
        throw std::runtime_error("no completed libpq operation");
    auto mode = lua_isnoneornil(L, 2) ? std::string("name") : string_arg(L, 2);
    if (mode != "name" && mode != "array")
        throw std::runtime_error("invalid row_mode");
    if (state.failure()) {
        const auto& err = *state.failure();
        lua_createtable(L, 0, 9);
        field(L, "code", err.code);
        field(L, "message", err.message);
        if (!err.sqlstate.empty())
            field(L, "sqlstate", err.sqlstate);
        if (!err.detail.empty())
            field(L, "detail", err.detail);
        if (!err.hint.empty())
            field(L, "hint", err.hint);
        if (!err.constraint.empty())
            field(L, "constraint", err.constraint);
        if (!err.table.empty())
            field(L, "table", err.table);
        lua_pushboolean(L, err.connect_failed);
        lua_setfield(L, -2, "connect_failed");
        if (err.statement_index)
            integer_field(L, "statement_index", static_cast<lua_Integer>(err.statement_index));
        state.consumed();
        return 1;
    }
    const auto top = lua_gettop(L);
    try {
        lua_createtable(L, 0, 3);
        integer_field(L, "transaction_status", state.transaction_status());
        integer_field(L, "result_bytes", static_cast<lua_Integer>(state.result_bytes()));
        lua_newtable(L); // statement results
        lua_Integer statement = 0;
        for (const auto& result: state.results()) {
            codec::push_result(L, result, mode == "name");
            lua_rawseti(L, -2, ++statement);
        }
        lua_setfield(L, -2, "results");
    } catch (const std::exception& e) {
        // Decoding happens on the Lua thread after the native transaction committed.
        // Never misreport a conversion failure as a rolled-back transaction.
        const bool committed = state.transaction_committed();
        state.close();
        lua_settop(L, top);
        lua_createtable(L, 0, 3);
        field(L, "code", "DECODE");
        field(L, "message", e.what());
        if (committed) {
            lua_pushboolean(L, true);
            lua_setfield(L, -2, "committed");
        }
    }
    state.consumed();
    return 1;
}
int create(lua_State* L) {
    auto cache_capacity = lua_isnoneornil(L, 1) ? 100 : uint_arg(L, 1, true);
    moon::pq::load_library(); // synchronize first publication across Moon workers
    auto s = lua_service::get(L);
    auto b = static_cast<box*>(lua_newuserdatauv(L, sizeof(box), 0));
    b->value = nullptr;
    b->owner = s->id();
    if (luaL_newmetatable(L, metaname)) {
        luaL_Reg methods[] = { { "connect", protect<connect> },
                               { "submit", protect<submit> },
                               { "transaction", protect<transaction> },
                               { "take", protect<take> },
                               { "close", protect<close> },
                               { "connected", protect<connected> },
                               { "busy", protect<busy> },
                               { nullptr, nullptr } };
        luaL_newlib(L, methods);
        lua_setfield(L, -2, "__index");
        lua_pushcfunction(L, gc);
        lua_setfield(L, -2, "__gc");
        lua_pushboolean(L, 0);
        lua_setfield(L, -2, "__metatable");
    }
    lua_setmetatable(L, -2);
    auto server = s->get_server();
    auto owner = s->id();
    b->value = new std::shared_ptr<connection>(std::make_shared<connection>(
        s->get_worker()->io_context(),
        [server, owner](int64_t session) {
            server->send_message(moon::message { moon::PTYPE_INTEGER, 0, owner, session, 1 });
        },
        cache_capacity
    ));
    return 1;
}
} // namespace

extern "C" int luaopen_libpq_core(lua_State* L) {
    luaL_Reg functions[] = { { "load", protect<load> },
                             { "new", protect<create> },
                             { nullptr, nullptr } };
    luaL_newlib(L, functions);
    return 1;
}
