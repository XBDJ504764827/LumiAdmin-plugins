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

## 安装

1. 安装依赖：MetaMod:Source、SourceMod 1.11+、GOKZ 3.6+、GlobalAPI 2.x、RIPExt、SteamWorks。
2. 将 `addons/` 目录合并进服务器根目录（`addons/sourcemod/plugins/` 下的 `.smx`）。
3. 启动服务器一次，生成配置文件 `cfg/sourcemod/lumiadmin/`。
4. 编辑 `cfg/sourcemod/lumiadmin/core.cfg`：

```cfg
core_api_base_url "https://你的域名"
core_server "27015" "后台生成的report_token"
```

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
