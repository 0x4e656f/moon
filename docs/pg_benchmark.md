# libpq 与 Rust/SQLx 性能对比

入口：`example/benchmark_pg.lua`。这是需要手动运行的 PostgreSQL 基准测试，不会替换业务 driver，也不会自动编译、启动数据库。

比较的是当前仓库的 `moon.db.libpq` / `libpq_sqldriver.client` 与 `ext.sqlx` / `lrust_sqldriver.client`。不是旧的纯 Lua `pg.lua`。两边使用同一组 PG 参数、SQL、数据、连接数、并发数、超时和语句缓存容量。

## 运行前

- 编译当前版本的 **Release Moon 和当前 `ext/lrust` 的 Rust 动态库**，确保加载的不是旧 SQLx 二进制。libpq 的准备方式见 [libpq.md](libpq.md)。
- 准备专用测试数据库和有建 schema 权限的测试用户。禁止对生产库运行。
- 测试会在 `moon_pgbench_...` 随机命名的独立 schema 中建表、写入，正常结束或普通错误时清理该 schema；不修改已有业务表。
- 超时、断电或强行终止可能留下测试 schema。JSON 的 `remaining_schemas` 记录已确认创建、尚未清理的目标，人工核实后再清理。建 schema 的应答丢失等极端情况仍需检查库内实际状态。
- 建连、建表、预热、校验写入总数和清理不计入性能数据。测试不自动重试超时/失败 SQL，避免重复写入。

当前默认是正式测量配置：6 轮、每轮至少 2 秒，含普通并行和额外 32 并发压力组。完整两边对比的**测量 + 预热至少约 16 分钟**，另加建表、校验、清理及慢请求排空时间；全局期限为 30 分钟。启动时会打印计划下限，明显不可能在期限内完成的计划会在建连前拒绝。

所有配置集中在 [example/pg_bench/config.lua](../example/pg_bench/config.lua)，每一项都附有中文说明。测试脚本不再读取环境变量，也不再支持环境变量覆盖配置。

先编辑配置文件中的这些字段（其余保留文件中的值）：

```lua
allow_write = true,          -- 确认是专用测试库后开启
host = "127.0.0.1",
port = 5432,
database = "moon_bench",
user = "moon_bench",
password = "你的测试密码",   -- 不要提交真实密码到版本库
sslmode = "disable",         -- 仅可信本地测试；远端建议 verify-full + sslrootcert
```

从仓库根目录运行，Windows：

```powershell
.\target\release\moon.exe example/benchmark_pg.lua pgbench manual
```

Linux 使用同一份配置文件和测试代码：

```sh
./target/release/moon example/benchmark_pg.lua pgbench manual
```

命令末尾 `pgbench manual` 是当前框架主程序读取的两个标识参数，不是数据库参数。请保留。

默认 Windows 使用仓库 `clib/libpq/libpq.dll`，Linux 使用系统 libpq。可用配置项 `library` 指定其他已准备好的库文件路径。TLS 默认 `require`，支持 `sslmode=disable/require/verify-ca/verify-full` 与 `sslrootcert`、`sslcert`、`sslkey`；不使用可能自动降级的 `prefer`。

证书、动态库和报告的非空路径统一相对**仓库根目录**，也支持绝对路径；不相对配置文件目录。Windows 路径建议用 `/`。Moon 改变工作目录不影响配置加载或这些路径。可选路径用空字符串表示自动/不显式指定。

## 测试内容

| 用例 | 测试内容 | 正确性检查 |
| --- | --- | --- |
| `tiny` | 参数化单行查询，观察固定调用成本 | 请求编号及 integer 类型 |
| `point` | bigint 主键点查 | ID、整数、布尔、文本 |
| `mixed_rows` | 默认一次返回 256 行混合字段 | 每次检查行数；完整检查时逐行检查所有字段 |
| `bytea` | 默认 16 KiB 二进制参数与结果往返 | 每次检查长度；完整检查时比对全部字节 |
| `bytea_send` | 发送 bytea 参数，PG 只返回 octet_length | 返回长度及 bigint 类型，侧重参数上传路径 |
| `bytea_read` | 从独立表读取预存 bytea，只发送整数主键 | 长度及完整字节，侧重结果下载路径 |
| `json_array` | JSONB 和 bigint[] 往返 | 中文、嵌套对象、JSON null、64 位整数上下限 |
| `write` | 等待完成的参数化 UPDATE | affected rows 与最终落库总数 |
| `transaction` | 默认 5 条参数化 UPDATE 的事务 | 事务累计 affected rows 与最终落库总数 |
| `batch` | 默认 5 条无参数 UPDATE 的 batch | 累计 affected rows 与最终落库总数 |
| `hot_lane` | 仅 driver：所有并发请求固定到同一连接 | 每次返回值；反映串行排队成本 |

driver 测量前另有不计时的同 key FIFO 检查：并发提交带前值条件的递增更新，请求乱序会导致更新失败。该检查针对同一发送 service 的入队顺序，不定义多个 service 之间的全局时序，也不证明故障后的顺序。

普通写入为每个压测协程分配独立计数行，以免数据库行锁竞争掩盖 driver/连接池成本。`hot_lane` 才刻意汇聚到一条 lane。每个请求都等到回应；不使用 fire-and-forget 的 `execute` 去冒充完成吞吐。

逐 lane 预检及并发预热全部进行完整校验。计时阶段，`mixed_rows` / `bytea` / `bytea_read` 默认在**每个协程**的第 1、101、201…个请求完整校验，其余请求检查行数/长度；其他用例始终完整校验。设置 `validate_every=1` 可恢复所有请求完整校验，但会增加压测端开销。抽查不是完整正确性证明，协议/异常/数据完整性仍由功能测试覆盖。

写入结果不仅核对总数，还逐个协程核对实际落库值，避免“总量相同但写错计数行”被漏过。事务语句模板在计时前创建，公开 API 内部的参数转换/编码成本仍计入测量。

`bytea_send` / `bytea_read` 使用不同 SQL，只能帮助缩小上传/下载瓶颈范围，不能视作纯网络或纯解码微基准。报告中的 MiB/s 只统计应用二进制 payload，**不含 PG 协议、文本 hex 膨胀或 TLS 开销**。

## 两种调用层次

- `direct`：每边创建 `poolsize` 条物理连接，每个并发协程固定使用一条。绕过 sqldriver，用来观察绑定、数据库协议和编解码成本。要求 `concurrency <= poolsize`。
- `driver`：使用各自真实的 client → service → 连接池路径。两边 driver 都放在配置的 `driver_thread`（默认 Moon worker 2），通过整数 key 精确映射到对应 lane。支持并发数大于池大小，测量包含队列等待和跨 service 序列化。

`driver_concurrencies={32}` 会在基准 `driver` 组之外追加 `driver_c32`：同样的池大小，但使用 32 个请求协程。可以配置多个不同值，例如 `{16,32,64}`；`{}` 关闭额外组。仅在 mode 包含 driver 时执行，不能与解析后的基准 concurrency 重复。每组重建连接池和独立 schema，并单独执行 FIFO 检查。**两边在同一组内对比**；不同并发组的吞吐/延迟差不能直接当作 driver 开销。

每条连接都会核对数据库、用户、服务端地址/版本、UTF-8、UTC、TLS，并确认各 lane 的 backend PID 不同。两套被测池共 `2 * poolsize` 条连接，另有一条管理连接；只跑单边时为 `poolsize + 1`。先建好两边连接，然后逐个测，不同时向数据库施加 A/B 压力。

每个用例分多轮执行，轮换先后顺序，执行前预热；默认 6 个偶数轮使两边先测的次数相同。每轮同时满足最低请求数和最低时长才停止发新请求，然后等待所有在途请求完成；不在时长到达时截断事务或丢弃慢请求。缓存容量相同，但两边内部缓存策略、协议和返回结果包装本身的成本仍是测量的一部分。GC 保持开启。管理连接通过 UPDATE 重置计数数据，不往被测连接缓存里插入重置 SQL，也不在预热后用 TRUNCATE/DDL 使服务端计划失效。

## 配置

以下字段均在 `example/pg_bench/config.lua` 的返回表内。数字用 Lua 数字而非字符串；开关用 `true` / `false`。未知字段或非法类型会报错，不会静默使用旧值。

| 配置项 | 文件中的初始值 | 含义 |
| --- | --- | --- |
| `allow_write` | `false` | 确认专用测试库后改为 true，否则拒绝连接数据库 |
| `host` / `port` | `127.0.0.1` / `5432` | 单个 TCP 主机和端口 |
| `database` / `user` | `moon_bench` / `moon_bench` | 修改为实际测试库和用户 |
| `password` | `""` | 测试密码，不写入报告；无需密码的测试认证可留空 |
| `sslmode` | `require` | 明确的 TLS 策略 |
| `sslrootcert` / `sslcert` / `sslkey` | `""` | CA / 客户端证书 / 客户端私钥路径 |
| `library` | `""` | libpq 路径；留空采用对应平台的库 |
| `mode` | `both` | `direct` / `driver` / `both` |
| `implementation` | `both` | `libpq` / `sqlx` / `both` |
| `poolsize` | `4` | 每边物理连接数 |
| `concurrency` | `0` | 同时等待请求的协程数；0 自动等于 poolsize |
| `driver_concurrencies` | `{32}` | 额外独立的 driver 并发组；`{}` 关闭 |
| `threads` | `4` | Moon 工作线程数，2..255；不修改 Rust 自身运行时线程数 |
| `driver_thread` | `2` | 两边 driver 工作线程编号，2..threads |
| `enable_stdout` / `loglevel` | `true` / `INFO` | Moon 控制台日志与级别；DEBUG / INFO / WARN / ERROR |
| `rounds` | `6` | 每个用例、每边测量轮数；偶数平衡先后顺序 |
| `iterations` | `1000` | 每轮轻量用例的最低总请求数，不是每协程请求数 |
| `bulk_iterations` | `100` | 每轮 mixed_rows / bytea 系列 / transaction / batch 最低总请求数 |
| `warmup` | `100` | 最低总预热请求数，至少并发数；另逐协程预热一次 |
| `min_duration_ms` | `2000` | 每轮最低测量时长；与最低请求数同时满足，0 只按次数 |
| `warmup_duration_ms` | `500` | 每轮最低预热时长；与 warmup 次数同时满足 |
| `validate_every` | `100` | 重结果每协程完整校验的间隔；1 为全量，其余请求仍做结构检查 |
| `run_label` | `""` | 手工记录构建/提交/机器标识；不要放密码或 URL |
| `rows` | `256` | 大结果集每次返回行数 |
| `data_rows` | `4096` | 基础样本行数，必须不少于 rows |
| `bytes` | `16384` | bytea 字节数 |
| `tx_size` | `5` | transaction / batch 每个请求的 SQL 条数 |
| `cache` | `100` | 每条连接预处理缓存容量，0 禁用 |
| `cases` | `{}` | 全部用例；或数组，例如 `{"tiny", "bytea"}`；hot_lane 仅 driver 可用 |
| `timeout_ms` | `30000` | 建连/执行超时及 PG statement/lock timeout |
| `deadline_ms` | `1800000` | 全局安全期限，含所有额外组；触发即标记无效并请求退出，不强杀进程 |
| `output` | `""` | 自动生成 target/pg_bench_*.json；也可指定路径，父目录须存在，拒绝覆盖已有报告 |
| `html_report` | `true` | 结束时自动生成离线 HTML 图表报告；false 仅保留 JSON |
| `html_output` | `""` | 留空使用与 JSON 同目录、同名的 .html；也可单独指定路径 |

队列容量限制在 driver 层均禁用，实际在途请求仍由压测并发数限制；libpq 的结果字节上限在本测试中关闭，SQLx 没有对应字节限制。两边都保留相同的行数上限。此配置是为对齐测试条件，不是生产环境容量建议。

默认已覆盖普通池并行与队列压力。以下是单独复测的组合，均先将 `driver_concurrencies={}`，避免重复追加压力组；每次退出后修改配置文件重新启动：

1. `poolsize=1, concurrency=1, mode="both"`：单连接基线。
2. `poolsize=4, concurrency=4, mode="both"`：通常的池并行性能。
3. `poolsize=4, concurrency=32, mode="driver"`：队列积压及热点串行场景。
4. 对以上组合分别设置 `cache=100` 和 `cache=0`，观察缓存收益。

例如只测 driver 高并发的查询与写入，在配置文件中修改对应字段：

```lua
mode = "driver",
poolsize = 4,
concurrency = 32,
driver_concurrencies = {},
cases = {"tiny", "point", "write", "transaction", "hot_lane"},
rounds = 6,
iterations = 10000,
bulk_iterations = 1000,
min_duration_ms = 3000,
warmup_duration_ms = 500,
```

只想先检查可运行性：设置 `driver_concurrencies={}`、`rounds=2`、`min_duration_ms=0`、`warmup_duration_ms=0`，其余次数按需减小。此时报告会提示短测量/小样本，不要把这类结果当作最终性能结论。

至少 2 秒不保证 p99 样本充足：慢事务在该时长内仍可能不足 1000 个请求。可以增大 `bulk_iterations` 或时长，同时提高 `deadline_ms`。计划下限不包含超出最低时长的请求、建连和清理，不能据此保证不会超时。

## HTML 图表报告

默认运行结束后同时生成两份文件，例如：

```text
target/pg_bench_标识.json
target/pg_bench_标识.html
```

双击 `.html` 用浏览器打开即可，不需要启动网站，不依赖 JavaScript、网络、CDN 或外部字体。样式与数据都在同一文件内。报告包含：

- 按 `direct` / `driver` / `driver_c32` 等实际分组的吞吐、p99 图；同图使用共同的线性刻度。
- 吞吐中位数与范围、p50/p95/p99/max 中位数、吞吐 CV（波动系数）、累计测量时长。
- 中位数吞吐比、同轮配对比值中位数、libpq 更快轮数及轮次范围是否重叠；不生成跨用例总分。
- 短测量、小样本、奇数轮、CV > 10%、校验占用 > 10% 等质量提示；阈值未触发也不等于显著差异。
- 每轮顺序、请求数、时长、峰值在途、完整校验次数、校验占比、预热时长、请求/SQL/行吞吐及 payload MiB/s。
- FIFO 校验、配置与数据库环境、清理错误及尚未清理的测试 schema。

配置示例（修改 `config.lua` 内对应字段）：

```lua
output = "target/my_pg_benchmark.json",
html_report = true,
html_output = "", -- 自动得到 target/my_pg_benchmark.html
```

启动时会检查 JSON/HTML 目标不同且均未被占用，并先生成标记为 `running` 的初始页面；测量中只更新 JSON，避免 HTML 渲染影响压测节奏。正常结束、SQL 错误或全局期限到达后重新生成 HTML。若强行终止或断电，HTML 可能停留在初始状态，最新完成的轮次以 JSON 检查点为准。

失败、超时、重复轮次、未达设定次数/时长、少于配置轮数、缺失计划用例/整组的报告标为无效，不显示优劣比值。完成了较少的配置轮数或短测试属于“完成但质量不足”，保留数值并提醒复测。缺失一边或没有有效轮次时显示 `—`，不填成 0。HTML 导出失败会使测试退出失败，并尽量将 `report_error` 写回 JSON，不能把这次运行当作完整成功。配置校验失败、目标冲突或目录不可写时，可能无法生成报告。

报告不输出密码或连接 URL，但仍包含测试库名、主机、用户和错误信息，分享前请检查。错误及数据文本均进行 HTML 转义，页面禁止执行脚本及加载外部资源。

## 如何看结果

- `RUN`：每轮成功请求/秒、p50/p95/p99/max 毫秒和错误数。延迟从调用公开 API 开始，包含参数处理、排队、数据库执行、结果解码与返回，不含之后的结果校验。
- v2 吞吐是成功请求数除以本轮开始发请求至所有响应完成校验/计数的时长，包含最后一次校验。旧版 v1 只算到最后回应，故不能忽略版本/校验策略变化直接做历史同比。`validation_wall_pct` 记录校验在压测协程所在 Lua 线程占用的墙钟比例，不是整个进程 CPU 占用。
- 这是固定在途并发数的闭环负载：收到回应才提交下一次请求，不模拟固定到达率或无限增长的生产队列。其 p99 不能代表超出服务能力时的生产长尾。
- `COMPARE libpq/sqlx=1.200x`：多轮吞吐中位数之比，表示该用例 libpq 约高 20%；`0.800x` 表示 libpq 约低 20%。这是一个比值，不是跨用例的总评分。
- JSON 保留每轮汇总、逐协程完成数、两边吞吐中位数、累计请求/累计时间吞吐、配对轮比值/范围、CV 与吞吐范围重叠。配对比值、CV 和范围重叠都是描述性统计，不是显著性检验或置信区间。
- 长测试不再保留/排序逐请求延迟数组，采用有界对数直方图统计全部成功请求；分位数取桶上界，舍入误差不超过约 1%（极短延迟最小桶为 1 ns）。mean/max 精确，直方图汇总不计入本轮时长，但逐请求计数会计入。`histogram_buckets` 可检查实际桶数；不是抽样后的 p99。
- transaction / batch 的 `requests_per_s` 是事务/批次每秒；`sql_statements_per_s` 是其中用户 SQL 的条数，不计 BEGIN/COMMIT。
- 任何请求错误、结果不正确、超时或清理失败都会标记报告无效；只使用 `status="complete"` 且无错误的结果比较。

没有一个单独的 QPS 可以证明“全面更好”。业务重视串行顺序时优先看 FIFO 检查、`hot_lane` 和 driver p99；业务重视大数据读取时看 `mixed_rows` / `bytea`；写入型业务看 `write` / `transaction`。

本套测试只测共同能力：Rust SQLx 的事务/batch 当前只回元数据，所以采用无 RETURNING 写语句；numeric 两边显式转 text。完整类型兼容与异常路径请另用各自功能测试。它不清空数据库/操作系统缓存，不修改 fsync 等数据库配置，不测建连耗时，也不将 Lua GC 内存或 `os.clock()` 伪装成整个 C++/Rust 进程的内存/CPU。资源占用需要独立进程单边运行并用外部监控测量。

## 无数据库自检

`tests/libpq/benchmark_unit.lua` 只使用纯 Lua 辅助函数、模拟调度器和模拟连接，检查统计、配置校验、启动阶段路径解析和 API 适配，并加载测试脚本及配置文件做语法检查。它不会启动 Moon、加载真实 SQLx/libpq 连接或访问网络。可用现有的独立 Lua 测试工具运行：

```powershell
.\target\libpq-tests\bin\libpq_lua_test.exe tests/libpq/benchmark_unit.lua
```

该自检不能代替手动连接 PostgreSQL 的实际基准测试。

整个入口流程也有离线测试，注入纯 Lua 的调度/数据库/报告桩，覆盖三组独立连接、计时、逐协程写入校验、错误清理、超时和 HTML 导出失败；不加载真实 Moon，也不读取数据库配置：

```powershell
.\target\libpq-tests\bin\libpq_lua_test.exe tests/libpq/benchmark_flow_unit.lua
```

HTML 渲染及文件输出的离线检查：

```powershell
.\target\libpq-tests\bin\libpq_lua_test.exe tests/libpq/report_unit.lua
```

它使用独立的模拟数据，不读取你的数据库配置，也不连接数据库；同时生成唯一命名的 `target/libpq-tests/report-preview-*.html` 和 JSON，用于人工检查排版。预览页面明确标注“模拟样例，非数据库实测”，不能作为性能结论。
