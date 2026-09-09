# libpq：异步 PostgreSQL 绑定与队列 driver

使用 **预编译 libpq**，只编译 Moon 的 C++/Lua 绑定。Windows 与 Linux 的业务 API 相同，与 SQLx/Rust 无依赖；旧 `pg.lua`、`sqldriver.lua` 和 SQLx 实现保持不变。

## 1. 准备依赖和编译

Windows x64，在仓库根目录执行：

```powershell
powershell -File third/libpq/prepare-windows.ps1 -Download
premake5 vs2022
# 在 VS 中编译 moon 项目，或在 VS 开发者命令行中：
MSBuild target/projects/moon/moon.vcxproj /p:Configuration=release /p:Platform=x64 /m
```

部署脚本固定 EDB 18.6-3 并校验 SHA256，只提取 libpq、OpenSSL 等 6 个 DLL 和许可到 `clib/libpq`。不会安装或启动数据库。
也可使用已下载的 ZIP：`-Archive C:/Downloads/postgresql-18.6-3-windows-x64-binaries.zip`。
完整说明见 [third/libpq/README.md](../third/libpq/README.md)。

Linux 安装发行版的客户端运行库，例如 Ubuntu/Debian：

```sh
sudo apt install libpq5
premake5 gmake
make -C target moon config=release -j2
```

Linux 默认加载系统 `libpq.so.5`，无需编译 libpq/OpenSSL，也无需 `libpq-dev`。其他发行版请使用其对应包名。
要求 libpq 14+，推荐受支持版本的最新修复版。上面的 Moon 编译仍要求框架已有的 C/C++ 构建环境。

本分支不要用仓库原有的 `premake5 build` 动作：它包含切回 master / pull 的逻辑；`premake5 run` 会启动 Moon。生成工程与编译本身不会运行 Moon。

## 2. 直接使用连接

以下业务代码运行在 Moon 协程中：

```lua
local moon = require("moon")
local pg = require("moon.db.libpq")

moon.async(function()
    local db = pg.connect({
        host = "127.0.0.1", port = 5432,
        dbname = "game", user = "game", password = os.getenv("PGPASSWORD"),
        sslmode = "disable", -- 仅可信本地测试；生产应使用 verify-full + sslrootcert
        timeout = 5000,
    })
    assert(not db.code, db.message)

    local result = db:query("SELECT $1::bigint AS id, $2::bytea AS data", {
        9223372036854775807, pg.bytea("a\0b"),
    })
    if result.code then
        moon.error(result.code, result.sqlstate or "", result.message)
    else
        moon.info(result.rows[1].id) -- Lua integer，不经过 double
    end
    db:close()
end)
```

成功的单语句结果始终是 `{rows, columns, command, rows_affected}`；不是直接返回行数组。失败为 `{code, message, sqlstate?, detail?, hint?, constraint?, table?}`。
`connect` 返回连接或错误表，不抛出普通连接错误。原生异常、非法参数、解码错误会关闭连接，避免遗留未知状态。
事务的 SQL 成功提交后才构造 Lua 结果；若此时发生转换异常，返回 `code="DECODE", committed=true`，表示事务**已经提交**，不得把它当作回滚而重试。提交本身失败/断线仍可能意味着提交状态未知。

直接连接方法：

| 方法 | 行为 |
| --- | --- |
| `query(sql, params?, options?)` | 单条参数化 SQL，支持 `RETURNING` |
| `execute(sql, params?, options?)` | 与 `query` 相同的等待式结果接口 |
| `batch(sql, options?)` | 无参数多语句，返回 `{results={...}}`；PG simple-query 语义 |
| `transaction(statements, options?)` | `BEGIN`、逐条执行、`COMMIT`；失败回滚；返回 `{results={...}}` |
| `prepare(name, sql, param_types?, options?)` | 当前物理连接的命名预处理语句 |
| `query_prepared(name, params?, options?)` | 执行当前连接已准备的语句 |
| `connected()` | 本地连接状态，不发探活 SQL |
| `close()` | 立即关闭，在途操作被唤醒并失败；幂等 |

一条连接只允许一个在途操作；并发调用返回 `BUSY`。`transaction` 持锁覆盖整个事务，不能在其间插入其他查询。
整个事务一次提交到 C++，只有最终完成时才唤醒 Lua；BEGIN、所有用户 SQL、COMMIT/必要回滚和缓存准备共享原生总期限。SQL/参数会在 BEGIN 前全部校验。
不要自己发送 `BEGIN`/`COMMIT` 来跨请求管理事务；请使用 `transaction`。`batch` 不应包含显式事务控制语句，遇到错误会丢弃连接。

### 自动预处理缓存

`connect({..., statement_cache_capacity=100})`：每个物理连接默认缓存最多 100 条语句，LRU 淘汰；设置 0 禁用。这个选项只在建连时设置，driver 的 `opts` 同样有效。

- 缓存 SELECT/INSERT/UPDATE/DELETE/WITH/VALUES/MERGE，以完整 SQL 和参数 OID 序列为键；参数值不参与缓存键。
- 首次需要准备，后续命中直接执行；容量小且 SQL 种类很多时，准备与淘汰可能增加往返，可按业务调整或禁用。
- 淘汰时异步 DEALLOCATE 对应内部语句，释放服务器资源；断线时清空本地缓存。batch、DDL 和事务控制不自动缓存。
- 手动 `prepare` 与自动缓存独立，不计入自动容量；名称不得使用保留前缀 `__moon_pq_`。
- 不要从业务删除内部预处理语句。外部 DEALLOCATE/DISCARD 或表结构变化导致缓存失效时，当前请求返回原始数据库错误并在识别到失效计划时丢弃连接；不会自动重放 SQL。后续请求由 driver 重连。
- 连接到不保留会话级预处理语句的代理时，使用 `statement_cache_capacity=0`。

## 3. 连接池与业务串行顺序

`libpq.core` 是 C++ 模块，`moon.db.libpq` 是 Lua 模块，都不是独立 service。
只有 `service/libpq_sqldriver.lua` 是 service。业务端引用独立的 `libpq_sqldriver.client`，不会进入服务初始化代码。

```lua
local driver = require("libpq_sqldriver.client")
local db_service = moon.new_service({
    name = "game_db", file = "service/libpq_sqldriver.lua",
    poolsize = 4, max_queue = 0, reconnect_delay = 1000,
    opts = {
        host = "127.0.0.1", port = 5432, dbname = "game", user = "game",
        password = os.getenv("PGPASSWORD"), sslmode = "disable", timeout = 5000,
    },
})
assert(db_service ~= 0)

local key = "player:1001"
driver.execute(db_service, "UPDATE player SET gold=gold+$1 WHERE id=$2", {10,1001}, key)
local result = driver.query(db_service, "SELECT gold FROM player WHERE id=$1", {1001}, key)
-- 同一 key：上面的写请求先执行完，再执行查询。
assert(not result.code, result.message)

local tx = driver.transaction(db_service, {
    {sql="UPDATE player SET gold=gold-$1 WHERE id=$2", params={10,1001}},
    {sql="INSERT INTO trade_log(player_id,amount) VALUES($1,$2)", params={1001,10}},
}, key)
assert(not tx.code, tx.message)
```

每条 lane 是一个 FIFO + 一个按需建立的物理连接。`poolsize=4` 最多持有 4 条连接，不是建立一个只有单连接在工作的池。
相同整数/字符串 key 固定路由，缺省 key 为 **1**，保留旧 driver 默认串行语义。整数路由仍是 `key % poolsize + 1`；不同 key 可能碰撞。
顺序指服务端收到请求的顺序；不同发送者同时投递时，没有全局业务时间顺序保证。

- `driver.query` 等待结果；`driver.execute` 投递后立即返回，失败只在 driver 记录错误码。需要知道写入是否成功时，用 `query` 执行写 SQL。
- `driver.query_any` 选最空闲的队列，仅适用于不要求顺序的操作。
- `driver.transaction` 等待事务结果；`execute_transaction` 是不等待版本。
- `driver.batch` 等待多语句结果。
- `driver.stats` 返回各 lane 的 `waiting/running/connected`。
- `driver.save_then_quit` 停止接收请求，等队列和在途 SQL 结束，再关闭连接并退出。

连接失败后暂时退避，后续请求可重新建连。已经发出的 SQL 在断线、超时或提交失败时**绝不自动重放**；提交结果可能不确定，业务应使用幂等键或单独核实。
这和旧 driver 的断线重试不同，是有意避免重复写入的安全差异。
连接池不暴露命名 prepare：预处理语句属于单个物理连接，重连后失效。会话设置也会在重连后丢失；常规初始化设置请通过连接 `options` 传入。
自动预处理缓存由各 lane 的物理连接独立维护，不影响同 key 的 FIFO 顺序。

## 4. 类型规则

| PG 类型 | Lua 结果 / 参数 |
| --- | --- |
| `boolean` | boolean |
| `int2/int4/int8/oid` | Lua integer；完整 int64 范围 |
| `float4/float8` | number，包括 NaN/±Infinity |
| `numeric/money` | string，避免静默精度损失 |
| 文本、UUID、日期时间、interval、网络地址、bit | string，保留 PG 文本表示 |
| `bytea` | 原始二进制 string；输入用 `pg.bytea` |
| `json/jsonb` | JSON 解码后的 Lua 值；普通参数 table 默认 JSONB |
| 已知类型数组 | Lua 数组，保留 NULL；多维输出为嵌套数组 |
| 未知/扩展 OID，如 enum/range/geometry | 原始 string，不因未知类型报错 |
| SQL NULL | `pg.NULL`（等于 `json.null`），不会变成 nil 导致字段/元素消失 |

```lua
pg.typed("numeric", "123456789012345678901234567890.00001")
pg.typed("timestamptz", "2024-02-29 12:00:00+08")
pg.typed("int8", pg.NULL)  -- 有类型的 SQL NULL
pg.jsonb({name="x", extra=pg.NULL})
pg.jsonb(pg.NULL)          -- JSON null；SQL NULL 直接用 pg.NULL
pg.array("text", {"NULL", "a,b", pg.NULL, ""})
pg.array("bytea", {"a\0b", ""})
```

数组参数目前支持一维；带非默认下标（例如 `[0:1]={1,2}`）的输出保持文本，避免悄悄丢失下标。
参数列表必须是无空洞的序列；SQL 值只能通过 `$1` 等绑定，不能当成 SQL 标识符使用。
文本必须为 UTF-8，不允许 NUL；二进制使用 bytea。默认 UTC、ISO 日期和 hex bytea；自定义连接 `options` 会覆盖这组默认启动选项。
JSON 内的数值精度遵循框架现有 JSON 编解码器，不等于 PG `numeric` 的十进制任意精度；高精度 JSON 数值建议保存为 JSON 字符串。

具名结果的重名列会覆盖。可在 SQL 使用别名，或传 `{row_mode="array"}`，配合 `columns` 按位置读取。

## 5. 超时、容量和支持边界

`timeout` 默认 10000 毫秒；连接时包括 DNS、所有候选地址和认证；查询时覆盖网络操作；事务中 BEGIN、所有语句、COMMIT/回滚共用一个期限。
driver 中查询超时**不包含队列等待和此前建连时间**。C++ 参数校验/编码在提交前完成，结果解码在原生完成后执行；这些同步 CPU 工作不被网络计时器强制抢占，也不计入其期限。

`max_rows` 默认 100000，`max_result_bytes` 默认 64 MiB，均可设为 0 取消限制；可按连接设置，也可逐次调用覆盖。
批量/事务的多个结果累计检查。字节数是原始字段数据，不包括 PGresult、Lua 表、JSON 解码、复制和序列化开销，因此不是内存硬上限。
大字段可能在 libpq 完整接收之后才触发限制；大结果应在 SQL 端分页。
`max_queue` 默认 0，不强制排队容量；设为正数后限制每条 lane 的等待请求数，不包括在途请求。满时返回 `QUEUE_FULL`，业务自行决定拒绝/降载。

连接超时、查询超时、结果超限、协议错误、COPY 响应会关闭物理连接；不会把半读的协议状态放回池中。
常规 PG SQL 错误会把所有结果读取完，确保同一连接可安全继续使用。

目前支持 TCP 单主机、异步 DNS、IPv4/IPv6 候选地址切换、libpq TLS/常规认证、参数化查询、事务、batch、命名 prepare。
暂不提供 COPY 数据流、pipeline 模式、LISTEN/NOTIFY API、游标/逐行消费 API、Unix-domain socket 或多主机 URL。
结果收集使用 libpq single-row mode，每行复制到紧凑的原始字节/字段索引存储后立即释放 PGresult，列信息只保存一次。最终在 C++ 直接构造具名/数组 Lua 行表，不再创建整批 Lua 字符串中间表；Lua 接口仍返回完整结果，**不是流式接口**。
目前仍请求 PostgreSQL **文本结果格式**；bytea/数组/数值的文本转换已移到 C++，没有切换为全二进制协议，因此保留 numeric 和未知类型的无损文本兼容性。

Lua 的 `types.lua` 只提供 NULL/typed/bytea/jsonb/array 参数包装；`libpq.lua` 只保留协程等待、选项和公开接口。参数编解码使用 `pq_lua_codec.hpp`，异步事务/缓存调度使用 `pq_connection.hpp`，不会在异步回调中访问 Lua。

Windows 用 socket 事件 + Asio 等待，Linux 用 Asio readiness；数据库网络收发始终由非阻塞 libpq 完成，不用阻塞查询线程池。
同一 PGconn 的调用全部回到拥有它的 Moon worker；native 回调通过 Moon 消息唤醒协程，不在其他线程直接访问 Lua。

## 6. 测试

不启动 Moon，不连接真实数据库的检查：

```powershell
premake5 --file=tests/libpq/premake5.lua vs2022
MSBuild target/libpq-tests/libpq_checks.sln /p:Configuration=release /p:Platform=x64 /m
./target/libpq-tests/bin/libpq_engine_test.exe
./target/libpq-tests/bin/libpq_lua_test.exe
```

```sh
bash tests/libpq/check-linux.sh
```

C++ 检查加载真正的预编译 libpq，但只连接进程内的回环协议模拟器，覆盖异步连接、DNS/地址切换、紧凑行收集、prepare、batch、LRU 命中/淘汰/OID 隔离/禁用/失效、原生事务单次通知/回滚/提交失败/总期限/累计限额、断线、关闭、BUSY。
Lua 检查编译并调用生产 C++ 编解码器，使用真实 JSON 模块和模拟调度器，覆盖类型精度、NULL、UTF-8、二进制/数组、具名/数组结果、整批事务校验、单次等待、FIFO、队列上限、并行 lane、优雅退出和不重放。
这些测试不等同于真实数据库、TLS 证书链和 SCRAM 认证的端到端验证。

你手动运行的 PostgreSQL 集成套件是 `example/test_libpq_pg.lua`。它会创建唯一测试 schema 并在结束时清理；请使用专用测试数据库与有建 schema 权限的账号。

```powershell
$env:PGHOST="127.0.0.1"
$env:PGPORT="5432"
$env:PGDATABASE="your_test_db"
$env:PGUSER="your_test_user"
$env:PGPASSWORD="your_test_password"
$env:PGSSLMODE="disable" # 仅可信本地测试
./target/release/moon.exe example/test_libpq_pg.lua
```

Linux 使用对应环境变量后：`./target/release/moon example/test_libpq_pg.lua`。默认 sslmode=require；生产使用 verify-full 并通过 `PGSSLROOTCERT` 指定 CA。
这两条启动命令供你手动执行，开发过程中没有执行它们。若进程被强杀，查看日志中的 schema 名称再手动清理。
