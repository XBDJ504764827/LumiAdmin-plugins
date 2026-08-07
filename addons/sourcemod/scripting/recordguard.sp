/**
 * LumiAdmin Record Guard - 异常完图成绩拦截插件。
 *
 * 功能：
 * 1. 从网站拉取地图异常时间规则
 * 2. 玩家完图后判断成绩是否异常（run_time <= threshold）
 * 3. 异常成绩拦截全球提交，创建网站待审记录（幂等）
 * 4. 管理员在网站审核通过后，轮询拉取并补交全球榜单
 *
 * 不做录像：异常记录无录像证据，由管理员在网站手工审核。
 * 独立插件：无配置文件，convar 使用默认值；core 未加载时自动读 core.cfg 降级。
 */
#include <sourcemod>
#include <ripext>
#include <GlobalAPI>
#include <gokz>
#include <gokz/core>
#include <gokz/kzplayer>
#include <lumiadmin/core>
#include <lumiadmin/config_parse>
#include <lumiadmin/recordguard>

#pragma newdecls required
#pragma semicolon 1

#define RECORDGUARD_VERSION "1.0.0"
#define MAX_URL_LENGTH 512
#define MAX_TOKEN_LENGTH 256
#define MAX_RECORD_ID 64
#define MAX_RULES 512
#define MAX_IDEMPOTENCY_KEY 96

ConVar g_RGEnabled = null;
ConVar g_RGRuleSyncInterval = null;
ConVar g_RGPollInterval = null;
ConVar g_RGRequestTimeout = null;
ConVar g_RGDebugLog = null;
ConVar g_RGTickrate = null;

Handle g_RGRuleTimer = null;
Handle g_RGPollTimer = null;

char g_CurrentMapName[128];

int g_RuleCount = 0;
char g_RuleMap[MAX_RULES][128];
int g_RuleCourse[MAX_RULES];
char g_RuleMode[MAX_RULES][16];
char g_RuleTimeType[MAX_RULES][8];
float g_RuleThreshold[MAX_RULES];

bool g_HeldActive[MAXPLAYERS + 1];
int g_HeldUserId[MAXPLAYERS + 1];
int g_HeldCourse[MAXPLAYERS + 1];
int g_HeldMode[MAXPLAYERS + 1];
int g_HeldTimeType[MAXPLAYERS + 1];
int g_HeldTeleports[MAXPLAYERS + 1];
int g_HeldMapId[MAXPLAYERS + 1];
float g_HeldRunTime[MAXPLAYERS + 1];
float g_HeldThreshold[MAXPLAYERS + 1];
bool g_HeldRecordCreated[MAXPLAYERS + 1];
char g_HeldRecordId[MAXPLAYERS + 1][MAX_RECORD_ID];
char g_HeldIdempotencyKey[MAXPLAYERS + 1][MAX_IDEMPOTENCY_KEY];
char g_HeldMapName[MAXPLAYERS + 1][128];
char g_HeldSteamId64[MAXPLAYERS + 1][32];
char g_HeldSteamId2[MAXPLAYERS + 1][32];
char g_HeldPlayerName[MAXPLAYERS + 1][MAX_NAME_LENGTH];

#include "recordguard/config.sp"
#include "recordguard/rules.sp"
#include "recordguard/detection.sp"
#include "recordguard/pending.sp"
#include "recordguard/submit.sp"

public Plugin myinfo =
{
    name = "LumiAdmin Record Guard",
    author = "LumiAdmin",
    description = "Holds abnormal GOKZ records for LumiAdmin review before global submission.",
    version = RECORDGUARD_VERSION,
    url = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
    CreateNative("RecordGuard_ShouldHoldRecord", Native_ShouldHoldRecord);
    CreateNative("RecordGuard_IsHoldingClient", Native_IsHoldingClient);
    RegPluginLibrary("recordguard");
    return APLRes_Success;
}

public void OnPluginStart()
{
    RecordGuard_OnPluginStart();
}

public void OnAllPluginsLoaded()
{
    RecordGuard_OnAllPluginsLoaded();
}

public void OnMapStart()
{
    GetCurrentMapDisplayName(g_CurrentMapName, sizeof(g_CurrentMapName));
    SyncRules();
    StartRuleSyncTimer();
    StartApprovedPollTimer();
}

public void OnMapEnd()
{
    StopRuleSyncTimer();
    StopApprovedPollTimer();
}

public void OnPluginEnd()
{
    StopRuleSyncTimer();
    StopApprovedPollTimer();
}

public void OnClientDisconnect(int client)
{
    ClearHeldRecord(client);
}
