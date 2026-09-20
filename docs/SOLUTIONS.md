# 插件问题修复方案说明

> **2026-09-09 状态更新**：本文档列出的 38 项问题已全部实施完毕（例外见文末），
> 逐项落地情况以 [ISSUES.md](ISSUES.md) 为准。本文保留作为方案存档。
> 4 个决策点的最终选择：H3-A（超限终态化+人工重放）、H6-A（本地兜底落盘，
> 已与 HA 方案合流实现）、M1（skip 视为幂等已应用，failed 才标 failed）、M2-A + M5-A。

> 对应 [ISSUES.md](ISSUES.md) 的 38 项问题，逐项给出修法。
> 标注 **【决策点】** 的条目存在多种做法/影响运营口径，需要拍板；
> 其余为标准修法，确认批次后可直接实施。

---

## 一、权限白名单链路（P1–P6）→ 见 [ACCESS-HA.md](ACCESS-HA.md)

P1–P6 的完整方案已单独成文（本地主裁决 + 熔断器 + 快照可靠性 + 事件推送，
分 S1–S4 四阶段）。此处不重复，只补充与其他批次的衔接：

- **H6（封禁落盘）的推荐方案与 HA 方案合流**：见下文 H6 的【决策点】。
- **M11（公共代码下沉）建议在动 S1 之前先做**，access.sp 重构时直接用新的
  共享 include，避免改两遍。

---

## 二、高严重度（H1–H7）

### H1 HTTPRequest 句柄泄漏 — 标准修法，建议合并到 M11 一起做
根因：`new HTTPRequest(url)` 后 `Post()` 不释放。修法本身是 Post 后补
`delete request`，但三处泄漏点恰好说明缺一个统一的请求封装。结合 M11：
新建 `include/lumiadmin/http_client.inc`，提供：

```
stock bool LumiHttpPost(const char[] label, const char[] url,
    JSONObject payload, HTTPResponseCallback callback, any value, int timeout)
```

内部负责 new/delete/超时/失败日志统一前缀，三插件全部换用——泄漏从此
结构性杜绝，而不是逐处补一行。

### H2 回调空响应解引用 — 标准修法
`pending.sp:125`、`submit.sp:50` 补 `response.Data == null` 判断，走已有的
`LogError + return`。同时给同插件其他回调补 `response.Status` 区间检查，
与 `bans.sp` 的写法对齐。改动 ≤10 行。

### H3 sync 队列死行堆积 — **【决策点：失败数据留不留】**
三种做法：
- **A（推荐）超限即终态化**：达到 MAX_RETRY 的行在 cleanup 时标记
  `failed`，打 ERROR 日志（含操作类型/target），管理命令
  `sm_lumi_sync_retry` 可把 failed 行重置回 pending 手动重放。队列加软上限
  （如 2000 行），超限时拒收新操作并告警。
  → 语义：放弃自动重试，但保留数据可人工捞回。
- **B 无限退避重试**：不设 MAX_RETRY，改为重试间隔指数退避（10 分钟起步，
  上限 24h），永不清除。
  → 语义：永不放弃，但长期宕机后恢复时可能出现"陈旧操作洪峰"（如一个月前
  的临时封禁现在才提交），需要后端能容忍。
- **C 直接丢弃**：超限删除 + 日志。
  → 最简单，但丢数据，不推荐。

需要你确认运营上更偏向 A 还是 B。

### H4 sync 主线程同步 SQL — 标准修法
- 全部 `SQL_Query`/`SQL_FastQuery` 改 `SQL_TQuery` 异步回调；
- `last_insert_rowid()` 查询取消（opId 仅用于日志，改用 idempotency key 即可）；
- 逐条 UPDATE 合并为 `UPDATE ... SET status=? WHERE id IN (1,2,3...)` 单条；
- 入队后立即 `SyncOfflineQueue()` 改为入 0.5s 延迟的一次性 timer，把 SQL
  开销从玩家命令路径挪出去。
风险低，改动集中在 queue.sp/sync.sp。

### H5 封禁菜单 client index 复用 — 标准修法
`g_BanTarget` 改存 userid；`MenuHandler_BanReason`/`SubmitMenuBan` 取用时
`GetClientOfUserId` 换算，换算失败（目标已断开）报"目标已离开"并终止菜单。
顺带检查 `g_BanTarget` 在 `OnClientDisconnect` 的清理（index 键位不变，
改 userid 后不需要清理，反而更简单）。

### H6 封禁"踢了但没存下来" — **【决策点：本地封禁兜底】**
- **A（推荐）本地兜底落盘**：server 插件已持有快照库（含 `bans` 表），把
  封禁在提交在线 API 的**同时**写入本地 `bans` 表。在线提交成功 → 等 ban
  poll 回来自然对齐；在线失败 → 本地行就是唯一记录，离线裁决照样能拦住该
  玩家。封禁永远可踢、永不丢失，server 插件对 sync.smx 不再强依赖。
  代价：ban poll 全量回放时需按 `(steam_id, expires_at)` 幂等去重（加
  UNIQUE 索引 + INSERT OR REPLACE，改动可控）。
  → 与 HA 方案"单机自治"目标完全一致，建议与 S1 一起做。
- **B 仅拒绝踢人**：在线+离线队列都失败时返回错误不给踢。
  → 简单，但管理员体验差（要罚人时罚不了），且没解决"封禁依赖 sync.smx
  在线"的结构问题。

### H7 print_records 卡死 — 标准修法
失败/响应无效路径复位 `inProgress[client]`；同时把几个以 client index 为
下标的数组改为 userid 定位（`GetClientOfUserId`），并在
`OnClientDisconnect` 复位，杜绝同类槽位复用问题。

---

## 三、中严重度（M1–M11）

### M1 sync 忽略 skipped — **【决策点：需确认后端语义】**
先确认后端 skip 的含义：
- 若 skip = "重复提交/已应用过"（幂等去重），**现状正确**，只需把 skip 计数
  打进日志即可，本项关闭；
- 若 skip = "被拒绝/未应用"，则按服务端逐条结果把对应行标 `failed`（附原因），
  管理员可通过 H3-A 的重放命令处理。

### M2 异常记录创建失败无重试 — **【决策点：重试强度】**
- **A（推荐）插件内退避重试**：失败后 30s/2m/10m 重试 3 次，仍失败则保留在
  内存 pending 列表 + ERROR 日志，地图切换/插件重载时重试一次。
  → 改动小（~80 行），覆盖绝大多数瞬时故障。
- **B 本地 SQLite 队列**：仿 sync 模式落盘，跨图/跨重启不丢。
  → 最稳，但为单一操作类型引入一套队列，性价比低于 A；若 recordguard 后续
  要加更多离线操作再升级到 B。

### M3 GlobalAPI 失败直接标 failed — 标准修法
`OnGlobalRecordCreated` 失败先退避重试（复用 M2-A 的机制）；回调补
`GlobalAPIResponseInvalid` 校验。最终仍失败的记录保留在 pending 列表，
由 recordguard 已有的待审提交通道在下次轮询时补交。

### M4 未初始化变量 — 一行修复
`points.sp:139` 改为 `points = rank.Points == -1 ? 0 : rank.Points;`。

### M5 每秒 IntegrityChecks 过重 — **【决策点：检测时效取舍】**
- **A（推荐）进服检查 + 低频复检**：`OnClientPutInServer` 后延迟 15s 首查
  （避开连接期 convar 查询失败），之后每 60s 复检一次；插件扫描改为
  OnMapStart 执行一次。
  → 32 人服的 convar 查询从 64 次/秒 降到 ~1 次/秒。作弊者中途改 fps_max
  最多 60s 后才被发现，可接受。
- **B 保持每秒**：若你们对"秒级发现作弊"有明确需求则维持现状，仅把插件
  扫描改为 map start 一次（这部分无争议）。

### M6 OnMapEnd off-by-one — 一行修复（`<=`）。
### M7 MapTop 菜单泄漏 — 一行修复（空分支 `delete menu`）。

### M8 g_PendingCount 双重维护 — 标准修法
删除入队时的手动 `++`，唯一来源改为 `UpdatePendingCount()`（改异步后用
`SELECT COUNT(*)` 回调更新）。native 返回值在窗口期 ±1 的误差可接受。

### M9 SQL 拼接改参数绑定 — 标准修法
queue.sp/audit.sp 的 INSERT/UPDATE 改 `SQL_PrepareQuery` +
`SQL_BindParamString/Int`。顺带消除转义截断风险（audit_log 长 reason）。
若嫌 PrepareQuery 样板多，折中：仅对含用户可控长文本的两条 SQL
（audit_log insert、queue insert 的 reason）做绑定，其余保留拼接。

### M10 封禁时长校验 — 标准修法
新增 `bool ParseBanDuration(const char[] arg, int &minutes)`：逐字符校验
数字，失败报用法错误。三个命令（sm_ban/sm_banip/sm_addban）统一换用，
"0"仍表示永久。

### M11 公共代码下沉共享 include — 标准修法（建议最先做）
新建 `include/lumiadmin/api_client.inc`（stock）：
- `LumiGetApiConfig(url, urlLen, path, token, tokenLen)` — 统一"core native
  优先、降级读 core.cfg"逻辑 + **失败结果 60s 负缓存**（顺带修 L1）；
- `BuildPluginApiUrl` — 统一去尾斜杠 + `/api/plugin` 前缀；
- `LumiDebugLog(tag, fmt...)` — 统一调试日志（保留各插件 tag 前缀）；
- `LumiHttpPost`（见 H1）。
三插件逐步替换调用点。风险低：include 是纯 stock，不影响 ABI。

---

## 四、低严重度（L1–L14）修法速览

| # | 修法 | 量 |
|---|------|----|
| L1 | 并入 M11：`LumiGetApiConfig` 失败结果 60s 负缓存 | 随 M11 |
| L2 | 并入 M11：超时作为 `LumiHttpPost` 参数，各插件用 convar 传入；ban poll 退避见 L10 | 随 M11 |
| L3 | 回调里对 `data.Get("items")` 结果先判 null/类型再 cast（ripext 判空 + 取不到即按失败处理）；bans.sp、rules.sp 两处 | ~10 行 |
| L4 | `GetClientAuthId` 返回值检查，失败跳过该玩家上报/提交；online.sp、bans.sp 六处 | ~15 行 |
| L5 | `sm_banip` 非玩家目标时复用 `IsIpAddressTarget` 校验，不合法报错 | ~5 行 |
| L6 | `points.sp:111-116` 先判 `client==0` 再动计数，`--` 后钳制下限 0 | ~5 行 |
| L7 | recordId 白名单校验（`[A-Za-z0-9-]`），不合法记日志丢弃 | ~8 行 |
| L8 | `CreateJsonRequest` 增加出参直接返回 token/port，删掉调用方的第二次 `GetApiConfig` | ~15 行 |
| L9 | hold 回调 value 携带发起时的 userid + record idempotency key，响应时校验仍是同一次 hold | ~20 行 |
| L10 | ban poll 独立 convar `server_ban_poll_interval`（默认 30s）；连续失败间隔 ×2 退避，上限 10 分钟，成功复位 | ~30 行 |
| L11 | sync `OnPluginEnd` 先同步 flush 队列再 `delete g_SyncDb` | ~10 行 |
| L12 | 菜单 reason 的 info 改稳定 key（cheat/abuse/insult），提交值按 key 查表；online.sp 两处文案进 lumiadmin.phrases | ~40 行 |
| L13 | `Native_EnqueueOperation` 检查 `GetNativeString` 返回值，失败 `ThrowNativeError` | ~5 行 |
| L14 | `GlobalAPIRequestFailed/ResponseInvalid` 统一改用 `request.Failure` 判定 | ~15 行 |

---

## 五、需要你拍板的 4 个决策点汇总

| 决策点 | 选项 | 我的建议 |
|--------|------|---------|
| ① H3 队列死行 | A 超限终态化+人工重放 / B 无限退避 | **A**（可控、可捞回） |
| ② H6 封禁落盘 | A 本地兜底落盘（与 HA 合流）/ B 失败就拒绝踢 | **A**（封禁永不丢，单机自治） |
| ③ M1 skipped 语义 | 关闭 / 标 failed | **需你确认后端 skip 含义** |
| ④ M2 记录重试 + M5 检查频率 | M2: A 插件内退避 / B SQLite 队列；M5: A 60s 复检 / B 保持每秒 | **M2-A、M5-A**（性价比最高） |

实施顺序建议：**M11（公共下沉）→ 批次 1 一行修复包 → H 系列剩余 → 批次 2-6**，
M11 先行可以让后面所有 HTTP/配置相关修复一次到位。