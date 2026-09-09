-- Pure validation and explicit mapping to the established PG benchmark helpers.
local M = {}
local shared = {"allow_write","host","port","database","user","password","sslmode","sslrootcert","sslcert","sslkey",
    "threads","driver_thread","enable_stdout","loglevel","run_label","mode","poolsize","cache","timeout_ms",
    "data_rows","rows","bytes","tx_size","validate_every","deadline_ms","output","html_report","html_output"}
local extra = {"stages","warmup_ms","idle_ms","collect_at_idle","think_ms","seed","workload","fifo_check","stop_on_error",
    "error_samples","sample_ms","sample_driver","checkpoint_ms","log_progress","max_samples","min_stage_qps","max_stage_p99_ms"}
local known = {tiny=true,point=true,mixed_rows=true,bytea=true,bytea_send=true,bytea_read=true,json_array=true,
    write=true,transaction=true,batch=true,hot_lane=true}
local function integer(v, label, lo, hi)
    assert(math.type(v)=="integer" and v>=lo and v<=hi, label.." is out of range")
    return v
end
local function array(t, label)
    assert(type(t)=="table" and #t>0, label.." must be a nonempty dense array")
    local count=0
    for k in pairs(t) do integer(k,label.." index",1,#t); count=count+1 end
    assert(count==#t,label.." must be a dense array")
end
function M.prepare(raw, root, common)
    local allowed={}
    for _,list in ipairs({shared,extra}) do for _,k in ipairs(list) do allowed[k]=true end end
    for k in pairs(raw) do assert(allowed[k],"unknown SQLx stress config: "..tostring(k)) end
    assert(raw.mode=="driver" or raw.mode=="direct","mode must be driver or direct")
    array(raw.stages,"stages"); array(raw.workload,"workload")
    local maximum,planned,samples,names=0,0,0,{}
    integer(raw.sample_ms,"sample_ms",100,2147483647)
    integer(raw.deadline_ms,"deadline_ms",1,2147483647)
    for _,s in ipairs(raw.stages) do
        assert(type(s)=="table","stage must be a table")
        for k in pairs(s) do assert(k=="name" or k=="concurrency" or k=="duration_ms","unknown stage field") end
        assert(type(s.name)=="string" and s.name~="" and not names[s.name],"stage names must be nonempty and unique")
        names[s.name]=true
        maximum=math.max(maximum,integer(s.concurrency,"stage.concurrency",1,65535))
        planned=planned+integer(s.duration_ms,"stage.duration_ms",1,2147483647)
        samples=samples+math.ceil(s.duration_ms/raw.sample_ms)+2
    end
    for _,k in ipairs({"warmup_ms","idle_ms","think_ms"}) do integer(raw[k],k,0,2147483647) end
    integer(raw.seed,"seed",1,2147483646)
    integer(raw.error_samples,"error_samples",0,10000)
    integer(raw.max_samples,"max_samples",1,1000000)
    integer(raw.checkpoint_ms,"checkpoint_ms",raw.sample_ms,2147483647)
    for _,k in ipairs({"collect_at_idle","fifo_check","stop_on_error","sample_driver","log_progress"}) do
        assert(type(raw[k])=="boolean",k.." must be boolean")
    end
    for _,k in ipairs({"min_stage_qps","max_stage_p99_ms"}) do
        assert(type(raw[k])=="number" and raw[k]>=0 and raw[k]<math.huge,k.." must be finite and nonnegative")
    end
    names={}
    for _,w in ipairs(raw.workload) do
        assert(type(w)=="table" and known[w.name] and not names[w.name],"unknown or duplicate workload")
        for k in pairs(w) do assert(k=="name" or k=="weight","unknown workload field") end
        assert(w.name~="hot_lane" or raw.mode=="driver","hot_lane requires driver mode")
        names[w.name]=true; integer(w.weight,"workload.weight",1,1000000)
    end
    planned=planned+#raw.stages*raw.warmup_ms+raw.idle_ms
    assert(planned<raw.deadline_ms,"deadline_ms is shorter than the warmup/load/idle plan; reserve time for setup and drain")
    assert(samples+math.ceil(raw.idle_ms/raw.sample_ms)+#raw.stages+2<=raw.max_samples,"max_samples is too small for the configured plan")
    local proxy={}
    for _,k in ipairs(shared) do proxy[k]=raw[k] end
    -- Unused A/B knobs are not stress-test settings; only reuse validation/URL construction.
    proxy.implementation="sqlx"; proxy.library=""; proxy.concurrency=maximum; proxy.driver_concurrencies={}
    proxy.rounds=1; proxy.iterations=100; proxy.bulk_iterations=1; proxy.warmup=1
    proxy.min_duration_ms=0; proxy.warmup_duration_ms=0; proxy.cases={}
    local cfg=common.config(proxy,root)
    for _,k in ipairs(extra) do cfg[k]=raw[k] end
    cfg.mode=raw.mode; cfg.planned_ms=planned
    cfg.url=cfg.url:gsub("application_name=moon_pg_benchmark","application_name=moon_sqlx_stress")
    return cfg
end
function M.public(raw)
    local out={}
    for _,list in ipairs({shared,extra}) do
        for _,k in ipairs(list) do
            if k~="password" and k~="sslkey" then out[k]=raw[k] end
        end
    end
    return out
end
return M
