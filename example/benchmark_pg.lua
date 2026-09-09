-- Manual PostgreSQL comparison. Never run against production; see docs/pg_benchmark.md.
-- Resolve relative to this script in BOTH phases: initial cwd is the repo; runtime cwd is example/.
local source=debug.getinfo(1,"S").source
local directory=source:sub(2):gsub("\\","/"):match("^(.*)/") or "."
local common=dofile(directory.."/pg_bench/common.lua")
local config=dofile(directory.."/pg_bench/config.lua")
if _G["__init__"] then
    return common.bootstrap(config)
end

local moon=require("moon")
local json=require("json")
-- Moon changes cwd to the bootstrap's directory; derive absolute paths from its library path.
local moon_path=assert(package.searchpath("moon",package.path)):gsub("\\","/")
local root=assert(moon_path:match("^(.*)/lualib/moon%.lua$"),"cannot locate workspace root")
local adapters=dofile(root.."/example/pg_bench/adapters.lua")
local cases=dofile(root.."/example/pg_bench/cases.lua")
local reports=dofile(root.."/example/pg_bench/report.lua")

moon.async(function()
    local cfg,profiles,minimum_ms
    local configured,why=pcall(function()
        cfg=common.config(config,root)
        profiles,minimum_ms=cases.plan(cfg,common.profiles(cfg))
    end)
    if not configured then moon.error(why); moon.exit(1); return end
    local suffix=("%d_%d_%06x"):format(os.time(),moon.id,math.random(0,0xffffff))
    local output=cfg.output or "target/pg_bench_"..suffix..".json"
    if not output:match("^%a:[/\\]") and output:sub(1,1)~="/" then output=root.."/"..output end
    local html_output=cfg.html_report and reports.html_path(output,cfg.html_output) or nil
    local prepared,writer=pcall(reports.writer,output,html_output,json.encode)
    if not prepared then moon.error(common.redact(writer,cfg)); moon.exit(1); return end
    local report={format_version=2,status="running",started_utc=os.date("!%Y-%m-%dT%H:%M:%SZ"),
        config={host=cfg.host,port=cfg.port,database=cfg.database,user=cfg.user,sslmode=cfg.sslmode,
            poolsize=cfg.poolsize,concurrency=cfg.concurrency,cache=cfg.cache,rounds=cfg.rounds,warmup=cfg.warmup,
            iterations=cfg.iterations,bulk_iterations=cfg.bulk_iterations,rows=cfg.rows,data_rows=cfg.data_rows,
            bytes=cfg.bytes,tx_size=cfg.tx_size,timeout_ms=cfg.timeout,deadline_ms=cfg.deadline,
            modes=cfg.modes,implementations=cfg.implementations,cases=cfg.cases or "all",
            lua=_VERSION,moon_threads=cfg.threads,driver_thread=cfg.driver_thread,
            enable_stdout=cfg.enable_stdout,loglevel=cfg.loglevel},
        notes={"Closed-loop acknowledged requests; no fire-and-forget, retries, or concurrent A/B load.",
            "An extra idle admin connection handles setup/reset/validation outside measurement.",
            "Latency excludes validation; wall throughput includes ALL validation/instrumentation through final completion.",
            "Each run satisfies BOTH minimum request count and duration, then drains in-flight requests.",
            "All warmup results are fully checked. Measured heavy results use per-worker periodic full checks plus structural checks.",
            "Quantiles use bounded 1% logarithmic upper-bound buckets (1 ns floor); mean/max remain exact.",
            "Extra driver concurrency groups are independent; compare A/B within a group, not unlike concurrency levels.",
            "bytea MiB/s counts application payload only, not protocol/TLS/hex traffic.",
            "SQLx transaction/batch returns metadata only; comparisons use writes without RETURNING.",
            "NUMERIC is explicitly cast to text in both queries; native type coverage is not scored.",
            "Connection establishment, setup, warmup, and cleanup are excluded. GC remains enabled.",
            "No process RSS/CPU measurement. Rust runtime and Moon have different worker topology."},
        endpoints={},checks={},runs={},comparisons={},cleanup_errors={},profiles=profiles,
        planned_minimum_s=minimum_ms/1000,files={json=output,html=html_output}}
    for _,key in ipairs({"min_duration_ms","warmup_duration_ms","validate_every","driver_concurrencies","run_label"}) do
        report.config[key]=cfg[key]
    end
    report.config.platform=package.config:sub(1,1)=="\\" and "Windows" or "POSIX"
    local finished,timed_out=false,false
    local admin,resources,schemas=nil,{},{}
    report.remaining_schemas=schemas -- keep the ownership ledger in every progress checkpoint
    local function save(with_html) writer:save(report,with_html) end
    local function save_final()
        local ok,err=pcall(save,true)
        if not ok then
            report.report_error=common.redact(err,cfg)
            if report.status~="deadline_exceeded" then report.status="failed" end
            -- An HTML/export failure must not leave the JSON marked as a successful benchmark.
            pcall(save,false)
        end
        return ok,err
    end
    local saved,save_error=save_final() -- initial "running" HTML also checks write permission before DB work
    if not saved then moon.error(common.redact(save_error,cfg)); moon.exit(1); return end
    moon.info("PG benchmark: test data only; report",output)
    if html_output then moon.info("HTML charts",html_output) end
    moon.info("mode",table.concat(cfg.modes,","),"pool",cfg.poolsize,"concurrency",cfg.concurrency,"cache",cfg.cache)
    moon.info(("Plan: %d groups, at least %.1f minutes measurement + warmup, deadline %.1f minutes")
        :format(#profiles,minimum_ms/60000,cfg.deadline/60000))
    moon.timeout(cfg.deadline,function()
        if finished then return end
        finished=true; timed_out=true; report.status="deadline_exceeded"
        report.error="Global deadline exceeded; benchmark is invalid. In-flight SQL may have committed. Inspect remaining_schemas for manual cleanup."
        report.remaining_schemas=schemas
        report.finished_utc=os.date("!%Y-%m-%dT%H:%M:%SZ")
        save_final()
        moon.error(report.error,table.concat(schemas,",")); moon.exit(1)
    end)

    local identity_sql=[[SELECT pg_backend_pid()::bigint AS pid,current_database()::text AS db,
        current_user::text AS db_user,current_setting('server_version_num')::text AS version,
        inet_server_addr()::text AS address,inet_server_port()::bigint AS port,
        current_setting('TimeZone')::text AS timezone,current_setting('client_encoding')::text AS encoding,
        (SELECT ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()) AS ssl]]
    local identity
    local function inspect(api)
        local pids={}
        for lane=1,(api==admin and 1 or cfg.poolsize) do
            local rows=api:query(identity_sql,{},lane)
            common.equal(#rows,1,"database identity query failed")
            local r=rows[1]
            assert(not pids[r.pid],"two pool lanes unexpectedly share one physical connection")
            pids[r.pid]=true
            common.equal(r.db,cfg.database,"connected to unexpected database")
            common.equal(r.timezone,"UTC","connection settings differ")
            common.equal(r.encoding,"UTF8","connection encoding differs")
            common.equal(r.ssl,cfg.sslmode~="disable","TLS mode not applied equally")
            if identity then
                for _, k in ipairs({"db","db_user","version","address","port","timezone","encoding","ssl"}) do
                    common.equal(r[k],identity[k],"libpq/SQLx connected to different endpoint or session settings: "..k)
                end
            else identity=r end
            report.endpoints[#report.endpoints+1]={implementation=api.implementation,
                mode=api==admin and "admin" or (api.profile or api.mode),lane=lane,server=r}
        end
    end
    local function record(metrics,api,case,round,position,phase)
        metrics.implementation=api.implementation; metrics.mode=api.profile or api.mode; metrics.case=case.name
        metrics.api_mode=api.mode
        metrics.round=round; metrics.position=position; metrics.phase=phase or "measure"
        metrics.sql_per_request=case.sql_per_request
        metrics.sql_statements_per_s=metrics.requests_per_s*case.sql_per_request -- excludes BEGIN/COMMIT
        if case.rows_per_request then metrics.rows_per_s=metrics.requests_per_s*case.rows_per_request end
        if case.bytes_sent then metrics.payload_send_mib_s=metrics.requests_per_s*case.bytes_sent/1048576 end
        if case.bytes_received then metrics.payload_receive_mib_s=metrics.requests_per_s*case.bytes_received/1048576 end
        metrics.warnings={}
        if metrics.elapsed_s<1 then metrics.warnings[#metrics.warnings+1]="测量短于 1 秒，易受启动和调度噪声影响" end
        if metrics.success<1000 then metrics.warnings[#metrics.warnings+1]="不足 1000 个成功样本，p99 尾部样本偏少" end
        if (metrics.validation_wall_pct or 0)>10 then metrics.warnings[#metrics.warnings+1]="校验占用超过 10% 的测量时间，吞吐受压测端限制" end
        if metrics.peak_inflight<math.min(metrics.concurrency,metrics.target_requests) then
            metrics.warnings[#metrics.warnings+1]="未达到目标在途并发，检查压测端调度或即时返回"
        end
        if metrics.error then metrics.error=common.redact(metrics.error,cfg) end
        report.runs[#report.runs+1]=metrics
        save()
    end
    local function compare(mode,case)
        if #cfg.implementations~=2 then return end
        local groups={libpq={},sqlx={}}
        for _, r in ipairs(report.runs) do
            if r.mode==mode and r.case==case.name and r.phase=="measure" and not r.error and r.errors==0 then
                groups[r.implementation][#groups[r.implementation]+1]=r
            end
        end
        if #groups.libpq~=cfg.rounds or #groups.sqlx~=cfg.rounds then return end
        local summary=common.compare(groups)
        summary.mode=mode; summary.case=case.name
        local a,b=summary.libpq,summary.sqlx
        report.comparisons[#report.comparisons+1]=summary
        moon.info(("COMPARE %-6s %-12s libpq/sqlx=%.3fx median req/s (libpq %.1f, sqlx %.1f)%s")
            :format(mode,case.name,summary.libpq_over_sqlx,a.median_requests_per_s,b.median_requests_per_s,
                summary.round_ranges_overlap and " [round ranges overlap; repeat before concluding]" or ""))
        save()
    end

    local ok,failure=pcall(function()
        local admin_cfg={}; for k,v in pairs(cfg) do admin_cfg[k]=v end
        admin_cfg.poolsize=1; admin_cfg.cache=0
        for _,profile in ipairs(profiles) do admin_cfg.concurrency=math.max(admin_cfg.concurrency,profile.concurrency) end
        admin_cfg.url=cfg.url:gsub("statement%-cache%-capacity=%d+","statement-cache-capacity=0")
        admin=adapters.open(moon,common,admin_cfg,cfg.implementations[1],"direct",root,"pgbench_admin_"..suffix)
        inspect(admin)
        for profile_index,profile in ipairs(profiles) do
            local profile_cfg={}; for k,v in pairs(cfg) do profile_cfg[k]=v end
            profile_cfg.concurrency=profile.concurrency
            local cfg=profile_cfg
            local mode=profile.mode
            local schema="moon_pgbench_"..suffix.."_p"..profile_index
            assert(schema:match("^moon_pgbench_%d+_%d+_%x+_p%d+$") and #schema<=63)
            local prefix='"'..schema..'".'
            local selected={}
            for _,name in ipairs(profile.cases) do selected[name]=true end
            local workloads=cases.build(cfg,prefix,common,json.null)
            local pools={}
            for _, implementation in ipairs(cfg.implementations) do
                local api=adapters.open(moon,common,cfg,implementation,mode,root,schema)
                api.profile=profile.name
                pools[implementation]=api; resources[#resources+1]=api; inspect(api)
            end
            admin:write('CREATE SCHEMA "'..schema..'"')
            schemas[#schemas+1]=schema; save()
            cases.setup(admin,cfg,prefix)
            if mode=="driver" then
                for _, name in ipairs(cfg.implementations) do
                    -- Reset outside the tested connection to avoid evicting its cached plans.
                    cases.reset(admin,cfg,prefix)
                    cases.fifo(pools[name],moon,cfg,prefix,common)
                    report.checks[#report.checks+1]={name="same_key_fifo",implementation=name,mode=profile.name,passed=true}
                    save()
                    moon.info("FIFO correctness passed",name)
                end
            end
            for case_index,case in ipairs(workloads) do
                if selected[case.name] then
                    for round=1,cfg.rounds do
                        local order={table.unpack(cfg.implementations)}
                        if #order==2 and (round+case_index+profile_index)%2==1 then order[1],order[2]=order[2],order[1] end
                        for position,name in ipairs(order) do
                            local api=pools[name]
                            if case.writes_per_request then cases.reset(admin,cfg,prefix) end
                            local operation=function(i,w)
                                assert(not timed_out,"benchmark deadline exceeded")
                                return case.request(api,i,w)
                            end
                            -- Prime every active lane, then do concurrent warmup with the same SQL.
                            for w=1,cfg.concurrency do case.check(operation(1,w),1,w) end
                            local warm=common.run(moon,math.max(cfg.warmup,cfg.concurrency),cfg.concurrency,operation,case.check,
                                {min_duration_ms=cfg.warmup_duration_ms})
                            if timed_out then return end
                            if warm.error then record(warm,api,case,round,position,"warmup"); error(warm.error,0) end
                            if case.writes_per_request then cases.reset(admin,cfg,prefix) end
                            local result=common.run(moon,case.count,cfg.concurrency,operation,case.check,
                                {min_duration_ms=cfg.min_duration_ms,validate_every=cfg.validate_every,check_fast=case.check_fast})
                            result.warmup={elapsed_s=warm.elapsed_s,success=warm.success,full_checks=warm.full_checks}
                            if timed_out then return end
                            if not result.error and case.writes_per_request then
                                local valid,err=pcall(cases.check_writes,admin,prefix,result.success*case.writes_per_request,common,
                                    result.worker_success,case.writes_per_request)
                                if not valid then result.error=tostring(err); result.errors=result.errors+1 end
                            end
                            record(result,api,case,round,position)
                            moon.info(("RUN %-6s %-12s %-5s round=%d req/s=%.1f p50=%.3f p95=%.3f p99=%.3f max=%.3fms errors=%d")
                                :format(profile.name,case.name,name,round,result.requests_per_s,result.p50_ms,result.p95_ms,result.p99_ms,result.max_ms,result.errors))
                            assert(not result.error,result.error)
                        end
                    end
                    compare(profile.name,case)
                end
            end
            admin:write('DROP SCHEMA "'..schema..'" CASCADE')
            schemas[#schemas]=nil
            for _, api in pairs(pools) do api:close() end
            save()
        end
    end)
    if timed_out then return end -- do not overwrite the timeout report or resume cleanup after exit

    -- Only our generated schema names are cleanup targets; never clear an existing database/table.
    for i=#schemas,1,-1 do
        if timed_out then return end
        local schema=schemas[i]
        local cleaned,err=pcall(function() admin:write('DROP SCHEMA "'..schema..'" CASCADE') end)
        if cleaned then table.remove(schemas,i)
        else report.cleanup_errors[#report.cleanup_errors+1]=common.redact(err,cfg) end
    end
    for _, api in ipairs(resources) do
        if timed_out then return end
        local closed,err=pcall(api.close,api)
        if not closed then report.cleanup_errors[#report.cleanup_errors+1]=common.redact(err,cfg) end
    end
    if admin then
        local closed,err=pcall(admin.close,admin)
        if not closed then report.cleanup_errors[#report.cleanup_errors+1]=common.redact(err,cfg) end
    end
    if timed_out then return end
    report.status=ok and #report.cleanup_errors==0 and "complete" or "failed"
    report.error=not ok and common.redact(failure,cfg) or nil
    report.remaining_schemas=schemas
    report.finished_utc=os.date("!%Y-%m-%dT%H:%M:%SZ")
    finished=true
    local written,err=save_final()
    if report.status=="complete" and written then
        moon.info("PG benchmark complete",output)
        if html_output then moon.info("Open HTML report",html_output) end
        moon.exit(0)
    else
        moon.error("Benchmark invalid/failed; do not use partial results to select a winner",
            report.error or "cleanup/report failure",written and output or common.redact(err,cfg),table.concat(schemas,","))
        moon.exit(1)
    end
end)
