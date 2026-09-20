# LumiAdmin Plugins

LumiAdmin 后台面板配套的 CS:GO / CS2 社区服务器 SourceMod 插件（重构版）。

后端项目：[LumiAdmin](https://github.com/iquankz/LumiAdmin)（Rust + React + PostgreSQL）

## 插件列表

| 插件 | 功能 |
|------|------|
| `core` | 共享配置：API 地址、（可选）面板级安装密钥、端口→Token 映射；启动时自动向面板识别本机服务器并领取 Token（一个物理机多游戏服共享一份配置） |
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
| **RIPExt / REST in Pawn** | 插件向后端发送 HTTP/JSON 请求（`core` 自识别、`server`/`sync`/`recordguard` 依赖） | `Library not found: ripext`，自识别与上报、封禁轮询、权限检查、异常记录全部失效 |
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

> RIPExt 是 `core`（服务器自识别）、`server`（在线玩家/状态/封禁/权限）、`sync`（离线队列）、`recordguard`（异常记录）的**硬依赖**，缺失时会报 `Library not found: ripext` 而无法加载。`global` 不直接使用 RIPExt。

**使用 `./deploy.sh` 部署时，RIPExt（官方预编译扩展 `rip.ext.so` + CA 证书包）会自动下载并安装到服务器**，无需手动处理；其余依赖（SteamWorks / GOKZ / GlobalAPI）脚本会自动检测缺失并提示，需手动安装。

## 安装（全新安装）

1. 安装依赖：MetaMod:Source、SourceMod 1.11+、GOKZ 3.6+、GlobalAPI 2.x、RIPExt、SteamWorks（见上表）。
2. 将 `addons/` 目录合并进服务器根目录（`addons/sourcemod/plugins/` 下的 `.smx`）。
3. 重启服务器。插件首次加载会自动生成配置文件：

```text
csgo/cfg/sourcemod/lumiadmin/core.cfg    # 必配：API 地址 + 端口 token 映射
csgo/cfg/sourcemod/lumiadmin/server.cfg   # 可选：上报间隔等
```

4. 编辑 `core.cfg`：**通常只需要填写面板地址**，插件会自动向面板识别本机服务器并领取 token。

```cfg
core_api_base_url "https://你的域名"
// 面板设置了 PLUGIN_INSTALL_KEY 时才需要填写（二者保持一致）
// core_install_key "面板生成的安装密钥"
```

- `core_api_base_url`：只填域名（如 `https://ban.threi.cn`），插件自动拼接 `/api/plugin` 路径
- **无需逐服配置 token**：插件启动后调用 `POST /api/plugin/identify`，面板按「请求来源 IP + 端口」自动匹配服务器并下发 `report_token`；识别结果缓存在 `cfg/sourcemod/lumiadmin/core_identity.cfg`，重启后立即可用
- 面板需已登记该服务器，且 `IP` 填写面板实际看到的来源地址（同机/NAT 场景填内网地址，反代场景需在面板开启 `PLUGIN_TRUST_PROXY_HEADERS=true`）
- 自动识别失败时会按 15s→30s→60s→120s→300s 退避重试；识别成功前进服权限走本地快照兜底，**不会卡住玩家**

只有在自动识别不可用时（如面板看不到真实来源 IP、多台服务器共享同一 IP 与端口）才需要手动配置旧式映射：

```cfg
core_server "27015" "后台生成的report_token"
core_server "27016" "token_for_27016"
```

- `core_server "<端口>" "<token>"`：端口对应当前服务器的 `hostport`；显式配置优先级最高，不会被自动识别覆盖
- 旧版升级用户可沿用旧配置 `cfg/sourcemod/cngokz-lumiadmin/cngokz-core.cfg` 中 `cngokz_server` 行的 token

5. 按需编辑 `cfg/sourcemod/lumiadmin/server.cfg`（上报间隔、权限 fail-open 等）。
6. 重启服务器，或按顺序 `sm plugins load core / server / sync / recordguard / global`。

## 免配置自识别（推荐）

### 它是怎么工作的

1. 插件启动后由 `core.smx` 调用 `POST /api/plugin/identify`，只带 `port` / `hostname` / `install_id`，不带 token；
2. 面板根据 TCP 来源 IP（或在可信代理场景下根据转发头）+ 端口，在服务器列表中定位本服，并返回该服的 `report_token`；
3. 插件把 `install_id` 与「端口→token」写入 `cfg/sourcemod/lumiadmin/core_identity.cfg`，后续所有 API 请求与旧版完全一致；
4. 面板重置 token 后，插件会按 `core_identify_interval`（默认 600 秒）自动重新识别跟进；也可控制台执行 `lumiadmin_reidentify` 立即刷新。

### 面板侧配置

在 LumiAdmin 后端 `.env` 中按需配置（详见 `backend/.env.example`）：

| 变量 | 默认 | 说明 |
|------|------|------|
| `PLUGIN_INSTALL_KEY` | 空 | 面板级安装密钥。设置后所有插件需在 `core.cfg` 填相同 `core_install_key`，否则拒绝识别 |
| `PLUGIN_AUTO_BIND` | `true` | 是否允许按来源 IP+端口自动绑定；关闭后仅允许已绑定的实例重新识别 |
| `PLUGIN_TRUST_PROXY_HEADERS` | `false` | 面板在 Nginx/Cloudflare 之后时设为 `true`，否则来源 IP 会是代理地址 |
| `PLUGIN_REBIND_AFTER_SECS` | `3600` | 旧实例静默该时长后，新实例可自动接管同一服务器 |

### core.cfg 可用开关

```cfg
core_auto_identify "1"          // 未配置 core_server 时自动识别
core_install_key ""             // 面板设置 PLUGIN_INSTALL_KEY 时填写相同值
core_identify_interval "600"   // 自动重新识别间隔（秒），0 = 仅识别一次
```

### 自检

- `lumiadmin_reidentify`（服务器控制台）：强制重新识别并刷新 token
- 识别成功后日志：`[LumiAdmin Core] identify success: port 27015 bound to server '...'`
- 识别失败会打 ERROR 并按退避重试；期间进服权限自动使用本地快照兜底，玩家不会卡连接

> 安全说明：来源 IP 由 TCP 连接确定，攻击者无法凭自己的 IP 认领他人服务器；同一 IP 上的陌生安装实例也无法抢走已绑定的服务器（除非旧实例静默超过 `PLUGIN_REBIND_AFTER_SECS`）。生产环境建议同时设置 `PLUGIN_INSTALL_KEY`。
>
> 更换机器/重装插件后若因旧绑定未过期而无法识别，可在面板「社区组管理 → 服务器 → 重置 Token」，重置会同时清除绑定，新实例下次识别即可接管。

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
