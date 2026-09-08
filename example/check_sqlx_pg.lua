-- Pure Lua syntax/catalog validation. Does NOT load Moon, Rust, or a DB driver.
-- premake5 --file=example/check_sqlx_pg.lua check_sqlx_pg
local directory = _SCRIPT_DIR or "example"
local function compile(name)
    local path = directory .. "/" .. name
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a")
    file:close()
    return assert(load(source, "@" .. path, "t", _G)), source
end
local _, test_source = compile("test_sqlx_pg.lua") -- Compile only: never execute the integration suite.
compile("example_lrust_sqldriver.lua")
local null = {} -- An identity sentinel sufficient for checking catalog structure.
local wrappers = {}
for _, kind in ipairs({ "json", "bytes" }) do
    wrappers[kind] = function(value) return { __sqlx_param = kind, value = value } end
end
local catalog_loader, catalog_source = compile("sqlx_pg_types.lua")
local catalog = catalog_loader()(wrappers, null)
local function unique_name(names, name)
    assert(type(name) == "string" and name:match("^[a-z][a-z0-9_]*$"), "unsafe catalog name")
    assert(not names[name], "duplicate catalog name: " .. name)
    names[name] = true
end
local names = {}
for _, field in ipairs(catalog.fields) do
    unique_name(names, field.name)
    assert(type(field.sql_type) == "string" and type(field.literal) == "string")
    assert(field.expected ~= nil and field.param ~= nil, "missing field test value: " .. field.name)
    assert(type(field.bind) == "string" and field.bind:find("$1", 1, true), "missing parameter test")
end
assert(#catalog.fields == 26, "update coverage count if the scalar catalog changes")
names = {}
for _, array in ipairs(catalog.arrays) do
    unique_name(names, array[1])
    assert(array[2]:sub(-2) == "[]")
    assert(type(array[3]) == "table" and array[3][2] == null, "array must include SQL NULL")
end
assert(#catalog.arrays == 13, "update coverage count if the array catalog changes")
names = {}
for _, cast in ipairs(catalog.text_only) do
    unique_name(names, cast[1])
    assert(type(cast[2]) == "string" and type(cast[3]) == "string")
end
assert(#catalog.text_only == 38, "update coverage count if the cast catalog changes")
-- A name/reference check catches public API additions omitted from this suite.
-- This is not a substitute for running assertions against PostgreSQL.
local _, wrapper_source = compile("../lualib/ext/sqlx.lua")
compile("../service/lrust_sqldriver.lua")
local _, driver_source = compile("../lualib/lrust_sqldriver/client.lua")
local combined = test_source .. catalog_source
local api_count = 0
for name in wrapper_source:gmatch("function M[%.:]([%w_]+)%(") do
    assert(combined:find("[%.:]" .. name .. "%s*%("), "missing SQLx API test reference: " .. name)
    api_count = api_count + 1
end
for name in driver_source:gmatch("function client%.([%w_]+)%(") do
    assert(test_source:find("driver%." .. name .. "%s*%("), "missing driver API test reference: " .. name)
    api_count = api_count + 1
end
for _, name in ipairs({ "pipe", "execute_pipe" }) do
    assert(test_source:find("driver%." .. name .. "%s*%("), "missing driver alias test reference: " .. name)
end
print(string.format("SQLx PG suite syntax/catalog OK: %d scalar fields, %d array types, %d CAST-only types. No DB/Moon execution.",
    #catalog.fields, #catalog.arrays, #catalog.text_only))
print(string.format("Public API references checked: %d functions plus 2 driver aliases (not runtime coverage).", api_count))
if newaction then
    newaction { trigger = "check_sqlx_pg", description = "Compile PG tests without running Moon or connecting to a database", execute = function() end }
end
