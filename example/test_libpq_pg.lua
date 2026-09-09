-- 手动 PostgreSQL 集成测试。仅在专用测试数据库运行；不会使用 SQLx。
-- 配置使用 PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSWORD/PGSSLMODE 等环境变量。
-- 创建唯一测试 schema，结束时清理。测试自身不自动启动数据库。
local moon = require("moon")
local pg = require("moon.db.libpq")
local client = require("libpq_sqldriver.client")

local opts = {
    host=os.getenv("PGHOST") or "127.0.0.1", port=tonumber(os.getenv("PGPORT") or "5432"),
    dbname=os.getenv("PGDATABASE") or "postgres", user=os.getenv("PGUSER") or "postgres",
    password=os.getenv("PGPASSWORD"), sslmode=os.getenv("PGSSLMODE") or "require",
    sslrootcert=os.getenv("PGSSLROOTCERT"), library=os.getenv("LIBPQ_LIBRARY"), timeout=5000,
}
local checks = 0
local function eq(actual, expected)
    checks = checks + 1
    assert(actual == expected, ("check %d: got %s, expected %s"):format(checks,tostring(actual),tostring(expected)))
end
local function good(result)
    assert(type(result)=="table" and not result.code,
        type(result)=="table" and (result.code or "") .. ": " .. (result.message or "") or "missing result")
    return result
end
local function connect() return good(pg.connect(opts)) end

moon.async(function()
    local db, driver, schema, created
    local ok, failure = xpcall(function()
        db = connect()
        schema = "moon_libpq_test_" .. os.time() .. "_" .. moon.id
        good(db:query('CREATE SCHEMA "' .. schema .. '"')); created=true
        local prefix = '"' .. schema .. '".'
        good(db:batch("CREATE TABLE " .. prefix .. "order_log(id bigserial PRIMARY KEY, k int, v int);"
            .. "CREATE TABLE " .. prefix .. "tx(id int PRIMARY KEY, amount bigint NOT NULL)"))

        -- 每种字段独立验证；typed 控制参数 OID，显式 cast 同时检查 PG 原生返回类型。
        local scalar = {
            {"boolean",true,true}, {"boolean",false,false},
            {"smallint",pg.typed("int2",-32768),-32768}, {"smallint",32767,32767},
            {"integer",-2147483648,-2147483648}, {"integer",2147483647,2147483647},
            {"bigint",math.mininteger,math.mininteger}, {"bigint",math.maxinteger,math.maxinteger},
            {"real",pg.typed("float4",1.25),1.25}, {"double precision",3.125,3.125},
            {"numeric",pg.typed("numeric","123456789012345678901234567890.000123"),"123456789012345678901234567890.000123"},
            {"text","中文 ' \" \\ $1","中文 ' \" \\ $1"}, {"text","",""},
            {"varchar(8)","hello","hello"}, {"char(4)","ab","ab  "}, {"name","name_test","name_test"},
            {"bytea",pg.bytea("\0\255\1'\\"),"\0\255\1'\\"}, {"bytea",pg.bytea(""),""},
            {"uuid",pg.typed("uuid","123e4567-e89b-12d3-a456-426614174000"),"123e4567-e89b-12d3-a456-426614174000"},
            {"date",pg.typed("date","2024-02-29"),"2024-02-29"},
            {"time",pg.typed("time","12:34:56.123456"),"12:34:56.123456"},
            {"timetz",pg.typed("timetz","12:34:56+08"),"12:34:56+08"},
            {"timestamp",pg.typed("timestamp","2024-02-29 12:34:56.123456"),"2024-02-29 12:34:56.123456"},
            {"timestamptz",pg.typed("timestamptz","2024-02-29 12:34:56+08"),"2024-02-29 04:34:56+00"},
            {"interval",pg.typed("interval","2 days 03:04:05"),"2 days 03:04:05"},
            {"inet",pg.typed("inet","192.0.2.1/24"),"192.0.2.1/24"},
            {"cidr",pg.typed("cidr","192.0.2.0/24"),"192.0.2.0/24"},
            {"macaddr",pg.typed("macaddr","08:00:2b:01:02:03"),"08:00:2b:01:02:03"},
            {"bit(4)",pg.typed("bit","1010"),"1010"}, {"varbit",pg.typed("varbit","101"),"101"},
            {"oid",pg.typed("oid","4294967295"),4294967295},
        }
        for _, case in ipairs(scalar) do
            local result = good(db:query("SELECT $1::" .. case[1] .. " AS v", {case[2]}))
            eq(result.rows[1].v,case[3]); eq(#result.columns,1)
        end
        for _, type_name in ipairs({"boolean","smallint","integer","bigint","real","double precision",
            "numeric","money","text","bytea","json","jsonb","uuid","date","time","timetz",
            "timestamp","timestamptz","interval","inet","cidr","macaddr","bit","varbit","oid","integer[]"}) do
            eq(good(db:query("SELECT NULL::" .. type_name .. " AS v")).rows[1].v, pg.NULL)
        end
        eq(type(good(db:query("SELECT 123.45::money AS v")).rows[1].v),"string")
        eq(good(db:query("SELECT $1::json AS v",{pg.typed("json",{x="a\"b",n=pg.NULL})})).rows[1].v.x,'a"b')
        eq(good(db:query("SELECT $1::jsonb AS v",{pg.jsonb({x=1,n=pg.NULL})})).rows[1].v.n,pg.NULL)
        eq(good(db:query("SELECT $1::jsonb AS v",{pg.jsonb(pg.NULL)})).rows[1].v,pg.NULL)
        local floats = good(db:query("SELECT 'NaN'::float8 AS n, 'Infinity'::float8 AS p, '-Infinity'::float4 AS m")).rows[1]
        eq(floats.n ~= floats.n,true); eq(floats.p,math.huge); eq(floats.m,-math.huge)

        for _, case in ipairs({{"int8",{math.maxinteger,pg.NULL,math.mininteger}},
            {"bool",{true,false,pg.NULL}}, {"text",{"NULL",'a,"\\{}',"",pg.NULL}},
            {"bytea",{"\0\255","",pg.NULL}}, {"numeric",{"1.000001",pg.NULL,"2.999999"}},
            {"uuid",{"123e4567-e89b-12d3-a456-426614174000",pg.NULL}}}) do
            local row = good(db:query("SELECT $1 AS v",{pg.array(case[1],case[2])})).rows[1].v
            for i, v in ipairs(case[2]) do eq(row[i],v) end
        end
        eq(#good(db:query("SELECT $1 AS v",{pg.array("text",{})})).rows[1].v,0)
        eq(good(db:query("SELECT ARRAY[[1,2],[3,4]] AS v")).rows[1].v[2][1],3)
        eq(good(db:query("SELECT '[0:1]={1,2}'::int[] AS v")).rows[1].v,"[0:1]={1,2}")
        -- 未内置的 PG 类型保留原始文本，不因为新类型/扩展 OID 报错。
        good(db:query("CREATE TYPE " .. prefix .. "mood AS ENUM ('happy','sad')"))
        eq(good(db:query("SELECT 'happy'::" .. prefix .. "mood AS v")).rows[1].v,"happy")
        eq(good(db:query("SELECT '[1,5)'::int4range AS v")).rows[1].v,"[1,5)")
        eq(good(db:query("SELECT point(1,2) AS v")).rows[1].v,"(1,2)")
        local dup = good(db:query("SELECT 1 AS x, 2 AS x",{}, {row_mode="array"})).rows[1]
        eq(dup[1],1); eq(dup[2],2)

        good(db:prepare("add_one","SELECT $1::bigint + 1 AS v",{"bigint"}))
        eq(good(db:query_prepared("add_one",{41})).rows[1].v,42)
        eq(good(db:batch("SELECT 1 AS v; SELECT 2 AS v")).results[2].rows[1].v,2)
        local table_name = prefix .. "tx"
        local tx = good(db:transaction({
            {sql="INSERT INTO " .. table_name .. " VALUES ($1,$2)",params={1,5}},
            {sql="INSERT INTO " .. table_name .. " VALUES ($1,$2) RETURNING amount",params={2,7}},
        }))
        eq(tx.results[2].rows[1].amount,7)
        local failed = db:transaction({{sql="INSERT INTO " .. table_name .. " VALUES (3,9)"},
            {sql="INSERT INTO " .. table_name .. " VALUES (1,999)"}})
        eq(failed.code,"DB"); eq(failed.sqlstate,"23505"); eq(failed.statement_index,2)
        eq(good(db:query("SELECT count(*) AS n FROM " .. table_name)).rows[1].n,2)
        local sum = good(db:query("SELECT SUM(amount) AS n, COALESCE(SUM(amount),0)::bigint AS i FROM " .. table_name)).rows[1]
        eq(sum.n,"12"); eq(sum.i,12)
        eq(db:query("SELECT 1/0").sqlstate,"22012")
        eq(good(db:query("SELECT 42 AS n")).rows[1].n,42) -- DB errors were drained

        -- 原生自动缓存：重复 SQL 只创建一个命名语句；LRU 淘汰会释放服务器资源。
        local cache_opts = {}; for k,v in pairs(opts) do cache_opts[k]=v end
        cache_opts.statement_cache_capacity=2
        local cached=good(pg.connect(cache_opts))
        local cache_sql="SELECT $1::bigint AS cached_value"
        for i=1,4 do eq(good(cached:query(cache_sql,{i})).rows[1].cached_value,i) end
        local inspect_sql="SELECT count(*)::bigint AS n FROM pg_prepared_statements WHERE left(name,10)='__moon_pq_'"
        eq(good(cached:batch(inspect_sql)).results[1].rows[1].n,1) -- batch 不占用自动缓存
        good(cached:query("SELECT 2 AS second"))
        good(cached:query(cache_sql,{5})) -- 刷新 LRU，second 应最先淘汰
        good(cached:query("SELECT 3 AS third"))
        eq(good(cached:batch(inspect_sql)).results[1].rows[1].n,2)
        eq(good(cached:batch("SELECT count(*)::bigint AS n FROM pg_prepared_statements WHERE statement='SELECT 2 AS second'"))
            .results[1].rows[1].n,0)
        -- 淘汰/prepare 也能在事务内完成，且仍保留所有用户语句结果。
        local cache_tx=good(cached:transaction({{sql=cache_sql,params={6}},{sql="SELECT 4 AS fourth"}}))
        eq(cache_tx.results[1].rows[1].cached_value,6); eq(cache_tx.results[2].rows[1].fourth,4)
        eq(good(cached:query(cache_sql,{7})).rows[1].cached_value,7)
        -- 同一 SQL，不同绑定 OID 必须分别准备，不能沿用上一次的参数类型。
        local typed_sql="SELECT $1::text AS value"
        eq(good(cached:query(typed_sql,{12})).rows[1].value,"12")
        eq(good(cached:query(typed_sql,{"text"})).rows[1].value,"text")
        cached:close()
        cache_opts.statement_cache_capacity=0
        cached=good(pg.connect(cache_opts))
        good(cached:query(cache_sql,{1})); good(cached:query(cache_sql,{2}))
        eq(good(cached:batch(inspect_sql)).results[1].rows[1].n,0)
        cached:close()

        local limited = connect()
        eq(limited:query("SELECT generate_series(1,5)",{}, {max_rows=2}).code,"LIMIT")
        eq(limited:connected(),false)
        limited = connect()
        eq(limited:query("SELECT repeat('x',100)",{}, {max_result_bytes=10}).code,"LIMIT")
        limited = connect()
        eq(limited:query("SELECT pg_sleep(1)",{}, {timeout=20}).code,"TIMEOUT")
        eq(limited:connected(),false)
        limited = connect()
        eq(limited:query("COPY (SELECT 1) TO STDOUT").code,"UNSUPPORTED")
        eq(limited:connected(),false)

        driver = assert(moon.new_service({name="libpq_test_driver",file="service/libpq_sqldriver.lua",opts=opts,poolsize=2}))
        assert(driver ~= 0)
        for i = 1, 50 do client.execute(driver,"INSERT INTO " .. prefix .. "order_log(k,v) VALUES (1,$1)",{i},"player:1") end
        local ordered = good(client.query(driver,"SELECT v FROM " .. prefix .. "order_log ORDER BY id",{},"player:1")).rows
        eq(#ordered,50); for i,row in ipairs(ordered) do eq(row.v,i) end
        local done, parallel_errors = 0, {}
        for _ = 1, 4 do moon.async(function()
            local r = client.query_any(driver,"SELECT pg_sleep(0.05), 1 AS n")
            if r.code then parallel_errors[#parallel_errors+1]=r.code end
            done=done+1
        end) end
        while done < 4 do moon.sleep(10) end
        eq(#parallel_errors,0)
        eq(#client.stats(driver).lanes,2)
        good(client.transaction(driver,{{sql="UPDATE " .. table_name .. " SET amount=amount+1 WHERE id=1"}},"player:1"))
        eq(client.query(driver,"SELECT pg_sleep(1)",{},1,{timeout=20}).code,"TIMEOUT")
        eq(good(client.query(driver,"SELECT 1 AS n",{},1)).rows[1].n,1) -- next request reconnects
        good(client.save_then_quit(driver)); driver=nil
    end, debug.traceback)

    if driver then pcall(client.save_then_quit,driver) end
    if created then
        if not db or not db:connected() then db=pg.connect(opts) end
        if db and not db.code then
            local cleanup = db:query('DROP SCHEMA "' .. schema .. '" CASCADE')
            if cleanup.code then moon.error("Manual cleanup required for schema",schema,cleanup.code) end
        else moon.error("Manual cleanup required for schema",schema) end
    end
    if db and not db.code then db:close() end
    if ok then moon.info("libpq PostgreSQL integration checks passed",checks)
    else moon.error("libpq PostgreSQL integration checks FAILED",failure) end
    moon.exit(ok and 0 or 1)
end)
