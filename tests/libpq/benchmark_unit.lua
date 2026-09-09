-- Offline benchmark checks: no Moon runtime, native database module, network, or report writes.
local checks=0
local function eq(a,b,label)
    checks=checks+1
    assert(a==b,(label or "mismatch")..": "..tostring(a).." ~= "..tostring(b))
end
local function near(a,b) checks=checks+1; assert(math.abs(a-b)<1e-8,"float mismatch") end
local function fails(fn,pattern)
    local ok,err=pcall(fn)
    eq(ok,false,"expected failure")
    if pattern then checks=checks+1; assert(tostring(err):find(pattern,1,true),tostring(err)) end
end
for _,path in ipairs({"example/benchmark_pg.lua","example/pg_bench/config.lua","example/pg_bench/common.lua",
    "example/pg_bench/adapters.lua","example/pg_bench/cases.lua","example/pg_bench/report.lua"}) do
    checks=checks+1; assert(loadfile(path)) -- compile, do not execute the Moon bootstrap
end
local common=dofile("example/pg_bench/common.lua")
local adapters=dofile("example/pg_bench/adapters.lua")
local cases=dofile("example/pg_bench/cases.lua")
local function raw_config(overrides)
    -- Independent fixture: editing local credentials/workload must not change unit-test expectations.
    local config={allow_write=true,host="127.0.0.1",port=5432,database="bench",user="tester",password="",
        sslmode="disable",sslrootcert="",sslcert="",sslkey="",library="",
        threads=4,driver_thread=2,enable_stdout=true,loglevel="INFO",mode="both",implementation="both",
        poolsize=4,concurrency=0,cache=100,rounds=3,iterations=1000,bulk_iterations=100,warmup=100,
        rows=256,data_rows=4096,bytes=16384,tx_size=5,cases={},timeout_ms=30000,deadline_ms=900000,output="",
        html_report=true,html_output="",min_duration_ms=0,warmup_duration_ms=0,
        validate_every=1,driver_concurrencies={},run_label="offline fixture"}
    for k,v in pairs(overrides or {}) do config[k]=v end
    return config
end
local function config(overrides,root) return common.config(raw_config(overrides),root) end
local function bootstrap_config(overrides,source,expected_dir)
    local raw=raw_config(overrides)
    local env=setmetatable({
        _G={__init__=true},
        debug={getinfo=function() return {source=source or "@example/benchmark_pg.lua"} end},
        os={getenv=function() error("benchmark must not read environment variables") end},
        dofile=function(path)
            local dir=expected_dir or "example"
            if path==dir.."/pg_bench/common.lua" then return common end
            eq(path,dir.."/pg_bench/config.lua","configuration must be script-relative")
            return raw
        end,
    },{__index=_G})
    return assert(loadfile("example/benchmark_pg.lua","t",env))() -- configuration branch only
end
eq(bootstrap_config({threads=4}).thread,4)
eq(bootstrap_config({threads=8,driver_thread=3,enable_stdout=false,loglevel="WARN"}).enable_stdout,false)
eq(bootstrap_config(nil,"@benchmark_pg.lua",".").thread,4) -- after Moon changes cwd
eq(bootstrap_config(nil,"@E:\\repo\\example\\benchmark_pg.lua","E:/repo/example").thread,4)
eq(bootstrap_config(nil,"@/repo/example/benchmark_pg.lua","/repo/example").thread,4)
fails(function() bootstrap_config({threads=1}) end,"must be >= 2")
fails(function() bootstrap_config({threads="typo"}) end,"integer")
fails(function() common.config(raw_config({allow_write=false})) end,"allow_write=true")
fails(function() common.config() end,"must return a table")
-- Load the actual on-disk configuration and run only the real bootstrap configuration branch.
-- No Lua/Moon service initialization, native database loading, or network occurs here.
local actual_config=dofile("example/pg_bench/config.lua")
local init_env=setmetatable({_G={__init__=true}},{__index=_G})
eq(assert(loadfile("example/benchmark_pg.lua","t",init_env))().thread,actual_config.threads)

local cfg=config()
eq(cfg.poolsize,4); eq(cfg.concurrency,4); eq(cfg.cache,100)
eq(cfg.modes[1],"direct"); eq(cfg.modes[2],"driver"); eq(cfg.implementations[2],"sqlx")
eq(cfg.url:find("statement-cache-capacity=100",1,true)~=nil,true)
eq(cfg.options:find("statement_timeout=30000",1,true)~=nil,true)
local encoded=config({user="a/b",password="a@b%/ #",database="db x",host="::1",
    cache=0,sslrootcert="E:/cert a.pem"})
eq(encoded.url:find("a%2Fb:a%40b%25%2F%20%23@[::1]:5432/db%20x?",1,true)~=nil,true)
eq(encoded.url:find("sslrootcert=E%3A%2Fcert%20a.pem",1,true)~=nil,true)
eq(encoded.cache,0)
eq(common.redact("password="..encoded.password,encoded),"password=<redacted>")
eq(common.redact("failed "..encoded.url,encoded),"failed <redacted PostgreSQL URL>")
eq(common.redact(common.url_escape(encoded.password),encoded),"<redacted>")
eq(config({mode="driver",concurrency=32}).concurrency,32)
eq(config({implementation="sqlx"}).implementations[1],"sqlx")
eq(config({poolsize=7}).concurrency,7)
eq(config({concurrency=2}).concurrency,2)
eq(cfg.cases,nil); eq(cfg.output,nil); eq(cfg.library,nil)
eq(cfg.html_report,true); eq(cfg.html_output,nil)
eq(config({html_report=false}).html_report,false)
eq(config({html_output="target/charts.html"},"E:/repo").html_output,"E:/repo/target/charts.html")
local selected=raw_config({cases={"tiny","bytea"}})
local parsed=common.config(selected)
eq(parsed.cases[2],"bytea"); parsed.cases[1]="point"; eq(selected.cases[1],"tiny")
local paths=config({output="target/report.json",sslrootcert="certs/ca.pem",library="clib\\libpq\\libpq.dll"},"E:/repo")
eq(paths.output,"E:/repo/target/report.json"); eq(paths.sslrootcert,"E:/repo/certs/ca.pem")
eq(paths.library,"E:/repo/clib/libpq/libpq.dll")
eq(paths.url:find("sslrootcert=E%3A%2Frepo%2Fcerts%2Fca.pem",1,true)~=nil,true)
eq(common.path("/repo","/tmp/report.json"),"/tmp/report.json")
eq(common.path("E:/repo","\\\\server\\share\\report.json"),"//server/share/report.json")
fails(function() common.path("E:/repo","E:relative") end,"drive-relative")
fails(function() common.path("E:/repo","E:") end,"drive-relative")
for _,bad in ipairs({
    {allow_write=false},{allow_write="true"},{database=false},{user=""},{password=false},
    {host=""},{host="[::1]"},{host="/tmp"},{host="db,db2"},{sslmode="prefer"},{port=65536},
    {poolsize=0},{poolsize=1.5},{poolsize="4"},{poolsize="typo"},
    {concurrency=5},{concurrency=-1},{cache=-1},{mode="typo"},{implementation="mysql"},
    {rows=4097},{timeout_ms=2147483648},{driver_thread=1},{driver_thread=5},{threads=1},{threads=256},
    {enable_stdout="false"},{loglevel="VERBOSE"},{output=false},{sslrootcert=123},
    {cases="tiny,bytea"},{cases={"tiny","tiny"}},{cases={[2]="tiny"}},{cases={tiny=true}},
    {cases={false}},{typo=1},{html_report="true"},{html_output=false},
    {min_duration_ms=-1},{min_duration_ms="10"},{warmup_duration_ms=-1},{validate_every=0},
    {run_label=false},{min_duration_ms=900000},{driver_concurrencies="32"},
    {driver_concurrencies={4}},{driver_concurrencies={32,32}},{driver_concurrencies={0}},
    {driver_concurrencies={[2]=32}},{driver_concurrencies={1.5}},
}) do fails(function() config(bad) end) end
-- Even a hostile/misconfigured environment cannot override this configuration layer.
local original_getenv=os.getenv
os.getenv=function() error("benchmark must not read environment variables") end
eq(config({port=6432,cache=0}).port,6432)
os.getenv=original_getenv

eq(common.median({4,1,3,2}),2.5); eq(common.median({3,1,2}),2); eq(common.median({}),0)
local metrics=common.summary({4,1,3,2},2,5,1)
eq(metrics.success,4); eq(metrics.attempted,5); eq(metrics.errors,1); eq(metrics.requests_per_s,2)
eq(metrics.mean_ms,2.5); eq(metrics.p50_ms,2); eq(metrics.p95_ms,4); eq(metrics.p99_ms,4); eq(metrics.max_ms,4)
eq(common.summary({},0,1,1).requests_per_s,0)
eq(common.quantile({},.99),0)
fails(function() common.equal(1.0,1) end,"integer precision")
fails(function() common.ok({kind="TIMEOUT",message="test"}) end,"TIMEOUT")
fails(function() common.ok({code="DB",sqlstate="23505",message="test"}) end,"23505")
fails(function() common.ok(false) end)

-- Minimal deferred-wakeup scheduler matching the real moon.async/wait/wakeup start barrier.
local function scheduler(body)
    local moon={}
    local now,serial,events=0,0,{}
    local function enqueue(co,delay)
        serial=serial+1; events[#events+1]={co=co,due=now+delay,serial=serial}
    end
    local function resume(co)
        local ok,err=coroutine.resume(co); assert(ok,err)
    end
    function moon.clock() return now end
    function moon.async(fn) local co=coroutine.create(fn); resume(co); return co end
    function moon.wait() return coroutine.yield() end
    function moon.wakeup(co) enqueue(co,0) end
    function moon.sleep(ms) enqueue(coroutine.running(),ms/1000); coroutine.yield() end
    function moon.tick(ms) now=now+ms/1000 end -- CPU/validation time without yielding
    local main=moon.async(function() body(moon) end)
    local steps=0
    while coroutine.status(main)~="dead" do
        assert(#events>0,"scheduler deadlock")
        table.sort(events,function(a,b) return a.due==b.due and a.serial<b.serial or a.due<b.due end)
        local event=table.remove(events,1); now=math.max(now,event.due); resume(event.co)
        steps=steps+1; assert(steps<10000,"scheduler did not terminate")
    end
    eq(#events,0,"in-flight work was not drained")
end
scheduler(function(moon)
    local seen,active,peak={},0,0
    local r=common.run(moon,12,3,function(i,w)
        eq(seen[i],nil); seen[i]=w
        active=active+1; peak=math.max(peak,active)
        moon.sleep(1); active=active-1
        return i
    end,function(value,i) eq(value,i) end)
    eq(#seen,12); eq(peak,3); eq(active,0)
    eq(r.attempted,12); eq(r.success,12); eq(r.errors,0); eq(r.error,nil)
    near(r.elapsed_s,.004); near(r.requests_per_s,3000); near(r.p99_ms,1)
end)
scheduler(function(moon)
    local r=common.run(moon,10,3,function(i)
        moon.sleep(1); if i==1 then error("deliberate operation error") end; return i
    end,function(value,i) eq(value,i) end)
    eq(r.attempted,3); eq(r.success,2); eq(r.errors,1)
    eq(r.error:find("deliberate operation error",1,true)~=nil,true)
end)
scheduler(function(moon)
    local r=common.run(moon,10,3,function(i) moon.sleep(1); return i end,function(_,i)
        if i==1 then error("deliberate validation error") end
    end)
    eq(r.attempted,3); eq(r.success,2); eq(r.errors,1)
    eq(r.error:find("deliberate validation error",1,true)~=nil,true)
end)
scheduler(function(moon)
    local r=common.run(moon,1,4,function() moon.sleep(1); return true end,function(v) eq(v,true) end)
    eq(r.success,1); eq(r.attempted,1); near(r.p50_ms,1)
end)
scheduler(function(moon)
    local r=common.run(moon,3,1,function() moon.sleep(1) end,function() moon.tick(10) end)
    near(r.p99_ms,1); near(r.elapsed_s,.033) -- all validation, including the final response, counts
    near(r.validation_s,.030); eq(r.full_checks,3)
end)

-- Time AND count limits; drain in-flight responses after the issue deadline.
scheduler(function(moon)
    local r=common.run(moon,2,2,function(i) moon.sleep(2); return i end,function(v,i) eq(v,i) end,
        {min_duration_ms=5})
    eq(r.success,6); near(r.elapsed_s,.006); eq(r.peak_inflight,2)
    eq(r.worker_success[1]+r.worker_success[2],6); eq(r.target_requests,2)
end)
scheduler(function(moon)
    local r=common.run(moon,10,2,function() moon.sleep(2) end,function() end,{min_duration_ms=1})
    eq(r.success,10); near(r.elapsed_s,.010) -- duration never cuts off the minimum count
end)
scheduler(function(moon)
    local full,fast={},0
    local r=common.run(moon,12,2,function(i) moon.sleep(1); return i end,function(_,_,w)
        full[w]=(full[w] or 0)+1
    end,{validate_every=3,check_fast=function() fast=fast+1 end})
    eq(full[1],2); eq(full[2],2); eq(fast,8); eq(r.full_checks,4)
end)
scheduler(function(moon)
    local r=common.run(moon,10,2,function(i) moon.sleep(i==1 and 1 or 5); if i==1 then error("fail fast") end end,
        function() end,{min_duration_ms=100})
    eq(r.attempted,2); eq(r.success,1); eq(r.errors,1); near(r.elapsed_s,.005)
end)
scheduler(function(moon)
    local r=common.run(moon,4,1,function() moon.sleep(1) end,function() end,
        {validate_every=100,check_fast=function() error("structural check failed") end})
    eq(r.errors,1); eq(r.attempted,2); eq(r.success,1)
end)

local hist=common.histogram()
eq(hist:finish().success,0)
local exact={}
for i=0,10000 do local ms=i/100; hist:add(ms); exact[#exact+1]=ms end
local h=hist:finish()
eq(h.success,10001); near(h.mean_ms,50); near(h.max_ms,100)
for _,q in ipairs({{"p50_ms",.5},{"p95_ms",.95},{"p99_ms",.99}}) do
    local expected=common.quantile(exact,q[2])
    eq(h[q[1]]>=expected-1e-10 and h[q[1]]<=expected*1.01+1e-6,true)
end
eq(h.histogram_buckets<1000,true)
hist:add(0.0000001); hist:add(2000000000)
eq(hist:finish().max_ms,2000000000)
fails(function() hist:add(-1) end); fails(function() hist:add(math.huge) end)
fails(function() hist:add(0/0) end)

local plan_cfg=config({driver_concurrencies={32,64},min_duration_ms=2000,warmup_duration_ms=500})
local profiles,minimum=cases.plan(plan_cfg,common.profiles(plan_cfg))
eq(#profiles,4); eq(profiles[3].name,"driver_c32"); eq(profiles[4].concurrency,64)
eq(#profiles[1].cases,10); eq(#profiles[2].cases,11); eq(minimum,43*2*3*2500)
local only_direct=config({mode="direct",driver_concurrencies={32}})
eq(#common.profiles(only_direct),1)
for _,bad in ipairs({{cases={"typo"}},{cases={"hot_lane"}},{min_duration_ms=20000}}) do
    local c=config(bad); fails(function() cases.plan(c,common.profiles(c)) end)
end
local comp={libpq={},sqlx={}}
for round=1,4 do
    for _,name in ipairs({"libpq","sqlx"}) do
        comp[name][round]={round=round,success=100,elapsed_s=name=="libpq" and 1 or 2,
            requests_per_s=name=="libpq" and 100 or 50,p95_ms=1,p99_ms=2}
    end
end
local compared=common.compare(comp)
eq(compared.libpq_over_sqlx,2); eq(compared.paired_ratio_median,2)
eq(compared.libpq_faster_rounds,4); eq(compared.libpq.qps_cv_pct,0)
eq(compared.libpq.pooled_requests_per_s,100); eq(compared.round_ranges_overlap,false)
comp.sqlx[4].round=3; fails(function() common.compare(comp) end,"duplicate")

-- Exercise all adapter branches against explicit fake public API shapes. No native module is loaded.
local module_names={"moon.db.libpq","ext.sqlx","libpq_sqldriver.client","lrust_sqldriver.client","json"}
local saved={}; for _,name in ipairs(module_names) do saved[name]=package.loaded[name] end
for _,implementation in ipairs({"libpq","sqlx"}) do
    for _,mode in ipairs({"direct","driver"}) do
        local pg=implementation=="libpq"
        local captured={created=0,closed=0,scans=0,stopped=0}
        local function query(sql,params,lane)
            captured.last={sql=sql,params=params,lane=lane}
            local rows={{value=123}}
            return pg and {rows=rows,rows_affected=3} or (mode=="driver" and {data=rows} or rows)
        end
        local function write(sql,params,lane)
            captured.last={sql=sql,params=params,lane=lane}; return {rows_affected=3}
        end
        local function transaction(statements,lane)
            captured.statements=statements; captured.lane=lane
            return pg and {results={{rows_affected=3},{rows_affected=3}}} or {rows_affected=6}
        end
        local function batch(sql,lane)
            captured.last={sql=sql,lane=lane}
            return pg and {results={{rows_affected=3},{rows_affected=3}}} or {rows_affected=6}
        end
        local function connection(opts)
            captured.created=captured.created+1; captured.options=opts
            local lane=captured.created
            return {
                query=function(_,sql,...)
                    local params=pg and (...) or {...}; return query(sql,params,lane)
                end,
                execute=function(_,sql,params) eq(pg,true); return write(sql,params,lane) end,
                execute_wait=function(_,sql,...) eq(pg,false); return write(sql,{...},lane) end,
                transaction=function(_,s) return transaction(s,lane) end,
                batch=function(_,sql) return batch(sql,lane) end,
                close=function() captured.closed=captured.closed+1; if not pg then return true end end,
            }
        end
        local module={
            connect=function(opts) eq(pg,true); return connection(opts) end,
            try_connect=function(url,name,opts)
                eq(pg,false); captured.url=url; captured.name=name; return connection(opts)
            end,
        }
        local client={
            query=function(id,sql,params,key) eq(id,257); return query(sql,params,key+1) end,
            query_params_on=function(id,key,sql,...) eq(id,257); return query(sql,{...},key+1) end,
            execute_params_wait_on=function(id,key,sql,...) eq(id,257); return write(sql,{...},key+1) end,
            execute=function() error("fire-and-forget must never be measured") end,
            transaction=function(id,s,key) eq(id,257); return transaction(s,key+1) end,
            transaction_on=function(id,key,s) eq(id,257); return transaction(s,key+1) end,
            batch=function(id,sql,key) eq(id,257); return batch(sql,key+1) end,
            batch_on=function(id,key,sql) eq(id,257); return batch(sql,key+1) end,
            save_then_quit=function(id) eq(id,257); captured.stopped=captured.stopped+1; return {closed=true} end,
        }
        for _,t in ipairs({client,module}) do
            function t.bytea(v) return {bytes=v} end
            function t.bytes(v) return {bytes=v} end
            function t.jsonb(v) return {json=v} end
            function t.json(v) return {json=v} end
            function t.array(kind,v) return {kind=kind,values=v} end
        end
        package.loaded[pg and "moon.db.libpq" or "ext.sqlx"]=module
        package.loaded[pg and "libpq_sqldriver.client" or "lrust_sqldriver.client"]=client
        package.loaded.json={decode=function(raw) return raw=="alive" and {{serviceid="101"}} or {} end}
        local moon={
            clock=function() return 0 end,
            new_service=function(conf) captured.conf=conf; return 257 end,
            scan_services=function(worker)
                eq(worker,3); captured.scans=captured.scans+1
                return captured.scans==1 and "alive" or "[]"
            end,
            sleep=function(ms) eq(ms,20) end,
        }
        local c=config({poolsize=2,driver_thread=3})
        local api=adapters.open(moon,common,c,implementation,mode,"E:/repo","tag")
        eq(api:query("select",{42,false},2)[1].value,123)
        eq(captured.last.lane,2); eq(captured.last.params[1],42); eq(captured.last.params[2],false)
        eq(api:write("update",{9},2),3); eq(captured.last.lane,2)
        local statements={{sql="a",params={1,false}},{sql="b",params={2}}}
        eq(api:transaction(statements,2),6); eq(captured.lane,2)
        eq(pg and captured.statements[1].sql or captured.statements[1][1],"a")
        eq(pg and captured.statements[1].params[1] or captured.statements[1][2],1)
        if pg then eq(captured.statements[1].params[2],false) else eq(captured.statements[1][3],false) end
        eq(api:batch("a;b",2),6); eq(captured.last.lane,2)
        eq(api:bytes("\0\255").bytes,"\0\255"); eq(api:json(123).json,123)
        eq(api:array("int8",{1}).kind,"int8")
        if mode=="driver" then
            eq(captured.conf.threadid,3); eq(captured.conf.poolsize,2); eq(captured.conf.max_queue,0)
            if not pg then eq(captured.conf.eager_connect,false); eq(captured.conf.url,c.url) end
        else
            eq(captured.created,2)
            if pg then eq(captured.options.statement_cache_capacity,100); eq(captured.options.max_result_bytes,0)
            else eq(captured.url,c.url); eq(captured.options.request_timeout,c.timeout) end
        end
        api:close(); api:close()
        eq(captured.closed,mode=="direct" and 2 or 0)
        eq(captured.stopped,mode=="driver" and 1 or 0)
        eq(captured.scans,mode=="driver" and 2 or 0)
    end
end
for _,name in ipairs(module_names) do package.loaded[name]=saved[name] end

-- Check fixture construction and representative validators independently of a database.
local null={} -- a stable sentinel is sufficient for these pure tests
local workloads=cases.build(config({rows=2,bytes=9}), '"fixture".', common, null)
eq(#workloads,11)
local by_name={}; for _,case in ipairs(workloads) do by_name[case.name]=case end
eq(by_name.hot_lane.driver_only,true); eq(by_name.transaction.sql_per_request,5)
eq(by_name.mixed_rows.count,cfg.bulk_iterations)
by_name.tiny.check({{value=123}},123)
fails(function() by_name.tiny.check({{value=123.0}},123) end,"integer precision")
by_name.json_array.check({{document={id=123,name="中文 benchmark",enabled=true,missing=null,nested={1,2,3}},
    ids={math.mininteger,0,math.maxinteger}}})
local payload
by_name.bytea.request({bytes=function(_,v) return v end,query=function(_,_,params) payload=params[1] end},1,1)
eq(#payload,9); eq(payload,"\0\1\127\255abcd\0"); by_name.bytea.check({{payload=payload}})
by_name.bytea_send.check({{size=9}}); by_name.bytea_read.check({{payload=payload}})
by_name.bytea_read.check_fast({{payload=payload}})
fails(function() by_name.bytea_read.check_fast({{payload="short"}}) end,"length mismatch")
fails(function() by_name.bytea_read.check({{payload=string.rep("x",9)}}) end,"corrupted")
fails(function() by_name.mixed_rows.check_fast({{}}) end,"row count")
local fixture_sql={}
cases.setup({bytes=function(_,v) return v end,write=function(_,sql) fixture_sql[#fixture_sql+1]=sql end},
    config({bytes=9}), '"fixture".')
eq(#fixture_sql,9); eq(fixture_sql[6]:find("binary_sample VALUES",1,true)~=nil,true)
local write_rows={{id=1,n=6},{id=2,n=9}}
local write_api={query=function(_,sql) return sql:find("SUM",1,true) and {{n=15}} or write_rows end}
cases.check_writes(write_api,'"fixture".',15,common,{2,3},3)
write_rows[1].n=9; write_rows[2].n=6 -- same total but wrong lane/worker must fail
fails(function() cases.check_writes(write_api,'"fixture".',15,common,{2,3},3) end,"per-worker")
fails(function() by_name.write.check(0) end,"write affected")
fails(function() by_name.transaction.check(4) end,"transaction affected")
fails(function() by_name.batch.check(4) end,"batch affected")
local reset_sql
cases.reset({write=function(_,sql) reset_sql=sql; return cfg.concurrency end},cfg,'"fixture".')
eq(reset_sql,'UPDATE "fixture".counters SET n=0')
fails(function() cases.reset({write=function() return 0 end},cfg,'"fixture".') end,"counter reset")
print(("benchmark offline checks passed (%d assertions; no Moon/database/network)"):format(checks))
