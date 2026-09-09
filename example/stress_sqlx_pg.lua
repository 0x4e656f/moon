-- SQLx-only PostgreSQL stress/soak test. Never run against a production database.
local directory=debug.getinfo(1,"S").source:sub(2):gsub("\\","/"):match("^(.*)/") or "."
local raw=dofile(directory.."/sqlx_stress/config.lua")
local common=dofile(directory.."/pg_bench/common.lua")
if _G["__init__"] then return common.bootstrap(raw) end
local moon=require("moon")
local json=require("json")
local moon_path=assert(package.searchpath("moon",package.path)):gsub("\\","/")
local root=assert(moon_path:match("^(.*)/lualib/moon%.lua$"),"cannot locate workspace root")
local settings=dofile(root.."/example/sqlx_stress/settings.lua")
local runner=dofile(root.."/example/sqlx_stress/runner.lua")
local exporter=dofile(root.."/example/sqlx_stress/report.lua")
local adapters=dofile(root.."/example/pg_bench/adapters.lua")
local cases=dofile(root.."/example/pg_bench/cases.lua")

moon.async(function()
    local configured,cfg=pcall(settings.prepare,raw,root,common)
    if not configured then moon.error(common.redact(cfg,raw)); moon.exit(1); return end
    local suffix=("%d_%d_%06x"):format(os.time(),moon.id,math.random(0,0xffffff))
    local schema="moon_sqlxstress_"..suffix
    assert(schema:match("^moon_sqlxstress_%d+_%d+_%x+$") and #schema<=63)
    local prefix='"'..schema..'".'
    local output=cfg.output or root.."/target/sqlx_stress_"..suffix..".json"
    local html=cfg.html_report and (cfg.html_output or output:gsub("%.json$","")..".html") or nil
    local prepared,writer=pcall(exporter.writer,output,html,json.encode)
    if not prepared then moon.error(common.redact(writer,cfg)); moon.exit(1); return end
    local report={format="moon_sqlx_stress",format_version=1,status="running",started_utc=os.date("!%Y-%m-%dT%H:%M:%SZ"),
        config=settings.public(raw),stages={},samples={},checks={},cleanup_errors={},remaining_schemas={},endpoints={}}
    report.config.lua=_VERSION; report.config.platform=package.config:sub(1,1)=="\\" and "Windows" or "POSIX"
    local ended=false
    local origin,last_checkpoint=moon.clock(),moon.clock()
    local admin,pool,sqlx,client
    local function save(final)
        local ok,err=pcall(writer.save,writer,report,final)
        if not ok then
            report.report_error=common.redact(err,cfg); report.status="failed"
            pcall(writer.save,writer,report,false)
            return false,report.report_error
        end
        last_checkpoint=moon.clock()
        return true
    end
    if not save(true) then moon.error(report.report_error); moon.exit(1); return end
    moon.info("SQLx stress JSON",output)
    if html then moon.info("SQLx stress HTML",html) end
    moon.info(("SQLx %s: pool=%d, %d stages, planned load/warmup/idle >= %.1f minutes")
        :format(cfg.mode,cfg.poolsize,#cfg.stages,cfg.planned_ms/60000))
    moon.timeout(cfg.deadline,function()
        if ended then return end
        ended=true; report.status="deadline_exceeded"
        report.error="Global deadline exceeded; in-flight writes may have committed. Inspect remaining_schemas and possibly_created_schema."
        report.finished_utc=os.date("!%Y-%m-%dT%H:%M:%SZ")
        save(true); moon.error(report.error); moon.exit(1)
    end)
    local function resources()
        local response=sqlx.response_stats()
        local snapshot={caller_lua_kib=collectgarbage("count"),waiting=response.waiting,ready=response.ready}
        if pool and pool.service and cfg.sample_driver then
            local state=common.ok(client.stats(pool.service))
            local queued,inflight,connected=0,0,0
            for _,lane in ipairs(state.lanes) do
                queued=queued+lane.queue
                inflight=inflight+(lane.inflight and 1 or 0)
                connected=connected+(lane.connected and 1 or 0)
            end
            snapshot.driver_queue=queued; snapshot.driver_inflight=inflight; snapshot.driver_connected=connected
            snapshot.driver_lua_kib=moon.call("debug",pool.service,"mem")
            assert(type(snapshot.driver_lua_kib)=="number","could not read driver Lua memory")
        end
        return snapshot
    end
    local function check(name,fn)
        local ok,err=pcall(fn)
        report.checks[#report.checks+1]={name=name,passed=ok,error=not ok and common.redact(err,cfg) or nil}
        if not ok then error(err,0) end
    end
    local function record(sample,stage,phase)
        if ended then return end
        assert(#report.samples<cfg.max_samples,"max_samples reached; increase it or reduce sampling frequency")
        sample.stage=stage; sample.phase=phase; sample.time_s=moon.clock()-origin
        sample.resources=resources()
        if ended then return end
        report.samples[#report.samples+1]=sample
        if moon.clock()-last_checkpoint>=cfg.checkpoint_ms/1000 then
            assert(save(false))
            if cfg.log_progress then
                moon.info(("SQLx progress %s/%s: %.1f req/s, p99 %.3f ms, window errors %d, waiting %d, ready %d")
                    :format(common.redact(stage,cfg),phase,sample.requests_per_s or 0,sample.p99_ms or 0,
                        sample.errors or 0,sample.resources.waiting,sample.resources.ready))
            end
        end
    end
    local function inspect(api,count,label)
        local seen={}
        for lane=1,count do
            local row=api:query([[SELECT pg_backend_pid()::bigint AS pid,current_database()::text AS db,
                current_user::text AS db_user,current_setting('server_version_num')::text AS version,
                current_setting('TimeZone')::text AS timezone,current_setting('client_encoding')::text AS encoding,
                (SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()) AS ssl]],{},lane)[1]
            assert(row and not seen[row.pid],"pool lanes must use distinct physical connections")
            seen[row.pid]=true
            common.equal(row.db,cfg.database); common.equal(row.timezone,"UTC"); common.equal(row.encoding,"UTF8")
            common.equal(row.ssl,cfg.sslmode~="disable")
            report.endpoints[#report.endpoints+1]={role=label,lane=lane,server=row}
        end
    end
    local function guard(api)
        for _,method in ipairs({"query","write","transaction","batch"}) do
            local invoke=api[method]
            if invoke then api[method]=function(self,...)
                assert(not ended,"stress deadline reached; SQL was not submitted")
                local result=invoke(self,...)
                assert(not ended,"stress deadline reached while waiting; write outcome may be unknown")
                return result
            end end
        end
        return api
    end
    local function verify(result,label)
        check(label.."/persisted_writes",function()
            local total=0
            for w=1,cfg.concurrency do result.worker_writes[w]=result.worker_writes[w] or 0; total=total+result.worker_writes[w] end
            cases.check_writes(admin,prefix,total,common,result.worker_writes,1)
        end)
        check(label.."/responses_released",function()
            local state=sqlx.response_stats()
            common.equal(state.waiting,0); common.equal(state.ready,0)
        end)
    end
    local ok,err=pcall(function()
        sqlx=require("ext.sqlx")
        if cfg.mode=="driver" then client=require("lrust_sqldriver.client") end
        local admin_cfg={}; for k,v in pairs(cfg) do admin_cfg[k]=v end
        admin_cfg.poolsize=1; admin_cfg.cache=0
        admin_cfg.url=cfg.url:gsub("statement%-cache%-capacity=%d+","statement-cache-capacity=0")
        admin=guard(adapters.open(moon,common,admin_cfg,"sqlx","direct",root,schema.."_admin"))
        inspect(admin,1,"admin")
        -- Record attempted ownership before CREATE. On an ambiguous CREATE error
        -- do NOT drop a schema whose creation we never confirmed.
        report.possibly_created_schema=schema; assert(save(false))
        admin:write('CREATE SCHEMA "'..schema..'"')
        report.remaining_schemas[1]=schema; report.possibly_created_schema=nil; assert(save(false))
        cases.setup(admin,cfg,prefix)
        pool=guard(adapters.open(moon,common,cfg,"sqlx",cfg.mode,root,schema))
        inspect(pool,cfg.poolsize,"load")
        local workloads=cases.build(cfg,prefix,common,json.null)
        if cfg.mode=="driver" and cfg.fifo_check then
            check("same_key_fifo",function() cases.reset(admin,cfg,prefix); cases.fifo(pool,moon,cfg,prefix,common) end)
        end
        report.initial_resources=resources(); assert(save(false))
        for _,spec in ipairs(cfg.stages) do
            if ended then return end
            local stage={name=spec.name,concurrency=spec.concurrency,status="warmup"}
            report.stages[#report.stages+1]=stage
            moon.info("SQLx stage starting",common.redact(spec.name,cfg),"concurrency",spec.concurrency,"duration_ms",spec.duration_ms)
            local current={}; for k,v in pairs(cfg) do current[k]=v end
            current.concurrency=spec.concurrency
            if cfg.warmup_ms>0 then
                cases.reset(admin,cfg,prefix)
                current.validate_every=1
                stage.warmup=runner.run(moon,common,current,pool,workloads,cfg.warmup_ms,nil,function() return ended end)
                if ended then return end
                assert(stage.warmup.errors==0,stage.warmup.error)
                verify(stage.warmup,spec.name.."/warmup")
                current.validate_every=cfg.validate_every
            end
            cases.reset(admin,cfg,prefix)
            stage.status="running"; assert(save(false))
            stage.result=runner.run(moon,common,current,pool,workloads,spec.duration_ms,function(sample)
                record(sample,spec.name,"measure")
            end,function() return ended end)
            if ended then return end
            local result=stage.result
            stage.status="checking"
            assert(not result.recording_error,result.recording_error)
            verify(result,spec.name)
            check(spec.name.."/thresholds",function()
                assert(result.success>0,"stage completed no successful requests")
                assert(result.elapsed_s*1000+.01>=spec.duration_ms,"stage stopped before target duration")
                assert(result.requests_per_s>=cfg.min_stage_qps,"stage QPS below configured minimum")
                assert(cfg.max_stage_p99_ms==0 or result.p99_ms<=cfg.max_stage_p99_ms,"stage p99 above configured maximum")
            end)
            stage.status=result.errors==0 and "complete" or "failed"
            assert(save(false))
            moon.info(("SQLx stage %s: %.1f req/s, p99 %.3f ms, successes %d, errors %d")
                :format(spec.name,result.requests_per_s,result.p99_ms,result.success,result.errors))
            if cfg.stop_on_error then assert(result.errors==0,result.error) end
        end
        if cfg.collect_at_idle then
            collectgarbage("collect")
            if pool.service then moon.call("debug",pool.service,"gc") end
            report.idle_gc=true
        end
        local idle_until=moon.clock()+cfg.idle_ms/1000
        repeat
            record({success=0,errors=0},"idle","idle")
            if ended or moon.clock()>=idle_until then break end
            moon.sleep(math.max(1,math.min(cfg.sample_ms,math.ceil((idle_until-moon.clock())*1000))))
        until false
    end)
    if ended then return end
    if not ok then report.error=common.redact(err,cfg) end
    local function cleanup(fn)
        local success,why=pcall(fn)
        if not success then report.cleanup_errors[#report.cleanup_errors+1]=common.redact(why,cfg) end
    end
    if pool then cleanup(function() pool:close() end) end
    if ended then return end
    if admin and #report.remaining_schemas>0 then
        cleanup(function() admin:write('DROP SCHEMA "'..schema..'" CASCADE'); report.remaining_schemas={} end)
    end
    if ended then return end
    if admin then cleanup(function() admin:close() end) end
    if ended then return end
    if sqlx then
        cleanup(function()
            report.final_resources=resources()
            common.equal(report.final_resources.waiting,0); common.equal(report.final_resources.ready,0)
        end)
    end
    local passed=ok and #report.stages==#cfg.stages and #report.cleanup_errors==0 and not report.report_error
    for _,stage in ipairs(report.stages) do if stage.status~="complete" then passed=false end end
    report.status=passed and "complete" or "failed"
    report.finished_utc=os.date("!%Y-%m-%dT%H:%M:%SZ"); report.elapsed_s=moon.clock()-origin
    ended=true
    local written=save(true)
    moon.info("SQLx stress finished",report.status,output,html or "HTML disabled")
    if report.error then moon.error(report.error) end
    moon.exit(passed and written and 0 or 1)
end)
