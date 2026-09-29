-- No Moon binary, native SQLx module, real DB, SSH or user config is loaded.
local base=dofile("tests/sqlx_stress/fixtures.lua")
local common=dofile("example/pg_bench/common.lua")
local stress=dofile("example/sqlx_stress/settings.lua")
local settings=dofile("example/sqlx_diagnostic/settings.lua")
local runner=dofile("example/sqlx_stress/runner.lua")
local metrics=dofile("example/sqlx_diagnostic/pg_metrics.lua")
local checks=0
local function eq(a,b) checks=checks+1; assert(a==b,tostring(a).." ~= "..tostring(b)) end
local function config()
    local c=base.config()
    for _,k in ipairs({"mode","poolsize","stages","collect_at_idle","fifo_check","stop_on_error","error_samples",
        "sample_driver","log_progress","max_samples","min_stage_qps","max_stage_p99_ms","output","html_report","html_output"}) do c[k]=nil end
    c.pool_sizes={2,4}; c.sweep_concurrency=4; c.sweep_duration_ms=250
    c.compare_poolsize=2; c.compare_concurrency=2; c.compare_duration_ms=250
    c.pg_stats=true; c.monitor_timeout_ms=100; c.shutdown_grace_ms=100
    c.runtime={root="/fixture",token="123_abcdef",raw_output="not-written.json"}
    return c
end
for _,path in ipairs({"example/diagnose_sqlx_pg.lua","example/sqlx_diagnostic/settings.lua","example/sqlx_diagnostic/pg_metrics.lua"}) do
    assert(loadfile(path))
end
local plan,configs,planned=settings.prepare(config(),"/fixture",common,stress)
eq(#plan,8); eq(planned,3060)
for i,n in ipairs({2,4,4,2,2,2,2,2}) do eq(plan[i].poolsize,n) end
for i,n in ipairs({"direct","driver","driver","direct"}) do eq(plan[i+4].mode,n); eq(configs[i+4].concurrency,2) end
eq(settings.public(config()).password,nil); eq(settings.public(config()).runtime,nil)
for _,edit in ipairs({function(c)c.pool_sizes={2,2} end,function(c)c.compare_concurrency=3 end,
    function(c)c.deadline_ms=3000 end,function(c)c.workload={{name="hot_lane",weight=1}} end,
    function(c)c.allow_write=false end,function(c)c.unknown=1 end,function(c)c.sample_ms=1 end}) do
    local c=config(); edit(c); eq(pcall(settings.prepare,c,"/fixture",common,stress),false)
end
local query
local api={query=function(_,sql,params) query=sql; return {{data={ok=true}}} end}
eq(metrics.environment(api).ok,true)
eq(metrics.snapshot(api,"safe_schema",{123,456},140000).ok,true)
eq(query:find("IN (123,456)",1,true)~=nil,true); eq(query:find("pg_stat_checkpointer",1,true),nil)
metrics.snapshot(api,"safe_schema",{},170000)
eq(query:find("IN (0)",1,true)~=nil,true); eq(query:find("pg_stat_checkpointer",1,true)~=nil,true)
eq(pcall(metrics.snapshot,api,"x",{"1);bad"},140000),false)

local function flow(options)
    options=options or {}
    local cfg=config()
    if options.invalid then cfg.allow_write=false end
    if options.no_monitor then cfg.pg_stats=false end
    local moon=base.scheduler()
    function moon.now() return 1000000+moon.clock()*1000 end
    local timeout=moon.timeout
    function moon.timeout(ms,fn) timeout(options.deadline and 100 or ms,fn) end
    function moon.call(protocol,service,cmd) eq(protocol,"debug"); moon.sleep(1); return 64 end
    local report,saves,created,dropped,active,submitted= nil,0,0,0,0,0
    local apis,counters={},{}
    local sqlx={response_stats=function() return {waiting=active,ready=0} end}
    local client={stats=function() moon.sleep(1); return {lanes={{queue=0,inflight=active>0}}} end}
    local adapters={open=function(_,_,c,implementation,mode,_,tag)
        eq(implementation,"sqlx")
        local a={mode=mode,service=mode=="driver" and 456 or nil,tag=tag,cfg=c}
        apis[#apis+1]=a
        if tag:find("_monitor$",1) then
            eq(c.timeout,100)
            eq(c.url:find("statement_timeout%3D100",1,true)~=nil,true)
            eq(c.url:find("lock_timeout%3D100",1,true)~=nil,true)
        end
        function a:query(_,_,lane)
            assert(not moon.exit_code,"query after exit")
            return {{pid=#apis*100+(lane or 1),db=cfg.database,timezone="UTC",encoding="UTF8"}}
        end
        function a:write(sql)
            assert(not moon.exit_code,"write after exit")
            if sql:find("^CREATE SCHEMA") then
                if options.create_error then error("uncertain create") end
                created=created+1
            elseif sql:find("^DROP SCHEMA") then
                eq(created,1)
                if options.cleanup_error then error("drop failed") end
                dropped=dropped+1
            else error("unexpected SQL") end
        end
        function a:close()
            if options.close_error and self.service then error("unconfirmed shutdown") end
            self.closed=true; self.service=nil
        end
        return a
    end}
    local cases={}
    function cases.setup(_,c) for i=1,c.concurrency do counters[i]=0 end end
    function cases.reset(_,c) for i=1,c.concurrency do counters[i]=0 end end
    function cases.check_writes(_,_,total,_,workers)
        eq(#workers,#counters)
        local sum=0
        for w,n in ipairs(workers) do eq(n,counters[w]); sum=sum+n end
        eq(total,sum)
    end
    function cases.build(c)
        local out={}
        for _,name in ipairs({"tiny","write","transaction"}) do
            local writes=name=="transaction" and cfg.tx_size or name=="write" and 1 or 0
            out[#out+1]={name=name,sql_per_request=math.max(1,writes),writes_per_request=writes,
                request=function(api,id,worker)
                    assert(not moon.exit_code,"request after exit")
                    active=active+1; submitted=submitted+1; moon.sleep(4); active=active-1
                    if options.request_error and id>5 then error("fixture-secret failure") end
                    counters[worker]=counters[worker]+writes
                    return id
                end,
                check=function(actual,expected) eq(actual,expected) end}
        end
        return out
    end
    local observed=0
    local fake_metrics={environment=function() return {version="140024"} end,
        snapshot=function(_,schema,pids)
            observed=observed+1; moon.sleep(2)
            if options.monitor_error then error("fixture-secret monitoring denied") end
            return {waits={},database={xact_commit=observed,stats_reset="fixture"}}
        end}
    local exporter={writer=function()
        return {save=function(_,value)
            report=value; saves=saves+1
            eq(value.config.password,nil); eq(value.config.runtime,nil)
            if options.report_error and value.status=="complete" then error("disk full") end
        end}
    end}
    local env=setmetatable({_G={},require=function(name)
        if name=="moon" then return moon end
        if name=="json" then return {null={}} end
        if name=="ext.sqlx" then return sqlx end
        if name=="lrust_sqldriver.client" then return client end
        error("unexpected dependency "..name)
    end,dofile=function(path)
        if path=="runtime.lua" then return cfg end
        if path:match("common%.lua$") then return common end
        if path:match("sqlx_diagnostic/settings%.lua$") then return settings end
        if path:match("sqlx_stress/settings%.lua$") then return stress end
        if path:match("runner%.lua$") then return runner end
        if path:match("report%.lua$") then return exporter end
        if path:match("adapters%.lua$") then return adapters end
        if path:match("cases%.lua$") then return cases end
        if path:match("pg_metrics%.lua$") then return fake_metrics end
        error("unexpected file "..path)
    end},{__index=_G})
    function moon.args() return {"sqlxdiag","manual","runtime.lua"} end
    env._G.__init__=true
    local boot=assert(loadfile("example/diagnose_sqlx_pg.lua","t",env))(moon.args())
    eq(boot.thread,4); eq(#apis,0)
    env._G.__init__=nil
    assert(loadfile("example/diagnose_sqlx_pg.lua","t",env))()
    moon.drain()
    if options.invalid then eq(#apis,0); eq(report,nil); eq(moon.exit_code,1); return end
    eq(active,0); eq(saves>1,true)
    if options.deadline then eq(report.status,"deadline_exceeded"); eq(dropped,0); eq(moon.exit_code,1); return end
    if options.close_error then eq(dropped,0); eq(#report.remaining_schemas,1)
    elseif options.create_error then eq(dropped,0); eq(report.possibly_created_schema~=nil,true)
    elseif options.cleanup_error then eq(dropped,0); eq(#report.remaining_schemas,1)
    else eq(dropped,1); eq(#report.remaining_schemas,0) end
    if options.request_error or options.close_error or options.create_error or options.cleanup_error then
        eq(report.status,"failed"); eq(moon.exit_code,1)
    elseif options.report_error then eq(moon.exit_code,1)
    else
        eq(report.status,"complete"); eq(#report.stages,8); eq(moon.exit_code,0)
        for _,s in ipairs(report.stages) do
            eq(s.status,"complete"); eq(s.result.errors,0)
            eq(#s.backend_pids,s.poolsize)
            local sum=0
            for _,sample in ipairs(report.samples) do if sample.stage==s.name then sum=sum+sample.success end end
            eq(sum,s.result.success)
        end
    end
    if options.monitor_error then eq(#report.warnings,1); eq(observed,1); eq(report.warnings[1]:find("fixture-secret",1,true),nil) end
    if options.no_monitor then eq(observed,0) end
    for _,a in ipairs(apis) do if not (options.close_error and a.service) then eq(a.closed,true) end end
end
flow(); flow({invalid=true}); flow({no_monitor=true}); flow({monitor_error=true})
flow({request_error=true}); flow({deadline=true}); flow({create_error=true})
flow({cleanup_error=true}); flow({close_error=true}); flow({report_error=true})
print(("SQLx diagnostic offline checks passed (%d assertions; no DB / Moon / SSH)"):format(checks))
