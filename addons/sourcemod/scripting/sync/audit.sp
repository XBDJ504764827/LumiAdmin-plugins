/**
 * 本地审计日志（断网期间的应急留痕，保留 7 天）。
 */
void WriteLocalAuditLog(
    const char[] operation,
    const char[] target,
    const char[] operatorName,
    const char[] operatorSteamid,
    bool success,
    const char[] message
)
{
    if (g_SyncDb == null) return;

    // M9：operator_steamid/message 等长文本改参数绑定，消除转义截断风险
    char stmtError[256];
    DBStatement stmt = SQL_PrepareQuery(g_SyncDb, "INSERT INTO audit_log (operation, target, operator_name, operator_steamid, server_port, success, message, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", stmtError, sizeof(stmtError));
    if (stmt == null)
    {
        LogError("[LumiAdmin Sync] failed to prepare audit log statement: %s", stmtError);
        return;
    }

    stmt.BindString(0, operation, false);
    stmt.BindString(1, target, false);
    stmt.BindString(2, operatorName, false);
    stmt.BindString(3, operatorSteamid, false);
    stmt.BindInt(4, g_ServerPort);
    stmt.BindInt(5, success ? 1 : 0);
    stmt.BindString(6, message, false);
    stmt.BindInt(7, GetTime());

    if (!SQL_Execute(stmt))
    {
        LogError("[LumiAdmin Sync] audit log insert failed.");
    }
    delete stmt;
}
