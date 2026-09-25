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
        "本地快照完全不可用（无法裁决）时是否放行玩家。", _, true, 0.0, true, 1.0);
    g_AccessCheckTimeout = CreateConVar("server_access_check_timeout", DEFAULT_ACCESS_CHECK_TIMEOUT,
        "快照刷新/补偿请求超时（秒）。", _, true, 2.0, true, 30.0);
    g_AccessMissingGrace = CreateConVar("server_access_missing_grace", DEFAULT_ACCESS_MISSING_GRACE,
        "资料未验证（profile_missing）时延迟复核的宽限（秒）；宽限内快照追平即放行，到期仍未验证才踢出。0 表示立即踢出（旧行为）。", _, true, 0.0, true, 120.0);
    g_AuthEventsInterval = CreateConVar("server_auth_events_interval", DEFAULT_AUTH_EVENTS_INTERVAL,
        "授权事件 Long-Poll 间隔（秒，插件侧看门狗周期；后端 hold≤20s）。", _, true, 5.0, true, 120.0);

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
    RegAdminCmd("sm_lumi_access_status", CommandAccessStatus, ADMFLAG_GENERIC,
        "查看 LumiAdmin 进服权限子系统状态（快照年龄/熔断状态/最近事件）。");
    RegAdminCmd("sm_lumi_auth_status", CommandAuthStatus, ADMFLAG_GENERIC,
        "查看 LumiAdmin 授权事件同步状态（连接/版本/待同步）。");
    RegServerCmd("lumiadmin_refresh_snapshot", CommandRefreshSnapshot,
        "手动触发权限快照立即刷新（应急/接收面板推送）。");
    // RCON 快车道（后端封禁落地后经 RCON 下发）：先写本地 Ban 再 Kick，保证重连即拦。
    RegServerCmd("lumiadmin_apply_ban", CommandApplyBanFastPath,
        "授权快车道：lumiadmin_apply_ban <ban_id> <version> <steam_id> <expires_unix|0> <reason>");
    RegServerCmd("lumiadmin_apply_unban", CommandApplyUnbanFastPath,
        "授权快车道：lumiadmin_apply_unban <ban_id> <version> <steam_id>");
    RegServerCmd("lumiadmin_auth_resync", CommandAuthResync,
        "手动触发授权事件补偿（resync / snapshot）。");
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
    AuthSync_Start();
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

Action CommandRefreshSnapshot(int args)
{
    g_AccessSnapshotNextRetry = 0;
    g_AccessSnapshotBackoffStep = 0;
    RequestAccessSnapshotRefresh(true);
    LogMessage("[LumiAdmin-Access] manual snapshot refresh requested (sm console).");
    return Plugin_Handled;
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
