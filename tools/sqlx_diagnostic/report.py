"""Offline, script-free diagnostic report. Does not load database credentials."""
import html
import json
import math
from collections import Counter, defaultdict
from statistics import median


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def fmt(value, digits=2):
    return f"{value:.{digits}f}" if number(value) else "—"


def esc(value):
    return html.escape(str(value))


def comparisons(report):
    groups = defaultdict(list)
    for stage in report.get("stages", []):
        r = stage.get("result", {})
        if stage.get("status") == "complete" and r.get("errors") == 0 and r.get("requests_per_s", 0) > 0:
            key = (stage["group"], stage["mode"], stage["poolsize"], stage["concurrency"])
            groups[key].append(stage)
    result = []
    for key, stages in groups.items():
        qps = [s["result"]["requests_per_s"] for s in stages]
        result.append(dict(group=key[0], mode=key[1], poolsize=key[2], concurrency=key[3], rounds=len(qps),
                           median_qps=median(qps), min_qps=min(qps), max_qps=max(qps),
                           run_p99_ms=[s["result"]["p99_ms"] for s in stages]))
    return result


def table(headers, rows):
    return '<div class="table"><table><tr>' + ''.join('<th>' + esc(h) + '</th>' for h in headers) + '</tr>' + ''.join(
        '<tr>' + ''.join('<td>' + esc(v) + '</td>' for v in row) + '</tr>' for row in rows) + '</table></div>'


def chart(title, lines, origin):
    # lines: (name, color, [(absolute timestamp, value)]). Missing samples break paths.
    values = [(t, v) for _, _, points in lines for t, v in points if number(t) and number(v)]
    if not values:
        return '<section><h2>' + esc(title) + '</h2><p>未采集 / 不可用</p></section>'
    last = max(max(t - origin, 0) for t, _ in values) or 1
    top = max(max(v, 0) for _, v in values) * 1.08 or 1
    out = ['<section><h2>' + esc(title) + '</h2><svg viewBox="0 0 850 240" role="img"><title>' + esc(title) + '</title>']
    for i in range(5):
        y = 195 - 40 * i
        out.append(f'<path class="grid" d="M70 {y}H825"/><text x="65" y="{y+4}" text-anchor="end">{top*i/4:.1f}</text>')
        out.append(f'<text x="{70+187*i}" y="220">{last*i/4:.0f}s</text>')
    for name, color, points in lines:
        path, opened = [], False
        for timestamp, value in points:
            if number(timestamp) and number(value):
                x, y = 70 + max(0, timestamp-origin)/last*750, 195-value/top*160
                path.append(f'{"L" if opened else "M"}{x:.2f} {y:.2f}')
                opened = True
            else:
                opened = False
        out.append(f'<path fill="none" stroke="{color}" stroke-width="2" d="{" ".join(path)}"/>')
    out.append('</svg><p>' + ' · '.join(esc(n) for n, _, _ in lines) + '</p></section>')
    return ''.join(out)


def render(report):
    stages, samples = report.get("stages", []), report.get("samples", [])
    os_samples = report.get("os_samples", [])
    origin = report.get("launcher_start_epoch_s", 0)
    parts = ['''<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
<title>SQLx 五分钟诊断</title><style>
body{font:14px/1.7 system-ui,'Microsoft YaHei',sans-serif;background:#f4f6fa;color:#213348;margin:0}
main{max-width:1440px;margin:auto;padding:28px}h1{margin:0}h2{font-size:18px}section,details{background:white;padding:16px;border:1px solid #dce3ea;border-radius:8px;margin:14px 0}
.notice{background:#fff0d7;padding:14px;border-left:4px solid #c98727}.charts{display:grid;grid-template-columns:1fr 1fr;gap:14px}.table{overflow:auto}table{border-collapse:collapse;width:100%;background:white;margin:12px 0}td,th{padding:8px;border-bottom:1px solid #dde4ec;text-align:right;white-space:nowrap}td:first-child,th:first-child{text-align:left}th{background:#eaf0f7}pre{white-space:pre-wrap;overflow-wrap:anywhere}svg{width:100%;height:auto}svg text{font:11px system-ui;fill:#65758a}.grid{stroke:#e0e6ed}@media(max-width:800px){.charts{display:block}main{padding:16px}}
</style><main><h1>SQLx / PostgreSQL 五分钟诊断</h1>''']
    add = parts.append
    add('<p>状态：' + esc(report.get("status", "unknown")) + ' · ' + esc(report.get("started_utc", "")) + '</p>')
    if report.get('sample'):
        add('<p class="notice">模拟样例，仅用于离线自检，并非真实数据库性能结果。</p>')
    add('<p class="notice">短测用于定位连接数与包装层成本，不是生产验收，也不能验证原先约 15 分钟后出现的性能退化。'
        'CPU 100% 表示占满一个逻辑核，可超过 100%；PG RSS 为匹配进程之和，共享页会重复计算，不能当作数据库独占内存。</p>')
    for warning in report.get("warnings", []):
        add('<p class="notice">' + esc(warning) + '</p>')
    for key in ("error", "report_error"):
        if report.get(key):
            add('<p class="notice">' + esc(report[key]) + '</p>')
    add('<h2>1. 连接数扩展与 2. direct / driver 对照</h2>')
    summaries = comparisons(report)
    pool_baseline = next((s['median_qps'] for s in summaries if s['group'] == 'pool' and s['rounds'] == 2), None)
    add(table(['组', '模式', '连接', '并发', '完成轮数', '中位 QPS', '相对首个连接数组', 'QPS 最小～最大', '各轮 P99 ms'], [
        [s['group'], s['mode'], s['poolsize'], s['concurrency'], s['rounds'], fmt(s['median_qps'], 1),
         fmt(s['median_qps']/pool_baseline, 3)+'×' if pool_baseline and s['group']=='pool' and s['rounds']==2 else '—',
         fmt(s['min_qps'], 1)+' ～ '+fmt(s['max_qps'], 1), ' / '.join(fmt(v) for v in s['run_p99_ms'])] for s in summaries]))
    api = {s['mode']: s for s in summaries if s['group'] == 'api'}
    if all(m in api and api[m]['rounds'] == 2 for m in ('direct', 'driver')):
        a, b = api['direct']['median_qps'], api['driver']['median_qps']
        add('<p>driver / direct 中位吞吐比：'+fmt(b/a, 3)+'；driver 相对变化 '+fmt((b/a-1)*100)+'%。'
            '仅表示这次相同 SQL/连接/并发下的端到端差异，不是独立测出的序列化耗时；两轮不构成统计显著性证明。</p>')
    else:
        add('<p>API 对照未完成两组各两轮，不计算完整对照结论。</p>')
    add('<p>pool 按配置正序、反序各测一轮；API 按 direct → driver → driver → direct。每轮新建池，'
        '在同一份测试表上重置计数并预热；既有版本/缓存/表膨胀不会被清除。不同并发的两组不可相互作吞吐倍率比较。</p>')
    add(table(['阶段', '模式/池/并发', '开始 s', '时长 s', 'QPS', 'SQL/s', 'P99 ms', 'max ms', '错误', '状态'], [
        [s['name'], f"{s['mode']}/{s['poolsize']}/{s['concurrency']}",
         fmt(s.get('start_epoch_s', origin)-origin, 1), fmt(s.get('result', {}).get('elapsed_s'), 1),
         *[fmt(s.get('result', {}).get(k)) for k in ('requests_per_s', 'sql_statements_per_s', 'p99_ms', 'max_ms', 'errors')],
         s.get('status')] for s in stages]))
    add('<h2>3. 同步指标与时间线</h2><div class="charts">')
    def load_points(fn):
        return [(s.get('epoch_s'), fn(s)) for s in samples]
    def os_points(source, key, scale=1):
        return [(s.get('epoch_s'), s.get(source, {}).get(key)/scale if number(s.get(source, {}).get(key)) else None) for s in os_samples]
    add(chart('吞吐：请求/秒', [('QPS', '#14867a', load_points(lambda s: s.get('requests_per_s')))], origin))
    add(chart('窗口延迟：毫秒', [(k, color, load_points(lambda s, k=k: s.get(k)))
                               for k, color in [('p99_ms', '#ce8230'), ('max_ms', '#bd4353')]], origin))
    add(chart('OS CPU：100% = 一个逻辑核', [(name, color, os_points(name, 'cpu_pct'))
              for name, color in [('moon', '#377dcc'), ('pg', '#14867a')]], origin))
    add(chart('OS RSS / Working Set：MiB', [(name, color, os_points(name, 'rss_bytes', 1024**2))
              for name, color in [('moon', '#377dcc'), ('pg', '#14867a')]], origin))
    add(chart('driver 等待队列 / 在途', [(key, color, load_points(lambda s, k=key: s.get('resources', {}).get(k)))
              for key, color in [('driver_queue', '#377dcc'), ('driver_inflight', '#ce8230')]], origin))
    add(chart('PG 采样耗时：毫秒', [('monitor', '#14867a', load_points(lambda s: s.get('pg_sample_ms')))], origin))
    add('</div>')
    resource_rows = []
    for stage in stages:
        if not number(stage.get('start_epoch_s')) or not number(stage.get('end_epoch_s')):
            continue
        windows = [s for s in os_samples if stage['start_epoch_s'] <= s['epoch_s'] <= stage['end_epoch_s']]
        row = [stage['name']]
        for source in ('moon', 'pg'):
            cpu = [s[source]['cpu_pct'] for s in windows if number(s.get(source, {}).get('cpu_pct'))]
            rss = [s[source]['rss_bytes']/1024**2 for s in windows if number(s.get(source, {}).get('rss_bytes'))]
            row += [f'{len(cpu)}/{len(windows)}', fmt(sum(cpu)/len(cpu)) if cpu else '—',
                    fmt(max(cpu)) if cpu else '—', fmt(max(rss)) if rss else '—']
        resource_rows.append(row)
    add(table(['阶段', 'Moon CPU 有效采样', '平均 %', '峰值 %', 'RSS 峰值 MiB',
               'PG CPU 有效采样', '平均 %', '峰值 %', 'RSS 合计峰值 MiB'], resource_rows))
    add('<p>CPU 为采样区间平均值，阶段边界可能覆盖少量前一阶段时间；PG OS 数据按本机接收时间对齐，'
        '远程采集有传输延迟。PG 匹配进程范围为配置的 OS 主机，不仅是本次测试连接。</p>')
    waits, db_rates, previous = Counter(), [], None
    for s in samples:
        pg = s.get('pg') or {}
        for w in pg.get('waits') or []:
            # Count sampled backend states, NOT time proportions and NOT CPU utilization.
            waits[(s['stage'], w.get('state'), w.get('wait_event_type'), w.get('wait_event'))] += 1
        db = pg.get('database')
        if db and number(s.get('pg_epoch_s')):
            t = s['pg_epoch_s']
            if previous and db.get('stats_reset') == previous[1].get('stats_reset') and t > previous[0]:
                row = [s['stage'], fmt(t-origin, 1)]
                for key in ('xact_commit', 'blks_read', 'blks_hit', 'blk_read_time', 'blk_write_time', 'deadlocks'):
                    a, b = db.get(key), previous[1].get(key)
                    row.append(fmt((a-b)/(t-previous[0])) if number(a) and number(b) and a >= b else '—')
                db_rates.append(row)
            previous = (t, db)
    add('<details open><summary>PG 等待事件：仅本轮负载连接，采样命中数</summary>')
    add(table(['阶段', 'state', '等待类型', '事件', '命中'], [[*key, count] for key, count in waits.items()]))
    add('<p>间歇采样会漏掉短等待；active 且无 wait_event 不等于 CPU 饱和。监控失败或未启用时不作零等待结论。</p></details>')
    add('<details><summary>PG 数据库级统计增量 / 秒</summary>')
    add(table(['阶段', '时间 s', 'commit/s', '块读取/s', '块命中/s', '读耗时 ms/s', '写耗时 ms/s', '死锁/s'], db_rates))
    add('<p>统计含同库其他会话、管理与监控连接，有刷新延迟；块读取不等于物理磁盘读取。'
        'track_io_timing=off 时耗时计数的零值不表示无 I/O。WAL/checkpoint 为实例级，表统计限本次 schema，详见 JSON。</p></details>')
    add('<details open><summary>正确性与清理</summary><pre>' + esc(json.dumps({k: report.get(k) for k in
        ('checks', 'final_resources', 'remaining_schemas', 'possibly_created_schema', 'cleanup_errors')}, ensure_ascii=False, indent=2)) + '</pre></details>')
    add('<details><summary>配置及数据库环境（不含密码）</summary><pre>' + esc(json.dumps({k: report.get(k) for k in
        ('config', 'database_environment')}, ensure_ascii=False, indent=2)) + '</pre></details>')
    add('<p>所有请求等待完成；不重试 SQL。延迟含排队、参数处理、DB、解码及跨服务返回，不含随后校验；'
        '吞吐包含校验与采样开销。P99 为全部成功请求直方图近似值，不是窗口 P99 平均数。'
        '第三项监控与全部阶段同步，不额外增加一段五分钟负载。原始数据保存在同目录 JSON。</p></main></html>')
    return ''.join(parts)
