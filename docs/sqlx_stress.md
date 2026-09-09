# SQLx / PostgreSQL 持续压测

入口：`example/stress_sqlx_pg.lua`。唯一配置文件：`example/sqlx_stress/config.lua`。

只测当前 SQLx 方案，默认经过 `lrust_sqldriver.client → service → lane 连接池`，不加载 libpq。也可选择直接调用 `ext.sqlx`。复用之前 PG 对比测试的 SQL、类型校验、直方图和 API 适配，不修改原有对比测试配置或业务模块。

## 配置后运行

1. 准备 **专用测试数据库** 和允许建 schema 的用户。测试会写入数据，严禁指向生产库；长时间写入会产生大量 WAL，请预留数据库磁盘和日志空间。
2. 使用当前 Release Moon 与配套 Rust 动态库（Windows：`clib/rust.dll`；Linux：在目标系统构建、部署 `librust.so`）。测试不自动编译或升级程序。
3. 编辑 `example/sqlx_stress/config.lua`：填写 host、port、database、user、password、TLS 配置，确认测试库后将 `allow_write` 改为 `true`。
4. 从仓库根目录启动，之后无需人工切换阶段：

```powershell
.\target\release\moon.exe example/stress_sqlx_pg.lua sqlxstress manual
```

Linux：

```sh
./target/release/moon example/stress_sqlx_pg.lua sqlxstress manual
```

末尾的 `sqlxstress manual` 是框架启动需要的两个标识参数，不是数据库参数。保留即可。所有压测参数都在 Lua 配置中，不读取环境变量。证书和报告路径均相对仓库根目录，也支持绝对路径；父目录需要已经存在。

默认计划为：4 并发 1 分钟 → 32 并发 5 分钟 → 32 并发 30 分钟；每阶段预热 10 秒，结束后空闲观察 60 秒。负载、预热与空闲合计至少 **37.5 分钟**，另加建连、建表、校验、等待在途请求和清理，默认整体期限为 45 分钟。

先检查能否跑通，可把同一配置文件中的相关字段改为：

```lua
stages = {
    {name = "smoke", concurrency = 4, duration_ms = 10000},
},
warmup_ms = 1000,
idle_ms = 1000,
deadline_ms = 120000,
```

这只验证流程，不代表持续负载稳定。正式测试按机器和数据库能力逐步提高并发/时长；`direct` 每阶段并发不能超过 `poolsize`，`driver` 允许超过池大小，以测量排队影响。

## 可配置内容

配置文件每项均有中文说明，主要分为：

- 数据库/TLS：地址、端口、测试库、用户、密码、sslmode 和证书。
- 框架/连接：worker 数、driver worker、日志、`mode`、`poolsize`、SQL 缓存、超时。
- 负载阶段：`stages` 中的名称、并发、时长；同一进程中保持同一个池，不按阶段重建。
- 请求组合：`workload` 中的类型与相对权重。无需合计 100，各协程使用独立可重复的随机序列；实际比例和请求数保存在报告中。
- 数据规模：样本行数、每次查询行数、bytea 大小、事务/batch 的 SQL 数。
- 运行策略：预热、空闲观察、空闲前是否主动 Lua GC、思考时间、错误后是否停止、错误详情保留数。
- 采样/报告：窗口间隔、JSON 检查点间隔、记录数上限、JSON/HTML 输出路径。
- 进度日志：`log_progress=true` 时，定时 JSON 检查点会打印当前阶段、窗口 QPS/p99、错误数和响应登记数。
- 可选门槛：每阶段最低 QPS、最高成功请求 p99；0 表示不启用。错误、写入不一致、响应未释放、清理失败始终使测试不通过。

支持的 workload：

| 名称 | 内容 |
| --- | --- |
| `tiny` | 参数化单行查询，观察固定调用成本 |
| `point` | bigint 主键点查 |
| `mixed_rows` | 混合字段批量读取，含 JSON、数组、NULL、bytea、numeric 转 text |
| `bytea` | 二进制参数与结果往返 |
| `bytea_send` | 上传二进制，仅返回长度 |
| `bytea_read` | 读取预存二进制 |
| `json_array` | JSONB 和 bigint[] 往返，含中文、NULL、64 位整数边界 |
| `write` | 等待完成的 UPDATE |
| `transaction` | 多条 UPDATE 的事务 |
| `batch` | 多语句 UPDATE；不承诺原子性 |
| `hot_lane` | 仅 driver：此类请求全部路由到 lane 1 |

普通写入为每个请求协程分配独立计数行，避免把数据库行锁竞争误认为连接池成本。预热及每阶段结束后，都核对 **每个协程的实际落库值和合计值**。一条 transaction/batch 是一个请求，SQL 吞吐另按其中的语句数统计，不含 BEGIN/COMMIT。

`validate_every` 只影响 mixed_rows 和 bytea 等重结果的完整检查频率，按“每协程、每类请求”计数；第一次以及后续指定间隔进行完整检查，其他请求仍检查结构/长度。预热全量校验。未抽到某类请求会在报告中提示，不能视作覆盖。

压测是闭环负载：每个协程收到结果并校验后才发下一次；`think_ms` 是完成后的停顿，不是固定请求到达率。所有写入都等待响应，不用 fire-and-forget 计算完成吞吐，不自动重试任何失败/超时 SQL。

连接容量策略沿用对比测试适配：driver 的 `max_queue=0`，Rust 队列至少容纳最大压测并发加 1（最低 100）；结果行上限覆盖 `rows` 和计数校验需要的行数。实际在途请求由压测并发控制。本测试不用于验证较小业务队列上限触发 BUSY 的行为，也不改变业务 driver 的容量默认值。

`stop_on_error=false` 表示本阶段继续记录请求错误，不是重试；阶段结束后的写入核对、采样失败、验收门槛等仍可能中止后续阶段。写入返回失败或超时也可能已经提交，最终核对会报告不一致。

## 自动报告

默认输出唯一文件：

```text
target/sqlx_stress_<时间_服务ID_随机值>.json
target/sqlx_stress_<时间_服务ID_随机值>.html
```

启动会打印两个绝对路径，并在连接数据库前生成 `running` 初始报告，以检查输出位置是否可写。负载中按 `checkpoint_ms` 更新 JSON，每阶段结束也保存；正常结束、普通异常和整体期限到达后生成最终 HTML。导出失败会退出失败，不把 JSON 保留为成功状态。已有报告不会被正常覆盖启动，重新运行可使用自动路径或改文件名。

HTML 双击即可打开，不需要服务器、网络、JavaScript 或 CDN，包含：

- 分阶段及每类请求的成功数、错误、QPS、SQL/s、p50/p95/p99/max。
- 逐窗口吞吐、p95/p99、错误、driver 队列和压测在途曲线。
- 进程级 SQLx `waiting/ready` 响应登记曲线及负载结束/关闭后的检查。
- 压测 service 和 driver service 的 Lua 内存曲线、空闲前主动 GC 标记。
- FIFO、落库计数、响应释放、门槛等检查项，错误详情、数据库版本/PID、非敏感配置和未清理 schema。

**Lua KiB 不是进程 RSS，也不包含全部 Rust/C++ 内存。** 压测端自身保存的报告窗口会增加 Lua 内存，空闲期会保留工作负载模板；不能仅根据此曲线认定内存泄漏或证明无泄漏。需要判断原生内存和 CPU 时，请同时用系统监控记录整个 Moon 进程的 RSS/CPU。`waiting/ready` 也是数量而非字节，不统计已经消费但尚未销毁的租约。

时间序列按完成请求的窗口统计，延迟只包含成功且通过校验的请求；失败数量及详情单列。分位数使用有界对数直方图统计全部成功请求，不保留逐请求数组，近似桶上界误差约 1%（极短值最小桶为 1 ns）。阶段 p99 来自阶段直方图，**不是平均各窗口 p99**。低样本数和校验占用较高会有提示。

监控 RPC、Lua 校验和 JSON 检查点均有开销；采样间隔和检查点间隔可增大。压测服务只有一个 Lua 线程，CPU/序列化也可能先成为瓶颈。报告的混合总 QPS 只能在请求权重、数据量、并发和配置一致时比较，不应据此认定某种实现全面更快。

## 安全退出和异常

正常或普通错误退出会先排空、关闭测试池，再清理本次确认创建的独立 schema，最后关闭管理连接。不会清理已有业务表。CREATE 的结果不确定时，不会擅自删除该名字的 schema，而是在 `possibly_created_schema` 中提示人工核实。

整体期限到达时尽量保存 `deadline_exceeded` 报告并请求 Moon 退出，不强杀进程，也不保证服务器上的旧 SQL 立即停止。不要把超时后仍在执行的写入当成已回滚。

断电/强杀可能使 HTML 停留在初始页、正在写的 JSON 不完整，并留下测试 schema；即使没有报告也应检查 `moon_sqlxstress_...`。这是普通文件检查点，不是具有断电原子性保证的日志。只能根据明确属于本次测试的名字人工清理。

本脚本不自动停止 PostgreSQL、断网或终止数据库 backend。数据库故障恢复、连接重建和幂等仍需单独的受控故障测试。“配置内验收通过”不等于已证明可直接全量上线。

运行结束后，把 **JSON 与 HTML 的路径** 发给我即可分析，JSON 是主要原始依据。报告不写密码、URL、私钥，但包含主机、数据库名、用户及数据库错误，分享前请检查。

## 离线自检

不加载 Moon 或真实 SQLx 连接，不读用户数据库配置；使用独立 Lua 测试程序：

```powershell
.\target\libpq-tests\bin\libpq_lua_test.exe tests/sqlx_stress/unit.lua
.\target\libpq-tests\bin\libpq_lua_test.exe tests/sqlx_stress/flow.lua
```

程序名来自已有测试设施，此处仅使用其独立 Lua/JSON 环境，不运行 libpq 或 SQLx 数据库请求。第一项覆盖配置、调度、直方图、错误、采样、HTML 转义、路径冲突/写盘错误，并生成明确标注“模拟样例”的预览。第二项执行真实 bootstrap、注入模拟服务，覆盖 direct/driver、预热、计数、超时、请求失败、门槛、采样失败、建 schema 结果不确定、清理及 HTML 导出失败。
