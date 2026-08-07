void Core_OnPluginStart()
{
    g_CoreApiBaseUrl = CreateConVar("core_api_base_url", CORE_DEFAULT_API_BASE_URL,
        "LumiAdmin 插件 API 地址，只填域名（如 https://你的域名），插件自动拼接 /api/plugin 路径。");
    g_CoreDebugLog = CreateConVar("core_debug", "0",
        "启用 core 调试日志。", _, true, 0.0, true, 1.0);
    g_CoreHostPort = FindConVar("hostport");
    if (g_CoreServerTokenMap == null)
    {
        g_CoreServerTokenMap = new StringMap();
    }

    RegServerCmd("core_server", CommandServerMapping,
        "注册一个端口->report_token 映射。可在 core.cfg 中多行配置：core_server \"27015\" \"token\"");
    HookConVarChange(g_CoreApiBaseUrl, OnCoreConfigChanged);
    HookConVarChange(g_CoreDebugLog, OnCoreConfigChanged);

    AutoExecConfig(true, "core", CORE_CFG_FOLDER);
    char apiBaseUrl[512];
    g_CoreApiBaseUrl.GetString(apiBaseUrl, sizeof(apiBaseUrl));
    LogMessage("LumiAdmin Core loaded. API base URL: %s", apiBaseUrl);
}

public void OnCoreConfigChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    InvalidateTokenCache();
}

void InvalidateTokenCache()
{
    g_CoreCachedReportToken[0] = '\0';
    g_CoreCachedReportPort = -1;
    g_CoreHasCachedReportToken = false;
}
