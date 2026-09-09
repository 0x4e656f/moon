-- 纯参数包装：可跨 Moon 服务序列化，不加载 libpq，不在 Lua 中编码/解码字段。
local M = { NULL = require("json").null }

---@class LibpqParameter
---@field __libpq_type string|integer PostgreSQL 类型名或 OID
---@field value any nil/json.null 表示 SQL NULL；json/jsonb 包装中的 json.null 表示 JSON null

--- 指定 PG 参数类型；适用于 numeric、日期时间、UUID、自定义 OID 和有类型的 NULL。
--- 类型检查、精度处理和编码由服务端 C++ 绑定完成。
---@param pgtype string|integer
---@param value any
---@return LibpqParameter
function M.typed(pgtype, value) return { __libpq_type = pgtype, value = value } end

--- 原始二进制 bytea 参数，保留 NUL 和任意字节。
---@param value string
---@return LibpqParameter
function M.bytea(value) return M.typed("bytea", value) end

--- Lua 值作为 JSONB；字符串编码为 JSON 字符串，NULL 编码为 JSON null。
---@param value any
---@return LibpqParameter
function M.jsonb(value) return M.typed("jsonb", value) end

--- 一维 PG 数组参数；元素可使用 NULL，空数组使用 {}。
---@param element_type string|integer
---@param values table
---@return LibpqParameter
function M.array(element_type, values)
    return { __libpq_type = "array", element_type = element_type, value = values }
end
return M
