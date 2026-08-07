#include <sourcemod>

#pragma newdecls required
#pragma semicolon 1

#define CORE_VERSION "1.0.0"
#define CORE_DEFAULT_API_BASE_URL "https://你的域名"
#define CORE_MAX_SERVER_TOKEN 256
#define CORE_CFG_FOLDER "sourcemod/lumiadmin"

ConVar g_CoreApiBaseUrl = null;
ConVar g_CoreDebugLog = null;
ConVar g_CoreHostPort = null;
StringMap g_CoreServerTokenMap = null;
char g_CoreCachedReportToken[CORE_MAX_SERVER_TOKEN];
int g_CoreCachedReportPort = -1;
bool g_CoreHasCachedReportToken = false;

#include "core/convars.sp"
#include "core/config.sp"
#include "core/natives.sp"

public Plugin myinfo =
{
    name = "LumiAdmin Core",
    author = "LumiAdmin",
    description = "Shared LumiAdmin configuration: API base URL and server port->token mapping.",
    version = CORE_VERSION,
    url = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
    CreateNative("Core_GetApiBaseUrl", Native_GetApiBaseUrl);
    CreateNative("Core_GetReportToken", Native_GetReportToken);
    CreateNative("Core_GetServerPort", Native_GetServerPort);
    CreateNative("Core_IsDebugEnabled", Native_IsDebugEnabled);
    RegPluginLibrary("core");
    return APLRes_Success;
}

public void OnPluginStart()
{
    Core_OnPluginStart();
}
