-- 协程接口层：参数校验/编码、结果解码、缓存及事务状态机均在 C++。
local moon = require("moon")
local core = require("libpq.core")
local types = require("moon.db.libpq.types")

---@class LibpqError
---@field code string DB/SOCKET/TIMEOUT/CLOSED/BUSY/INVALID/LIMIT/ERROR 等
---@field message string
---@field sqlstate? string PostgreSQL SQLSTATE，仅数据库错误包含
---@field detail? string
---@field hint? string
---@field committed? boolean 仅事务已成功提交但结果解码失败时为 true；此时不可重试写入
---@field statement_index? integer 事务内失败语句的 1-based 索引
---@field constraint? string
---@field table? string
---@field connect_failed? boolean 是否在连接阶段失败

---@class LibpqOperationOptions
---@field timeout? integer 整个单次操作的毫秒超时，默认 10000；不包含 driver 排队/建连时间
---@field max_rows? integer 总结果行数，默认 100000；0 不限
---@field max_result_bytes? integer 总字段原始字节数，默认 64 MiB；0 不限，不是进程内存上限
---@field row_mode? 'name'|'array' 默认 name；array 保留重复列名对应的所有字段

---@class LibpqOptions : LibpqOperationOptions
---@field statement_cache_capacity? integer 每个物理连接的自动预处理 LRU 容量，默认 100；0 禁用
---@field host? string 单个 TCP 主机，默认 127.0.0.1；DNS 使用 Asio 异步解析
---@field hostaddr? string 已解析的单个 IP；host 仍用于证书主机名校验
---@field port? integer 默认 5432
---@field dbname string
---@field user string
---@field password? string
---@field sslmode? string 默认 require；生产建议 verify-full 并指定 sslrootcert
---@field sslrootcert? string CA 文件
---@field sslcert? string 客户端证书文件
---@field sslkey? string 客户端私钥文件
---@field application_name? string
---@field options? string PostgreSQL 启动参数，例如 -c timezone=UTC
---@field library? string 预编译 libpq 动态库路径；Linux 默认系统 libpq.so.5，Windows 默认 clib/libpq/libpq.dll

---@class LibpqResult
---@field rows table[]
---@field columns {name:string, oid:integer}[]
---@field command string PostgreSQL 命令标签
---@field rows_affected integer

---@class LibpqStatement
---@field sql string 单条 SQL，参数占位符为 $1、$2……
---@field params? any[]

---@class LibpqConnection
---@field private native userdata
---@field private busy boolean
---@field private config LibpqOperationOptions
local Connection = {}
Connection.__index = Connection
local M = { NULL = types.NULL, typed = types.typed, bytea = types.bytea,
    jsonb = types.jsonb, array = types.array }

local function err(code, message) return { code = code, message = tostring(message) } end
local function uint(n, zero)
    assert(math.type(n) == "integer" and n >= (zero and 0 or 1) and n <= 0xffffffff, "invalid integer option")
    return n
end
local function settings(config, override)
    override = override or {}
    assert(type(override) == "table", "operation options must be a table")
    local result = {}
    for k, v in pairs(config) do result[k] = v end
    for k, v in pairs(override) do
        assert(k == "timeout" or k == "max_rows" or k == "max_result_bytes" or k == "row_mode", "unknown operation option")
        result[k] = v
    end
    uint(result.timeout); uint(result.max_rows, true); uint(result.max_result_bytes, true)
    assert(result.row_mode == "name" or result.row_mode == "array", "invalid row_mode")
    return result
end

local function receive(self, session, row_mode)
    local signal = moon.wait(session)
    if signal ~= 1 then self.native:close(); return err("CANCELLED", "coroutine wait interrupted; connection discarded") end
    return self.native:take(row_mode)
end

-- pcall can yield in Lua 5.4. Release the Lua lock on every normal/error path.
local function locked(self, action)
    if self.busy then return err("BUSY", "one connection supports one operation; use libpq_sqldriver to queue") end
    if not self.native:connected() then return err("CLOSED", "connection is closed") end
    self.busy = true
    local ok, result = pcall(action)
    self.busy = false
    if not ok then
        self.native:close() -- uncertain native/codec exceptions must not leak a transaction
        return err("ERROR", result)
    end
    return result
end

local function one(self, kind, sql, params, override, name)
    return locked(self, function()
        local opts = settings(self.config, override)
        local session = self.native:submit(kind, sql, params, opts.timeout,
            opts.max_rows, opts.max_result_bytes, name)
        local result = receive(self, session, opts.row_mode)
        if result.code or kind == "batch" then return result end
        return result.results[1] or { rows={}, columns={}, command="", rows_affected=0 }
    end)
end

--- 异步连接；仅挂起当前协程。失败返回 LibpqError，成功返回连接对象。
--- 默认要求 TLS；仅可信本地测试可显式选择 sslmode="disable"。
---@async
---@param options LibpqOptions
---@return LibpqConnection|LibpqError
function M.connect(options)
    local native
    local ok, result = pcall(function()
        assert(type(options) == "table", "connect options must be a table")
        local config = settings({ timeout=10000, max_rows=100000, max_result_bytes=64*1024*1024, row_mode="name" })
        local connopts = { host="127.0.0.1", port="5432", sslmode="require", client_encoding="UTF8",
            application_name="moon-libpq", options="-c timezone=UTC -c datestyle=ISO,YMD -c bytea_output=hex",
            gssencmode="disable" }
        local allowed = {host=true,hostaddr=true,port=true,dbname=true,user=true,password=true,sslmode=true,
            sslrootcert=true,sslcert=true,sslkey=true,sslpassword=true,application_name=true,options=true,
            keepalives=true,keepalives_idle=true,keepalives_interval=true,keepalives_count=true,tcp_user_timeout=true}
        for k, v in pairs(options) do
            if config[k] ~= nil then config[k] = v
            elseif k ~= "library" and k ~= "statement_cache_capacity" then
                assert(allowed[k], "unsupported connection option: " .. tostring(k))
                assert(type(v) == "string" or type(v) == "number", "connection options require strings or numbers")
                connopts[k] = tostring(v)
            end
        end
        config = settings(config)
        assert(connopts.dbname and connopts.user, "dbname and user are required")
        core.load(options.library)
        native = core.new(uint(options.statement_cache_capacity or 100, true))
        local self = setmetatable({ native=native, config=config, busy=false }, Connection)
        local response = receive(self, native:connect(connopts, config.timeout))
        if response.code then native:close(); return response end
        return self
    end)
    if not ok then if native then native:close() end; return err("INVALID", result) end
    return result
end

--- 单条参数化 SQL；C++ 直接生成最终行表，常用 DML/SELECT 自动复用连接内预处理缓存。
--- 返回 rows/columns/command/rows_affected；数据库错误返回带 SQLSTATE 的错误表。
---@async
---@param sql string
---@param params? any[] 稠密序列；SQL NULL 用 libpq.NULL
---@param options? LibpqOperationOptions
---@return LibpqResult|LibpqError
function Connection:query(sql, params, options) return one(self, "query", sql, params, options) end

--- 执行写语句；和 query 返回相同结构，也可读取 INSERT ... RETURNING 的 rows。
---@async
---@param sql string
---@param params? any[]
---@param options? LibpqOperationOptions
---@return LibpqResult|LibpqError
function Connection:execute(sql, params, options) return self:query(sql, params, options) end

--- 执行多条无参数 SQL，返回 {results=LibpqResult[]}。不接收外部字符串拼接的值。
--- 使用 PG simple-query 隐式事务语义；请勿包含显式事务控制。失败后丢弃连接以清理会话状态。
---@async
---@param sql string
---@param options? LibpqOperationOptions
---@return table|LibpqError
function Connection:batch(sql, options)
    return one(self, "batch", sql, nil, options)
end

--- 一次提交整个事务到 C++，BEGIN/顺序执行/COMMIT/必要回滚共用一个总超时，仅等待一次。
--- 先验证全部参数。断线/超时/提交失败均不重放；提交错误意味着最终提交状态可能未知。
---@async
---@param statements LibpqStatement[]
---@param options? LibpqOperationOptions
---@return table|LibpqError 成功 {results=LibpqResult[]}，失败含 statement_index
function Connection:transaction(statements, options)
    return locked(self, function()
        local opts = settings(self.config, options)
        local session = self.native:transaction(statements, opts.timeout, opts.max_rows, opts.max_result_bytes)
        return receive(self, session, opts.row_mode)
    end)
end

--- 创建本连接的命名预处理语句；名称不得使用内部前缀 __moon_pq_，重连后需重新 prepare。
--- 池化 driver 不暴露手动 prepare，但自动缓存对每条 lane 都有效。
---@async
---@param name string
---@param sql string
---@param param_types? (string|integer)[] 参数类型名/OID；0 由 PG 推断
---@param options? LibpqOperationOptions
---@return LibpqResult|LibpqError
function Connection:prepare(name, sql, param_types, options)
    return one(self, "prepare", sql, param_types, options, name)
end

--- 执行本连接的命名预处理语句；参数格式应与 prepare 的类型一致。
---@async
---@param name string
---@param params? any[]
---@param options? LibpqOperationOptions
---@return LibpqResult|LibpqError
function Connection:query_prepared(name, params, options) return one(self, "prepared", " ", params, options, name) end

--- 立即关闭，正在等待的操作返回 CLOSED；不会等待或提交未结束的事务。
function Connection:close() self.native:close() end
--- 只检查本地 libpq 连接状态，不发送探活 SQL；远端断开可能在下次查询才被发现。
---@return boolean
function Connection:connected() return self.native:connected() end
return M
