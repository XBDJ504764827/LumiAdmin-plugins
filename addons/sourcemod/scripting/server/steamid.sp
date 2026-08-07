/**
 * SteamID 解析与转换工具（SteamID2/SteamID3 ↔ SteamID64）。
 */

bool IsDecimalString(const char[] value)
{
    int len = strlen(value);
    if (len == 0)
    {
        return false;
    }

    for (int i = 0; i < len; i++)
    {
        if (value[i] < '0' || value[i] > '9')
        {
            return false;
        }
    }
    return true;
}

bool IsSteamId64String(const char[] steamId)
{
    return strlen(steamId) == 17 && StrContains(steamId, "7656119") == 0 && IsDecimalString(steamId);
}

bool IsIpAddressTarget(const char[] target)
{
    int len = strlen(target);
    bool hasDot = false;
    bool hasDigit = false;

    for (int i = 0; i < len; i++)
    {
        if (target[i] >= '0' && target[i] <= '9')
        {
            hasDigit = true;
            continue;
        }

        if (target[i] == '.')
        {
            hasDot = true;
            continue;
        }

        return false;
    }

    return hasDot && hasDigit;
}

bool AppendCharToString(char[] value, int maxLen, int ch)
{
    int len = strlen(value);
    if (len >= maxLen - 1)
    {
        return false;
    }

    value[len] = ch;
    value[len + 1] = '\0';
    return true;
}

void CopyStringRange(const char[] source, int start, int endExclusive, char[] dest, int maxLen)
{
    int destIdx = 0;
    for (int i = start; i < endExclusive && destIdx < maxLen - 1; i++)
    {
        dest[destIdx] = source[i];
        destIdx++;
    }
    dest[destIdx] = '\0';
}

void DecimalAddStrings(const char[] left, const char[] right, char[] output, int maxLen)
{
    char reversed[64];
    int reversedLen = 0;
    int i = strlen(left) - 1;
    int j = strlen(right) - 1;
    int carry = 0;

    while ((i >= 0 || j >= 0 || carry > 0) && reversedLen < sizeof(reversed) - 1)
    {
        int sum = carry;
        if (i >= 0)
        {
            sum += left[i] - '0';
            i--;
        }
        if (j >= 0)
        {
            sum += right[j] - '0';
            j--;
        }

        reversed[reversedLen] = (sum % 10) + '0';
        reversedLen++;
        carry = sum / 10;
    }

    int outIdx = 0;
    for (int k = reversedLen - 1; k >= 0 && outIdx < maxLen - 1; k--)
    {
        output[outIdx] = reversed[k];
        outIdx++;
    }
    output[outIdx] = '\0';
}

void DecimalMultiplyByTwoAndAddSmall(const char[] decimal, int addValue, char[] output, int maxLen)
{
    char reversed[64];
    int reversedLen = 0;
    int carry = addValue;

    for (int i = strlen(decimal) - 1; i >= 0 && reversedLen < sizeof(reversed) - 1; i--)
    {
        int value = (decimal[i] - '0') * 2 + carry;
        reversed[reversedLen] = (value % 10) + '0';
        reversedLen++;
        carry = value / 10;
    }

    while (carry > 0 && reversedLen < sizeof(reversed) - 1)
    {
        reversed[reversedLen] = (carry % 10) + '0';
        reversedLen++;
        carry /= 10;
    }

    int outIdx = 0;
    for (int k = reversedLen - 1; k >= 0 && outIdx < maxLen - 1; k--)
    {
        output[outIdx] = reversed[k];
        outIdx++;
    }
    output[outIdx] = '\0';
}

bool ConvertSteam2ToSteamId64(const char[] steamId2, char[] steamId64, int maxLen)
{
    if (StrContains(steamId2, "STEAM_", false) != 0)
    {
        return false;
    }

    int firstColon = FindCharInString(steamId2, ':');
    if (firstColon == -1)
    {
        return false;
    }

    int secondColon = -1;
    int len = strlen(steamId2);
    for (int i = firstColon + 1; i < len; i++)
    {
        if (steamId2[i] == ':')
        {
            secondColon = i;
            break;
        }
    }
    if (secondColon == -1)
    {
        return false;
    }

    char universe[8];
    char yPart[4];
    char zPart[32];
    CopyStringRange(steamId2, 6, firstColon, universe, sizeof(universe));
    CopyStringRange(steamId2, firstColon + 1, secondColon, yPart, sizeof(yPart));
    CopyStringRange(steamId2, secondColon + 1, len, zPart, sizeof(zPart));

    if (!IsDecimalString(universe) || !IsDecimalString(yPart) || !IsDecimalString(zPart))
    {
        return false;
    }

    int y = StringToInt(yPart);
    if (y < 0 || y > 1)
    {
        return false;
    }

    char accountId[32];
    DecimalMultiplyByTwoAndAddSmall(zPart, y, accountId, sizeof(accountId));
    DecimalAddStrings("76561197960265728", accountId, steamId64, maxLen);
    return IsSteamId64String(steamId64);
}

bool ConvertSteam3ToSteamId64(const char[] steamId3, char[] steamId64, int maxLen)
{
    int len = strlen(steamId3);
    if (len <= 6 || StrContains(steamId3, "[U:1:") != 0 || steamId3[len - 1] != ']')
    {
        return false;
    }

    char accountId[32];
    CopyStringRange(steamId3, 5, len - 1, accountId, sizeof(accountId));
    if (!IsDecimalString(accountId))
    {
        return false;
    }

    DecimalAddStrings("76561197960265728", accountId, steamId64, maxLen);
    return IsSteamId64String(steamId64);
}

bool NormalizePluginSteamId(const char[] input, char[] steamId64, int maxLen)
{
    char value[128];
    strcopy(value, sizeof(value), input);
    TrimString(value);

    if (IsSteamId64String(value))
    {
        strcopy(steamId64, maxLen, value);
        return true;
    }

    if (ConvertSteam2ToSteamId64(value, steamId64, maxLen))
    {
        return true;
    }

    if (ConvertSteam3ToSteamId64(value, steamId64, maxLen))
    {
        return true;
    }

    return false;
}

bool SteamId2SegmentHasValue(int segment, const char[] universe, const char[] yPart, const char[] zPart)
{
    if (segment == 0)
    {
        return universe[0] != '\0';
    }
    if (segment == 1)
    {
        return yPart[0] != '\0';
    }
    return zPart[0] != '\0';
}

bool AppendSteamId2SegmentDigit(int segment, int digit, char[] universe, int universeMaxLen, char[] yPart, int yMaxLen, char[] zPart, int zMaxLen)
{
    if (segment == 0)
    {
        return AppendCharToString(universe, universeMaxLen, digit);
    }
    if (segment == 1)
    {
        return AppendCharToString(yPart, yMaxLen, digit);
    }
    if (segment == 2)
    {
        return AppendCharToString(zPart, zMaxLen, digit);
    }
    return false;
}

/**
 * 从命令行读取被聊天框拆分的 SteamID2（STEAM_X:Y:Z 的冒号可能被拆为独立参数）。
 */
bool ReadSteamId2CommandTarget(int firstArg, int args, char[] steamId2, int maxLen, int &nextArg)
{
    char part[64];
    GetCmdArg(firstArg, part, sizeof(part));
    if (StrContains(part, "STEAM_", false) != 0)
    {
        return false;
    }

    char universe[8] = "";
    char yPart[4] = "";
    char zPart[32] = "";
    int segment = 0;

    for (int arg = firstArg; arg <= args; arg++)
    {
        GetCmdArg(arg, part, sizeof(part));
        int start = 0;
        if (arg == firstArg)
        {
            start = 6;
        }
        else if (part[0] != ':' && segment < 2 && SteamId2SegmentHasValue(segment, universe, yPart, zPart))
        {
            segment++;
        }

        int len = strlen(part);
        for (int i = start; i < len; i++)
        {
            if (part[i] == ':')
            {
                if (segment >= 2)
                {
                    return false;
                }
                segment++;
                continue;
            }

            if (part[i] < '0' || part[i] > '9')
            {
                return false;
            }

            if (!AppendSteamId2SegmentDigit(segment, part[i], universe, sizeof(universe), yPart, sizeof(yPart), zPart, sizeof(zPart)))
            {
                return false;
            }
        }

        if (universe[0] != '\0' && yPart[0] != '\0' && zPart[0] != '\0')
        {
            char normalizedSteamId2[64];
            Format(normalizedSteamId2, sizeof(normalizedSteamId2), "STEAM_%s:%s:%s", universe, yPart, zPart);
            char steamId64[64];
            if (!ConvertSteam2ToSteamId64(normalizedSteamId2, steamId64, sizeof(steamId64)))
            {
                return false;
            }

            strcopy(steamId2, maxLen, normalizedSteamId2);
            nextArg = arg + 1;
            return true;
        }
    }

    return false;
}

/**
 * 按 SteamID2 的 Y:Z 部分查找在线玩家（忽略 universe 差异）。
 */
int FindClientBySteamId2(const char[] steamId2)
{
    char inputYz[64];
    int firstColon = FindCharInString(steamId2, ':');
    if (firstColon == -1)
    {
        return -1;
    }
    strcopy(inputYz, sizeof(inputYz), steamId2[firstColon + 1]);

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
        {
            continue;
        }

        char clientSteamId2[64];
        if (GetClientAuthId(i, AuthId_Steam2, clientSteamId2, sizeof(clientSteamId2), true))
        {
            int clientFirstColon = FindCharInString(clientSteamId2, ':');
            if (clientFirstColon != -1 && StrEqual(clientSteamId2[clientFirstColon + 1], inputYz, false))
            {
                return i;
            }
        }
    }
    return -1;
}

void AppendCommandReason(int startArg, int args, char[] reason, int maxLen)
{
    reason[0] = '\0';
    for (int i = startArg; i <= args; i++)
    {
        char part[192];
        GetCmdArg(i, part, sizeof(part));
        if (reason[0] != '\0')
        {
            StrCat(reason, maxLen, " ");
        }
        StrCat(reason, maxLen, part);
    }

    if (reason[0] == '\0')
    {
        strcopy(reason, maxLen, "未填写");
    }
}
