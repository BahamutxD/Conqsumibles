-- Conq_core.lua
-- Standalone core shim for RABuffs Logger.
-- Replaces RAB_Core_Register / RAB_Core_AddTimer / RAB_Core_Unregister
-- so raidlog.lua, ConsumableIntegration.lua, etc. work without RABuffs.
--
-- All private names use RABL_ prefix to avoid collision with RABuffs when
-- both addons are loaded simultaneously.
--
-- Does NOT declare: RAB_Buffs, RABFrame, RAB_Spelltip, RAB_SpelltipTextLeft*,
--                   RAB_BuffTimers, RABuffs_Version, RABuffs_DeciVersion.

-- ---------------------------------------------------------------------------
-- Tooltip frame  (CQ_Spelltip / CQ_Frame)
-- raidlog.lua uses these to scan UnitBuff tooltip text.
-- Both names are private to the logger - no collision with RABuffs.xml frames.
-- ---------------------------------------------------------------------------
CQ_Frame = CreateFrame("Frame", "CQFrame", UIParent);
CQ_Frame:Hide();

CQ_Spelltip = CreateFrame("GameTooltip", "CQSpelltip", UIParent, "GameTooltipTemplate");
CQ_Spelltip:SetOwner(UIParent, "ANCHOR_NONE");
CQ_Spelltip:Hide();

-- The GameTooltipTemplate creates CQSpelltipTextLeft1 etc. globally.
CQ_SpelltipTextLeft1 = CQSpelltipTextLeft1;
CQ_SpelltipTextLeft2 = CQSpelltipTextLeft2;

-- ---------------------------------------------------------------------------
-- CQ_Print helper
-- RABuffs declares this too; if already present, leave it alone.
-- ---------------------------------------------------------------------------
if not CQ_Print then
    function CQ_Print(msg, kind)
        local color = "|cffffffff";
        if kind == "warn" then color = "|cffff9900"; end
        if kind == "ok"   then color = "|cff00ff00"; end
        DEFAULT_CHAT_FRAME:AddMessage(color .. "[Conq] " .. tostring(msg) .. "|r");
    end
end

-- ---------------------------------------------------------------------------
-- RAB_Core_* event/timer system
-- Only installed if RABuffs is absent. When RABuffs is loaded first these
-- are already present and fully functional - we must not overwrite them.
-- ---------------------------------------------------------------------------
if not RAB_Core_Register then

    local RLC = CreateFrame("Frame", "CQ_CoreFrame", UIParent);
    RLC.subscribers = {};
    RLC.timers = {};

    RLC:SetScript("OnEvent", function()
        local subs = this.subscribers[event];
        if subs == nil then return; end
        for key, func in subs do
            local ret = func();
            if ret == "remove" then
                subs[key] = nil;
            end
        end
    end);

    RLC:SetScript("OnUpdate", function()
        local dt = arg1;
        for _, t in RLC.timers do
            if t.enabled then
                t.accum = (t.accum or 0) + dt;
                if t.accum >= t.interval then
                    t.accum = t.accum - t.interval;
                    t.func();
                end
            end
        end
    end);

    function RAB_Core_Register(ev, key, func)
        if RLC.subscribers[ev] == nil then
            RLC:RegisterEvent(ev);
            RLC.subscribers[ev] = {};
        end
        RLC.subscribers[ev][key] = func;
    end

    function RAB_Core_Unregister(ev, key)
        if RLC.subscribers[ev] == nil then return; end
        RLC.subscribers[ev][key] = nil;
        local any = false;
        for _ in RLC.subscribers[ev] do any = true; break; end
        if not any then
            RLC.subscribers[ev] = nil;
            RLC:UnregisterEvent(ev);
        end
    end

    function RAB_Core_AddTimer(interval, key, func)
        for _, t in RLC.timers do
            if t.id == key then
                t.interval = interval;
                t.func     = func;
                t.enabled  = true;
                t.accum    = 0;
                return;
            end
        end
        table.insert(RLC.timers, {
            id       = key,
            interval = interval,
            func     = func,
            enabled  = true,
            accum    = 0,
        });
    end

    function RAB_Core_RemoveTimer(key)
        for i, t in RLC.timers do
            if t.id == key then
                RLC.timers[i] = nil;
                return;
            end
        end
    end

end -- if not RAB_Core_Register

-- ---------------------------------------------------------------------------
-- Saved variable bootstrap
-- ---------------------------------------------------------------------------
local svBootstrap = CreateFrame("Frame");
svBootstrap:RegisterEvent("PLAYER_LOGIN");
svBootstrap:SetScript("OnEvent", function()
    if type(CQui_RaidLogs) ~= "table" then
        CQui_RaidLogs = { raids = {}, version = "2.0.0" };
    end
    if type(CQui_RaidLogs.raids) ~= "table" then
        CQui_RaidLogs.raids = {};
    end
    if type(CQ_GuidDB) ~= "table" then
        CQ_GuidDB = {};
    end
    if type(CQui_Settings) ~= "table" then
        CQui_Settings = {};
    end
    this:UnregisterEvent("PLAYER_LOGIN");
end);
