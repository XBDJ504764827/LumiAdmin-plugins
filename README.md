# LumiAdmin Plugins

LumiAdmin 后台面板配套的 CS:GO / CS2 社区服务器 SourceMod 插件（重构版）。

后端项目：[LumiAdmin](https://github.com/iquankz/LumiAdmin)（Rust + React + PostgreSQL）

## 插件列表

| 插件 | 功能 |
|------|------|
| `core` | 共享配置：API 地址、端口→Token 映射（一个物理机多游戏服共享一份配置） |
| `server` | 在线玩家上报、服务器状态、封禁轮询/执行、进服权限检查、断开原因上报 |
| `sync` | 离线操作队列：断网时本地缓存封禁等操作，恢复后自动补报 |
| `recordguard` | 异常完图成绩拦截，进入网站待审池，管理员审核通过后补交全球榜单 |
| `global` | GOKZ 全球榜单功能（替代原版 gokz-global），载入时自动禁用原版 |

> 原 `cngokz-prime`（CS Prime 检测）功能已删除。
> 录像上传与寻路请使用独立插件 [stratosphere](https://github.com/iquankz/stratosphere) / [wayfinder](https://github.com/iquankz/wayfinder)。

## 依赖（必需）

安装本插件包前，游戏服务器必须已具备以下运行时依赖。缺少依赖时 SourceMod 会报 `Library not found` / `Native not bound`，插件无法加载或功能降级。

| 依赖 | 用途 | 缺失影响 |
|------|------|----------|
| MetaMod:Source | SourceMod 运行基础 | 无法运行 |
| SourceMod 1.11+ | `.smx` 插件运行环境 | 无法运行 |
| **RIPExt / REST in Pawn** | 插件向后端发送 HTTP/JSON 请求（`server`/`sync`/`recordguard` 依赖） | `Library not found: ripext`，上报、封禁轮询、权限检查、异常记录全部失效 |
| SteamWorks | HTTP 请求底层依赖；GlobalAPI 环境常见依赖 | 部分 HTTPS 请求可能失败 |
| GOKZ 3.6+ | KZ 核心、模式、计时、录像接口 | `recordguard`/`global` 无法工作 |
| GlobalAPI 2.x | 全球榜单接口 | `global` 无法工作，`recordguard` 无法补交全球 |

常见依赖文件位置（`csgo/addons/sourcemod/`）：

```text
extensions/ripext.ext.so
extensions/SteamWorks.ext.so
plugins/GlobalAPI.smx
plugins/gokz-core.smx
```

检查命令：

```text
sm exts list      # 应看到 RIPExt 和 SteamWorks
sm plugins list   # 应看到 GlobalAPI、GOKZ 与本插件包
```

> RIPExt 是 `server`（在线玩家/状态/封禁/权限）、`sync`（离线队列）、`recordguard`（异常记录）三个插件的**硬依赖**，缺失时它们会报 `Library not found: ripext` 而无法加载。`core` 与 `global` 不直接使用 RIPExt。

**使用 `./deploy.sh` 部署时，RIPExt（官方预编译扩展 `rip.ext.so` + CA 证书包）会自动下载并安装到服务器**，无需手动处理；其余依赖（SteamWorks / GOKZ / GlobalAPI）脚本会自动检测缺失并提示，需手动安装。

## 安装（全新安装）

1. 安装依赖：MetaMod:Source、SourceMod 1.11+、GOKZ 3.6+、GlobalAPI 2.x、RIPExt、SteamWorks（见上表）。
2. 将 `addons/` 目录合并进服务器根目录（`addons/sourcemod/plugins/` 下的 `.smx`）。
3. 重启服务器。插件首次加载会自动生成配置文件：

```text
csgo/cfg/sourcemod/lumiadmin/core.cfg    # 必配：API 地址 + 端口 token 映射
csgo/cfg/sourcemod/lumiadmin/server.cfg   # 可选：上报间隔等
```

4. 编辑 `core.cfg`（生成的文件已自带示例说明，直接取消注释填写即可）：

```cfg
core_api_base_url "https://你的域名"
// ===== 服务器端口 -> report_token 映射 =====
// token 获取: LumiAdmin 后台 -> 社区组管理 -> 服务器 -> report_token
core_server "27015" "后台生成的report_token"
```

- `core_api_base_url`：只填域名（如 `https://ban.threi.cn`），插件自动拼接 `/api/plugin` 路径
- `core_server "<端口>" "<token>"`：端口对应当前服务器的 `hostport`；同一物理机多端口就写多行
- 旧版升级用户可沿用旧配置 `cfg/sourcemod/cngokz-lumiadmin/cngokz-core.cfg` 中 `cngokz_server` 行的 token

同一物理机多端口：

```cfg
core_server "27015" "token_for_27015"
core_server "27016" "token_for_27016"
core_server "27017" "token_for_27017"
```

5. 按需编辑 `cfg/sourcemod/lumiadmin/server.cfg`（上报间隔、权限 fail-open 等）。
6. 重启服务器，或按顺序 `sm plugins load core / server / sync / recordguard / global`。

## 清理旧插件（必须）

旧插件与新插件功能冲突（重复上报、库冲突），升级前请先清理：

1. 将以下文件移入 `plugins/disabled/` 或删除：

```
cngokz-core.smx
cngokz-server.smx
cngokz-sync.smx
cngokz-recordguard.smx
cngokz-global.smx
cngokz-prime.smx
manger_online_reporter.smx
manger_edge_sync.smx
gokz-r2upload.smx
gokz-global.smx
```

2. 删除旧配置目录：

```
csgo/cfg/sourcemod/cngokz-lumiadmin/
csgo/cfg/sourcemod/cngokz/
```

3. `gokz-replays.smx`：如果服务器安装的是旧版修改版，请替换为 GOKZ 原版（新插件不再需要 `CNGOKZ_RP_ForceSaveRun`）。

## 本地编译

```bash
./build.sh
```

详见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。

## 许可证

私有项目，未授权禁止使用。
