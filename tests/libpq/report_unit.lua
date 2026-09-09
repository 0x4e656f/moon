-- Offline report tests. Synthetic values only; never load Moon/config.lua or connect to a database.
local reports=dofile("example/pg_bench/report.lua")
local checks=0
local function eq(a,b) checks=checks+1; assert(a==b,tostring(a).." ~= "..tostring(b)) end
local function contains(text,part) checks=checks+1; assert(text:find(part,1,true),"missing: "..part) end
local function absent(text,part) checks=checks+1; assert(not text:find(part,1,true),"unexpected: "..part) end
local function fails(fn,part)
    local ok,err=pcall(fn); eq(ok,false); if part then contains(tostring(err),part) end
end
local function balanced(html)
    local stack={}
    for closing,name in html:gmatch("<(/?)([%a][%w]*)[^>]*>") do
        if closing=="/" then eq(table.remove(stack),name)
        elseif name~="meta" and name~="br" and name~="hr" then stack[#stack+1]=name end
    end
    eq(#stack,0)
end
local function fixture()
    local report={format_version=1,status="complete",sample=true,
        started_utc="2026-01-01T00:00:00Z",finished_utc="2026-01-01T00:00:30Z",
        config={host="example.invalid",port=5432,database="synthetic_only",user="fixture",sslmode="disable",
            poolsize=4,concurrency=4,cache=100,rounds=3,modes={"direct"},implementations={"libpq","sqlx"},
            cases={"tiny"},iterations=100,bulk_iterations=100,rows=256,tx_size=5,lua="Lua 5.4",moon_threads=4,driver_thread=2},
        runs={},checks={},cleanup_errors={},remaining_schemas={},endpoints={},notes={"SYNTHETIC DATA ONLY"}}
    for round=1,3 do
        for position,impl in ipairs({"libpq","sqlx"}) do
            local multiplier=impl=="libpq" and 1 or .5
            local qps=100*round*multiplier
            report.runs[#report.runs+1]={mode="direct",case="tiny",implementation=impl,phase="measure",round=round,
                position=position,success=100,attempted=100,errors=0,elapsed_s=100/qps,requests_per_s=qps,
                sql_statements_per_s=qps,p50_ms=round*multiplier,p95_ms=round*5*multiplier,
                p99_ms=round*10*multiplier,max_ms=round*12*multiplier}
        end
    end
    return report
end
local good=fixture()
local html=reports.render(good)
contains(html,"<!doctype html>"); contains(html,"模拟样例，非数据库实测")
contains(html,"测量完成"); contains(html,"2.000×"); contains(html,"轮次范围重叠")
contains(html,'<td>200.0</td>'); contains(html,'<td>20.000</td>')
contains(html,"每轮原始统计"); contains(html,"Content-Security-Policy")
contains(html,'style="width:100.0000%"'); contains(html,'style="width:50.0000%"')
absent(html,"<script"); absent(html,"<link"); absent(html," src="); absent(html,"https://")
eq(#good.runs,6); eq(good.runs[1].requests_per_s,100) -- rendering does not sort/mutate caller data

local malicious=fixture()
malicious.config.password="NEVER_RENDER_PASSWORD"
malicious.config.url="NEVER_RENDER_CONNECTION_URL"
malicious.config.database='<img src=x onerror="alert(1)">&'
malicious.notes={'</style><script>alert("unsafe")</script>'}
local escaped=reports.render(malicious)
absent(escaped,"NEVER_RENDER_PASSWORD"); absent(escaped,"NEVER_RENDER_CONNECTION_URL")
absent(escaped,"<img src=x"); absent(escaped,'<script>alert')
contains(escaped,"&lt;img src=x onerror=&quot;alert(1)&quot;&gt;&amp;")
contains(escaped,"&lt;/style&gt;&lt;script&gt;")

local failure=fixture()
failure.status="failed"; failure.error="DB failed <script>bad</script>"
failure.runs[1].errors=1; failure.runs[1].error="TIMEOUT"
failure.cleanup_errors={"cleanup <failed>"}; failure.remaining_schemas={'test_"schema'}
local failed=reports.render(failure)
contains(failed,"数据无效 / 尚未完成"); absent(failed,"测量完成"); absent(failed,"2.000×")
contains(failed,"DB failed &lt;script&gt;bad&lt;/script&gt;"); contains(failed,"TIMEOUT")
contains(failed,"cleanup &lt;failed&gt;"); contains(failed,"test_&quot;schema")
local deadline=fixture(); deadline.status="deadline_exceeded"
contains(reports.render(deadline),"数据无效 / 尚未完成"); absent(reports.render(deadline),"2.000×")
local incomplete=fixture(); table.remove(incomplete.runs)
contains(reports.render(incomplete),"数据无效 / 尚未完成"); absent(reports.render(incomplete),"2.000×")
local partial=fixture(); partial.status="running"
absent(reports.render(partial),"2.000×")
local nonfinite=fixture(); nonfinite.runs[1].p99_ms=math.huge
local invalid=reports.render(nonfinite)
absent(invalid,"width:inf"); absent(invalid,"2.000×"); contains(invalid,"数据无效 / 尚未完成")
local zero=fixture(); for _,run in ipairs(zero.runs) do run.p99_ms=0 end
absent(reports.render(zero),"width:nan"); contains(reports.render(zero),"0.000</span>")
local single=fixture(); single.config.implementations={"libpq"}
single.runs={single.runs[1],single.runs[3],single.runs[5]}
contains(reports.render(single),"测量完成"); absent(reports.render(single),"2.000×")
contains(reports.render(single),"无有效测量轮次")
local empty=reports.render({status="running"})
contains(empty,"尚无请求结果"); absent(empty,"测量完成")
local warm=fixture(); warm.status="failed"; warm.runs={warm.runs[1]}
warm.runs[1].phase="warmup"; warm.runs[1].errors=1; warm.runs[1].error="warmup error"
contains(reports.render(warm),"warmup error"); absent(reports.render(warm),"2.000×")

local v2=fixture()
v2.format_version=2
v2.profiles={{name="direct",mode="direct",concurrency=4,cases={"tiny"}}}
v2.config.min_duration_ms=100; v2.config.warmup_duration_ms=50; v2.config.validate_every=100
v2.config.driver_concurrencies={32}; v2.config.run_label="fixture <build>"
for _,run in ipairs(v2.runs) do
    run.target_requests=10; run.min_duration_ms=100; run.peak_inflight=4; run.full_checks=4
    run.validation_wall_pct=20; run.warmup={elapsed_s=.05}
    run.payload_send_mib_s=123.45; run.payload_receive_mib_s=234.56; run.rows_per_s=123456
    run.warnings={"diagnostic <tag>"}
end
local quality=reports.render(v2)
contains(quality,"测量完成"); contains(quality,"配对轮比值中位数 2.000×")
contains(quality,"libpq 更快 3 / 3 轮"); contains(quality,"吞吐 CV %")
contains(quality,"p99 样本偏少"); contains(quality,"单轮不足 1 秒")
contains(quality,"校验时间 > 10%"); contains(quality,"fixture &lt;build&gt;")
contains(quality,"发送 MiB/s"); contains(quality,"123.45"); contains(quality,"234.56")
contains(quality,"diagnostic &lt;tag&gt;"); contains(quality,"最小 1 ns")
for _,page in ipairs({html,quality,failed,empty,escaped}) do balanced(page) end
local duplicate=fixture(); duplicate.runs[3].round=1
absent(reports.render(duplicate),"2.000×"); contains(reports.render(duplicate),"数据无效 / 尚未完成")
local missing_case=fixture(); missing_case.config.cases={"tiny","point"}
absent(reports.render(missing_case),"2.000×")
v2.profiles[1].cases={"tiny","point"}
absent(reports.render(v2),"2.000×")
v2.profiles[1].cases={"tiny"}; v2.profiles[2]={name="driver_c32",mode="driver",concurrency=32,cases={"tiny"}}
absent(reports.render(v2),"2.000×")
v2.profiles[2]=nil; v2.runs[1].target_requests=101
absent(reports.render(v2),"2.000×")
v2.runs[1].target_requests=10; v2.runs[1].min_duration_ms=1001
absent(reports.render(v2),"2.000×")

eq(reports.html_path("E:/report.JSON"),"E:/report.html")
eq(reports.html_path("/tmp/result"),"/tmp/result.html")
eq(reports.html_path("/tmp/a.json","/tmp/b.html"),"/tmp/b.html")
-- In-memory filesystem: verifies overwrite protection, optional HTML, write/close failure propagation.
local function filesystem(initial,options)
    local fs={files=initial or {},writes=0}; options=options or {}
    function fs.open(path,mode)
        if mode=="rb" then
            if fs.files[path] then return {close=function() return true end} end
            return nil
        end
        if path==options.fail_open then return nil,"permission denied" end
        return {write=function(self,content)
            if options.fail_write then return nil,"disk full" end
            fs.files[path]=content; fs.writes=fs.writes+1; return self
        end,close=function() if options.fail_close then return nil,"flush failed" end; return true end}
    end
    return fs
end
local encode=function(report) return 'JSON:'..report.status end
local fs=filesystem()
local writer=reports.writer("/r.json","/r.html",encode,fs)
writer:save(good,false); eq(fs.writes,1); eq(fs.files["/r.html"],nil)
writer:save(good,true); eq(fs.writes,3); contains(fs.files["/r.html"],"2.000×")
local json_only=filesystem()
reports.writer("/r.json",nil,encode,json_only):save(good,true); eq(json_only.writes,1)
for _,path in ipairs({"/r.json","/r.html"}) do
    local existing=filesystem({[path]="existing user report"})
    fails(function() reports.writer("/r.json","/r.html",encode,existing) end,"Refusing to overwrite")
    eq(existing.writes,0); eq(existing.files[path],"existing user report")
end
fails(function() reports.writer("/r.json","/a/../r.json",encode,filesystem()) end,"must be different")
local blocked=filesystem({}, {fail_open="/r.html"})
fails(function() reports.writer("/r.json","/r.html",encode,blocked):save(good,true) end,"permission denied")
eq(blocked.files["/r.json"],"JSON:complete") -- caller marks the report failed and checkpoints JSON again
for _,test in ipairs({{fail_write=true},{fail_close=true}}) do
    fails(function() reports.writer("/r.json",nil,encode,filesystem({},test)):save(good,true) end)
end

-- Generate a uniquely named, clearly labeled sample for local browser inspection, using no real data.
local preview=fixture()
preview.config.modes={"direct","driver"}; preview.config.cases={"tiny","mixed_rows","transaction"}
preview.runs={}
for _,mode in ipairs(preview.config.modes) do
    for i,name in ipairs(preview.config.cases) do
        for _,run in ipairs(fixture().runs) do
            run.mode=mode; run.case=name
            run.requests_per_s=run.requests_per_s*(i==1 and 62 or i==2 and 4 or 13)
            run.elapsed_s=run.success/run.requests_per_s
            run.sql_statements_per_s=run.requests_per_s*(name=="transaction" and 5 or 1)
            run.p50_ms=run.p50_ms*.07; run.p95_ms=run.p95_ms*.07; run.p99_ms=run.p99_ms*.07; run.max_ms=run.max_ms*.07
            preview.runs[#preview.runs+1]=run
        end
    end
end
preview.checks={{implementation="libpq",mode="driver",name="same_key_fifo",passed=true},
    {implementation="sqlx",mode="driver",name="same_key_fifo",passed=true}}
local stem=("target/libpq-tests/report-preview-%d-%06x"):format(os.time(),math.random(0,0xffffff))
reports.writer(stem..".json",stem..".html",require("json").encode):save(preview,true)
print(("report offline checks passed (%d assertions; synthetic data, no Moon/database/network)"):format(checks))
print("HTML_PREVIEW="..stem..".html")
