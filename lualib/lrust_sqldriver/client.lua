--- SQLx driver 客户端 API；加载本模块不会创建服务或数据库连接。
--- 通过 require("lrust_sqldriver.client") 加载客户端 API，不初始化服务。
--- 一条 lane = 一个物理连接 + FIFO 队列；多次调用需要原子性时请使用 transaction。
local moon = require("moon")
local buffer = require("buffer")
local json = require("json")
local tpack = table.pack

---@alias LrustSqlDriverAffinity integer|string 业务路由 key；不同 key 可能落到同一条 lane。
---@alias LrustSqlDriverRoute LrustSqlDriverAffinity|false|nil 内部路由；false/nil 选择负载最低的 lane。
---@alias LrustSqlDriverSql string|table|buffer_shr_ptr|buffer_ptr SQL 文本、json.concat 可拼接片段或 Moon buffer；不是参数列表。
---@alias LrustSqlDriverErrorCode 'DB'|'SOCKET'|'TIMEOUT'|'BUSY'|'CLOSED'|'DRIVER'|'INVALID'|'COMMAND'

---@class LrustSqlDriverOptions: SqlXConnectOptions
---@field url? string 数据库连接 URL，与 database_url 二选一。
---@field database_url? string url 的兼容别名。

--- moon.new_service 的配置。url/database_url/opts.url/opts.database_url 至少指定一个。
---@class LrustSqlDriverConfig: service_params
---@field url? string 数据库连接 URL，优先级最高。
---@field database_url? string url 的兼容别名。
---@field opts? LrustSqlDriverOptions 兼容的嵌套连接配置；顶层同名配置优先。
---@field poolsize? integer lane/物理连接数，默认 1，必须大于 0。
---@field connect_timeout? integer 建立连接超时，毫秒，默认 5000。
---@field request_timeout? integer 请求开始执行后的超时，毫秒，默认 30000；不含排队时间。
---@field max_rows? integer 每次查询的最大行数，默认 100000。
---@field queue_capacity? integer 每个 Rust 连接的待执行队列容量，默认 100。
---@field max_queue? integer 每条 driver lane 的排队加执行中请求上限；默认 0 表示不限。
---@field eager_connect? boolean 是否在服务启动时建立所有连接，默认 true。

---@class LrustSqlDriverStatement
---@field [integer] LrustSqlDriverSql|SqlXParam # [1] 为 SQL，[2..n] 为绑定参数。
---@field n? integer table.pack 的总长度（包含 SQL）；存在尾部 nil 时必须保留。

---@class LrustSqlDriverError
---@field code LrustSqlDriverErrorCode 业务先检查此字段；错误不会自动重放。
---@field kind string 原始 SQLx 错误类别，或 driver 自身的错误类别。
---@field message string 错误说明；TIMEOUT/SOCKET 不保证写入未提交。
---@field error_kind? string 数据库错误分类。
---@field sqlstate? string 数据库提供的 SQLSTATE。
---@field constraint? string 约束名。
---@field table? string 表名。

---@class LrustSqlDriverSuccess
---@field code? nil 成功时没有 code 字段。
---@field kind? nil 成功时没有 kind 字段。
---@field message? string 成功说明。
---@field num_queries integer 本次语句数；query/execute/batch 为 1，transaction 为语句列表长度。

---@class LrustSqlDriverQueryResult: LrustSqlDriverSuccess
---@field data SqlXRow[] 查询行数组，可能为空；行内 SQL NULL 为 json.null。

---@class LrustSqlDriverExecuteResult: LrustSqlDriverSuccess
---@field data SqlXExecuteResult 原始 SQLx 执行元数据。
---@field rows_affected SqlXUInt64 影响行数，batch 为累计值。
---@field last_insert_id? SqlXUInt64 MySQL/SQLite 适用，PostgreSQL 无此字段。

---@class LrustSqlDriverTransactionResult: LrustSqlDriverSuccess
---@field data true 事务成功标记，不是逐条 SQL 的结果集。
---@field message string 成功时为 ok。
---@field rows_affected SqlXUInt64 事务内累计影响行数。

---@alias LrustSqlDriverQueryResponse LrustSqlDriverQueryResult|LrustSqlDriverError
---@alias LrustSqlDriverWriteResponse LrustSqlDriverExecuteResult|LrustSqlDriverError
---@alias LrustSqlDriverTransactionResponse LrustSqlDriverTransactionResult|LrustSqlDriverError
---@alias LrustSqlDriverResult LrustSqlDriverQueryResult|LrustSqlDriverExecuteResult|LrustSqlDriverTransactionResult|LrustSqlDriverError

---@class LrustSqlDriverLaneStats
---@field queue integer 等待队列长度，不含正在执行的请求。
---@field running boolean 此 lane 的工作协程是否正在运行。
---@field inflight boolean 是否有请求正在执行。
---@field connected boolean 此 lane 是否持有连接对象；不是主动探测数据库存活。
---@field name string 底层 SQLx 连接名。

---@class LrustSqlDriverStats
---@field accepting boolean 是否还接受新请求。
---@field poolsize integer lane 数量。
---@field lanes LrustSqlDriverLaneStats[] 按 lane 索引排列的统计。

---@class LrustSqlDriver
local client = {}

-- 客户端与服务端各自校验事务序列；服务端不能仅依赖客户端校验。
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

---@param sql LrustSqlDriverSql
---@return string
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

---@param queries LrustSqlDriverStatement[]|SqlXStatement[]
---@return SqlXStatement[]
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

---@async
---@param db integer driver 服务 ID。
---@param affinity LrustSqlDriverRoute
---@param sql LrustSqlDriverSql
---@return LrustSqlDriverQueryResponse
local function query_with_affinity(db, affinity, sql)
    return moon.call("lua", db, "query", affinity, sql_string(sql))
end

---@param db integer driver 服务 ID。
---@param affinity LrustSqlDriverRoute
---@param sql LrustSqlDriverSql
local function execute_with_affinity(db, affinity, sql)
    moon.send("lua", db, "execute", affinity, sql_string(sql))
end

---@async
---@param db integer driver 服务 ID。
---@param affinity LrustSqlDriverRoute
---@param sql LrustSqlDriverSql
---@return LrustSqlDriverWriteResponse
local function execute_wait_with_affinity(db, affinity, sql)
    return moon.call("lua", db, "execute", affinity, sql_string(sql))
end

---@async
---@param db integer driver 服务 ID。
---@param affinity LrustSqlDriverRoute
---@param sql LrustSqlDriverSql
---@param ... SqlXParam
---@return LrustSqlDriverQueryResponse
local function query_params_with_affinity(db, affinity, sql, ...)
    return moon.call("lua", db, "query_params", affinity, sql_string(sql), tpack(...))
end

---@param db integer driver 服务 ID。
---@param affinity LrustSqlDriverRoute
---@param sql LrustSqlDriverSql
---@param ... SqlXParam
local function execute_params_with_affinity(db, affinity, sql, ...)
    moon.send("lua", db, "execute_params", affinity, sql_string(sql), tpack(...))
end

---@async
---@param db integer driver 服务 ID。
---@param affinity LrustSqlDriverRoute
---@param sql LrustSqlDriverSql
---@param ... SqlXParam
---@return LrustSqlDriverWriteResponse
local function execute_params_wait_with_affinity(db, affinity, sql, ...)
    return moon.call("lua", db, "execute_params", affinity, sql_string(sql), tpack(...))
end

---@async
---@param db integer
---@param affinity LrustSqlDriverRoute
---@param sql LrustSqlDriverSql
---@param wait_result boolean true 使用 moon.call，false 仅发送请求。
---@overload fun(db: integer, affinity: LrustSqlDriverRoute, sql: LrustSqlDriverSql, wait_result: true): LrustSqlDriverWriteResponse
---@overload fun(db: integer, affinity: LrustSqlDriverRoute, sql: LrustSqlDriverSql, wait_result: false)
---@return LrustSqlDriverWriteResponse|nil
local function batch_with_affinity(db, affinity, sql, wait_result)
    if wait_result then
        return moon.call("lua", db, "batch", affinity, sql_string(sql))
    end
    moon.send("lua", db, "batch", affinity, sql_string(sql))
end

---@async
---@param db integer
---@param affinity LrustSqlDriverRoute
---@param queries LrustSqlDriverStatement[]|SqlXStatement[]
---@param wait_result boolean true 使用 moon.call，false 仅发送请求。
---@overload fun(db: integer, affinity: LrustSqlDriverRoute, queries: LrustSqlDriverStatement[], wait_result: true): LrustSqlDriverTransactionResponse
---@overload fun(db: integer, affinity: LrustSqlDriverRoute, queries: LrustSqlDriverStatement[], wait_result: false)
---@return LrustSqlDriverTransactionResponse|nil
local function transaction_with_affinity(db, affinity, queries, wait_result)
    queries = prepare_queries(queries)
    if wait_result then
        return moon.call("lua", db, "transaction", affinity, queries)
    end
    moon.send("lua", db, "transaction", affinity, queries)
end

--- 构造可跨服务传递的 PostgreSQL 一维数组参数。
---@param element_type SqlXArrayType|string 元素类型，支持别名、大小写归一化和 [] 后缀。
---@param values SqlXArrayValue[] 无空洞序列；NULL 元素使用 json.null。
---@return SqlXArrayParam param
function client.array(element_type, values)
    assert(type(element_type) == "string", "lrust_sqldriver array type must be a string")
    assert(type(values) == "table", "lrust_sqldriver array values must be a table")
    return {
        __sqlx_array = true,
        type = element_type,
        values = values,
    }
end

--- 构造 SQL NULL；PG 非文本 NULL 应指定类型。
---@param type_name? SqlXNullType|string 默认 text。
---@return SqlXNullParam param
function client.null(type_name)
    return {
        __sqlx_param = "null",
        type = type_name or "text",
    }
end

--- 构造 UTF-8 文本参数，不根据内容自动识别 JSON。
---@param value string
---@return SqlXTextParam param
function client.text(value)
    assert(type(value) == "string", "lrust_sqldriver.text value must be a string")
    return {
        __sqlx_param = "text",
        value = value,
    }
end

--- 构造 JSON/JSONB 参数；字符串是 JSON 字符串值，不是原始 JSON 文档。
---@param value SqlXJsonValue
---@return SqlXJsonParam param
function client.json(value)
    return {
        __sqlx_param = "json",
        value = value,
    }
end

--- 构造二进制参数，允许 NUL 和非 UTF-8 字节。
---@param value string
---@return SqlXBytesParam param
function client.bytes(value)
    assert(type(value) == "string", "lrust_sqldriver.bytes value must be a string")
    return {
        __sqlx_param = "bytes",
        value = value,
    }
end

--- 查询并等待结果。成功的行数组在 result.data，错误在 result.code。
--- 未指定 affinity 时使用 key=1；相同 key 固定进入同一条 FIFO lane。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param sql LrustSqlDriverSql SQL 文本、可拼接片段或 buffer；参数需单独传递。
---@param affinity? LrustSqlDriverAffinity 默认 1；不同 key 仍可能映射到同一条 lane。
---@return LrustSqlDriverQueryResponse result 先检查 result.code 判断失败。
function client.query(db, sql, affinity)
    return query_with_affinity(db, affinity or 1, sql)
end

--- 查询并等待结果。成功的行数组在 result.data，错误在 result.code。
--- 显式指定业务 key；相同 key 固定进入同一条 FIFO lane。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param affinity LrustSqlDriverAffinity 业务路由 key（整数或字符串）。
---@param sql LrustSqlDriverSql SQL 文本、可拼接片段或 buffer；参数需单独传递。
---@return LrustSqlDriverQueryResponse result 先检查 result.code 判断失败。
function client.query_on(db, affinity, sql)
    assert(affinity ~= nil and affinity ~= false, "query_on requires an affinity key")
    return query_with_affinity(db, affinity, sql)
end

--- 查询并等待结果。成功的行数组在 result.data，错误在 result.code。
--- 选择当前负载最低的 lane，不保证与其他请求的先后关系。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param sql LrustSqlDriverSql SQL 文本、可拼接片段或 buffer；参数需单独传递。
---@return LrustSqlDriverQueryResponse result 先检查 result.code 判断失败。
function client.query_any(db, sql)
    return query_with_affinity(db, false, sql)
end

--- 提交单条语句，不等待、不返回执行结果；错误仅记录日志。
--- 未指定 affinity 时使用 key=1；相同 key 固定进入同一条 FIFO lane。
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param sql LrustSqlDriverSql SQL 文本、可拼接片段或 buffer；参数需单独传递。
---@param affinity? LrustSqlDriverAffinity 默认 1；不同 key 仍可能映射到同一条 lane。
function client.execute(db, sql, affinity)
    execute_with_affinity(db, affinity or 1, sql)
end

--- 提交单条语句，不等待、不返回执行结果；错误仅记录日志。
--- 显式指定业务 key；相同 key 固定进入同一条 FIFO lane。
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param affinity LrustSqlDriverAffinity 业务路由 key（整数或字符串）。
---@param sql LrustSqlDriverSql SQL 文本、可拼接片段或 buffer；参数需单独传递。
function client.execute_on(db, affinity, sql)
    assert(affinity ~= nil and affinity ~= false, "execute_on requires an affinity key")
    execute_with_affinity(db, affinity, sql)
end

--- 提交单条语句，不等待、不返回执行结果；错误仅记录日志。
--- 选择当前负载最低的 lane，不保证与其他请求的先后关系。
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param sql LrustSqlDriverSql SQL 文本、可拼接片段或 buffer；参数需单独传递。
function client.execute_any(db, sql)
    execute_with_affinity(db, false, sql)
end

--- 执行单条语句并等待影响行数等元数据；不返回查询行。
--- 未指定 affinity 时使用 key=1；相同 key 固定进入同一条 FIFO lane。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param sql LrustSqlDriverSql SQL 文本、可拼接片段或 buffer；参数需单独传递。
---@param affinity? LrustSqlDriverAffinity 默认 1；不同 key 仍可能映射到同一条 lane。
---@return LrustSqlDriverWriteResponse result 先检查 result.code 判断失败。
function client.execute_wait(db, sql, affinity)
    return execute_wait_with_affinity(db, affinity or 1, sql)
end

--- 执行单条语句并等待影响行数等元数据；不返回查询行。
--- 显式指定业务 key；相同 key 固定进入同一条 FIFO lane。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param affinity LrustSqlDriverAffinity 业务路由 key（整数或字符串）。
---@param sql LrustSqlDriverSql SQL 文本、可拼接片段或 buffer；参数需单独传递。
---@return LrustSqlDriverWriteResponse result 先检查 result.code 判断失败。
function client.execute_wait_on(db, affinity, sql)
    assert(affinity ~= nil and affinity ~= false, "execute_wait_on requires an affinity key")
    return execute_wait_with_affinity(db, affinity, sql)
end

--- 执行单条语句并等待影响行数等元数据；不返回查询行。
--- 选择当前负载最低的 lane，不保证与其他请求的先后关系。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param sql LrustSqlDriverSql SQL 文本、可拼接片段或 buffer；参数需单独传递。
---@return LrustSqlDriverWriteResponse result 先检查 result.code 判断失败。
function client.execute_wait_any(db, sql)
    return execute_wait_with_affinity(db, false, sql)
end

--- 参数化查询并等待结果；成功的行数组在 result.data。
--- 默认使用业务 key=1，按抵达 driver 的顺序串行执行。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param sql LrustSqlDriverSql SQL 文本、可拼接片段或 buffer；参数需单独传递。
---@param ... SqlXParam 位置绑定参数，保留尾部 nil。
---@return LrustSqlDriverQueryResponse result 先检查 result.code 判断失败。
function client.query_params(db, sql, ...)
    return query_params_with_affinity(db, 1, sql, ...)
end

--- 参数化查询并等待结果；成功的行数组在 result.data。
--- 显式指定业务 key；相同 key 固定进入同一条 FIFO lane。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param affinity LrustSqlDriverAffinity 业务路由 key（整数或字符串）。
---@param sql LrustSqlDriverSql SQL 文本、可拼接片段或 buffer；参数需单独传递。
---@param ... SqlXParam 位置绑定参数，保留尾部 nil。
---@return LrustSqlDriverQueryResponse result 先检查 result.code 判断失败。
function client.query_params_on(db, affinity, sql, ...)
    assert(affinity ~= nil and affinity ~= false, "query_params_on requires an affinity key")
    return query_params_with_affinity(db, affinity, sql, ...)
end

--- 参数化查询并等待结果；成功的行数组在 result.data。
--- 选择当前负载最低的 lane，不保证与其他请求的先后关系。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param sql LrustSqlDriverSql SQL 文本、可拼接片段或 buffer；参数需单独传递。
---@param ... SqlXParam 位置绑定参数，保留尾部 nil。
---@return LrustSqlDriverQueryResponse result 先检查 result.code 判断失败。
function client.query_params_any(db, sql, ...)
    return query_params_with_affinity(db, false, sql, ...)
end

--- 提交参数化语句，不等待、不返回执行结果；错误仅记录日志。
--- 默认使用业务 key=1，按抵达 driver 的顺序串行执行。
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param sql LrustSqlDriverSql SQL 文本、可拼接片段或 buffer；参数需单独传递。
---@param ... SqlXParam 位置绑定参数，保留尾部 nil。
function client.execute_params(db, sql, ...)
    execute_params_with_affinity(db, 1, sql, ...)
end

--- 提交参数化语句，不等待、不返回执行结果；错误仅记录日志。
--- 显式指定业务 key；相同 key 固定进入同一条 FIFO lane。
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param affinity LrustSqlDriverAffinity 业务路由 key（整数或字符串）。
---@param sql LrustSqlDriverSql SQL 文本、可拼接片段或 buffer；参数需单独传递。
---@param ... SqlXParam 位置绑定参数，保留尾部 nil。
function client.execute_params_on(db, affinity, sql, ...)
    assert(affinity ~= nil and affinity ~= false, "execute_params_on requires an affinity key")
    execute_params_with_affinity(db, affinity, sql, ...)
end

--- 提交参数化语句，不等待、不返回执行结果；错误仅记录日志。
--- 选择当前负载最低的 lane，不保证与其他请求的先后关系。
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param sql LrustSqlDriverSql SQL 文本、可拼接片段或 buffer；参数需单独传递。
---@param ... SqlXParam 位置绑定参数，保留尾部 nil。
function client.execute_params_any(db, sql, ...)
    execute_params_with_affinity(db, false, sql, ...)
end

--- 执行参数化语句并等待影响行数等元数据。
--- 默认使用业务 key=1，按抵达 driver 的顺序串行执行。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param sql LrustSqlDriverSql SQL 文本、可拼接片段或 buffer；参数需单独传递。
---@param ... SqlXParam 位置绑定参数，保留尾部 nil。
---@return LrustSqlDriverWriteResponse result 先检查 result.code 判断失败。
function client.execute_params_wait(db, sql, ...)
    return execute_params_wait_with_affinity(db, 1, sql, ...)
end

--- 执行参数化语句并等待影响行数等元数据。
--- 显式指定业务 key；相同 key 固定进入同一条 FIFO lane。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param affinity LrustSqlDriverAffinity 业务路由 key（整数或字符串）。
---@param sql LrustSqlDriverSql SQL 文本、可拼接片段或 buffer；参数需单独传递。
---@param ... SqlXParam 位置绑定参数，保留尾部 nil。
---@return LrustSqlDriverWriteResponse result 先检查 result.code 判断失败。
function client.execute_params_wait_on(db, affinity, sql, ...)
    assert(affinity ~= nil and affinity ~= false, "execute_params_wait_on requires an affinity key")
    return execute_params_wait_with_affinity(db, affinity, sql, ...)
end

--- 执行参数化语句并等待影响行数等元数据。
--- 选择当前负载最低的 lane，不保证与其他请求的先后关系。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param sql LrustSqlDriverSql SQL 文本、可拼接片段或 buffer；参数需单独传递。
---@param ... SqlXParam 位置绑定参数，保留尾部 nil。
---@return LrustSqlDriverWriteResponse result 先检查 result.code 判断失败。
function client.execute_params_wait_any(db, sql, ...)
    return execute_params_wait_with_affinity(db, false, sql, ...)
end

--- 等待多条原始 SQL 执行完成；不接受绑定参数，不承诺事务原子性。
--- 未指定 affinity 时使用 key=1；相同 key 固定进入同一条 FIFO lane。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param sql LrustSqlDriverSql SQL 文本、可拼接片段或 buffer；参数需单独传递。
---@param affinity? LrustSqlDriverAffinity 默认 1；不同 key 仍可能映射到同一条 lane。
---@return LrustSqlDriverWriteResponse result 先检查 result.code 判断失败。
function client.batch(db, sql, affinity)
    return batch_with_affinity(db, affinity or 1, sql, true)
end

--- 等待多条原始 SQL 执行完成；不接受绑定参数，不承诺事务原子性。
--- 显式指定业务 key；相同 key 固定进入同一条 FIFO lane。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param affinity LrustSqlDriverAffinity 业务路由 key（整数或字符串）。
---@param sql LrustSqlDriverSql SQL 文本、可拼接片段或 buffer；参数需单独传递。
---@return LrustSqlDriverWriteResponse result 先检查 result.code 判断失败。
function client.batch_on(db, affinity, sql)
    assert(affinity ~= nil and affinity ~= false, "batch_on requires an affinity key")
    return batch_with_affinity(db, affinity, sql, true)
end

--- 等待多条原始 SQL 执行完成；不接受绑定参数，不承诺事务原子性。
--- 选择当前负载最低的 lane，不保证与其他请求的先后关系。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param sql LrustSqlDriverSql SQL 文本、可拼接片段或 buffer；参数需单独传递。
---@return LrustSqlDriverWriteResponse result 先检查 result.code 判断失败。
function client.batch_any(db, sql)
    return batch_with_affinity(db, false, sql, true)
end

--- 发送多条原始 SQL；不绑定参数、不等待结果，错误仅记录日志。
--- 未指定 affinity 时使用 key=1；相同 key 固定进入同一条 FIFO lane。
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param sql LrustSqlDriverSql SQL 文本、可拼接片段或 buffer；参数需单独传递。
---@param affinity? LrustSqlDriverAffinity 默认 1；不同 key 仍可能映射到同一条 lane。
function client.execute_batch(db, sql, affinity)
    batch_with_affinity(db, affinity or 1, sql, false)
end

--- 在一个事务内执行语句列表；返回累计影响行数，不返回逐条查询行。
--- 未指定 affinity 时使用 key=1；相同 key 固定进入同一条 FIFO lane。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param queries LrustSqlDriverStatement[] 无空洞序列；语句尾部 nil 使用 table.pack 保留。
---@param affinity? LrustSqlDriverAffinity 默认 1；不同 key 仍可能映射到同一条 lane。
---@return LrustSqlDriverTransactionResponse result 先检查 result.code 判断失败。
function client.transaction(db, queries, affinity)
    return transaction_with_affinity(db, affinity or 1, queries, true)
end

--- 在一个事务内执行语句列表；返回累计影响行数，不返回逐条查询行。
--- 显式指定业务 key；相同 key 固定进入同一条 FIFO lane。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param affinity LrustSqlDriverAffinity 业务路由 key（整数或字符串）。
---@param queries LrustSqlDriverStatement[] 无空洞序列；语句尾部 nil 使用 table.pack 保留。
---@return LrustSqlDriverTransactionResponse result 先检查 result.code 判断失败。
function client.transaction_on(db, affinity, queries)
    assert(affinity ~= nil and affinity ~= false, "transaction_on requires an affinity key")
    return transaction_with_affinity(db, affinity, queries, true)
end

--- 在一个事务内执行语句列表；返回累计影响行数，不返回逐条查询行。
--- 选择当前负载最低的 lane，不保证与其他请求的先后关系。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param queries LrustSqlDriverStatement[] 无空洞序列；语句尾部 nil 使用 table.pack 保留。
---@return LrustSqlDriverTransactionResponse result 先检查 result.code 判断失败。
function client.transaction_any(db, queries)
    return transaction_with_affinity(db, false, queries, true)
end

--- 提交事务但不等待执行结果；错误仅记录日志，不自动重放。
--- 未指定 affinity 时使用 key=1；相同 key 固定进入同一条 FIFO lane。
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param queries LrustSqlDriverStatement[] 无空洞序列；语句尾部 nil 使用 table.pack 保留。
---@param affinity? LrustSqlDriverAffinity 默认 1；不同 key 仍可能映射到同一条 lane。
function client.execute_transaction(db, queries, affinity)
    transaction_with_affinity(db, affinity or 1, queries, false)
end

--- 提交事务但不等待执行结果；错误仅记录日志，不自动重放。
--- 显式指定业务 key；相同 key 固定进入同一条 FIFO lane。
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param affinity LrustSqlDriverAffinity 业务路由 key（整数或字符串）。
---@param queries LrustSqlDriverStatement[] 无空洞序列；语句尾部 nil 使用 table.pack 保留。
function client.execute_transaction_on(db, affinity, queries)
    assert(affinity ~= nil and affinity ~= false, "execute_transaction_on requires an affinity key")
    transaction_with_affinity(db, affinity, queries, false)
end

--- transaction 的兼容别名；这是事务，不是返回逐条结果的 PG pipeline。
client.pipe = client.transaction
--- execute_transaction 的兼容别名；不等待、不返回执行结果。
client.execute_pipe = client.execute_transaction

--- 查询各 lane 的负载，包含排队和正在执行的请求。
---@async
---@param db integer driver 服务 ID。
---@return integer[] lengths 按 lane 索引排列，从 1 开始。
function client.len(db)
    return moon.call("lua", db, "len")
end

--- 获取服务接收状态和各 lane 的队列/连接状态。
---@async
---@param db integer driver 服务 ID。
---@return LrustSqlDriverStats stats
function client.stats(db)
    return moon.call("lua", db, "stats")
end

--- 通知 driver 停止接收请求，排空队列后关闭连接并退出。
--- 仅发送通知，不等待服务退出，也没有完成确认返回值。
---@param db integer driver 服务 ID。
function client.save_then_quit(db)
    moon.send("lua", db, "save_then_quit")
end

return client
