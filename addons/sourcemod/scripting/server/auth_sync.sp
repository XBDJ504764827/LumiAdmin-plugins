/**
 * LumiAuth 事件同步（Data Plane）：Long-Poll + ACK + Version + Snapshot 补偿。
 *
 * - 主链路：POST /api/plugin/auth/events/poll（后端 hold≤20s，插件 timeout 25s+余量）；
 * - 写库成功（含内存规则生效）后再 POST /api/plugin/auth/ack；
 * - 版本跳跃（snapshot_required 或差值>500）走 POST /api/plugin/auth/snapshot 全量替换；
 * - 断线指数退避 1s→2s→5s→10s→30s→60s；补偿 poll（bans/access snapshot 30s）保留为兜底。
 * - 日志不输出 report_token。
 */

void AuthSync_Start()
{
    AuthSync_Stop();
    float interval = g_AuthEventsInterval != null ? g_AuthEventsInterval.FloatValue : 25.0;
    if (interval < 5.0)
    {
        interval = 5.0;
    }
    g_AuthEventsTimer = CreateTimer(interval, Timer_AuthEventsPoll, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    // 启动即拉一次，不等首个周期
    AuthSync_PollOnce();
}

void AuthSync_Stop()
{
    if (g_AuthEventsTimer != null)
    {
        delete g_AuthEventsTimer;
        g_AuthEventsTimer = null;
    }
}

public Action Timer_AuthEventsPoll(Handle timer)
{
    AuthSync_PollOnce();
    return Plugin_Continue;
}

void AuthSync_PollOnce()
{
    if (g_AuthEventsInFlight)
    {
        return;
    }

    char token[MAX_SERVER_TOKEN];
    char url[512];
    int currentPort = 0;
    if (!GetCurrentServerPort(currentPort))
    {
        return;
    }
    if (!ResolvePluginApiConfig(url, sizeof(url), "/auth/events/poll", token, sizeof(token)))
    {
        AuthSync_OnUnreachable("no api config");
        return;
    }

    JSONObject payload = new JSONObject();
    payload.SetString("report_token", token);
    payload.SetInt("port", currentPort);
    payload.SetInt("after_version", g_AuthLastAppliedVersion);
    payload.SetInt("wait_secs", 25);

    // 后端 hold≤20s，插件 timeout 给 30s 余量；回调在主线程执行，可安全写库
    g_AuthEventsInFlight = true;
    if (!PostJsonObject(url, payload, OnAuthEventsResponse, currentPort, 30.0))
    {
        delete payload;
        g_AuthEventsInFlight = false;
        AuthSync_OnUnreachable("post failed");
        return;
    }
    delete payload;
}

public void OnAuthEventsResponse(HTTPResponse response, any value, const char[] error)
{
    g_AuthEventsInFlight = false;

    if (error[0] != '\0' || response.Status < HTTPStatus_OK || response.Status >= HTTPStatus_MultipleChoices)
    {
        if (error[0] != '\0')
        {
            AuthSync_OnUnreachable(error);
        }
        else
        {
            char detail[64];
            Format(detail, sizeof(detail), "HTTP %d", response.Status);
            AuthSync_OnUnreachable(detail);
        }
        return;
    }

    JSONObject root = view_as<JSONObject>(response.Data);
    if (root == null)
    {
        AuthSync_OnUnreachable("empty response");
        return;
    }

    bool snapshotRequired = root.GetBool("snapshot_required");
    int latestVersion = root.GetInt("latest_version");

    if (snapshotRequired || (latestVersion - g_AuthLastAppliedVersion) > AUTH_SNAPSHOT_VERSION_GAP)
    {
        LogMessage("[LumiAuth] Snapshot required (applied=%d latest=%d).", g_AuthLastAppliedVersion, latestVersion);
        LogAccessEvent("snapshot", "required by version gap");
        delete root;
        AuthSync_OnReachable();
        AuthSync_RequestSnapshot();
        return;
    }

    JSON rawEvents = root.Get("events");
    JSONArray events = view_as<JSONArray>(rawEvents);
    if (events == null)
    {
        delete root;
        AuthSync_OnReachable();
        return;
    }

    int maxVersion = g_AuthLastAppliedVersion;
    for (int i = 0; i < events.Length; i++)
    {
        JSONObject ev = view_as<JSONObject>(events.Get(i));
        if (ev == null)
        {
            continue;
        }

        char eventId[MAX_AUTH_EVENT_ID];
        char eventType[64];
        int version = ev.GetInt("version");
        ev.GetString("event_id", eventId, sizeof(eventId));
        ev.GetString("event_type", eventType, sizeof(eventType));

        // 乱序/重复：已应用则跳过；未来版本（>last+1）触发 resync，不无脑应用
        if (version <= g_AuthLastAppliedVersion || AuthEventAlreadyApplied(eventId))
        {
            delete ev;
            continue;
        }
        if (version != g_AuthLastAppliedVersion + 1)
        {
            LogMessage("[LumiAuth] Version gap detected (applied=%d got=%d), requesting resync.", g_AuthLastAppliedVersion, version);
            delete ev;
            delete events;
            delete root;
            AuthSync_RequestSnapshot();
            return;
        }

        JSONObject payload = view_as<JSONObject>(ev.Get("payload"));
        AuthSync_ApplyEvent(eventId, version, eventType, payload);
        if (payload != null)
        {
            delete payload;
        }
        delete ev;

        if (version > maxVersion)
        {
            maxVersion = version;
        }
    }

    delete events;
    delete root;

    AuthSync_OnReachable();
    if (maxVersion > g_AuthLastAppliedVersion)
    {
        AuthSync_Ack(maxVersion);
    }
}

void AuthSync_ApplyEvent(const char[] eventId, int version, const char[] eventType, JSONObject payload)
{
    if (payload == null)
    {
        AuthMarkEventApplied(eventId, version);
        return;
    }

    char steamId[64];
    char ip[64];
    char reason[256];
    steamId[0] = '\0';
    ip[0] = '\0';
    reason[0] = '\0';
    payload.GetString("steamid64", steamId, sizeof(steamId));
    if (steamId[0] == '\0')
    {
        payload.GetString("steam_id", steamId, sizeof(steamId));
    }
    payload.GetString("ip_address", ip, sizeof(ip));
    payload.GetString("reason", reason, sizeof(reason));

    if (StrEqual(eventType, "ban.add"))
    {
        int expiresAt = 0;
        char expiresText[64];
        if (payload.GetString("expires_at", expiresText, sizeof(expiresText)) && expiresText[0] != '\0')
        {
            // 后端 RFC3339；插件侧无法解析则视为永久（由补偿 snapshot 纠正精确值）
            expiresAt = 0;
        }
        if (reason[0] == '\0')
        {
            strcopy(reason, sizeof(reason), "封禁");
        }
        if (AuthUpsertLocalBan(steamId, ip, reason, expiresAt, eventId, version))
        {
            LogMessage("[LumiAuth] Applying event %d (%s).", version, eventType);
            LogAccessEvent("event", eventType);
            AuthSync_KickIfOnline(steamId, ip, reason);
            LogMessage("[LumiAuth] Applied event %d.", version);
        }
    }
    else if (StrEqual(eventType, "ban.remove"))
    {
        if (AuthRemoveLocalBan(steamId, eventId, version))
        {
            LogMessage("[LumiAuth] Applying event %d (%s).", version, eventType);
            LogAccessEvent("event", eventType);
            LogMessage("[LumiAuth] Applied event %d.", version);
        }
    }
    else if (StrEqual(eventType, "whitelist.add"))
    {
        if (AuthUpsertWhitelist(steamId, eventId, version))
        {
            LogMessage("[LumiAuth] Applying event %d (%s).", version, eventType);
            LogAccessEvent("event", eventType);
            LogMessage("[LumiAuth] Applied event %d.", version);
        }
    }
    else if (StrEqual(eventType, "whitelist.remove"))
    {
        if (AuthRemoveWhitelist(steamId, eventId, version))
        {
            LogMessage("[LumiAuth] Applying event %d (%s).", version, eventType);
            LogAccessEvent("event", eventType);
            LogMessage("[LumiAuth] Applied event %d.", version);
        }
    }
    else if (StrEqual(eventType, "server.config.update"))
    {
        // 配置变更不直接改 server_rules（快照 30s 内会带回精确值），仅推进版本 + 触发一次快照刷新
        AuthMarkEventApplied(eventId, version);
        LogMessage("[LumiAuth] Applying event %d (%s).", version, eventType);
        LogAccessEvent("event", eventType);
        RequestAccessSnapshotRefresh(true);
        LogMessage("[LumiAuth] Applied event %d.", version);
    }
    else
    {
        LogMessage("[LumiAuth] Unknown event type '%s' at version %d, marking applied.", eventType, version);
        AuthMarkEventApplied(eventId, version);
    }
}

/**
 * 新 ban 落地后若玩家正在服内，立即补踢（封禁实时性）。
 */
void AuthSync_KickIfOnline(const char[] steamId, const char[] ip, const char[] reason)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
        {
            continue;
        }

        char clientSteam[64];
        char clientIp[64];
        if (!GetClientAuthId(client, AuthId_SteamID64, clientSteam, sizeof(clientSteam), true))
        {
            continue;
        }
        GetClientIP(client, clientIp, sizeof(clientIp), true);

        bool hit = false;
        if (steamId[0] != '\0' && StrEqual(clientSteam, steamId, false))
        {
            hit = true;
        }
        else if (ip[0] != '\0' && StrEqual(clientIp, ip, false))
        {
            hit = true;
        }

        if (hit)
        {
            LogAccessEvent("kick", "banned (event)");
            MarkClientDisconnect(client, SESSION_REASON_BANNED_KICKED, reason);
            KickClient(client, "%T", "Kick Banned Message", client, reason);
        }
    }
}

void AuthSync_Ack(int version)
{
    char token[MAX_SERVER_TOKEN];
    char url[512];
    int currentPort = 0;
    if (!GetCurrentServerPort(currentPort))
    {
        return;
    }
    if (!ResolvePluginApiConfig(url, sizeof(url), "/auth/ack", token, sizeof(token)))
    {
        return;
    }

    JSONObject payload = new JSONObject();
    payload.SetString("report_token", token);
    payload.SetInt("port", currentPort);
    payload.SetInt("version", version);
    PostJsonObject(url, payload, OnAuthAckResponse, version, 10.0);
    delete payload;
    LogMessage("[LumiAuth] ACK %d.", version);
}

public void OnAuthAckResponse(HTTPResponse response, any value, const char[] error)
{
    if (error[0] != '\0' || response.Status < HTTPStatus_OK || response.Status >= HTTPStatus_MultipleChoices)
    {
        LogMessage("[LumiAuth] ACK %d failed, will re-ack on next poll.", value);
        return;
    }
}

void AuthSync_RequestSnapshot()
{
    char token[MAX_SERVER_TOKEN];
    char url[512];
    int currentPort = 0;
    if (!GetCurrentServerPort(currentPort))
    {
        return;
    }
    if (!ResolvePluginApiConfig(url, sizeof(url), "/auth/snapshot", token, sizeof(token)))
    {
        AuthSync_OnUnreachable("no api config for snapshot");
        return;
    }

    JSONObject payload = new JSONObject();
    payload.SetString("report_token", token);
    payload.SetInt("port", currentPort);
    PostJsonObject(url, payload, OnAuthSnapshotResponse, 0, 15.0);
    delete payload;
    LogMessage("[LumiAuth] Snapshot required, requesting full snapshot.");
}

public void OnAuthSnapshotResponse(HTTPResponse response, any value, const char[] error)
{
    if (error[0] != '\0' || response.Status < HTTPStatus_OK || response.Status >= HTTPStatus_MultipleChoices)
    {
        if (error[0] != '\0')
        {
            AuthSync_OnUnreachable(error);
        }
        else
        {
            AuthSync_OnUnreachable("snapshot HTTP error");
        }
        return;
    }

    JSONObject root = view_as<JSONObject>(response.Data);
    if (root == null)
    {
        AuthSync_OnUnreachable("snapshot empty response");
        return;
    }

    int latestVersion = root.GetInt("latest_version");
    JSONObject item = view_as<JSONObject>(root.Get("item"));
    if (item == null)
    {
        LogError("[LumiAuth] Snapshot response missed item.");
        delete root;
        AuthSync_OnUnreachable("snapshot missed item");
        return;
    }

    // 全量替换本地授权状态（复用快照事务写库），再把版本推进到 latest
    SaveAccessSnapshot(item);
    delete item;
    delete root;

    AuthPersistAppliedVersion(latestVersion);
    AuthSync_OnReachable();
    LogMessage("[LumiAuth] Snapshot applied: %d.", latestVersion);
    LogAccessEvent("snapshot", "applied");

    // Q5：恢复后立即全服比对补踢
    AuthReconcileOnlinePlayers();
    AuthSync_Ack(latestVersion);
}

void AuthSync_OnReachable()
{
    if (!g_AuthConnected)
    {
        g_AuthConnected = true;
        LogMessage("[LumiAuth] Connected. Current version: %d.", g_AuthLastAppliedVersion);
    }
    g_AuthBackoffStep = 0;
    g_AuthLastOk = GetTime();
    if (g_AuthEventsInFlight)
    {
        g_AuthEventsInFlight = false;
    }
}

void AuthSync_OnUnreachable(const char[] cause)
{
    if (g_AuthConnected)
    {
        g_AuthConnected = false;
        LogMessage("[LumiAuth] Connection lost (%s). Reconnecting...", cause);
    }

    // 指数退避 1s→2s→5s→10s→30s→60s：缩短看门狗周期以更快重连
    static const int steps[6] = { 1, 2, 5, 10, 30, 60 };
    if (g_AuthBackoffStep < 5)
    {
        g_AuthBackoffStep++;
    }
    else
    {
        g_AuthBackoffStep = 5;
    }
    AuthSync_Stop();
    g_AuthEventsTimer = CreateTimer(float(steps[g_AuthBackoffStep]), Timer_AuthEventsPoll, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

// =====[ 快车道 ServerCmd：先落盘，再 Kick（Q3 定稿顺序）]=====

Action CommandApplyBanFastPath(int args)
{
    if (args < 5)
    {
        LogError("[LumiAuth] lumiadmin_apply_ban: bad args (%d).", args);
        return Plugin_Handled;
    }

    char banId[64];
    char versionText[16];
    char steamId[64];
    char expiresText[32];
    char reason[256];
    GetCmdArg(1, banId, sizeof(banId));
    GetCmdArg(2, versionText, sizeof(versionText));
    GetCmdArg(3, steamId, sizeof(steamId));
    GetCmdArg(4, expiresText, sizeof(expiresText));
    GetCmdArg(5, reason, sizeof(reason));

    int version = StringToInt(versionText);
    int expiresAt = StringToInt(expiresText);

    // 1) 先落本地 Ban（幂等 eventId=ban_id，避免快车道与事件双写重复）
    char eventId[128];
    Format(eventId, sizeof(eventId), "fastpath:%s", banId);
    if (!AuthUpsertLocalBan(steamId, "", reason, expiresAt, eventId, version))
    {
        LogError("[LumiAuth] lumiadmin_apply_ban: local persist failed for %s.", steamId);
        return Plugin_Handled;
    }
    if (version > 0)
    {
        AuthPersistAppliedVersion(version);
    }
    LogMessage("[LumiAuth] Fast-path ban persisted for %s (version %d).", steamId, version);

    // 2) 再 Kick 在服命中者（此时重连必被本地拦，竞态关闭）
    AuthSync_KickIfOnline(steamId, "", reason);
    if (version > 0)
    {
        AuthSync_Ack(version);
    }
    return Plugin_Handled;
}

Action CommandApplyUnbanFastPath(int args)
{
    if (args < 3)
    {
        LogError("[LumiAuth] lumiadmin_apply_unban: bad args (%d).", args);
        return Plugin_Handled;
    }

    char banId[64];
    char versionText[16];
    char steamId[64];
    GetCmdArg(1, banId, sizeof(banId));
    GetCmdArg(2, versionText, sizeof(versionText));
    GetCmdArg(3, steamId, sizeof(steamId));

    int version = StringToInt(versionText);
    char eventId[128];
    Format(eventId, sizeof(eventId), "fastpath:%s", banId);
    AuthRemoveLocalBan(steamId, eventId, version);
    if (version > 0)
    {
        AuthPersistAppliedVersion(version);
        AuthSync_Ack(version);
    }
    LogMessage("[LumiAuth] Fast-path unban applied for %s.", steamId);
    return Plugin_Handled;
}

Action CommandAuthResync(int args)
{
    g_AuthBackoffStep = 0;
    AuthSync_RequestSnapshot();
    LogMessage("[LumiAuth] Manual resync requested (snapshot).");
    return Plugin_Handled;
}

Action CommandAuthStatus(int admin, int args)
{
    ReplyToCommand(admin, "[LumiAuth] ---- status ----");
    ReplyToCommand(admin, "[LumiAuth] connected: %d last_applied_version: %d last_ok: %ds ago",
        g_AuthConnected ? 1 : 0,
        g_AuthLastAppliedVersion,
        g_AuthLastOk > 0 ? GetTime() - g_AuthLastOk : -1);
    ReplyToCommand(admin, "[LumiAuth] events_in_flight: %d backoff_step: %d",
        g_AuthEventsInFlight ? 1 : 0,
        g_AuthBackoffStep);
    return Plugin_Handled;
}
