/**
 * 同步引擎：配置解析、定时器、HTTP 同步。
 */

void StartSyncTimer()
{
    StopSyncTimer();
    float interval = g_SyncInterval.FloatValue;
    g_SyncTimer = CreateTimer(interval, Timer_SyncQueue, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void StopSyncTimer()
{
    if (g_SyncTimer != null)
    {
        delete g_SyncTimer;
        g_SyncTimer = null;
    }
}

public Action Timer_SyncQueue(Handle timer)
{
    SyncOfflineQueue();
    return Plugin_Continue;
}

/**
 * 解析 API 配置：优先 core 插件 native，降级读取 core.cfg 文件。
 */
bool GetApiConfig(char[] apiBaseUrl, int apiMaxLen, char[] token, int tokenMaxLen, int &port)
{
    apiBaseUrl[0] = '\0';
    token[0] = '\0';
    port = 0;

    if (LibraryExists("core"))
    {
        Core_GetApiBaseUrl(apiBaseUrl, apiMaxLen);
        Core_GetReportToken(token, tokenMaxLen);
        port = Core_GetServerPort();
    }

    if (apiBaseUrl[0] == '\0' || token[0] == '\0' || port <= 0)
    {
        char fileBase[512];
        char fileToken[MAX_SERVER_TOKEN];
        int filePort = 0;
        if (LumiReadCoreConfigCached(fileBase, sizeof(fileBase), filePort, fileToken, sizeof(fileToken)))
        {
            strcopy(apiBaseUrl, apiMaxLen, fileBase);
            strcopy(token, tokenMaxLen, fileToken);
            port = filePort;
        }
    }

    TrimString(apiBaseUrl);
    TrimString(token);
    return apiBaseUrl[0] != '\0' && token[0] != '\0' && port > 0;
}

void ResolveSyncConfig()
{
    char apiBaseUrl[512];
    char token[MAX_SERVER_TOKEN];
    int port = 0;
    if (GetApiConfig(apiBaseUrl, sizeof(apiBaseUrl), token, sizeof(token), port))
    {
        g_ServerPort = port;
        strcopy(g_ServerReportToken, sizeof(g_ServerReportToken), token);
    }
}

public Action CommandSetToken(int args)
{
    if (args < 2) return Plugin_Handled;

    char portText[16];
    char token[256];
    GetCmdArg(1, portText, sizeof(portText));
    GetCmdArg(2, token, sizeof(token));

    g_ServerPort = StringToInt(portText);
    strcopy(g_ServerReportToken, sizeof(g_ServerReportToken), token);

    LogMessage("[LumiAdmin Sync] Configured for port %d", g_ServerPort);
    return Plugin_Handled;
}

public Action CommandSyncStatus(int client, int args)
{
    char status[128];
    Format(status, sizeof(status), "[LumiAdmin Sync] Status: %s | Pending: %d | Last sync: %d seconds ago",
        g_IsOnline ? "Online" : "Offline",
        g_PendingCount,
        GetTime() - g_LastSyncTime);

    ReplyToCommand(client, status);
    return Plugin_Handled;
}

public Action CommandForceSync(int client, int args)
{
    ReplyToCommand(client, "[LumiAdmin Sync] Force syncing queue...");
    SyncOfflineQueue();
    return Plugin_Handled;
}

/**
 * 构建插件 API URL：base + /api/plugin + suffix。
 */
bool BuildPluginApiUrl(const char[] suffix, char[] url, int maxLen)
{
    char baseUrl[512];
    char token[MAX_SERVER_TOKEN];
    int port = 0;
    if (!GetApiConfig(baseUrl, sizeof(baseUrl), token, sizeof(token), port))
    {
        return false;
    }

    int len = strlen(baseUrl);
    while (len > 0 && baseUrl[len - 1] == '/')
    {
        baseUrl[--len] = '\0';
    }

    Format(url, maxLen, "%s/api/plugin%s", baseUrl, suffix);
    return true;
}

void SyncOfflineQueue()
{
    if (g_SyncDb == null) return;
    if (g_SyncInFlight) return;
    if (g_ServerPort <= 0 || g_ServerReportToken[0] == '\0')
    {
        ResolveSyncConfig();
    }
    if (g_ServerPort <= 0 || g_ServerReportToken[0] == '\0') return;

    // 查询待同步的操作（最多 50 条）
    DBResultSet results = SQL_Query(g_SyncDb, "SELECT id, operation, target, target_type, player_name, reason, duration_minutes, operator_name, operator_steamid, created_at, idempotency_key FROM offline_queue WHERE status = 'pending' AND retry_count < %d ORDER BY created_at ASC LIMIT 50", MAX_RETRY_COUNT);

    if (results == null) return;

    ArrayList ids = new ArrayList();
    JSONObject jsonPayload = new JSONObject();
    jsonPayload.SetString("report_token", g_ServerReportToken);
    jsonPayload.SetInt("port", g_ServerPort);
    JSONArray opsArray = new JSONArray();

    while (SQL_FetchRow(results))
    {
        int id = SQL_FetchInt(results, 0);
        ids.Push(id);

        char operation[32];
        char target[64];
        char targetType[16];
        char playerName[128];
        char reason[256];
        char operatorName[128];
        char operatorSteamid[64];
        char idempotencyKey[MAX_IDEMPOTENCY_KEY];
        int durationMinutes;
        int createdAt;

        SQL_FetchString(results, 1, operation, sizeof(operation));
        SQL_FetchString(results, 2, target, sizeof(target));
        SQL_FetchString(results, 3, targetType, sizeof(targetType));
        SQL_FetchString(results, 4, playerName, sizeof(playerName));
        SQL_FetchString(results, 5, reason, sizeof(reason));
        durationMinutes = SQL_FetchInt(results, 6);
        SQL_FetchString(results, 7, operatorName, sizeof(operatorName));
        SQL_FetchString(results, 8, operatorSteamid, sizeof(operatorSteamid));
        createdAt = SQL_FetchInt(results, 9);
        SQL_FetchString(results, 10, idempotencyKey, sizeof(idempotencyKey));

        JSONObject entry = new JSONObject();
        entry.SetString("operation", operation);
        entry.SetString("target", target);
        entry.SetString("target_type", targetType);
        entry.SetString("player_name", playerName);
        entry.SetString("reason", reason);
        entry.SetInt("duration_minutes", durationMinutes);
        entry.SetString("operator_name", operatorName);
        entry.SetString("operator_steamid", operatorSteamid);
        entry.SetInt("created_at_unix", createdAt);
        entry.SetString("idempotency_key", idempotencyKey);

        opsArray.Push(entry);
        delete entry;
    }
    delete results;

    if (opsArray.Length == 0)
    {
        delete opsArray;
        delete jsonPayload;
        delete ids;
        return;
    }

    jsonPayload.Set("operations", opsArray);
    delete opsArray;

    char url[512];
    if (!BuildPluginApiUrl("/offline/sync", url, sizeof(url)))
    {
        delete jsonPayload;
        delete ids;
        return;
    }

    HTTPRequest request = new HTTPRequest(url);
    request.Timeout = 10;
    g_SyncInFlight = true;
    // RIPExt 自动释放 request 句柄，只释放 payload
    request.Post(jsonPayload, OnSyncResponse, ids);
    delete jsonPayload;
    delete request;
}

public void OnSyncResponse(HTTPResponse response, any value, const char[] error)
{
    ArrayList ids = view_as<ArrayList>(value);

    if (error[0] != '\0')
    {
        LogError("[LumiAdmin Sync] Sync failed: %s", error);
        g_IsOnline = false;
        g_SyncInFlight = false;
        MarkOperationsRetryable(ids, error);
        delete ids;
        return;
    }

    if (response.Status < HTTPStatus_OK || response.Status >= HTTPStatus_MultipleChoices)
    {
        LogError("[LumiAdmin Sync] Sync returned HTTP %d", response.Status);
        g_IsOnline = false;
        char errorMsg[64];
        Format(errorMsg, sizeof(errorMsg), "HTTP %d", response.Status);
        g_SyncInFlight = false;
        if (response.Status >= HTTPStatus_BadRequest && response.Status < HTTPStatus_InternalServerError)
        {
            MarkOperationsFailed(ids, errorMsg);
        }
        else
        {
            MarkOperationsRetryable(ids, errorMsg);
        }
        delete ids;
        return;
    }

    g_IsOnline = true;
    g_SyncInFlight = false;
    g_LastSyncTime = GetTime();

    JSONObject data = view_as<JSONObject>(response.Data);
    if (data == null)
    {
        delete ids;
        UpdatePendingCount();
        return;
    }

    int applied = data.GetInt("applied");
    int skipped = data.GetInt("skipped");

    LogMessage("[LumiAdmin Sync] Sync complete: applied=%d, skipped=%d", applied, skipped);

    // M1：按服务端逐条结果分别标记；服务端返回 results 缺失时退回全量标 synced
    JSONArray results = view_as<JSONArray>(data.Get("results"));
    if (results == null)
    {
        MarkOperationSynced(ids);
        delete data;
        delete ids;
        UpdatePendingCount();
        return;
    }

    ArrayList skippedIds = new ArrayList();
    for (int i = 0; i < ids.Length; i++)
    {
        int id = ids.Get(i);
        bool failed = false;
        if (i < results.Length)
        {
            JSONObject result = view_as<JSONObject>(results.Get(i));
            if (result != null)
            {
                // applied=成功；skipped=重复提交（幂等，视为已应用）；failed=被拒绝
                char resultStatus[32];
                result.GetString("status", resultStatus, sizeof(resultStatus));
                if (StrEqual(resultStatus, "failed") || result.GetBool("rejected"))
                {
                    char reason[128];
                    result.GetString("error", reason, sizeof(reason));
                    ArrayList single = new ArrayList();
                    single.Push(id);
                    MarkOperationsFailed(single, reason);
                    delete single;
                    failed = true;
                }
                delete result;
            }
        }
        if (!failed)
        {
            skippedIds.Push(id);
        }
    }
    delete results;

    // skipped 视为已应用（幂等去重），与 applied 一并标记 synced
    MarkOperationSynced(skippedIds);
    delete skippedIds;
    delete data;
    delete ids;

    UpdatePendingCount();
}
