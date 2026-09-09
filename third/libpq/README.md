# libpq 预编译依赖

这里只保存 PostgreSQL 公共头文件、许可和 Windows 部署脚本，不编译 libpq、OpenSSL 或数据库服务端。
Moon 内置 `libpq.core` 使用运行时动态加载，因此编译 Moon 不要求安装 libpq，也不会给不用 PostgreSQL 的服务增加运行时依赖。

## Windows x64

使用 [PostgreSQL 官网推荐的 EDB 二进制包](https://www.postgresql.org/download/windows/)，不是社区自行构建包。
当前固定 EDB **18.6-3**；下载地址、SHA256、DLL 清单见 `windows-runtime.json`。
SHA256 是本次通过 HTTPS 获取归档后计算的固定完整性校验值，并非 EDB 签名。

在仓库根目录执行以下任意一种：

```powershell
# 自动下载到 target，仅提取 6 个 DLL 和许可到 clib/libpq
powershell -File third/libpq/prepare-windows.ps1 -Download

# 已从 EDB 下载了同一版本的 ZIP：离线部署
powershell -File third/libpq/prepare-windows.ps1 -Archive C:/Downloads/postgresql-18.6-3-windows-x64-binaries.zip
```

不会安装 PostgreSQL、启动数据库或运行 Moon。已有不同 DLL 时默认拒绝覆盖；停止使用该 DLL 的进程后，可用 `-Force` 备份并替换。
发布应用时部署整个 `clib/libpq` 文件夹，保留许可。不要混用不同发行包的 OpenSSL/国际化 DLL。
目标 Windows 还需匹配的 Microsoft Visual C++ x64 运行库；编译 Moon 的开发机通常已有。

如果已安装 PostgreSQL，也可以不复制 DLL，连接配置直接指定：

```lua
library = [[C:\Program Files\PostgreSQL\18\bin\libpq.dll]]
```

加载器从该 DLL 自身目录及系统安全搜索目录解析依赖，不依赖添加全局 PATH。

## Linux

使用发行版或 [PostgreSQL 官方软件源](https://www.postgresql.org/download/linux/)的预编译客户端库。
Ubuntu/Debian 通常只需要：

```sh
sudo apt install libpq5
```

不需要安装数据库服务端，也不需要 `libpq-dev`：绑定使用仓库里的公共头文件并动态加载 `libpq.so.5`。
运行时要求 libpq **14+** 且线程安全；建议使用仍受支持版本的最新修复包。
不同发行版的包名可能是 `libpq` / `postgresql-libs`，请使用目标系统自己的包管理器，别把另一台机器的 `.so` 随意复制过来。
自定义安装位置可在连接配置中指定 `library="/opt/postgresql/lib/libpq.so.5"`，其依赖也必须能被系统加载器找到。

## 头文件来源

`include/libpq-fe.h`、`include/postgres_ext.h`、`include/libpq/libpq-fs.h` 未作修改，来自 PostgreSQL 18.6 官方源码；许可见 `COPYRIGHT`。
源码归档原地址：`https://ftp.postgresql.org/pub/source/v18.6/postgresql-18.6.tar.bz2`。
此仓库不再携带完整 libpq 源码或其构建配置。库的 C ABI 保持兼容，绑定只使用 libpq 14 已存在的函数，并在加载时检查版本和所有必需符号。

使用方法和测试见仓库根目录 `docs/libpq.md`。
