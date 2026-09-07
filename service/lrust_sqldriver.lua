local moon = require("moon")

-- This module has the same two roles as service/sqldriver.lua:
--
--   * service mode: moon.new_service { file = "lrust_sqldriver.lua", ... }
--   * client mode:  local db = require("lrust_sqldriver")
--
-- Service configuration:
--   name             unique Moon service name
--   url              SQLx connection URL (may also be opts.url/database_url)
--   poolsize         number of FIFO lanes / physical connections (default 1)
--   connect_timeout  connection timeout in milliseconds (default 5000)
--   request_timeout  query/execute/transaction timeout in milliseconds (default 30000)
--   max_rows         maximum rows buffered for one query (default 100000)
--   queue_capacity   SQLx actor queue capacity (default 100; one request is normally in flight)
--   max_queue        max queued + running requests per lane; 0 is unlimited
--   eager_connect    open every lane during startup (default true)

local conf = ...
local client = {}

local function transaction_length(queries)
    assert(type(queries) == "table", "lrust_sqldriver transaction queries must be a table")
    local n, count = #queries, 0
    for key in pairs(queries) do
        assert(math.type(key) == "integer" and key >= 1 and key <= n,
            "lrust_sqldriver transaction queries must be a sequence without holes")
        count = count + 1
    end
    assert(count == n, "lrust_sqldriver transaction queries must be a sequence without holes")
    return n
end

if type(conf) == "table" and conf.name then
    local sqlx = require("ext.sqlx")
    local list = require("list")

    local tpack = table.pack
    local tunpack = table.unpack
    local traceback = debug.traceback

    local opts = conf.opts or {}
    local database_url = conf.url or conf.database_url or opts.url or opts.database_url
    assert(type(database_url) == "string" and database_url ~= "",
        "lrust_sqldriver requires conf.url (or conf.opts.url/database_url)")

    local poolsize = math.tointeger(conf.poolsize or 1)
    assert(poolsize and poolsize > 0, "lrust_sqldriver poolsize must be a positive integer")

    local connect_timeout = math.tointeger(conf.connect_timeout or opts.connect_timeout or 5000)
    assert(connect_timeout and connect_timeout > 0,
        "lrust_sqldriver connect_timeout must be a positive integer")

    local request_timeout = math.tointeger(conf.request_timeout or opts.request_timeout or 30000)
    assert(request_timeout and request_timeout > 0,
        "lrust_sqldriver request_timeout must be a positive integer")

    local max_rows = math.tointeger(conf.max_rows or opts.max_rows or 100000)
    assert(max_rows and max_rows > 0, "lrust_sqldriver max_rows must be a positive integer")

    local queue_capacity = math.tointeger(conf.queue_capacity or opts.queue_capacity or 100)
    assert(queue_capacity and queue_capacity > 0,
        "lrust_sqldriver queue_capacity must be a positive integer")

    local max_queue = math.tointeger(conf.max_queue or 0)
    assert(max_queue and max_queue >= 0,
        "lrust_sqldriver max_queue must be a non-negative integer")

    local pool = {}
    local accepting = true
    local shutdown_started = false
    local round_robin = 0

    local function error_result(code, message, kind)
        return {
            code = code,
            kind = kind or code,
            message = tostring(message or code),
        }
    end

    local function normalize_error(res)
        local kind = type(res) == "table" and rawget(res, "kind") or nil
        if not kind then
            return nil
        end

        local code
        if kind == "DB" then
            code = "DB"
        elseif kind == "SOCKET" then
            code = "SOCKET"
        elseif kind == "TIMEOUT" then
            code = "TIMEOUT"
        elseif kind == "BUSY" or kind == "CLOSED" then
            code = kind
        else
            code = "DRIVER"
        end

        local out = error_result(code, rawget(res, "message"), kind)
        for k, v in pairs(res) do
            if rawget(out, k) == nil then
                out[k] = v
            end
        end
        return out
    end

    local function normalize_success(req, res)
        if req.command == "transaction" then
            return {
                data = true,
                message = type(res) == "table" and res.message or "ok",
                rows_affected = type(res) == "table" and res.rows_affected or nil,
                num_queries = #req.payload.queries,
            }
        end

        if req.command == "execute" or req.command == "execute_params" or req.command == "batch" then
            return {
                data = res,
                rows_affected = type(res) == "table" and res.rows_affected or nil,
                last_insert_id = type(res) == "table" and res.last_insert_id or nil,
                num_queries = 1,
            }
        end

        return {
            data = res,
            num_queries = 1,
        }
    end

    local function restore_param(value)
        if type(value) == "table" and rawget(value, "__sqlx_array") == true then
            return sqlx.array(value.type, value.values)
        end
        return value
    end

    local function prepare_payload(command, sql, params)
        if command == "query" or command == "execute" or command == "batch" then
            assert(type(sql) == "string", "lrust_sqldriver query SQL must be a string")
            return { sql = sql }
        end

        if command == "query_params" or command == "execute_params" then
            assert(type(sql) == "string", "lrust_sqldriver query_params SQL must be a string")
            assert(type(params) == "table", "lrust_sqldriver query_params parameters must be a table")
            local n = params.n or #params
            assert(math.type(n) == "integer" and n >= 0,
                "lrust_sqldriver parameter count must be a non-negative integer")
            local restored = { n = n }
            for i = 1, n do
                restored[i] = restore_param(params[i])
            end
            return { sql = sql, params = restored }
        end

        assert(command == "transaction", "unknown database command: " .. tostring(command))
        assert(type(sql) == "table", "lrust_sqldriver transaction queries must be a table")

        local queries = {}
        for i = 1, transaction_length(sql) do
            local query = sql[i]
            assert(type(query) == "table" and type(query[1]) == "string",
                string.format("lrust_sqldriver transaction query #%d must start with an SQL string", i))
            local n = query.n or #query
            assert(math.type(n) == "integer" and n >= 1,
                "lrust_sqldriver transaction statement length must be a positive integer")
            local prepared = { query[1], n = n }
            for j = 2, n do
                prepared[j] = restore_param(query[j])
            end
            queries[i] = prepared
        end
        return { queries = queries }
    end

    local function lane_load(ctx)
        return list.size(ctx.queue) + (ctx.inflight and 1 or 0)
    end

    local function stable_hash(key)
        if type(key) == "number" then
            local value = math.tointeger(key)
            assert(value, "lrust_sqldriver affinity number must be an integer")
            return value
        end

        assert(type(key) == "string", "lrust_sqldriver affinity must be an integer or string")
        local value = 2166136261
        for i = 1, #key do
            value = ((value ~ string.byte(key, i)) * 16777619) & 0x7FFFFFFFFFFFFFFF
        end
        return value
    end

    local function least_loaded_lane()
        local best
        local best_load
        for offset = 1, poolsize do
            local index = (round_robin + offset - 1) % poolsize + 1
            local ctx = pool[index]
            local load = lane_load(ctx)
            if not best_load or load < best_load then
                best = ctx
                best_load = load
            end
        end
        round_robin = best.index
        return best
    end

    local function select_lane(affinity)
        if affinity == false or affinity == nil then
            return least_loaded_lane()
        end
        return pool[stable_hash(affinity) % poolsize + 1]
    end

    local function close_lane(ctx)
        if not ctx.db then
            return
        end
        local ok, closed, err = xpcall(ctx.db.close, traceback, ctx.db)
        if not ok then
            moon.error(string.format("lrust_sqldriver failed to close lane %d: %s", ctx.index, closed))
        elseif not closed then
            moon.error(string.format("lrust_sqldriver failed to close lane %d: %s",
                ctx.index, type(err) == "table" and err.message or tostring(err)))
        end
        ctx.db = nil
    end

    local function connect_lane(ctx)
        local db, err = sqlx.try_connect(database_url, ctx.connection_name, {
            connect_timeout = connect_timeout,
            request_timeout = request_timeout,
            max_rows = max_rows,
            queue_capacity = queue_capacity,
        })
        if not db then
            return nil, normalize_error(err) or error_result("DRIVER", "unknown SQLx connection error")
        end
        ctx.db = db
        return db
    end

    local function invoke(ctx, req)
        if not ctx.db then
            local _, err = connect_lane(ctx)
            if err then
                return err
            end
        end

        local ok, res, detail = xpcall(function()
            if req.command == "query" then
                return ctx.db:query(req.payload.sql)
            elseif req.command == "query_params" then
                local params = req.payload.params
                return ctx.db:query(req.payload.sql, tunpack(params, 1, params.n))
            elseif req.command == "execute" then
                return ctx.db:execute_wait(req.payload.sql)
            elseif req.command == "execute_params" then
                local params = req.payload.params
                return ctx.db:execute_wait(req.payload.sql, tunpack(params, 1, params.n))
            elseif req.command == "batch" then
                return ctx.db:batch(req.payload.sql)
            else
                return ctx.db:transaction(req.payload.queries)
            end
        end, traceback)

        if not ok then
            return error_result("DRIVER", res)
        end
        if res == false or res == nil then
            return error_result("DRIVER", detail or "SQLx returned no result")
        end

        return normalize_error(res) or normalize_success(req, res)
    end

    local function execute_request(ctx, req)
        local res = invoke(ctx, req)
        if res.code == "SOCKET" or res.code == "TIMEOUT" or res.code == "CLOSED" then
            close_lane(ctx)
        end
        -- Never replay a request automatically: after a lost response the server
        -- may already have committed a write. The next queued request reconnects.
        return res
    end

    local function finish_request(req, res)
        if req.session == 0 then
            if res.code then
                moon.error(string.format(
                    "lrust_sqldriver %s failed on affinity '%s': [%s] %s",
                    req.command,
                    tostring(req.affinity),
                    tostring(res.code),
                    tostring(res.message)))
            end
            return
        end
        moon.response("lua", req.sender, req.session, res)
    end

    local function start_worker(ctx)
        if ctx.running then
            return
        end

        ctx.running = true
        moon.async(function()
            while true do
                local req = list.pop(ctx.queue)
                if not req then
                    break
                end

                ctx.inflight = true
                local ok, res = xpcall(execute_request, traceback, ctx, req)
                if not ok then
                    res = error_result("DRIVER", res)
                    close_lane(ctx)
                end
                finish_request(req, res)
                ctx.inflight = false
            end
            ctx.running = false
        end)
    end

    local function reject(sender, session, res)
        if session == 0 then
            moon.error(string.format("lrust_sqldriver rejected request: [%s] %s", res.code, res.message))
        else
            moon.response("lua", sender, session, res)
        end
    end

    local function enqueue(sender, session, command, affinity, sql, params)
        if not accepting then
            reject(sender, session, error_result("CLOSED", "lrust_sqldriver is shutting down"))
            return
        end

        local ok, payload_or_error = pcall(prepare_payload, command, sql, params)
        if not ok then
            reject(sender, session, error_result("INVALID", payload_or_error))
            return
        end

        local ok_lane, ctx_or_error = pcall(select_lane, affinity)
        if not ok_lane then
            reject(sender, session, error_result("INVALID", ctx_or_error))
            return
        end
        local ctx = ctx_or_error

        if max_queue > 0 and lane_load(ctx) >= max_queue then
            reject(sender, session, error_result(
                "BUSY",
                string.format("lrust_sqldriver lane %d queue is full", ctx.index)))
            return
        end

        list.push(ctx.queue, {
            sender = sender,
            session = session,
            command = command,
            affinity = affinity,
            payload = payload_or_error,
        })
        start_worker(ctx)
    end

    for i = 1, poolsize do
        pool[i] = {
            index = i,
            queue = list.new(),
            running = false,
            inflight = false,
            db = nil,
            -- Keep names stable across service restarts. lrust replaces a stale
            -- same-name handler, while each pool lane still has its own handle.
            connection_name = string.format("lrust_sqldriver:%s:%d", conf.name, i),
        }
    end

    if conf.eager_connect ~= false then
        for _, ctx in ipairs(pool) do
            local _, err = connect_lane(ctx)
            if err then
                for _, opened in ipairs(pool) do
                    close_lane(opened)
                end
                error(string.format(
                    "lrust_sqldriver failed to connect lane %d: [%s] %s",
                    ctx.index,
                    tostring(err.code),
                    tostring(err.message)))
            end
        end
    end

    local function stats()
        local result = {
            accepting = accepting,
            poolsize = poolsize,
            lanes = {},
        }
        for _, ctx in ipairs(pool) do
            result.lanes[ctx.index] = {
                queue = list.size(ctx.queue),
                running = ctx.running,
                inflight = ctx.inflight,
                connected = ctx.db ~= nil,
                name = ctx.connection_name,
            }
        end
        return result
    end

    local function drain_and_quit()
        if shutdown_started then
            return
        end
        shutdown_started = true
        accepting = false

        moon.async(function()
            while true do
                local drained = true
                for _, ctx in ipairs(pool) do
                    if ctx.running or list.size(ctx.queue) > 0 then
                        drained = false
                        break
                    end
                end
                if drained then
                    break
                end
                moon.sleep(10)
            end

            for _, ctx in ipairs(pool) do
                close_lane(ctx)
            end
            moon.quit()
        end)
    end

    moon.dispatch("lua", function(sender, session, command, affinity, sql, params)
        if command == "query" or command == "query_params"
            or command == "execute" or command == "execute_params" or command == "batch"
            or command == "transaction" then
            enqueue(sender, session, command, affinity, sql, params)
        elseif command == "len" then
            local result = {}
            for _, ctx in ipairs(pool) do
                result[ctx.index] = lane_load(ctx)
            end
            moon.response("lua", sender, session, result)
        elseif command == "stats" then
            moon.response("lua", sender, session, stats())
        elseif command == "save_then_quit" then
            drain_and_quit()
        else
            reject(sender, session, error_result("COMMAND", "unknown command: " .. tostring(command)))
        end
    end)

    moon.shutdown(drain_and_quit)
else
    local buffer = require("buffer")
    local json = require("json")
    local tpack = table.pack

    local function sql_string(sql)
        local value_type = type(sql)
        if value_type == "string" then
            return sql
        elseif value_type == "table" then
            return buffer.unpack(json.concat(sql))
        elseif value_type == "userdata" then
            return buffer.unpack(sql)
        end
        error("lrust_sqldriver SQL must be a string, table, or buffer")
    end

    local function prepare_queries(queries)
        assert(type(queries) == "table", "lrust_sqldriver transaction queries must be a table")
        local result = {}
        for i = 1, transaction_length(queries) do
            local query = queries[i]
            assert(type(query) == "table" and query[1] ~= nil,
                string.format("lrust_sqldriver transaction query #%d is invalid", i))
            local n = query.n or #query
            assert(math.type(n) == "integer" and n >= 1,
                "lrust_sqldriver transaction statement length must be a positive integer")
            local copy = { sql_string(query[1]), n = n }
            for j = 2, n do
                copy[j] = query[j]
            end
            result[i] = copy
        end
        return result
    end

    local function query_with_affinity(db, affinity, sql)
        return moon.call("lua", db, "query", affinity, sql_string(sql))
    end

    local function execute_with_affinity(db, affinity, sql)
        moon.send("lua", db, "execute", affinity, sql_string(sql))
    end

    local function execute_wait_with_affinity(db, affinity, sql)
        return moon.call("lua", db, "execute", affinity, sql_string(sql))
    end

    local function query_params_with_affinity(db, affinity, sql, ...)
        return moon.call("lua", db, "query_params", affinity, sql_string(sql), tpack(...))
    end

    local function execute_params_with_affinity(db, affinity, sql, ...)
        moon.send("lua", db, "execute_params", affinity, sql_string(sql), tpack(...))
    end

    local function execute_params_wait_with_affinity(db, affinity, sql, ...)
        return moon.call("lua", db, "execute_params", affinity, sql_string(sql), tpack(...))
    end

    local function batch_with_affinity(db, affinity, sql, wait_result)
        if wait_result then
            return moon.call("lua", db, "batch", affinity, sql_string(sql))
        end
        moon.send("lua", db, "batch", affinity, sql_string(sql))
    end

    local function transaction_with_affinity(db, affinity, queries, wait_result)
        queries = prepare_queries(queries)
        if wait_result then
            return moon.call("lua", db, "transaction", affinity, queries)
        end
        moon.send("lua", db, "transaction", affinity, queries)
    end

    --- Create a PostgreSQL typed-array parameter that survives service IPC.
    function client.array(element_type, values)
        assert(type(element_type) == "string", "lrust_sqldriver array type must be a string")
        assert(type(values) == "table", "lrust_sqldriver array values must be a table")
        return {
            __sqlx_array = true,
            type = element_type,
            values = values,
        }
    end

    function client.null(type_name)
        return {
            __sqlx_param = "null",
            type = type_name or "text",
        }
    end

    function client.text(value)
        assert(type(value) == "string", "lrust_sqldriver.text value must be a string")
        return {
            __sqlx_param = "text",
            value = value,
        }
    end

    function client.json(value)
        return {
            __sqlx_param = "json",
            value = value,
        }
    end

    function client.bytes(value)
        assert(type(value) == "string", "lrust_sqldriver.bytes value must be a string")
        return {
            __sqlx_param = "bytes",
            value = value,
        }
    end

    function client.query(db, sql, affinity)
        return query_with_affinity(db, affinity or 1, sql)
    end

    function client.query_on(db, affinity, sql)
        assert(affinity ~= nil and affinity ~= false, "query_on requires an affinity key")
        return query_with_affinity(db, affinity, sql)
    end

    function client.query_any(db, sql)
        return query_with_affinity(db, false, sql)
    end

    function client.execute(db, sql, affinity)
        execute_with_affinity(db, affinity or 1, sql)
    end

    function client.execute_on(db, affinity, sql)
        assert(affinity ~= nil and affinity ~= false, "execute_on requires an affinity key")
        execute_with_affinity(db, affinity, sql)
    end

    function client.execute_any(db, sql)
        execute_with_affinity(db, false, sql)
    end

    function client.execute_wait(db, sql, affinity)
        return execute_wait_with_affinity(db, affinity or 1, sql)
    end

    function client.execute_wait_on(db, affinity, sql)
        assert(affinity ~= nil and affinity ~= false, "execute_wait_on requires an affinity key")
        return execute_wait_with_affinity(db, affinity, sql)
    end

    function client.execute_wait_any(db, sql)
        return execute_wait_with_affinity(db, false, sql)
    end

    function client.query_params(db, sql, ...)
        return query_params_with_affinity(db, 1, sql, ...)
    end

    function client.query_params_on(db, affinity, sql, ...)
        assert(affinity ~= nil and affinity ~= false, "query_params_on requires an affinity key")
        return query_params_with_affinity(db, affinity, sql, ...)
    end

    function client.query_params_any(db, sql, ...)
        return query_params_with_affinity(db, false, sql, ...)
    end

    function client.execute_params(db, sql, ...)
        execute_params_with_affinity(db, 1, sql, ...)
    end

    function client.execute_params_on(db, affinity, sql, ...)
        assert(affinity ~= nil and affinity ~= false, "execute_params_on requires an affinity key")
        execute_params_with_affinity(db, affinity, sql, ...)
    end

    function client.execute_params_any(db, sql, ...)
        execute_params_with_affinity(db, false, sql, ...)
    end

    function client.execute_params_wait(db, sql, ...)
        return execute_params_wait_with_affinity(db, 1, sql, ...)
    end

    function client.execute_params_wait_on(db, affinity, sql, ...)
        assert(affinity ~= nil and affinity ~= false, "execute_params_wait_on requires an affinity key")
        return execute_params_wait_with_affinity(db, affinity, sql, ...)
    end

    function client.execute_params_wait_any(db, sql, ...)
        return execute_params_wait_with_affinity(db, false, sql, ...)
    end

    function client.batch(db, sql, affinity)
        return batch_with_affinity(db, affinity or 1, sql, true)
    end

    function client.batch_on(db, affinity, sql)
        assert(affinity ~= nil and affinity ~= false, "batch_on requires an affinity key")
        return batch_with_affinity(db, affinity, sql, true)
    end

    function client.batch_any(db, sql)
        return batch_with_affinity(db, false, sql, true)
    end

    function client.execute_batch(db, sql, affinity)
        batch_with_affinity(db, affinity or 1, sql, false)
    end

    function client.transaction(db, queries, affinity)
        return transaction_with_affinity(db, affinity or 1, queries, true)
    end

    function client.transaction_on(db, affinity, queries)
        assert(affinity ~= nil and affinity ~= false, "transaction_on requires an affinity key")
        return transaction_with_affinity(db, affinity, queries, true)
    end

    function client.transaction_any(db, queries)
        return transaction_with_affinity(db, false, queries, true)
    end

    function client.execute_transaction(db, queries, affinity)
        transaction_with_affinity(db, affinity or 1, queries, false)
    end

    function client.execute_transaction_on(db, affinity, queries)
        assert(affinity ~= nil and affinity ~= false, "execute_transaction_on requires an affinity key")
        transaction_with_affinity(db, affinity, queries, false)
    end

    -- Compatibility aliases. Unlike pg.pipe(), SQLx transactions do not return
    -- a result set for each statement.
    client.pipe = client.transaction
    client.execute_pipe = client.execute_transaction

    function client.len(db)
        return moon.call("lua", db, "len")
    end

    function client.stats(db)
        return moon.call("lua", db, "stats")
    end

    function client.save_then_quit(db)
        moon.send("lua", db, "save_then_quit")
    end
end

return client
