#if defined _lumiadmin_config_parse_included
#endinput
#endif
#define _lumiadmin_config_parse_included

#if !defined CORE_PARSE_MAX_TOKEN
#define CORE_PARSE_MAX_TOKEN 256
#endif

/**
 * LumiAdmin 配置文件解析工具（stock 函数，各插件独立编译时使用）。
 * 用于无 core 插件时直接读取 cfg/sourcemod/lumiadmin/core.cfg 降级运行。
 */

/**
 * 从配置行中提取引号内的值。
 * 行格式: key "value"
 */
stock bool ParseConfigValueLine(const char[] line, const char[] key, char[] value, int maxLen)
{
    value[0] = '\0';
    if (StrContains(line, key, false) != 0)
    {
        return false;
    }

    int firstQuote = FindCharInString(line, '"');
    if (firstQuote < 0)
    {
        return false;
    }

    int secondQuote = FindCharInString(line[firstQuote + 1], '"');
    if (secondQuote < 0)
    {
        return false;
    }
    secondQuote += firstQuote + 1;

    int copyLength = secondQuote - firstQuote - 1;
    if (copyLength >= maxLen)
    {
        copyLength = maxLen - 1;
    }

    for (int i = 0; i < copyLength; i++)
    {
        value[i] = line[firstQuote + 1 + i];
    }
    value[copyLength] = '\0';
    return true;
}

/**
 * 从配置行中提取引号内的值，并返回第二个引号之后的偏移量。
 */
stock bool CopyQuotedValue(const char[] line, int firstQuote, char[] value, int maxLen, int &nextOffset)
{
    value[0] = '\0';

    int secondQuote = FindCharInString(line[firstQuote + 1], '"');
    if (secondQuote < 0)
    {
        return false;
    }
    secondQuote += firstQuote + 1;

    int copyLength = secondQuote - firstQuote - 1;
    if (copyLength >= maxLen)
    {
        copyLength = maxLen - 1;
    }

    for (int i = 0; i < copyLength; i++)
    {
        value[i] = line[firstQuote + 1 + i];
    }
    value[copyLength] = '\0';
    nextOffset = secondQuote + 1;
    return true;
}

/**
 * 解析 core_server 配置行，提取端口和 token。
 * 行格式: core_server "port" "token"
 */
stock bool ParseCoreServerMappingLine(const char[] line, int &port, char[] token, int tokenMaxLen)
{
    return ParsePortTokenMappingLine(line, "core_server", port, token, tokenMaxLen);
}

/**
 * 解析「端口 -> token」配置行（可指定 key，支持 core_server / core_identity）。
 * 行格式: <key> "port" "token"
 * 要求 key 之后必须是空白或引号，避免 core_identity 误匹配 core_identity_id。
 */
stock bool ParsePortTokenMappingLine(const char[] line, const char[] key, int &port, char[] token, int tokenMaxLen)
{
    token[0] = '\0';
    port = 0;

    int keyLen = strlen(key);
    if (keyLen <= 0 || strncmp(line, key, keyLen, false) != 0)
    {
        return false;
    }

    int boundary = line[keyLen];
    if (boundary != '\0' && boundary != ' ' && boundary != '\t' && boundary != '"')
    {
        return false;
    }

    int firstQuote = FindCharInString(line, '"');
    if (firstQuote < 0)
    {
        return false;
    }

    char portText[16];
    int nextOffset = 0;
    if (!CopyQuotedValue(line, firstQuote, portText, sizeof(portText), nextOffset))
    {
        return false;
    }

    int tokenQuote = FindCharInString(line[nextOffset], '"');
    if (tokenQuote < 0)
    {
        return false;
    }
    tokenQuote += nextOffset;

    if (!CopyQuotedValue(line, tokenQuote, token, tokenMaxLen, nextOffset))
    {
        return false;
    }

    port = StringToInt(portText);
    TrimString(token);
    return port > 0;
}

/**
 * 读取插件自动识别后写入的 core_identity.cfg，补充当前端口对应的 token。
 * 配置路径: csgo/cfg/sourcemod/lumiadmin/core_identity.cfg
 */
stock bool ReadCoreIdentityToken(int currentPort, char[] token, int tokenMaxLen)
{
    token[0] = '\0';
    if (currentPort <= 0)
    {
        return false;
    }

    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "../../cfg/sourcemod/lumiadmin/core_identity.cfg");

    File file = OpenFile(path, "r");
    if (file == null)
    {
        return false;
    }

    bool found = false;
    char line[512];
    while (!file.EndOfFile() && file.ReadLine(line, sizeof(line)))
    {
        TrimString(line);
        if (line[0] == '\0' || (line[0] == '/' && line[1] == '/'))
        {
            continue;
        }

        int linePort = 0;
        char lineToken[CORE_PARSE_MAX_TOKEN];
        if (ParsePortTokenMappingLine(line, "core_identity", linePort, lineToken, sizeof(lineToken)) && linePort == currentPort)
        {
            strcopy(token, tokenMaxLen, lineToken);
            found = true;
            break;
        }
    }

    delete file;
    return found;
}

/**
 * 无 core 插件时读取 core.cfg 文件获取 API 地址、当前端口对应的 token。
 * 配置路径: csgo/cfg/sourcemod/lumiadmin/core.cfg
 */
stock bool ReadCoreConfigFile(char[] apiBaseUrl, int apiMaxLen, int &port, char[] token, int tokenMaxLen)
{
    apiBaseUrl[0] = '\0';
    token[0] = '\0';
    port = 0;

    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "../../cfg/sourcemod/lumiadmin/core.cfg");

    File file = OpenFile(path, "r");
    if (file == null)
    {
        return false;
    }

    int currentPort = 0;
    ConVar hostport = FindConVar("hostport");
    if (hostport != null)
    {
        currentPort = hostport.IntValue;
    }

    char line[512];
    while (!file.EndOfFile() && file.ReadLine(line, sizeof(line)))
    {
        TrimString(line);
        if (line[0] == '\0' || (line[0] == '/' && line[1] == '/'))
        {
            continue;
        }

        char value[256];
        if (apiBaseUrl[0] == '\0' && ParseConfigValueLine(line, "core_api_base_url", value, sizeof(value)))
        {
            strcopy(apiBaseUrl, apiMaxLen, value);
            continue;
        }

        if (port <= 0 && currentPort > 0)
        {
            int linePort = 0;
            char lineToken[CORE_PARSE_MAX_TOKEN];
            if (ParseCoreServerMappingLine(line, linePort, lineToken, sizeof(lineToken)) && linePort == currentPort)
            {
                port = linePort;
                strcopy(token, tokenMaxLen, lineToken);
            }
        }
    }

    delete file;

    TrimString(apiBaseUrl);
    TrimString(token);

    // core.cfg 未配置该端口时，回退到插件自识别写入的 core_identity.cfg
    if (token[0] == '\0' && currentPort > 0)
    {
        ReadCoreIdentityToken(currentPort, token, tokenMaxLen);
        port = token[0] != '\0' ? currentPort : 0;
    }

    return apiBaseUrl[0] != '\0' && port > 0 && token[0] != '\0';
}
