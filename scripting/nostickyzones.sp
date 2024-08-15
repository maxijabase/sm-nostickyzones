#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.0"
#define TRIGGER_NAME "sticky_removal_zone"
#define MAX_SEARCH_DIST 600.0
#define ZONE_SIZE 300.0

bool g_bAllowOutline = true;
Database g_DB;
int g_iLaserMaterial = -1;
int g_iHaloMaterial = -1;

float g_fMinBounds[MAXPLAYERS + 1][3];
float g_fMaxBounds[MAXPLAYERS + 1][3];

bool g_WaitingForSize[MAXPLAYERS + 1];
char g_CurrentSizeEdit[MAXPLAYERS + 1][32];

int g_iZoneTeam[MAXPLAYERS + 1];
bool g_bZoneGlowing[2048];

#define TEAM_ALL 0
#define TEAM_RED 2
#define TEAM_BLU 3

public Plugin myinfo = 
{
    name = "[TF2] Sticky Removal Zones", 
    author = "ampere", 
    description = "Create custom zones where stickies are automatically removed.", 
    version = PLUGIN_VERSION, 
    url = "https://github.com/maxijabase"
};

public void OnPluginStart()
{
    LoadTranslations("common.phrases");
    
    HookEvent("teamplay_round_start", EventRoundStart);
    
    CreateConVar("sm_sticky_removal_version", PLUGIN_VERSION, "Custom Sticky Removal Zones version", FCVAR_SPONLY | FCVAR_REPLICATED | FCVAR_NOTIFY);
    
    RegAdminCmd("sm_stickyzones", StickyZones_Menu, ADMFLAG_ROOT, "Opens the sticky removal zones menu.");
    RegAdminCmd("sm_showstickyzones", Show_StickyZones, ADMFLAG_ROOT, "Shows all sticky removal zones for 10 seconds");
    
    Database.Connect(SQL_OnConnect, "no_sticky_zones");

    CreateTimer(0.1, Timer_DrawZones, _, TIMER_REPEAT);
}

public void OnMapStart()
{
    g_iLaserMaterial = PrecacheModel("materials/sprites/laser.vmt");
    g_iHaloMaterial = PrecacheModel("materials/sprites/halo01.vmt");
    CreateTimer(1.0, Timer_ScanStickies, INVALID_HANDLE, TIMER_REPEAT);
}

public void SQL_OnConnect(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("Database connection failed! Error: %s", error);
        SetFailState("Database connection failed. See error logs for details.");
        return;
    }
    
    g_DB = db;
    SQL_CreateTables();
}

void SQL_CreateTables()
{
    char query[512];
    Format(query, sizeof(query), "CREATE TABLE IF NOT EXISTS TF2_StickyRemovalZones ("
        ... "id INT AUTO_INCREMENT PRIMARY KEY, "
        ... "locX FLOAT, locY FLOAT, locZ FLOAT, "
        ... "minX FLOAT, minY FLOAT, minZ FLOAT, "
        ... "maxX FLOAT, maxY FLOAT, maxZ FLOAT, "
        ... "team INT, map VARCHAR(64))");
    g_DB.Query(SQL_OnCreatedTable, query);
}

public void SQL_OnCreatedTable(Database db, DBResultSet results, const char[] error, any data)
{
    if (db == null)
    {
        LogError("Table creation query failed! %s", error);
    }
}

public Action EventRoundStart(Event event, const char[] name, bool dontBroadcast)
{
    char mapname[64];
    GetCurrentMap(mapname, sizeof(mapname));
    
    char query[256];
    Format(query, sizeof(query), "SELECT locX, locY, locZ, minX, minY, minZ, maxX, maxY, maxZ, team "
        ..."FROM TF2_StickyRemovalZones WHERE map = '%s';", mapname);
    
    g_DB.Query(SQL_OnGetZones, query);
    return Plugin_Continue;
}

public void SQL_OnGetZones(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
    {
        LogError("Query failed! %s", error);
    }
    else if (results.RowCount > 0)
    {
        while (results.FetchRow())
        {
            float pos[3], minbounds[3], maxbounds[3];
            int team;
            for (int i = 0; i < 3; i++)
            {
                pos[i] = results.FetchFloat(i);
                minbounds[i] = results.FetchFloat(i + 3);
                maxbounds[i] = results.FetchFloat(i + 6);
            }
            team = results.FetchInt(9);
            CreateZone(pos, minbounds, maxbounds, team);
        }
    }
}

public Action StickyZones_Menu(int client, int args)
{
    Menu menu = new Menu(StickyZones_MainMenu);
    menu.SetTitle("Sticky Removal Zones Menu:");
    menu.AddItem("0", "Create Zone");
    menu.AddItem("1", "Delete Nearest Zone");
    menu.AddItem("2", "Show All Zones");
    menu.Display(client, MENU_TIME_FOREVER);
    
    return Plugin_Handled;
}

public int StickyZones_MainMenu(Menu menu, MenuAction action, int param1, int param2)
{
    switch (action)
    {
        case MenuAction_Select:
        {
            switch (param2)
            {
                case 0: StickyZones_CustomSizeMenu(param1);
                case 1: DeleteZone(param1);
                case 2: ShowAllZones(param1);
            }
        }
        case MenuAction_End: delete menu;
    }

    return 0;
}

public Action StickyZones_CustomSizeMenu(int client)
{
    Menu menu = new Menu(StickyZones_CustomSizeHandler);
    menu.SetTitle("Custom Zone Creation:");
    menu.AddItem("width", "Set Width");
    menu.AddItem("length", "Set Length");
    menu.AddItem("height", "Set Height");
    menu.AddItem("team", "Set Team");
    menu.AddItem("create", "Create Zone", (g_fMinBounds[client][0] != 0.0 && g_iZoneTeam[client] >= TEAM_ALL) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
    menu.Display(client, MENU_TIME_FOREVER);
    
    return Plugin_Handled;
}

public int StickyZones_CustomSizeHandler(Menu menu, MenuAction action, int param1, int param2)
{
    switch (action)
    {
        case MenuAction_Select:
        {
            char info[32];
            menu.GetItem(param2, info, sizeof(info));
            
            if (StrEqual(info, "create"))
            {
                CreateZoneAtClient(param1);
            }
            else if (StrEqual(info, "team"))
            {
                DisplayTeamSelectionMenu(param1);
            }
            else
            {
                g_CurrentSizeEdit[param1] = info;
                PrintToChat(param1, "[SM] Enter the %s of the zone in units:", info);
                g_WaitingForSize[param1] = true;
            }
        }
        case MenuAction_End: delete menu;
    }

    return 0;
}

public Action DisplayTeamSelectionMenu(int client)
{
    Menu menu = new Menu(TeamSelectionHandler);
    menu.SetTitle("Select Team for Sticky Removal:");
    menu.AddItem("0", "All Teams");
    menu.AddItem("2", "RED Team");
    menu.AddItem("3", "BLU Team");
    menu.Display(client, MENU_TIME_FOREVER);
    
    return Plugin_Handled;
}

public int TeamSelectionHandler(Menu menu, MenuAction action, int param1, int param2)
{
    switch (action)
    {
        case MenuAction_Select:
        {
            char info[32];
            menu.GetItem(param2, info, sizeof(info));
            g_iZoneTeam[param1] = StringToInt(info);
            PrintToChat(param1, "[SM] Team set to: %s", (g_iZoneTeam[param1] == TEAM_ALL) ? "All Teams" : (g_iZoneTeam[param1] == TEAM_RED) ? "RED Team" : "BLU Team");
            StickyZones_CustomSizeMenu(param1);
        }
        case MenuAction_End: delete menu;
    }

    return 0;
}

public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
    if (g_WaitingForSize[client])
    {
        float size = StringToFloat(sArgs);
        if (size > 0.0)
        {
            if (StrEqual(g_CurrentSizeEdit[client], "width"))
            {
                g_fMinBounds[client][0] = -size / 2;
                g_fMaxBounds[client][0] = size / 2;
            }
            else if (StrEqual(g_CurrentSizeEdit[client], "length"))
            {
                g_fMinBounds[client][1] = -size / 2;
                g_fMaxBounds[client][1] = size / 2;
            }
            else if (StrEqual(g_CurrentSizeEdit[client], "height"))
            {
                g_fMinBounds[client][2] = -size / 2;
                g_fMaxBounds[client][2] = size / 2;
            }
            
            PrintToChat(client, "[SM] %s set to %.2f units", g_CurrentSizeEdit[client], size);
            g_WaitingForSize[client] = false;
            StickyZones_CustomSizeMenu(client);
        }
        else
        {
            PrintToChat(client, "[SM] Invalid size. Please enter a positive number.");
        }
        return Plugin_Handled;
    }
    return Plugin_Continue;
}

void CreateZoneAtClient(int client)
{
    float pos[3];
    GetClientAbsOrigin(client, pos);
    
    for (int i = 0; i < 3; i++)
        pos[i] = float(RoundToFloor(pos[i]));
    
    int zone = CreateZone(pos, g_fMinBounds[client], g_fMaxBounds[client], g_iZoneTeam[client]);
    if (zone != -1)
    {
        g_bZoneGlowing[zone] = true;
        CreateTimer(10.0, Timer_StopZoneGlow, zone);
        
        // Draw the zone outline immediately
        DrawZoneOutline(pos, g_fMinBounds[client], g_fMaxBounds[client], g_iZoneTeam[client]);
        
        char mapname[64];
        GetCurrentMap(mapname, sizeof(mapname));
        
        char query[512];
        Format(query, sizeof(query), "INSERT INTO TF2_StickyRemovalZones "
            ... "(locX, locY, locZ, minX, minY, minZ, maxX, maxY, maxZ, team, map) VALUES "
            ... "(%f, %f, %f, %f, %f, %f, %f, %f, %f, %d, '%s');", 
            pos[0], pos[1], pos[2], 
            g_fMinBounds[client][0], g_fMinBounds[client][1], g_fMinBounds[client][2], 
            g_fMaxBounds[client][0], g_fMaxBounds[client][1], g_fMaxBounds[client][2], 
            g_iZoneTeam[client], mapname);
        
        g_DB.Query(SQL_OnZoneSaved, query);
    }
}

public void SQL_OnZoneSaved(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
    {
        LogError("Failed to save zone! Error: %s", error);
    }
    else
    {
        PrintToChatAll("[SM] New sticky removal zone added!");
    }
}

int CreateZone(float pos[3], float minbounds[3], float maxbounds[3], int team)
{
    int trigger = CreateEntityByName("trigger_multiple");
    if (trigger != -1)
    {
        char targetname[64];
        Format(targetname, sizeof(targetname), "%s_%d", TRIGGER_NAME, team);
        DispatchKeyValue(trigger, "targetname", targetname);
        DispatchKeyValue(trigger, "StartDisabled", "0");
        DispatchKeyValue(trigger, "spawnflags", "1");
        
        DispatchSpawn(trigger);
        ActivateEntity(trigger);
        
        TeleportEntity(trigger, pos, NULL_VECTOR, NULL_VECTOR);
        
        SetEntPropVector(trigger, Prop_Send, "m_vecMins", minbounds);
        SetEntPropVector(trigger, Prop_Send, "m_vecMaxs", maxbounds);
        
        SetEntProp(trigger, Prop_Send, "m_nSolidType", 2);
        
        int enteffects = GetEntProp(trigger, Prop_Send, "m_fEffects");
        enteffects |= 32;
        SetEntProp(trigger, Prop_Send, "m_fEffects", enteffects);
    }
    return trigger;
}

public Action Timer_StopZoneGlow(Handle timer, any zoneEnt)
{
    g_bZoneGlowing[zoneEnt] = false;
    return Plugin_Stop;
}

void DeleteZone(int client)
{
    float clientPos[3], zonePos[3];
    GetClientAbsOrigin(client, clientPos);
    
    int closestZone = -1;
    float closestDist = MAX_SEARCH_DIST;
    
    int ent = -1;
    while ((ent = FindEntityByClassname(ent, "trigger_multiple")) != -1)
    {
        char name[64];
        GetEntPropString(ent, Prop_Data, "m_iName", name, sizeof(name));
        if (StrContains(name, TRIGGER_NAME) == 0)
        {
            GetEntPropVector(ent, Prop_Send, "m_vecOrigin", zonePos);
            float dist = GetVectorDistance(clientPos, zonePos);
            if (dist < closestDist)
            {
                closestZone = ent;
                closestDist = dist;
            }
        }
    }
    
    if (closestZone != -1)
    {
        float zoneMin[3], zoneMax[3];
        GetEntPropVector(closestZone, Prop_Send, "m_vecMins", zoneMin);
        GetEntPropVector(closestZone, Prop_Send, "m_vecMaxs", zoneMax);
        
        RemoveEntity(closestZone);
        
        char query[512];
        Format(query, sizeof(query), "DELETE FROM TF2_StickyRemovalZones WHERE "
            ... "locX = %f AND locY = %f AND locZ = %f AND "
            ... "minX = %f AND minY = %f AND minZ = %f AND "
            ... "maxX = %f AND maxY = %f AND maxZ = %f LIMIT 1;", 
            zonePos[0], zonePos[1], zonePos[2],
            zoneMin[0], zoneMin[1], zoneMin[2],
            zoneMax[0], zoneMax[1], zoneMax[2]);
        g_DB.Query(SQL_OnZoneDeleted, query);
        
        PrintToChat(client, "[SM] Nearest sticky removal zone deleted.");
    }
    else
    {
        PrintToChat(client, "[SM] No nearby sticky removal zones found.");
    }
}

public void SQL_OnZoneDeleted(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
    {
        LogError("Failed to delete zone from database! Error: %s", error);
    }
    else if (results.AffectedRows == 0)
    {
        LogError("No zone was deleted from the database.");
    }
}

public Action Show_StickyZones(int client, int args)
{
    ShowAllZones(client);
    return Plugin_Handled;
}

void ShowAllZones(int client)
{
    if (g_bAllowOutline)
    {
        PrintToChat(client, "[SM] Showing all sticky removal zones for 10 seconds.");
        g_bAllowOutline = false;
        CreateTimer(10.0, Timer_DisallowShow);
        
        char mapname[64];
        GetCurrentMap(mapname, sizeof(mapname));
        
        char query[256];
        Format(query, sizeof(query), "SELECT locX, locY, locZ, minX, minY, minZ, maxX, maxY, maxZ, team "
            ... "FROM TF2_StickyRemovalZones WHERE map = '%s';", mapname);
        
        g_DB.Query(SQL_OnGetZonesForDisplay, query);
    }
}

public Action Timer_DisallowShow(Handle timer)
{
    g_bAllowOutline = true;
    return Plugin_Stop;
}

public void SQL_OnGetZonesForDisplay(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
    {
        LogError("Query failed! %s", error);
    }
    else
    {
        while (results.FetchRow())
        {
            float pos[3], minbounds[3], maxbounds[3];
            int team;
            for (int i = 0; i < 3; i++)
            {
                pos[i] = results.FetchFloat(i);
                minbounds[i] = results.FetchFloat(i + 3);
                maxbounds[i] = results.FetchFloat(i + 6);
            }
            team = results.FetchInt(9);
            DrawZoneOutline(pos, minbounds, maxbounds, team);
        }
    }
}

void DrawZoneOutline(float pos[3], float minbounds[3], float maxbounds[3], int team)
{
    int color[4];
    switch (team)
    {
        case TEAM_RED:
        color = { 255, 0, 0, 255 }; // Red
        case TEAM_BLU:
        color = { 0, 0, 255, 255 }; // Blue
        default:
        color = { 255, 255, 255, 255 }; // White
    }
    
    float vector1[3], vector2[3];
    AddVectors(pos, minbounds, vector1);
    AddVectors(pos, maxbounds, vector2);
    
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client))
        {
            TE_SendBeamBoxToClient(client, vector1, vector2, g_iLaserMaterial, g_iHaloMaterial, 0, 30, 10.0, 5.0, 5.0, 2, 1.0, color, 0);
        }
    }
}

stock void TE_SendBeamBoxToClient(int client, float uppercorner[3], float bottomcorner[3], int ModelIndex, int HaloIndex, int StartFrame, int FrameRate, float Life, float Width, float EndWidth, int FadeLength, float Amplitude, int Color[4], int Speed)
{
    float tc1[3], tc2[3], tc3[3], tc4[3], tc5[3], tc6[3];
    
    AddVectors(tc1, uppercorner, tc1);
    tc1[0] = bottomcorner[0];
    AddVectors(tc2, uppercorner, tc2);
    tc2[1] = bottomcorner[1];
    AddVectors(tc3, uppercorner, tc3);
    tc3[2] = bottomcorner[2];
    AddVectors(tc4, bottomcorner, tc4);
    tc4[0] = uppercorner[0];
    AddVectors(tc5, bottomcorner, tc5);
    tc5[1] = uppercorner[1];
    AddVectors(tc6, bottomcorner, tc6);
    tc6[2] = uppercorner[2];
    
    TE_SetupBeamPoints(uppercorner, tc1, ModelIndex, HaloIndex, StartFrame, FrameRate, Life, Width, EndWidth, FadeLength, Amplitude, Color, Speed);
    TE_SendToClient(client);
    TE_SetupBeamPoints(uppercorner, tc2, ModelIndex, HaloIndex, StartFrame, FrameRate, Life, Width, EndWidth, FadeLength, Amplitude, Color, Speed);
    TE_SendToClient(client);
    TE_SetupBeamPoints(uppercorner, tc3, ModelIndex, HaloIndex, StartFrame, FrameRate, Life, Width, EndWidth, FadeLength, Amplitude, Color, Speed);
    TE_SendToClient(client);
    TE_SetupBeamPoints(tc6, tc1, ModelIndex, HaloIndex, StartFrame, FrameRate, Life, Width, EndWidth, FadeLength, Amplitude, Color, Speed);
    TE_SendToClient(client);
    TE_SetupBeamPoints(tc6, tc2, ModelIndex, HaloIndex, StartFrame, FrameRate, Life, Width, EndWidth, FadeLength, Amplitude, Color, Speed);
    TE_SendToClient(client);
    TE_SetupBeamPoints(tc6, bottomcorner, ModelIndex, HaloIndex, StartFrame, FrameRate, Life, Width, EndWidth, FadeLength, Amplitude, Color, Speed);
    TE_SendToClient(client);
    TE_SetupBeamPoints(tc4, bottomcorner, ModelIndex, HaloIndex, StartFrame, FrameRate, Life, Width, EndWidth, FadeLength, Amplitude, Color, Speed);
    TE_SendToClient(client);
    TE_SetupBeamPoints(tc5, bottomcorner, ModelIndex, HaloIndex, StartFrame, FrameRate, Life, Width, EndWidth, FadeLength, Amplitude, Color, Speed);
    TE_SendToClient(client);
    TE_SetupBeamPoints(tc5, tc1, ModelIndex, HaloIndex, StartFrame, FrameRate, Life, Width, EndWidth, FadeLength, Amplitude, Color, Speed);
    TE_SendToClient(client);
    TE_SetupBeamPoints(tc5, tc3, ModelIndex, HaloIndex, StartFrame, FrameRate, Life, Width, EndWidth, FadeLength, Amplitude, Color, Speed);
    TE_SendToClient(client);
    TE_SetupBeamPoints(tc4, tc3, ModelIndex, HaloIndex, StartFrame, FrameRate, Life, Width, EndWidth, FadeLength, Amplitude, Color, Speed);
    TE_SendToClient(client);
    TE_SetupBeamPoints(tc4, tc2, ModelIndex, HaloIndex, StartFrame, FrameRate, Life, Width, EndWidth, FadeLength, Amplitude, Color, Speed);
    TE_SendToClient(client);
}

public Action Timer_ScanStickies(Handle timer)
{
    int sticky = -1;
    while ((sticky = FindEntityByClassname(sticky, "tf_projectile_pipe_remote")) != -1)
    {
        float stickyPos[3];
        GetEntPropVector(sticky, Prop_Send, "m_vecOrigin", stickyPos);
        int stickyTeam = GetEntProp(sticky, Prop_Send, "m_iTeamNum");
        
        int zone = -1;
        while ((zone = FindEntityByClassname(zone, "trigger_multiple")) != -1)
        {
            char name[64];
            GetEntPropString(zone, Prop_Data, "m_iName", name, sizeof(name));
            if (StrContains(name, TRIGGER_NAME) == 0)
            {
                int zoneTeam = TEAM_ALL;
                if (StrContains(name, "_2") != -1)
                    zoneTeam = TEAM_RED;
                else if (StrContains(name, "_3") != -1)
                    zoneTeam = TEAM_BLU;
                
                float zonePos[3], zoneMin[3], zoneMax[3];
                GetEntPropVector(zone, Prop_Send, "m_vecOrigin", zonePos);
                GetEntPropVector(zone, Prop_Send, "m_vecMins", zoneMin);
                GetEntPropVector(zone, Prop_Send, "m_vecMaxs", zoneMax);
                
                if (IsPointInBox(stickyPos, zonePos, zoneMin, zoneMax))
                {
                    // Remove sticky if it's in an "All Teams" zone or if it's in an enemy team's zone
                    if (zoneTeam == TEAM_ALL || zoneTeam != stickyTeam)
                    {
                        AcceptEntityInput(sticky, "Kill");
                        int owner = GetEntPropEnt(sticky, Prop_Send, "m_hThrower");
                        break;
                    }
                }
            }
        }
    }
    return Plugin_Continue;
}

public Action Timer_DrawZones(Handle timer)
{
    int ent = -1;
    while ((ent = FindEntityByClassname(ent, "trigger_multiple")) != -1)
    {
        char name[64];
        GetEntPropString(ent, Prop_Data, "m_iName", name, sizeof(name));
        if (StrContains(name, TRIGGER_NAME) == 0)
        {
            float pos[3], mins[3], maxs[3];
            GetEntPropVector(ent, Prop_Send, "m_vecOrigin", pos);
            GetEntPropVector(ent, Prop_Send, "m_vecMins", mins);
            GetEntPropVector(ent, Prop_Send, "m_vecMaxs", maxs);
            
            int team;
            if (StrContains(name, "_2") != -1)
                team = TEAM_RED;
            else if (StrContains(name, "_3") != -1)
                team = TEAM_BLU;
            else
                team = TEAM_ALL;
            
            if (g_bZoneGlowing[ent])
            {
                DrawZoneOutline(pos, mins, maxs, team);
            }
        }
    }
    return Plugin_Continue;
}

// Helper function to check if a point is inside a box
bool IsPointInBox(float point[3], float boxOrigin[3], float boxMins[3], float boxMaxs[3])
{
    float adjustedPoint[3];
    SubtractVectors(point, boxOrigin, adjustedPoint);
    
    return (adjustedPoint[0] >= boxMins[0] && adjustedPoint[0] <= boxMaxs[0] && 
        adjustedPoint[1] >= boxMins[1] && adjustedPoint[1] <= boxMaxs[1] && 
        adjustedPoint[2] >= boxMins[2] && adjustedPoint[2] <= boxMaxs[2]);
}