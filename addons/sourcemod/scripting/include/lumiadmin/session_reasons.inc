#if defined _lumiadmin_session_reasons_included
  #endinput
#endif
#define _lumiadmin_session_reasons_included

/**
 * LumiAdmin player session disconnect reasons.
 * Reported to POST /api/plugin/online-players/disconnect.
 */

#define SESSION_REASON_ADMIN_KICKED "admin_kicked"
#define SESSION_REASON_PLAYER_QUIT "player_quit"
#define SESSION_REASON_ACCESS_REJECTED "access_rejected"
#define SESSION_REASON_BANNED_KICKED "banned_kicked"
#define SESSION_REASON_SNAPSHOT_MISSING "snapshot_missing"
#define SESSION_REASON_SERVER_STALE "server_stale"
