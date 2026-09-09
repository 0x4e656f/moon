-- Executes the real bootstrap with injected Lua-only services/SQL/report sinks.
-- Never loads Moon, native database modules, local credentials, or a network transport.
local common=dofile("example/pg_bench/common.lua")
local workloads=dofile("example/pg_bench/cases.lua")
local reports=dofile("example/pg_bench/report.lua")
local checks=0
local function eq(a,b) checks=checks+1; assert(a==b,tostring(a).." ~= "..tostring(b)) end
local function test(options)
    options=options or {}
    local cfg={allow_write=true,host="example.invalid",port=5432,database="fixture",user="fixture",password="fixture-secret",
        sslmode="disable",sslrootcert="",sslcert="",sslkey="",library="",threads=4,driver_thread=2,
        enable_stdout=false,loglevel="INFO",mode="both",implementation="both",poolsize=2,concurrency=2,
        driver_concurrencies={4},cache=100,rounds=2,iterations=2,bulk_iterations=2,warmup=2,
        min_duration_ms=5,warmup_duration_ms=2,validate_every=100,run_label="synthetic flow",
        rows=2,data_rows=4,bytes=8,tx_size=2,cases={"tiny","write","hot_lane"},timeout_ms=1000,deadline_ms=2000,
        output="target/not-written.json",html_report=true,html_output=""}
    if options.bad_case then cfg.cases={"unknown"} end
    local moon,report={id=123}
    local now,serial,pid=0,0,100
    local events,apis,schemas,counters={},{},{},{}
    local created,dropped,checkpoints,fifo=0,0,0,0
    local exit_code,main,deadline
    local function enqueue(co,ms)
        serial=serial+1; events[#events+1]={co=co,time=now+ms/1000,serial=serial}
    end
    local function resume(co) local ok,err=coroutine.resume(co); assert(ok,err) end
    function moon.async(fn) local co=coroutine.create(fn); resume(co); return co end
    function moon.clock() return now end
    function moon.wait() return coroutine.yield() end
    function moon.wakeup(co) enqueue(co,0) end
    function moon.sleep(ms) enqueue(coroutine.running(),ms); coroutine.yield() end
    function moon.timeout(_,fn) deadline=fn end
    function moon.exit(code) exit_code=code end
    function moon.info() end
    function moon.error(message)
        assert(not tostring(message):find("fixture-secret",1,true),"password leaked to log")
    end
    local adapters={open=function(_,_,config,implementation,mode,_,tag)
        local api={implementation=implementation,mode=mode,poolsize=config.poolsize,concurrency=config.concurrency,pids={}}
        for lane=1,config.poolsize do pid=pid+1; api.pids[lane]=pid end
        apis[#apis+1]=api
        function api:query(_,_,lane)
            return {{pid=self.pids[lane],db="fixture",db_user="fixture",version="140024",address="fixture",
                port=5432,timezone="UTC",encoding="UTF8",ssl=false}}
        end
        function api:write(sql)
            local schema=sql:match('SCHEMA "([%w_]+)"')
            if sql:match("^CREATE") then eq(schemas[schema],nil); schemas[schema]=true; created=created+1
            elseif sql:match("^DROP") then eq(schemas[schema],true); schemas[schema]=nil; dropped=dropped+1
            else error("unexpected admin SQL") end
        end
        function api:request(prefix,name,i,w)
            eq(self.closed,nil)
            moon.sleep(1)
            if options.request_error and implementation=="sqlx" and name=="write" then
                error("fixture-secret deliberate database failure")
            end
            if name=="write" then counters[prefix][w]=counters[prefix][w]+1 end
            return i
        end
        function api:close() self.closed=true end
        if tag:find("admin",1,true) then eq(config.concurrency,4) end -- admin result row limit covers biggest group
        return api
    end}
    local cases={plan=workloads.plan}
    function cases.build(config,prefix)
        local result={}
        for _,name in ipairs({"tiny","write","hot_lane"}) do
            result[#result+1]={name=name,count=config.iterations,sql_per_request=1,
                writes_per_request=name=="write" and 1 or nil,driver_only=name=="hot_lane",
                request=function(api,i,w) return api:request(prefix,name,i,w) end,
                check=function(v,i) eq(v,i) end}
        end
        return result
    end
    function cases.reset(_,config,prefix)
        counters[prefix]={}; for w=1,config.concurrency do counters[prefix][w]=0 end
    end
    cases.setup=cases.reset
    function cases.fifo(_,_,config) fifo=fifo+1; eq(config.concurrency==2 or config.concurrency==4,true) end
    function cases.check_writes(_,prefix,expected,_,workers,multiplier)
        local total=0
        eq(#counters[prefix],#workers)
        for w,count in ipairs(workers) do eq(counters[prefix][w],count*multiplier); total=total+count*multiplier end
        eq(total,expected)
    end
    local exporter={html_path=reports.html_path,writer=function()
        return {save=function(_,value,with_html)
            report=value; checkpoints=checkpoints+1
            eq(report.config.password,nil); eq(report.config.url,nil)
            if options.export_error and value.status=="complete" and with_html then error("export fixture failure") end
        end}
    end}
    local env=setmetatable({_G={},
        debug={getinfo=function() return {source="@example/benchmark_pg.lua"} end},
        package={config=package.config,searchpath=function() return "E:/fixture/lualib/moon.lua" end},
        require=function(name)
            if name=="moon" then return moon end
            eq(name,"json"); return {null={},encode=function() error("real JSON writer must not run") end}
        end,
        dofile=function(path)
            if path:match("common%.lua$") then return common end
            if path:match("config%.lua$") then return cfg end
            if path:match("adapters%.lua$") then return adapters end
            if path:match("cases%.lua$") then return cases end
            if path:match("report%.lua$") then return exporter end
            error("unexpected file read: "..path)
        end,
    },{__index=_G})
    main=moon.async(function() assert(loadfile("example/benchmark_pg.lua","t",env))() end)
    local steps=0
    -- The bootstrap creates its own coroutine, so drain all scheduled work rather than just main.
    while #events>0 do
        table.sort(events,function(a,b) return a.time==b.time and a.serial<b.serial or a.time<b.time end)
        local event=table.remove(events,1); now=event.time; resume(event.co)
        steps=steps+1; assert(steps<10000,"flow scheduler did not terminate")
        if options.deadline and now>.03 then local fn=deadline; deadline=nil; options.deadline=false; fn() end
    end
    eq(coroutine.status(main),"dead")
    if options.bad_case then eq(#apis,0); eq(exit_code,1); eq(report,nil); return end
    eq(report.config.validate_every,100); eq(#report.profiles,3)
    eq(report.profiles[3].name,"driver_c4")
    if report.status=="deadline_exceeded" then
        eq(exit_code,1); eq(#report.remaining_schemas>0,true)
    else
        eq(created,dropped); eq(next(schemas),nil); eq(#report.remaining_schemas,0)
        for _,api in ipairs(apis) do eq(api.closed,true) end
        if options.request_error then
            eq(exit_code,1); eq(report.status,"failed")
            eq(report.error:find("fixture-secret",1,true),nil)
            eq(report.error:find("<redacted>",1,true)~=nil,true)
        elseif options.export_error then
            eq(exit_code,1); eq(report.status,"failed")
            eq(report.report_error:find("export fixture failure",1,true)~=nil,true)
        else
            eq(exit_code,0); eq(report.status,"complete"); eq(fifo,4)
            eq(#report.comparisons,8); eq(#report.runs,32)
            for _,r in ipairs(report.runs) do
                eq(r.errors,0); eq(r.elapsed_s>=.005-1e-8,true); eq(r.warmup.elapsed_s>=.002-1e-8,true)
                eq(r.concurrency,r.mode=="driver_c4" and 4 or 2)
            end
            eq(reports.render(report):find("测量完成",1,true)~=nil,true)
            eq(checkpoints>#report.runs,true)
        end
    end
end
test()
test({bad_case=true})
test({request_error=true})
test({export_error=true})
test({deadline=true})
print(("benchmark flow checks passed (%d assertions; injected Lua-only services, no Moon/database/network)"):format(checks))
