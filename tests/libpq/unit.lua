-- Standalone Lua tests with the real Moon JSON codec and mocked scheduler/I/O.
-- Run with target/libpq-tests/bin/libpq_lua_test.exe, never moon.exe.
package.path = "lualib/?.lua;lualib/?/init.lua;" .. package.path
local wrappers = require("moon.db.libpq.types")
-- These functions compile the production C++ codec, not a Lua reimplementation.
local t = setmetatable(require("libpq.testcodec"), {__index=wrappers})
local json = require("json")
local checks = 0
local function eq(actual, expected)
    checks = checks + 1
    assert(actual == expected, ("check %d: %s ~= %s"):format(checks, tostring(actual), tostring(expected)))
end
local function throws(fn) eq(pcall(fn), false) end
for _, n in ipairs({math.mininteger, -1, 0, 1, math.maxinteger}) do
    local p = t.encode(n); eq(p.oid, 20); eq(t.decode(p.value, 20), n)
end
eq(t.decode("123456789012345678901234567890.00001", 1700), "123456789012345678901234567890.00001")
eq(t.decode("$123.45", 790), "$123.45")
eq(t.decode("t", 16), true); eq(t.decode("f", 16), false)
eq(t.decode("Infinity", 701), math.huge); eq(t.decode("-Infinity", 700), -math.huge)
local nan = t.decode("NaN", 701); eq(nan ~= nan, true)
eq(t.encode(t.NULL).value, nil)
eq(t.encode(t.typed("int8", t.NULL)).oid, 20)
eq(t.encode(t.jsonb(t.NULL)).value, "null")
eq(t.decode("null", 3802), t.NULL)
eq(t.decode(t.encode(t.jsonb({quote='a"b\\c', n=t.NULL})).value, 3802).quote, 'a"b\\c')
local bytes = "\0\1\127\128\255\\'"
eq(t.encode(t.bytea(bytes)).value, bytes); eq(t.encode(t.bytea(bytes)).format, 1)
eq(t.decode("\\x00017f80ff5c27", 17), bytes)
eq(t.decode("\\000\\001\\177\\200\\377\\\\'", 17), bytes)
for _, value in ipairs({"NULL", "", "中文", '{x,y}', '"\\', "a\nb"}) do
    local p = t.encode(t.array("text", {value,t.NULL,"end"}))
    local a = t.decode(p.value, p.oid)
    eq(a[1], value); eq(a[2], t.NULL); eq(a[3], "end")
end
local a = t.decode(t.encode(t.array("bytea", {bytes,"",t.NULL})).value, 1001)
eq(a[1], bytes); eq(a[2], ""); eq(a[3], t.NULL)
local bools = t.decode("{t,f,NULL}", 1000); eq(bools[1], true); eq(bools[2], false); eq(bools[3], t.NULL)
eq(t.decode("{{1,2},{3,4}}", 1007)[2][1], 3)
eq(t.decode("[0:1]={1,2}", 1007), "[0:1]={1,2}")
eq(#t.decode("{}", 1009), 0)
eq(t.decode("(1,2)", 99999), "(1,2)")
throws(function() t.encode("a\0b") end)
throws(function() t.encode("\255") end)
throws(function() t.encode_params({[1]=1,[3]=2}) end)
throws(function() t.encode_params({x=1}) end)
throws(function() t.decode("9223372036854775808", 20) end)
throws(function() t.decode("\\x123", 17) end)
throws(function() t.decode('{"unterminated}', 1009) end)
local result = t.result({rows={{"1",t.NULL}},columns={{name="v",oid=20},{name="n",oid=25}},command="SELECT 1",affected="1"})
eq(result.rows[1].v, 1); eq(result.rows[1].n, t.NULL); eq(result.rows_affected, 1)
-- Native conversion must not create intermediate string/numeric row tables.
for _, n in ipairs({1.25, -0.125, 1e100, 1e-100, math.pi}) do
    local p=t.encode(n); eq(p.oid,701); eq(t.decode(p.value,701),n)
end
local every_byte, hex = {}, {}
for i=0,255 do every_byte[#every_byte+1]=string.char(i); hex[#hex+1]=("%02x"):format(i) end
every_byte=table.concat(every_byte)
eq(t.decode("\\x"..table.concat(hex),17),every_byte)
eq(t.decode("\\x"..table.concat(hex):upper(),17),every_byte)
eq(t.decode(t.encode(t.array("bytea",{every_byte})).value,1001)[1],every_byte)
eq(t.decode(t.encode(t.array("jsonb",{{a=1},t.NULL,{n=t.NULL}})).value,3807)[3].n,t.NULL)
eq(t.encode(false).value,"f"); eq(t.encode(t.typed("int8",nil)).value,nil)
eq(t.encode(t.jsonb("text")).value,'"text"')
for _, invalid in ipairs({"\192\128","\237\160\128","\244\144\128\128","\240\128","\128"}) do
    throws(function() t.encode(invalid) end)
end
for _, invalid in ipairs({"", "\0", "\255"}) do throws(function() t.sql(invalid) end) end
throws(function() t.encode(t.array("text",{[1]="x",[3]="y"})) end)
throws(function() t.encode(t.typed("unknown",1)) end)
throws(function() t.encode(t.typed(-1,1)) end)
throws(function() t.decode("not-a-number",701) end)
throws(function() t.decode("truthy",16) end)
throws(function() t.decode("\\400",17) end)
throws(function() t.decode("{,}",1009) end)
throws(function() t.decode(string.rep("{",65).."1"..string.rep("}",65),1007) end)
throws(function() t.statements({{sql="SELECT 1"},{sql="SELECT 2",params={"\255"}}}) end)
throws(function() t.statements({{sql="/* unterminated"}}) end)
for _, keyword in ipairs({"BEGIN","START","COMMIT","END","ROLLBACK","ABORT","SAVEPOINT","RELEASE","PREPARE"}) do
    throws(function() t.statements({{sql=" -- leading\n /* a /* b */ c */ "..keyword}}) end)
end
local raw = {rows={{"1","2",t.NULL,"\\x00ff",'{"ok":true}'}},
    columns={{name="x",oid=20},{name="x",oid=23},{name="n",oid=25},{name="b",oid=17},{name="j",oid=3802}},
    command="SELECT 1",affected="1"}
local named=t.result(raw,"name"); eq(named.rows[1].x,2); eq(named.rows[1].n,t.NULL)
eq(named.rows[1].b,"\0\255"); eq(named.rows[1].j.ok,true); eq(#named.columns,5)
local positional=t.result(raw,"array"); eq(positional.rows[1][1],1); eq(positional.rows[1][2],2)
eq(positional.rows[1][3],t.NULL); eq(#positional.rows[1],5)
-- All former Lua codec functions are gone from the production parameter wrapper.
eq(rawget(wrappers,"encode"),nil); eq(rawget(wrappers,"decode"),nil); eq(rawget(wrappers,"result"),nil)

-- Direct connection wrapper: native completions are deterministic, never networked.
local now, hold, history, native, session, waits = 0, false, {}, nil, 0, 0
local function new_native(capacity)
    local n = {connected_flag=false, capacity=capacity}
    function n:connected() return self.connected_flag end
    function n:close() self.connected_flag = false end
    function n:connect(options, timeout)
        self.options = options; self.connected_flag = true
        self.response = {results={},transaction_status=0}; session = session + 1; return session
    end
    function n:submit(kind, sql, params, timeout, max_rows, max_bytes, name)
        t.sql(sql)
        if kind == "prepare" or kind == "prepared" then
            assert(type(name) == "string" and #name > 0 and name:sub(1,10) ~= "__moon_pq_")
        end
        local encoded = {}
        if kind == "prepare" then for i, v in ipairs(params or {}) do encoded[i] = {oid=t.type_oid(v)} end
        else encoded = t.encode_params(params) end
        history[#history+1] = {sql=sql,params=encoded,timeout=timeout,kind=kind,name=name}
        if sql == "disconnect" then self.connected_flag=false; self.response={code="SOCKET",message="closed"}
        else
            self.response = {transaction_status=0,result_bytes=1,results={{rows={{v=1}},columns={{name="v",oid=20}},command="SELECT 1",rows_affected=1}}} end
        session = session + 1; return session
    end
    function n:transaction(statements, timeout, max_rows, max_bytes)
        local encoded = t.statements(statements)
        history[#history+1] = {kind="transaction",statements=encoded,timeout=timeout,max_rows=max_rows,max_bytes=max_bytes}
        self.response = {results={}}
        for i in ipairs(encoded) do self.response.results[i] = {rows={{v=i}}} end
        session = session + 1; return session
    end
    function n:take(mode) self.row_mode=mode; return self.response end
    native = n; return n
end
local moon = {clock=function() return now end, wait=function() waits=waits+1; if hold then return coroutine.yield() else return 1 end end}
package.loaded.moon = moon
package.preload["libpq.core"] = function() return {load=function() return 180006 end,new=new_native} end
local pg = require("moon.db.libpq")
local db = pg.connect({dbname="mock",user="mock"})
eq(db.code, nil); eq(native.options.sslmode, "require"); eq(native.options.client_encoding,"UTF8")
eq(native.capacity,100)
eq(db:query("select $1", {math.maxinteger}).rows[1].v, 1)
eq(history[#history].params[1].value, tostring(math.maxinteger))
local begin = #history
local before_wait = waits
local tx = db:transaction({{sql="one"},{sql="two",params={pg.bytea(bytes)}}})
eq(#tx.results, 2); eq(#history,begin+1); eq(history[#history].kind,"transaction")
eq(waits,before_wait+1); eq(history[#history].statements[2].params[1].value,bytes)
eq(db:query("ok").code, nil)
begin = #history
eq(db:transaction({{sql="ok"},{sql="/* nested /* x */ end */ -- skip\n COMMIT"}}).code,"ERROR")
eq(#history,begin) -- all statements validated before BEGIN
db = pg.connect({dbname="mock",user="mock"})
eq(db:prepare("p","select $1",{"bigint"}).code,nil)
eq(history[#history].params[1].oid,20)
eq(db:query_prepared("p",{2}).code,nil); eq(history[#history].name,"p")
hold = true
local co = coroutine.create(function() eq(db:query("ok").code,nil) end)
eq(coroutine.resume(co),true)
eq(db:query("conflict").code,"BUSY")
hold = false; eq(coroutine.resume(co,1),true); eq(coroutine.status(co),"dead")
eq(db:transaction({{sql="one"}}, {timeout=10,max_rows=9,max_result_bytes=12,row_mode="array"}).code,nil)
eq(history[#history].timeout,10); eq(history[#history].max_rows,9); eq(history[#history].max_bytes,12)
eq(native.row_mode,"array")
db = pg.connect({dbname="mock",user="mock"})
begin = #history
eq(db:query("disconnect").code,"SOCKET"); eq(#history,begin+1)
db = pg.connect({dbname="mock",user="mock",statement_cache_capacity=0})
eq(native.capacity,0)
db = pg.connect({dbname="mock",user="mock"})
eq(db:query_prepared(nil).code,"ERROR")
db = pg.connect({dbname="mock",user="mock"})
hold = true
co = coroutine.create(function() eq(db:query("ok").code,"CANCELLED") end)
eq(coroutine.resume(co),true)
hold = false
eq(coroutine.resume(co,false),true); eq(db:connected(),false)

-- Driver scheduling: controllable coroutines, fixed lane routing, no libpq library.
local dispatch, shutdown, quit, responses, pending, calls = nil,nil,false,{},{},{}
moon.dispatch = function(_, fn) dispatch=fn end
moon.shutdown = function(fn) shutdown=fn end
moon.quit = function() quit=true end
moon.error = function() end
moon.sleep = function() coroutine.yield("sleep") end
moon.response = function(_,sender,sid,value) responses[sid]=value end
moon.async = function(fn)
    local thread = coroutine.create(fn)
    pending[#pending+1]=thread
    assert(coroutine.resume(thread))
    return thread
end
local opened = 0
package.loaded["moon.db.libpq"] = {connect=function()
    opened=opened+1
    local id = opened
    return { connected=function(self) return not self.closed end, close=function(self) self.closed=true end,
        query=function(self,sql)
            calls[#calls+1] = {id=id,sql=sql}
            coroutine.yield("query")
            if sql == "socket" then self.closed=true; return {code="SOCKET",message="mock"} end
            return {rows={{value=sql}}}
        end }
end}
assert(loadfile("service/libpq_sqldriver.lua"))({opts={},poolsize=2,max_queue=1})
dispatch(10,1,"query",1,"a")
dispatch(10,2,"query",1,"b")
dispatch(10,3,"query",1,"overflow")
eq(responses[3].code,"QUEUE_FULL"); eq(#calls,1)
dispatch(10,4,"query",2,"parallel")
eq(#calls,2); eq(opened,2); eq(calls[1].id ~= calls[2].id,true)
assert(coroutine.resume(pending[1])); eq(#calls,3); eq(calls[3].sql,"b"); eq(calls[3].id,calls[1].id)
dispatch(10,5,"save_then_quit")
eq(quit,false)
dispatch(10,6,"query",1,"late"); eq(responses[6].code,"CLOSING")
assert(coroutine.resume(pending[1])); assert(coroutine.resume(pending[2])); assert(coroutine.resume(pending[3]))
eq(quit,true); eq(responses[5].closed,true)
eq(responses[1].rows[1].value,"a"); eq(responses[2].rows[1].value,"b")

-- Reconnect for a later request, but never replay an uncertain write.
pending,calls,responses,quit = {},{},{},false
assert(loadfile("service/libpq_sqldriver.lua"))({opts={},poolsize=1})
dispatch(10,7,"query",1,"socket")
assert(coroutine.resume(pending[1])); eq(responses[7].code,"SOCKET"); eq(#calls,1)
dispatch(10,8,"query",1,"next")
eq(#calls,2); eq(calls[1].id ~= calls[2].id,true)
assert(coroutine.resume(pending[2]))

-- Connection backoff rejects before SQL and can recover on the next attempt.
pending,calls,responses = {},{},{}
local retries = 0
package.loaded["moon.db.libpq"] = {connect=function()
    retries=retries+1; return {code="SOCKET",message="no server",connect_failed=true}
end}
assert(loadfile("service/libpq_sqldriver.lua"))({opts={},poolsize=1,reconnect_delay=1000})
dispatch(10,9,"query",1,"never_sent")
dispatch(10,10,"query",1,"never_sent")
eq(responses[9].code,"SOCKET"); eq(responses[10].code,"CONNECT_BACKOFF"); eq(retries,1)
now = now + 2
dispatch(10,11,"query",1,"never_sent")
eq(retries,2); eq(responses[11].code,"SOCKET")

-- Parse the integration suite and all new entry points without executing them.
for _, file in ipairs({"lualib/moon/db/libpq.lua", "lualib/moon/db/libpq/types.lua",
    "lualib/libpq_sqldriver/client.lua", "service/libpq_sqldriver.lua", "example/test_libpq_pg.lua"}) do
    assert(loadfile(file))
end
print(("libpq Lua checks passed (%d assertions; mock scheduler, no database)"):format(checks))
