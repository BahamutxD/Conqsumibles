-- Conq_CombatStats.lua
-- Tracks three additional combat stats:
--   1. Resurrection casts (who rezzed, how many times)
--   2. Innervate (who cast it, who received it)
--   3. CC breaks (who broke a Polymorph or Shackle Undead, and on which mob)
--
-- All data is stored under the active raid object in CQui_RaidLogs.
-- Hooks into the existing CQ_SpellGoFrame dispatcher for rez and innervate
-- casts.  CC break detection uses SPELL_DAMAGE_EVENT_OTHER cross-referenced
-- against a live table of CC'd mob GUIDs.
--
-- Data layout added to each raid object:
--
--   raid.rezzes[casterName] = { count = N, spellName = "Rebirth" }
--
--   raid.innervates[casterName] = {
--       count   = N,          -- total casts
--       targets = { [targetName] = N, ... }   -- who received them
--   }
--
--   raid.ccBreaks[breakerName] = {
--       count  = N,
--       breaks = { { mobName, ccType, timestamp }, ... }
--   }
--
-- Requires Nampower/SuperWOW (SPELL_GO_OTHER, SPELL_DAMAGE_EVENT_OTHER).
-- If Nampower is absent the SPELL_GO handler never fires; the module is safe
-- to load but will record nothing.

-- ============================================================================
-- SPELL ID TABLES
-- ============================================================================

-- All resurrection spell IDs. Mapped to a display name for the export.
CQ_CS_RezSpellIDs = {
    -- Priest: Resurrection
    [2006]  = "Resurrection",
    [2010]  = "Resurrection",
    [10880] = "Resurrection",
    [10881] = "Resurrection",
    [20770] = "Resurrection",
    -- Paladin: Redemption
    [7328]  = "Redemption",
    [10322] = "Redemption",
    [10324] = "Redemption",
    [20772] = "Redemption",
    [20773] = "Redemption",
    -- Shaman: Ancestral Spirit
    [2008]  = "Ancestral Spirit",
    [20609] = "Ancestral Spirit",
    [20610] = "Ancestral Spirit",
    [20776] = "Ancestral Spirit",
    [20777] = "Ancestral Spirit",
    -- Druid: Rebirth
    [20484] = "Rebirth",
    [20739] = "Rebirth",
    [20742] = "Rebirth",
    [20747] = "Rebirth",
    [20748] = "Rebirth",
};

-- Innervate (single spell, single rank in classic)
CQ_CS_InnervateSpellID = 29166;

-- CC spell IDs.  Value is the CC type label used in the break record.
-- SPELL_GO fires when the CC is CAST; we then note the target unit by
-- scanning the mob roster.
CQ_CS_CCSpellIDs = {
    -- Polymorph (all variants)
    [118]   = "Polymorph",
    [12824] = "Polymorph",
    [12825] = "Polymorph",
    [12826] = "Polymorph",
    [28270] = "Polymorph",   -- Cow
    [28271] = "Polymorph",   -- Turtle
    [28272] = "Polymorph",   -- Pig
    [57561] = "Polymorph",   -- Rodent
    -- Shackle Undead
    [9484]  = "Shackle Undead",
    [9485]  = "Shackle Undead",
    [10955] = "Shackle Undead",
};

-- How long (seconds) to keep a CC entry in the active table after the cast.
-- Polymorph max = 50 s, Shackle max = 30 s.  We use 60 s as a generous cap.
local CC_EXPIRE_SECONDS = 60;

-- ============================================================================
-- RUNTIME STATE
-- ============================================================================

-- Active CC'd mobs: [mobGuid] = { ccType, casterName, castTime, mobName }
-- Populated when a CC SPELL_GO fires; cleared when the mob takes damage or
-- the entry expires.
CQ_CS_ActiveCCs = {};

-- Whether to print debug output for this module.
CQ_CS_Debug = false;

-- ============================================================================
-- HELPERS
-- ============================================================================

-- Ensure the three stat tables exist on the current raid object.
local function CQ_CS_EnsureRaidTables(raid)
    if not raid.rezzes     then raid.rezzes     = {}; end
    if not raid.innervates then raid.innervates  = {}; end
    if not raid.ccBreaks   then raid.ccBreaks    = {}; end
end

-- Resolve a GUID to a player name using the raidlog's shared map.
-- Falls back to UnitName(guid) which SuperWOW supports.
local function CQ_CS_ResolveName(guid)
    if not guid then return nil; end
    -- Primary: shared raidlog GUID map (broadest, kept fresh)
    if CQ_Log_GuidMap and CQ_Log_GuidMap[guid] then
        return CQ_Log_GuidMap[guid];
    end
    -- Fallback: SuperWOW UnitName(guid)
    local n = UnitName(guid);
    if n and n ~= "" then return n; end
    return nil;
end

-- Resolve a mob GUID to a display name (NPC name).
-- Tries UnitName(guid) first (SuperWOW), then scans visible mob units.
local function CQ_CS_ResolveMobName(guid)
    if not guid then return "Unknown Mob"; end
    local n = UnitName(guid);
    if n and n ~= "" then return n; end
    return "mob:" .. string.sub(tostring(guid), 1, 8);
end

-- ============================================================================
-- RECORD FUNCTIONS
-- ============================================================================

function CQ_CS_RecordRez(casterName, spellName)
    if not CQ_Log or not CQ_Log.isLogging or not CQ_Log.currentRaidId then return; end
    local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
    if not raid then return; end
    CQ_CS_EnsureRaidTables(raid);

    if not raid.rezzes[casterName] then
        raid.rezzes[casterName] = { count = 0, spellName = spellName };
    end
    raid.rezzes[casterName].count = raid.rezzes[casterName].count + 1;

    if CQ_CS_Debug then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff[CS:REZ] " .. casterName ..
            " cast " .. spellName ..
            " (total: " .. raid.rezzes[casterName].count .. ")|r");
    end
end

-- Called from the innervate SPELL_GO handler (records the caster).
-- Target enrichment happens later via the chat event handler.
function CQ_CS_RecordInnervateCast(casterName)
    if not CQ_Log or not CQ_Log.isLogging or not CQ_Log.currentRaidId then return; end
    local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
    if not raid then return; end
    CQ_CS_EnsureRaidTables(raid);

    if not raid.innervates[casterName] then
        raid.innervates[casterName] = { count = 0, targets = {} };
    end
    raid.innervates[casterName].count = raid.innervates[casterName].count + 1;

    -- Remember who last cast innervate and when so the chat handler can
    -- attribute the target.
    CQ_CS_LastInnervateCaster = casterName;
    CQ_CS_LastInnervateTime   = GetTime();

    if CQ_CS_Debug then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff[CS:INNERVATE] " .. casterName ..
            " cast Innervate (total: " .. raid.innervates[casterName].count .. ")|r");
    end
end

-- Called from CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS when we see
-- "PlayerName gains Innervate." — enriches the last innervate with a target.
function CQ_CS_RecordInnervateTarget(targetName)
    if not CQ_Log or not CQ_Log.isLogging or not CQ_Log.currentRaidId then return; end
    local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
    if not raid then return; end

    local caster = CQ_CS_LastInnervateCaster;
    if not caster then return; end

    -- Accept the target only if the SPELL_GO fired within the last 3 seconds
    if not CQ_CS_LastInnervateTime or (GetTime() - CQ_CS_LastInnervateTime) > 3 then
        return;
    end

    CQ_CS_EnsureRaidTables(raid);

    if not raid.innervates[caster] then
        raid.innervates[caster] = { count = 0, targets = {} };
    end
    local t = raid.innervates[caster].targets;
    t[targetName] = (t[targetName] or 0) + 1;

    -- Clear so the same chat event doesn't double-attribute
    CQ_CS_LastInnervateCaster = nil;
    CQ_CS_LastInnervateTime   = nil;

    if CQ_CS_Debug then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff[CS:INNERVATE] target=" .. targetName ..
            " (caster=" .. caster .. ")|r");
    end
end

function CQ_CS_RecordCCBreak(breakerName, mobName, ccType)
    if not CQ_Log or not CQ_Log.isLogging or not CQ_Log.currentRaidId then return; end
    local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
    if not raid then return; end
    CQ_CS_EnsureRaidTables(raid);

    if not raid.ccBreaks[breakerName] then
        raid.ccBreaks[breakerName] = { count = 0, breaks = {} };
    end
    local entry = raid.ccBreaks[breakerName];
    entry.count = entry.count + 1;
    table.insert(entry.breaks, {
        mobName   = mobName,
        ccType    = ccType,
        timestamp = time(),
    });

    if CQ_CS_Debug then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff4444[CS:CCBREAK] " .. breakerName ..
            " broke " .. ccType .. " on " .. mobName ..
            " (total breaks: " .. entry.count .. ")|r");
    end
end

-- ============================================================================
-- CC ACTIVE TABLE MANAGEMENT
-- ============================================================================

-- Expire CC entries that are too old.
local function CQ_CS_ExpireOldCCs()
    local now = GetTime();
    for guid, cc in pairs(CQ_CS_ActiveCCs) do
        if (now - cc.castTime) > CC_EXPIRE_SECONDS then
            CQ_CS_ActiveCCs[guid] = nil;
        end
    end
end

-- Called when a CC spell fires (SPELL_GO).
-- We need to find which mob unit the caster is currently targeting because
-- SPELL_GO on vanilla SuperWOW only provides the caster GUID (arg3), not the
-- target GUID.  The most reliable approach is UnitGUID("target") captured
-- immediately on the SPELL_GO event — the caster's client has focus on the
-- target at the instant of cast.  For OTHER players we fall back to scanning
-- all visible mob units for one that now has the CC debuff (using UnitDebuff).
--
-- This is a best-effort approach.  It will miss CCs cast while the local
-- player's target is something else, but it covers the self-cast case (which
-- is the most common Polymorph scenario) reliably.
local function CQ_CS_RegisterCC(spellID, casterName)
    CQ_CS_ExpireOldCCs();

    local ccType = CQ_CS_CCSpellIDs[spellID];
    if not ccType then return; end

    -- Strategy 1: local player's current target
    local targetGuid = GetUnitGUID("target");
    if targetGuid and not UnitIsPlayer("target") and not UnitIsFriend("player", "target") then
        local mobName = UnitName("target") or "Unknown Mob";
        CQ_CS_ActiveCCs[targetGuid] = {
            ccType     = ccType,
            casterName = casterName,
            castTime   = GetTime(),
            mobName    = mobName,
        };
        if CQ_CS_Debug then
            DEFAULT_CHAT_FRAME:AddMessage("|cffffff00[CS:CC] Registered " .. ccType ..
                " on " .. mobName .. " (GUID:" .. string.sub(tostring(targetGuid),1,8) .. ")" ..
                " by " .. casterName .. "|r");
        end
        return;
    end

    -- Strategy 2: scan visible mob units for a fresh CC debuff
    -- We scan "target", "focus", and the first 8 mob units exposed by SuperWOW.
    -- This is a heuristic and may not always find the right mob, but it is
    -- harmless if it misses — we simply won't record the CC in the active table.
    local ccName = ccType; -- e.g. "Polymorph" or "Shackle Undead"
    local unitsToScan = { "target" };  -- "focus" is not valid in vanilla WoW (TBC+)
    -- Nampower exposes "nameplate1".."nameplate20" on some builds; skip here
    -- as it is not universally available.
    for _, unit in ipairs(unitsToScan) do
        if UnitExists(unit) and not UnitIsPlayer(unit) and not UnitIsFriend("player", unit) then
            local guid = GetUnitGUID(unit);
            if guid then
                -- Check if this mob has a debuff matching the CC name
                local i = 1;
                while true do
                    local debuffName = UnitDebuff(unit, i);
                    if not debuffName then break; end
                    if string.find(debuffName, ccName, 1, true) then
                        CQ_CS_ActiveCCs[guid] = {
                            ccType     = ccType,
                            casterName = casterName,
                            castTime   = GetTime(),
                            mobName    = UnitName(unit) or "Unknown Mob",
                        };
                        if CQ_CS_Debug then
                            DEFAULT_CHAT_FRAME:AddMessage("|cffffff00[CS:CC] Registered (scan) " ..
                                ccType .. " on " .. (UnitName(unit) or "?") .. "|r");
                        end
                        return;
                    end
                    i = i + 1;
                end
            end
        end
    end
end

-- ============================================================================
-- SPELL_GO HOOK  (piggybacks onto CQ_SpellGoFrame via a second registration)
-- We listen on both SPELL_GO_SELF and SPELL_GO_OTHER using a separate frame
-- so we don't have to modify CQ_SpellGoFrame directly.
-- ============================================================================

local CQ_CS_SpellGoFrame = CreateFrame("Frame");
CQ_CS_SpellGoFrame:RegisterEvent("SPELL_GO_SELF");
CQ_CS_SpellGoFrame:RegisterEvent("SPELL_GO_OTHER");
CQ_CS_SpellGoFrame:SetScript("OnEvent", function()
    if event ~= "SPELL_GO_SELF" and event ~= "SPELL_GO_OTHER" then return; end

    -- Nampower SPELL_GO: arg1=itemId, arg2=spellID, arg3=casterGUID
    local spellID    = arg2;
    local casterGuid = arg3;

    if not spellID then return; end

    -- ---- Resurrection -------------------------------------------------------
    local rezName = CQ_CS_RezSpellIDs[spellID];
    if rezName then
        local casterName = CQ_CS_ResolveName(casterGuid);
        if casterName then
            CQ_CS_RecordRez(casterName, rezName);
        end
        return; -- rez and CC are mutually exclusive
    end

    -- ---- Innervate ----------------------------------------------------------
    if spellID == CQ_CS_InnervateSpellID then
        local casterName = CQ_CS_ResolveName(casterGuid);
        if casterName then
            CQ_CS_RecordInnervateCast(casterName);
        end
        return;
    end

    -- ---- CC casts (record active CC) ----------------------------------------
    if CQ_CS_CCSpellIDs[spellID] then
        local casterName = CQ_CS_ResolveName(casterGuid) or "Unknown";
        CQ_CS_RegisterCC(spellID, casterName);
        return;
    end
end);

-- ============================================================================
-- INNERVATE TARGET  (chat event — fires when the recipient gains the buff)
-- Format: "PlayerName gains Innervate."
-- Event:  CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS
-- ============================================================================

local CQ_CS_InnervateFrame = CreateFrame("Frame");
CQ_CS_InnervateFrame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS");
CQ_CS_InnervateFrame:SetScript("OnEvent", function()
    local msg = arg1;
    if not msg then return; end

    -- Match: "PlayerName gains Innervate."
    -- Also handle: "You gain Innervate." (self-innervate, rare but valid)
    local targetName;
    if string.find(msg, "^You gain Innervate") then
        targetName = UnitName("player");
    elseif string.find(msg, "gains Innervate") then
        local _, _, extracted = string.find(msg, "^(.+) gains Innervate");
        if extracted then
            targetName = extracted;
        end
    end

    if targetName then
        CQ_CS_RecordInnervateTarget(targetName);
    end
end);

-- ============================================================================
-- CC BREAK DETECTION  (SPELL_DAMAGE_EVENT_OTHER and AUTO_ATTACK_OTHER)
-- When a CC'd mob receives any damage we record who caused it.
-- AUTO_ATTACK_OTHER:        arg1=attackerGuid, arg2=targetGuid
-- SPELL_DAMAGE_EVENT_OTHER: arg1=targetGuid,   arg2=casterGuid
-- ============================================================================

local CQ_CS_CCBreakFrame = CreateFrame("Frame");
CQ_CS_CCBreakFrame:RegisterEvent("AUTO_ATTACK_OTHER");
CQ_CS_CCBreakFrame:RegisterEvent("SPELL_DAMAGE_EVENT_OTHER");
CQ_CS_CCBreakFrame:SetScript("OnEvent", function()
    if not CQ_Log or not CQ_Log.isLogging then return; end

    local attackerGuid, targetGuid;
    if event == "AUTO_ATTACK_OTHER" then
        attackerGuid = arg1;
        targetGuid   = arg2;
    else -- SPELL_DAMAGE_EVENT_OTHER
        targetGuid   = arg1;
        attackerGuid = arg2;
    end

    if not targetGuid or not attackerGuid then return; end

    -- Is this mob currently CC'd?
    local cc = CQ_CS_ActiveCCs[targetGuid];
    if not cc then return; end

    -- Was it already expired?
    if (GetTime() - cc.castTime) > CC_EXPIRE_SECONDS then
        CQ_CS_ActiveCCs[targetGuid] = nil;
        return;
    end

    -- Resolve the attacker to a player name
    local breakerName = CQ_CS_ResolveName(attackerGuid);
    if not breakerName then return; end

    -- Only attribute to raid members (prevent NPCs/pets from showing up)
    local isRaidMember = (breakerName == UnitName("player"));
    if not isRaidMember then
        for i = 1, GetNumRaidMembers() do
            if UnitName("raid" .. i) == breakerName then
                isRaidMember = true;
                break;
            end
        end
    end
    if not isRaidMember then return; end

    -- The caster of the CC is exempt — they're allowed to nuke their own CC
    -- (intentional break, e.g. counterspell follow-up). Debatable: enable
    -- this if you want to track even self-breaks.
    -- if breakerName == cc.casterName then return; end

    -- Record the break and remove the active entry (one break per CC instance)
    CQ_CS_RecordCCBreak(breakerName, cc.mobName, cc.ccType);
    CQ_CS_ActiveCCs[targetGuid] = nil;
end);

-- ============================================================================
-- INITIALIZE  (called once at PLAYER_LOGIN)
-- Sets the NP_EnableSpellGoEvents CVar — this is idempotent; raidlog.lua
-- already sets it, but we guard here in case load order ever changes.
-- ============================================================================

local CQ_CS_InitFrame = CreateFrame("Frame");
CQ_CS_InitFrame:RegisterEvent("PLAYER_LOGIN");
CQ_CS_InitFrame:SetScript("OnEvent", function()
    if not GetNampowerVersion then
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cffff9900[CombatStats] Nampower not detected. Rez/Innervate/CC tracking disabled.|r");
        CQ_CS_SpellGoFrame:UnregisterEvent("SPELL_GO_SELF");
        CQ_CS_SpellGoFrame:UnregisterEvent("SPELL_GO_OTHER");
        CQ_CS_CCBreakFrame:UnregisterEvent("AUTO_ATTACK_OTHER");
        CQ_CS_CCBreakFrame:UnregisterEvent("SPELL_DAMAGE_EVENT_OTHER");
    else
        SetCVar("NP_EnableSpellGoEvents", "1");
        if CQ_CS_Debug then
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff00ff00[CombatStats] Initialized (rez/innervate/CC tracking active).|r");
        end
    end
    this:UnregisterEvent("PLAYER_LOGIN");
end);

-- ============================================================================
-- SLASH COMMAND  /conqcs
-- ============================================================================

SLASH_CONQCS1 = "/conqcs";
SlashCmdList["CONQCS"] = function(msg)
    msg = strlower(string.gsub(msg or "", "^%s*(.-)%s*$", "%1"));

    if msg == "debug" then
        CQ_CS_Debug = not CQ_CS_Debug;
        if CQ_CS_Debug then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[CombatStats] Debug ENABLED|r");
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[CombatStats] Debug DISABLED|r");
        end

    elseif msg == "cc" or msg == "ccbreaks" then
        if not CQ_Log or not CQ_Log.isLogging or not CQ_Log.currentRaidId then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[CombatStats] No active raid.|r");
            return;
        end
        local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
        if not raid or not raid.ccBreaks or not next(raid.ccBreaks) then
            DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[CombatStats] No CC breaks recorded.|r");
            return;
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cffff4444=== CC BREAKS ===|r");
        for name, data in pairs(raid.ccBreaks) do
            DEFAULT_CHAT_FRAME:AddMessage("|cffffffff" .. name .. "|r: " .. data.count .. " break(s)");
            for _, b in ipairs(data.breaks) do
                DEFAULT_CHAT_FRAME:AddMessage("  |cffaaaaaa" .. b.ccType .. " on " .. b.mobName .. "|r");
            end
        end

    elseif msg == "rezzes" or msg == "rez" then
        if not CQ_Log or not CQ_Log.isLogging or not CQ_Log.currentRaidId then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[CombatStats] No active raid.|r");
            return;
        end
        local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
        if not raid or not raid.rezzes or not next(raid.rezzes) then
            DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[CombatStats] No rezzes recorded.|r");
            return;
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00=== REZZES ===|r");
        for name, data in pairs(raid.rezzes) do
            DEFAULT_CHAT_FRAME:AddMessage("|cffffffff" .. name .. "|r: " ..
                data.count .. "x " .. data.spellName);
        end

    elseif msg == "innervate" or msg == "innervates" then
        if not CQ_Log or not CQ_Log.isLogging or not CQ_Log.currentRaidId then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[CombatStats] No active raid.|r");
            return;
        end
        local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
        if not raid or not raid.innervates or not next(raid.innervates) then
            DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[CombatStats] No innervates recorded.|r");
            return;
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff=== INNERVATES ===|r");
        for name, data in pairs(raid.innervates) do
            DEFAULT_CHAT_FRAME:AddMessage("|cffffffff" .. name .. "|r: " .. data.count .. " cast(s)");
            for target, n in pairs(data.targets) do
                DEFAULT_CHAT_FRAME:AddMessage("  -> " .. target .. " (" .. n .. "x)");
            end
        end

    elseif msg == "activeccs" then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffff00=== ACTIVE CCs ===|r");
        CQ_CS_ExpireOldCCs();
        local count = 0;
        for guid, cc in pairs(CQ_CS_ActiveCCs) do
            local age = math.floor(GetTime() - cc.castTime);
            DEFAULT_CHAT_FRAME:AddMessage("|cffffffff" .. cc.mobName .. "|r " ..
                cc.ccType .. " by " .. cc.casterName .. " (" .. age .. "s ago)");
            count = count + 1;
        end
        if count == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa No active CCs tracked.|r");
        end

    elseif msg == "status" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00=== COMBAT STATS STATUS ===|r");
        DEFAULT_CHAT_FRAME:AddMessage("Nampower:   " .. tostring(GetNampowerVersion ~= nil));
        DEFAULT_CHAT_FRAME:AddMessage("Logging:    " .. tostring(CQ_Log and CQ_Log.isLogging or false));
        DEFAULT_CHAT_FRAME:AddMessage("Debug:      " .. tostring(CQ_CS_Debug));
        local ccCount = 0;
        for _ in pairs(CQ_CS_ActiveCCs) do ccCount = ccCount + 1; end
        DEFAULT_CHAT_FRAME:AddMessage("Active CCs: " .. ccCount);

    else
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00=== Combat Stats (/conqcs) ===|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqcs rezzes      - Show rez counts|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqcs innervates  - Show innervate counts + targets|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqcs cc          - Show CC break counts|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqcs activeccs   - Show currently tracked CC'd mobs|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqcs status      - Module status|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00/conqcs debug       - Toggle debug output|r");
    end
end
