-- Conq_EnchantScanner.lua
-- Enchant scanner integrated into Conqsumibles.
-- Scans all raid members' gear enchants during a logging session.
-- Players out of range are queued for retry; successful scans are stored
-- under raid.enchants[playerName].slots[slotName] =
--   { itemId, itemName, itemQuality, enchantId, enchant }.
--
-- Derived from Encantadores v1.5 by Claude.
-- Integrated into Conqsumibles v2.0.0.
-- ---------------------------------------------------------------------------

CQ_EnchantScanner = {
    VERSION      = "1.0",
    scanning     = false,
    state        = "idle",   -- "idle" | "waiting" | "read"
    timer        = 0,
    STEP_DELAY   = 1.2,      -- seconds to wait after NotifyInspect before reading
    currentUnit  = nil,
    queue        = {},       -- { unit, name, attempt }
    retryQueue   = {},       -- players deferred for a later pass
    RETRY_DELAY  = 60,       -- seconds between retry passes
    lastRetryTime = 0,
    MAX_ATTEMPTS = 5,        -- give up after this many failed inspect attempts per player
    sessionScanned = {},     -- playerName -> true; prevents re-scanning already-done players
    debug        = false,
};

-- ---------------------------------------------------------------------------
-- SLOT DEFINITIONS  (mirrors Encantadores exactly)
-- ---------------------------------------------------------------------------
CQ_EnchantScanner.SLOTS = {
    { id = 1,  name = "Head",      enchantable = true  },
    { id = 2,  name = "Neck",      enchantable = true  },
    { id = 3,  name = "Shoulder",  enchantable = true  },
    { id = 15, name = "Back",      enchantable = true  },
    { id = 5,  name = "Chest",     enchantable = true  },
    { id = 9,  name = "Wrist",     enchantable = true  },
    { id = 10, name = "Hands",     enchantable = true  },
    { id = 6,  name = "Waist",     enchantable = true  },
    { id = 7,  name = "Legs",      enchantable = true  },
    { id = 8,  name = "Feet",      enchantable = true  },
    { id = 11, name = "Ring 1",    enchantable = true  },
    { id = 12, name = "Ring 2",    enchantable = true  },
    { id = 16, name = "Main Hand", enchantable = true  },
    { id = 17, name = "Off Hand",  enchantable = true  },
    { id = 18, name = "Ranged",    enchantable = true,  casterSkip = true },
};

-- Classes whose ranged slot cannot be enchanted (wand / relic)
CQ_EnchantScanner.CASTER_CLASSES = {
    ["Mage"]    = true,
    ["Warlock"] = true,
    ["Priest"]  = true,
    ["Paladin"] = true,
    ["Shaman"]  = true,
    ["Druid"]   = true,
};

-- ---------------------------------------------------------------------------
-- ITEM QUALITY NAMES  (maps GetItemInfo quality index -> readable name)
-- ---------------------------------------------------------------------------
CQ_EnchantScanner.QUALITY_NAMES = {
    [0] = "poor",
    [1] = "common",
    [2] = "uncommon",
    [3] = "rare",
    [4] = "epic",
    [5] = "legendary",
    [6] = "artifact",
    [7] = "heirloom",
};

-- ---------------------------------------------------------------------------
-- HARDCODED ENCHANT NAMES  (ZG head/shoulder librams; vanilla 1.12)
-- ---------------------------------------------------------------------------
CQ_EnchantScanner.ENCHANT_NAMES = {
    [1144] = "ZG: +8 Def/+10 Armor",
    [1145] = "ZG: +8 Spell Dmg/Heal",
    [1146] = "ZG: +8 Str/+25 AP",
    [1147] = "ZG: +8 Agi",
    [1148] = "ZG: +8 Spirit",
    [1149] = "ZG: +8 Int",
    [1150] = "ZG: Increased Healing",
    [1151] = "ZG: +10 Fire Resist",
    [1152] = "ZG: +10 Nature Resist",
    [1153] = "ZG: +10 Frost Resist",
    [1154] = "ZG: +10 Shadow Resist",
    [1155] = "ZG: +10 Arcane Resist",
    [1128] = "ZG: Presence of Might",
    [1129] = "ZG: Presence of Sight",
    [1130] = "ZG: Presence of Power",
};

-- ---------------------------------------------------------------------------
-- TOOLTIP SCANNER  (reuses ENCTooltipScanner if Encantadores is loaded,
--                   otherwise creates its own frame)
-- ---------------------------------------------------------------------------
local function EnsureTooltip()
    if CQ_EnchantScanner._tt then return end;
    -- Prefer the Encantadores frame if it already exists to avoid duplicate globals
    if ENCTooltipScanner then
        CQ_EnchantScanner._tt = ENCTooltipScanner;
    else
        CQ_EnchantScanner._tt = CreateFrame(
            "GameTooltip", "CQEncTooltipScanner", UIParent, "GameTooltipTemplate");
        CQ_EnchantScanner._tt:SetOwner(UIParent, "ANCHOR_NONE");
    end
end

-- ---------------------------------------------------------------------------
-- TOOLTIP PARSING  (positional strategy from Encantadores)
-- ---------------------------------------------------------------------------
local ANCHOR_PATTERNS = {
    "^Durability", "^Classes:", "^Races:", "^Requires",
    "^Equip:", "^Use:", "^Chance on hit", "^Set:",
    "%(%d+/%d+%)", "^ItemID:",
};
local HARD_HEADER_PATTERNS = {
    "^Soulbound$", "^Binds when", "^Unique",
    "^Head$", "^Neck$", "^Shoulder$", "^Back$", "^Chest$",
    "^Waist$", "^Legs$", "^Feet$", "^Wrist$", "^Hands$",
    "^Finger$", "^Trinket$", "^Main Hand$", "^Off Hand$",
    "^One%-Hand$", "^Two%-Hand$", "^Ranged$", "^Held In Off%-hand$",
    "^Cloth$", "^Leather$", "^Mail$", "^Plate$", "^Shield$",
    "^Miscellaneous$", "^Idol$", "^Totem$", "^Libram$",
    "^Dagger$", "^Sword$", "^Axe$", "^Mace$", "^Polearm$",
    "^Stave$", "^Staff$", "^Bow$", "^Gun$", "^Crossbow$", "^Wand$",
    "^Fist Weapon$", "^Thrown$", "^<", "^Value:", "^ItemID:",
};

local function _matchesAny(txt, patterns)
    for _, p in ipairs(patterns) do
        if string.find(txt, p) then return true end;
    end
    return false;
end

local function _extractEnchantLine(lines)
    local hardHeaderDone = false;
    local lastNonEmpty   = nil;
    for _, txt in ipairs(lines) do
        if txt == "" then
            -- skip blank
        elseif _matchesAny(txt, ANCHOR_PATTERNS) then
            if hardHeaderDone and lastNonEmpty then return lastNonEmpty end;
            return nil;
        elseif _matchesAny(txt, HARD_HEADER_PATTERNS) then
            hardHeaderDone = false;
            lastNonEmpty   = nil;
        else
            hardHeaderDone = true;
            lastNonEmpty   = txt;
        end
    end
    return nil;
end

local function _stripSetLines(lines)
    local result = {};
    for _, txt in ipairs(lines) do
        if string.find(txt, "%(%d+/%d+%)") then break end;
        table.insert(result, txt);
    end
    return result;
end

-- Read enchant name from tooltip for a unit/slot, learn and cache it.
local function _learnEnchantFromTooltip(unit, slotId, enchantId)
    if not enchantId or enchantId == 0 then return end;
    -- Already know a clean name?
    if CQ_EnchantScanner.ENCHANT_NAMES[enchantId] then return end;
    if CQ_EncDB and CQ_EncDB.learned and CQ_EncDB.learned[enchantId] then
        if not string.find(CQ_EncDB.learned[enchantId], "^ID %d") then return end;
    end

    EnsureTooltip();
    local tt  = CQ_EnchantScanner._tt;
    local ttPrefix = (tt == ENCTooltipScanner) and "ENCTooltipScanner" or "CQEncTooltipScanner";

    local ok = pcall(function()
        tt:ClearLines();
        tt:SetInventoryItem(unit, slotId);
    end);
    if not ok then return end;

    local lines = {};
    for i = 2, tt:NumLines() do
        local left = getglobal(ttPrefix .. "TextLeft" .. i);
        if left then
            local txt = left:GetText();
            if txt then
                local clean = string.gsub(txt, "|c%x%x%x%x%x%x%x%x", "");
                clean = string.gsub(clean, "|r", "");
                clean = string.gsub(clean, "^%s+", "");
                clean = string.gsub(clean, "%s+$", "");
                table.insert(lines, clean);
            end
        end
    end

    local enchantLine = _extractEnchantLine(_stripSetLines(lines));
    if not CQ_EncDB then CQ_EncDB = {} end;
    if not CQ_EncDB.learned then CQ_EncDB.learned = {} end;
    if enchantLine then
        CQ_EncDB.learned[enchantId] = enchantLine;
    else
        CQ_EncDB.learned[enchantId] = "ID " .. enchantId;
    end
end

function CQ_EnchantScanner:GetEnchantName(enchantId)
    if not enchantId or enchantId == 0 then return nil end;
    if self.ENCHANT_NAMES[enchantId] then return self.ENCHANT_NAMES[enchantId] end;
    if CQ_EncDB and CQ_EncDB.learned and CQ_EncDB.learned[enchantId] then
        return CQ_EncDB.learned[enchantId];
    end
    return nil;
end

-- ---------------------------------------------------------------------------
-- PARSE ITEM LINK
-- ---------------------------------------------------------------------------
function CQ_EnchantScanner:ParseItemLink(link)
    if not link then return nil, nil end;
    local _, _, itemId, enchantId = string.find(link, "item:(%d+):(%d+)");
    if itemId then return tonumber(itemId), tonumber(enchantId) end;
    return nil, nil;
end

-- ---------------------------------------------------------------------------
-- LOGGING HELPERS
-- ---------------------------------------------------------------------------
local function _dbg(msg)
    -- silent; only printed when debug=true via /cqenc debug
    if CQ_EnchantScanner.debug then
        DEFAULT_CHAT_FRAME:AddMessage("|cff88ccff[CQ Enchant]|r " .. msg);
    end
end

local function _info(msg)
    _dbg(msg);  -- silent in normal operation; visible only when debug=true
end

-- ---------------------------------------------------------------------------
-- WRITE RESULTS INTO RAID LOG
-- Stores under raid.enchants[playerName] = {
--     class   = "Warrior",
--     scanned = timestamp,
--     slots   = { ["Head"] = { itemId=X, itemName="Foo", itemQuality="epic", enchantId=Y, enchant="Name" }, ... },
--     missing = { "Wrist", "Feet", ... },
-- }
-- ---------------------------------------------------------------------------
local function _writeToRaidLog(name, data)
    if not CQ_Log or not CQ_Log.isLogging or not CQ_Log.currentRaidId then return end;
    if not CQui_RaidLogs or not CQui_RaidLogs.raids then return end;
    local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
    if not raid then return end;

    if not raid.enchants then raid.enchants = {} end;

    -- Merge rather than overwrite: keep any previously-scanned slots and only
    -- replace with fresher data.
    local existing = raid.enchants[name];
    if not existing then
        raid.enchants[name] = {
            class   = data.class,
            scanned = time(),
            slots   = {},
            missing = {},
        };
        existing = raid.enchants[name];
    else
        existing.scanned = time();
        existing.class   = data.class;
    end

    for slotName, slotData in pairs(data.slots) do
        existing.slots[slotName] = slotData;
    end

    -- Rebuild missing list from merged slots
    existing.missing = {};
    for _, slot in ipairs(CQ_EnchantScanner.SLOTS) do
        if slot.enchantable then
            local sd = existing.slots[slot.name];
            if sd and not sd.holdable and not sd.casterSkip
               and sd.enchantId == 0 then
                table.insert(existing.missing, slot.name);
            end
        end
    end

    _dbg("Wrote enchants for " .. name ..
         " (" .. table.getn(existing.missing) .. " missing)");
end

-- ---------------------------------------------------------------------------
-- INSPECT / PROCESS ONE UNIT
-- Returns "ok" | "retry" (unit unreachable)
-- ---------------------------------------------------------------------------
function CQ_EnchantScanner:ProcessUnit(unit)
    local name  = UnitName(unit)  or unit;
    local class = UnitClass(unit) or "Unknown";

    -- Unreachable: queue for retry
    if not UnitIsConnected(unit) then
        _dbg(name .. " offline — will retry");
        return "retry";
    end
    if unit ~= "player" and not UnitIsVisible(unit) then
        _dbg(name .. " out of range — will retry");
        return "retry";
    end

    local data = { class = class, slots = {}, missing = {} };

    for _, slot in ipairs(self.SLOTS) do
        if slot.casterSkip and self.CASTER_CLASSES[class] then
            data.slots[slot.name] = { casterSkip = true };
        else
            local link = GetInventoryItemLink(unit, slot.id);
            if link then
                local itemId, enchantId = self:ParseItemLink(link);
                if itemId then
                    local isHoldable = false;
                    -- Fetch item name and quality for all slots (returns name, link, quality, ...)
                    local iName, _, iQuality = GetItemInfo(itemId);
                    local iQualityName = (iQuality ~= nil)
                        and (CQ_EnchantScanner.QUALITY_NAMES[iQuality] or "unknown")
                        or "unknown";

                    if slot.id == 17 then
                        local _, _, _, _, _, _, _, equipLoc = GetItemInfo(itemId);
                        if equipLoc == "INVTYPE_HOLDABLE" then
                            isHoldable = true;
                            data.slots[slot.name] = {
                                itemId      = itemId,
                                itemName    = iName or "",
                                itemQuality = iQualityName,
                                enchantId   = enchantId,
                                enchant     = nil,
                                holdable    = true,
                            };
                        end
                    end
                    if not isHoldable then
                        if enchantId and enchantId ~= 0 then
                            _learnEnchantFromTooltip(unit, slot.id, enchantId);
                        end
                        data.slots[slot.name] = {
                            itemId      = itemId,
                            itemName    = iName or "",
                            itemQuality = iQualityName,
                            enchantId   = enchantId or 0,
                            enchant     = self:GetEnchantName(enchantId),
                        };
                        if slot.enchantable and (not enchantId or enchantId == 0) then
                            table.insert(data.missing, slot.name);
                        end
                    end
                end
            end
        end
    end

    -- Cross-slot name resolution (in case tooltip gave us the name on another pass)
    for _, slot in ipairs(self.SLOTS) do
        local sd = data.slots[slot.name];
        if sd and sd.enchantId and sd.enchantId ~= 0 then
            local known = self:GetEnchantName(sd.enchantId);
            if known and not string.find(known, "^ID %d") then
                sd.enchant = known;
            end
        end
    end

    _writeToRaidLog(name, data);
    self.sessionScanned[name] = true;

    if table.getn(data.missing) > 0 then
        _info(name .. ": " .. table.getn(data.missing) ..
              " slot(s) missing enchant (" ..
              table.concat(data.missing, ", ") .. ")");
    else
        _dbg(name .. " fully enchanted");
    end

    return "ok";
end

-- ---------------------------------------------------------------------------
-- BUILD QUEUE  (call at raid start or on demand)
-- ---------------------------------------------------------------------------
function CQ_EnchantScanner:BuildQueue(forceRescan)
    local numRaid  = GetNumRaidMembers();
    local numParty = GetNumPartyMembers();
    if numRaid == 0 and numParty == 0 then return end;

    local playerName = UnitName("player");
    self.queue = {};

    if numRaid > 0 then
        for i = 1, numRaid do
            local unit = "raid" .. i;
            local name = UnitName(unit);
            if name and (forceRescan or not self.sessionScanned[name]) then
                local u = (name == playerName) and "player" or unit;
                table.insert(self.queue, { unit = u, name = name, attempt = 1 });
            end
        end
    else
        if forceRescan or not self.sessionScanned[playerName] then
            table.insert(self.queue, { unit = "player", name = playerName, attempt = 1 });
        end
        for i = 1, numParty do
            local unit  = "party" .. i;
            local name  = UnitName(unit);
            if name and (forceRescan or not self.sessionScanned[name]) then
                table.insert(self.queue, { unit = unit, name = name, attempt = 1 });
            end
        end
    end
    _dbg("Queue built: " .. table.getn(self.queue) .. " player(s)");
end

-- ---------------------------------------------------------------------------
-- START / STOP
-- ---------------------------------------------------------------------------
function CQ_EnchantScanner:StartScan(forceRescan)
    if self.scanning then
        _info("Scan already in progress...");
        return;
    end
    self:BuildQueue(forceRescan);
    if table.getn(self.queue) == 0 then
        _dbg("Nothing to scan.");
        return;
    end
    self.retryQueue  = {};
    self.scanning    = true;
    self.state       = "idle";
    self.timer       = 0;
    self.currentUnit = nil;
    _info("Scanning " .. table.getn(self.queue) .. " player(s)...");
end

function CQ_EnchantScanner:StopScan()
    self.scanning    = false;
    self.state       = "idle";
    self.currentUnit = nil;
    self.queue       = {};
end

-- Called when a new raid session begins.
function CQ_EnchantScanner:OnRaidStart()
    self.sessionScanned = {};
    self.retryQueue     = {};
    self.lastRetryTime  = GetTime();
    -- Short delay so the raid roster is fully populated before we inspect
    RAB_Core_AddTimer(5, "CQEncInitialScan", function()
        CQ_EnchantScanner:StartScan(false);
        RAB_Core_RemoveTimer("CQEncInitialScan");
    end);
end

-- Called when the raid session ends.
function CQ_EnchantScanner:OnRaidEnd()
    self:StopScan();
    self.sessionScanned = {};
    self.retryQueue     = {};
end

-- ---------------------------------------------------------------------------
-- STATE MACHINE  (driven by OnUpdate)
-- ---------------------------------------------------------------------------
CQ_EnchantScanner._frame = CreateFrame("Frame", "CQEnchantScannerFrame", UIParent);

CQ_EnchantScanner._frame:SetScript("OnEvent", function()
    if event == "INSPECT_READY" then
        if CQ_EnchantScanner.scanning and CQ_EnchantScanner.state == "waiting" then
            CQ_EnchantScanner.state = "read";
        end
    end
end);
CQ_EnchantScanner._frame:RegisterEvent("INSPECT_READY");

CQ_EnchantScanner._frame:SetScript("OnUpdate", function()
    local es = CQ_EnchantScanner;
    local dt = arg1;

    -- Periodic retry pass (even when not actively scanning)
    if CQ_Log and CQ_Log.isLogging then
        es.lastRetryTime = es.lastRetryTime or 0;
        if (GetTime() - es.lastRetryTime) >= es.RETRY_DELAY then
            es.lastRetryTime = GetTime();
            if table.getn(es.retryQueue) > 0 then
                -- Move retry entries back into the main queue and kick off a scan
                for _, entry in ipairs(es.retryQueue) do
                    table.insert(es.queue, entry);
                end
                es.retryQueue = {};
                if not es.scanning then
                    es.scanning = true;
                    es.state    = "idle";
                    _dbg("Retry pass: " .. table.getn(es.queue) .. " player(s)");
                end
            end
        end
    end

    if not es.scanning then return end;

    if es.state == "idle" then
        if table.getn(es.queue) == 0 then
            -- Done with this pass
            es.scanning = false;
            local retryCount = table.getn(es.retryQueue);
            if retryCount > 0 then
                _info("Scan pass done. " .. retryCount ..
                      " player(s) out of range — will retry in " ..
                      es.RETRY_DELAY .. "s.");
            else
                _info("Scan complete.");
            end
            return;
        end

        local entry = table.remove(es.queue, 1);
        if not entry then return end;
        if not UnitExists(entry.unit) then
            -- Unit gone from raid (disconnected / left) — skip silently
            return;
        end

        es.currentEntry = entry;

        if entry.unit == "player" then
            -- Self inspect: no NotifyInspect needed
            es.state = "read";
        else
            NotifyInspect(entry.unit);
            es.timer = 0;
            es.state = "waiting";
        end

    elseif es.state == "waiting" then
        es.timer = es.timer + dt;
        if es.timer >= es.STEP_DELAY then
            es.state = "read";
        end

    elseif es.state == "read" then
        local entry = es.currentEntry;
        es.currentEntry = nil;
        es.state  = "idle";
        es.timer  = 0;

        if entry and UnitExists(entry.unit) then
            local result = es:ProcessUnit(entry.unit);
            if result == "retry" then
                entry.attempt = entry.attempt + 1;
                if entry.attempt <= es.MAX_ATTEMPTS then
                    table.insert(es.retryQueue, entry);
                    _dbg(entry.name .. " queued for retry (attempt " ..
                         entry.attempt .. "/" .. es.MAX_ATTEMPTS .. ")");
                else
                    _info("|cffff9900" .. entry.name ..
                          " unreachable after " .. es.MAX_ATTEMPTS ..
                          " attempts — skipped.|r");
                end
            end
        end
    end
end);

-- ---------------------------------------------------------------------------
-- HOOK INTO RAID LOGGER  (called by Conq_raidlog.lua start/finalize hooks)
-- ---------------------------------------------------------------------------

-- CQ_EnchantScanner_OnRaidStart / OnRaidEnd are called from Conq_raidlog.lua
-- after CQ_Log_StartRaid / CQ_Log_FinalizeRaid. We expose thin wrappers so
-- the hook names are predictable.
function CQ_EnchantScanner_OnRaidStart()
    CQ_EnchantScanner:OnRaidStart();
end

function CQ_EnchantScanner_OnRaidEnd()
    CQ_EnchantScanner:OnRaidEnd();
end

-- ---------------------------------------------------------------------------
-- ROSTER CHANGE: add new joiners to the queue mid-raid
-- ---------------------------------------------------------------------------
local _rosterFrame = CreateFrame("Frame");
_rosterFrame:RegisterEvent("RAID_ROSTER_UPDATE");
_rosterFrame:SetScript("OnEvent", function()
    if not CQ_Log or not CQ_Log.isLogging then return end;
    -- Give the game a moment to populate the new unit tokens
    RAB_Core_AddTimer(3, "CQEncRosterUpdate", function()
        local newEntries = {};
        local playerName = UnitName("player");
        for i = 1, GetNumRaidMembers() do
            local unit = "raid" .. i;
            local name = UnitName(unit);
            if name and not CQ_EnchantScanner.sessionScanned[name] then
                local u = (name == playerName) and "player" or unit;
                table.insert(newEntries, { unit = u, name = name, attempt = 1 });
            end
        end
        if table.getn(newEntries) > 0 then
            for _, e in ipairs(newEntries) do
                table.insert(CQ_EnchantScanner.queue, e);
            end
            if not CQ_EnchantScanner.scanning then
                CQ_EnchantScanner.scanning = true;
                CQ_EnchantScanner.state    = "idle";
                _dbg("Roster update: queued " .. table.getn(newEntries) ..
                     " new player(s) for enchant scan");
            end
        end
        RAB_Core_RemoveTimer("CQEncRosterUpdate");
    end);
end);

-- ---------------------------------------------------------------------------
-- SLASH COMMANDS
-- ---------------------------------------------------------------------------
SLASH_CQENCHANT1 = "/cqenchant";
SLASH_CQENCHANT2 = "/cqenc";
SlashCmdList["CQENCHANT"] = function(msg)
    msg = string.lower(msg or "");

    if msg == "" or msg == "scan" then
        if not CQ_Log or not CQ_Log.isLogging then
            _info("|cffff9900No active raid session. Enchants will not be stored in the log.|r");
        end
        CQ_EnchantScanner:StartScan(false);

    elseif msg == "rescan" then
        _info("Force-rescanning all raid members...");
        CQ_EnchantScanner:StartScan(true);

    elseif msg == "status" then
        _info("=== ENCHANT SCANNER STATUS ===");
        _info("Scanning: "      .. tostring(CQ_EnchantScanner.scanning));
        _info("State: "         .. CQ_EnchantScanner.state);
        _info("Queue: "         .. table.getn(CQ_EnchantScanner.queue));
        _info("Retry queue: "   .. table.getn(CQ_EnchantScanner.retryQueue));
        local scannedCount = 0;
        for _ in pairs(CQ_EnchantScanner.sessionScanned) do scannedCount = scannedCount + 1 end;
        _info("Scanned this session: " .. scannedCount);
        _info("Raid logging active: " .. tostring(CQ_Log and CQ_Log.isLogging or false));

    elseif msg == "show" or msg == "report" then
        -- Print a quick summary to chat
        if not CQ_Log or not CQ_Log.currentRaidId or not CQui_RaidLogs then
            _info("No active raid log.");
            return;
        end
        local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
        if not raid or not raid.enchants then
            _info("No enchant data recorded yet.");
            return;
        end
        _info("=== ENCHANT REPORT (current raid) ===");
        local allOk, hasMissing = {}, {};
        for name, data in pairs(raid.enchants) do
            if table.getn(data.missing) > 0 then
                table.insert(hasMissing, name);
            else
                table.insert(allOk, name);
            end
        end
        table.sort(hasMissing); table.sort(allOk);
        for _, name in ipairs(hasMissing) do
            local data = raid.enchants[name];
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cffFF5555" .. name .. "|r missing: " ..
                table.concat(data.missing, ", "));
        end
        for _, name in ipairs(allOk) do
            DEFAULT_CHAT_FRAME:AddMessage("|cff55FF55" .. name .. "|r  fully enchanted");
        end
        if table.getn(hasMissing) == 0 and table.getn(allOk) == 0 then
            _info("No data yet — run /cqenc scan first.");
        end

    elseif msg == "retry" then
        if table.getn(CQ_EnchantScanner.retryQueue) == 0 then
            _info("Retry queue is empty.");
        else
            _info("Forcing retry of " .. table.getn(CQ_EnchantScanner.retryQueue) ..
                  " player(s)...");
            for _, e in ipairs(CQ_EnchantScanner.retryQueue) do
                table.insert(CQ_EnchantScanner.queue, e);
            end
            CQ_EnchantScanner.retryQueue = {};
            if not CQ_EnchantScanner.scanning then
                CQ_EnchantScanner.scanning = true;
                CQ_EnchantScanner.state    = "idle";
            end
        end

    elseif msg == "debug" then
        CQ_EnchantScanner.debug = not CQ_EnchantScanner.debug;
        DEFAULT_CHAT_FRAME:AddMessage("|cff88ccff[CQ Enchant]|r Debug " .. (CQ_EnchantScanner.debug and "ON" or "OFF"));

    elseif msg == "dump" then
        if not CQ_EncDB or not CQ_EncDB.learned or not next(CQ_EncDB.learned) then
            _info("No learned enchants yet.");
        else
            _info("Learned enchant IDs:");
            for id, name in pairs(CQ_EncDB.learned) do
                DEFAULT_CHAT_FRAME:AddMessage("  |cffFFFF00[" .. id .. "]|r = " .. name);
            end
        end

    elseif msg == "forget" then
        if CQ_EncDB then CQ_EncDB.learned = {} end;
        _info("Learned enchant database cleared.");

    elseif string.find(msg, "^name %d") then
        local _, _, idStr, enchName = string.find(msg, "^name (%d+)%s+(.+)");
        if idStr and enchName then
            local eid = tonumber(idStr);
            if not CQ_EncDB then CQ_EncDB = {} end;
            if not CQ_EncDB.learned then CQ_EncDB.learned = {} end;
            CQ_EncDB.learned[eid] = enchName;
            _info("Learned: |cffFFFF00[" .. eid .. "]|r = " .. enchName);
        else
            _info("Usage: /cqenc name <id> <enchant name>");
        end

    elseif msg == "help" then
        _info("/cqenc [scan]    — scan all raid members now");
        _info("/cqenc rescan    — force rescan (including already-scanned players)");
        _info("/cqenc report    — print enchant summary to chat");
        _info("/cqenc retry     — immediately retry out-of-range players");
        _info("/cqenc status    — scanner state / queue info");
        _info("/cqenc dump      — list all learned enchant IDs");
        _info("/cqenc forget    — clear learned enchant database");
        _info("/cqenc name <id> <n> — manually teach an enchant name");
        _info("/cqenc debug     — toggle debug output");

    else
        _info("Unknown command. Try /cqenc help");
    end
end

-- ---------------------------------------------------------------------------
-- INIT (saved variables bootstrap for CQ_EncDB)
-- ---------------------------------------------------------------------------
local _initFrame = CreateFrame("Frame");
_initFrame:RegisterEvent("PLAYER_LOGIN");
_initFrame:SetScript("OnEvent", function()
    if type(CQ_EncDB) ~= "table" then CQ_EncDB = {} end;
    if type(CQ_EncDB.learned) ~= "table" then CQ_EncDB.learned = {} end;
    this:UnregisterEvent("PLAYER_LOGIN");
end);
