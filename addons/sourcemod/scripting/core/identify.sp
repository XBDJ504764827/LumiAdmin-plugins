/**
 * LumiAdmin Core - 插件免配置自识别。
 *
 * 插件只需在 core.cfg 填写 core_api_base_url，启动后由 core 调用
 * POST /api/plugin/identify，面板按「请求来源 IP + 端口」自动匹配服务器并下发
 * report_token；token 写入 core_identity.cfg 缓存，重启后立即可用。
 *
 * - core.cfg 中显式配置的 core_server "port" "token" 优先级最高，永不被覆盖；
 * - 识别失败按 15s→30s→60s→120s→300s 退避重试，期间进服权限走本地快照兜底；
 * - 成功后按 core_identify_interval 周期刷新，便于面板重置 token 后自动跟进。
 */

#define CORE_IDENTITY_BACKOFF_MAX_STEP 4
#define CORE_IDENTIFY_TIMEOUT 10

Handle g_CoreIdentifyTimer = null;
bool g_CoreIdentifyInFlight = false;
int g_CoreIdentifyBackoffStep = 0;
StringMap g_CoreStaticPortMap = null; // 来自 core.cfg 的显式映射（不参与自动识别）
StringMap g_CoreAutoPortMap = null;   // 来自自动识别的端口（用于写回 core_identity.cfg）

void Core_InitIdentity()
{
    g_CoreInstallId[0] = '\0';
    g_CoreServerId[0] = '\0';

    if (g_CoreStaticPortMap == null)
    {
        g_CoreStaticPortMap = new StringMap();
    }
    if (g_CoreAutoPortMap == null)
    {
        g_CoreAutoPortMap = new StringMap();
    }

    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "../../cfg/sourcemod/lumiadmin/core_identity.cfg");

    File file = OpenFile(path, "r");
    if (file == null)
    {
        Core_GenerateInstallId();
        return;
    }

    char line[512];
    while (!file.EndOfFile() && file.ReadLine(line, sizeof(line)))
    {
        TrimString(line);
        if (line[0] == '\0' || (line[0] == '/' && line[1] == '/'))
        {
            continue;
        }

        char value[256];
        if (ParseConfigValueLine(line, "core_identity_id", value, sizeof(value)))
        {
            strcopy(g_CoreInstallId, sizeof(g_CoreInstallId), value);
            TrimString(g_CoreInstallId);
            continue;
        }

        if (ParseConfigValueLine(line, "core_server_id", value, sizeof(value)))
        {
            strcopy(g_CoreServerId, sizeof(g_CoreServerId), value);
            TrimString(g_CoreServerId);
            continue;
        }

        int port = 0;
        char token[CORE_MAX_SERVER_TOKEN];
        if (ParsePortTokenMappingLine(line, "core_identity", port, token, sizeof(token)))
        {
            char portKey[16];
            IntToString(port, portKey, sizeof(portKey));
            g_CoreAutoPortMap.SetValue(portKey, 1);
            RegisterServerTokenMapping(port, token);
        }
    }

    delete file;

    if (g_CoreInstallId[0] == '\0')
    {
        Core_GenerateInstallId();
    }
}

void Core_GenerateInstallId()
{
    static const char hexChars[] = "0123456789abcdef";
    for (int i = 0; i < 32; i++)
    {
        g_CoreInstallId[i] = hexChars[GetRandomInt(0, 15)];
    }
    g_CoreInstallId[32] = '\0';
}

bool Core_AutoIdentifyEnabled()
{
    return g_CoreAutoIdentify != null && g_CoreAutoIdentify.BoolValue;
}

/**
 * 启动自动识别流程（延迟 5s，等待 core.cfg 中的 core_server 命令执行完毕）。
 */
void Core_StartIdentify()
{
    if (!Core_AutoIdentifyEnabled())
    {
        return;
    }
    Core_RequestIdentify(5.0);
}

/**
 * 请求一次识别。delay<=0 表示尽快执行；已有请求在途/已排队时不重复排队。
 */
void Core_RequestIdentify(float delay)
{
    if (!Core_AutoIdentifyEnabled() || g_CoreIdentifyInFlight)
    {
        return;
    }
    if (g_CoreIdentifyTimer != null)
    {
        return;
    }
    g_CoreIdentifyTimer = CreateTimer(delay > 0.0 ? delay : 0.1, Timer_CoreIdentify);
}

public Action Timer_CoreIdentify(Handle timer)
{
    g_CoreIdentifyTimer = null;
    Core_TryIdentify();
    return Plugin_Stop;
}

bool Core_IsStaticPort(int port)
{
    char portKey[16];
    IntToString(port, portKey, sizeof(portKey));
    return g_CoreStaticPortMap != null && g_CoreStaticPortMap.ContainsKey(portKey);
}

void Core_MarkStaticPort(int port)
{
    if (g_CoreStaticPortMap == null)
    {
        g_CoreStaticPortMap = new StringMap();
    }
    if (g_CoreAutoPortMap != null)
    {
        char portKey[16];
        IntToString(port, portKey, sizeof(portKey));
        g_CoreAutoPortMap.Remove(portKey);
    }

    char portKey[16];
    IntToString(port, portKey, sizeof(portKey));
    g_CoreStaticPortMap.SetValue(portKey, 1);
}

bool Core_TryIdentify()
{
    if (!Core_AutoIdentifyEnabled() || g_CoreIdentifyInFlight)
    {
        return false;
    }

    int port = 0;
    if (!GetCurrentServerPort(port))
    {
        // hostport 暂不可用（极少见）：稍后重试，不放弃自动识别
        Core_ScheduleIdentifyRetry();
        return false;
    }

    // core.cfg 显式配置优先：绝不覆盖用户手写的 token
    if (Core_IsStaticPort(port))
    {
        return false;
    }

    char baseUrl[512];
    if (g_CoreApiBaseUrl == null)
    {
        return false;
    }
    g_CoreApiBaseUrl.GetString(baseUrl, sizeof(baseUrl));
    TrimString(baseUrl);
    if (baseUrl[0] == '\0')
    {
        Core_ScheduleIdentifyRetry();
        return false;
    }

    char url[640];
    Core_BuildIdentifyUrl(baseUrl, url, sizeof(url));

    char hostname[128];
    hostname[0] = '\0';
    ConVar hostnameCvar = FindConVar("hostname");
    if (hostnameCvar != null)
    {
        hostnameCvar.GetString(hostname, sizeof(hostname));
    }

    JSONObject payload = new JSONObject();
    payload.SetInt("port", port);
    payload.SetString("hostname", hostname);
    payload.SetString("game", "source");
    payload.SetString("install_id", g_CoreInstallId);

    HTTPRequest request = new HTTPRequest(url);
    request.Timeout = CORE_IDENTIFY_TIMEOUT;

    char installKey[128];
    installKey[0] = '\0';
    if (g_CoreInstallKey != null)
    {
        g_CoreInstallKey.GetString(installKey, sizeof(installKey));
        TrimString(installKey);
    }
    if (installKey[0] != '\0')
    {
        request.SetHeader("X-Lumi-Install-Key", installKey);
    }

    request.Post(payload, OnCoreIdentifyResponse, port);
    delete request;
    delete payload;

    g_CoreIdentifyInFlight = true;
    return true;
}

Action CommandReidentify(int args)
{
    g_CoreIdentifyBackoffStep = 0;
    if (g_CoreIdentifyTimer != null)
    {
        delete g_CoreIdentifyTimer;
        g_CoreIdentifyTimer = null;
    }
    Core_RequestIdentify(0.0);
    LogMessage("[LumiAdmin Core] manual re-identify requested.");
    return Plugin_Handled;
}

void Core_BuildIdentifyUrl(const char[] baseUrl, char[] url, int maxLen)
{
    char trimmed[512];
    strcopy(trimmed, sizeof(trimmed), baseUrl);
    TrimString(trimmed);

    int len = strlen(trimmed);
    while (len > 0 && trimmed[len - 1] == '/')
    {
        trimmed[--len] = '\0';
    }

    Format(url, maxLen, "%s/api/plugin/identify", trimmed);
}

public void OnCoreIdentifyResponse(HTTPResponse response, any value, const char[] error)
{
    g_CoreIdentifyInFlight = false;
    int port = value;

    if (error[0] != '\0' || response.Status < HTTPStatus_OK || response.Status >= HTTPStatus_MultipleChoices)
    {
        if (error[0] != '\0')
        {
            LogError("[LumiAdmin Core] identify failed for port %d: %s. Retrying in %ds.", port, error, Core_NextIdentifyBackoffSeconds());
        }
        else
        {
            LogError("[LumiAdmin Core] identify failed for port %d: HTTP %d. Retrying in %ds.", port, response.Status, Core_NextIdentifyBackoffSeconds());
        }
        Core_ScheduleIdentifyRetry();
        return;
    }

    JSONObject root = view_as<JSONObject>(response.Data);
    if (root == null)
    {
        Core_ScheduleIdentifyRetry();
        return;
    }

    JSONObject server = view_as<JSONObject>(root.Get("server"));
    if (server == null)
    {
        LogError("[LumiAdmin Core] identify response missing server object for port %d.", port);
        delete root;
        Core_ScheduleIdentifyRetry();
        return;
    }

    char token[CORE_MAX_SERVER_TOKEN];
    char serverName[128];
    char serverId[CORE_MAX_SERVER_ID];
    token[0] = '\0';
    server.GetString("report_token", token, sizeof(token));
    server.GetString("server_name", serverName, sizeof(serverName));
    server.GetString("server_id", serverId, sizeof(serverId));
    TrimString(token);
    TrimString(serverId);
    strcopy(g_CoreServerId, sizeof(g_CoreServerId), serverId);

    if (token[0] == '\0')
    {
        LogError("[LumiAdmin Core] identify response for port %d contained empty report_token.", port);
        delete server;
        delete root;
        Core_ScheduleIdentifyRetry();
        return;
    }

    RegisterServerTokenMapping(port, token);
    InvalidateTokenCache();
    if (g_CoreAutoPortMap == null)
    {
        g_CoreAutoPortMap = new StringMap();
    }
    char portKey[16];
    IntToString(port, portKey, sizeof(portKey));
    g_CoreAutoPortMap.SetValue(portKey, 1);

    g_CoreIdentifyBackoffStep = 0;
    Core_SaveIdentity();
    LogMessage("[LumiAdmin Core] identify success: port %d bound to server '%s'.", port, serverName);

    delete server;
    delete root;

    // 周期性刷新，便于管理员在面板重置 token 后自动跟进
    if (g_CoreIdentifyInterval != null && g_CoreIdentifyInterval.IntValue > 0)
    {
        Core_RequestIdentify(float(g_CoreIdentifyInterval.IntValue));
    }
}

void Core_ScheduleIdentifyRetry()
{
    int seconds = Core_NextIdentifyBackoffSeconds();
    if (g_CoreIdentifyBackoffStep < CORE_IDENTITY_BACKOFF_MAX_STEP)
    {
        g_CoreIdentifyBackoffStep++;
    }
    Core_RequestIdentify(float(seconds));
}

int Core_NextIdentifyBackoffSeconds()
{
    // 15s → 30s → 60s → 120s → 300s
    static const int steps[CORE_IDENTITY_BACKOFF_MAX_STEP + 1] = { 15, 30, 60, 120, 300 };
    int index = g_CoreIdentifyBackoffStep;
    if (index < 0)
    {
        index = 0;
    }
    if (index > CORE_IDENTITY_BACKOFF_MAX_STEP)
    {
        index = CORE_IDENTITY_BACKOFF_MAX_STEP;
    }
    return steps[index];
}

/**
 * 把安装实例 ID 与自动识别出的端口映射写回 core_identity.cfg。
 */
void Core_SaveIdentity()
{
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "../../cfg/sourcemod/lumiadmin/core_identity.cfg");

    File file = OpenFile(path, "w");
    if (file == null)
    {
        LogError("[LumiAdmin Core] failed to write %s.", path);
        return;
    }

    file.WriteLine("// Auto-generated by LumiAdmin Core. Do not edit while the server is running.");
    file.WriteLine("// 删除本文件后，插件会在下次启动时重新向面板识别服务器。");
    file.WriteLine("core_identity_id \"%s\"", g_CoreInstallId);
    file.WriteLine("core_server_id \"%s\"", g_CoreServerId);

    if (g_CoreAutoPortMap != null && g_CoreServerTokenMap != null)
    {
        StringMapSnapshot snapshot = g_CoreAutoPortMap.Snapshot();
        for (int i = 0; i < snapshot.Length; i++)
        {
            char portKey[16];
            snapshot.GetKey(i, portKey, sizeof(portKey));

            char token[CORE_MAX_SERVER_TOKEN];
            if (g_CoreServerTokenMap.GetString(portKey, token, sizeof(token)))
            {
                file.WriteLine("core_identity \"%s\" \"%s\"", portKey, token);
            }
        }
        delete snapshot;
    }

    delete file;
}
