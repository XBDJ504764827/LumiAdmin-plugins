#if defined _lumiadmin_recordguard_included
#endinput
#endif
#define _lumiadmin_recordguard_included

/**
 * LumiAdmin Record Guard - abnormal record interception natives.
 * Loaded from the "recordguard" plugin. Optional for "global".
 */

/**
 * Asks recordguard whether this run should be held back from global
 * submission for manual review.
 */
native bool RecordGuard_ShouldHoldRecord(int client, int course, int mode, int timeType, float runTime, int teleportsUsed, int mapId);

/**
 * Returns whether recordguard is currently holding a run for this client.
 */
native bool RecordGuard_IsHoldingClient(int client);

public SharedPlugin __pl_lumiadmin_recordguard =
{
    name = "recordguard",
    file = "recordguard.smx",
#if defined REQUIRE_PLUGIN
    required = 1,
#else
    required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_lumiadmin_recordguard_SetNTVOptional()
{
    MarkNativeAsOptional("RecordGuard_ShouldHoldRecord");
    MarkNativeAsOptional("RecordGuard_IsHoldingClient");
}
#endif
