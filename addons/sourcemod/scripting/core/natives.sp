public int Native_GetApiBaseUrl(Handle plugin, int numParams)
{
    int maxLen = GetNativeCell(2);
    char apiBaseUrl[512];
    if (g_CoreApiBaseUrl != null)
    {
        g_CoreApiBaseUrl.GetString(apiBaseUrl, sizeof(apiBaseUrl));
    }
    TrimString(apiBaseUrl);
    SetNativeString(1, apiBaseUrl, maxLen);
    return apiBaseUrl[0] != '\0' ? 1 : 0;
}

public int Native_GetReportToken(Handle plugin, int numParams)
{
    int maxLen = GetNativeCell(2);
    char token[CORE_MAX_SERVER_TOKEN];
    if (!GetCurrentReportToken(token, sizeof(token)))
    {
        SetNativeString(1, "", maxLen);
        return 0;
    }
    SetNativeString(1, token, maxLen);
    return 1;
}

public int Native_GetServerPort(Handle plugin, int numParams)
{
    int port = 0;
    if (!GetCurrentServerPort(port))
    {
        return 0;
    }
    return port;
}

public int Native_IsDebugEnabled(Handle plugin, int numParams)
{
    return (g_CoreDebugLog != null && g_CoreDebugLog.BoolValue) ? 1 : 0;
}

public int Native_GetServerId(Handle plugin, int numParams)
{
    int maxLen = GetNativeCell(2);
    if (g_CoreServerId[0] == '\0')
    {
        SetNativeString(1, "", maxLen);
        return 0;
    }
    SetNativeString(1, g_CoreServerId, maxLen);
    return 1;
}
