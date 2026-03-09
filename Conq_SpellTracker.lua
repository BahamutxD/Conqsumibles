-- Conq_SpellTracker.lua
-- Track specific spell casts during raids using UNIT_CASTEVENT
-- Version 1.2 - Removed duplicate Sunder Armor SPELL_GO handling.
--               Sunder tracking for all players (self and others) is now
--               owned exclusively by CQ_SpellGoFrame (Conq_raidlog.lua).
--               Registering SPELL_GO_SELF/OTHER here caused every Sunder cast
--               by any raid member to be falsely attributed to the local player
--               (UnitName("player")) via CQ_Log_RecordSunderSelf, which ignores
--               the caster GUID entirely. This module is kept for future
--               non-Sunder spell tracking via UNIT_CASTEVENT.

CQ_SpellTracker = {
    enabled = false,
    debug = false,
    guidMap = {}, -- GUID -> playerName, rebuilt on roster changes
};

-- Spells to track (spell ID -> spell name)
-- NOTE: Sunder Armor is intentionally NOT handled here. It is tracked for all
-- players (self and others) by CQ_SpellGoFrame in Conq_raidlog.lua via the
-- CQ_Log_SunderSpellIDs table. Adding it here would cause double-counting.
-- Add future non-Sunder spells here when needed.
CQ_SpellTracker_TrackedSpells = {
    -- Add spells here as needed.
    -- Example:
    -- [12345] = "Some Other Spell",
};

local spellTrackerFrame = CreateFrame("Frame");

-- ============================================================================
-- GUID MAP
-- ============================================================================

-- Rebuild the GUID->name lookup from the current raid/party roster.
-- Called on RAID_ROSTER_UPDATE, PARTY_MEMBERS_CHANGED, and PLAYER_LOGIN.
-- SuperWOW provides UnitGUID(); without it the map stays empty and we fall
-- back to "player only" behaviour.
function CQ_SpellTracker_RebuildGuidMap()
    CQ_SpellTracker.guidMap = {};

    local playerGuid = GetUnitGUID("player");
    if playerGuid then CQ_SpellTracker.guidMap[playerGuid] = UnitName("player"); end

    local numRaid = GetNumRaidMembers();
    if numRaid > 0 then
        for i = 1, numRaid do
            local unit = "raid" .. i;
            local guid = GetUnitGUID(unit);
            local name = UnitName(unit);
            if name and guid then CQ_SpellTracker.guidMap[guid] = name; end
        end
        return;
    end

    local numParty = GetNumPartyMembers();
    for i = 1, numParty do
        local unit = "party" .. i;
        local guid = GetUnitGUID(unit);
        local name = UnitName(unit);
        if name and guid then CQ_SpellTracker.guidMap[guid] = name; end
    end
end

-- Resolve a GUID to a player name.
-- Returns name string, or nil if unknown.
function CQ_SpellTracker_GuidToName(guid)
    if not guid then return nil; end
    return CQ_SpellTracker.guidMap[guid];
end

-- ============================================================================
-- INIT / EVENT HANDLER
-- ============================================================================

function CQ_SpellTracker_Init()
    if not GetNampowerVersion then
        if CQ_SpellTracker.debug then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[Spell Tracker] Nampower not detected - tracker disabled|r");
        end
        return;
    end

    CQ_SpellTracker.enabled = true;

    -- DO NOT register SPELL_GO_SELF or SPELL_GO_OTHER here.
    -- Sunder Armor (and all other SPELL_GO-based tracking) is handled
    -- exclusively by CQ_SpellGoFrame in Conq_raidlog.lua.
    -- Registering these events here caused every Sunder cast by any raid
    -- member to be falsely credited to the local player (UnitName("player"))
    -- because CQ_Log_RecordSunderSelf ignores the caster GUID.
    --
    -- If future spells need tracking here via UNIT_CASTEVENT, register that
    -- event below instead, and resolve the caster using arg1/arg2/arg3
    -- (unit, spellID, GUID) rather than calling UnitName("player") blindly.

    -- Keep the GUID map fresh for any future UNIT_CASTEVENT-based tracking.
    spellTrackerFrame:RegisterEvent("RAID_ROSTER_UPDATE");
    spellTrackerFrame:RegisterEvent("PARTY_MEMBERS_CHANGED");

    spellTrackerFrame:SetScript("OnEvent", function()
        -- RAID_ROSTER_UPDATE or PARTY_MEMBERS_CHANGED
        CQ_SpellTracker_RebuildGuidMap();
    end);

    -- Seed the map immediately.
    CQ_SpellTracker_RebuildGuidMap();

    if CQ_SpellTracker.debug then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Spell Tracker] Initialized (Sunder owned by raidlog)|r");
    end
end

function CQ_SpellTracker_CountTracked()
    local count = 0;
    for _ in pairs(CQ_SpellTracker_TrackedSpells) do
        count = count + 1;
    end
    return count;
end

-- CQ_SpellTracker_OnCastEvent is kept as a stub for future non-Sunder use.
-- It is NOT wired to any frame event. If you add spells to
-- CQ_SpellTracker_TrackedSpells and register UNIT_CASTEVENT above, update
-- this function to use arg3 (casterGUID) for name resolution rather than
-- UnitName("player").
function CQ_SpellTracker_OnCastEvent()
    -- stub - not currently called
end

-- ============================================================================
-- SLASH COMMANDS
-- ============================================================================

SLASH_CONQSPELLS1 = "/conqspells";
SlashCmdList["CONQSPELLS"] = function(msg)
    msg = strlower(msg or "");

    if msg == "debug" then
        CQ_SpellTracker.debug = not CQ_SpellTracker.debug;
        if CQ_SpellTracker.debug then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Spell Tracker] Debug mode ENABLED|r");
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[Spell Tracker] Debug mode DISABLED|r");
        end

    elseif msg == "status" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00=== SPELL TRACKER STATUS ===|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Enabled: " .. tostring(CQ_SpellTracker.enabled) .. "|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Nampower: " .. tostring(GetNampowerVersion ~= nil) .. "|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GetUnitGUID: " .. tostring(GetUnitGUID ~= nil) .. "|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Tracked spells (non-Sunder): " .. CQ_SpellTracker_CountTracked() .. "|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Sunder tracking: owned by CQ_SpellGoFrame (Conq_raidlog.lua)|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Debug: " .. tostring(CQ_SpellTracker.debug) .. "|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Raid logging: " ..
            tostring(CQ_Log and CQ_Log.isLogging or false) .. "|r");

        -- Show GUID map size
        local guidCount = 0;
        for _ in pairs(CQ_SpellTracker.guidMap) do guidCount = guidCount + 1; end
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GUIDs mapped: " .. guidCount .. "|r");

    elseif msg == "guids" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00=== GUID MAP ===|r");
        local count = 0;
        for guid, name in pairs(CQ_SpellTracker.guidMap) do
            DEFAULT_CHAT_FRAME:AddMessage("|cffffffff" .. name .. "|r -> " .. guid);
            count = count + 1;
        end
        if count == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900No GUIDs mapped yet. Join a raid or party.|r");
        end

    elseif msg == "rebuild" then
        CQ_SpellTracker_RebuildGuidMap();
        local count = 0;
        for _ in pairs(CQ_SpellTracker.guidMap) do count = count + 1; end
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Spell Tracker] GUID map rebuilt - " .. count .. " entries|r");

    elseif msg == "list" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00=== TRACKED SPELLS (non-Sunder) ===|r");
        local sorted = {};
        for spellID, name in pairs(CQ_SpellTracker_TrackedSpells) do
            table.insert(sorted, { id = spellID, name = name });
        end
        table.sort(sorted, function(a, b) return a.name < b.name; end);

        if table.getn(sorted) == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900No additional spells configured.|r");
            DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa(Sunder Armor is tracked by Conq_raidlog.lua)|r");
        else
            local shown = 0;
            for _, spell in ipairs(sorted) do
                DEFAULT_CHAT_FRAME:AddMessage("|cffffffff" .. spell.name .. "|r (ID: " .. spell.id .. ")");
                shown = shown + 1;
                if shown >= 30 then
                    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00... and " ..
                        (CQ_SpellTracker_CountTracked() - 30) .. " more|r");
                    break;
                end
            end
        end

    elseif msg == "stats" or msg == "show" then
        if not CQ_Log or not CQ_Log.isLogging or not CQ_Log.currentRaidId then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900No active raid logging|r");
            return;
        end

        local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
        if not raid or not raid.spells then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900No spell data recorded yet|r");
            return;
        end

        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00=== SPELL CAST STATS (Current Raid) ===|r");
        local anyData = false;
        for playerName, spells in pairs(raid.spells) do
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00" .. playerName .. ":|r");
            for spellKey, data in pairs(spells) do
                DEFAULT_CHAT_FRAME:AddMessage("  " .. data.spellName ..
                    ": |cffffffff" .. data.count .. " casts|r");
            end
            anyData = true;
        end
        if not anyData then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900No spell casts recorded yet.|r");
        end

    else
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00=== RAB Spell Tracker ===|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa  Sunder Armor is tracked by Conq_raidlog.lua (CQ_SpellGoFrame).|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqspells status  - Show tracker status|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqspells debug   - Toggle debug output|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqspells list    - List tracked spells|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqspells stats   - Show spell casts for current raid|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqspells guids   - Show current GUID->name map|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqspells rebuild - Force rebuild GUID map|r");
    end
end

-- ============================================================================
-- INITIALIZE
-- ============================================================================

local initFrame = CreateFrame("Frame");
initFrame:RegisterEvent("PLAYER_LOGIN");
initFrame:SetScript("OnEvent", function()
    CQ_SpellTracker_Init();
    this:UnregisterEvent("PLAYER_LOGIN");
end);
