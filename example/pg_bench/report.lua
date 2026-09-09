-- Offline HTML report generation. Pure rendering; no Moon, database, JavaScript, or CDN dependency.
local M = {}
local implementations={"libpq","sqlx"}
local labels={libpq="libpq",sqlx="Rust/SQLx"}
local metrics={"requests_per_s","p50_ms","p95_ms","p99_ms","max_ms"}

local function escape(value)
    return (tostring(value==nil and "—" or value):gsub("&","&amp;"):gsub("<","&lt;")
        :gsub(">","&gt;"):gsub('"',"&quot;"):gsub("'","&#39;"))
end
local function number(value)
    return type(value)=="number" and value==value and value>=0 and value<math.huge
end
local function formatted(value,digits)
    if not number(value) then return "—" end
    -- SVG/CSS-independent numeric labels; decimal separator is stable even under a changed locale.
    return (("%."..(digits or 2).."f"):format(value):gsub(",","."))
end
local function median(values)
    table.sort(values)
    local n=#values
    if n==0 then return nil end
    if n%2==1 then return values[(n+1)//2] end
    return (values[n//2]+values[n//2+1])/2
end
local function valid(run)
    if run.phase~="measure" or run.error or run.errors~=0 then return false end
    if not number(run.success) or run.success<=0 or run.success~=run.attempted then return false end
    if not number(run.elapsed_s) or run.elapsed_s<=0 then return false end
    if run.target_requests and (not number(run.target_requests) or run.success<run.target_requests) then return false end
    if run.min_duration_ms and (not number(run.min_duration_ms) or run.elapsed_s*1000+.001<run.min_duration_ms) then return false end
    for _,key in ipairs(metrics) do if not number(run[key]) then return false end end
    return true
end
local function summary(runs)
    local result={rounds=0,by_round={},unique=true,measured_s=0,min_samples=math.huge,min_elapsed=math.huge,validation_pct=0}
    local columns={}
    for _,key in ipairs(metrics) do columns[key]={} end
    for _,run in ipairs(runs) do
        if valid(run) then
            result.rounds=result.rounds+1
            if not number(run.round) or run.round%1~=0 or run.round<1 or result.by_round[run.round] then result.unique=false end
            if number(run.round) then result.by_round[run.round]=run.requests_per_s end
            result.measured_s=result.measured_s+run.elapsed_s
            result.min_samples=math.min(result.min_samples,run.success)
            result.min_elapsed=math.min(result.min_elapsed,run.elapsed_s)
            result.validation_pct=math.max(result.validation_pct,run.validation_wall_pct or 0)
            for _,key in ipairs(metrics) do columns[key][#columns[key]+1]=run[key] end
        end
    end
    for _,key in ipairs(metrics) do result[key]=median(columns[key]) end
    local qps=columns.requests_per_s
    result.min_qps=qps[1]; result.max_qps=qps[#qps]
    if #qps>0 then
        local mean=0; for _,n in ipairs(qps) do mean=mean+n end; mean=mean/#qps
        local variance=0; for _,n in ipairs(qps) do variance=variance+(n-mean)^2 end
        result.cv_pct=mean>0 and math.sqrt(variance/#qps)/mean*100 or 0
    end
    return result
end

local style=[=[
:root{color-scheme:light dark;--bg:#f5f6f8;--paper:#fff;--ink:#182633;--muted:#566674;--line:#dbe2e7;--track:#eaf0f3;--pq:#087f83;--rust:#c56b32;--bad:#ae303f;--good:#137263;--note:#fff4dd}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.6 system-ui,-apple-system,"Segoe UI","Microsoft YaHei",sans-serif}main{max-width:1320px;margin:auto;padding:40px 32px 64px}h1,h2,h3,p{margin:0}h1{font-size:34px;letter-spacing:-1px;line-height:1.25}h2{font-size:23px}h3{font-size:17px}a{color:var(--pq)}header{padding-bottom:28px;border-bottom:1px solid var(--line)}.eyebrow{font-size:12px;letter-spacing:2px;color:var(--muted);margin-bottom:10px}.heading{display:flex;justify-content:space-between;align-items:center;gap:20px}.meta,.hint{color:var(--muted);font-size:13px}.meta{margin-top:12px}.badge{display:inline-block;border-radius:6px;padding:5px 12px;font-size:13px;white-space:nowrap;background:var(--track)}.good{color:var(--good)}.bad{color:var(--bad)}.notice{border-left:4px solid var(--pq);background:var(--paper);padding:15px 18px;margin:20px 0}.notice.bad{border-color:var(--bad)}.sample{background:var(--note);border-color:var(--rust)}.stats{display:grid;grid-template-columns:repeat(4,1fr);gap:16px;margin:24px 0}.stat{background:var(--paper);padding:15px 18px;border:1px solid var(--line);border-radius:8px}.stat strong{display:block;font-size:25px;font-weight:600}.stat span{color:var(--muted);font-size:13px}nav{display:flex;gap:20px;flex-wrap:wrap;margin-bottom:24px}section{margin-top:32px;scroll-margin-top:20px}.section-title{display:flex;justify-content:space-between;align-items:baseline;gap:14px;flex-wrap:wrap;margin-bottom:14px}.legend{display:flex;gap:18px;font-size:13px}.swatch{display:inline-block;width:12px;height:12px;border-radius:2px;margin-right:6px}.pq{background:var(--pq)}.rust{background:var(--rust)}.charts{display:grid;grid-template-columns:1fr 1fr;gap:20px}.chart{margin:0;min-width:0;background:var(--paper);padding:22px;border-radius:10px;border:1px solid var(--line)}.chart .hint{margin:4px 0 18px}.axis{display:flex;justify-content:space-between;color:var(--muted);font-size:12px;border-bottom:1px solid var(--line);margin:0 93px 12px 69px}.bar-group{margin:17px 0}.case-name{font-size:13px;font-weight:600;overflow-wrap:anywhere;margin-bottom:6px}.bar-row{display:grid;grid-template-columns:60px minmax(0,1fr) 84px;gap:9px;align-items:center;margin:5px 0;font-size:12px}.track{height:14px;background:var(--track);border-radius:3px;overflow:hidden}.bar{height:100%;min-width:0}.value{text-align:right;font-variant-numeric:tabular-nums}.table-wrap{overflow:auto;margin-top:16px;background:var(--paper);border:1px solid var(--line);border-radius:8px}table{width:100%;border-collapse:collapse;font-size:13px}caption{text-align:left;padding:14px 16px;font-weight:600}th,td{text-align:right;padding:10px 13px;border-bottom:1px solid var(--line);white-space:nowrap;font-variant-numeric:tabular-nums}th{font-size:12px;color:var(--muted);font-weight:600;background:var(--track)}th:first-child,td:first-child{text-align:left}tr:last-child td{border-bottom:0}td.text{white-space:normal;min-width:220px;text-align:left;overflow-wrap:anywhere}details{margin:14px 0;background:var(--paper);border:1px solid var(--line);border-radius:8px;padding:13px 16px}summary{cursor:pointer;font-weight:600}details .table-wrap{border:0;margin:12px -8px 0}details p{margin-top:10px}dl{display:grid;grid-template-columns:190px minmax(0,1fr);gap:9px 20px;margin:18px 0 0}dt{color:var(--muted)}dd{margin:0;overflow-wrap:anywhere;font-variant-numeric:tabular-nums}ul{padding-left:22px}li{margin:6px 0;overflow-wrap:anywhere}.empty{padding:25px 0;color:var(--muted)}.wrap{white-space:pre-wrap;overflow-wrap:anywhere}footer{margin-top:36px;border-top:1px solid var(--line);padding-top:18px;color:var(--muted);font-size:12px}
@media(prefers-color-scheme:dark){:root{--bg:#101820;--paper:#18232d;--ink:#e6edf3;--muted:#adbcc9;--line:#344452;--track:#263642;--pq:#43b6b3;--rust:#efaa78;--bad:#ff9ba7;--good:#77d7b3;--note:#3a3020}}
@media(max-width:900px){.charts{grid-template-columns:1fr}}@media(max-width:540px){main{padding:24px 14px 40px}h1{font-size:27px}.heading{align-items:flex-start;flex-direction:column;gap:10px}.stats{grid-template-columns:1fr 1fr;gap:10px}.chart{padding:16px}.bar-row{grid-template-columns:57px minmax(0,1fr) 78px;gap:7px}.axis{margin-left:64px;margin-right:85px}dl{grid-template-columns:1fr;gap:3px}dd{margin-bottom:10px}}
@media print{:root{color-scheme:light;--bg:#fff;--paper:#fff;--ink:#182633;--muted:#566674;--line:#dbe2e7;--track:#eaf0f3;--pq:#087f83;--rust:#c56b32}body{print-color-adjust:exact;-webkit-print-color-adjust:exact}main{max-width:none;padding:12px}nav{display:none}.charts{grid-template-columns:1fr}.bar-group,tr{break-inside:avoid}.table-wrap{overflow:visible}th,td{white-space:normal;padding:5px}details{break-inside:avoid}}
]=]

--- Render only known, non-secret fields; escape all report strings as text (including DB errors).
--- Invalid/partial reports retain diagnostic charts but never emit comparative conclusions.
function M.render(report)
    local out={}
    local function add(value) out[#out+1]=value end
    local cfg=report.config or {}
    local clean=report.status=="complete" and not report.error and not report.report_error
        and #(report.cleanup_errors or {})==0 and #(report.remaining_schemas or {})==0
    local groups,order={},{}
    local total,errors=0,0
    for _,run in ipairs(report.runs or {}) do
        if run.error or (number(run.errors) and run.errors>0) then clean=false end
        if run.phase=="measure" then
            if number(run.success) then total=total+run.success end
            if not valid(run) then clean=false end
        end
        if number(run.errors) then errors=errors+run.errors end
        if labels[run.implementation] then
            local mode=tostring(run.mode or "unknown")
            local name=tostring(run.case or "unknown")
            if not groups[mode] then groups[mode]={cases={},order={}}; order[#order+1]=mode end
            local group=groups[mode]
            if not group.cases[name] then
                group.cases[name]={libpq={},sqlx={}}; group.order[#group.order+1]=name
            end
            local runs=group.cases[name][run.implementation]; runs[#runs+1]=run
        end
    end
    if total==0 then clean=false end
    for _,check in ipairs(report.checks or {}) do if check.passed~=true then clean=false end end
    local expected=cfg.implementations or {}
    if #expected==0 or not number(cfg.rounds) or cfg.rounds<=0 then clean=false end
    for _,mode in ipairs(cfg.modes or {}) do if not groups[mode] then clean=false end end
    for _,profile in ipairs(report.profiles or {}) do
        local group=groups[profile.name]
        if not group then clean=false else
            group.concurrency=profile.concurrency; group.api_mode=profile.mode
            for _,name in ipairs(profile.cases or {}) do if not group.cases[name] then clean=false end end
        end
    end
    if type(cfg.cases)=="table" then
        for _,mode in ipairs(cfg.modes or {}) do
            for _,name in ipairs(cfg.cases) do
                if not (mode=="direct" and name=="hot_lane") and (not groups[mode] or not groups[mode].cases[name]) then clean=false end
            end
        end
    end
    for _,mode in ipairs(order) do
        local group=groups[mode]
        for _,name in ipairs(group.order) do
            local case=group.cases[name]; case.summaries={}
            for _,impl in ipairs(implementations) do case.summaries[impl]=summary(case[impl]) end
            for _,impl in ipairs(expected) do
                local s=case.summaries[impl]
                if not s or s.rounds~=cfg.rounds or not s.unique then clean=false end
                if s and number(cfg.rounds) then
                    for round=1,cfg.rounds do if not s.by_round[round] then clean=false end end
                end
            end
        end
    end
    local function chart(group,key,title,unit,digits)
        local max=0
        for _,name in ipairs(group.order) do
            for _,impl in ipairs(implementations) do max=math.max(max,group.cases[name].summaries[impl][key] or 0) end
        end
        add('<figure class="chart"><h3>'..title..'</h3><p class="hint">'..unit..' · 每个用例采用有效测量轮次的中位数 · 同图共用线性刻度</p>')
        add('<div class="axis"><span>0</span><span>'..formatted(max,digits)..'</span></div>')
        for _,name in ipairs(group.order) do
            add('<div class="bar-group"><div class="case-name">'..escape(name)..'</div>')
            for _,impl in ipairs(implementations) do
                local value=group.cases[name].summaries[impl][key]
                local width=max>0 and value and math.min(100,value/max*100) or 0
                local description=labels[impl].." / "..name..": "..(value and formatted(value,digits).." "..unit or "无有效测量轮次")
                add('<div class="bar-row" aria-label="'..escape(description)..'"><span>'..labels[impl]..'</span>')
                add('<div class="track" aria-hidden="true"><div class="bar '..(impl=="libpq" and "pq" or "rust")..'" style="width:'..formatted(width,4)..'%"></div></div>')
                add('<span class="value">'..formatted(value,digits)..'</span></div>')
            end
            add('</div>')
        end
        add('</figure>')
    end
    add('<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">')
    add('<meta http-equiv="Content-Security-Policy" content="default-src &#39;none&#39;; style-src &#39;unsafe-inline&#39;; base-uri &#39;none&#39;; form-action &#39;none&#39;">')
    add('<title>PostgreSQL 基准报告 · libpq 与 Rust/SQLx</title><style>'..style..'</style></head><body><main>')
    add('<header><div class="eyebrow">MOON / POSTGRESQL BENCHMARK</div><div class="heading"><h1>libpq × Rust/SQLx</h1>')
    add('<span class="badge '..(clean and "good" or "bad")..'">'..(clean and "测量完成" or "数据无效 / 尚未完成")..'</span></div>')
    add('<p class="meta">开始 '..escape(report.started_utc)..' · 结束 '..escape(report.finished_utc)..' · 状态 '..escape(report.status)..'</p></header>')
    if report.sample then add('<div class="notice sample"><strong>模拟样例，非数据库实测</strong> · 此页仅用于检查报告布局和统计展示。</div>') end
    add('<div class="notice '..(clean and "" or "bad")..'">'..(clean
        and '按业务场景看吞吐与长尾，不将不同用例混合成一个总分。事务 / batch 的一次请求包含多条 SQL。'
        or '此报告仅用于诊断。运行未完成、有错误或数据不完整时，不据此判断两种实现的优劣。图中只保留有效轮次，缺失值以 — 表示。')..'</div>')
    add('<div class="stats">')
    for _,item in ipairs({{"每边连接数",cfg.poolsize},{"基准并发数（额外组见下方）",cfg.concurrency},{"每组目标轮数",cfg.rounds},{"测量成功请求数",total}}) do
        add('<div class="stat"><span>'..item[1]..'</span><strong>'..escape(item[2])..'</strong></div>')
    end
    add('</div><div class="notice"><strong>测量质量</strong> · 少于 6 轮、单轮不足 1 秒或 1000 个请求、吞吐 CV 超过 10% 时仅作探索性比较。CV 是轮次波动系数，不是置信区间；p99 是闭环负载下的延迟。</div>')
    add('<nav aria-label="报告目录">')
    for index,mode in ipairs(order) do add('<a href="#mode-'..index..'">'..escape(mode)..'</a>') end
    add('<a href="#diagnostics">诊断与配置</a></nav>')
    if #order==0 then add('<p class="empty">尚无请求结果。请查看下方错误与配置；未测量不等于性能为零。</p>') end
    for index,mode in ipairs(order) do
        local group=groups[mode]
        add('<section id="mode-'..index..'"><div class="section-title"><h2>'..escape(mode)..' <span class="hint">'..
            ((group.api_mode or mode)=="driver" and "客户端 → service → 连接池" or mode=="direct" and "直接调用连接" or "测量分组")..'</span></h2>')
        add('<div class="legend"><span><i class="swatch pq"></i>libpq</span><span><i class="swatch rust"></i>Rust/SQLx</span></div></div><div class="charts">')
        chart(group,"requests_per_s","吞吐对比 · 越高越好","请求 / 秒",1)
        chart(group,"p99_ms","p99 延迟对比 · 越低越好","毫秒",3)
        add('</div><p class="hint">p99 为“每轮 p99 的中位数”，不是合并所有请求后的 p99。柱形图不包含错误轮次；具体轮数见下表。</p>')
        add('<p class="hint">本组请求并发 '..escape(group.concurrency or cfg.concurrency)..' · 每边连接数 '..escape(cfg.poolsize)..' · 不同并发组不可直接归因于 driver 开销。</p>')
        add('<div class="table-wrap"><table><caption>多轮统计</caption><thead><tr><th>用例</th><th>实现</th><th>有效轮数</th><th>请求 / 秒</th><th>吞吐范围</th><th>p50 ms</th><th>p95 ms</th><th>p99 ms</th><th>max ms 中位数</th><th>吞吐 CV %</th><th>测量总秒数</th><th>质量提示</th></tr></thead><tbody>')
        for _,name in ipairs(group.order) do
            local case=group.cases[name]
            for _,impl in ipairs(implementations) do
                local s=case.summaries[impl]
                add('<tr><td>'..escape(name)..'</td><td>'..labels[impl]..'</td><td>'..s.rounds..' / '..escape(cfg.rounds)..'</td>')
                add('<td>'..formatted(s.requests_per_s,1)..'</td><td>'..formatted(s.min_qps,1)..' – '..formatted(s.max_qps,1)..'</td>')
                for _,key in ipairs({"p50_ms","p95_ms","p99_ms","max_ms"}) do add('<td>'..formatted(s[key],3)..'</td>') end
                local warnings={}
                if s.rounds<6 then warnings[#warnings+1]="少于 6 轮" end
                if s.min_elapsed<1 then warnings[#warnings+1]="单轮不足 1 秒" end
                if s.min_samples<1000 then warnings[#warnings+1]="p99 样本偏少" end
                if (s.cv_pct or 0)>10 then warnings[#warnings+1]="轮次波动 > 10%" end
                if s.validation_pct>10 then warnings[#warnings+1]="校验时间 > 10%" end
                if cfg.rounds and cfg.rounds%2==1 then warnings[#warnings+1]="奇数轮，先测次数不完全平衡" end
                add('<td>'..formatted(s.cv_pct,1)..'</td><td>'..formatted(s.measured_s,2)..'</td><td class="text">'..
                    (#warnings>0 and table.concat(warnings,"；") or "未触发上述阈值；不代表统计显著")..'</td>')
                add('</tr>')
            end
        end
        add('</tbody></table></div><div class="table-wrap"><table><caption>吞吐比值 · libpq / Rust/SQLx（不是总评分）</caption><thead><tr><th>用例</th><th>中位数比值</th><th>解读</th></tr></thead><tbody>')
        for _,name in ipairs(group.order) do
            local a,b=group.cases[name].summaries.libpq,group.cases[name].summaries.sqlx
            local ratio,explanation="—","数据不完整或报告无效，不作比较"
            if clean and number(cfg.rounds) and cfg.rounds>0 and a.rounds==cfg.rounds and b.rounds==cfg.rounds
                and a.requests_per_s and b.requests_per_s and b.requests_per_s>0 then
                ratio=formatted(a.requests_per_s/b.requests_per_s,3).."×"
                local overlap=a.min_qps<=b.max_qps and b.min_qps<=a.max_qps
                explanation=overlap and "轮次范围重叠，增加样本复测；不代表显著差异" or "轮次范围未重叠；仍需结合 p99 与更多轮次判断"
                local paired,wins={},0
                for round=1,cfg.rounds do
                    local x,y=a.by_round[round],b.by_round[round]
                    if x and y and y>0 then paired[#paired+1]=x/y; if x>y then wins=wins+1 end end
                end
                explanation=explanation.."；配对轮比值中位数 "..formatted(median(paired),3).."×；libpq 更快 "..wins.." / "..cfg.rounds.." 轮"
            end
            add('<tr><td>'..escape(name)..'</td><td>'..ratio..'</td><td class="text">'..explanation..'</td></tr>')
        end
        add('</tbody></table></div>')
        for _,name in ipairs(group.order) do
            add('<details><summary>'..escape(name)..' · 每轮原始统计</summary><div class="table-wrap"><table><thead><tr><th>实现</th><th>阶段</th><th>轮次 / 顺序</th><th>成功 / 尝试</th><th>耗时 s</th><th>请求 / 秒</th><th>SQL / 秒</th><th>p50 ms</th><th>p95 ms</th><th>p99 ms</th><th>max ms</th><th>峰值在途</th><th>完整校验数</th><th>校验时间 %</th><th>预热 s</th><th>发送 MiB/s</th><th>接收 MiB/s</th><th>行 / 秒</th><th>提示 / 错误</th></tr></thead><tbody>')
            for _,impl in ipairs(implementations) do
                for _,run in ipairs(group.cases[name][impl]) do
                    add('<tr><td>'..labels[impl]..'</td><td>'..escape(run.phase)..'</td><td>'..escape(run.round)..' / '..escape(run.position)..'</td>')
                    add('<td>'..escape(run.success)..' / '..escape(run.attempted)..'</td><td>'..formatted(run.elapsed_s,3)..'</td>')
                    for _,key in ipairs({"requests_per_s","sql_statements_per_s","p50_ms","p95_ms","p99_ms","max_ms"}) do add('<td>'..formatted(run[key],3)..'</td>') end
                    for _,key in ipairs({"peak_inflight","full_checks","validation_wall_pct"}) do add('<td>'..formatted(run[key],2)..'</td>') end
                    add('<td>'..formatted(run.warmup and run.warmup.elapsed_s,3)..'</td>')
                    for _,key in ipairs({"payload_send_mib_s","payload_receive_mib_s","rows_per_s"}) do add('<td>'..formatted(run[key],2)..'</td>') end
                    add('<td class="text '..(valid(run) and "" or "bad")..'">'..escape(run.error or (run.errors==0 and "无错误" or run.errors))..
                        (#(run.warnings or {})>0 and "；"..escape(table.concat(run.warnings,"；")) or "")..'</td></tr>')
                end
            end
            add('</tbody></table></div></details>')
        end
        add('</section>')
    end
    add('<section id="diagnostics"><h2>诊断与配置</h2><p class="hint">请求 / 校验错误计数：'..escape(errors)..'。单边运行没有另一边的实测值，不会填零或生成胜负结论。</p>')
    for _,issue in ipairs({report.error or "",report.report_error or ""}) do
        if issue~="" then add('<div class="notice bad wrap">'..escape(issue)..'</div>') end
    end
    for _,issue in ipairs(report.cleanup_errors or {}) do add('<div class="notice bad wrap">清理失败：'..escape(issue)..'</div>') end
    if #(report.remaining_schemas or {})>0 then
        add('<div class="notice bad"><strong>尚未清理的测试 schema（人工确认后处理）</strong><ul>')
        for _,name in ipairs(report.remaining_schemas) do add('<li>'..escape(name)..'</li>') end
        add('</ul></div>')
    end
    add('<details><summary>FIFO 正确性检查</summary><ul>')
    for _,check in ipairs(report.checks or {}) do add('<li>'..escape(check.implementation)..' / '..escape(check.mode)..' / '..escape(check.name)..'：'..(check.passed==true and '通过' or '未通过')..'</li>') end
    if #(report.checks or {})==0 then add('<li>未记录检查结果（direct 模式不执行 driver FIFO 检查）。</li>') end
    add('</ul></details><details><summary>配置及数据库环境 · 不包含密码 / 连接 URL</summary><dl>')
    for _,key in ipairs({"host","port","database","user","sslmode","poolsize","concurrency","cache","rounds","warmup",
        "iterations","bulk_iterations","rows","data_rows","bytes","tx_size","timeout_ms","deadline_ms","modes","implementations",
        "cases","lua","moon_threads","driver_thread","enable_stdout","loglevel","min_duration_ms","warmup_duration_ms",
        "validate_every","driver_concurrencies","run_label","platform"}) do
        local value=cfg[key]
        if type(value)=="table" then value=table.concat(value,", ") end
        if value~=nil then add('<dt>'..key..'</dt><dd>'..escape(value)..'</dd>') end
    end
    add('</dl>')
    for _,endpoint in ipairs(report.endpoints or {}) do
        local server=endpoint.server or {}
        add('<p class="hint wrap">'..escape(endpoint.implementation)..' / '..escape(endpoint.mode)..' / lane '..escape(endpoint.lane)..
            '：PG '..escape(server.version)..' · PID '..escape(server.pid)..' · '..escape(server.address)..':'..escape(server.port)..'</p>')
    end
    add('</details><details><summary>统计口径与限制</summary><ul><li>同用例对比吞吐与延迟，不混合计算整体 QPS；事务 / batch 的请求数与 SQL 条数不同。</li>')
    add('<li>闭环固定在途并发；延迟包含排队、数据库与编解码，不含结果校验。v2 吞吐包含全部校验开销；v1 不含最后一次校验。</li><li>p50 / p95 / p99 / max 均展示各轮相应统计量的中位数；没有保留逐请求样本，不能反推合并分位数。v2 分位数为 1% 对数桶上界（最小 1 ns），mean / max 精确。MiB/s 只算应用 payload，不是网络流量。</li>')
    for _,note in ipairs(report.notes or {}) do add('<li>'..escape(note)..'</li>') end
    add('</ul></details></section><footer>单文件离线报告 · 无外部字体、脚本、CDN 或网络请求 · JSON 文件保留完整原始汇总</footer></main></body></html>')
    return table.concat(out)
end

function M.html_path(json_path,override)
    if override and override~="" then return override end
    if json_path:lower():sub(-5)==".json" then return json_path:sub(1,-6)..".html" end
    return json_path..".html"
end
local function canonical(path)
    local parts={}
    for part in path:gsub("\\","/"):gmatch("[^/]+") do
        if part==".." and #parts>0 and parts[#parts]~=".." then table.remove(parts)
        elseif part~="." then parts[#parts+1]=part end
    end
    local value=table.concat(parts,"/")
    return package.config:sub(1,1)=="\\" and value:lower() or value
end

--- Reserve fresh targets before any DB work. Rewrites only these report files on later checkpoints.
--- fs is injectable for offline failure/collision tests; production uses Lua's io module.
function M.writer(json_path,html_path,encode,fs)
    fs=fs or io
    assert(not html_path or canonical(json_path)~=canonical(html_path),"JSON and HTML report paths must be different")
    for _,path in ipairs({json_path,html_path}) do
        local existing=fs.open(path,"rb")
        if existing then existing:close(); error("Refusing to overwrite existing report: "..path,0) end
    end
    local function write(path,content)
        local file,why=fs.open(path,"wb")
        assert(file,"cannot create report "..path..": "..tostring(why))
        local ok,err=file:write(content)
        local closed,close_error=file:close()
        assert(ok,err); assert(closed,close_error)
    end
    return {save=function(_,report,with_html)
        write(json_path,encode(report))
        if html_path and with_html then write(html_path,M.render(report)) end
    end}
end
return M
