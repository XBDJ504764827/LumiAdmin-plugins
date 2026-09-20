#if defined _lumiadmin_core_included
#endinput
#endif
#define _lumiadmin_core_included

/**
 * LumiAdmin Core - shared configuration natives.
 * Loaded from the "core" plugin. All natives are optional;
 * other plugins must fall back to reading core.cfg directly.
 */

native int Core_GetApiBaseUrl(char[] apiBaseUrl, int maxLen);
native int Core_GetReportToken(char[] token, int maxLen);
native int Core_GetServerPort();
native bool Core_IsDebugEnabled();
// LumiAuth：identify 下发的稳定 server_id（UUID 字符串），hostname 自动跟随回写面板。
// 老 core.smx 无此 native 时返回 0，调用方按空字符串处理（向后兼容）。
native int Core_GetServerId(char[] serverId, int maxLen);

public SharedPlugin __pl_lumiadmin_core =
{
    name = "core",
    file = "core.smx",
#if defined REQUIRE_PLUGIN
    required = 1,
#else
    required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_lumiadmin_core_SetNTVOptional()
{
    MarkNativeAsOptional("Core_GetApiBaseUrl");
    MarkNativeAsOptional("Core_GetReportToken");
    MarkNativeAsOptional("Core_GetServerPort");
    MarkNativeAsOptional("Core_IsDebugEnabled");
    MarkNativeAsOptional("Core_GetServerId");
}
#endif
