/**
 * 安全格式化整数到 SQL 字符串，负数输出 "0"。
 */
void SafeIntToString(int value, char[] buffer, int maxLen)
{
    if (value < 0) value = 0;
    IntToString(value, buffer, maxLen);
}

void InitSyncDb()
{
    char error[256];
    g_SyncDb = SQLite_UseDatabase(SYNC_DB, error, sizeof(error));
    if (g_SyncDb == null)
    {
        LogError("[LumiAdmin Sync] SQLite open failed: %s", error);
        return;
    }

    // 离线操作队列表
    SQL_FastQuery(g_SyncDb, "CREATE TABLE IF NOT EXISTS offline_queue (id INTEGER PRIMARY KEY AUTOINCREMENT, operation TEXT NOT NULL, target TEXT NOT NULL, target_type TEXT NOT NULL, player_name TEXT, reason TEXT, duration_minutes INTEGER, operator_name TEXT NOT NULL, operator_steamid TEXT, server_port INTEGER NOT NULL, created_at INTEGER NOT NULL, status TEXT NOT NULL, synced_at INTEGER, sync_error TEXT, retry_count INTEGER DEFAULT 0, idempotency_key TEXT NOT NULL)");
    SQL_FastQuery(g_SyncDb, "CREATE UNIQUE INDEX IF NOT EXISTS idx_offline_queue_idempotency_key ON offline_queue(idempotency_key)");

    // 本地审计日志表
    SQL_FastQuery(g_SyncDb, "CREATE TABLE IF NOT EXISTS audit_log (id INTEGER PRIMARY KEY AUTOINCREMENT, operation TEXT NOT NULL, target TEXT NOT NULL, operator_name TEXT NOT NULL, operator_steamid TEXT, server_port INTEGER NOT NULL, success INTEGER NOT NULL, message TEXT, created_at INTEGER NOT NULL)");

    UpdatePendingCount();
    CleanupStaleRecords();
}

void UpdatePendingCount()
{
    if (g_SyncDb == null) return;

    DBResultSet results = SQL_Query(g_SyncDb, "SELECT COUNT(*) FROM offline_queue WHERE status = 'pending' AND retry_count < %d", MAX_RETRY_COUNT);
    if (results != null)
    {
        if (SQL_FetchRow(results))
        {
            g_PendingCount = SQL_FetchInt(results, 0);
        }
        delete results;
    }
}

void CleanupStaleRecords()
{
    if (g_SyncDb == null) return;

    int cutoff = GetTime() - CLEANUP_RETENTION_SECONDS;

    char query[256];
    Format(query, sizeof(query), "DELETE FROM offline_queue WHERE status IN ('synced', 'failed') AND created_at < %d", cutoff);
    SQL_FastQuery(g_SyncDb, query);

    Format(query, sizeof(query), "DELETE FROM audit_log WHERE created_at < %d", cutoff);
    SQL_FastQuery(g_SyncDb, query);
}

bool EscapeSqlString(Database db, const char[] value, char[] escaped, int maxLen)
{
    escaped[0] = '\0';
    return SQL_EscapeString(db, value, escaped, maxLen);
}

bool ExecuteSql(Database db, const char[] query, const char[] context)
{
    if (SQL_FastQuery(db, query))
    {
        return true;
    }
    LogError("[LumiAdmin Sync] SQL failed in %s.", context);
    return false;
}

/**
 * 添加操作到离线队列。
 * @param operation 操作类型: ban, unban, whitelist_add, whitelist_remove
 * @param target 目标 (SteamID64 或 IP)
 * @param targetType 目标类型: steam 或 ip
 * @param playerName 玩家名称（可选）
 * @param reason 原因（可选）
 * @param durationMinutes 封禁时长（分钟，0=永久）
 * @param operatorName 操作人名称
 * @param operatorSteamid 操作人SteamID（可选）
 * @return 操作ID，失败返回 -1
 */
int EnqueueOperation(
    const char[] operation,
    const char[] target,
    const char[] targetType,
    const char[] playerName,
    const char[] reason,
    int durationMinutes,
    const char[] operatorName,
    const char[] operatorSteamid
)
{
    if (g_SyncDb == null) return -1;

    // 生成幂等键
    char idempotencyKey[MAX_IDEMPOTENCY_KEY];
    Format(idempotencyKey, sizeof(idempotencyKey), "%d_%d_%s_%s_%d",
        GetTime(), ++g_OperationSeq, operation, target, g_ServerPort);

    if (durationMinutes < 0)
    {
        LogError("[LumiAdmin Sync] EnqueueOperation rejected: negative duration_minutes %d.", durationMinutes);
        return -1;
    }

    if (g_ServerPort <= 0)
    {
        LogError("[LumiAdmin Sync] EnqueueOperation rejected: invalid server_port %d.", g_ServerPort);
        return -1;
    }

    char escapedTarget[256];
    char escapedPlayerName[256];
    char escapedReason[512];
    char escapedOperatorName[256];
    char escapedOperatorSteamid[256];
    char escapedIdempotencyKey[MAX_IDEMPOTENCY_KEY];

    EscapeSqlString(g_SyncDb, target, escapedTarget, sizeof(escapedTarget));
    EscapeSqlString(g_SyncDb, playerName, escapedPlayerName, sizeof(escapedPlayerName));
    EscapeSqlString(g_SyncDb, reason, escapedReason, sizeof(escapedReason));
    EscapeSqlString(g_SyncDb, operatorName, escapedOperatorName, sizeof(escapedOperatorName));
    EscapeSqlString(g_SyncDb, operatorSteamid, escapedOperatorSteamid, sizeof(escapedOperatorSteamid));
    EscapeSqlString(g_SyncDb, idempotencyKey, escapedIdempotencyKey, sizeof(escapedIdempotencyKey));

    char query[2048];
    char portBuf[16];
    char timeBuf[16];
    SafeIntToString(g_ServerPort, portBuf, sizeof(portBuf));
    SafeIntToString(GetTime(), timeBuf, sizeof(timeBuf));

    Format(query, sizeof(query), "INSERT INTO offline_queue (operation, target, target_type, player_name, reason, duration_minutes, operator_name, operator_steamid, server_port, created_at, status, idempotency_key) VALUES ('%s', '%s', '%s', '%s', '%s', %d, '%s', '%s', %s, %s, 'pending', '%s')", operation, escapedTarget, targetType, escapedPlayerName, escapedReason, durationMinutes, escapedOperatorName, escapedOperatorSteamid, portBuf, timeBuf, escapedIdempotencyKey);

    if (!ExecuteSql(g_SyncDb, query, "enqueue operation"))
    {
        return -1;
    }

    int opId = 0;
    DBResultSet results = SQL_Query(g_SyncDb, "SELECT last_insert_rowid()");
    if (results != null)
    {
        if (SQL_FetchRow(results))
        {
            opId = SQL_FetchInt(results, 0);
        }
        delete results;
    }

    WriteLocalAuditLog(operation, target, operatorName, operatorSteamid, true, "Enqueued for offline sync");

    g_PendingCount++;

    // 立即尝试同步（离线时会自动重试）
    SyncOfflineQueue();

    return opId;
}

void MarkOperationSynced(int id)
{
    if (g_SyncDb == null) return;
    if (id < 0) return;

    char query[256];
    char timeBuf[16];
    char idBuf[16];
    SafeIntToString(GetTime(), timeBuf, sizeof(timeBuf));
    SafeIntToString(id, idBuf, sizeof(idBuf));
    Format(query, sizeof(query), "UPDATE offline_queue SET status = 'synced', synced_at = %s WHERE id = %s", timeBuf, idBuf);
    ExecuteSql(g_SyncDb, query, "mark operation synced");
}

void MarkOperationsFailed(ArrayList ids, const char[] error)
{
    if (g_SyncDb == null) return;

    char escapedError[256];
    EscapeSqlString(g_SyncDb, error, escapedError, sizeof(escapedError));

    for (int i = 0; i < ids.Length; i++)
    {
        int id = ids.Get(i);
        if (id < 0) continue;

        char query[512];
        char idBuf[16];
        SafeIntToString(id, idBuf, sizeof(idBuf));
        Format(query, sizeof(query), "UPDATE offline_queue SET status = 'failed', sync_error = '%s' WHERE id = %s", escapedError, idBuf);
        ExecuteSql(g_SyncDb, query, "mark operations failed");
    }

    UpdatePendingCount();
}

void MarkOperationsRetryable(ArrayList ids, const char[] error)
{
    if (g_SyncDb == null) return;

    char escapedError[256];
    EscapeSqlString(g_SyncDb, error, escapedError, sizeof(escapedError));

    for (int i = 0; i < ids.Length; i++)
    {
        int id = ids.Get(i);
        if (id < 0) continue;

        char query[512];
        char idBuf[16];
        SafeIntToString(id, idBuf, sizeof(idBuf));
        Format(query, sizeof(query), "UPDATE offline_queue SET status = 'pending', sync_error = '%s', retry_count = retry_count + 1 WHERE id = %s", escapedError, idBuf);
        ExecuteSql(g_SyncDb, query, "mark operations retryable");
    }

    UpdatePendingCount();
}

public int Native_EnqueueOperation(Handle plugin, int numParams)
{
    char operation[32];
    char target[64];
    char targetType[16];
    char playerName[128];
    char reason[256];
    char operatorName[128];
    char operatorSteamid[64];

    GetNativeString(1, operation, sizeof(operation));
    GetNativeString(2, target, sizeof(target));
    GetNativeString(3, targetType, sizeof(targetType));
    GetNativeString(4, playerName, sizeof(playerName));
    GetNativeString(5, reason, sizeof(reason));
    GetNativeString(6, operatorName, sizeof(operatorName));
    GetNativeString(7, operatorSteamid, sizeof(operatorSteamid));
    int durationMinutes = GetNativeCell(8);

    return EnqueueOperation(operation, target, targetType, playerName, reason, durationMinutes, operatorName, operatorSteamid);
}

public int Native_IsOnline(Handle plugin, int numParams)
{
    return g_IsOnline ? 1 : 0;
}

public int Native_GetPendingCount(Handle plugin, int numParams)
{
    return g_PendingCount;
}
