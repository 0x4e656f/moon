-- Launch through tools/sqlx_diagnostic/run.py: supplies a private, generated Lua config.
local args=...
if not _G["__init__"] then args=require("moon").args() end
local raw=dofile(assert(args[3],"use python tools/sqlx_diagnostic/run.py"))
local root=raw.runtime.root
local common=dofile(root.."/example/pg_bench/common.lua")
if _G["__init__"] then return common.bootstrap(raw) end
local moon,json=require("moon"),require("json")
local settings=dofile(root.."/example/sqlx_diagnostic/settings.lua")
local stress=dofile(root.."/example/sqlx_stress/settings.lua")
local runner=dofile(root.."/example/sqlx_stress/runner.lua")
local exporter=dofile(root.."/example/sqlx_stress/report.lua")
local adapters=dofile(root.."/example/pg_bench/adapters.lua")
local cases=dofile(root.."/example/pg_bench/cases.lua")
local metrics=dofile(root.."/example/sqlx_diagnostic/pg_metrics.lua")

moon.async(function()
    local valid,plan,configs,planned=pcall(settings.prepare,raw,root,common,stress)
    if not valid then moon.error(common.redact(plan,raw)); moon.exit(1); return end
    local schema="moon_sqlxdiag_"..raw.runtime.token
    assert(schema:match("^moon_sqlxdiag_%d+_%x+$") and #schema<=63)
    local prefix='"'..schema..'".'
    local report={format="moon_sqlx_diagnostic",format_version=1,status="running",config=settings.public(raw),
        started_utc=os.date("!%Y-%m-%dT%H:%M:%SZ"),planned_ms=planned,plan=plan,
        stages={},samples={},checks={},cleanup_errors={},remaining_schemas={},warnings={}}
    local writer=exporter.writer(raw.runtime.raw_output,nil,json.encode)
    local origin,last_checkpoint=moon.clock(),moon.clock()
    local ended=false
    local admin,monitor,pool,sqlx,client
    local monitor_failed=false
    if not raw.pg_stats then report.warnings[#report.warnings+1]="PG SQL metrics disabled by pg_stats=false" end
    local function save()
        local ok,err=pcall(writer.save,writer,report,false)
        if not ok then report.report_error=common.redact(err,raw); error(report.report_error,0) end
        last_checkpoint=moon.clock()
    end
    local function now() return moon.now()/1000 end
    local function guard(api)
        for _,key in ipairs({"query","write","transaction","batch"}) do
            local fn=api[key]
            if fn then api[key]=function(self,...)
                assert(not ended,"diagnostic deadline reached; SQL not submitted")
                local result=fn(self,...)
                assert(not ended,"deadline reached while waiting; write outcome may be unknown")
                return result
            end end
        end
        return api
    end
    local function check(name,fn)
        local ok,err=pcall(fn)
        report.checks[#report.checks+1]={name=name,passed=ok,error=not ok and common.redact(err,raw) or nil}
        assert(ok,err)
    end
    local function resources()
        local r=sqlx.response_stats()
        local result={caller_lua_kib=collectgarbage("count"),waiting=r.waiting,ready=r.ready}
        if pool and pool.service then
            local s=common.ok(client.stats(pool.service))
            result.driver_queue=0; result.driver_inflight=0
            for _,lane in ipairs(s.lanes) do
                result.driver_queue=result.driver_queue+lane.queue
                result.driver_inflight=result.driver_inflight+(lane.inflight and 1 or 0)
            end
            result.driver_lua_kib=moon.call("debug",pool.service,"mem")
        end
        return result
    end
    local function inspect(api,n)
        local pids,seen={},{}
        for lane=1,n do
            local row=api:query([[SELECT pg_backend_pid()::bigint AS pid,current_database()::text AS db,
                current_setting('TimeZone')::text AS timezone,current_setting('client_encoding')::text AS encoding]],{},lane)[1]
            assert(row and not seen[row.pid],"pool must use distinct physical connections")
            common.equal(row.db,raw.database); common.equal(row.timezone,"UTC"); common.equal(row.encoding,"UTF8")
            seen[row.pid]=true; pids[#pids+1]=row.pid
        end
        return pids
    end
    local function record(sample,spec,pids)
        if ended then return end
        sample.stage=spec.name; sample.time_s=moon.clock()-origin; sample.epoch_s=now()
        sample.resources=resources()
        if monitor and not monitor_failed then
            local started=moon.clock()
            local ok,result=pcall(metrics.snapshot,monitor,schema,pids,tonumber(report.database_environment.version))
            sample.pg_sample_ms=(moon.clock()-started)*1000
            sample.pg_epoch_s=now()
            if ok then sample.pg=result else
                monitor_failed=true
                report.warnings[#report.warnings+1]="PG monitoring stopped: "..common.redact(result,raw)
            end
        end
        if ended then return end
        report.samples[#report.samples+1]=sample
        if moon.clock()-last_checkpoint>=raw.checkpoint_ms/1000 then save() end
    end
    save()
    moon.timeout(raw.deadline_ms,function()
        if ended then return end
        ended=true; report.status="deadline_exceeded"
        report.error="Deadline exceeded. SQL may have committed; inspect remaining_schemas / possibly_created_schema."
        report.finished_utc=os.date("!%Y-%m-%dT%H:%M:%SZ"); report.elapsed_s=moon.clock()-origin
        pcall(save); moon.error(report.error); moon.exit(1)
    end)
    local ok,err=pcall(function()
        sqlx=require("ext.sqlx"); client=require("lrust_sqldriver.client")
        local maximum=0
        for _,c in ipairs(configs) do maximum=math.max(maximum,c.concurrency) end
        local setup={}; for k,v in pairs(configs[1]) do setup[k]=v end
        setup.concurrency=maximum; setup.poolsize=1; setup.cache=0
        setup.url=setup.url:gsub("statement%-cache%-capacity=%d+","statement-cache-capacity=0")
        admin=guard(adapters.open(moon,common,setup,"sqlx","direct",root,schema.."_admin"))
        report.database_environment=metrics.environment(admin)
        report.possibly_created_schema=schema; save()
        admin:write('CREATE SCHEMA "'..schema..'"')
        report.remaining_schemas={schema}; report.possibly_created_schema=nil; save()
        cases.setup(admin,setup,prefix)
        if raw.pg_stats then
            local mc={}; for k,v in pairs(setup) do mc[k]=v end
            mc.timeout=raw.monitor_timeout_ms
            mc.url=mc.url:gsub("statement_timeout%%3D%d+","statement_timeout%%3D"..mc.timeout)
                :gsub("lock_timeout%%3D%d+","lock_timeout%%3D"..mc.timeout)
            local success,value=pcall(adapters.open,moon,common,mc,"sqlx","direct",root,schema.."_monitor")
            if success then monitor=guard(value) else report.warnings[#report.warnings+1]="PG monitor unavailable: "..common.redact(value,raw) end
        end
        local function verify(result,label)
            check(label.."/persisted_writes",function()
                local total=0
                for w=1,maximum do result.worker_writes[w]=result.worker_writes[w] or 0; total=total+result.worker_writes[w] end
                cases.check_writes(admin,prefix,total,common,result.worker_writes,1)
            end)
            check(label.."/responses_released",function()
                local state=sqlx.response_stats(); common.equal(state.waiting,0); common.equal(state.ready,0)
            end)
            assert(result.errors==0,result.error); assert(not result.recording_error,result.recording_error)
        end
        for index,spec in ipairs(plan) do
            if ended then return end
            local cfg=configs[index]
            local stage={name=spec.name,mode=spec.mode,group=spec.group,round=spec.round,poolsize=spec.poolsize,
                concurrency=spec.concurrency,status="setup"}
            report.stages[#report.stages+1]=stage; save()
            moon.info("SQLx diagnostic",spec.name,"duration_ms",spec.duration_ms)
            pool=guard(adapters.open(moon,common,cfg,"sqlx",spec.mode,root,schema.."_"..index))
            stage.backend_pids=inspect(pool,spec.poolsize)
            local workloads=cases.build(cfg,prefix,common,json.null)
            cases.reset(admin,setup,prefix)
            if cfg.warmup_ms>0 then
                local every=cfg.validate_every; cfg.validate_every=1
                stage.warmup=runner.run(moon,common,cfg,pool,workloads,cfg.warmup_ms,nil,function() return ended end)
                if ended then return end
                cfg.validate_every=every; verify(stage.warmup,spec.name.."/warmup")
            end
            cases.reset(admin,setup,prefix)
            -- Same GC boundary in every profile; no forced GC during timed load.
            collectgarbage("collect"); if pool.service then moon.call("debug",pool.service,"gc") end
            stage.status="running"; save()
            stage.start_epoch_s=now()
            stage.result=runner.run(moon,common,cfg,pool,workloads,spec.duration_ms,function(s)
                record(s,spec,stage.backend_pids)
            end,function() return ended end)
            if ended then return end
            stage.end_epoch_s=stage.start_epoch_s+stage.result.elapsed_s
            verify(stage.result,spec.name)
            assert(stage.result.success>0 and stage.result.elapsed_s*1000+.01>=spec.duration_ms,"incomplete stage")
            stage.status="complete"; save()
            pool:close(); pool=nil
        end
        collectgarbage("collect")
        local idle_until=moon.clock()+raw.idle_ms/1000
        while moon.clock()<idle_until and not ended do
            record({success=0,errors=0},{name="idle"},{})
            moon.sleep(math.max(1,math.min(raw.sample_ms,math.ceil((idle_until-moon.clock())*1000))))
        end
    end)
    if ended then return end
    if not ok then report.error=common.redact(err,raw) end
    local function cleanup(fn)
        local success,why=pcall(fn)
        if not success then report.cleanup_errors[#report.cleanup_errors+1]=common.redact(why,raw) end
        return success
    end
    local pool_closed=not pool or cleanup(function() pool:close(); pool=nil end)
    if ended then return end
    if monitor then cleanup(function() monitor:close(); monitor=nil end) end
    if ended then return end
    -- Never drop tables while an unconfirmed load service may still be running.
    if pool_closed and admin and #report.remaining_schemas>0 then
        cleanup(function() admin:write('DROP SCHEMA "'..schema..'" CASCADE'); report.remaining_schemas={} end)
    end
    if ended then return end
    if admin then cleanup(function() admin:close(); admin=nil end) end
    if ended then return end
    if sqlx then cleanup(function()
        report.final_resources=resources()
        common.equal(report.final_resources.waiting,0); common.equal(report.final_resources.ready,0)
    end) end
    local passed=ok and #report.cleanup_errors==0 and not report.report_error and #report.stages==#plan
    report.status=passed and "complete" or "failed"
    report.elapsed_s=moon.clock()-origin; report.finished_utc=os.date("!%Y-%m-%dT%H:%M:%SZ")
    ended=true
    local written,why=pcall(save)
    if not written then moon.error(common.redact(why,raw)) end
    if report.error then moon.error(report.error) end
    moon.exit(passed and written and 0 or 1)
end)
