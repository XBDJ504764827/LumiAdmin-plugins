#include <sourcemod>
#include <ripext>
#include <lumiadmin/config_parse>

#pragma newdecls required
#pragma semicolon 1

#define CORE_VERSION "1.2.0"
#define CORE_DEFAULT_API_BASE_URL "https://你的域名"
#define CORE_MAX_SERVER_TOKEN 256
#define CORE_MAX_INSTALL_ID 64
#define CORE_MAX_SERVER_ID 64
#define CORE_CFG_FOLDER "sourcemod/lumiadmin"

ConVar g_CoreApiBaseUrl = null;
ConVar g_CoreDebugLog = null;
ConVar g_CoreHostPort = null;
ConVar g_CoreInstallKey = null;
ConVar g_CoreAutoIdentify = null;
ConVar g_CoreIdentifyInterval = null;
StringMap g_CoreServerTokenMap = null;
char g_CoreCachedReportToken[CORE_MAX_SERVER_TOKEN];
int g_CoreCachedReportPort = -1;
bool g_CoreHasCachedReportToken = false;
char g_CoreInstallId[CORE_MAX_INSTALL_ID];
char g_CoreServerId[CORE_MAX_SERVER_ID];
int g_CoreLastNoTokenLog = 0;

#include "core/convars.sp"
#include "core/config.sp"
#include "core/identify.sp"
#include "core/natives.sp"

public Plugin myinfo =
{
    name = "LumiAdmin Core",
    author = "XBDJ504764827",
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
    CreateNative("Core_GetServerId", Native_GetServerId);
    RegPluginLibrary("core");
    return APLRes_Success;
}

public void OnPluginStart()
{
    Core_OnPluginStart();
}
