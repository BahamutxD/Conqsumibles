-- Conq_raidlog.lua
--  Raid logging system for tracking consumable usage, buff uptimes, and player participation
-- Version 2.0.0

CQ_Log = {
    isLogging = false,
    isPendingCombat = false, -- True when in a raid zone but waiting for first combat before logging starts
    currentRaidId = nil,
    lastCheckTime = 0,
    checkInterval = 15, -- Check every 15 seconds (reduced from 10 to minimize stuttering)
    currentZone = nil,
    sessionStartTime = nil,
    combatStartTime = nil,
    inCombat = false,
    trackOutOfCombat = true, -- Option to track data even when not in combat
    trackLoot = true, -- Option to track loot and gold drops
    trackDeaths = true, -- Option to track player deaths
    trackSunders = true, -- Option to track Sunder Armor casts
    -- Loot quality filter: table of quality levels to track.
    -- Keys: "poor"(0), "common"(1), "uncommon"(2), "rare"(3), "epic"(4), "legendary"(5)
    -- Default: track uncommon (green) and above only.
    trackLootQualities = {
        poor      = false, -- grey
        common    = false, -- white
        uncommon  = true,  -- green
        rare      = true,  -- blue
        epic      = true,  -- purple
        legendary = true,  -- orange
    },
    debugPotions = false, -- Enable debug output for potion tracking
    debugConsumables = false, -- Enable debug output for consumable tracking
    sniffing = false, -- Sniff all combat log events to find weapon enchant message
    lastParticipationCheck = 0, -- Track when we last updated participation times
    autoExportInterval = 600, -- Export every 10 minutes (600 seconds)
    lastExportTime = 0,
    hasFileExport = false, -- true when WriteCustomFile (CustomData/) is available
    exportFormat = "lua", -- "lua" or "json"
    verboseExport = false, -- true = full key names in export, false = shortened (default)
    autoUploadOnFinalize = false, -- true = auto-upload to Discord bot when raid ends
    cachedTrackedConsumables = nil, -- Cached result of GetTrackedConsumables(), built at raid start
    -- Grace period removed: safe zone map handles cross-zone raids instead
};

-- Raid zones to track
CQ_Log_ValidZones = {
    ["Molten Core"] = true,
    ["Blackwing Lair"] = true,
    ["Ruins of Ahn'Qiraj"] = true,
    ["Temple of Ahn'Qiraj"] = true,
    ["Naxxramas"] = true,
    ["The Upper Necropolis"] = true,
    ["Zul'Gurub"] = true,
    ["Emerald Sanctum"] = true,
    ["Tower of Karazhan"] = true,
    ["The Rock of Desolation"] = true
};

-- Item quality lookup: the first 6 chars of the colour code in an item link
-- map to a quality level name.  Item links are formatted as:
--   |cff<RRGGBB>|Hitem:...|h[Name]|h|r
-- These are the standard WoW 1.12 item quality colours (all lowercase hex).
CQ_Log_QualityColors = {
    ["ff9d9d9d"] = "poor",       -- grey  (Quality 0)
    ["ffffffff"] = "common",     -- white (Quality 1)
    ["ff1eff00"] = "uncommon",   -- green (Quality 2)
    ["ff0070dd"] = "rare",       -- blue  (Quality 3)
    ["ffa335ee"] = "epic",       -- purple(Quality 4)
    ["ffff8000"] = "legendary",  -- orange(Quality 5)
    ["ffe6cc80"] = "artifact",   -- tan   (Quality 6 – Artifact/heirloom, rare on 1.12)
};

-- Returns the quality name string for an item link, or "unknown".
function CQ_Log_GetLinkQuality(itemLink)
    if not itemLink then return "unknown"; end
    -- Item links start with |c followed by 8 hex chars
    local _, _, colorHex = string.find(itemLink, "^|c(%x%x%x%x%x%x%x%x)");
    if colorHex then
        local q = CQ_Log_QualityColors[strlower(colorHex)];
        if q then return q; end
    end
    return "unknown";
end

-- Returns true when the given quality name passes the current filter.
function CQ_Log_QualityAllowed(qualityName)
    if not CQ_Log.trackLootQualities then return true; end
    -- "unknown" quality always passes so we never silently drop weird items.
    if qualityName == "unknown" or qualityName == "artifact" then return true; end
    return CQ_Log.trackLootQualities[qualityName] ~= false;
end

-- Safe zones per raid group: zones where you land when you die/release.
-- When the active raid's safe zone is entered, logging continues rather than finalizing.
-- Multiple raids can share a safe zone (e.g. MC+BWL both use Searing Gorge).
CQ_Log_RaidGroups = {
    {
        zones     = { ["Molten Core"] = true, ["Blackwing Lair"] = true },
        safeZones = { ["Searing Gorge"] = true, ["Blackrock Mountain"] = true },
    },
    {
        zones    = { ["Zul'Gurub"] = true },
        safeZone = "Stranglethorn Vale"
    },
    {
        zones    = { ["Ruins of Ahn'Qiraj"] = true, ["Temple of Ahn'Qiraj"] = true },
        safeZone = "Silithus"
    },
    {
		zones    = { ["Naxxramas"] = true, ["The Upper Necropolis"] = true },
        safeZone = "Eastern Plaguelands"
    },
    {
        zones    = { ["Emerald Sanctum"] = true },
        safeZone = "Hyjal"
    },
    {
        zones    = { ["Tower of Karazhan"] = true, ["The Rock of Desolation"] = true },
        safeZone = "Deadwind Pass"
    },
};

-- Returns the safe zone for whichever raid group contains the given zone, or nil.
function CQ_Log_GetSafeZone(zone)
    for _, group in ipairs(CQ_Log_RaidGroups) do
        if group.zones[zone] then
            -- Support both new multi-zone table and legacy single-string formats
            return group.safeZones or group.safeZone;
        end
    end
    return nil;
end

-- Returns true if the given zone is a safe zone for the currently active raid.
function CQ_Log_IsActiveSafeZone(zone)
    if not CQ_Log.currentZone then return false; end
    for _, group in ipairs(CQ_Log_RaidGroups) do
        if group.zones[CQ_Log.currentZone] then
            -- Handle both new safeZones table and legacy safeZone string
            if group.safeZones then
                return group.safeZones[zone] == true;
            else
                return group.safeZone == zone;
            end
        end
    end
    return false;
end

-- Consumable durations in seconds (can be edited for custom server values)
-- CQ_Log_ConsumableDurations: buffKey -> duration in seconds.
--
-- This table is populated automatically at load time by
-- CQ_ConsInt_BuildDurationsTable() in Conq_ConsumableIntegration.lua,
-- which reads the duration field from each CQ_Buffs entry.
--
-- To change a duration: edit the duration field on the CQ_Buffs entry in
-- Conq_buffs.lua. You only need to add an entry here if you want to OVERRIDE
-- a value that is already defined in CQ_Buffs, or for keys that have no
-- CQ_Buffs entry (e.g. legacy keys kept for backward compat).
CQ_Log_ConsumableDurations = {
    -- Legacy key kept for backward compatibility with old saved variables.
    bogling = 600,
    -- Class buffs are tracked by SPELL_GO (stored in raid.spells, not consumables).
    -- Do NOT add class buff keys here; they would cause the buff scanner to
    -- double-count every player who has the buff.
};

-- Potion/Tea tracking patterns
-- Self:   "You gain 1741 Mana from Restore Mana."
-- Self:   "You gain 983 Mana from Tea."
-- Others: "Durotavich gains 2218 Mana from Durotavich 's Restore Mana."
-- Others: "Durotavich gains 913 Mana from Durotavich 's Tea."
-- Patterns are broad enough to catch both formats.
CQ_Log_PotionPatterns = {
    majorMana = {
        "Restore Mana",   -- Matches "from Restore Mana" and "from Name 's Restore Mana"
    },
    nordanaarTea = {
        "from.*Tea",      -- Matches "from Tea" and "from Name 's Tea" but not "Your Tea heals"
    },
    limitinvulpotion = {
        "Invulnerability", -- Matches "You gain Invulnerability." and "Name gains Invulnerability."
    },
};

-- ============================================================================
-- UNIT_CASTEVENT-BASED CONSUMABLE USE COUNTING
-- ============================================================================
-- SuperWOW's UNIT_CASTEVENT fires for every player in the raid when they use
-- a consumable, identified by spell ID.  This is the authoritative source for
-- application counts — it works for all players, fires at the exact moment of
-- use, and covers elixirs which produce no named chat message for other players.
--
-- Spell IDs verified via /conqlog dcl testing on this server (confirmed):
--   spellID 26276  → Greater Firepower     (greaterfirepower)   [DCL confirmed]
--   spellID 56544  → Greater Frost Power   (greaterfrostpower)  [DCL confirmed]
--   spellID 24382  → Spirit of Zanza       (spiritofzanza)      [DCL confirmed]
--   spellID 6615   → Free Action           (freeactionpotion)   [DCL confirmed]
--   spellID 29432  → Frozen Rune           (frozenrune)         [DCL confirmed]
--   spellID 17543  → Greater Fire Prot.    (greaterfirepot)     [DCL confirmed]
--   spellID 3593   → Health II / Fortitude (elixirfortitude)    [DCL confirmed]
--   spellID 19398  → Tea                   (nordanaarTea - potions table)
--   spellID 17531  → Restore Mana          (majorMana - potions table)
--   spellID 25122  → Brilliant Wizard Oil  (brilliantwizardoil - enchant table)
--   spellID 57107  → Medivh's Merlot Blue  (merlotblue - cast ID confirmed via DCL)
-- All other IDs sourced from RABuffs_buffs.lua identifiers[].spellId.
--
-- When SuperWOW is absent this table still exists; the handler simply never
-- fires so the polling system remains the fallback for application counting.
--
-- Dedup window (60 s): Mageblood fires SPELL_GO every 5 s while active
-- (periodic re-cast); the window collapses those into a single "use".
CQ_Log_ConsumableSpellIDs = {
    -- ---- Flasks ------------------------------------------------------------
    [17628] = "flask",              -- Flask of Supreme Power
    [17626] = "titans",             -- Flask of the Titans
    [17627] = "wisdom",             -- Flask of Distilled Wisdom
    [17629] = "chromaticres",       -- Flask of Chromatic Resistance
    -- ---- Elixirs – Battle --------------------------------------------------
    [11405] = "giants",             -- Elixir of the Giants
    [17538] = "mongoose",           -- Elixir of the Mongoose
    [11334] = "greateragilityelixir", -- Elixir of Greater Agility
    [11328] = "agilityelixir",      -- Elixir of Agility
    [17038] = "firewater",          -- Winterfall Firewater
    [11406] = "demonslaying",       -- Elixir of Demonslaying
    -- ---- Elixirs – Guardian ------------------------------------------------
    [3593]  = "elixirfortitude",    -- Elixir of Fortitude (buff: Health II)  ← DCL confirmed
    [11348] = "supdef",             -- Elixir of Superior Defense
    -- ---- Elixirs – Spell Power ---------------------------------------------
    [17539] = "greaterarcane",      -- Greater Arcane Elixir
    [26276] = "greaterfirepower",   -- Elixir of Greater Firepower            ← DCL confirmed
    [56545] = "greaterarcanepower", -- Elixir of Greater Arcane Power
    [56544] = "greaterfrostpower",  -- Elixir of Greater Frost Power          ← DCL confirmed
    [45988] = "greaternaturepower", -- Elixir of Greater Nature Power
    [21920] = "frostpower",         -- Elixir of Frost Power
    [11474] = "shadowpower",        -- Elixir of Shadow Power
    [45427] = "dreamshard",         -- Dreamshard Elixir
    [45489] = "dreamtonic",         -- Dreamtonic
    [11390] = "arcaneelixir",       -- Arcane Elixir
    [7844]  = "firepowerelixir",    -- Elixir of Firepower
    [17535] = "elixirofthesages",   -- Elixir of the Sages
    -- ---- Utility Potions ---------------------------------------------------
    [24363] = "mageblood",          -- Mageblood Potion (Mana Regeneration)
    [6615]  = "freeactionpotion",   -- Free Action Potion                     ← DCL confirmed
    [11359] = "restorativepotion",  -- Restorative Potion
    -- ---- Protection Potions ------------------------------------------------
    [17543] = "greaterfirepot",     -- Greater Fire Protection Potion         ← DCL confirmed
    [17544] = "greaterfrostpot",    -- Greater Frost Protection Potion
    [17546] = "greaternaturepot",   -- Greater Nature Protection Potion
    [17548] = "greatershadowpot",   -- Greater Shadow Protection Potion
    [17549] = "greaterarcanepot",   -- Greater Arcane Protection Potion
    [17545] = "greaterholypot",     -- Greater Holy Protection Potion
    [29432] = "frozenrune",         -- Frozen Rune (Fire Protection)          ← DCL confirmed
    -- ---- Zanza Potions -----------------------------------------------------
    [24382] = "spiritofzanza",      -- Spirit of Zanza                        ← DCL confirmed
    [24383] = "swiftnessofzanza",   -- Swiftness of Zanza
    [24417] = "sheenofzanza",       -- Sheen of Zanza
    -- ---- Juju Buffs --------------------------------------------------------
    [16323] = "jujupower",          -- Juju Power
    [16329] = "jujumight",          -- Juju Might
    [16325] = "jujuchill",          -- Juju Chill
    [16322] = "jujuflurry",         -- Juju Flurry
    [16321] = "jujuescape",         -- Juju Escape
    [16326] = "jujuember",          -- Juju Ember
    [16327] = "jujuguile",          -- Juju Guile
    -- ---- Blasted Lands Buffs -----------------------------------------------
    [10667] = "roids",              -- R.O.I.D.S. (Rage of Ages)
    [10669] = "scorpok",            -- Ground Scorpok Assay (Strike of the Scorpok)
    [10692] = "cerebralcortex",     -- Cerebral Cortex Compound
    [10668] = "lungJuice",          -- Lung Juice Cocktail
    [10693] = "gizzardgum",         -- Gizzard Gum
    -- ---- Concoctions -------------------------------------------------------
    [36931] = "arcanegiants",       -- Concoction of the Arcane Giant
    [36928] = "emeraldmongoose",    -- Concoction of the Emerald Mongoose
    [36934] = "dreamwater",         -- Concoction of the Dreamwater
    -- ---- Food & Drink ------------------------------------------------------
    -- All cast spell IDs confirmed via DCL in-game testing.
    [18230] = "squid",              -- Grilled Squid
    [18233] = "nightfinsoup",       -- Nightfin Soup
    [22731] = "tuber",              -- Runn Tum Tuber Surprise
    [24800] = "desertdumpling",     -- Smoked Desert Dumpling / Power Mushroom
    [25660] = "mushroomstam",       -- Hardened Mushroom
    [10256] = "tenderwolf",         -- Tender Wolf Steak
    [25888] = "sagefish",           -- Sagefish Delight
    [15852] = "dragonbreathchili",  -- Dragonbreath Chili
    [46084] = "gurubashigumbo",     -- Gurubashi Gumbo
    [57045] = "telabimmedley",      -- Tel'Abim Medley
    [57043] = "telabimdelight",     -- Tel'Abim Delight
    [57055] = "telabimsurprise",    -- Tel'Abim Surprise
    [45626] = "gilneashotstew",     -- Gilneas Hot Stew
    [22789] = "gordokgreengrog",    -- Gordok Green Grog
    [25804] = "rumseyrum",          -- Rumsey Rum Black Label
    [57106] = "merlot",             -- Medivh's Merlot
    [57107] = "merlotblue",         -- Medivh's Merlot Blue Label
    [49552] = "herbalsalad",        -- Herbal Salad
};

-- Lookup set: buffKeys tracked via SPELL_GO.
-- The polling loop skips application-counting for these keys; the event is authoritative.
CQ_Log_CastTrackedKeys = {};
for _, buffKey in pairs(CQ_Log_ConsumableSpellIDs) do
    CQ_Log_CastTrackedKeys[buffKey] = true;
end

-- Dedup: ignore repeated SPELL_GO fires for the same player+key within this window.
-- Mageblood is a periodic buff that re-fires every 5s; 60s collapses that into one use.
CQ_Log_BuffUseDedup = {};
CQ_Log_BUFFUSE_DEDUP_WINDOW = 60; -- seconds

-- ============================================================================
-- SPELL_GO handler for consumable use counting (Nampower).
-- Nampower: arg1=itemId, arg2=spellID, arg3=casterGUID
-- ============================================================================
-- Named handler so CQ_SimulateCastEvent can call it directly for testing.
-- Reads arg2 (spellID) and arg3 (casterGUID) from globals, exactly as Nampower sets them.
-- NOTE: This function is no longer called by a frame event. The unified
-- CQ_SpellGoFrame dispatcher (below) handles consumable SPELL_GO events.
-- Kept here because CQ_SimulateCastEvent (Conq_MinimapButton.lua) calls it
-- directly for UI testing. CQ_SimulateCastEvent always pre-seeds CQ_Log_GuidMap
-- with the target player's GUID before calling this, so the tier-1 cache hit
-- always fires and the tier-2 GetUnitGUID scan below is never reached in
-- normal test usage. Do not remove without updating the simulate tab.
function CQ_Log_OnConsumableSpellGo()
    local spellID    = arg2;
    local casterGuid = arg3;

    local buffKey = CQ_Log_ConsumableSpellIDs[spellID];
    if not buffKey then return; end
    if not CQ_Log.isLogging then return; end
    if CQ_Log.trackedItems and CQ_Log.trackedItems[buffKey] == false then return; end

    local playerName;

    -- Tier 1: GUID cache
    playerName = CQ_Log_GuidMap[casterGuid];
    -- Tier 2: GetUnitGUID roster scan
    if not playerName then
        if GetUnitGUID("player") == casterGuid then
            playerName = UnitName("player");
        else
            for i = 1, GetNumRaidMembers() do
                if GetUnitGUID("raid" .. i) == casterGuid then
                    playerName = UnitName("raid" .. i);
                    break;
                end
            end
        end
        if playerName then CQ_Log_GuidMap[casterGuid] = playerName; end
    end

    if not playerName then
        if CQ_Log.debugConsumables then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[CONS CAST] Unresolved GUID spellID=" ..
                tostring(spellID) .. " key=" .. buffKey .. "|r");
        end
        return;
    end

    CQ_Log_RecordBuffUse(playerName, buffKey);
end

-- CQ_ConsumableCastFrame, CQ_ClassBuffCastFrame, and CQ_SunderCastFrame have
-- been consolidated into CQ_SpellGoFrame below. See unified dispatcher.

-- ============================================================================

-- Goblin Sapper Charge and Stratholme Holy Water both fire many damage hits per
-- detonation (one per target hit). We deduplicate by recording the last time we
-- counted one for each player; any further hits within SAPPER_DEDUP_WINDOW seconds
-- are ignored. Holy Water shares the same dedup table keyed by "<player>_holywater".
CQ_Log_SapperDedup = {};   -- [playerName] = GetTime() of last counted detonation
CQ_Log_SAPPER_DEDUP_WINDOW = 2; -- seconds

-- Raid log data. Guarded so the SavedVariable loaded from disk is never
-- overwritten at file-load time (PLAYER_LOGIN hasn't fired yet here).
-- The bootstrap in Conq_core.lua and CQ_Log_Init() will fill any gaps.
if type(CQui_RaidLogs) ~= "table" then
    CQui_RaidLogs = { raids = {}, version = "2.0.0" };
end
if type(CQui_RaidLogs.raids) ~= "table" then
    CQui_RaidLogs.raids = {};
end

-- GUID -> playerName cache, populated lazily as names are resolved.
-- Declared here (before the SPELL_GO frames below) so it is never nil
-- when a spell event fires at load time.
CQ_Log_GuidMap = {};

-- Queue of unresolved GUIDs waiting for name resolution via chat events.
-- Each entry: { guid, timestamp }
CQ_Log_PendingGuidQueue = {};
CQ_Log_GUID_RESOLVE_WINDOW = 1.0; -- seconds

-- Check Nampower API availability and configure export flag.
function CQ_Log_CheckSuperwow()
    local hasNamepower = (GetNampowerVersion ~= nil);
    local hasWriteFile = (WriteCustomFile   ~= nil);
    local hasGuid      = (GetUnitGUID       ~= nil);

    if hasNamepower then
        local major, minor, patch = GetNampowerVersion();
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RAB Log] Nampower v" ..
            major .. "." .. minor .. "." .. patch ..
            " writeFile=" .. tostring(hasWriteFile) ..
            " guid=" .. tostring(hasGuid) .. "|r");
    else
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cffff9900[RAB Log] Nampower not detected. Install Nampower for full functionality.|r");
    end

    CQ_Log.hasFileExport = hasWriteFile and true or false;

    return hasNamepower or hasWriteFile or hasGuid;
end

-- date() is a Lua 5.1 stdlib function exposed by SuperWOW but absent in the
-- vanilla WoW 1.12 sandbox.  This wrapper falls back to time()-based string.
local function CQ_SafeDate(fmt)
    if date then
        return date(fmt);
    end
    local t = time();
    local h, m = GetGameTime();
    h = math.floor(h or 0);
    m = math.floor(m or 0);
    if fmt == "%Y%m%d_%H%M%S" or fmt == "%d%m%y_%H%M%S" then
        return string.format("%010d_%02d%02d00", t, h, m);
    elseif fmt == "%Y-%m-%d %H:%M:%S" then
        return string.format("epoch-%d %02d:%02d:00", t, h, m);
    else
        return tostring(t);
    end
end

-- Escape string for JSON/Lua output
function CQ_Log_EscapeString(str)
    if not str then return ""; end
    str = string.gsub(str, "\\", "\\\\");
    str = string.gsub(str, "\"", "\\\"");
    str = string.gsub(str, "\n", "\\n");
    str = string.gsub(str, "\r", "\\r");
    str = string.gsub(str, "\t", "\\t");
    return str;
end

-- Check if a player has any potion/tea usage - NEW FUNCTION
function CQ_Log_HasPotionUsage(playerPotionData)
    if not playerPotionData then return false; end
    
    local totalUsage = (playerPotionData.majorMana or 0)
                     + (playerPotionData.nordanaarTea or 0)
                     + (playerPotionData.limitinvulpotion or 0);
    return totalUsage > 0;
end

-- Filter player data to remove players with 0 potion/tea usage - NEW FUNCTION
function CQ_Log_FilterPotionData(potionsTable)
    local filtered = {};
    
    for playerName, potionData in pairs(potionsTable) do
        if CQ_Log_HasPotionUsage(potionData) then
            filtered[playerName] = potionData;
        end
    end
    
    return filtered;
end

-- Serialize a Lua table to Lua format - MODIFIED for filtering
-- Key shortening map: long name -> short name in export
CQ_Log_KeyMap = {
    -- top-level raid fields
    ["startTime"]          = "st",
    ["endTime"]            = "et",
    ["zone"]               = "zone",   -- keep: only appears once
    ["players"]            = "players", -- keep: section header
    ["deaths"]             = "deaths",  -- keep: section header
    ["loot"]               = "loot",    -- keep: section header
    ["spells"]             = "spells",  -- keep: section header
    ["metadata"]           = "meta",
    ["castTrackedConsumables"] = "ctc",
    -- metadata fields
    ["playerName"]         = "pn",
    ["playerRealm"]        = "pr",
    ["playerGuild"]        = "pg",
    ["lockoutId"]          = "lid",
    ["addonVersion"]       = "av",
    ["raidSize"]           = "rs",
    -- player fields
    ["class"]              = "cl",
    ["firstSeen"]          = "fs",
    ["lastSeen"]           = "ls",
    ["participationTime"]  = "pt",
    ["consumables"]        = "cons",
    -- consumable fields
    ["applications"]       = "app",
    ["totalUptime"]        = "tu",
    ["lastCheckHad"]       = "lch",
    ["lastCheckTime"]      = "lct",
    ["lastTimeRemaining"]  = "ltr",
    -- death fields
    ["killedBy"]           = "kb",
    ["timestamp"]          = "ts",
    ["totalMoneyCopper"]   = "tmc",  -- raid-level total money in copper
    -- loot fields
    ["itemId"]             = "iid",
    ["itemName"]           = "in",   -- NEW: Add item name mapping
    ["itemQuality"]        = "iq",   -- item quality name (poor/common/uncommon/rare/epic/legendary)
    ["quantity"]           = "qty",
    -- spell/sunder fields
    ["count"]              = "cnt",
    ["spellName"]          = "sn",
    -- castTrackedConsumables fields
    ["buffKey"]            = "bk",
    ["consumableName"]     = "cn",
    ["spellID"]            = "sid",
    -- ["timestamp"] already mapped above under death fields
};

function CQ_Log_ShortKey(key)
    if CQ_Log.verboseExport then
        return key;
    end
    return CQ_Log_KeyMap[key] or key;
end

-- Fields that are internal polling/tracking state and should never appear in exports.
-- They are used at runtime to drive change-detection but carry no meaning to the
-- parser or recovery system.
local CQ_Log_ExcludeFromExport = {
    ["preRaidCredited"]   = true,  -- pre-raid buff credit guard flag
    ["lastCheckHad"]      = true,  -- previous poll: did player have the buff?
    ["lastCheckTime"]     = true,  -- wall-clock time of last poll
    ["lastTimeRemaining"] = true,  -- buff duration seen at last poll
    ["isBaselineScan"]    = true,  -- cleared after first PerformCheck pass
};

function CQ_Log_SerializeToLua(tbl, indent, maxDepth, isRootRaid)
    indent = indent or 0;
    maxDepth = maxDepth or 10;

    if indent > maxDepth then
        return "nil";
    end

    local spacing = string.rep(" ", indent);
    local parts = {};
    table.insert(parts, "{\n");

    -- Sort keys for consistent output
    local keys = {};
    for key, _ in pairs(tbl) do
        table.insert(keys, key);
    end
    table.sort(keys, function(a, b)
        if type(a) == type(b) then
            return tostring(a) < tostring(b);
        end
        return type(a) < type(b);
    end);

    for _, key in ipairs(keys) do
        local value = tbl[key];

        -- FILTER: skip internal runtime fields that have no meaning in the export
        if type(key) == "string" and CQ_Log_ExcludeFromExport[key] then
            value = nil;
        end

        -- FILTER: skip empty tables
        if type(value) == "table" and next(value) == nil then
            value = nil;
        end

        -- FILTER: potions block - strip empty entries
        if isRootRaid and key == "potions" and type(value) == "table" then
            value = CQ_Log_FilterPotionData(value);
            if next(value) == nil then value = nil; end
        end

        if value ~= nil then
            local keyStr;
            if type(key) == "string" then
                keyStr = "[\"" .. CQ_Log_ShortKey(CQ_Log_EscapeString(key)) .. "\"]";
            else
                keyStr = "[" .. tostring(key) .. "]";
            end

            table.insert(parts, spacing);
            table.insert(parts, " ");
            table.insert(parts, keyStr);
            table.insert(parts, " = ");
            
            if type(value) == "table" then
                table.insert(parts, CQ_Log_SerializeToLua(value, indent + 1, maxDepth, false));
                table.insert(parts, ",\n");
            elseif type(value) == "string" then
                table.insert(parts, "\"");
                table.insert(parts, CQ_Log_EscapeString(value));
                table.insert(parts, "\",\n");
            elseif type(value) == "number" then
                table.insert(parts, tostring(value));
                table.insert(parts, ",\n");
            elseif type(value) == "boolean" then
                table.insert(parts, tostring(value));
                table.insert(parts, ",\n");
            end
        end
    end

    table.insert(parts, spacing);
    table.insert(parts, "}");
    return table.concat(parts);
end

-- Serialize a Lua table to JSON format - MODIFIED for filtering
function CQ_Log_SerializeToJSON(tbl, indent, maxDepth, isRootRaid)
    indent = indent or 0;
    maxDepth = maxDepth or 10;
    
    if indent > maxDepth then
        return "null";
    end
    
    local spacing = string.rep(" ", indent);
    local parts = {};
    table.insert(parts, "{\n");
    local first = true;
    
    -- Sort keys for consistent output
    local keys = {};
    for key, _ in pairs(tbl) do
        table.insert(keys, key);
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b); end);
    
    for _, key in ipairs(keys) do
        local value = tbl[key];

        -- FILTER: skip internal runtime fields
        if type(key) == "string" and CQ_Log_ExcludeFromExport[key] then
            value = nil;
        end

        -- FILTER: If this is the "potions" key in root raid data, filter it
        if isRootRaid and key == "potions" and type(value) == "table" then
            value = CQ_Log_FilterPotionData(value);
            -- Skip empty potions table
            if next(value) == nil then
                value = nil;
            end
        end
        
        if value ~= nil then
            if not first then
                table.insert(parts, ",\n");
            end
            first = false;
            
            table.insert(parts, spacing);
            table.insert(parts, "  \"");
            table.insert(parts, CQ_Log_EscapeString(tostring(key)));
            table.insert(parts, "\": ");
            
            if type(value) == "table" then
                table.insert(parts, CQ_Log_SerializeToJSON(value, indent + 1, maxDepth, false));
            elseif type(value) == "string" then
                table.insert(parts, "\"");
                table.insert(parts, CQ_Log_EscapeString(value));
                table.insert(parts, "\"");
            elseif type(value) == "number" then
                table.insert(parts, tostring(value));
            elseif type(value) == "boolean" then
                table.insert(parts, value and "true" or "false");
            else
                table.insert(parts, "null");
            end
        end
    end
    
    table.insert(parts, "\n");
    table.insert(parts, spacing);
    table.insert(parts, "}");
    return table.concat(parts);
end

-- Build a friendly filename stem: e.g. "Naxxramas-120226" (zone-DDMMYY)
function CQ_Log_BuildFilename(zone, raidId)
    -- Sanitize zone: remove spaces, apostrophes, and other non-alphanumeric chars
    local safezone = zone or "Unknown";
    safezone = string.gsub(safezone, "'", "");
    safezone = string.gsub(safezone, " ", "");
    safezone = string.gsub(safezone, "[^%w%-]", "");
    
    -- Extract DDMMYY from raidId which is formatted as YYYYMMDD_HHMMSS
    local datepart = string.sub(raidId, 1, 8); -- "20260211"
    local day   = string.sub(datepart, 7, 8);  -- "11"
    local month = string.sub(datepart, 5, 6);  -- "02"
    local year  = string.sub(datepart, 3, 4);  -- "26"
    local friendlydate = day .. month .. year; -- "110226"
    
    return safezone .. "-" .. friendlydate;
end

-- Export current raid data to file - MODIFIED to use filtered serialization
function CQ_Log_ExportToFile(silent)
    if not CQ_Log.hasFileExport then
        if not silent then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[RAB Log] WriteCustomFile not available (requires Nampower v3.2.0+)|r");
        end
        return false;
    end
    
    if not CQ_Log.currentRaidId or not CQui_RaidLogs.raids[CQ_Log.currentRaidId] then
        if not silent then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[RAB Log] No active raid to export|r");
        end
        return false;
    end
    
    local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
    local extension = CQ_Log.exportFormat == "json" and ".json" or ".lua";
    local filename = CQ_Log_BuildFilename(raid.zone, CQ_Log.currentRaidId) .. extension;
    
    -- Build the export content
    local parts = {};
    
    if CQ_Log.exportFormat == "json" then
        -- JSON format
        table.insert(parts, "{\n");
        table.insert(parts, "  \"_comment\": \"Conqsumibles Raid Log Export\",\n");
        table.insert(parts, "  \"raidId\": \"");
        table.insert(parts, CQ_Log.currentRaidId);
        table.insert(parts, "\",\n");
        table.insert(parts, "  \"zone\": \"");
        table.insert(parts, CQ_Log_EscapeString(raid.zone or "Unknown"));
        table.insert(parts, "\",\n");
        table.insert(parts, "  \"exportDate\": \"");
        table.insert(parts, CQ_SafeDate("%Y-%m-%d %H:%M:%S"));
        table.insert(parts, "\",\n");
        table.insert(parts, "  \"version\": \"");
        table.insert(parts, CQui_RaidLogs.version);
        table.insert(parts, "\",\n");
        table.insert(parts, CQ_Log_SerializeToJSON(raid, 1, 10, true));
        table.insert(parts, "\n}\n");
    else
        table.insert(parts, "CQ_RaidExport = ");
        table.insert(parts, CQ_Log_SerializeToLua(raid, 0, 10, true));
        table.insert(parts, ";\n");
    end
    
    local content = table.concat(parts);
    
    -- WriteCustomFile writes to CustomData/ and raises on failure (no return value).
    local ok, err = pcall(WriteCustomFile, filename, content);

    if ok then
        CQ_Log.lastExportTime = GetTime();
        if not silent then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RAB Log] Exported to: CustomData/" .. filename .. "|r");
        end
        return true;
    else
        if not silent then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[RAB Log] Export failed: " .. tostring(err) .. "|r");
        end
        return false;
    end
end

-- Export all raids to a single file - MODIFIED to use filtered serialization
function CQ_Log_ExportAllRaids()
    if not CQ_Log.hasFileExport then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[RAB Log] WriteCustomFile not available (requires Nampower v3.2.0+)|r");
        return false;
    end
    
    if not CQui_RaidLogs or not CQui_RaidLogs.raids then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[RAB Log] No raids to export|r");
        return false;
    end
    
    local extension = CQ_Log.exportFormat == "json" and ".json" or ".lua";
    local filename = "rablog_all_" .. CQ_SafeDate("%d%m%y_%H%M%S") .. extension;
    
    -- Build the export content with filtering
    local parts = {};
    
    if CQ_Log.exportFormat == "json" then
        -- JSON format
        table.insert(parts, "{\n");
        table.insert(parts, "  \"_comment\": \"Conqsumibles All Raids Export\",\n");
        table.insert(parts, "  \"exportDate\": \"");
        table.insert(parts, CQ_SafeDate("%Y-%m-%d %H:%M:%S"));
        table.insert(parts, "\",\n");
        table.insert(parts, "  \"version\": \"");
        table.insert(parts, CQui_RaidLogs.version);
        table.insert(parts, "\",\n");
        table.insert(parts, "  \"raids\": {\n");
        
        local first = true;
        for raidId, raidData in pairs(CQui_RaidLogs.raids) do
            if not first then
                table.insert(parts, ",\n");
            end
            first = false;
            
            table.insert(parts, "    \"");
            table.insert(parts, CQ_Log_EscapeString(raidId));
            table.insert(parts, "\": ");
            table.insert(parts, CQ_Log_SerializeToJSON(raidData, 2, 10, true));
        end
        
        table.insert(parts, "\n  }\n");
        table.insert(parts, "}\n");
    else
        table.insert(parts, "CQ_AllRaidsExport = {\n");
        
        for raidId, raidData in pairs(CQui_RaidLogs.raids) do
            table.insert(parts, "  [\"");
            table.insert(parts, CQ_Log_EscapeString(raidId));
            table.insert(parts, "\"] = ");
            table.insert(parts, CQ_Log_SerializeToLua(raidData, 1, 10, true));
            table.insert(parts, ",\n");
        end
        
        table.insert(parts, "};\n");
    end
    
    local content = table.concat(parts);
    
    local ok, err = pcall(WriteCustomFile, filename, content);

    if ok then
        CQ_Log.lastExportTime = GetTime(); -- prevent auto-export firing right after manual exportall
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RAB Log] All raids exported to: CustomData/" .. filename .. "|r");
        return true;
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[RAB Log] Export failed: " .. tostring(err) .. "|r");
        return false;
    end
end

-- Auto-export timer function
function CQ_Log_AutoExportCheck()
    if not CQ_Log.isLogging or not CQ_Log.hasFileExport then
        return;
    end
    
    local currentTime = GetTime();
    if currentTime - CQ_Log.lastExportTime >= CQ_Log.autoExportInterval then
        CQ_Log_ExportToFile(true); -- silent = true for auto-exports
    end
end

-- Returns the server lockout ID for the given zone by scanning GetSavedInstanceInfo.
-- Returns nil if not found or if the API is unavailable.
local function CQ_Log_GetLockoutId(zone)
    if not GetSavedInstanceInfo then return nil; end
    for i = 1, 20 do
        local name, id = GetSavedInstanceInfo(i);
        if not name then break; end
        if name == zone then return id; end
    end
    return nil;
end

-- Initialize tracking tables for current raid
function CQ_Log_InitializeRaid()
    -- Defensive: ensure CQui_RaidLogs is in a usable state.
    if type(CQui_RaidLogs) ~= "table" then
        CQui_RaidLogs = { raids = {}, version = "2.0.0" };
    end
    if type(CQui_RaidLogs.raids) ~= "table" then
        CQui_RaidLogs.raids = {};
    end
    -- Use the zone that was recorded when we entered the raid area, not
    -- GetRealZoneText() which could return a safe zone or wrong zone if the
    -- player died and released before entering first combat.
    local currentZone = CQ_Log.currentZone or GetRealZoneText();
    -- Keep only the most recently completed raid in memory to prevent unbounded
    -- growth across a long session with multiple raids.
    -- The previous raid was already exported to file at FinalizeRaid time,
    -- so dropping it from the in-memory table loses nothing.
    local previousRaidId = nil;
    local newestTime = "";  -- raidId is a string (YYYYMMDD_HHMMSS), so compare string vs string
    for raidId, _ in pairs(CQui_RaidLogs.raids) do
        -- raidId format is YYYYMMDD_HHMMSS - lexicographic sort gives chronological order
        if raidId > newestTime then
            newestTime = raidId;
            previousRaidId = raidId;
        end
    end
    -- Drop everything except the most recent completed raid
    local keptRaid = previousRaidId and CQui_RaidLogs.raids[previousRaidId] or nil;
    CQui_RaidLogs.raids = {};
    if keptRaid then
        CQui_RaidLogs.raids[previousRaidId] = keptRaid;
    end

    local raidId = CQ_SafeDate("%Y%m%d_%H%M%S");
    CQ_Log.currentRaidId = raidId;
    CQ_Log.sessionStartTime = time();
    
    CQui_RaidLogs.raids[raidId] = {
        startTime = time(),
        endTime = nil,
        zone = currentZone,
        players = {},
        potions = {}, -- Track Major Mana Potions and Nordanaar Herbal Tea
        castTrackedConsumables = {}, -- Track consumables detected via SPELL_GO
        isBaselineScan = true, -- Suppresses false +1 on first PerformCheck after a fresh init (cleared after first pass, absent after recovery)
        deaths = {}, -- Track player deaths: [{playerName, killedBy, timestamp}]
        loot = {}, -- Track all loot items: [{playerName, itemId, itemName, itemQuality, quantity}]
        totalMoneyCopper = 0, -- Running total of all money drops (copper), condensed to one field
        spells = {}, -- Track spell casts: [playerName][spellId] = {count, spellName}
        metadata = {
            raidSize     = GetNumRaidMembers(),
            playerName   = UnitName("player"),
            playerRealm  = GetRealmName(),
            playerGuild  = GetGuildInfo("player") or "",
            lockoutId    = CQ_Log_GetLockoutId(currentZone),
            addonVersion = "2.0.0"
        }
    };
    
    -- Reset per-raid transient state
    CQ_Log_SapperDedup = {};
    CQ_Log_PendingGuidQueue = {};

    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RAB Log] Raid logging started for " .. (CQ_Log.currentZone or currentZone) .. "|r");
    
    -- Cache the tracked-consumables list once at raid start so PerformCheck
    -- doesn't re-read the profile every 15 seconds for the entire raid.
    CQ_Log.cachedTrackedConsumables = CQ_Log_GetTrackedConsumables();
    
    -- Reset timers
    CQ_Log.lastParticipationCheck = GetTime();
    CQ_Log.lastExportTime = GetTime();
    
    -- Flush any weapon enchant / consumable casts that arrived during the
    -- pending-combat window (before this raid object existed).
    if CQ_ConsInt_FlushPendingQueue then
        CQ_ConsInt_FlushPendingQueue(CQui_RaidLogs.raids[raidId]);
    end
end

-- Finalize current raid log
function CQ_Log_FinalizeRaid()
    if not CQui_RaidLogs then return; end
    
    if CQ_Log.currentRaidId and CQui_RaidLogs.raids[CQ_Log.currentRaidId] then
        CQui_RaidLogs.raids[CQ_Log.currentRaidId].endTime = time();
        -- Mark as cleanly completed. This flag is ONLY set here, never in auto-export
        -- or crash paths, so the uploader can trust it means the raid ended normally.
        CQui_RaidLogs.raids[CQ_Log.currentRaidId].completed = true;
        
        -- Export to file if Nampower WriteCustomFile is available
        if CQ_Log.hasFileExport then
            if CQ_Log_ExportToFile(false) then
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RAB Log] Raid ended. Data exported to file!|r");
            end
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[RAB Log] Raid ended but Nampower WriteCustomFile unavailable - data not saved.|r");
        end

        -- Auto-upload to Discord bot if enabled.
        -- CQ_Log_DoUpload is defined in Conq_MinimapButton.lua; guard with a nil
        -- check so raidlog.lua stays functional even if the minimap button isn't loaded.
        if CQ_Log.autoUploadOnFinalize and CQ_Log_DoUpload then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00d4ff[Conq] Auto-uploading raid log to Discord...|r");
            CQ_Log_DoUpload(true); -- silent=true (suppresses the "sending..." line)
        end
    end
    
    CQ_Log.currentRaidId = nil;
    CQ_Log.sessionStartTime = nil;
    CQ_Log.isLogging = false;
    CQ_Log.cachedTrackedConsumables = nil;

end

-- ============================================================================
-- CONSUMABLE TRACKING CATALOG
-- Used by both the config UI and GetTrackedConsumables().
-- Each section has a header label and a list of { buffKey, displayLabel } pairs.
-- The UI stores per-item enabled flags in CQ_Log.trackedItems[buffKey].
-- Add new consumables here; they will automatically appear in the Consumables tab.
-- ============================================================================
CQ_Log_ConsumableCatalog = {
    -- ---- Flasks --------------------------------------------------------
    {
        header = "Flasks",
        items = {
            { key = "flask",        label = "Flask of Supreme Power" , itemId = 13512 },
            { key = "titans",       label = "Flask of the Titans" , itemId = 13510 },
            { key = "wisdom",       label = "Flask of Distilled Wisdom" , itemId = 13511 },
            { key = "chromaticres", label = "Flask of Chromatic Resistance" , itemId = 13513 },
        },
    },
    -- ---- Elixirs --------------------------------------------------------
    {
        header = "Elixirs – Battle",
        items = {
            { key = "giants",              label = "Elixir of the Giants" , itemId = 9206 },
            { key = "mongoose",            label = "Elixir of the Mongoose" , itemId = 13452 },
            { key = "greateragilityelixir",label = "Elixir of Greater Agility" , itemId = 9187 },
            { key = "agilityelixir",       label = "Agility Elixir" , itemId = 8949 },
            { key = "firewater",           label = "Winterfall Firewater" , itemId = 12820 },
            { key = "demonslaying",        label = "Elixir of Demonslaying" , itemId = 9224 },
        },
    },
    {
        header = "Elixirs – Guardian",
        items = {
            { key = "elixirfortitude", label = "Elixir of Fortitude" , itemId = 3825 },
            { key = "supdef",          label = "Superior Defense Elixir" , itemId = 13445 },
        },
    },
    {
        header = "Elixirs – Spell Power",
        items = {
            { key = "shadowpower",        label = "Elixir of Shadow Power" , itemId = 9264 },
            { key = "greaterarcanepower", label = "Greater Arcane Power" , itemId = 13454 },
            { key = "greaterfrostpower",  label = "Greater Frost Power" , itemId = 21920 },
            { key = "greaterfirepower",   label = "Elixir of Greater Firepower" , itemId = 21546 },
            { key = "greaternaturepower", label = "Greater Nature Power" , itemId = 50237 },
            { key = "greaterarcane",      label = "Greater Arcane Elixir" , itemId = 13454 },
            { key = "dreamshard",         label = "Dreamshard Elixir" },
            { key = "dreamtonic",         label = "Dreamtonic" },
            { key = "arcaneelixir",       label = "Arcane Elixir" , itemId = 9155 },
            { key = "frostpower",         label = "Elixir of Frost Power" , itemId = 17708 },
            { key = "firepowerelixir",    label = "Elixir of Firepower" , itemId = 6373 },
            { key = "elixirofthesages",   label = "Elixir of the Sages" , itemId = 13447 },
        },
    },
    -- ---- Protection Potions (Greater → Normal → Lesser → Frozen Rune) --
    {
        header = "Protection Potions",
        items = {
            { key = "greaterarcanepot",  label = "Greater Arcane Protection" , itemId = 13461 },
            { key = "greaternaturepot",  label = "Greater Nature Protection" , itemId = 13458 },
            { key = "greatershadowpot",  label = "Greater Shadow Protection" , itemId = 13459 },
            { key = "greaterfirepot",    label = "Greater Fire Protection" , itemId = 13457 },
            { key = "greaterfrostpot",   label = "Greater Frost Protection" , itemId = 13456 },
            { key = "greaterholypot",    label = "Greater Holy Protection" , itemId = 13460 },
            { key = "frozenrune",        label = "Frozen Rune" , itemId = 22682 },
        },
    },
    -- ---- Miscellaneous Potions ------------------------------------------
    {
        header = "Miscellaneous Potions",
        items = {
            { key = "mageblood",         label = "Mageblood Potion" , itemId = 20007 },
            { key = "restorativepotion",  label = "Restorative Potion" , itemId = 9030 },
            { key = "freeactionpotion",   label = "Free Action Potion" , itemId = 5634 },
            { key = "limitinvulpotion",   label = "Limited Invulnerability Potion" , itemId = 3387 },
        },
    },
    -- ---- Weapon Enchants & Oils -----------------------------------------
    {
        header = "Weapon Enchants & Oils",
        items = {
            { key = "brillmanaoil",             label = "Brilliant Mana Oil" , itemId = 20748 },
            { key = "brilliantwizardoil",       label = "Brilliant Wizard Oil" , itemId = 20749 },
            { key = "blessedwizardoil",         label = "Blessed Wizard Oil" , itemId = 23123 },
            { key = "lessermanaoil",            label = "Lesser Mana Oil" , itemId = 20747 },
            { key = "wizardoil",                label = "Wizard Oil" , itemId = 20750 },
            { key = "frostoil",                 label = "Frost Oil" , itemId = 3824 },
            { key = "shadowoil",                label = "Shadow Oil" , itemId = 3826 },
            { key = "densesharpeningstone",     label = "Dense Sharpening Stone" , itemId = 12404 },
            { key = "elementalsharpeningstone", label = "Elemental Sharpening Stone" , itemId = 18262 },
            { key = "consecratedstone",         label = "Consecrated Sharpening Stone" , itemId = 23122 },
            { key = "denseweightstone",         label = "Dense Weightstone" , itemId = 12643 },
        },
    },
    -- ---- Juju Buffs -----------------------------------------------------
    {
        header = "Juju Buffs",
        items = {
            { key = "jujupower",  label = "Juju Power" , itemId = 12451 },
            { key = "jujumight",  label = "Juju Might" , itemId = 12460 },
            { key = "jujuchill",  label = "Juju Chill" , itemId = 12457 },
            { key = "jujuflurry", label = "Juju Flurry" , itemId = 12455 },
            { key = "jujuescape", label = "Juju Escape" , itemId = 12459 },
            { key = "jujuember",  label = "Juju Ember" , itemId = 12461 },
            { key = "jujuguile",  label = "Juju Guile" , itemId = 12462 },
        },
    },
    -- ---- Zanza Potions --------------------------------------------------
    {
        header = "Zanza Potions",
        items = {
            { key = "spiritofzanza",    label = "Spirit of Zanza" ,    itemId = 20079 },
            { key = "swiftnessofzanza", label = "Swiftness of Zanza" , itemId = 20080 },
            { key = "sheenofzanza",     label = "Sheen of Zanza" ,     itemId = 20081 },
        },
    },
    -- ---- Blasted Lands Buffs --------------------------------------------
    {
        header = "Blasted Lands Buffs",
        items = {
            { key = "roids",          label = "R.O.I.D.S." , itemId = 8410 },
            { key = "scorpok",        label = "Ground Scorpok Assay" , itemId = 8412 },
            { key = "cerebralcortex", label = "Cerebral Cortex Compound" , itemId = 8423 },
            { key = "lungJuice",      label = "Lung Juice Cocktail" , itemId = 8411 },
            { key = "gizzardgum",     label = "Gizzard Gum" , itemId = 8424 },
        },
    },
    -- ---- Food Buffs -----------------------------------------------------
    {
        header = "Food Buffs",
        items = {
            { key = "squid",            label = "Grilled Squid" },
            { key = "nightfinsoup",     label = "Nightfin Soup" },
            { key = "tuber",            label = "Runn Tum Tuber Surprise" },
            { key = "desertdumpling",   label = "Smoked Desert Dumpling / Power Mushroom" },
            { key = "mushroomstam",     label = "Hardened Mushroom" },
            { key = "tenderwolf",       label = "Tender Wolf Steak" },
            { key = "sagefish",         label = "Sagefish Delight" },
            { key = "dragonbreathchili",label = "Dragonbreath Chili" },
            { key = "gurubashigumbo",   label = "Gurubashi Gumbo" },
            { key = "telabimmedley",    label = "Tel'Abim Medley" },
            { key = "telabimdelight",   label = "Tel'Abim Delight" },
            { key = "telabimsurprise",  label = "Tel'Abim Surprise" },
            { key = "gilneashotstew",   label = "Gilneas Hot Stew" },
            { key = "gordokgreengrog",  label = "Gordok Green Grog" },
            { key = "rumseyrum",        label = "Rumsey Rum Black Label" },
            { key = "merlot",           label = "Medivh's Merlot" },
            { key = "merlotblue",       label = "Medivh's Merlot Blue Label" },
            { key = "herbalsalad",      label = "Herbal Salad" },
        },
    },
    -- ---- Rogue Poisons --------------------------------------------------
    -- Tracked by cast event (SPELL_GO) via CQ_ConsTracker_KeyMap.
    -- No buff bar visible for other players; application event only.
    {
        header = "Rogue Poisons",
        items = {
            { key = "deadlypoison",      label = "Deadly Poison",       itemId = 20844 },
            { key = "instantpoison",     label = "Instant Poison",      itemId = 8928  },
            { key = "woundpoison",       label = "Wound Poison",        itemId = 10922 },
            { key = "mindnumbingpoison", label = "Mind-numbing Poison", itemId = 9186  },
            { key = "cripplingpoison",   label = "Crippling Poison",    itemId = 3776  },
            { key = "corrosivepoison",   label = "Corrosive Poison",    itemId = 47409 },
            { key = "dissolventpoison",  label = "Dissolvent Poison",   itemId = 54010 },
        },
    },
    -- ---- Explosives -----------------------------------------------------
    {
        header = "Explosives",
        items = {
            { key = "goblinsapper",         label = "Goblin Sapper Charge" ,     itemId = 10646 },
            { key = "stratholmeholywater",  label = "Stratholme Holy Water",     itemId = 13180 },
            { key = "oilofimmolation",      label = "Oil of Immolation" ,        itemId = 8956  },
        },
    },
    -- ---- Concoctions ----------------------------------------------------
    {
        header = "Concoctions",
        items = {
            { key = "arcanegiants",    label = "Arcane Giants" },
            { key = "emeraldmongoose", label = "Emerald Mongoose" },
            { key = "dreamwater",      label = "Dream Water" },
        },
    },
    -- ---- Class Buffs --------------------------------------------------------
    -- Tracked by CASTER via SPELL_GO. Count = how many times the player cast the buff.
    {
        header = "Class Buffs – Mage",
        items = {
            { key = "ai", label = "Arcane Intellect (single)" },
            { key = "ab", label = "Arcane Brilliance (group)"  },
        },
    },
    {
        header = "Class Buffs – Priest",
        items = {
            { key = "pwf",  label = "Power Word: Fortitude (single)"           },
            { key = "pof",  label = "Prayer of Fortitude (group)"              },
            { key = "ds",   label = "Divine Spirit (single)"                   },
            { key = "pos",  label = "Prayer of Spirit (group)"                 },
            { key = "sprot",label = "Shadow Protection (single)"               },
            { key = "posp", label = "Prayer of Shadow Protection (group)"      },
        },
    },
    {
        header = "Class Buffs – Paladin",
        items = {
            { key = "bos",    label = "Blessing of Salvation"          },
            { key = "gbos",   label = "Greater Blessing of Salvation"  },
            { key = "bow",    label = "Blessing of Wisdom"             },
            { key = "gbow",   label = "Greater Blessing of Wisdom"     },
            { key = "bok",    label = "Blessing of Kings"              },
            { key = "gbok",   label = "Greater Blessing of Kings"      },
            { key = "bol",    label = "Blessing of Light"              },
            { key = "gbol",   label = "Greater Blessing of Light"      },
            { key = "bom",    label = "Blessing of Might"              },
            { key = "gbom",   label = "Greater Blessing of Might"      },
            { key = "bosanc", label = "Blessing of Sanctuary"          },
            { key = "gbosanc",label = "Greater Blessing of Sanctuary"  },
        },
    },
    {
        header = "Class Buffs – Druid",
        items = {
            { key = "motw", label = "Mark of the Wild (single)" },
            { key = "gotw", label = "Gift of the Wild (group)"  },
        },
    },
};

-- Seed any missing per-item enabled flags to true (default: all tracked).
function CQ_Log_EnsureItemDefaults()
    if not CQ_Log.trackedItems then
        CQ_Log.trackedItems = {};
    end
    for _, section in ipairs(CQ_Log_ConsumableCatalog) do
        for _, item in ipairs(section.items) do
            if CQ_Log.trackedItems[item.key] == nil then
                CQ_Log.trackedItems[item.key] = true;
            end
        end
    end
end

-- Get consumables to track, driven entirely by the per-item checkboxes in the Consumables tab.
function CQ_Log_GetTrackedConsumables()
    CQ_Log_EnsureItemDefaults();

    local tracked = {};

    if CQ_Log.debugConsumables then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[CONSUMABLE DEBUG] === Getting Tracked Consumables (per-item settings) ===|r");
    end

    for _, section in ipairs(CQ_Log_ConsumableCatalog) do
        for _, item in ipairs(section.items) do
            if CQ_Log.trackedItems[item.key] then
                if CQ_Log_ConsumableDurations[item.key] then
                    tracked[item.key] = true;
                    if CQ_Log.debugConsumables then
                        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00  + " .. item.key .. "|r");
                    end
                end
            end
        end
    end

    if CQ_Log.debugConsumables then
        local count = 0;
        for _ in pairs(tracked) do count = count + 1; end
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[CONSUMABLE DEBUG] Tracking " .. count .. " consumables total|r");
    end

    return tracked;
end

-- Helper function to get buff tooltip text (mimics core addon's updateSpellTooltip functionality)
local function CQ_Log_GetBuffTooltip(unitId, buffIndex)
    if not CQ_Spelltip then
        return nil;
    end
    
    -- Set up tooltip to scan the buff
    CQ_Spelltip:SetOwner(CQ_Frame or UIParent, "ANCHOR_NONE");
    CQ_Spelltip:ClearLines();
    CQ_Spelltip:SetUnitBuff(unitId, buffIndex);
    
    -- Get the first line of the tooltip (buff name)
    local tooltipText = CQ_SpelltipTextLeft1 and CQ_SpelltipTextLeft1:GetText();
    
    CQ_Spelltip:Hide();
    
    return tooltipText;
end

-- Check if player has a specific buff (improved to use tooltip + spellId like core addon)
function CQ_Log_CheckPlayerBuff(unitId, buffKey)
    if not CQ_Buffs[buffKey] or not CQ_Buffs[buffKey].identifiers then
        return false, 0;
    end
    
    local buffIndex = 1; -- Start at 1, not 0 for UnitBuff
    
    while true do
        local buffTexture, buffStacks, buffSpellId = UnitBuff(unitId, buffIndex);
        if not buffTexture then
            break;
        end
        
        -- spellId from Nampower (no overflow workaround needed)
        if buffSpellId and buffSpellId < 0 then
            buffSpellId = buffSpellId + 65536;
        end
        
        -- Clean the texture path
        local cleanTexture = string.gsub(buffTexture, "Interface\\\\Icons\\\\", "");
        cleanTexture = string.gsub(cleanTexture, "Interface\\Icons\\", "");
        
        -- Check if this buff matches any identifier for the buffKey
        for _, identifier in ipairs(CQ_Buffs[buffKey].identifiers) do
            local isMatch = false;
            
            -- Priority 1: Use spellId if available (most reliable)
            if buffSpellId and identifier.spellId then
                if buffSpellId == identifier.spellId then
                    isMatch = true;
                    if CQ_Log.debugConsumables then
                        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[BUFF MATCH] " .. buffKey .. " matched by spellId " .. buffSpellId .. "|r");
                    end
                end
            else
                -- Priority 2: Check texture match
                if identifier.texture == cleanTexture then
                    -- If tooltip is specified, verify it matches (critical for shared textures)
                    if identifier.tooltip then
                        local tooltipText = CQ_Log_GetBuffTooltip(unitId, buffIndex);
                        if tooltipText and tooltipText == identifier.tooltip then
                            isMatch = true;
                            if CQ_Log.debugConsumables then
                                DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[BUFF MATCH] " .. buffKey .. " matched by texture + tooltip '" .. tooltipText .. "'|r");
                            end
                        elseif CQ_Log.debugConsumables and tooltipText then
                            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[BUFF MISMATCH] Texture matched but tooltip didn't: expected '" .. identifier.tooltip .. "', got '" .. tooltipText .. "'|r");
                        end
                    else
                        -- No tooltip required, texture match is enough
                        isMatch = true;
                        if CQ_Log.debugConsumables then
                            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[BUFF MATCH] " .. buffKey .. " matched by texture only|r");
                        end
                    end
                end
            end
            
            -- If we found a match, get time remaining and return
            if isMatch then
                local timeLeft = 0;
                if RAB_BuffTimers then
                    local playerName = UnitName(unitId);
                    local timerKey = playerName .. "." .. buffKey;
                    if RAB_BuffTimers[timerKey] then
                        timeLeft = RAB_BuffTimers[timerKey] - GetTime();
                        if timeLeft < 0 then timeLeft = 0; end
                    end
                end
                
                -- If we don't have timer data, estimate based on consumable duration
                if timeLeft == 0 and CQ_Log_ConsumableDurations[buffKey] then
                    timeLeft = CQ_Log_ConsumableDurations[buffKey];
                end
                
                if CQ_Log.debugConsumables then
                    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[BUFF CHECK] Found " .. buffKey .. " on " .. UnitName(unitId) .. " (" .. timeLeft .. "s)|r");
                end
                
                return true, timeLeft;
            end
        end
        
        buffIndex = buffIndex + 1;
    end
    
    return false, 0;
end

-- Check weapon enchant status for a player.
-- GetWeaponEnchantInfo() only works for the local player, so:
--   self  -> use GetWeaponEnchantInfo() to confirm the slot is active, then
--            cross-check castTrackedConsumables to identify *which* enchant it is.
--            Without the cast check every tracked wepbuffonly buff for that slot
--            returns true simultaneously (the API gives no enchant identity).
--            NOTE: enchants applied before entering the raid zone will not have a
--            cast record and will show as missing until reapplied.
--   others -> rely solely on UNIT_CASTEVENT data stored in castTrackedConsumables.
function CQ_Log_CheckWeaponEnchant(unitId, buffKey, playerName, raid)
    local isPlayer = (unitId == "player") or (playerName == UnitName("player"));
    local buffData = CQ_Buffs[buffKey];
    if not buffData or buffData.type ~= "wepbuffonly" then
        return false, 0;
    end
    local isOH = (buffData.useOn == "weaponOH");

    -- ---- Local player: use the actual API --------------------------------
    if isPlayer then
        local mh, mhtime, _, oh, ohtime, _ = GetWeaponEnchantInfo();
        local slotActive, slotTime;
        if isOH then
            slotActive = oh;
            slotTime   = ohtime;
        else
            slotActive = mh;
            slotTime   = mhtime;
        end

        if CQ_Log.debugConsumables then
            -- Only log once per check (for the first buffKey we encounter) to avoid spam.
            -- Log raw API values so we can see what the server actually returns.
            if buffKey == "brillmanaoil" or buffKey == "brilliantwizardoil" then
                DEFAULT_CHAT_FRAME:AddMessage("|cff888888[WEP API] mh=" .. tostring(mh) ..
                    " mhtime=" .. tostring(mhtime) ..
                    " oh=" .. tostring(oh) ..
                    " ohtime=" .. tostring(ohtime) .. "|r");
            end
        end

        if not slotActive then
            return false, 0;
        end

        -- Slot is active - cross-check cast tracker to identify which enchant.
        if not raid or not raid.castTrackedConsumables then
            if CQ_Log.debugConsumables then
                DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[WEP DEBUG] " .. buffKey ..
                    " slot active but castTrackedConsumables is nil (raid=" ..
                    tostring(raid ~= nil) .. ")|r");
            end
            return false, 0;
        end
        local castKey = playerName .. "." .. buffKey;
        local tracked = raid.castTrackedConsumables[castKey];
        if not tracked then
            if CQ_Log.debugConsumables then
                DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[WEP DEBUG] " .. buffKey ..
                    " slot active but no cast record for key='" .. castKey .. "'|r");
            end
            return false, 0;
        end
        local duration = CQ_Log_ConsumableDurations[buffKey] or 1800;
        local elapsed  = GetTime() - tracked.timestamp;
        if elapsed > duration then
            if CQ_Log.debugConsumables then
                DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[WEP DEBUG] " .. buffKey ..
                    " cast record expired (elapsed=" .. math.floor(elapsed) .. "s)|r");
            end
            return false, 0;
        end

        if CQ_Log.debugConsumables then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[WEP DEBUG] " .. buffKey ..
                " MATCHED via cast record (elapsed=" .. math.floor(elapsed) .. "s)|r");
        end
        local timeLeft = math.floor((slotTime or 0) / 1000);
        return true, timeLeft;
    end

    -- ---- Other players: derive state from SPELL_GO data ------------
    if not raid or not raid.castTrackedConsumables then
        return false, 0;
    end
    local castKey = playerName .. "." .. buffKey;
    local tracked = raid.castTrackedConsumables[castKey];
    if not tracked then
        return false, 0;
    end
    local duration = CQ_Log_ConsumableDurations[buffKey] or 1800;
    local elapsed  = GetTime() - tracked.timestamp;
    local timeLeft = duration - elapsed;
    if timeLeft > 0 then
        return true, timeLeft;
    end
    return false, 0;
end

-- Track consumable usage for a player
function CQ_Log_TrackConsumable(playerName, buffKey, hasBuff, timeRemaining)
    if not CQ_Log.currentRaidId or not CQui_RaidLogs then return; end
    
    local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
    if not raid then return; end
    
    -- Only track if player has the buff - don't track missing buffs
    if not hasBuff then return; end
    
    -- Initialize player data if needed
    if not raid.players[playerName] then
        local raidIndex = CQ_Log_GetRaidIndex(playerName);
        local _, playerClass;
        if raidIndex then
            _, playerClass = UnitClass("raid" .. raidIndex);
        elseif playerName == UnitName("player") then
            _, playerClass = UnitClass("player");
        end
        raid.players[playerName] = {
            class = playerClass or "Unknown",
            participationTime = 0,
            lastSeen = time(),
            firstSeen = time(),
            consumables = {}
        };
    end
    
    -- Guard: player entry may have been created by recovery without a consumables table
    if not raid.players[playerName].consumables then
        raid.players[playerName].consumables = {};
    end

    -- Initialize consumable tracking for this player
    if not raid.players[playerName].consumables[buffKey] then
        raid.players[playerName].consumables[buffKey] = {
            applications    = 0,
            totalUptime     = 0,
            lastCheckHad    = false,
            lastCheckTime   = GetTime(),
            lastTimeRemaining = 0,
            preRaidCredited = false,  -- guard: at most one pre-raid credit per key per raid
        };
    end

    local consumableData = raid.players[playerName].consumables[buffKey];
    local currentTime = GetTime();

    -- ---- Pre-raid buff credit (first-seen) --------------------------------
    -- If the buff is already active and we haven't yet credited a pre-raid use
    -- for this key, credit 1 application now.
    -- This applies to ALL keys, including cast-tracked ones: a buff applied before
    -- logging started will never produce a cast event, so the only way to credit
    -- it is here via polling. The preRaidCredited flag ensures we do this at most
    -- once per raid per key regardless of reconnects or reloads.
    -- We do NOT skip chatTracked keys here — cast events handle mid-raid uses,
    -- but this one-time credit covers the pre-raid case they can never see.
    local chatTracked = CQ_Log_CastTrackedKeys and CQ_Log_CastTrackedKeys[buffKey];
    local preRaidCreditApplied = false;
    if hasBuff
        and not raid.isBaselineScan
        and consumableData.applications == 0
        and not consumableData.preRaidCredited
    then
        consumableData.applications    = 1;
        consumableData.preRaidCredited = true;
        preRaidCreditApplied           = true;  -- prevent double-count below
        if CQ_Log.debugConsumables then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff[TRACK] " .. playerName ..
                " first seen with " .. buffKey .. " active — pre-raid credit applied|r");
        end
    end

    -- ---- Reconnect / gap detection ----------------------------------------
    -- If the gap since the last check is more than 2× the check interval the
    -- player was offline (or the scanner was stalled).  When they come back
    -- with a buff whose time-remaining is consistent with the one we last saw,
    -- we don't double-count it; but if they reappear with a long-duration buff
    -- that had NOT been seen before (lastCheckHad == false) we credit one use.
    local timeSinceLastCheck = currentTime - (consumableData.lastCheckTime or currentTime);
    local playerReconnected  = timeSinceLastCheck > CQ_Log.checkInterval * 2;

    -- Detect refresh: if they had the buff and now have more time than expected.
    -- Both lastTimeRemaining and timeRemaining are in seconds; lastCheckTime and
    -- currentTime are wall-clock seconds from time(), so the arithmetic is consistent.
    -- NOTE: For consumables in CQ_Log_CastTrackedKeys the application count
    -- is driven by cast events (CQ_Log_RecordBuffUse), NOT by this polling
    -- path. Skip the increment here to avoid double-counting.
    -- NOTE: chatTracked declared above in the pre-raid credit block.
    if not chatTracked then
    if hasBuff and consumableData.lastCheckHad then
        local expectedRemaining = consumableData.lastTimeRemaining - (currentTime - consumableData.lastCheckTime);
        if timeRemaining > expectedRemaining + 30 then
            consumableData.applications = consumableData.applications + 1;
            if CQ_Log.debugConsumables then
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff[TRACK] " .. playerName .. " refreshed " .. buffKey .. " (apps: " .. consumableData.applications .. ")|r");
            end
        end
    elseif hasBuff and not consumableData.lastCheckHad and not preRaidCreditApplied then
        -- Buff appeared since last tick.
        -- If the player reconnected after a gap, credit the application.
        -- If this is the baseline scan, skip (pre-raid buffs are handled by the
        -- first-seen credit block above, which fires on the very next tick after
        -- the baseline clears and lastCheckHad is still false).
        -- Otherwise (buff appeared naturally mid-raid), count it.
        -- preRaidCreditApplied guard: avoids double-count when the pre-raid credit
        -- block and this block would both fire on the very first detection tick.
        if playerReconnected then
            if timeRemaining > 30 then
                consumableData.applications = consumableData.applications + 1;
                if CQ_Log.debugConsumables then
                    DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff[TRACK] " .. playerName .. " reconnected with " .. buffKey .. " (apps: " .. consumableData.applications .. ")|r");
                end
            end
        elseif not raid.isBaselineScan then
            consumableData.applications = consumableData.applications + 1;
            if CQ_Log.debugConsumables then
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff[TRACK] " .. playerName .. " applied " .. buffKey .. " (apps: " .. consumableData.applications .. ")|r");
            end
        elseif CQ_Log.debugConsumables then
            DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[TRACK] " .. playerName .. " has " .. buffKey .. " (baseline - not counted)|r");
        end
    end
    end -- end if not chatTracked

    -- Update tracking data
    consumableData.lastCheckHad = hasBuff;
    consumableData.lastCheckTime = currentTime;
    consumableData.lastTimeRemaining = timeRemaining;
    
    -- Update uptime using real elapsed time since last check, capped at checkInterval
    -- to avoid inflating numbers after long gaps (e.g. reconnects, loading screens).
    -- This mirrors how participationTime is calculated.
    if hasBuff then
        local uptimeToAdd = math.min(timeSinceLastCheck, CQ_Log.checkInterval);
        consumableData.totalUptime = consumableData.totalUptime + uptimeToAdd;
    end
end

-- Get raid index for a player name
function CQ_Log_GetRaidIndex(playerName)
    for i = 1, GetNumRaidMembers() do
        if UnitName("raid" .. i) == playerName then
            return i;
        end
    end
    return nil;
end

-- Track player participation - IMPROVED VERSION
-- This function tracks ACTUAL raid attendance independent of consumables
function CQ_Log_TrackParticipation()
    if not CQ_Log.currentRaidId or not CQui_RaidLogs then return; end
    
    local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
    if not raid then return; end
    
    local currentTime = GetTime();
    local timeSinceLastCheck = currentTime - CQ_Log.lastParticipationCheck;
    
    -- Prevent double-counting by ensuring we don't add time more frequently than check interval
    if timeSinceLastCheck < CQ_Log.checkInterval then
        return;
    end
    
    -- Update last check time
    CQ_Log.lastParticipationCheck = currentTime;
    
    local timeToAdd = math.min(timeSinceLastCheck, CQ_Log.checkInterval);

    local selfName = UnitName("player");

    for i = 1, GetNumRaidMembers() do
        local unitId = "raid" .. i;
        local playerName = UnitName(unitId);

        -- Skip self here — handled by the explicit block below to avoid double-counting.
        if playerName and playerName ~= selfName and UnitIsConnected(unitId) then
            if not raid.players[playerName] then
                local _, playerClass = UnitClass(unitId);
                raid.players[playerName] = {
                    class = playerClass or "Unknown",
                    participationTime = 0,
                    lastSeen = time(),
                    firstSeen = time(),
                    consumables = {}
                };
            elseif raid.players[playerName].class == "Unknown" then
                -- Retroactively fix class if it was stored as Unknown on first creation
                local _, playerClass = UnitClass(unitId);
                if playerClass then
                    raid.players[playerName].class = playerClass;
                end
            end

            raid.players[playerName].participationTime = raid.players[playerName].participationTime + timeToAdd;
            raid.players[playerName].lastSeen = time();
        end
    end

    -- The local player appears as "player", not as a "raidX" unit, so the loop
    -- above never counts them.  Track them explicitly here.
    if selfName then
        if not raid.players[selfName] then
            local _, selfClass = UnitClass("player");
            raid.players[selfName] = {
                class = selfClass or "Unknown",
                participationTime = 0,
                lastSeen = time(),
                firstSeen = time(),
                consumables = {}
            };
        end
        raid.players[selfName].participationTime = raid.players[selfName].participationTime + timeToAdd;
        raid.players[selfName].lastSeen = time();
    end
end

-- Main check function called every 15 seconds
function CQ_Log_PerformCheck()
    if not CQ_Log.isLogging or not CQ_Log.currentRaidId then return; end
    
    -- Only check in combat unless trackOutOfCombat is enabled
    if not CQ_Log.inCombat and not CQ_Log.trackOutOfCombat then return; end
    
    local currentTime = GetTime();
    if currentTime - CQ_Log.lastCheckTime < CQ_Log.checkInterval then
        return;
    end
    
    CQ_Log.lastCheckTime = currentTime;
    
    -- Use the cached consumables list built at raid start.
    -- Falls back to GetTrackedConsumables() only if the cache is somehow missing.
    local trackedConsumables = CQ_Log.cachedTrackedConsumables or CQ_Log_GetTrackedConsumables();
    
    -- Debug output
    if CQ_Log.debugConsumables then
        local count = 0;
        for _ in pairs(trackedConsumables) do count = count + 1; end
        DEFAULT_CHAT_FRAME:AddMessage("|cff888888[CONSUMABLE DEBUG] Tracking " .. count .. " consumable types|r");
        
        -- Dump castTrackedConsumables so we can see what's stored
        local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
        if raid and raid.castTrackedConsumables then
            local castCount = 0;
            for k, v in pairs(raid.castTrackedConsumables) do
                castCount = castCount + 1;
                DEFAULT_CHAT_FRAME:AddMessage("|cff888888[CAST TABLE] " .. k ..
                    " spellID=" .. tostring(v.spellID) ..
                    " age=" .. math.floor(GetTime() - v.timestamp) .. "s|r");
            end
            if castCount == 0 then
                DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[CAST TABLE] castTrackedConsumables is EMPTY|r");
            end
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[CAST TABLE] castTrackedConsumables does not exist on raid object|r");
        end
    end
    
    -- Track participation FIRST - this is independent of consumables
    CQ_Log_TrackParticipation();
    
    -- Then check consumables for all raid members
    local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
    local selfName = UnitName("player");
    for i = 1, GetNumRaidMembers() do
        local unitId = "raid" .. i;
        local playerName = UnitName(unitId);

        -- Skip self here — handled by the explicit block below to avoid double-scanning.
        if playerName and playerName ~= selfName and UnitIsConnected(unitId) then
            -- Stamp lastSeen so reconnect detection in TrackConsumable can work
            if raid.players[playerName] then
                raid.players[playerName].lastSeen = time();
            end
            for buffKey, _ in pairs(trackedConsumables) do
                local hasBuff, timeRemaining;
                local buffData = CQ_Buffs[buffKey];
                -- Weapon enchants (oils, stones, poisons) have no buff bar visible
                -- for other players, and GetWeaponEnchantInfo() only works for self.
                -- Applications are counted exclusively by Nampower (CQ_ConsTracker).
                -- Skip polling entirely for these on non-self players.
                if buffData and buffData.type == "wepbuffonly" then
                    -- nothing to poll; Nampower is the only source for other players
                else
                    hasBuff, timeRemaining = CQ_Log_CheckPlayerBuff(unitId, buffKey);
                    CQ_Log_TrackConsumable(playerName, buffKey, hasBuff, timeRemaining);
                end
            end
        end
    end

    -- The local player appears as "player" unit, not as a "raidX" unit, so the
    -- loop above never checks their buffs.  Scan them explicitly here.
    if selfName then
        for buffKey, _ in pairs(trackedConsumables) do
            local hasBuff, timeRemaining;
            local buffData = CQ_Buffs[buffKey];
            if buffData and buffData.type == "wepbuffonly" then
                hasBuff, timeRemaining = CQ_Log_CheckWeaponEnchant("player", buffKey, selfName, raid);
            else
                hasBuff, timeRemaining = CQ_Log_CheckPlayerBuff("player", buffKey);
            end
            CQ_Log_TrackConsumable(selfName, buffKey, hasBuff, timeRemaining);
        end
    end

    -- Clear the baseline flag after the first pass so all subsequent scans
    -- count new applications normally.
    if raid.isBaselineScan then
        raid.isBaselineScan = nil;
    end
end

-- Combat log event for potion/tea tracking
-- Messages format:
-- Major Mana: "You gain XXX Mana from Restore Mana." / "PlayerName gains XXX Mana from Restore Mana."
-- Tea Mana:   "You gain XXX Mana from Tea."           / "PlayerName gains XXX Mana from Tea."
-- Tea Health: "Your Tea heals you for XXX."           / "PlayerName's Tea heals PlayerName for XXX."
-- ============================================================================
-- Record a single chat-event-confirmed consumable use for a player.
-- Increments consumables[buffKey].applications and creates the entry if needed.
-- Returns true if the use was recorded, false if dedup suppressed it.
-- ============================================================================
function CQ_Log_RecordBuffUse(playerName, buffKey)
    if not CQ_Log.isLogging or not CQ_Log.currentRaidId then return false; end
    local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
    if not raid then return false; end

    -- Dedup: same player, same buffKey within window → skip
    local dedupKey = playerName .. "." .. buffKey;
    local now = GetTime();
    if CQ_Log_BuffUseDedup[dedupKey] then
        if now - CQ_Log_BuffUseDedup[dedupKey] < CQ_Log_BUFFUSE_DEDUP_WINDOW then
            return false;
        end
    end
    CQ_Log_BuffUseDedup[dedupKey] = now;

    -- Ensure player entry exists
    if not raid.players[playerName] then
        local unitId = nil;
        for i = 1, GetNumRaidMembers() do
            if UnitName("raid" .. i) == playerName then unitId = "raid" .. i; break; end
        end
        local _, cls;
        if unitId then _, cls = UnitClass(unitId); end
        raid.players[playerName] = {
            class = cls or "Unknown",
            participationTime = 0,
            lastSeen = time(),
            firstSeen = time(),
            consumables = {},
            deaths = 0,
        };
    end
    if not raid.players[playerName].consumables then
        raid.players[playerName].consumables = {};
    end

    -- Ensure consumable entry exists
    if not raid.players[playerName].consumables[buffKey] then
        raid.players[playerName].consumables[buffKey] = {
            applications  = 0,
            totalUptime   = 0,
            lastCheckHad  = false,
            lastCheckTime = GetTime(),
            lastTimeRemaining = 0,
        };
    end

    raid.players[playerName].consumables[buffKey].applications =
        raid.players[playerName].consumables[buffKey].applications + 1;

    if CQ_Log.debugConsumables or CQ_Log.debugPotions then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff[CHAT-USE] " .. playerName ..
            " used " .. buffKey ..
            " (total: " .. raid.players[playerName].consumables[buffKey].applications .. ")|r");
    end
    return true;
end

function CQ_Log_CombatLogEvent()
    if CQ_Log.debugPotions then
        DEFAULT_CHAT_FRAME:AddMessage("|cff888888[POTION DEBUG] Event: " .. (event or "?") .. " | Message: " .. (arg1 or "?") .. "|r");
    end

    if not CQ_Log.isLogging or not CQ_Log.currentRaidId then
        if CQ_Log.debugPotions then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[POTION DEBUG] Not logging (isLogging=" .. tostring(CQ_Log.isLogging) .. ", raidId=" .. tostring(CQ_Log.currentRaidId) .. ") - use /conqlog status|r");
        end
        return;
    end

    local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
    if not raid then return; end

    local playerName;
    local message = arg1;

    -- Filter out totem buffs
    if string.find(message, " Totem ") then
        return;
    end

    if event == "CHAT_MSG_SPELL_SELF_BUFF" or event == "CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS" then
        playerName = UnitName("player");
    elseif event == "CHAT_MSG_SPELL_PARTY_BUFF" or
           event == "CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS" or
           event == "CHAT_MSG_SPELL_FRIENDLYPLAYER_BUFF" or
           event == "CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS" then
        if string.find(message, "^You gain") or string.find(message, "^Your Tea heals") then
            playerName = UnitName("player");
        else
            local _, _, extractedName = string.find(message, "^(.+) gains");
            if not extractedName then
                _, _, extractedName = string.find(message, "^(.+)'s Tea heals");
            end
            if extractedName then
                if string.find(extractedName, "%(") then
                    return; -- pet, ignore
                end
                playerName = extractedName;
            end
        end
    end

    if not playerName then return; end

    -- Verify the player is in our raid
    local isInRaid = playerName == UnitName("player");
    if not isInRaid then
        for i = 1, GetNumRaidMembers() do
            if UnitName("raid" .. i) == playerName then
                isInRaid = true;
                break;
            end
        end
    end
    if not isInRaid then return; end

    if not raid.potions then raid.potions = {}; end
    if not raid.potions[playerName] then
        raid.potions[playerName] = { majorMana = 0, nordanaarTea = 0, limitinvulpotion = 0 };
    end

    -- Major Mana Potion
    for _, pattern in ipairs(CQ_Log_PotionPatterns.majorMana) do
        if string.find(message, pattern) then
            raid.potions[playerName].majorMana = raid.potions[playerName].majorMana + 1;
            if CQ_Log.debugPotions then
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff[POTION] " .. playerName .. " used Major Mana Potion (total: " .. raid.potions[playerName].majorMana .. ")|r");
            end
            return;
        end
    end

    -- Nordanaar Herbal Tea
    for _, pattern in ipairs(CQ_Log_PotionPatterns.nordanaarTea) do
        if string.find(message, pattern) then
            raid.potions[playerName].nordanaarTea = raid.potions[playerName].nordanaarTea + 1;
            if CQ_Log.debugPotions then
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff[POTION] " .. playerName .. " used Nordanaar Tea (total: " .. raid.potions[playerName].nordanaarTea .. ")|r");
            end
            return;
        end
    end

    -- Limited Invulnerability Potion
    -- Fires on CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS:       "You gain Invulnerability."
    -- Fires on CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS: "Name gains Invulnerability."
    if CQ_Log.trackedItems and CQ_Log.trackedItems["limitinvulpotion"] ~= false then
        for _, pattern in ipairs(CQ_Log_PotionPatterns.limitinvulpotion) do
            if string.find(message, pattern) then
                if not raid.potions[playerName].limitinvulpotion then
                    raid.potions[playerName].limitinvulpotion = 0;
                end
                raid.potions[playerName].limitinvulpotion = raid.potions[playerName].limitinvulpotion + 1;
                if CQ_Log.debugPotions then
                    DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff[POTION] " .. playerName .. " used Limited Invulnerability Potion (total: " .. raid.potions[playerName].limitinvulpotion .. ")|r");
                end
                return;
            end
        end
    end
end

-- Map the exact enchant-application chat message substring to a buffKey.
-- When a player applies a weapon oil or stone, the client prints one of:
--   Self:   "Your weapon is imbued with Brilliant Mana Oil."
--   Others: "PlayerName's weapon is imbued with Brilliant Mana Oil."
-- The substring we match is everything after "imbued with " (or the full name
-- that appears in those messages on this server).  We match case-insensitively
-- so minor server-side capitalisation differences don't break detection.
--
-- NOTE: AURA_CAST fires weapon enchant events for weapon enchant item
-- applications, NOT CAST events - the cast-event path in CQ_ConsTracker
-- therefore never fires for these.  Chat message matching is the only reliable
-- approach, exactly like mana potions and sapper charges.
CQ_Log_WeaponEnchantPatterns = {
    -- Weapon Oils
    { pattern = "Brilliant Mana Oil",           buffKey = "brillmanaoil"         },
    { pattern = "Brilliant Wizard Oil",          buffKey = "brilliantwizardoil"   },
    { pattern = "Blessed Wizard Oil",            buffKey = "blessedwizardoil"     },
    { pattern = "Lesser Mana Oil",               buffKey = "lessermanaoil"        },
    { pattern = "Wizard Oil[^%a]",               buffKey = "wizardoil"            }, -- anchored: won't match "Brilliant Wizard Oil"
    { pattern = "Frost Oil",                     buffKey = "frostoil"             },
    { pattern = "Shadow Oil",                    buffKey = "shadowoil"            },
    -- Weapon Stones
    { pattern = "Consecrated Sharpening Stone",  buffKey = "consecratedstone"     },
    { pattern = "Elemental Sharpening Stone",    buffKey = "elementalsharpeningstone" },
    { pattern = "Dense Sharpening Stone",        buffKey = "densesharpeningstone" },
    { pattern = "Dense Weightstone",             buffKey = "denseweightstone"     },
};

-- Weapon enchant application messages appear in CHAT_MSG_SPELL_SELF_BUFF (self)
-- and CHAT_MSG_SPELL_FRIENDLYPLAYER_BUFF (others).
--
-- Typical formats observed on Turtle WoW / vanilla-era servers:
--   Self:   "Your weapon is imbued with Brilliant Mana Oil."
--           "Your weapon is enchanted with Dense Sharpening Stone."
--   Others: "PlayerName's weapon is imbued with Brilliant Mana Oil."
--           "PlayerName's weapon is enchanted with Dense Sharpening Stone."
--
-- We match both "imbued" and "enchanted" variants to stay server-agnostic,
-- and we scan for the oil/stone name anywhere in the message.
function CQ_Log_WeaponEnchantEvent()
    if not CQ_Log.isLogging or not CQ_Log.currentRaidId then return; end

    local message = arg1;
    -- Quick reject: must mention "weapon" and either "imbued" or "enchanted"
    if not (string.find(message, "weapon") and
            (string.find(message, "imbued") or string.find(message, "enchanted"))) then
        return;
    end

    local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
    if not raid then return; end

    -- Determine who applied the enchant
    local playerName;
    if event == "CHAT_MSG_SPELL_SELF_BUFF" then
        playerName = UnitName("player");
    elseif event == "CHAT_MSG_SPELL_FRIENDLYPLAYER_BUFF" then
        if string.find(message, "^Your ") then
            -- Some servers route self-buffs through FRIENDLYPLAYER_BUFF
            playerName = UnitName("player");
        else
            local _, _, extractedName = string.find(message, "^(.+)'s weapon");
            if extractedName and not string.find(extractedName, "%(") then
                playerName = extractedName;
            end
        end
    end

    if not playerName then return; end

    -- Verify the player is in our raid
    local isInRaid = playerName == UnitName("player");
    if not isInRaid then
        for i = 1, GetNumRaidMembers() do
            if UnitName("raid" .. i) == playerName then
                isInRaid = true;
                break;
            end
        end
    end
    if not isInRaid then return; end

    -- Identify which enchant was applied
    local buffKey;
    for _, entry in ipairs(CQ_Log_WeaponEnchantPatterns) do
        if string.find(message, entry.pattern) then
            buffKey = entry.buffKey;
            break;
        end
    end

    if not buffKey then
        if CQ_Log.debugConsumables then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[WEP ENCHANT] Unrecognised enchant message: " .. message .. "|r");
        end
        return;
    end

    -- Initialise player data if needed
    if not raid.players[playerName] then
        local raidIndex = CQ_Log_GetRaidIndex(playerName);
        local _, playerClass;
        if raidIndex then
            _, playerClass = UnitClass("raid" .. raidIndex);
        end
        raid.players[playerName] = {
            class            = playerClass or "Unknown",
            participationTime = 0,
            lastSeen         = time(),
            firstSeen        = time(),
            consumables      = {}
        };
    end

    if not raid.players[playerName].consumables then
        raid.players[playerName].consumables = {};
    end

    if not raid.players[playerName].consumables[buffKey] then
        raid.players[playerName].consumables[buffKey] = {
            applications     = 0,
            totalUptime      = 0,
            lastCheckHad     = false,
            lastCheckTime    = GetTime(),
            lastTimeRemaining = 0
        };
    end

    local cd = raid.players[playerName].consumables[buffKey];
    cd.applications    = cd.applications + 1;
    cd.lastCheckTime   = GetTime();
    cd.lastCheckHad    = true;
    cd.lastTimeRemaining = CQ_Log_ConsumableDurations[buffKey] or 1800;

    -- Also store in castTrackedConsumables so CQ_Log_CheckWeaponEnchant
    -- can confirm identity when polling GetWeaponEnchantInfo for the local player.
    if not raid.castTrackedConsumables then
        raid.castTrackedConsumables = {};
    end
    raid.castTrackedConsumables[playerName .. "." .. buffKey] = {
        timestamp      = GetTime(),
        spellID        = nil,
        consumableName = buffKey,
        spellName      = nil,
    };

    if CQ_Log.debugConsumables then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff[WEP ENCHANT] " .. playerName ..
            " applied " .. buffKey .. " (apps: " .. cd.applications .. ")|r");
    end
end

-- Combat log event for Goblin Sapper Charge and Stratholme Holy Water tracking.
-- Both items hit every enemy in range, so one use generates many damage messages.
-- We use a per-player dedup window to count only one use regardless of targets hit.
--
-- Self message:   "Your <item> hits <target> for X."         (CHAT_MSG_SPELL_SELF_DAMAGE)
-- Others message: "PlayerName's <item> hits <target> for X." (CHAT_MSG_SPELL_FRIENDLYPLAYER_DAMAGE)
function CQ_Log_SapperEvent()
    if not CQ_Log.isLogging or not CQ_Log.currentRaidId then return; end

    local message = arg1;

    -- Identify which item fired and its buffKey / dedup key
    local buffKey, dedupKey, spellLabel;
    if string.find(message, "Goblin Sapper Charge") then
        buffKey   = "goblinsapper";
        dedupKey  = "sapper";
        spellLabel = "Goblin Sapper Charge";
    elseif string.find(message, "Stratholme Holy Water") then
        buffKey   = "stratholmeholywater";
        dedupKey  = "holywater";
        spellLabel = "Stratholme Holy Water";
    else
        return;
    end

    local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
    if not raid then return; end

    -- Determine who used the item
    local playerName;
    if event == "CHAT_MSG_SPELL_SELF_DAMAGE" then
        playerName = UnitName("player");
    elseif event == "CHAT_MSG_SPELL_FRIENDLYPLAYER_DAMAGE" then
        local _, _, extractedName = string.find(message, "^(.+)'s " .. spellLabel);
        if extractedName and not string.find(extractedName, "%(") then
            playerName = extractedName;
        end
    end

    if not playerName then return; end

    -- Verify the player is in our raid
    local isInRaid = playerName == UnitName("player");
    if not isInRaid then
        for i = 1, GetNumRaidMembers() do
            if UnitName("raid" .. i) == playerName then
                isInRaid = true;
                break;
            end
        end
    end
    if not isInRaid then return; end

    -- Deduplicate: ignore if we already counted this item for this player very recently
    local now = GetTime();
    local dedupFullKey = playerName .. "_" .. dedupKey;
    local lastUse = CQ_Log_SapperDedup[dedupFullKey] or 0;
    if (now - lastUse) < CQ_Log_SAPPER_DEDUP_WINDOW then
        return;
    end
    CQ_Log_SapperDedup[dedupFullKey] = now;

    -- Record in players consumables table
    if not raid.players[playerName] then
        local raidIndex = CQ_Log_GetRaidIndex(playerName);
        local _, playerClass;
        if raidIndex then
            _, playerClass = UnitClass("raid" .. raidIndex);
        end
        raid.players[playerName] = {
            class = playerClass or "Unknown",
            participationTime = 0,
            lastSeen = time(),
            firstSeen = time(),
            consumables = {}
        };
    end

    if not raid.players[playerName].consumables then
        raid.players[playerName].consumables = {};
    end

    if not raid.players[playerName].consumables[buffKey] then
        raid.players[playerName].consumables[buffKey] = {
            applications = 0,
            totalUptime = 0,
            lastCheckHad = false,
            lastCheckTime = GetTime(),
            lastTimeRemaining = 0
        };
    end

    raid.players[playerName].consumables[buffKey].applications =
        raid.players[playerName].consumables[buffKey].applications + 1;
    raid.players[playerName].consumables[buffKey].lastCheckTime = GetTime();

    if CQ_Log.debugConsumables then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff[EXPLOSIVE] " .. playerName .. " used " .. spellLabel .. " (total: " ..
            raid.players[playerName].consumables[buffKey].applications .. ")|r");
    end
end

-- ============================================================================
-- SUNDER ARMOR TRACKING
-- ============================================================================
--
-- SPELL_GO (Nampower) fires for every player's Sunder cast:
--   arg1 = caster GUID, arg3 = "CAST", arg4 = spellID.
-- This is the only source that fires on ALL casts, including silent refreshes
-- at max (5) stacks where no chat message appears.
--
-- GUID resolution (three-tier, in priority order):
--   1. Cache hit in CQ_Log_GuidMap - O(1), covers all casts after first.
--   2. GetUnitGUID() roster scan - resolves the GUID unambiguously for every
--      player when SuperWOW is present (the normal case on this server).
--      The map is pre-seeded at login and kept fresh on roster events so most
--      casts hit tier 1 rather than rescanning.
--   3. Pending-queue + CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE fallback -
--      used only when GetUnitGUID() is unavailable or a new player joins mid-raid
--      before the roster event has fired. With a single Warrior the name is
--      unambiguous; with multiple Warriors a "Warrior-XXXXXX" placeholder is
--      used so counts are never silently dropped.

-- Sunder Armor spell IDs (all ranks)
CQ_Log_SunderSpellIDs = {
    [772]   = true,   -- Rank 1
    [8205]  = true,   -- Rank 2
    [7386]  = true,   -- Rank 3
    [7405]  = true,   -- Rank 4
    [8380]  = true,   -- Rank 5
    [11597] = true,   -- Rank 6
};

-- ============================================================================
-- CLASS BUFF CAST TRACKING  (via SPELL_GO)
-- Tracks WHO CAST the buff, not who received it.
-- Stored under raid.spells[playerName]["buff_key"] = {count=N, spellName="..."}
-- Uses the same GUID resolution logic as Sunder Armor.
-- ============================================================================

-- Spell ID -> {buffKey, displayName}
-- Covers every rank of each buff.  Individual + group (Greater/Prayer) casts
-- all map to the same buffKey so one checkbox covers both.
CQ_Log_ClassBuffSpellIDs = {
    -- Mage: Arcane Intellect (ranks 1-5) — single target
    [1459]  = { key = "ai", name = "Arcane Intellect" },
    [1460]  = { key = "ai", name = "Arcane Intellect" },
    [1461]  = { key = "ai", name = "Arcane Intellect" },
    [10156] = { key = "ai", name = "Arcane Intellect" },
    [10157] = { key = "ai", name = "Arcane Intellect" },
    -- Mage: Arcane Brilliance (ranks 1-2) — group
    [23028] = { key = "ab", name = "Arcane Brilliance" },
    [27126] = { key = "ab", name = "Arcane Brilliance" },

    -- Priest: Power Word: Fortitude (ranks 1-6) — single target
    [1243]  = { key = "pwf", name = "Power Word: Fortitude" },
    [1244]  = { key = "pwf", name = "Power Word: Fortitude" },
    [1245]  = { key = "pwf", name = "Power Word: Fortitude" },
    [2791]  = { key = "pwf", name = "Power Word: Fortitude" },
    [10937] = { key = "pwf", name = "Power Word: Fortitude" },
    [10938] = { key = "pwf", name = "Power Word: Fortitude" },
    -- Priest: Prayer of Fortitude (ranks 1-2) — group
    [21562] = { key = "pof", name = "Prayer of Fortitude" },
    [21564] = { key = "pof", name = "Prayer of Fortitude" },

    -- Priest: Divine Spirit (ranks 1-4) — single target
    [14752] = { key = "ds", name = "Divine Spirit" },
    [14818] = { key = "ds", name = "Divine Spirit" },
    [14819] = { key = "ds", name = "Divine Spirit" },
    [27841] = { key = "ds", name = "Divine Spirit" },
    -- Priest: Prayer of Spirit (rank 1) — group
    [27681] = { key = "pos", name = "Prayer of Spirit" },

    -- Priest: Shadow Protection (ranks 1-2) — single target
    [976]   = { key = "sprot", name = "Shadow Protection" },
    [10957] = { key = "sprot", name = "Shadow Protection" },
    [10958] = { key = "sprot", name = "Shadow Protection" },
    -- Priest: Prayer of Shadow Protection (ranks 1-2) — group
    [27683] = { key = "posp", name = "Prayer of Shadow Protection" },
    [39374] = { key = "posp", name = "Prayer of Shadow Protection" },

    -- Paladin: Blessing of Salvation (ranks 1-3) — single target
    [1038]  = { key = "bos", name = "Blessing of Salvation" },
    [19742] = { key = "bos", name = "Blessing of Salvation" },
    [19743] = { key = "bos", name = "Blessing of Salvation" },
    -- Paladin: Greater Blessing of Salvation — group
    [25895] = { key = "gbos", name = "Greater Blessing of Salvation" },

    -- Paladin: Blessing of Wisdom (ranks 1-7) — single target
    [19850] = { key = "bow", name = "Blessing of Wisdom" },
    [19852] = { key = "bow", name = "Blessing of Wisdom" },
    [19853] = { key = "bow", name = "Blessing of Wisdom" },
    [19854] = { key = "bow", name = "Blessing of Wisdom" },
    [25290] = { key = "bow", name = "Blessing of Wisdom" },  -- Rank 7 (DCL confirmed)
    -- Paladin: Greater Blessing of Wisdom — group
    [25918] = { key = "gbow", name = "Greater Blessing of Wisdom" },

    -- Paladin: Blessing of Kings (rank 1) — single target
    [20217] = { key = "bok", name = "Blessing of Kings" },
    -- Paladin: Greater Blessing of Kings — group
    [25898] = { key = "gbok", name = "Greater Blessing of Kings" },

    -- Paladin: Blessing of Light (ranks 1-3) — single target
    [19977] = { key = "bol", name = "Blessing of Light" },
    [19978] = { key = "bol", name = "Blessing of Light" },
    [19979] = { key = "bol", name = "Blessing of Light" },
    -- Paladin: Greater Blessing of Light — group
    [25890] = { key = "gbol", name = "Greater Blessing of Light" },

    -- Paladin: Blessing of Might (ranks 1-8) — single target
    [19740] = { key = "bom", name = "Blessing of Might" },
    [19834] = { key = "bom", name = "Blessing of Might" },
    [19835] = { key = "bom", name = "Blessing of Might" },
    [19836] = { key = "bom", name = "Blessing of Might" },
    [19837] = { key = "bom", name = "Blessing of Might" },
    [19838] = { key = "bom", name = "Blessing of Might" },
    [25291] = { key = "bom", name = "Blessing of Might" },
    -- Paladin: Greater Blessing of Might — group
    [25916] = { key = "gbom", name = "Greater Blessing of Might" },

    -- Paladin: Blessing of Sanctuary (ranks 1-5) — single target
    [20911] = { key = "bosanc", name = "Blessing of Sanctuary" },
    [20912] = { key = "bosanc", name = "Blessing of Sanctuary" },
    [20913] = { key = "bosanc", name = "Blessing of Sanctuary" },
    [20914] = { key = "bosanc", name = "Blessing of Sanctuary" },
    [20915] = { key = "bosanc", name = "Blessing of Sanctuary" },
    -- Paladin: Greater Blessing of Sanctuary — group
    [25899] = { key = "gbosanc", name = "Greater Blessing of Sanctuary" },

    -- Druid: Mark of the Wild (ranks 1-8) — single target
    [1126]  = { key = "motw", name = "Mark of the Wild" },
    [5232]  = { key = "motw", name = "Mark of the Wild" },
    [6756]  = { key = "motw", name = "Mark of the Wild" },
    [5234]  = { key = "motw", name = "Mark of the Wild" },
    [8907]  = { key = "motw", name = "Mark of the Wild" },
    [9884]  = { key = "motw", name = "Mark of the Wild" },
    [9885]  = { key = "motw", name = "Mark of the Wild" },
    [26990] = { key = "motw", name = "Mark of the Wild" },
    -- Druid: Gift of the Wild (ranks 1-3) — group
    [21849] = { key = "gotw", name = "Gift of the Wild" },
    [21850] = { key = "gotw", name = "Gift of the Wild" },
    [26991] = { key = "gotw", name = "Gift of the Wild" },
};

-- Record a class buff cast for playerName into raid.spells.
function CQ_Log_RecordClassBuff(playerName, buffKey, spellName)
    if not CQ_Log.isLogging or not CQ_Log.currentRaidId then return; end
    -- Respect the per-item checkbox in the Consumables tab
    if CQ_Log.trackedItems and CQ_Log.trackedItems[buffKey] == false then return; end

    local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
    if not raid then return; end

    if not raid.spells[playerName] then
        raid.spells[playerName] = {};
    end
    if not raid.spells[playerName][buffKey] then
        raid.spells[playerName][buffKey] = { count = 0, spellName = spellName };
    end
    raid.spells[playerName][buffKey].count =
        raid.spells[playerName][buffKey].count + 1;

    if CQ_Log.debugConsumables then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff[CLASS BUFF] " .. playerName ..
            " cast " .. spellName ..
            " (total: " .. raid.spells[playerName][buffKey].count .. ")|r");
    end
end

-- (Class buff SPELL_GO handling moved to CQ_SpellGoFrame unified dispatcher below.)

-- (CQ_Log_GuidMap, CQ_Log_PendingGuidQueue, and CQ_Log_GUID_RESOLVE_WINDOW
--  are declared at file-top, before the SPELL_GO frames that use them.)

-- Record a confirmed Sunder cast for playerName into the active raid.
function CQ_Log_RecordSunder(playerName)
    if not CQ_Log.isLogging or not CQ_Log.currentRaidId then return; end
    if not CQ_Log.trackSunders then return; end
    local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
    if not raid then return; end

    if not raid.spells[playerName] then
        raid.spells[playerName] = {};
    end
    if not raid.spells[playerName]["sunder_armor"] then
        raid.spells[playerName]["sunder_armor"] = {
            count = 0,
            spellName = "Sunder Armor",
        };
    end

    raid.spells[playerName]["sunder_armor"].count =
        raid.spells[playerName]["sunder_armor"].count + 1;

    if CQ_Log.debugConsumables then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff[SUNDER] " .. playerName ..
            " (total: " .. raid.spells[playerName]["sunder_armor"].count .. ")|r");
    end
end

-- Called by Conq_SpellTracker.lua when the LOCAL PLAYER casts Sunder Armor.
-- SpellTracker handles SPELL_GO_SELF and delegates here so all recording
-- logic stays in one place. We resolve the local player's name directly
-- (no GUID lookup needed) and call CQ_Log_RecordSunder.
function CQ_Log_RecordSunderSelf(spellID)
    if not CQ_Log_SunderSpellIDs or not CQ_Log_SunderSpellIDs[spellID] then return; end
    local playerName = UnitName("player");
    if not playerName then return; end
    CQ_Log_RecordSunder(playerName);
end

-- Build (or rebuild) the GUID->name map from the current raid/party roster.
-- Called at init and on roster changes.
function CQ_Log_RebuildGuidMap()
    -- Always include the local player
    local playerGuid = GetUnitGUID("player");
    if playerGuid then
        CQ_Log_GuidMap[playerGuid] = UnitName("player");
    end

    local numRaid = GetNumRaidMembers();
    if numRaid > 0 then
        for i = 1, numRaid do
            local unit  = "raid" .. i;
            local name  = UnitName(unit);
            local guid  = GetUnitGUID(unit);
            if name and guid then
                CQ_Log_GuidMap[guid] = name;
            end
        end
    else
        local numParty = GetNumPartyMembers();
        for i = 1, numParty do
            local unit  = "party" .. i;
            local name  = UnitName(unit);
            local guid  = GetUnitGUID(unit);
            if name and guid then
                CQ_Log_GuidMap[guid] = name;
            end
        end
    end
end

-- ============================================================================
-- UNIFIED SPELL_GO DISPATCHER
-- One frame handles consumables, class buffs, and Sunder Armor in a single
-- pass. GUID resolution is shared; SetCVar is called exactly once.
-- ============================================================================

-- Shared GUID resolver: cache → GetUnitGUID scan → nil.
-- Updates CQ_Log_GuidMap as a side-effect.
local function CQ_SpellGo_ResolveGuid(casterGuid)
    if not casterGuid then return nil; end

    -- 1. Cache hit
    local name = CQ_Log_GuidMap[casterGuid];
    if name then return name; end

    -- Opportunistic refresh when the map looks too small
    local mapSize = 0;
    for _ in pairs(CQ_Log_GuidMap) do mapSize = mapSize + 1; end
    if mapSize <= 1 then CQ_Log_RebuildGuidMap(); end

    -- 2. GetUnitGUID roster scan
    if GetUnitGUID and GetUnitGUID("player") == casterGuid then
        name = UnitName("player");
    end
    if not name then
        local numRaid = GetNumRaidMembers();
        if numRaid > 0 then
            for i = 1, numRaid do
                local unit = "raid" .. i;
                if GetUnitGUID(unit) == casterGuid then
                    name = UnitName(unit);
                    break;
                end
            end
        else
            for i = 1, GetNumPartyMembers() do
                local unit = "party" .. i;
                if GetUnitGUID(unit) == casterGuid then
                    name = UnitName(unit);
                    break;
                end
            end
        end
    end

    if name then CQ_Log_GuidMap[casterGuid] = name; end
    return name;
end

SetCVar("NP_EnableSpellGoEvents", "1");

CQ_SpellGoFrame = CreateFrame("Frame");
CQ_SpellGoFrame:RegisterEvent("SPELL_GO_SELF");
CQ_SpellGoFrame:RegisterEvent("SPELL_GO_OTHER");
CQ_SpellGoFrame:RegisterEvent("RAID_ROSTER_UPDATE");
CQ_SpellGoFrame:RegisterEvent("PARTY_MEMBERS_CHANGED");
CQ_SpellGoFrame:SetScript("OnEvent", function()
    -- Roster changes: keep the GUID map fresh
    if event == "RAID_ROSTER_UPDATE" or event == "PARTY_MEMBERS_CHANGED" then
        CQ_Log_RebuildGuidMap();
        return;
    end

    -- Nampower SPELL_GO: arg1=itemId, arg2=spellID, arg3=casterGUID
    local spellID    = arg2;
    local casterGuid = arg3;

    -- ---- 1. Consumables ------------------------------------------------
    local buffKey = CQ_Log_ConsumableSpellIDs[spellID];
    if buffKey and CQ_Log.isLogging then
        if not (CQ_Log.trackedItems and CQ_Log.trackedItems[buffKey] == false) then
            local playerName = CQ_SpellGo_ResolveGuid(casterGuid);
            if playerName then
                CQ_Log_RecordBuffUse(playerName, buffKey);
            elseif CQ_Log.debugConsumables then
                DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[CONS CAST] Unresolved GUID spellID=" ..
                    tostring(spellID) .. " key=" .. buffKey .. "|r");
            end
        end
    end

    -- ---- 2. Class buffs ------------------------------------------------
    local spellDef = CQ_Log_ClassBuffSpellIDs[spellID];
    if spellDef and CQ_Log.isLogging then
        local playerName = CQ_SpellGo_ResolveGuid(casterGuid);
        if playerName then
            CQ_Log_RecordClassBuff(playerName, spellDef.key, spellDef.name);
        elseif CQ_Log.debugConsumables then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[CLASS BUFF] Unresolved GUID " ..
                tostring(casterGuid) .. " for spellID " .. tostring(spellID) .. "|r");
        end
    end

    -- ---- 3. Sunder Armor -----------------------------------------------
    if CQ_Log_SunderSpellIDs[spellID] then
        local now = GetTime();
        local playerName = CQ_SpellGo_ResolveGuid(casterGuid);
        if playerName then
            CQ_Log_RecordSunder(playerName);
            if CQ_Log.debugConsumables then
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff[SUNDER] " .. playerName ..
                    " via GUID scan (" .. tostring(casterGuid) .. ")|r");
            end
        else
            -- Fallback: queue for chat-event resolution
            table.insert(CQ_Log_PendingGuidQueue, { guid = casterGuid, timestamp = now });
            if CQ_Log.debugConsumables then
                DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[SUNDER] Unknown GUID " ..
                    tostring(casterGuid) .. " - queued for chat resolution|r");
            end
        end
    end
end);

-- Name-resolution fallback: CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE.
-- Only reached when UnitGUID is unavailable or a GUID wasn't in the roster
-- snapshot at cast time (e.g. player just zoned in).
-- With UnitGUID working correctly this handler fires but the queue is empty
-- and it exits immediately after the Sunder Armor guard.
CQ_SunderNameFrame = CreateFrame("Frame");
CQ_SunderNameFrame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE");
CQ_SunderNameFrame:SetScript("OnEvent", function()
    local message = arg1;
    if not string.find(message, "Sunder Armor") then return; end

    -- Nothing pending - common case when GetUnitGUID resolved everything already
    if table.getn(CQ_Log_PendingGuidQueue) == 0 then return; end

    local now = GetTime();

    -- Collect pending GUIDs still within the resolve window
    local resolved = {};
    local expired  = {};
    for _, entry in ipairs(CQ_Log_PendingGuidQueue) do
        if (now - entry.timestamp) <= CQ_Log_GUID_RESOLVE_WINDOW then
            table.insert(resolved, entry);
        else
            table.insert(expired, entry);
        end
    end
    CQ_Log_PendingGuidQueue = {};

    -- For expired-but-still-unresolved entries, try one last GetUnitGUID scan.
    -- This handles silent Sunder refreshes at max stacks where no chat
    -- message fires and the resolve window closes before we get here.
    if table.getn(expired) > 0 then
        CQ_Log_RebuildGuidMap(); -- ensure map is current
        local stillExpired = {};
        for _, entry in ipairs(expired) do
            local rescuedName = CQ_Log_GuidMap[entry.guid];
            if rescuedName then
                CQ_Log_RecordSunder(rescuedName);
                if CQ_Log.debugConsumables then
                    DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff[SUNDER] Late-rescue GUID " ..
                        tostring(entry.guid) .. " -> " .. rescuedName .. "|r");
                end
            else
                table.insert(stillExpired, entry);
                if CQ_Log.debugConsumables then
                    DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SUNDER] GUID " ..
                        tostring(entry.guid) .. " expired unresolved|r");
                end
            end
        end
        expired = stillExpired;
    else
        for _, entry in ipairs(expired) do
            if CQ_Log.debugConsumables then
                DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SUNDER] GUID " ..
                    tostring(entry.guid) .. " expired unresolved|r");
            end
        end
    end

    if table.getn(resolved) == 0 then return; end

    -- Last-resort name resolution: find Warriors in the roster.
    -- Last-resort: no GUID matched; use warrior count heuristic when there is exactly one
    -- Warrior. Multiple Warriors get a GUID-suffix placeholder so counts
    -- still accumulate consistently rather than being silently dropped.
    local warriors = {};
    local selfName  = UnitName("player");
    local _, selfClass = UnitClass("player");
    if selfClass == "WARRIOR" then
        table.insert(warriors, { name = selfName, guid = GetUnitGUID("player") });
    end

    local numRaid = GetNumRaidMembers();
    if numRaid > 0 then
        for i = 1, numRaid do
            local unit = "raid" .. i;
            local name = UnitName(unit);
            local _, class = UnitClass(unit);
            if name and class == "WARRIOR" then
                local isDup = false;
                for _, w in ipairs(warriors) do
                    if w.name == name then isDup = true; break; end
                end
                if not isDup then
                    table.insert(warriors, { name = name, guid = GetUnitGUID(unit) });
                end
            end
        end
    else
        local numParty = GetNumPartyMembers();
        for i = 1, numParty do
            local unit = "party" .. i;
            local name = UnitName(unit);
            local _, class = UnitClass(unit);
            if name and class == "WARRIOR" then
                table.insert(warriors, { name = name, guid = GetUnitGUID(unit) });
            end
        end
    end

    for _, entry in ipairs(resolved) do
        local name;

        -- Try to match GUID against the warrior list (GetUnitGUID scan works
        -- even if it was absent at cast time due to roster initialisation lag)
        for _, w in ipairs(warriors) do
            if w.guid and w.guid == entry.guid then
                name = w.name;
                break;
            end
        end

        if not name then
            if table.getn(warriors) == 1 then
                name = warriors[1].name;
            else
                -- Truly ambiguous - use a stable GUID-keyed placeholder but do NOT
                -- cache it in CQ_Log_GuidMap so future lookups can still resolve
                -- to a real name once the roster is fully loaded.
                local placeholder = "Warrior-" .. string.sub(tostring(entry.guid), -6);
                CQ_Log_RecordSunder(placeholder);
                if CQ_Log.debugConsumables then
                    DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[SUNDER] Fallback placeholder " ..
                        placeholder .. " (GUID " .. tostring(entry.guid) .. " unresolved)|r");
                end
                -- Do not fall through to the cache/migrate block below
            end
        end

        if name then
            -- Resolved to a real name: cache it and migrate any existing placeholder counts.
            local placeholder = "Warrior-" .. string.sub(tostring(entry.guid), -6);
            CQ_Log_GuidMap[entry.guid] = name;

            -- Migrate placeholder spell counts to the real name if any exist
            if CQ_Log.isLogging and CQ_Log.currentRaidId then
                local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
                if raid and raid.spells and raid.spells[placeholder] then
                    if not raid.spells[name] then
                        raid.spells[name] = raid.spells[placeholder];
                    else
                        -- Merge: add counts from placeholder into existing real-name entry
                        for spellKey, spellData in pairs(raid.spells[placeholder]) do
                            if raid.spells[name][spellKey] then
                                raid.spells[name][spellKey].count =
                                    raid.spells[name][spellKey].count + spellData.count;
                            else
                                raid.spells[name][spellKey] = spellData;
                            end
                        end
                    end
                    raid.spells[placeholder] = nil;
                    if CQ_Log.debugConsumables then
                        DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff[SUNDER] Migrated placeholder " ..
                            placeholder .. " -> " .. name .. "|r");
                    end
                end
            end

            CQ_Log_RecordSunder(name);
        end

        if CQ_Log.debugConsumables and name then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff[SUNDER] Fallback resolved GUID " ..
                tostring(entry.guid) .. " -> " .. name .. "|r");
        end
    end
end);

-- Zone change event
function CQ_Log_ZoneChanged()
    local newZone = GetRealZoneText();
    
    if CQ_Log_ValidZones[newZone] then
        if not CQ_Log.isLogging and not CQ_Log.isPendingCombat then
            -- Entering a raid zone fresh - arm pending-combat wait (logging starts on first combat)
            if UnitInRaid("player") then
                CQ_Log.currentZone = newZone;
                CQ_Log_ArmPendingCombat();
            end
        elseif CQ_Log.isPendingCombat then
            -- Moved to a different valid zone before first combat (e.g. entered BWL wing
            -- after arming on MC entrance). Just update the stored zone so InitializeRaid
            -- uses the correct one when combat eventually starts.
            CQ_Log.currentZone = newZone;
        elseif CQ_Log.isLogging then
            -- Already logging. Guard against currentZone being nil (player was
            -- already inside the instance when the addon loaded or /conqlog start
            -- was used manually). If nil, adopt the new zone and keep logging.
            if not CQ_Log.currentZone then
                CQ_Log.currentZone = newZone;
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RAB Log] Zone re-acquired: " .. newZone .. " - logging continues|r");
            else
                -- Moving between raid zones in the same group (e.g. Karazhan <-> Rock of Desolation,
                -- or Molten Core <-> Blackwing Lair). Check by looking up whether both zones
                -- belong to the same entry in CQ_Log_RaidGroups rather than comparing the
                -- safeZone value directly (table == table is always false in Lua).
                local sameGroup = false;
                for _, group in ipairs(CQ_Log_RaidGroups) do
                    if group.zones[CQ_Log.currentZone] and group.zones[newZone] then
                        sameGroup = true;
                        break;
                    end
                end
                if sameGroup then
                    CQ_Log.currentZone = newZone;
                    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RAB Log] Zone transition within raid group: " .. newZone .. "|r");
                else
                    -- Different raid group - finalize and arm fresh pending-combat wait
                    CQ_Log_FinalizeRaid();
                    if UnitInRaid("player") then
                        CQ_Log.currentZone = newZone;
                        CQ_Log_ArmPendingCombat();
                    end
                end
            end
        end
    elseif CQ_Log.isPendingCombat then
        -- Left the zone before ever entering combat - disarm
        CQ_Log.isPendingCombat = false;
        CQ_Log.currentZone = nil;
        DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[RAB Log] Left raid zone before combat - logging cancelled|r");
    elseif CQ_Log.isLogging then
        if CQ_Log_IsActiveSafeZone(newZone) then
            -- Entered the graveyard/release zone for this raid - keep logging.
            -- Do NOT clear currentZone; IsActiveSafeZone depends on it staying
            -- set to the raid zone so a second death->release still resolves.
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[RAB Log] Entered safe zone (" .. newZone .. ") - logging continues|r");
        else
            -- Left to an unrelated zone - finalize
            CQ_Log_FinalizeRaid();
            CQ_Log.currentZone = nil;
        end
    end
end

-- Arm the "waiting for first combat" state when entering a raid zone.
-- zone must already be stored in CQ_Log.currentZone before calling this.
function CQ_Log_ArmPendingCombat()
    CQ_Log.isPendingCombat = true;
    CQ_Log.isLogging = false;
    DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[RAB Log] Waiting for first combat to start logging (" .. (CQ_Log.currentZone or "?") .. ")...|r");
end

-- Combat events
function CQ_Log_EnterCombat()
    -- First combat after zoning in: start logging now
    if CQ_Log.isPendingCombat then
        CQ_Log.isPendingCombat = false;
        CQ_Log.isLogging = true;
        CQ_Log_InitializeRaid();
    end

    if CQ_Log.isLogging then
        CQ_Log.inCombat = true;
        if not CQ_Log.combatStartTime then
            CQ_Log.combatStartTime = GetTime();
        end
    end
end

function CQ_Log_LeaveCombat()
    if CQ_Log.isLogging then
        CQ_Log.inCombat = false;
        CQ_Log.combatStartTime = nil;
    end
end

-- Group update handler
-- Only used to arm logging when you join a raid in a valid zone.
-- Stopping logging when you leave is handled by ZoneChanged (you'll leave
-- the raid zone) or /conqlog stop. We do NOT check UnitInRaid here because
-- RAID_ROSTER_UPDATE fires constantly for other players' events and
-- UnitInRaid("player") can flicker false during normal roster syncs.
function CQ_Log_GroupUpdate()
    local currentZone = GetRealZoneText();
    if not CQ_Log.isLogging and not CQ_Log.isPendingCombat then
        if (CQ_Log_ValidZones[currentZone] or CQ_Log_IsActiveSafeZone(currentZone)) and UnitInRaid("player") then
            if CQ_Log_ValidZones[currentZone] then
                CQ_Log.currentZone = currentZone;
            end
            CQ_Log_ArmPendingCombat();
        end
    end
end

-- Count number of raids
function CQ_Log_CountRaids()
    if not CQui_RaidLogs or not CQui_RaidLogs.raids then return 0; end
    
    local count = 0;
    for _, _ in pairs(CQui_RaidLogs.raids) do
        count = count + 1;
    end
    return count;
end

-- Initialize the raid logger
function CQ_Log_Init()
    -- Bootstrap CQui_RaidLogs in case the SavedVariable is nil on fresh install.
    if type(CQui_RaidLogs) ~= "table" then
        CQui_RaidLogs = { raids = {}, version = "2.0.0" };
    end
    if type(CQui_RaidLogs.raids) ~= "table" then
        CQui_RaidLogs.raids = {};
    end
    if not CQui_RaidLogs.version then
        CQui_RaidLogs.version = "2.0.0";
    end

    CQ_Log_CheckSuperwow();

    -- Seed GUID->name map immediately so the first Sunder cast resolves correctly
    CQ_Log_RebuildGuidMap();
    RAB_Core_Register("PLAYER_REGEN_DISABLED", "raidlog_combat", CQ_Log_EnterCombat);
    RAB_Core_Register("PLAYER_REGEN_ENABLED", "raidlog_combat", CQ_Log_LeaveCombat);
    RAB_Core_Register("ZONE_CHANGED_NEW_AREA", "raidlog_zone", CQ_Log_ZoneChanged);
    RAB_Core_Register("RAID_ROSTER_UPDATE", "raidlog_roster", CQ_Log_GroupUpdate);
    RAB_Core_Register("PARTY_MEMBERS_CHANGED", "raidlog_party", CQ_Log_GroupUpdate);

    -- Mana potion and Nordanaar Tea tracked via combat log message patterns
    RAB_Core_Register("CHAT_MSG_SPELL_SELF_BUFF", "raidlog_potions", CQ_Log_CombatLogEvent);
    RAB_Core_Register("CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS", "raidlog_potions", CQ_Log_CombatLogEvent);
    RAB_Core_Register("CHAT_MSG_SPELL_PARTY_BUFF", "raidlog_potions", CQ_Log_CombatLogEvent);
    RAB_Core_Register("CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS", "raidlog_potions", CQ_Log_CombatLogEvent);
    RAB_Core_Register("CHAT_MSG_SPELL_FRIENDLYPLAYER_BUFF", "raidlog_potions", CQ_Log_CombatLogEvent);
    RAB_Core_Register("CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS", "raidlog_potions", CQ_Log_CombatLogEvent);

    -- Goblin Sapper Charge tracked via damage events (no buff icon)
    RAB_Core_Register("CHAT_MSG_SPELL_SELF_DAMAGE", "raidlog_sapper", CQ_Log_SapperEvent);
    RAB_Core_Register("CHAT_MSG_SPELL_FRIENDLYPLAYER_DAMAGE", "raidlog_sapper", CQ_Log_SapperEvent);

    -- Sunder Armor, consumables, and class buffs: primary counting via SPELL_GO
    -- (CQ_SpellGoFrame unified dispatcher), name resolution via
    -- CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE (CQ_SunderNameFrame).
    -- Both frames are registered at file-load time above.
    -- RAB_Core_Register is not used for these because they need direct arg access.

    -- Add timer for periodic checks
    RAB_Core_AddTimer(CQ_Log.checkInterval, "raidlog_check", CQ_Log_PerformCheck);

    -- Add auto-export timer if Nampower WriteCustomFile is available
    if CQ_Log.hasFileExport then
        RAB_Core_AddTimer(60, "raidlog_autoexport", CQ_Log_AutoExportCheck);
    end
    
    -- Check if we're already in a raid zone at load time
    local currentZone = GetRealZoneText();
    if CQ_Log_ValidZones[currentZone] and UnitInRaid("player") then
        CQ_Log.currentZone = currentZone;
        CQ_Log_ArmPendingCombat();
    end
    

end

-- Slash command handler
SLASH_CONQLOG1 = "/conqlog";
SlashCmdList["CONQLOG"] = function(msg)
    msg = strlower(msg or "");
    
    if msg == "export" or msg == "exportnow" then
        if CQ_Log.hasFileExport then
            if CQ_Log_ExportToFile(false) then
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RAB Log] Raid data exported successfully!|r");
            end
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[RAB Log] Export requires Nampower WriteCustomFile. Data is not persisted without it.|r");
        end
    elseif msg == "exportall" then
        CQ_Log_ExportAllRaids();
    elseif msg == "format" or msg == "format lua" then
        CQ_Log.exportFormat = "lua";
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RAB Log] Export format set to: Lua (.lua)|r");
    elseif msg == "format json" then
        CQ_Log.exportFormat = "json";
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RAB Log] Export format set to: JSON (.json)|r");
    elseif msg == "verbose" then
        CQ_Log.verboseExport = not CQ_Log.verboseExport;
        if CQ_Log.verboseExport then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RAB Log] Export keys: VERBOSE (full names)|r");
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[RAB Log] Export keys: SHORTENED (default)|r");
        end
        if CQ_Config_Update then CQ_Config_Update(); end
    elseif msg == "interval" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RAB Log] Auto-export interval: " .. CQ_Log.autoExportInterval .. " seconds (" .. (CQ_Log.autoExportInterval / 60) .. " minutes)|r");
    elseif string.find(msg, "^interval %d+") then
        local _, _, seconds = string.find(msg, "^interval (%d+)");
        if seconds then
            CQ_Log.autoExportInterval = tonumber(seconds);
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RAB Log] Auto-export interval set to: " .. CQ_Log.autoExportInterval .. " seconds|r");
        end
    elseif msg == "save" then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[RAB Log] Raid data is no longer saved to SavedVariables.|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cffff9900Use /conqlog export (requires Nampower WriteCustomFile) to export data to a file.|r");
    elseif msg == "status" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00=== RAID LOG STATUS ===|r");
        if CQ_Log.isPendingCombat then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900Raid logging PENDING - waiting for first combat|r");
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900Zone: " .. (CQ_Log.currentZone or "unknown") .. "|r");
        elseif CQ_Log.isLogging then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Raid logging is ACTIVE|r");
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Current Raid ID: " .. (CQ_Log.currentRaidId or "none") .. "|r");
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Zone: " .. (CQ_Log.currentZone or "unknown") .. "|r");
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00In Combat: " .. tostring(CQ_Log.inCombat) .. "|r");
            local safeZone = CQ_Log_GetSafeZone(CQ_Log.currentZone or "");
            if safeZone then
                local safeZoneStr;
                if type(safeZone) == "table" then
                    local parts = {};
                    for z, _ in pairs(safeZone) do table.insert(parts, z); end
                    safeZoneStr = table.concat(parts, ", ");
                else
                    safeZoneStr = safeZone;
                end
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Safe zone: " .. safeZoneStr .. "|r");
            end
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900Raid logging is INACTIVE|r");
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Total raids logged: " .. CQ_Log_CountRaids() .. "|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Track out of combat: " .. tostring(CQ_Log.trackOutOfCombat) .. "|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Debug potions: " .. tostring(CQ_Log.debugPotions) .. "|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Nampower WriteCustomFile export: " .. tostring(CQ_Log.hasFileExport) .. "|r");
        if CQ_Log.hasFileExport then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Export format: " .. CQ_Log.exportFormat .. "|r");
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Auto-export interval: " .. (CQ_Log.autoExportInterval / 60) .. " min|r");
        end
    elseif msg == "toggle" or msg == "togglecombat" then
        CQ_Log.trackOutOfCombat = not CQ_Log.trackOutOfCombat;
        if CQ_Log.trackOutOfCombat then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Raid logging will track data both IN and OUT of combat|r");
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900Raid logging will ONLY track data during combat|r");
        end
    elseif msg == "testenchant" or msg == "testenchants" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RAB Log] === WEAPON ENCHANT PATTERN TEST ===|r");
        local testMessages = {
            { msg = "Your weapon is imbued with Brilliant Mana Oil.",             expect = "brillmanaoil" },
            { msg = "Your weapon is enchanted with Brilliant Mana Oil.",          expect = "brillmanaoil" },
            { msg = "Raidmember's weapon is imbued with Brilliant Wizard Oil.",   expect = "brilliantwizardoil" },
            { msg = "Your weapon is imbued with Consecrated Sharpening Stone.",   expect = "consecratedstone" },
            { msg = "Raidmember's weapon is enchanted with Dense Weightstone.",   expect = "denseweightstone" },
            { msg = "Your weapon is imbued with Frost Oil.",                      expect = "frostoil" },
            { msg = "Your weapon is imbued with Totally Unknown Oil.",            expect = "NO MATCH" },
        };
        for _, t in ipairs(testMessages) do
            local matched = "NO MATCH";
            if string.find(t.msg, "weapon") and
               (string.find(t.msg, "imbued") or string.find(t.msg, "enchanted")) then
                for _, entry in ipairs(CQ_Log_WeaponEnchantPatterns) do
                    if string.find(t.msg, entry.pattern) then
                        matched = entry.buffKey;
                        break;
                    end
                end
            end
            local ok = (matched == t.expect);
            local color = ok and "|cff00ff00" or "|cffff0000";
            DEFAULT_CHAT_FRAME:AddMessage(color .. "[" .. (ok and "OK" or "FAIL") .. "] " .. t.msg .. "|r");
            if not ok then
                DEFAULT_CHAT_FRAME:AddMessage("       Expected: " .. t.expect .. "  Got: " .. matched);
            end
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RAB Log] === END TEST ===|r");
    elseif msg == "testpotion" or msg == "testpotions" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RAB Log] === POTION PATTERN TEST ===|r");
        local testMessages = {
            { msg = "You gain 1741 Mana from Restore Mana.",                        expect = "majorMana" },
            { msg = "Durotavich gains 2218 Mana from Durotavich 's Restore Mana.", expect = "majorMana" },
            { msg = "You gain 983 Mana from Tea.",                                  expect = "nordanaarTea" },
            { msg = "Durotavich gains 913 Mana from Durotavich 's Tea.",            expect = "nordanaarTea" },
            { msg = "Your Tea heals you for 611.",                                  expect = "IGNORED (heal)" },
            { msg = "Durotavich's Tea heals Durotavich for 400.",                   expect = "IGNORED (heal)" },
            { msg = "You gain Invulnerability.",                                    expect = "limitinvulpotion" },
            { msg = "Cabesilla gains Invulnerability.",                             expect = "limitinvulpotion" },
        };
        for _, t in ipairs(testMessages) do
            local matched = "NO MATCH";
            if string.find(t.msg, "Restore Mana") then
                matched = "majorMana";
            elseif string.find(t.msg, "from.*Tea") then
                matched = "nordanaarTea";
            elseif string.find(t.msg, "Your Tea heals") or string.find(t.msg, "'s Tea heals") then
                matched = "IGNORED (heal)";
            elseif string.find(t.msg, "Invulnerability") then
                matched = "limitinvulpotion";
            end
            local color = (matched == t.expect) and "|cff00ff00" or "|cffff0000";
            DEFAULT_CHAT_FRAME:AddMessage(color .. "[" .. (matched == t.expect and "OK" or "FAIL") .. "] " .. t.msg .. "|r");
            DEFAULT_CHAT_FRAME:AddMessage("       Expected: " .. t.expect .. "  Got: " .. matched);
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RAB Log] === END TEST ===|r");
    elseif msg == "potions" or msg == "showpotions" then
        -- Show current potion counts for active raid
        if not CQ_Log.currentRaidId or not CQui_RaidLogs.raids[CQ_Log.currentRaidId] then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[RAB Log] No active raid session|r");
        else
            local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00=== POTION USAGE THIS RAID ===|r");
            local found = false;
            for playerName, potionData in pairs(raid.potions) do
                if (potionData.majorMana or 0) > 0 or (potionData.nordanaarTea or 0) > 0 or (potionData.limitinvulpotion or 0) > 0 then
                    DEFAULT_CHAT_FRAME:AddMessage("|cffffffff" .. playerName .. "|r: ManaPotion=" .. (potionData.majorMana or 0) .. "  Tea=" .. (potionData.nordanaarTea or 0) .. "  LimInvul=" .. (potionData.limitinvulpotion or 0));
                    found = true;
                end
            end
            if not found then
                DEFAULT_CHAT_FRAME:AddMessage("|cffff9900No potion/tea usage recorded yet|r");
            end
        end
    elseif msg == "debugpotions" or msg == "debugpotion" then
        CQ_Log.debugPotions = not CQ_Log.debugPotions;
        if CQ_Log.debugPotions then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Potion debug mode ENABLED|r");
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900Potion debug mode DISABLED|r");
        end
    elseif msg == "debugconsumables" or msg == "debugconsumable" then
        CQ_Log.debugConsumables = not CQ_Log.debugConsumables;
        if CQ_Log.debugConsumables then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Consumable debug mode ENABLED|r");
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900Consumable debug mode DISABLED|r");
        end
    elseif msg == "simulate" then
        -- Inject fake data through the real tracking pipeline for every category.
        -- Safe to use: no items are consumed, no spells are cast, no game state
        -- is modified. All data lands in the active raid log exactly as real
        -- events would, so the export and parser see realistic output.
        -- Requires logging to be active (/conqlog start first).
        if not CQ_Log.isLogging or not CQ_Log.currentRaidId then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[RAB Log] Not logging. Run /conqlog start first.|r");
            return;
        end

        local playerName = UnitName("player");
        local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
        local totals = { cons=0, classbuff=0, sunder=0, wepenchant=0 };

        -- ---- 1. Consumables (via cast pipeline) ----------------------------
        -- Calls the same integration function a real SPELL_GO event would hit.
        if CQ_ConsInt_OnConsumable then
            for spellID, consumableName in pairs(CQ_ConsTracker_Tracked or {}) do
                CQ_ConsInt_OnConsumable(
                    playerName, spellID, consumableName, consumableName, GetTime(), "CAST");
                totals.cons = totals.cons + 1;
            end
        end

        -- ---- 2. Weapon enchants (via RecordBuffUse directly) ---------------
        -- Weapon enchants are tracked via AURA_CAST / wepbuffonly polling;
        -- simulate credits one application of each tracked weapon buff key.
        if CQ_Buffs then
            for buffKey, buffData in pairs(CQ_Buffs) do
                if buffData.type == "wepbuffonly" then
                    CQ_Log_RecordBuffUse(playerName, buffKey);
                    totals.wepenchant = totals.wepenchant + 1;
                end
            end
        end

        -- ---- 3. Class buffs (via RecordClassBuff) --------------------------
        -- Deduplicate by key so we fire one cast per distinct buff type.
        local classbuffSeen = {};
        for _, spellDef in pairs(CQ_Log_ClassBuffSpellIDs or {}) do
            if not classbuffSeen[spellDef.key] then
                classbuffSeen[spellDef.key] = true;
                CQ_Log_RecordClassBuff(playerName, spellDef.key, spellDef.name);
                totals.classbuff = totals.classbuff + 1;
            end
        end

        -- ---- 4. Sunder Armor (via RecordSunder) ----------------------------
        CQ_Log_RecordSunder(playerName);
        totals.sunder = 1;

        -- ---- 5. Death ------------------------------------------------------
        -- Directly write one death into the raid data, same as OnDeath would.
        if CQ_Log.trackDeaths then
            if not raid.players[playerName] then
                raid.players[playerName] = {
                    class = select(2, UnitClass("player")) or "Unknown",
                    participationTime = 0, lastSeen = time(), firstSeen = time(),
                    consumables = {}, deaths = 0,
                };
            end
            raid.players[playerName].deaths = (raid.players[playerName].deaths or 0) + 1;
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[SIM] Recorded 1 death for " .. playerName .. "|r");
        end

        -- ---- 6. Loot -------------------------------------------------------
        -- Inject a fake item directly into raid.loot.
        if CQ_Log.trackLoot then
            if not raid.loot then raid.loot = {}; end
            table.insert(raid.loot, {
                player    = playerName,
                itemLink  = "|cff0070dd|Hitem:18832:0:0:0|h[Brutality Blade]|h|r",
                quantity  = 1,
                timestamp = time(),
            });
            DEFAULT_CHAT_FRAME:AddMessage("|cff0070dd[SIM] Injected fake loot entry for " .. playerName .. "|r");
        end

        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "|cff00ff00[SIM] Done for %s — %d consumable(s), %d weapon enchant(s), " ..
            "%d class buff(s), %d sunder(s). Run /conqlog export to verify.|r",
            playerName, totals.cons, totals.wepenchant, totals.classbuff, totals.sunder));

    elseif msg == "start" then
        -- Force start logging regardless of zone, combat state, or raid membership.
        -- Useful for testing outside raid zones.
        if CQ_Log.isLogging then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[RAB Log] Already logging (raid ID: " .. CQ_Log.currentRaidId .. ")|r");
        else
            CQ_Log.isPendingCombat = false;
            CQ_Log.isLogging = true;
            local zone = GetRealZoneText() or "Unknown";
            if not CQ_Log.currentZone then
                CQ_Log.currentZone = zone;
            end
            CQ_Log_InitializeRaid();
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RAB Log] Logging force-started in " .. zone .. "|r");
        end
    elseif msg == "stop" then
        if CQ_Log.isLogging then
            CQ_Log_FinalizeRaid();
            CQ_Log.currentZone = nil;
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RAB Log] Logging stopped.|r");
        elseif CQ_Log.isPendingCombat then
            CQ_Log.isPendingCombat = false;
            CQ_Log.currentZone = nil;
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[RAB Log] Pending combat cancelled.|r");
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[RAB Log] Not currently logging.|r");
        end
    elseif msg == "sunder" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00=== SUNDER TRACKING STATUS ===|r");
        DEFAULT_CHAT_FRAME:AddMessage("Cast frame (CQ_SunderCastFrame): " .. tostring(CQ_SunderCastFrame ~= nil));
        DEFAULT_CHAT_FRAME:AddMessage("Name frame (CQ_SunderNameFrame): " .. tostring(CQ_SunderNameFrame ~= nil));
        DEFAULT_CHAT_FRAME:AddMessage("GetUnitGUID available: " .. tostring(GetUnitGUID ~= nil));
        DEFAULT_CHAT_FRAME:AddMessage("Pending queue size: " .. table.getn(CQ_Log_PendingGuidQueue));
        local guidCount = 0;
        for guid, name in pairs(CQ_Log_GuidMap) do
            guidCount = guidCount + 1;
            DEFAULT_CHAT_FRAME:AddMessage("  GUID cache: " .. name .. " -> " .. tostring(guid));
        end
        DEFAULT_CHAT_FRAME:AddMessage("Cached GUIDs: " .. guidCount);
        if CQ_Log.currentRaidId and CQui_RaidLogs.raids[CQ_Log.currentRaidId] then
            local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
            local spellCount = 0;
            for player, spells in pairs(raid.spells) do
                for key, data in pairs(spells) do
                    DEFAULT_CHAT_FRAME:AddMessage("  Recorded: " .. player .. " - " .. data.spellName .. " x" .. data.count);
                    spellCount = spellCount + 1;
                end
            end
            if spellCount == 0 then
                DEFAULT_CHAT_FRAME:AddMessage("|cffff9900  No Sunder casts recorded yet this raid.|r");
            end
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900  No active raid log.|r");
        end

    elseif msg == "cache" then
        -- Show all in-memory cache/lookup-table states.
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00=== RAID LOG CACHE CONTENTS ===|r");

        -- 1) GUID -> Name map (Sunder caster resolution)
        local guidCount = 0;
        for _ in pairs(CQ_Log_GuidMap) do guidCount = guidCount + 1; end
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GUID Map (" .. guidCount .. " entries):|r");
        if guidCount == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa  (empty - fire a Sunder or join a raid group)|r");
        else
            for guid, name in pairs(CQ_Log_GuidMap) do
                DEFAULT_CHAT_FRAME:AddMessage("|cffffffff  " .. name .. "|r -> " .. guid);
            end
        end

        -- 2) Pending GUID queue (unresolved Sunder GUIDs awaiting a chat event)
        local pendingCount = table.getn(CQ_Log_PendingGuidQueue);
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Pending GUID Queue (" .. pendingCount .. " entries):|r");
        if pendingCount == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa  (empty)|r");
        else
            local now = GetTime();
            for i = 1, pendingCount do
                local entry = CQ_Log_PendingGuidQueue[i];
                local age = string.format("%.2fs", now - (entry.timestamp or 0));
                DEFAULT_CHAT_FRAME:AddMessage("|cffffffff  [" .. i .. "] guid=" .. tostring(entry.guid) .. " age=" .. age .. "|r");
            end
        end

        -- 3) Sapper dedup table
        local sapperCount = 0;
        for _ in pairs(CQ_Log_SapperDedup) do sapperCount = sapperCount + 1; end
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Sapper Dedup Table (" .. sapperCount .. " entries):|r");
        if sapperCount == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa  (empty)|r");
        else
            local now = GetTime();
            for player, ts in pairs(CQ_Log_SapperDedup) do
                local age = string.format("%.1fs ago", now - ts);
                DEFAULT_CHAT_FRAME:AddMessage("|cffffffff  " .. player .. "|r: last counted " .. age);
            end
        end

        -- 4) ConsumableTracker spell info cache
        if CQ_ConsTracker and CQ_ConsTracker.spellCache then
            local cacheCount = 0;
            for _ in pairs(CQ_ConsTracker.spellCache) do cacheCount = cacheCount + 1; end
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00ConsumableTracker Spell Cache (" .. cacheCount .. " entries):|r");
            if cacheCount == 0 then
                DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa  (empty - no consumables used yet)|r");
            else
                for spellID, info in pairs(CQ_ConsTracker.spellCache) do
                    DEFAULT_CHAT_FRAME:AddMessage("|cffffffff  [" .. spellID .. "] " .. (info[1] or "?") .. " " .. (info[2] or "") .. "|r");
                end
            end
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa ConsumableTracker spell cache: not available|r");
        end

        -- 5) castTrackedConsumables from active raid
        if CQ_Log.currentRaidId and CQui_RaidLogs.raids[CQ_Log.currentRaidId] then
            local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
            local ctc = raid.castTrackedConsumables or {};
            local ctcCount = 0;
            for _ in pairs(ctc) do ctcCount = ctcCount + 1; end
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Cast-Tracked Consumables (active raid, " .. ctcCount .. " entries):|r");
            if ctcCount == 0 then
                DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa  (empty - no SPELL_GO consumables recorded)|r");
            else
                local now = GetTime();
                for key, v in pairs(ctc) do
                    local age = string.format("%.0fs ago", now - (v.timestamp or 0));
                    local buffKey = string.match(key, "%.(.+)$") or key;
                    local dur = CQ_Log_ConsumableDurations[buffKey] or 0;
                    local expiresIn = dur > 0 and string.format(", expires in ~%.0fs", math.max(0, dur - (now - (v.timestamp or 0)))) or "";
                    DEFAULT_CHAT_FRAME:AddMessage("|cffffffff  " .. key .. "|r (" .. age .. expiresIn .. ")");
                end
            end
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa castTrackedConsumables: no active raid|r");
        end

    elseif msg == "benchmark" then
        -- Show timing diagnostics and event throughput stats.
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00=== RAID LOG BENCHMARK / TIMING ===|r");

        -- Check interval settings
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Check Interval: " .. CQ_Log.checkInterval .. "s|r");
        local timeSinceLast = math.floor(GetTime() - CQ_Log.lastCheckTime);
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Time Since Last Check: " .. timeSinceLast .. "s (next in ~" .. math.max(0, CQ_Log.checkInterval - timeSinceLast) .. "s)|r");

        -- Session uptime
        if CQ_Log.sessionStartTime then
            local sessionAge = time() - CQ_Log.sessionStartTime;
            local sessionMins = math.floor(sessionAge / 60);
            local sessionSecs = math.mod(sessionAge, 60);
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Session Uptime: " .. sessionMins .. "m " .. sessionSecs .. "s|r");
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa Session Uptime: not logging|r");
        end

        -- Combat timing
        if CQ_Log.combatStartTime then
            local combatAge = math.floor(GetTime() - CQ_Log.combatStartTime);
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Current Combat: " .. combatAge .. "s|r");
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa Current Combat: not in combat|r");
        end

        -- Auto-export timing
        if CQ_Log.hasFileExport then
            local timeSinceExport = math.floor(GetTime() - CQ_Log.lastExportTime);
            local nextExportIn = math.max(0, CQ_Log.autoExportInterval - timeSinceExport);
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Auto-Export Interval: " .. (CQ_Log.autoExportInterval / 60) .. " min|r");
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Last Export: " .. timeSinceExport .. "s ago (next in ~" .. nextExportIn .. "s)|r");
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa Auto-Export: Nampower WriteCustomFile not available|r");
        end

        -- Data volume: count total events recorded in current raid
        if CQ_Log.currentRaidId and CQui_RaidLogs.raids[CQ_Log.currentRaidId] then
            local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];

            local playerCount = 0;
            local consumableCount = 0;
            for pName, pData in pairs(raid.players or {}) do
                playerCount = playerCount + 1;
                for _ in pairs(pData.consumables or {}) do
                    consumableCount = consumableCount + 1;
                end
            end

            local ctcCount = 0;
            for _ in pairs(raid.castTrackedConsumables or {}) do ctcCount = ctcCount + 1; end

            local deathCount = table.getn(raid.deaths or {});
            local lootCount  = table.getn(raid.loot or {});

            local spellPlayerCount = 0;
            local totalSpellCasts = 0;
            for _, spells in pairs(raid.spells or {}) do
                spellPlayerCount = spellPlayerCount + 1;
                for _, data in pairs(spells) do
                    totalSpellCasts = totalSpellCasts + (data.count or 0);
                end
            end

            local manaTotal = 0;
            local teaTotal  = 0;
            for _, potData in pairs(raid.potions or {}) do
                manaTotal = manaTotal + (potData.majorMana or 0);
                teaTotal  = teaTotal  + (potData.nordanaarTea or 0);
            end

            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00--- Current Raid Data Volume ---");
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Players tracked:        " .. playerCount .. "|r");
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Consumable entries:      " .. consumableCount .. "|r");
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Cast-tracked entries:    " .. ctcCount .. "|r");
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Deaths recorded:         " .. deathCount .. "|r");
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Loot entries:            " .. lootCount .. "|r");
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Sunder casters:          " .. spellPlayerCount .. " (" .. totalSpellCasts .. " total casts)|r");
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Mana potions (raid):     " .. manaTotal .. "|r");
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Nordanaar Tea (raid):    " .. teaTotal .. "|r");

            -- GUID map & pending queue
            local guidCount2 = 0;
            for _ in pairs(CQ_Log_GuidMap) do guidCount2 = guidCount2 + 1; end
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GUID map size:           " .. guidCount2 .. "|r");
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Pending GUID queue:      " .. table.getn(CQ_Log_PendingGuidQueue) .. "|r");
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa No active raid - no data volume stats available.|r");

            -- Still show GUID map sizes for idle diagnostics
            local guidCount2 = 0;
            for _ in pairs(CQ_Log_GuidMap) do guidCount2 = guidCount2 + 1; end
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GUID map size: " .. guidCount2 .. "|r");
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Pending GUID queue: " .. table.getn(CQ_Log_PendingGuidQueue) .. "|r");
        end

        -- Total raids ever logged this session
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Total raids in memory: " .. CQ_Log_CountRaids() .. "|r");

    elseif msg == "sniff" then
        -- Toggle a broad combat log listener to find what message fires on weapon enchant application.
        if CQ_Log.sniffing then
            CQ_Log.sniffing = false;
            local events = {
                "CHAT_MSG_SPELL_SELF_BUFF", "CHAT_MSG_SPELL_SELF_DAMAGE",
                "CHAT_MSG_SPELL_PARTY_BUFF", "CHAT_MSG_SPELL_FRIENDLYPLAYER_BUFF",
                "CHAT_MSG_SPELL_ITEM_ENCHANTMENTS", "CHAT_MSG_SPELL_CREATURE_VS_SELF_BUFF",
                "CHAT_MSG_SYSTEM", "CHAT_MSG_COMBAT_SELF_HITS", "CHAT_MSG_COMBAT_SELF_MISSES",
                "CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS", "CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS",
                "CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS",
            };
            for _, ev in ipairs(events) do
                RAB_Core_Unregister(ev, "raidlog_sniff");
            end
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[RAB Log] Combat log sniff DISABLED|r");
        else
            CQ_Log.sniffing = true;
            local sniffFunc = function()
                DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[SNIFF][" .. (event or "?") .. "] " .. tostring(arg1) .. "|r");
            end;
            local events = {
                "CHAT_MSG_SPELL_SELF_BUFF", "CHAT_MSG_SPELL_SELF_DAMAGE",
                "CHAT_MSG_SPELL_PARTY_BUFF", "CHAT_MSG_SPELL_FRIENDLYPLAYER_BUFF",
                "CHAT_MSG_SPELL_ITEM_ENCHANTMENTS", "CHAT_MSG_SPELL_CREATURE_VS_SELF_BUFF",
                "CHAT_MSG_SYSTEM", "CHAT_MSG_COMBAT_SELF_HITS", "CHAT_MSG_COMBAT_SELF_MISSES",
                "CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS", "CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS",
                "CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS",
            };
            for _, ev in ipairs(events) do
                RAB_Core_Register(ev, "raidlog_sniff", sniffFunc);
            end
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RAB Log] Combat log sniff ENABLED - apply your oil now|r");
        end
    elseif msg == "debugcombatlog" or msg == "dcl" then
        -- Toggle a comprehensive combat log + UNIT_CASTEVENT listener.
        -- Designed specifically to identify what fires when a consumable is used.
        -- Prints event name, full message (arg1), and any extra args that carry
        -- player names or spell IDs.  Use this to figure out which patterns to
        -- add to CQ_Log_BuffUsePatterns.
        --
        -- HOW TO USE:
        --   1) /conqlog debugcombatlog   (or /conqlog dcl)
        --   2) Use the consumable you want to identify (eat it, drink it, apply it)
        --   3) Ask a raid member to use one and watch for their name in the output
        --   4) /conqlog debugcombatlog again to turn it off
        --   5) Tell the developer which event + message text fired

        if CQ_Log.debugCombatLog then
            -- ---- DISABLE ------------------------------------------------
            CQ_Log.debugCombatLog = false;

            local chatEvents = {
                "CHAT_MSG_SPELL_SELF_BUFF",
                "CHAT_MSG_SPELL_SELF_DAMAGE",
                "CHAT_MSG_SPELL_PARTY_BUFF",
                "CHAT_MSG_SPELL_PARTY_DAMAGE",
                "CHAT_MSG_SPELL_FRIENDLYPLAYER_BUFF",
                "CHAT_MSG_SPELL_FRIENDLYPLAYER_DAMAGE",
                "CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS",
                "CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS",
                "CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS",
                "CHAT_MSG_SPELL_DAMAGESHIELDS_ON_SELF",
                "CHAT_MSG_SPELL_DAMAGESHIELDS_ON_OTHERS",
            };
            for _, ev in ipairs(chatEvents) do
                RAB_Core_Unregister(ev, "raidlog_dcl");
            end

            -- Unregister SPELL_GO from our dedicated frame
            if CQ_DCL_CastFrame then
                CQ_DCL_CastFrame:UnregisterEvent("SPELL_GO_SELF");
                CQ_DCL_CastFrame:UnregisterEvent("SPELL_GO_OTHER");
            end

            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[RAB DCL] Combat log debug DISABLED|r");
        else
            -- ---- ENABLE -------------------------------------------------
            CQ_Log.debugCombatLog = true;

            -- Chat event handler: prints every message from the tracked events.
            -- Colour-codes by event category so self/party/friendly are easy to tell apart.
            local function DCL_ChatEvent()
                local ev  = event or "?";
                local msg = tostring(arg1 or "");

                -- Skip empty messages and pure whitespace
                if msg == "" then return; end

                -- Colour by source
                local col;
                if string.find(ev, "SELF") then
                    col = "|cff00ff00";    -- green  = self
                elseif string.find(ev, "PARTY") then
                    col = "|cffffff00";    -- yellow = party
                else
                    col = "|cff00ffff";    -- cyan   = friendly player
                end

                -- Short event name: strip "CHAT_MSG_SPELL_" prefix for readability
                local shortEv = string.gsub(ev, "CHAT_MSG_SPELL_", "");
                shortEv = string.gsub(shortEv, "CHAT_MSG_", "");

                DEFAULT_CHAT_FRAME:AddMessage(col .. "[DCL][" .. shortEv .. "]|r " .. msg);
            end

            local chatEvents = {
                "CHAT_MSG_SPELL_SELF_BUFF",
                "CHAT_MSG_SPELL_SELF_DAMAGE",
                "CHAT_MSG_SPELL_PARTY_BUFF",
                "CHAT_MSG_SPELL_PARTY_DAMAGE",
                "CHAT_MSG_SPELL_FRIENDLYPLAYER_BUFF",
                "CHAT_MSG_SPELL_FRIENDLYPLAYER_DAMAGE",
                "CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS",
                "CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS",
                "CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS",
                "CHAT_MSG_SPELL_DAMAGESHIELDS_ON_SELF",
                "CHAT_MSG_SPELL_DAMAGESHIELDS_ON_OTHERS",
            };
            for _, ev in ipairs(chatEvents) do
                RAB_Core_Register(ev, "raidlog_dcl", DCL_ChatEvent);
            end

            -- SPELL_GO handler (Nampower). Prints caster GUID and spell ID.
            if not CQ_DCL_CastFrame then
                CQ_DCL_CastFrame = CreateFrame("Frame");
            end
            SetCVar("NP_EnableSpellGoEvents", "1");
            CQ_DCL_CastFrame:RegisterEvent("SPELL_GO_SELF");
            CQ_DCL_CastFrame:RegisterEvent("SPELL_GO_OTHER");
            CQ_DCL_CastFrame:SetScript("OnEvent", function()
                if not CQ_Log.debugCombatLog then return; end

                -- Nampower SPELL_GO: arg1=itemId, arg2=spellID, arg3=casterGUID
                local spellID    = arg2;
                local casterGuid = tostring(arg3 or "?");

                -- Resolve GUID to a name
                local casterName = CQ_Log_GuidMap and CQ_Log_GuidMap[casterGuid];
                if not casterName then
                    if GetUnitGUID("player") == casterGuid then
                        casterName = UnitName("player");
                    else
                        for i = 1, GetNumRaidMembers() do
                            if GetUnitGUID("raid" .. i) == casterGuid then
                                casterName = UnitName("raid" .. i);
                                break;
                            end
                        end
                    end
                    casterName = casterName or ("GUID:" .. string.sub(casterGuid, 1, 12));
                end

                -- Resolve spell name via Nampower API
                local spellName = "";
                if GetSpellNameAndRankForId and spellID then
                    spellName = GetSpellNameAndRankForId(spellID) or "";
                end
                local spellStr = spellID and
                    ("spellID=" .. tostring(spellID) ..
                     (spellName ~= "" and (" (" .. spellName .. ")") or ""))
                    or "spellID=nil";

                DEFAULT_CHAT_FRAME:AddMessage(
                    "|cffff88ff[DCL][" .. event .. "]|r " ..
                    casterName .. "  " .. spellStr);
            end);
            DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[DCL] SPELL_GO listener armed (Nampower)|r");

            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RAB DCL] Combat log debug ENABLED|r");
            DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa  |cff00ff00Green|r=self  |cffffff00Yellow|r=party  |cff00ffff Cyan|r=friendly  |cffff88ffPink|r=SPELL_GO");
            DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa  Use a consumable now and watch what fires.");
            DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa  /conqlog dcl again to turn off.|r");
        end

    elseif msg == "forcecheck" or msg == "check" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00=== FORCING RAID CHECK ===|r");
        if CQ_Log.isLogging then
            CQ_Log.lastCheckTime = 0;
            CQ_Log_PerformCheck();
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Check complete!|r");
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000Not currently logging a raid|r");
        end
    elseif msg == "superwow" then
        -- Check Nampower API status
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00=== NAMPOWER API STATUS ===|r");
        DEFAULT_CHAT_FRAME:AddMessage("Nampower (GetNampowerVersion):   " .. tostring(GetNampowerVersion ~= nil));
        if GetNampowerVersion then
            local major, minor, patch = GetNampowerVersion();
            DEFAULT_CHAT_FRAME:AddMessage("Nampower version:                " .. major .. "." .. minor .. "." .. patch);
        end
        DEFAULT_CHAT_FRAME:AddMessage("WriteCustomFile (export gate):   " .. tostring(WriteCustomFile ~= nil));
        DEFAULT_CHAT_FRAME:AddMessage("ReadCustomFile  (recovery gate): " .. tostring(ReadCustomFile ~= nil));
        DEFAULT_CHAT_FRAME:AddMessage("GetUnitGUID:                     " .. tostring(GetUnitGUID ~= nil));
        DEFAULT_CHAT_FRAME:AddMessage("GetSpellNameAndRankForId:        " .. tostring(GetSpellNameAndRankForId ~= nil));
        DEFAULT_CHAT_FRAME:AddMessage("UnitBuff spellId support:        " .. (function()
            local tex, stacks, id = UnitBuff("player", 1);
            return tostring(id ~= nil);
        end)());
        if CQ_ConsTracker then
            DEFAULT_CHAT_FRAME:AddMessage("ConsumableTracker enabled:       " .. tostring(CQ_ConsTracker.enabled));
        end
    elseif msg == "findspells" then
        -- Scan bags for weapon enchant items using Nampower's GetSpellNameAndRankForId
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00=== WEAPON ENCHANT SPELL ID SCAN ===|r");
        if not GetSpellNameAndRankForId then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000GetSpellNameAndRankForId not available - requires Nampower|r");
        else
            local itemsToCheck = {
                [20748] = "Brilliant Mana Oil",
                [20749] = "Brilliant Wizard Oil",
                [23123] = "Blessed Wizard Oil",
                [20747] = "Lesser Mana Oil",
                [20750] = "Wizard Oil",
                [3829]  = "Frost Oil",
                [3824]  = "Shadow Oil",
                [23122] = "Consecrated Sharpening Stone",
                [18262] = "Elemental Sharpening Stone",
                [12404] = "Dense Sharpening Stone",
                [12643] = "Dense Weightstone",
            };
            local found = false;
            for bag = 0, 4 do
                for slot = 1, GetContainerNumSlots(bag) do
                    local itemLink = GetContainerItemLink(bag, slot);
                    local itemId = itemLink and tonumber(string.match(itemLink, "item:(%d+)")) or nil;
                    if itemId and itemsToCheck[itemId] then
                        local itemName = itemsToCheck[itemId];
                        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Found in bags: " .. itemName .. " (itemId=" .. itemId .. ")|r");
                        DEFAULT_CHAT_FRAME:AddMessage("|cffff9900Use /conqcons debug then apply it to find the spell ID|r");
                        found = true;
                    end
                end
            end
            if not found then
                DEFAULT_CHAT_FRAME:AddMessage("|cffff9900No weapon enchant items found in bags|r");
            end
        end
    elseif string.find(msg, "^debugplayer ") then
        -- /conqlog debugplayer <name> [buffkey]
        -- Print everything the logger currently knows about a specific player,
        -- optionally filtered to a single buffKey.  Useful for bugs #4 and #5.
        local _, _, targetName, filterKey = string.find(msg, "^debugplayer (%S+)%s*(.*)$");
        if not targetName then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900Usage: /conqlog debugplayer <PlayerName> [buffKey]|r");
        elseif not CQ_Log.currentRaidId or not CQui_RaidLogs.raids[CQ_Log.currentRaidId] then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900No active raid session.|r");
        else
            local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
            local pData = raid.players[targetName];
            if not pData then
                DEFAULT_CHAT_FRAME:AddMessage("|cffff9900Player '" .. targetName .. "' not found in raid log.|r");
                DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa Tip: names are case-sensitive.|r");
            else
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00=== DEBUG: " .. targetName .. " ===|r");
                DEFAULT_CHAT_FRAME:AddMessage("Class: " .. (pData.class or "?") ..
                    "  participation: " .. math.floor((pData.participationTime or 0) / 60) .. "m" ..
                    "  lastSeen: " .. (pData.lastSeen and (time() - pData.lastSeen) .. "s ago" or "never"));
                local cons = pData.consumables or {};
                local shown = 0;
                for bk, cd in pairs(cons) do
                    if filterKey == "" or bk == filterKey then
                        local timeSinceLast = cd.lastCheckTime and (time() - cd.lastCheckTime) or -1;
                        DEFAULT_CHAT_FRAME:AddMessage(string.format(
                            "|cffffffff%s|r  apps=%d  uptime=%ds  lastHad=%s  lastRemaining=%ds  lastCheck=%ds ago",
                            bk,
                            cd.applications or 0,
                            cd.totalUptime   or 0,
                            tostring(cd.lastCheckHad),
                            cd.lastTimeRemaining or 0,
                            math.max(0, math.floor(timeSinceLast))));
                        shown = shown + 1;
                    end
                end
                if shown == 0 then
                    if filterKey ~= "" then
                        DEFAULT_CHAT_FRAME:AddMessage("|cffff9900No entry for buffKey '" .. filterKey .. "' yet.|r");
                    else
                        DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa No consumable entries recorded yet.|r");
                    end
                end
                -- Also show potion data
                local potData = raid.potions and raid.potions[targetName];
                if potData then
                    DEFAULT_CHAT_FRAME:AddMessage(string.format(
                        "|cffaaaaaa Potions: majorMana=%d  tea=%d  limitinvul=%d|r",
                        potData.majorMana or 0, potData.nordanaarTea or 0, potData.limitinvulpotion or 0));
                end
            end
        end
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqlog status - Show logging status|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqlog start - Force start logging (ignores zone/combat/raid checks)|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqlog stop - Force stop logging|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqlog toggle - Toggle out-of-combat tracking|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqlog debugpotions - Toggle verbose potion detection output|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqlog testpotion - Test potion pattern matching|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqlog testenchant - Test weapon enchant pattern matching|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqlog potions - Show potion/tea counts for current raid|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqlog debugplayer <Name> [key] - Dump all consumable state for a player|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqlog debugconsumables - Toggle weapon/consumable debug output|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqlog sunder - Diagnose Sunder Armor tracking (GUID map, frame, recorded casts)|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqlog cache - Show all in-memory cache contents (GUID map, spell cache, etc.)|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqlog benchmark - Show timing diagnostics and data volume stats|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqlog sniff - Toggle broad combat log listener (to find unknown messages)|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqlog debugcombatlog (dcl) - Toggle SPELL_GO + chat debug log|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqlog forcecheck - Force immediate check|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqlog superwow - Check Nampower API status|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqlog findspells - Scan bags for weapon enchant items|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqlog export - Export current raid now (requires Nampower WriteCustomFile)|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqlog exportall - Export all raids (requires Nampower WriteCustomFile)|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqlog format [lua|json] - Set export format|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqlog interval [seconds] - Set auto-export interval|r");
    end
end;

-- ============================================================================
-- DEATH TRACKING
-- ============================================================================

-- Table to track the last attacker for each victim GUID.
-- Updated by SPELL_DAMAGE_EVENT_OTHER and AUTO_ATTACK_OTHER.
-- Consumed (and cleared) by UNIT_DIED.
CQ_LastAttackerByVictim = {};

-- Internal helper: resolve a GUID to a display name.
-- Checks CQ_Log_GuidMap (the primary raidlog map, kept fresh by CQ_SpellGoFrame
-- and CQ_Log_RebuildGuidMap), then falls back to the SpellTracker map, then
-- to UnitName() direct call (SuperWOW supports GUID strings).
local function CQ_Log_GuidToName(guid)
    if not guid then return nil; end
    -- Primary: raidlog GUID map (broader, updated by all SPELL_GO events)
    local name = CQ_Log_GuidMap[guid];
    if name then return name; end
    -- Secondary: SpellTracker map (populated independently)
    if CQ_SpellTracker and CQ_SpellTracker.guidMap then
        name = CQ_SpellTracker.guidMap[guid];
        if name then return name; end
    end
    -- Fallback: SuperWOW UnitName(guid) direct call
    name = UnitName(guid);
    if name and name ~= "" then return name; end
    return nil;
end

-- Damage event frame: tracks last attacker per victim GUID.
local CQ_DeathAttackerFrame = CreateFrame("Frame");

local function CQ_Log_OnDamageEvent()
    -- SPELL_DAMAGE_EVENT_OTHER: arg1=targetGuid, arg2=casterGuid
    -- AUTO_ATTACK_OTHER:        arg1=attackerGuid, arg2=targetGuid
    local attackerGuid, victimGuid;
    if event == "AUTO_ATTACK_OTHER" then
        attackerGuid = arg1;
        victimGuid   = arg2;
    else -- SPELL_DAMAGE_EVENT_OTHER
        victimGuid   = arg1;
        attackerGuid = arg2;
    end

    if not victimGuid or not attackerGuid then return; end

    local attackerName = CQ_Log_GuidToName(attackerGuid) or attackerGuid;
    CQ_LastAttackerByVictim[victimGuid] = attackerName;
end

-- Wire up damage tracking once on load.
-- CVars are set here; they are no-ops if Nampower is absent.
SetCVar("NP_EnableAutoAttackEvents", "1");
CQ_DeathAttackerFrame:RegisterEvent("AUTO_ATTACK_OTHER");
CQ_DeathAttackerFrame:RegisterEvent("SPELL_DAMAGE_EVENT_OTHER");
CQ_DeathAttackerFrame:SetScript("OnEvent", function()
    CQ_Log_OnDamageEvent();
end);

-- UNIT_DIED handler (Nampower event: arg1 = victim GUID string).
local function CQ_Log_OnUnitDied()
    if not CQ_Log.isLogging or not CQ_Log.currentRaidId then
        return;
    end
    if not CQ_Log.trackDeaths then
        return;
    end

    local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
    if not raid then return; end

    local victimGuid = arg1;
    if not victimGuid then return; end

    -- Resolve victim GUID to a player name.
    local playerName = CQ_Log_GuidToName(victimGuid);
    if not playerName then return; end

    -- Only track raid members (or the player themselves).
    local isInRaid = false;
    if playerName == UnitName("player") then
        isInRaid = true;
    else
        for i = 1, GetNumRaidMembers() do
            if UnitName("raid" .. i) == playerName then
                isInRaid = true;
                break;
            end
        end
    end

    if not isInRaid then
        -- Clean up stale attacker entry for non-raid units too.
        CQ_LastAttackerByVictim[victimGuid] = nil;
        return;
    end

    -- Look up last attacker and clean up.
    local killedBy = CQ_LastAttackerByVictim[victimGuid] or "Unknown";
    CQ_LastAttackerByVictim[victimGuid] = nil;

    -- Record the death.
    table.insert(raid.deaths, {
        playerName = playerName,
        killedBy   = killedBy,
        timestamp  = time(),
    });

    -- Initialize player data if needed.
    if not raid.players[playerName] then
        local raidIndex = CQ_Log_GetRaidIndex(playerName);
        local _, playerClass;
        if raidIndex then
            _, playerClass = UnitClass("raid" .. raidIndex);
        elseif playerName == UnitName("player") then
            _, playerClass = UnitClass("player");
        end

        raid.players[playerName] = {
            class             = playerClass or "Unknown",
            participationTime = 0,
            lastSeen          = time(),
            firstSeen         = time(),
            consumables       = {},
            deaths            = 0,
        };
    end

    -- Increment death count.
    raid.players[playerName].deaths = (raid.players[playerName].deaths or 0) + 1;

    if CQ_Log.debugConsumables then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[DEATH] " .. playerName .. " killed by " .. killedBy ..
            " (total deaths: " .. raid.players[playerName].deaths .. ")|r");
    end
end

-- Also wipe the attacker table at the start of each new combat to avoid
-- stale entries from a previous pull carrying over.
local function CQ_Log_WipeAttackerTable()
    CQ_LastAttackerByVictim = {};
end

-- ============================================================================
-- LOOT TRACKING
-- ============================================================================

function CQ_Log_OnLoot()
    if not CQ_Log.isLogging or not CQ_Log.currentRaidId then
        return;
    end
    
    local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
    if not raid then return; end
    
    -- Parse loot message from arg1
    -- Formats:
    -- "You receive loot: [Item Link]."
    -- "You receive loot: [Item Link]x3."
    -- "You receive item: [Item Link]."
    -- "PlayerName receives loot: [Item Link]."
    
    local playerName, itemLink, quantity;
    
    -- Check if it's the player
    if string.find(arg1, "^You receive") then
        playerName = UnitName("player");
        _, _, itemLink, quantity = string.find(arg1, "loot: (|c%x+|Hitem:[^|]+|h%[[^%]]+%]|h|r)x?(%d*)");
        if not itemLink then
            _, _, itemLink, quantity = string.find(arg1, "item: (|c%x+|Hitem:[^|]+|h%[[^%]]+%]|h|r)x?(%d*)");
        end
    else
        -- Check if it's another player
        _, _, playerName, itemLink, quantity = string.find(arg1, "^(.+) receives loot: (|c%x+|Hitem:[^|]+|h%[[^%]]+%]|h|r)x?(%d*)");
    end
    
    if not playerName or not itemLink then
        return;
    end
    
    -- Only track raid members
    local isInRaid = false;
    if playerName == UnitName("player") then
        isInRaid = true;
    else
        for i = 1, GetNumRaidMembers() do
            if UnitName("raid" .. i) == playerName then
                isInRaid = true;
                break;
            end
        end
    end
    
    if not isInRaid then
        return;
    end
    
    -- Extract item ID from link
    local _, _, itemId = string.find(itemLink, "item:(%d+)");
    itemId = tonumber(itemId);
    
    -- Extract item name from link
    -- Item link format: |cffffffff|Hitem:12345:0:0:0|h[Item Name]|h|r
    local itemName = nil;
    local _, _, name = string.find(itemLink, "%[(.-)%]");
    if name and name ~= "" then
        itemName = name;
    end
    
    -- Detect item quality from link colour and apply the quality filter.
    local itemQuality = CQ_Log_GetLinkQuality(itemLink);
    if itemId and itemId > 0 and not CQ_Log_QualityAllowed(itemQuality) then
        if CQ_Log.debugConsumables then
            DEFAULT_CHAT_FRAME:AddMessage("|cff888888[LOOT SKIP] " .. playerName ..
                " looted " .. (itemName or "?") ..
                " (" .. itemQuality .. ") - filtered out by quality setting|r");
        end
        return;
    end
    
    -- Parse quantity
    quantity = tonumber(quantity) or 1;
    
    -- Record the loot
    table.insert(raid.loot, {
        playerName = playerName,
        itemId = itemId,
        itemName = itemName,
        itemQuality = (itemId and itemId > 0) and itemQuality or nil,
        quantity = quantity,
    });
    
    if CQ_Log.debugConsumables then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[LOOT] " .. playerName .. " looted " .. itemLink .. 
            (quantity > 1 and (" x" .. quantity) or "") .. "|r");
    end
end

function CQ_Log_OnMoney()
    if not CQ_Log.isLogging or not CQ_Log.currentRaidId then
        return;
    end
    
    local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
    if not raid then return; end
    
    -- Parse money message from arg1
    -- Format: "Your share of the loot is 5 Gold, 23 Silver, 42 Copper."
    -- Also: "Your share of the loot is 23 Silver, 42 Copper."
    -- Also: "Your share of the loot is 42 Copper."
    if not string.find(arg1, "Your share of the loot is") then return; end

    local gold, silver, copper = 0, 0, 0;
    _, _, gold   = string.find(arg1, "(%d+) Gold");
    _, _, silver = string.find(arg1, "(%d+) Silver");
    _, _, copper = string.find(arg1, "(%d+) Copper");

    gold   = tonumber(gold)   or 0;
    silver = tonumber(silver) or 0;
    copper = tonumber(copper) or 0;

    if gold > 0 or silver > 0 or copper > 0 then
        local amount = gold * 10000 + silver * 100 + copper;

        -- Accumulate into the single raid-level total instead of one entry per drop.
        raid.totalMoneyCopper = (raid.totalMoneyCopper or 0) + amount;

        if CQ_Log.debugConsumables then
            local runningG = math.floor(raid.totalMoneyCopper / 10000);
            local runningS = math.floor(math.mod(raid.totalMoneyCopper, 10000) / 100);
            local runningC = math.mod(raid.totalMoneyCopper, 100);
            DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00[MONEY] +" .. gold .. "g " ..
                silver .. "s " .. copper .. "c  (raid total: " ..
                runningG .. "g " .. runningS .. "s " .. runningC .. "c)|r");
        end
    end
end

-- Register death and loot events
-- UNIT_DIED is a Nampower event; arg1 = victim GUID string.
RAB_Core_Register("UNIT_DIED", "deathtrack", CQ_Log_OnUnitDied);
-- Wipe the last-attacker table at the start of each new combat pull.
RAB_Core_Register("PLAYER_REGEN_DISABLED", "deathAttackerWipe", CQ_Log_WipeAttackerTable);
RAB_Core_Register("CHAT_MSG_LOOT", "loottrack", CQ_Log_OnLoot);
RAB_Core_Register("CHAT_MSG_MONEY", "moneytrack", CQ_Log_OnMoney);

-- Wait for PLAYER_LOGIN to initialize
local initFrame = CreateFrame("Frame");
initFrame:RegisterEvent("PLAYER_LOGIN");
initFrame:SetScript("OnEvent", function()
    CQ_Log_Init();
    this:UnregisterEvent("PLAYER_LOGIN");
end);

-- ============================================================================
-- POTION EVENT DIAGNOSTIC  /potdiag
-- Listens on every buff-related chat event and prints any message that contains
-- a keyword, so you can see the exact raw string and which event it fires on.
-- Usage:
--   /potdiag on          start listening
--   /potdiag off         stop listening
--   /potdiag test        run pattern-match test against known messages
-- ============================================================================
CQ_PotDiag = { enabled = false };

local potDiagFrame = CreateFrame("Frame");

local POT_DIAG_EVENTS = {
    "CHAT_MSG_SPELL_SELF_BUFF",
    "CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS",
    "CHAT_MSG_SPELL_PARTY_BUFF",
    "CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS",
    "CHAT_MSG_SPELL_FRIENDLYPLAYER_BUFF",
    "CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS",
    "CHAT_MSG_SPELL_SELF_DAMAGE",
    "CHAT_MSG_SPELL_PARTY_DAMAGE",
    "CHAT_MSG_SPELL_FRIENDLYPLAYER_DAMAGE",
    "CHAT_MSG_SPELL_DAMAGESHIELDS_ON_SELF",
    "CHAT_MSG_SPELL_DAMAGESHIELDS_ON_OTHERS",
    "CHAT_MSG_SYSTEM",
};

local POT_DIAG_KEYWORDS = {
    "Tea", "tea", "Mana", "Invulnerability", "invulnerability",
    "Invulnerable", "Restoration", "restoration", "potion", "Potion",
};

local function potDiagMatches(msg)
    for _, kw in ipairs(POT_DIAG_KEYWORDS) do
        if string.find(msg, kw, 1, true) then return true; end
    end
    return false;
end

local function potDiagCheckPatterns(msg)
    local results = {};
    if string.find(msg, "from.*Tea") then
        table.insert(results, "|cff00ff00MATCH nordanaarTea|r");
    end
    if string.find(msg, "Restore Mana") then
        table.insert(results, "|cff00ff00MATCH majorMana|r");
    end
    if string.find(msg, "Invulnerability") then
        table.insert(results, "|cffff6600MATCH limitinvulpotion|r");
    end
    if table.getn(results) == 0 then
        table.insert(results, "|cffaaaaааno pattern match|r");
    end
    return table.concat(results, ", ");
end

potDiagFrame:SetScript("OnEvent", function()
    if not CQ_PotDiag.enabled then return; end
    local msg = tostring(arg1 or "");
    if not potDiagMatches(msg) then return; end
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff[POTDIAG][" .. tostring(event) .. "]|r");
    DEFAULT_CHAT_FRAME:AddMessage("|cffffffff  " .. msg .. "|r");
    DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa  " .. potDiagCheckPatterns(msg) .. "|r");
end);

SLASH_CONQPOTDIAG1 = "/conqpotdiag";
SlashCmdList["CONQPOTDIAG"] = function(msg)
    msg = string.gsub(msg or "", "^%s*(.-)%s*$", "%1");
    if msg == "on" or msg == "enable" then
        CQ_PotDiag.enabled = true;
        for _, ev in ipairs(POT_DIAG_EVENTS) do potDiagFrame:RegisterEvent(ev); end
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[PotDiag] ENABLED - use a Tea or LIP now|r");
    elseif msg == "off" or msg == "disable" then
        CQ_PotDiag.enabled = false;
        for _, ev in ipairs(POT_DIAG_EVENTS) do potDiagFrame:UnregisterEvent(ev); end
        DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[PotDiag] DISABLED|r");
    elseif msg == "test" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff=== PotDiag pattern test ===|r");
        local tests = {
            { msg = "You gain 983 Mana from Tea.",                    expect = "nordanaarTea" },
            { msg = "Raidmate gains 913 Mana from Raidmate 's Tea.",  expect = "nordanaarTea" },
            { msg = "Your Tea heals you for 611.",                    expect = "no match (heal tick, ignored)" },
            { msg = "You gain Invulnerability.",                      expect = "limitinvulpotion" },
            { msg = "Raidmate gains Invulnerability.",                expect = "limitinvulpotion" },
            { msg = "You gain 1500 Mana from Restore Mana.",         expect = "majorMana" },
        };
        for _, t in ipairs(tests) do
            local result = potDiagCheckPatterns(t.msg);
            DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[expect: " .. t.expect .. "]|r " .. result);
            DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff" .. t.msg .. "|r");
        end
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/potdiag on   - start listening|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/potdiag off  - stop listening|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/potdiag test - run pattern test|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa Then drink a Tea or LIP and watch what fires.|r");
    end
end
