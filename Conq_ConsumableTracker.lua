-- Conq_ConsumableTracker.lua
-- Lightweight consumable detection using cast events (SuperWOW/Nampower)
-- Based on SuperWowCombatLogger's tracking without the combat log file overhead
-- Version 1.5 - pcall guard on GetSpellNameAndRankForId to prevent "Spell not
--               found" hard error for custom-server or high spell IDs that are
--               not present in the client's local spell database.

-- Requires SuperWOW or Nampower for cast event support

CQ_ConsTracker = {
    enabled = false,
    spellCache = {}, -- Cache spell names to avoid repeated SpellInfo calls
    debug = false,
    callbacks = {}, -- Functions to call when consumables are detected

    -- Retry queue: holds events whose GUID could not be resolved at fire time.
    -- Flushed on every RAID_ROSTER_UPDATE / PARTY_MEMBERS_CHANGED.
    -- Entries older than RETRY_EXPIRE seconds are discarded without firing.
    pendingQueue = {},
    RETRY_EXPIRE = 15, -- seconds before a queued event is dropped
};

-- Persistent GUID->name database.
-- Stored as the SavedVariable CQ_GuidDB so it survives reloads and sessions.
-- Format: CQ_GuidDB[guid] = { name = "PlayerName", realm = "RealmName", t = lastSeenTimestamp }
-- GUIDs are permanent per character on vanilla/Turtle WoW servers, so entries
-- never truly go stale. We record a timestamp anyway so entries can be pruned
-- if the DB ever grows very large (/conqcons prunedb).
-- Initialized to {} here; PLAYER_LOGIN merges in the real saved data.
CQ_GuidDB = {};

-- Consumables to track via UNIT_CASTEVENT (spell ID -> display name).
--
-- NOTE: This table is populated automatically at load time by
-- CQ_ConsInt_BuildTrackedTables() in Conq_ConsumableIntegration.lua,
-- which derives it from the castSpells fields in CQ_Buffs (Conq_buffs.lua).
--
-- DO NOT add entries here manually. To track a new consumable, add it to
-- CQ_Buffs in Conq_buffs.lua with a castSpells field.
CQ_ConsTracker_Tracked = {};

-- ---------------------------------------------------------------------------
-- Frames (global to prevent GC)
-- ---------------------------------------------------------------------------

-- Dedicated frame for UNIT_CASTEVENT.
-- This frame handles cast events from SuperWOW (UNIT_CASTEVENT) or Nampower (SPELL_GO_*) whose OnEvent script receives the payload
-- via arg1..arg5 globals. RAB_Core_Register routes through a shared frame that
-- calls handlers with no arguments, so we register directly here instead.
CQ_CastEventFrame = CreateFrame("Frame");

-- Separate frame that listens for roster changes to flush the retry queue
-- and keep the GUID DB fresh.
CQ_ConsumableRosterFrame = CreateFrame("Frame");

-- ---------------------------------------------------------------------------
-- GUID database
-- ---------------------------------------------------------------------------

-- Record a GUID->name mapping into the persistent DB.
-- Called whenever we successfully resolve any GUID.
function CQ_GuidDB_Record(guid, name)
    if not guid or not name or name == "" or name == UNKNOWN then return; end
    local realm = GetCVar("realmName") or "";
    CQ_GuidDB[guid] = { name = name, realm = realm, t = time() };
end

-- Look up a GUID in the persistent DB.
-- Returns the stored name, or nil if not found.
function CQ_GuidDB_Lookup(guid)
    if not guid then return nil; end
    local entry = CQ_GuidDB[guid];
    if entry then return entry.name; end
    return nil;
end

-- Seed the DB from the current raid/party roster.
-- Called on login and on every roster update so the DB fills up quickly
-- from normal play, even without any consumable events firing.
function CQ_GuidDB_SeedFromRoster()
    if not UnitExists then return; end

    -- Always record the local player.
    local _, playerGUID = UnitExists("player");
    if playerGUID then
        CQ_GuidDB_Record(playerGUID, UnitName("player"));
    end

    local numRaid = GetNumRaidMembers();
    if numRaid > 0 then
        for i = 1, numRaid do
            local unit = "raid" .. i;
            local _, guid = UnitExists(unit);
            local name = UnitName(unit);
            if guid and name then
                CQ_GuidDB_Record(guid, name);
            end
        end
        return;
    end

    local numParty = GetNumPartyMembers();
    for i = 1, numParty do
        local unit = "party" .. i;
        local _, guid = UnitExists(unit);
        local name = UnitName(unit);
        if guid and name then
            CQ_GuidDB_Record(guid, name);
        end
    end
end

-- Remove entries older than maxAgeDays days.
-- Vanilla GUID DBs rarely exceed a few hundred entries even after months of
-- raiding, so this is mostly a courtesy cleanup feature.
function CQ_GuidDB_Prune(maxAgeDays)
    maxAgeDays = maxAgeDays or 90;
    local cutoff = time() - (maxAgeDays * 86400);
    local removed = 0;
    for guid, entry in pairs(CQ_GuidDB) do
        if entry.t < cutoff then
            CQ_GuidDB[guid] = nil;
            removed = removed + 1;
        end
    end
    return removed;
end

-- Count DB entries.
function CQ_GuidDB_Count()
    local n = 0;
    for _ in pairs(CQ_GuidDB) do n = n + 1; end
    return n;
end

-- ---------------------------------------------------------------------------
-- Init
-- ---------------------------------------------------------------------------

function CQ_ConsTracker_Init()
    if not GetNampowerVersion then
        if CQ_ConsTracker.debug then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[RAB Consumables] Nampower not detected - tracker disabled|r");
        end
        return;
    end

    CQ_ConsTracker.enabled = true;

    -- Nampower: SPELL_GO fires on server confirmation of a cast.
    -- AURA_CAST covers weapon enchant application events.
    SetCVar("NP_EnableSpellGoEvents", "1");
    CQ_CastEventFrame:RegisterEvent("SPELL_GO_SELF");
    CQ_CastEventFrame:RegisterEvent("SPELL_GO_OTHER");
    SetCVar("NP_EnableAuraCastEvents", "1");
    CQ_CastEventFrame:RegisterEvent("AURA_CAST_ON_SELF");
    CQ_CastEventFrame:RegisterEvent("AURA_CAST_ON_OTHER");
    CQ_CastEventFrame:SetScript("OnEvent", function()
        CQ_ConsTracker_OnCastEvent();
    end);

    -- Roster frame: seed GUID DB + flush retry queue on every roster change.
    CQ_ConsumableRosterFrame:RegisterEvent("RAID_ROSTER_UPDATE");
    CQ_ConsumableRosterFrame:RegisterEvent("PARTY_MEMBERS_CHANGED");
    CQ_ConsumableRosterFrame:SetScript("OnEvent", function()
        CQ_GuidDB_SeedFromRoster();
        CQ_ConsTracker_FlushQueue();
    end);

    -- Seed immediately with whoever is already in the group at login.
    CQ_GuidDB_SeedFromRoster();

    if CQ_ConsTracker.debug then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RAB Consumables] Tracker initialized - monitoring " ..
            CQ_ConsTracker_CountTracked() .. " consumables, " ..
            CQ_GuidDB_Count() .. " GUIDs in DB|r");
    end
end

-- Count how many consumables we're tracking.
function CQ_ConsTracker_CountTracked()
    local count = 0;
    for _ in pairs(CQ_ConsTracker_Tracked) do count = count + 1; end
    return count;
end

-- ---------------------------------------------------------------------------
-- GUID resolution  (live methods first, persistent DB as final fallback)
-- ---------------------------------------------------------------------------

-- Resolution order:
--   1. SuperWOW UnitName(guid) direct call  — works when unit is loaded client-side
--   2. Raid roster UnitExists scan          — works when unit is in group and loaded
--   3. Party roster UnitExists scan
--   4. Local player check
--   5. Persistent CQ_GuidDB               — works even for offline / DC'd players
--                                             because GUIDs are permanent per character
-- Returns name string, or nil if all methods fail.
function CQ_ConsTracker_ResolveGUID(guid)
    if not guid then return nil; end

    -- 1. Direct UnitName lookup.
    local name = UnitName(guid);
    if name and name ~= "" and name ~= UNKNOWN then
        CQ_GuidDB_Record(guid, name); -- keep DB current
        return name;
    end

    -- 2. Raid roster scan.
    for i = 1, GetNumRaidMembers() do
        local unit = "raid" .. i;
        local _, uguid = UnitExists(unit);
        if uguid and uguid == guid then
            name = UnitName(unit);
            if name and name ~= "" then
                CQ_GuidDB_Record(guid, name);
                return name;
            end
        end
    end

    -- 3. Party roster scan.
    for i = 1, GetNumPartyMembers() do
        local unit = "party" .. i;
        local _, uguid = UnitExists(unit);
        if uguid and uguid == guid then
            name = UnitName(unit);
            if name and name ~= "" then
                CQ_GuidDB_Record(guid, name);
                return name;
            end
        end
    end

    -- 4. Local player.
    local _, playerGUID = UnitExists("player");
    if playerGUID and playerGUID == guid then
        name = UnitName("player");
        CQ_GuidDB_Record(guid, name);
        return name;
    end

    -- 5. Persistent DB — the key addition. Handles DC'd / offline / OOR players
    --    as long as we have seen them in any previous session.
    name = CQ_GuidDB_Lookup(guid);
    if name then
        if CQ_ConsTracker.debug then
            DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[RAB Consumables] Resolved via GuidDB: " ..
                guid .. " -> " .. name .. "|r");
        end
        return name;
    end

    return nil;
end

-- ---------------------------------------------------------------------------
-- Main UNIT_CASTEVENT handler
-- ---------------------------------------------------------------------------

-- Event types handled:
-- SuperWOW UNIT_CASTEVENT:
--   "CAST"     - instant/channel complete (potions, poisons, sappers)
--   "MAINHAND" - weapon enchant applied to main hand
--   "OFFHAND"  - weapon enchant applied to off hand
-- Nampower SPELL_GO_SELF / SPELL_GO_OTHER: spell confirmed cast by server
-- Nampower AURA_CAST_ON_SELF / AURA_CAST_ON_OTHER: aura landed (weapon enchants)
function CQ_ConsTracker_OnCastEvent()
    local casterGUID, spellID;

    if event == "SPELL_GO_SELF" or event == "SPELL_GO_OTHER" then
        -- Nampower: arg1=itemId, arg2=spellID, arg3=casterGUID
        casterGUID = arg3;
        spellID    = arg2;
    elseif event == "AURA_CAST_ON_SELF" or event == "AURA_CAST_ON_OTHER" then
        -- Nampower: arg1=spellID, arg2=casterGUID, arg3=targetGUID
        casterGUID = arg2;
        spellID    = arg1;
    else
        return;
    end

    local consumableName = CQ_ConsTracker_Tracked[spellID];
    if not consumableName then return; end

    local casterName = CQ_ConsTracker_ResolveGUID(casterGUID);

    if not casterName or casterName == "" then
        CQ_ConsTracker_Enqueue(casterGUID, spellID, consumableName, "CAST");
        return;
    end

    CQ_ConsTracker_Dispatch(casterName, spellID, consumableName, "CAST");
end

-- ---------------------------------------------------------------------------
-- Retry queue
-- ---------------------------------------------------------------------------

function CQ_ConsTracker_Enqueue(casterGUID, spellID, consumableName, eventType)
    local entry = {
        guid      = casterGUID,
        spellID   = spellID,
        name      = consumableName,
        eventType = eventType,
        timestamp = GetTime(),
        expires   = GetTime() + CQ_ConsTracker.RETRY_EXPIRE,
    };
    table.insert(CQ_ConsTracker.pendingQueue, entry);

    if CQ_ConsTracker.debug then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[RAB Consumables] GUID unresolved, queued: " ..
            tostring(casterGUID) .. " spellID=" .. tostring(spellID) ..
            " (queue=" .. table.getn(CQ_ConsTracker.pendingQueue) .. ")|r");
    end
end

-- Called on every RAID_ROSTER_UPDATE / PARTY_MEMBERS_CHANGED.
function CQ_ConsTracker_FlushQueue()
    if table.getn(CQ_ConsTracker.pendingQueue) == 0 then return; end

    local now = GetTime();
    local remaining = {};

    for _, entry in ipairs(CQ_ConsTracker.pendingQueue) do
        if now > entry.expires then
            if CQ_ConsTracker.debug then
                DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[RAB Consumables] Queued event expired, dropping: " ..
                    tostring(entry.guid) .. " spellID=" .. tostring(entry.spellID) .. "|r");
            end
        else
            local name = CQ_ConsTracker_ResolveGUID(entry.guid);
            if name and name ~= "" then
                if CQ_ConsTracker.debug then
                    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RAB Consumables] Queued event resolved: " ..
                        name .. " spellID=" .. tostring(entry.spellID) .. "|r");
                end
                -- Use original cast timestamp so log timing stays accurate.
                CQ_ConsTracker_Dispatch(name, entry.spellID, entry.name, entry.eventType, entry.timestamp);
            else
                table.insert(remaining, entry);
            end
        end
    end

    CQ_ConsTracker.pendingQueue = remaining;
end

-- ---------------------------------------------------------------------------
-- Dispatch (shared final path for immediate and retried events)
-- ---------------------------------------------------------------------------

function CQ_ConsTracker_Dispatch(casterName, spellID, consumableName, eventType, timestamp)
    timestamp = timestamp or GetTime();
    local spellName = CQ_ConsTracker_GetSpellInfo(spellID);

    if CQ_ConsTracker.debug then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[" .. eventType .. "] " .. casterName ..
            " applied " .. (spellName or consumableName) .. " (" .. spellID .. ")|r");
    end

    CQ_ConsTracker_FireCallbacks(casterName, spellID, consumableName, spellName, timestamp, eventType);
end

-- ---------------------------------------------------------------------------
-- Spell info cache
-- ---------------------------------------------------------------------------

function CQ_ConsTracker_GetSpellInfo(spellID)
    local cached = CQ_ConsTracker.spellCache[spellID];
    -- cached == nil  : not yet looked up
    -- cached == false: looked up, spell not in client DB (known miss)
    -- cached == table: successful lookup
    if cached == false then return nil, nil; end
    if cached then return cached[1], cached[2]; end

    local spell, rank;
    if GetSpellNameAndRankForId then
        -- GetSpellNameAndRankForId raises a hard Lua error ("Spell not found")
        -- for any spell ID that is absent from the client's local spell database.
        -- This happens with custom-server spells and high IDs not in the 1.12
        -- client data (e.g. 45427, 45489, 36931, 57045...).
        -- pcall absorbs the error so one unknown spell ID can't crash the addon.
        local ok, a, b = pcall(GetSpellNameAndRankForId, spellID);
        if ok then
            spell = a;
            rank  = b;
        else
            -- Cache the miss as false so we don't retry a known-bad ID every event.
            CQ_ConsTracker.spellCache[spellID] = false;
            return nil, nil;
        end
    end
    if spell then
        rank = string.find(rank or "", "^Rank") and rank or "";
        CQ_ConsTracker.spellCache[spellID] = { spell, rank };
        return spell, rank;
    end
    -- Cache the miss so future calls skip the pcall entirely.
    CQ_ConsTracker.spellCache[spellID] = false;
    return nil, nil;
end

-- ---------------------------------------------------------------------------
-- Callback registry
-- ---------------------------------------------------------------------------

-- Callback receives: (playerName, spellID, consumableName, spellName, timestamp, event)
-- event is "CAST", "MAINHAND", or "OFFHAND"
function CQ_ConsTracker_RegisterCallback(name, func)
    CQ_ConsTracker.callbacks[name] = func;
end

function CQ_ConsTracker_UnregisterCallback(name)
    CQ_ConsTracker.callbacks[name] = nil;
end

function CQ_ConsTracker_FireCallbacks(playerName, spellID, consumableName, spellName, timestamp, event)
    for name, callback in pairs(CQ_ConsTracker.callbacks) do
        local ok, err = pcall(callback, playerName, spellID, consumableName, spellName, timestamp, event);
        if not ok and CQ_ConsTracker.debug then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[RAB Consumables] Callback '" .. name .. "' error: " .. tostring(err) .. "|r");
        end
    end
end

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------

SLASH_CONQCONS1 = "/conqcons";
SlashCmdList["CONQCONS"] = function(msg)
    msg = strlower(msg or "");

    if msg == "debug" then
        CQ_ConsTracker.debug = not CQ_ConsTracker.debug;
        if CQ_ConsTracker.debug then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RAB Consumables] Debug mode ENABLED|r");
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[RAB Consumables] Debug mode DISABLED|r");
        end

    elseif msg == "status" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00=== RAB CONSUMABLE TRACKER STATUS ===|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Enabled: "       .. tostring(CQ_ConsTracker.enabled) .. "|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Nampower: "      .. tostring(GetNampowerVersion ~= nil) .. "|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Tracking: "      .. CQ_ConsTracker_CountTracked() .. " consumables|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Pending queue: " .. table.getn(CQ_ConsTracker.pendingQueue) .. " events|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Retry window: "  .. CQ_ConsTracker.RETRY_EXPIRE .. "s|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00GUID DB size: "  .. CQ_GuidDB_Count() .. " entries|r");
        local callbackCount = 0;
        for _ in pairs(CQ_ConsTracker.callbacks) do callbackCount = callbackCount + 1; end
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Callbacks: "     .. callbackCount .. "|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Cached spells: " .. CQ_ConsTracker_CountCached() .. "|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Debug: "         .. tostring(CQ_ConsTracker.debug) .. "|r");

    elseif msg == "queue" then
        local n = table.getn(CQ_ConsTracker.pendingQueue);
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00=== PENDING RETRY QUEUE (" .. n .. ") ===|r");
        if n == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa Queue is empty.|r");
        else
            local now = GetTime();
            for i, entry in ipairs(CQ_ConsTracker.pendingQueue) do
                local ttl = string.format("%.0f", entry.expires - now);
                DEFAULT_CHAT_FRAME:AddMessage("|cffffffff[" .. i .. "]|r " ..
                    entry.name .. " guid=" .. tostring(entry.guid) .. " ttl=" .. ttl .. "s");
            end
        end

    elseif msg == "flushqueue" then
        local before = table.getn(CQ_ConsTracker.pendingQueue);
        CQ_ConsTracker_FlushQueue();
        local after = table.getn(CQ_ConsTracker.pendingQueue);
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RAB Consumables] Flushed: " ..
            before .. " -> " .. after .. " pending|r");

    elseif msg == "db" or msg == "guiddb" then
        local n = CQ_GuidDB_Count();
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00=== GUID DATABASE (" .. n .. " entries) ===|r");
        if n == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa DB is empty. Play with others to populate it.|r");
        else
            local sorted = {};
            for guid, entry in pairs(CQ_GuidDB) do
                table.insert(sorted, { guid = guid, name = entry.name, t = entry.t });
            end
            table.sort(sorted, function(a, b) return a.t > b.t; end);
            local shown = math.min(20, table.getn(sorted));
            for i = 1, shown do
                local e = sorted[i];
                local age = string.format("%.0fd ago", (time() - e.t) / 86400);
                DEFAULT_CHAT_FRAME:AddMessage("|cffffffff" .. e.name .. "|r  " .. age .. "  " .. e.guid);
            end
            if n > 20 then
                DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa... and " .. (n - 20) .. " more|r");
            end
        end

    elseif strsub(msg, 1, 7) == "prunedb" then
        local days = tonumber(string.match(msg, "prunedb%s+(%d+)")) or 90;
        local removed = CQ_GuidDB_Prune(days);
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RAB Consumables] Pruned " .. removed ..
            " entries older than " .. days .. " days. DB now has " .. CQ_GuidDB_Count() .. " entries.|r");

    elseif msg == "seeddb" then
        CQ_GuidDB_SeedFromRoster();
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RAB Consumables] Seeded from roster. " ..
            CQ_GuidDB_Count() .. " total entries.|r");

    elseif msg == "list" or msg == "tracked" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00=== TRACKED CONSUMABLES ===|r");
        local sorted = {};
        for spellID, name in pairs(CQ_ConsTracker_Tracked) do
            table.insert(sorted, { id = spellID, name = name });
        end
        table.sort(sorted, function(a, b) return a.name < b.name; end);
        local shown = 0;
        for _, item in ipairs(sorted) do
            DEFAULT_CHAT_FRAME:AddMessage("|cffffffff" .. item.name .. "|r (ID: " .. item.id .. ")");
            shown = shown + 1;
            if shown >= 20 then
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00... and " .. (CQ_ConsTracker_CountTracked() - 20) .. " more|r");
                break;
            end
        end

    elseif msg == "clear" or msg == "clearcache" then
        CQ_ConsTracker.spellCache = {};
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RAB Consumables] Spell cache cleared|r");

    elseif msg == "callbacks" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00=== REGISTERED CALLBACKS ===|r");
        local count = 0;
        for name, _ in pairs(CQ_ConsTracker.callbacks) do
            DEFAULT_CHAT_FRAME:AddMessage("|cffffffff- " .. name .. "|r");
            count = count + 1;
        end
        if count == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900No callbacks registered|r");
        end

    else
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00=== RAB Consumable Tracker ===|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqcons status          - Show tracker status|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqcons debug           - Toggle debug output|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqcons list            - List tracked consumables|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqcons callbacks       - Show registered callbacks|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqcons queue           - Show pending retry queue|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqcons flushqueue      - Manually flush retry queue|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqcons db              - Show GUID database (recent 20)|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqcons seeddb          - Seed DB from current roster|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqcons prunedb [days]  - Remove entries older than N days (default 90)|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqcons clear           - Clear spell cache|r");
    end
end

function CQ_ConsTracker_CountCached()
    local n = 0;
    for _, v in pairs(CQ_ConsTracker.spellCache) do
        -- Only count real hits (tables), not known-miss sentinels (false).
        if v ~= false then n = n + 1; end
    end
    return n;
end

-- ---------------------------------------------------------------------------
-- Initialise on login
-- ---------------------------------------------------------------------------

local initFrame = CreateFrame("Frame");
initFrame:RegisterEvent("PLAYER_LOGIN");
initFrame:SetScript("OnEvent", function()
    -- CQ_GuidDB is already populated by the WoW SavedVariables system at this
    -- point. Guard against first-ever-run where the variable doesn't exist yet.
    if type(CQ_GuidDB) ~= "table" then
        CQ_GuidDB = {};
    end
    CQ_ConsTracker_Init();
    this:UnregisterEvent("PLAYER_LOGIN");
end);
