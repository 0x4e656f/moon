# PostgreSQL SQLx 回归测试

入口：`example/test_sqlx_pg.lua`。类型数据：`example/sqlx_pg_types.lua`。

测试只使用 PostgreSQL，默认同时测试 `ext.sqlx` 和 `lrust_sqldriver`。
这不是性能压测；每项检查真实返回值，打印 `[PASS]` / `[FAIL]`，最后汇总。
单项失败后继续其他用例，最后统一清理。退出码：`0` 成功，`1` 有失败，`2` 总超时。

## 运行前

- 使用 **PostgreSQL 14+ 的专用测试数据库**，不要连接生产库。14+ 用于 multirange 类型用例。
- 测试账号需要在这个数据库中创建 schema，以及在自己的 schema 中建表、类型、域和序列的权限。不需要超级用户，也不会终止其他数据库会话。
- Moon 工作目录必须是仓库根目录；已配套部署 `clib/rust.dll` 和 `lualib/ext/sqlx.lua`。driver 服务在 `service/lrust_sqldriver.lua`，客户端在 `lualib/lrust_sqldriver/client.lua`，两份都需部署。
- SQLx 协议号 23 不能被其他模块占用。
- 默认使用 4 个 Moon 工作线程，单独启动测试进程。脚本结束会调用 `moon.exit`，不要作为业务进程中的普通服务启动。

PowerShell 示例，**由你手动执行**：

```powershell
$env:DATABASE_URL = 'postgres://postgres:YOUR_PASSWORD@127.0.0.1:5432/sqlx_test'
.\moon.exe example/test_sqlx_pg.lua
$LASTEXITCODE
```

连接串中的特殊字符需要 URL 编码。测试不会主动打印连接串；不要把真实密码提交到代码库。

只检查 Lua 语法和类型数据表、不启动 Moon、不连接数据库：

```powershell
premake5 --file=example/check_sqlx_pg.lua check_sqlx_pg
```

这个检查只加载专用检查脚本，不加载根目录 `premake5.lua`，不会构建、更新或切换 Git 分支。
**语法检查通过不代表数据库测试通过。**

driver 已拆分为服务与客户端模块。客户端统一使用 `require("lrust_sqldriver.client")`，不再兼容旧的 `require("lrust_sqldriver")`。服务启动仍然使用 `file = "lrust_sqldriver.lua"`，不会新增服务。

SQLx 包装层及 driver 拆分的模拟回归检查（同样不启动 Moon、不连接数据库）：

```powershell
premake5 --file=ext/lrust/test/sqlx_wrapper_check.lua check_sqlx
```

此检查覆盖客户端独立导入、服务配置校验、客户端请求转发、服务消息分发、参数校验、延迟连接和关闭；不代替真实数据库及并发测试。

## 覆盖范围

| 分类 | 覆盖内容 |
| --- | --- |
| 原生字段 | INT2/SMALLINT、INT4/INTEGER、INT8/BIGINT、FLOAT4/REAL、FLOAT8/DOUBLE PRECISION、BOOL/BOOLEAN、TEXT、VARCHAR、CHAR、BPCHAR、NAME、BYTEA、DATE、TIME、TIMESTAMP、TIMESTAMPTZ、TIMETZ、UUID、JSON、JSONB，共 26 个字段用例 |
| 自增字段 | SMALLSERIAL、SERIAL、BIGSERIAL、IDENTITY，使用 INSERT RETURNING 获取值 |
| 数组 | BOOL、INT2/4/8、FLOAT4/8、TEXT、VARCHAR、NAME、BYTEA、UUID、JSON、JSONB，共 13 种；包含空数组、SQL NULL 字段、NULL 元素、整数边界、浮点容差 |
| 其他 PG 字段 | 38 种 CAST-only 用例：NUMERIC/DECIMAL/MONEY、INTERVAL、BIT/VARBIT、网络地址、几何类型、range/multirange、XML、全文搜索、OID、PG_LSN、部分非原生数组；另测自定义 ENUM、DOMAIN、复合类型 |
| 数据精度 | 有符号 64 位整数上下界、32/64 位浮点、NaN/Infinity、中文与引号、含 NUL/非法 UTF-8 字节的 BYTEA、微秒、时区和跨日转换 |
| 参数 | 普通 bool/integer/number/string/table、text/json/bytes/null/array 包装、裸 nil、json.null、尾部 nil、JSON 标量/对象/数组/嵌套、SQL NULL 与 JSON null 区分 |
| SQLx 接口 | connect、try_connect、find_connection、stats、query、execute、execute_wait、batch、execute_batch、transaction、execute_transaction、close，以及参数辅助函数 |
| 事务 | 提交、整笔回滚、空事务、影响行数、table.pack 保留尾部 nil、拒绝稀疏/非法语句列表且不产生部分写入 |
| 错误与边界 | SQLSTATE/约束名/表名、语法错误、缺少参数、重复列名、非法 UTF-8/数组类型/数组元素/整数溢出、非法连接选项、max_rows 边界、查询/写入/batch/事务超时 |
| 生命周期 | 队列满返回 BUSY、计数恢复、同名连接替换、重复 close、多个共享句柄同时 close、满队列关闭并排空、关闭后 CLOSED、最后句柄 GC、非法响应令牌 |
| 跨服务 | 命名连接查找、并发响应归属、NULL/二进制/JSON/所有支持数组的序列化传递；字段结果也通过新 driver 检查 |
| 新 driver | 全部公开路由接口及 pipe 别名、返回格式、池大小、物理连接、默认 key=1、整数/string key、同 key FIFO、独立 lane 和 any 路由、len/stats、延迟连接、max_queue、超时重连不重放、停止接收并排空退出 |

“全部类型”指当前 SQLx 明确支持解码的 PG 类型及上述边界覆盖，**不代表 SQLx 原生支持全部 PostgreSQL 内建/扩展/自定义类型**。

- NUMERIC/DECIMAL/MONEY 原生查询应返回明确错误，单独的反向用例会验证这一点。使用 `value::TEXT` 查询时才按字符串检查精度。
- `cast-only/*` 只验证字段存储及显式转换，不把未知类型返回的原始字节当作原生支持。PostGIS 等扩展不在测试范围内。
- 当前原生日期时间/NUMERIC/BPCHAR 数组等没有完整类型化解码，因此相关样本放在 CAST-only 分组。支持的数组是一维数组。
- PG 标量参数的 Lua integer 默认是 INT8，number 默认是 FLOAT8，string 默认是 TEXT；日期、UUID 等使用 `$1::TEXT::DATE` / `$1::TEXT::UUID`，避免把 TEXT 二进制参数误当成目标类型。
- PG 不提供这个接口意义上的 `last_insert_id`，自增主键应使用 `INSERT ... RETURNING`。

## 清理与可重复运行

每次使用随机后缀的新 schema：`sqlx_test_<时间>_<服务ID>_<随机值>`。不复用固定业务表，不执行数据库级删除。

只有本次 `CREATE SCHEMA` 明确成功的 schema 才会在退出前 `DROP SCHEMA ... CASCADE`；先排空 driver，后删除测试 schema 并关闭连接。创建失败时不会删除同名已有 schema。

默认正常/断言失败都尝试清理。进程崩溃、强制结束、总超时或数据库断开时可能残留，日志会提供准确 schema 名称。请核对名称后自行删除，不要使用批量匹配删除。

保留样本方便查库：

```powershell
$env:SQLX_TEST_KEEP_DATA = '1'
.\moon.exe example/test_sqlx_pg.lua
Remove-Item Env:SQLX_TEST_KEEP_DATA
```

只测 `ext.sqlx`，跳过 driver 集成：`$env:SQLX_TEST_DRIVER = '0'`。该分组会明确计入 SKIP。

默认单请求超时测试阈值为 300ms，故意执行四倍时长的 `pg_sleep`。远程/繁忙数据库可增大：

```powershell
$env:SQLX_TEST_SLOW_MS = '1000'
$env:SQLX_TEST_DEADLINE_MS = '600000'
```

总时限默认 300000ms。普通连接请求超时为 15 秒，连接超时 5 秒；排队/关闭测试利用本次 schema 的行锁同步，不依赖固定 sleep 猜测顺序。

## 尚需专门故障注入的项目

这套用例不关闭数据库、不杀后端、不改网络，也不测试其他数据库模块。真实断网、数据库重启、连接阶段网络超时、服务异常死亡后的 5–6 分钟响应回收、超过 5 分钟不消费响应、大规模内存/压力测试仍应在专门环境中验证。

超时不代表写入没有提交。测试通过序列记录超时请求尝试次数，检查 driver 不自动重放；业务仍要自己处理结果不确定性。
