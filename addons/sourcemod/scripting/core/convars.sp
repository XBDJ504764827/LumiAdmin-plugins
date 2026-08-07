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
    Core_EnsureConfigTemplate();
    char apiBaseUrl[512];
    g_CoreApiBaseUrl.GetString(apiBaseUrl, sizeof(apiBaseUrl));
    LogMessage("LumiAdmin Core loaded. API base URL: %s", apiBaseUrl);
}

/**
 * AutoExecConfig 生成的 core.cfg 只包含 ConVar，不包含服务器命令 core_server。
 * 首次生成后在此追加端口->token 映射的示例与说明，方便用户直接编辑。
 */
void Core_EnsureConfigTemplate()
{
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "../../cfg/sourcemod/lumiadmin/core.cfg");

    File file = OpenFile(path, "r");
    if (file == null)
    {
        return;
    }

    // 已包含 core_server 说明则跳过（用户已编辑过）
    bool hasServerSection = false;
    char line[512];
    while (!file.EndOfFile() && file.ReadLine(line, sizeof(line)))
    {
        if (StrContains(line, "core_server", false) != -1)
        {
            hasServerSection = true;
            break;
        }
    }
    delete file;

    if (hasServerSection)
    {
        return;
    }

    file = OpenFile(path, "a");
    if (file == null)
    {
        return;
    }

    file.WriteLine("");
    file.WriteLine("// ===== 服务器端口 -> report_token 映射 =====");
    file.WriteLine("// 每个游戏服一行，端口必须与服务器 hostport 一致");
    file.WriteLine("// token 获取: LumiAdmin 后台 -> 社区组管理 -> 服务器 -> report_token");
    file.WriteLine("// 同一物理机多端口示例:");
    file.WriteLine("// core_server \"27015\" \"在此填写后台生成的report_token\"");
    file.WriteLine("// core_server \"27016\" \"在此填写后台生成的report_token\"");
    delete file;
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
