-- Every Lua service created with this entry gets its own Lua state and context.
local moon = require("moon")
local hotfix = require("hotfix")

local conf = assert(..., "missing service config")
assert(type(conf.module) == "string", "conf.module must be a Lua file path")
assert(conf.parts == nil or type(conf.parts) == "table", "conf.parts must be a path table")

-- Read the source each time, so hotfix.update sees the edited file.
local function load_source(path)
    local file, err = io.open(path, "rb")
    assert(file, err)
    local source = file:read("*a")
    file:close()
    local loader, load_err = load(source, "@" .. path)
    assert(loader, load_err)
    return loader, path
end

hotfix.addsearcher(load_source)

local context = { config = conf, state = {} }
local modules = {}
local registered = {}

local function add_module(path)
    assert(type(path) == "string", "module path must be a string")
    assert(not registered[path], "duplicate module path: " .. path)
    local name = path:match("([^/\\]+)%.lua$")
    assert(name, "module path must end in .lua: " .. path)
    assert(not modules[name], "duplicate module name: " .. name)

    local module = hotfix.require(path)
    assert(type(module) == "table", "module must return a table: " .. path)
    modules[name] = module
    registered[path] = true
end

add_module(conf.module)
local parts = conf.parts or {}
for _, path in ipairs(parts) do
    add_module(path)
end
local named_parts = {}
for name in pairs(parts) do
    if type(name) == "string" then
        named_parts[#named_parts + 1] = name
    end
end
table.sort(named_parts)
for _, name in ipairs(named_parts) do
    add_module(parts[name])
end

moon.dispatch("lua", function(sender, session, command, ...)
    if command == "__hotfix" then
        local path, replacement = ...
        if not registered[path] then
            moon.response("lua", sender, session, false, "module is not registered: " .. tostring(path))
            return
        end
        local called, ok, err = pcall(hotfix.update, path, replacement)
        if not called then
            moon.response("lua", sender, session, false, ok)
        elseif not ok then
            moon.response("lua", sender, session, false, err)
        else
            moon.response("lua", sender, session, true)
        end
        return
    end

    local module_name, method_name
    if type(command) == "string" then
        module_name, method_name = command:match("^([%w_]+)%.([%w_]+)$")
    end
    local module = modules[module_name]
    local method = module and module[method_name]
    if type(method) ~= "function" then
        moon.response("lua", sender, session, false, "unknown command: " .. tostring(command))
        return
    end

    local result = table.pack(pcall(method, context, ...))
    if not result[1] then
        moon.response("lua", sender, session, false, result[2])
        return
    end
    moon.response("lua", sender, session, true, table.unpack(result, 2, result.n))
end)
