local ADDON, ESF = ...
local EM = ESF.EditMode

-- Moves and resizes the Need/Greed/Pass roll windows (GroupLootFrame1-4) through Edit Mode.
-- Settings per layout: position, size, growth direction (see EditMode.lua).

local SCALE_MIN, SCALE_MAX, SCALE_STEP = 50, 200, 5   -- percent
local SLOT_SPACING = 100                             -- Blizzard's GroupLootContainer.reservedSize
local TEST_DURATION = 30                             -- seconds a test roll stays up
local MOCK_TEMPLATES = { "MKBGroupLootFrameTemplate", "GroupLootFrameTemplate" }   -- Forever, retail

local el = {
    name = "Loot Roll Frame", id = "LootRoll", key = "lootRollFrame", db = "lootRollLayouts",
    tooltip = "Move and resize the Need/Greed/Pass roll windows.",
}

function el:Resolve(e)
    return { x = e.x, y = e.y, scale = e.scale or 1, dir = e.dir == "DOWN" and "DOWN" or "UP" }
end

----------------------------------------------------------------------
-- Positioning (real roll windows, the Edit Mode preview and test rolls use the same slots)
----------------------------------------------------------------------
-- Slot 1 sits where the frame was placed; further slots stack up or down from it.
-- Offsets are converted into the frame's own (scaled) coordinates.
local function PlaceSlot(frame, slot, v)
    local c = GroupLootContainer
    local spacing = (c and c.reservedSize) or SLOT_SPACING
    local scale = v.scale
    local offset = (v.dir == "DOWN" and -1 or 1) * (slot - 1) * spacing * scale

    frame:SetScale(scale)
    frame:ClearAllPoints()
    if v.x and v.y then
        frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", v.x / scale, (v.y + offset) / scale)
    elseif c and c:GetBottom() then
        -- Blizzard's spot (the container only has a position after its first roll)
        frame:SetPoint("CENTER", c, "BOTTOM", 0, (spacing * 0.5 + offset) / scale)
    elseif UIParentBottomManagedFrameContainer and UIParentBottomManagedFrameContainer:GetTop() then
        frame:SetPoint("CENTER", UIParentBottomManagedFrameContainer, "TOP", 0, (spacing * 0.5 + offset) / scale)
    else
        frame:SetPoint("CENTER", UIParent, "BOTTOM", 0, (250 + offset) / scale)
    end
end

-- Real roll windows. Disabled: back to Blizzard's anchors (same formula as GroupLootContainer_Update).
local applied = false

local function ApplyRollFrames()
    local c = GroupLootContainer
    if not (c and c.rollFrames) then return end
    local on = el:IsOn()
    if not on and not applied then return end
    local v = EM.Current(el)
    for i = 1, c.maxIndex or 0 do
        local f = c.rollFrames[i]
        if f then
            if on then
                PlaceSlot(f, i, v)
            else
                f:SetScale(1)
                f:ClearAllPoints()
                f:SetPoint("CENTER", c, "BOTTOM", 0, (c.reservedSize or SLOT_SPACING) * (i - 0.5))
            end
        end
    end
    applied = on
end

----------------------------------------------------------------------
-- Mock roll windows (Blizzard's template with its scripts removed, so they never touch real rolls)
----------------------------------------------------------------------
local SAMPLES = {
    { icon = "Interface\\Icons\\INV_Sword_39", name = "Sample Sword", quality = 4 },
    { icon = "Interface\\Icons\\INV_Chest_Plate06", name = "Sample Breastplate", quality = 3 },
    { icon = "Interface\\Icons\\INV_Jewelry_Ring_03", name = "Sample Ring", quality = 2 },
    { icon = "Interface\\Icons\\INV_Misc_Gem_Ruby_02", name = "Sample Gem", quality = 3 },
}
local QUALITY_RGB = { [2] = { 0.12, 1, 0 }, [3] = { 0, 0.44, 0.87 }, [4] = { 0.64, 0.21, 0.93 } }

local function SetMockItem(f, sample)
    if f.IconFrame then
        if f.IconFrame.Icon then f.IconFrame.Icon:SetTexture(sample.icon) end
        if f.IconFrame.Border and ColorManager and ColorManager.GetAtlasDataForLootBorderItemQuality then
            local atlas = ColorManager.GetAtlasDataForLootBorderItemQuality(sample.quality)
            if atlas then f.IconFrame.Border:SetAtlas(atlas) end
        end
    end
    local r, g, b = unpack(QUALITY_RGB[sample.quality] or QUALITY_RGB[2])
    if ColorManager and ColorManager.GetColorDataForItemQuality then
        local c = ColorManager.GetColorDataForItemQuality(sample.quality)
        if c then r, g, b = c.r, c.g, c.b end
    end
    if f.Name then
        f.Name:SetText(sample.name)
        f.Name:SetVertexColor(r, g, b)
    end
    if f.Border then f.Border:SetVertexColor(r, g, b) end
end

local function CreateMock()
    local f
    for _, template in ipairs(MOCK_TEMPLATES) do
        local ok, frame = pcall(CreateFrame, "Frame", nil, UIParent, template)
        if ok and frame then f = frame break end
    end

    if f then
        for _, script in ipairs({ "OnShow", "OnHide", "OnEvent", "OnUpdate" }) do f:SetScript(script, nil) end
        if EventRegistry and EventRegistry.UnregisterFrameEventAndCallback then
            pcall(EventRegistry.UnregisterFrameEventAndCallback, EventRegistry, "OPEN_MASTER_LOOT_LIST", f)
        end
        local bc = f.LootButtonContainer or f
        f.rollButtons = {}
        for _, k in ipairs({ "NeedButton", "GreedButton", "PassButton" }) do
            local b = bc[k]
            if b then
                b:SetScript("OnClick", nil)   -- the template's OnClick would call RollOnLoot
                table.insert(f.rollButtons, b)
            end
        end
        if bc.TransmogButton then bc.TransmogButton:Hide() end
        if f.IconFrame then
            for _, script in ipairs({ "OnEnter", "OnLeave", "OnUpdate", "OnClick" }) do f.IconFrame:SetScript(script, nil) end
        end
        if f.Timer then f.Timer:SetMinMaxValues(0, 1) f.Timer:SetValue(0.6) end
        SetMockItem(f, SAMPLES[1])
    else
        -- fallback if no template exists on this client
        f = CreateFrame("Frame", nil, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
        f:SetSize(277, 67)
        if f.SetBackdrop then
            f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                edgeSize = 14, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
            f:SetBackdropColor(0, 0, 0, 0.8)
        end
        f.rollButtons = {}
    end
    f:SetClampedToScreen(true)
    if f.SetDontSavePosition then f:SetDontSavePosition(true) end
    f:Hide()
    return f
end

----------------------------------------------------------------------
-- Test rolls (button in the options): three mock rolls at the current position
----------------------------------------------------------------------
local TEST_COUNT = 3
local testRolls = {}
local testButton

local function TestRollsShown()
    for _, f in ipairs(testRolls) do
        if f:IsShown() then return true end
    end
    return false
end

local function UpdateTestButton()
    if testButton then testButton:SetText(TestRollsShown() and "Hide Test Rolls" or "Show Test Rolls") end
end

local function PlaceTestRolls()
    local v = EM.Current(el)   -- disabled: Blizzard's position and size
    for i, f in ipairs(testRolls) do
        if f:IsShown() then PlaceSlot(f, i, v) end
    end
end

local function ShowTestRolls(count)
    for i = 1, TEST_COUNT do
        local f = testRolls[i]
        if i <= count then
            if not f then
                f = CreateMock()
                f:SetFrameStrata("DIALOG")
                for _, b in ipairs(f.rollButtons) do
                    b:SetScript("OnClick", function() f:Hide() end)   -- "rolling" closes it, the slot stays free
                end
                if f.Timer then f.Timer:SetMinMaxValues(0, TEST_DURATION) end
                f:HookScript("OnHide", UpdateTestButton)
                f:SetScript("OnUpdate", function(self, elapsed)
                    self.remaining = self.remaining - elapsed
                    if self.Timer then self.Timer:SetValue(math.max(0, self.remaining)) end
                    if self.remaining <= 0 then self:Hide() end
                end)
                testRolls[i] = f
            end
            SetMockItem(f, SAMPLES[i])
            f.remaining = TEST_DURATION
            f:Show()
        elseif f then
            f:Hide()
        end
    end
    PlaceTestRolls()
    UpdateTestButton()
end

----------------------------------------------------------------------
-- Edit Mode
----------------------------------------------------------------------
function el:BuildPreview()
    local f = CreateMock()
    for _, b in ipairs(f.rollButtons) do b:EnableMouse(false) end
    if f.IconFrame then f.IconFrame:EnableMouse(false) end
    return f
end

function el:PlacePreview(f, v)
    PlaceSlot(f, 1, v)
end

function el:PreviewPosition(f)
    local cx, cy = f:GetCenter()
    if not cx then return nil end
    local s = f:GetScale()
    return cx * s, cy * s
end

function el:Refresh()
    ApplyRollFrames()
    PlaceTestRolls()
end

function el:Install()
    if type(GroupLootContainer_Update) == "function" then
        hooksecurefunc("GroupLootContainer_Update", function()
            if el:IsOn() then ApplyRollFrames() end
        end)
    end
end

el.dialogRows = {
    {
        kind = "dropdown", label = "Growth Direction",
        options = function() return { { "UP", "Up" }, { "DOWN", "Down" } } end,
        get = function(v) return v.dir end,
        set = function(value) EM.Modify(el, function(e) e.dir = value end) end,
    },
    {
        kind = "slider", label = "Size", min = SCALE_MIN, max = SCALE_MAX, step = SCALE_STEP,
        format = function(v) return math.floor(v + 0.5) .. "%" end,
        get = function(v) return math.floor(v.scale * 100 + 0.5) end,
        set = function(value) EM.Modify(el, function(e) e.scale = value / 100 end) end,
    },
}

----------------------------------------------------------------------
-- Settings
----------------------------------------------------------------------
EM:Register(el)

ESF:Custom({
    noLabel = true,
    parent = el.spec,
    create = function(row)
        local btn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        btn:SetSize(200, 22)
        btn:SetPoint("LEFT", row, "LEFT", row.labelX, 0)
        btn:SetScript("OnClick", function() ShowTestRolls(TestRollsShown() and 0 or TEST_COUNT) end)
        testButton = btn
        UpdateTestButton()
        return btn
    end,
    update = function(btn, on) btn:SetEnabled(on) end,
})
