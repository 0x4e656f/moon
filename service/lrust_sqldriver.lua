--- SQLx driver 服务入口：连接池、业务 key 路由、FIFO 执行和关闭。
--- 客户端 API 与公开类型位于 lualib/lrust_sqldriver/client.lua。
---@type LrustSqlDriverConfig
local conf = ...

assert(type(conf) == "table" and conf.name,
    'lrust_sqldriver service requires configuration; use require("lrust_sqldriver.client") for client API')

local moon = require("moon")

---@alias LrustSqlDriverCommand 'query'|'query_params'|'execute'|'execute_params'|'batch'|'transaction'
--- 以下为服务内部类型。
---@class LrustSqlDriverPackedParams
---@field [integer] SqlXParam
---@field n integer 参数总数；保留尾部 nil。

---@class LrustSqlDriverPayload
---@field sql? string query/execute/batch 的 SQL。
---@field params? LrustSqlDriverPackedParams 参数化 query/execute 的参数。
---@field queries? SqlXStatement[] transaction 的语句序列。

---@class LrustSqlDriverRequest
---@field sender integer 请求服务 ID。
---@field session integer 会话 ID，0 表示不需要响应。
---@field command LrustSqlDriverCommand
---@field affinity? LrustSqlDriverAffinity|false
---@field payload LrustSqlDriverPayload

---@class LrustSqlDriverQueue
---@field h integer 队列头索引。
---@field t integer 队列尾索引。
---@field [integer] LrustSqlDriverRequest

---@class LrustSqlDriverLane
---@field index integer lane 索引，从 1 开始。
---@field queue LrustSqlDriverQueue
---@field running boolean
---@field inflight boolean
---@field db? SqlX
---@field connection_name string

-- 即使绕过客户端直接发送消息，也必须校验事务序列。
---@param queries SqlXStatement[]|LrustSqlDriverStatement[]
---@return integer count
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

local sqlx = require("ext.sqlx")
local list = require("list")

local tpack = table.pack
local tunpack = table.unpack
local traceback = debug.traceback

---@type LrustSqlDriverOptions
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

---@type table<integer, LrustSqlDriverLane>
local pool = {}
local accepting = true
local shutdown_started = false
local round_robin = 0

---@param code LrustSqlDriverErrorCode
---@param message? any
---@param kind? string
---@return LrustSqlDriverError
local function error_result(code, message, kind)
    return {
        code = code,
        kind = kind or code,
        message = tostring(message or code),
    }
end

---@param res any
---@return LrustSqlDriverError?
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

---@param req LrustSqlDriverRequest
---@param res any 已成功的 SQLx 协议载荷，由 req.command 决定具体结构。
---@return LrustSqlDriverQueryResult|LrustSqlDriverExecuteResult|LrustSqlDriverTransactionResult
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

---@param value SqlXParam
---@return SqlXParam
local function restore_param(value)
    if type(value) == "table" and rawget(value, "__sqlx_array") == true then
        return sqlx.array(value.type, value.values)
    end
    return value
end

---@param command LrustSqlDriverCommand
---@param sql string|SqlXStatement[]
---@param params? LrustSqlDriverPackedParams
---@return LrustSqlDriverPayload
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

---@param ctx LrustSqlDriverLane
---@return integer count 排队与执行中请求总数。
local function lane_load(ctx)
    return list.size(ctx.queue) + (ctx.inflight and 1 or 0)
end

---@param key LrustSqlDriverAffinity
---@return integer hash
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

---@return LrustSqlDriverLane
local function least_loaded_lane()
    ---@type LrustSqlDriverLane|nil
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
    ---@cast best LrustSqlDriverLane poolsize > 0，循环必定选出一条已初始化的 lane。
    round_robin = best.index
    return best
end

---@param affinity LrustSqlDriverRoute
---@return LrustSqlDriverLane
local function select_lane(affinity)
    if affinity == false or affinity == nil then
        return least_loaded_lane()
    end
    return pool[stable_hash(affinity) % poolsize + 1]
end

---@async
---@param ctx LrustSqlDriverLane
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

---@async
---@param ctx LrustSqlDriverLane
---@return SqlX? connection
---@return LrustSqlDriverError? err
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

---@async
---@param ctx LrustSqlDriverLane
---@param req LrustSqlDriverRequest
---@return LrustSqlDriverResult
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

---@async
---@param ctx LrustSqlDriverLane
---@param req LrustSqlDriverRequest
---@return LrustSqlDriverResult
local function execute_request(ctx, req)
    local res = invoke(ctx, req)
    if res.code == "SOCKET" or res.code == "TIMEOUT" or res.code == "CLOSED" then
        close_lane(ctx)
    end
    -- Never replay a request automatically: after a lost response the server
    -- may already have committed a write. The next queued request reconnects.
    return res
end

---@param req LrustSqlDriverRequest
---@param res LrustSqlDriverResult
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

---@param ctx LrustSqlDriverLane
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

---@param sender integer
---@param session integer 0 表示只记录日志，不发送响应。
---@param res LrustSqlDriverError
local function reject(sender, session, res)
    if session == 0 then
        moon.error(string.format("lrust_sqldriver rejected request: [%s] %s", res.code, res.message))
    else
        moon.response("lua", sender, session, res)
    end
end

---@param sender integer
---@param session integer
---@param command LrustSqlDriverCommand
---@param affinity LrustSqlDriverRoute
---@param sql string|SqlXStatement[]
---@param params? LrustSqlDriverPackedParams
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

---@return LrustSqlDriverStats
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

--- 停止接收请求并启动异步排空流程；此函数本身不等待退出。
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
