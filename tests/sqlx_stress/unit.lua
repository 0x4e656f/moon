-- Offline only: independent fixtures, fake scheduler/API, real report serializer.
local fixtures=dofile("tests/sqlx_stress/fixtures.lua")
local common=dofile("example/pg_bench/common.lua")
local settings=dofile("example/sqlx_stress/settings.lua")
local runner=dofile("example/sqlx_stress/runner.lua")
local reports=dofile("example/sqlx_stress/report.lua")
local checks=0
local function eq(a,b) checks=checks+1; assert(a==b,tostring(a).." ~= "..tostring(b)) end
local function fails(fn) eq(pcall(fn),false) end
for _,path in ipairs({"example/stress_sqlx_pg.lua","example/sqlx_stress/config.lua","example/sqlx_stress/settings.lua",
    "example/sqlx_stress/runner.lua","example/sqlx_stress/report.lua"}) do assert(loadfile(path)) end
local cfg=settings.prepare(fixtures.config(),"/repo",common)
eq(cfg.concurrency,4); eq(cfg.mode,"driver"); eq(cfg.output,"/repo/target/not-written.json")
eq(cfg.implementations[1],"sqlx"); eq(cfg.url:find("moon_sqlx_stress",1,true)~=nil,true)
eq(settings.public(fixtures.config()).password,nil)
for _,edit in ipairs({function(c)c.allow_write=false end,function(c)c.mode="both" end,
    function(c)c.stages[2].name="base" end,function(c)c.stages[1].concurrency=0 end,
    function(c)c.stages[4]=c.stages[1] end,function(c)c.workload[1].name="other" end,
    function(c)c.workload[1].weight=0 end,function(c)c.mode="direct" end,
    function(c)c.max_samples=1 end,function(c)c.checkpoint_ms=1 end,
    function(c)c.deadline_ms=700 end,function(c)c.sample_driver="yes" end,
    function(c)c.min_stage_qps=0/0 end,function(c)c.invalid=true end}) do
    local raw=fixtures.config(); edit(raw); fails(function() settings.prepare(raw,"/repo",common) end)
end
local function run(options)
    options=options or {}
    local c=settings.prepare(fixtures.config(),"/repo",common)
    c.concurrency=4; c.workload={{name="write",weight=1}}; c.stop_on_error=not options.keep_going
    local moon=fixtures.scheduler()
    local active,peak,submitted,committed=0,0,0,{}
    local results,samples
    local work={{name="write",writes_per_request=2,sql_per_request=2,
        request=function(_,i,w)
            submitted=submitted+1; active=active+1; peak=math.max(peak,active)
            moon.sleep(options.slow and 400 or 7)
            active=active-1
            if options.error and i%3==0 then error("fixture-secret injected error") end
            committed[w]=(committed[w] or 0)+2
            return i
        end,
        check=function(v,i) if options.bad_result and i==2 then error("invalid result") end; eq(v,i) end}}
    samples={}
    moon.async(function()
        results=runner.run(moon,common,c,{},work,250,function(s)
            samples[#samples+1]=s
            if options.sampling_error then error("observer failed") end
            if options.yield_observer then moon.sleep(25) end
        end,function() return false end)
    end)
    moon.drain()
    eq(active,0); eq(peak,4); eq(results.attempted,submitted)
    eq(results.success+results.errors,submitted)
    local sum,errors=0,0; for _,s in ipairs(samples) do sum=sum+s.success; errors=errors+s.errors end
    if not options.sampling_error then eq(sum,results.success); eq(errors,results.errors) end
    if options.sampling_error then eq(results.recording_error:find("observer failed",1,true)~=nil,true)
    elseif options.error or options.bad_result then
        eq(results.errors>0,true); eq(#results.error_details<=c.error_samples,true)
        eq(results.error:find("fixture-secret",1,true),nil)
        if options.keep_going then eq(results.elapsed_s>=.25,true) else eq(results.elapsed_s<.25,true) end
    else
        eq(results.errors,0); eq(results.elapsed_s>=.25,true)
        eq(results.sql_statements,2*results.success)
        for w,n in ipairs(results.worker_writes) do eq(n,committed[w]) end
    end
    return results,samples
end
local result,samples=run()
run({yield_observer=true}); run({slow=true}); run({error=true}); run({error=true,keep_going=true})
run({bad_result=true}); run({sampling_error=true})

local report={format="moon_sqlx_stress",format_version=1,sample=true,status="complete",elapsed_s=2,
    started_utc="2026-01-01T00:00:00Z",finished_utc="2026-01-01T00:00:02Z",
    config=settings.public(fixtures.config()),stages={},samples=samples,checks={{name="fixture",passed=true}},cleanup_errors={},remaining_schemas={}}
for _,spec in ipairs(report.config.stages) do report.stages[#report.stages+1]={name=spec.name,status="complete",concurrency=4,result=result} end
for i,s in ipairs(samples) do s.time_s=i*.1; s.resources={caller_lua_kib=100+i,driver_lua_kib=80,waiting=i,ready=0,driver_queue=i} end
local html=reports.render(report)
for _,word in ipairs({"配置内验收通过","模拟样例，非数据库实测","窗口吞吐","不是进程 RSS","<svg","Content-Security-Policy"}) do eq(html:find(word,1,true)~=nil,true) end
eq(html:find("<script",1,true),nil)
local tags={}
for close,name,tail in html:gmatch("<(/?)([%a][%w]*)([^>]*)>") do
    if close=="/" then eq(table.remove(tags),name)
    elseif name~="meta" and not tail:match("/%s*$") then tags[#tags+1]=name end
end
eq(#tags,0)
report.error="<script>alert('x')</script>"
html=reports.render(report); eq(html:find("&lt;script&gt;",1,true)~=nil,true); eq(html:find("配置内验收通过",1,true),nil)
report.error=nil
local function filesystem(options)
    options=options or {}; local fs={files={},writes=0}
    function fs.open(path,mode)
        if mode=="rb" then return fs.files[path] and {close=function() end} or nil end
        if options.open==path then return nil,"permission denied" end
        return {write=function(self,content)
            if options.disk then return nil,"disk full" end
            fs.files[path]=content; fs.writes=fs.writes+1; return self
        end,close=function() return not options.close,"flush failed" end}
    end
    return fs
end
local fs=filesystem()
reports.writer("/a.json","/a.html",function() return "JSON" end,fs):save(report,true)
eq(fs.files["/a.json"],"JSON"); eq(fs.files["/a.html"]:find("<svg",1,true)~=nil,true)
fails(function() reports.writer("/a.json","/x.html",function() end,fs) end)
fails(function() reports.writer("/a.json","/b/../a.json",function() end,filesystem()) end)
for _,option in ipairs({{open="/a.html"},{disk=true},{close=true}}) do
    fails(function() reports.writer("/a.json","/a.html",function() return "JSON" end,filesystem(option)):save(report,true) end)
end
local stem=("target/sqlx_stress_preview_%d_%06x"):format(os.time(),math.random(0,0xffffff))
reports.writer(stem..".json",stem..".html",require("json").encode):save(report,true)
print(("SQLx stress offline checks passed (%d assertions; no Moon/DB/network)"):format(checks))
print("HTML_PREVIEW="..stem..".html")
