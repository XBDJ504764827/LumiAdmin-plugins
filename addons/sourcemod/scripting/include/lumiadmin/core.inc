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
}
#endif
