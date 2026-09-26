/**
 * 进服权限检查：本地同步裁决（LumiAuth Data Plane）。
 *
 * - OnClientAuthorized 内同步读本地 SQLite（含内存规则），命中封禁/白名单缺失/
 *   确认的门槛不足即立即 Kick，不等待任何 HTTP；
 * - 限制侧软失败（profile_missing 缺资料 / low_rating-low_steam_level 旧快照低分，
 *   即“玩家可能刚达标、快照还没追上”）则先放行并点查直取
 *   （POST /api/plugin/access/profile，server_access_missing_grace 秒，默认 3s）：
 *   点查早到即提前裁决，宽限到期做最终裁决（零容忍：仍未验证/确认不达标即踢）。
 *   未达标玩家在服内最多存在宽限时长；
 * - /access/check 在线复核已退役为主链路，仅保留后台对账（auth_sync 恢复后全服复核补踢）；
 * - 熔断器保留用于后台补偿链路（快照刷新/ban poll），不再阻塞进服。
 *
 * 设计文档：docs/ACCESS-HA.md（在线为主已废弃，本地自治为准）。
 */

#define ACCESS_STATUS_RECENT_MAX 10
#define ACCESS_CONFIG_ERROR_LOG_INTERVAL 600

// 最近事件记录（自检命令展示用）
char g_AccessRecentEvents[ACCESS_STATUS_RECENT_MAX][192];
int g_AccessRecentEventHead = 0;
int g_AccessRecentEventCount = 0;

int g_AccessLastConfigErrorLog = 0;

// =====[ 权限检查入口 ]=====

public void OnClientAuthorized(int client, const char[] auth)
{
    if (IsFakeClient(client) || !IsClientConnected(client))
    {
        return;
    }

    if (client > 0 && client <= MaxClients)
    {
        g_AccessMissingDeferred[client] = 0;
    }
    // 本地同步裁决：零网络等待（资料未验证除外：先放行并延迟复核，见下）。
    LocalAccessDecide(client);
}

/**
 * 进服本地裁决（同步，<10ms，不做任何 HTTP）。
 * 与 LocalAccessFallback 同一规则，区别：这是主链路而非降级。
 */
void LocalAccessDecide(int client)
{
    LocalAccessFallback(client);
}

/**
 * 限制侧软失败：快照缺资料（profile_missing）或快照资料为旧低分
 * （low_rating / low_steam_level，快照 30s 拉取 + 后端强刷节流导致）。
 * 这类拒绝可能是“玩家刚达标、快照还没追上”，走宽限延迟复核而非立即踢；
 * 封禁 / 白名单缺失 / 中高风险等硬拒绝不在此列，仍立即踢出。
 */
bool IsGraceableRestrictionDeny(const char[] failureCode)
{
    return StrEqual(failureCode, "profile_missing")
        || StrEqual(failureCode, "low_rating")
        || StrEqual(failureCode, "low_steam_level");
}

// =====[ 在线复核层（已退役为主链路，仅后台对账保留；进服用 LocalAccessDecide）]=====

// 在线复核层已退役：历史入口/回调/载荷构造全部删除。
// 进服只走 LocalAccessDecide；后台对账走 auth_sync 事件 + 补偿快照。

// =====[ 本地快照兜底 ]=====

/**
 * 本地裁决：进服主链路（同步，零网络等待；资料未验证走宽限延迟复核）。
 * 快照「陈旧但可用」：过期只告警，不作为放行或踢人依据。
 */
void LocalAccessFallback(int client)
{
    if (client <= 0 || !IsClientConnected(client) || IsFakeClient(client))
    {
        return;
    }

    char steamId[64];
    char ipAddress[64];
    bool hasAuth = GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId), true);
    GetClientIP(client, ipAddress, sizeof(ipAddress), true);

    // 快照完全缺失/损坏 → 按 fail_open 放行并立即触发一次刷新
    if (g_AccessSnapshotDb == null)
    {
        if (!ShouldFailOpenAccessCheck())
        {
            LogAccessEvent("kick", "snapshot unavailable, fail_closed");
            ReportAccessDecision(client, steamId, ipAddress, false, "snapshot_fallback", "snapshot_missing", "访问控制服务暂时不可用。");
            MarkClientDisconnect(client, SESSION_REASON_ACCESS_REJECTED, "访问控制服务暂时不可用。");
            KickClient(client, "%T", "Access Service Unavailable", client);
            return;
        }
        LogAccessEvent("allow", "snapshot unavailable, fail_open");
        ReportAccessDecision(client, steamId, ipAddress, true, "unrestricted", "", "");
        RequestAccessSnapshotRefresh(true);
        return;
    }

    // 从未同步成功：本地白名单/资料表可能是空的，无裁决依据 → 按 fail_open 口径，
    // 避免后端部署窗口/新装首启把所有人（含白名单玩家）挡在门外要求重进。
    // 注：取 token 失败时 core 侧已异步触发自动识别；首次同步成功后由
    // OnAccessSnapshotResponse 调用 AuthReconcileOnlinePlayers 补踢。
    if (!LocalSnapshotEverSynced())
    {
        if (!ShouldFailOpenAccessCheck())
        {
            LogAccessEvent("kick", "never synced, fail_closed");
            ReportAccessDecision(client, steamId, ipAddress, false, "snapshot_fallback", "snapshot_missing", "访问控制服务暂时不可用。");
            MarkClientDisconnect(client, SESSION_REASON_ACCESS_REJECTED, "访问控制服务暂时不可用。");
            KickClient(client, "%T", "Access Service Unavailable", client);
            return;
        }
        LogAccessEvent("allow", "never synced, fail_open");
        ReportAccessDecision(client, steamId, ipAddress, true, "snapshot_fallback", "", "");
        RequestAccessSnapshotRefresh(true);
        return;
    }

    char reason[256];
    if (hasAuth && FindOfflineBan(steamId, ipAddress, reason, sizeof(reason)))
    {
        LogAccessEvent("kick", "banned (local snapshot)");
        ReportAccessDecision(client, steamId, ipAddress, false, "banned", "banned", reason);
        MarkClientDisconnect(client, SESSION_REASON_BANNED_KICKED, reason);
        KickClient(client, "%T", "Kick Banned Message", client, reason);
        return;
    }

    if (!hasAuth)
    {
        // 白名单模式开启时无法验证 = 不在白名单；非白名单模式按 fail_open 放行
        if (SnapshotHasRule("whitelist_mode_enabled") || !ShouldFailOpenAccessCheck())
        {
            LogAccessEvent("kick", "no steamid under whitelist mode (fallback)");
            ReportAccessDecision(client, steamId, ipAddress, false, "whitelist_rejected", "no_steamid", "无法获取 SteamID。");
            MarkClientDisconnect(client, SESSION_REASON_ACCESS_REJECTED, "无法获取 SteamID。");
            KickClient(client, "%T", "Access Whitelist Unconfirmed", client);
            return;
        }
        LogAccessEvent("allow", "no steamid, fail_open");
        ReportAccessDecision(client, steamId, ipAddress, true, "unrestricted", "", "");
        return;
    }

    char allowMethod[32];
    char denyMethod[32];
    char denyFailureCode[48];
    char denyReason[256];
    LocalRuleDecision decision = OfflineEvaluateRules(steamId, ipAddress, allowMethod, sizeof(allowMethod), denyMethod, sizeof(denyMethod), denyFailureCode, sizeof(denyFailureCode), denyReason, sizeof(denyReason));

    if (decision == LocalRule_Allow)
    {
        LogAccessEvent("allow", "local snapshot");
        ReportAccessDecision(client, steamId, ipAddress, true, allowMethod, "", "");
        return;
    }

    if (decision == LocalRule_Deny)
    {
        // 限制侧软失败（缺资料/旧低分）：点查直取 + 宽限终裁。点查回调早到即提前裁决
        // （达标 1s 内确认，不用等满宽限），宽限定时器做最终裁决（零容忍）。
        if (IsGraceableRestrictionDeny(denyFailureCode))
        {
            float grace = (g_AccessMissingGrace == null) ? 3.0 : g_AccessMissingGrace.FloatValue;
            if (grace > 0.0 && client > 0 && client <= MaxClients && g_AccessMissingDeferred[client] == 0)
            {
                g_AccessMissingDeferred[client] = 1;
                LogAccessEvent("allow", "restriction soft-deny, point query + grace recheck");
                ReportAccessDecision(client, steamId, ipAddress, false, denyMethod, denyFailureCode, denyReason);
                RequestPlayerProfile(client, steamId);
                RequestAccessSnapshotRefresh(true);
                CreateTimer(grace, Timer_AccessMissingRecheck, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
                return;
            }
        }
        // 硬拒绝（封禁/白名单缺失/中高风险/确认不达标且宽限已用过或已关闭）：
        // 本地自治主链路下直接踢，白名单才真正生效。
        // 注意：直接用 %s 展示原因，不走 %T 翻译，避免翻译文件未更新时
        // KickClient 抛异常导致「判定拒绝却没有真正踢出」。
        LogAccessEvent("kick", "rules denied (local snapshot)");
        ReportAccessDecision(client, steamId, ipAddress, false, denyMethod, denyFailureCode, denyReason);
        MarkClientDisconnect(client, SESSION_REASON_ACCESS_REJECTED, denyReason);
        KickClient(client, "%s", denyReason);
        return;
    }

    // LocalRule_Unavailable：规则表缺失/损坏，无法裁决，按 fail_open 口径处理
    if (!ShouldFailOpenAccessCheck())
    {
        LogAccessEvent("kick", "rules unavailable, fail_closed");
        ReportAccessDecision(client, steamId, ipAddress, false, "snapshot_fallback", "rules_unavailable", "本地访问快照未确认玩家满足进入条件。");
        MarkClientDisconnect(client, SESSION_REASON_ACCESS_REJECTED, "本地访问快照未确认玩家满足进入条件。");
        KickClient(client, "%T", "Access Whitelist Unconfirmed", client);
        return;
    }
    LogAccessEvent("allow", "rules unavailable, fail_open");
    ReportAccessDecision(client, steamId, ipAddress, true, "unrestricted", "", "");
    RequestAccessSnapshotRefresh(true);
    return;
}

/**
 * 限制侧宽限终裁（点查回调早到 / 宽限定时器到期共用）。
 * 快照/点查已追平 → 留服；到期仍未验证或确认不达标 → 踢出（零容忍）。
 * kickOnMissing=false（点查回调）时若仍是软失败则不动，等宽限定时器终裁。
 */
void RecheckAccessAfterProfile(int client, const char[] tag, bool kickOnMissing)
{
    char steamId[64];
    char ipAddress[64];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId), true))
    {
        return;
    }
    GetClientIP(client, ipAddress, sizeof(ipAddress), true);

    char reason[256];
    if (FindOfflineBan(steamId, ipAddress, reason, sizeof(reason)))
    {
        LogAccessEvent("kick", "grace recheck: banned");
        ReportAccessDecision(client, steamId, ipAddress, false, "banned", "banned", reason);
        MarkClientDisconnect(client, SESSION_REASON_BANNED_KICKED, reason);
        KickClient(client, "%T", "Kick Banned Message", client, reason);
        return;
    }

    char allowMethod[32];
    char denyMethod[32];
    char denyFailureCode[48];
    char denyReason[256];
    LocalRuleDecision decision = OfflineEvaluateRules(steamId, ipAddress, allowMethod, sizeof(allowMethod), denyMethod, sizeof(denyMethod), denyFailureCode, sizeof(denyFailureCode), denyReason, sizeof(denyReason));
    if (decision == LocalRule_Allow)
    {
        LogAccessEvent("allow", tag);
        ReportAccessDecision(client, steamId, ipAddress, true, allowMethod, "", "");
        return;
    }
    if (decision == LocalRule_Deny)
    {
        if (!kickOnMissing && IsGraceableRestrictionDeny(denyFailureCode))
        {
            return;
        }
        LogAccessEvent("kick", tag);
        ReportAccessDecision(client, steamId, ipAddress, false, denyMethod, denyFailureCode, denyReason);
        MarkClientDisconnect(client, SESSION_REASON_ACCESS_REJECTED, denyReason);
        KickClient(client, "%s", denyReason);
        return;
    }

    if (!ShouldFailOpenAccessCheck())
    {
        LogAccessEvent("kick", "grace recheck: rules unavailable, fail_closed");
        ReportAccessDecision(client, steamId, ipAddress, false, "snapshot_fallback", "rules_unavailable", "本地访问快照未确认玩家满足进入条件。");
        MarkClientDisconnect(client, SESSION_REASON_ACCESS_REJECTED, "本地访问快照未确认玩家满足进入条件。");
        KickClient(client, "%T", "Access Whitelist Unconfirmed", client);
    }
}

/**
 * 宽限定时器：最终裁决（零容忍）。未达标玩家在服内存在时长不超过宽限。
 */
public Action Timer_AccessMissingRecheck(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientConnected(client) || IsFakeClient(client))
    {
        return Plugin_Stop;
    }
    if (client > 0 && client <= MaxClients)
    {
        g_AccessMissingDeferred[client] = 2;
    }
    RecheckAccessAfterProfile(client, "grace recheck: synced", true);
    return Plugin_Stop;
}

/**
 * 单玩家资料点查（宽限开始时触发，异步，不阻塞进服）。
 * 后端命中缓存毫秒级返回；缺失时做有界同步拉取（约 2s），玩家无感知。
 */
void RequestPlayerProfile(int client, const char[] steamId)
{
    if (g_AccessSnapshotDb == null || steamId[0] == '\0')
    {
        return;
    }

    char url[512];
    char token[256];
    if (!ResolvePluginApiConfig(url, sizeof(url), "/access/profile", token, sizeof(token)))
    {
        return;
    }

    int currentPort = 0;
    if (!GetCurrentServerPort(currentPort))
    {
        return;
    }

    JSONObject payload = new JSONObject();
    payload.SetString("report_token", token);
    payload.SetInt("port", currentPort);
    payload.SetString("steam_id64", steamId);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(steamId);
    PostJsonObject(url, payload, OnAccessProfileResponse, pack, g_AccessCheckTimeout.FloatValue);
    delete payload;
}

public void OnAccessProfileResponse(HTTPResponse response, any value, const char[] error)
{
    DataPack pack = view_as<DataPack>(value);
    int userid = 0;
    char steamId[64];
    steamId[0] = '\0';
    if (pack != null)
    {
        pack.Reset();
        userid = pack.ReadCell();
        pack.ReadString(steamId, sizeof(steamId));
        delete pack;
    }
    if (error[0] != '\0' || response.Status != HTTPStatus_OK)
    {
        // 点查失败/超时：宽限定时器会按零容忍终裁，这里只记日志
        LogHttpPostFailure("access profile query", response, error);
        return;
    }

    JSONObject root = view_as<JSONObject>(response.Data);
    if (root == null)
    {
        return;
    }
    JSONObject item = view_as<JSONObject>(root.Get("item"));
    if (item == null)
    {
        delete root;
        return;
    }
    char itemSteamId[64];
    item.GetString("steam_id64", itemSteamId, sizeof(itemSteamId));
    if (itemSteamId[0] == '\0')
    {
        strcopy(itemSteamId, sizeof(itemSteamId), steamId);
    }
    int rating = LumiJsonGetInt(item, "rating");
    int steamLevel = LumiJsonGetInt(item, "steam_level");
    int expiresAt = LumiJsonGetInt(item, "expires_at_unix");
    delete item;
    delete root;

    if (!UpsertAccessProfile(itemSteamId, rating, steamLevel, expiresAt))
    {
        return;
    }
    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientConnected(client) || IsFakeClient(client))
    {
        return;
    }
    // 点查早到：立即复核，不用等满宽限；仍是软失败则等定时器终裁
    RecheckAccessAfterProfile(client, "grace recheck: point query hit", false);
}

/**
 * 点查资料写入本地表（INSERT OR REPLACE），复核即用，不必等快照轮询。
 */
bool UpsertAccessProfile(const char[] steamId, int rating, int steamLevel, int expiresAt)
{
    if (g_AccessSnapshotDb == null || steamId[0] == '\0' || expiresAt <= GetTime())
    {
        return false;
    }

    char escapedSteamId[128];
    char query[512];
    SQL_EscapeString(g_AccessSnapshotDb, steamId, escapedSteamId, sizeof(escapedSteamId));
    Format(query, sizeof(query),
        "INSERT OR REPLACE INTO access_profiles (steam_id, rating, steam_level, expires_at) VALUES ('%s', %d, %d, %d)",
        escapedSteamId, rating, steamLevel, expiresAt);
    return SQL_FastQuery(g_AccessSnapshotDb, query);
}

/**
 * 本地裁决三态结果：
 *  - LocalRule_Allow        ：满足进服条件（method 给出进服方式）
 *  - LocalRule_Deny         ：明确不满足（白名单缺失/门槛不足）→ 直接踢，白名单才真正生效
 *  - LocalRule_Unavailable  ：规则表缺失/损坏，无法裁决 → 由 fail_open 决定放行或踢
 *
 * 关键：旧实现把「明确拒绝」和「规则不可用」混为一谈（都返回 false 后按 fail_open
 * 放行），导致 LumiAuth 本地自治主链路下白名单形同虚设。此枚举区分两者。
 */
enum LocalRuleDecision
{
    LocalRule_Allow = 0,
    LocalRule_Deny = 1,
    LocalRule_Unavailable = 2,
}

/**
 * 本地规则裁决（三态）。
 * allowMethod 在 Allow 时写入进服方式（whitelist / restriction / unrestricted）。
 * denyMethod / denyFailureCode / denyReason 在 Deny 时写入进服方式与拒绝原因，
 * 供进服监控展示（如 whitelist_rejected / restriction_rejected）。
 */
LocalRuleDecision OfflineEvaluateRules(
    const char[] steamId,
    const char[] ipAddress,
    char[] allowMethod, int methodMaxLen,
    char[] denyMethod, int denyMethodMaxLen,
    char[] denyFailureCode, int failMaxLen,
    char[] denyReason, int reasonMaxLen)
{
    allowMethod[0] = '\0';
    denyMethod[0] = '\0';
    denyFailureCode[0] = '\0';
    denyReason[0] = '\0';

    if (g_AccessSnapshotDb == null)
    {
        return LocalRule_Unavailable;
    }

    DBResultSet results = SQL_Query(g_AccessSnapshotDb, "SELECT whitelist_mode_enabled, access_restriction_enabled, min_rating, min_steam_level, risk_block_enabled FROM server_rules WHERE id = 1");
    if (results == null)
    {
        return LocalRule_Unavailable;
    }

    if (!SQL_FetchRow(results))
    {
        // 规则表无行：无法裁决（不是玩家不满足）
        delete results;
        return LocalRule_Unavailable;
    }

    bool whitelistModeEnabled = SQL_FetchInt(results, 0) != 0;
    bool accessRestrictionEnabled = SQL_FetchInt(results, 1) != 0;
    int minRating = SQL_FetchInt(results, 2);
    int minSteamLevel = SQL_FetchInt(results, 3);
    bool riskBlockEnabled = results.FieldCount > 4 && SQL_FetchInt(results, 4) != 0;
    delete results;

    bool hasWhitelist = whitelistModeEnabled && OfflineWhitelistContains(steamId);

    int profileRating = 0;
    int profileSteamLevel = 0;
    ProfileCheck profileCheck = ProfileCheck_Missing;
    bool meetsRestriction = accessRestrictionEnabled;
    if (accessRestrictionEnabled && !(minRating <= 0 && minSteamLevel <= 0))
    {
        profileCheck = OfflineCheckProfile(steamId, minRating, minSteamLevel, profileRating, profileSteamLevel);
        meetsRestriction = profileCheck == ProfileCheck_Meets;
    }

    // 中高风险拦截（risk_block）：未持白名单且当前 IP 与有效封禁账号关联 → 拒绝
    if (riskBlockEnabled && !(whitelistModeEnabled && hasWhitelist) && OfflineIpHasRisk(ipAddress))
    {
        strcopy(denyMethod, denyMethodMaxLen, "risk_blocked");
        strcopy(denyFailureCode, failMaxLen, "risk_blocked");
        strcopy(denyReason, reasonMaxLen, "检测到你的网络环境存在风险，暂时无法进入该服务器。");
        return LocalRule_Deny;
    }

    // 均未开启 → 无限制放行
    if (!whitelistModeEnabled && !accessRestrictionEnabled)
    {
        strcopy(allowMethod, methodMaxLen, "unrestricted");
        return LocalRule_Allow;
    }

    // 进入限制优先（与后端 /access/check 顺序一致）
    if (accessRestrictionEnabled && meetsRestriction)
    {
        strcopy(allowMethod, methodMaxLen, "restriction");
        return LocalRule_Allow;
    }

    // 白名单放行
    if (whitelistModeEnabled && hasWhitelist)
    {
        strcopy(allowMethod, methodMaxLen, "whitelist");
        return LocalRule_Allow;
    }

    // 明确拒绝：按启用模式给出原因与失败码（与后端 access/check 组合一致）。
    // 限制侧失败码细分：low_rating / low_steam_level / profile_missing，
    // 供进服监控准确展示（资料未验证 ≠ Rating 不足）。
    if (whitelistModeEnabled && !hasWhitelist && !accessRestrictionEnabled)
    {
        strcopy(denyMethod, denyMethodMaxLen, "whitelist_rejected");
        strcopy(denyFailureCode, failMaxLen, "not_whitelisted");
        strcopy(denyReason, reasonMaxLen, "你没有该服务器的白名单，请前往网站申请。");
    }
    else if (accessRestrictionEnabled && !meetsRestriction && !whitelistModeEnabled)
    {
        strcopy(denyMethod, denyMethodMaxLen, "restriction_rejected");
        FormatProfileDeny(profileCheck, profileRating, profileSteamLevel, minRating, minSteamLevel, denyFailureCode, failMaxLen, denyReason, reasonMaxLen);
    }
    else if (whitelistModeEnabled && !hasWhitelist && accessRestrictionEnabled && !meetsRestriction)
    {
        // 组合拒绝：白名单与门槛均未满足；失败码给出限制侧的具体原因，便于审计区分
        strcopy(denyMethod, denyMethodMaxLen, "restriction_rejected");
        FormatProfileDeny(profileCheck, profileRating, profileSteamLevel, minRating, minSteamLevel, denyFailureCode, failMaxLen, denyReason, reasonMaxLen);
        strcopy(denyReason, reasonMaxLen, "你既没有该服务器的白名单，也未达到最低进入要求。");
    }
    else
    {
        // 组合下至少其一满足即已放行，走到这里说明白名单与门槛均未满足
        strcopy(denyMethod, denyMethodMaxLen, "restriction_rejected");
        FormatProfileDeny(profileCheck, profileRating, profileSteamLevel, minRating, minSteamLevel, denyFailureCode, failMaxLen, denyReason, reasonMaxLen);
        strcopy(denyReason, reasonMaxLen, "你的资料未满足服务器进入要求。");
    }
    return LocalRule_Deny;
}


bool SnapshotHasRule(const char[] column)
{
    char query[128];
    Format(query, sizeof(query), "SELECT %s FROM server_rules WHERE id = 1", column);
    DBResultSet results = SQL_Query(g_AccessSnapshotDb, query);
    if (results == null)
    {
        return false;
    }
    bool enabled = SQL_FetchRow(results) && SQL_FetchInt(results, 0) != 0;
    delete results;
    return enabled;
}

// =====[ 本地快照查询 ]=====

bool ShouldFailOpenAccessCheck()
{
    return g_AccessFailOpen == null || g_AccessFailOpen.BoolValue;
}

bool GetMetadataValue(const char[] key, char[] value, int maxLen)
{
    char escapedKey[128];
    char query[256];
    SQL_EscapeString(g_AccessSnapshotDb, key, escapedKey, sizeof(escapedKey));
    Format(query, sizeof(query), "SELECT value FROM metadata WHERE key = '%s'", escapedKey);

    DBResultSet results = SQL_Query(g_AccessSnapshotDb, query);
    if (results == null)
    {
        return false;
    }

    bool found = false;
    if (SQL_FetchRow(results))
    {
        SQL_FetchString(results, 0, value, maxLen);
        found = true;
    }
    delete results;
    return found;
}

bool FindOfflineBan(const char[] steamId, const char[] ipAddress, char[] reason, int maxLen)
{
    char escapedSteamId[128];
    char escapedIpAddress[128];
    char query[512];
    SQL_EscapeString(g_AccessSnapshotDb, steamId, escapedSteamId, sizeof(escapedSteamId));
    SQL_EscapeString(g_AccessSnapshotDb, ipAddress, escapedIpAddress, sizeof(escapedIpAddress));
    Format(query, sizeof(query), "SELECT reason FROM bans WHERE (steam_id = '%s' OR ip_address = '%s') AND (expires_at IS NULL OR expires_at = 0 OR expires_at > %d) LIMIT 1", escapedSteamId, escapedIpAddress, GetTime());

    DBResultSet results = SQL_Query(g_AccessSnapshotDb, query);
    if (results == null)
    {
        return false;
    }

    bool found = false;
    if (SQL_FetchRow(results))
    {
        SQL_FetchString(results, 0, reason, maxLen);
        found = true;
    }
    delete results;
    return found;
}

bool OfflineWhitelistContains(const char[] steamId)
{
    char escapedSteamId[128];
    char query[256];
    SQL_EscapeString(g_AccessSnapshotDb, steamId, escapedSteamId, sizeof(escapedSteamId));
    Format(query, sizeof(query), "SELECT steam_id FROM whitelist WHERE steam_id = '%s' LIMIT 1", escapedSteamId);

    DBResultSet results = SQL_Query(g_AccessSnapshotDb, query);
    if (results == null)
    {
        return false;
    }

    bool found = SQL_FetchRow(results);
    delete results;
    return found;
}

// 当前 IP 是否与「当前有效封禁账号」关联（快照 risk_ips 集合，供 risk_block 使用）
bool OfflineIpHasRisk(const char[] ipAddress)
{
    if (ipAddress[0] == '\0')
    {
        return false;
    }

    char escapedIpAddress[128];
    char query[256];
    SQL_EscapeString(g_AccessSnapshotDb, ipAddress, escapedIpAddress, sizeof(escapedIpAddress));
    Format(query, sizeof(query), "SELECT 1 FROM risk_ips WHERE ip = '%s' LIMIT 1", escapedIpAddress);

    DBResultSet results = SQL_Query(g_AccessSnapshotDb, query);
    if (results == null)
    {
        return false;
    }

    bool found = SQL_FetchRow(results);
    delete results;
    return found;
}

/**
 * 玩家进服资料（rating / steam_level）本地校验结果：
 *  - Meets          ：资料存在且未过期，rating 与 steam 等级均达标
 *  - LowRating      ：rating 低于门槛（资料存在，玩家确实未达标）
 *  - LowSteamLevel  ：steam 等级低于门槛
 *  - Missing        ：快照无该玩家资料或资料已过期 → 是「未验证」而非「不达标」，
 *                     上报 profile_missing，由拒绝驱动的资料强刷链路自愈
 */
enum ProfileCheck
{
    ProfileCheck_Meets = 0,
    ProfileCheck_LowRating = 1,
    ProfileCheck_LowSteamLevel = 2,
    ProfileCheck_Missing = 3,
}

/**
 * 校验快照 access_profiles 中的玩家资料是否满足进服门槛。
 * rating / steamLevel 在资料存在时输出实际值（用于拒绝原因展示）。
 * 带 expires_at 过滤：过期资料视为未验证，避免快照刷新长期失败时用过期数据裁决。
 */
ProfileCheck OfflineCheckProfile(const char[] steamId, int minRating, int minSteamLevel, int &rating, int &steamLevel)
{
    rating = 0;
    steamLevel = 0;

    char escapedSteamId[128];
    char query[256];
    SQL_EscapeString(g_AccessSnapshotDb, steamId, escapedSteamId, sizeof(escapedSteamId));
    Format(query, sizeof(query), "SELECT rating, steam_level, expires_at FROM access_profiles WHERE steam_id = '%s' LIMIT 1", escapedSteamId);

    DBResultSet results = SQL_Query(g_AccessSnapshotDb, query);
    if (results == null)
    {
        return ProfileCheck_Missing;
    }

    ProfileCheck result = ProfileCheck_Missing;
    if (SQL_FetchRow(results))
    {
        rating = SQL_FetchInt(results, 0);
        steamLevel = SQL_FetchInt(results, 1);
        int expiresAt = SQL_FetchInt(results, 2);
        if (expiresAt > 0 && expiresAt <= GetTime())
        {
            result = ProfileCheck_Missing;
        }
        else if (rating < minRating)
        {
            result = ProfileCheck_LowRating;
        }
        else if (steamLevel < minSteamLevel)
        {
            result = ProfileCheck_LowSteamLevel;
        }
        else
        {
            result = ProfileCheck_Meets;
        }
    }
    delete results;
    return result;
}

/**
 * 由资料校验结果生成限制侧失败码与拒绝原因。
 * low_rating / low_steam_level 的原因带具体数值，玩家与管理员可直接对账；
 * profile_missing 提示稍后重试（自愈链路正在刷新资料）。
 */
void FormatProfileDeny(ProfileCheck check, int rating, int steamLevel, int minRating, int minSteamLevel, char[] failCode, int failMaxLen, char[] reason, int reasonMaxLen)
{
    if (check == ProfileCheck_LowRating)
    {
        strcopy(failCode, failMaxLen, "low_rating");
        Format(reason, reasonMaxLen, "你的 Rating %d 未达到该服务器要求的 %d。", rating, minRating);
    }
    else if (check == ProfileCheck_LowSteamLevel)
    {
        strcopy(failCode, failMaxLen, "low_steam_level");
        Format(reason, reasonMaxLen, "你的 Steam 等级 %d 未达到该服务器要求的 %d。", steamLevel, minSteamLevel);
    }
    else
    {
        strcopy(failCode, failMaxLen, "profile_missing");
        strcopy(reason, reasonMaxLen, "你的进入资料尚未验证，请稍后再试。");
    }
}

// =====[ 熔断器（已删除：在线复核层随 LumiAuth 上线退役，后台补偿靠 auth_sync 退避）]=====

// =====[ 快照刷新 ]=====

void StartAccessSnapshotTimer()
{
    StopAccessSnapshotTimer();

    float interval = g_AccessSnapshotInterval.FloatValue;
    g_AccessSnapshotTimer = CreateTimer(interval, Timer_RefreshAccessSnapshot, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void StopAccessSnapshotTimer()
{
    if (g_AccessSnapshotTimer != null)
    {
        delete g_AccessSnapshotTimer;
        g_AccessSnapshotTimer = null;
    }
}

/**
 * 立即刷新（带退避节流）：快照缺失/熔断触发时调用。
 * immediate=true 时跳过退避直接请求（首次部署、手动应急）。
 */
void RequestAccessSnapshotRefresh(bool immediate)
{
    int now = GetTime();
    int backoff = g_AccessSnapshotBackoffStep;
    if (!immediate && backoff > 0 && now < g_AccessSnapshotNextRetry)
    {
        return;
    }

    g_AccessSnapshotNextRetry = now + NextSnapshotBackoffSeconds();
    RefreshAccessSnapshot();
}

int NextSnapshotBackoffSeconds()
{
    // 30s→60s→120s→300s 退避，上限为常规刷新间隔
    int base = 30 << (g_AccessSnapshotBackoffStep > 4 ? 4 : g_AccessSnapshotBackoffStep);
    int interval = g_AccessSnapshotInterval.IntValue;
    if (interval > 0 && base > interval)
    {
        base = interval;
    }
    return base;
}

public Action Timer_RefreshAccessSnapshot(Handle timer)
{
    RefreshAccessSnapshot();
    return Plugin_Continue;
}

void RefreshAccessSnapshot()
{
    if (g_AccessSnapshotDb == null)
    {
        return;
    }

    char token[256];
    char url[512];
    int currentPort = 0;
    if (!GetCurrentServerPort(currentPort))
    {
        return;
    }

    if (!ResolvePluginApiConfig(url, sizeof(url), "/access/snapshot", token, sizeof(token)))
    {
        if (ShouldLogAccessConfigError())
        {
            LogError("[LumiAdmin-Access] snapshot refresh skipped: plugin API config unavailable.");
        }
        return;
    }

    JSONObject payload = new JSONObject();
    payload.SetString("report_token", token);
    payload.SetInt("port", currentPort);
    // etag 增量：回传现有快照版本，后端无变化时跳过全量传输。
    // 例外：本地 server_rules 缺失/异常时省略 etag，强制后端回全量以补写规则，
    // 避免「etag 命中 unchanged → 规则表永远为空 → 本地裁决全部 fail_open」。
    if (g_AccessSnapshotEtag[0] != '\0' && LocalServerRulesPresent())
    {
        payload.SetString("etag", g_AccessSnapshotEtag);
    }
    else if (g_AccessSnapshotEtag[0] != '\0')
    {
        LogError("[LumiAdmin-Access] local server_rules missing; forcing full snapshot refresh.");
    }

    PostJsonObject(url, payload, OnAccessSnapshotResponse, 0, g_AccessCheckTimeout.FloatValue);
    delete payload;
}

/**
 * 本地快照是否曾经同步成功（metadata.version 有值，SQLite 持久化，重启不丢）。
 * false = 白名单/资料表可能是空的，无裁决依据，进服走 fail_open 兜底而非直接踢。
 */
bool LocalSnapshotEverSynced()
{
    if (g_AccessSnapshotDb == null)
    {
        return false;
    }

    char version[128];
    if (!GetMetadataValue("version", version, sizeof(version)))
    {
        return false;
    }
    return version[0] != '\0';
}

/**
 * 本地规则表是否已写入（server_rules 有 id=1 行）。
 * 用于决定快照刷新是否可走 etag 增量。
 */
bool LocalServerRulesPresent()
{
    if (g_AccessSnapshotDb == null)
    {
        return false;
    }

    DBResultSet results = SQL_Query(g_AccessSnapshotDb, "SELECT 1 FROM server_rules WHERE id = 1 LIMIT 1");
    if (results == null)
    {
        return false;
    }
    bool present = SQL_FetchRow(results);
    delete results;
    return present;
}

public void OnAccessSnapshotResponse(HTTPResponse response, any value, const char[] error)
{
    if (error[0] != '\0')
    {
        SnapshotRefreshFailed("HTTP error", error);
        return;
    }

    if (response.Status != HTTPStatus_OK)
    {
        // etag 协议兼容：后端不支持时可能返回非 200，仅记录
        if (response.Status != HTTPStatus_NotModified)
        {
            SnapshotRefreshFailed("HTTP status", "");
        }
        return;
    }

    JSONObject root = view_as<JSONObject>(response.Data);
    if (root == null)
    {
        SnapshotRefreshFailed("empty response", "");
        return;
    }

    // 后端确认无变化：刷新成功，重置退避。
    // RIPExt 对缺失 key 会抛异常，统一走 LumiJsonGetBool 安全取值。
    if (LumiJsonGetBool(root, "unchanged"))
    {
        g_AccessSnapshotBackoffStep = 0;
        g_AccessSnapshotLastRefreshOk = GetTime();
        delete root;
        return;
    }

    JSONObject item = view_as<JSONObject>(root.Get("item"));
    if (item == null)
    {
        LogError("[LumiAdmin-Access] access snapshot response missed item.");
        delete root;
        return;
    }

    bool wasSynced = LocalSnapshotEverSynced();
    SaveAccessSnapshot(item);
    delete item;
    delete root;
    // 首启/部署窗口内放行过的玩家：首次同步成功后立即比对补踢
    if (!wasSynced && LocalSnapshotEverSynced())
    {
        LogAccessEvent("snapshot", "first sync, reconciling online players");
        AuthReconcileOnlinePlayers();
    }
}

void SnapshotRefreshFailed(const char[] cause, const char[] detail)
{
    g_AccessSnapshotBackoffStep = (g_AccessSnapshotBackoffStep >= 4) ? 4 : g_AccessSnapshotBackoffStep + 1;
    if (detail[0] != '\0')
    {
        LogError("[LumiAdmin-Access] snapshot refresh failed (%s): %s. Backing off %ds.", cause, detail, NextSnapshotBackoffSeconds());
    }
    else
    {
        LogError("[LumiAdmin-Access] snapshot refresh failed (%s). Backing off %ds.", cause, NextSnapshotBackoffSeconds());
    }
    LogAccessEvent("snapshot", cause);
}

void InitAccessSnapshotDb()
{
    char error[256];
    g_AccessSnapshotDb = SQLite_UseDatabase(ACCESS_SNAPSHOT_DB, error, sizeof(error));
    if (g_AccessSnapshotDb == null)
    {
        LogError("[LumiAdmin-Access] access snapshot SQLite open failed: %s", error);
        return;
    }

    SQL_FastQuery(g_AccessSnapshotDb, "CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
    SQL_FastQuery(g_AccessSnapshotDb, "CREATE TABLE IF NOT EXISTS server_rules (id INTEGER PRIMARY KEY CHECK (id = 1), whitelist_mode_enabled INTEGER NOT NULL, access_restriction_enabled INTEGER NOT NULL, min_rating INTEGER NOT NULL, min_steam_level INTEGER NOT NULL, risk_block_enabled INTEGER NOT NULL DEFAULT 0)");
    // 旧库升级：补 risk_block_enabled 列（CREATE IF NOT EXISTS 不会改已有表）
    SQL_FastQuery(g_AccessSnapshotDb, "ALTER TABLE server_rules ADD COLUMN risk_block_enabled INTEGER NOT NULL DEFAULT 0");
    SQL_FastQuery(g_AccessSnapshotDb, "CREATE TABLE IF NOT EXISTS risk_ips (ip TEXT PRIMARY KEY)");
    SQL_FastQuery(g_AccessSnapshotDb, "CREATE TABLE IF NOT EXISTS bans (steam_id TEXT, ip_address TEXT, reason TEXT NOT NULL, expires_at INTEGER)");
    SQL_FastQuery(g_AccessSnapshotDb, "CREATE TABLE IF NOT EXISTS whitelist (steam_id TEXT PRIMARY KEY)");
    SQL_FastQuery(g_AccessSnapshotDb, "CREATE TABLE IF NOT EXISTS access_profiles (steam_id TEXT PRIMARY KEY, rating INTEGER NOT NULL, steam_level INTEGER NOT NULL, expires_at INTEGER NOT NULL)");

    SQL_FastQuery(g_AccessSnapshotDb, "CREATE INDEX IF NOT EXISTS idx_bans_steam_id ON bans(steam_id)");
    SQL_FastQuery(g_AccessSnapshotDb, "CREATE INDEX IF NOT EXISTS idx_bans_ip_address ON bans(ip_address)");
    SQL_FastQuery(g_AccessSnapshotDb, "CREATE INDEX IF NOT EXISTS idx_bans_expires_at ON bans(expires_at)");
    // 本地兜底封禁（H6）与快照全量回放共用 bans 表：
    // 唯一索引保证 poll 回放对同一 (steam_id, ip_address, reason, expires_at) 幂等
    SQL_FastQuery(g_AccessSnapshotDb, "CREATE UNIQUE INDEX IF NOT EXISTS idx_bans_dedupe ON bans(steam_id, ip_address, reason, expires_at)");
    // LumiAuth：事件幂等表（event_id 去重）+ last_applied_version 持久化在 metadata
    SQL_FastQuery(g_AccessSnapshotDb, "CREATE TABLE IF NOT EXISTS applied_events (event_id TEXT PRIMARY KEY, version INTEGER NOT NULL)");
    SQL_FastQuery(g_AccessSnapshotDb, "CREATE INDEX IF NOT EXISTS idx_applied_events_version ON applied_events(version)");

    char etag[128];
    if (GetMetadataValue("version", etag, sizeof(etag)) && etag[0] != '\0')
    {
        strcopy(g_AccessSnapshotEtag, sizeof(g_AccessSnapshotEtag), etag);
    }

    char appliedText[32];
    if (GetMetadataValue("auth_last_applied_version", appliedText, sizeof(appliedText)))
    {
        g_AuthLastAppliedVersion = StringToInt(appliedText);
        if (g_AuthLastAppliedVersion < 0)
        {
            g_AuthLastAppliedVersion = 0;
        }
    }

    // 规则表缺失（升级/首次/上次写入回滚）时：清掉 etag，确保下次刷新带回全量规则，
    // 否则 etag 命中 unchanged 会让规则表永远为空，本地裁决全部 fail_open。
    if (!LocalServerRulesPresent())
    {
        LogError("[LumiAdmin-Access] local server_rules missing at startup; full snapshot required.");
        g_AccessSnapshotEtag[0] = '\0';
    }
}

/**
 * 快车道/事件写入本地封禁（先落盘再 Kick 由调用方保证顺序）。
 * eventId 为空时跳过幂等表（快车道 RCON 无 event_id，用 ban_id 去重由快照回放保证）。
 */
bool AuthUpsertLocalBan(const char[] steamId, const char[] ipAddress, const char[] reason, int expiresAt, const char[] eventId, int version)
{
    if (g_AccessSnapshotDb == null)
    {
        return false;
    }

    if (eventId[0] != '\0' && AuthEventAlreadyApplied(eventId))
    {
        return true;
    }

    char escapedSteamId[128];
    char escapedIp[128];
    char escapedReason[512];
    SQL_EscapeString(g_AccessSnapshotDb, steamId, escapedSteamId, sizeof(escapedSteamId));
    SQL_EscapeString(g_AccessSnapshotDb, ipAddress, escapedIp, sizeof(escapedIp));
    SQL_EscapeString(g_AccessSnapshotDb, reason, escapedReason, sizeof(escapedReason));

    char query[1024];
    Format(query, sizeof(query), "INSERT OR IGNORE INTO bans (steam_id, ip_address, reason, expires_at) VALUES ('%s', '%s', '%s', %d)",
        escapedSteamId, escapedIp, escapedReason, expiresAt);
    if (!SQL_FastQuery(g_AccessSnapshotDb, query))
    {
        LogError("[LumiAuth] local ban upsert failed for %s.", steamId);
        return false;
    }

    if (eventId[0] != '\0')
    {
        AuthMarkEventApplied(eventId, version);
    }
    return true;
}

bool AuthRemoveLocalBan(const char[] steamId, const char[] eventId, int version)
{
    if (g_AccessSnapshotDb == null)
    {
        return false;
    }

    if (eventId[0] != '\0' && AuthEventAlreadyApplied(eventId))
    {
        return true;
    }

    char escaped[128];
    char query[256];
    SQL_EscapeString(g_AccessSnapshotDb, steamId, escaped, sizeof(escaped));
    Format(query, sizeof(query), "DELETE FROM bans WHERE steam_id = '%s'", escaped);
    SQL_FastQuery(g_AccessSnapshotDb, query);

    if (eventId[0] != '\0')
    {
        AuthMarkEventApplied(eventId, version);
    }
    return true;
}

bool AuthUpsertWhitelist(const char[] steamId, const char[] eventId, int version)
{
    if (g_AccessSnapshotDb == null)
    {
        return false;
    }

    if (eventId[0] != '\0' && AuthEventAlreadyApplied(eventId))
    {
        return true;
    }

    char escaped[128];
    char query[256];
    SQL_EscapeString(g_AccessSnapshotDb, steamId, escaped, sizeof(escaped));
    Format(query, sizeof(query), "INSERT OR REPLACE INTO whitelist (steam_id) VALUES ('%s')", escaped);
    if (!SQL_FastQuery(g_AccessSnapshotDb, query))
    {
        LogError("[LumiAuth] local whitelist upsert failed for %s.", steamId);
        return false;
    }

    if (eventId[0] != '\0')
    {
        AuthMarkEventApplied(eventId, version);
    }
    return true;
}

bool AuthRemoveWhitelist(const char[] steamId, const char[] eventId, int version)
{
    if (g_AccessSnapshotDb == null)
    {
        return false;
    }

    if (eventId[0] != '\0' && AuthEventAlreadyApplied(eventId))
    {
        return true;
    }

    char escaped[128];
    char query[256];
    SQL_EscapeString(g_AccessSnapshotDb, steamId, escaped, sizeof(escaped));
    Format(query, sizeof(query), "DELETE FROM whitelist WHERE steam_id = '%s'", escaped);
    SQL_FastQuery(g_AccessSnapshotDb, query);

    if (eventId[0] != '\0')
    {
        AuthMarkEventApplied(eventId, version);
    }
    return true;
}

bool AuthEventAlreadyApplied(const char[] eventId)
{
    char escaped[128];
    char query[256];
    SQL_EscapeString(g_AccessSnapshotDb, eventId, escaped, sizeof(escaped));
    Format(query, sizeof(query), "SELECT version FROM applied_events WHERE event_id = '%s' LIMIT 1", escaped);
    DBResultSet results = SQL_Query(g_AccessSnapshotDb, query);
    if (results == null)
    {
        return false;
    }
    bool found = SQL_FetchRow(results);
    delete results;
    return found;
}

void AuthMarkEventApplied(const char[] eventId, int version)
{
    char escaped[128];
    char query[256];
    SQL_EscapeString(g_AccessSnapshotDb, eventId, escaped, sizeof(escaped));
    Format(query, sizeof(query), "INSERT OR IGNORE INTO applied_events (event_id, version) VALUES ('%s', %d)", escaped, version);
    SQL_FastQuery(g_AccessSnapshotDb, query);
    AuthPersistAppliedVersion(version);
}

void AuthPersistAppliedVersion(int version)
{
    if (version > g_AuthLastAppliedVersion)
    {
        g_AuthLastAppliedVersion = version;
    }
    char text[32];
    IntToString(g_AuthLastAppliedVersion, text, sizeof(text));
    char escaped[64];
    SQL_EscapeString(g_AccessSnapshotDb, text, escaped, sizeof(escaped));
    char query[256];
    Format(query, sizeof(query), "INSERT OR REPLACE INTO metadata (key, value) VALUES ('auth_last_applied_version', '%s')", escaped);
    SQL_FastQuery(g_AccessSnapshotDb, query);
}

// =====[ 恢复后全服比对补踢（Q5 定稿：立即执行，对局中也会被踢）]=====

void AuthReconcileOnlinePlayers()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
        {
            continue;
        }

        char steamId[64];
        char ip[64];
        if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId), true))
        {
            continue;
        }
        GetClientIP(client, ip, sizeof(ip), true);

        char reason[256];
        if (FindOfflineBan(steamId, ip, reason, sizeof(reason)))
        {
            LogAccessEvent("kick", "reconcile: banned after resync");
            MarkClientDisconnect(client, SESSION_REASON_BANNED_KICKED, reason);
            KickClient(client, "%T", "Kick Banned Message", client, reason);
            continue;
        }

        char allowMethod[32];
        char denyMethod[32];
        char denyFailureCode[48];
        char denyReason[256];
        LocalRuleDecision decision = OfflineEvaluateRules(steamId, ip, allowMethod, sizeof(allowMethod), denyMethod, sizeof(denyMethod), denyFailureCode, sizeof(denyFailureCode), denyReason, sizeof(denyReason));
        if (decision == LocalRule_Deny)
        {
            LogAccessEvent("kick", "reconcile: rules denied");
            ReportAccessDecision(client, steamId, ip, false, denyMethod, denyFailureCode, denyReason);
            MarkClientDisconnect(client, SESSION_REASON_ACCESS_REJECTED, denyReason);
            KickClient(client, "%s", denyReason);
        }
        else if (decision == LocalRule_Unavailable && !ShouldFailOpenAccessCheck())
        {
            LogAccessEvent("kick", "reconcile: rules unavailable, fail_closed");
            MarkClientDisconnect(client, SESSION_REASON_ACCESS_REJECTED, "本地访问快照未确认玩家满足进入条件。");
            KickClient(client, "%T", "Access Whitelist Unconfirmed", client);
        }
    }
}

void SaveAccessSnapshot(JSONObject item)
{
    if (g_AccessSnapshotDb == null)
    {
        return;
    }

    if (!SQL_FastQuery(g_AccessSnapshotDb, "BEGIN IMMEDIATE TRANSACTION"))
    {
        LogError("[LumiAdmin-Access] access snapshot: failed to BEGIN transaction.");
        return;
    }

    if (!SQL_FastQuery(g_AccessSnapshotDb, "DELETE FROM metadata")
        || !SQL_FastQuery(g_AccessSnapshotDb, "DELETE FROM server_rules")
        || !SQL_FastQuery(g_AccessSnapshotDb, "DELETE FROM bans")
        || !SQL_FastQuery(g_AccessSnapshotDb, "DELETE FROM whitelist")
        || !SQL_FastQuery(g_AccessSnapshotDb, "DELETE FROM access_profiles")
        || !SQL_FastQuery(g_AccessSnapshotDb, "DELETE FROM risk_ips"))
    {
        LogError("[LumiAdmin-Access] access snapshot: cleanup failed, ROLLBACK.");
        SQL_FastQuery(g_AccessSnapshotDb, "ROLLBACK");
        return;
    }

    char version[128];
    char generatedAt[64];
    char expiresAt[64];
    item.GetString("version", version, sizeof(version));
    item.GetString("generated_at", generatedAt, sizeof(generatedAt));
    item.GetString("expires_at", expiresAt, sizeof(expiresAt));

    if (!InsertMetadata("version", version)
        || !InsertMetadata("generated_at", generatedAt)
        || !InsertMetadata("expires_at", expiresAt))
    {
        LogError("[LumiAdmin-Access] access snapshot: metadata insert failed, ROLLBACK.");
        SQL_FastQuery(g_AccessSnapshotDb, "ROLLBACK");
        return;
    }

    char generatedAtUnix[32];
    char expiresAtUnix[32];
    IntToString(LumiJsonGetInt(item, "generated_at_unix"), generatedAtUnix, sizeof(generatedAtUnix));
    IntToString(LumiJsonGetInt(item, "expires_at_unix"), expiresAtUnix, sizeof(expiresAtUnix));
    if (!InsertMetadata("generated_at_unix", generatedAtUnix)
        || !InsertMetadata("expires_at_unix", expiresAtUnix))
    {
        LogError("[LumiAdmin-Access] access snapshot: metadata unix insert failed, ROLLBACK.");
        SQL_FastQuery(g_AccessSnapshotDb, "ROLLBACK");
        return;
    }

    JSONObject server = view_as<JSONObject>(LumiJsonGet(item, "server"));
    if (server != null)
    {
        char query[512];
        Format(query, sizeof(query),
            "INSERT INTO server_rules (id, whitelist_mode_enabled, access_restriction_enabled, min_rating, min_steam_level, risk_block_enabled) VALUES (1, %d, %d, %d, %d, %d)",
            LumiJsonGetBool(server, "whitelist_mode_enabled") ? 1 : 0,
            LumiJsonGetBool(server, "access_restriction_enabled") ? 1 : 0,
            LumiJsonGetInt(server, "min_rating"),
            LumiJsonGetInt(server, "min_steam_level"),
            LumiJsonGetBool(server, "risk_block_enabled") ? 1 : 0);
        if (!SQL_FastQuery(g_AccessSnapshotDb, query))
        {
            LogError("[LumiAdmin-Access] access snapshot: server_rules insert failed, ROLLBACK.");
            SQL_FastQuery(g_AccessSnapshotDb, "ROLLBACK");
            delete server;
            return;
        }
        delete server;
    }
    else
    {
        // 缺少 server 段：不能清空规则表后留下空状态（会导致本地裁决全部 fail_open），
        // 直接回滚保留旧规则，等待下一次带 server 的全量快照。
        LogError("[LumiAdmin-Access] access snapshot: missing server rules, ROLLBACK.");
        SQL_FastQuery(g_AccessSnapshotDb, "ROLLBACK");
        return;
    }

    JSONArray bans = view_as<JSONArray>(item.Get("bans"));
    bool bansSaved = SaveSnapshotBans(bans);
    if (bans != null)
    {
        delete bans;
    }
    if (!bansSaved)
    {
        SQL_FastQuery(g_AccessSnapshotDb, "ROLLBACK");
        return;
    }

    JSONArray whitelist = view_as<JSONArray>(item.Get("whitelist"));
    bool whitelistSaved = SaveSnapshotWhitelist(whitelist);
    if (whitelist != null)
    {
        delete whitelist;
    }
    if (!whitelistSaved)
    {
        SQL_FastQuery(g_AccessSnapshotDb, "ROLLBACK");
        return;
    }

    JSONArray profiles = view_as<JSONArray>(item.Get("access_profiles"));
    bool profilesSaved = SaveSnapshotAccessProfiles(profiles);
    if (profiles != null)
    {
        delete profiles;
    }
    if (!profilesSaved)
    {
        SQL_FastQuery(g_AccessSnapshotDb, "ROLLBACK");
        return;
    }

    JSONArray riskIps = view_as<JSONArray>(item.Get("risk_ips"));
    bool riskIpsSaved = SaveSnapshotRiskIps(riskIps);
    if (riskIps != null)
    {
        delete riskIps;
    }
    if (!riskIpsSaved)
    {
        SQL_FastQuery(g_AccessSnapshotDb, "ROLLBACK");
        return;
    }

    if (!SQL_FastQuery(g_AccessSnapshotDb, "COMMIT"))
    {
        LogError("[LumiAdmin-Access] access snapshot: COMMIT failed, ROLLBACK.");
        SQL_FastQuery(g_AccessSnapshotDb, "ROLLBACK");
        return;
    }

    g_AccessSnapshotBackoffStep = 0;
    g_AccessSnapshotLastRefreshOk = GetTime();
    strcopy(g_AccessSnapshotEtag, sizeof(g_AccessSnapshotEtag), version);
    LogMessage("[LumiAdmin-Access] snapshot refreshed: version '%s', bans/whitelist/profiles/risk_ips updated.", version);
}

bool InsertMetadata(const char[] key, const char[] value)
{
    char escapedKey[128];
    char escapedValue[256];
    char query[512];
    SQL_EscapeString(g_AccessSnapshotDb, key, escapedKey, sizeof(escapedKey));
    SQL_EscapeString(g_AccessSnapshotDb, value, escapedValue, sizeof(escapedValue));
    Format(query, sizeof(query), "INSERT INTO metadata (key, value) VALUES ('%s', '%s')", escapedKey, escapedValue);
    if (!SQL_FastQuery(g_AccessSnapshotDb, query))
    {
        LogError("[LumiAdmin-Access] access snapshot: metadata insert failed for key '%s'", key);
        return false;
    }
    return true;
}

bool SaveSnapshotRiskIps(JSONArray riskIps)
{
    if (riskIps == null)
    {
        return true;
    }

    char query[256];
    for (int i = 0; i < riskIps.Length; i++)
    {
        char ip[64];
        if (!riskIps.GetString(i, ip, sizeof(ip)))
        {
            continue;
        }
        if (ip[0] == '\0')
        {
            continue;
        }

        char escapedIp[128];
        SQL_EscapeString(g_AccessSnapshotDb, ip, escapedIp, sizeof(escapedIp));
        Format(query, sizeof(query), "INSERT OR IGNORE INTO risk_ips (ip) VALUES ('%s')", escapedIp);
        if (!SQL_FastQuery(g_AccessSnapshotDb, query))
        {
            LogError("[LumiAdmin-Access] access snapshot: risk_ips insert failed at index %d", i);
            return false;
        }
    }
    return true;
}

bool SaveSnapshotBans(JSONArray bans)
{
    if (bans == null)
    {
        return true;
    }

    for (int i = 0; i < bans.Length; i++)
    {
        JSONObject ban = view_as<JSONObject>(bans.Get(i));
        if (ban == null)
        {
            continue;
        }

        char steamId[64];
        char ipAddress[64];
        char reason[256];
        char expiresAtUnix[32];
        ban.GetString("steam_id", steamId, sizeof(steamId));
        ban.GetString("ip_address", ipAddress, sizeof(ipAddress));
        ban.GetString("reason", reason, sizeof(reason));
        IntToString(LumiJsonGetInt(ban, "expires_at_unix"), expiresAtUnix, sizeof(expiresAtUnix));

        char escapedSteamId[128];
        char escapedIpAddress[128];
        char escapedReason[512];
        SQL_EscapeString(g_AccessSnapshotDb, steamId, escapedSteamId, sizeof(escapedSteamId));
        SQL_EscapeString(g_AccessSnapshotDb, ipAddress, escapedIpAddress, sizeof(escapedIpAddress));
        SQL_EscapeString(g_AccessSnapshotDb, reason, escapedReason, sizeof(escapedReason));

        char query[1024];
        Format(query, sizeof(query), "INSERT OR IGNORE INTO bans (steam_id, ip_address, reason, expires_at) VALUES ('%s', '%s', '%s', %d)", escapedSteamId, escapedIpAddress, escapedReason, StringToInt(expiresAtUnix));
        if (!SQL_FastQuery(g_AccessSnapshotDb, query))
        {
            LogError("[LumiAdmin-Access] access snapshot: bans insert failed at index %d", i);
            delete ban;
            return false;
        }
        delete ban;
    }

    return true;
}

bool SaveSnapshotWhitelist(JSONArray whitelist)
{
    if (whitelist == null)
    {
        return true;
    }

    for (int i = 0; i < whitelist.Length; i++)
    {
        JSONObject entry = view_as<JSONObject>(whitelist.Get(i));
        if (entry == null)
        {
            continue;
        }

        char steamId[64];
        entry.GetString("steam_id64", steamId, sizeof(steamId));
        char escapedSteamId[128];
        char query[256];
        SQL_EscapeString(g_AccessSnapshotDb, steamId, escapedSteamId, sizeof(escapedSteamId));
        Format(query, sizeof(query), "INSERT OR REPLACE INTO whitelist (steam_id) VALUES ('%s')", escapedSteamId);
        if (!SQL_FastQuery(g_AccessSnapshotDb, query))
        {
            LogError("[LumiAdmin-Access] access snapshot: whitelist insert failed at index %d", i);
            delete entry;
            return false;
        }
        delete entry;
    }

    return true;
}

bool SaveSnapshotAccessProfiles(JSONArray profiles)
{
    if (profiles == null)
    {
        return true;
    }

    for (int i = 0; i < profiles.Length; i++)
    {
        JSONObject profile = view_as<JSONObject>(profiles.Get(i));
        if (profile == null)
        {
            continue;
        }

        char steamId[64];
        profile.GetString("steam_id64", steamId, sizeof(steamId));
        char escapedSteamId[128];
        char query[512];
        SQL_EscapeString(g_AccessSnapshotDb, steamId, escapedSteamId, sizeof(escapedSteamId));
        Format(query, sizeof(query),
            "INSERT OR REPLACE INTO access_profiles (steam_id, rating, steam_level, expires_at) VALUES ('%s', %d, %d, %d)",
            escapedSteamId,
            LumiJsonGetInt(profile, "rating"),
            LumiJsonGetInt(profile, "steam_level"),
            LumiJsonGetInt(profile, "expires_at_unix"));
        if (!SQL_FastQuery(g_AccessSnapshotDb, query))
        {
            LogError("[LumiAdmin-Access] access snapshot: access_profiles insert failed at index %d", i);
            delete profile;
            return false;
        }
        delete profile;
    }

    return true;
}

// =====[ 可观测性 ]=====

void LogAccessEvent(const char[] kind, const char[] detail)
{
    char entry[192];
    Format(entry, sizeof(entry), "%d %s: %s", GetTime(), kind, detail);

    g_AccessRecentEvents[g_AccessRecentEventHead] = entry;
    g_AccessRecentEventHead = (g_AccessRecentEventHead + 1) % ACCESS_STATUS_RECENT_MAX;
    if (g_AccessRecentEventCount < ACCESS_STATUS_RECENT_MAX)
    {
        g_AccessRecentEventCount++;
    }
}

/**
 * 上报本地裁决结果到 LumiAdmin（异步，不阻塞进服）。
 *
 * LumiAuth 本地自治后进服不再调用 /access/check，进服监控改由插件主动上报：
 * POST /api/plugin/access/record，携带 report_token + port + 裁决结果。
 * 网络失败仅记录日志，绝不影响进服主链路。
 */
void ReportAccessDecision(int client, const char[] steamId, const char[] ipAddress, bool allowed, const char[] accessMethod, const char[] failureCode, const char[] rejectReason)
{
    if (steamId[0] == '\0')
    {
        return;
    }

    char url[512];
    char token[256];
    if (!ResolvePluginApiConfig(url, sizeof(url), "/access/record", token, sizeof(token)))
    {
        return;
    }

    int currentPort = 0;
    GetCurrentServerPort(currentPort);

    char playerName[128];
    playerName[0] = '\0';
    if (client > 0 && IsClientConnected(client))
    {
        GetClientName(client, playerName, sizeof(playerName));
    }

    JSONObject payload = new JSONObject();
    payload.SetString("report_token", token);
    payload.SetInt("port", currentPort);
    payload.SetString("steam_id64", steamId);
    if (ipAddress[0] != '\0')
    {
        payload.SetString("ip_address", ipAddress);
    }
    if (playerName[0] != '\0')
    {
        payload.SetString("player", playerName);
    }
    payload.SetBool("allowed", allowed);
    payload.SetString("access_method", accessMethod);
    if (failureCode[0] != '\0')
    {
        payload.SetString("failure_code", failureCode);
    }
    if (rejectReason[0] != '\0')
    {
        payload.SetString("reject_reason", rejectReason);
    }

    int rating = 0;
    int steamLevel = 0;
    if (GetOfflineProfileValues(steamId, rating, steamLevel))
    {
        payload.SetInt("rating", rating);
        payload.SetInt("steam_level", steamLevel);
    }

    PostJsonObject(url, payload, OnAccessRecordResponse, 0, g_AccessCheckTimeout.FloatValue);
    delete payload;
}

public void OnAccessRecordResponse(HTTPResponse response, any value, const char[] error)
{
    LogHttpPostFailure("access record report", response, error);
}

/**
 * 读取本地快照中的玩家 rating / steam_level（用于进服监控展示）。
 * 无记录时返回 false。
 */
bool GetOfflineProfileValues(const char[] steamId, int &rating, int &steamLevel)
{
    if (g_AccessSnapshotDb == null || steamId[0] == '\0')
    {
        return false;
    }

    char escapedSteamId[128];
    char query[256];
    SQL_EscapeString(g_AccessSnapshotDb, steamId, escapedSteamId, sizeof(escapedSteamId));
    Format(query, sizeof(query), "SELECT rating, steam_level FROM access_profiles WHERE steam_id = '%s' LIMIT 1", escapedSteamId);

    DBResultSet results = SQL_Query(g_AccessSnapshotDb, query);
    if (results == null)
    {
        return false;
    }

    bool found = false;
    if (SQL_FetchRow(results))
    {
        rating = SQL_FetchInt(results, 0);
        steamLevel = SQL_FetchInt(results, 1);
        found = true;
    }
    delete results;
    return found;
}

bool ShouldLogAccessConfigError()
{
    int now = GetTime();
    if (now - g_AccessLastConfigErrorLog < ACCESS_CONFIG_ERROR_LOG_INTERVAL)
    {
        return false;
    }
    g_AccessLastConfigErrorLog = now;
    return true;
}

// =====[ 自检命令 sm_lumi_access_status ]=====

Action CommandAccessStatus(int admin, int args)
{
    char expiresAtUnixText[32];
    int snapshotAge = -1;
    if (GetMetadataValue("expires_at_unix", expiresAtUnixText, sizeof(expiresAtUnixText)))
    {
        int expiresAtUnix = StringToInt(expiresAtUnixText);
        if (expiresAtUnix > 0)
        {
            snapshotAge = GetTime() - expiresAtUnix;
            if (snapshotAge < 0)
            {
                snapshotAge = 0;
            }
        }
    }

    ReplyToCommand(admin, "[LumiAdmin-Access] ---- status ----");
    ReplyToCommand(admin, "[LumiAdmin-Access] mode: local sync decide (missing-grace %.0fs), events reconcile",
        (g_AccessMissingGrace == null) ? 25.0 : g_AccessMissingGrace.FloatValue);
    ReplyToCommand(admin, "[LumiAdmin-Access] snapshot db: %s", g_AccessSnapshotDb == null ? "UNAVAILABLE" : "ok");
    ReplyToCommand(admin, "[LumiAdmin-Access] snapshot age: %ds (stale snapshots still usable as fallback)", snapshotAge < 0 ? -1 : snapshotAge);
    ReplyToCommand(admin, "[LumiAdmin-Access] snapshot version: '%s' last ok refresh: %ds ago",
        g_AccessSnapshotEtag,
        g_AccessSnapshotLastRefreshOk > 0 ? GetTime() - g_AccessSnapshotLastRefreshOk : -1);
    ReplyToCommand(admin, "[LumiAdmin-Access] snapshot refresh backoff step: %d", g_AccessSnapshotBackoffStep);

    ReplyToCommand(admin, "[LumiAdmin-Access] fail_open: %d check timeout: %.1fs",
        ShouldFailOpenAccessCheck() ? 1 : 0,
        g_AccessCheckTimeout.FloatValue);
    ReplyToCommand(admin, "[LumiAdmin-Access] auth events: last_applied=%d connected=%d",
        g_AuthLastAppliedVersion,
        g_AuthConnected ? 1 : 0);

    // 本地快照表内容诊断（定位「规则缺失 → 全部 fail_open」类问题）
    if (g_AccessSnapshotDb != null)
    {
        ReplyToCommand(admin, "[LumiAdmin-Access] ---- local snapshot tables ----");
        ReplyToCommand(admin, "[LumiAdmin-Access] server_rules row: %s", LocalServerRulesPresent() ? "present" : "MISSING");

        char ruleText[128];
        ruleText[0] = '\0';
        DBResultSet ruleSet = SQL_Query(g_AccessSnapshotDb, "SELECT whitelist_mode_enabled, access_restriction_enabled, min_rating, min_steam_level, risk_block_enabled FROM server_rules WHERE id = 1");
        if (ruleSet != null)
        {
            if (SQL_FetchRow(ruleSet))
            {
                Format(ruleText, sizeof(ruleText), "whitelist=%d restriction=%d min_rating=%d min_level=%d risk_block=%d",
                    SQL_FetchInt(ruleSet, 0), SQL_FetchInt(ruleSet, 1), SQL_FetchInt(ruleSet, 2), SQL_FetchInt(ruleSet, 3),
                    ruleSet.FieldCount > 4 ? SQL_FetchInt(ruleSet, 4) : 0);
            }
            delete ruleSet;
        }
        ReplyToCommand(admin, "[LumiAdmin-Access] rules detail: %s", ruleText[0] != '\0' ? ruleText : "(none)");

        DBResultSet wlCount = SQL_Query(g_AccessSnapshotDb, "SELECT COUNT(*) FROM whitelist");
        int whitelistTotal = (wlCount != null && SQL_FetchRow(wlCount)) ? SQL_FetchInt(wlCount, 0) : -1;
        if (wlCount != null)
        {
            delete wlCount;
        }
        DBResultSet banCount = SQL_Query(g_AccessSnapshotDb, "SELECT COUNT(*) FROM bans");
        int banTotal = (banCount != null && SQL_FetchRow(banCount)) ? SQL_FetchInt(banCount, 0) : -1;
        if (banCount != null)
        {
            delete banCount;
        }
        DBResultSet profileCount = SQL_Query(g_AccessSnapshotDb, "SELECT COUNT(*) FROM access_profiles");
        int profileTotal = (profileCount != null && SQL_FetchRow(profileCount)) ? SQL_FetchInt(profileCount, 0) : -1;
        if (profileCount != null)
        {
            delete profileCount;
        }
        DBResultSet riskIpCount = SQL_Query(g_AccessSnapshotDb, "SELECT COUNT(*) FROM risk_ips");
        int riskIpTotal = (riskIpCount != null && SQL_FetchRow(riskIpCount)) ? SQL_FetchInt(riskIpCount, 0) : -1;
        if (riskIpCount != null)
        {
            delete riskIpCount;
        }
        ReplyToCommand(admin, "[LumiAdmin-Access] rows: whitelist=%d bans=%d access_profiles=%d risk_ips=%d",
            whitelistTotal, banTotal, profileTotal, riskIpTotal);
    }

    if (g_AccessRecentEventCount > 0)
    {
        ReplyToCommand(admin, "[LumiAdmin-Access] ---- recent events (oldest first) ----");
        for (int i = 0; i < g_AccessRecentEventCount; i++)
        {
            int idx = (g_AccessRecentEventHead - g_AccessRecentEventCount + i + ACCESS_STATUS_RECENT_MAX * 2) % ACCESS_STATUS_RECENT_MAX;
            ReplyToCommand(admin, "[LumiAdmin-Access] %s", g_AccessRecentEvents[idx]);
        }
    }
    return Plugin_Handled;
}