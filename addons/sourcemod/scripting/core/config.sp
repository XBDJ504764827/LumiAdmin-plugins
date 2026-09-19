bool GetCurrentServerPort(int &port)
{
    if (g_CoreHostPort == null)
    {
        return false;
    }
    port = g_CoreHostPort.IntValue;
    return port > 0;
}

bool GetCurrentReportToken(char[] token, int maxLen)
{
    token[0] = '\0';

    int currentPort = 0;
    if (!GetCurrentServerPort(currentPort))
    {
        return false;
    }

    if (g_CoreHasCachedReportToken && g_CoreCachedReportPort == currentPort)
    {
        strcopy(token, maxLen, g_CoreCachedReportToken);
        return true;
    }

    char portKey[16];
    IntToString(currentPort, portKey, sizeof(portKey));
    if (g_CoreServerTokenMap == null || !g_CoreServerTokenMap.GetString(portKey, token, maxLen))
    {
        // 尚无 token：触发自动识别（异步，不阻塞当前调用），同时提示管理员
        if (g_CoreAutoIdentify != null && g_CoreAutoIdentify.BoolValue)
        {
            Core_RequestIdentify(0.0);
            int now = GetTime();
            if (now - g_CoreLastNoTokenLog >= 60)
            {
                g_CoreLastNoTokenLog = now;
                LogMessage("LumiAdmin Core: no report token for port %d yet; auto-identify requested (see core_identity.cfg).", currentPort);
            }
        }
        else
        {
            LogError("LumiAdmin Core: no report token found for port %d. Add a mapping in cfg/sourcemod/lumiadmin/core.cfg: core_server \"%d\" \"<token>\"", currentPort, currentPort);
        }
        return false;
    }

    TrimString(token);
    if (token[0] == '\0')
    {
        LogError("LumiAdmin Core: report token for port %d is empty.", currentPort);
        return false;
    }

    g_CoreCachedReportPort = currentPort;
    strcopy(g_CoreCachedReportToken, sizeof(g_CoreCachedReportToken), token);
    g_CoreHasCachedReportToken = true;
    return true;
}

public Action CommandServerMapping(int args)
{
    if (args < 2)
    {
        return Plugin_Handled;
    }

    char portText[64];
    char token[CORE_MAX_SERVER_TOKEN];
    GetCmdArg(1, portText, sizeof(portText));
    GetCmdArg(2, token, sizeof(token));

    int port = StringToInt(portText);
    if (port <= 0)
    {
        LogError("LumiAdmin Core: server mapping ignored, invalid port %s.", portText);
        return Plugin_Handled;
    }

    RegisterServerTokenMapping(port, token);
    Core_MarkStaticPort(port);
    InvalidateTokenCache();
    return Plugin_Handled;
}

void RegisterServerTokenMapping(int port, const char[] token)
{
    if (port <= 0)
    {
        LogError("LumiAdmin Core: server mapping ignored, invalid port %d.", port);
        return;
    }

    char trimmedToken[CORE_MAX_SERVER_TOKEN];
    strcopy(trimmedToken, sizeof(trimmedToken), token);
    TrimString(trimmedToken);
    if (trimmedToken[0] == '\0')
    {
        LogError("LumiAdmin Core: server mapping ignored, empty token for port %d.", port);
        return;
    }

    char portKey[16];
    IntToString(port, portKey, sizeof(portKey));
    g_CoreServerTokenMap.SetString(portKey, trimmedToken);
    LogMessage("LumiAdmin Core: mapped port %d to report token.", port);
}
