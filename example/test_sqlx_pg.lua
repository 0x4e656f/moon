-- PostgreSQL integration/regression suite. Run manually from the Moon root.
-- See example/SQLX_PG_TEST.md. Never point this script at a production database.
if _G["__init__"] then
    return { thread = 4, enable_stdout = true, loglevel = "INFO" }
end

local moon = require("moon")
local sqlx = require("ext.sqlx")
local json = require("json")
local driver = require("lrust_sqldriver.client")
local startup = ...
local self_file = debug.getinfo(1, "S").source:sub(2)

-- A separate Lua VM verifies connection discovery and response ownership/IPC.
if type(startup) == "table" and startup.mode == "sqlx_test_peer" then
    moon.dispatch("lua", function(sender, session, name, statement, params)
        local ok, result = xpcall(function()
            local db = assert(sqlx.find_connection(name), "shared connection not found")
            return db:query(statement, table.unpack(params, 1, params.n))
        end, debug.traceback)
        moon.response("lua", sender, session, ok and result or { kind = "ERROR", message = result })
    end)
    return
end

local null = json.null
local catalog = dofile("example/sqlx_pg_types.lua")(sqlx, null)
local url = type(startup) == "table" and startup.url or os.getenv("DATABASE_URL")
local keep_data = os.getenv("SQLX_TEST_KEEP_DATA") == "1"
local test_driver = os.getenv("SQLX_TEST_DRIVER") ~= "0"
local function positive_env(name, fallback)
    local value = tonumber(os.getenv(name)) or fallback
    assert(math.type(value) == "integer" and value > 0, name .. " must be a positive integer")
    return value
end
local slow_ms = positive_env("SQLX_TEST_SLOW_MS", 300)
-- Leave a generous scheduling margin, but keep the server-side sleep much
-- longer so a close which waits for the old query is caught deterministically.
local timeout_sleep_ms = math.max(4000, slow_ms * 8)
local timeout_budget_ms = slow_ms + 1500
local deadline_ms = positive_env("SQLX_TEST_DEADLINE_MS", 300000)
local connection_options = { connect_timeout = 5000, request_timeout = 15000, max_rows = 1000, queue_capacity = 128 }
local suffix = string.format("%d_%d_%06x", os.time(), moon.id, math.random(0, 0xffffff))
local schema = "sqlx_test_" .. suffix
assert(schema:match("^sqlx_test_%d+_%d+_%x+$") and #schema <= 63)
local qualified = '"' .. schema .. '".'
local created, finished = false, false
local connections, services, peers, jobs = {}, {}, {}, {}
local passed, failed, skipped, sequence = 0, 0, 0, 0
local failures = {}
local admin, main_name

local function safe_message(value)
    return tostring(value):gsub("postgres[ql]*://[^%s]+", "<redacted PostgreSQL URL>")
end
local function expect(condition, message)
    if not condition then error(message or "assertion failed", 2) end
end
local function equal(actual, expected, path, epsilon)
    path = path or "value"
    if type(actual) == "number" and type(expected) == "number" and epsilon then
        expect(math.abs(actual - expected) <= epsilon * math.max(1, math.abs(expected)),
            path .. ": floating-point mismatch: " .. tostring(actual) .. " / " .. tostring(expected))
    elseif type(expected) == "table" then
        expect(type(actual) == "table", path .. ": expected table, got " .. type(actual))
        for key, value in pairs(expected) do equal(actual[key], value, path .. "." .. tostring(key), epsilon) end
        for key in pairs(actual) do expect(expected[key] ~= nil, path .. ": unexpected key " .. tostring(key)) end
    else
        expect(actual == expected, path .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
        expect(type(actual) == type(expected), path .. ": Lua type mismatch")
        if type(expected) == "number" and math.type(expected) == "integer" then
            expect(math.type(actual) == "integer", path .. ": integer was converted to float")
        end
    end
end
local function ok(result)
    expect(type(result) == "table", "expected result table, got " .. tostring(result))
    expect(not result.kind and not result.code, safe_message(result.message or result.kind or result.code))
    return result
end
local function row(result)
    result = ok(result)
    equal(#result, 1, "row count")
    return result[1]
end
local function error_result(result, kind, fragment)
    expect(type(result) == "table" and type(result.kind) == "string", "expected a structured SQLx error")
    expect(type(result.message) == "string" and result.message ~= "", "error message missing")
    if kind then equal(result.kind, kind, "error kind") end
    if fragment then
        expect(result.message:lower():find(fragment:lower(), 1, true), "error message missing: " .. fragment)
    end
    return result
end
local function case(name, fn)
    local started = moon.clock()
    local success, err = xpcall(fn, debug.traceback)
    if success then
        passed = passed + 1
        print(string.format("[PASS] %s (%.1f ms)", name, (moon.clock() - started) * 1000))
    else
        failed = failed + 1
        failures[#failures + 1] = name
        moon.error("[FAIL] " .. name .. "\n" .. safe_message(err))
    end
end
local function wait_until(predicate, description, timeout_ms)
    local deadline = moon.clock() + (timeout_ms or 10000) / 1000
    repeat
        if predicate() then return end
        expect(moon.clock() < deadline, "timed out waiting for " .. description)
        moon.sleep(10)
    until false
end
local function start_job(fn)
    local job = { done = false }
    jobs[#jobs + 1] = job
    moon.async(function()
        job.success, job.value = xpcall(fn, debug.traceback)
        job.done = true
    end)
    return job
end
local function join(job)
    wait_until(function() return job.done end, "test coroutine", 30000)
    expect(job.success, safe_message(job.value))
    return job.value
end
local function open(label, options, exact_name, use_try)
    sequence = sequence + 1
    local name = exact_name or (schema .. ":" .. label .. ":" .. sequence)
    local db, err
    if use_try then db, err = sqlx.try_connect(url, name, options or connection_options)
    else db = sqlx.connect(url, name, options or connection_options) end
    expect(db, "connection failed: " .. safe_message(err and err.message))
    connections[#connections + 1] = db
    return db, name
end
local function close(db)
    local success, err = db:close()
    expect(success == true, "close failed: " .. safe_message(err and err.message))
end
local function driver_row(result)
    return row(ok(result).data)
end
local function new_driver(label, options)
    local name = schema .. "_" .. label
    local conf = {
        unique = true, name = name, file = "lrust_sqldriver.lua", threadid = 2,
        url = url, poolsize = 3, max_queue = 128, queue_capacity = 32,
        connect_timeout = 5000, request_timeout = 15000, max_rows = 1000,
    }
    for key, value in pairs(options or {}) do conf[key] = value end
    local id = moon.new_service(conf)
    expect(type(id) == "number" and id > 0, "driver service creation failed")
    local record = { id = id, name = name, poolsize = conf.poolsize }
    services[#services + 1] = record
    return id, record
end
local function stop_driver(record)
    if moon.queryservice(record.name) == 0 then return end
    driver.save_then_quit(record.id)
    wait_until(function() return moon.queryservice(record.name) == 0 end, "driver drain and quit", 30000)
    for i = 1, record.poolsize do
        equal(sqlx.find_connection("lrust_sqldriver:" .. record.name .. ":" .. i), nil, "closed driver lane")
    end
end
local function reset_gate()
    ok(admin:execute_wait("UPDATE " .. qualified .. "queue_gate SET n = 0 WHERE id = 1"))
end
-- Hold a row lock belonging exclusively to this run. This avoids pg_sleep-based
-- races when testing queue overflow, shutdown, and independent driver lanes.
local function with_gate(fn)
    reset_gate()
    local locker = open("locker")
    ok(locker:batch("BEGIN; UPDATE " .. qualified .. "queue_gate SET n = n WHERE id = 1"))
    local success, err = xpcall(fn, debug.traceback)
    local rolled_back, rollback_err = pcall(function() ok(locker:batch("ROLLBACK")); close(locker) end)
    expect(rolled_back, safe_message(rollback_err))
    expect(success, safe_message(err))
end
local function wait_locked(pid)
    wait_until(function()
        return row(admin:query([[SELECT EXISTS(SELECT 1 FROM pg_stat_activity
            WHERE pid = $1::INT8::INT4 AND wait_event_type = 'Lock') AS locked]], pid)).locked
    end, "PostgreSQL row-lock wait")
end

local function setup()
    expect(type(url) == "string" and (url:match("^postgres://") or url:match("^postgresql://")),
        "Set DATABASE_URL to a PostgreSQL TEST database URL")
    admin, main_name = open("main")
    print("[INFO] PostgreSQL " .. row(admin:query("SHOW server_version")).server_version)
    expect(tonumber(row(admin:query("SHOW server_version_num")).server_version_num) >= 140000,
        "The full type catalog (including multiranges) requires PostgreSQL 14+")
    print("[INFO] Isolated schema: " .. schema .. "; keep_data=" .. tostring(keep_data))
    -- No IF NOT EXISTS: if the generated name already exists, NEVER reuse/drop it.
    ok(admin:execute_wait('CREATE SCHEMA "' .. schema .. '"'))
    created = true
    ok(admin:batch("SET TIME ZONE 'UTC'; SET DateStyle = 'ISO, YMD'; SET IntervalStyle = 'postgres'"))
    local definitions, columns, literals = { "id INT4 PRIMARY KEY" }, { "id" }, { "1" }
    for _, spec in ipairs(catalog.fields) do
        definitions[#definitions + 1] = "c_" .. spec.name .. " " .. spec.sql_type
        columns[#columns + 1] = "c_" .. spec.name
        literals[#literals + 1] = spec.literal
    end
    ok(admin:batch("CREATE TABLE " .. qualified .. "scalar_values (" .. table.concat(definitions, ",") .. ");"
        .. "INSERT INTO " .. qualified .. "scalar_values (" .. table.concat(columns, ",") .. ") VALUES ("
        .. table.concat(literals, ",") .. ");INSERT INTO " .. qualified .. "scalar_values(id) VALUES (2),(3);"
        .. "CREATE TABLE " .. qualified .. "events(id INT8 PRIMARY KEY, value TEXT);"
        .. "CREATE TABLE " .. qualified .. "queue_gate(id INT4 PRIMARY KEY, n INT4 NOT NULL);"
        .. "INSERT INTO " .. qualified .. "queue_gate VALUES(1, 0);"
        .. "CREATE TABLE " .. qualified .. "fifo(id INT4 PRIMARY KEY, n INT4 NOT NULL);"
        .. "INSERT INTO " .. qualified .. "fifo VALUES(1, 0);"))
end

local function field_tests()
    for _, spec in ipairs(catalog.fields) do
        case("field/" .. spec.name, function()
            local rows = ok(admin:query("SELECT c_" .. spec.name .. " AS value FROM " .. qualified .. "scalar_values WHERE id IN (1,2) ORDER BY id"))
            equal(#rows, 2)
            equal(rows[1].value, spec.expected, spec.name, spec.epsilon)
            equal(rows[2].value, null, spec.name .. " SQL NULL")
            local expected = spec.param
            if type(expected) == "table" and expected.__sqlx_param then expected = expected.value end
            equal(row(admin:query("SELECT " .. spec.bind .. " AS value", spec.param)).value,
                expected, spec.name .. " parameter", spec.epsilon)
            equal(ok(admin:execute_wait("UPDATE " .. qualified .. "scalar_values SET c_" .. spec.name
                .. " = " .. spec.bind .. " WHERE id=3", spec.param)).rows_affected, 1)
            equal(row(admin:query("SELECT c_" .. spec.name .. " AS value FROM " .. qualified
                .. "scalar_values WHERE id=3")).value, expected, spec.name .. " persisted parameter", spec.epsilon)
        end)
    end
    case("field/serial-smallserial-bigserial-identity", function()
        ok(admin:execute_wait("CREATE TABLE " .. qualified .. [[generated_values(
            a SMALLSERIAL, b SERIAL, c BIGSERIAL, d INT8 GENERATED ALWAYS AS IDENTITY)]]))
        local value = row(admin:query("INSERT INTO " .. qualified .. "generated_values DEFAULT VALUES RETURNING *"))
        equal(value, { a = 1, b = 1, c = 1, d = 1 })
    end)
    case("field/all-columns-in-one-row", function()
        local value = row(admin:query("SELECT * FROM " .. qualified .. "scalar_values WHERE id = 1"))
        for _, spec in ipairs(catalog.fields) do equal(value["c_" .. spec.name], spec.expected, spec.name, spec.epsilon) end
    end)
    case("field/empty-result-and-null-first-row", function()
        equal(ok(admin:query("SELECT 1 AS n WHERE FALSE")), {})
        local rows = ok(admin:query([[SELECT n FROM (VALUES
            (1, NULL::INT8), (2, 9223372036854775807::INT8)) AS values_with_order(position,n) ORDER BY position]]))
        equal(rows[1].n, null)
        equal(rows[2].n, math.maxinteger)
    end)
    case("field/float-special-values", function()
        local value = row(admin:query([[SELECT 'NaN'::FLOAT8 AS nan, 'Infinity'::FLOAT8 AS pos,
            '-Infinity'::FLOAT4 AS neg, 1.23456789012345::FLOAT8 AS precise]]))
        expect(value.nan ~= value.nan, "NaN was not preserved")
        equal(value.pos, math.huge); equal(value.neg, -math.huge)
        equal(value.precise, 1.23456789012345, "double precision", 1e-14)
    end)
    case("field/time-fractions-and-timezone", function()
        local value = row(admin:query([[SELECT '00:00:00'::TIME AS midnight,
            '12:30:45.500000'::TIME AS half, '12:30:45.000001'::TIME AS micro,
            '2024-01-01 00:00:00+08'::TIMESTAMPTZ AS utc,
            '12:00:00+05:30'::TIMETZ AS offset]]))
        equal(value, { midnight = "00:00:00", half = "12:30:45.500", micro = "12:30:45.000001",
            utc = "2023-12-31T16:00:00Z", offset = "12:00:00+05:30" })
    end)
    for _, spec in ipairs(catalog.arrays) do
        case("array/" .. spec[1] .. "/stored-empty-null-elements", function()
            local table_name = qualified .. "array_" .. spec[1]
            local expression = spec[5] or ("$1::" .. spec[2])
            ok(admin:execute_wait("CREATE TABLE " .. table_name .. "(id INT4 PRIMARY KEY, value " .. spec[2] .. ")"))
            ok(admin:execute_wait("INSERT INTO " .. table_name .. " VALUES (1, " .. expression .. ")", sqlx.array(spec[1], spec[3])))
            ok(admin:execute_wait("INSERT INTO " .. table_name .. " VALUES (2, " .. expression .. ")", sqlx.array(spec[1], {})))
            ok(admin:execute_wait("INSERT INTO " .. table_name .. " VALUES (3, NULL)"))
            local rows = ok(admin:query("SELECT value FROM " .. table_name .. " ORDER BY id"))
            equal(#rows, 3); equal(rows[1].value, spec[3], "array", spec[4])
            equal(rows[2].value, {}); equal(rows[3].value, null)
        end)
    end
    case("array/type-alias-and-suffix", function()
        equal(row(admin:query("SELECT $1::INT8[] AS value", sqlx.array(" BIGINT[] ", { 1, null, 3 }))).value, { 1, null, 3 })
    end)
    for _, spec in ipairs(catalog.text_only) do
        case("cast-only/" .. spec[1], function()
            local table_name = qualified .. "cast_" .. spec[1]
            ok(admin:execute_wait("CREATE TABLE " .. table_name .. "(id INT4 PRIMARY KEY, value " .. spec[2] .. ")"))
            ok(admin:execute_wait("INSERT INTO " .. table_name .. " VALUES (1, (" .. spec[3] .. ")::" .. spec[2] .. "), (2, NULL)"))
            local rows = ok(admin:query("SELECT value::TEXT AS value FROM " .. table_name .. " ORDER BY id"))
            equal(#rows, 2); expect(type(rows[1].value) == "string" and rows[1].value ~= "", "TEXT cast returned no text")
            equal(rows[2].value, null)
            if spec[1] == "numeric" then equal(rows[1].value, "12345678901234567890.1234567890") end
            if spec[1] == "decimal" then equal(rows[1].value, "-1234567890123456.7890") end
            equal(row(admin:query("SELECT value::TEXT = ((" .. spec[3] .. ")::" .. spec[2] .. ")::TEXT AS same FROM "
                .. table_name .. " WHERE id = 1")).same, true)
        end)
    end
    for _, typename in ipairs({ "NUMERIC", "DECIMAL", "MONEY" }) do
        case("unsupported-native/" .. typename, function()
            error_result(admin:query("SELECT 12.34::" .. typename .. " AS value"), "ERROR", "decimal")
        end)
    end
    case("cast-only/enum-domain-composite", function()
        ok(admin:batch("CREATE TYPE " .. qualified .. "test_mood AS ENUM('ready','done');"
            .. "CREATE DOMAIN " .. qualified .. "test_positive AS INT4 CHECK(VALUE > 0);"
            .. "CREATE TYPE " .. qualified .. "test_pair AS (n INT4, label TEXT);"
            .. "CREATE TABLE " .. qualified .. "custom_values(mood " .. qualified .. "test_mood, "
            .. "positive " .. qualified .. "test_positive, pair " .. qualified .. "test_pair);"
            .. "INSERT INTO " .. qualified .. "custom_values VALUES('ready', 7, ROW(1,'two'));"))
        equal(row(admin:query("SELECT mood::TEXT AS mood, positive::INT4 AS positive, pair::TEXT AS pair FROM "
            .. qualified .. "custom_values")), { mood = "ready", positive = 7, pair = "(1,two)" })
    end)
end

local function parameter_tests()
    case("params/plain-text-not-json-injection-and-bytes", function()
        local text = "[not json] ' ; DROP TABLE imaginary; -- 中文"
        equal(row(admin:query("SELECT $1::TEXT AS a, $2::TEXT AS b, $3::BYTEA AS c",
            text, sqlx.text('{"looks":"json"}'), sqlx.bytes(catalog.binary))),
            { a = text, b = '{"looks":"json"}', c = catalog.binary })
        equal(row(admin:query("SELECT $1::BYTEA AS value", sqlx.bytes(""))).value, "")
    end)
    case("params/json-scalars-object-array-and-null", function()
        local values = { false, true, 42, 1.25, "中文", null, { key = "value", child = { false, null, 7 } } }
        for _, value in ipairs(values) do equal(row(admin:query("SELECT $1::JSONB AS value", sqlx.json(value))).value, value) end
        local value = row(admin:query("SELECT $1::JSONB AS value", { plain = "table", enabled = false })).value
        equal(value, { plain = "table", enabled = false })
        equal(row(admin:query("SELECT $1::JSONB AS value", sqlx.json(nil))).value, null)
        equal(row(admin:query([[SELECT $1::JSONB IS NULL AS sql_null,
            jsonb_typeof($2::JSONB) AS json_type]], sqlx.null("jsonb"), sqlx.json(null))),
            { sql_null = true, json_type = "null" })
        local nested = { leaf = null }
        for _ = 1, 30 do nested = { nested } end
        equal(row(admin:query("SELECT $1::JSONB AS value", sqlx.json(nested))).value, nested)
    end)
    case("params/json-direct-conversion-compatibility", function()
        local object = { ['quote"slash\\line\n'] = "escaped key", [""] = "empty key", nested = { false, null, 1.25 },
            low = math.mininteger, high = math.maxinteger }
        for _, typename in ipairs({ "JSON", "JSONB" }) do
            equal(row(admin:query("SELECT $1::" .. typename .. " AS value", object)).value, object)
            equal(row(admin:query("SELECT $1::" .. typename .. " AS value", sqlx.json(object))).value, object)
            equal(row(admin:query("SELECT $1::" .. typename .. "[] AS value",
                sqlx.array(typename:lower(), { object, null, false, "text" }))).value, { object, null, false, "text" })
        end
        equal(row(admin:query("SELECT jsonb_typeof($1::JSONB) AS value", {})).value, "array")
        local sparse = { 1, 2, 3 }
        sparse[2] = nil
        equal(row(admin:query("SELECT $1::JSONB AS value", sparse)).value, { 1, null, 3 })
        local numeric_keys = { [0] = "zero", [-2] = "negative", label = "object" }
        equal(row(admin:query("SELECT $1::JSONB AS value", numeric_keys)).value,
            { ["0"] = "zero", ["-2"] = "negative", label = "object" })
        local depth = { leaf = true }
        for _ = 1, 63 do depth = { depth } end
        equal(row(admin:query("SELECT jsonb_typeof($1::JSONB) AS value", depth)).value, "array")
        error_result(admin:query("SELECT $1::JSONB", { depth }), "ERROR", "64")
        local cyclic = {}; cyclic.self = cyclic
        error_result(admin:query("SELECT $1::JSONB", cyclic), "ERROR", "64")
        equal(row(admin:query("SELECT 1 AS value")).value, 1, "connection survives depth/cycle errors")
    end)
    for _, typename in ipairs({ "bool", "int2", "int4", "int8", "float4", "float8", "text", "bytea", "jsonb",
        "uuid", "date", "time", "timetz", "timestamp", "timestamptz" }) do
        case("params/typed-null/" .. typename, function()
            equal(row(admin:query("SELECT $1::" .. typename .. " AS value", sqlx.null(typename))).value, null)
        end)
    end
    case("params/implicit-null-and-trailing-nil", function()
        equal(row(admin:query("SELECT $1::TEXT AS a, $2::TEXT AS b, $3::TEXT AS c", nil, null, nil)),
            { a = null, b = null, c = null })
        equal(row(admin:query("SELECT $1::TEXT AS value", sqlx.null())).value, null)
    end)
    local invalid = {
        { "json-invalid-key-utf8", "SELECT $1::JSONB", { [string.char(255)] = true } },
        { "json-invalid-value-utf8", "SELECT $1::JSONB", { value = string.char(255) } },
        { "json-bool-key", "SELECT $1::JSONB", { [false] = 1 } },
        { "json-fractional-key", "SELECT $1::JSONB", { [1.25] = 1 } },
        { "json-nan", "SELECT $1::JSONB", { value = 0 / 0 } },
        { "json-infinity", "SELECT $1::JSONB", sqlx.json({ value = math.huge }) },
        { "json-function", "SELECT $1::JSONB", { value = function() end } },
        { "json-array-invalid-value", "SELECT $1::JSONB[]", sqlx.array("jsonb", { { value = math.huge } }) },
        { "invalid-utf8", "SELECT $1::TEXT", string.char(255) },
        { "typed-invalid-utf8", "SELECT $1::TEXT", sqlx.text(string.char(255)) },
        { "function-param", "SELECT $1::TEXT", function() end },
        { "null-type", "SELECT $1::TEXT", sqlx.null("does_not_exist") },
        { "array-type", "SELECT $1::TEXT[]", sqlx.array("date", { "2024-01-01" }) },
        { "array-int2-overflow", "SELECT $1::INT2[]", sqlx.array("int2", { 32768 }) },
        { "array-int4-overflow", "SELECT $1::INT4[]", sqlx.array("int4", { 2147483648 }) },
        { "array-wrong-type", "SELECT $1::BOOL[]", sqlx.array("bool", { 1 }) },
        { "array-invalid-uuid", "SELECT $1::UUID[]", sqlx.array("uuid", { "not-a-uuid" }) },
        { "array-invalid-utf8", "SELECT $1::TEXT[]", sqlx.array("text", { string.char(255) }) },
        { "array-not-sequence", "SELECT $1::INT8[]", sqlx.array("int8", { wrong = 1 }) },
    }
    for _, spec in ipairs(invalid) do
        case("params/reject/" .. spec[1], function()
            error_result(admin:query(spec[2], spec[3]), "ERROR")
            equal(row(admin:query("SELECT 1 AS value")).value, 1, "connection survives argument error")
        end)
    end
end

local function operation_tests()
    local events = qualified .. "events"
    case("api/query-returning-execute-metadata", function()
        equal(row(admin:query("INSERT INTO " .. events .. " VALUES(10, $1::TEXT) RETURNING id, value", "returning")),
            { id = 10, value = "returning" })
        local result = ok(admin:execute_wait("UPDATE " .. events .. " SET value=$1::TEXT WHERE id=$2::INT8", "changed", 10))
        equal(result.rows_affected, 1); equal(result.last_insert_id, nil, "PG has no last_insert_id")
        equal(ok(admin:execute_wait("DELETE FROM " .. events .. " WHERE id=10")).rows_affected, 1)
        equal(ok(admin:execute_wait("DELETE FROM " .. events .. " WHERE id=10")).rows_affected, 0)
    end)
    case("api/execute-fire-and-forget-fifo", function()
        admin:execute("INSERT INTO " .. events .. " VALUES($1::INT8, $2::TEXT)", 11, "first")
        admin:execute("UPDATE " .. events .. " SET value=$1::TEXT WHERE id=$2::INT8", "second", 11)
        equal(row(admin:query("SELECT value FROM " .. events .. " WHERE id=11")).value, "second")
    end)
    case("api/batch-and-execute-batch", function()
        local result = ok(admin:batch("INSERT INTO " .. events .. " VALUES(12,'batch');UPDATE " .. events .. " SET value='two' WHERE id=12;"))
        equal(result.rows_affected, 2)
        admin:execute_batch("INSERT INTO " .. events .. " VALUES(13,'async');UPDATE " .. events .. " SET value='done' WHERE id=13;")
        equal(row(admin:query("SELECT value FROM " .. events .. " WHERE id=13")).value, "done")
    end)
    case("api/transaction-commit-and-empty", function()
        local result = ok(admin:transaction({
            { "INSERT INTO " .. events .. " VALUES($1::INT8,$2::TEXT)", 20, "one" },
            { "UPDATE " .. events .. " SET value=$1::TEXT WHERE id=$2::INT8", "two", 20 },
        }))
        equal(result.rows_affected, 2); equal(result.message, "ok")
        equal(row(admin:query("SELECT value FROM " .. events .. " WHERE id=20")).value, "two")
        equal(ok(admin:transaction({})).rows_affected, 0)
    end)
    case("api/transaction-rollback-and-sqlstate", function()
        local result = error_result(admin:transaction({
            { "INSERT INTO " .. events .. " VALUES(21,'must rollback')" },
            { "INSERT INTO " .. events .. " VALUES(21,'duplicate')" },
        }), "DB")
        equal(result.sqlstate, "23505"); expect(type(result.constraint) == "string", "constraint missing")
        equal(result.table, "events")
        equal(row(admin:query("SELECT count(*) AS n FROM " .. events .. " WHERE id=21")).n, 0)
    end)
    case("api/transaction-trailing-nil-and-fire-and-forget", function()
        ok(admin:transaction({ table.pack("INSERT INTO " .. events .. " VALUES($1::INT8,$2::TEXT)", 22, nil) }))
        equal(row(admin:query("SELECT value FROM " .. events .. " WHERE id=22")).value, null)
        admin:execute_transaction({ { "INSERT INTO " .. events .. " VALUES(23,'async')" },
            { "UPDATE " .. events .. " SET value='committed' WHERE id=23" } })
        equal(row(admin:query("SELECT value FROM " .. events .. " WHERE id=23")).value, "committed")
    end)
    case("api/reject-sparse-invalid-transactions-without-partial-write", function()
        error_result(admin:transaction({ [1] = { "INSERT INTO " .. events .. " VALUES(24,'bad')" }, [3] = { "SELECT 1" } }), "ERROR")
        error_result(admin:transaction({ { "INSERT INTO " .. events .. " VALUES(24,'bad')" }, { false } }), "ERROR")
        equal(row(admin:query("SELECT count(*) AS n FROM " .. events .. " WHERE id=24")).n, 0)
    end)
    case("errors/syntax-missing-parameter-duplicate-column", function()
        equal(error_result(admin:query("SELEC 1"), "DB").sqlstate, "42601")
        error_result(admin:query("SELECT $1::INT8 AS value"), "DB")
        error_result(admin:query("SELECT 1 AS duplicate, 2 AS duplicate"), "ERROR", "duplicate")
        equal(row(admin:query("SELECT 1 AS a, 2 AS b")), { a = 1, b = 2 })
    end)
    case("errors/not-null-check-foreign-key-and-recovery", function()
        ok(admin:batch("CREATE TABLE " .. qualified .. "parent_keys(id INT4 PRIMARY KEY);"
            .. "INSERT INTO " .. qualified .. "parent_keys VALUES(1);"
            .. "CREATE TABLE " .. qualified .. "constraints_test(id INT4 PRIMARY KEY, n INT4 NOT NULL CHECK(n>0), "
            .. "parent INT4 REFERENCES " .. qualified .. "parent_keys(id));"))
        local table_name = qualified .. "constraints_test"
        equal(error_result(admin:execute_wait("INSERT INTO " .. table_name .. " VALUES(1,NULL,1)"), "DB").sqlstate, "23502")
        equal(error_result(admin:execute_wait("INSERT INTO " .. table_name .. " VALUES(1,-1,1)"), "DB").sqlstate, "23514")
        equal(error_result(admin:execute_wait("INSERT INTO " .. table_name .. " VALUES(1,1,999)"), "DB").sqlstate, "23503")
        equal(ok(admin:execute_wait("INSERT INTO " .. table_name .. " VALUES(1,1,1)")).rows_affected, 1)
    end)
    case("api/find-connection-stats-and-cross-service-response", function()
        equal(sqlx.find_connection(schema .. ":missing"), nil)
        local shared = assert(sqlx.find_connection(main_name))
        equal(row(shared:query("SELECT 123 AS value")).value, 123)
        equal(sqlx.stats()[main_name], 0)
        local peer = moon.new_service { name = schema .. "_peer", file = self_file, mode = "sqlx_test_peer", threadid = 3 }
        expect(peer > 0, "peer creation failed"); peers[#peers + 1] = peer
        local pending = {}
        for i = 1, 8 do
            pending[i] = start_job(function()
                return row(moon.call("lua", peer, main_name, "SELECT $1::INT8 AS n, $2::TEXT AS t", table.pack(i, nil)))
            end)
        end
        for i, job in ipairs(pending) do equal(join(job), { n = i, t = null }, "response owner/correlation") end
    end)
end

local function lifecycle_tests()
    case("connection/persistent-session-and-statement-cache", function()
        local db = open("persistent")
        local pid = row(db:query("SELECT pg_backend_pid() AS pid")).pid
        ok(db:batch("CREATE TEMP TABLE sqlx_session_probe(n BIGINT); INSERT INTO sqlx_session_probe VALUES(1)"))
        for i = 1, 5 do
            equal(row(db:query("SELECT $1::BIGINT AS n, pg_backend_pid() AS pid", i)), { n = i, pid = pid })
        end
        ok(db:execute_wait("UPDATE sqlx_session_probe SET n=n+1"))
        ok(db:transaction({ { "UPDATE sqlx_session_probe SET n=n+1" } }))
        equal(row(db:query("SELECT n FROM sqlx_session_probe")).n, 3)
        equal(row(db:query("SELECT pg_backend_pid() AS pid")).pid, pid)
        expect(row(db:query("SELECT count(*)::BIGINT AS n FROM pg_prepared_statements WHERE statement = $1",
            "SELECT $1::BIGINT AS n, pg_backend_pid() AS pid")).n >= 1, "prepared statement was not cached")
        close(db)
    end)
    case("transaction/error-releases-locks-before-next-request", function()
        local db = open("rollback_locks")
        local pid = row(db:query("SELECT pg_backend_pid() AS pid")).pid
        error_result(db:transaction({
            { "UPDATE " .. qualified .. "queue_gate SET n=n+1 WHERE id=1" },
            { "SELECT 1/0" },
        }), "DB")
        wait_until(function()
            return row(admin:query("SELECT state FROM pg_stat_activity WHERE pid=$1::BIGINT", pid)).state == "idle"
        end, "failed transaction must finish ROLLBACK, not remain idle in transaction (aborted)", 1000)
        -- The failed connection remains idle: another connection must be able
        -- to take the lock without waiting for a future request to flush ROLLBACK.
        ok(admin:transaction({
            { "SET LOCAL lock_timeout = '1s'" },
            { "SELECT * FROM " .. qualified .. "queue_gate WHERE id=1 FOR UPDATE" },
        }))
        equal(row(db:query("SELECT 42 AS n")).n, 42)
        close(db)
    end)
    case("connection/try-connect-numeric-options-and-url-alias", function()
        local db = open("try", 5000, nil, true)
        equal(row(db:query("SELECT 1 AS value")).value, 1); close(db)
        local alias_url = url:gsub("^postgres://", "postgresql://")
        local alias, err = sqlx.try_connect(alias_url, schema .. ":url_alias", connection_options)
        expect(alias, safe_message(err and err.message)); connections[#connections + 1] = alias
        equal(row(alias:query("SELECT 1 AS value")).value, 1); close(alias)
    end)
    case("transaction/commit-error-discards-connection", function()
        local db = open("commit_error")
        local pid = row(db:query("SELECT pg_backend_pid() AS pid")).pid
        ok(db:batch("CREATE TEMP TABLE sqlx_commit_probe(n BIGINT UNIQUE DEFERRABLE INITIALLY DEFERRED)"))
        local err = error_result(db:transaction({ { "INSERT INTO sqlx_commit_probe VALUES(1),(1)" } }), "DB")
        equal(err.sqlstate, "23505", "commit error metadata must be preserved")
        expect(row(db:query("SELECT pg_backend_pid() AS pid")).pid ~= pid, "failed COMMIT connection was reused")
        close(db)
    end)
    case("connection/reject-invalid-options-and-url", function()
        for _, key in ipairs({ "connect_timeout", "request_timeout", "max_rows", "queue_capacity", "reconnect_max_delay" }) do
            for _, value in ipairs({ 0, -1, math.maxinteger }) do
                local db, err = sqlx.try_connect(url, schema .. ":invalid", { [key] = value })
                equal(db, nil); error_result(err, "ERROR")
            end
        end
        for _, key in ipairs({ "reconnect_initial_delay", "reconnect_log_interval" }) do
            for _, value in ipairs({ -1, math.maxinteger }) do
                local db, err = sqlx.try_connect(url, schema .. ":invalid", { [key] = value })
                equal(db, nil); error_result(err, "ERROR")
            end
        end
        local invalid_db, invalid_err = sqlx.try_connect(url, schema .. ":invalid",
            { reconnect_initial_delay = 1001, reconnect_max_delay = 1000 })
        equal(invalid_db, nil); error_result(invalid_err, "ERROR")
        local db, err = sqlx.try_connect("not-a-database-url", schema .. ":invalid")
        equal(db, nil); error_result(err)
        local success = pcall(sqlx.connect, "not-a-database-url", schema .. ":invalid")
        equal(success, false, "connect must raise")
    end)
    case("limits/max-rows-boundary-and-recovery", function()
        local db = open("max_rows", { max_rows = 3 })
        local pid = row(db:query("SELECT pg_backend_pid() AS pid")).pid
        equal(#ok(db:query("SELECT generate_series(1,3) AS n")), 3)
        error_result(db:query("SELECT generate_series(1,4) AS n"), nil, "max_rows")
        local recovered = row(db:query("SELECT 7 AS value, pg_backend_pid() AS pid"))
        equal(recovered.value, 7)
        expect(recovered.pid ~= pid, "partially read connection was reused after max_rows")
        close(db)
    end)
    for _, method in ipairs({ "query", "execute_wait", "batch", "transaction" }) do
        case("limits/request-timeout/" .. method, function()
            local db = open("timeout_" .. method, { request_timeout = slow_ms })
            local statement = "SELECT pg_sleep(" .. tostring(timeout_sleep_ms / 1000) .. ")"
            local started = moon.clock()
            local result
            if method == "transaction" then
                result = db:transaction({ { "INSERT INTO " .. qualified .. "events VALUES(30,'timeout rollback')" }, { statement } })
            else result = db[method](db, statement) end
            error_result(result, "TIMEOUT")
            close(db) -- No replay. A timed-out non-transactional write may have committed.
            expect((moon.clock() - started) * 1000 < timeout_budget_ms,
                "timeout/close waited for the cancelled database operation")
            if method == "transaction" then
                wait_until(function()
                    return row(admin:query("SELECT count(*) AS n FROM " .. qualified .. "events WHERE id=30")).n == 0
                end, "timed-out transaction rollback")
            end
        end)
    end
    case("limits/timeout-queued-request-reconnects-without-replay", function()
        local db, name = open("timeout_queued", { request_timeout = slow_ms, queue_capacity = 2 })
        local pid = row(db:query("SELECT pg_backend_pid() AS pid")).pid
        local first = start_job(function()
            return db:query("SELECT pg_sleep(" .. tostring(timeout_sleep_ms / 1000) .. ")")
        end)
        local second = start_job(function() return db:query("SELECT pg_backend_pid() AS pid") end)
        equal(sqlx.stats()[name], 2, "requests were not queued before the timeout")
        error_result(join(first), "TIMEOUT")
        expect(row(join(second)).pid ~= pid, "queued request reused timed-out transport")
        equal(sqlx.stats()[name], 0)
        equal(row(db:query("SELECT 7 AS n")).n, 7)
        close(db)
    end)
    case("queue/busy-counter-and-no-replay", function()
        local db, name = open("busy", { queue_capacity = 1, request_timeout = 15000 })
        local pid = row(db:query("SELECT pg_backend_pid() AS pid")).pid
        local first, second
        with_gate(function()
            first = start_job(function() return db:execute_wait("UPDATE " .. qualified .. "queue_gate SET n=n+1 WHERE id=1") end)
            wait_locked(pid)
            second = start_job(function() return db:execute_wait("UPDATE " .. qualified .. "queue_gate SET n=n+1 WHERE id=1") end)
            equal(sqlx.stats()[name], 2, "inflight plus queued")
            error_result(db:execute_wait("UPDATE " .. qualified .. "queue_gate SET n=n+100 WHERE id=1"), "BUSY")
            error_result(db:transaction({ { "UPDATE " .. qualified .. "queue_gate SET n=n+1000 WHERE id=1" } }), "BUSY")
            equal(sqlx.stats()[name], 2, "BUSY must restore counter")
        end)
        ok(join(first)); ok(join(second))
        equal(row(admin:query("SELECT n FROM " .. qualified .. "queue_gate WHERE id=1")).n, 2)
        equal(sqlx.stats()[name], 0); close(db)
    end)
    case("connection/close-full-queue-shared-handles-drain", function()
        local db, name = open("close_full", { queue_capacity = 1, request_timeout = 15000 })
        local shared = assert(sqlx.find_connection(name)); connections[#connections + 1] = shared
        local pid = row(db:query("SELECT pg_backend_pid() AS pid")).pid
        local first, second, closing, other_closing
        with_gate(function()
            first = start_job(function() return db:execute_wait("UPDATE " .. qualified .. "queue_gate SET n=n+1 WHERE id=1") end)
            wait_locked(pid)
            second = start_job(function() return db:execute_wait("UPDATE " .. qualified .. "queue_gate SET n=n+1 WHERE id=1") end)
            equal(sqlx.stats()[name], 2)
            closing = start_job(function() close(db); return true end)
            other_closing = start_job(function() close(shared); return true end)
            expect(not closing.done and not other_closing.done, "close acknowledged before drain")
            equal(sqlx.find_connection(name), nil)
            error_result(db:query("SELECT 1"), "CLOSED")
        end)
        ok(join(first)); ok(join(second)); equal(join(closing), true); equal(join(other_closing), true)
        equal(row(admin:query("SELECT n FROM " .. qualified .. "queue_gate WHERE id=1")).n, 2)
        equal(sqlx.stats()[name], nil); close(db); close(shared)
        error_result(db:query("SELECT 1"), "CLOSED")
    end)
    case("connection/same-name-replacement", function()
        local old, name = open("replace")
        local current = open("replace", nil, name)
        close(old)
        local found = assert(sqlx.find_connection(name))
        equal(row(found:query("SELECT 42 AS value")).value, 42)
        equal(sqlx.stats()[name], 0, "old close removed replacement")
        close(current); equal(sqlx.find_connection(name), nil)
    end)
    case("connection/last-handle-gc-releases-registry", function()
        local name = schema .. ":gc"
        do
            -- Deliberately not kept in the cleanup list: this tests last-handle GC.
            local db = sqlx.connect(url, name, connection_options)
            equal(row(db:query("SELECT 1 AS value")).value, 1)
        end
        collectgarbage("collect"); collectgarbage("collect")
        wait_until(function() return sqlx.stats()[name] == nil end, "last-handle GC cleanup")
        equal(sqlx.find_connection(name), nil)
    end)
    case("native/invalid-response-token", function()
        local native = require("rust.sqlx")
        error_result(native.decode(0, moon.id), "ERROR", "response id")
        error_result(native.decode(-1, moon.id), "ERROR", "response id")
    end)
end

local function driver_tests()
    local db, record = new_driver("driver")
    case("driver/pool-and-affinity", function()
        local stats = driver.stats(db)
        equal(stats.poolsize, 3); equal(stats.accepting, true); equal(#stats.lanes, 3)
        local pids = {}
        for key = 1, 3 do
            local pid = driver_row(driver.query_on(db, key, "SELECT pg_backend_pid() AS pid")).pid
            equal(driver_row(driver.query_on(db, key, "SELECT pg_backend_pid() AS pid")).pid, pid)
            expect(not pids[pid], "different integer lanes share a physical connection"); pids[pid] = true
        end
        local a = driver_row(driver.query_on(db, "player:1001", "SELECT pg_backend_pid() AS pid")).pid
        equal(driver_row(driver.query_on(db, "player:1001", "SELECT pg_backend_pid() AS pid")).pid, a)
        equal(driver_row(driver.query(db, "SELECT pg_backend_pid() AS pid")).pid,
            driver_row(driver.query_on(db, 1, "SELECT pg_backend_pid() AS pid")).pid)
    end)
    case("driver/all-supported-fields-over-ipc", function()
        local value = driver_row(driver.query_any(db, "SELECT * FROM " .. qualified .. "scalar_values WHERE id=1"))
        for _, spec in ipairs(catalog.fields) do equal(value["c_" .. spec.name], spec.expected, spec.name, spec.epsilon) end
        local empty = driver_row(driver.query_any(db, "SELECT * FROM " .. qualified .. "scalar_values WHERE id=2"))
        for _, spec in ipairs(catalog.fields) do equal(empty["c_" .. spec.name], null) end
    end)
    for _, spec in ipairs(catalog.arrays) do
        case("driver/array-parameter-ipc/" .. spec[1], function()
            local expression = spec[5] or ("$1::" .. spec[2])
            equal(driver_row(driver.query_params_on(db, 1001, "SELECT " .. expression .. " AS value",
                driver.array(spec[1], spec[3]))).value, spec[3], "IPC array", spec[4])
        end)
    end
    case("driver/wrappers-null-and-trailing-nil-ipc", function()
        equal(driver_row(driver.query_params_on(db, 1001,
            "SELECT $1::TEXT AS t, $2::JSONB AS j, $3::BYTEA AS b, $4::INT8 AS n, $5::TEXT AS tail",
            driver.text("{literal}"), driver.json({ enabled = false, n = null }), driver.bytes(catalog.binary), driver.null("int8"), nil)),
            { t = "{literal}", j = { enabled = false, n = null }, b = catalog.binary, n = null, tail = null })
        equal(driver_row(driver.query_params(db, "SELECT $1::TEXT AS value", nil)).value, null)
        equal(driver_row(driver.query_params_any(db, "SELECT $1::INT8 AS value", math.maxinteger)).value, math.maxinteger)
    end)
    case("driver/query-table-and-buffer-input", function()
        equal(driver_row(driver.query(db, { "SELECT ", "42 AS value" })).value, 42)
        equal(driver_row(driver.query(db, json.concat({ "SELECT ", "43 AS value" }))).value, 43)
    end)
    -- Call every public routing variant. A barrier on EACH lane is required for
    -- fire-and-forget *_any: a following *_any query may select another lane.
    local function barrier()
        for key = 1, 3 do ok(driver.query_on(db, key, "SELECT 1 AS value")) end
    end
    local events = qualified .. "events"
    local operations = {
        { "execute", function(s) driver.execute(db, s) end },
        { "execute_on", function(s) driver.execute_on(db, 11, s) end },
        { "execute_any", function(s) driver.execute_any(db, s) end },
        { "execute_wait", function(s) return driver.execute_wait(db, s) end },
        { "execute_wait_on", function(s) return driver.execute_wait_on(db, 11, s) end },
        { "execute_wait_any", function(s) return driver.execute_wait_any(db, s) end },
        { "execute_params", function(s, id) driver.execute_params(db, s, id, "bound") end, true },
        { "execute_params_on", function(s, id) driver.execute_params_on(db, 11, s, id, "bound") end, true },
        { "execute_params_any", function(s, id) driver.execute_params_any(db, s, id, "bound") end, true },
        { "execute_params_wait", function(s, id) return driver.execute_params_wait(db, s, id, "bound") end, true },
        { "execute_params_wait_on", function(s, id) return driver.execute_params_wait_on(db, 11, s, id, "bound") end, true },
        { "execute_params_wait_any", function(s, id) return driver.execute_params_wait_any(db, s, id, "bound") end, true },
        { "batch", function(s) return driver.batch(db, s .. "; SELECT 1;") end },
        { "batch_on", function(s) return driver.batch_on(db, 11, s .. "; SELECT 1;") end },
        { "batch_any", function(s) return driver.batch_any(db, s .. "; SELECT 1;") end },
        { "execute_batch", function(s) driver.execute_batch(db, s .. "; SELECT 1;") end },
        { "transaction", function(s) return driver.transaction(db, { { s } }) end },
        { "transaction_on", function(s) return driver.transaction_on(db, 11, { { s } }) end },
        { "transaction_any", function(s) return driver.transaction_any(db, { { s } }) end },
        { "execute_transaction", function(s) driver.execute_transaction(db, { { s } }) end },
        { "execute_transaction_on", function(s) driver.execute_transaction_on(db, 11, { { s } }) end },
        { "pipe", function(s) return driver.pipe(db, { { s } }) end },
        { "execute_pipe", function(s) driver.execute_pipe(db, { { s } }) end },
    }
    local fire_and_forget = {
        execute = true, execute_on = true, execute_any = true,
        execute_params = true, execute_params_on = true, execute_params_any = true,
        execute_batch = true, execute_transaction = true, execute_transaction_on = true, execute_pipe = true,
    }
    for index, op in ipairs(operations) do
        case("driver/api/" .. op[1], function()
            local id = 1000 + index
            local statement = op[3] and ("INSERT INTO " .. events .. " VALUES($1::INT8,$2::TEXT)")
                or ("INSERT INTO " .. events .. " VALUES(" .. id .. ",'literal')")
            local result = op[2](statement, id)
            if fire_and_forget[op[1]] then
                equal(result, nil, "fire-and-forget return value")
            else
                ok(result); equal(result.num_queries, 1)
                expect(type(result.rows_affected) == "number" and result.rows_affected >= 1, "rows_affected missing")
            end
            barrier()
            equal(row(admin:query("SELECT value FROM " .. events .. " WHERE id=$1::INT8", id)).value, op[3] and "bound" or "literal")
        end)
    end
    case("driver/transaction-nil-rollback-and-error-shape", function()
        local result = ok(driver.transaction_on(db, 1001, {
            table.pack("INSERT INTO " .. events .. " VALUES($1::INT8,$2::TEXT)", 2000, nil),
            { "UPDATE " .. events .. " SET value=value WHERE id=2000" },
        }))
        equal(result.data, true); equal(result.num_queries, 2); equal(result.rows_affected, 2)
        equal(driver_row(driver.query_on(db, 1001, "SELECT value FROM " .. events .. " WHERE id=2000")).value, null)
        local err = driver.transaction_on(db, 1001, { { "INSERT INTO " .. events .. " VALUES(2001,'rollback')" },
            { "INSERT INTO " .. events .. " VALUES(2001,'duplicate')" } })
        equal(error_result(err, "DB").code, "DB"); equal(err.sqlstate, "23505")
        equal(driver_row(driver.query_on(db, 1001, "SELECT count(*) AS n FROM " .. events .. " WHERE id=2001")).n, 0)
        equal(error_result(driver.query(db, "SELECT 1 AS x, 2 AS x"), "ERROR").code, "DRIVER")
    end)
    case("driver/same-key-fifo-and-independent-lane", function()
        local key = "player:serialized"
        ok(driver.execute_wait_on(db, key, "UPDATE " .. qualified .. "fifo SET n=0 WHERE id=1"))
        -- Every update can succeed only if its predecessor has finished.
        for i = 1, 40 do
            driver.execute_params_on(db, key, "UPDATE " .. qualified .. "fifo SET n=$1::INT8::INT4 WHERE id=1 AND n=$2::INT8::INT4", i, i - 1)
        end
        equal(driver_row(driver.query_on(db, key, "SELECT n FROM " .. qualified .. "fifo WHERE id=1")).n, 40)
        local pid = driver_row(driver.query_on(db, 1, "SELECT pg_backend_pid() AS pid")).pid
        local blocked
        with_gate(function()
            blocked = start_job(function() return driver.execute_wait_on(db, 1, "UPDATE " .. qualified .. "queue_gate SET n=n+1 WHERE id=1") end)
            wait_locked(pid)
            equal(driver_row(driver.query_on(db, 2, "SELECT 9 AS value")).value, 9)
            equal(driver_row(driver.query_any(db, "SELECT 8 AS value")).value, 8)
            expect(not blocked.done, "blocked lane unexpectedly completed")
            local lengths = driver.len(db)
            expect(lengths[2] >= 1, "inflight lane absent from len") -- integer key 1 maps to lane 2
        end)
        ok(join(blocked)); barrier()
        equal(driver.len(db), { 0, 0, 0 })
    end)
    case("driver/lazy-connect", function()
        local lazy, rec = new_driver("lazy", { eager_connect = false, poolsize = 2 })
        local stats = driver.stats(lazy)
        equal(stats.lanes[1].connected, false); equal(stats.lanes[2].connected, false)
        equal(driver_row(driver.query_on(lazy, 2, "SELECT 1 AS value")).value, 1)
        stats = driver.stats(lazy)
        equal(stats.lanes[1].connected, true); equal(stats.lanes[2].connected, false)
        stop_driver(rec)
    end)
    case("driver/max-queue-busy-and-draining-shutdown", function()
        local limited, rec = new_driver("limited", { poolsize = 1, max_queue = 1 })
        local pid = driver_row(driver.query(limited, "SELECT pg_backend_pid() AS pid")).pid
        local pending
        with_gate(function()
            pending = start_job(function() return driver.execute_wait(limited, "UPDATE " .. qualified .. "queue_gate SET n=n+1 WHERE id=1") end)
            wait_locked(pid)
            equal(driver.len(limited), { 1 })
            equal(error_result(driver.execute_wait(limited, "UPDATE " .. qualified .. "queue_gate SET n=n+100 WHERE id=1"), "BUSY").code, "BUSY")
            driver.save_then_quit(limited)
            equal(driver.stats(limited).accepting, false)
            equal(error_result(driver.query(limited, "SELECT 1"), "CLOSED").code, "CLOSED")
            expect(moon.queryservice(rec.name) > 0, "driver exited before draining")
        end)
        ok(join(pending)); stop_driver(rec)
        equal(row(admin:query("SELECT n FROM " .. qualified .. "queue_gate WHERE id=1")).n, 1)
    end)
    case("driver/timeout-reconnect-without-replay", function()
        local timed, rec = new_driver("timed", { poolsize = 1, request_timeout = slow_ms })
        local pid = driver_row(driver.query(timed, "SELECT pg_backend_pid() AS pid")).pid
        -- Sequence increments are visible even if the timed-out statement rolls
        -- back. This distinguishes one execution from accidental write replay.
        ok(admin:execute_wait("CREATE SEQUENCE " .. qualified .. "attempts START 1"))
        local started = moon.clock()
        local err = driver.query(timed, "SELECT nextval('" .. schema .. ".attempts') AS attempt, pg_sleep("
            .. tostring(timeout_sleep_ms / 1000) .. ") AS pause")
        equal(error_result(err, "TIMEOUT").code, "TIMEOUT")
        expect((moon.clock() - started) * 1000 < timeout_budget_ms, "driver TIMEOUT waited for connection cleanup")
        local next_pid = driver_row(driver.query(timed, "SELECT pg_backend_pid() AS pid")).pid
        expect(next_pid ~= pid, "driver failed to recreate timed-out connection")
        equal(row(admin:query("SELECT last_value, is_called FROM " .. qualified .. "attempts")),
            { last_value = 1, is_called = true }, "timed-out statement must execute once, without replay")
        stop_driver(rec)
    end)
    case("driver/unserializable-result-does-not-stall-lane", function()
        local tested, rec = new_driver("serialization", { poolsize = 1 })
        for _, statement in ipairs({
            "SELECT 'NaN'::FLOAT8 AS value",
            [[SELECT (repeat('[', 40) || '1' || repeat(']', 40))::JSONB AS value]],
        }) do
            local err = driver.query(tested, statement)
            equal(error_result(err, "DRIVER", "serialize/send").code, "DRIVER")
            equal(driver_row(driver.query(tested, "SELECT 42 AS value")).value, 42)
            local lane = driver.stats(tested).lanes[1]
            expect(not lane.running and not lane.inflight and lane.queue == 0, "driver lane remained stuck")
        end
        stop_driver(rec)
    end)
    case("driver/save-then-quit", function() stop_driver(record) end)
end

local function cleanup()
    -- Each cleanup attempt is independent; one failure must not hide the others.
    for _, record in ipairs(services) do case("cleanup/service/" .. record.name, function() stop_driver(record) end) end
    for _, peer in ipairs(peers) do moon.kill(peer) end
    for i, job in ipairs(jobs) do
        if not job.done then case("cleanup/pending-job/" .. i, function() join(job) end) end
    end
    if created and not keep_data then
        case("cleanup/drop-isolated-schema", function()
            expect(schema:match("^sqlx_test_%d+_%d+_%x+$"), "unsafe schema name")
            -- Drop only the schema successfully CREATED by THIS run.
            ok(admin:execute_wait('DROP SCHEMA "' .. schema .. '" CASCADE'))
            created = false
        end)
    end
    for i = #connections, 1, -1 do
        case("cleanup/connection/" .. i, function() close(connections[i]) end)
    end
    if created then print("[INFO] Schema retained (keep-data or cleanup failure): " .. schema) end
end

moon.timeout(deadline_ms, function()
    if not finished then
        moon.error("[FAIL] Suite watchdog expired; inspect retained schema " .. schema .. ". No success reported.")
        moon.exit(2)
    end
end)
moon.async(function()
    local success, err = xpcall(function()
        setup()
        field_tests()
        parameter_tests()
        operation_tests()
        lifecycle_tests()
        if test_driver then driver_tests()
        else skipped = skipped + 1; print("[SKIP] driver integration (SQLX_TEST_DRIVER=0)") end
    end, debug.traceback)
    if not success then case("suite/setup-or-run", function() error(err) end) end
    cleanup()
    finished = true
    print(string.format("[SUMMARY] PASS=%d FAIL=%d SKIP=%d schema=%s", passed, failed, skipped, schema))
    if #failures > 0 then moon.error("[FAILED CASES] " .. table.concat(failures, ", ")) end
    moon.exit(failed == 0 and 0 or 1)
end)
