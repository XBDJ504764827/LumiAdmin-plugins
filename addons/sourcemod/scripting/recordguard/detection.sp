/**
 * 异常检测与拦截。
 */

public int Native_ShouldHoldRecord(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    int course = GetNativeCell(2);
    int mode = GetNativeCell(3);
    int timeType = GetNativeCell(4);
    float runTime = GetNativeCell(5);
    int teleportsUsed = GetNativeCell(6);
    int mapId = GetNativeCell(7);

    return ShouldHoldRecord(client, course, mode, timeType, runTime, teleportsUsed, mapId);
}

public int Native_IsHoldingClient(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    return client >= 1 && client <= MaxClients && g_HeldActive[client];
}

bool ShouldHoldRecord(int client, int course, int mode, int timeType, float runTime, int teleportsUsed, int mapId)
{
    if (g_RGEnabled == null || !g_RGEnabled.BoolValue)
    {
        return false;
    }
    if (!IsValidClient(client) || IsFakeClient(client))
    {
        return false;
    }

    char modeShort[16];
    GetModeShortName(mode, modeShort, sizeof(modeShort));

    char timeTypeName[8];
    GetTimeTypeName(timeType, timeTypeName, sizeof(timeTypeName));

    float threshold = 0.0;
    if (!FindMatchingThreshold(g_CurrentMapName, course, modeShort, timeTypeName, threshold))
    {
        return false;
    }

    if (runTime > threshold)
    {
        return false;
    }

    HoldAbnormalRecord(client, course, mode, timeType, runTime, teleportsUsed, mapId, modeShort, timeTypeName, threshold);
    return true;
}
