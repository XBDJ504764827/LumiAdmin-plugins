/**
 * LumiAdmin Sync - 离线操作队列与同步引擎。
 *
 * 功能：
 * 1. 离线操作队列 - 所有操作先写入本地 SQLite，再尝试同步（断网应急处理）
 * 2. 断线检测 - HTTP 请求失败时自动切换离线模式
 * 3. 重连同步 - 定时检查队列，自动重试 pending 操作
 * 4. 本地审计 - 记录所有操作到 audit_log 表
 *
 * 独立插件：无配置文件，convar 全部使用默认值，可控制台临时修改。
 */
#include <sourcemod>
#include <adt_array>
#include <ripext>
#include <lumiadmin/core>
#include <lumiadmin/config_parse>
#include <lumiadmin/api_client>

#pragma newdecls required
#pragma semicolon 1

#define SYNC_VERSION "1.0.0"
#define SYNC_DB "lumiadmin_sync"
#define MAX_IDEMPOTENCY_KEY 64
#define MAX_SERVER_TOKEN 256
#define MAX_RETRY_COUNT 10
#define CLEANUP_RETENTION_SECONDS 604800

Database g_SyncDb = null;
Handle g_SyncTimer = null;
ConVar g_SyncInterval = null;
char g_ServerReportToken[MAX_SERVER_TOKEN];
int g_ServerPort = 0;
bool g_IsOnline = true;
bool g_SyncInFlight = false;
int g_PendingCount = 0;
int g_LastSyncTime = 0;
int g_OperationSeq = 0;

// H4：SQL 异步化后，入队触发改为延迟一次性 timer，避免命令路径卡顿
Handle g_SyncKickTimer = null;
// H3：超过软上限后拒收新操作，防止断网数月队列无限膨胀
#define SYNC_QUEUE_SOFT_LIMIT 2000

#include "sync/queue.sp"
#include "sync/audit.sp"
#include "sync/sync.sp"

public Plugin myinfo =
{
    name = "LumiAdmin Sync",
    author = "LumiAdmin",
    description = "Offline operation queue and sync engine for LumiAdmin.",
    version = SYNC_VERSION,
    url = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
    CreateNative("Sync_EnqueueOperation", Native_EnqueueOperation);
    CreateNative("Sync_IsOnline", Native_IsOnline);
    CreateNative("Sync_GetPendingCount", Native_GetPendingCount);
    RegPluginLibrary("sync");
    return APLRes_Success;
}

public void OnPluginStart()
{
    g_SyncInterval = CreateConVar("sync_interval", "30.0",
        "离线队列同步间隔（秒）。", _, true, 10.0);
    HookConVarChange(g_SyncInterval, OnSyncIntervalChanged);

    RegServerCmd("sync_set_token", CommandSetToken,
        "设置服务器 report token（fallback：sync_set_token <port> <token>）。");
    RegAdminCmd("sm_sync_status", CommandSyncStatus, ADMFLAG_RCON, "显示离线同步状态。");
    RegAdminCmd("sm_force_sync", CommandForceSync, ADMFLAG_RCON, "强制同步离线队列。");
    RegAdminCmd("sm_lumi_sync_retry", CommandRetryFailed, ADMFLAG_RCON, "把 failed 状态的离线队列行重置回 pending 手动重放。");

    ResolveSyncConfig();
    InitSyncDb();
    StartSyncTimer();
}

public void OnMapStart()
{
    if (g_SyncDb == null)
    {
        InitSyncDb();
    }
    ResolveSyncConfig();
    StartSyncTimer();
}

public void OnMapEnd()
{
    StopSyncTimer();
}

public void OnPluginEnd()
{
    StopSyncTimer();
    if (g_SyncKickTimer != null)
    {
        delete g_SyncKickTimer;
        g_SyncKickTimer = null;
    }
    // L11：显式释放数据库句柄，与 server 插件风格一致
    if (g_SyncDb != null)
    {
        delete g_SyncDb;
        g_SyncDb = null;
    }
}

public void OnSyncIntervalChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    StartSyncTimer();
}
