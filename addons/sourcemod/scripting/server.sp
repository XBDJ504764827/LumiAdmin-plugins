/**
 * LumiAdmin Server - 服务器侧上报与管控插件。
 *
 * 功能：
 * 1. 在线玩家上报（定时 + 断开原因）
 * 2. 服务器状态上报（FPS/CPU/Tickrate/在线数/地图）
 * 3. 封禁轮询与执行（sm_ban/sm_banip/sm_addban/sm_unban 拦截 + 菜单）
 * 4. 进服权限检查（在线 + 本地 SQLite 快照离线降级）
 * 5. 离线操作队列接入（配合 sync 插件做断网应急）
 *
 * 独立插件：core 未加载时自动读取 core.cfg 文件降级运行。
 */
#include <sourcemod>
#include <adt_array>
#include <ripext>
#include <lumiadmin/core>
#include <lumiadmin/config_parse>
#include <lumiadmin/api_client>
#include <lumiadmin/session_reasons>

#pragma newdecls required
#pragma semicolon 1

// sync 插件（可选）native 声明
native int Sync_EnqueueOperation(const char[] operation, const char[] target, const char[] targetType, const char[] playerName, const char[] reason, const char[] operatorName, const char[] operatorSteamid, int durationMinutes);
native bool Sync_IsOnline();
native int Sync_GetPendingCount();

#define DEFAULT_REPORT_INTERVAL "5.0"
#define DEFAULT_ACCESS_SNAPSHOT_INTERVAL "30.0"
#define DEFAULT_STATUS_REPORT_INTERVAL "30.0"
#define DEFAULT_DEBUG_LOG "0"
#define DEFAULT_ACCESS_FAIL_OPEN "1"
#define DEFAULT_ACCESS_CHECK_TIMEOUT "5.0"
#define DEFAULT_AUTH_EVENTS_INTERVAL "25.0"
#define AUTH_SNAPSHOT_VERSION_GAP 500
#define ACCESS_SNAPSHOT_DB "lumiadmin_access_snapshot"
#define MAX_SERVER_TOKEN 256
#define MAX_BAN_POLL_ETAG 96
#define MAX_ACCESS_SNAPSHOT_ETAG 128
#define MAX_AUTH_EVENT_ID 64

ConVar g_ReportInterval;
ConVar g_AccessSnapshotInterval;
ConVar g_StatusReportInterval;
ConVar g_DebugLog;
ConVar g_AccessFailOpen;
ConVar g_AccessCheckTimeout;
ConVar g_CpuUsageCvar;
ConVar g_HostPortCvar = null;
ConVar g_TickrateCvar = null;
Handle g_ReportTimer = null;
Handle g_BanPollTimer = null;
Handle g_AccessSnapshotTimer = null;
Handle g_StatusReportTimer = null;
Database g_AccessSnapshotDb = null;
StringMap g_ServerTokenMap = null;
char g_CachedReportToken[MAX_SERVER_TOKEN];
int g_CachedReportPort = -1;
bool g_HasCachedReportToken = false;
int g_LastPluginConfigState = -1;
int g_LastPluginConfigPort = -1;
int g_LastPluginConfigEntryIndex = -1;
int g_BanTarget[MAXPLAYERS + 1];
int g_BanTime[MAXPLAYERS + 1];
bool g_WaitingOwnReason[MAXPLAYERS + 1];
int g_LastTickrate = 64;
int g_ServerStartTime = 0;
int g_UnbanAdminUserId = 0;
char g_DisconnectReason[MAXPLAYERS + 1][32];
char g_DisconnectDetail[MAXPLAYERS + 1][256];

// 快照增量同步与退避状态
char g_AccessSnapshotEtag[MAX_ACCESS_SNAPSHOT_ETAG];
int g_AccessSnapshotBackoffStep = 0;
int g_AccessSnapshotNextRetry = 0;
int g_AccessSnapshotLastRefreshOk = 0;

// ban poll 失败退避状态（L10）
int g_BanPollBackoffStep = 0;

// 封禁轮询版本签名 etag
char g_BanPollEtag[MAX_BAN_POLL_ETAG];

// LumiAuth 事件同步状态（Data Plane）：last_applied_version 持久化在 metadata 表
ConVar g_AuthEventsInterval;
Handle g_AuthEventsTimer = null;
bool g_AuthConnected = false;
bool g_AuthEventsInFlight = false;
int g_AuthLastAppliedVersion = 0;
int g_AuthBackoffStep = 0;
int g_AuthLastOk = 0;

public Plugin myinfo =
{
    name = "LumiAdmin Server",
    author = "LumiAdmin",
    description = "Reports CS:GO online players and server status to LumiAdmin, enforces bans and access control.",
    version = "1.0.0",
    url = ""
};

#include "server/convars.sp"
#include "server/http.sp"
#include "server/steamid.sp"
#include "server/online.sp"
#include "server/bans.sp"
#include "server/access.sp"
#include "server/auth_sync.sp"

public void OnPluginStart()
{
    Server_OnPluginStart();
}

public void OnMapStart()
{
    if (g_AccessSnapshotDb == null)
    {
        InitAccessSnapshotDb();
    }

    StartReportTimer();
    StartBanPollTimer();
    StartAccessSnapshotTimer();
    StartStatusReportTimer();
    AuthSync_Start();
}

public void OnMapEnd()
{
    StopReportTimer();
    StopBanPollTimer();
    StopAccessSnapshotTimer();
    StopStatusReportTimer();
    AuthSync_Stop();
}

public void OnClientDisconnect(int client)
{
    ReportClientDisconnect(client);
    ClearClientDisconnectReason(client);
    g_WaitingOwnReason[client] = false;
    // H5：存的是 userid，槽位复用不再串人；清零防陈旧值
    g_BanTarget[client] = 0;
    g_BanTime[client] = 0;
}

public void OnClientPutInServer(int client)
{
    ClearClientDisconnectReason(client);
}

public void OnPluginEnd()
{
    StopReportTimer();
    StopBanPollTimer();
    StopAccessSnapshotTimer();
    StopStatusReportTimer();

    if (g_AccessSnapshotDb != null)
    {
        delete g_AccessSnapshotDb;
        g_AccessSnapshotDb = null;
    }
    if (g_ServerTokenMap != null)
    {
        delete g_ServerTokenMap;
        g_ServerTokenMap = null;
    }
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
    MarkNativeAsOptional("Sync_EnqueueOperation");
    MarkNativeAsOptional("Sync_IsOnline");
    MarkNativeAsOptional("Sync_GetPendingCount");
    RegPluginLibrary("server");
    return APLRes_Success;
}

public void OnAllPluginsLoaded()
{
    if (GetFeatureStatus(FeatureType_Native, "Sync_EnqueueOperation") != FeatureStatus_Available)
    {
        LogMessage("[LumiAdmin Server] sync.smx is not loaded; offline operation queue is unavailable. Ban/unban commands will only run while the API is reachable.");
    }
}
