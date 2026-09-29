-- Diagnostic-only configuration. Keep the established stress/A-B tests unchanged.
local M={}
local shared={"allow_write","host","port","database","user","password","sslmode","sslrootcert","sslcert","sslkey",
    "threads","driver_thread","enable_stdout","loglevel","run_label","cache","timeout_ms","data_rows","rows","bytes",
    "tx_size","validate_every","deadline_ms","warmup_ms","idle_ms","think_ms","seed","workload","sample_ms","checkpoint_ms"}
local extra={"pool_sizes","sweep_concurrency","sweep_duration_ms","compare_poolsize","compare_concurrency",
    "compare_duration_ms","pg_stats","monitor_timeout_ms","moon_executable_windows","moon_executable_linux",
    "output_directory","monitor","runtime","shutdown_grace_ms"}
local function integer(n,label,minimum,maximum)
    assert(math.type(n)=="integer" and n>=minimum and n<=maximum,label.." out of range")
end
function M.prepare(raw,root,common,stress)
    local allowed={}
    for _,list in ipairs({shared,extra}) do for _,k in ipairs(list) do allowed[k]=true end end
    for k in pairs(raw) do assert(allowed[k],"unknown diagnostic config: "..tostring(k)) end
    for _,k in ipairs({"sweep_concurrency","compare_concurrency"}) do integer(raw[k],k,1,65535) end
    integer(raw.compare_poolsize,"compare_poolsize",1,1024)
    assert(raw.compare_concurrency<=raw.compare_poolsize,"A/B concurrency must be <= compare_poolsize; avoid queue-policy differences")
    for _,k in ipairs({"sweep_duration_ms","compare_duration_ms","monitor_timeout_ms"}) do integer(raw[k],k,1,2147483647) end
    assert(type(raw.pg_stats)=="boolean","pg_stats must be boolean")
    assert(type(raw.pool_sizes)=="table" and #raw.pool_sizes>0 and #raw.pool_sizes<=8,"pool_sizes must have 1..8 entries")
    local seen,count={},0
    for i,n in pairs(raw.pool_sizes) do
        integer(i,"pool_sizes index",1,#raw.pool_sizes); integer(n,"pool size",1,1024)
        assert(not seen[n],"duplicate pool size"); seen[n]=true; count=count+1
    end
    assert(count==#raw.pool_sizes,"pool_sizes must be dense")
    for _,w in ipairs(raw.workload) do assert(w.name~="hot_lane","hot_lane is excluded from the common A/B workload") end
    local plan={}
    local function add(group,mode,pool,concurrency,ms,round)
        plan[#plan+1]={name=("%02d_%s_%s_p%d_r%d"):format(#plan+1,group,mode,pool,round),
            group=group,mode=mode,poolsize=pool,concurrency=concurrency,duration_ms=ms,round=round}
    end
    for _,n in ipairs(raw.pool_sizes) do add("pool","driver",n,raw.sweep_concurrency,raw.sweep_duration_ms,1) end
    for i=#raw.pool_sizes,1,-1 do add("pool","driver",raw.pool_sizes[i],raw.sweep_concurrency,raw.sweep_duration_ms,2) end
    for i,mode in ipairs({"direct","driver","driver","direct"}) do
        add("api",mode,raw.compare_poolsize,raw.compare_concurrency,raw.compare_duration_ms,math.ceil(i/2))
    end
    local configs,planned={},raw.idle_ms
    for _,spec in ipairs(plan) do
        local c={}
        for _,k in ipairs(shared) do c[k]=raw[k] end
        c.mode=spec.mode; c.poolsize=spec.poolsize
        c.stages={{name=spec.name,concurrency=spec.concurrency,duration_ms=spec.duration_ms}}
        c.collect_at_idle=true; c.fifo_check=false; c.stop_on_error=true; c.error_samples=10
        c.sample_driver=true; c.log_progress=true; c.max_samples=100000
        c.min_stage_qps=0; c.max_stage_p99_ms=0; c.output=""; c.html_report=false; c.html_output=""
        configs[#configs+1]=stress.prepare(c,root,common)
        planned=planned+spec.duration_ms+raw.warmup_ms
    end
    assert(planned<raw.deadline_ms,"deadline_ms must reserve time beyond the complete diagnostic plan")
    return plan,configs,planned
end
function M.public(raw)
    local c={}
    for k,v in pairs(raw) do if k~="password" and k~="sslkey" and k~="runtime" then c[k]=v end end
    return c
end
return M
