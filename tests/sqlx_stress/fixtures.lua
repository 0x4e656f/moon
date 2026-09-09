-- Independent synthetic settings and cooperative clock; never read user credentials.
local M={}
function M.config()
    return {allow_write=true,host="example.invalid",port=5432,database="fixture",user="fixture",password="fixture-secret",
        sslmode="disable",sslrootcert="",sslcert="",sslkey="",threads=4,driver_thread=2,enable_stdout=false,loglevel="INFO",
        run_label="SYNTHETIC",mode="driver",poolsize=2,cache=100,timeout_ms=1000,
        stages={{name="base",concurrency=2,duration_ms=250},{name="load",concurrency=4,duration_ms=400}},
        warmup_ms=120,idle_ms=100,collect_at_idle=true,deadline_ms=5000,think_ms=0,seed=777,
        workload={{name="tiny",weight=1},{name="write",weight=1},{name="transaction",weight=1}},
        data_rows=4,rows=2,bytes=8,tx_size=2,validate_every=3,fifo_check=true,stop_on_error=true,error_samples=2,
        sample_ms=100,sample_driver=true,checkpoint_ms=100,log_progress=true,max_samples=100,min_stage_qps=0,max_stage_p99_ms=0,
        output="target/not-written.json",html_report=true,html_output=""}
end
function M.scheduler()
    local moon={id=123,events={},coroutines={}}
    local now,serial=0,0
    local function enqueue(co,ms,fn)
        serial=serial+1; moon.events[#moon.events+1]={co=co,time=now+ms/1000,serial=serial,fn=fn}
    end
    local function resume(co)
        local ok,err=coroutine.resume(co); assert(ok,err)
    end
    function moon.async(fn)
        local co=coroutine.create(fn); moon.coroutines[#moon.coroutines+1]=co; resume(co); return co
    end
    function moon.clock() return now end
    function moon.wait() return coroutine.yield() end
    function moon.wakeup(co) enqueue(co,0) end
    function moon.sleep(ms) enqueue(coroutine.running(),ms); return coroutine.yield() end
    function moon.timeout(ms,fn) enqueue(nil,ms,fn) end
    function moon.exit(code) moon.exit_code=code end
    function moon.info(...) for _,v in ipairs({...}) do assert(not tostring(v):find("fixture-secret",1,true)) end end
    moon.error=moon.info
    function moon.drain()
        local steps=0
        while #moon.events>0 do
            table.sort(moon.events,function(a,b) return a.time==b.time and a.serial<b.serial or a.time<b.time end)
            local e=table.remove(moon.events,1); now=e.time
            if e.fn then e.fn() else resume(e.co) end
            steps=steps+1; assert(steps<100000,"scheduler failed to terminate")
        end
        for _,co in ipairs(moon.coroutines) do assert(coroutine.status(co)=="dead","orphan coroutine") end
    end
    return moon
end
return M
