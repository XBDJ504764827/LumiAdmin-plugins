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

    char escapedTarget[256];
    char escapedOperatorName[256];
    char escapedOperatorSteamid[256];
    char escapedMessage[512];

    EscapeSqlString(g_SyncDb, target, escapedTarget, sizeof(escapedTarget));
    EscapeSqlString(g_SyncDb, operatorName, escapedOperatorName, sizeof(escapedOperatorName));
    EscapeSqlString(g_SyncDb, operatorSteamid, escapedOperatorSteamid, sizeof(escapedOperatorSteamid));
    EscapeSqlString(g_SyncDb, message, escapedMessage, sizeof(escapedMessage));

    char query[1024];
    char portBuf[16];
    char timeBuf[16];
    char successBuf[8];
    SafeIntToString(g_ServerPort, portBuf, sizeof(portBuf));
    SafeIntToString(GetTime(), timeBuf, sizeof(timeBuf));
    SafeIntToString(success ? 1 : 0, successBuf, sizeof(successBuf));

    Format(query, sizeof(query), "INSERT INTO audit_log (operation, target, operator_name, operator_steamid, server_port, success, message, created_at) VALUES ('%s', '%s', '%s', '%s', %s, %s, '%s', %s)", operation, escapedTarget, escapedOperatorName, escapedOperatorSteamid, portBuf, successBuf, escapedMessage, timeBuf);

    ExecuteSql(g_SyncDb, query, "local audit log");
}
