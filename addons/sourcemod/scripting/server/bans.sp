/**
 * 封禁：轮询执行、命令拦截、菜单流程、提交/解封。
 */

// ban poll 独立于上报周期，带失败退避（L10）
void StartBanPollTimer()
{
    StopBanPollTimer();

    // 基础间隔 30s，失败按 ×2 退避（30s→60s→120s→…上限 10 分钟），成功复位
    float base = 30.0;
    if (g_BanPollBackoffStep > 0)
    {
        float backoff = base * float(1 << (g_BanPollBackoffStep > 5 ? 5 : g_BanPollBackoffStep));
        if (backoff > 600.0)
        {
            backoff = 600.0;
        }
        base = backoff;
    }
    g_BanPollTimer = CreateTimer(base, Timer_PollBans, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void StopBanPollTimer()
{
    if (g_BanPollTimer != null)
    {
        delete g_BanPollTimer;
        g_BanPollTimer = null;
    }
}

public Action Timer_PollBans(Handle timer)
{
    char token[256];
    char url[512];
    int currentPort = 0;
    if (!GetCurrentServerPort(currentPort))
    {
        return Plugin_Continue;
    }
    if (!ResolvePluginApiConfig(url, sizeof(url), "/bans/poll", token, sizeof(token)))
    {
        return Plugin_Continue;
    }

    JSONObject payload = new JSONObject();
    payload.SetString("report_token", token);
    payload.SetInt("port", currentPort);
    // 回传上次版本签名；首次请求或配置变更后为空，后端会返回完整列表
    if (g_BanPollEtag[0] != '\0')
    {
        payload.SetString("etag", g_BanPollEtag);
    }

    PostJsonObject(url, payload, OnBanPollResponse);
    delete payload;

    return Plugin_Continue;
}

public void OnBanPollResponse(HTTPResponse response, any value, const char[] error)
{
    if (error[0] != '\0')
    {
        BanPollFailed("HTTP error: %s", error);
        return;
    }

    if (response.Status != HTTPStatus_OK)
    {
        BanPollFailed("HTTP status %d", "");
        return;
    }

    g_BanPollBackoffStep = 0;

    JSONObject data = view_as<JSONObject>(response.Data);
    if (data == null)
    {
        LogError("[LumiAdmin Server] ban poll response data was null.");
        return;
    }

    // 记录服务端返回的版本签名，供下次轮询回传以启用增量检测
    if (!data.IsNull("etag"))
    {
        data.GetString("etag", g_BanPollEtag, sizeof(g_BanPollEtag));
    }

    JSON rawItems = data.Get("items");
    if (rawItems == null)
    {
        LogError("[LumiAdmin Server] ban poll response missing items.");
        delete data;
        return;
    }

    JSONArray items = view_as<JSONArray>(rawItems);
    if (items == null)
    {
        LogError("[LumiAdmin Server] ban poll items is not an array.");
        delete data;
        return;
    }

    // 预构建在线玩家索引，避免 O(N×M) 遍历
    StringMap steamMap = new StringMap();
    StringMap ipMap = new StringMap();
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
        {
            continue;
        }
        char clientSteamId64[64];
        char clientIp[64];
        if (GetClientAuthId(client, AuthId_SteamID64, clientSteamId64, sizeof(clientSteamId64), true))
        {
            steamMap.SetValue(clientSteamId64, client);
        }
        if (GetClientIP(client, clientIp, sizeof(clientIp), true))
        {
            ipMap.SetValue(clientIp, client);
        }
    }

    for (int i = 0; i < items.Length; i++)
    {
        JSON rawItem = items.Get(i);
        JSONObject item = view_as<JSONObject>(rawItem);
        KickMatchingBan(item, steamMap, ipMap);
        delete item;
    }

    delete steamMap;
    delete ipMap;
    delete items;
    delete data;
}

void BanPollFailed(const char[] cause, const char[] detail)
{
    g_BanPollBackoffStep = g_BanPollBackoffStep >= 5 ? 5 : g_BanPollBackoffStep + 1;
    if (detail[0] != '\0')
    {
        LogError("[LumiAdmin Server] ban poll failed (%s): %s. Backing off to %ds.", cause, detail, 30 * (1 << g_BanPollBackoffStep));
    }
    else
    {
        LogError("[LumiAdmin Server] ban poll failed (%s). Backing off to %ds.", cause, 30 * (1 << g_BanPollBackoffStep));
    }
}

void KickMatchingBan(JSONObject item, StringMap steamMap, StringMap ipMap)
{
    char steamId[64];
    char ipAddress[64];
    char reason[256];
    item.GetString("steam_id", steamId, sizeof(steamId));
    if (!item.IsNull("ip_address"))
    {
        item.GetString("ip_address", ipAddress, sizeof(ipAddress));
    }
    else
    {
        ipAddress[0] = '\0';
    }
    item.GetString("reason", reason, sizeof(reason));

    // 用预构建索引 O(1) 查找匹配玩家
    int matchedClient = -1;
    if (steamId[0] != '\0' && steamMap.GetValue(steamId, matchedClient))
    {
        // SteamID 匹配
    }
    else if (ipAddress[0] != '\0' && ipMap.GetValue(ipAddress, matchedClient))
    {
        // IP 匹配
    }

    if (matchedClient > 0 && IsClientInGame(matchedClient))
    {
        CompletePolledBanDetails(matchedClient);
        MarkClientDisconnect(matchedClient, SESSION_REASON_BANNED_KICKED, reason);
        KickClient(matchedClient, "%T", "Kick Banned Message", matchedClient, reason);
    }
}

void CompletePolledBanDetails(int client)
{
    char token[256];
    char url[512];
    char steamId64[64];
    char ipAddress[64];
    char playerName[128];
    if (!ResolvePluginApiConfig(url, sizeof(url), "/bans/check", token, sizeof(token)))
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
    JSONObject payload = BuildPluginBanCheckPayload(token, currentPort, steamId64, ipAddress, playerName);
    PostJsonObject(url, payload, OnBanCheckResponse);
    delete payload;
}

// =====[ 封禁提交 ]=====

bool SubmitPluginBan(int client, int target, const char[] banType, const char[] steamId, const char[] ipAddress, const char[] player, int duration, const char[] reason)
{
    char token[256];
    char banUrl[512];
    char adminName[128];
    char adminSteamid[64];
    char normalizedSteamId[64];

    if (StrEqual(banType, "steam"))
    {
        if (!NormalizePluginSteamId(steamId, normalizedSteamId, sizeof(normalizedSteamId)))
        {
            ReplyToCommand(client, "%T", "Ban Invalid SteamID", client, steamId);
            return false;
        }
    }
    else
    {
        strcopy(normalizedSteamId, sizeof(normalizedSteamId), steamId);
    }

    if (client == 0)
    {
        strcopy(adminName, sizeof(adminName), "CONSOLE");
        adminSteamid[0] = '\0';
    }
    else
    {
        GetClientName(client, adminName, sizeof(adminName));
        GetClientAuthId(client, AuthId_SteamID64, adminSteamid, sizeof(adminSteamid), true);
    }

    int currentPort = 0;
    if (!GetCurrentServerPort(currentPort))
    {
        return false;
    }

    // 先尝试在线提交
    if (ResolvePluginApiConfig(banUrl, sizeof(banUrl), "/bans", token, sizeof(token)))
    {
        JSONObject payload = BuildPluginBanPayload(token, currentPort, banType, normalizedSteamId, ipAddress, player, duration, reason, adminName);
        PostJsonObject(banUrl, payload, OnPluginBanResponse);
        delete payload;
    }
    else
    {
        // API 配置无效，尝试离线队列
        ReplyToCommand(client, "%T", "Ban API Not Configured", client);
    }

    // 同时写入离线队列作为备份（幂等键会防止重复应用）
    char targetId[64];
    if (StrEqual(banType, "steam"))
    {
        strcopy(targetId, sizeof(targetId), normalizedSteamId);
    }
    else
    {
        strcopy(targetId, sizeof(targetId), ipAddress);
    }

    // 本地兜底落盘（H6）：封禁立即写入本地快照 bans 表，在线提交失败/断网时
    // 本地行就是唯一记录，离线裁决照样拦截；在线成功后 ban poll 全量回放会覆盖对齐。
    // ban poll 回放以 (steam_id, expires_at) 幂等去重，不会重复。
    SaveLocalBanFallback(targetId, banType, reason, duration);

    if (!QueueEdgeSyncOperation("ban", targetId, banType, player, reason, adminName, adminSteamid, duration))
    {
        ReplyToCommand(client, "%T", "Ban Queue Unavailable", client);
    }

    if (target > 0 && IsClientInGame(target))
    {
        MarkClientDisconnect(target, SESSION_REASON_BANNED_KICKED, reason);
        KickClient(target, "%T", "Kick Banned Message", target, reason);
    }
    return true;
}

JSONObject BuildPluginBanPayload(const char[] token, int port, const char[] banType, const char[] steamId, const char[] ipAddress, const char[] player, int duration, const char[] reason, const char[] operatorName)
{
    JSONObject payload = new JSONObject();
    payload.SetString("report_token", token);
    payload.SetInt("port", port);
    payload.SetString("ban_type", banType);
    payload.SetString("steam_id", steamId);
    payload.SetString("ip_address", ipAddress);
    payload.SetString("player", player);
    payload.SetInt("duration_minutes", duration);
    payload.SetString("reason", reason);
    payload.SetString("operator_name", operatorName);
    return payload;
}

JSONObject BuildPluginUnbanPayload(const char[] token, int port, const char[] target, const char[] reason, const char[] operatorName, const char[] operatorSteamid)
{
    JSONObject payload = new JSONObject();
    payload.SetString("report_token", token);
    payload.SetInt("port", port);
    payload.SetString("target", target);
    payload.SetString("reason", reason);
    payload.SetString("operator_name", operatorName);
    if (operatorSteamid[0] != '\0')
    {
        payload.SetString("operator_steamid", operatorSteamid);
    }
    return payload;
}

JSONObject BuildPluginBanCheckPayload(const char[] token, int port, const char[] steamId, const char[] ipAddress, const char[] player)
{
    JSONObject payload = new JSONObject();
    payload.SetString("report_token", token);
    payload.SetInt("port", port);
    payload.SetInt("server_port", port);
    payload.SetString("steam_id", steamId);
    payload.SetString("ip_address", ipAddress);
    payload.SetString("player", player);
    return payload;
}

public void OnPluginBanResponse(HTTPResponse response, any value, const char[] error)
{
    LogHttpPostFailure("ban submit", response, error);
}

/**
 * 本地兜底封禁（H6）：写入快照库 bans 表。
 * steam 类型同时写 steam_id 列；ip 类型写 ip_address 列，两种都能被 FindOfflineBan 命中。
 */
void SaveLocalBanFallback(const char[] targetId, const char[] banType, const char[] reason, int duration)
{
    if (g_AccessSnapshotDb == null || targetId[0] == '\0')
    {
        return;
    }

    int expiresAt = duration > 0 ? GetTime() + duration * 60 : 0;

    bool isSteam = StrEqual(banType, "steam");
    char escapedSteamId[128];
    char escapedIpAddress[128];
    char escapedReason[512];
    SQL_EscapeString(g_AccessSnapshotDb, isSteam ? targetId : "", escapedSteamId, sizeof(escapedSteamId));
    SQL_EscapeString(g_AccessSnapshotDb, isSteam ? "" : targetId, escapedIpAddress, sizeof(escapedIpAddress));
    SQL_EscapeString(g_AccessSnapshotDb, reason, escapedReason, sizeof(escapedReason));

    char query[1024];
    Format(query, sizeof(query), "INSERT INTO bans (steam_id, ip_address, reason, expires_at) VALUES ('%s', '%s', '%s', %d)", escapedSteamId, escapedIpAddress, escapedReason, expiresAt);
    if (!SQL_FastQuery(g_AccessSnapshotDb, query))
    {
        LogError("[LumiAdmin Server] local ban fallback insert failed for target %s.", targetId);
        return;
    }
    LogMessage("[LumiAdmin Server] local ban fallback saved for target %s (expires %d).", targetId, expiresAt);
}

public void OnPluginUnbanResponse(HTTPResponse response, any value, const char[] error)
{
    int client = GetClientOfUserId(value);

    if (error[0] != '\0')
    {
        LogError("[LumiAdmin Server] unban failed: %s", error);
        if (client > 0)
        {
            PrintToChat(client, "%T", "Unban Failed Generic", client, error);
        }
        return;
    }

    if (response.Status >= HTTPStatus_OK && response.Status < HTTPStatus_MultipleChoices)
    {
        if (client > 0)
        {
            PrintToChat(client, "%T", "Unban Success", client);
        }
        return;
    }

    if (response.Status == HTTPStatus_BadRequest)
    {
        JSONObject data = view_as<JSONObject>(response.Data);
        if (data != null)
        {
            char message[256];
            if (data.GetString("message", message, sizeof(message)) && message[0] != '\0')
            {
                // message 已填充
            }
            else if (data.GetString("error", message, sizeof(message)) && message[0] != '\0')
            {
                // message 已填充
            }
            else
            {
                strcopy(message, sizeof(message), "解封失败，请稍后重试");
            }

            if (client > 0)
            {
                PrintToChat(client, "[LumiAdmin] %s", message);
            }
            LogError("[LumiAdmin Server] unban failed: %s", message);
            delete data;
        }
        else if (client > 0)
        {
            PrintToChat(client, "%T", "Unban Failed Retry", client);
        }
    }
    else
    {
        LogError("[LumiAdmin Server] unban returned HTTP status %d.", response.Status);
        if (client > 0)
        {
            PrintToChat(client, "%T", "Unban Failed HTTP", client, response.Status);
        }
    }
}

public void OnBanCheckResponse(HTTPResponse response, any value, const char[] error)
{
    LogHttpPostFailure("ban check", response, error);
}

// =====[ 命令 ]=====

/**
 * 封禁时长解析（M10）：逐字符校验纯数字，非数字报错而非静默按 0（永久）处理。
 * "0" 仍表示永久。
 */
bool ParseBanDuration(const char[] arg, int &minutes, int client)
{
    if (!IsDecimalString(arg) || strlen(arg) == 0 || strlen(arg) > 9)
    {
        ReplyToCommand(client, "[LumiAdmin] 封禁时长必须是纯数字分钟数（0=永久），收到: %s", arg);
        return false;
    }
    minutes = StringToInt(arg);
    if (minutes < 0)
    {
        ReplyToCommand(client, "[LumiAdmin] 封禁时长不能为负数。");
        return false;
    }
    return true;
}

public Action CommandBan(int client, int args)
{
    if (args == 0 && client > 0)
    {
        DisplayBanTargetMenu(client);
        return Plugin_Handled;
    }

    if (args < 2)
    {
        ReplyToCommand(client, "用法: sm_ban <#userid|name|steamid2> <minutes|0> [reason]");
        return Plugin_Handled;
    }

    // CS:GO 聊天命令可能将 STEAM_X:Y:Z 中的冒号拆分为独立参数。
    char targetArg[128] = "";
    char timeArg[32] = "";
    int argIdx = 1;

    // 第一步：提取目标（SteamID 或玩家名/#userid）
    {
        char part[64];
        GetCmdArg(1, part, sizeof(part));
        if (StrContains(part, "STEAM_", false) == 0)
        {
            if (!ReadSteamId2CommandTarget(1, args, targetArg, sizeof(targetArg), argIdx))
            {
                ReplyToCommand(client, "[LumiAdmin] SteamID 格式无效，应为 STEAM_X:Y:Z。");
                return Plugin_Handled;
            }
        }
        else
        {
            strcopy(targetArg, sizeof(targetArg), part);
            argIdx = 2;
        }
    }

    // 第二步：提取封禁时长
    if (argIdx > args)
    {
        ReplyToCommand(client, "用法: sm_ban <#userid|name|steamid2> <minutes|0> [reason]");
        return Plugin_Handled;
    }

    if (argIdx <= args)
    {
        GetCmdArg(argIdx, timeArg, sizeof(timeArg));
        argIdx++;
    }

    int duration;
    if (!ParseBanDuration(timeArg, duration, client))
    {
        return Plugin_Handled;
    }

    // 第三步：提取封禁理由
    char reason[256];
    AppendCommandReason(argIdx, args, reason, sizeof(reason));

    // SteamID2 格式 (STEAM_X:Y:Z)：搜索在线玩家或直接提交封禁
    if (StrContains(targetArg, "STEAM_", false) == 0)
    {
        int target = FindClientBySteamId2(targetArg);
        if (target > 0 && IsClientInGame(target))
        {
            char steamId64[64];
            char ipAddress[64];
            char player[128];
            if (!GetClientAuthId(target, AuthId_SteamID64, steamId64, sizeof(steamId64), true))
            {
                ReplyToCommand(client, "[LumiAdmin] 目标玩家尚未完成 Steam 授权，无法封禁。");
                return Plugin_Handled;
            }
            GetClientIP(target, ipAddress, sizeof(ipAddress), true);
            GetClientName(target, player, sizeof(player));
            if (SubmitPluginBan(client, target, "steam", steamId64, ipAddress, player, duration, reason))
            {
                ReplyToCommand(client, "%T", "Ban Applied", client);
            }
        }
        else
        {
            char steamId64[64];
            if (!ConvertSteam2ToSteamId64(targetArg, steamId64, sizeof(steamId64)))
            {
                ReplyToCommand(client, "[LumiAdmin] SteamID 格式无效，应为 STEAM_X:Y:Z。");
                return Plugin_Handled;
            }

            if (SubmitPluginBan(client, 0, "steam", steamId64, "", "", duration, reason))
            {
                ReplyToCommand(client, "%T", "Ban Uploaded Offline", client);
            }
        }
        return Plugin_Handled;
    }

    // RCON 通过 SteamID64 执行，网站已创建封禁记录
    bool isSteamId64 = IsSteamId64String(targetArg);
    if (client == 0 && isSteamId64)
    {
        ReplyToCommand(client, "%T", "Ban Record Created", client);
        return Plugin_Handled;
    }

    if (isSteamId64)
    {
        if (SubmitPluginBan(client, 0, "steam", targetArg, "", "", duration, reason))
        {
            ReplyToCommand(client, "%T", "Ban Uploaded Offline", client);
        }
        return Plugin_Handled;
    }

    // 通过玩家名称或 #userid 查找
    int target = FindTarget(client, targetArg, true);
    if (target <= 0)
    {
        return Plugin_Handled;
    }

    char steamId[64];
    char ipAddress[64];
    char player[128];
    if (!GetClientAuthId(target, AuthId_SteamID64, steamId, sizeof(steamId), true))
    {
        ReplyToCommand(client, "[LumiAdmin] 目标玩家尚未完成 Steam 授权，无法封禁。");
        return Plugin_Handled;
    }
    GetClientIP(target, ipAddress, sizeof(ipAddress), true);
    GetClientName(target, player, sizeof(player));

    SubmitPluginBan(client, target, "steam", steamId, ipAddress, player, duration, reason);
    return Plugin_Handled;
}

public Action CommandBanIp(int client, int args)
{
    if (args < 2)
    {
        ReplyToCommand(client, "用法: sm_banip <ip|#userid|name> <minutes|0> [reason]");
        return Plugin_Handled;
    }

    char targetArg[128];
    char timeArg[32];
    GetCmdArg(1, targetArg, sizeof(targetArg));
    GetCmdArg(2, timeArg, sizeof(timeArg));

    int duration;
    if (!ParseBanDuration(timeArg, duration, client))
    {
        return Plugin_Handled;
    }

    char reason[256];
    AppendCommandReason(3, args, reason, sizeof(reason));

    char steamId[64] = "";
    char ipAddress[64];
    char player[128] = "";
    int target = FindTarget(client, targetArg, true, false);
    if (target > 0)
    {
        if (!GetClientAuthId(target, AuthId_SteamID64, steamId, sizeof(steamId), true))
        {
            steamId[0] = '\0';
        }
        GetClientIP(target, ipAddress, sizeof(ipAddress), true);
        GetClientName(target, player, sizeof(player));
    }
    else
    {
        // 非玩家目标必须是合法 IP（L5）
        if (!IsIpAddressTarget(targetArg))
        {
            ReplyToCommand(client, "[LumiAdmin] sm_banip 目标必须是玩家或合法 IP 地址，收到: %s", targetArg);
            return Plugin_Handled;
        }
        strcopy(ipAddress, sizeof(ipAddress), targetArg);
    }

    SubmitPluginBan(client, target, "ip", steamId, ipAddress, player, duration, reason);
    return Plugin_Handled;
}

public Action CommandAddBan(int client, int args)
{
    if (args < 2)
    {
        ReplyToCommand(client, "用法: sm_addban <minutes|0> <steamid> [reason]");
        return Plugin_Handled;
    }

    char timeArg[32];
    char steamId[128];
    GetCmdArg(1, timeArg, sizeof(timeArg));

    int reasonStart = 3;
    char part[64];
    GetCmdArg(2, part, sizeof(part));
    if (StrContains(part, "STEAM_", false) == 0)
    {
        if (!ReadSteamId2CommandTarget(2, args, steamId, sizeof(steamId), reasonStart))
        {
            ReplyToCommand(client, "[LumiAdmin] SteamID 格式无效，应为 STEAM_X:Y:Z。");
            return Plugin_Handled;
        }
    }
    else
    {
        strcopy(steamId, sizeof(steamId), part);
    }

    int duration;
    if (!ParseBanDuration(timeArg, duration, client))
    {
        return Plugin_Handled;
    }

    char reason[256];
    AppendCommandReason(reasonStart, args, reason, sizeof(reason));
    SubmitPluginBan(client, 0, "steam", steamId, "", "", duration, reason);
    return Plugin_Handled;
}

public Action CommandUnban(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "用法: sm_unban <steamid|ip> [reason]");
        return Plugin_Handled;
    }

    char target[128];
    char reason[256];
    char token[256];
    char url[512];
    char adminName[128];
    char adminSteamid[64];

    GetCmdArg(1, target, sizeof(target));
    if (!IsSteamId64String(target) && !IsIpAddressTarget(target))
    {
        ReplyToCommand(client, "[LumiAdmin] 游戏内解封玩家请使用 SteamID64。");
        return Plugin_Handled;
    }
    AppendCommandReason(2, args, reason, sizeof(reason));

    // 处理服务器控制台（client=0）的情况
    if (client == 0)
    {
        strcopy(adminName, sizeof(adminName), "CONSOLE");
        adminSteamid[0] = '\0';
        g_UnbanAdminUserId = 0;
    }
    else
    {
        GetClientName(client, adminName, sizeof(adminName));
        GetClientAuthId(client, AuthId_SteamID64, adminSteamid, sizeof(adminSteamid), true);
        g_UnbanAdminUserId = GetClientUserId(client);
    }

    int currentPort = 0;
    if (!GetCurrentServerPort(currentPort))
    {
        ReplyToCommand(client, "[LumiAdmin] 无法获取服务器端口。");
        return Plugin_Handled;
    }

    // 尝试在线解封
    if (ResolvePluginApiConfig(url, sizeof(url), "/bans/unban", token, sizeof(token)))
    {
        JSONObject payload = BuildPluginUnbanPayload(token, currentPort, target, reason, adminName, adminSteamid);
        PostJsonObject(url, payload, OnPluginUnbanResponse, g_UnbanAdminUserId);
        delete payload;
    }
    else
    {
        ReplyToCommand(client, "[LumiAdmin] API 未配置，使用离线队列...");
    }

    // 同时写入离线队列作为备份
    char targetType[16];
    if (IsSteamId64String(target))
    {
        strcopy(targetType, sizeof(targetType), "steam");
    }
    else
    {
        strcopy(targetType, sizeof(targetType), "ip");
    }

    if (!QueueEdgeSyncOperation("unban", target, targetType, "", reason, adminName, adminSteamid, 0))
    {
        ReplyToCommand(client, "%T", "Ban Queue Unavailable", client);
    }

    return Plugin_Handled;
}

// =====[ 菜单 ]=====

public Action ChatHook(int client, const char[] command, int argc)
{
    if (!g_WaitingOwnReason[client])
    {
        return Plugin_Continue;
    }

    char reason[256];
    GetCmdArgString(reason, sizeof(reason));
    StripQuotes(reason);
    g_WaitingOwnReason[client] = false;

    if (StrEqual(reason, "!noreason"))
    {
        PrintToChat(client, "%T", "Ban Reason Cancelled", client);
        return Plugin_Handled;
    }

    SubmitMenuBan(client, reason);
    return Plugin_Handled;
}

void DisplayBanTargetMenu(int client)
{
    Menu menu = new Menu(MenuHandler_BanTarget);
    menu.SetTitle("%T", "Ban Menu Title", client);

    for (int target = 1; target <= MaxClients; target++)
    {
        if (!IsClientInGame(target) || IsFakeClient(target))
        {
            continue;
        }

        char userid[16];
        char name[128];
        IntToString(GetClientUserId(target), userid, sizeof(userid));
        GetClientName(target, name, sizeof(name));
        menu.AddItem(userid, name);
    }

    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_BanTarget(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }

    if (action == MenuAction_Select)
    {
        char userid[16];
        menu.GetItem(item, userid, sizeof(userid));
        // H5：存 userid 而非 client index，防止菜单间隔期间槽位复用封错人
        g_BanTarget[client] = StringToInt(userid);
        DisplayBanTimeMenu(client);
    }

    return 0;
}

void DisplayBanTimeMenu(int client)
{
    Menu menu = new Menu(MenuHandler_BanTime);
    menu.SetTitle("%T", "Ban Menu Duration Title", client);
    char durationLabel[64];
    Format(durationLabel, sizeof(durationLabel), "%T", "Ban Duration Permanent", client); menu.AddItem("0", durationLabel);
    Format(durationLabel, sizeof(durationLabel), "%T", "Ban Duration 10 Minutes", client); menu.AddItem("10", durationLabel);
    Format(durationLabel, sizeof(durationLabel), "%T", "Ban Duration 30 Minutes", client); menu.AddItem("30", durationLabel);
    Format(durationLabel, sizeof(durationLabel), "%T", "Ban Duration 1 Hour", client); menu.AddItem("60", durationLabel);
    Format(durationLabel, sizeof(durationLabel), "%T", "Ban Duration 1 Day", client); menu.AddItem("1440", durationLabel);
    Format(durationLabel, sizeof(durationLabel), "%T", "Ban Duration 1 Week", client); menu.AddItem("10080", durationLabel);
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_BanTime(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }

    if (action == MenuAction_Select)
    {
        char minutes[16];
        menu.GetItem(item, minutes, sizeof(minutes));
        g_BanTime[client] = StringToInt(minutes);
        DisplayBanReasonMenu(client);
    }

    return 0;
}

void DisplayBanReasonMenu(int client)
{
    Menu menu = new Menu(MenuHandler_BanReason);
    menu.SetTitle("%T", "Ban Menu Reason Title", client);
    char reasonLabel[64];
    // L12：info 用稳定 key，展示文案走翻译，改翻译不影响提交值
    Format(reasonLabel, sizeof(reasonLabel), "%T", "Ban Reason Cheating", client); menu.AddItem("cheat", reasonLabel);
    Format(reasonLabel, sizeof(reasonLabel), "%T", "Ban Reason Malicious Behavior", client); menu.AddItem("malicious", reasonLabel);
    Format(reasonLabel, sizeof(reasonLabel), "%T", "Ban Reason Insulting Players", client); menu.AddItem("insult", reasonLabel);
    Format(reasonLabel, sizeof(reasonLabel), "%T", "Ban Reason Custom", client); menu.AddItem("own", reasonLabel);
    menu.Display(client, MENU_TIME_FOREVER);
}

/**
 * L12：稳定 key → 提交文案查表。
 */
void GetBanReasonForKey(const char[] key, char[] reason, int maxLen)
{
    if (StrEqual(key, "cheat"))
    {
        strcopy(reason, maxLen, "作弊");
    }
    else if (StrEqual(key, "malicious"))
    {
        strcopy(reason, maxLen, "恶意行为");
    }
    else if (StrEqual(key, "insult"))
    {
        strcopy(reason, maxLen, "辱骂玩家");
    }
    else
    {
        strcopy(reason, maxLen, key);
    }
}

public int MenuHandler_BanReason(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }

    if (action == MenuAction_Select)
    {
        char key[64];
        menu.GetItem(item, key, sizeof(key));
        if (StrEqual(key, "own"))
        {
            g_WaitingOwnReason[client] = true;
            PrintToChat(client, "%T", "Ban Reason Cancel Hint", client);
            return 0;
        }

        // H5：userid 换算，目标断开即报错终止
        int target = GetClientOfUserId(g_BanTarget[client]);
        if (target <= 0 || !IsClientInGame(target))
        {
            PrintToChat(client, "%T", "Ban Target Invalid", client);
            g_BanTarget[client] = 0;
            return 0;
        }

        char steamId[64];
        char ipAddress[64];
        char player[128];
        if (!GetClientAuthId(target, AuthId_SteamID64, steamId, sizeof(steamId), true))
        {
            PrintToChat(client, "%T", "Ban Target Invalid", client);
            return 0;
        }
        GetClientIP(target, ipAddress, sizeof(ipAddress), true);
        GetClientName(target, player, sizeof(player));

        char reason[256];
        GetBanReasonForKey(key, reason, sizeof(reason));
        SubmitPluginBan(client, target, "steam", steamId, ipAddress, player, g_BanTime[client], reason);
    }

    return 0;
}

void SubmitMenuBan(int client, const char[] reason)
{
    // H5：userid 换算，目标断开即报错终止
    int target = GetClientOfUserId(g_BanTarget[client]);
    if (target <= 0 || !IsClientInGame(target))
    {
        PrintToChat(client, "%T", "Ban Target Invalid", client);
        g_BanTarget[client] = 0;
        return;
    }

    char steamId[64];
    char ipAddress[64];
    char player[128];
    if (!GetClientAuthId(target, AuthId_SteamID64, steamId, sizeof(steamId), true))
    {
        PrintToChat(client, "%T", "Ban Target Invalid", client);
        return;
    }
    GetClientIP(target, ipAddress, sizeof(ipAddress), true);
    GetClientName(target, player, sizeof(player));
    SubmitPluginBan(client, target, "steam", steamId, ipAddress, player, g_BanTime[client], reason);
}
