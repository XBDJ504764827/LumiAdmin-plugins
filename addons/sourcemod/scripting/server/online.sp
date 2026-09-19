/**
 * 在线玩家上报、服务器状态上报、断开原因上报。
 */

void StartReportTimer()
{
    StopReportTimer();

    float interval = g_ReportInterval.FloatValue;
    g_ReportTimer = CreateTimer(interval, Timer_ReportOnlinePlayers, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void StopReportTimer()
{
    if (g_ReportTimer != null)
    {
        delete g_ReportTimer;
        g_ReportTimer = null;
    }
}

public Action Timer_ReportOnlinePlayers(Handle timer)
{
    char reportUrl[512];
    char reportToken[256];
    if (!ResolvePluginApiConfig(reportUrl, sizeof(reportUrl), "/online-players/report", reportToken, sizeof(reportToken)))
    {
        return Plugin_Continue;
    }

    JSONObject payload = BuildReportPayload(reportToken);
    PostJsonObject(reportUrl, payload, OnReportResponse);
    delete payload;

    return Plugin_Continue;
}

public void OnReportResponse(HTTPResponse response, any value, const char[] error)
{
    LogHttpPostFailure("online players report", response, error);
}

JSONObject BuildReportPayload(const char[] reportToken)
{
    int currentPort = 0;
    GetCurrentServerPort(currentPort);

    char currentMap[64];
    GetCurrentMap(currentMap, sizeof(currentMap));

    JSONObject root = new JSONObject();
    root.SetInt("port", currentPort);
    root.SetString("report_token", reportToken);
    root.SetString("current_map", currentMap);

    JSONArray players = new JSONArray();
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
        {
            continue;
        }

        char player[128];
        char steamId64[64];
        char playerIp[64];
        GetClientName(client, player, sizeof(player));
        // L4：未授权客户端跳过，避免空 steamid 上报
        if (!GetClientAuthId(client, AuthId_SteamID64, steamId64, sizeof(steamId64), true) || steamId64[0] == '\0')
        {
            continue;
        }
        GetClientIP(client, playerIp, sizeof(playerIp), true);

        JSONObject entry = new JSONObject();
        entry.SetString("name", player);
        entry.SetString("steam_id64", steamId64);
        entry.SetString("ip", playerIp);
        entry.SetInt("ping", RoundToNearest(GetClientAvgLatency(client, NetFlow_Both) * 1000.0));
        entry.SetInt("server_port", currentPort);
        entry.SetInt("connected_seconds", RoundToNearest(GetClientTime(client)));
        players.Push(entry);
        delete entry;
    }

    root.Set("players", players);
    delete players;
    return root;
}

// =====[ 服务器状态 ]=====

void StartStatusReportTimer()
{
    StopStatusReportTimer();

    float interval = g_StatusReportInterval.FloatValue;
    g_StatusReportTimer = CreateTimer(interval, Timer_ReportServerStatus, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void StopStatusReportTimer()
{
    if (g_StatusReportTimer != null)
    {
        delete g_StatusReportTimer;
        g_StatusReportTimer = null;
    }
}

public Action Timer_ReportServerStatus(Handle timer)
{
    g_LastTickrate = GetTickrate();
    ReportServerStatus();
    return Plugin_Continue;
}

void ReportServerStatus()
{
    char token[256];
    char url[512];
    if (!ResolvePluginApiConfig(url, sizeof(url), "/server-status", token, sizeof(token)))
    {
        return;
    }

    JSONObject payload = BuildServerStatusPayload(token);
    PostJsonObject(url, payload, OnServerStatusResponse);
    delete payload;
}

JSONObject BuildServerStatusPayload(const char[] token)
{
    int currentPort = 0;
    GetCurrentServerPort(currentPort);

    float fps = GetServerFrameRate();
    float cpu = GetServerCpuUsage();
    float tickrate = float(g_LastTickrate);
    int uptime = GetTime() - g_ServerStartTime;
    int playersCount = 0;
    int maxPlayers = GetMaxHumanPlayers();

    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client) && !IsFakeClient(client))
        {
            playersCount++;
        }
    }

    char currentMap[128];
    GetCurrentMap(currentMap, sizeof(currentMap));

    JSONObject payload = new JSONObject();
    payload.SetString("report_token", token);
    payload.SetInt("port", currentPort);
    payload.SetFloat("fps", fps);
    payload.SetFloat("cpu_usage", cpu);
    payload.SetFloat("tickrate", tickrate);
    payload.SetInt("uptime_seconds", uptime);
    payload.SetInt("players_count", playersCount);
    payload.SetInt("max_players", maxPlayers);
    payload.SetString("current_map", currentMap);
    return payload;
}

public void OnServerStatusResponse(HTTPResponse response, any value, const char[] error)
{
    LogHttpPostFailure("server status report", response, error);
}

float GetServerFrameRate()
{
    return GetTickInterval() > 0.0 ? 1.0 / GetTickInterval() : 0.0;
}

float GetServerCpuUsage()
{
    if (g_CpuUsageCvar != null)
    {
        return g_CpuUsageCvar.FloatValue;
    }
    return 0.0;
}

int GetTickrate()
{
    if (g_TickrateCvar != null)
    {
        int maxUpdateRate = g_TickrateCvar.IntValue;
        if (maxUpdateRate > 0)
        {
            return maxUpdateRate;
        }
    }
    return 64;
}

// =====[ 断开原因 ]=====

void ClearClientDisconnectReason(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }
    g_DisconnectReason[client][0] = '\0';
    g_DisconnectDetail[client][0] = '\0';
}

void MarkClientDisconnect(int client, const char[] reason, const char[] detail)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }
    strcopy(g_DisconnectReason[client], sizeof(g_DisconnectReason[]), reason);
    strcopy(g_DisconnectDetail[client], sizeof(g_DisconnectDetail[]), detail);
}

public Action CommandKickListener(int client, const char[] command, int args)
{
    if (args < 1)
    {
        return Plugin_Continue;
    }

    char targetArg[128];
    GetCmdArg(1, targetArg, sizeof(targetArg));
    int target = FindTarget(client, targetArg, true, false);
    if (target <= 0)
    {
        return Plugin_Continue;
    }

    char reason[256];
    AppendCommandReason(2, args, reason, sizeof(reason));

    char adminName[128];
    if (client == 0)
    {
        strcopy(adminName, sizeof(adminName), "CONSOLE");
    }
    else
    {
        GetClientName(client, adminName, sizeof(adminName));
    }

    char detail[256];
    Format(detail, sizeof(detail), "管理员 %s 执行 sm_kick：%s", adminName, reason);
    MarkClientDisconnect(target, SESSION_REASON_ADMIN_KICKED, detail);
    return Plugin_Continue;
}

void ReportClientDisconnect(int client)
{
    if (client <= 0 || client > MaxClients || IsFakeClient(client))
    {
        return;
    }

    char token[256];
    char url[512];
    if (!ResolvePluginApiConfig(url, sizeof(url), "/online-players/disconnect", token, sizeof(token)))
    {
        return;
    }

    int currentPort = 0;
    if (!GetCurrentServerPort(currentPort))
    {
        return;
    }

    char steamId64[64] = "";
    char steamId2[64] = "";
    GetClientAuthId(client, AuthId_SteamID64, steamId64, sizeof(steamId64), true);
    GetClientAuthId(client, AuthId_Steam2, steamId2, sizeof(steamId2), true);
    if (steamId64[0] == '\0' && steamId2[0] == '\0')
    {
        return;
    }

    char reason[32];
    if (g_DisconnectReason[client][0] == '\0')
    {
        strcopy(reason, sizeof(reason), SESSION_REASON_PLAYER_QUIT);
    }
    else
    {
        strcopy(reason, sizeof(reason), g_DisconnectReason[client]);
    }

    char detail[256];
    if (g_DisconnectDetail[client][0] == '\0')
    {
        strcopy(detail, sizeof(detail), "玩家断开连接。");
    }
    else
    {
        strcopy(detail, sizeof(detail), g_DisconnectDetail[client]);
    }

    char playerName[128] = "";
    char playerIp[64] = "";
    GetClientName(client, playerName, sizeof(playerName));
    GetClientIP(client, playerIp, sizeof(playerIp), true);

    JSONObject payload = new JSONObject();
    payload.SetString("report_token", token);
    payload.SetInt("port", currentPort);
    payload.SetString("steam_id64", steamId64);
    payload.SetString("steam_id", steamId2);
    payload.SetString("player_name", playerName);
    payload.SetString("ip", playerIp);
    payload.SetString("reason", reason);
    payload.SetString("detail", detail);
    PostJsonObject(url, payload, OnDisconnectReportResponse);
    delete payload;
}

public void OnDisconnectReportResponse(HTTPResponse response, any value, const char[] error)
{
    LogHttpPostFailure("disconnect report", response, error);
}
