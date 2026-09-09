-- SQLx/PostgreSQL 压测的唯一配置入口；不读取环境变量。
-- 从仓库根目录运行：target/release/moon.exe example/stress_sqlx_pg.lua sqlxstress manual
-- 只能使用专用测试库。确认后开启 allow_write，不要提交真实密码。
return {
    allow_write = true, -- 自动创建、写入、清理独立 moon_sqlxstress_... schema
    host = "172.31.129.249",
    port = 5432,
    database = "moon_bench",
    user = "neo",
    password = "Maxiang123,",
    sslmode = "disable", -- disable / require / verify-ca / verify-full
    sslrootcert = "",    -- 路径均相对仓库根目录，或用绝对路径（Windows 建议 /）
    sslcert = "",
    sslkey = "",

    threads = 4,         -- Moon worker 数，2..255；不改变 Rust 运行时线程数
    driver_thread = 2,   -- driver 所在 worker，2..threads
    enable_stdout = true,
    loglevel = "INFO",   -- DEBUG / INFO / WARN / ERROR
    run_label = "",      -- 自填机器、构建版本、提交号等；不要放密码/连接 URL
    mode = "driver",     -- driver：真实 client→service→连接池；direct：直接 ext.sqlx
    poolsize = 4,        -- 全部阶段复用同一个连接池，另有一条管理连接
    cache = 100,         -- 每连接 SQL 语句缓存容量，0 禁用
    timeout_ms = 30000,  -- 建连/执行及 PG statement/lock 超时，不是整条队列的等待上限

    -- 依次执行，duration_ms 是持续发请求的时间；到期后等待在途请求完成。
    -- direct 模式下每阶段 concurrency 必须 <= poolsize。
    stages = {
        {name = "baseline", concurrency = 4, duration_ms = 60000},
        {name = "pressure", concurrency = 32, duration_ms = 300000},
        {name = "soak", concurrency = 32, duration_ms = 1800000},
    },
    warmup_ms = 10000,        -- 每阶段预热，0 禁用；不计入正式吞吐，仍校验结果和写入
    idle_ms = 60000,          -- 全部负载结束后保持池开启、空闲观察；0 禁用
    collect_at_idle = true,   -- 空闲观察前执行一次 Lua GC，报告标记；负载中不强制 GC
    deadline_ms = 2700000,    -- 整体安全期限，含初始化、预热、排队排空、空闲和清理
    think_ms = 0,            -- 每协程请求完成后的停顿，0 为闭环满负载；不是固定到达率
    seed = 12345,            -- 每协程独立的确定性随机种子，不影响其他框架随机数

    -- 混合请求的相对权重（无需合计 100）；删除某项即可不测它。
    -- tiny/point/mixed_rows/bytea/bytea_send/bytea_read/json_array/write/transaction/batch/hot_lane
    -- hot_lane 仅支持 driver，所有此类请求进入第 1 条 lane。
    workload = {
        {name = "point", weight = 35},
        {name = "write", weight = 25},
        {name = "transaction", weight = 10},
        {name = "mixed_rows", weight = 10},
        {name = "bytea", weight = 5},
        {name = "json_array", weight = 10},
        {name = "hot_lane", weight = 5},
    },
    data_rows = 4096,          -- 基础样本表行数，必须 >= rows
    rows = 256,               -- mixed_rows 每次返回行数
    bytes = 16384,            -- bytea 系列的 payload 字节数
    tx_size = 5,              -- 每个 transaction/batch 请求内的 UPDATE 数
    validate_every = 100,     -- 每协程、每类重结果的第 1、101…次完整校验；1 全量校验
    fifo_check = true,        -- driver 启动后执行不计时的同 key FIFO 检查
    stop_on_error = true,     -- 首个请求/校验错误后停止发新请求并排空；false 继续记录，不重试 SQL
    error_samples = 20,       -- 每阶段保留前 N 个错误详情；错误计数始终完整

    sample_ms = 5000,         -- 时间序列采样周期；每个窗口分别统计吞吐和延迟
    sample_driver = true,     -- 采集 lane 队列、inflight、连接数和 driver Lua 内存；direct 时忽略
    checkpoint_ms = 60000,    -- JSON 检查点间隔，>= sample_ms；阶段结束也保存
    log_progress = true,      -- 写定时检查点时输出当前阶段和窗口指标；可关闭减少日志
    max_samples = 20000,      -- 限制报告记录数，不是数据库队列容量；超出计划在建连前拒绝
    min_stage_qps = 0,        -- 可选验收门槛：每阶段 QPS 下限，0 不检查
    max_stage_p99_ms = 0,     -- 可选验收门槛：每阶段成功请求 p99 上限，0 不检查

    output = "",             -- 留空：target/sqlx_stress_<唯一标识>.json；指定时父目录必须存在
    html_report = true,       -- 自动生成自包含 HTML 图表，无网络/CDN/外部脚本
    html_output = "",        -- 留空：与 JSON 同名的 .html；不覆盖已有报告
}
