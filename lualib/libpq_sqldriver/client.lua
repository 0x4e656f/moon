-- 纯客户端模块；不创建 service，也不加载 libpq 动态库。
local moon = require("moon")
local types = require("moon.db.libpq.types")
local M = { NULL=types.NULL, typed=types.typed, bytea=types.bytea, jsonb=types.jsonb, array=types.array }

---@alias LibpqLaneKey integer|string

--- 在服务端的指定队列执行参数化 SQL 并等待结果。默认 key=1，保持原 sqldriver 的默认串行语义。
--- 相同 key 固定映射到一个物理连接的 FIFO；不同 key 可能碰撞，不能保证一定并行。
---@async
---@param service integer driver 服务 ID
---@param sql string
---@param params? any[]
---@param key? LibpqLaneKey
---@param options? LibpqOperationOptions
---@return LibpqResult|LibpqError
function M.query(service, sql, params, key, options)
    return moon.call("lua", service, "query", key or 1, sql, params, options)
end

--- 投递写请求，不等待结果；失败由 driver 记录错误码，不重放 SQL、不记录密码或 SQL 参数。
---@param service integer
---@param sql string
---@param params? any[]
---@param key? LibpqLaneKey
---@param options? LibpqOperationOptions
function M.execute(service, sql, params, key, options)
    moon.send("lua", service, "execute", key or 1, sql, params, options)
end

--- 无串行亲和要求的查询：选择当前负载最低的队列，同负载时轮转。
---@async
---@param service integer
---@param sql string
---@param params? any[]
---@param options? LibpqOperationOptions
---@return LibpqResult|LibpqError
function M.query_any(service, sql, params, options)
    return moon.call("lua", service, "query", false, sql, params, options)
end

--- 一组参数化语句作为一个队列项执行；事务全程占用同一连接，不允许插入其他请求。
---@async
---@param service integer
---@param statements LibpqStatement[]
---@param key? LibpqLaneKey
---@param options? LibpqOperationOptions
---@return table|LibpqError
function M.transaction(service, statements, key, options)
    return moon.call("lua", service, "transaction", key or 1, statements, options)
end

--- 投递事务但不等待结果；顺序和失败策略与 transaction 相同。
---@param service integer
---@param statements LibpqStatement[]
---@param key? LibpqLaneKey
---@param options? LibpqOperationOptions
function M.execute_transaction(service, statements, key, options)
    moon.send("lua", service, "transaction", key or 1, statements, options)
end

--- 执行多条无参数 SQL，等待 {results=...}；参数化批量写入请用 transaction。
---@async
---@param service integer
---@param sql string
---@param key? LibpqLaneKey
---@param options? LibpqOperationOptions
---@return table|LibpqError
function M.batch(service, sql, key, options)
    return moon.call("lua", service, "batch", key or 1, sql, options)
end

--- 返回各队列的 waiting/running/connected；waiting 不含正在执行的请求。
---@async
---@param service integer
---@return table
function M.stats(service) return moon.call("lua", service, "stats") end

--- 停止接收新请求，等待队列与在途 SQL 全部结束，再关闭连接并退出服务。
---@async
---@param service integer
---@return table
function M.save_then_quit(service) return moon.call("lua", service, "save_then_quit") end
return M
