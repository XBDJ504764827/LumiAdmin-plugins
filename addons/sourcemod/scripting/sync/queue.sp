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

    // M8：唯一计数来源，其余位置一律调用本函数
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

    // H3：达到 MAX_RETRY 的死行先终态化为 failed（保留数据可人工重放），过期后一并清理
    char query[512];
    Format(query, sizeof(query), "UPDATE offline_queue SET status = 'failed', sync_error = 'max retries exceeded' WHERE status = 'pending' AND retry_count >= %d", MAX_RETRY_COUNT);
    SQL_FastQuery(g_SyncDb, query);

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

    // H3：软上限，超限拒收并告警
    if (g_PendingCount >= SYNC_QUEUE_SOFT_LIMIT)
    {
        LogError("[LumiAdmin Sync] EnqueueOperation rejected: pending queue reached soft limit (%d). Check API connectivity.", g_PendingCount);
        return -1;
    }

    // M9：reason/player_name 等用户可控长文本改用 SQL_PrepareQuery 参数绑定，
    // 避免转义串在 buffer 截断中间导致 SQL 语法错误
    char stmtError[256];
    DBStatement stmt = SQL_PrepareQuery(g_SyncDb, "INSERT INTO offline_queue (operation, target, target_type, player_name, reason, duration_minutes, operator_name, operator_steamid, server_port, created_at, status, idempotency_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?)", stmtError, sizeof(stmtError));
    if (stmt == null)
    {
        LogError("[LumiAdmin Sync] failed to prepare enqueue statement: %s", stmtError);
        return -1;
    }

    stmt.BindString(0, operation, false);
    stmt.BindString(1, target, false);
    stmt.BindString(2, targetType, false);
    stmt.BindString(3, playerName, false);
    stmt.BindString(4, reason, false);
    stmt.BindInt(5, durationMinutes);
    stmt.BindString(6, operatorName, false);
    stmt.BindString(7, operatorSteamid, false);
    stmt.BindInt(8, g_ServerPort);
    stmt.BindInt(9, GetTime());
    stmt.BindString(10, idempotencyKey, false);

    if (!SQL_Execute(stmt))
    {
        LogError("[LumiAdmin Sync] enqueue insert failed.");
        delete stmt;
        return -1;
    }
    delete stmt;

    WriteLocalAuditLog(operation, target, operatorName, operatorSteamid, true, "Enqueued for offline sync");

    // H4：不再同步查询 last_insert_rowid()；opId 仅用于日志，调用方不依赖精确值
    // M8：不再手动 ++，统一由 UpdatePendingCount 维护
    UpdatePendingCount();

    // H4：入队后 0.5s 延迟触发同步，把 SQL 开销挪出玩家命令路径
    KickSyncQueueDeferred();

    return 0;
}

/**
 * H4：延迟一次性 timer 触发同步，重复入队不叠加。
 */
void KickSyncQueueDeferred()
{
    if (g_SyncKickTimer != null)
    {
        return;
    }
    g_SyncKickTimer = CreateTimer(0.5, Timer_SyncKickDeferred);
}

public Action Timer_SyncKickDeferred(Handle timer)
{
    g_SyncKickTimer = null;
    SyncOfflineQueue();
    return Plugin_Stop;
}

/**
 * H3：把 failed 行重置回 pending 手动重放（sm_lumi_sync_retry）。
 */
public Action CommandRetryFailed(int client, int args)
{
    if (g_SyncDb == null)
    {
        ReplyToCommand(client, "[LumiAdmin Sync] database unavailable.");
        return Plugin_Handled;
    }

    char query[256];
    Format(query, sizeof(query), "UPDATE offline_queue SET status = 'pending', retry_count = 0, sync_error = '' WHERE status = 'failed'");
    SQL_FastQuery(g_SyncDb, query);
    int affected = SQL_GetAffectedRows(g_SyncDb);
    ReplyToCommand(client, "[LumiAdmin Sync] %d failed operation(s) reset to pending.", affected);

    UpdatePendingCount();
    if (affected > 0)
    {
        SyncOfflineQueue();
    }
    return Plugin_Handled;
}

/**
 * H4：批量标记，单条 UPDATE ... WHERE id IN (...) 取代逐条 UPDATE。
 */
bool MarkOperationsByIds(ArrayList ids, const char[] statusClause, const char[] error)
{
    if (g_SyncDb == null || ids == null || ids.Length == 0)
    {
        return false;
    }

    char idList[2048];
    idList[0] = '\0';
    char idBuf[16];
    for (int i = 0; i < ids.Length; i++)
    {
        int id = ids.Get(i);
        if (id < 0) continue;
        IntToString(id, idBuf, sizeof(idBuf));
        if (idList[0] != '\0')
        {
            StrCat(idList, sizeof(idList), ",");
        }
        StrCat(idList, sizeof(idList), idBuf);
    }

    if (idList[0] == '\0')
    {
        return false;
    }

    char escapedError[256];
    escapedError[0] = '\0';
    if (error[0] != '\0')
    {
        EscapeSqlString(g_SyncDb, error, escapedError, sizeof(escapedError));
    }

    char timeBuf[16];
    SafeIntToString(GetTime(), timeBuf, sizeof(timeBuf));

    char query[2600];
    if (error[0] != '\0')
    {
        Format(query, sizeof(query), "UPDATE offline_queue SET %s, sync_error = '%s' WHERE id IN (%s)", statusClause, escapedError, idList);
    }
    else
    {
        Format(query, sizeof(query), "UPDATE offline_queue SET %s WHERE id IN (%s)", statusClause, idList);
    }

    ExecuteSql(g_SyncDb, query, "mark operations by ids");
    UpdatePendingCount();
    return true;
}

void MarkOperationSynced(ArrayList ids)
{
    if (g_SyncDb == null) return;

    char timeBuf[16];
    SafeIntToString(GetTime(), timeBuf, sizeof(timeBuf));
    char clause[64];
    Format(clause, sizeof(clause), "status = 'synced', synced_at = %s", timeBuf);
    MarkOperationsByIds(ids, clause, "");
}

void MarkOperationsFailed(ArrayList ids, const char[] error)
{
    MarkOperationsByIds(ids, "status = 'failed'", error);
}

void MarkOperationsRetryable(ArrayList ids, const char[] error)
{
    MarkOperationsByIds(ids, "status = 'pending', retry_count = retry_count + 1", error);
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

    // L13：GetNativeString 失败时中止，避免使用未初始化/截断数据
    if (GetNativeString(1, operation, sizeof(operation)) != SP_ERROR_NONE
        || GetNativeString(2, target, sizeof(target)) != SP_ERROR_NONE
        || GetNativeString(3, targetType, sizeof(targetType)) != SP_ERROR_NONE
        || GetNativeString(4, playerName, sizeof(playerName)) != SP_ERROR_NONE
        || GetNativeString(5, reason, sizeof(reason)) != SP_ERROR_NONE
        || GetNativeString(6, operatorName, sizeof(operatorName)) != SP_ERROR_NONE
        || GetNativeString(7, operatorSteamid, sizeof(operatorSteamid)) != SP_ERROR_NONE)
    {
        ThrowNativeError(SP_ERROR_NATIVE, "Invalid parameters passed to Sync_EnqueueOperation.");
        return -1;
    }
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