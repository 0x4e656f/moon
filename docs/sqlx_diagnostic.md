# SQLx 五分钟性能诊断

用于验证三件事：增加连接是否有用、`ext.sqlx` 与 `lrust_sqldriver` 的端到端差异，以及同时观测 Moon/PG 资源和数据库等待。**不运行 libpq，不修改业务 driver、Rust 或数据库全局配置。**

## 配置与运行

需要 Python **3.10+**（仅标准库，无需 pip）、已经构建好的 Release Moon 和配套 Rust 库。配置文件是 `example/sqlx_diagnostic/config.json`，不读取环境变量，也不读取或改动旧压测配置。

1. 填写 `host/port/database/user/password` 和 TLS 参数。必须是允许建 schema 的**专用测试库**，不要使用生产库。
2. 确认后设 `allow_write=true`。默认关闭，避免误写。密码仅保存在你的本地配置，不要提交真实密码。
3. 从仓库根目录执行：

```powershell
python tools/sqlx_diagnostic/run.py
```

Linux：

```sh
python3 tools/sqlx_diagnostic/run.py
```

可先检查计划，不启动 Moon、不连接数据库、不启动 SSH：

```sh
python tools/sqlx_diagnostic/run.py --check
```

`--config path/to/config.json` 可指定另一份配置；其他测试参数全部在 JSON 中。文件中的可执行文件、证书、输出目录相对仓库根目录解析，也支持绝对路径。**不要直接运行 Lua 入口**：启动器提供运行配置并独立采集 Moon 进程资源。

默认依次执行：

| 验证 | 顺序 | 请求并发 | 每轮正式负载 |
| --- | --- | --- | --- |
| 连接数量 | driver：4→8→16→16→8→4 条连接 | 固定 32 | 20 秒，共 120 秒 |
| API 开销 | direct→driver→driver→direct | 固定 8，连接固定 8 | 30 秒，共 120 秒 |
| 资源与 PG 等待 | 与全部阶段同步 | 不额外增加负载阶段 | 全程 |

每轮预热 2 秒，共 20 秒；最后关闭负载池、执行一次压测 Lua GC，再空闲观察 10 秒。**负载+预热+空闲共 270 秒**，加上建连、校验、排空和清理，正常约 5 分钟。网络或数据库慢时可能更久：默认整轮安全期限 360 秒，启动器再给 15 秒退出宽限；不是到第 300 秒就强杀 SQL。

两轮正反序/ABBA 只能减少时间漂移影响，不消除缓存、表膨胀或后台任务影响，也不构成统计显著性证明。每轮重新建池，在相同 schema 上重置计数并预热，不清空 PG 缓存，不执行 VACUUM 或统计重置。

## 配置字段

JSON 不支持注释，对照此表修改：

| 字段 | 含义 |
| --- | --- |
| `allow_write`、数据库/TLS 字段 | 显式写入授权及连接参数，独立测试 schema 自动创建/清理 |
| `threads` / `driver_thread` | Moon worker 数/driver 所在 worker；不改变 Tokio 线程数 |
| `cache` / `timeout_ms` | 每连接语句缓存/建连与执行超时，不是 driver 队列总等待期限 |
| `pool_sizes` | 不重复的连接数列表，自动正序和反序各测一次 |
| `sweep_concurrency` / `sweep_duration_ms` | 连接数实验的固定请求并发和每轮时长 |
| `compare_poolsize` / `compare_concurrency` / `compare_duration_ms` | API 对照参数；两种模式一致，并发不得超过连接数，以免把两种排队策略差异混作包装成本 |
| `warmup_ms` / `idle_ms` | 每轮预热/全部负载结束后空闲；0 禁用 |
| `deadline_ms` / `shutdown_grace_ms` | Lua 整轮安全期限/启动器额外退出宽限；超过后仅终止自己启动的 Moon，不终止 PG |
| `think_ms` / `seed` | 闭环请求完成后停顿/每协程随机种子；不是固定请求到达率 |
| `workload` | 请求类型和权重，两项实验一致。默认将原报告 hot_lane 的 5% 加到 point，去掉仅 driver 支持的 hot_lane，因此不能与原报告直接作等负载比较 |
| `data_rows` / `rows` / `bytes` / `tx_size` | 数据集行数、多行读取行数、二进制大小、事务更新条数 |
| `validate_every` | 重结果完整验证间隔；预热完整校验，正式测试第一次及每隔指定次数完整校验，其他请求检查结构 |
| `sample_ms` / `checkpoint_ms` | Lua/PG 指标采样周期/原始 JSON 检查点周期 |
| `pg_stats` / `monitor_timeout_ms` | 是否采集 PG 统计/独立监控连接的执行与建连超时 |
| `moon_executable_windows` / `moon_executable_linux` | 已编译 Moon 路径，不自动编译 |
| `output_directory` | 输出根目录，每次生成新的唯一子目录，不覆盖旧报告 |
| `run_label`、日志字段 | 机器、构建版本等备注；请勿放密码或 URL |
| `monitor.sample_ms` | 独立 Python OS 采集周期；默认 1 秒，不在请求路径调用系统命令 |
| `monitor.pg_os_mode` | `disabled` / `local` / `ssh`，见下文 |
| `monitor.pg_process_names` | 要匹配的 PG 可执行文件名，不含 `.exe`；默认 postgres/postmaster |
| `monitor.ssh_target` / `ssh_port` / `ssh_python` | 已有 SSH 主机别名或 user@host、端口、远程 Python 3 可执行文件 |

错误后停止发新请求、等待在途完成；所有写入等待确认，**绝不重放失败/未知结果的写入**。每轮预热及正式负载结束都验证每个协程的落库计数和合计值，并检查 SQLx waiting/ready 已释放。正式负载中不强制 GC。

## PG 远程 CPU / 内存采集

Moon 的 CPU 和整个进程 RSS/Working Set 自动采集，包含 Rust/C++，不是 Lua `collectgarbage` 数值。Windows 使用 Win32 进程 API，Linux 读取 `/proc`。首次或新出现的 PID 没有 CPU 差分基线，留空而不是填 0。

**PG 在另一台机器上，SQL 连接本身无法获取那台机器的进程 CPU/RSS。** 默认 `pg_os_mode="disabled"`，报告明确显示未采集；PG 等待事件及数据库统计仍自动采集。

Linux PG 主机可配置免交互 SSH：

```json
"monitor": {
  "sample_ms": 1000,
  "pg_os_mode": "ssh",
  "pg_process_names": ["postgres", "postmaster"],
  "ssh_target": "monitor@your-pg-host",
  "ssh_port": 22,
  "ssh_python": "python3"
}
```

SSH 使用已有密钥/代理和已确认的 known_hosts，启用 BatchMode/StrictHostKeyChecking，不弹密码、不自动接受新主机密钥、不修改 SSH 配置。只向远程 Python 标准输入传入只读采集代码，不上传文件、不连接/修改远端数据库。远端需 Python 3.10+ 和读取 PG 进程的权限；受 `/proc` hidepid 等限制时会缺失，不能当作 0。远端采集器有自己的期限，连接断开后不会无限运行。SSH 模式要求远程为支持 POSIX shell 的 Linux 环境。

若 PG 与 Moon 确实在同一个 OS/进程命名空间，可设 `pg_os_mode="local"`，Windows/Linux 都支持。**远程 PG、WSL 或容器中的 PG 不能误用本机采样替代。** 采集范围是指定主机上所有匹配的 PG 进程，可能包括其他实例；不要与本次负载连接的 CPU 混淆。

OS CPU 口径为 `100%=一个逻辑核`，多核可超过 100%，不是 Windows 任务管理器除以总核数后的数值。PG RSS 合计会重复计算共享内存映射，**不等于 PG 独占物理内存**。Moon RSS 也可能因分配器缓存而不回落，短测不能证明无泄漏。

## 数据库指标

另开一条监控连接，使用同一数据库用户，每次在独立自动提交查询中读取：

- 本轮负载连接 PID 对应的 `pg_stat_activity` state/wait_event_type/wait_event，不记录 SQL 文本。
- `pg_stat_database` 的提交、块命中/读取、I/O 时间、死锁等累计值及增量。
- 当前测试 schema 的更新、HOT 更新、live/dead tuple 估计、autovacuum 次数。
- 实例级 `pg_stat_bgwriter`、PG 14+ 的 `pg_stat_wal`、PG 17+ 的 `pg_stat_checkpointer`。
- PG 版本、服务端地址、fsync/synchronous_commit/full_page_writes、统计开关和缓冲配置。

SQL 统计不需要安装扩展，不自动授予权限，不修改 PG 配置。普通同用户会话通常可见自己的负载连接；权限不足、监控超时等会记录警告并停止该次 PG 监控，但保留负载结果。此时测试 complete **不代表监控完整**。

等待事件命中数不是等待时间百分比；2 秒采样可能漏掉毫秒级尖峰。`active` 且无等待不等于 CPU 饱和。数据库级数据包含同库其他业务/管理/监控连接；WAL/checkpoint 是实例级，统计有刷新延迟，统计重置的窗口不计算增量。`track_io_timing=off` 时 0 毫秒不表示没有 I/O；块读取可能命中 OS 缓存，不能直接当作物理磁盘读。参见 [PostgreSQL 14 统计文档](https://www.postgresql.org/docs/14/monitoring-stats.html)。

## 报告与异常

输出示例：

```text
target/sqlx_diagnostic_<时间_随机ID>/
    report.html       自包含图表、对照汇总、分阶段资源和等待事件
    report.json       合并后的完整数据，后续分析请提供这个文件
    raw.json          Lua 运行检查点/最终结果
    os.jsonl          独立 OS 采样，逐行刷新
    pg-monitor.log   PG 系统采集器/SSH 诊断日志
```

HTML 在启动时先创建“运行中”页面，进度见控制台和 raw.json，结束后自动更新。完整报告分开列出数据测试结果和监控警告；CPU/RSS 缺失时留空，不伪造零值。API 两种模式各完成两轮才计算完整吞吐比；P99 来自各轮直方图，不平均成一个假的总 P99。

配置会转成一次性临时 Lua 文件供 Moon bootstrap 使用，包含密码，在退出时删除；Linux 临时文件权限为当前用户私有，Windows 使用当前用户临时目录 ACL。最终报告不含 password/sslkey/完整连接 URL，但主机、数据库名、用户名、SSH 目标和错误等仍可能敏感，分享前检查。不要把日志/报告公开到不可信位置。

每次只清理自己确认成功创建的 `moon_sqlxdiag_<本次ID>` schema。CREATE 结果不确定或负载池关闭未确认时保留并报告，不冒险删除。普通失败仍生成 HTML。安全期限/中断/强杀不保证在途 SQL 回滚；断电可能遗留 schema 和临时文件，务必根据本次精确名字检查，禁止批量清理其他 schema。

## 离线验证

以下命令不运行 Moon、不加载真实 SQLx、不连接数据库或 SSH：

```powershell
python -m unittest discover -s tests/sqlx_diagnostic -p "test_*.py" -v
.\target\libpq-tests\bin\libpq_lua_test.exe tests/sqlx_diagnostic/offline.lua
```

第二个程序仅使用已有独立 Lua/JSON 测试环境。覆盖计划顺序/时长、配置拒绝、生成 Lua 转义、PID 复用、缺失指标、报告倍率/HTML 转义、PG SQL 构造、完整模拟阶段、请求失败、监控失败、deadline、建 schema 不确定、关闭/清理/导出失败。

**五分钟测试无法复现或排除原来约 15 分钟后才出现的下降，也无法给出生产容量/无泄漏保证。** 本次的目标是先用较短时间缩小瓶颈范围。
