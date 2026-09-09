-- Self-contained, script-free HTML. Never load local DB configuration while rendering.
local M={}
local function escape(v)
    return (tostring(v==nil and "—" or v):gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;")
        :gsub('"',"&quot;"):gsub("'","&#39;"))
end
local function numeric(v) return type(v)=="number" and v==v and v>=0 and v<math.huge end
local function format(v,d)
    return numeric(v) and (("%."..(d or 2).."f"):format(v):gsub(",",".")) or "—"
end
local function chart(samples,title,unit,series)
    local maximum,last=0,1
    for _,s in ipairs(samples) do
        if numeric(s.time_s) then
            last=math.max(last,s.time_s)
            for _,line in ipairs(series) do local v=line.read(s); if numeric(v) then maximum=math.max(maximum,v) end end
        end
    end
    maximum=maximum>0 and maximum*1.08 or 1
    local out={'<section class="chart"><h2>'..escape(title)..'</h2><svg viewBox="0 0 840 265" role="img"><title>'..escape(title)..'</title>'}
    for i=0,4 do
        local y=215-i*45
        out[#out+1]=('<path class="grid" d="M70 %dH820"/><text x="62" y="%d" text-anchor="end">%s</text>')
            :format(y,y+4,format(maximum*i/4,1))
    end
    for i=0,4 do
        out[#out+1]=('<text x="%d" y="240" text-anchor="middle">%s s</text>'):format(70+i*187,format(last*i/4,0))
    end
    out[#out+1]='<text x="70" y="18">'..escape(unit)..'</text>'
    for _,line in ipairs(series) do
        local points,open={},false
        for _,s in ipairs(samples) do
            local v=line.read(s)
            if numeric(v) and numeric(s.time_s) then
                local x,y=70+s.time_s/last*750,215-v/maximum*180
                points[#points+1]=(open and "L" or "M")..format(x,2).." "..format(y,2); open=true
            else open=false end
        end
        out[#out+1]='<path fill="none" stroke="'..line.color..'" stroke-width="2" d="'..table.concat(points," ")..'"/>'
    end
    out[#out+1]='</svg><div class="legend">'
    for _,line in ipairs(series) do out[#out+1]='<span style="color:'..line.color..'">━ '..escape(line.name)..'</span>' end
    out[#out+1]='</div></section>'
    return table.concat(out)
end
local function resource(key) return function(s) return s.resources and s.resources[key] end end
local function latency(key) return function(s) return (s.success or 0)>0 and s[key] or nil end end
local function pretty(value,depth)
    depth=depth or 0
    if type(value)~="table" then return tostring(value) end
    if depth>8 then return "..." end
    local keys={}; for k in pairs(value) do if k~="password" and k~="url" and k~="sslkey" then keys[#keys+1]=k end end
    table.sort(keys,function(a,b) return tostring(a)<tostring(b) end)
    local lines={}
    for _,k in ipairs(keys) do lines[#lines+1]=string.rep("  ",depth)..tostring(k)..": "..pretty(value[k],depth+1) end
    return table.concat(lines,"\n")
end
function M.render(report)
    local out={}
    local function add(s) out[#out+1]=s end
    local total,errors=0,0
    local clean=report.status=="complete" and not report.error and not report.report_error
        and #(report.cleanup_errors or {})==0 and #(report.remaining_schemas or {})==0 and not report.possibly_created_schema
    local stages=report.stages or {}
    if #stages==0 or #stages~=#((report.config or {}).stages or {}) then clean=false end
    for _,s in ipairs(stages) do
        local r=s.result or {}
        total=total+(r.success or 0); errors=errors+(r.errors or 0)+(s.warmup and s.warmup.errors or 0)
        if s.status~="complete" or r.recording_error or (r.success or 0)==0 then clean=false end
    end
    for _,c in ipairs(report.checks or {}) do if not c.passed then clean=false end end
    if errors>0 then clean=false end
    local state=clean and "配置内验收通过" or report.status=="running" and "运行中 · 非最终结果" or "未通过 / 未完成"
    add([[<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">]])
    add([[<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"><title>SQLx PostgreSQL 压测报告</title><style>
*{box-sizing:border-box}body{margin:0;background:#f3f6fa;color:#213348;font:14px/1.6 system-ui,'Microsoft YaHei',sans-serif}main{max-width:1440px;margin:auto;padding:32px}h1{font-size:30px;margin:0}h2{font-size:17px;margin:0 0 12px}p{color:#5c6d80}.tag{display:inline-block;background:#dce8f1;padding:5px 12px;border-radius:6px}.notice{padding:15px 20px;background:#fff1d9;border-left:4px solid #cb8833;white-space:pre-wrap;overflow-wrap:anywhere}.cards,.charts{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:18px;margin:22px 0}.cards{grid-template-columns:repeat(4,minmax(0,1fr))}.card,.chart,details{background:white;border:1px solid #dbe3ec;border-radius:10px;padding:18px}.card strong{display:block;font-size:24px}.card span,.legend{color:#526b81;font-size:12px}svg{width:100%;height:auto;display:block}svg text{font:11px system-ui;fill:#5c6d80}.grid{stroke:#e4eaf1;stroke-width:1}.legend{display:flex;gap:18px;flex-wrap:wrap}.table{overflow:auto;margin:18px 0;border:1px solid #dbe3ec;border-radius:8px}table{border-collapse:collapse;width:100%;background:white}td,th{padding:9px 13px;border-bottom:1px solid #e3eaf2;text-align:right;white-space:nowrap;font-variant-numeric:tabular-nums}th{background:#eaf0f6}td:first-child,th:first-child{text-align:left}pre{white-space:pre-wrap;overflow-wrap:anywhere;font:12px/1.7 ui-monospace,monospace}details{margin:15px 0}summary{cursor:pointer;font-weight:600}.bad{color:#b93845}.good{color:#147d66}li{margin:5px 0;overflow-wrap:anywhere}footer{margin-top:28px;color:#697b8c}@media(max-width:800px){main{padding:18px}.charts{grid-template-columns:1fr}.cards{grid-template-columns:1fr 1fr}}@media print{.charts{grid-template-columns:1fr}.chart{break-inside:avoid}main{padding:8px}.table{overflow:visible}}
</style></head><body><main>]])
    add('<h1>SQLx / PostgreSQL 持续压测</h1><p>'..escape(report.started_utc)..' → '..escape(report.finished_utc)..' · '..escape((report.config or {}).run_label)..'</p>')
    add('<span class="tag '..(clean and 'good' or 'bad')..'">'..state..'</span>')
    if report.sample then add('<p class="notice">模拟样例，非数据库实测。仅用于检查报告排版。</p>') end
    add('<p>只测 SQLx；每个阶段复用同一个连接池。通过表示本次配置和检查项通过，不等于已证明生产环境无故障。</p>')
    add('<div class="cards">')
    for _,c in ipairs({{"成功请求",format(total,0)},{"请求 / 校验错误",format(errors,0)},{"记录阶段",format(#stages,0)},{"整次耗时 s",format(report.elapsed_s,1)}}) do
        add('<div class="card"><span>'..c[1]..'</span><strong>'..c[2]..'</strong></div>')
    end
    add('</div><h2>分阶段结果</h2><div class="table"><table><thead><tr><th>阶段 / 状态</th><th>并发</th><th>时长 s</th><th>成功 / 尝试</th><th>QPS</th><th>SQL/s</th><th>p50 ms</th><th>p95 ms</th><th>p99 ms</th><th>max ms</th><th>错误</th><th>峰值在途</th><th>校验占比</th></tr></thead><tbody>')
    for _,s in ipairs(stages) do
        local r=s.result or {}
        add('<tr><td>'..escape(s.name)..' / '..escape(s.status)..'</td><td>'..format(s.concurrency,0)..'</td><td>'..format(r.elapsed_s,2)..'</td>')
        add('<td>'..format(r.success,0)..' / '..format(r.attempted,0)..'</td><td>'..format(r.requests_per_s,1)..'</td><td>'..format(r.sql_statements_per_s,1)..'</td>')
        for _,k in ipairs({"p50_ms","p95_ms","p99_ms","max_ms"}) do add('<td>'..format((r.success or 0)>0 and r[k] or nil,3)..'</td>') end
        add('<td>'..format(r.errors,0)..'</td><td>'..format(r.peak_inflight,0)..'</td><td>'..format(r.validation_wall_pct,2)..'%</td></tr>')
    end
    add('</tbody></table></div><div class="charts">')
    local samples=report.samples or {}
    add(chart(samples,"窗口吞吐","成功请求 / s",{{name="QPS",color="#14867a",read=function(s) return s.requests_per_s end}}))
    add(chart(samples,"窗口延迟","毫秒 · 成功且校验通过的请求",{
        {name="p95",color="#468ad0",read=latency("p95_ms")},{name="p99",color="#cd8142",read=latency("p99_ms")}}))
    add(chart(samples,"队列与在途","数量 · 不包含未发出的请求",{
        {name="driver 队列",color="#468ad0",read=resource("driver_queue")},
        {name="压测在途",color="#cd8142",read=function(s) return s.inflight end}}))
    add(chart(samples,"SQLx 响应登记","进程级数量，不是字节数",{
        {name="waiting",color="#14867a",read=resource("waiting")},{name="ready",color="#cd8142",read=resource("ready")}}))
    add(chart(samples,"Lua 内存（不是进程 RSS）","KiB · 含压测端保存的报告数据",{
        {name="压测 service",color="#468ad0",read=resource("caller_lua_kib")},
        {name="driver service",color="#14867a",read=resource("driver_lua_kib")}}))
    add(chart(samples,"窗口错误","请求 / 校验错误数",{{name="错误",color="#bd4152",read=function(s) return s.errors end}}))
    add('</div>')
    for _,s in ipairs(stages) do
        local r=s.result or {}
        add('<details><summary>'..escape(s.name)..' · 各类请求、预热及错误</summary>')
        if (r.success or 0)<1000 then add('<p class="notice">成功样本不足 1000，p99 尾部样本偏少。</p>') end
        if (r.validation_wall_pct or 0)>10 then add('<p class="notice">校验占用超过 10% 的墙钟时间，压测端可能影响吞吐。</p>') end
        add('<div class="table"><table><thead><tr><th>请求类型</th><th>成功 / 尝试</th><th>QPS</th><th>p99 ms</th><th>max ms</th><th>错误</th></tr></thead><tbody>')
        for _,c in ipairs(r.cases or {}) do
            add('<tr><td>'..escape(c.name)..'</td><td>'..format(c.success,0)..' / '..format(c.attempted,0)..'</td><td>'..format(c.requests_per_s,1)..'</td><td>'..format(c.success>0 and c.p99_ms or nil,3)..'</td><td>'..format(c.success>0 and c.max_ms or nil,3)..'</td><td>'..format(c.errors,0)..'</td></tr>')
            if c.attempted==0 then add('<tr><td colspan="6">此类请求本阶段未被抽到，不能视为已经验证。</td></tr>') end
        end
        add('</tbody></table></div><pre>'..escape(pretty({warmup=s.warmup or "disabled",errors=r.error_details or {},recording_error=r.recording_error}))..'</pre></details>')
    end
    add('<details open><summary>正确性与清理</summary><ul>')
    for _,c in ipairs(report.checks or {}) do add('<li class="'..(c.passed and "good" or "bad")..'">'..escape(c.name)..'：'..(c.passed and "通过" or escape(c.error))..'</li>') end
    add('</ul><pre>'..escape(pretty({initial=report.initial_resources or {},final=report.final_resources or {},idle_gc=report.idle_gc or false}))..'</pre></details>')
    for _,message in ipairs({report.error or "",report.report_error or ""}) do if message~="" then add('<p class="notice bad">'..escape(message)..'</p>') end end
    for _,message in ipairs(report.cleanup_errors or {}) do add('<p class="notice bad">清理失败：'..escape(message)..'</p>') end
    if #(report.remaining_schemas or {})>0 or report.possibly_created_schema then
        add('<p class="notice bad">请人工核实并清理测试 schema：'..escape(table.concat(report.remaining_schemas or {},", "))..'\n创建结果不确定：'..escape(report.possibly_created_schema)..'</p>')
    end
    add('<details><summary>配置与数据库环境（不含密码 / URL / 私钥）</summary><pre>'..escape(pretty(report.config or {}))..'\n\n'..escape(pretty(report.endpoints or {}))..'</pre></details>')
    add('<footer>统计口径：固定并发闭环负载，不模拟固定到达率；每次都等待响应，不自动重试。成功 QPS 包含客户端选取请求、验证、采样和检查点开销。延迟包含参数处理、排队、数据库执行、解码和跨服务返回，不包含随后校验；失败请求不混入成功延迟分位数。分位数使用全部成功请求的有界对数直方图，桶上界约 1% 误差（最小 1 ns），不是窗口 p99 的平均值。事务/batch 的 SQL 条数不含 BEGIN/COMMIT。Lua 内存含报告记录、不能据此证明 Rust/C++ 无泄漏；RSS/CPU 请用系统监控。空闲期、重建/重启、故障注入与生产真实流量需要单独分析。HTML 只在启动和退出时更新，运行中的进度看 JSON；异常断电可能留下未完成报告和测试 schema。</footer>')
    add('</main></body></html>')
    return table.concat(out)
end
local function canonical(path)
    local parts={}
    for p in path:gsub("\\","/"):gmatch("[^/]+") do
        if p==".." and #parts>0 and parts[#parts]~=".." then table.remove(parts) elseif p~="." then parts[#parts+1]=p end
    end
    local s=table.concat(parts,"/")
    return package.config:sub(1,1)=="\\" and s:lower() or s
end
function M.writer(json_path,html_path,encode,fs)
    fs=fs or io
    assert(not html_path or canonical(json_path)~=canonical(html_path),"JSON and HTML paths must be different")
    for _,path in ipairs({json_path,html_path}) do
        local f=fs.open(path,"rb")
        if f then f:close(); error("Refusing to overwrite existing report: "..path,0) end
    end
    local function write(path,content)
        local f,err=fs.open(path,"wb")
        assert(f,"cannot write report: "..path..": "..tostring(err))
        local ok,why=f:write(content)
        local closed,close_error=f:close()
        assert(ok,why); assert(closed,close_error)
    end
    return {save=function(_,report,with_html)
        write(json_path,encode(report))
        if with_html and html_path then write(html_path,M.render(report)) end
    end}
end
return M
