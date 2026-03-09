-- Conq_MinimapButton.lua
-- Minimap button and Logger Config UI
-- Version 2.0 - Tabbed config window with live stats and full command reference

CQ_MinimapButton = {
    initialized = false,
    angle = 220,
    activeTab = "status",
};

-- ============================================================================
-- SETTINGS PERSISTENCE
--
-- We save user-configurable options into CQui_Settings.raidLogSettings.
-- CQui_Settings IS a SavedVariable (declared in core.lua) so it survives reloads.
--
-- RAB_StartUp() (fires on VARIABLES_LOADED) strips any key from CQui_Settings
-- that is not present in CQui_DefSettings.  To protect our key we inject
-- raidLogSettings into CQui_DefSettings here at file-load time, which is
-- guaranteed to run before VARIABLES_LOADED fires.
--
-- We cannot use CQui_RaidLogs because raidlog.lua may reinitialize it on
-- every login, destroying any .settings key we wrote there.
--
-- Load timing: restore on PLAYER_ENTERING_WORLD so raidlog.lua's own
-- PLAYER_LOGIN handler has already run and set CQ_Log defaults first.
-- ============================================================================

-- Standalone: CQui_Settings is our own SavedVariable (declared in the .toc).
-- No CQui_DefSettings / RAB_StartUp exists to strip keys, so we just ensure
-- the table is initialised.  The PLAYER_LOGIN bootstrap in Conq_core.lua
-- handles the nil-check, but we guard here too in case load order varies.
if type(CQui_Settings) ~= "table" then
    CQui_Settings = {};
end

local CQ_PersistedKeys = {
    "trackOutOfCombat",
    "trackLoot",
    "trackDeaths",
    "trackSunders",
    "trackLootQualities",
    "trackedItems",
    "exportFormat",
    "verboseExport",
    "autoExportInterval",
    "checkInterval",
    "trackedZones",
};

function CQ_Settings_Save()
    if not CQ_Log then return; end
    if type(CQui_Settings) ~= "table" then return; end
    if type(CQui_Settings.raidLogSettings) ~= "table" then
        CQui_Settings.raidLogSettings = {};
    end

    for _, k in ipairs(CQ_PersistedKeys) do
        local v = CQ_Log[k];
        if type(v) == "table" then
            local copy = {};
            for tk, tv in pairs(v) do copy[tk] = tv; end
            CQui_Settings.raidLogSettings[k] = copy;
        else
            CQui_Settings.raidLogSettings[k] = v;
        end
    end
end

function CQ_Settings_Load()
    if not CQ_Log then return; end
    if type(CQui_Settings) ~= "table" then return; end
    if type(CQui_Settings.raidLogSettings) ~= "table" then return; end

    local s = CQui_Settings.raidLogSettings;
    for _, k in ipairs(CQ_PersistedKeys) do
        if s[k] ~= nil then
            if type(s[k]) == "table" then
                local copy = {};
                for tk, tv in pairs(s[k]) do copy[tk] = tv; end
                CQ_Log[k] = copy;
            else
                CQ_Log[k] = s[k];
            end
        end
    end

    -- Sync trackedZones back into ValidZones so auto-start logic sees the changes.
    if CQ_Log.trackedZones and CQ_Log_ValidZones then
        -- First, clear any existing entries then re-add only enabled ones.
        for z in pairs(CQ_Log_ValidZones) do
            CQ_Log_ValidZones[z] = nil;
        end
        for z, enabled in pairs(CQ_Log.trackedZones) do
            if enabled then
                CQ_Log_ValidZones[z] = true;
            end
        end
    end
end

-- ============================================================================
-- HELPER: Start / Stop wrappers
-- ============================================================================

function CQ_MinimapButton_StartLogging()
    if not CQ_Log then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[Conq] Conq_raidlog.lua failed to load - check for errors on login.|r");
        return;
    end
    if CQ_Log.isLogging then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[Conq] Already logging|r");
        return;
    end
    CQ_Log.isPendingCombat = false;
    CQ_Log.isLogging = true;
    local zone = GetRealZoneText() or "Unknown";
    if not CQ_Log.currentZone then CQ_Log.currentZone = zone; end
    if CQ_Log_InitializeRaid then CQ_Log_InitializeRaid(); end
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Conq] Logging started in " .. zone .. "|r");
end

function CQ_MinimapButton_StopLogging()
    if not CQ_Log then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[Conq] Conq_raidlog.lua failed to load - check for errors on login.|r");
        return;
    end
    if CQ_Log.isLogging then
        if CQ_Log_FinalizeRaid then CQ_Log_FinalizeRaid(); end
        CQ_Log.currentZone = nil;
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Conq] Logging stopped.|r");
    elseif CQ_Log.isPendingCombat then
        CQ_Log.isPendingCombat = false;
        CQ_Log.currentZone = nil;
        DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[Conq] Pending combat cancelled.|r");
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[Conq] Not currently logging.|r");
    end
end

-- ============================================================================
-- MINIMAP BUTTON
-- ============================================================================

function CQ_MinimapButton_Init()
    if CQ_MinimapButton.initialized then return; end

    local button = CreateFrame("Button", "CQ_MinimapButton_Frame", Minimap);
    button:SetWidth(31);
    button:SetHeight(31);
    button:SetFrameStrata("MEDIUM");
    button:SetFrameLevel(8);
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight");
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp");

    local icon = button:CreateTexture("CQ_MinimapButton_Icon", "BACKGROUND");
    icon:SetWidth(20);
    icon:SetHeight(20);
    icon:SetTexture("Interface\\Icons\\INV_Misc_Note_06");
    icon:SetPoint("CENTER", 1, 1);

    local border = button:CreateTexture("CQ_MinimapButton_Border", "OVERLAY");
    border:SetWidth(52);
    border:SetHeight(52);
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder");
    border:SetPoint("TOPLEFT", 0, 0);

    CQ_MinimapButton_UpdatePosition();

    button:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT");
        GameTooltip:AddLine("Conqsumibles", 0.0, 0.831, 1.0);
        GameTooltip:AddLine("Conquistadores Raid Logger", 0.6, 0.6, 0.6);
        GameTooltip:AddLine(" ");
        if CQ_Log and CQ_Log.isLogging then
            GameTooltip:AddLine("Logging:  |cff00ff00ACTIVE|r", 0.9, 0.9, 0.9);
            GameTooltip:AddLine("Zone:  " .. (CQ_Log.currentZone or "?"), 0.7, 0.7, 0.7);
            if CQ_Log.inCombat then
                GameTooltip:AddLine("Combat:  |cffff4444IN COMBAT|r", 0.9, 0.9, 0.9);
            end
        elseif CQ_Log and CQ_Log.isPendingCombat then
            GameTooltip:AddLine("Logging:  |cffff9900PENDING COMBAT|r", 0.9, 0.9, 0.9);
        else
            GameTooltip:AddLine("Logging:  |cff666666INACTIVE|r", 0.9, 0.9, 0.9);
        end
        -- Live sunder count
        if CQ_Log and CQ_Log.isLogging and CQ_Log.currentRaidId and CQui_RaidLogs then
            local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
            if raid and raid.spells then
                local total = 0;
                for _, spells in pairs(raid.spells) do
                    if spells["sunder_armor"] then
                        total = total + (spells["sunder_armor"].count or 0);
                    end
                end
                if total > 0 then
                    GameTooltip:AddLine("Sunders:  |cff88ccff" .. total .. "|r", 0.9, 0.9, 0.9);
                end
            end
        end
        GameTooltip:AddLine(" ");
        GameTooltip:AddLine("|cffaaaaaa[Left-Click]|r   Open Config", 0.8, 0.8, 0.8);
        GameTooltip:AddLine("|cffaaaaaa[Right-Click]|r  Toggle Logging", 0.8, 0.8, 0.8);
        GameTooltip:AddLine("|cffaaaaaa[Shift+Click]|r  Export Now", 0.8, 0.8, 0.8);
        GameTooltip:AddLine("|cffaaaaaa[Drag]|r          Move Button", 0.8, 0.8, 0.8);
        GameTooltip:Show();
    end);

    button:SetScript("OnLeave", function() GameTooltip:Hide(); end);

    button:SetScript("OnClick", function()
        if IsShiftKeyDown() then
            if CQ_Log and CQ_Log.hasFileExport then
                if CQ_Log_ExportToFile and CQ_Log_ExportToFile(false) then
                    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Conq] Raid data exported!|r");
                end
            else
                DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[Conq] Export requires Nampower WriteCustomFile (v3.2.0+)|r");
            end
        elseif arg1 == "RightButton" then
            if CQ_Log and CQ_Log.isLogging then
                CQ_MinimapButton_StopLogging();
            else
                CQ_MinimapButton_StartLogging();
            end
        else
            CQ_Config_Toggle();
        end
    end);

    button.isDragging = false;
    button:RegisterForDrag("LeftButton");
    button:SetScript("OnDragStart", function()
        this:LockHighlight();
        this.isDragging = true;
    end);
    button:SetScript("OnDragStop", function()
        this:UnlockHighlight();
        this.isDragging = false;
    end);
    button:SetScript("OnUpdate", function()
        if this.isDragging then
            local xpos, ypos = GetCursorPosition();
            local xmin, ymin = Minimap:GetLeft(), Minimap:GetBottom();
            xpos = xmin - xpos / UIParent:GetScale() + 70;
            ypos = ypos / UIParent:GetScale() - ymin - 70;
            CQ_MinimapButton.angle = math.deg(math.atan2(ypos, xpos));
            CQ_MinimapButton_UpdatePosition();
        end
    end);

    CQ_MinimapButton.initialized = true;
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Conq] Minimap button loaded. Left-click to open config.|r");
end

function CQ_MinimapButton_UpdatePosition()
    local angle = math.rad(CQ_MinimapButton.angle);
    local x = math.cos(angle) * 80;
    local y = math.sin(angle) * 80;
    local button = getglobal("CQ_MinimapButton_Frame");
    if button then
        button:SetPoint("CENTER", Minimap, "CENTER", x, y);
    end
end

-- ============================================================================
-- LAYOUT CONSTANTS
-- ============================================================================

local FRAME_W     = 560;
local FRAME_H     = 640;
local CONTENT_W   = 528;
local CONTENT_LEFT  = 14;
local CONTENT_TOP   = -80;   -- y offset from frame top where tab content starts
local TAB_W       = 84;
local TAB_H       = 22;

-- ============================================================================
-- SHARED WIDGET HELPERS
-- ============================================================================

-- ============================================================================
-- CUSTOM BUTTON / CHECKBOX / EDITBOX SKINNING  (JSX design system)
-- ============================================================================

-- Colour palette (Reclutadores-inspired: lighter, more readable dark theme)
local CQ_C = {
    bg       = { 0.09,  0.11,  0.15  },  -- main frame bg: visible dark blue-grey
    surface  = { 0.12,  0.15,  0.21  },  -- card/section bg: slightly lighter
    elevated = { 0.17,  0.21,  0.30  },  -- hover/elevated surface
    border   = { 0.22,  0.30,  0.42  },  -- visible borders
    accent   = { 0.0,   0.831, 1.0   },  -- #00d4ff  (unchanged)
    accentDm = { 0.0,   0.4,   0.5   },  -- dim accent (unchanged)
    green    = { 0.0,   0.902, 0.463 },  -- unchanged
    red      = { 1.0,   0.322, 0.322 },  -- unchanged
    muted    = { 0.55,  0.60,  0.68  },  -- brighter muted text
    white    = { 0.95,  0.96,  0.97  },  -- near-white labels
};

-- Apply RAB skin to a plain Button frame.
--   style: "primary" | "ghost" | "danger" | "green"
-- Uses explicit border textures instead of SetBackdrop edgeFile (unreliable in 1.12).
local function CQ_SkinButton(btn, style)
    local s = style or "ghost";

    -- ── Colour definitions ──────────────────────────────────────────────────
    -- bgR/G/B/A  : fill colour
    -- bdR/G/B    : border colour (full alpha applied separately)
    -- txR/G/B    : label text colour
    local bgR,bgG,bgB,bgA, bdR,bdG,bdB, txR,txG,txB;

    if s == "green" then
        bgR,bgG,bgB,bgA = 0.0,  0.12, 0.04, 1;
        bdR,bdG,bdB     = 0.0,  0.70, 0.25;
        txR,txG,txB     = CQ_C.green[1], CQ_C.green[2], CQ_C.green[3];
    elseif s == "danger" or s == "stop" then
        bgR,bgG,bgB,bgA = 0.12, 0.0,  0.0,  1;
        bdR,bdG,bdB     = 0.75, 0.15, 0.15;
        txR,txG,txB     = 1.0,  0.45, 0.45;
    elseif s == "primary" then
        bgR,bgG,bgB,bgA = 0.0,  0.10, 0.14, 1;
        bdR,bdG,bdB     = CQ_C.accentDm[1], CQ_C.accentDm[2], CQ_C.accentDm[3];
        txR,txG,txB     = CQ_C.accent[1], CQ_C.accent[2], CQ_C.accent[3];
    else -- ghost
        bgR,bgG,bgB,bgA = 0.13, 0.17, 0.24, 1;
        bdR,bdG,bdB     = 0.30, 0.40, 0.55;
        txR,txG,txB     = 0.85, 0.90, 0.95;
    end

    -- ── Background fill via SetBackdrop (bgFile only, no edge) ─────────────
    btn:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        tile = true, tileSize = 16,
        insets = { left=0, right=0, top=0, bottom=0 }
    });
    btn:SetBackdropColor(bgR, bgG, bgB, bgA);

    -- ── 1-px border: four explicit line textures ────────────────────────────
    -- Store on btn so hover scripts can recolour them.
    local bT = btn:CreateTexture(nil,"OVERLAY"); bT:SetHeight(1);
        bT:SetPoint("TOPLEFT",btn,"TOPLEFT",0,0); bT:SetPoint("TOPRIGHT",btn,"TOPRIGHT",0,0);
    local bB = btn:CreateTexture(nil,"OVERLAY"); bB:SetHeight(1);
        bB:SetPoint("BOTTOMLEFT",btn,"BOTTOMLEFT",0,0); bB:SetPoint("BOTTOMRIGHT",btn,"BOTTOMRIGHT",0,0);
    local bL = btn:CreateTexture(nil,"OVERLAY"); bL:SetWidth(1);
        bL:SetPoint("TOPLEFT",btn,"TOPLEFT",0,0); bL:SetPoint("BOTTOMLEFT",btn,"BOTTOMLEFT",0,0);
    local bR = btn:CreateTexture(nil,"OVERLAY"); bR:SetWidth(1);
        bR:SetPoint("TOPRIGHT",btn,"TOPRIGHT",0,0); bR:SetPoint("BOTTOMRIGHT",btn,"BOTTOMRIGHT",0,0);
    btn._bdrTx = { bT, bB, bL, bR };

    local function SetBorder(r,g,b,a)
        bT:SetTexture(r,g,b,a or 1); bB:SetTexture(r,g,b,a or 1);
        bL:SetTexture(r,g,b,a or 1); bR:SetTexture(r,g,b,a or 1);
    end
    SetBorder(bdR, bdG, bdB, 0.9);

    -- ── Label colour ────────────────────────────────────────────────────────
    local fs = btn:GetFontString();
    if fs then fs:SetTextColor(txR, txG, txB); end

    -- ── Hover / pressed feedback ────────────────────────────────────────────
    local prevEnter = btn:GetScript("OnEnter");
    local prevLeave = btn:GetScript("OnLeave");
    local prevDown  = btn:GetScript("OnMouseDown");
    local prevUp    = btn:GetScript("OnMouseUp");

    btn:SetScript("OnEnter", function()
        if s == "green" then
            btn:SetBackdropColor(0.0, 0.20, 0.07, 1);
            SetBorder(CQ_C.green[1], CQ_C.green[2], CQ_C.green[3], 1.0);
        elseif s == "danger" or s == "stop" then
            btn:SetBackdropColor(0.20, 0.0, 0.0, 1);
            SetBorder(CQ_C.red[1], CQ_C.red[2], CQ_C.red[3], 1.0);
            local fs2 = btn:GetFontString(); if fs2 then fs2:SetTextColor(1.0, 0.6, 0.6); end
        elseif s == "primary" then
            btn:SetBackdropColor(0.0, 0.16, 0.22, 1);
            SetBorder(CQ_C.accent[1], CQ_C.accent[2], CQ_C.accent[3], 1.0);
        else
            btn:SetBackdropColor(0.18, 0.22, 0.32, 1);
            SetBorder(0.55, 0.65, 0.80, 1.0);
            local fs2 = btn:GetFontString(); if fs2 then fs2:SetTextColor(0.92, 0.95, 1.0); end
        end
        if prevEnter then prevEnter(); end
    end);
    btn:SetScript("OnLeave", function()
        btn:SetBackdropColor(bgR, bgG, bgB, bgA);
        SetBorder(bdR, bdG, bdB, 0.9);
        local fs2 = btn:GetFontString(); if fs2 then fs2:SetTextColor(txR, txG, txB); end
        if prevLeave then prevLeave(); end
    end);
    btn:SetScript("OnMouseDown", function()
        btn:SetBackdropColor(bgR*0.6, bgG*0.6, bgB*0.6, 1);
        if prevDown then prevDown(); end
    end);
    btn:SetScript("OnMouseUp", function()
        btn:SetBackdropColor(bgR, bgG, bgB, bgA);
        if prevUp then prevUp(); end
    end);
end

-- Custom checkbox: draws a small box + tick without using OptionsCheckButtonTemplate.
-- Returns the CheckButton. Use cb:GetChecked() / cb:SetChecked() as normal.
-- Visual sync is driven entirely by OnClick; call RAB_SkinCheckbox_Sync(cb) after
-- programmatic SetChecked calls to keep the artwork in step.
local function CQ_SkinCheckbox(cb)
    -- Erase every built-in CheckButton texture Blizzard draws automatically
    cb:SetCheckedTexture("");
    cb:SetNormalTexture("");
    cb:SetHighlightTexture("");
    cb:SetDisabledCheckedTexture("");
    if cb.SetPushedTexture then cb:SetPushedTexture(""); end

    local BOX = 14;
    cb:SetWidth(BOX); cb:SetHeight(BOX);

    -- BACKGROUND layer: dark fill quad (full BOXxBOX)
    local fill = cb:CreateTexture(nil, "BACKGROUND");
    fill:SetWidth(BOX); fill:SetHeight(BOX);
    fill:SetPoint("CENTER", cb, "CENTER", 0, 0);
    fill:SetTexture(CQ_C.surface[1], CQ_C.surface[2], CQ_C.surface[3], 1);

    -- ARTWORK layer: four 1-px border lines (sit above fill, below tick)
    local bT = cb:CreateTexture(nil,"ARTWORK"); bT:SetHeight(1);
        bT:SetPoint("TOPLEFT",cb,"TOPLEFT",0,0);
        bT:SetPoint("TOPRIGHT",cb,"TOPRIGHT",0,0);
    local bBo = cb:CreateTexture(nil,"ARTWORK"); bBo:SetHeight(1);
        bBo:SetPoint("BOTTOMLEFT",cb,"BOTTOMLEFT",0,0);
        bBo:SetPoint("BOTTOMRIGHT",cb,"BOTTOMRIGHT",0,0);
    local bL = cb:CreateTexture(nil,"ARTWORK"); bL:SetWidth(1);
        bL:SetPoint("TOPLEFT",cb,"TOPLEFT",0,0);
        bL:SetPoint("BOTTOMLEFT",cb,"BOTTOMLEFT",0,0);
    local bR = cb:CreateTexture(nil,"ARTWORK"); bR:SetWidth(1);
        bR:SetPoint("TOPRIGHT",cb,"TOPRIGHT",0,0);
        bR:SetPoint("BOTTOMRIGHT",cb,"BOTTOMRIGHT",0,0);

    local function SetBoxBorder(r,g,b,a)
        local al = a or 1;
        bT:SetTexture(r,g,b,al); bBo:SetTexture(r,g,b,al);
        bL:SetTexture(r,g,b,al); bR:SetTexture(r,g,b,al);
    end

    -- OVERLAY layer: tick — small centered quad, 8x8 so borders stay visible
    local tick = cb:CreateTexture(nil, "OVERLAY");
    tick:SetWidth(8); tick:SetHeight(8);
    tick:SetPoint("CENTER", cb, "CENTER", 0, 0);
    tick:SetTexture(CQ_C.green[1], CQ_C.green[2], CQ_C.green[3], 1);
    tick:Hide();

    local function ApplyVisual(isChecked)
        if isChecked then
            tick:Show();
            fill:SetTexture(0.0, 0.16, 0.07, 1);
            SetBoxBorder(0.0, 0.78, 0.30, 1.0);
        else
            tick:Hide();
            fill:SetTexture(CQ_C.surface[1], CQ_C.surface[2], CQ_C.surface[3], 1);
            SetBoxBorder(CQ_C.border[1], CQ_C.border[2], CQ_C.border[3], 0.9);
        end
    end

    -- Sync visuals from the actual C-side checked state.
    cb.CQ_SyncVisual = function()
        ApplyVisual(cb:GetChecked() and true or false);
    end;

    -- In 1.12, OnClick fires before the C state flips for some checkbox types,
    -- and after for others. Use a one-frame OnUpdate defer to read GetChecked()
    -- after the engine has settled, which is always correct regardless of timing.
    local pending = false;
    local ticker = CreateFrame("Frame");
    ticker:SetScript("OnUpdate", function()
        if pending then
            pending = false;
            ApplyVisual(cb:GetChecked() and true or false);
        end
    end);

    local prevOnClick = cb:GetScript("OnClick");
    cb:SetScript("OnClick", function()
        pending = true;
        if prevOnClick then prevOnClick(); end
    end);

    cb:SetScript("OnEnter", function()
        SetBoxBorder(CQ_C.accent[1], CQ_C.accent[2], CQ_C.accent[3], 0.9);
    end);
    cb:SetScript("OnLeave", function()
        cb.CQ_SyncVisual();
    end);

    -- Sync immediately so initial state is correct
    cb.CQ_SyncVisual();

    return fill, nil, tick;
end

-- Skin an EditBox (replace InputBoxTemplate visuals)
-- Call BEFORE setting any OnEditFocusGained/Lost scripts on the editbox,
-- because this function sets those scripts and individual setup will chain onto them.
local function CQ_SkinEditBox(eb)
    eb:EnableMouse(true);
    eb:EnableKeyboard(true);
    eb:SetAutoFocus(false);
    -- A plain EditBox has no font by default — text won't display without this
    eb:SetFontObject(GameFontHighlightSmall);
    if eb.SetTextInsets then eb:SetTextInsets(4,4,2,2); end
    eb:SetTextColor(CQ_C.white[1], CQ_C.white[2], CQ_C.white[3]);

    -- Clicking the box grabs focus; Escape releases it
    eb:SetScript("OnMouseDown", function() eb:SetFocus(); end);
    eb:SetScript("OnEscapePressed", function() eb:ClearFocus(); end);

    -- Fill via SetBackdrop (bgFile only)
    eb:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        tile = true, tileSize = 16,
        insets = { left=0, right=0, top=0, bottom=0 }
    });
    eb:SetBackdropColor(0.09, 0.12, 0.18, 1);

    -- Explicit 1px border textures
    local eT = eb:CreateTexture(nil,"OVERLAY"); eT:SetHeight(1);
        eT:SetPoint("TOPLEFT",eb,"TOPLEFT",0,0); eT:SetPoint("TOPRIGHT",eb,"TOPRIGHT",0,0);
    local eB = eb:CreateTexture(nil,"OVERLAY"); eB:SetHeight(1);
        eB:SetPoint("BOTTOMLEFT",eb,"BOTTOMLEFT",0,0); eB:SetPoint("BOTTOMRIGHT",eb,"BOTTOMRIGHT",0,0);
    local eL = eb:CreateTexture(nil,"OVERLAY"); eL:SetWidth(1);
        eL:SetPoint("TOPLEFT",eb,"TOPLEFT",0,0); eL:SetPoint("BOTTOMLEFT",eb,"BOTTOMLEFT",0,0);
    local eR = eb:CreateTexture(nil,"OVERLAY"); eR:SetWidth(1);
        eR:SetPoint("TOPRIGHT",eb,"TOPRIGHT",0,0); eR:SetPoint("BOTTOMRIGHT",eb,"BOTTOMRIGHT",0,0);

    -- Store setter on the frame so the focus scripts below can call it
    local function SetEBBorder(r,g,b,a)
        local al = a or 1;
        eT:SetTexture(r,g,b,al); eB:SetTexture(r,g,b,al);
        eL:SetTexture(r,g,b,al); eR:SetTexture(r,g,b,al);
    end
    eb._SetBorder = SetEBBorder;
    SetEBBorder(CQ_C.border[1], CQ_C.border[2], CQ_C.border[3], 0.9);

    -- Set focus scripts now; individual setup code that runs AFTER this call
    -- must chain via prevFocusGained/Lost pattern (which it already does).
    eb:SetScript("OnEditFocusGained", function()
        eb._SetBorder(CQ_C.accent[1], CQ_C.accent[2], CQ_C.accent[3], 1.0);
        eb.hasFocus = true;
    end);
    eb:SetScript("OnEditFocusLost", function()
        eb._SetBorder(CQ_C.border[1], CQ_C.border[2], CQ_C.border[3], 0.9);
        eb.hasFocus = false;
    end);
end

-- Skin a scroll frame created with UIPanelScrollFrameTemplate.
-- Hides Blizzard art and draws a minimal dark track + cyan thumb.
local function CQ_SkinScrollFrame(sf, sfName)
    local sbName = sfName .. "ScrollBar";
    local sb = getglobal(sbName);
    if not sb then return; end

    -- Hide the track background Blizzard draws on the scrollbar
    sb:SetBackdrop(nil);

    -- Up / Down buttons: replace textures with plain arrows
    local upBtn   = getglobal(sbName .. "ScrollUpButton");
    local downBtn = getglobal(sbName .. "ScrollDownButton");

    local function SkinArrowBtn(btn, dy)
        if not btn then return; end
        btn:SetNormalTexture(""); btn:SetPushedTexture("");
        btn:SetHighlightTexture(""); btn:SetDisabledTexture("");
        btn:SetWidth(12); btn:SetHeight(12);
        -- Plain coloured quad for arrow indicator
        local bg = btn:CreateTexture(nil,"BACKGROUND");
        bg:SetAllPoints(); bg:SetTexture(0.11, 0.14, 0.20, 1);
        local arrow = btn:CreateTexture(nil,"OVERLAY");
        arrow:SetWidth(6); arrow:SetHeight(6);
        arrow:SetPoint("CENTER", btn, "CENTER", 0, 0);
        arrow:SetTexture(0.25, 0.40, 0.55, 1);
        btn:SetScript("OnEnter", function() arrow:SetTexture(CQ_C.accent[1],CQ_C.accent[2],CQ_C.accent[3],1); end);
        btn:SetScript("OnLeave", function() arrow:SetTexture(0.25, 0.40, 0.55, 1); end);
    end
    SkinArrowBtn(upBtn,   1);
    SkinArrowBtn(downBtn, -1);

    -- Thumb texture
    local thumb = getglobal(sbName .. "ThumbTexture");
    if thumb then
        thumb:SetTexture(0.0, 0.45, 0.60, 0.85);
        thumb:SetWidth(8);
    end

    -- Track background: thin dark strip behind the scrollbar
    local track = sb:CreateTexture(nil, "BACKGROUND");
    track:SetWidth(8);
    track:SetPoint("TOP",    sb, "TOP",    0, -12);
    track:SetPoint("BOTTOM", sb, "BOTTOM", 0,  12);
    track:SetTexture(0.12, 0.15, 0.22, 1);

    -- Track border lines (left + right only)
    local tL = sb:CreateTexture(nil,"ARTWORK"); tL:SetWidth(1);
        tL:SetPoint("TOP",sb,"TOP",-4,-12); tL:SetPoint("BOTTOM",sb,"BOTTOM",-4,12);
    local tR = sb:CreateTexture(nil,"ARTWORK"); tR:SetWidth(1);
        tR:SetPoint("TOP",sb,"TOP",4,-12); tR:SetPoint("BOTTOM",sb,"BOTTOM",4,12);
    tL:SetTexture(CQ_C.border[1],CQ_C.border[2],CQ_C.border[3],0.7);
    tR:SetTexture(CQ_C.border[1],CQ_C.border[2],CQ_C.border[3],0.7);
end


local function MkHeader(parent, text, anchorFrame, anchorPoint, xOff, yOff)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal");
    fs:SetPoint("TOPLEFT", anchorFrame, anchorPoint or "BOTTOMLEFT", xOff or 0, yOff or -12);
    fs:SetText("|cff00d4ff" .. text .. "|r");
    local line = parent:CreateTexture(nil, "OVERLAY");
    line:SetWidth(CONTENT_W - 4);
    line:SetHeight(1);
    line:SetPoint("TOPLEFT", fs, "BOTTOMLEFT", 0, -3);
    line:SetTexture(0.0, 0.55, 0.70, 0.70);
    return fs, line;
end

local function MkSmall(parent, text, anchor, ap, xOff, yOff, w)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall");
    fs:SetPoint("TOPLEFT", anchor, ap or "BOTTOMLEFT", xOff or 0, yOff or -5);
    fs:SetWidth(w or (CONTENT_W - 6));
    fs:SetJustifyH("LEFT");
    fs:SetText(text);
    return fs;
end

local function MkBtn(parent, name, w, h, label, anchor, ap, xOff, yOff, style)
    local btn = CreateFrame("Button", name, parent);
    btn:SetWidth(w or 130);
    btn:SetHeight(h or 22);
    btn:SetPoint("TOPLEFT", anchor, ap or "BOTTOMLEFT", xOff or 0, yOff or -8);
    local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall");
    fs:SetAllPoints(); fs:SetJustifyH("CENTER"); fs:SetText(label);
    btn:SetFontString(fs);
    CQ_SkinButton(btn, style or "ghost");
    return btn;
end

local function MkCheck(parent, name, label, anchor, ap, xOff, yOff)
    local cb = CreateFrame("CheckButton", name, parent);
    cb:SetWidth(14); cb:SetHeight(14);
    cb:SetPoint("TOPLEFT", anchor, ap or "BOTTOMLEFT", xOff or 0, yOff or -5);
    CQ_SkinCheckbox(cb);
    -- Label sits to the right
    local lbl = parent:CreateFontString(name.."Text", "OVERLAY", "GameFontHighlightSmall");
    lbl:SetPoint("LEFT", cb, "RIGHT", 6, 0);
    lbl:SetText(label);
    lbl:SetTextColor(CQ_C.white[1], CQ_C.white[2], CQ_C.white[3]);
    return cb;
end

-- ============================================================================
-- TAB: STATUS
-- ============================================================================

-- Auto-refresh ticker for the live stats panel
local CQ_StatsRefreshFrame = CreateFrame("Frame");
CQ_StatsRefreshFrame.elapsed = 0;
CQ_StatsRefreshFrame.interval = 5; -- seconds between auto-refreshes
CQ_StatsRefreshFrame:SetScript("OnUpdate", function()
    CQ_StatsRefreshFrame.elapsed = CQ_StatsRefreshFrame.elapsed + arg1;
    if CQ_StatsRefreshFrame.elapsed >= CQ_StatsRefreshFrame.interval then
        CQ_StatsRefreshFrame.elapsed = 0;
        local frame = getglobal("CQ_ConfigFrame");
        if frame and frame:IsShown() and CQ_MinimapButton.activeTab == "status" then
            CQ_Config_UpdateStats();
        end
    end
end);

-- Format copper into "Xg Ys Zc"
local function FormatMoney(copper)
    local g = math.floor(copper / 10000);
    local s = math.floor(math.mod(copper, 10000) / 100);
    local c = math.mod(copper, 100);
    if g > 0 then
        return "|cffffcc00" .. g .. "g|r |cffc0c0c0" .. s .. "s|r |cffcd7f32" .. c .. "c|r";
    elseif s > 0 then
        return "|cffc0c0c0" .. s .. "s|r |cffcd7f32" .. c .. "c|r";
    else
        return "|cffcd7f32" .. c .. "c|r";
    end
end

-- Format seconds into "Xh Ym Zs" or "Ym Zs"
local function FormatDuration(secs)
    local h = math.floor(secs / 3600);
    local m = math.floor(math.mod(secs, 3600) / 60);
    local s = math.mod(secs, 60);
    if h > 0 then
        return h .. "h " .. m .. "m " .. s .. "s";
    else
        return m .. "m " .. s .. "s";
    end
end

local function CreateStatusTab(parent)
    local tab = CreateFrame("Frame", "CQ_Tab_Status", parent);
    tab:SetWidth(CONTENT_W);
    tab:SetHeight(FRAME_H - 90);
    tab:SetPoint("TOPLEFT", parent, "TOPLEFT", CONTENT_LEFT, CONTENT_TOP);
    tab:Hide();

    -- ================================================================
    -- Dimensions  (tab height = FRAME_H - 90 = 550px)
    -- ================================================================
    -- BANNER_H  : 74px  — 3 stacked buttons fit without overflow
    -- STRIP_H   : 48px  — large stat chips (Players/Deaths/Loot/Duration)
    -- BODY_GAP  : 10px  — clear visual separation below strip
    -- TOP_USED  : 132px
    -- BODY      : 418px — 5 panels, no scrollframe needed
    --
    -- Layout:
    --   GAP  (10px)
    --   ROW 1 (2-col, 168px): Sunder Armor | Recent Deaths
    --   RULE (1px)
    --   ROW 2 (full,  100px): Notable Loot
    --   RULE (1px)
    --   ROW 3 (2-col,  80px): Potions & Consumables | Money Drops
    --   Total: 10+168+1+100+1+80 = 360px  (58px breathing room)
    -- ================================================================
    local BANNER_H = 74;   -- 3 buttons × 17px + gaps + top margin = 74px
    local STRIP_H  = 48;   -- taller strip for stat chips
    local TOP_USED = BANNER_H + STRIP_H;  -- 122px
    local BTN_W    = 80;
    local BTN_H    = 17;

    -- ================================================================
    -- BANNER: status info left, buttons right
    -- ================================================================
    local banner = tab:CreateTexture(nil, "BACKGROUND");
    banner:SetWidth(CONTENT_W); banner:SetHeight(BANNER_H);
    banner:SetPoint("TOPLEFT", 0, 0);
    banner:SetTexture(0.06, 0.09, 0.14, 1.0);

    -- Subtle left accent bar on banner
    local accentBar = tab:CreateTexture(nil, "OVERLAY");
    accentBar:SetWidth(2); accentBar:SetHeight(BANNER_H - 12);
    accentBar:SetPoint("TOPLEFT", 0, -6);
    accentBar:SetTexture(0.0, 0.831, 1.0, 0.7);

    local statusLabel = tab:CreateFontString("CQ_Status_Label", "OVERLAY", "GameFontNormal");
    statusLabel:SetPoint("TOPLEFT", 10, -9);
    statusLabel:SetText("|cff778899\xE2\x97\x8F INACTIVE|r");

    local statusZone = tab:CreateFontString("CQ_Status_Zone", "OVERLAY", "GameFontHighlightSmall");
    statusZone:SetPoint("TOPLEFT", statusLabel, "BOTTOMLEFT", 0, -4);
    statusZone:SetWidth(CONTENT_W - BTN_W - 24);
    statusZone:SetJustifyH("LEFT");
    statusZone:SetText("|cff445566Enter a tracked zone to begin.|r");

    local statusRaid = tab:CreateFontString("CQ_Status_RaidID", "OVERLAY", "GameFontHighlightSmall");
    statusRaid:SetPoint("TOPLEFT", statusZone, "BOTTOMLEFT", 0, -3);
    statusRaid:SetWidth(CONTENT_W - BTN_W - 24);
    statusRaid:SetJustifyH("LEFT");
    statusRaid:SetText("");

    local swStatus = tab:CreateFontString("CQ_Status_SW", "OVERLAY", "GameFontHighlightSmall");
    swStatus:SetPoint("TOPLEFT", statusRaid, "BOTTOMLEFT", 0, -2);
    swStatus:SetWidth(CONTENT_W - BTN_W - 24);
    swStatus:SetJustifyH("LEFT");
    if CQ_Log and CQ_Log.hasFileExport then
        swStatus:SetText("|cff00cc00Export: enabled|r");
    else
        swStatus:SetText("|cff445566Export: not available|r");
    end

    -- hidden ToggleBtn (required by CQ_Config_Update)
    local toggleBtn = CreateFrame("Button", "CQ_Status_ToggleBtn", tab);
    toggleBtn:SetWidth(1); toggleBtn:SetHeight(1);
    toggleBtn:SetPoint("TOPRIGHT", -200, -8);
    toggleBtn:Hide();

    -- right-side buttons: Start / Stop / Export stacked
    local startBtn = CreateFrame("Button", "CQ_Status_StartBtn", tab);
    startBtn:SetWidth(BTN_W); startBtn:SetHeight(BTN_H);
    startBtn:SetPoint("TOPRIGHT", -4, -8);
    do local _fs = startBtn:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); _fs:SetAllPoints(); _fs:SetJustifyH("CENTER"); _fs:SetText("Start"); startBtn:SetFontString(_fs); CQ_SkinButton(startBtn, "green"); end
    startBtn:SetScript("OnClick", function() CQ_MinimapButton_StartLogging(); CQ_Config_Update(); end);

    local stopBtn = CreateFrame("Button", "CQ_Status_StopBtn", tab);
    stopBtn:SetWidth(BTN_W); stopBtn:SetHeight(BTN_H);
    stopBtn:SetPoint("TOPRIGHT", -4, -28);
    do local _fs = stopBtn:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); _fs:SetAllPoints(); _fs:SetJustifyH("CENTER"); _fs:SetText("Stop"); stopBtn:SetFontString(_fs); CQ_SkinButton(stopBtn, "danger"); end
    stopBtn:SetScript("OnClick", function() CQ_MinimapButton_StopLogging(); CQ_Config_Update(); end);

    local exportBtn = CreateFrame("Button", "CQ_Status_ExportBtn", tab);
    exportBtn:SetWidth(BTN_W); exportBtn:SetHeight(BTN_H);
    exportBtn:SetPoint("TOPRIGHT", -4, -48);
    do local _fs = exportBtn:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); _fs:SetAllPoints(); _fs:SetJustifyH("CENTER"); _fs:SetText("Export"); exportBtn:SetFontString(_fs); CQ_SkinButton(exportBtn, "ghost"); end
    exportBtn:SetScript("OnClick", function()
        if CQ_Log and CQ_Log.hasFileExport and CQ_Log_ExportToFile then
            if CQ_Log_ExportToFile(false) then
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Conq] Exported current raid.|r");
            end
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[Conq] Export requires Nampower WriteCustomFile (v3.2.0+).|r");
        end
    end);
    if not (CQ_Log and CQ_Log.hasFileExport) then exportBtn:Disable(); end

    -- ================================================================
    -- STATS STRIP: 4 chips with more breathing room
    -- ================================================================
    local stripBg = tab:CreateTexture(nil, "BACKGROUND");
    stripBg:SetWidth(CONTENT_W); stripBg:SetHeight(STRIP_H);
    stripBg:SetPoint("TOPLEFT", tab, "TOPLEFT", 0, -BANNER_H);
    stripBg:SetTexture(0.08, 0.11, 0.17, 1.0);

    -- Top border line of strip
    local stripTopLine = tab:CreateTexture(nil, "OVERLAY");
    stripTopLine:SetWidth(CONTENT_W); stripTopLine:SetHeight(1);
    stripTopLine:SetPoint("TOPLEFT", tab, "TOPLEFT", 0, -BANNER_H);
    stripTopLine:SetTexture(0.14, 0.20, 0.32, 0.8);

    -- Bottom border line of strip
    local stripBotLine = tab:CreateTexture(nil, "OVERLAY");
    stripBotLine:SetWidth(CONTENT_W); stripBotLine:SetHeight(1);
    stripBotLine:SetPoint("TOPLEFT", tab, "TOPLEFT", 0, -(BANNER_H + STRIP_H));
    stripBotLine:SetTexture(0.14, 0.20, 0.32, 0.8);

    local chipDefs = {
        { name="Players",  label="PLAYERS"  },
        { name="Deaths",   label="DEATHS"   },
        { name="Loot",     label="LOOT"     },
        { name="Duration", label="DURATION" },
    };
    -- Reserve right portion of strip for the Refresh button (60px wide + margin)
    local CHIP_TOTAL_W = CONTENT_W - 70;
    local CHIP_W = math.floor(CHIP_TOTAL_W / 4);
    for i, chip in ipairs(chipDefs) do
        local xBase = (i - 1) * CHIP_W + 12;
        -- Small muted label above
        local lbl = tab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall");
        lbl:SetPoint("TOPLEFT", tab, "TOPLEFT", xBase, -(BANNER_H + 8));
        lbl:SetText("|cff3a5068" .. chip.label .. "|r");
        -- Large value below label
        local val = tab:CreateFontString("CQ_Stat_" .. chip.name, "OVERLAY", "GameFontNormalLarge");
        val:SetPoint("TOPLEFT", tab, "TOPLEFT", xBase, -(BANNER_H + 22));
        val:SetWidth(CHIP_W - 14);
        val:SetJustifyH("LEFT");
        val:SetText("|cff2a3a4aâ|r");
        -- Subtle separator between chips
        if i < 4 then
            local sep = tab:CreateTexture(nil, "OVERLAY");
            sep:SetWidth(1); sep:SetHeight(STRIP_H - 14);
            sep:SetPoint("TOPLEFT", tab, "TOPLEFT", i * CHIP_W, -(BANNER_H + 7));
            sep:SetTexture(0.16, 0.24, 0.36, 0.4);
        end
    end

    -- ================================================================
    -- BODY: 5 panels laid out directly on the tab frame.
    -- No scrollframe — everything fits within the 454px body height.
    --
    -- ROW 1 (2-col, 174px): Sunder Armor | Recent Deaths   y=0
    -- RULE  (1px)                                           y=174
    -- ROW 2 (full,   98px): Notable Loot                   y=175
    -- RULE  (1px)                                           y=273
    -- ROW 3 (2-col, 148px): Potions & Consumables | Money  y=274
    -- ================================================================

    -- Shrunk ROW1 (~20% smaller) + top gap creates clear visual separation
    local BODY_GAP = 10;  -- px gap between strip and first content row
    local ROW1_H = 168;  -- Sunder | Deaths
    local ROW2_H = 90;   -- Notable Loot (3-col grid)
    local ROW3_H = 76;   -- Potions (3 lines) | Money
    local ROW4_H = 68;   -- Top Consumers (buff uptime ranking)

    local BODY_TOP = TOP_USED + BODY_GAP;  -- px from tab top where body starts (gap after strip)
    local PAD      = 0;                   -- flush to tab edges
    local IW       = CONTENT_W;
    local HALF     = math.floor((IW - 1) / 2);  -- left col width (1px gap)
    local RX       = HALF + 1;            -- x-start of right column

    -- ── Helper: dark card background ─────────────────────────────────────────
    local function Card(x, y, w, h, dark)
        local col = 0.080;
        local bg = tab:CreateTexture(nil, "BACKGROUND");
        bg:SetWidth(w); bg:SetHeight(h);
        bg:SetPoint("TOPLEFT", tab, "TOPLEFT", x, -(BODY_TOP + y));
        bg:SetTexture(col, col + 0.03, col + 0.07, 0.98);
    end

    -- ── Helper: section label inside card ────────────────────────────────────
    local function CardLabel(text, x, y)
        local fs = tab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall");
        fs:SetPoint("TOPLEFT", tab, "TOPLEFT", x + 9, -(BODY_TOP + y + 7));
        fs:SetText("|cff00d4ff" .. text .. "|r");
        -- Underline: extends from left inset to right edge of the card
        -- Card right edge = x + HALF - 1 for half-width cards (x=0 or x=RX)
        -- For full-width card (used externally via lootUl), created separately.
        local cardRight = x + HALF - 2;
        local ul = tab:CreateTexture(nil, "OVERLAY");
        ul:SetHeight(1);
        ul:SetPoint("TOPLEFT",  tab, "TOPLEFT", x + 9,      -(BODY_TOP + y + 23));
        ul:SetPoint("TOPRIGHT", tab, "TOPLEFT", cardRight,   -(BODY_TOP + y + 23));
        ul:SetTexture(0.0, 0.38, 0.52, 0.5);
        return fs;
    end

    -- ── Helper: content text area ─────────────────────────────────────────────
    -- Creates the named CQ_Stat_<name> FontString, inset below the label
    local function ContentText(name, x, y, w, h)
        local fs = tab:CreateFontString("CQ_Stat_" .. name, "OVERLAY", "GameFontHighlightSmall");
        -- Inset: 9px left, 26px from card top (below label+underline), 9px right
        fs:SetPoint("TOPLEFT", tab, "TOPLEFT", x + 9, -(BODY_TOP + y + 26));
        fs:SetWidth(w - 18);
        fs:SetHeight(h - 30);
        fs:SetJustifyH("LEFT");
        fs:SetJustifyV("TOP");
        fs:SetText("|cff2a3a4a\xe2\x80\x94|r");
        return fs;
    end

    -- ── Helper: full-width horizontal rule between rows ───────────────────────
    local function BodyRule(y)
        local r = tab:CreateTexture(nil, "OVERLAY");
        r:SetWidth(IW); r:SetHeight(1);
        r:SetPoint("TOPLEFT", tab, "TOPLEFT", 0, -(BODY_TOP + y));
        r:SetTexture(0.12, 0.18, 0.28, 0.9);
    end

    -- ── Helper: vertical divider between two columns ──────────────────────────
    local function ColDiv(y, h)
        local vd = tab:CreateTexture(nil, "OVERLAY");
        vd:SetWidth(1); vd:SetHeight(h);
        vd:SetPoint("TOPLEFT", tab, "TOPLEFT", HALF, -(BODY_TOP + y));
        vd:SetTexture(0.12, 0.18, 0.28, 0.9);
    end

    -- ================================================================
    -- ROW 1 — Sunder Armor (L) | Recent Deaths (R)    y=0..174
    -- ================================================================
    Card(0,    0, HALF,   ROW1_H, true);
    Card(RX,   0, HALF,   ROW1_H, false);
    ColDiv(0, ROW1_H);

    CardLabel("Sunder Armor",   0,  0);
    CardLabel("Recent Deaths",  RX, 0);

    ContentText("SunderText", 0,  0, HALF, ROW1_H);
    ContentText("DeathText",  RX, 0, HALF, ROW1_H);

    BodyRule(ROW1_H);

    -- ================================================================
    -- ROW 2 — Notable Loot (full width)    y=175..272
    -- ================================================================
    local y2 = ROW1_H + 1;
    Card(0, y2, IW, ROW2_H, true);

    -- Full-width card label needs a wider underline
    local lootLabelFs = tab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall");
    lootLabelFs:SetPoint("TOPLEFT", tab, "TOPLEFT", 9, -(BODY_TOP + y2 + 7));
    lootLabelFs:SetText("|cff00d4ffNotable Loot|r");
    local lootUl = tab:CreateTexture(nil, "OVERLAY");
    lootUl:SetHeight(1);
    lootUl:SetPoint("TOPLEFT",  tab, "TOPLEFT", 9,       -(BODY_TOP + y2 + 23));
    lootUl:SetPoint("TOPRIGHT", tab, "TOPLEFT", IW - 4,  -(BODY_TOP + y2 + 23));
    lootUl:SetTexture(0.0, 0.38, 0.52, 0.5);

    -- LootText (A) already created via ContentText; B and C are manual
    ContentText("LootText", 0, y2, IW, ROW2_H);  -- col A

    -- Col B and C FontStrings for the 3-column loot grid
    local LC = math.floor(IW / 3);
    local lootFsB = tab:CreateFontString("CQ_Stat_LootTextB", "OVERLAY", "GameFontHighlightSmall");
    lootFsB:SetPoint("TOPLEFT", tab, "TOPLEFT", LC + 6, -(BODY_TOP + y2 + 26));
    lootFsB:SetWidth(LC - 12); lootFsB:SetHeight(ROW2_H - 30);
    lootFsB:SetJustifyH("LEFT"); lootFsB:SetJustifyV("TOP"); lootFsB:SetText("");

    local lootFsC = tab:CreateFontString("CQ_Stat_LootTextC", "OVERLAY", "GameFontHighlightSmall");
    lootFsC:SetPoint("TOPLEFT", tab, "TOPLEFT", LC * 2 + 6, -(BODY_TOP + y2 + 26));
    lootFsC:SetWidth(LC - 12); lootFsC:SetHeight(ROW2_H - 30);
    lootFsC:SetJustifyH("LEFT"); lootFsC:SetJustifyV("TOP"); lootFsC:SetText("");

    -- Subtle col dividers inside the loot row
    local function LColDiv(x)
        local ld = tab:CreateTexture(nil, "OVERLAY");
        ld:SetWidth(1); ld:SetHeight(ROW2_H - 2);
        ld:SetPoint("TOPLEFT", tab, "TOPLEFT", x, -(BODY_TOP + y2 + 1));
        ld:SetTexture(0.12, 0.18, 0.28, 0.5);
    end
    LColDiv(LC);
    LColDiv(LC * 2);

    BodyRule(y2 + ROW2_H);

    -- ================================================================
    -- ROW 3 — Potions & Consumables (L) | Money Drops (R)   y=274..421
    -- ================================================================
    local y3 = y2 + ROW2_H + 1;
    Card(0,  y3, HALF, ROW3_H, false);
    Card(RX, y3, HALF, ROW3_H, true);
    ColDiv(y3, ROW3_H);

    CardLabel("Potions & Consumables", 0,  y3);
    CardLabel("Money Drops",           RX, y3);

    ContentText("PotText",   0,  y3, HALF, ROW3_H);
    ContentText("MoneyText", RX, y3, HALF, ROW3_H);

    BodyRule(y3 + ROW3_H);

    -- ================================================================
    -- ROW 4 — Top Consumers / Buff Uptime (full width)
    -- ================================================================
    local y4 = y3 + ROW3_H + 1;
    Card(0, y4, IW, ROW4_H, false);

    -- Full-width label + underline (same pattern as Notable Loot)
    local uptimeLabelFs = tab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall");
    uptimeLabelFs:SetPoint("TOPLEFT", tab, "TOPLEFT", 9, -(BODY_TOP + y4 + 7));
    uptimeLabelFs:SetText("|cff00d4ffTop Consumers|r");
    local uptimeUl = tab:CreateTexture(nil, "OVERLAY");
    uptimeUl:SetHeight(1);
    uptimeUl:SetPoint("TOPLEFT",  tab, "TOPLEFT", 9,      -(BODY_TOP + y4 + 23));
    uptimeUl:SetPoint("TOPRIGHT", tab, "TOPLEFT", IW - 4, -(BODY_TOP + y4 + 23));
    uptimeUl:SetTexture(0.0, 0.38, 0.52, 0.5);

    -- UptimeText is now visible — 3-column layout driven by UpdateStats
    -- We create three FontStrings: col A (0..IW/3), B (IW/3..2*IW/3), C (2*IW/3..IW)
    local UC = math.floor(IW / 3);
    local uptimeFsA = tab:CreateFontString("CQ_Stat_UptimeTextA", "OVERLAY", "GameFontHighlightSmall");
    uptimeFsA:SetPoint("TOPLEFT", tab, "TOPLEFT", 9,           -(BODY_TOP + y4 + 26));
    uptimeFsA:SetWidth(UC - 12); uptimeFsA:SetHeight(ROW4_H - 30);
    uptimeFsA:SetJustifyH("LEFT"); uptimeFsA:SetJustifyV("TOP");
    uptimeFsA:SetText("|cff2a3a4aâ|r");

    local uptimeFsB = tab:CreateFontString("CQ_Stat_UptimeTextB", "OVERLAY", "GameFontHighlightSmall");
    uptimeFsB:SetPoint("TOPLEFT", tab, "TOPLEFT", UC + 6,       -(BODY_TOP + y4 + 26));
    uptimeFsB:SetWidth(UC - 12); uptimeFsB:SetHeight(ROW4_H - 30);
    uptimeFsB:SetJustifyH("LEFT"); uptimeFsB:SetJustifyV("TOP");
    uptimeFsB:SetText("");

    local uptimeFsC = tab:CreateFontString("CQ_Stat_UptimeTextC", "OVERLAY", "GameFontHighlightSmall");
    uptimeFsC:SetPoint("TOPLEFT", tab, "TOPLEFT", UC * 2 + 6,   -(BODY_TOP + y4 + 26));
    uptimeFsC:SetWidth(UC - 12); uptimeFsC:SetHeight(ROW4_H - 30);
    uptimeFsC:SetJustifyH("LEFT"); uptimeFsC:SetJustifyV("TOP");
    uptimeFsC:SetText("");

    -- Col dividers inside the uptime row
    local function UColDiv(x)
        local ud = tab:CreateTexture(nil, "OVERLAY");
        ud:SetWidth(1); ud:SetHeight(ROW4_H - 2);
        ud:SetPoint("TOPLEFT", tab, "TOPLEFT", x, -(BODY_TOP + y4 + 1));
        ud:SetTexture(0.12, 0.18, 0.28, 0.6);
    end
    UColDiv(UC);
    UColDiv(UC * 2);

    -- Hidden legacy UptimeText (still required as a global by some UpdateStats paths)
    local hiddenUptime = tab:CreateFontString("CQ_Stat_UptimeText", "OVERLAY", "GameFontHighlightSmall");
    hiddenUptime:SetPoint("TOPLEFT", tab, "TOPLEFT", 0, 0);
    hiddenUptime:SetWidth(1); hiddenUptime:SetHeight(1);
    hiddenUptime:Hide();

    -- ── Refresh button — right side of stats strip, vertically centred ─────────
    local refreshBtn = CreateFrame("Button", "CQ_Status_RefreshBtn", tab);
    refreshBtn:SetWidth(62); refreshBtn:SetHeight(22);
    refreshBtn:SetPoint("TOPRIGHT", tab, "TOPRIGHT", -4, -(BANNER_H + math.floor((STRIP_H - 22) / 2)));
    do local _fs = refreshBtn:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); _fs:SetAllPoints(); _fs:SetJustifyH("CENTER"); _fs:SetText("Refresh"); refreshBtn:SetFontString(_fs); CQ_SkinButton(refreshBtn, "ghost"); end
    refreshBtn:SetScript("OnClick", function() CQ_Config_UpdateStats(); end);

    return tab;
end
-- ============================================================================
-- TAB: OPTIONS
-- ============================================================================

local function CreateOptionsTab(parent)
    local tab = CreateFrame("Frame", "CQ_Tab_Options", parent);
    tab:SetWidth(CONTENT_W);
    tab:SetHeight(FRAME_H - 90);
    tab:SetPoint("TOPLEFT", parent, "TOPLEFT", CONTENT_LEFT, CONTENT_TOP);
    tab:Hide();

    -- Scroll frame so content is never clipped
    local scrollFrame = CreateFrame("ScrollFrame", "CQ_Opt_Scroll", tab,
        "UIPanelScrollFrameTemplate");
    scrollFrame:SetWidth(CONTENT_W - 20);
    scrollFrame:SetHeight(FRAME_H - 98);
    scrollFrame:SetPoint("TOPLEFT", tab, "TOPLEFT", 0, 0);

    local content = CreateFrame("Frame", "CQ_Opt_ScrollContent", scrollFrame);
    content:SetWidth(CONTENT_W - 20);
    content:SetHeight(1);   -- will grow as yOff increases
    scrollFrame:SetScrollChild(content);
    CQ_SkinScrollFrame(scrollFrame, "CQ_Opt_Scroll");

    -- Redirect all element creation to the scroll content frame.
    -- "tab" below now refers to the content frame for anchoring purposes.
    local tab = content;   -- shadow outer tab inside this function only

    -- Absolute-position layout using yOff, same pattern as Simulate tab.
    -- This avoids anchor-chain drift. All elements anchor to the tab frame.
    local M   = 8;    -- left margin (px from tab left edge)
    local IW  = CONTENT_W - 20 - M * 2;  -- inner width (account for scrollbar)
    local CHK = 26;   -- checkbox row height
    local yOff = 8;

    -- Helper: dark background box between two yOff positions
    local function OptBox(startY, endY)
        local box = tab:CreateTexture(nil, "BACKGROUND");
        box:SetWidth(IW);
        box:SetHeight(endY - startY);
        box:SetPoint("TOPLEFT", tab, "TOPLEFT", M, -startY);
        box:SetTexture(0.12, 0.15, 0.22, 0.95);
    end

    -- Helper: section header + full-width divider line
    local function OptHdr(text, extraGap)
        yOff = yOff + (extraGap or 8);
        local hdr = tab:CreateFontString(nil, "OVERLAY", "GameFontNormal");
        hdr:SetPoint("TOPLEFT", tab, "TOPLEFT", M, -yOff);
        hdr:SetText("|cff00d4ff" .. text .. "|r");
        yOff = yOff + 16;
        local line = tab:CreateTexture(nil, "OVERLAY");
        line:SetWidth(CONTENT_W - M * 2);
        line:SetHeight(1);
        line:SetPoint("TOPLEFT", tab, "TOPLEFT", M, -yOff);
        line:SetTexture(0.0, 0.55, 0.70, 0.70);
        yOff = yOff + 6;
    end

    -- Helper: checkbox at current yOff
    local function OptCheck(cbName, label, indentX)
        local x = M + (indentX or 0);
        local cb = CreateFrame("CheckButton", cbName, tab);
        cb:SetWidth(14); cb:SetHeight(14);
        cb:SetPoint("TOPLEFT", tab, "TOPLEFT", x, -yOff);
        CQ_SkinCheckbox(cb);
        local lbl = tab:CreateFontString(cbName.."Text", "OVERLAY", "GameFontHighlightSmall");
        lbl:SetPoint("LEFT", cb, "RIGHT", 6, 0);
        lbl:SetText(label);
        lbl:SetTextColor(CQ_C.white[1], CQ_C.white[2], CQ_C.white[3]);
        return cb;
    end

    -- Helper: small grey note text
    local function OptNote(text, indentX)
        local x = M + (indentX or 0);
        local fs = tab:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall");
        fs:SetPoint("TOPLEFT", tab, "TOPLEFT", x, -yOff);
        fs:SetWidth(IW - (indentX or 0));
        fs:SetJustifyH("LEFT");
        fs:SetText(text);
        return fs;
    end

    -- ================================================================
    -- WHAT TO TRACK
    -- ================================================================
    OptHdr("What to Track", 0);
    local boxStart_track = yOff;

    local combatCheck = OptCheck("CQ_Opt_CombatCheck",
        "Track consumables out of combat  (recommended: on)");
    combatCheck:SetScript("OnClick", function()
        if not CQ_Log then return; end
        CQ_Log.trackOutOfCombat = this:GetChecked() and true or false;
        CQ_Settings_Save();
    end);
    yOff = yOff + CHK;

    OptNote("|cff666666When disabled, consumable uptime is only recorded during active combat.\n" ..
        "Leaving this on gives more accurate total uptime percentages.|r", 22);
    yOff = yOff + 28;

    local lootCheck = OptCheck("CQ_Opt_LootCheck", "Track loot and gold drops");
    lootCheck:SetScript("OnClick", function()
        if not CQ_Log then return; end
        CQ_Log.trackLoot = this:GetChecked() and true or false;
        CQ_Settings_Save();
        CQ_Config_Update();
    end);
    yOff = yOff + CHK;

    OptNote("|cff666666Which item qualities to record. Gold drops are always tracked.|r", 22);
    yOff = yOff + 16;

    -- Quality checkboxes: 2-column grid, 3 rows
    local QUALITIES = {
        { "poor",      "|cff9d9d9dGrey  (Poor)|r"      },
        { "common",    "|cffffffffWhite (Common)|r"     },
        { "uncommon",  "|cff1eff00Green (Uncommon)|r"   },
        { "rare",      "|cff0070ddBlue  (Rare)|r"       },
        { "epic",      "|cffa335eePurple (Epic)|r"      },
        { "legendary", "|cffff8000Orange (Legendary)|r" },
    };

    local HALF = math.floor(IW / 2);
    for i = 1, table.getn(QUALITIES), 2 do
        local qL = QUALITIES[i];
        local qR = QUALITIES[i + 1];

        local cbL = CreateFrame("CheckButton", "CQ_Opt_LootQ_" .. qL[1], tab);
        cbL:SetWidth(14); cbL:SetHeight(14);
        cbL:SetPoint("TOPLEFT", tab, "TOPLEFT", M + 22, -yOff);
        CQ_SkinCheckbox(cbL);
        local _lblL = tab:CreateFontString("CQ_Opt_LootQ_"..qL[1].."Text","OVERLAY","GameFontHighlightSmall");
        _lblL:SetPoint("LEFT", cbL, "RIGHT", 6, 0); _lblL:SetText(qL[2]);

        if CQ_Log and CQ_Log.trackLootQualities then
            cbL:SetChecked(CQ_Log.trackLootQualities[qL[1]]); if cbL.CQ_SyncVisual then cbL.CQ_SyncVisual(); end
        end
        local qKeyL = qL[1];
        cbL:SetScript("OnClick", function()
            if not CQ_Log then return; end
            CQ_Log.trackLootQualities = CQ_Log.trackLootQualities or {};
            CQ_Log.trackLootQualities[qKeyL] = this:GetChecked() and true or false;
            CQ_Settings_Save();
        end);

        if qR then
            local cbR = CreateFrame("CheckButton", "CQ_Opt_LootQ_" .. qR[1], tab);
            cbR:SetWidth(14); cbR:SetHeight(14);
            cbR:SetPoint("TOPLEFT", tab, "TOPLEFT", M + 22 + HALF, -yOff);
            CQ_SkinCheckbox(cbR);
            local _lblR = tab:CreateFontString("CQ_Opt_LootQ_"..qR[1].."Text","OVERLAY","GameFontHighlightSmall");
            _lblR:SetPoint("LEFT", cbR, "RIGHT", 6, 0); _lblR:SetText(qR[2]);

            if CQ_Log and CQ_Log.trackLootQualities then
                cbR:SetChecked(CQ_Log.trackLootQualities[qR[1]]); if cbR.CQ_SyncVisual then cbR.CQ_SyncVisual(); end
            end
            local qKeyR = qR[1];
            cbR:SetScript("OnClick", function()
                if not CQ_Log then return; end
                CQ_Log.trackLootQualities = CQ_Log.trackLootQualities or {};
                CQ_Log.trackLootQualities[qKeyR] = this:GetChecked() and true or false;
                CQ_Settings_Save();
            end);
        end

        yOff = yOff + CHK - 4;  -- quality rows a touch tighter
    end
    yOff = yOff + 4;

    local deathCheck = OptCheck("CQ_Opt_DeathCheck", "Track player deaths");
    deathCheck:SetScript("OnClick", function()
        if not CQ_Log then return; end
        CQ_Log.trackDeaths = this:GetChecked() and true or false;
        CQ_Settings_Save();
    end);
    yOff = yOff + CHK;

    local sunderCheck = OptCheck("CQ_Opt_SunderCheck", "Track Sunder Armor casts");
    sunderCheck:SetScript("OnClick", function()
        if not CQ_Log then return; end
        CQ_Log.trackSunders = this:GetChecked() and true or false;
        CQ_Settings_Save();
    end);
    yOff = yOff + CHK + 4;
    OptBox(boxStart_track, yOff);

    -- ================================================================
    -- AUTO-EXPORT
    -- ================================================================
    OptHdr("Auto-Export", 10);
    local boxStart_export = yOff;

    -- Row: label + editbox + "minutes" suffix + Apply button
    local exportLbl = tab:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall");
    exportLbl:SetPoint("TOPLEFT", tab, "TOPLEFT", M, -yOff);
    exportLbl:SetText("|cffaaaaaaInterval (seconds):|r");
    exportLbl:SetWidth(130);

    local exportEdit = CreateFrame("EditBox", "CQ_Opt_ExportIntervalEdit", tab);
    exportEdit:SetWidth(56);
    exportEdit:SetHeight(22);
    exportEdit:SetPoint("LEFT", exportLbl, "RIGHT", 6, 0);
    exportEdit:SetNumeric(true);
    exportEdit:SetMaxLetters(5);
    exportEdit:SetText(tostring(CQ_Log and CQ_Log.autoExportInterval or 600));
    CQ_SkinEditBox(exportEdit);

    local exportSecLbl = tab:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall");
    exportSecLbl:SetPoint("LEFT", exportEdit, "RIGHT", 5, 0);
    exportSecLbl:SetText("|cff888888sec  (0 = disabled)|r");

    local exportApply = CreateFrame("Button", "CQ_Opt_ExportApply", tab);
    exportApply:SetWidth(60);
    exportApply:SetHeight(22);
    exportApply:SetPoint("LEFT", exportSecLbl, "RIGHT", 8, 0);
    do local _fs = exportApply:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); _fs:SetAllPoints(); _fs:SetJustifyH("CENTER"); _fs:SetText("Apply"); exportApply:SetFontString(_fs); CQ_SkinButton(exportApply, "primary"); end
    exportApply:SetScript("OnClick", function()
        if not CQ_Log then return; end
        local v = tonumber(exportEdit:GetText()) or 600;
        if v < 0 then v = 0; end
        CQ_Log.autoExportInterval = v;
        CQ_Settings_Save();
        local msg = v == 0 and "|cffff9900disabled|r"
                           or ("|cff00ff00" .. v .. "s (" .. math.floor(v/60) .. "m)|r");
        DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[Conq] Auto-export interval set to " .. msg);
    end);
    exportEdit:SetScript("OnEnterPressed", function()
        exportApply:Click();
        this:ClearFocus();
    end);

    yOff = yOff + 26;

    OptNote(
        "|cff666666Requires Nampower. The file is written to the WoW |r" ..
        "|cffaaaaaa CustomData/|r|cff666666 folder.|r");
    yOff = yOff + 16;
    OptBox(boxStart_export, yOff);

    -- ================================================================
    -- BUFF POLLING
    -- ================================================================
    OptHdr("Buff Polling", 10);
    local boxStart_poll = yOff;

    local pollLbl = tab:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall");
    pollLbl:SetPoint("TOPLEFT", tab, "TOPLEFT", M, -yOff);
    pollLbl:SetText("|cffaaaaaaCheck interval (seconds):|r");
    pollLbl:SetWidth(160);

    local pollEdit = CreateFrame("EditBox", "CQ_Opt_PollIntervalEdit", tab);
    pollEdit:SetWidth(46);
    pollEdit:SetHeight(22);
    pollEdit:SetPoint("LEFT", pollLbl, "RIGHT", 6, 0);
    pollEdit:SetNumeric(true);
    pollEdit:SetMaxLetters(4);
    pollEdit:SetText(tostring(CQ_Log and CQ_Log.checkInterval or 15));
    CQ_SkinEditBox(pollEdit);

    local pollSecLbl = tab:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall");
    pollSecLbl:SetPoint("LEFT", pollEdit, "RIGHT", 5, 0);
    pollSecLbl:SetText("|cff888888sec|r");

    local pollApply = CreateFrame("Button", "CQ_Opt_PollApply", tab);
    pollApply:SetWidth(60);
    pollApply:SetHeight(22);
    pollApply:SetPoint("LEFT", pollSecLbl, "RIGHT", 8, 0);
    do local _fs = pollApply:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); _fs:SetAllPoints(); _fs:SetJustifyH("CENTER"); _fs:SetText("Apply"); pollApply:SetFontString(_fs); CQ_SkinButton(pollApply, "primary"); end
    pollApply:SetScript("OnClick", function()
        if not CQ_Log then return; end
        local v = tonumber(pollEdit:GetText()) or 15;
        if v < 5  then v = 5;  end   -- minimum 5s to avoid CPU hammering
        if v > 60 then v = 60; end   -- maximum 60s
        CQ_Log.checkInterval = v;
        -- Restart the timer so it actually fires at the new interval,
        -- not just the one it was registered with at raid start.
        RAB_Core_RemoveTimer("raidlog_check");
        RAB_Core_AddTimer(v, "raidlog_check", CQ_Log_PerformCheck);
        CQ_Settings_Save();
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cffaaaaaa[Conq] Buff poll interval set to |cff00ff00" .. v .. "s|r");
    end);
    pollEdit:SetScript("OnEnterPressed", function()
        pollApply:Click();
        this:ClearFocus();
    end);

    yOff = yOff + 26;

    OptNote(
        "|cff666666How often the raid roster is scanned for active buffs and consumables.\n" ..
        "Lower = more accurate uptime data but slightly more CPU. Range: 5–60s. Default: 15s.|r");
    yOff = yOff + 28;
    OptBox(boxStart_poll, yOff);

    -- ================================================================
    -- AUTOMATICALLY-TRACKED RAID ZONES
    -- ================================================================
    OptHdr("Automatically-Tracked Raid Zones", 10);
    local boxStart_zones = yOff;

    -- All zones from CQ_Log_ValidZones, with friendly display order
    local ZONE_LIST = {
        "Molten Core",
        "Blackwing Lair",
        "Zul'Gurub",
        "Ruins of Ahn'Qiraj",
        "Temple of Ahn'Qiraj",
        "Naxxramas",
        "Emerald Sanctum",
        "Tower of Karazhan",
        "The Rock of Desolation",
    };

    -- Helper: is a zone currently enabled?
    local function ZoneEnabled(zoneName)
        -- If trackedZones is nil, all zones are on by default (matches ValidZones)
        if not CQ_Log or not CQ_Log.trackedZones then
            return CQ_Log_ValidZones and CQ_Log_ValidZones[zoneName] or false;
        end
        return CQ_Log.trackedZones[zoneName] ~= false;
    end

    -- Two-column zone checkbox grid
    local ZONE_COL_W = math.floor(IW / 2);
    local ZONE_ROW_H = 22;
    local zCol = 0;
    for _, zoneName in ipairs(ZONE_LIST) do
        local xOff = M + zCol * ZONE_COL_W;
        local cbName = "CQ_Opt_Zone_" .. string.gsub(zoneName, "[^%w]", "_");
        local cb = CreateFrame("CheckButton", cbName, tab);
        cb:SetWidth(14); cb:SetHeight(14);
        cb:SetPoint("TOPLEFT", tab, "TOPLEFT", xOff, -yOff);
        CQ_SkinCheckbox(cb);
        local _zlbl = tab:CreateFontString(cbName.."Text","OVERLAY","GameFontHighlightSmall");
        _zlbl:SetPoint("LEFT", cb, "RIGHT", 6, 0);
        _zlbl:SetText(zoneName); _zlbl:SetWidth(ZONE_COL_W - 22);
        cb:SetChecked(ZoneEnabled(zoneName)); if cb.CQ_SyncVisual then cb.CQ_SyncVisual(); end

        local zName = zoneName;   -- close over correctly
        cb:SetScript("OnClick", function()
            if not CQ_Log then return; end
            if not CQ_Log.trackedZones then
                -- Seed from ValidZones so all are explicitly stored
                CQ_Log.trackedZones = {};
                if CQ_Log_ValidZones then
                    for z in pairs(CQ_Log_ValidZones) do
                        CQ_Log.trackedZones[z] = true;
                    end
                end
            end
            CQ_Log.trackedZones[zName] = this:GetChecked() and true or false;
            -- Keep ValidZones in sync so auto-start logic works immediately
            if CQ_Log_ValidZones then
                if CQ_Log.trackedZones[zName] then
                    CQ_Log_ValidZones[zName] = true;
                else
                    CQ_Log_ValidZones[zName] = nil;
                end
            end
            CQ_Settings_Save();
        end);

        zCol = zCol + 1;
        if zCol >= 2 then
            zCol = 0;
            yOff = yOff + ZONE_ROW_H;
        end
    end
    if zCol > 0 then yOff = yOff + ZONE_ROW_H; end
    yOff = yOff + 4;

    OptNote(
        "|cff555555Logging arms automatically when you enter a checked zone in a raid group.\n" ..
        "It starts on your first combat hit to avoid logging trash. Safe zones\n" ..
        "(graveyards / release points) keep logging active across wipes.|r");
    yOff = yOff + 42;
    OptBox(boxStart_zones, yOff);

    -- Size the scroll content to fit everything
    content:SetHeight(yOff + 12);

    -- Return the outer scrollable tab frame (not content)
    return CQ_Tab_Options;
end

-- ============================================================================
-- TAB: SIMULATE
-- Mirrors the Consumables tab layout but replaces checkboxes with "Fire"
-- buttons that inject a fake consumable application directly into the active
-- raid log via CQ_Log_TrackConsumable. No real items needed.
-- ============================================================================

-- ============================================================================
-- FULL PIPELINE CAST SIMULATOR
-- Injects a fake Nampower event by setting the arg1/arg2/arg3/event globals
-- exactly as Nampower does, then calling CQ_ConsTracker_OnCastEvent() directly.
-- This exercises the entire real detection pipeline:
--   GUID resolution → KeyMap lookup → raid membership check →
--   CQ_ConsInt_OnConsumable → castTrackedConsumables write → raid.players write
--
-- spellID    : a spell ID from CQ_ConsTracker_Tracked / CQ_ConsTracker_KeyMap
-- playerName : name of a raid/party member (or UnitName("player") for self)
-- eventType  : "SPELL_GO_OTHER" | "SPELL_GO_SELF" | "AURA_CAST_ON_OTHER" | "AURA_CAST_ON_SELF"
--              Defaults to "SPELL_GO_OTHER".  Use AURA_CAST_* for weapon enchants.
-- badGuid    : if true, passes a fake unresolvable GUID to exercise the retry queue.
-- ============================================================================
function CQ_SimulateCastEvent(spellID, playerName, eventType, badGuid)
    eventType = eventType or "SPELL_GO_OTHER";

    -- Determine which pipeline owns this spell ID.
    -- System A: CQ_Log_ConsumableSpellIDs  (flasks, elixirs, food, potions, juju etc.)
    --           handler: CQ_Log_OnConsumableSpellGo()  reads arg2=spellID, arg3=guid
    -- System B: CQ_ConsTracker_KeyMap      (weapon oils, stones, poisons, sapper)
    --           handler: CQ_ConsTracker_OnCastEvent()  reads arg1/arg2/arg3 per event type
    local isSystemA = CQ_Log_ConsumableSpellIDs and CQ_Log_ConsumableSpellIDs[spellID] ~= nil;
    local isSystemB = CQ_ConsTracker_KeyMap      and CQ_ConsTracker_KeyMap[spellID]      ~= nil;

    -- System B also detects spells in CQ_ConsTracker_Tracked that aren't in KeyMap,
    -- but those are discarded downstream so we don't need to test them here.
    if not isSystemA and not isSystemB then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[CastSim] spellID=" .. tostring(spellID) ..
            " not found in either ConsumableSpellIDs or ConsTracker_KeyMap — nothing to fire.|r");
        return false;
    end

    -- Require Nampower for System B (AURA_CAST / ConsTracker path).
    -- System A uses GetUnitGUID which also needs Nampower, but fail gracefully.
    if isSystemB and (not CQ_ConsTracker or not CQ_ConsTracker.enabled) then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[CastSim] CQ_ConsTracker not enabled (Nampower required for weapon enchants/poisons).|r");
        return false;
    end

    -- Resolve GUID
    local guid = nil;
    if badGuid then
        guid = "0x000000000BADDEAD";
    else
        if playerName == UnitName("player") then
            local _, g = UnitExists("player");
            guid = g;
        end
        if not guid then
            for i = 1, GetNumRaidMembers() do
                local unit = "raid" .. i;
                if UnitName(unit) == playerName then
                    local _, g = UnitExists(unit);
                    guid = g;
                    break;
                end
            end
        end
        if not guid then
            for i = 1, GetNumPartyMembers() do
                local unit = "party" .. i;
                if UnitName(unit) == playerName then
                    local _, g = UnitExists(unit);
                    guid = g;
                    break;
                end
            end
        end
        if not guid and CQ_GuidDB then
            for g, entry in pairs(CQ_GuidDB) do
                if entry.name == playerName then guid = g; break; end
            end
        end
        -- System A uses GetUnitGUID; if that's unavailable seed GuidMap directly
        if not guid and GetUnitGUID then
            guid = GetUnitGUID("player");
        end
        if not guid then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[CastSim] Cannot resolve GUID for '" ..
                tostring(playerName) .. "'.|r");
            return false;
        end
    end

    -- Save globals
    local prev_event = event;
    local prev_arg1  = arg1;
    local prev_arg2  = arg2;
    local prev_arg3  = arg3;

    if isSystemA then
        -- System A: SPELL_GO_OTHER — arg2=spellID, arg3=casterGUID
        event = "SPELL_GO_OTHER";
        arg1  = 0;
        arg2  = spellID;
        arg3  = guid;
        -- Also seed GuidMap so the handler resolves the name without a roster scan
        if CQ_Log_GuidMap then
            CQ_Log_GuidMap[guid] = playerName;
        end
        CQ_Log_OnConsumableSpellGo();
    end

    if isSystemB then
        -- System B: set globals per event type and call ConsTracker handler
        event = eventType;
        if eventType == "SPELL_GO_SELF" or eventType == "SPELL_GO_OTHER" then
            arg1 = 0;
            arg2 = spellID;
            arg3 = guid;
        elseif eventType == "AURA_CAST_ON_SELF" or eventType == "AURA_CAST_ON_OTHER" then
            local _, selfGuid = UnitExists("player");
            arg1 = spellID;
            arg2 = guid;
            arg3 = selfGuid or guid;
        end
        CQ_ConsTracker_OnCastEvent();
    end

    -- Restore globals
    event = prev_event;
    arg1  = prev_arg1;
    arg2  = prev_arg2;
    arg3  = prev_arg3;

    return true;
end

local function CreateSimulateTab(parent)
    local tab = CreateFrame("Frame", "CQ_Tab_Simulate", parent);
    tab:SetWidth(CONTENT_W);
    tab:SetHeight(FRAME_H - 90);
    tab:SetPoint("TOPLEFT", parent, "TOPLEFT", CONTENT_LEFT, CONTENT_TOP);
    tab:Hide();

    local scrollFrame = CreateFrame("ScrollFrame", "CQ_Sim_Scroll", tab,
        "UIPanelScrollFrameTemplate");
    scrollFrame:SetWidth(CONTENT_W - 20);
    scrollFrame:SetHeight(FRAME_H - 98);
    scrollFrame:SetPoint("TOPLEFT", 0, 0);

    local content = CreateFrame("Frame", nil, scrollFrame);
    content:SetWidth(CONTENT_W - 36);
    content:SetHeight(10);
    scrollFrame:SetScrollChild(content);
    CQ_SkinScrollFrame(scrollFrame, "CQ_Sim_Scroll");

    -- Dark background for the entire simulate list
    local simBg = content:CreateTexture(nil, "BACKGROUND");
    simBg:SetAllPoints(content);
    simBg:SetTexture(0.12, 0.15, 0.22, 0.98);

    local M      = 6;    -- margin
    local ROW_H  = 22;
    local HDR_H  = 16;
    local BTN_W  = 44;
    local BTN_H  = 18;
    local IW     = CONTENT_W - 36 - M * 2;
    local COL_W  = math.floor(IW / 2);

    local yOff = 6;

    -- Helper: draw a section header + divider line, return new yOff
    local function SimHdr(text)
        yOff = yOff + 10;
        local hdr = content:CreateFontString(nil, "OVERLAY", "GameFontNormal");
        hdr:SetPoint("TOPLEFT", M, -yOff);
        hdr:SetText("|cff00d4ff" .. text .. "|r");
        yOff = yOff + HDR_H;
        local div = content:CreateTexture(nil, "OVERLAY");
        div:SetWidth(IW); div:SetHeight(1);
        div:SetPoint("TOPLEFT", M, -yOff);
        div:SetTexture(0.4, 0.35, 0.1, 0.5);
        yOff = yOff + 6;
    end

    -- Helper: draw a Fire button + label at current yOff/col, advance position
    local function SimRow(btnName, label, col, onClick)
        local xBase = M + col * COL_W;
        local btn = CreateFrame("Button", btnName, content);
        btn:SetWidth(BTN_W); btn:SetHeight(BTN_H);
        btn:SetPoint("TOPLEFT", xBase, -yOff);
        do local _fs = btn:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); _fs:SetAllPoints(); _fs:SetJustifyH("CENTER"); _fs:SetText("Fire"); btn:SetFontString(_fs); CQ_SkinButton(btn, "primary"); end
        btn:SetScript("OnClick", onClick);
        local lbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall");
        lbl:SetPoint("LEFT", btn, "RIGHT", 4, 0);
        lbl:SetWidth(COL_W - BTN_W - 8);
        lbl:SetText(label);
        lbl:SetJustifyH("LEFT");
        return btn;
    end

    -- Helper: get the current raid table, print error if not available
    local function GetRaid()
        if not CQ_Log or not CQ_Log.isLogging or not CQ_Log.currentRaidId then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[RAB Simulate] Not logging. Run /conqlog start first.|r");
            return nil;
        end
        if not CQui_RaidLogs or not CQui_RaidLogs.raids then return nil; end
        return CQui_RaidLogs.raids[CQ_Log.currentRaidId];
    end

    -- Helper: ensure a player entry exists in raid.players
    local function EnsurePlayer(raid, name)
        if not raid.players[name] then
            raid.players[name] = {
                class = "Unknown",
                participationTime = 0,
                lastSeen = time(),
                firstSeen = time(),
                consumables = {},
                deaths = 0,
            };
        end
    end

    -- ================================================================
    -- Top instruction + Fire All consumables button
    -- ================================================================
    local note = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall");
    note:SetPoint("TOPLEFT", M, -yOff);
    note:SetWidth(IW);
    note:SetText("|cffaaaaaaStart logging first ( /conqlog start ), then click Fire to inject test events.|r");
    yOff = yOff + 18;

    local fireAllBtn = CreateFrame("Button", "CQ_Sim_FireAll", content);
    fireAllBtn:SetWidth(130); fireAllBtn:SetHeight(20);
    fireAllBtn:SetPoint("TOPLEFT", M, -yOff);
    do local _fs = fireAllBtn:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); _fs:SetAllPoints(); _fs:SetJustifyH("CENTER"); _fs:SetText("Fire All Consumables"); fireAllBtn:SetFontString(_fs); CQ_SkinButton(fireAllBtn, "primary"); end
    fireAllBtn:SetScript("OnClick", function()
        if not GetRaid() then return; end
        local playerName = UnitName("player");
        local count = 0;
        for _, section in ipairs(CQ_Log_ConsumableCatalog) do
            for _, item in ipairs(section.items) do
                local duration = CQ_Log_ConsumableDurations[item.key] or 1800;
                if duration > 0 then
                    CQ_Log_TrackConsumable(playerName, item.key, true, duration);
                    count = count + 1;
                end
            end
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[RAB Simulate] Fired " .. count .. " consumables.|r");
    end);
    yOff = yOff + 28;

    local topDiv = content:CreateTexture(nil, "OVERLAY");
    topDiv:SetWidth(IW); topDiv:SetHeight(1);
    topDiv:SetPoint("TOPLEFT", M, -yOff);
    topDiv:SetTexture(0.22, 0.30, 0.42, 0.8);
    yOff = yOff + 6;

    -- ================================================================
    -- SECTION: Deaths
    -- ================================================================
    SimHdr("Player Deaths");

    local DEATH_NAMES = { "Warrior", "Mage", "Priest", "Warlock", "Druid", "Paladin" };
    local DEATH_KILLERS = { "Ragnaros", "Nefarian", "C'Thun", "Kel'Thuzad", "Archimonde", "Illidan" };

    local dCol = 0;
    for i, name in ipairs(DEATH_NAMES) do
        local dName   = name;
        local dKiller = DEATH_KILLERS[i] or "Unknown";
        SimRow("CQ_Sim_Death_" .. i, "Kill " .. dName, dCol, function()
            local raid = GetRaid(); if not raid then return; end
            EnsurePlayer(raid, dName);
            table.insert(raid.deaths, {
                playerName = dName,
                killedBy   = dKiller,
                timestamp  = time(),
            });
            raid.players[dName].deaths = (raid.players[dName].deaths or 0) + 1;
            DEFAULT_CHAT_FRAME:AddMessage("|cffff6666[RAB Simulate] Death: " .. dName .. " killed by " .. dKiller .. "|r");
        end);
        dCol = dCol + 1;
        if dCol >= 2 then dCol = 0; yOff = yOff + ROW_H; end
    end
    if dCol > 0 then yOff = yOff + ROW_H; end

    -- ================================================================
    -- SECTION: Loot
    -- ================================================================
    SimHdr("Loot Drops");

    local LOOT_ITEMS = {
        { name = "Tier 2 Helm",        quality = 4, itemId = 16931 },
        { name = "Sulfuron Hammer",     quality = 4, itemId = 17182 },
        { name = "Ashkandi",            quality = 4, itemId = 19364 },
        { name = "Band of Accuria",     quality = 3, itemId = 17063 },
        { name = "Core Hound Tooth",    quality = 3, itemId = 18805 },
        { name = "Onyxia Scale Cloak",  quality = 2, itemId = 15138 },
    };

    local lCol = 0;
    for _, loot in ipairs(LOOT_ITEMS) do
        local lName    = loot.name;
        local lQuality = loot.quality;
        local lItemId  = loot.itemId;
        -- Map quality int to name string matching raidlog conventions
        local QNAMES = { [0]="poor", [1]="common", [2]="uncommon", [3]="rare", [4]="epic", [5]="legendary" };
        local lQualName = QNAMES[lQuality] or "uncommon";
        SimRow("CQ_Sim_Loot_" .. lItemId, lName, lCol, function()
            local raid = GetRaid(); if not raid then return; end
            local player = UnitName("player");
            table.insert(raid.loot, {
                playerName  = player,
                itemId      = lItemId,
                itemName    = lName,
                itemQuality = lQualName,
                quantity    = 1,
            });
            DEFAULT_CHAT_FRAME:AddMessage("|cff1eff00[RAB Simulate] Loot: " .. lName .. " → " .. player .. "|r");
        end);
        lCol = lCol + 1;
        if lCol >= 2 then lCol = 0; yOff = yOff + ROW_H; end
    end
    if lCol > 0 then yOff = yOff + ROW_H; end

    -- ================================================================
    -- SECTION: Gold Drops
    -- ================================================================
    SimHdr("Gold Drops");

    local GOLD_AMOUNTS = {
        { label = "1g 50s",   copper = 15000  },
        { label = "5g 22s",   copper = 52200  },
        { label = "12g",      copper = 120000 },
        { label = "25g 10s",  copper = 251000 },
    };

    local gCol = 0;
    for _, gold in ipairs(GOLD_AMOUNTS) do
        local gLabel  = gold.label;
        local gCopper = gold.copper;
        SimRow("CQ_Sim_Gold_" .. gCopper, gLabel, gCol, function()
            local raid = GetRaid(); if not raid then return; end
            raid.totalMoneyCopper = (raid.totalMoneyCopper or 0) + gCopper;
            DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00[RAB Simulate] Gold drop: " .. gLabel ..
                "  (raid total: " .. raid.totalMoneyCopper .. "c)|r");
        end);
        gCol = gCol + 1;
        if gCol >= 2 then gCol = 0; yOff = yOff + ROW_H; end
    end
    if gCol > 0 then yOff = yOff + ROW_H; end

    -- ================================================================
    -- SECTION: Sunder Armor
    -- ================================================================
    SimHdr("Sunder Armor Casts");

    local SUNDER_PLAYERS = {
        { name = "Kargath",  count = 1  },
        { name = "Rokmar",   count = 5  },
        { name = "Gronn",    count = 15 },
        { name = "Vazruden", count = 30 },
    };

    local sCol = 0;
    for _, s in ipairs(SUNDER_PLAYERS) do
        local sName  = s.name;
        local sCount = s.count;
        local sLabel = sName .. " ×" .. sCount;
        SimRow("CQ_Sim_Sunder_" .. sName, sLabel, sCol, function()
            local raid = GetRaid(); if not raid then return; end
            -- Inject directly into raid.spells — same structure as CQ_Log_RecordSunder
            if not raid.spells[sName] then raid.spells[sName] = {}; end
            if not raid.spells[sName]["sunder_armor"] then
                raid.spells[sName]["sunder_armor"] = { count = 0, spellName = "Sunder Armor" };
            end
            raid.spells[sName]["sunder_armor"].count =
                raid.spells[sName]["sunder_armor"].count + sCount;
            DEFAULT_CHAT_FRAME:AddMessage("|cff88ccff[RAB Simulate] Sunder: " .. sName ..
                " ×" .. sCount .. " (total: " .. raid.spells[sName]["sunder_armor"].count .. ")|r");
        end);
        sCol = sCol + 1;
        if sCol >= 2 then sCol = 0; yOff = yOff + ROW_H; end
    end
    if sCol > 0 then yOff = yOff + ROW_H; end

    -- ================================================================
    -- SECTION: Consumables (from catalog)
    -- ================================================================
    if CQ_Log_ConsumableCatalog then
        for _, section in ipairs(CQ_Log_ConsumableCatalog) do
            SimHdr(section.header);
            local col = 0;
            for _, item in ipairs(section.items) do
                local bKey   = item.key;
                local bLabel = item.label;
                local btn = SimRow("CQ_Sim_Fire_" .. bKey, bLabel, col, function()
                    if not GetRaid() then return; end
                    local duration = CQ_Log_ConsumableDurations[bKey] or 1800;
                    CQ_Log_TrackConsumable(UnitName("player"), bKey, true, duration);
                    -- Remove dots before printing to chat: WoW 1.12 chat renderer
                    -- auto-linkifies dot-separated strings (e.g. "R.O.I.D.S.") as URLs.
                    local safeLabel = string.gsub(bLabel, "%.", "");
                    DEFAULT_CHAT_FRAME:AddMessage("|cff00ffff[RAB Simulate] Fired: " .. safeLabel .. "|r");
                end);
                -- Tooltip
                local bItemId = CQ_Buffs and CQ_Buffs[bKey] and CQ_Buffs[bKey].itemId;
                if bItemId then
                    btn:SetScript("OnEnter", function()
                        GameTooltip:SetOwner(this, "ANCHOR_RIGHT");
                        GameTooltip:SetHyperlink("item:" .. bItemId);
                        GameTooltip:Show();
                    end);
                    btn:SetScript("OnLeave", function() GameTooltip:Hide(); end);
                end
                col = col + 1;
                if col >= 2 then col = 0; yOff = yOff + ROW_H; end
            end
            if col > 0 then yOff = yOff + ROW_H; end
        end
    end

    yOff = yOff + 10;
    content:SetHeight(yOff);

    return tab;
end

-- ============================================================================
-- TAB: CONSUMABLES
-- 3-column scrollable grid of individual per-buffKey checkboxes, organized
-- under category section headers.  Global names: CQ_Cons_Item_<buffKey>.
-- ============================================================================

-- Number of columns in the consumable checkbox grid.
local CONS_COLS = 3;

local function CreateConsumablesTab(parent)
    local tab = CreateFrame("Frame", "CQ_Tab_Consumables", parent);
    tab:SetWidth(CONTENT_W);
    tab:SetHeight(FRAME_H - 90);
    tab:SetPoint("TOPLEFT", parent, "TOPLEFT", CONTENT_LEFT, CONTENT_TOP);
    tab:Hide();

    -- ScrollFrame so the list can grow indefinitely.
    local scrollFrame = CreateFrame("ScrollFrame", "CQ_Cons_Scroll", tab,
        "UIPanelScrollFrameTemplate");
    scrollFrame:SetWidth(CONTENT_W - 20);
    scrollFrame:SetHeight(FRAME_H - 98);
    scrollFrame:SetPoint("TOPLEFT", 0, 0);

    local content = CreateFrame("Frame", nil, scrollFrame);
    content:SetWidth(CONTENT_W - 36);
    content:SetHeight(10);
    scrollFrame:SetScrollChild(content);
    CQ_SkinScrollFrame(scrollFrame, "CQ_Cons_Scroll");

    -- Dark background for the entire consumables list
    local consBg = content:CreateTexture(nil, "BACKGROUND");
    consBg:SetAllPoints(content);
    consBg:SetTexture(0.12, 0.15, 0.22, 0.98);

    -- Seed defaults before building checkboxes.
    if CQ_Log_EnsureItemDefaults then CQ_Log_EnsureItemDefaults(); end

    -- Layout constants
    local MARGIN      = 6;
    local COL_W       = math.floor((CONTENT_W - 36 - MARGIN) / CONS_COLS);
    local ROW_H       = 24;   -- taller rows = more breathing room between checkboxes
    local HDR_H       = 22;   -- height for a section header row
    local HDR_GAP     = 12;   -- extra vertical gap before each section header

    -- We place everything with absolute y offsets into the content frame.
    local yOff = 4;  -- current vertical cursor (positive, added as negative SetPoint)

    -- "Enable All" / "Disable All" global buttons at the top
    local allBtn = CreateFrame("Button", "CQ_Cons_EnableAll", content);
    allBtn:SetWidth(90);
    allBtn:SetHeight(20);
    allBtn:SetPoint("TOPLEFT", MARGIN, -yOff);
    do local _fs = allBtn:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); _fs:SetAllPoints(); _fs:SetJustifyH("CENTER"); _fs:SetText("Enable All"); allBtn:SetFontString(_fs); CQ_SkinButton(allBtn, "primary"); end
    allBtn:SetScript("OnClick", function()
        if not CQ_Log then return; end
        if not CQ_Log.trackedItems then CQ_Log.trackedItems = {}; end
        for _, section in ipairs(CQ_Log_ConsumableCatalog) do
            for _, item in ipairs(section.items) do
                CQ_Log.trackedItems[item.key] = true;
            end
        end
        CQ_Settings_Save();
        CQ_Config_Update();
    end);

    local noneBtn = CreateFrame("Button", "CQ_Cons_DisableAll", content);
    noneBtn:SetWidth(90);
    noneBtn:SetHeight(20);
    noneBtn:SetPoint("TOPLEFT", allBtn, "TOPRIGHT", 6, 0);
    do local _fs = noneBtn:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); _fs:SetAllPoints(); _fs:SetJustifyH("CENTER"); _fs:SetText("Disable All"); noneBtn:SetFontString(_fs); CQ_SkinButton(noneBtn, "ghost"); end
    noneBtn:SetScript("OnClick", function()
        if not CQ_Log then return; end
        if not CQ_Log.trackedItems then CQ_Log.trackedItems = {}; end
        for _, section in ipairs(CQ_Log_ConsumableCatalog) do
            for _, item in ipairs(section.items) do
                CQ_Log.trackedItems[item.key] = false;
            end
        end
        CQ_Settings_Save();
        CQ_Config_Update();
    end);

    yOff = yOff + 20 + 4;

    -- Small hint: class buffs track caster, not receiver
    local classBuffNote = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall");
    classBuffNote:SetPoint("TOPLEFT", MARGIN, -yOff);
    classBuffNote:SetWidth(CONTENT_W - 36 - MARGIN * 2);
    classBuffNote:SetJustifyH("LEFT");
    classBuffNote:SetText("|cff888888Class Buffs sections track WHO CAST the buff (cast count per player), detected via spell cast events.|r");
    yOff = yOff + 16 + 8;

    -- Divider under the global buttons
    local topDiv = content:CreateTexture(nil, "OVERLAY");
    topDiv:SetWidth(CONTENT_W - 36 - MARGIN * 2);
    topDiv:SetHeight(1);
    topDiv:SetPoint("TOPLEFT", MARGIN, -yOff);
    topDiv:SetTexture(0.35, 0.3, 0.1, 0.6);
    yOff = yOff + 8;

    -- Class colour lookup for "Class Buffs – <Class>" section headers.
    -- Colours match the standard WoW class palette used in the raid frame.
    local CLASS_BUFF_COLORS = {
        ["Class Buffs \226\128\147 Mage"]    = { hex = "ff6969ff", r = 0.41, g = 0.41, b = 1.00 },
        ["Class Buffs \226\128\147 Priest"]  = { hex = "ffffffff", r = 1.00, g = 1.00, b = 1.00 },
        ["Class Buffs \226\128\147 Paladin"] = { hex = "fff58cba", r = 0.96, g = 0.55, b = 0.73 },
        ["Class Buffs \226\128\147 Druid"]   = { hex = "ffff7c0a", r = 1.00, g = 0.49, b = 0.04 },
        ["Class Buffs \226\128\147 Shaman"]  = { hex = "ff0070dd", r = 0.00, g = 0.44, b = 0.87 },
        ["Class Buffs \226\128\147 Warlock"] = { hex = "ff9482c9", r = 0.58, g = 0.51, b = 0.79 },
        ["Class Buffs \226\128\147 Hunter"]  = { hex = "ffaad372", r = 0.67, g = 0.83, b = 0.45 },
        ["Class Buffs \226\128\147 Warrior"] = { hex = "ffc69b3d", r = 0.78, g = 0.61, b = 0.24 },
        ["Class Buffs \226\128\147 Rogue"]   = { hex = "fffff468", r = 1.00, g = 0.96, b = 0.41 },
    };

    -- Iterate catalog sections.  Each section gets a full-width header row,
    -- then its items are laid out left-to-right across CONS_COLS columns.
    if CQ_Log_ConsumableCatalog then
        for _, section in ipairs(CQ_Log_ConsumableCatalog) do
            -- Section header (full width).
            -- Class Buff sections use the class colour; everything else uses gold.
            yOff = yOff + HDR_GAP;

            local classEntry = CLASS_BUFF_COLORS[section.header];
            local headerColor = classEntry and ("|cff" .. string.sub(classEntry.hex, 3)) or "|cff00d4ff";
            local divR, divG, divB, divA;
            if classEntry then
                divR, divG, divB, divA = classEntry.r * 0.55, classEntry.g * 0.55, classEntry.b * 0.55, 0.6;
            else
                divR, divG, divB, divA = 0.4, 0.35, 0.1, 0.5;
            end

            local hdr = content:CreateFontString(nil, "OVERLAY", "GameFontNormal");
            hdr:SetPoint("TOPLEFT", MARGIN, -yOff);
            hdr:SetText(headerColor .. section.header .. "|r");
            yOff = yOff + 16;

            local hdrdiv = content:CreateTexture(nil, "OVERLAY");
            hdrdiv:SetWidth(CONTENT_W - 36 - MARGIN * 2);
            hdrdiv:SetHeight(1);
            hdrdiv:SetPoint("TOPLEFT", MARGIN, -yOff);
            hdrdiv:SetTexture(divR, divG, divB, divA);
            yOff = yOff + 6;

            -- Place items in a 3-column grid
            local col = 0;
            local rowStartY = yOff;

            for _, item in ipairs(section.items) do
                local xOff = MARGIN + col * COL_W;
                local enabled = (not CQ_Log.trackedItems) or
                                (CQ_Log.trackedItems[item.key] ~= false);

                local cbName = "CQ_Cons_Item_" .. item.key;
                local cb = CreateFrame("CheckButton", cbName, content);
                cb:SetWidth(14); cb:SetHeight(14);
                cb:SetPoint("TOPLEFT", xOff, -yOff);
                CQ_SkinCheckbox(cb);
                local _clbl = content:CreateFontString(cbName.."Text","OVERLAY","GameFontHighlightSmall");
                _clbl:SetPoint("LEFT", cb, "RIGHT", 6, 0);
                _clbl:SetText(item.label); _clbl:SetWidth(COL_W - 22);

                cb:SetChecked(enabled); if cb.CQ_SyncVisual then cb.CQ_SyncVisual(); end

                -- Close over item.key correctly
                local bKey = item.key;
                cb:SetScript("OnClick", function()
                    if not CQ_Log then return; end
                    if not CQ_Log.trackedItems then
                        CQ_Log.trackedItems = {};
                    end
                    CQ_Log.trackedItems[bKey] = this:GetChecked() and true or false;
                    CQ_Settings_Save();
                end);

                col = col + 1;
                if col >= CONS_COLS then
                    col = 0;
                    yOff = yOff + ROW_H;
                end
            end

            -- Advance y if the last row wasn't full
            if col > 0 then
                yOff = yOff + ROW_H;
            end
        end
    end

    yOff = yOff + 8;
    content:SetHeight(yOff);

    return tab;
end

-- ============================================================================
-- TAB: COMMANDS
-- ============================================================================

local function CreateCommandsTab(parent)
    local tab = CreateFrame("Frame", "CQ_Tab_Commands", parent);
    tab:SetWidth(CONTENT_W);
    tab:SetHeight(FRAME_H - 90);
    tab:SetPoint("TOPLEFT", parent, "TOPLEFT", CONTENT_LEFT, CONTENT_TOP);
    tab:Hide();

    local scrollFrame = CreateFrame("ScrollFrame", "CQ_Cmd_Scroll", tab,
        "UIPanelScrollFrameTemplate");
    scrollFrame:SetWidth(CONTENT_W - 20);
    scrollFrame:SetHeight(FRAME_H - 98);
    scrollFrame:SetPoint("TOPLEFT", 0, 0);

    local content = CreateFrame("Frame", nil, scrollFrame);
    content:SetWidth(CONTENT_W - 36);
    content:SetHeight(10);
    scrollFrame:SetScrollChild(content);
    CQ_SkinScrollFrame(scrollFrame, "CQ_Cmd_Scroll");

    -- Dark background for the entire commands list
    local cmdBg = content:CreateTexture(nil, "BACKGROUND");
    cmdBg:SetAllPoints(content);
    cmdBg:SetTexture(0.12, 0.15, 0.22, 0.98);

    local sections = {
        {
            title = "Raid Logger  ·  /conqlog",
            rows = {
                { "/conqlog",                        "Show all subcommands in chat" },
                { "/conqlog status",                 "Show logging status, zone, combat state" },
                { "/conqlog start",                  "Force-start logging (bypasses all checks)" },
                { "/conqlog stop",                   "Force-stop and finalize current session" },
                { "/conqlog toggle",                 "Toggle out-of-combat tracking on/off" },
                { "/conqlog export",                 "Export current raid to file" },
                { "/conqlog exportall",              "Export all raids to one file" },
                { "/conqlog format lua",             "Set export format to Lua" },
                { "/conqlog format json",            "Set export format to JSON" },
                { "/conqlog verbose",                "Toggle verbose export keys (full names)" },
                { "/conqlog interval <sec>",         "Set auto-export interval in seconds" },
                { "/conqlog potions",                "Show mana potion and tea usage this raid" },
                { "/conqlog sunder",                 "Diagnose Sunder tracking  (GUID map, counts)" },
                { "/conqlog cache",                  "Dump all in-memory cache contents" },
                { "/conqlog benchmark",              "Show timing and data volume diagnostics" },
                { "/conqlog superwow",               "Check client extension API status" },
                { "/conqlog forcecheck",             "Force an immediate buff/consumable check" },
                { "/conqlog findspells",             "Scan bags for weapon enchant items" },
                { "/conqlog sniff",                  "Toggle broad combat log sniffer" },
                { "/conqlog debugpotions",           "Toggle verbose potion detection output" },
                { "/conqlog debugconsumables",       "Toggle verbose consumable / enchant output" },
                { "/conqlog testpotion",             "Run potion pattern self-test" },
                { "/conqlog testenchant",            "Run weapon enchant pattern self-test" },
            },
        },
        {
            title = "Buff Tracker  ·  /rab  /rabuffs",
            rows = {
                { "/rab",                           "Show buff tracker help" },
                { "/rab show",                      "Show the main RABuffs window" },
                { "/rab hide",                      "Hide the main RABuffs window" },
                { "/rab versioncheck",              "Check addon version across raid / party" },
                { "/rab versioncheck guild",        "Check addon version across guild" },
                { "/rab profile list",              "List all saved profiles" },
                { "/rab profile save <name>",       "Save current bar layout as a profile" },
                { "/rab profile load <name>",       "Load a saved profile" },
                { "/rab profile delete <name>",     "Delete a saved profile" },
                { "/rab profile current",           "Show name of the active profile" },
            },
        },
        {
            title = "Buff Queries  ·  /rq  /rabq",
            rows = {
                { "/rq <buff>",                     "Query who has a specific buff" },
                { "/rq not <buff>",                 "Query who is MISSING a buff" },
                { "/rq <buff> <limit> <class>",     "Filter by count limit and/or class" },
                { "/rq raid <buff>",                "Print result to raid chat" },
                { "/rq party <buff>",               "Print result to party chat" },
                { "/rq officer <buff>",             "Print result to officer chat" },
                { "/rq w <player> <buff>",          "Whisper result to a specific player" },
                { "/rq c <channel> <buff>",         "Output result to a channel number" },
            },
        },
        {
            title = "Consumable Tracker  ·  /conqcons",
            rows = {
                { "/conqcons status",                "Show tracker status and registration info" },
                { "/conqcons debug",                 "Toggle cast event debug output" },
                { "/conqcons list",                  "List all tracked consumable spell IDs" },
                { "/conqcons callbacks",             "Show registered callback functions" },
                { "/conqcons clear",                 "Clear the spell name cache" },
            },
        },
        {
            title = "Spell Tracker  ·  /conqspells",
            rows = {
                { "/conqspells status",              "Show tracker status" },
                { "/conqspells debug",               "Toggle debug output" },
                { "/conqspells list",                "List all tracked spell IDs" },
                { "/conqspells stats",               "Show spell cast counts for current raid" },
                { "/conqspells guids",               "Show the GUID to player-name map" },
                { "/conqspells rebuild",             "Force rebuild the GUID map from roster" },
            },
        },
        {
            title = "Config Window  ·  /conqconfig",
            rows = {
                { "/conqconfig",                     "Open or close this window" },
            },
        },
    };

    local INDENT  = 6;
    local CMD_W   = 186;
    local DESC_W  = CONTENT_W - 56 - CMD_W;
    local ROW_H   = 13;
    local yOff    = 4;

    for _, section in ipairs(sections) do
        -- Section header
        local hdr = content:CreateFontString(nil, "OVERLAY", "GameFontNormal");
        hdr:SetPoint("TOPLEFT", INDENT, -yOff);
        hdr:SetText("|cff00d4ff" .. section.title .. "|r");
        yOff = yOff + 16;

        local div = content:CreateTexture(nil, "OVERLAY");
        div:SetWidth(CONTENT_W - 54);
        div:SetHeight(1);
        div:SetPoint("TOPLEFT", INDENT, -yOff);
        div:SetTexture(0.0, 0.55, 0.70, 0.60);
        yOff = yOff + 4;

        for _, row in ipairs(section.rows) do
            local cmdStr = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall");
            cmdStr:SetPoint("TOPLEFT", INDENT + 2, -yOff);
            cmdStr:SetWidth(CMD_W);
            cmdStr:SetJustifyH("LEFT");
            cmdStr:SetText("|cffaaaaaa" .. row[1] .. "|r");

            local descStr = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall");
            descStr:SetPoint("TOPLEFT", INDENT + CMD_W + 6, -yOff);
            descStr:SetWidth(DESC_W);
            descStr:SetJustifyH("LEFT");
            descStr:SetText("|cff888888" .. row[2] .. "|r");

            yOff = yOff + ROW_H;
        end

        yOff = yOff + 10;
    end

    content:SetHeight(yOff + 8);
    return tab;
end

-- ============================================================================
-- TAB: DEBUG
-- ============================================================================

local function CreateDebugTab(parent)
    local tab = CreateFrame("Frame", "CQ_Tab_Debug", parent);
    tab:SetWidth(CONTENT_W);
    tab:SetHeight(FRAME_H - 90);
    tab:SetPoint("TOPLEFT", parent, "TOPLEFT", CONTENT_LEFT, CONTENT_TOP);
    tab:Hide();

    -- Debug toggles
    local dbgHdr, dbgLine = MkHeader(tab, "Debug Output", tab, "TOPLEFT", 0, -4);

    -- dark box behind the 3 debug checkboxes
    -- MkCheck offsets: -6 (first), -4, -4. Each checkbox ~26px tall. Total ~98px.
    local dbgBoxBg = tab:CreateTexture(nil, "BACKGROUND");
    dbgBoxBg:SetWidth(CONTENT_W - 4);
    dbgBoxBg:SetHeight(98);
    dbgBoxBg:SetPoint("TOPLEFT", dbgLine, "BOTTOMLEFT", 0, -3);
    dbgBoxBg:SetTexture(0.12, 0.15, 0.22, 0.95);

    local debugPotCheck = MkCheck(tab, "CQ_Dbg_PotCheck",
        "Potion / tea detection (verbose)", dbgLine, "BOTTOMLEFT", 0, -6);
    debugPotCheck:SetScript("OnClick", function()
        if not CQ_Log then return; end
        CQ_Log.debugPotions = this:GetChecked() and true or false;
        DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[Conq] Potion debug: " ..
            (CQ_Log.debugPotions and "|cff00ff00ON|r" or "|cffff9900OFF|r"));
    end);

    local debugConsCheck = MkCheck(tab, "CQ_Dbg_ConsCheck",
        "Consumables / weapon enchants (verbose)", debugPotCheck, "BOTTOMLEFT", 0, -4);
    debugConsCheck:SetScript("OnClick", function()
        if not CQ_Log then return; end
        CQ_Log.debugConsumables = this:GetChecked() and true or false;
        DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[Conq] Consumable debug: " ..
            (CQ_Log.debugConsumables and "|cff00ff00ON|r" or "|cffff9900OFF|r"));
    end);

    local verboseExportCheck = MkCheck(tab, "CQ_Dbg_VerboseExport",
        "Verbose export keys (full names instead of shortened)", debugConsCheck, "BOTTOMLEFT", 0, -4);
    verboseExportCheck:SetScript("OnClick", function()
        if not CQ_Log then return; end
        CQ_Log.verboseExport = this:GetChecked() and true or false;
        CQ_Settings_Save();
        DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[Conq] Verbose export: " ..
            (CQ_Log.verboseExport and "|cff00ff00ON (full names)|r" or "|cffff9900OFF (shortened)|r"));
    end);

    -- Diagnostics
    local diagHdr, diagLine = MkHeader(tab, "Diagnostic Actions", verboseExportCheck, "BOTTOMLEFT", 0, -12);

    -- dark box behind the 2-column button grid (6 rows x 27px each + padding)
    local diagBoxBg = tab:CreateTexture(nil, "BACKGROUND");
    diagBoxBg:SetWidth(CONTENT_W - 4);
    diagBoxBg:SetHeight(172);
    diagBoxBg:SetPoint("TOPLEFT", diagLine, "BOTTOMLEFT", 0, -3);
    diagBoxBg:SetTexture(0.12, 0.15, 0.22, 0.95);

    -- Left column
    local colL = diagLine;

    local forceCheckBtn = MkBtn(tab, nil, 148, 22, "Force Buff Check", colL, "BOTTOMLEFT", 0, -8);
    forceCheckBtn:SetScript("OnClick", function()
        if CQ_Log.isLogging then
            CQ_Log.lastCheckTime = 0;
            if CQ_Log_PerformCheck then CQ_Log_PerformCheck(); end
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Conq] Forced buff check complete.|r");
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[Conq] Not currently logging.|r");
        end
    end);

    local testPotBtn = MkBtn(tab, nil, 148, 22, "Test Potion Patterns",
        forceCheckBtn, "BOTTOMLEFT", 0, -5);
    testPotBtn:SetScript("OnClick", function() SlashCmdList["CONQLOG"]("testpotion"); end);

    local testEnchBtn = MkBtn(tab, nil, 148, 22, "Test Enchant Patterns",
        testPotBtn, "BOTTOMLEFT", 0, -5);
    testEnchBtn:SetScript("OnClick", function() SlashCmdList["CONQLOG"]("testenchant"); end);

    local sunderBtn = MkBtn(tab, nil, 148, 22, "Sunder Diagnose",
        testEnchBtn, "BOTTOMLEFT", 0, -5);
    sunderBtn:SetScript("OnClick", function() SlashCmdList["CONQLOG"]("sunder"); end);

    local cacheBtn = MkBtn(tab, nil, 148, 22, "Dump Cache",
        sunderBtn, "BOTTOMLEFT", 0, -5);
    cacheBtn:SetScript("OnClick", function() SlashCmdList["CONQLOG"]("cache"); end);

    local benchBtn = MkBtn(tab, nil, 148, 22, "Benchmark",
        cacheBtn, "BOTTOMLEFT", 0, -5);
    benchBtn:SetScript("OnClick", function() SlashCmdList["CONQLOG"]("benchmark"); end);

    -- Right column (same row alignment as left, via TOPRIGHT anchors)
    local function RightOf(leftBtn, label, onClick)
        local btn = CreateFrame("Button", nil, tab);
        btn:SetWidth(148);
        btn:SetHeight(22);
        btn:SetPoint("TOPLEFT", leftBtn, "TOPRIGHT", 8, 0);
        btn:SetScript("OnClick", onClick);
        local _fs = btn:CreateFontString(nil,"OVERLAY","GameFontNormalSmall");
        _fs:SetAllPoints(); _fs:SetJustifyH("CENTER"); _fs:SetText(label); btn:SetFontString(_fs);
        CQ_SkinButton(btn, "ghost");
        return btn;
    end

    RightOf(forceCheckBtn, "Rebuild GUID Map", function()
        if CQ_Log_RebuildGuidMap then
            CQ_Log_RebuildGuidMap();
            local n = 0;
            for _ in pairs(CQ_Log_GuidMap) do n = n + 1; end
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[Conq] GUID map rebuilt — " .. n .. " entries.|r");
        end
    end);

    RightOf(testPotBtn, "Toggle Log Sniff", function()
        SlashCmdList["CONQLOG"]("sniff");
    end);

    RightOf(testEnchBtn, "Find Enchant Items", function()
        SlashCmdList["CONQLOG"]("findspells");
    end);

    RightOf(sunderBtn, "API Status", function()
        SlashCmdList["CONQLOG"]("superwow");
    end);

    RightOf(cacheBtn, "Consumable Status", function()
        SlashCmdList["CONQCONS"]("status");
    end);

    RightOf(benchBtn, "Spell Tracker Status", function()
        if SlashCmdList["CONQSPELLS"] then
            SlashCmdList["CONQSPELLS"]("status");
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[Conq] Spell Tracker not available (Nampower required)|r");
        end
    end);

    -- Client extension API summary
    local swHdr, swLine = MkHeader(tab, "Client Extension API Status", benchBtn, "BOTTOMLEFT", 0, -12);

    local function swRow(label, present)
        return label .. string.rep(" ", math.max(1, 28 - strlen(label))) ..
            (present and "|cff00ff00available|r" or "|cffff6666missing|r");
    end

    -- dark box behind the client extension API status text (4 rows)
    local swBoxBg = tab:CreateTexture(nil, "BACKGROUND");
    swBoxBg:SetWidth(CONTENT_W - 4);
    swBoxBg:SetHeight(62);
    swBoxBg:SetPoint("TOPLEFT", swLine, "BOTTOMLEFT", 0, -3);
    swBoxBg:SetTexture(0.12, 0.15, 0.22, 0.95);

    local swText = tab:CreateFontString("CQ_Dbg_SwText", "OVERLAY", "GameFontHighlightSmall");
    swText:SetPoint("TOPLEFT", swLine, "BOTTOMLEFT", 0, -6);
    swText:SetWidth(CONTENT_W - 4);
    swText:SetJustifyH("LEFT");

    local function swRefresh()
        swText:SetText(
            
            swRow("Nampower",                      GetNampowerVersion ~= nil) .. "\n" ..
            swRow("WriteCustomFile (export)",      WriteCustomFile   ~= nil) .. "\n" ..
            swRow("GetUnitGUID",                   GetUnitGUID       ~= nil)
        );
    end

    swRefresh();
    tab:SetScript("OnShow", swRefresh);

    return tab;
end

-- ============================================================================
-- TAB: CAST TEST
-- Full pipeline test tab.  Every button calls CQ_SimulateCastEvent() so the
-- entire real detection path is exercised: GUID resolution, CQ_ConsTracker_Tracked
-- lookup, CQ_ConsTracker_KeyMap lookup, raid membership check,
-- CQ_ConsInt_OnConsumable, castTrackedConsumables write, raid.players write.
--
-- Layout:
--   • Top bar  : status line + "Fire All" + debug-enable reminder
--   • Sections : one per consumable category, 2-column grid of "Cast" buttons
--   • Each button label shows the consumable name; colour indicates event type:
--       cyan   = SPELL_GO (potions/sappers/poisons)
--       orange = AURA_CAST (weapon enchants/oils/stones)
--       grey   = buff-poll only (no cast event — shown for reference, disabled)
-- ============================================================================

local function CreateCastTestTab(parent)
    local tab = CreateFrame("Frame", "CQ_Tab_Casttest", parent);
    tab:SetWidth(CONTENT_W);
    tab:SetHeight(FRAME_H - 90);
    tab:SetPoint("TOPLEFT", parent, "TOPLEFT", CONTENT_LEFT, CONTENT_TOP);
    tab:Hide();

    local scrollFrame = CreateFrame("ScrollFrame", "CQ_CT_Scroll", tab,
        "UIPanelScrollFrameTemplate");
    scrollFrame:SetWidth(CONTENT_W - 20);
    scrollFrame:SetHeight(FRAME_H - 98);
    scrollFrame:SetPoint("TOPLEFT", 0, 0);

    local content = CreateFrame("Frame", nil, scrollFrame);
    content:SetWidth(CONTENT_W - 36);
    content:SetHeight(10);
    scrollFrame:SetScrollChild(content);
    CQ_SkinScrollFrame(scrollFrame, "CQ_CT_Scroll");

    local bg = content:CreateTexture(nil, "BACKGROUND");
    bg:SetAllPoints(content);
    bg:SetTexture(0.12, 0.15, 0.22, 0.98);

    local M     = 6;
    local IW    = CONTENT_W - 36 - M * 2;
    local COL_W = math.floor(IW / 2);
    local ROW_H = 22;
    local BTN_W = 48;
    local BTN_H = 18;
    local HDR_H = 16;
    local yOff  = 6;

    -- ── Section header + divider ──────────────────────────────────────────
    local function CTHdr(text, r, g, b)
        yOff = yOff + 10;
        local hdr = content:CreateFontString(nil, "OVERLAY", "GameFontNormal");
        hdr:SetPoint("TOPLEFT", M, -yOff);
        local cr = r or 0.0; local cg = g or 0.831; local cb = b or 1.0;
        hdr:SetTextColor(cr, cg, cb);
        hdr:SetText(text);
        yOff = yOff + HDR_H;
        local div = content:CreateTexture(nil, "OVERLAY");
        div:SetWidth(IW); div:SetHeight(1);
        div:SetPoint("TOPLEFT", M, -yOff);
        div:SetTexture(cr * 0.6, cg * 0.6, cb * 0.6, 0.7);
        yOff = yOff + 6;
    end

    -- ── Single cast-test button ───────────────────────────────────────────
    -- spellID   : the spell ID to pass to CQ_SimulateCastEvent
    -- label     : display name
    -- eventType : "SPELL_GO_OTHER" | "AURA_CAST_ON_OTHER" | nil (disabled)
    -- col       : 0 or 1
    local function CTRow(uniqueSuffix, label, spellID, eventType, col)
        local xBase = M + col * COL_W;

        local btn = CreateFrame("Button", "CQ_CT_Btn_" .. uniqueSuffix, content);
        btn:SetWidth(BTN_W); btn:SetHeight(BTN_H);
        btn:SetPoint("TOPLEFT", xBase, -yOff);

        local _fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall");
        _fs:SetAllPoints(); _fs:SetJustifyH("CENTER");
        btn:SetFontString(_fs);

        local lbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall");
        lbl:SetPoint("LEFT", btn, "RIGHT", 4, 0);
        lbl:SetWidth(COL_W - BTN_W - 8);
        lbl:SetJustifyH("LEFT");

        if not eventType then
            -- Buff-poll only: no cast event exists, show greyed out
            _fs:SetText("–");
            lbl:SetText("|cff555555" .. label .. "|r");
            btn:SetBackdrop({
                bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                tile = true, tileSize = 16,
                insets = { left=0, right=0, top=0, bottom=0 }
            });
            btn:SetBackdropColor(0.10, 0.10, 0.10, 0.7);
            btn:Disable();
        else
            -- Cast event (all types: SPELL_GO and AURA_CAST both use the same primary style)
            _fs:SetText("Cast");
            lbl:SetText("|cff00ffff" .. label .. "|r");
            CQ_SkinButton(btn, "primary");
            local sID = spellID; local eT = eventType;
            btn:SetScript("OnClick", function()
                if not CQ_Log or not CQ_Log.isLogging then
                    DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[CastTest] Start logging first (/conqlog start).|r");
                    return;
                end
                local ok = CQ_SimulateCastEvent(sID, UnitName("player"), eT, false);
                if ok then
                    local safeLabel = string.gsub(label, "%.", "");
                    local evLabel = (eT == "AURA_CAST_ON_OTHER" or eT == "AURA_CAST_ON_SELF")
                        and "AURA_CAST" or "SPELL_GO";
                    DEFAULT_CHAT_FRAME:AddMessage(
                        "|cff00ffff[CastTest] " .. evLabel .. " → " .. safeLabel ..
                        " (spellID=" .. sID .. ")|r");
                end
            end);
        end

        return btn;
    end

    -- ── Advance col/row cursor ────────────────────────────────────────────
    local curCol = 0;
    local function CT(suffix, label, spellID, eventType)
        CTRow(suffix, label, spellID, eventType, curCol);
        curCol = curCol + 1;
        if curCol >= 2 then curCol = 0; yOff = yOff + ROW_H; end
    end
    local function CTFlush()
        if curCol > 0 then curCol = 0; yOff = yOff + ROW_H; end
    end

    -- ================================================================
    -- TOP BAR
    -- ================================================================
    local statusNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall");
    statusNote:SetPoint("TOPLEFT", M, -yOff);
    statusNote:SetWidth(IW);
    statusNote:SetJustifyH("LEFT");
    statusNote:SetText("|cff00ffff Cyan|r = SPELL_GO / AURA_CAST   " ..
        "|cff888888Grey|r = buff-poll only (no event)");
    yOff = yOff + 16;

    -- Debug hint
    local dbgNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall");
    dbgNote:SetPoint("TOPLEFT", M, -yOff);
    dbgNote:SetWidth(IW);
    dbgNote:SetJustifyH("LEFT");
    dbgNote:SetText("|cff666666Enable /conqcons debug and /conqlog debugconsumables to trace each pipeline stage in chat.|r");
    yOff = yOff + 14;

    -- "Fire All Mapped" button
    local fireAllBtn = CreateFrame("Button", "CQ_CT_FireAll", content);
    fireAllBtn:SetWidth(150); fireAllBtn:SetHeight(20);
    fireAllBtn:SetPoint("TOPLEFT", M, -yOff);
    do
        local _fs = fireAllBtn:CreateFontString(nil,"OVERLAY","GameFontNormalSmall");
        _fs:SetAllPoints(); _fs:SetJustifyH("CENTER");
        _fs:SetText("Fire All Mapped"); fireAllBtn:SetFontString(_fs);
        CQ_SkinButton(fireAllBtn, "primary");
    end

    -- "Fire Bad GUID" button (tests retry queue)
    local badGuidBtn = CreateFrame("Button", "CQ_CT_BadGuid", content);
    badGuidBtn:SetWidth(140); badGuidBtn:SetHeight(20);
    badGuidBtn:SetPoint("LEFT", fireAllBtn, "RIGHT", 6, 0);
    do
        local _fs = badGuidBtn:CreateFontString(nil,"OVERLAY","GameFontNormalSmall");
        _fs:SetAllPoints(); _fs:SetJustifyH("CENTER");
        _fs:SetText("Fire Bad GUID"); badGuidBtn:SetFontString(_fs);
        CQ_SkinButton(badGuidBtn, "ghost");
    end
    badGuidBtn:SetScript("OnClick", function()
        if not CQ_Log or not CQ_Log.isLogging then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[CastTest] Start logging first.|r");
            return;
        end
        -- Fire with an unresolvable GUID to exercise the 15s retry queue
        CQ_SimulateCastEvent(25123, UnitName("player"), "SPELL_GO_OTHER", true);
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cffff9900[CastTest] Bad GUID fired — event should land in retry queue. " ..
            "Use /conqcons queue to inspect it.|r");
    end);

    yOff = yOff + 28;

    local topDiv = content:CreateTexture(nil, "OVERLAY");
    topDiv:SetWidth(IW); topDiv:SetHeight(1);
    topDiv:SetPoint("TOPLEFT", M, -yOff);
    topDiv:SetTexture(0.22, 0.30, 0.42, 0.8);
    yOff = yOff + 8;

    -- ================================================================
    -- SECTION: Weapon Oils  (AURA_CAST via CQ_ConsTracker)
    -- ================================================================
    CTHdr("Weapon Oils", 1.0, 0.65, 0.1);
    CT("brillmanaoil",     "Brilliant Mana Oil",    25123, "AURA_CAST_ON_OTHER");
    CT("lessermanaoil",    "Lesser Mana Oil",        20747, "AURA_CAST_ON_OTHER");
    CT("brillwizardoil",   "Brilliant Wizard Oil",   25122, "AURA_CAST_ON_OTHER");
    CT("blessedwizardoil", "Blessed Wizard Oil",     28898, "AURA_CAST_ON_OTHER");
    CT("wizardoil",        "Wizard Oil",             25121, "AURA_CAST_ON_OTHER");
    CT("frostoil",         "Frost Oil",               3829, "AURA_CAST_ON_OTHER");
    CT("shadowoil",        "Shadow Oil",              3594, "AURA_CAST_ON_OTHER");
    CTFlush();

    -- ================================================================
    -- SECTION: Weapon Stones  (AURA_CAST via CQ_ConsTracker)
    -- ================================================================
    CTHdr("Weapon Stones", 1.0, 0.65, 0.1);
    CT("elemstone",   "Elemental Sharp. Stone", 22756, "AURA_CAST_ON_OTHER");
    CT("densestone",  "Dense Sharp. Stone",      16138, "AURA_CAST_ON_OTHER");
    CT("consecstone", "Consecrated Stone",       28891, "AURA_CAST_ON_OTHER");
    CT("denseweight", "Dense Weightstone",       16622, "AURA_CAST_ON_OTHER");
    CTFlush();

    -- ================================================================
    -- SECTION: Rogue Poisons  (SPELL_GO via CQ_ConsTracker)
    -- No buff bar for other players — Nampower only, all ranks.
    -- ================================================================
    CTHdr("Rogue Poisons", 0.0, 0.831, 1.0);
    CT("deadlyp5",    "Deadly Poison V",         11357, "SPELL_GO_OTHER");
    CT("deadlyp4",    "Deadly Poison IV",        11356, "SPELL_GO_OTHER");
    CT("deadlyp3",    "Deadly Poison III",       11355, "SPELL_GO_OTHER");
    CT("deadlyp2",    "Deadly Poison II",         2824, "SPELL_GO_OTHER");
    CT("deadlyp1",    "Deadly Poison",            2823, "SPELL_GO_OTHER");
    CT("instantp6",   "Instant Poison VI",        8679, "SPELL_GO_OTHER");
    CT("instantp5",   "Instant Poison V",         8688, "SPELL_GO_OTHER");
    CT("instantp4",   "Instant Poison IV",        8687, "SPELL_GO_OTHER");
    CT("instantp3",   "Instant Poison III",       8686, "SPELL_GO_OTHER");
    CT("instantp2",   "Instant Poison II",        8685, "SPELL_GO_OTHER");
    CT("instantp1",   "Instant Poison",           8680, "SPELL_GO_OTHER");
    CT("woundp5",     "Wound Poison V",          13219, "SPELL_GO_OTHER");
    CT("woundp4",     "Wound Poison IV",         13218, "SPELL_GO_OTHER");
    CT("woundp3",     "Wound Poison III",        13223, "SPELL_GO_OTHER");
    CT("woundp2",     "Wound Poison II",         13222, "SPELL_GO_OTHER");
    CT("woundp1",     "Wound Poison",            13220, "SPELL_GO_OTHER");
    CT("mindnumb3",   "Mind-numbing III",         5763, "SPELL_GO_OTHER");
    CT("mindnumb2",   "Mind-numbing II",          8694, "SPELL_GO_OTHER");
    CT("mindnumb1",   "Mind-numbing",             5761, "SPELL_GO_OTHER");
    CT("cripplingp2", "Crippling Poison II",      3408, "SPELL_GO_OTHER");
    CT("cripplingp1", "Crippling Poison",         3409, "SPELL_GO_OTHER");
    CTFlush();

    -- ================================================================
    -- SECTION: Explosives  (SPELL_GO via CQ_ConsTracker)
    -- ================================================================
    CTHdr("Explosives", 0.0, 0.831, 1.0);
    CT("sapper", "Goblin Sapper Charge", 13241, "SPELL_GO_OTHER");
    CTFlush();

    -- ================================================================
    -- SECTION: Flasks  (SPELL_GO via CQ_Log_ConsumableSpellIDs)
    -- ================================================================
    CTHdr("Flasks", 0.0, 0.831, 1.0);
    CT("flask",        "Flask of Supreme Power",  17628, "SPELL_GO_OTHER");
    CT("titans",       "Flask of the Titans",      17626, "SPELL_GO_OTHER");
    CT("wisdom",       "Flask of Distilled Wisdom",17627, "SPELL_GO_OTHER");
    CT("chromaticres", "Flask of Chromatic Res.",  17629, "SPELL_GO_OTHER");
    CTFlush();

    -- ================================================================
    -- SECTION: Battle Elixirs  (SPELL_GO via CQ_Log_ConsumableSpellIDs)
    -- ================================================================
    CTHdr("Battle Elixirs", 0.0, 0.831, 1.0);
    CT("mongoose",       "Elixir of the Mongoose",    17538, "SPELL_GO_OTHER");
    CT("giants",         "Elixir of the Giants",       11405, "SPELL_GO_OTHER");
    CT("greateragility", "Elixir of Greater Agility",  11334, "SPELL_GO_OTHER");
    CT("agilityelixir",  "Elixir of Agility",           11328, "SPELL_GO_OTHER");
    CT("firewater",      "Winterfall Firewater",        17038, "SPELL_GO_OTHER");
    CT("demonslaying",   "Elixir of Demonslaying",      11406, "SPELL_GO_OTHER");
    CTFlush();

    -- ================================================================
    -- SECTION: Guardian Elixirs  (SPELL_GO via CQ_Log_ConsumableSpellIDs)
    -- ================================================================
    CTHdr("Guardian Elixirs", 0.0, 0.831, 1.0);
    CT("elixirfortitude", "Elixir of Fortitude",        3593, "SPELL_GO_OTHER");
    CT("supdef",          "Elixir of Superior Defense", 11348, "SPELL_GO_OTHER");
    CTFlush();

    -- ================================================================
    -- SECTION: Spell Power Elixirs  (SPELL_GO via CQ_Log_ConsumableSpellIDs)
    -- ================================================================
    CTHdr("Spell Power Elixirs", 0.0, 0.831, 1.0);
    CT("greaterarcane",      "Greater Arcane Elixir",        17539, "SPELL_GO_OTHER");
    CT("greaterfirepower",   "Elixir of Greater Firepower",  26276, "SPELL_GO_OTHER");
    CT("greaterarcanepower", "Elixir of Greater Arcane Pow.",56545, "SPELL_GO_OTHER");
    CT("greaterfrostpower",  "Elixir of Greater Frost Pow.", 56544, "SPELL_GO_OTHER");
    CT("greaternaturepower", "Elixir of Greater Nature Pow.",45988, "SPELL_GO_OTHER");
    CT("shadowpower",        "Elixir of Shadow Power",       11474, "SPELL_GO_OTHER");
    CT("frostpower",         "Elixir of Frost Power",        21920, "SPELL_GO_OTHER");
    CT("dreamshard",         "Dreamshard Elixir",            45427, "SPELL_GO_OTHER");
    CT("dreamtonic",         "Dreamtonic",                   45489, "SPELL_GO_OTHER");
    CT("arcaneelixir",       "Arcane Elixir",                11390, "SPELL_GO_OTHER");
    CT("firepowerelixir",    "Elixir of Firepower",           7844, "SPELL_GO_OTHER");
    CT("elixirofthesages",   "Elixir of the Sages",          17535, "SPELL_GO_OTHER");
    CTFlush();

    -- ================================================================
    -- SECTION: Protection Potions  (SPELL_GO via CQ_Log_ConsumableSpellIDs)
    -- ================================================================
    CTHdr("Protection Potions", 0.0, 0.831, 1.0);
    CT("greaterfirepot",   "Greater Fire Prot.",    17543, "SPELL_GO_OTHER");
    CT("greaterfrostpot",  "Greater Frost Prot.",   17544, "SPELL_GO_OTHER");
    CT("greaternaturepot", "Greater Nature Prot.",  17546, "SPELL_GO_OTHER");
    CT("greaterarcanepot", "Greater Arcane Prot.",  17549, "SPELL_GO_OTHER");
    CT("greatershadowpot", "Greater Shadow Prot.",  17548, "SPELL_GO_OTHER");
    CT("greaterholypot",   "Greater Holy Prot.",    17545, "SPELL_GO_OTHER");
    CT("frozenrune",       "Frozen Rune",           29432, "SPELL_GO_OTHER");
    CT("firepot",          "Fire Prot. Potion",      7233, "SPELL_GO_OTHER");
    CT("frostpot",         "Frost Prot. Potion",     7239, "SPELL_GO_OTHER");
    CT("shadowpot",        "Shadow Prot. Potion",    7242, "SPELL_GO_OTHER");
    CT("holypot",          "Holy Prot. Potion",      7245, "SPELL_GO_OTHER");
    CT("naturepot",        "Nature Prot. Potion",    7254, "SPELL_GO_OTHER");
    CTFlush();

    -- ================================================================
    -- SECTION: Utility Potions  (SPELL_GO via CQ_Log_ConsumableSpellIDs)
    -- ================================================================
    CTHdr("Utility Potions", 0.0, 0.831, 1.0);
    CT("mageblood",         "Mageblood Potion",   24363, "SPELL_GO_OTHER");
    CT("freeactionpotion",  "Free Action Potion",  6615, "SPELL_GO_OTHER");
    CT("restorativepotion", "Restorative Potion", 11359, "SPELL_GO_OTHER");
    CTFlush();

    -- ================================================================
    -- SECTION: Zanza  (SPELL_GO via CQ_Log_ConsumableSpellIDs)
    -- ================================================================
    CTHdr("Zanza Potions", 0.0, 0.831, 1.0);
    CT("spiritofzanza",    "Spirit of Zanza",    24382, "SPELL_GO_OTHER");
    CT("swiftnessofzanza", "Swiftness of Zanza", 24383, "SPELL_GO_OTHER");
    CT("sheenofzanza",     "Sheen of Zanza",      24417, "SPELL_GO_OTHER");
    CTFlush();

    -- ================================================================
    -- SECTION: Juju  (SPELL_GO via CQ_Log_ConsumableSpellIDs)
    -- ================================================================
    CTHdr("Juju", 0.0, 0.831, 1.0);
    CT("jujupower",  "Juju Power",  16323, "SPELL_GO_OTHER");
    CT("jujumight",  "Juju Might",  16329, "SPELL_GO_OTHER");
    CT("jujuflurry", "Juju Flurry", 16322, "SPELL_GO_OTHER");
    CT("jujuchill",  "Juju Chill",  16325, "SPELL_GO_OTHER");
    CT("jujuember",  "Juju Ember",  16326, "SPELL_GO_OTHER");
    CT("jujuescape", "Juju Escape", 16321, "SPELL_GO_OTHER");
    CT("jujuguile",  "Juju Guile",  16327, "SPELL_GO_OTHER");
    CTFlush();

    -- ================================================================
    -- SECTION: Blasted Lands  (SPELL_GO via CQ_Log_ConsumableSpellIDs)
    -- ================================================================
    CTHdr("Blasted Lands", 0.0, 0.831, 1.0);
    CT("roids",         "R.O.I.D.S.",              10667, "SPELL_GO_OTHER");
    CT("scorpok",       "Ground Scorpok Assay",     10669, "SPELL_GO_OTHER");
    CT("cerebralcortex","Cerebral Cortex Compound", 10692, "SPELL_GO_OTHER");
    CT("lungjuice",     "Lung Juice Cocktail",       10668, "SPELL_GO_OTHER");
    CT("gizzardgum",    "Gizzard Gum",               10693, "SPELL_GO_OTHER");
    CTFlush();

    -- ================================================================
    -- SECTION: Food & Drink  (SPELL_GO via CQ_Log_ConsumableSpellIDs)
    -- ================================================================
    CTHdr("Food & Drink", 0.0, 0.831, 1.0);
    CT("squid",          "Grilled Squid",            18230, "SPELL_GO_OTHER");
    CT("nightfinsoup",   "Nightfin Soup",             18233, "SPELL_GO_OTHER");
    CT("tuber",          "Runn Tum Tuber Surprise",   22731, "SPELL_GO_OTHER");
    CT("desertdumpling", "Smoked Desert Dumpling",    24800, "SPELL_GO_OTHER");
    CT("tenderwolf",     "Tender Wolf Steak",         10256, "SPELL_GO_OTHER");
    CT("sagefish",       "Sagefish Delight",          25888, "SPELL_GO_OTHER");
    CT("mushroomstam",   "Hardened Mushroom",         25660, "SPELL_GO_OTHER");
    CT("dragonbreath",   "Dragonbreath Chili",        15852, "SPELL_GO_OTHER");
    CT("gurubashigumbo", "Gurubashi Gumbo",           46084, "SPELL_GO_OTHER");
    CT("telabimmedley",  "Tel'Abim Medley",           57045, "SPELL_GO_OTHER");
    CT("telabimdelight", "Tel'Abim Delight",          57043, "SPELL_GO_OTHER");
    CT("telabimsurprise","Tel'Abim Surprise",         57055, "SPELL_GO_OTHER");
    CT("gilneasstew",    "Gilneas Hot Stew",          45626, "SPELL_GO_OTHER");
    CT("gordokgrog",     "Gordok Green Grog",         22789, "SPELL_GO_OTHER");
    CT("rumseyrum",      "Rumsey Rum Black Label",    25804, "SPELL_GO_OTHER");
    CT("merlot",         "Medivh's Merlot",           57106, "SPELL_GO_OTHER");
    CT("merlotblue",     "Medivh's Merlot Blue",      57107, "SPELL_GO_OTHER");
    CT("herbalsalad",    "Herbal Salad",               49552, "SPELL_GO_OTHER");
    CTFlush();

    -- ================================================================
    -- SECTION: Concoctions  (SPELL_GO via CQ_Log_ConsumableSpellIDs)
    -- ================================================================
    CTHdr("Concoctions", 0.0, 0.831, 1.0);
    CT("arcanegiants",    "Concoction: Arcane Giant",    36931, "SPELL_GO_OTHER");
    CT("emeraldmongoose", "Concoction: Emerald Mongoose", 36928, "SPELL_GO_OTHER");
    CT("dreamwater",      "Concoction: Dreamwater",       36934, "SPELL_GO_OTHER");
    CTFlush();

    -- ================================================================
    -- Wire up "Fire All" — every cast-trackable spell, one representative
    -- rank per consumable type for poisons, full list for everything else.
    -- ================================================================
    local MAPPED_SPELLS = {
        -- Weapon Oils (AURA_CAST)
        { 25123, "AURA_CAST_ON_OTHER" },  -- Brilliant Mana Oil
        { 20747, "AURA_CAST_ON_OTHER" },  -- Lesser Mana Oil
        { 25122, "AURA_CAST_ON_OTHER" },  -- Brilliant Wizard Oil
        { 28898, "AURA_CAST_ON_OTHER" },  -- Blessed Wizard Oil
        { 25121, "AURA_CAST_ON_OTHER" },  -- Wizard Oil
        { 3829,  "AURA_CAST_ON_OTHER" },  -- Frost Oil
        { 3594,  "AURA_CAST_ON_OTHER" },  -- Shadow Oil
        -- Weapon Stones (AURA_CAST)
        { 22756, "AURA_CAST_ON_OTHER" },  -- Elemental Sharpening Stone
        { 16138, "AURA_CAST_ON_OTHER" },  -- Dense Sharpening Stone
        { 28891, "AURA_CAST_ON_OTHER" },  -- Consecrated Stone
        { 16622, "AURA_CAST_ON_OTHER" },  -- Dense Weightstone
        -- Rogue Poisons — highest rank per type (SPELL_GO)
        { 11357, "SPELL_GO_OTHER" },  -- Deadly Poison V
        { 8679,  "SPELL_GO_OTHER" },  -- Instant Poison VI
        { 13219, "SPELL_GO_OTHER" },  -- Wound Poison V
        { 5763,  "SPELL_GO_OTHER" },  -- Mind-numbing Poison III
        { 3408,  "SPELL_GO_OTHER" },  -- Crippling Poison II
        -- Explosives
        { 13241, "SPELL_GO_OTHER" },  -- Goblin Sapper
        -- Flasks
        { 17628, "SPELL_GO_OTHER" },  -- Flask of Supreme Power
        { 17626, "SPELL_GO_OTHER" },  -- Flask of the Titans
        { 17627, "SPELL_GO_OTHER" },  -- Flask of Distilled Wisdom
        { 17629, "SPELL_GO_OTHER" },  -- Flask of Chromatic Resistance
        -- Battle Elixirs
        { 17538, "SPELL_GO_OTHER" },  { 11405, "SPELL_GO_OTHER" },
        { 11334, "SPELL_GO_OTHER" },  { 11328, "SPELL_GO_OTHER" },
        { 17038, "SPELL_GO_OTHER" },  { 11406, "SPELL_GO_OTHER" },
        -- Guardian Elixirs
        { 3593,  "SPELL_GO_OTHER" },  { 11348, "SPELL_GO_OTHER" },
        -- Spell Power Elixirs
        { 17539, "SPELL_GO_OTHER" },  { 26276, "SPELL_GO_OTHER" },
        { 56545, "SPELL_GO_OTHER" },  { 56544, "SPELL_GO_OTHER" },
        { 45988, "SPELL_GO_OTHER" },  { 11474, "SPELL_GO_OTHER" },
        { 21920, "SPELL_GO_OTHER" },  { 45427, "SPELL_GO_OTHER" },
        { 45489, "SPELL_GO_OTHER" },  { 11390, "SPELL_GO_OTHER" },
        { 7844,  "SPELL_GO_OTHER" },  { 17535, "SPELL_GO_OTHER" },
        -- Protection Potions
        { 17543, "SPELL_GO_OTHER" },  { 17544, "SPELL_GO_OTHER" },
        { 17546, "SPELL_GO_OTHER" },  { 17549, "SPELL_GO_OTHER" },
        { 17548, "SPELL_GO_OTHER" },  { 17545, "SPELL_GO_OTHER" },
        { 29432, "SPELL_GO_OTHER" },
        -- Utility Potions
        { 24363, "SPELL_GO_OTHER" },  { 6615,  "SPELL_GO_OTHER" },
        { 11359, "SPELL_GO_OTHER" },
        -- Zanza
        { 24382, "SPELL_GO_OTHER" },  { 24383, "SPELL_GO_OTHER" },
        { 24417, "SPELL_GO_OTHER" },
        -- Juju
        { 16323, "SPELL_GO_OTHER" },  { 16329, "SPELL_GO_OTHER" },
        { 16322, "SPELL_GO_OTHER" },  { 16325, "SPELL_GO_OTHER" },
        { 16326, "SPELL_GO_OTHER" },  { 16321, "SPELL_GO_OTHER" },
        { 16327, "SPELL_GO_OTHER" },
        -- Blasted Lands
        { 10667, "SPELL_GO_OTHER" },  { 10669, "SPELL_GO_OTHER" },
        { 10692, "SPELL_GO_OTHER" },  { 10668, "SPELL_GO_OTHER" },
        { 10693, "SPELL_GO_OTHER" },
        -- Food
        { 18230, "SPELL_GO_OTHER" },  { 18233, "SPELL_GO_OTHER" },
        { 22731, "SPELL_GO_OTHER" },  { 24800, "SPELL_GO_OTHER" },
        { 10256, "SPELL_GO_OTHER" },  { 25888, "SPELL_GO_OTHER" },
        { 25660, "SPELL_GO_OTHER" },  { 15852, "SPELL_GO_OTHER" },
        { 46084, "SPELL_GO_OTHER" },  { 57045, "SPELL_GO_OTHER" },
        { 57043, "SPELL_GO_OTHER" },  { 57055, "SPELL_GO_OTHER" },
        { 45626, "SPELL_GO_OTHER" },  { 22789, "SPELL_GO_OTHER" },
        { 25804, "SPELL_GO_OTHER" },  { 57106, "SPELL_GO_OTHER" },
        { 57107, "SPELL_GO_OTHER" },  { 49552, "SPELL_GO_OTHER" },
        -- Concoctions
        { 36931, "SPELL_GO_OTHER" },  { 36928, "SPELL_GO_OTHER" },
        { 36934, "SPELL_GO_OTHER" },
    };

    fireAllBtn:SetScript("OnClick", function()
        if not CQ_Log or not CQ_Log.isLogging then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff9900[CastTest] Start logging first (/conqlog start).|r");
            return;
        end
        local player = UnitName("player");
        local fired, failed = 0, 0;
        for _, t in ipairs(MAPPED_SPELLS) do
            if CQ_SimulateCastEvent(t[1], player, t[2], false) then
                fired = fired + 1;
            else
                failed = failed + 1;
            end
        end
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff00ff00[CastTest] Fired " .. fired .. " mapped spells" ..
            (failed > 0 and (", |cffff9900" .. failed .. " failed|r") or "") ..
            ". Check /conqcons debug output.|r");
    end);

    yOff = yOff + 10;
    content:SetHeight(yOff);
    return tab;
end

-- ============================================================================
-- MAIN FRAME & TAB CONTROLLER
-- ============================================================================

function CQ_Config_Create()
    local frame = CreateFrame("Frame", "CQ_ConfigFrame", UIParent);
    frame:SetWidth(FRAME_W);
    frame:SetHeight(FRAME_H);
    frame:SetPoint("CENTER", UIParent, "CENTER");
    frame:SetFrameStrata("DIALOG");
    frame:EnableMouse(true);
    frame:SetMovable(true);
    frame:RegisterForDrag("LeftButton");
    frame:SetScript("OnDragStart", function() this:StartMoving(); end);
    frame:SetScript("OnDragStop", function() this:StopMovingOrSizing(); end);
    frame:Hide();

    frame:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        tile = true, tileSize = 16,
        insets = { left = 0, right = 0, top = 0, bottom = 0 }
    });
    frame:SetBackdropColor(0.09, 0.11, 0.16, 0.97);
    -- 1px border drawn manually as four thin textures
    local bdrT = frame:CreateTexture(nil,"OVERLAY"); bdrT:SetHeight(1); bdrT:SetTexture(0.22,0.30,0.42,0.9); bdrT:SetPoint("TOPLEFT",frame,"TOPLEFT",0,0); bdrT:SetPoint("TOPRIGHT",frame,"TOPRIGHT",0,0);
    local bdrB = frame:CreateTexture(nil,"OVERLAY"); bdrB:SetHeight(1); bdrB:SetTexture(0.22,0.30,0.42,0.9); bdrB:SetPoint("BOTTOMLEFT",frame,"BOTTOMLEFT",0,0); bdrB:SetPoint("BOTTOMRIGHT",frame,"BOTTOMRIGHT",0,0);
    local bdrL = frame:CreateTexture(nil,"OVERLAY"); bdrL:SetWidth(1);  bdrL:SetTexture(0.22,0.30,0.42,0.9); bdrL:SetPoint("TOPLEFT",frame,"TOPLEFT",0,0); bdrL:SetPoint("BOTTOMLEFT",frame,"BOTTOMLEFT",0,0);
    local bdrR = frame:CreateTexture(nil,"OVERLAY"); bdrR:SetWidth(1);  bdrR:SetTexture(0.22,0.30,0.42,0.9); bdrR:SetPoint("TOPRIGHT",frame,"TOPRIGHT",0,0); bdrR:SetPoint("BOTTOMRIGHT",frame,"BOTTOMRIGHT",0,0);

    -- Title bar background
    local titleBg = frame:CreateTexture(nil, "BACKGROUND");
    titleBg:SetWidth(FRAME_W - 8);
    titleBg:SetHeight(40);
    titleBg:SetPoint("TOP", 0, -4);
    titleBg:SetTexture(0.07, 0.09, 0.14, 0.97);

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge");
    title:SetPoint("TOP", 0, -14);
    title:SetText("|cff00ccffConqsumibles|r  |cff4a6080·  Raid Logger|r");

    local closeBtn = CreateFrame("Button", nil, frame);
    closeBtn:SetWidth(22); closeBtn:SetHeight(22);
    closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -8);
    -- Background fill
    local closeBg = closeBtn:CreateTexture(nil,"BACKGROUND");
    closeBg:SetAllPoints(); closeBg:SetTexture(0.18,0.04,0.04,0.8);
    -- Border lines
    local cbT = closeBtn:CreateTexture(nil,"OVERLAY"); cbT:SetHeight(1);
        cbT:SetPoint("TOPLEFT",closeBtn,"TOPLEFT",0,0); cbT:SetPoint("TOPRIGHT",closeBtn,"TOPRIGHT",0,0);
    local cbBo = closeBtn:CreateTexture(nil,"OVERLAY"); cbBo:SetHeight(1);
        cbBo:SetPoint("BOTTOMLEFT",closeBtn,"BOTTOMLEFT",0,0); cbBo:SetPoint("BOTTOMRIGHT",closeBtn,"BOTTOMRIGHT",0,0);
    local cbL = closeBtn:CreateTexture(nil,"OVERLAY"); cbL:SetWidth(1);
        cbL:SetPoint("TOPLEFT",closeBtn,"TOPLEFT",0,0); cbL:SetPoint("BOTTOMLEFT",closeBtn,"BOTTOMLEFT",0,0);
    local cbR2 = closeBtn:CreateTexture(nil,"OVERLAY"); cbR2:SetWidth(1);
        cbR2:SetPoint("TOPRIGHT",closeBtn,"TOPRIGHT",0,0); cbR2:SetPoint("BOTTOMRIGHT",closeBtn,"BOTTOMRIGHT",0,0);
    local function SetCloseBorder(r,g,b)
        cbT:SetTexture(r,g,b,1); cbBo:SetTexture(r,g,b,1);
        cbL:SetTexture(r,g,b,1); cbR2:SetTexture(r,g,b,1);
    end
    SetCloseBorder(0.55,0.12,0.12);
    local closeLabel = closeBtn:CreateFontString(nil,"OVERLAY","GameFontNormalLarge");
    closeLabel:SetAllPoints(); closeLabel:SetText("|cffdd3333X|r"); closeLabel:SetJustifyH("CENTER");
    closeBtn:SetScript("OnEnter", function()
        closeBg:SetTexture(0.35,0.04,0.04,1);
        SetCloseBorder(1.0,0.25,0.25);
        closeLabel:SetText("|cffff4444X|r");
    end);
    closeBtn:SetScript("OnLeave", function()
        closeBg:SetTexture(0.18,0.04,0.04,0.8);
        SetCloseBorder(0.55,0.12,0.12);
        closeLabel:SetText("|cffdd3333X|r");
    end);
    closeBtn:SetScript("OnClick", function() frame:Hide(); end);

    -- Tab buttons
    local tabDefs = {
        { id = "status",      label = "Status"      },
        { id = "options",     label = "Options"     },
        { id = "consumables", label = "Consumables" },
        { id = "commands",    label = "Commands"    },
        { id = "debug",       label = "Debug"       },
        { id = "simulate",    label = "Simulate"    },
        { id = "casttest",    label = "Cast Test"   },
    };

    -- Compute tab width so all tabs fit within the frame.
    -- 7 tabs x (TAB_W + 4) gap: available = FRAME_W - 28 (left+right margin)
    local availTabW = FRAME_W - 28;
    local numTabs   = table.getn(tabDefs);
    local dynTabW   = math.floor((availTabW - (numTabs - 1) * 4) / numTabs);

    for i, def in ipairs(tabDefs) do
        local btn = CreateFrame("Button", "CQ_TabBtn_" .. def.id, frame);
        btn:SetWidth(dynTabW);
        btn:SetHeight(TAB_H);
        btn:SetPoint("TOPLEFT", frame, "TOPLEFT",
            14 + (i - 1) * (dynTabW + 4), -48);
        local _tabfs = btn:CreateFontString(nil,"OVERLAY","GameFontNormalSmall");
        _tabfs:SetAllPoints(); _tabfs:SetJustifyH("CENTER"); _tabfs:SetText(def.label); btn:SetFontString(_tabfs);
        CQ_SkinButton(btn, "ghost");
        -- Active-tab underline (hidden by default)
        local _ind = frame:CreateTexture("CQ_TabInd_" .. def.id, "OVERLAY");
        _ind:SetHeight(2); _ind:SetWidth(dynTabW - 4);
        _ind:SetPoint("BOTTOM", btn, "BOTTOM", 0, 0);
        _ind:SetTexture(0.0, 0.831, 1.0, 1.0);
        _ind:Hide();
        local id = def.id;
        btn:SetScript("OnClick", function()
            CQ_Config_ShowTab(id);
        end);
    end

    -- Divider below tabs
    local tabSep = frame:CreateTexture(nil, "OVERLAY");
    tabSep:SetWidth(FRAME_W - 28);
    tabSep:SetHeight(1);
    tabSep:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -72);
    tabSep:SetTexture(0.22, 0.30, 0.42, 0.9);

    -- Build tab panels
    CreateStatusTab(frame);
    CreateOptionsTab(frame);
    CreateConsumablesTab(frame);
    CreateCommandsTab(frame);
    CreateDebugTab(frame);
    CreateSimulateTab(frame);
    CreateCastTestTab(frame);

    -- Version footer
    local footer = frame:CreateFontString("CQ_Config_Footer", "OVERLAY", "GameFontNormalSmall");
    footer:SetPoint("BOTTOM", 0, 7);
    footer:SetText("|cff778899v" .. (CQui_RaidLogs and CQui_RaidLogs.version or "?") .. "|r");

    return frame;
end

-- Capitalize first letter for tab panel name lookup
local function TabPanelName(id)
    return "CQ_Tab_" .. string.upper(string.sub(id, 1, 1)) .. string.sub(id, 2);
end

function CQ_Config_ShowTab(tabId)
    CQ_MinimapButton.activeTab = tabId;
    local ids = { "status", "options", "consumables", "commands", "debug", "simulate", "casttest" };
    for _, id in ipairs(ids) do
        local panel = getglobal(TabPanelName(id));
        if panel then
            if id == tabId then panel:Show() else panel:Hide() end;
        end
        local btn = getglobal("CQ_TabBtn_" .. id);
        if btn then
            local cap = string.upper(string.sub(id, 1, 1)) .. string.sub(id, 2);
            local _fs = btn:GetFontString();
            local ind = getglobal("CQ_TabInd_" .. id);
            if id == tabId then
                if _fs then _fs:SetText(cap); _fs:SetTextColor(0.0, 0.831, 1.0); end
                btn:SetBackdropColor(0.0, 0.10, 0.18, 1);
                -- Recolour explicit border textures stored by RAB_SkinButton
                if btn._bdrTx then
                    for _, tx in ipairs(btn._bdrTx) do tx:SetTexture(0.0, 0.60, 0.80, 1.0); end
                end
                if ind then ind:Show(); end
                btn:Disable();
            else
                if _fs then _fs:SetText(cap); _fs:SetTextColor(0.60, 0.68, 0.80); end
                btn:SetBackdropColor(0.13, 0.17, 0.24, 1);
                if btn._bdrTx then
                    for _, tx in ipairs(btn._bdrTx) do tx:SetTexture(0.30, 0.40, 0.55, 0.9); end
                end
                if ind then ind:Hide(); end
                btn:Enable();
            end
        end
    end
    CQ_Config_Update();
end

function CQ_Config_Toggle()
    local frame = getglobal("CQ_ConfigFrame");
    if not frame then frame = CQ_Config_Create(); end
    if frame:IsShown() then
        frame:Hide();
    else
        frame:Show();
        CQ_Config_ShowTab(CQ_MinimapButton.activeTab or "status");
    end
end

-- ============================================================================
-- UPDATE STATS: Dedicated function for refreshing the live stats panel only.
-- Called by the auto-ticker and the Refresh button, as well as from
-- CQ_Config_Update when on the Status tab.
-- ============================================================================

function CQ_Config_UpdateStats()
    if not CQ_Log then return; end

    local function SetBox(name, text)
        local fs = getglobal("CQ_Stat_" .. name);
        if fs then fs:SetText(text); end
    end

    local DASH = "|cff445566—|r";

    if not (CQ_Log.isLogging and CQ_Log.currentRaidId and CQui_RaidLogs) then
        SetBox("Players",  DASH); SetBox("Deaths", DASH);
        SetBox("Loot",     DASH); SetBox("Duration", DASH);
        local function Clr(name)
            local fs = getglobal("CQ_Stat_" .. name);
            if fs then fs:SetText("|cff445566No active raid session.|r"); end
        end
        local function ClrBlank(name)
            local fs = getglobal("CQ_Stat_" .. name);
            if fs then fs:SetText(""); end
        end
        Clr("SunderText"); Clr("DeathText");  Clr("LootText");
        Clr("PotText");    Clr("UptimeText"); Clr("MoneyText");
        ClrBlank("LootTextB"); ClrBlank("LootTextC");
        ClrBlank("UptimeTextA"); ClrBlank("UptimeTextB"); ClrBlank("UptimeTextC");
        return;
    end

    local raid = CQui_RaidLogs.raids[CQ_Log.currentRaidId];
    if not raid then return; end

    -- ── Strip: 4 overview chips ───────────────────────────────────────────────
    local pc = 0;
    for _ in pairs(raid.players or {}) do pc = pc + 1; end
    SetBox("Players", "|cffffffff" .. pc .. "|r");

    local deathCount = table.getn(raid.deaths or {});
    local dCol = deathCount == 0 and "|cff00cc00" or (deathCount <= 3 and "|cffffcc00" or "|cffff5555");
    SetBox("Deaths", dCol .. deathCount .. "|r");

    SetBox("Loot", "|cffffffff" .. table.getn(raid.loot or {}) .. "|r");

    if CQ_Log.sessionStartTime then
        local age = time() - CQ_Log.sessionStartTime;
        local h = math.floor(age / 3600);
        local m = math.floor(math.mod(age, 3600) / 60);
        local s = math.mod(age, 60);
        if h > 0 then
            SetBox("Duration", "|cffffffff" .. h .. "|r|cff778899h|r |cffffffff" .. m .. "|r|cff778899m|r");
        else
            SetBox("Duration", "|cffffffff" .. m .. "|r|cff778899m|r |cffffffff" .. s .. "|r|cff778899s|r");
        end
    else
        SetBox("Duration", DASH);
    end

    -- ── Sunder Armor ─────────────────────────────────────────────────────────
    local sunderFs = getglobal("CQ_Stat_SunderText");
    if sunderFs then
        local total = 0;
        local byPlayer = {};
        for player, spells in pairs(raid.spells or {}) do
            local cnt = spells["sunder_armor"] and (spells["sunder_armor"].count or 0) or 0;
            if cnt > 0 then
                total = total + cnt;
                table.insert(byPlayer, { name = player, count = cnt });
            end
        end
        table.sort(byPlayer, function(a, b) return a.count > b.count; end);

        if total == 0 then
            sunderFs:SetText("|cff445566No sunders yet.|r");
        else
            local lines = { "|cff778899Total:|r |cff88ccff" .. total .. "|r" };
            local shown = 0;
            for _, e in ipairs(byPlayer) do
                if shown >= 8 then
                    table.insert(lines, "|cff445566  + " .. (table.getn(byPlayer) - 8) .. " more|r");
                    break;
                end
                table.insert(lines, "  |cffffffff" .. e.name .. "|r  |cff88ccff" .. e.count .. "|r");
                shown = shown + 1;
            end
            sunderFs:SetText(table.concat(lines, "\n"));
        end
    end

    -- ── Recent Deaths ────────────────────────────────────────────────────────
    local deathFs = getglobal("CQ_Stat_DeathText");
    if deathFs then
        local deaths = raid.deaths or {};
        if table.getn(deaths) == 0 then
            deathFs:SetText("|cff00cc00No deaths so far!|r");
        else
            local lines = {};
            local startIdx = math.max(1, table.getn(deaths) - 8);
            for i = table.getn(deaths), startIdx, -1 do
                local d = deaths[i];
                if d then
                    local kb = (d.killedBy and d.killedBy ~= "" and d.killedBy ~= "Unknown")
                        and ("|cff778899 ← " .. d.killedBy .. "|r") or "";
                    table.insert(lines, "|cffff6666" .. (d.playerName or "?") .. "|r" .. kb);
                end
            end
            if table.getn(deaths) > 9 then
                table.insert(lines, "|cff445566… " .. (table.getn(deaths) - 9) .. " earlier|r");
            end
            deathFs:SetText(table.concat(lines, "\n"));
        end
    end

    -- ── Notable Loot — 3-column layout ──────────────────────────────────────
    -- LootText, LootTextB, LootTextC each hold one column's worth of entries.
    local lootFsA = getglobal("CQ_Stat_LootText");
    local lootFsB = getglobal("CQ_Stat_LootTextB");
    local lootFsC = getglobal("CQ_Stat_LootTextC");
    if lootFsA then
        local loot = raid.loot or {};
        local qualColor = {
            poor="9d9d9d", common="ffffff", uncommon="1eff00",
            rare="0070dd", epic="a335ee", legendary="ff8000",
        };
        -- Collect notable items (uncommon+), fall back to recent common if none
        local notable = {};
        for i = table.getn(loot), 1, -1 do
            local entry = loot[i];
            if entry then
                local q = entry.itemQuality or "common";
                if q=="uncommon" or q=="rare" or q=="epic" or q=="legendary" then
                    table.insert(notable, entry);
                end
            end
            if table.getn(notable) >= 9 then break; end
        end
        if table.getn(notable) == 0 then
            for i = table.getn(loot), math.max(1, table.getn(loot)-8), -1 do
                table.insert(notable, loot[i]);
            end
        end

        if table.getn(notable) == 0 then
            lootFsA:SetText("|cff445566No loot yet.|r");
            if lootFsB then lootFsB:SetText(""); end
            if lootFsC then lootFsC:SetText(""); end
        else
            -- Distribute across 3 columns
            local colA, colB, colC = {}, {}, {};
            for idx, entry in ipairs(notable) do
                local q   = entry.itemQuality or "common";
                local col = "|cff" .. (qualColor[q] or "ffffff");
                local qty = (entry.quantity and entry.quantity > 1) and " x"..entry.quantity or "";
                local line = col .. (entry.itemName or "?") .. "|r" .. qty ..
                    "  |cff556677" .. (entry.playerName or "?") .. "|r";
                local bucket = math.mod(idx - 1, 3);
                if bucket == 0 then table.insert(colA, line);
                elseif bucket == 1 then table.insert(colB, line);
                else table.insert(colC, line); end
            end
            lootFsA:SetText(table.concat(colA, "\n"));
            if lootFsB then lootFsB:SetText(table.concat(colB, "\n")); end
            if lootFsC then lootFsC:SetText(table.concat(colC, "\n")); end
        end
    end

    -- ── Top Consumers (buff uptime %) — 3 columns A/B/C ────────────────────────
    local upFsA = getglobal("CQ_Stat_UptimeTextA");
    local upFsB = getglobal("CQ_Stat_UptimeTextB");
    local upFsC = getglobal("CQ_Stat_UptimeTextC");
    if upFsA then
        local sessionDur = CQ_Log.sessionStartTime and (time() - CQ_Log.sessionStartTime) or 0;
        local function ClearUptime(msg)
            upFsA:SetText(msg or ""); if upFsB then upFsB:SetText(""); end; if upFsC then upFsC:SetText(""); end;
        end
        if sessionDur < 5 or pc == 0 then
            ClearUptime("|cff445566No data yet.|r");
        else
            local keyUptime = {};
            local keyName   = {};
            for _, playerData in pairs(raid.players or {}) do
                for buffKey, consData in pairs(playerData.consumables or {}) do
                    if not keyUptime[buffKey] then
                        keyUptime[buffKey] = 0;
                        keyName[buffKey]   = consData.consumableName or buffKey;
                    end
                    keyUptime[buffKey] = keyUptime[buffKey] + (consData.totalUptime or 0);
                end
            end
            local sorted = {};
            for k, totalUp in pairs(keyUptime) do
                local avg = math.min(100, math.floor(totalUp / (pc * sessionDur) * 100 + 0.5));
                if avg > 0 then
                    table.insert(sorted, { key=k, pct=avg, name=keyName[k] });
                end
            end
            table.sort(sorted, function(a, b) return a.pct > b.pct; end);

            if table.getn(sorted) == 0 then
                ClearUptime("|cff445566No uptime data yet.|r");
            else
                local colA, colB, colC = {}, {}, {};
                local shown = 0;
                for _, e in ipairs(sorted) do
                    local pctCol = e.pct >= 80 and "|cff00cc00" or (e.pct >= 50 and "|cffffcc00" or "|cffff6644");
                    local nm = e.name or e.key;
                    if string.len(nm) > 18 then nm = string.sub(nm, 1, 17) .. "…"; end
                    local line = "|cffaaaaaa" .. nm .. "|r  " .. pctCol .. e.pct .. "%|r";
                    local bucket = math.mod(shown, 3);
                    if bucket == 0 then table.insert(colA, line);
                    elseif bucket == 1 then table.insert(colB, line);
                    else table.insert(colC, line); end
                    shown = shown + 1;
                    if shown >= 9 then break; end
                end
                upFsA:SetText(table.concat(colA, "\n"));
                if upFsB then upFsB:SetText(table.concat(colB, "\n")); end
                if upFsC then upFsC:SetText(table.concat(colC, "\n")); end
            end
        end
    end

    -- ── Potions & Consumables ────────────────────────────────────────────────
    local potFs = getglobal("CQ_Stat_PotText");
    if potFs then
        local lines = {};
        local mp, nt = 0, 0;
        for _, pd in pairs(raid.potions or {}) do
            mp = mp + (pd.majorMana or 0);
            nt = nt + (pd.nordanaarTea or 0);
        end
        table.insert(lines, "|cff778899Major Mana:|r  |cffffffff" .. mp .. "|r");
        table.insert(lines, "|cff778899Nordanaar Tea:|r  |cffffffff" .. nt .. "|r");

        -- Sappers: count from castTrackedConsumables
        local sapperTotal = 0;
        for _, entry in pairs(raid.castTrackedConsumables or {}) do
            if entry.buffKey == "goblinsapper" then
                sapperTotal = sapperTotal + 1;
            end
        end
        table.insert(lines, "|cff778899Sappers:|r  |cffffffff" .. sapperTotal .. "|r");

        potFs:SetText(table.concat(lines, "\n"));
    end

    -- ── Money ────────────────────────────────────────────────────────────────
    local moneyFs = getglobal("CQ_Stat_MoneyText");
    if moneyFs then
        local tmc = raid.totalMoneyCopper or 0;
        if tmc > 0 then
            local g = math.floor(tmc / 10000);
            local s = math.floor(math.mod(tmc, 10000) / 100);
            local c = math.mod(tmc, 100);
            local str = "";
            if g > 0 then str = str .. "|cffffcc00" .. g .. "g|r "; end
            if s > 0 or g > 0 then str = str .. "|cffc0c0c0" .. s .. "s|r "; end
            str = str .. "|cffcd7f32" .. c .. "c|r";
            moneyFs:SetText(str);
        else
            moneyFs:SetText("|cff445566No money drops.|r");
        end
    end
end

-- ============================================================================
-- UPDATE: Refresh all live data across tabs
-- ============================================================================

function CQ_Config_Update()
    local frame = getglobal("CQ_ConfigFrame");
    if not frame or not frame:IsShown() then return; end
    if not CQ_Log then return; end

    -- Defaults guard
    if CQ_Log.trackOutOfCombat == nil then CQ_Log.trackOutOfCombat = true; end
    if CQ_Log.trackLoot        == nil then CQ_Log.trackLoot = true; end
    if CQ_Log.trackDeaths      == nil then CQ_Log.trackDeaths = true; end
    if CQ_Log.trackSunders     == nil then CQ_Log.trackSunders = true; end
    if CQ_Log.debugPotions     == nil then CQ_Log.debugPotions = false; end
    if CQ_Log.debugConsumables == nil then CQ_Log.debugConsumables = false; end
    if CQ_Log.verboseExport    == nil then CQ_Log.verboseExport = false; end
    -- Ensure loot quality filter defaults
    if not CQ_Log.trackLootQualities then
        CQ_Log.trackLootQualities = {
            poor = false, common = false, uncommon = true,
            rare = true, epic = true, legendary = true,
        };
    end
    -- Ensure per-item consumable defaults exist
    if CQ_Log_EnsureItemDefaults then CQ_Log_EnsureItemDefaults(); end

    -- ---- Status tab ----
    local lbl = getglobal("CQ_Status_Label");
    if lbl then
        if CQ_Log.isPendingCombat then
            lbl:SetText("|cffff9900● PENDING COMBAT|r");
        elseif CQ_Log.isLogging then
            lbl:SetText("|cff00ff00● LOGGING|r");
        else
            lbl:SetText("|cff778899● INACTIVE|r");
        end
    end

    local zone = getglobal("CQ_Status_Zone");
    if zone then
        if CQ_Log.isLogging or CQ_Log.isPendingCombat then
            local s = "Zone: " .. (CQ_Log.currentZone or "?");
            if CQ_Log.isLogging and CQ_Log.inCombat then
                s = s .. "  |cffff4444[IN COMBAT]|r";
            end
            if CQ_Log.isPendingCombat then
                s = s .. "  |cffff9900[waiting for combat]|r";
            end
            zone:SetText(s);
        else
            zone:SetText("Enter a tracked raid zone to start automatically.");
        end
    end

    local raidId = getglobal("CQ_Status_RaidID");
    if raidId then
        if CQ_Log.isLogging and CQ_Log.currentRaidId then
            raidId:SetText("|cff8899aaRaid ID: " .. CQ_Log.currentRaidId .. "|r");
        else
            raidId:SetText("");
        end
    end

    -- Update Start/Stop button enabled states
    local startBtn = getglobal("CQ_Status_StartBtn");
    if startBtn then
        if CQ_Log.isLogging then startBtn:Disable() else startBtn:Enable() end;
    end
    local stopBtn2 = getglobal("CQ_Status_StopBtn");
    if stopBtn2 then
        if CQ_Log.isLogging or CQ_Log.isPendingCombat then
            stopBtn2:Enable();
        else
            stopBtn2:Disable();
        end
    end

    -- Live stats (delegated to dedicated function for auto-refresh reuse)
    CQ_Config_UpdateStats();

    -- ---- Options tab ----
    local cc = getglobal("CQ_Opt_CombatCheck");
    if cc then cc:SetChecked(CQ_Log.trackOutOfCombat); if cc.CQ_SyncVisual then cc.CQ_SyncVisual(); end end

    local lc = getglobal("CQ_Opt_LootCheck");
    if lc then lc:SetChecked(CQ_Log.trackLoot); if lc.CQ_SyncVisual then lc.CQ_SyncVisual(); end end

    local deathCb = getglobal("CQ_Opt_DeathCheck");
    if deathCb then deathCb:SetChecked(CQ_Log.trackDeaths); if deathCb.CQ_SyncVisual then deathCb.CQ_SyncVisual(); end end

    local sunderCb = getglobal("CQ_Opt_SunderCheck");
    if sunderCb then sunderCb:SetChecked(CQ_Log.trackSunders); if sunderCb.CQ_SyncVisual then sunderCb.CQ_SyncVisual(); end end

    -- Auto-export interval editbox
    local exportEdit = getglobal("CQ_Opt_ExportIntervalEdit");
    if exportEdit and not exportEdit.hasFocus then
        exportEdit:SetText(tostring(CQ_Log.autoExportInterval or 600));
    end

    -- Buff poll interval editbox
    local pollEdit = getglobal("CQ_Opt_PollIntervalEdit");
    if pollEdit and not pollEdit.hasFocus then
        pollEdit:SetText(tostring(CQ_Log.checkInterval or 15));
    end

    -- Zone checkboxes
    local ZONE_LIST_UPD = {
        "Molten Core", "Blackwing Lair", "Zul'Gurub",
        "Ruins of Ahn'Qiraj", "Temple of Ahn'Qiraj", "Naxxramas",
        "Emerald Sanctum", "Tower of Karazhan", "The Rock of Desolation",
    };
    for _, zoneName in ipairs(ZONE_LIST_UPD) do
        local cbName = "CQ_Opt_Zone_" .. string.gsub(zoneName, "[^%w]", "_");
        local zcb = getglobal(cbName);
        if zcb then
            local enabled;
            if CQ_Log.trackedZones then
                enabled = CQ_Log.trackedZones[zoneName] ~= false;
            else
                enabled = CQ_Log_ValidZones and CQ_Log_ValidZones[zoneName] or false;
            end
            zcb:SetChecked(enabled); if zcb.CQ_SyncVisual then zcb.CQ_SyncVisual(); end
        end
    end

    -- Loot quality filter checkboxes
    if CQ_Log.trackLootQualities then
        local quals = { "poor", "common", "uncommon", "rare", "epic", "legendary" };
        for _, q in ipairs(quals) do
            local qcb = getglobal("CQ_Opt_LootQ_" .. q);
            if qcb then
                qcb:SetChecked(CQ_Log.trackLootQualities[q]); if qcb.CQ_SyncVisual then qcb.CQ_SyncVisual(); end
                -- Grey out quality checkboxes when loot tracking is disabled
                if CQ_Log.trackLoot then
                    qcb:Enable();
                else
                    qcb:Disable();
                end
            end
        end
    end

    -- ---- Consumables tab ----
    if CQ_Log_ConsumableCatalog and CQ_Log.trackedItems then
        for _, section in ipairs(CQ_Log_ConsumableCatalog) do
            for _, item in ipairs(section.items) do
                local cb = getglobal("CQ_Cons_Item_" .. item.key);
                if cb then
                    cb:SetChecked(CQ_Log.trackedItems[item.key] ~= false); if cb.CQ_SyncVisual then cb.CQ_SyncVisual(); end
                end
            end
        end
    end

    -- ---- Debug tab ----
    local dp = getglobal("CQ_Dbg_PotCheck");
    if dp then dp:SetChecked(CQ_Log.debugPotions); if dp.CQ_SyncVisual then dp.CQ_SyncVisual(); end end

    local dbgCons = getglobal("CQ_Dbg_ConsCheck");
    if dbgCons then dbgCons:SetChecked(CQ_Log.debugConsumables); if dbgCons.CQ_SyncVisual then dbgCons.CQ_SyncVisual(); end end

    local verboseExport = getglobal("CQ_Dbg_VerboseExport");
    if verboseExport then verboseExport:SetChecked(CQ_Log.verboseExport); if verboseExport.CQ_SyncVisual then verboseExport.CQ_SyncVisual(); end end

    -- Footer
    local footer = getglobal("CQ_Config_Footer");
    if footer then
        footer:SetText("|cff778899v" ..
            (CQui_RaidLogs and CQui_RaidLogs.version or "?") .. "|r");
    end
end

-- ============================================================================
-- SLASH COMMANDS
-- ============================================================================

SLASH_CONQCONFIG1 = "/conqconfig";
SlashCmdList["CONQCONFIG"] = function(msg)
    CQ_Config_Toggle();
end;

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

local initFrame = CreateFrame("Frame");
initFrame:RegisterEvent("PLAYER_LOGIN");
initFrame:RegisterEvent("PLAYER_ENTERING_WORLD");
initFrame:SetScript("OnEvent", function()
    if event == "PLAYER_LOGIN" then
        CQ_MinimapButton_Init();
        -- Do NOT load settings here - raidlog.lua's PLAYER_LOGIN handler may not
        -- have run yet and would overwrite our values with defaults.

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- All PLAYER_LOGIN handlers have now completed and CQ_Log has its
        -- defaults set. Safe to overlay our saved values on top.
        CQ_Settings_Load();
        initFrame:UnregisterEvent("PLAYER_ENTERING_WORLD");
    end
end);