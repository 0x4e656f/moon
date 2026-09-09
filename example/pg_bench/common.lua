-- Pure configuration/statistics helpers; no Moon, database, or filesystem side effects.
local M = {}

local function positive(config, name, zero)
    local n = config[name]
    assert(math.type(n) == "integer" and n >= (zero and 0 or 1), "config." .. name .. " must be an integer in range")
    return n
end
local function selection(value, choices)
    if value == "both" then return choices end
    for _, choice in ipairs(choices) do if value == choice then return {choice} end end
    error("invalid benchmark selection: " .. tostring(value))
end
function M.url_escape(value)
    return (tostring(value):gsub("([^%w%-%._~])", function(c) return ("%%%02X"):format(c:byte()) end))
end

--- Startup settings are read before Moon initializes; defaults live only in config.lua.
function M.bootstrap(config)
    assert(type(config)=="table", "benchmark config.lua must return a table")
    local threads=positive(config,"threads")
    assert(threads>=2,"config.threads must be >= 2")
    assert(threads<=255,"config.threads must be <= 255 (Moon worker ID limit)")
    local driver=positive(config,"driver_thread")
    assert(driver>=2 and driver<=threads,"config.driver_thread must be between 2 and threads")
    assert(type(config.enable_stdout)=="boolean","config.enable_stdout must be boolean")
    assert(({DEBUG=true,INFO=true,WARN=true,ERROR=true})[config.loglevel],"invalid config.loglevel")
    return {thread=threads,enable_stdout=config.enable_stdout,loglevel=config.loglevel}
end

--- Resolve optional paths independently of Moon's change to the bootstrap working directory.
function M.path(root,value)
    if value==nil or value=="" then return nil end
    assert(type(value)=="string","config paths must be strings")
    value=value:gsub("\\","/")
    assert(not value:match("^%a:") or value:match("^%a:/"),"drive-relative paths are not supported; use an absolute path")
    if not root or value:match("^%a:/") or value:sub(1,1)=="/" then return value end
    return root.."/"..value
end

--- Validate the explicit config table; no environment fallback or independent backend URLs.
function M.config(config,root)
    M.bootstrap(config)
    local allowed={allow_write=true,host=true,port=true,database=true,user=true,password=true,
        sslmode=true,sslrootcert=true,sslcert=true,sslkey=true,library=true,
        threads=true,driver_thread=true,enable_stdout=true,loglevel=true,
        mode=true,implementation=true,poolsize=true,concurrency=true,cache=true,
        rounds=true,iterations=true,bulk_iterations=true,warmup=true,rows=true,data_rows=true,
        bytes=true,tx_size=true,cases=true,timeout_ms=true,deadline_ms=true,output=true,
        html_report=true,html_output=true,min_duration_ms=true,warmup_duration_ms=true,
        validate_every=true,driver_concurrencies=true,run_label=true}
    for name in pairs(config) do assert(allowed[name],"unknown benchmark config field: "..tostring(name)) end
    for _,name in ipairs({"host","database","user","password","sslmode"}) do
        assert(type(config[name])=="string","config."..name.." must be a string")
    end
    local c = {
        host=config.host, port=positive(config,"port"), database=config.database,
        user=config.user, password=config.password, sslmode=config.sslmode,
        threads=config.threads, driver_thread=config.driver_thread,
        enable_stdout=config.enable_stdout, loglevel=config.loglevel,
        poolsize=positive(config,"poolsize"), iterations=positive(config,"iterations"),
        bulk_iterations=positive(config,"bulk_iterations"),
        rounds=positive(config,"rounds"), warmup=positive(config,"warmup"),
        min_duration_ms=positive(config,"min_duration_ms",true),
        warmup_duration_ms=positive(config,"warmup_duration_ms",true),
        validate_every=positive(config,"validate_every"),
        rows=positive(config,"rows"), data_rows=positive(config,"data_rows"),
        bytes=positive(config,"bytes"), tx_size=positive(config,"tx_size"),
        cache=positive(config,"cache",true), timeout=positive(config,"timeout_ms"),
        deadline=positive(config,"deadline_ms"),
        modes=selection(config.mode,{"direct","driver"}),
        implementations=selection(config.implementation,{"libpq","sqlx"}),
    }
    for _,name in ipairs({"sslrootcert","sslcert","sslkey","library","output","html_output"}) do c[name]=M.path(root,config[name]) end
    assert(type(config.html_report)=="boolean","config.html_report must be boolean")
    c.html_report=config.html_report
    assert(config.allow_write==true, "set allow_write=true in config.lua; benchmark creates/drops its own schema and writes test data")
    assert(c.database~="" and c.user~="", "set database and user in config.lua for a dedicated test database")
    assert(c.port <= 65535 and c.poolsize <= 1024, "invalid port/poolsize")
    assert(c.host ~= "" and not c.host:find("[,/@%s%[%]]"),
        "config.host must be a single TCP hostname or unbracketed IP, not a URL or socket")
    assert(({disable=true,require=true,["verify-ca"]=true,["verify-full"]=true})[c.sslmode],
        "config.sslmode must be disable/require/verify-ca/verify-full (no TLS fallback)")
    c.concurrency=positive(config,"concurrency",true)
    if c.concurrency==0 then c.concurrency=c.poolsize end
    for _, mode in ipairs(c.modes) do
        assert(mode ~= "direct" or c.concurrency <= c.poolsize,
            "direct mode requires concurrency <= poolsize; use driver mode to measure queueing")
    end
    assert(c.data_rows >= c.rows, "config.data_rows must be >= rows")
    assert(c.timeout <= 2147483647 and c.deadline <= 2147483647, "timeout/deadline exceeds timer range")
    assert(c.min_duration_ms<c.deadline and c.warmup_duration_ms<c.deadline,
        "measurement/warmup duration must be less than deadline_ms")
    assert(type(config.run_label)=="string","config.run_label must be a string")
    c.run_label=config.run_label
    assert(type(config.driver_concurrencies)=="table","config.driver_concurrencies must be a dense array")
    c.driver_concurrencies={}
    local seen_concurrency,nc={},0
    for index,n in pairs(config.driver_concurrencies) do
        assert(math.type(index)=="integer" and index>=1 and index<=#config.driver_concurrencies,
            "config.driver_concurrencies must be a dense array")
        assert(math.type(n)=="integer" and n>0 and not seen_concurrency[n] and n~=c.concurrency,
            "driver_concurrencies must contain distinct positive integers different from concurrency")
        seen_concurrency[n]=true; nc=nc+1; c.driver_concurrencies[index]=n
    end
    assert(nc==#config.driver_concurrencies,"config.driver_concurrencies must be a dense array")
    assert(type(config.cases)=="table","config.cases must be an array of case names; {} selects all")
    local selected,seen,count={},{},0
    for index,name in pairs(config.cases) do
        assert(math.type(index)=="integer" and index>=1 and index<=#config.cases,"config.cases must be a dense array")
        assert(type(name)=="string" and name~="" and not seen[name],"config.cases must contain unique nonempty names")
        selected[index]=name; seen[name]=true; count=count+1
    end
    assert(count==#config.cases,"config.cases must be a dense array")
    c.cases=count>0 and selected or nil
    c.options="-c timezone=UTC -c datestyle=ISO,YMD -c bytea_output=hex"
        .. " -c statement_timeout=" .. c.timeout .. " -c lock_timeout=" .. c.timeout
    local host=c.host:find(":",1,true) and ("["..c.host.."]") or c.host
    local auth=M.url_escape(c.user) .. (c.password and ":"..M.url_escape(c.password) or "")
    local query={"sslmode="..M.url_escape(c.sslmode), "statement-cache-capacity="..c.cache,
        "options="..M.url_escape(c.options), "application_name=moon_pg_benchmark"}
    for _, k in ipairs({"sslrootcert","sslcert","sslkey"}) do
        if c[k] then query[#query+1]=k.."="..M.url_escape(c[k]) end
    end
    c.url=("postgresql://%s@%s:%d/%s?%s"):format(auth,host,c.port,M.url_escape(c.database),table.concat(query,"&"))
    return c
end

--- Each extra driver concurrency is a separate group with new pools and test data.
function M.profiles(cfg)
    local profiles={}
    for _,mode in ipairs(cfg.modes) do
        profiles[#profiles+1]={name=mode,mode=mode,concurrency=cfg.concurrency}
        if mode=="driver" then
            for _,n in ipairs(cfg.driver_concurrencies) do
                profiles[#profiles+1]={name="driver_c"..n,mode=mode,concurrency=n}
            end
        end
    end
    return profiles
end

function M.redact(message, cfg)
    local s=tostring(message):gsub("postgres[%w]*://[^%s]+", "<redacted PostgreSQL URL>")
    if cfg.password and cfg.password ~= "" then
        for _, value in ipairs({cfg.password,M.url_escape(cfg.password)}) do
            s=s:gsub(value:gsub("([^%w])","%%%1"),"<redacted>")
        end
    end
    return s
end
function M.ok(result)
    assert(type(result)=="table", "database returned no result table")
    if result.code or result.kind then
        error((result.code or result.kind).." "..(result.sqlstate or "").." "..(result.message or "database error"), 2)
    end
    return result
end
function M.equal(actual, expected, label)
    assert(actual==expected and type(actual)==type(expected), label or "result mismatch")
    if math.type(expected)=="integer" then assert(math.type(actual)=="integer", "integer precision/type lost") end
end
function M.quantile(sorted, q)
    if #sorted==0 then return 0 end
    return sorted[math.max(1,math.ceil(#sorted*q))]
end
function M.median(values)
    local sorted={table.unpack(values)}; table.sort(sorted)
    if #sorted==0 then return 0 end
    local mid=math.floor(#sorted/2)+1
    return #sorted%2==1 and sorted[mid] or (sorted[mid-1]+sorted[mid])/2
end
function M.summary(samples, elapsed, attempted, errors)
    table.sort(samples)
    local sum=0; for _, ms in ipairs(samples) do sum=sum+ms end
    return {elapsed_s=elapsed, attempted=attempted, success=#samples, errors=errors,
        requests_per_s=elapsed>0 and #samples/elapsed or 0,
        mean_ms=#samples>0 and sum/#samples or 0,
        p50_ms=M.quantile(samples,.50),p95_ms=M.quantile(samples,.95),p99_ms=M.quantile(samples,.99),
        max_ms=samples[#samples] or 0}
end

-- Bounded logarithmic histogram: upper-bound quantiles, <= 1% rounding (or 1 ns).
-- No per-request latency array, sorting, random sampling or GC growth on long runs.
function M.histogram()
    local bins,count,sum,maximum={},0,0,0
    local base,log_step=0.000001,math.log(1.01) -- milliseconds; 1 ns minimum bucket
    local function boundary(index) return index==0 and 0 or base*math.exp((index-1)*log_step) end
    return {
        add=function(_,ms)
            assert(ms>=0 and ms<math.huge,"non-finite or negative request latency")
            local index=ms==0 and 0 or math.max(1,math.ceil(math.log(ms/base)/log_step)+1)
            bins[index]=(bins[index] or 0)+1; count=count+1; sum=sum+ms; maximum=math.max(maximum,ms)
        end,
        finish=function()
            local keys={}; for index in pairs(bins) do keys[#keys+1]=index end; table.sort(keys)
            local function quantile(q)
                local rank,seen=math.ceil(count*q),0
                if count==0 then return 0 end
                for _,index in ipairs(keys) do
                    seen=seen+bins[index]
                    if seen>=rank then return math.min(maximum,boundary(index)) end
                end
            end
            return {success=count,mean_ms=count>0 and sum/count or 0,max_ms=maximum,
                p50_ms=quantile(.50),p95_ms=quantile(.95),p99_ms=quantile(.99),
                latency_method="log_histogram_1pct_1ns",histogram_buckets=#keys}
        end,
    }
end

--- Descriptive paired-round ratios; ranges and CV are NOT significance tests.
function M.compare(groups)
    local summary,by_round={},{}
    for _,name in ipairs({"libpq","sqlx"}) do
        local qps,p95,p99,total,elapsed={},{},{},0,0
        by_round[name]={}
        for _,r in ipairs(groups[name]) do
            assert(not by_round[name][r.round],"duplicate measurement round")
            by_round[name][r.round]=r.requests_per_s
            qps[#qps+1]=r.requests_per_s; p95[#p95+1]=r.p95_ms; p99[#p99+1]=r.p99_ms
            total=total+r.success; elapsed=elapsed+r.elapsed_s
        end
        local mean=0; for _,n in ipairs(qps) do mean=mean+n end; mean=mean/#qps
        local variance=0; for _,n in ipairs(qps) do variance=variance+(n-mean)^2 end
        summary[name]={median_requests_per_s=M.median(qps),median_run_p95_ms=M.median(p95),
            median_run_p99_ms=M.median(p99),min_requests_per_s=math.min(table.unpack(qps)),
            max_requests_per_s=math.max(table.unpack(qps)),total_success=total,measured_s=elapsed,
            pooled_requests_per_s=total/elapsed,
            qps_cv_pct=mean>0 and math.sqrt(variance/#qps)/mean*100 or 0}
    end
    local ratios,wins={},0
    for _,r in ipairs(groups.libpq) do
        local b=assert(by_round.sqlx[r.round],"missing paired SQLx round")
        assert(b>0 and r.requests_per_s>0,"zero-duration measurements cannot be compared")
        ratios[#ratios+1]=r.requests_per_s/b
        if r.requests_per_s>b then wins=wins+1 end
    end
    assert(#groups.libpq==#groups.sqlx,"unpaired measurement rounds")
    local a,b=summary.libpq,summary.sqlx
    summary.libpq_over_sqlx=a.median_requests_per_s/b.median_requests_per_s
    summary.paired_ratio_median=M.median(ratios)
    summary.paired_ratio_min=math.min(table.unpack(ratios)); summary.paired_ratio_max=math.max(table.unpack(ratios))
    summary.libpq_faster_rounds=wins; summary.paired_rounds=#ratios
    summary.round_ranges_overlap=a.min_requests_per_s<=b.max_requests_per_s and b.min_requests_per_s<=a.max_requests_per_s
    return summary
end

--- Closed-loop load. Every request waits for its database response; fail fast, drain in-flight work.
--- Latency includes adapter/API/queue/DB/decode, but excludes result validation. Wall throughput
--- includes validation/instrumentation between requests; no fire-and-forget or timeout replay.
function M.run(moon, count, workers, operation, validate, options)
    options=options or {}
    local duration=(options.min_duration_ms or 0)/1000
    local every=options.validate_every or 1
    local waiter=coroutine.running()
    local threads,histogram={},M.histogram()
    local worker_success,worker_attempted={},{}
    local next_id,done,attempted,errors=0,0,0,0
    local failure,finished,started,stop_at
    local validation_s,full_checks,active,peak=0,0,0,0
    for worker=1,workers do
        worker_success[worker]=0; worker_attempted[worker]=0
        threads[worker]=moon.async(function()
            moon.wait() -- start barrier
            while not failure and (next_id<count or moon.clock()<stop_at) do
                next_id=next_id+1
                local id=next_id
                attempted=attempted+1
                worker_attempted[worker]=worker_attempted[worker]+1
                active=active+1; peak=math.max(peak,active)
                local begin=moon.clock()
                local ok,result=pcall(operation,id,worker)
                local ended=moon.clock()
                active=active-1
                if ok then
                    local full=not options.check_fast or (worker_attempted[worker]-1)%every==0
                    if full then full_checks=full_checks+1 end
                    ok,result=pcall(full and validate or options.check_fast,result,id,worker)
                    validation_s=validation_s+(moon.clock()-ended)
                end
                if ok then
                    histogram:add((ended-begin)*1000); worker_success[worker]=worker_success[worker]+1
                else errors=errors+1; failure=failure or tostring(result) end
            end
            done=done+1
            if done==workers then finished=moon.clock(); moon.wakeup(waiter) end
        end)
    end
    started=moon.clock()
    stop_at=started+duration
    for _, thread in ipairs(threads) do moon.wakeup(thread) end
    moon.wait()
    local result=histogram:finish()
    result.elapsed_s=finished-started
    result.attempted=attempted; result.errors=errors
    result.requests_per_s=result.elapsed_s>0 and result.success/result.elapsed_s or 0
    result.target_requests=count; result.min_duration_ms=duration*1000
    result.validation_s=validation_s; result.full_checks=full_checks
    result.validation_wall_pct=result.elapsed_s>0 and validation_s/result.elapsed_s*100 or 0
    result.worker_success=worker_success; result.worker_attempted=worker_attempted
    result.peak_inflight=peak; result.concurrency=workers
    result.error=failure
    return result
end
return M
