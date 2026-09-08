--- SQLx driver 客户端 API，通过 require("lrust_sqldriver.client") 使用；加载不创建服务或数据库连接。
--- 先用 moon.new_service 启动 file="lrust_sqldriver.lua"，再把返回的服务 ID 作为各 API 的 db 参数。
--- 用法：local driver = require("lrust_sqldriver.client")；driver.query(db, "SELECT 1 AS value")。
--- 每条 lane 是一个独立连接加 FIFO 队列；不同 key 可能碰撞，同 key 按抵达服务的顺序串行。
--- 默认接口使用 key=1，_on 显式指定业务 key，_any 选择最低负载；key 不是 lane 编号。
--- poolsize=1 时全部数据库请求串行；多 lane 不能保证互相之间的执行/完成顺序。
--- 同 key 只保证单次请求的排序，多次调用之间仍可能插入其他请求；原子执行请使用 transaction。
--- query 系列返回 data 行数组，等待执行返回元数据，transaction 成功为 data=true；先检查 result.code。
--- 已收到的 driver 错误以 code/kind/message 表示；客户端本地校验、序列化错误仍可能直接抛出。
--- 本模块原样透传 moon.call；服务不可达或等待被中断等 Moon 层失败不保证是上述错误表。
--- @async 接口需要在可挂起的 Moon 协程中调用；不等待接口的返回不代表请求入队或数据库提交成功。
--- request_timeout 不包含 driver/Rust 队列等待，也不是 moon.call 的总等待期限；SQL 不自动重放。
--- 超时/断线不会等待旧 SQL 执行结束才返回，数据库端仍可能执行；跨故障的业务顺序不能仅靠 lane。
--- 无法跨服务打包的结果（如 NaN 或过深 JSON）返回 DRIVER，lane 继续处理后续请求。
--- 建连失败按 lane 指数退避，冷却期间请求直接返回 connect_failed/retry_after_ms，未提交 SQL。
--- 所有字段解码和绑定限制沿用 ext.sqlx；当前 NUMERIC 原生解码尚不支持，并未自动转为字符串。
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

--- moon.new_service 的配置。url/database_url/opts.url/opts.database_url 至少指定一个，按此顺序取值。
--- file 使用 lrust_sqldriver.lua；name 参与底层连接命名，各独立 driver 实例不要使用相同 name。
--- 配置用于服务启动，不是传给客户端 require；池大小在服务生命周期中固定，不支持在线调整。
---@class LrustSqlDriverConfig: service_params
---@field url? string 数据库连接 URL，优先级最高。
---@field database_url? string url 的兼容别名。
---@field opts? LrustSqlDriverOptions 兼容的嵌套连接配置；顶层同名配置优先。
---@field poolsize? integer lane 数/最大并行处理请求数，默认 1，必须大于 0；各 lane 独立连接，惰性模式按需建立。
---@field connect_timeout? integer 建立连接超时，毫秒，默认 5000。
---@field request_timeout? integer Rust 开始执行后的超时，毫秒，默认 30000；不含两层队列等待，事务/batch 按整个请求计时。
---@field max_rows? integer 每次查询的最大行数，默认 100000；超过后返回错误，不是分页或截断返回。
---@field queue_capacity? integer 每个 Rust 连接的等待队列容量，默认 100；不是 driver 的 max_queue。
---@field reconnect_initial_delay? integer 首次建连失败后的冷却毫秒数，默认 250；连续失败翻倍，0 禁用退避。
---@field reconnect_max_delay? integer 冷却上限毫秒数，默认 5000；正整数且不小于 reconnect_initial_delay，成功建连后重置。
---@field reconnect_log_interval? integer 不等待调用的建连失败日志间隔，毫秒，默认 5000；0 不限速，不影响普通 SQL 错误。
---@field max_queue? integer 每条 driver lane 的排队加执行中请求上限；默认 0 表示不限。
---@field eager_connect? boolean 默认 true，启动时建立全部连接，失败则中止启动；false 由各 lane 第一条请求按需建立。

---@class LrustSqlDriverStatement
---@field [integer] LrustSqlDriverSql|SqlXParam # [1] 为 SQL，[2..n] 为绑定参数。
---@field n? integer table.pack 的总长度（包含 SQL）；存在尾部 nil 时必须保留。

---@class LrustSqlDriverError
---@field connect_failed? boolean true 表示本次建连/冷却失败，SQL 未提交；普通 SQL 错误、断线、执行超时不能据此推断提交状态。
---@field retry_after_ms? integer 本 lane/连接的剩余冷却毫秒数；到期不代表数据库恢复，也不会自动重试。
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
---@field inflight boolean 是否有当前请求正在处理，包含连接建立、SQL 执行和必要的故障清理。
---@field connected boolean 此 lane 是否持有连接对象；不是主动探测数据库存活。
---@field name string 底层 SQLx 连接名。

---@class LrustSqlDriverStats
---@field accepting boolean 是否还接受新请求。
---@field poolsize integer lane 数量。
---@field lanes LrustSqlDriverLaneStats[] 按 lane 索引排列的统计。

---@class LrustSqlDriver
local client = {}

--- 校验事务外层列表是从 1 开始的无空洞序列，返回语句数；空列表合法。
--- 客户端检查失败会在发送消息前抛出 Lua 错误；服务端仍会独立复检。
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

--- 把 SQL 输入规范化成可跨服务传输的字符串，不执行 SQL。
--- string 直接使用；table 按 json.concat 规则拼接后解包；Moon buffer 读取为字符串。
--- table 是 SQL 片段，不是 {sql, param1, ...} 参数列表，也不会自动生成占位符；绑定值应走参数化接口。
--- 非法输入或不可解包的 buffer 会在发送消息前抛出错误。
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

--- 完整校验并复制事务语句列表，把每条语句的 SQL 片段/buffer 转成字符串。
--- 每条语句保留 n，支持 table.pack 带来的尾部 nil；参数值只做浅拷贝，不在此编码 JSON。
--- 外层或任意语句非法会直接抛错，不会发送已经准备好的部分列表。
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

--- 把无绑定参数的查询按内部路由封装为一次 moon.call，等待并原样返回 driver 响应。
--- SQL 先规范化为字符串；不拆包 result.data，也不对 Moon 通信错误做统一包装。
---@async
---@param db integer driver 服务 ID。
---@param affinity LrustSqlDriverRoute
---@param sql LrustSqlDriverSql
---@return LrustSqlDriverQueryResponse
local function query_with_affinity(db, affinity, sql)
    return moon.call("lua", db, "query", affinity, sql_string(sql))
end

--- 发送无绑定参数的 execute 消息，不等待 driver 接收或数据库执行完成。
--- 内部 affinity 可以为 false；公开默认入口会自行转换为 key=1。
---@param db integer driver 服务 ID。
---@param affinity LrustSqlDriverRoute
---@param sql LrustSqlDriverSql
local function execute_with_affinity(db, affinity, sql)
    moon.send("lua", db, "execute", affinity, sql_string(sql))
end

--- 以 moon.call 发送 execute 命令，等待执行元数据；与不等待版使用同一服务端命令。
--- 是否应答由消息 session 区分，SQL 在客户端先规范化为字符串。
---@async
---@param db integer driver 服务 ID。
---@param affinity LrustSqlDriverRoute
---@param sql LrustSqlDriverSql
---@return LrustSqlDriverWriteResponse
local function execute_wait_with_affinity(db, affinity, sql)
    return moon.call("lua", db, "execute", affinity, sql_string(sql))
end

--- 发送参数化查询并等待 driver 结果；用 table.pack 封装变长参数，保留尾部 nil。
--- affinity 只负责路由，不占数据库参数位置；本函数不会把业务 key 自动绑定进 SQL。
---@async
---@param db integer driver 服务 ID。
---@param affinity LrustSqlDriverRoute
---@param sql LrustSqlDriverSql
---@param ... SqlXParam
---@return LrustSqlDriverQueryResponse
local function query_params_with_affinity(db, affinity, sql, ...)
    return moon.call("lua", db, "query_params", affinity, sql_string(sql), tpack(...))
end

--- 发送参数化 execute 消息但不等待结果；用 table.pack 保留参数总数及尾部 nil。
--- 只保证客户端完成消息发送调用，不提供入队成功或事务提交确认。
---@param db integer driver 服务 ID。
---@param affinity LrustSqlDriverRoute
---@param sql LrustSqlDriverSql
---@param ... SqlXParam
local function execute_params_with_affinity(db, affinity, sql, ...)
    moon.send("lua", db, "execute_params", affinity, sql_string(sql), tpack(...))
end

--- 发送参数化 execute 命令并等待执行元数据；按显式参数总数保留尾部 nil。
--- 返回结构由 driver 生成，不会返回 SELECT/RETURNING 行。
---@async
---@param db integer driver 服务 ID。
---@param affinity LrustSqlDriverRoute
---@param sql LrustSqlDriverSql
---@param ... SqlXParam
---@return LrustSqlDriverWriteResponse
local function execute_params_wait_with_affinity(db, affinity, sql, ...)
    return moon.call("lua", db, "execute_params", affinity, sql_string(sql), tpack(...))
end

--- 把原始多语句 SQL 规范化后作为单个 batch 请求发送，不接受绑定参数。
--- wait_result=true 时等待结果；false 时仅发送消息，不等待 lane 执行完成。
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

--- 先完整准备事务列表，再以一个 transaction 请求发往目标 lane，不逐条发送。
--- wait_result=true 时等待事务结果；false 时只发消息，但客户端校验仍会同步抛错。
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

--- 构造可跨 Moon 服务传递的 PostgreSQL 一维数组参数，不加载 SQLx 或建立连接。
--- 普通 table 默认是 JSON；数组必须使用此包装器，{} 表示空数组，SQL NULL 元素用 json.null。
--- 构造时只检查 element_type/values 的 Lua 类型；元素类型、范围及内容由服务端 SQLx 在提交时校验。
--- 不会深拷贝 values；发送查询前对该表的修改会影响绑定值，MySQL/SQLite 不支持 PG 数组参数。
--- 用法：driver.query_params(db, "SELECT $1::BIGINT[] AS value", driver.array("int8", {1, json.null, 3}))。
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

--- 构造带 SQL 类型的 NULL 参数，不建立连接；类型合法性在服务端提交 SQL 时校验。
--- 裸 nil/json.null 默认绑定 TEXT NULL；PG 非文本 NULL 应明确指定类型，例如 int8、uuid。
--- driver.null("jsonb") 是 SQL NULL；driver.json(nil) 则是 JSON 文档中的 null。
--- 返回普通标记表，适用于参数化接口和事务语句，不用于表示查询结果中的 NULL。
---@param type_name? SqlXNullType|string 默认 text。
---@return SqlXNullParam param
function client.null(type_name)
    return {
        __sqlx_param = "null",
        type = type_name or "text",
    }
end

--- 显式构造 UTF-8 TEXT 参数，不根据 { / [ 前缀猜测 JSON；普通 Lua 字符串已有相同行为。
--- 非 string 立即抛错；UTF-8 合法性由服务端 SQLx 校验，原始二进制应使用 bytes。
--- 该值是绑定参数而非 SQL 片段；日期/UUID 文本可在 SQL 中使用 $1::TEXT::DATE 或 $1::TEXT::UUID。
---@param value string UTF-8 文本；不是直接拼接进 SQL 的片段。
---@return SqlXTextParam param
function client.text(value)
    assert(type(value) == "string", "lrust_sqldriver.text value must be a string")
    return {
        __sqlx_param = "text",
        value = value,
    }
end

--- 构造 JSON/JSONB 绑定参数，支持 Lua 对象、数组及字符串/数字/布尔等标量。
--- 字符串是 JSON 字符串值，不会解析成原始 JSON 文档；已有 JSON 文本应先解码成 Lua 值。
--- nil/json.null 表示 JSON null；SQL NULL 应使用 driver.null("jsonb")。
--- 构造时不深拷贝或编码 table；随请求跨服务传递后，由 SQLx 编码并报告非法值。
--- 空 table 为 []；对象键限 UTF-8 字符串/整数，数值必须有限。还需遵守 Moon 跨服务序列化深度限制。
---@param value SqlXJsonValue 待编码的 Lua 值；nil/json.null 表示 JSON null。
---@return SqlXJsonParam param
function client.json(value)
    return {
        __sqlx_param = "json",
        value = value,
    }
end

--- 构造原始二进制绑定参数，PG 对应 BYTEA，允许 NUL 和非法 UTF-8 字节。
--- 非 string 立即抛错；字符串内容就是实际字节，不解析十六进制或 Base64。
--- 返回可跨服务序列化的标记表，适用于参数化接口和事务语句。
---@param value string 原始字节串，可为空，不要求 UTF-8。
---@return SqlXBytesParam param
function client.bytes(value)
    assert(type(value) == "string", "lrust_sqldriver.bytes value must be a string")
    return {
        __sqlx_param = "bytes",
        value = value,
    }
end

--- 执行单条无绑定参数的查询并等待结果，也支持写入语句的 RETURNING 行。
--- 未指定 affinity 时使用 key=1；不同 key 可能落到同一 lane，传 false 也会回退到 1，不代表 any 路由。
--- 本接口不接收绑定值；SQL table 仅用于拼接片段，需要 $1 等绑定时请用 query_params 系列。
--- 收到 driver 响应后先检查 result.code；成功行数组在 result.data，没有记录为 {}，SQL NULL 为 json.null。
--- 重复列名需用 AS 区分，超出 max_rows 或字段解码失败会返回错误；NUMERIC 等限制与 ext.sqlx 相同。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param sql LrustSqlDriverSql 单条 SQL、片段或 buffer；本接口不接受绑定参数。
---@param affinity? LrustSqlDriverAffinity 默认 1；业务 key 而非 lane 编号，false 也回退到 1。
---@return LrustSqlDriverQueryResponse result 先检查 result.code 判断失败。
function client.query(db, sql, affinity)
    return query_with_affinity(db, affinity or 1, sql)
end

--- 执行单条无绑定参数的查询并等待结果，也支持写入语句的 RETURNING 行。
--- 按显式业务 key 固定路由；相同 key 按抵达 driver 的顺序 FIFO 执行，key 不是 lane 编号。
--- 本接口不接收绑定值；SQL table 仅用于拼接片段，需要 $1 等绑定时请用 query_params 系列。
--- 收到 driver 响应后先检查 result.code；成功行数组在 result.data，没有记录为 {}，SQL NULL 为 json.null。
--- 重复列名需用 AS 区分，超出 max_rows 或字段解码失败会返回错误；NUMERIC 等限制与 ext.sqlx 相同。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param affinity LrustSqlDriverAffinity 业务 key（整数或字符串），仅用于路由，不自动绑定进 SQL。
---@param sql LrustSqlDriverSql 单条 SQL、片段或 buffer；本接口不接受绑定参数。
---@return LrustSqlDriverQueryResponse result 先检查 result.code 判断失败。
function client.query_on(db, affinity, sql)
    assert(affinity ~= nil and affinity ~= false, "query_on requires an affinity key")
    return query_with_affinity(db, affinity, sql)
end

--- 执行单条无绑定参数的查询并等待结果，也支持写入语句的 RETURNING 行。
--- 由 driver 选择当前负载最低的 lane，同负载时轮转；不保证与前后请求使用同一连接或按发送顺序完成。
--- 本接口不接收绑定值；SQL table 仅用于拼接片段，需要 $1 等绑定时请用 query_params 系列。
--- 收到 driver 响应后先检查 result.code；成功行数组在 result.data，没有记录为 {}，SQL NULL 为 json.null。
--- 重复列名需用 AS 区分，超出 max_rows 或字段解码失败会返回错误；NUMERIC 等限制与 ext.sqlx 相同。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param sql LrustSqlDriverSql 单条 SQL、片段或 buffer；本接口不接受绑定参数。
---@return LrustSqlDriverQueryResponse result 先检查 result.code 判断失败。
function client.query_any(db, sql)
    return query_with_affinity(db, false, sql)
end

--- 发送单条无绑定参数的执行请求，不等待入队或执行确认，不返回影响行数。
--- 未指定 affinity 时使用 key=1；不同 key 可能落到同一 lane，传 false 也会回退到 1，不代表 any 路由。
--- 需要绑定参数时使用 execute_params 系列；服务内部仍等待 SQLx 完成后才处理本 lane 的下一条。
--- driver 收到后的拒绝/执行错误只记服务日志；客户端参数校验或消息序列化错误仍可能抛出。
--- 调用返回不表示写入成功；需要确认结果请使用对应等待版，错误请求不会自动重放。
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param sql LrustSqlDriverSql 单条 SQL、片段或 buffer；本接口不接受绑定参数。
---@param affinity? LrustSqlDriverAffinity 默认 1；业务 key 而非 lane 编号，false 也回退到 1。
function client.execute(db, sql, affinity)
    execute_with_affinity(db, affinity or 1, sql)
end

--- 发送单条无绑定参数的执行请求，不等待入队或执行确认，不返回影响行数。
--- 按显式业务 key 固定路由；相同 key 按抵达 driver 的顺序 FIFO 执行，key 不是 lane 编号。
--- 需要绑定参数时使用 execute_params 系列；服务内部仍等待 SQLx 完成后才处理本 lane 的下一条。
--- driver 收到后的拒绝/执行错误只记服务日志；客户端参数校验或消息序列化错误仍可能抛出。
--- 调用返回不表示写入成功；需要确认结果请使用对应等待版，错误请求不会自动重放。
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param affinity LrustSqlDriverAffinity 业务 key（整数或字符串），仅用于路由，不自动绑定进 SQL。
---@param sql LrustSqlDriverSql 单条 SQL、片段或 buffer；本接口不接受绑定参数。
function client.execute_on(db, affinity, sql)
    assert(affinity ~= nil and affinity ~= false, "execute_on requires an affinity key")
    execute_with_affinity(db, affinity, sql)
end

--- 发送单条无绑定参数的执行请求，不等待入队或执行确认，不返回影响行数。
--- 由 driver 选择当前负载最低的 lane，同负载时轮转；不保证与前后请求使用同一连接或按发送顺序完成。
--- 需要绑定参数时使用 execute_params 系列；服务内部仍等待 SQLx 完成后才处理本 lane 的下一条。
--- driver 收到后的拒绝/执行错误只记服务日志；客户端参数校验或消息序列化错误仍可能抛出。
--- 调用返回不表示写入成功；需要确认结果请使用对应等待版，错误请求不会自动重放。
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param sql LrustSqlDriverSql 单条 SQL、片段或 buffer；本接口不接受绑定参数。
function client.execute_any(db, sql)
    execute_with_affinity(db, false, sql)
end

--- 执行单条无绑定参数的语句并等待写入元数据，不返回 SELECT/RETURNING 行。
--- 未指定 affinity 时使用 key=1；不同 key 可能落到同一 lane，传 false 也会回退到 1，不代表 any 路由。
--- 需要绑定业务值时使用 execute_params_wait 系列，不要把 affinity 当作 SQL 参数。
--- 先检查 result.code；成功可读取 result.rows_affected，result.data 为原始 SQLx 元数据。
--- PG 自增值请用 query 系列执行 INSERT ... RETURNING；TIMEOUT/SOCKET 不证明写入未提交，driver 不自动重放。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param sql LrustSqlDriverSql 单条 SQL、片段或 buffer；本接口不接受绑定参数。
---@param affinity? LrustSqlDriverAffinity 默认 1；业务 key 而非 lane 编号，false 也回退到 1。
---@return LrustSqlDriverWriteResponse result 先检查 result.code 判断失败。
function client.execute_wait(db, sql, affinity)
    return execute_wait_with_affinity(db, affinity or 1, sql)
end

--- 执行单条无绑定参数的语句并等待写入元数据，不返回 SELECT/RETURNING 行。
--- 按显式业务 key 固定路由；相同 key 按抵达 driver 的顺序 FIFO 执行，key 不是 lane 编号。
--- 需要绑定业务值时使用 execute_params_wait 系列，不要把 affinity 当作 SQL 参数。
--- 先检查 result.code；成功可读取 result.rows_affected，result.data 为原始 SQLx 元数据。
--- PG 自增值请用 query 系列执行 INSERT ... RETURNING；TIMEOUT/SOCKET 不证明写入未提交，driver 不自动重放。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param affinity LrustSqlDriverAffinity 业务 key（整数或字符串），仅用于路由，不自动绑定进 SQL。
---@param sql LrustSqlDriverSql 单条 SQL、片段或 buffer；本接口不接受绑定参数。
---@return LrustSqlDriverWriteResponse result 先检查 result.code 判断失败。
function client.execute_wait_on(db, affinity, sql)
    assert(affinity ~= nil and affinity ~= false, "execute_wait_on requires an affinity key")
    return execute_wait_with_affinity(db, affinity, sql)
end

--- 执行单条无绑定参数的语句并等待写入元数据，不返回 SELECT/RETURNING 行。
--- 由 driver 选择当前负载最低的 lane，同负载时轮转；不保证与前后请求使用同一连接或按发送顺序完成。
--- 需要绑定业务值时使用 execute_params_wait 系列，不要把 affinity 当作 SQL 参数。
--- 先检查 result.code；成功可读取 result.rows_affected，result.data 为原始 SQLx 元数据。
--- PG 自增值请用 query 系列执行 INSERT ... RETURNING；TIMEOUT/SOCKET 不证明写入未提交，driver 不自动重放。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param sql LrustSqlDriverSql 单条 SQL、片段或 buffer；本接口不接受绑定参数。
---@return LrustSqlDriverWriteResponse result 先检查 result.code 判断失败。
function client.execute_wait_any(db, sql)
    return execute_wait_with_affinity(db, false, sql)
end

--- 执行单条参数化查询并等待 driver 返回结果，也支持写入语句的 RETURNING 行。
--- 固定使用默认业务 key=1；本接口没有独立的 affinity 参数，指定业务 key 请使用对应 _on 版本。
--- sql 后的变长参数按占位符顺序绑定，保留尾部 nil；路由 key 不会自动成为 SQL 参数。
--- 收到 driver 响应后先检查 result.code；成功行数组在 result.data，没有记录为 {}，SQL NULL 为 json.null。
--- 重复列名需用 AS 区分，超出 max_rows 或字段解码失败会返回错误；NUMERIC 等限制与 ext.sqlx 相同。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param sql LrustSqlDriverSql 单条 SQL、片段或 buffer；绑定值通过后续变长参数传入。
---@param ... SqlXParam 位置绑定参数，保留尾部 nil。
---@return LrustSqlDriverQueryResponse result 先检查 result.code 判断失败。
function client.query_params(db, sql, ...)
    return query_params_with_affinity(db, 1, sql, ...)
end

--- 执行单条参数化查询并等待 driver 返回结果，也支持写入语句的 RETURNING 行。
--- 按显式业务 key 固定路由；相同 key 按抵达 driver 的顺序 FIFO 执行，key 不是 lane 编号。
--- sql 后的变长参数按占位符顺序绑定，保留尾部 nil；路由 key 不会自动成为 SQL 参数。
--- 收到 driver 响应后先检查 result.code；成功行数组在 result.data，没有记录为 {}，SQL NULL 为 json.null。
--- 重复列名需用 AS 区分，超出 max_rows 或字段解码失败会返回错误；NUMERIC 等限制与 ext.sqlx 相同。
--- 用法：driver.query_params_on(db, player_id, "SELECT id FROM users WHERE id=$1", player_id)。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param affinity LrustSqlDriverAffinity 业务 key（整数或字符串），仅用于路由，不自动绑定进 SQL。
---@param sql LrustSqlDriverSql 单条 SQL、片段或 buffer；绑定值通过后续变长参数传入。
---@param ... SqlXParam 位置绑定参数，保留尾部 nil。
---@return LrustSqlDriverQueryResponse result 先检查 result.code 判断失败。
function client.query_params_on(db, affinity, sql, ...)
    assert(affinity ~= nil and affinity ~= false, "query_params_on requires an affinity key")
    return query_params_with_affinity(db, affinity, sql, ...)
end

--- 执行单条参数化查询并等待 driver 返回结果，也支持写入语句的 RETURNING 行。
--- 由 driver 选择当前负载最低的 lane，同负载时轮转；不保证与前后请求使用同一连接或按发送顺序完成。
--- sql 后的变长参数按占位符顺序绑定，保留尾部 nil；路由 key 不会自动成为 SQL 参数。
--- 收到 driver 响应后先检查 result.code；成功行数组在 result.data，没有记录为 {}，SQL NULL 为 json.null。
--- 重复列名需用 AS 区分，超出 max_rows 或字段解码失败会返回错误；NUMERIC 等限制与 ext.sqlx 相同。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param sql LrustSqlDriverSql 单条 SQL、片段或 buffer；绑定值通过后续变长参数传入。
---@param ... SqlXParam 位置绑定参数，保留尾部 nil。
---@return LrustSqlDriverQueryResponse result 先检查 result.code 判断失败。
function client.query_params_any(db, sql, ...)
    return query_params_with_affinity(db, false, sql, ...)
end

--- 发送单条参数化执行请求，不等待入队或执行确认，不返回影响行数。
--- 固定使用默认业务 key=1；本接口没有独立的 affinity 参数，指定业务 key 请使用对应 _on 版本。
--- sql 后的变长参数按位置绑定并保留尾部 nil；服务内部仍等待 SQLx 完成后才处理本 lane 的下一条。
--- driver 收到后的拒绝/执行错误只记服务日志；客户端参数校验或消息序列化错误仍可能抛出。
--- 调用返回不表示写入成功；需要确认结果请使用对应等待版，错误请求不会自动重放。
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param sql LrustSqlDriverSql 单条 SQL、片段或 buffer；绑定值通过后续变长参数传入。
---@param ... SqlXParam 位置绑定参数，保留尾部 nil。
function client.execute_params(db, sql, ...)
    execute_params_with_affinity(db, 1, sql, ...)
end

--- 发送单条参数化执行请求，不等待入队或执行确认，不返回影响行数。
--- 按显式业务 key 固定路由；相同 key 按抵达 driver 的顺序 FIFO 执行，key 不是 lane 编号。
--- sql 后的变长参数按位置绑定并保留尾部 nil；服务内部仍等待 SQLx 完成后才处理本 lane 的下一条。
--- driver 收到后的拒绝/执行错误只记服务日志；客户端参数校验或消息序列化错误仍可能抛出。
--- 调用返回不表示写入成功；需要确认结果请使用对应等待版，错误请求不会自动重放。
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param affinity LrustSqlDriverAffinity 业务 key（整数或字符串），仅用于路由，不自动绑定进 SQL。
---@param sql LrustSqlDriverSql 单条 SQL、片段或 buffer；绑定值通过后续变长参数传入。
---@param ... SqlXParam 位置绑定参数，保留尾部 nil。
function client.execute_params_on(db, affinity, sql, ...)
    assert(affinity ~= nil and affinity ~= false, "execute_params_on requires an affinity key")
    execute_params_with_affinity(db, affinity, sql, ...)
end

--- 发送单条参数化执行请求，不等待入队或执行确认，不返回影响行数。
--- 由 driver 选择当前负载最低的 lane，同负载时轮转；不保证与前后请求使用同一连接或按发送顺序完成。
--- sql 后的变长参数按位置绑定并保留尾部 nil；服务内部仍等待 SQLx 完成后才处理本 lane 的下一条。
--- driver 收到后的拒绝/执行错误只记服务日志；客户端参数校验或消息序列化错误仍可能抛出。
--- 调用返回不表示写入成功；需要确认结果请使用对应等待版，错误请求不会自动重放。
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param sql LrustSqlDriverSql 单条 SQL、片段或 buffer；绑定值通过后续变长参数传入。
---@param ... SqlXParam 位置绑定参数，保留尾部 nil。
function client.execute_params_any(db, sql, ...)
    execute_params_with_affinity(db, false, sql, ...)
end

--- 执行单条参数化语句并等待写入元数据，不返回 SELECT/RETURNING 行。
--- 固定使用默认业务 key=1；本接口没有独立的 affinity 参数，指定业务 key 请使用对应 _on 版本。
--- sql 后按位置传入绑定值，保留尾部 nil；PG 参数使用 $1、$2 等占位符。
--- 先检查 result.code；成功可读取 result.rows_affected，result.data 为原始 SQLx 元数据。
--- PG 自增值请用 query 系列执行 INSERT ... RETURNING；TIMEOUT/SOCKET 不证明写入未提交，driver 不自动重放。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param sql LrustSqlDriverSql 单条 SQL、片段或 buffer；绑定值通过后续变长参数传入。
---@param ... SqlXParam 位置绑定参数，保留尾部 nil。
---@return LrustSqlDriverWriteResponse result 先检查 result.code 判断失败。
function client.execute_params_wait(db, sql, ...)
    return execute_params_wait_with_affinity(db, 1, sql, ...)
end

--- 执行单条参数化语句并等待写入元数据，不返回 SELECT/RETURNING 行。
--- 按显式业务 key 固定路由；相同 key 按抵达 driver 的顺序 FIFO 执行，key 不是 lane 编号。
--- sql 后按位置传入绑定值，保留尾部 nil；PG 参数使用 $1、$2 等占位符。
--- 先检查 result.code；成功可读取 result.rows_affected，result.data 为原始 SQLx 元数据。
--- PG 自增值请用 query 系列执行 INSERT ... RETURNING；TIMEOUT/SOCKET 不证明写入未提交，driver 不自动重放。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param affinity LrustSqlDriverAffinity 业务 key（整数或字符串），仅用于路由，不自动绑定进 SQL。
---@param sql LrustSqlDriverSql 单条 SQL、片段或 buffer；绑定值通过后续变长参数传入。
---@param ... SqlXParam 位置绑定参数，保留尾部 nil。
---@return LrustSqlDriverWriteResponse result 先检查 result.code 判断失败。
function client.execute_params_wait_on(db, affinity, sql, ...)
    assert(affinity ~= nil and affinity ~= false, "execute_params_wait_on requires an affinity key")
    return execute_params_wait_with_affinity(db, affinity, sql, ...)
end

--- 执行单条参数化语句并等待写入元数据，不返回 SELECT/RETURNING 行。
--- 由 driver 选择当前负载最低的 lane，同负载时轮转；不保证与前后请求使用同一连接或按发送顺序完成。
--- sql 后按位置传入绑定值，保留尾部 nil；PG 参数使用 $1、$2 等占位符。
--- 先检查 result.code；成功可读取 result.rows_affected，result.data 为原始 SQLx 元数据。
--- PG 自增值请用 query 系列执行 INSERT ... RETURNING；TIMEOUT/SOCKET 不证明写入未提交，driver 不自动重放。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param sql LrustSqlDriverSql 单条 SQL、片段或 buffer；绑定值通过后续变长参数传入。
---@param ... SqlXParam 位置绑定参数，保留尾部 nil。
---@return LrustSqlDriverWriteResponse result 先检查 result.code 判断失败。
function client.execute_params_wait_any(db, sql, ...)
    return execute_params_wait_with_affinity(db, false, sql, ...)
end

--- 一次提交并等待原始多语句 SQL 执行完成，不返回各语句查询行。
--- 未指定 affinity 时使用 key=1；不同 key 可能落到同一 lane，传 false 也会回退到 1，不代表 any 路由。
--- SQL 可含分号分隔的多条语句，不接受绑定参数；只用于可信 SQL，片段表不是事务列表。
--- 整个 batch 占一个 lane 请求并共用一次执行超时；不主动建立事务，不承诺跨语句原子性。
--- 先检查 result.code；成功 rows_affected 为累计值，data 为 SQLx 元数据，num_queries 固定为 1。
--- 需要参数绑定及原子提交请使用 transaction；失败或超时不能据此认定所有语句都未生效。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param sql LrustSqlDriverSql 可信的原始多语句 SQL、片段或 buffer；不接受绑定参数。
---@param affinity? LrustSqlDriverAffinity 默认 1；业务 key 而非 lane 编号，false 也回退到 1。
---@return LrustSqlDriverWriteResponse result 先检查 result.code 判断失败。
function client.batch(db, sql, affinity)
    return batch_with_affinity(db, affinity or 1, sql, true)
end

--- 一次提交并等待原始多语句 SQL 执行完成，不返回各语句查询行。
--- 按显式业务 key 固定路由；相同 key 按抵达 driver 的顺序 FIFO 执行，key 不是 lane 编号。
--- SQL 可含分号分隔的多条语句，不接受绑定参数；只用于可信 SQL，片段表不是事务列表。
--- 整个 batch 占一个 lane 请求并共用一次执行超时；不主动建立事务，不承诺跨语句原子性。
--- 先检查 result.code；成功 rows_affected 为累计值，data 为 SQLx 元数据，num_queries 固定为 1。
--- 需要参数绑定及原子提交请使用 transaction；失败或超时不能据此认定所有语句都未生效。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param affinity LrustSqlDriverAffinity 业务 key（整数或字符串），仅用于路由，不自动绑定进 SQL。
---@param sql LrustSqlDriverSql 可信的原始多语句 SQL、片段或 buffer；不接受绑定参数。
---@return LrustSqlDriverWriteResponse result 先检查 result.code 判断失败。
function client.batch_on(db, affinity, sql)
    assert(affinity ~= nil and affinity ~= false, "batch_on requires an affinity key")
    return batch_with_affinity(db, affinity, sql, true)
end

--- 一次提交并等待原始多语句 SQL 执行完成，不返回各语句查询行。
--- 由 driver 选择当前负载最低的 lane，同负载时轮转；不保证与前后请求使用同一连接或按发送顺序完成。
--- SQL 可含分号分隔的多条语句，不接受绑定参数；只用于可信 SQL，片段表不是事务列表。
--- 整个 batch 占一个 lane 请求并共用一次执行超时；不主动建立事务，不承诺跨语句原子性。
--- 先检查 result.code；成功 rows_affected 为累计值，data 为 SQLx 元数据，num_queries 固定为 1。
--- 需要参数绑定及原子提交请使用 transaction；失败或超时不能据此认定所有语句都未生效。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param sql LrustSqlDriverSql 可信的原始多语句 SQL、片段或 buffer；不接受绑定参数。
---@return LrustSqlDriverWriteResponse result 先检查 result.code 判断失败。
function client.batch_any(db, sql)
    return batch_with_affinity(db, false, sql, true)
end

--- 发送原始多语句 SQL，但不等待结果或返回执行元数据。
--- 未指定 affinity 时使用 key=1；不同 key 可能落到同一 lane，传 false 也会回退到 1，不代表 any 路由。
--- SQL 可含分号分隔的多条语句，不接受绑定参数；只用于可信 SQL，片段表不是事务列表。
--- 整个 batch 占一个 lane 请求并共用一次执行超时；不主动建立事务，不承诺跨语句原子性。
--- 服务端失败只记录日志，客户端校验/序列化仍可能抛错；需要确认完成请用 batch。
--- 需要参数绑定及原子提交请使用 transaction；失败或超时不能据此认定所有语句都未生效。
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param sql LrustSqlDriverSql 可信的原始多语句 SQL、片段或 buffer；不接受绑定参数。
---@param affinity? LrustSqlDriverAffinity 默认 1；业务 key 而非 lane 编号，false 也回退到 1。
function client.execute_batch(db, sql, affinity)
    batch_with_affinity(db, affinity or 1, sql, false)
end

--- 把完整语句列表作为一个请求，在单一 lane 的一个数据库事务中顺序执行并等待提交。
--- 未指定 affinity 时使用 key=1；不同 key 可能落到同一 lane，传 false 也会回退到 1，不代表 any 路由。
--- 每条格式为 {sql, param1, ...}，PG 占位符在每条语句中从 $1 重新编号；尾部 nil 用 table.pack 保留。
--- 外层必须无空洞，可为空；客户端校验失败在发送前抛错，不会发送部分列表。
--- 服务端管理事务边界，不要手动混入 BEGIN/COMMIT；整个事务共用一次执行超时，不包含列表外请求。
--- 先检查 result.code；成功 data=true，rows_affected 为累计值，num_queries 为语句数，不返回逐条查询行。
--- 执行失败会回滚该事务；超时/断线可能使提交结果不确定，不自动重放。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param queries LrustSqlDriverStatement[] 无空洞语句列表，可为空；每条尾部 nil 用 table.pack 保留。
---@param affinity? LrustSqlDriverAffinity 默认 1；业务 key 而非 lane 编号，false 也回退到 1。
---@return LrustSqlDriverTransactionResponse result 先检查 result.code 判断失败。
function client.transaction(db, queries, affinity)
    return transaction_with_affinity(db, affinity or 1, queries, true)
end

--- 把完整语句列表作为一个请求，在单一 lane 的一个数据库事务中顺序执行并等待提交。
--- 按显式业务 key 固定路由；相同 key 按抵达 driver 的顺序 FIFO 执行，key 不是 lane 编号。
--- 每条格式为 {sql, param1, ...}，PG 占位符在每条语句中从 $1 重新编号；尾部 nil 用 table.pack 保留。
--- 外层必须无空洞，可为空；客户端校验失败在发送前抛错，不会发送部分列表。
--- 服务端管理事务边界，不要手动混入 BEGIN/COMMIT；整个事务共用一次执行超时，不包含列表外请求。
--- 先检查 result.code；成功 data=true，rows_affected 为累计值，num_queries 为语句数，不返回逐条查询行。
--- 执行失败会回滚该事务；超时/断线可能使提交结果不确定，不自动重放。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param affinity LrustSqlDriverAffinity 业务 key（整数或字符串），仅用于路由，不自动绑定进 SQL。
---@param queries LrustSqlDriverStatement[] 无空洞语句列表，可为空；每条尾部 nil 用 table.pack 保留。
---@return LrustSqlDriverTransactionResponse result 先检查 result.code 判断失败。
function client.transaction_on(db, affinity, queries)
    assert(affinity ~= nil and affinity ~= false, "transaction_on requires an affinity key")
    return transaction_with_affinity(db, affinity, queries, true)
end

--- 把完整语句列表作为一个请求，在单一 lane 的一个数据库事务中顺序执行并等待提交。
--- 由 driver 选择当前负载最低的 lane，同负载时轮转；不保证与前后请求使用同一连接或按发送顺序完成。
--- 每条格式为 {sql, param1, ...}，PG 占位符在每条语句中从 $1 重新编号；尾部 nil 用 table.pack 保留。
--- 外层必须无空洞，可为空；客户端校验失败在发送前抛错，不会发送部分列表。
--- 服务端管理事务边界，不要手动混入 BEGIN/COMMIT；整个事务共用一次执行超时，不包含列表外请求。
--- 先检查 result.code；成功 data=true，rows_affected 为累计值，num_queries 为语句数，不返回逐条查询行。
--- 执行失败会回滚该事务；超时/断线可能使提交结果不确定，不自动重放。
---@async
---@nodiscard
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param queries LrustSqlDriverStatement[] 无空洞语句列表，可为空；每条尾部 nil 用 table.pack 保留。
---@return LrustSqlDriverTransactionResponse result 先检查 result.code 判断失败。
function client.transaction_any(db, queries)
    return transaction_with_affinity(db, false, queries, true)
end

--- 把完整语句列表作为一个事务请求发送，但不等待事务提交结果。
--- 未指定 affinity 时使用 key=1；不同 key 可能落到同一 lane，传 false 也会回退到 1，不代表 any 路由。
--- 每条格式为 {sql, param1, ...}，PG 占位符在每条语句中从 $1 重新编号；尾部 nil 用 table.pack 保留。
--- 外层必须无空洞，可为空；客户端校验失败在发送前抛错，不会发送部分列表。
--- 服务端管理事务边界，不要手动混入 BEGIN/COMMIT；整个事务共用一次执行超时，不包含列表外请求。
--- driver 的拒绝/执行错误只记录日志；需要确认提交及影响行数时使用 transaction。
--- 执行失败会回滚该事务；超时/断线可能使提交结果不确定，不自动重放。
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param queries LrustSqlDriverStatement[] 无空洞语句列表，可为空；每条尾部 nil 用 table.pack 保留。
---@param affinity? LrustSqlDriverAffinity 默认 1；业务 key 而非 lane 编号，false 也回退到 1。
function client.execute_transaction(db, queries, affinity)
    transaction_with_affinity(db, affinity or 1, queries, false)
end

--- 把完整语句列表作为一个事务请求发送，但不等待事务提交结果。
--- 按显式业务 key 固定路由；相同 key 按抵达 driver 的顺序 FIFO 执行，key 不是 lane 编号。
--- 每条格式为 {sql, param1, ...}，PG 占位符在每条语句中从 $1 重新编号；尾部 nil 用 table.pack 保留。
--- 外层必须无空洞，可为空；客户端校验失败在发送前抛错，不会发送部分列表。
--- 服务端管理事务边界，不要手动混入 BEGIN/COMMIT；整个事务共用一次执行超时，不包含列表外请求。
--- driver 的拒绝/执行错误只记录日志；需要确认提交及影响行数时使用 transaction。
--- 执行失败会回滚该事务；超时/断线可能使提交结果不确定，不自动重放。
---@param db integer moon.new_service 返回的 driver 服务 ID，不是 SQLx 连接对象。
---@param affinity LrustSqlDriverAffinity 业务 key（整数或字符串），仅用于路由，不自动绑定进 SQL。
---@param queries LrustSqlDriverStatement[] 无空洞语句列表，可为空；每条尾部 nil 用 table.pack 保留。
function client.execute_transaction_on(db, affinity, queries)
    assert(affinity ~= nil and affinity ~= false, "execute_transaction_on requires an affinity key")
    transaction_with_affinity(db, affinity, queries, false)
end

--- transaction 的直接兼容别名，参数、默认 key=1、等待行为及返回值完全相同。
--- 实际仍是一个数据库事务，不是 PG pipeline，也不会返回每条 SQL 的查询行。
client.pipe = client.transaction
--- execute_transaction 的直接兼容别名；完整校验后提交一个事务，不等待结果或返回影响行数。
--- 默认 key=1，可传 affinity；客户端校验可能抛错，服务端失败只记日志。
client.execute_pipe = client.execute_transaction

--- 等待 driver 返回各 lane 的即时负载，不等待数据库请求全部完成。
--- 每项为 Lua 等待队列加当前处理中的请求；连接建立、执行和错误清理也可能计入当前请求。
--- 结果直接是整数数组，不包含 data/code 包装，不是累计执行次数或 Rust 全局连接统计。
--- 它是可立即过时的快照，不能作为写入成功、退出完成或多调用事务的确认。
---@async
---@param db integer driver 服务 ID。
---@return integer[] lengths 按 lane 索引排列，从 1 开始。
function client.len(db)
    return moon.call("lua", db, "len")
end

--- 等待 driver 返回接收状态及所有 lane 的队列/连接快照，不执行数据库探活。
--- queue 不含当前请求，inflight 表示当前处理中的请求，running 表示工作协程是否运行。
--- connected 仅代表持有连接对象；与 sqlx.stats 的 Rust 请求计数不是同一层统计。
--- 结果直接是统计对象，不包含 data/code 包装；不会等待排队 SQL 执行完。
---@async
---@param db integer driver 服务 ID。
---@return LrustSqlDriverStats stats
function client.stats(db)
    return moon.call("lua", db, "stats")
end

--- 仅发送关闭通知，不等待服务处理通知、排空或退出，也没有完成确认返回值。
--- driver 收到后停止接收新数据库请求，处理完已接收请求，尝试关闭所有连接并退出。
--- 排空不代表所有 SQL 都成功；待确认的写入应使用等待接口取得各自结果。
--- 调用后不要继续发送业务请求；多发送者应先协调停写，较晚抵达的请求可能被 CLOSED 拒绝。
--- 服务仍存活时可读取 stats.accepting，但它不等于退出完成；重复通知的服务端处理是幂等的。
---@param db integer driver 服务 ID。
function client.save_then_quit(db)
    moon.send("lua", db, "save_then_quit")
end

return client
