-- Closed-loop mixed load; bounded histograms, no per-request sample retention.
-- Inject Moon, workloads and callbacks for offline scheduling/failure tests.
local M={}
function M.run(moon, common, cfg, api, workloads, duration_ms, on_sample, cancelled)
    local selected,total_weight={},0
    for _,w in ipairs(cfg.workload) do
        local found
        for _,case in ipairs(workloads) do if case.name==w.name then found=case; break end end
        assert(found,"workload not implemented: "..w.name)
        total_weight=total_weight+w.weight
        selected[#selected+1]={case=found,ceiling=total_weight,hist=common.histogram(),attempted=0,errors=0,sql=0}
    end
    local histogram,window=common.histogram(),common.histogram()
    local workers,acknowledged={},{}
    local attempted,errors,request_errors,validation_errors,done,active,peak,sql=0,0,0,0,0,0,0,0
    local full_checks,validation_s,window_errors=0,0,0
    local stopped,finished,failure=false,nil,nil
    local error_details={}
    local started,stop_at,last_sample
    local function failed(message,kind,item,id,worker,latency)
        errors=errors+1; window_errors=window_errors+1
        if kind=="validation" then validation_errors=validation_errors+1 else request_errors=request_errors+1 end
        if item then item.errors=item.errors+1 end
        local text=common.redact(message,cfg):sub(1,4096)
        failure=failure or text
        if #error_details<cfg.error_samples then
            error_details[#error_details+1]={message=text,kind=kind,case=item and item.case.name or "worker",request_id=id,worker=worker,latency_ms=latency}
        end
        if cfg.stop_on_error or kind=="worker" then stopped=true end
    end
    for w=1,cfg.concurrency do
        acknowledged[w]=0
        workers[w]=moon.async(function()
            moon.wait() -- all workers start at the same barrier
            local ok,err=pcall(function()
                local random=(cfg.seed+w*104729)%2147483646+1
                local counts={}
                while not stopped and not cancelled() and moon.clock()<stop_at do
                    random=(random*48271)%2147483647
                    local ticket=random%total_weight+1
                    local item
                    for _,choice in ipairs(selected) do if ticket<=choice.ceiling then item=choice; break end end
                    local case=item.case
                    counts[case.name]=(counts[case.name] or 0)+1
                    attempted=attempted+1; item.attempted=item.attempted+1
                    local id=attempted
                    active=active+1; peak=math.max(peak,active)
                    local begin=moon.clock()
                    local valid,result=pcall(case.request,api,id,w)
                    local ended=moon.clock()
                    active=active-1
                    local latency=(ended-begin)*1000
                    local kind="request"
                    if valid then
                        kind="validation"
                        local full=not case.check_fast or (counts[case.name]-1)%cfg.validate_every==0
                        if full then full_checks=full_checks+1 end
                        valid,result=pcall(full and case.check or case.check_fast,result,id,w)
                        validation_s=validation_s+moon.clock()-ended
                    end
                    if valid then
                        histogram:add(latency); window:add(latency); item.hist:add(latency)
                        sql=sql+case.sql_per_request; item.sql=item.sql+case.sql_per_request
                        acknowledged[w]=acknowledged[w]+(case.writes_per_request or 0)
                    else failed(result,kind,item,id,w,latency) end
                    -- Never replay a failed/unknown write. Optional think time is not a retry delay.
                    if cfg.think_ms>0 then moon.sleep(cfg.think_ms) end
                end
            end)
            if not ok then failed(err,"worker",nil,nil,w); stopped=true end
            done=done+1
            if done==cfg.concurrency then finished=moon.clock() end
        end)
    end
    started=moon.clock(); stop_at=started+duration_ms/1000; last_sample=started
    for _,co in ipairs(workers) do moon.wakeup(co) end
    local recording_error
    local function emit(now)
        if now<=last_sample then return end
        local sample=window:finish()
        sample.elapsed_s=now-last_sample; sample.offset_s=now-started
        sample.requests_per_s=sample.elapsed_s>0 and sample.success/sample.elapsed_s or 0
        sample.errors=window_errors; sample.inflight=active; sample.attempted=attempted
        window=common.histogram(); window_errors=0; last_sample=now
        -- Snapshot before a possibly yielding observer: subsequent requests go
        -- into the next window, and sampled totals cannot change underneath it.
        if on_sample and not recording_error then
            local ok,err=pcall(on_sample,sample)
            if not ok then recording_error=tostring(err); stopped=true end
        end
    end
    while done<cfg.concurrency do
        local remaining=(stop_at-moon.clock())*1000
        moon.sleep(remaining>0 and math.max(1,math.min(cfg.sample_ms,math.ceil(remaining))) or cfg.sample_ms)
        if cancelled() then return nil end
        emit(finished or moon.clock())
    end
    emit(finished) -- workers may finish while the previous observer is yielding
    local result=histogram:finish()
    result.elapsed_s=finished-started
    result.requests_per_s=result.elapsed_s>0 and result.success/result.elapsed_s or 0
    result.attempted=attempted; result.errors=errors
    result.request_errors=request_errors; result.validation_errors=validation_errors
    result.error=failure; result.error_details=error_details; result.recording_error=recording_error
    result.worker_writes=acknowledged; result.sql_statements=sql
    result.sql_statements_per_s=result.elapsed_s>0 and sql/result.elapsed_s or 0
    result.validation_wall_pct=result.elapsed_s>0 and validation_s/result.elapsed_s*100 or 0
    result.full_checks=full_checks; result.peak_inflight=peak; result.concurrency=cfg.concurrency
    result.duration_ms=duration_ms; result.stopped_early=stopped; result.cases={}
    for _,item in ipairs(selected) do
        local stats=item.hist:finish()
        stats.name=item.case.name; stats.attempted=item.attempted; stats.errors=item.errors
        stats.requests_per_s=result.elapsed_s>0 and stats.success/result.elapsed_s or 0
        stats.sql_statements=item.sql
        result.cases[#result.cases+1]=stats
    end
    return result
end
return M
