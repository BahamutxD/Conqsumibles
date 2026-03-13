-- Conq_ConsumableIntegration.lua
-- Connects CQ_ConsTracker to RABuffs raid logging.
-- FIXED VERSION: Corrects castTrackedConsumables key format and prevents ghost consumables
--
-- WEAPON ENCHANTS NOW WORK: Testing showed that weapon oils and sharpening stones
-- DO fire cast event with "START" and "CAST" events (not MAINHAND/OFFHAND as
-- originally thought). The spell IDs are mapped below in CQ_ConsTracker_KeyMap.
--
-- This integration handles both the cast event detection and provides a
-- supplementary weapon enchant poller as a fallback for the local player.

-- Map spell IDs to RABuffs consumable keys.
-- These are the ITEM USE spell IDs from cast event MAINHAND/OFFHAND events.
-- Verified against SuperWowCombatLogger (core.lua).
-- Both MH and OH versions of the same item share the same spell ID and map to
-- the base buffKey - the slot is determined by the MAINHAND/OFFHAND event type.
CQ_ConsTracker_KeyMap = {
    -- Goblin Sapper Charge
    [13241] = "goblinsapper",

    -- Stratholme Holy Water (same detection path as Goblin Sapper)
    [17291] = "stratholmeholywater",

    -- Mana Oils
    [25123] = "brillmanaoil",           -- Brilliant Mana Oil
    [20747] = "lessermanaoil",          -- Lesser Mana Oil (old ID 25121 was wrong)

    -- Wizard Oils
    [25122] = "brilliantwizardoil",     -- Brilliant Wizard Oil
    [28898] = "blessedwizardoil",       -- Blessed Wizard Oil (old ID 68567 was wrong)
    [25121] = "wizardoil",              -- Wizard Oil (old ID 25080 was wrong)

    -- Sharpening Stones
    [16138] = "densesharpeningstone",       -- Dense Sharpening Stone
    [22756] = "elementalsharpeningstone",   -- Elemental Sharpening Stone (old ID 16139 was wrong)
    [28891] = "consecratedstone",           -- Consecrated Sharpening Stone (old ID 24674 was wrong)

    -- Weightstones
    [16622] = "denseweightstone",           -- Dense Weightstone (old ID 16141 was wrong)

    -- Misc Weapon Oils
    [3829]  = "frostoil",               -- Frost Oil
    [3594]  = "shadowoil",              -- Shadow Oil

    -- Rogue Poisons
    -- All ranks map to the base buffKey — only the application matters,
    -- there is no buff bar to poll for other players.
    [11357] = "deadlypoison",           -- Deadly Poison V
    [11356] = "deadlypoison",           -- Deadly Poison IV
    [11355] = "deadlypoison",           -- Deadly Poison III
    [2824]  = "deadlypoison",           -- Deadly Poison II
    [2823]  = "deadlypoison",           -- Deadly Poison

    [8679]  = "instantpoison",          -- Instant Poison VI
    [8688]  = "instantpoison",          -- Instant Poison V
    [8687]  = "instantpoison",          -- Instant Poison IV
    [8686]  = "instantpoison",          -- Instant Poison III
    [8685]  = "instantpoison",          -- Instant Poison II
    [8680]  = "instantpoison",          -- Instant Poison

    [13219] = "woundpoison",            -- Wound Poison V
    [13218] = "woundpoison",            -- Wound Poison IV
    [13223] = "woundpoison",            -- Wound Poison III
    [13222] = "woundpoison",            -- Wound Poison II
    [13220] = "woundpoison",            -- Wound Poison

    [5763]  = "mindnumbingpoison",      -- Mind-numbing Poison III
    [8694]  = "mindnumbingpoison",      -- Mind-numbing Poison II
    [5761]  = "mindnumbingpoison",      -- Mind-numbing Poison

    [3408]  = "cripplingpoison",        -- Crippling Poison II
    [3409]  = "cripplingpoison",        -- Crippling Poison

    -- Custom server poisons
    [47409] = "corrosivepoison",        -- Corrosive Poison
    [54010] = "dissolventpoison",       -- Dissolvent Poison

    -- DCL-confirmed server-specific poison application spell IDs
    [25351] = "deadlypoison",           -- Deadly Poison       (DCL confirmed)
    [11340] = "instantpoison",          -- Instant Poison      (DCL confirmed)
    [11399] = "mindnumbingpoison",      -- Mind-numbing Poison (DCL confirmed)
    [11202] = "cripplingpoison",        -- Crippling Poison    (DCL confirmed)
    [52575] = "corrosivepoison",        -- Corrosive Poison    (DCL confirmed)
    [45881] = "dissolventpoison",       -- Dissolvent Poison   (DCL confirmed)
};

-- Buffs that share textures and need special handling
-- Key: texture name, Value: table of spellID -> buffKey
-- (Currently none of the tracked consumables share textures.)
CQ_ConsTracker_SharedTextures = {
    -- Add entries here if future tracked consumables share an icon.
    -- You can find texture names by hovering over buffs and using /rab info
};

-- Reverse lookup: buffKey -> list of spellIDs that can create it
CQ_ConsTracker_BuffKeyToSpells = {};

-- Queue for cast events that arrive during the isPendingCombat window,
-- before the raid object exists.  Flushed by CQ_Log_InitializeRaid.
-- Each entry: { playerName, spellID, consumableName, spellName, timestamp, buffKey }
CQ_ConsInt_PendingQueue = {};

-- Weapon enchant polling state (LOCAL PLAYER ONLY - supplementary fallback).
--
-- The primary detection method for weapon enchants is now the chat message
-- pattern matching in CQ_Log_WeaponEnchantEvent() (Conq_raidlog.lua),
-- which handles both the local player and other raid members reliably.
--
-- This poller remains as a secondary confirmation for the local player:
-- it watches GetWeaponEnchantInfo() for time increases so that if a player
-- applies an oil directly from bags (bypassing the RABuffs UI) without a chat
-- message being generated, we still notice the slot became active.
-- In practice the chat message is the authoritative source; the poller
-- provides a belt-and-suspenders check for the local player's MH/OH slots.
CQ_WepPoll = {
    lastMhTime  = 0,   -- last known MH enchant time in ms
    lastOhTime  = 0,   -- last known OH enchant time in ms
    -- buffKey the player most recently *attempted* to apply via RAB_UseItem,
    -- per slot.  Cleared once consumed by the poller.
    pendingMhKey = nil,
    pendingOhKey = nil,
    -- Minimum increase in remaining time (ms) to count as a fresh application.
    -- Oils last 30 min = 1,800,000 ms.  We use 60,000 ms (1 min) as the threshold
    -- to avoid counting normal timer drift as a new application.
    threshold   = 60000,
};

-- Build reverse lookup on initialization
function CQ_ConsTracker_BuildReverseLookup()
    -- Clear existing
    CQ_ConsTracker_BuffKeyToSpells = {};
    
    -- Build from direct mapping
    for spellID, buffKey in pairs(CQ_ConsTracker_KeyMap) do
        if not CQ_ConsTracker_BuffKeyToSpells[buffKey] then
            CQ_ConsTracker_BuffKeyToSpells[buffKey] = {};
        end
        table.insert(CQ_ConsTracker_BuffKeyToSpells[buffKey], spellID);
    end
    
    -- Build from shared textures
    for texture, spellMap in pairs(CQ_ConsTracker_SharedTextures) do
        for spellID, buffKey in pairs(spellMap) do
            if not CQ_ConsTracker_BuffKeyToSpells[buffKey] then
                CQ_ConsTracker_BuffKeyToSpells[buffKey] = {};
            end
            -- Check if already added
            local found = false;
            for _, existingID in ipairs(CQ_ConsTracker_BuffKeyToSpells[buffKey]) do
                if existingID == spellID then
                    found = true;
                    break;
                end
            end
            if not found then
                table.insert(CQ_ConsTracker_BuffKeyToSpells[buffKey], spellID);
            end
        end
    end
end

-- Get buff key from spell ID (checks both direct mapping and shared textures)
function CQ_ConsInt_GetBuffKeyFromSpellId(spellID)
    -- First check direct mapping
    if CQ_ConsTracker_KeyMap[spellID] then
        return CQ_ConsTracker_KeyMap[spellID];
    end
    
    -- Check shared textures
    for texture, spellMap in pairs(CQ_ConsTracker_SharedTextures) do
        if spellMap[spellID] then
            return spellMap[spellID];
        end
    end
    
    return nil;
end

-- Check if a buff key can be created by multiple spells (shares texture)
function CQ_ConsInt_HasSharedTexture(buffKey)
    local spells = CQ_ConsTracker_BuffKeyToSpells[buffKey];
    return spells and table.getn(spells) > 1;
end

-- Called by the RAB_UseItem hook when the player clicks a weapon buff button.
-- Records which buffKey they intend to apply so the poller can identify it.
function CQ_WepPoll_RecordIntent(buffKey)
    if not CQ_Buffs[buffKey] then return; end
    local isOH = (CQ_Buffs[buffKey].useOn == "weaponOH");
    if isOH then
        CQ_WepPoll.pendingOhKey = buffKey;
    else
        CQ_WepPoll.pendingMhKey = buffKey;
    end
    if CQ_Log and CQ_Log.debugConsumables then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00[WEP POLL] Recorded intent: " .. buffKey ..
            " slot=" .. (isOH and "OH" or "MH") .. "|r");
    end
end

-- Core polling function - called every 2 seconds by a timer.
-- Detects when GetWeaponEnchantInfo() time increases (= new enchant applied).
function CQ_WepPoll_Check()
    local mh, mhtime, _, oh, ohtime, _ = GetWeaponEnchantInfo();
    local curMh = (mh and mhtime) or 0;
    local curOh = (oh and ohtime) or 0;

    -- Detect MH application: time went up by more than threshold
    if curMh - CQ_WepPoll.lastMhTime > CQ_WepPoll.threshold then
        local buffKey = CQ_WepPoll.pendingMhKey;
        CQ_WepPoll.pendingMhKey = nil;
        CQ_WepPoll_OnApplied("MH", buffKey);
    end
    -- Detect OH application
    if curOh - CQ_WepPoll.lastOhTime > CQ_WepPoll.threshold then
        local buffKey = CQ_WepPoll.pendingOhKey;
        CQ_WepPoll.pendingOhKey = nil;
        CQ_WepPoll_OnApplied("OH", buffKey);
    end

    CQ_WepPoll.lastMhTime = curMh;
    CQ_WepPoll.lastOhTime = curOh;
end

-- Called when GetWeaponEnchantInfo() detects a fresh application on a slot.
-- This is the LOCAL PLAYER ONLY fallback.  Primary detection is chat message based.
function CQ_WepPoll_OnApplied(slot, buffKey)
    -- The poller only knows the slot (MH/OH), not which buffKey was applied.
    -- We rely on the RAB_UseItem hook (via CQ_WepPoll_RecordIntent) to provide buffKey.
    -- If we don't have a buffKey (player didn't click the RAB UI), skip it;
    -- the chat message detection will handle it.
    if not buffKey then
        if CQ_Log and CQ_Log.debugConsumables then
            DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00[WEP POLL] " .. slot .. 
                " enchant applied but no buffKey recorded (user bypassed RAB UI)|r");
        end
        return;
    end
    
    if CQ_Log and CQ_Log.debugConsumables then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[WEP POLL] " .. slot .. " enchant applied: " .. buffKey .. "|r");
    end
    
    -- This will be picked up by the normal buff scanner checks instead
    -- No need to manually increment here since the scanner will see it
end

-- Main callback from CQ_ConsTracker for all cast event detections.
-- Receives: (playerName, spellID, consumableName, spellName, timestamp, event)
-- event is "CAST" for potions/poisons/sappers, "MAINHAND"/"OFFHAND" for weapon enchants.
function CQ_ConsInt_OnConsumable(playerName, spellID, consumableName, spellName, timestamp, event)
    if not playerName or not spellID or not timestamp then
        return;
    end

    -- Weapon enchants arrive as MAINHAND or OFFHAND; treat them the same as CAST
    -- for recording purposes. Everything below uses isWeaponEnchant where slot matters.
    local isWeaponEnchant = (event == "MAINHAND" or event == "OFFHAND");
    local isCast = (event == "CAST");
    if not isWeaponEnchant and not isCast then
        return; -- ignore START, FAIL, etc.
    end

    -- Get the RABuffs key for this consumable
    local buffKey = CQ_ConsInt_GetBuffKeyFromSpellId(spellID);

    if CQ_Log and CQ_Log.debugConsumables then
        DEFAULT_CHAT_FRAME:AddMessage("|cffaaffff[INTEGRATION] SpellID " .. tostring(spellID) ..
            " -> buffKey: " .. tostring(buffKey) .. " for " .. playerName ..
            " (event: " .. event .. ")|r");
    end

    -- If this is during the pending combat window queue it for later
    if CQ_Log and CQ_Log.isPendingCombat and not CQ_Log.isLogging then
        if buffKey then
            table.insert(CQ_ConsInt_PendingQueue, {
                playerName   = playerName,
                spellID      = spellID,
                consumableName = consumableName,
                spellName    = spellName,
                timestamp    = timestamp,
                buffKey      = buffKey,
            });
            if CQ_Log and CQ_Log.debugConsumables then
                DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00[PENDING QUEUE] " .. playerName ..
                    " -> " .. (spellName or consumableName) .. " queued|r");
            end
        end
        return;
    end

    -- Only track during active raid logging
    if not CQ_Log.isLogging or not CQ_Log.currentRaidId then
        return;
    end
    
    local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
    if not raid then return; end
    
    -- Verify player is in raid
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
    
    -- Record in castTrackedConsumables for weapon enchants and consumables with a buffKey.
    -- KEY FORMAT: "PlayerName.buffKey"  — this must match what CQ_Log_CheckWeaponEnchant
    -- reads (castKey = playerName .. "." .. buffKey).
    --
    -- WEAPON ENCHANTS: We only track the MH (mainhand) key. OH tracking was removed
    -- because SPELL_GO has no slot info and always recording both MH+OH caused every
    -- weapon enchant to appear doubled in the export.
    if buffKey then
        if not raid.castTrackedConsumables then
            raid.castTrackedConsumables = {};
        end

        local now = GetTime();
        local isWepEnchant = CQ_Buffs[buffKey] and CQ_Buffs[buffKey].type == "wepbuffonly";

        -- For weapon enchants resolve to the MH key only (strip trailing "oh" if needed).
        -- For everything else just use the key as-is.
        local mhKey = buffKey;
        if isWepEnchant and string.sub(buffKey, -2) == "oh" then
            mhKey = string.sub(buffKey, 1, -3);
        end

        -- Clear stale records for OTHER enchants on this player so a re-enchant
        -- does not leave a ghost entry from a previous oil/stone.
        if isWepEnchant then
            for existingCastKey, _ in pairs(raid.castTrackedConsumables) do
                local existingBK = string.match(existingCastKey, "%.([^%.]+)$");
                if existingBK and CQ_Buffs[existingBK] and
                   CQ_Buffs[existingBK].type == "wepbuffonly" and
                   existingBK ~= mhKey then
                    local expectedKey = playerName .. "." .. existingBK;
                    if existingCastKey == expectedKey then
                        raid.castTrackedConsumables[existingCastKey] = nil;
                        if CQ_Log.debugConsumables then
                            DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00[CAST CLEARED] " .. existingCastKey ..
                                " (replaced by new enchant spellID=" .. spellID .. ")|r");
                        end
                    end
                end
            end
        end

        local castKey = playerName .. "." .. mhKey;
        raid.castTrackedConsumables[castKey] = {
            timestamp      = now,
            spellID        = spellID,
            consumableName = consumableName,
            spellName      = spellName,
            playerName     = playerName,
            buffKey        = mhKey,
        };
        if CQ_Log.debugConsumables then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[CAST TRACKED] " .. castKey ..
                " spellID=" .. spellID .. " [" .. event .. "]|r");
        end
    end
    
    -- Check if this is a tracked spell (not a consumable with buffKey)
    -- Spells like Sunder Armor should be tracked separately in raid.spells
    if not buffKey and event == "CAST" then
        -- This is a spell without a buffKey (like Sunder Armor)
        -- Track it in the spells table instead
        if not raid.spells then
            raid.spells = {};
        end
        
        if not raid.spells[playerName] then
            raid.spells[playerName] = {};
        end
        
        if not raid.spells[playerName][spellID] then
            raid.spells[playerName][spellID] = {
                count = 0,
                spellName = spellName or consumableName,
            };
        end
        
        raid.spells[playerName][spellID].count = raid.spells[playerName][spellID].count + 1;
        
        if CQ_Log.debugConsumables then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff[SPELL] " .. playerName .. " cast " .. 
                (spellName or consumableName) .. " (count: " .. raid.spells[playerName][spellID].count .. ")|r");
        end
        
        return; -- Done tracking this spell
    end
    
    -- For weapon buffs, sapper, and other consumables
    if not buffKey then
        -- This doesn't have a mapping and isn't a tracked spell
        if CQ_Log.debugConsumables and event == "CAST" then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[CAST] " .. playerName .. 
                " used unmapped item: " .. consumableName .. " (" .. spellID .. ")|r");
        end
        return;
    end
    
    -- Initialize player data if needed
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
    
    -- Initialize consumable tracking for this player
    if not raid.players[playerName].consumables[buffKey] then
        raid.players[playerName].consumables[buffKey] = {
            applications = 0,
            totalUptime = 0,
            lastCheckHad = false,
            lastCheckTime = time(),
            lastTimeRemaining = 0,
            preRaidCredited = false,  -- guard: prevents poll pre-raid credit racing with this cast event
        };
    end
    
    local consumableData = raid.players[playerName].consumables[buffKey];
    
    -- Only increment application count on successful CAST
    -- START events are useful for debugging but we don't count them
    if event == "CAST" then
        consumableData.applications = consumableData.applications + 1;
        consumableData.lastCheckTime = time();
        consumableData.lastCheckHad = true;
        
        -- Set expected remaining time based on duration
        local duration = CQ_Log_ConsumableDurations[buffKey] or 3600;
        consumableData.lastTimeRemaining = duration;
        
        if CQ_Log.debugConsumables then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff[CAST] " .. playerName .. 
                " used " .. (spellName or consumableName) .. 
                " (apps: " .. consumableData.applications .. ")|r");
        end
    elseif event == "START" and CQ_Log.debugConsumables then
        -- Just log START events in debug mode (helps track refresh attempts)
        DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00[START] " .. playerName .. 
            " begins casting " .. (spellName or consumableName) .. "|r");
    end
end

-- Flush the pending queue into the newly-created raid object.
-- Called by CQ_Log_InitializeRaid immediately after the raid table exists.
function CQ_ConsInt_FlushPendingQueue(raid)
    if not raid or table.getn(CQ_ConsInt_PendingQueue) == 0 then
        return;
    end

    if CQ_Log.debugConsumables then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[PENDING QUEUE] Flushing " ..
            table.getn(CQ_ConsInt_PendingQueue) .. " queued cast(s) into raid log|r");
    end

    if not raid.castTrackedConsumables then
        raid.castTrackedConsumables = {};
    end

    for _, entry in ipairs(CQ_ConsInt_PendingQueue) do
        -- Write castTrackedConsumables entries. For weapon enchants we only stamp
        -- the MH key — OH tracking was removed to prevent doubled export entries.
        local isWepEnchant = CQ_Buffs[entry.buffKey] and CQ_Buffs[entry.buffKey].type == "wepbuffonly";
        local mhKey = entry.buffKey;
        if isWepEnchant and string.sub(entry.buffKey, -2) == "oh" then
            mhKey = string.sub(entry.buffKey, 1, -3);
        end
        local castKey = entry.playerName .. "." .. mhKey;
        raid.castTrackedConsumables[castKey] = {
            timestamp      = entry.timestamp,
            spellID        = entry.spellID,
            consumableName = entry.consumableName,
            spellName      = entry.spellName,
            playerName     = entry.playerName,
            buffKey        = mhKey,
        };

        -- Also increment the application counter
        if not raid.players[entry.playerName] then
            local raidIndex = CQ_Log_GetRaidIndex(entry.playerName);
            local _, playerClass;
            if raidIndex then
                _, playerClass = UnitClass("raid" .. raidIndex);
            end
            raid.players[entry.playerName] = {
                class = playerClass or "Unknown",
                participationTime = 0,
                lastSeen = time(),
                firstSeen = time(),
                consumables = {}
            };
        end
        if not raid.players[entry.playerName].consumables[entry.buffKey] then
            raid.players[entry.playerName].consumables[entry.buffKey] = {
                applications = 0,
                totalUptime = 0,
                lastCheckHad = false,
                lastCheckTime = time(),
                lastTimeRemaining = 0,
                preRaidCredited = false,  -- guard: prevents poll pre-raid credit racing with this cast event
            };
        end
        local consumableData = raid.players[entry.playerName].consumables[entry.buffKey];
        consumableData.applications = consumableData.applications + 1;
        consumableData.lastCheckTime = time();
        consumableData.lastCheckHad = true;
        local duration = CQ_Log_ConsumableDurations[entry.buffKey] or 3600;
        consumableData.lastTimeRemaining = duration;

        if CQ_Log.debugConsumables then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[PENDING QUEUE] Flushed: spellID " .. entry.spellID ..
                " (" .. entry.playerName .. " -> " .. entry.buffKey .. ")|r");
        end
    end

    -- Clear the queue
    CQ_ConsInt_PendingQueue = {};
end

-- Guard against Init being called more than once (timers always repeat in this engine).
CQ_ConsInt_Initialized = false;

-- Register the callback on initialization.
-- Note: the primary weapon enchant detection is now chat-message based
-- (CQ_Log_WeaponEnchantEvent in raidlog.lua).  This Init sets up:
--   1. The cast event callback for any future CAST-trackable consumables.
--   2. The RAB_UseItem hook so the WepPoll fallback knows intended buffKey.
--   3. The GetWeaponEnchantInfo poller as a belt-and-suspenders fallback
--      for the local player.
function CQ_ConsInt_Init()
    if CQ_ConsInt_Initialized then return; end
    CQ_ConsInt_Initialized = true;

    CQ_ConsTracker_BuildReverseLookup();

    if CQ_ConsTracker and CQ_ConsTracker_RegisterCallback then
        CQ_ConsTracker_RegisterCallback("raidlog", CQ_ConsInt_OnConsumable);
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[RAB Integration] CQ_ConsTracker not found!|r");
    end

    -- Tell the polling system (CQ_Log_CastTrackedKeys) to skip application-counting
    -- for every buffKey that System B (weapon enchants + poisons) tracks via Nampower.
    -- Without this, the 15s poll would see the weapon enchant still active and
    -- double-count it as a new application.
    -- Weapon enchants and poisons have no buff bar for other players, so polling
    -- can never contribute uptime for them either — skipping is always correct.
    if CQ_Log_CastTrackedKeys then
        for _, buffKey in pairs(CQ_ConsTracker_KeyMap) do
            CQ_Log_CastTrackedKeys[buffKey] = true;
        end
    end

end

-- Initialize after both systems are loaded
local integrationFrame = CreateFrame("Frame");
integrationFrame:RegisterEvent("PLAYER_LOGIN");
integrationFrame:SetScript("OnEvent", function()
    CQ_ConsInt_Init();
    this:UnregisterEvent("PLAYER_LOGIN");
end);

-- Helper function to check if a consumable was already tracked via cast event.
-- Keys in castTrackedConsumables are "PlayerName.buffKey".
function CQ_ConsInt_WasTrackedByCast(playerName, buffKey, spellID)
    if not CQ_Log.currentRaidId or not CQui_RaidLogs then
        return false;
    end

    local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
    if not raid or not raid.castTrackedConsumables then
        return false;
    end

    local castKey = playerName .. "." .. buffKey;
    local tracked = raid.castTrackedConsumables[castKey];
    if not tracked then
        return false;
    end

    -- Consider it tracked if seen within the last 30 seconds
    if GetTime() - tracked.timestamp < 30 then
        return true;
    end

    return false;
end

-- Add slash command to test the integration
SLASH_CONQCONSTEST1 = "/conqconstest";
SlashCmdList["CONQCONSTEST"] = function(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00=== RAB CONSUMABLE INTEGRATION TEST ===|r");
    
    -- Check tracker
    if CQ_ConsTracker then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Tracker: LOADED|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Tracker enabled: " .. tostring(CQ_ConsTracker.enabled) .. "|r");
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000Tracker: NOT LOADED|r");
    end
    
    -- Check raid log
    if CQ_Log then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Raid Log: LOADED|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Logging active: " .. tostring(CQ_Log.isLogging) .. "|r");
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000Raid Log: NOT LOADED|r");
    end
    
    -- Check callback registration
    if CQ_ConsTracker and CQ_ConsTracker.callbacks then
        if CQ_ConsTracker.callbacks["raidlog"] then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Callback: REGISTERED|r");
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000Callback: NOT REGISTERED|r");
        end
    end
    
    -- Report shared texture tracking
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00--- Shared Texture Tracking ---|r");
    local sharedCount = 0;
    for buffKey, spells in pairs(CQ_ConsTracker_BuffKeyToSpells) do
        if table.getn(spells) > 1 then
            sharedCount = sharedCount + 1;
            local spellList = "";
            for i, spellID in ipairs(spells) do
                spellList = spellList .. spellID;
                if i < table.getn(spells) then
                    spellList = spellList .. ", ";
                end
            end
            DEFAULT_CHAT_FRAME:AddMessage("|cffffffff  " .. buffKey .. ": [" .. spellList .. "]|r");
        end
    end
    if sharedCount == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffffff  No shared textures configured|r");
    end
    
    -- Suggest next steps
    if not CQ_Log or not CQ_Log.isLogging then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff9900Note: Start a raid in a raid zone to test tracking|r");
    end
    
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Use /conqcons debug to see consumable detection|r");
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Use /rablog debugconsumables to see raid log updates|r");
end
