/**
 * 规则拉取与匹配。
 */

void SyncRules()
{
    if (g_RGEnabled == null || !g_RGEnabled.BoolValue)
    {
        return;
    }

    HTTPRequest request = CreateJsonRequest("/abnormal-record-rules");
    if (request == null)
    {
        return;
    }

    ApplyServerHeaders(request);
    request.Get(OnRulesSynced);
}

public void OnRulesSynced(HTTPResponse response, any value, const char[] error)
{
    if (error[0] != '\0')
    {
        LogError("[lumiadmin-recordguard] Rule sync failed: %s", error);
        return;
    }

    if (response.Status < HTTPStatus_OK || response.Status >= HTTPStatus_MultipleChoices)
    {
        LogError("[lumiadmin-recordguard] Rule sync returned HTTP status %d.", response.Status);
        return;
    }

    JSONObject root = view_as<JSONObject>(response.Data);
    if (root == null)
    {
        LogError("[lumiadmin-recordguard] Rule sync returned empty JSON.");
        return;
    }

    JSON rawItems = root.Get("items");
    if (rawItems == null)
    {
        g_RuleCount = 0;
        delete root;
        return;
    }

    // L3：类型校验，返回非数组时按空规则处理
    JSONArray items = view_as<JSONArray>(rawItems);
    if (items == null)
    {
        g_RuleCount = 0;
        LogError("[lumiadmin-recordguard] rule sync items is not an array.");
        delete root;
        return;
    }
    int count = items.Length;
    if (count > MAX_RULES)
    {
        count = MAX_RULES;
    }

    g_RuleCount = 0;
    for (int i = 0; i < count; i++)
    {
        JSONObject item = view_as<JSONObject>(items.Get(i));
        if (item == null)
        {
            continue;
        }

        char mapName[128];
        if (!item.GetString("map_name", mapName, sizeof(mapName)) || mapName[0] == '\0')
        {
            delete item;
            continue;
        }

        strcopy(g_RuleMap[g_RuleCount], sizeof(g_RuleMap[]), mapName);
        TrimString(g_RuleMap[g_RuleCount]);
        LowerString(g_RuleMap[g_RuleCount]);

        g_RuleCourse[g_RuleCount] = item.GetInt("course");
        g_RuleMode[g_RuleCount][0] = '\0';
        g_RuleTimeType[g_RuleCount][0] = '\0';

        if (!item.IsNull("mode"))
        {
            item.GetString("mode", g_RuleMode[g_RuleCount], sizeof(g_RuleMode[]));
            TrimString(g_RuleMode[g_RuleCount]);
            LowerString(g_RuleMode[g_RuleCount]);
        }
        if (!item.IsNull("time_type"))
        {
            item.GetString("time_type", g_RuleTimeType[g_RuleCount], sizeof(g_RuleTimeType[]));
            TrimString(g_RuleTimeType[g_RuleCount]);
            LowerString(g_RuleTimeType[g_RuleCount]);
        }

        g_RuleThreshold[g_RuleCount] = item.GetFloat("threshold_seconds");
        if (g_RuleThreshold[g_RuleCount] <= 0.0)
        {
            delete item;
            continue;
        }
        g_RuleCount++;
        delete item;
    }
    delete items;
    delete root;

    DebugLog("synced %d abnormal record rules", g_RuleCount);
}

stock void LowerString(char[] value)
{
    for (int i = 0; value[i] != '\0'; i++)
    {
        if (value[i] >= 'A' && value[i] <= 'Z')
        {
            value[i] = view_as<char>(value[i] + 32);
        }
    }
}

bool FindMatchingThreshold(const char[] mapName, int course, const char[] mode, const char[] timeType, float &threshold)
{
    char normalizedMap[128];
    strcopy(normalizedMap, sizeof(normalizedMap), mapName);
    TrimString(normalizedMap);
    LowerString(normalizedMap);

    int bestScore = -1;
    threshold = 0.0;

    for (int i = 0; i < g_RuleCount; i++)
    {
        bool exactMap = StrEqual(g_RuleMap[i], normalizedMap, false);
        bool allMaps = StrEqual(g_RuleMap[i], "*", false);
        if (!exactMap && !allMaps)
        {
            continue;
        }

        // 精确地图规则优先于全地图默认规则；course 必须精确匹配（0=主图，1-99=奖励图）
        int score = exactMap ? 8 : 0;
        if (g_RuleCourse[i] != course)
        {
            continue;
        }
        score += 4;

        if (g_RuleMode[i][0] != '\0')
        {
            if (!StrEqual(g_RuleMode[i], mode, false))
            {
                continue;
            }
            score += 2;
        }

        if (g_RuleTimeType[i][0] != '\0')
        {
            if (!StrEqual(g_RuleTimeType[i], timeType, false))
            {
                continue;
            }
            score += 1;
        }

        if (score > bestScore)
        {
            bestScore = score;
            threshold = g_RuleThreshold[i];
        }
    }

    return bestScore >= 0 && threshold > 0.0;
}

void GetModeShortName(int mode, char[] buffer, int maxLen)
{
    switch (mode)
    {
        case Mode_Vanilla:
        {
            strcopy(buffer, maxLen, "vnl");
        }
        case Mode_SimpleKZ:
        {
            strcopy(buffer, maxLen, "skz");
        }
        case Mode_KZTimer:
        {
            strcopy(buffer, maxLen, "kzt");
        }
        default:
        {
            strcopy(buffer, maxLen, "unknown");
        }
    }
}

void GetGlobalModeNameFromShort(const char[] modeShort, char[] buffer, int maxLen)
{
    if (StrEqual(modeShort, "vnl", false))
    {
        strcopy(buffer, maxLen, "kz_vanilla");
    }
    else if (StrEqual(modeShort, "skz", false))
    {
        strcopy(buffer, maxLen, "kz_simple");
    }
    else if (StrEqual(modeShort, "kzt", false))
    {
        strcopy(buffer, maxLen, "kz_timer");
    }
    else
    {
        strcopy(buffer, maxLen, modeShort);
    }
}

void GetTimeTypeName(int timeType, char[] buffer, int maxLen)
{
    if (timeType == TimeType_Pro)
    {
        strcopy(buffer, maxLen, "pro");
    }
    else
    {
        strcopy(buffer, maxLen, "tp");
    }
}
