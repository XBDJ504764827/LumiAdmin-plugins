# LumiAdmin 插件问题总清单

> 汇总两次审查的全部发现：权限白名单链路（P 系列，详见 [ACCESS-HA.md](ACCESS-HA.md)）
> + 全代码库扫描（H/M/L 系列）。共 38 项。
> 状态标记：`☐` 未处理 / `☑` 已修复。
> 每项含 文件:行号，可点击定位。
>
> **2026-09-09 更新**：38 项问题已按「在线裁决为主、本地快照兜底」架构修复
> （P3 的面板事件推送部分待后端配合），详见各项说明。
> 所在架构以 [ACCESS-HA.md](ACCESS-HA.md) v2 为准；所有插件编译通过（SourceMod 1.11）。

---

## 一、权限白名单链路（P1–P6）

| # | 状态 | 问题 | 位置 | 说明与建议 |
|---|------|------|------|-----------|
| P1 | ☑ | 在线裁决无条件信任，后端事故会连续踢人 | `scripting/server/access.sp` | 已修复（v2 架构）：在线裁决为主但受熔断器保护——连续 3 次 HTTP 失败即 OPEN 跳过在线层走本地兜底，杜绝后端宕机时连接卡死/连续误踢 |
| P2 | ☑ | 快照过期即硬失效，`fail_open=0` 时全体被踢 | `scripting/server/access.sp` | 已修复：删除 `IsAccessSnapshotUsable` 硬失效，兜底时快照「陈旧但可用」，过期只告警 |
| P3 | ☐* | 白名单变更靠 300s 轮询，加白后最多等 5 分钟 | `Timer_RefreshAccessSnapshot` | etag 增量 + `lumiadmin_refresh_snapshot` 手动应急命令已上线；*面板事件推送（S4）需后端配合，待做 |
| P4 | ☑ | 三条静默放行旁路 | `access.sp` | 已修复：token 缺失直接走本地兜底（限流告警）、响应格式异常计熔断失败后兜底、无 SteamID 交由兜底层按白名单模式裁决 |
| P5 | ☑ | 在线检查超时 10s，被踢玩家在服内悬挂 | `server/http.sp` | 已修复：检查超时独立 convar 默认 5s；熔断 OPEN 后新连接零等待直接兜底 |
| P6 | ☑ | 降级/恢复/快照过期无醒目日志，管理员无法感知 | 全局 | 已修复：统一 `[LumiAdmin-Access]` 前缀 + `sm_lumi_access_status` 自检命令 |

---

## 二、高严重度（正确性 / 资源泄漏）

| # | 状态 | 问题 | 位置 | 说明与建议 |
|---|------|------|------|-----------|
| H1 | ☑ | HTTPRequest 句柄持续泄漏（每次请求一个） | server/sync 各处 | 已修复：server 插件统一 `PostJsonObject`（Post 后 `delete request`），access/ban poll/snapshot 换用；sync.sp 补 `delete request` |
| H2 | ☑ | HTTP 回调对空响应直接解引用 → native error | `recordguard/pending.sp`、`submit.sp` | 已修复：`response.Data` 判空后走失败路径（创建记录含重试）；poll-approved 补判空 |
| H3 | ☑ | sync 离线队列"死行"永久堆积、无上限 | `sync/queue.sp` | 已修复：`CleanupStaleRecords` 先把 retry≥10 的行终态化为 failed（可人工重放）再按保留期清理；队列加 2000 行软上限，超限拒收并告警；`sm_lumi_sync_retry` 可把 failed 行重置回 pending |
| H4 | ☑ | sync 主线程同步 SQL，命令路径可能卡顿 | `sync/queue.sp`、`sync/sync.sp` | 已修复：逐条 UPDATE 合并为 `UPDATE ... WHERE id IN (...)` 批量；取消 `last_insert_rowid()` 查询；入队触发改 0.5s 延迟一次性 timer，SQL 开销移出命令路径 |
| H5 | ☑ | 封禁菜单缓存 client index，可能封错人 | `server/bans.sp` | 已修复：`g_BanTarget` 改存 userid，用时 `GetClientOfUserId` 换算，目标断开报"目标无效"终止 |
| H6 | ☑ | 封禁可能"踢了但没存下来" | `server/bans.sp` | 已修复：封禁提交同时写入本地快照 bans 表（`SaveLocalBanFallback`），在线失败时本地行就是唯一记录，离线裁决照样拦截；快照回放按 (steam_id, ip_address, reason, expires_at) 唯一索引幂等去重 |
| H7 | ☑ | print_records 失败后玩家命令永久卡死 | `global/print_records.sp` | 已修复：失败路径调用 `ResetPrintRecordsState` 复位 `inProgress/waitingForOtherCallback`；`OnClientPutInServer` 时同步复位 |

---

## 三、中严重度（逻辑缺陷 / 性能 / 架构）

| # | 状态 | 问题 | 位置 | 说明与建议 |
|---|------|------|------|-----------|
| M1 | ☑ | sync 忽略服务端 skipped 结果，操作可能丢失 | `sync/sync.sp` | 已修复：按服务端逐条 `results` 分别标记——failed/rejected 标 failed（附原因），applied/skipped 标 synced；响应无 results 时退回全量标 synced |
| M2 | ☑ | recordguard 异常记录创建失败无重试，成绩静默丢失 | `recordguard/pending.sp` | 已修复：30s/2m/10m 退避重试 3 次，仍失败保留内存 pending + ERROR 日志 |
| M3 | ☑ | GlobalAPI 失败直接永久标 failed，无重试 | `recordguard/submit.sp` | 已修复：前 3 次失败上报 transient 状态（记录保持待审，站点下轮重新下发），之后才标 failed |
| M4 | ☑ | 读取未初始化变量（恒假的条件） | `global/points.sp` | 已修复：`points = rank.Points == -1 ? 0 : rank.Points` |
| M5 | ☑ | 每秒 IntegrityChecks 过重 | `global.sp` | 已修复：进服 15s 首查 + 60s 低频复检；插件扫描拆出 `PluginScanChecks`，map start 执行一次 |
| M6 | ☑ | OnMapEnd 循环漏最后一个槽位（off-by-one） | `global.sp` | 已修复：`client <= MaxClients` |
| M7 | ☑ | MapTop 空分支泄漏 Menu 句柄 | `global/maptop_menu.sp` | 已修复：空分支 `delete menu` 后再重开上级菜单 |
| M8 | ☑ | `g_PendingCount` 双重维护，窗口期不准 | `sync/queue.sp` | 已修复：删除入队手动 `++`，唯一来源 `UpdatePendingCount()` |
| M9 | ☑ | SQL 全拼接 + escape，audit_log 可能截断出错 | `sync/queue.sp`、`sync/audit.sp` | 已修复：队列 INSERT 与 audit_log INSERT 改 `SQL_PrepareQuery` 参数绑定 |
| M10 | ☑ | 封禁时长 `"abc"` 变永久封禁 | `server/bans.sp` | 已修复：`ParseBanDuration` 逐字符校验纯数字，三个命令（sm_ban/sm_banip/sm_addban）统一换用 |
| M11 | ☑ | GetApiConfig / BuildPluginApiUrl / DebugLog 三份重复实现 | 各插件 | 已修复：新建 `include/lumiadmin/api_client.inc`（`LumiReadCoreConfigCached` 带 60s 负缓存 + `LumiBuildPluginApiUrl`），三插件配置读取换用 |

---

## 四、低严重度（打磨项）

| # | 状态 | 修法 |
|---|------|------|
| L1 | ☑ | `LumiReadCoreConfigCached` 失败结果 60s 负缓存（随 M11） |
| L2 | ☑ | server 插件超时经 `PostJsonObject` 参数化（access 用 `server_access_check_timeout`）；ban poll 退避见 L10 |
| L3 | ☑ | bans poll items、recordguard rules/poll-approved 的数组先判类型再 cast |
| L4 | ☑ | `GetClientAuthId` 返回值检查：online.sp 上报、bans.sp 封禁路径（含菜单）空则跳过/报错 |
| L5 | ☑ | `sm_banip` 非玩家目标复用 `IsIpAddressTarget` 校验 |
| L6 | ☑ | `points.sp` 回调先判 `client==0` 再动计数；`UpdatePoints` 补 client 边界检查 |
| L7 | ☑ | recordId 白名单校验 `[A-Za-z0-9-]`（`IsValidRecordId`），submit-result 与 result 提交均校验 |
| L8 | ☐ | recordguard 轮询双重解析配置：`GetApiConfig` 仍保留（结构耦合较深，收益低，暂缓） |
| L9 | ☑ | hold 回调 value 携带发起时的 userid + idempotency key，响应时校验仍是同一次 hold |
| L10 | ☑ | ban poll 独立 30s 基础间隔，失败 ×2 退避上限 10 分钟，成功复位 |
| L11 | ☑ | sync `OnPluginEnd` 显式 `delete g_SyncDb` |
| L12 | ☑ | 菜单 reason info 改稳定 key（cheat/malicious/insult），提交值按 key 查表 |
| L13 | ☑ | `Native_EnqueueOperation` 检查 `GetNativeString` 返回值，失败 `ThrowNativeError` |
| L14 | ☑ | `GlobalAPIRequestFailed` 改用 `request.Failure`；`GlobalAPIResponseInvalid` 改判空对象，删除 `IsValidHandle` 探测 |

---

## 五、遗留事项

| 事项 | 说明 |
|------|------|
| P3 面板事件推送（S4） | 需 LumiAdmin 后端支持向游戏服推送白名单变更，插件侧接收端 `lumiadmin_refresh_snapshot` 已就绪 |
| L8 双重配置解析 | 收益低、耦合深，暂缓 |
| server/http.sp `DebugLog` 未使用警告 | 历史遗留（server 插件有自己的 convar 版本），无功能影响 |
| sync 主线程 SQL 仍非全异步 | H4 已消除命令路径卡顿（批量 + 延迟触发）；全异步化（SQL_TQuery）收益已很小，未做 |