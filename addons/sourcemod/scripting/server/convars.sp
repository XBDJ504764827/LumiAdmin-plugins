void Server_OnPluginStart()
{
    LoadTranslations("lumiadmin.phrases");

    g_ReportInterval = CreateConVar("server_report_interval", DEFAULT_REPORT_INTERVAL,
        "在线玩家上报间隔（秒）。", _, true, 5.0);
    g_AccessSnapshotInterval = CreateConVar("server_access_snapshot_interval", DEFAULT_ACCESS_SNAPSHOT_INTERVAL,
        "进服权限快照刷新间隔（秒）。", _, true, 30.0);
    g_StatusReportInterval = CreateConVar("server_status_interval", DEFAULT_STATUS_REPORT_INTERVAL,
        "服务器状态上报间隔（秒）。", _, true, 10.0);
    g_DebugLog = CreateConVar("server_debug", DEFAULT_DEBUG_LOG,
        "启用 server 插件调试日志。", _, true, 0.0, true, 1.0);
    g_AccessFailOpen = CreateConVar("server_access_fail_open", DEFAULT_ACCESS_FAIL_OPEN,
        "LumiAdmin 权限 API 与本地快照不可用时是否放行玩家。", _, true, 0.0, true, 1.0);

    // sys_cpu_usage: SourceMod 内置 CPU 使用率 ConVar
    g_CpuUsageCvar = FindConVar("sys_cpu_usage");
    g_HostPortCvar = FindConVar("hostport");
    g_TickrateCvar = FindConVar("sv_maxupdaterate");

    HookConVarChange(g_ReportInterval, OnPluginConfigChanged);
    HookConVarChange(g_AccessSnapshotInterval, OnPluginConfigChanged);
    HookConVarChange(g_StatusReportInterval, OnStatusReportIntervalChanged);
    HookConVarChange(g_DebugLog, OnPluginConfigChanged);

    RegAdminCmd("sm_ban", CommandBan, ADMFLAG_BAN, "sm_ban <#userid|name> <minutes|0> [reason]");
    RegAdminCmd("sm_banip", CommandBanIp, ADMFLAG_BAN, "sm_banip <ip|#userid|name> <minutes|0> [reason]");
    RegAdminCmd("sm_addban", CommandAddBan, ADMFLAG_RCON, "sm_addban <minutes|0> <steamid> [reason]");
    RegAdminCmd("sm_unban", CommandUnban, ADMFLAG_UNBAN, "sm_unban <steamid|ip> [reason]");
    RegServerCmd("server_set_token", CommandServerMapping,
        "设置服务器 report token（fallback：server_set_token <port> <token>）。");
    AddCommandListener(ChatHook, "say");
    AddCommandListener(ChatHook, "say_team");
    AddCommandListener(CommandKickListener, "sm_kick");

    if (g_ServerTokenMap == null)
    {
        g_ServerTokenMap = new StringMap();
    }

    g_ServerStartTime = GetTime();
    EnsureConfigDirectory();
    AutoExecConfig(true, "server", "sourcemod/lumiadmin");
    InitAccessSnapshotDb();
    StartReportTimer();
    StartBanPollTimer();
    StartAccessSnapshotTimer();
    StartStatusReportTimer();
}

void EnsureConfigDirectory()
{
    char dir[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, dir, sizeof(dir), "../../cfg/sourcemod/lumiadmin");
    if (!DirExists(dir))
    {
        CreateDirectory(dir, 511);
    }
}

public void OnPluginConfigChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    InvalidatePluginConfigCache();
    ResetPluginConfigLogState();

    if (convar == g_ReportInterval)
    {
        StartReportTimer();
        StartBanPollTimer();
        return;
    }

    if (convar == g_AccessSnapshotInterval)
    {
        StartAccessSnapshotTimer();
    }
}

public void OnStatusReportIntervalChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    StartStatusReportTimer();
}

void ResetServerTokenMappings()
{
    if (g_ServerTokenMap != null)
    {
        g_ServerTokenMap.Clear();
    }
}

void InvalidatePluginConfigCache()
{
    g_CachedReportToken[0] = '\0';
    g_CachedReportPort = -1;
    g_HasCachedReportToken = false;
    g_BanPollEtag[0] = '\0';
}

void ResetPluginConfigLogState()
{
    g_LastPluginConfigState = -1;
    g_LastPluginConfigPort = -1;
    g_LastPluginConfigEntryIndex = -1;
}

bool ShouldLogPluginConfigState(int state, int port, int entryIndex = -1)
{
    if (state == g_LastPluginConfigState && port == g_LastPluginConfigPort && entryIndex == g_LastPluginConfigEntryIndex)
    {
        return false;
    }

    g_LastPluginConfigState = state;
    g_LastPluginConfigPort = port;
    g_LastPluginConfigEntryIndex = entryIndex;
    return true;
}

Action CommandServerMapping(int args)
{
    if (args < 2)
    {
        return Plugin_Handled;
    }

    char portText[64];
    char token[MAX_SERVER_TOKEN];
    GetCmdArg(1, portText, sizeof(portText));
    GetCmdArg(2, token, sizeof(token));

    int port = StringToInt(portText);
    if (port <= 0)
    {
        LogError("[LumiAdmin Server] server mapping ignored: invalid port %s.", portText);
        return Plugin_Handled;
    }

    RegisterServerTokenMapping(port, token);
    InvalidatePluginConfigCache();
    return Plugin_Handled;
}

void RegisterServerTokenMapping(int port, const char[] token)
{
    if (port <= 0)
    {
        LogError("[LumiAdmin Server] server mapping ignored: invalid port %d.", port);
        return;
    }

    char trimmedToken[MAX_SERVER_TOKEN];
    strcopy(trimmedToken, sizeof(trimmedToken), token);
    TrimString(trimmedToken);
    if (trimmedToken[0] == '\0')
    {
        LogError("[LumiAdmin Server] server mapping ignored: empty token for port %d.", port);
        return;
    }

    char portKey[16];
    IntToString(port, portKey, sizeof(portKey));

    g_ServerTokenMap.SetString(portKey, trimmedToken);
}
