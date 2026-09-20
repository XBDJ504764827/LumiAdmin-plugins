/**
 * 审核通过记录补交全球榜单（无录像）。
 * M3：GlobalAPI 失败退避重试后再标 failed；L7：recordId 白名单校验；L3：JSON 类型校验。
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
    // RIPExt 自动释放 request 句柄，只释放 payload
    request.Post(payload, OnApprovedRecordsPolled);
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
    if (root == null)
    {
        LogError("[lumiadmin-recordguard] Poll approved response was empty.");
        return;
    }

    JSON rawItems = root.Get("items");
    if (rawItems == null)
    {
        delete root;
        return;
    }

    // L3：类型校验，返回非数组时按失败处理
    JSONArray items = view_as<JSONArray>(rawItems);
    if (items == null)
    {
        LogError("[lumiadmin-recordguard] Poll approved items is not an array.");
        delete root;
        return;
    }

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

/**
 * L7：服务端返回的 recordId 白名单校验（字母数字与短横线），防止破坏 URL。
 */
bool IsValidRecordId(const char[] recordId)
{
    if (recordId[0] == '\0')
    {
        return false;
    }
    for (int i = 0; recordId[i] != '\0'; i++)
    {
        char c = recordId[i];
        bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-';
        if (!ok)
        {
            return false;
        }
    }
    return true;
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

    if (!IsValidRecordId(recordId) || steamId2[0] == '\0' || mapId <= 0)
    {
        if (IsValidRecordId(recordId))
        {
            SubmitRecordResult(recordId, false, 0, "missing steam_id2 or map_id");
        }
        else
        {
            LogError("[lumiadmin-recordguard] approved record has invalid id, dropped.");
        }
        return;
    }

    // 无录像：直接补交全球记录
    DataPack pack = new DataPack();
    pack.WriteString(recordId);
    pack.WriteCell(0); // M3：重试轮次

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
    int retryIndex = pack.ReadCell();
    delete pack;

    if (request.Failure)
    {
        // M3：失败不再立即终态。前 3 次只上报瞬时错误状态（不写 failed），
        // 站点保持待审状态，下个轮询周期会重新下发补交
        if (retryIndex < 3)
        {
            LogError("[lumiadmin-recordguard] GlobalAPI create record failed for %s (attempt %d/3); record stays pending, site will re-dispatch on next poll.", recordId, retryIndex + 1);
            SubmitRecordResultTransient(recordId, "GlobalAPI request failed, retrying via poll");
            return 0;
        }
        SubmitRecordResult(recordId, false, 0, "GlobalAPI_CreateRecord request failed after retries");
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
    if (!IsValidRecordId(recordId))
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
    // RIPExt 自动释放 request 句柄，只释放 payload
    request.Post(payload, OnSubmitResultResponse);
    delete payload;
}

/**
 * M3：上报瞬时错误但不终态化——status 保持待审，站点下个轮询周期重新下发。
 */
void SubmitRecordResultTransient(const char[] recordId, const char[] error)
{
    if (!IsValidRecordId(recordId))
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
    payload.SetString("status", "pending");
    payload.SetString("error", error);
    // RIPExt 自动释放 request 句柄，只释放 payload
    request.Post(payload, OnSubmitResultResponse);
    delete payload;
}

/**
 * M3：上报瞬时错误但不终态化——status 保持待审，站点下个轮询周期重新下发。
 */
void SubmitRecordResultTransient(const char[] recordId, const char[] error)
{
    if (!IsValidRecordId(recordId))
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
    payload.SetString("status", "pending");
    payload.SetString("error", error);
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