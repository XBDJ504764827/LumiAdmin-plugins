/**
 * 审核通过记录补交全球榜单（无录像）。
 */

void PollApprovedRecords()
{
    if (g_RGEnabled == null || !g_RGEnabled.BoolValue)
    {
        return;
    }

    HTTPRequest request = CreateJsonRequest("/abnormal-records/poll-approved");
    if (request == null)
    {
        return;
    }

    char apiBaseUrl[MAX_URL_LENGTH];
    char token[MAX_TOKEN_LENGTH];
    int port = 0;
    if (!GetApiConfig(apiBaseUrl, sizeof(apiBaseUrl), token, sizeof(token), port))
    {
        delete request;
        return;
    }

    JSONObject payload = new JSONObject();
    payload.SetString("report_token", token);
    payload.SetInt("port", port);
    payload.SetInt("limit", 5);
    request.Post(payload, OnApprovedRecordsPolled);
    delete request;
    delete payload;
}

public void OnApprovedRecordsPolled(HTTPResponse response, any value, const char[] error)
{
    if (error[0] != '\0')
    {
        LogError("[lumiadmin-recordguard] Poll approved failed: %s", error);
        return;
    }

    if (response.Status < HTTPStatus_OK || response.Status >= HTTPStatus_MultipleChoices)
    {
        LogError("[lumiadmin-recordguard] Poll approved returned HTTP status %d.", response.Status);
        return;
    }

    JSONObject root = view_as<JSONObject>(response.Data);
    JSON rawItems = root.Get("items");
    if (rawItems == null)
    {
        delete root;
        return;
    }

    JSONArray items = view_as<JSONArray>(rawItems);
    for (int i = 0; i < items.Length; i++)
    {
        JSONObject item = view_as<JSONObject>(items.Get(i));
        if (item != null)
        {
            SubmitApprovedRecord(item);
            delete item;
        }
    }
    delete items;
    delete root;
}

void SubmitApprovedRecord(JSONObject item)
{
    char recordId[MAX_RECORD_ID];
    char steamId2[32];
    char modeShort[16];
    char modeGlobal[32];

    item.GetString("id", recordId, sizeof(recordId));
    item.GetString("steam_id2", steamId2, sizeof(steamId2));
    item.GetString("mode", modeShort, sizeof(modeShort));
    GetGlobalModeNameFromShort(modeShort, modeGlobal, sizeof(modeGlobal));

    int mapId = item.GetInt("map_id");
    int course = item.GetInt("course");
    int teleports = item.GetInt("teleports");
    float runTime = item.GetFloat("run_time_seconds");

    if (recordId[0] == '\0' || steamId2[0] == '\0' || mapId <= 0)
    {
        SubmitRecordResult(recordId, false, 0, "missing steam_id2 or map_id");
        return;
    }

    // 无录像：直接补交全球记录
    DataPack pack = new DataPack();
    pack.WriteString(recordId);

    if (!GlobalAPI_CreateRecord(OnGlobalRecordCreated, pack, steamId2, mapId, modeGlobal, course, GetTickrate(), teleports, runTime))
    {
        delete pack;
        SubmitRecordResult(recordId, false, 0, "GlobalAPI_CreateRecord failed to dispatch");
    }
}

public int OnGlobalRecordCreated(JSON_Object response, GlobalAPIRequestData request, DataPack pack)
{
    pack.Reset();
    char recordId[MAX_RECORD_ID];
    pack.ReadString(recordId, sizeof(recordId));
    delete pack;

    if (request.Failure)
    {
        SubmitRecordResult(recordId, false, 0, "GlobalAPI_CreateRecord request failed");
        return 0;
    }

    int globalRecordId = response.GetInt("record_id");
    if (globalRecordId <= 0)
    {
        SubmitRecordResult(recordId, false, 0, "GlobalAPI response missing record_id");
        return 0;
    }

    SubmitRecordResult(recordId, true, globalRecordId, "");
    return 0;
}

void SubmitRecordResult(const char[] recordId, bool success, int globalRecordId, const char[] error)
{
    if (recordId[0] == '\0')
    {
        return;
    }

    char suffix[160];
    Format(suffix, sizeof(suffix), "/abnormal-records/%s/submit-result", recordId);
    HTTPRequest request = CreateJsonRequest(suffix);
    if (request == null)
    {
        return;
    }

    char apiBaseUrl[MAX_URL_LENGTH];
    char token[MAX_TOKEN_LENGTH];
    int port = 0;
    if (!GetApiConfig(apiBaseUrl, sizeof(apiBaseUrl), token, sizeof(token), port))
    {
        delete request;
        return;
    }

    JSONObject payload = new JSONObject();
    payload.SetString("report_token", token);
    payload.SetInt("port", port);
    payload.SetString("status", success ? "submitted" : "failed");
    if (success)
    {
        payload.SetInt("global_record_id", globalRecordId);
    }
    else
    {
        payload.SetString("error", error);
    }
    request.Post(payload, OnSubmitResultResponse);
    delete request;
    delete payload;
}

public void OnSubmitResultResponse(HTTPResponse response, any value, const char[] error)
{
    if (error[0] != '\0')
    {
        LogError("[lumiadmin-recordguard] Submit result failed: %s", error);
        return;
    }

    if (response.Status < HTTPStatus_OK || response.Status >= HTTPStatus_MultipleChoices)
    {
        LogError("[lumiadmin-recordguard] Submit result returned HTTP status %d.", response.Status);
    }
}
