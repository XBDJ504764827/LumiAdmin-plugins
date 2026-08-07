#define LEGACY_GLOBAL_PLUGIN "addons/sourcemod/plugins/gokz-global.smx"
#define LEGACY_GLOBAL_DISABLED_DIR "addons/sourcemod/plugins/disabled"
#define LEGACY_GLOBAL_DISABLED_PLUGIN "addons/sourcemod/plugins/disabled/gokz-global.smx"

void UnloadLegacyGlobalPlugin()
{
	ServerCommand("sm plugins unload gokz-global");
	ServerExecute();
}

bool IsLegacyGlobalSurfaceOccupied()
{
	return GetFeatureStatus(FeatureType_Native, "GOKZ_GL_PrintRecords") == FeatureStatus_Available
		|| LibraryExists("gokz-global")
		|| FindPluginByFile("gokz-global.smx") != INVALID_HANDLE
		|| FileExists(LEGACY_GLOBAL_PLUGIN);
}

bool DisableLegacyGlobalBinary()
{
	UnloadLegacyGlobalPlugin();
	
	if (!FileExists(LEGACY_GLOBAL_PLUGIN))
	{
		return true;
	}
	
	if (!DirExists(LEGACY_GLOBAL_DISABLED_DIR) && !CreateDirectory(LEGACY_GLOBAL_DISABLED_DIR, 511))
	{
		LogError("[global] Failed to create %s", LEGACY_GLOBAL_DISABLED_DIR);
		return false;
	}
	
	if (FileExists(LEGACY_GLOBAL_DISABLED_PLUGIN) && !DeleteFile(LEGACY_GLOBAL_DISABLED_PLUGIN))
	{
		LogError("[global] Failed to replace existing disabled gokz-global.smx");
		return false;
	}
	
	if (RenameFile(LEGACY_GLOBAL_DISABLED_PLUGIN, LEGACY_GLOBAL_PLUGIN))
	{
		LogMessage("[global] Moved legacy gokz-global.smx to plugins/disabled");
		return true;
	}
	
	LogError("[global] Failed to move legacy gokz-global.smx to plugins/disabled");
	return false;
}
