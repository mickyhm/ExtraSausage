-- Group Browser tweaks for the Looking For Group window: a handle at the bottom edge
-- makes the window taller on the browse tab. The other tabs keep Blizzard's size;
-- their layouts are built for it.
--
-- Nothing here may run Blizzard's list code from addon code (directly, or by reading
-- a frame's position right after resizing it, which lays the list out on the spot):
-- the rows set up that way are tainted, and in dungeons, raids and battlegrounds the
-- group data is secret, so Blizzard's own row update fails on them.
local ADDON, ESF = ...

local GROUP_FINDER = "Blizzard_GroupFinder_VanillaStyle"
local DEFAULT_HEIGHT = 535   -- LFGParentFrame's size in Blizzard_LFGVanilla_ParentFrame.xml
local MAX_HEIGHT = 1200
local SCREEN_MARGIN = 4      -- keep this much space to the bottom of the screen

local mod
local enabled, handleOn = false, false
local height = DEFAULT_HEIGHT
local appliedHeight = DEFAULT_HEIGHT
local hooked = false
local grip

-- Tallest the window can get without leaving the screen. Only called before resizing.
local function MaxHeight()
    local top = LFGParentFrame:GetTop()
    local max = MAX_HEIGHT
    if top then max = math.min(max, math.max(top - SCREEN_MARGIN, DEFAULT_HEIGHT)) end
    return max
end

-- How far the top edge moves per pixel of extra height, by anchor point.
local TOP_SHIFT = {
    TOPLEFT = 0, TOP = 0, TOPRIGHT = 0,
    LEFT = 0.5, CENTER = 0.5, RIGHT = 0.5,
    BOTTOMLEFT = 1, BOTTOM = 1, BOTTOMRIGHT = 1,
}

local function Apply()
    local parent, browse = LFGParentFrame, LFGBrowseFrame
    if not parent or not browse then return end
    -- IsShown, not IsVisible: the browse tab stays selected while the window is closed
    local active = enabled and handleOn and browse:IsShown()
    local h = active and math.min(math.max(height, DEFAULT_HEIGHT), MAX_HEIGHT) or DEFAULT_HEIGHT
    if math.abs(appliedHeight - h) > 0.5 then
        -- The window isn't always anchored at its top (moved with BlizzMove: CENTER).
        -- Work out from the anchor how far the top would move and shift it back,
        -- without reading the new position.
        local shift = 0
        if parent:GetNumPoints() == 1 then
            shift = (TOP_SHIFT[(parent:GetPoint(1))] or 0) * (h - appliedHeight)
        end
        parent:SetHeight(h)
        if shift ~= 0 then parent:AdjustPointsOffset(0, -shift) end
        appliedHeight = h
    end
    if grip then grip:SetShown(active) end
    -- Blizzard's separator above the buttons sits 21 px above the list's bottom edge, so it
    -- shows through the gaps between rows
    if browse.BarMiddle then browse.BarMiddle:SetShown(not enabled) end
end

----------------------------------------------------------------------
-- Resize grip at the bottom edge. Apply keeps the top edge in place,
-- so dragging only moves the bottom edge.
----------------------------------------------------------------------
local function CursorY()
    local _, y = GetCursorPosition()
    return y / LFGParentFrame:GetEffectiveScale()
end

local GRIP_W, GRIP_H = 112, 20
local GRIP_LINE_W = 28
-- 45 degree sides: the edges then step exactly one pixel across per pixel down
local GRIP_SLANT = GRIP_H
local BORDER_HOVER = { 0.78, 0.63, 0.42 }
local LINE_COLOR, LINE_HOVER = { 0.6, 0.5, 0.35 }, { 0.88, 0.78, 0.58 }
-- Edge bands from the outside in, sampled from the window frame's metal border:
-- dim rim, bright metal, dark brown, darker brown, then the fill.
local GRIP_BANDS = {
    { width = 1, color = { 0.19, 0.14, 0.08 } },
    { width = 2, color = { 0.53, 0.42, 0.28 }, metal = true },
    { width = 1, color = { 0.26, 0.17, 0.06 } },
    { width = 1, color = { 0.16, 0.11, 0.05 } },
}
local GRIP_FILL = { 0.06, 0.05, 0.04 }

local LOWER_LEFT = LOWER_LEFT_VERTEX or 2
local LOWER_RIGHT = LOWER_RIGHT_VERTEX or 4

-- Trapezoid hanging from the window's bottom edge: \___/
-- Layers are inset along the slanted sides and the bottom; the top has no border.
-- Side insets are rounded to whole pixels so every band's edge stays on the pixel grid.
local function Trapezoid(parent, subLevel, color, inset)
    local t = parent:CreateTexture(nil, "ARTWORK", nil, subLevel)
    t:SetColorTexture(1, 1, 1)
    t:SetVertexColor(color[1], color[2], color[3])
    local side = math.floor(inset * math.sqrt(GRIP_H ^ 2 + GRIP_SLANT ^ 2) / GRIP_H + 0.5)
    local h = GRIP_H - inset
    t:SetPoint("TOPLEFT", side, 0)
    t:SetPoint("TOPRIGHT", -side, 0)
    t:SetHeight(h)
    local slant = GRIP_SLANT * h / GRIP_H
    t:SetVertexOffset(LOWER_LEFT, slant, 0)
    t:SetVertexOffset(LOWER_RIGHT, -slant, 0)
    return t
end

local function SetColor(parts, c)
    for _, t in ipairs(parts) do t:SetVertexColor(c[1], c[2], c[3]) end
end

local function CreateGrip()
    grip = CreateFrame("Button", nil, LFGBrowseFrame)
    grip:SetSize(GRIP_W, GRIP_H)
    grip:SetPoint("TOP", LFGBrowseFrame, "BOTTOM", 0, 4)
    grip:SetFrameLevel(LFGBrowseFrame:GetFrameLevel() + 20)

    local inset, metal = 0, nil
    for i, band in ipairs(GRIP_BANDS) do
        local t = Trapezoid(grip, i - 1, band.color, inset)
        if band.metal then metal = t end
        inset = inset + band.width
    end
    Trapezoid(grip, #GRIP_BANDS, GRIP_FILL, inset)
    local lines = {}
    for i = -1, 1 do
        local line = grip:CreateTexture(nil, "OVERLAY")
        line:SetColorTexture(1, 1, 1)
        line:SetSize(GRIP_LINE_W, 1)
        line:SetPoint("CENTER", 0, i * 3)
        table.insert(lines, line)
    end
    local function Highlight(on)
        local c = on and BORDER_HOVER or GRIP_BANDS[2].color
        metal:SetVertexColor(c[1], c[2], c[3])
        SetColor(lines, on and LINE_HOVER or LINE_COLOR)
    end
    Highlight(false)
    grip:SetScript("OnEnter", function() Highlight(true) end)
    grip:SetScript("OnLeave", function(self)
        if not self.startY then Highlight(false) end
    end)

    grip:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        self.startY, self.startH, self.maxH = CursorY(), appliedHeight, MaxHeight()
        self:SetScript("OnUpdate", function()
            local h = math.floor(self.startH + (self.startY - CursorY()) + 0.5)
            height = math.min(math.max(h, DEFAULT_HEIGHT), self.maxH)
            Apply()
        end)
    end)
    grip:SetScript("OnMouseUp", function(self)
        if not self.startY then return end
        self:SetScript("OnUpdate", nil)
        self.startY, self.startH = nil, nil
        if not self:IsMouseOver() then Highlight(false) end
        ESFDB.lfgFrameHeight = height
    end)
    grip:SetScript("OnHide", grip:GetScript("OnMouseUp"))
end

----------------------------------------------------------------------
-- Background art: keep the picture at its normal size at the top and
-- fill the extra space below it with the dark tone from its top edge.
----------------------------------------------------------------------
-- Inset.CustomBG at the default window height (Blizzard_LFGVanilla_Browse.xml):
-- BackgroundArt is 80 below the top and 3 above the bottom, CustomBG 3 inside it.
local BG_HEIGHT = DEFAULT_HEIGHT - 80 - 3 - 2 * 3

local function ExtendBackground()
    local inset = LFGBrowseFrame.Inset
    local bg = inset and inset.CustomBG
    if not bg then return end

    bg:ClearAllPoints()
    bg:SetPoint("TOPLEFT", inset, "TOPLEFT", 3, -3)
    bg:SetPoint("TOPRIGHT", inset, "TOPRIGHT", -3, -3)
    bg:SetHeight(BG_HEIGHT)

    local fill = inset:CreateTexture(nil, "BACKGROUND")
    fill:SetColorTexture(0.047, 0.039, 0.035)
    fill:SetPoint("TOPLEFT", bg, "BOTTOMLEFT")
    fill:SetPoint("BOTTOMRIGHT", inset, "BOTTOMRIGHT", -3, 3)
end

local function Hook()
    if hooked or not LFGParentFrame or not LFGBrowseFrame then return end
    hooked = true
    CreateGrip()
    ExtendBackground()
    LFGBrowseFrame:HookScript("OnShow", Apply)
    LFGBrowseFrame:HookScript("OnHide", Apply)
    Apply()
end

local IsLoaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
if IsLoaded(GROUP_FINDER) then
    Hook()
else
    local f = CreateFrame("Frame")
    f:RegisterEvent("ADDON_LOADED")
    f:SetScript("OnEvent", function(self, _, name)
        if name == GROUP_FINDER then
            self:UnregisterEvent("ADDON_LOADED")
            Hook()
        end
    end)
end

mod = ESF:Module({
    name = "Expand LFG Window", key = "betterLFGFrame",
    desc = "Allows more entries to be shown in the group browser",
    note = "Allows more entries to be shown at once in the group browser.",
    onChange = function(on)
        enabled = on
        height = ESFDB.lfgFrameHeight or DEFAULT_HEIGHT
    end,
})

ESF:Checkbox({
    key = "lfgResizeHandle", label = "Expand Handle", default = true,
    tooltip = "Drag the handle at the bottom of the group browser to make the window taller.",
    onChange = function(on)
        handleOn = on
        Apply()
    end,
})
