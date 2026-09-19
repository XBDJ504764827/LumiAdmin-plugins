/**
 * 配置与 HTTP 工具。无 cfg 文件，convar 全部使用默认值。
 */

void RecordGuard_OnPluginStart()
{
    g_RGEnabled = CreateConVar("recordguard_enabled", "1",
        "启用异常记录拦截。", _, true, 0.0, true, 1.0);
    g_RGRuleSyncInterval = CreateConVar("recordguard_rule_sync_interval", "60.0",
        "规则同步间隔（秒）。", _, true, 15.0);
    g_RGPollInterval = CreateConVar("recordguard_poll_interval", "10.0",
        "审核通过记录轮询间隔（秒）。", _, true, 5.0);
    g_RGRequestTimeout = CreateConVar("recordguard_request_timeout", "15",
        "HTTP 请求超时（秒）。", _, true, 3.0, true, 60.0);
    g_RGDebugLog = CreateConVar("recordguard_debug", "0",
        "启用 recordguard 调试日志。", _, true, 0.0, true, 1.0);
    g_RGTickrate = FindConVar("sv_maxupdaterate");
}

void RecordGuard_OnAllPluginsLoaded()
{
    if (!LibraryExists("gokz-core"))
    {
        LogError("[LumiAdmin Record Guard] gokz-core is not loaded; record holding will not work.");
    }
}

void StartRuleSyncTimer()
{
    StopRuleSyncTimer();
    g_RGRuleTimer = CreateTimer(g_RGRuleSyncInterval.FloatValue, Timer_SyncRules, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void StopRuleSyncTimer()
{
    if (g_RGRuleTimer != null)
    {
        delete g_RGRuleTimer;
        g_RGRuleTimer = null;
    }
}

public Action Timer_SyncRules(Handle timer)
{
    SyncRules();
    return Plugin_Continue;
}

void StartApprovedPollTimer()
{
    StopApprovedPollTimer();
    g_RGPollTimer = CreateTimer(g_RGPollInterval.FloatValue, Timer_PollApproved, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void StopApprovedPollTimer()
{
    if (g_RGPollTimer != null)
    {
        delete g_RGPollTimer;
        g_RGPollTimer = null;
    }
}

public Action Timer_PollApproved(Handle timer)
{
    PollApprovedRecords();
    return Plugin_Continue;
}

void DebugLog(const char[] format, any ...)
{
    if (g_RGDebugLog == null || !g_RGDebugLog.BoolValue)
    {
        return;
    }

    char message[512];
    VFormat(message, sizeof(message), format, 2);
    LogMessage("[lumiadmin-recordguard] %s", message);
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
        char fileToken[MAX_TOKEN_LENGTH];
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

/**
 * 构建插件 API URL：base + /api/plugin + suffix。
 */
bool BuildPluginApiUrl(const char[] suffix, char[] url, int maxLen)
{
    char baseUrl[MAX_URL_LENGTH];
    char token[MAX_TOKEN_LENGTH];
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

HTTPRequest CreateJsonRequest(const char[] suffix)
{
    char url[MAX_URL_LENGTH];
    if (!BuildPluginApiUrl(suffix, url, sizeof(url)))
    {
        LogError("[lumiadmin-recordguard] Missing API base URL, token, or server port.");
        return null;
    }

    HTTPRequest request = new HTTPRequest(url);
    request.Timeout = g_RGRequestTimeout != null ? g_RGRequestTimeout.IntValue : 15;
    request.SetHeader("Accept", "application/json");
    return request;
}

void ApplyServerHeaders(HTTPRequest request)
{
    char apiBaseUrl[MAX_URL_LENGTH];
    char token[MAX_TOKEN_LENGTH];
    int port = 0;
    if (!GetApiConfig(apiBaseUrl, sizeof(apiBaseUrl), token, sizeof(token), port))
    {
        return;
    }

    request.SetHeader("x-cngokz-report-token", "%s", token);
    request.SetHeader("x-cngokz-server-port", "%d", port);
}

int GetTickrate()
{
    if (g_RGTickrate != null)
    {
        return g_RGTickrate.IntValue;
    }
    return RoundToNearest(1.0 / GetTickInterval());
}
