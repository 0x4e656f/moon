--- SQLx driver 独立服务入口；通过 moon.new_service 的 file="lrust_sqldriver.lua" 启动。
--- 本文件只负责服务生命周期、连接池、路由和队列；业务 API 使用 require("lrust_sqldriver.client")。
--- 每条 lane 是独立 SQLx 连接加 Lua FIFO 队列；每条最多处理一个请求，多条可以并行等待数据库。
--- 固定业务 key 按哈希映射到 lane；只保证已接收请求在该 lane 内的先后，不等于多次调用的事务。
--- 即使客户端不等待，服务端仍等待本次 SQLx 调用完成后才推进同一 lane，保证顺序。
--- max_queue 限制本服务每条 lane 的等待加当前请求数；queue_capacity 是另一层的 Rust 队列容量。
--- 连接失败不会重放当前 SQL；SOCKET/TIMEOUT/CLOSED 后清理连接，下一条请求再尝试建立。
--- 服务实例应使用不同 conf.name，避免相同底层连接名互相替换；不要从外部关闭或使用 lane 连接。
--- 公开配置/返回类型定义在客户端模块中，本服务无需 require 客户端来执行。
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
---@field running boolean 工作协程是否已启动，用于避免一条 lane 启动多个消费者。
---@field inflight boolean 是否正在处理一个请求，包含其连接建立、执行和必要清理。
---@field db? SqlX 当前连接对象；惰性连接未建立或故障清理后为 nil。
---@field connection_name string lane 专属进程内连接名，由服务名和 lane 索引组成。

--- 校验事务外层列表是从 1 开始的无空洞序列，返回语句数；空列表合法。
--- 服务端独立校验，不信任客户端已做过检查；非法输入抛错，由入队阶段转换成 INVALID。
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

-- 解析启动配置：顶层优先于 opts，缺省使用 SQLx 默认值；池大小和 Lua 队列只在顶层配置。
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

--- 构造 driver 统一错误表；code 供客户端判断失败，kind 保留原始错误分类。
--- message 转成字符串，未提供时使用 code；本函数只包装结果，不记录日志或发送响应。
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

--- 把 SQLx 错误表转换为 driver 错误；无 kind 字段表示不是错误，返回 nil。
--- DB/SOCKET/TIMEOUT/BUSY/CLOSED 保留对应 code，其余 SQLx 错误统一归为 DRIVER。
--- 保留原 kind、sqlstate、constraint 等附加字段，便于业务区分数据库失败和驱动解码失败。
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

--- 按请求类别包装 SQLx 成功结果，保持 driver 客户端统一的返回结构。
--- 查询：data 为行数组；执行/batch：data 为元数据，同时提升 rows_affected/last_insert_id。
--- 事务：data=true，rows_affected 为累计值；num_queries 为事务长度，其余命令为 1。
--- 只负责成功结构映射，调用者必须先排除错误；不会把 SQL NULL 转成 Lua nil。
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

--- 识别跨服务传来的 PG 数组普通标记，重建 SQLx 数组包装器。
--- 其他值（包括 text/json/bytes/null 标记）原样交给 SQLx；此处不编码 JSON 或转换字段类型。
---@param value SqlXParam
---@return SqlXParam
local function restore_param(value)
    if type(value) == "table" and rawget(value, "__sqlx_array") == true then
        return sqlx.array(value.type, value.values)
    end
    return value
end

--- 按命令校验请求载荷，生成供 lane 工作协程使用的内部结构，尚不执行 SQL。
--- 参数化命令保留显式 n，避免尾部 nil 在消息传递后丢失；逐个恢复数组标记。
--- 事务逐条校验 SQL 和参数长度，完整准备后才允许入队；任意异常由 enqueue 返回 INVALID。
--- 原始 query/execute/batch 只接收 SQL 字符串；SQL 片段及 buffer 应已在客户端转换。
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

--- 计算本服务眼中的 lane 负载：Lua 等待队列长度，加当前处理中的请求（至多 1）。
--- 当前请求的连接建立、执行和必要的关闭也计入 inflight；不查询 Rust 或数据库的全局负载。
--- 该值同时用于最小负载路由、max_queue 准入检查以及客户端 len。
---@param ctx LrustSqlDriverLane
---@return integer count 排队与执行中请求总数。
local function lane_load(ctx)
    return list.size(ctx.queue) + (ctx.inflight and 1 or 0)
end

--- 把业务路由 key 转成确定性整数；整数直接使用，字符串按字节计算哈希。
--- 拒绝非整数数值及其他 Lua 类型；它不是加密哈希，不保证不同 key 不碰撞。
--- 最终 lane 由 hash % poolsize + 1 决定，因此 key 不是 lane 编号，改变 poolsize 会改变映射。
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

--- 选择当前负载最小的 lane；负载相同时按上次选择位置轮转，避免总选第一条。
--- 只观察本服务队列，不考虑 SQL 成本或数据库锁等待；不建立连接，也不搬移已排队请求。
--- 用于无亲和性请求，不能保证连续两次调用落到同一连接或按发送顺序执行。
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

--- 根据内部 affinity 选择 lane：false/nil 使用最小负载，整数/字符串使用固定哈希映射。
--- 同一服务、同一 poolsize 和同一 key 始终选中同一 lane，不因当前负载高而改路。
--- 客户端默认接口会把省略的 key 转成 1；只有显式 any 接口才传入 false。
---@param affinity LrustSqlDriverRoute
---@return LrustSqlDriverLane
local function select_lane(affinity)
    if affinity == false or affinity == nil then
        return least_loaded_lane()
    end
    return pool[stable_hash(affinity) % poolsize + 1]
end

--- 等待关闭当前 lane 持有的 SQLx 连接；没有句柄时直接返回。
--- 关闭异常/失败仅记录日志，随后仍清空 ctx.db；此函数不重试关闭、不重放 SQL。
--- 用于服务退出及连接故障后的清理；清空后下一条请求可按原连接名重新建立连接。
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

--- 按 lane 专属名称建立 SQLx 连接，等待连接结果并应用统一的超时、行数和队列配置。
--- 成功写入 ctx.db；失败返回规范化错误而不重试，由当前请求或启动流程决定如何处理。
--- 用于启动预连接、首次惰性连接以及故障后的下一条请求；不是跨 lane 连接复用。
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

--- 在指定 lane 上执行一个已准备的请求；没有连接时先建立，连接失败则不提交本次 SQL。
--- 即使客户端使用不等待接口，服务内部仍等待 SQLx 完成后才执行该 lane 的下一条请求。
--- 参数化请求按显式 n 展开参数；事务整批提交给 SQLx，不拆成多个 lane 请求。
--- SQLx 调用异常/无有效响应转为 DRIVER，正常响应按成功或错误结构包装；此处不自动重试。
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

--- 执行一次 lane 请求，并处理 SOCKET/TIMEOUT/CLOSED 后的连接清理。
--- 这几类失败先等待 close_lane，再交回原错误；后续排队请求才尝试重连。
--- 不会重新执行当前失败请求，因为响应丢失或超时不能证明数据库没有提交写入。
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

--- 向等待调用者返回一次 driver 结果；session=0 表示不等待调用，只记录失败日志。
--- 不等待请求成功时静默结束；此处不重试请求，也不修改结果结构。
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

--- 确保每条 lane 至多有一个工作协程；已有协程时直接返回，不重复启动。
--- 工作协程从 FIFO 队首取请求，等待执行及必要清理，再处理下一条；其他 lane 可独立推进。
--- 未捕获的请求执行异常转换为 DRIVER 并清理连接；处理结果通过 finish_request 返回或记录。
--- 队列暂时为空后释放 running 标记，之后的新请求可再次启动工作协程。
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

--- 处理尚未入队的请求拒绝：有 session 就回错误表，无 session 就记录日志。
--- 用于关闭、参数非法、队列满或未知命令等情况；不访问数据库，不等待队列空位。
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

--- 数据库请求的统一入口：检查接收状态、校验载荷、选择 lane，再检查该 lane 的容量。
--- 关闭中返回 CLOSED，参数/路由非法返回 INVALID，达到 max_queue 返回 BUSY。
--- max_queue 计算等待加当前请求，0 表示不限；固定 key 不会因目标 lane 满而转发到别处。
--- 全部检查通过后才压入 FIFO 并确保工作协程启动；拒绝的请求不会执行部分 SQL。
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

-- 先创建所有 lane 的 Lua 状态；这里尚未建立物理连接，也不启动工作协程。
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

-- 默认启动时逐条建立连接；任意连接失败就清理已打开的连接并中止启动。
-- eager_connect=false 时不预连，每条 lane 的第一条请求负责建立；启动成功不代表数据库可用。
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

--- 构造服务及所有 lane 的状态快照，不执行数据库探活。
--- queue 只含等待请求；inflight 表示当前正在处理请求，running 表示工作协程存活。
--- connected 仅说明持有 Lua 连接对象，不能保证网络正常；统计不等待各 lane 排空。
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

--- 启动幂等的优雅退出流程；立即停止接收新数据库请求，本函数本身不等待退出。
--- 后台协程等所有 lane 已接收请求处理完，再依次尝试关闭连接，最后调用 moon.quit。
--- 排空表示请求已处理，不代表每条 SQL 都成功；已有错误仍按原来的响应/日志规则处理。
--- 关闭期间仍可在服务存活时读取 len/stats；重复关闭通知不会再启动第二次流程。
--- 没有退出完成应答，也没有单独的排空总超时；应由外层服务管理逻辑确认退出。
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

-- 数据库命令统一入队；len/stats 直接读取快照，不等待队列中的 SQL。
-- save_then_quit 仅发起退出流程，不回复完成应答；未知命令通过 reject 报告 COMMAND。
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

-- Moon 正常关闭通知与客户端关闭命令共用同一幂等排空流程；不能保证强制终止时也执行。
moon.shutdown(drain_and_quit)
