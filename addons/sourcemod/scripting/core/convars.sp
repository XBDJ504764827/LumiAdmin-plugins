void Core_OnPluginStart()
{
    g_CoreApiBaseUrl = CreateConVar("core_api_base_url", CORE_DEFAULT_API_BASE_URL,
        "LumiAdmin 插件 API 地址，只填域名（如 https://你的域名），插件自动拼接 /api/plugin 路径。");
    g_CoreDebugLog = CreateConVar("core_debug", "0",
        "启用 core 调试日志。", _, true, 0.0, true, 1.0);
    g_CoreInstallKey = CreateConVar("core_install_key", "",
        "面板级安装密钥。面板设置了 PLUGIN_INSTALL_KEY 时需填写相同值；留空表示面板未启用密钥。");
    g_CoreAutoIdentify = CreateConVar("core_auto_identify", "1",
        "未配置 core_server 映射时，是否自动向面板识别本服并领取 report_token。", _, true, 0.0, true, 1.0);
    g_CoreIdentifyInterval = CreateConVar("core_identify_interval", "600",
        "自动识别成功后重新识别的间隔（秒），便于面板重置 token 后自动跟进；0 表示仅识别一次。", _, true, 0.0);
    g_CoreHostPort = FindConVar("hostport");
    if (g_CoreServerTokenMap == null)
    {
        g_CoreServerTokenMap = new StringMap();
    }
    Core_InitIdentity();

    RegServerCmd("core_server", CommandServerMapping,
        "注册一个端口->report_token 映射。可在 core.cfg 中多行配置：core_server \"27015\" \"token\"");
    RegServerCmd("lumiadmin_reidentify", CommandReidentify,
        "强制重新向面板识别本服并刷新 report_token（应急/面板重置 token 后使用）。");
    HookConVarChange(g_CoreApiBaseUrl, OnCoreConfigChanged);
    HookConVarChange(g_CoreDebugLog, OnCoreConfigChanged);
    HookConVarChange(g_CoreInstallKey, OnCoreConfigChanged);
    HookConVarChange(g_CoreAutoIdentify, OnCoreConfigChanged);

    AutoExecConfig(true, "core", CORE_CFG_FOLDER);
    Core_EnsureConfigTemplate();
    char apiBaseUrl[512];
    g_CoreApiBaseUrl.GetString(apiBaseUrl, sizeof(apiBaseUrl));
    LogMessage("LumiAdmin Core loaded. API base URL: %s", apiBaseUrl);

    Core_StartIdentify();
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
    file.WriteLine("// ===== 服务器端口 -> report_token 映射（可选）=====");
    file.WriteLine("// 默认无需填写：插件会自动向面板识别本服并领取 token，缓存在 core_identity.cfg。");
    file.WriteLine("// 仅在自动识别不可用（如面板看不到真实来源 IP）时，才需要手动配置。");
    file.WriteLine("// token 获取: LumiAdmin 后台 -> 社区组管理 -> 服务器 -> report_token");
    file.WriteLine("// 同一物理机多端口示例:");
    file.WriteLine("// core_server \"27015\" \"在此填写后台生成的report_token\"");
    file.WriteLine("// core_server \"27016\" \"在此填写后台生成的report_token\"");
    delete file;
}

public void OnCoreConfigChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    InvalidateTokenCache();

    // 安装密钥或开关变化后重新识别一次
    if (convar == g_CoreInstallKey || convar == g_CoreAutoIdentify)
    {
        Core_RequestIdentify(1.0);
    }
}

void InvalidateTokenCache()
{
    g_CoreCachedReportToken[0] = '\0';
    g_CoreCachedReportPort = -1;
    g_CoreHasCachedReportToken = false;
}
