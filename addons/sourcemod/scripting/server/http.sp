/**
 * HTTP 与 API 配置解析工具。
 */

void DebugLog(const char[] format, any ...)
{
    if (g_DebugLog == null || !g_DebugLog.BoolValue)
    {
        return;
    }

    char message[512];
    VFormat(message, sizeof(message), format, 2);
    PrintToServer("[LumiAdmin Server Debug] %s", message);
}

bool GetCurrentServerPort(int &port)
{
    if (LibraryExists("core"))
    {
        port = Core_GetServerPort();
        if (port > 0)
        {
            return true;
        }
    }

    if (g_HostPortCvar == null)
    {
        return false;
    }
    port = g_HostPortCvar.IntValue;
    return port > 0;
}

bool GetCurrentReportToken(char[] token, int maxLen)
{
    token[0] = '\0';

    if (LibraryExists("core") && Core_GetReportToken(token, maxLen))
    {
        return token[0] != '\0';
    }

    int currentPort = 0;
    if (!GetCurrentServerPort(currentPort))
    {
        if (ShouldLogPluginConfigState(7, 0))
        {
            LogError("[LumiAdmin Server] skipped: current server port detect failed.");
        }
        return false;
    }

    if (g_HasCachedReportToken && g_CachedReportPort == currentPort)
    {
        strcopy(token, maxLen, g_CachedReportToken);
        return true;
    }

    // 降级：直接读取 core.cfg 文件（core 插件未加载时，失败结果 60s 负缓存）
    char fileBase[512];
    char fileToken[MAX_SERVER_TOKEN];
    int filePort = 0;
    if (LumiReadCoreConfigCached(fileBase, sizeof(fileBase), filePort, fileToken, sizeof(fileToken)) && filePort == currentPort)
    {
        strcopy(token, maxLen, fileToken);
        TrimString(token);
        if (token[0] != '\0')
        {
            g_CachedReportPort = currentPort;
            strcopy(g_CachedReportToken, sizeof(g_CachedReportToken), token);
            g_HasCachedReportToken = true;
            return true;
        }
    }

    char portKey[16];
    IntToString(currentPort, portKey, sizeof(portKey));
    if (g_ServerTokenMap == null || !g_ServerTokenMap.GetString(portKey, token, maxLen))
    {
        if (ShouldLogPluginConfigState(6, currentPort))
        {
            LogError("[LumiAdmin Server] skipped: no token found for port %d.", currentPort);
        }
        return false;
    }

    TrimString(token);
    if (token[0] == '\0')
    {
        if (ShouldLogPluginConfigState(5, currentPort))
        {
            LogError("[LumiAdmin Server] skipped: token for port %d is empty.", currentPort);
        }
        return false;
    }

    g_CachedReportPort = currentPort;
    strcopy(g_CachedReportToken, sizeof(g_CachedReportToken), token);
    g_HasCachedReportToken = true;
    return true;
}

/**
 * 构建插件 API URL：base + /api/plugin + suffix。
 */
bool BuildPluginApiUrl(char[] url, int maxLen, const char[] suffix)
{
    if (!LumiBuildPluginApiUrl(url, maxLen, suffix))
    {
        int currentPort = 0;
        GetCurrentServerPort(currentPort);
        if (ShouldLogPluginConfigState(0, currentPort))
        {
            LogError("[LumiAdmin Server] skipped: core_api_base_url is empty.");
        }
        return false;
    }
    return true;
}

bool ResolvePluginApiConfig(char[] url, int urlMaxLen, const char[] suffix, char[] token, int tokenMaxLen)
{
    if (!BuildPluginApiUrl(url, urlMaxLen, suffix))
    {
        return false;
    }

    if (!GetCurrentReportToken(token, tokenMaxLen))
    {
        return false;
    }

    return true;
}

/**
 * 发送 JSON POST 请求。内部负责 HTTPRequest 句柄的释放（防泄漏）。
 * timeout 取 0 或负值时使用默认 10s。
 */
bool PostJsonObject(const char[] url, JSONObject payload, HTTPRequestCallback callback, any value = 0, float timeout = 10.0)
{
    if (payload == null)
    {
        LogError("[LumiAdmin Server] failed to create JSON payload for %s.", url);
        return false;
    }

    HTTPRequest request = new HTTPRequest(url);
    request.Timeout = timeout > 0 ? RoundToZero(timeout) : 10;
    request.Post(payload, callback, value);
    delete request;
    return true;
}

void LogHttpPostFailure(const char[] label, HTTPResponse response, const char[] error)
{
    if (error[0] != '\0')
    {
        LogError("[LumiAdmin Server] %s failed: %s", label, error);
        return;
    }

    if (response.Status < HTTPStatus_OK || response.Status >= HTTPStatus_MultipleChoices)
    {
        LogError("[LumiAdmin Server] %s returned HTTP status %d.", label, response.Status);
    }
}

bool QueueEdgeSyncOperation(const char[] operation, const char[] target, const char[] targetType, const char[] playerName, const char[] reason, const char[] operatorName, const char[] operatorSteamid, int durationMinutes)
{
    if (GetFeatureStatus(FeatureType_Native, "Sync_EnqueueOperation") != FeatureStatus_Available)
    {
        LogError("[LumiAdmin Server] Sync_EnqueueOperation is unavailable. Load sync.smx to enable the offline operation queue.");
        return false;
    }

    Sync_EnqueueOperation(operation, target, targetType, playerName, reason, operatorName, operatorSteamid, durationMinutes);
    return true;
}
