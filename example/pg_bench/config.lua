-- PostgreSQL 对比测试的唯一配置入口；不读取环境变量。
-- 只修改此文件即可运行。数字用 Lua number，开关用 true/false。
-- 请使用专用测试库；不要把真实密码提交到版本库。
return {
    -- 安全开关：确认下方指向专用测试库后改成 true。
    -- 测试会创建、写入并删除自己生成的 moon_pgbench_... schema。
    allow_write = true,

    -- 两套实现共用的数据库配置，不接受各自独立的连接 URL。
    host = "172.31.129.249",           -- 单个 TCP 主机；IPv6 直接写 ::1，不加 []
    port = 5432,
    database = "moon_bench",
    user = "neo",
    password = "123",               -- 填写测试密码；无需密码的测试认证可留空

    -- disable / require / verify-ca / verify-full；不使用自动降级的 prefer。
    -- 可信本地测试可用 disable；远端建议 verify-full 并指定 CA。
    sslmode = "disable",
    sslrootcert = "",            -- CA 文件；空字符串表示不显式指定
    sslcert = "",                -- 客户端证书；空字符串表示不显式指定
    sslkey = "",                 -- 客户端私钥；空字符串表示不显式指定
    library = "",                -- libpq 路径；空字符串：Windows 用 clib/libpq/libpq.dll，Linux 用系统库

    -- Moon 启动配置，两边使用相同的 driver 工作线程。
    threads = 4,                 -- Moon 工作线程总数，2..255；不改变 Rust 运行时线程数
    driver_thread = 2,           -- driver 工作线程编号，2 <= driver_thread <= threads
    enable_stdout = true,
    loglevel = "INFO",           -- DEBUG / INFO / WARN / ERROR

    -- 测量对象与并发配置。
    mode = "both",               -- direct / driver / both
    implementation = "both",     -- libpq / sqlx / both
    poolsize = 4,                -- 每边物理连接数，1..1024
    concurrency = 0,             -- 0 自动等于 poolsize；direct 要求并发数 <= poolsize
    driver_concurrencies = {32}, -- 额外独立的 driver 压力组；{} 关闭，不可重复 concurrency
    cache = 100,                 -- 每条连接的预处理语句缓存容量，0 禁用

    -- 每轮总请求数，不是每协程请求数。
    rounds = 6,                  -- 偶数使两边先测次数相同；正式比较建议至少 6 轮
    iterations = 1000,           -- 轻量用例每轮最低请求数；达到请求数且达到时长后停止发新请求
    bulk_iterations = 100,       -- 大结果 / bytea / transaction / batch 每轮最低请求数
    warmup = 100,                -- 每次测量前预热；实际至少 concurrency 次，另逐协程预热一次
    min_duration_ms = 2000,      -- 每边每用例每轮至少 2 秒；0 恢复纯固定次数测试
    warmup_duration_ms = 500,    -- 每轮并发预热至少 0.5 秒；0 只按 warmup 次数
    validate_every = 100,       -- 重结果每协程首个及每 100 个完整校验，其余检查结构；1 全量校验
    run_label = "",             -- 可填写 git 提交/构建标识/机器说明；写入报告，不要包含密码

    -- 数据规模。
    rows = 256,                  -- mixed_rows 每次返回行数
    data_rows = 4096,            -- 基础样本行数，必须 >= rows
    bytes = 16384,               -- bytea 每次往返的字节数
    tx_size = 5,                 -- transaction / batch 每次请求包含的 SQL 条数

    -- 空数组表示全部；也可以只选部分，例如 {"tiny", "write", "transaction"}。
    -- 可选：tiny / point / mixed_rows / bytea / bytea_send / bytea_read / json_array / write / transaction / batch / hot_lane。
    -- hot_lane 仅 driver 模式适用。
    cases = {},

    -- 超时均为毫秒。执行超时不包含 driver 排队；全局期限包含整个测试与清理。
    timeout_ms = 30000,          -- 建连/执行超时，同时设置 PG statement_timeout 和 lock_timeout
    deadline_ms = 1800000,       -- 默认全套约 16 分钟起；30 分钟全局期限，超时标记无效并请求退出

    -- 所有非空文件路径均可写绝对路径，或相对仓库根目录；不相对本配置文件。
    -- Windows 路径建议使用 /，如 E:/certs/ca.pem。
    -- 空字符串自动生成 target/pg_bench_时间戳_标识.json；父目录必须存在，拒绝覆盖已有报告。
    output = "",

    -- 测试结束（包括普通失败 / 超时）后生成离线 HTML 图表报告，保留上面的 JSON。
    html_report = true,          -- false 只生成 JSON
    html_output = "",           -- 留空：与 JSON 同目录、同名 .html；也可指定独立路径
}
