/**
 * 进服权限检查：本地同步裁决（LumiAuth Data Plane），grace=0。
 *
 * - OnClientAuthorized 内同步读本地 SQLite（含内存规则），命中封禁/白名单缺失/
 *   门槛不满足即立即 Kick，不等待任何 HTTP；
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

    // 本地同步裁决：零网络等待，grace=0（快照说不在白名单即直接阻止进入）。
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

// =====[ 在线复核层（已退役为主链路，仅后台对账保留；进服用 LocalAccessDecide）]=====

// 在线复核层已退役：历史入口/回调/载荷构造全部删除。
// 进服只走 LocalAccessDecide；后台对账走 auth_sync 事件 + 补偿快照。

// =====[ 本地快照兜底 ]=====

/**
 * 本地裁决：进服主链路（同步，零网络等待，grace=0）。
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

    if (!OfflineRulesAllowClient(steamId))
    {
        if (!ShouldFailOpenAccessCheck())
        {
            LogAccessEvent("kick", "rules not confirmed, fail_closed (fallback)");
            ReportAccessDecision(client, steamId, ipAddress, false, "whitelist_rejected", "rules_unconfirmed", "本地访问快照未确认玩家满足进入条件。");
            MarkClientDisconnect(client, SESSION_REASON_ACCESS_REJECTED, "本地访问快照未确认玩家满足进入条件。");
            KickClient(client, "%T", "Access Whitelist Unconfirmed", client);
            return;
        }
        LogAccessEvent("allow", "rules unconfirmed, fail_open (fallback)");
        // 规则未确认说明本地 server_rules 缺失/异常：以无限制上报，但触发一次全量快照补写规则。
        ReportAccessDecision(client, steamId, ipAddress, true, "unrestricted", "", "");
        RequestAccessSnapshotRefresh(true);
        return;
    }

    LogAccessEvent("allow", "local snapshot fallback");
    char allowMethod[32];
    LocalAllowAccessMethod(allowMethod, sizeof(allowMethod));
    ReportAccessDecision(client, steamId, ipAddress, true, allowMethod, "", "");
}

/**
 * 本地放行时推断进服方式：白名单模式 → whitelist；进入限制 → restriction；
 * 均未开启 → unrestricted。用于进服监控展示。
 */
void LocalAllowAccessMethod(char[] method, int maxLen)
{
    strcopy(method, maxLen, "unrestricted");
    if (SnapshotHasRule("whitelist_mode_enabled"))
    {
        strcopy(method, maxLen, "whitelist");
    }
    else if (SnapshotHasRule("access_restriction_enabled"))
    {
        strcopy(method, maxLen, "restriction");
    }
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

bool OfflineRulesAllowClient(const char[] steamId)
{
    if (g_AccessSnapshotDb == null)
    {
        return false;
    }

    DBResultSet results = SQL_Query(g_AccessSnapshotDb, "SELECT whitelist_mode_enabled, access_restriction_enabled, min_rating, min_steam_level FROM server_rules WHERE id = 1");
    if (results == null)
    {
        return false;
    }

    bool allowed = false;
    if (SQL_FetchRow(results))
    {
        bool whitelistModeEnabled = SQL_FetchInt(results, 0) != 0;
        bool accessRestrictionEnabled = SQL_FetchInt(results, 1) != 0;
        int minRating = SQL_FetchInt(results, 2);
        int minSteamLevel = SQL_FetchInt(results, 3);

        if (whitelistModeEnabled)
        {
            allowed = OfflineWhitelistContains(steamId);
        }
        else
        {
            allowed = true;
        }

        if (allowed && accessRestrictionEnabled)
        {
            allowed = OfflineProfileMeetsRequirement(steamId, minRating, minSteamLevel);
        }
    }
    delete results;
    return allowed;
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

bool OfflineProfileMeetsRequirement(const char[] steamId, int minRating, int minSteamLevel)
{
    if (minRating <= 0 && minSteamLevel <= 0)
    {
        return true;
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

    bool meets = false;
    if (SQL_FetchRow(results))
    {
        int rating = SQL_FetchInt(results, 0);
        int steamLevel = SQL_FetchInt(results, 1);
        meets = rating >= minRating && steamLevel >= minSteamLevel;
    }
    delete results;
    return meets;
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

    SaveAccessSnapshot(item);
    delete item;
    delete root;
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
    SQL_FastQuery(g_AccessSnapshotDb, "CREATE TABLE IF NOT EXISTS server_rules (id INTEGER PRIMARY KEY CHECK (id = 1), whitelist_mode_enabled INTEGER NOT NULL, access_restriction_enabled INTEGER NOT NULL, min_rating INTEGER NOT NULL, min_steam_level INTEGER NOT NULL)");
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

        if (!OfflineRulesAllowClient(steamId))
        {
            if (!ShouldFailOpenAccessCheck())
            {
                LogAccessEvent("kick", "reconcile: rules unconfirmed");
                MarkClientDisconnect(client, SESSION_REASON_ACCESS_REJECTED, "本地访问快照未确认玩家满足进入条件。");
                KickClient(client, "%T", "Access Whitelist Unconfirmed", client);
            }
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
        || !SQL_FastQuery(g_AccessSnapshotDb, "DELETE FROM access_profiles"))
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
            "INSERT INTO server_rules (id, whitelist_mode_enabled, access_restriction_enabled, min_rating, min_steam_level) VALUES (1, %d, %d, %d, %d)",
            LumiJsonGetBool(server, "whitelist_mode_enabled") ? 1 : 0,
            LumiJsonGetBool(server, "access_restriction_enabled") ? 1 : 0,
            LumiJsonGetInt(server, "min_rating"),
            LumiJsonGetInt(server, "min_steam_level"));
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

    if (!SQL_FastQuery(g_AccessSnapshotDb, "COMMIT"))
    {
        LogError("[LumiAdmin-Access] access snapshot: COMMIT failed, ROLLBACK.");
        SQL_FastQuery(g_AccessSnapshotDb, "ROLLBACK");
        return;
    }

    g_AccessSnapshotBackoffStep = 0;
    g_AccessSnapshotLastRefreshOk = GetTime();
    strcopy(g_AccessSnapshotEtag, sizeof(g_AccessSnapshotEtag), version);
    LogMessage("[LumiAdmin-Access] snapshot refreshed: version '%s', bans/whitelist/profiles updated.", version);
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
    ReplyToCommand(admin, "[LumiAdmin-Access] mode: local sync decide (grace=0), events reconcile");
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