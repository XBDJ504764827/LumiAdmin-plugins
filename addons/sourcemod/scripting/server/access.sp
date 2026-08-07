/**
 * 进服权限检查 + 本地 SQLite 快照（离线降级）。
 */

// =====[ 权限检查 ]=====

public void OnClientAuthorized(int client, const char[] auth)
{
    if (IsFakeClient(client) || !IsClientConnected(client))
    {
        return;
    }

    // 准入接口已包含封禁检查，无需单独调用封禁校验
    SubmitAccessCheck(client);
}

void SubmitAccessCheck(int client)
{
    if (client <= 0 || client > MaxClients || !IsClientConnected(client) || IsFakeClient(client))
    {
        return;
    }

    char token[256];
    char url[512];
    char steamId64[64];
    char ipAddress[64];
    char playerName[128];
    if (!ResolvePluginApiConfig(url, sizeof(url), "/access/check", token, sizeof(token)))
    {
        return;
    }

    if (!GetClientAuthId(client, AuthId_SteamID64, steamId64, sizeof(steamId64), true))
    {
        return;
    }

    GetClientIP(client, ipAddress, sizeof(ipAddress), true);
    GetClientName(client, playerName, sizeof(playerName));
    int currentPort = 0;
    if (!GetCurrentServerPort(currentPort))
    {
        return;
    }

    JSONObject payload = BuildPluginAccessCheckPayload(token, currentPort, steamId64, ipAddress, playerName);
    int userId = GetClientUserId(client);
    PostJsonObject(url, payload, OnAccessCheckResponse, userId);
    delete payload;
}

JSONObject BuildPluginAccessCheckPayload(const char[] token, int port, const char[] steamId64, const char[] ipAddress, const char[] player)
{
    JSONObject payload = new JSONObject();
    payload.SetString("report_token", token);
    payload.SetInt("port", port);
    payload.SetInt("server_port", port);
    payload.SetString("steam_id64", steamId64);
    payload.SetString("ip_address", ipAddress);
    payload.SetString("player", player);
    return payload;
}

public void OnAccessCheckResponse(HTTPResponse response, any value, const char[] error)
{
    if (error[0] != '\0' || response.Status < HTTPStatus_OK || response.Status >= HTTPStatus_MultipleChoices)
    {
        // 在线检查失败，使用本地快照降级
        OfflineAccessCheck(value);
        return;
    }

    int client = GetClientOfUserId(value);
    if (client <= 0 || !IsClientConnected(client))
    {
        return;
    }

    JSONObject data = view_as<JSONObject>(response.Data);
    if (data == null)
    {
        return;
    }

    JSON rawResult = data.Get("result");
    if (rawResult == null)
    {
        delete data;
        return;
    }

    JSONObject result = view_as<JSONObject>(rawResult);
    if (result == null)
    {
        delete data;
        return;
    }

    bool allowed = result.GetBool("allowed");
    if (!allowed)
    {
        char message[256];
        char failureCode[64];
        char accessMethod[64];
        result.GetString("message", message, sizeof(message));
        result.GetString("failure_code", failureCode, sizeof(failureCode));
        result.GetString("access_method", accessMethod, sizeof(accessMethod));
        if (StrEqual(failureCode, "banned") || StrEqual(failureCode, "linked_ip_banned") || StrEqual(accessMethod, "banned"))
        {
            MarkClientDisconnect(client, SESSION_REASON_BANNED_KICKED, message);
        }
        else
        {
            MarkClientDisconnect(client, SESSION_REASON_ACCESS_REJECTED, message);
        }
        KickClient(client, "%s", message);
    }

    delete result;
    delete data;
}

// =====[ 本地快照降级 ]=====

void OfflineAccessCheck(any userId)
{
    int client = GetClientOfUserId(userId);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    if (g_AccessSnapshotDb == null || !IsAccessSnapshotUsable())
    {
        if (ShouldFailOpenAccessCheck())
        {
            DebugLog("Access check fallback allowed userId %d because local snapshot is unavailable.", userId);
            return;
        }
        MarkClientDisconnect(client, SESSION_REASON_ACCESS_REJECTED, "访问控制服务暂时不可用。");
        KickClient(client, "%T", "Access Service Unavailable", client);
        return;
    }

    char steamId[64];
    char ipAddress[64];
    GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId), true);
    GetClientIP(client, ipAddress, sizeof(ipAddress), true);

    char reason[256];
    if (FindOfflineBan(steamId, ipAddress, reason, sizeof(reason)))
    {
        MarkClientDisconnect(client, SESSION_REASON_BANNED_KICKED, reason);
        KickClient(client, "%T", "Kick Banned Message", client, reason);
        return;
    }

    if (!OfflineRulesAllowClient(steamId))
    {
        if (ShouldFailOpenAccessCheck())
        {
            DebugLog("Access check fallback allowed userId %d because offline whitelist/access rules could not confirm eligibility.", userId);
            return;
        }
        MarkClientDisconnect(client, SESSION_REASON_ACCESS_REJECTED, "本地访问快照未确认玩家满足进入条件。");
        KickClient(client, "%T", "Access Whitelist Unconfirmed", client);
        return;
    }
}

bool ShouldFailOpenAccessCheck()
{
    return g_AccessFailOpen == null || g_AccessFailOpen.BoolValue;
}

bool IsAccessSnapshotUsable()
{
    char expiresAtUnixText[32];
    if (!GetMetadataValue("expires_at_unix", expiresAtUnixText, sizeof(expiresAtUnixText)))
    {
        return false;
    }

    int expiresAtUnix = StringToInt(expiresAtUnixText);
    if (expiresAtUnix <= 0)
    {
        return false;
    }

    return GetTime() < expiresAtUnix;
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
        return;
    }

    JSONObject payload = new JSONObject();
    payload.SetString("report_token", token);
    payload.SetInt("port", currentPort);

    HTTPRequest request = new HTTPRequest(url);
    request.Timeout = 10;
    request.Post(payload, OnAccessSnapshotResponse);
    delete payload;
}

public void OnAccessSnapshotResponse(HTTPResponse response, any value, const char[] error)
{
    if (error[0] != '\0')
    {
        LogError("[LumiAdmin Server] access snapshot refresh failed: %s", error);
        return;
    }

    if (response.Status != HTTPStatus_OK)
    {
        LogError("[LumiAdmin Server] access snapshot returned HTTP status %d.", response.Status);
        return;
    }

    JSONObject root = view_as<JSONObject>(response.Data);
    if (root == null)
    {
        LogError("[LumiAdmin Server] access snapshot response was empty.");
        return;
    }

    JSONObject item = view_as<JSONObject>(root.Get("item"));
    if (item == null)
    {
        LogError("[LumiAdmin Server] access snapshot response missed item.");
        delete root;
        return;
    }

    SaveAccessSnapshot(item);
    delete item;
    delete root;
}

void InitAccessSnapshotDb()
{
    char error[256];
    g_AccessSnapshotDb = SQLite_UseDatabase(ACCESS_SNAPSHOT_DB, error, sizeof(error));
    if (g_AccessSnapshotDb == null)
    {
        LogError("[LumiAdmin Server] access snapshot SQLite open failed: %s", error);
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
}

void SaveAccessSnapshot(JSONObject item)
{
    if (g_AccessSnapshotDb == null)
    {
        return;
    }

    if (!SQL_FastQuery(g_AccessSnapshotDb, "BEGIN IMMEDIATE TRANSACTION"))
    {
        LogError("[LumiAdmin Server] access snapshot: failed to BEGIN transaction.");
        return;
    }

    if (!SQL_FastQuery(g_AccessSnapshotDb, "DELETE FROM metadata")
        || !SQL_FastQuery(g_AccessSnapshotDb, "DELETE FROM server_rules")
        || !SQL_FastQuery(g_AccessSnapshotDb, "DELETE FROM bans")
        || !SQL_FastQuery(g_AccessSnapshotDb, "DELETE FROM whitelist")
        || !SQL_FastQuery(g_AccessSnapshotDb, "DELETE FROM access_profiles"))
    {
        LogError("[LumiAdmin Server] access snapshot: cleanup failed, ROLLBACK.");
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
        LogError("[LumiAdmin Server] access snapshot: metadata insert failed, ROLLBACK.");
        SQL_FastQuery(g_AccessSnapshotDb, "ROLLBACK");
        return;
    }

    char generatedAtUnix[32];
    char expiresAtUnix[32];
    IntToString(item.GetInt("generated_at_unix"), generatedAtUnix, sizeof(generatedAtUnix));
    IntToString(item.GetInt("expires_at_unix"), expiresAtUnix, sizeof(expiresAtUnix));
    if (!InsertMetadata("generated_at_unix", generatedAtUnix)
        || !InsertMetadata("expires_at_unix", expiresAtUnix))
    {
        LogError("[LumiAdmin Server] access snapshot: metadata unix insert failed, ROLLBACK.");
        SQL_FastQuery(g_AccessSnapshotDb, "ROLLBACK");
        return;
    }

    JSONObject server = view_as<JSONObject>(item.Get("server"));
    if (server != null)
    {
        char query[512];
        Format(query, sizeof(query),
            "INSERT INTO server_rules (id, whitelist_mode_enabled, access_restriction_enabled, min_rating, min_steam_level) VALUES (1, %d, %d, %d, %d)",
            server.GetBool("whitelist_mode_enabled") ? 1 : 0,
            server.GetBool("access_restriction_enabled") ? 1 : 0,
            server.GetInt("min_rating"),
            server.GetInt("min_steam_level"));
        if (!SQL_FastQuery(g_AccessSnapshotDb, query))
        {
            LogError("[LumiAdmin Server] access snapshot: server_rules insert failed, ROLLBACK.");
            SQL_FastQuery(g_AccessSnapshotDb, "ROLLBACK");
            delete server;
            return;
        }
        delete server;
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
        LogError("[LumiAdmin Server] access snapshot: COMMIT failed, ROLLBACK.");
        SQL_FastQuery(g_AccessSnapshotDb, "ROLLBACK");
    }
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
        LogError("[LumiAdmin Server] access snapshot: metadata insert failed for key '%s'", key);
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
        IntToString(ban.GetInt("expires_at_unix"), expiresAtUnix, sizeof(expiresAtUnix));

        char escapedSteamId[128];
        char escapedIpAddress[128];
        char escapedReason[512];
        SQL_EscapeString(g_AccessSnapshotDb, steamId, escapedSteamId, sizeof(escapedSteamId));
        SQL_EscapeString(g_AccessSnapshotDb, ipAddress, escapedIpAddress, sizeof(escapedIpAddress));
        SQL_EscapeString(g_AccessSnapshotDb, reason, escapedReason, sizeof(escapedReason));

        char query[1024];
        Format(query, sizeof(query), "INSERT INTO bans (steam_id, ip_address, reason, expires_at) VALUES ('%s', '%s', '%s', %d)", escapedSteamId, escapedIpAddress, escapedReason, StringToInt(expiresAtUnix));
        if (!SQL_FastQuery(g_AccessSnapshotDb, query))
        {
            LogError("[LumiAdmin Server] access snapshot: bans insert failed at index %d", i);
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
            LogError("[LumiAdmin Server] access snapshot: whitelist insert failed at index %d", i);
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
            profile.GetInt("rating"),
            profile.GetInt("steam_level"),
            profile.GetInt("expires_at_unix"));
        if (!SQL_FastQuery(g_AccessSnapshotDb, query))
        {
            LogError("[LumiAdmin Server] access snapshot: access_profiles insert failed at index %d", i);
            delete profile;
            return false;
        }
        delete profile;
    }

    return true;
}
