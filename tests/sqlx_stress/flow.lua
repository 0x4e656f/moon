-- Execute the real bootstrap with synthetic config/services/database/report sinks.
local fixtures=dofile("tests/sqlx_stress/fixtures.lua")
local common=dofile("example/pg_bench/common.lua")
local settings=dofile("example/sqlx_stress/settings.lua")
local runner=dofile("example/sqlx_stress/runner.lua")
local renderer=dofile("example/sqlx_stress/report.lua")
local checks=0
local function eq(a,b) checks=checks+1; assert(a==b,tostring(a).." ~= "..tostring(b)) end
local function test(options)
    options=options or {}
    local cfg=fixtures.config()
    if options.invalid then cfg.allow_write=false end
    if options.threshold then cfg.min_stage_qps=1000000 end
    if options.direct then cfg.mode="direct"; cfg.poolsize=4 end
    local moon=fixtures.scheduler()
    local timeout=moon.timeout
    function moon.timeout(ms,fn) timeout(options.deadline and 100 or ms,fn) end
    local report,initial_html,final_html,checkpoints=nil,false,false,0
    local created,dropped,active,submitted,fifo=0,0,0,0,0
    local apis,counters={},{}
    function moon.call(protocol,_,cmd)
        eq(protocol,"debug"); eq(cmd=="mem" or cmd=="gc",true); moon.sleep(1); return 64
    end
    local native={response_stats=function() return {waiting=active,ready=0} end}
    local client={stats=function()
        if options.sample_error and submitted>90 then error("sample failed") end
        moon.sleep(1)
        local lanes={}
        for i=1,cfg.poolsize do lanes[i]={queue=math.max(0,active-cfg.poolsize),inflight=active>=i,connected=true} end
        return {lanes=lanes}
    end}
    local adapters={open=function(_,_,c,impl,mode,_,tag)
        eq(impl,"sqlx")
        local api={mode=mode,service=mode=="driver" and 456 or nil}
        api.admin=tag:sub(-6)=="_admin"
        apis[#apis+1]=api
        function api:query(_,_,lane)
            return {{pid=#apis*100+(lane or 1),db=cfg.database,db_user=cfg.user,version="160000",timezone="UTC",encoding="UTF8",ssl=false}}
        end
        function api:write(sql)
            assert(not moon.exit_code,"SQL submitted after deadline exit")
            if sql:find("^CREATE SCHEMA") then
                if options.create_error then error("uncertain CREATE") end
                created=created+1
            elseif sql:find("^DROP SCHEMA") then
                eq(created,1)
                if options.cleanup_error then error("cleanup failed") end
                dropped=dropped+1
            else error("unexpected bootstrap SQL: "..sql) end
        end
        function api:close()
            self.closed=true; self.service=nil
        end
        return api
    end}
    local cases={}
    function cases.setup(_,c) for w=1,c.concurrency do counters[w]=0 end end
    function cases.reset(_,c) for w=1,c.concurrency do counters[w]=0 end end
    function cases.fifo() fifo=fifo+1 end
    function cases.check_writes(_,_,expected,_,workers)
        local sum=0
        eq(#workers,#counters)
        for w,n in ipairs(workers) do eq(counters[w],n); sum=sum+n end
        eq(sum,expected)
    end
    function cases.build()
        local out={}
        for _,name in ipairs({"tiny","write","transaction"}) do
            local writes=name=="transaction" and cfg.tx_size or name=="write" and 1 or 0
            out[#out+1]={name=name,writes_per_request=writes,sql_per_request=math.max(1,writes),
                request=function(_,i,w)
                    assert(not moon.exit_code,"workload submitted after deadline")
                    active=active+1; submitted=submitted+1; moon.sleep(4); active=active-1
                    if options.request_error and name=="write" and i>5 then error("fixture-secret request failed") end
                    counters[w]=counters[w]+writes
                    return i
                end,
                check=function(value,i) eq(value,i) end}
        end
        return out
    end
    local exporter={writer=function()
        return {save=function(_,value,with_html)
            eq(value.config.password,nil); eq(value.config.url,nil); eq(value.config.sslkey,nil)
            report=value; checkpoints=checkpoints+1
            if with_html and value.status=="running" then initial_html=true end
            if with_html and value.status~="running" then final_html=true end
            if options.export_error and value.status=="complete" and with_html then error("HTML export failed") end
        end}
    end}
    local env=setmetatable({_G={},debug={getinfo=function() return {source="@example/stress_sqlx_pg.lua"} end},
        package={config=package.config,searchpath=function() return "/fixture/lualib/moon.lua" end},
        require=function(name)
            if name=="moon" then return moon end
            if name=="json" then return {null={}} end
            if name=="ext.sqlx" then return native end
            if name=="lrust_sqldriver.client" then return client end
            error("unexpected dependency: "..name)
        end,
        dofile=function(path)
            if path:match("config%.lua$") then return cfg end
            if path:match("common%.lua$") then return common end
            if path:match("settings%.lua$") then return settings end
            if path:match("runner%.lua$") then return runner end
            if path:match("report%.lua$") then return exporter end
            if path:match("adapters%.lua$") then return adapters end
            if path:match("cases%.lua$") then return cases end
            error("unexpected helper: "..path)
        end}, {__index=_G})
    -- Initialization phase must return Moon settings without loading a native DB module.
    env._G.__init__=true
    local startup=assert(loadfile("example/stress_sqlx_pg.lua","t",env))()
    eq(startup.thread,cfg.threads); eq(#apis,0)
    env._G.__init__=nil
    assert(loadfile("example/stress_sqlx_pg.lua","t",env))()
    moon.drain()
    if options.invalid then eq(#apis,0); eq(report,nil); eq(moon.exit_code,1); return end
    eq(initial_html,true); eq(final_html,true); eq(checkpoints>2,true); eq(active,0)
    if options.deadline then
        eq(report.status,"deadline_exceeded"); eq(moon.exit_code,1); eq(dropped,0)
        eq(#report.remaining_schemas,1)
        return
    end
    for _,api in ipairs(apis) do eq(api.closed,true) end
    if options.create_error then eq(created,0); eq(dropped,0); eq(report.possibly_created_schema~=nil,true)
    elseif options.cleanup_error then eq(#report.remaining_schemas,1); eq(dropped,0)
    else eq(created,1); eq(dropped,1); eq(#report.remaining_schemas,0) end
    if next(options) and not options.direct then
        eq(report.status,"failed"); eq(moon.exit_code,1)
        eq(renderer.render(report):find("配置内验收通过",1,true),nil)
        if options.request_error then eq(report.error:find("fixture-secret",1,true),nil) end
    else
        eq(report.status,"complete"); eq(moon.exit_code,0); eq(fifo,options.direct and 0 or 1)
        eq(#report.stages,2); eq(report.final_resources.waiting,0)
        for _,stage in ipairs(report.stages) do
            eq(stage.result.errors,0); eq(stage.status,"complete")
            local observed=0
            for _,s in ipairs(report.samples) do if s.stage==stage.name then observed=observed+s.success end end
            eq(observed,stage.result.success)
        end
        eq(renderer.render(report):find("配置内验收通过",1,true)~=nil,true)
    end
end
test(); test({direct=true}); test({invalid=true}); test({request_error=true}); test({threshold=true})
test({sample_error=true}); test({cleanup_error=true}); test({create_error=true}); test({export_error=true}); test({deadline=true})
print(("SQLx stress flow checks passed (%d assertions; fake services/DB/report sinks only)"):format(checks))
