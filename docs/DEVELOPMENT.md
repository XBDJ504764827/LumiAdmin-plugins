# LumiAdmin 插件开发文档

> LumiAdmin 后台面板配套 SourceMod 插件（重构版）。
> 本仓库为独立插件仓库，目录结构仿照 `gokz-top-plugins`，每个插件独立加载/卸载，互不依赖。

---

## 1. 插件清单（共 5 个）

| 插件名 | 功能 | 配置文件 | 说明 |
|--------|------|----------|------|
| `core` | 共享配置：API 地址、端口→token 映射 | `cfg/sourcemod/lumiadmin/core.cfg` | 物理机多游戏服共享一份配置 |
| `server` | 在线玩家上报、服务器状态、封禁轮询/执行、进服权限检查+本地快照、断开原因上报 | `cfg/sourcemod/lumiadmin/server.cfg` | 原 `cngokz-server` 重构 |
| `sync` | 离线操作队列（SQLite 本地缓存 + 断线重试 + 应急处理） | 无（全默认值） | 原 `cngokz-sync` 重构 |
| `recordguard` | 异常记录拦截、规则同步、待审提交、审核通过补交全球 | 无（规则从网站拉取） | 原 `cngokz-recordguard` 重构，**不做录像** |
| `global` | GOKZ 全球榜单替代版（含异常记录拦截点），载入时自动禁用原版 `gokz-global` | 沿用 `cfg/sourcemod/gokz/gokz-global.cfg` | 原 `cngokz-global` 重构，**移除 WR 录像上传** |

> `cngokz-prime` 功能已删除（不再检测 CS Prime）。
> `gokz-replays` 修改版不再维护，服务器使用原版 GOKZ Replays；异常记录不做录像证据。

## 2. 目录结构

```
LumiAdmin-plugins/
├── README.md                        # 项目说明 + 安装 + 旧插件清理指南
├── docs/DEVELOPMENT.md              # 本文档
├── addons/sourcemod/
│   ├── plugins/                     # 编译产物 .smx（发布包含）
│   ├── scripting/
│   │   ├── core.sp                  # 插件入口（唯一）
│   │   ├── core/                    # 模块目录
│   │   │   ├── convars.sp
│   │   │   ├── config.sp
│   │   │   └── natives.sp
│   │   ├── server.sp
│   │   ├── server/
│   │   │   ├── convars.sp
│   │   │   ├── http.sp
│   │   │   ├── steamid.sp
│   │   │   ├── online.sp
│   │   │   ├── bans.sp
│   │   │   └── access.sp
│   │   ├── sync.sp
│   │   ├── sync/
│   │   │   ├── queue.sp
│   │   │   ├── audit.sp
│   │   │   └── sync.sp
│   │   ├── recordguard.sp
│   │   ├── recordguard/
│   │   │   ├── config.sp
│   │   │   ├── rules.sp
│   │   │   ├── detection.sp
│   │   │   ├── pending.sp
│   │   │   └── submit.sp
│   │   ├── global.sp
│   │   ├── global/
│   │   │   ├── convars.sp           # 含 legacy_disable（禁用原版 gokz-global）
│   │   │   ├── api.sp
│   │   │   ├── send_run.sp          # 含 recordguard 拦截点
│   │   │   ├── commands.sp
│   │   │   ├── maptop.sp
│   │   │   ├── points.sp
│   │   │   └── ban_player.sp
│   │   └── include/
│   │       ├── lumiadmin/core.inc
│   │       ├── lumiadmin/recordguard.inc
│   │       └── lumiadmin/session_reasons.inc
│   └── translations/
│       └── lumiadmin.phrases.txt    # 多语言（中英）
├── cfg/sourcemod/lumiadmin/         # 运行时自动生成配置（core.cfg / server.cfg）
├── build.sh                         # 本地编译脚本（spcomp64 + SM 1.11）
└── .github/workflows/main.yml       # CI：自动版本号 + 编译 + full/upgrade 两个 zip 发布
```

## 3. 设计决策（与旧版差异）

| 决策 | 旧版 | 新版 |
|------|------|------|
| 插件命名 | `cngokz-*` | 无前缀，按功能命名（core/server/sync/recordguard/global） |
| 配置目录 | `cfg/sourcemod/cngokz-lumiadmin/` | `cfg/sourcemod/lumiadmin/` |
| 默认 API 地址 | `http://127.0.0.1:8080/api/plugin` | `https://你的域名`（插件内部拼接 `/api/plugin` 路径） |
| CS Prime | `cngokz-prime` 独立插件 | **删除** |
| WR 录像上传 | `cngokz-global` 内嵌 | **移除**（由独立插件 stratosphere 承担，键名 `wr/` 不冲突） |
| 异常录像 | `cngokz-recordguard` 捕获 + R2 上传 `audit/` | **移除**（不依赖修改版 gokz-replays，异常记录无录像证据，管理员网站手工审核） |
| 旧插件兼容 | legacy_disable + 兼容 native | **一概不兼容**，提供清理指南 |
| 插件间依赖 | server/sync/recordguard 依赖 core 可选；global 依赖 recordguard 可选 | 同上：所有跨插件 native 均为 optional，插件卸载不影响其他插件运行 |
| 全局榜单 | `cngokz-global` 替代原版 | `global` 替代，**载入时自动禁用原版 `gokz-global.smx`** |

### 3.1 独立插件原则

- 每个插件只在自己的目录中声明 native / library / forward。
- 跨插件调用一律 `#undef REQUIRE_PLUGIN` + `MarkNativeAsOptional`，调用前检查 `GetFeatureStatus` / `LibraryExists`。
- 任何插件卸载（core 除外时）：server 降级读取自己的 convar；recordguard 失去规则同步能力时本地拦截仍生效（用本地缓存规则）；global 失去 recordguard 时正常提交全球（不拦截）。

### 3.2 配置默认值（方便其他开发者）

```text
core.cfg:
    core_api_base_url    "https://你的域名"     # 只填域名，不带 /api/plugin
    core_server          "27015" "report_token" # 一行一个端口映射

server.cfg:
    server_report_interval        "5.0"
    server_status_interval        "30.0"
    server_access_snapshot_interval "300.0"
    server_access_fail_open       "1"
    server_debug                  "0"
```

sync / recordguard 无配置文件，convar 使用合理默认值，需要时可服务器控制台临时修改。

## 4. 后端 API 对照

所有插件请求均以 `POST {core_api_base_url}/api/plugin/...` 发起（URL 拼接规则：去掉末尾 `/`，追加 `/api/plugin` 与具体路径）。

### 4.1 core
无 HTTP 请求，仅配置。

### 4.2 server

| 端点 | 触发 | 说明 |
|------|------|------|
| `POST /api/plugin/online-players/report` | 每 `server_report_interval` 秒 | 上报在线玩家列表 |
| `POST /api/plugin/online-players/disconnect` | 玩家断开时 | 上报断开原因 |
| `POST /api/plugin/server-status` | 每 `server_status_interval` 秒 | 上报 FPS/CPU/Tickrate/uptime/map |
| `POST /api/plugin/bans/poll` | 每 `server_report_interval` 秒 | 轮询活跃封禁（etag 增量） |
| `POST /api/plugin/bans/check` | 玩家进服时 | 单玩家封禁检查 |
| `POST /api/plugin/bans` | sm_ban/sm_banip/sm_addban | 提交封禁 |
| `POST /api/plugin/bans/unban` | sm_unban | 提交解封 |
| `POST /api/plugin/access/check` | 玩家授权后 | 进服权限检查（is_cs_prime 字段不再上报） |
| `POST /api/plugin/access/snapshot` | 每 `server_access_snapshot_interval` 秒 | 拉取权限快照写入本地 SQLite（断网应急） |

### 4.3 sync

| 端点 | 触发 | 说明 |
|------|------|------|
| `POST /api/plugin/offline/sync` | 队列有 pending 操作时（每 `sync_interval` 秒重试） | 批量同步离线操作 |

### 4.4 recordguard

| 端点 | 触发 | 说明 |
|------|------|------|
| `GET /api/plugin/abnormal-record-rules` | 地图加载时 + 定时 | 拉取异常时间规则（Header 鉴权：`x-lumiadmin-report-token` + `x-lumiadmin-server-port`） |
| `POST /api/plugin/abnormal-records` | 检测到异常成绩 | 创建待审记录（idempotency_key 幂等） |
| `POST /api/plugin/abnormal-records/poll-approved` | 定时轮询 | 拉取审核通过的记录（limit） |
| `POST /api/plugin/abnormal-records/{id}/submit-result` | 补交全球后 | 回写提交结果 |

> 异常录像相关端点（`/replay`、`/replay-metadata`）不再使用。

### 4.5 global

| 端点 | 触发 | 说明 |
|------|------|------|
| GlobalAPI（gokz.top） | 完图提交 | 全球记录创建（异常时被 recordguard 拦截） |
| `POST /api/plugin/bans` | 全球封禁同步 | 反作弊触发封禁时同时写入 LumiAdmin（可选） |

## 5. 模块设计

### 5.1 core（3 模块）

- `convars.sp`：创建 `core_api_base_url` / `core_debug`，注册 `core_server` 服务器命令（`core_server <port> <token>`），解析 `core.cfg` 中的 `core_server "port" "token"` 多行映射。
- `config.sp`：`core.cfg` 文件解析（兼容注释行），端口→token 内存缓存。
- `natives.sp`：`Core_GetApiBaseUrl` / `Core_GetReportToken` / `Core_GetServerPort` / `Core_IsDebugEnabled`，注册 library `core`。

### 5.2 server（6 模块）

- `convars.sp`：创建全部 server convar，`AutoExecConfig(true, "server", "sourcemod/lumiadmin")`。
- `http.sp`：URL 拼接（base + `/api/plugin/...`）、token 解析（优先 core native，降级读取 `core.cfg` 文件）、`PostJsonObject` 公共请求函数。
- `steamid.sp`：SteamID2/SteamID3 → SteamID64 转换、校验、命令行解析工具。
- `online.sp`：在线玩家上报（构建 payload、回调）、断开原因捕获（say/`sm_kick` 监听、断连上报）。
- `bans.sp`：封禁轮询（etag）、封禁/解封提交、`sm_ban`/`sm_banip`/`sm_addban`/`sm_unban` 拦截、菜单流程、踢人执行。
- `access.sp`：进服权限检查（在线 + 离线快照降级）、SQLite 快照表结构与刷新、fail-open 逻辑。

### 5.3 sync（3 模块）

- `queue.sp`：SQLite `offline_queue` 表初始化、入队（幂等键）、查询 pending、状态更新（synced/failed/retry）。
- `audit.sp`：本地 `audit_log` 表写入、7 天清理。
- `sync.sp`：同步引擎（批量 50 条、重试上限 10 次、在线/离线状态、定时器）。

### 5.4 recordguard（5 模块）

- `config.sp`：convar（enabled / rule_sync_interval / poll_interval / request_timeout / debug），不生成 cfg 文件。
- `rules.sp`：规则拉取与内存缓存（map+course+mode+time_type 四元组 → threshold），匹配优先级。
- `detection.sp`：`GOKZ_OnTimerEnd` 后判断 `run_time <= threshold` 且 `teleports` 匹配 → 拦截标记。
- `pending.sp`：待审记录状态机（held → 创建网站记录 → 幂等重试）。
- `submit.sp`：轮询审核通过记录 → 调 global 补交全球 → 回写结果。

### 5.5 global（7 模块）

- `convars.sp`：沿用 `cfg/sourcemod/gokz/gokz-global.cfg`；**载入时检测并禁用原版 `gokz-global.smx`**（存在则改名 `.disabled` 并提示重启）。
- `api.sp`：GlobalAPI 请求封装。
- `send_run.sp`：完图提交链路，插入 recordguard 拦截点（`RecordGuard_ShouldHoldRecord`）。
- `commands.sp`：全局命令（`!global` 等）。
- `maptop.sp`：地图 TOP 菜单 + 记录打印。
- `points.sp`：积分计算。
- `ban_player.sp`：全球封禁。

## 6. 旧插件清理指南（部署时执行）

> 旧插件与新插件**功能冲突**（重复上报、库冲突），必须清理。

1. 停用旧插件（移入 `plugins/disabled/` 或删除）：

```text
cngokz-core.smx
cngokz-server.smx
cngokz-sync.smx
cngokz-recordguard.smx
cngokz-global.smx
cngokz-prime.smx
manger_online_reporter.smx
manger_edge_sync.smx
gokz-r2upload.smx
gokz-global.smx          # 原版；新 global 载入时也会自动禁用
```

2. 删除旧配置目录：

```text
csgo/cfg/sourcemod/cngokz-lumiadmin/
csgo/cfg/sourcemod/cngokz/
```

3. 安装新插件到 `plugins/`，配置 `cfg/sourcemod/lumiadmin/core.cfg`（API 地址 + 端口 token）。
4. 重启服务器或按顺序 `sm plugins load core / server / sync / recordguard / global`。
5. 检查 `sm plugins list` 与后端服务器状态页确认上报正常。

## 7. 编译与 CI

### 本地编译

```bash
./build.sh
```

依赖：SourceMod 1.11 spcomp64（自动下载或使用 `~/gokz/sourcemod-1.11.0-git6970-linux` 缓存）、`~/gokz-top-plugins` 或 `~/gokz` 的 include 目录（GOKZ 头文件、GlobalAPI 等）。

### GitHub Actions（main.yml）

仿照 gokz-top-plugins：

- 触发：push master/main、tag、PR、手动。
- 版本号：PR 用 commit SHA；tag 直接用 tag 名；push 自动 bump（feat → minor，其余 patch）。
- 编译：SM 1.11（i386 兼容）下载 + `include/gokz/version.inc` 生成 + 逐个 spcomp。
- 打包：`full`（含 cfg 模板）与 `upgrade`（不含 cfg）两个 zip。
- 发布：softprops/action-gh-release 自动建 Release。

## 8. 依赖

| 依赖 | 用途 | 缺失影响 |
|------|------|----------|
| MetaMod:Source + SourceMod 1.11 | 运行环境 | 无法运行 |
| RIPExt | HTTP/JSON（server/sync/recordguard） | 上报、封禁轮询、权限检查、异常记录全部失效 |
| GOKZ 3.6+ | KZ 核心、模式、计时、录像接口 | core/server 可运行；recordguard/global 无法工作 |
| GlobalAPI 2.x | 全球榜单 | global 无法工作，recordguard 补交失败 |
| SteamWorks | GlobalAPI 常见环境依赖 | GlobalAPI 部分请求可能不可用 |

## 9. 开发进度

- [x] core 插件（convars/config/natives）
- [x] sync 插件（queue/audit/sync）
- [x] server 插件（6 模块）
- [x] recordguard 插件（5 模块，无录像）
- [x] global 插件（7 模块，移除 WR 上传，载入时禁用原版 gokz-global）
- [x] include 头文件（core.inc / recordguard.inc / session_reasons.inc / config_parse.inc）
- [x] 翻译文件 lumiadmin.phrases.txt（中英双语）
- [x] build.sh + GitHub Actions
- [x] 编译验证（本机 spcomp64，5 个插件全部通过）
