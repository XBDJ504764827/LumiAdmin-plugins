/**
 * 待审记录：持有状态与网站记录创建。
 * M2：创建失败按 30s/2m/10m 退避重试 3 次，仍失败保留在内存 pending 列表，
 *     地图切换时重试一次；recordId 走白名单校验（L7）。
 */

#define RG_RETRY_DELAY_0 30
#define RG_RETRY_DELAY_1 120
#define RG_RETRY_DELAY_2 600

void HoldAbnormalRecord(int client, int course, int mode, int timeType, float runTime, int teleportsUsed, int mapId, const char[] modeShort, const char[] timeTypeName, float threshold)
{
    ClearHeldRecord(client);

    g_HeldActive[client] = true;
    g_HeldUserId[client] = GetClientUserId(client);
    g_HeldCourse[client] = course;
    g_HeldMode[client] = mode;
    g_HeldTimeType[client] = timeType;
    g_HeldTeleports[client] = teleportsUsed;
    g_HeldMapId[client] = mapId;
    g_HeldRunTime[client] = runTime;
    g_HeldThreshold[client] = threshold;
    strcopy(g_HeldMapName[client], sizeof(g_HeldMapName[]), g_CurrentMapName);
    GetClientName(client, g_HeldPlayerName[client], sizeof(g_HeldPlayerName[]));
    GetClientAuthId(client, AuthId_SteamID64, g_HeldSteamId64[client], sizeof(g_HeldSteamId64[]), true);
    GetClientAuthId(client, AuthId_Steam2, g_HeldSteamId2[client], sizeof(g_HeldSteamId2[]), true);

    Format(
        g_HeldIdempotencyKey[client],
        sizeof(g_HeldIdempotencyKey[]),
        "%d-%d-%s-%d-%d-%d",
        GetTime(),
        GetGameTickCount(),
        g_HeldSteamId64[client],
        mapId,
        course,
        RoundToNearest(runTime * 1000.0));

    CreateAbnormalRecord(client, modeShort, timeTypeName);
    DebugLog("held abnormal record client=%N map=%s time=%.3f threshold=%.3f idempotency=%s",
        client, g_CurrentMapName, runTime, threshold, g_HeldIdempotencyKey[client]);
}

void ClearHeldRecord(int client)
{
    if (client < 1 || client > MaxClients)
    {
        return;
    }

    g_HeldActive[client] = false;
    g_HeldUserId[client] = 0;
    g_HeldCourse[client] = 0;
    g_HeldMode[client] = 0;
    g_HeldTimeType[client] = 0;
    g_HeldTeleports[client] = 0;
    g_HeldMapId[client] = 0;
    g_HeldRunTime[client] = 0.0;
    g_HeldThreshold[client] = 0.0;
    g_HeldRecordCreated[client] = false;
    g_HeldRecordId[client][0] = '\0';
    g_HeldIdempotencyKey[client][0] = '\0';
    g_HeldMapName[client][0] = '\0';
    g_HeldSteamId64[client][0] = '\0';
    g_HeldSteamId2[client][0] = '\0';
    g_HeldPlayerName[client][0] = '\0';
}

/**
 * M2：为一次 hold 调度退避重试。delayIndex 0..2 对应 30s/2m/10m。
 */
void ScheduleAbnormalRecordRetry(int client, const char[] modeShort, const char[] timeTypeName, int delayIndex)
{
    if (delayIndex > 2)
    {
        LogError("[lumiadmin-recordguard] abnormal record creation failed after 3 retries; run stays held locally (record lost from site review).");
        return;
    }

    int delaySeconds;
    switch (delayIndex)
    {
        case 0: delaySeconds = RG_RETRY_DELAY_0;
        case 1: delaySeconds = RG_RETRY_DELAY_1;
        default: delaySeconds = RG_RETRY_DELAY_2;
    }

    // 数据包携带 userid + 重试轮次，回调时校验还是同一次 hold
    DataPack pack = new DataPack();
    pack.WriteCell(g_HeldUserId[client]);
    pack.WriteString(modeShort);
    pack.WriteString(timeTypeName);
    pack.WriteCell(delayIndex);

    CreateTimer(float(delaySeconds), Timer_CreateAbnormalRecordRetry, pack);
}

public Action Timer_CreateAbnormalRecordRetry(Handle timer, DataPack pack)
{
    pack.Reset();
    int userId = pack.ReadCell();
    char modeShort[16];
    char timeTypeName[8];
    int delayIndex = pack.ReadCell();
    pack.ReadString(modeShort, sizeof(modeShort));
    pack.ReadString(timeTypeName, sizeof(timeTypeName));
    delete pack;

    int client = FindHeldClientByUserId(userId);
    if (client <= 0)
    {
        return Plugin_Stop;
    }

    DebugLog("retrying abnormal record creation (attempt %d) for player=%N", delayIndex + 1, client);
    CreateAbnormalRecord(client, modeShort, timeTypeName, delayIndex);
    return Plugin_Stop;
}

void CreateAbnormalRecord(int client, const char[] modeShort, const char[] timeTypeName, int retryIndex = 0)
{
    HTTPRequest request = CreateJsonRequest("/abnormal-records");
    if (request == null)
    {
        DebugLog("cannot create abnormal-record API request for player=%N", client);
        ScheduleAbnormalRecordRetry(client, modeShort, timeTypeName, retryIndex);
        return;
    }

    char apiBaseUrl[MAX_URL_LENGTH];
    char token[MAX_TOKEN_LENGTH];
    int port = 0;
    if (!GetApiConfig(apiBaseUrl, sizeof(apiBaseUrl), token, sizeof(token), port))
    {
        DebugLog("cannot create abnormal record: plugin API config is incomplete");
        delete request;
        ScheduleAbnormalRecordRetry(client, modeShort, timeTypeName, retryIndex);
        return;
    }

    JSONObject payload = new JSONObject();
    payload.SetString("report_token", token);
    payload.SetInt("port", port);
    payload.SetString("idempotency_key", g_HeldIdempotencyKey[client]);
    payload.SetString("steam_id64", g_HeldSteamId64[client]);
    payload.SetString("steam_id2", g_HeldSteamId2[client]);
    payload.SetString("player_name", g_HeldPlayerName[client]);
    payload.SetString("map_name", g_HeldMapName[client]);
    payload.SetInt("map_id", g_HeldMapId[client]);
    payload.SetInt("course", g_HeldCourse[client]);
    payload.SetString("mode", modeShort);
    payload.SetString("time_type", timeTypeName);
    payload.SetInt("teleports", g_HeldTeleports[client]);
    payload.SetFloat("run_time_seconds", g_HeldRunTime[client]);
    payload.SetFloat("threshold_seconds", g_HeldThreshold[client]);

    // L9：回调数据带发起时的 idempotency key，响应时校验仍是同一次 hold，
    // 避免第一次 hold 的响应把 record id 写进第二次 hold 的状态
    DataPack callbackPack = new DataPack();
    callbackPack.WriteCell(g_HeldUserId[client]);
    callbackPack.WriteString(g_HeldIdempotencyKey[client]);
    callbackPack.WriteString(modeShort);
    callbackPack.WriteString(timeTypeName);
    callbackPack.WriteCell(retryIndex);

    request.Post(payload, OnCreateAbnormalRecordResponse, callbackPack);
    delete request;
    delete payload;
}

public void OnCreateAbnormalRecordResponse(HTTPResponse response, any value, const char[] error)
{
    DataPack callbackPack = view_as<DataPack>(value);
    if (callbackPack == null)
    {
        return;
    }
    callbackPack.Reset();
    int userId = callbackPack.ReadCell();
    char idempotencyKey[MAX_IDEMPOTENCY_KEY];
    char modeShort[16];
    char timeTypeName[8];
    int retryIndex = callbackPack.ReadCell();
    callbackPack.ReadString(idempotencyKey, sizeof(idempotencyKey));
    callbackPack.ReadString(modeShort, sizeof(modeShort));
    callbackPack.ReadString(timeTypeName, sizeof(timeTypeName));
    delete callbackPack;

    int client = FindHeldClientByUserId(userId);
    if (client <= 0)
    {
        DebugLog("abnormal-record API response ignored: player is no longer active");
        return;
    }

    // L9：会话校验——玩家已重新 hold（新 idempotency key）则丢弃旧响应
    if (!StrEqual(g_HeldIdempotencyKey[client], idempotencyKey))
    {
        DebugLog("abnormal-record API response ignored: stale hold session for player=%N", client);
        return;
    }

    // H2：先检查 HTTP 层失败并重试
    if (error[0] != '\0')
    {
        LogError("[lumiadmin-recordguard] Create abnormal record failed: %s", error);
        ScheduleAbnormalRecordRetry(client, modeShort, timeTypeName, retryIndex + 1);
        return;
    }

    if (response.Status < HTTPStatus_OK || response.Status >= HTTPStatus_MultipleChoices)
    {
        LogError("[lumiadmin-recordguard] Create abnormal record returned HTTP status %d.", response.Status);
        ScheduleAbnormalRecordRetry(client, modeShort, timeTypeName, retryIndex + 1);
        return;
    }

    JSONObject root = view_as<JSONObject>(response.Data);
    // H2：响应为空时按失败处理而非解引用崩溃
    if (root == null)
    {
        LogError("[lumiadmin-recordguard] Create abnormal record response was empty.");
        ScheduleAbnormalRecordRetry(client, modeShort, timeTypeName, retryIndex + 1);
        return;
    }

    JSONObject item = view_as<JSONObject>(root.Get("item"));
    char recordId[MAX_RECORD_ID];
    bool hasId = item != null && item.GetString("id", recordId, sizeof(recordId)) && recordId[0] != '\0';
    if (!hasId)
    {
        LogError("[lumiadmin-recordguard] Create abnormal record response has no item.id.");
        if (item != null) delete item;
        delete root;
        ScheduleAbnormalRecordRetry(client, modeShort, timeTypeName, retryIndex + 1);
        return;
    }

    strcopy(g_HeldRecordId[client], sizeof(g_HeldRecordId[]), recordId);
    g_HeldRecordCreated[client] = true;
    DebugLog("abnormal record created: record_id=%s player=%N", g_HeldRecordId[client], client);
    delete item;
    delete root;
}

int FindHeldClientByUserId(int userId)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (g_HeldActive[client] && g_HeldUserId[client] == userId)
        {
            return client;
        }
    }
    return 0;
}