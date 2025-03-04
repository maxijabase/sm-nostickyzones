#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_VERSION "1.1"
#define TRIGGER_NAME "sticky_removal_zone"
#define MAX_SEARCH_DIST 600.0
#define HEIGHT_ADJUST_INCREMENT 8.0  // Amount to adjust height per click
#define DOUBLE_CLICK_TIME 0.3  // Time window in seconds for double click

bool g_bAllowOutline = true;
Database g_DB;
int g_iLaserMaterial = -1;
int g_iHaloMaterial = -1;

float g_fMinBounds[MAXPLAYERS + 1][3];
float g_fMaxBounds[MAXPLAYERS + 1][3];
float g_fAreaCenter[MAXPLAYERS + 1][3];  // Store the calculated center of the area

int g_iZoneTeam[MAXPLAYERS + 1];
bool g_bZoneGlowing[2048];

// Custom area creation tracking
bool g_bCreatingArea[MAXPLAYERS + 1] = { false, ... };
int g_iAreaStep[MAXPLAYERS + 1] = { 0, ... };
float g_fAreaPoints[MAXPLAYERS + 1][2][3]; // Two points: start and end
int g_iPreviewEntities[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };
Handle g_hPreviewTimer[MAXPLAYERS + 1] = { null, ... };

// Track vertical offset for height adjustment with scroll wheel
float g_fVerticalOffset[MAXPLAYERS + 1] = { 0.0, ... };

// Global array to track previous button states
int g_iPreviousButtons[MAXPLAYERS + 1] = { 0, ... };

// For double-click detection
float g_fLastClickTime[MAXPLAYERS + 1] = { 0.0, ... };

#define TEAM_ALL 0
#define TEAM_RED 2
#define TEAM_BLU 3

public Plugin myinfo = 
{
    name = "[TF2] Sticky Removal Zones", 
    author = "ampere, adapted by Claude", 
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
    RegAdminCmd("sm_cancelarea", CMD_CancelArea, ADMFLAG_ROOT, "Cancels the current area creation");
    
    Database.Connect(SQL_OnConnect, "no_sticky_zones");

    CreateTimer(0.1, Timer_DrawZones, _, TIMER_REPEAT);
    
    // Hook client pre-think for all clients
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            SDKHook(i, SDKHook_PreThink, OnClientPreThink);
        }
    }
}

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_PreThink, OnClientPreThink);
    g_iPreviousButtons[client] = 0;
    g_fVerticalOffset[client] = 0.0;
}

public void OnMapStart()
{
    g_iLaserMaterial = PrecacheModel("materials/sprites/laser.vmt");
    g_iHaloMaterial = PrecacheModel("materials/sprites/halo01.vmt");
    PrecacheSound("buttons/button14.wav", true);
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
                case 0: StartAreaCreation(param1);  // Start custom area creation
                case 1: DeleteZone(param1);
                case 2: ShowAllZones(param1);
            }
        }
        case MenuAction_End: delete menu;
    }

    return 0;
}

public Action CMD_CancelArea(int client, int args)
{
    if (g_bCreatingArea[client])
    {
        g_bCreatingArea[client] = false;
        g_iAreaStep[client] = 0;
        g_fVerticalOffset[client] = 0.0;
        CleanupPreview(client);
        PrintToChat(client, "[SM] Area creation canceled.");
    }
    else
    {
        PrintToChat(client, "[SM] You are not creating an area.");
    }
    
    return Plugin_Handled;
}

void CleanupPreview(int client)
{
    // Kill preview timer
    if (g_hPreviewTimer[client] != null)
    {
        delete g_hPreviewTimer[client];
        g_hPreviewTimer[client] = null;
    }
    
    // Remove preview entity
    if (g_iPreviewEntities[client] != INVALID_ENT_REFERENCE)
    {
        int entity = EntRefToEntIndex(g_iPreviewEntities[client]);
        if (entity != INVALID_ENT_REFERENCE)
        {
            RemoveEntity(entity);
        }
        g_iPreviewEntities[client] = INVALID_ENT_REFERENCE;
    }
}

void StartAreaCreation(int client)
{
    // Reset any existing area creation
    CleanupPreview(client);
    
    g_bCreatingArea[client] = true;
    g_iAreaStep[client] = 1;
    g_fVerticalOffset[client] = 0.0;
    g_fLastClickTime[client] = 0.0;
    
    PrintToChat(client, "[SM] Point at a location and double-click left mouse to set a corner.");
    PrintToChat(client, "[SM] Use right-click to raise height and left-click to lower height.");
    PrintToChat(client, "[SM] Current height offset: 0 units");
    PrintToChat(client, "[SM] Use /sm_cancelarea to cancel.");
    
    // Start preview timer
    g_hPreviewTimer[client] = CreateTimer(0.1, Timer_AreaPreview, client, TIMER_REPEAT);
}

public Action Timer_AreaPreview(Handle timer, int client)
{
    if (!IsClientInGame(client) || !g_bCreatingArea[client])
    {
        g_hPreviewTimer[client] = null;
        return Plugin_Stop;
    }
    
    float eyePos[3], eyeAng[3], endPos[3];
    GetClientEyePosition(client, eyePos);
    GetClientEyeAngles(client, eyeAng);
    
    TR_TraceRayFilter(eyePos, eyeAng, MASK_SOLID, RayType_Infinite, TraceFilterPlayers);
    
    if (TR_DidHit())
    {
        TR_GetEndPosition(endPos);
        
        // Apply vertical offset for height adjustment
        endPos[2] += g_fVerticalOffset[client];
        
        // Round to whole numbers for cleaner display
        for (int i = 0; i < 3; i++)
        {
            endPos[i] = float(RoundToFloor(endPos[i]));
        }
        
        // Show a marker at the current aim position with appropriate color
        int color[4] = {0, 255, 0, 255}; // Green for point 1
        if (g_iAreaStep[client] == 2)
        {
            color = {255, 165, 0, 255}; // Orange for point 2
        }
        
        TE_SetupBeamRingPoint(endPos, 5.0, 8.0, g_iLaserMaterial, g_iHaloMaterial, 0, 15, 0.1, 2.0, 0.0, color, 1, 0);
        TE_SendToClient(client);
        
        // If we have both points, preview the area
        if (g_iAreaStep[client] == 2)
        {
            float mins[3], maxs[3], center[3];
            
            // Calculate area bounds
            for (int i = 0; i < 3; i++)
            {
                mins[i] = (g_fAreaPoints[client][0][i] < endPos[i]) ? g_fAreaPoints[client][0][i] : endPos[i];
                maxs[i] = (g_fAreaPoints[client][0][i] > endPos[i]) ? g_fAreaPoints[client][0][i] : endPos[i];
            }
            
            // Calculate center
            for (int i = 0; i < 3; i++)
            {
                center[i] = (mins[i] + maxs[i]) / 2.0;
            }
            
            // Adjust mins and maxs to be relative to center
            float relMins[3], relMaxs[3];
            for (int i = 0; i < 3; i++)
            {
                relMins[i] = mins[i] - center[i];
                relMaxs[i] = maxs[i] - center[i];
            }
            
            // Draw preview box
            int Color[4] = { 0, 255, 255, 255 }; // Cyan
            TE_SendBeamBoxToClient(client, mins, maxs, g_iLaserMaterial, g_iHaloMaterial, 0, 30, 0.1, 3.0, 3.0, 2, 1.0, Color, 0);
            
            // Display dimensions
            float width = maxs[0] - mins[0];
            float length = maxs[1] - mins[1];
            float height = maxs[2] - mins[2];
            
            // Show dimensions to client
            PrintHintText(client, "Area Dimensions: %.0f x %.0f x %.0f units", width, length, height);
        }
        else
        {
            // Show current vertical offset when in first step
            PrintHintText(client, "Height offset: %.0f units (Use mouse buttons to adjust)", g_fVerticalOffset[client]);
        }
    }
    
    return Plugin_Continue;
}

public Action OnClientPreThink(int client)
{
    if (!IsClientInGame(client) || !g_bCreatingArea[client])
        return Plugin_Continue;
    
    // Get current buttons
    int currentButtons = GetClientButtons(client);
    
    // Mouse1 (left click) for decreasing height
    if ((currentButtons & IN_ATTACK) && !(g_iPreviousButtons[client] & IN_ATTACK))
    {
        float currentTime = GetGameTime();
        float timeSinceLastClick = currentTime - g_fLastClickTime[client];
        
        // Check for double click to set point
        if (timeSinceLastClick <= DOUBLE_CLICK_TIME)
        {
            ProcessAreaClick(client);
            // Reset time to avoid triple-click issues
            g_fLastClickTime[client] = 0.0;
        }
        else
        {
            // Not a double click, adjust height down
            g_fVerticalOffset[client] -= HEIGHT_ADJUST_INCREMENT;
            PrintHintText(client, "Height: %.0f units | Mouse1 ↓ Mouse2 ↑ | Double-click to set", g_fVerticalOffset[client]);
            EmitSoundToClient(client, "buttons/button14.wav", _, _, SNDLEVEL_NORMAL);
            
            // Save this click time
            g_fLastClickTime[client] = currentTime;
        }
    }
    
    // Mouse2 (right click) for increasing height
    if ((currentButtons & IN_ATTACK2) && !(g_iPreviousButtons[client] & IN_ATTACK2))
    {
        g_fVerticalOffset[client] += HEIGHT_ADJUST_INCREMENT;
        PrintHintText(client, "Height: %.0f units | Mouse1 ↓ Mouse2 ↑ | Double-click to set", g_fVerticalOffset[client]);
        EmitSoundToClient(client, "buttons/button14.wav", _, _, SNDLEVEL_NORMAL);
    }
    
    // Store current button state for next frame
    g_iPreviousButtons[client] = currentButtons;
    
    return Plugin_Continue;
}

void ProcessAreaClick(int client)
{
    float eyePos[3], eyeAng[3], endPos[3];
    GetClientEyePosition(client, eyePos);
    GetClientEyeAngles(client, eyeAng);
    
    TR_TraceRayFilter(eyePos, eyeAng, MASK_SOLID, RayType_Infinite, TraceFilterPlayers);
    
    if (TR_DidHit())
    {
        TR_GetEndPosition(endPos);
        
        // Apply vertical offset
        endPos[2] += g_fVerticalOffset[client];
        
        // Round to whole numbers
        for (int i = 0; i < 3; i++)
        {
            endPos[i] = float(RoundToFloor(endPos[i]));
        }
        
        if (g_iAreaStep[client] == 1)
        {
            // Set first point
            for (int i = 0; i < 3; i++)
            {
                g_fAreaPoints[client][0][i] = endPos[i];
            }
            
            PrintToChat(client, "[SM] First corner set at: %.0f, %.0f, %.0f (offset: %.0f)", 
                endPos[0], endPos[1], endPos[2] - g_fVerticalOffset[client], g_fVerticalOffset[client]);
            PrintToChat(client, "[SM] Now point at second corner and double-click again.");
            
            // Reset vertical offset for consistency between points
            g_fVerticalOffset[client] = 0.0;
            
            g_iAreaStep[client] = 2;
        }
        else if (g_iAreaStep[client] == 2)
        {
            // Set second point
            for (int i = 0; i < 3; i++)
            {
                g_fAreaPoints[client][1][i] = endPos[i];
            }
            
            PrintToChat(client, "[SM] Second corner set at: %.0f, %.0f, %.0f (offset: %.0f)", 
                endPos[0], endPos[1], endPos[2] - g_fVerticalOffset[client], g_fVerticalOffset[client]);
            
            // Calculate area dimensions
            float mins[3], maxs[3];
            
            // Get min and max for each coordinate
            for (int i = 0; i < 3; i++)
            {
                mins[i] = (g_fAreaPoints[client][0][i] < g_fAreaPoints[client][1][i]) ? g_fAreaPoints[client][0][i] : g_fAreaPoints[client][1][i];
                maxs[i] = (g_fAreaPoints[client][0][i] > g_fAreaPoints[client][1][i]) ? g_fAreaPoints[client][0][i] : g_fAreaPoints[client][1][i];
            }
            
            // Calculate center
            for (int i = 0; i < 3; i++)
            {
                g_fAreaCenter[client][i] = (mins[i] + maxs[i]) / 2.0;
            }
            
            // Set bounds relative to center
            for (int i = 0; i < 3; i++)
            {
                g_fMinBounds[client][i] = mins[i] - g_fAreaCenter[client][i];
                g_fMaxBounds[client][i] = maxs[i] - g_fAreaCenter[client][i];
            }
            
            // Cleanup
            CleanupPreview(client);
            g_bCreatingArea[client] = false;
            g_iAreaStep[client] = 0;
            g_fVerticalOffset[client] = 0.0;
            
            // Proceed to team selection
            DisplayTeamSelectionMenu(client);
        }
    }
}

public bool TraceFilterPlayers(int entity, int contentsMask)
{
    return entity > MaxClients;
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
            
            // Show confirmation menu with information about the zone
            Menu confirmMenu = new Menu(ConfirmZoneCreation);
            
            // Calculate dimensions
            float width = g_fMaxBounds[param1][0] - g_fMinBounds[param1][0];
            float length = g_fMaxBounds[param1][1] - g_fMinBounds[param1][1];
            float height = g_fMaxBounds[param1][2] - g_fMinBounds[param1][2];
            
            confirmMenu.SetTitle("Create Sticky Removal Zone?");
            
            char infoText[128];
            Format(infoText, sizeof(infoText), "Size: %.0f x %.0f x %.0f units", width, length, height);
            confirmMenu.AddItem("size", infoText, ITEMDRAW_DISABLED);
            
            char teamName[32];
            switch (g_iZoneTeam[param1])
            {
                case TEAM_ALL: strcopy(teamName, sizeof(teamName), "All Teams");
                case TEAM_RED: strcopy(teamName, sizeof(teamName), "RED Team");
                case TEAM_BLU: strcopy(teamName, sizeof(teamName), "BLU Team");
            }
            
            Format(infoText, sizeof(infoText), "Team: %s", teamName);
            confirmMenu.AddItem("team", infoText, ITEMDRAW_DISABLED);
            
            Format(infoText, sizeof(infoText), "Position: %.0f, %.0f, %.0f", 
                g_fAreaCenter[param1][0], g_fAreaCenter[param1][1], g_fAreaCenter[param1][2]);
            confirmMenu.AddItem("position", infoText, ITEMDRAW_DISABLED);
            
            confirmMenu.AddItem("yes", "Create Zone");
            confirmMenu.AddItem("no", "Cancel");
            
            confirmMenu.Display(param1, MENU_TIME_FOREVER);
        }
        case MenuAction_End: delete menu;
    }

    return 0;
}

public int ConfirmZoneCreation(Menu menu, MenuAction action, int param1, int param2)
{
    switch (action)
    {
        case MenuAction_Select:
        {
            char info[32];
            menu.GetItem(param2, info, sizeof(info));
            
            if (StrEqual(info, "yes"))
            {
                CreateZoneAtClient(param1);
                PrintToChat(param1, "[SM] Sticky removal zone created successfully!");
            }
            else
            {
                PrintToChat(param1, "[SM] Zone creation cancelled.");
            }
        }
        case MenuAction_End: delete menu;
    }

    return 0;
}

void CreateZoneAtClient(int client)
{
    float pos[3];
    for (int i = 0; i < 3; i++)
    {
        pos[i] = g_fAreaCenter[client][i];
    }
    
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
        
        // Draw the area outline before deleting
        int color[4] = { 255, 0, 0, 255 }; // Red for deletion
        float vector1[3], vector2[3];
        AddVectors(zonePos, zoneMin, vector1);
        AddVectors(zonePos, zoneMax, vector2);
        TE_SendBeamBoxToClient(client, vector1, vector2, g_iLaserMaterial, g_iHaloMaterial, 0, 30, 5.0, 5.0, 5.0, 2, 1.0, color, 0);
        
        // Confirm deletion
        Menu confirmMenu = new Menu(DeleteConfirm_Menu);
        SetMenuTitle(confirmMenu, "Delete this Sticky Removal Zone?");
        
        // Store entity reference in a hidden info field
        char entityRef[16];
        IntToString(EntIndexToEntRef(closestZone), entityRef, sizeof(entityRef));
        
        AddMenuItem(confirmMenu, entityRef, "Yes, Delete It");
        AddMenuItem(confirmMenu, "no", "No, Cancel");
        
        confirmMenu.Display(client, 10);
    }
    else
    {
        PrintToChat(client, "[SM] There isn't any nearby sticky removal zone to delete.");
    }
}

public int DeleteConfirm_Menu(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_Select)
    {
        char info[32];
        GetMenuItem(menu, param2, info, sizeof(info));
        
        if (!StrEqual(info, "no"))
        {
            // Convert string back to entity reference
            int entRef = StringToInt(info);
            int entity = EntRefToEntIndex(entRef);
            
            if (entity != INVALID_ENT_REFERENCE)
            {
                float entPos[3], zoneMin[3], zoneMax[3];
                GetEntPropVector(entity, Prop_Send, "m_vecOrigin", entPos);
                GetEntPropVector(entity, Prop_Send, "m_vecMins", zoneMin);
                GetEntPropVector(entity, Prop_Send, "m_vecMaxs", zoneMax);
                
                char query[512];
                Format(query, sizeof(query), "DELETE FROM TF2_StickyRemovalZones WHERE "
                    ... "locX = %f AND locY = %f AND locZ = %f AND "
                    ... "minX = %f AND minY = %f AND minZ = %f AND "
                    ... "maxX = %f AND maxY = %f AND maxZ = %f LIMIT 1;", 
                    entPos[0], entPos[1], entPos[2],
                    zoneMin[0], zoneMin[1], zoneMin[2],
                    zoneMax[0], zoneMax[1], zoneMax[2]);
                g_DB.Query(SQL_OnZoneDeleted, query);
                
                RemoveEntity(entity);
                PrintToChat(param1, "[SM] Sticky removal zone deleted!");
            }
            else
            {
                PrintToChat(param1, "[SM] Error: The sticky removal zone was no longer valid.");
            }
        }
        else
        {
            PrintToChat(param1, "[SM] Deletion cancelled.");
        }
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }
    
    return 0;
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
    
    // Create the additional corners of the box
    tc1[0] = bottomcorner[0];
    tc1[1] = uppercorner[1];
    tc1[2] = uppercorner[2];
    
    tc2[0] = uppercorner[0];
    tc2[1] = bottomcorner[1];
    tc2[2] = uppercorner[2];
    
    tc3[0] = uppercorner[0];
    tc3[1] = uppercorner[1];
    tc3[2] = bottomcorner[2];
    
    tc4[0] = uppercorner[0];
    tc4[1] = bottomcorner[1];
    tc4[2] = bottomcorner[2];
    
    tc5[0] = bottomcorner[0];
    tc5[1] = uppercorner[1];
    tc5[2] = bottomcorner[2];
    
    tc6[0] = bottomcorner[0];
    tc6[1] = bottomcorner[1];
    tc6[2] = uppercorner[2];
    
    // Draw all the edges
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