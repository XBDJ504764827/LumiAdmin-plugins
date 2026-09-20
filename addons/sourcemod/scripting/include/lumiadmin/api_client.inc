#if defined _lumiadmin_api_client_included
#endinput
#endif
#define _lumiadmin_api_client_included

/**
 * LumiAdmin 插件公共 HTTP/配置工具（stock，各插件独立编译时内联）。
 *
 * - LumiReadCoreConfigCached：core 插件不可用时读取 core.cfg，
 *   失败结果做 60s 负缓存，避免 cfg 缺失时每个请求周期都重读文件（ISSUES L1）。
 * - LumiBuildPluginApiUrl：统一去尾斜杠 + /api/plugin 前缀。
 */

#define LUMI_CONFIG_NEGATIVE_CACHE_SECONDS 60

stock bool LumiReadCoreConfigCached(char[] apiBaseUrl, int apiMaxLen, int &port, char[] token, int tokenMaxLen)
{
    static int lastFailTime = 0;

    int now = GetTime();
    if (lastFailTime != 0 && now - lastFailTime < LUMI_CONFIG_NEGATIVE_CACHE_SECONDS)
    {
        return false;
    }

    bool ok = ReadCoreConfigFile(apiBaseUrl, apiMaxLen, port, token, tokenMaxLen);
    if (!ok)
    {
        if (lastFailTime == 0)
        {
            lastFailTime = now;
        }
        return false;
    }

    lastFailTime = 0;
    return true;
}

/**
 * 构建插件 API URL：base + /api/plugin + suffix。
 * baseUrl 来源：core 插件 native，降级读 core.cfg（带负缓存）。
 */
stock bool LumiBuildPluginApiUrl(char[] url, int urlMaxLen, const char[] suffix)
{
    char baseUrl[512];
    baseUrl[0] = '\0';

    if (LibraryExists("core"))
    {
        Core_GetApiBaseUrl(baseUrl, sizeof(baseUrl));
    }
    TrimString(baseUrl);

    if (baseUrl[0] == '\0')
    {
        char fileToken[CORE_PARSE_MAX_TOKEN];
        int filePort = 0;
        LumiReadCoreConfigCached(baseUrl, sizeof(baseUrl), filePort, fileToken, sizeof(fileToken));
        TrimString(baseUrl);
    }

    if (baseUrl[0] == '\0')
    {
        url[0] = '\0';
        return false;
    }

    int len = strlen(baseUrl);
    while (len > 0 && baseUrl[len - 1] == '/')
    {
        baseUrl[--len] = '\0';
    }

    Format(url, urlMaxLen, "%s/api/plugin%s", baseUrl, suffix);
    return true;
}

/**
 * RIPExt 安全取值封装：`JSONObject.GetBool/GetInt/GetFloat/Get/IsNull`
 * 在 key 缺失时会抛 "Could not retrieve value for key" 异常，
 * 这里统一先用 HasKey 探测，缺失则返回默认值。
 *
 * GetString 本身返回 bool 不抛异常，可直接使用。
 */
stock bool LumiJsonGetBool(JSONObject obj, const char[] key, bool defaultValue = false)
{
    if (obj == null || !obj.HasKey(key) || obj.IsNull(key))
    {
        return defaultValue;
    }
    return obj.GetBool(key);
}

stock int LumiJsonGetInt(JSONObject obj, const char[] key, int defaultValue = 0)
{
    if (obj == null || !obj.HasKey(key) || obj.IsNull(key))
    {
        return defaultValue;
    }
    return obj.GetInt(key);
}

stock float LumiJsonGetFloat(JSONObject obj, const char[] key, float defaultValue = 0.0)
{
    if (obj == null || !obj.HasKey(key) || obj.IsNull(key))
    {
        return defaultValue;
    }
    return obj.GetFloat(key);
}

/** 安全获取嵌套对象/数组；缺失或类型不符时返回 null（调用方自行判空）。 */
stock JSON LumiJsonGet(JSONObject obj, const char[] key)
{
    if (obj == null || !obj.HasKey(key) || obj.IsNull(key))
    {
        return null;
    }
    return obj.Get(key);
}