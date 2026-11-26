local ADDON, ESF = ...
local EM = ESF.EditMode

-- Moves the totem timers (TotemFrame below the player frame; hunters' hawks use it too) through
-- Edit Mode. Settings per layout: position, size, growth direction, timer side, icon spacing.
--
-- TotemFrame sits in the player frame's managed container next to the (secure) pet frame, so we
-- never call its methods or write to it: that would taint the container's layout in combat.
-- Only C-side changes are made: Blizzard's buttons are reparented to our holder (they keep their
-- own scripts, right-click still dismisses), and a hook on TotemFrame:Layout sets the space the
-- container keeps for them (none when moved away from the player frame).

local SCALE_MIN, SCALE_MAX, SCALE_STEP = 50, 200, 5   -- percent
local SPACING_MIN, SPACING_MAX = 0, 20
local BUTTON = 37                                     -- TotemButtonTemplate size
local HALF = BUTTON / 2
local BLIZZ_SPACING = -6                              -- TotemFrame.spacing
local BLIZZ_LEFT, BLIZZ_TOP = 15, 2                   -- first icon in TotemFrame (leftPadding 15, topPadding -2)
local HAWK_SPELL = 1293241                            -- Summon Hawk

local DIRS = { RIGHT = { 1, 0 }, LEFT = { -1, 0 }, UP = { 0, 1 }, DOWN = { 0, -1 } }
local TIMER_POINTS = {
    BELOW = { "TOP", "BOTTOM", 0, 5 },   -- Blizzard's
    ABOVE = { "BOTTOM", "TOP", 0, -5 },
    RIGHT = { "LEFT", "RIGHT", -4, 0 },
    LEFT = { "RIGHT", "LEFT", 4, 0 },
}

local function Vertical(dir) return dir == "UP" or dir == "DOWN" end

local el = {
    name = "Totem Timers", id = "TotemTimers", key = "totemTimers", db = "totemTimerLayouts",
    tooltip = "Move and resize the totem timers below the player frame. Hunters' hawks are shown there too.",
}

function el:Resolve(e)
    local dir = DIRS[e.dir] and e.dir or "RIGHT"
    local timer = e.timer
    if Vertical(dir) then
        if timer ~= "LEFT" then timer = "RIGHT" end
    elseif timer ~= "ABOVE" then
        timer = "BELOW"
    end
    return { x = e.x, y = e.y, scale = e.scale or 1, dir = dir, timer = timer, spacing = e.spacing or 0 }
end

----------------------------------------------------------------------
-- Layout (real timers and the Edit Mode preview)
----------------------------------------------------------------------
-- Icon centers relative to the first icon, and the box around all icons
local function Geometry(n, v)
    local step = BUTTON + BLIZZ_SPACING + v.spacing
    local d = DIRS[v.dir]
    local centers = {}
    local left, right, top, bottom = -HALF, HALF, HALF, -HALF
    for i = 1, n do
        local cx, cy = (i - 1) * step * d[1], (i - 1) * step * d[2]
        centers[i] = { cx, cy }
        left, right = math.min(left, cx - HALF), math.max(right, cx + HALF)
        top, bottom = math.max(top, cy + HALF), math.min(bottom, cy - HALF)
    end
    return centers, left, right, top, bottom
end

local function SetTimerPoint(button, timer)
    local p = TIMER_POINTS[timer]
    button.Duration:ClearAllPoints()
    button.Duration:SetPoint(p[1], button, p[2], p[3], p[4])
end

-- Lays the buttons out inside `frame`; returns the box (relative to the first icon's center)
local function LayoutButtons(frame, buttons, v)
    local centers, left, right, top, bottom = Geometry(math.max(#buttons, 1), v)
    frame:SetSize(right - left, top - bottom)
    for i, b in ipairs(buttons) do
        b:ClearAllPoints()
        b:SetPoint("CENTER", frame, "TOPLEFT", centers[i][1] - left, centers[i][2] - top)
        SetTimerPoint(b, v.timer)
    end
    return left, right, top, bottom
end

-- Puts the first icon's center at the saved spot, or the first icon where Blizzard puts it:
-- relative to TotemFrame's top left, given as `point` of `ref` plus an offset in ref's units.
local function Place(frame, v, left, top, ref, point, ox, oy)
    local s = v.scale
    local relScale = (v.x and v.y) and UIParent:GetEffectiveScale() or ref:GetEffectiveScale()
    frame:SetScale(relScale * s / frame:GetParent():GetEffectiveScale())
    frame:ClearAllPoints()
    if v.x and v.y then
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", v.x / s + left, v.y / s + top)
    else
        frame:SetPoint("TOPLEFT", ref, point, (ox + BLIZZ_LEFT) / s + HALF + left, (oy + BLIZZ_TOP) / s - HALF + top)
    end
end

-- Where TotemFrame's top left is, or would be. The container only positions its children once
-- something was shown in it; until then TotemFrame would sit at the container's top left.
local function DefaultRef()
    if TotemFrame and TotemFrame:IsShown() and TotemFrame:GetLeft() then
        return TotemFrame, "TOPLEFT", 0, 0
    end
    local c = PlayerBottomManagedFrameContainer
    local blc = c and c.BottomManagedLayoutContainer
    if blc and blc:GetLeft() then return blc, "TOPLEFT", 0, 0 end
    local width = (blc and blc.fixedWidth) or 160
    if c and c:GetTop() then return c, "TOP", -width / 2, 0 end
    return PlayerFrame, "BOTTOM", 30 - width / 2, 25   -- the container's anchor in PlayerFrame.xml
end

----------------------------------------------------------------------
-- Real timers
----------------------------------------------------------------------
local holder
local taken = setmetatable({}, { __mode = "k" })   -- Blizzard buttons we reparented

local function ActiveButtons()
    local list = {}
    local pool = TotemFrame and TotemFrame.totemPool
    if pool then
        for b in pool:EnumerateActive() do
            if b:IsShown() then table.insert(list, b) end
        end
    end
    table.sort(list, function(a, b) return (a.layoutIndex or 0) < (b.layoutIndex or 0) end)
    return list
end

local function Restore()
    for b in pairs(taken) do
        b:SetParent(TotemFrame)
        SetTimerPoint(b, "BELOW")
        taken[b] = nil
    end
    local buttons = ActiveButtons()
    for i, b in ipairs(buttons) do
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", TotemFrame, "TOPLEFT", BLIZZ_LEFT + (i - 1) * (BUTTON + BLIZZ_SPACING), BLIZZ_TOP)
    end
    if #buttons > 0 then
        TotemFrame:SetSize(BLIZZ_LEFT + #buttons * BUTTON + (#buttons - 1) * BLIZZ_SPACING, BUTTON - BLIZZ_TOP)
    end
end

local function Apply()
    if not (TotemFrame and TotemFrame.totemPool) then return end
    if not el:IsOn() then
        if next(taken) then Restore() end
        return
    end

    if not holder then
        holder = CreateFrame("Frame", nil, PlayerFrame)   -- hidden together with the player frame
    end
    holder:SetFrameStrata(TotemFrame:GetFrameStrata())
    holder:SetFrameLevel(TotemFrame:GetFrameLevel())

    local buttons = ActiveButtons()
    for _, b in ipairs(buttons) do
        if b:GetParent() ~= holder then
            b:SetParent(holder)
            taken[b] = true
        end
    end

    local v = EM.Current(el)
    local left, right, top, bottom = LayoutButtons(holder, buttons, v)
    Place(holder, v, left, top, TotemFrame, "TOPLEFT", 0, 0)

    -- space the player frame's container keeps for the timers
    if #buttons > 0 then
        if v.x and v.y then
            TotemFrame:SetSize(0, 0)
        else
            TotemFrame:SetSize(BLIZZ_LEFT + (right + HALF) * v.scale, (HALF - bottom) * v.scale - BLIZZ_TOP)
        end
    end
end

----------------------------------------------------------------------
-- Edit Mode preview: Blizzard's button template with sample icons
----------------------------------------------------------------------
local function Samples()
    local _, class = UnitClass("player")
    if class == "SHAMAN" then
        return {   -- SHAMAN_TOTEM_PRIORITIES order: fire, earth, water, air
            { icon = "Interface\\Icons\\Spell_Fire_SearingTotem", time = 42 },
            { icon = "Interface\\Icons\\Spell_Nature_StoneSkinTotem", time = 95 },
            { icon = "Interface\\Icons\\INV_Spear_04", time = 58 },
            { icon = "Interface\\Icons\\Spell_Nature_Windfury", time = 110 },
        }
    end
    local icon = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(HAWK_SPELL)
        or "Interface\\Icons\\Ability_Hunter_AnimalHandler"
    return { { icon = icon, time = 9 }, { icon = icon, time = 17 } }
end

function el:BuildPreview()
    local f = CreateFrame("Frame", nil, UIParent)
    f.buttons = {}
    for _, sample in ipairs(Samples()) do
        local b = CreateFrame("Button", nil, f, "TotemButtonTemplate")
        b:EnableMouse(false)
        for _, script in ipairs({ "OnClick", "OnEnter", "OnLeave", "OnUpdate" }) do b:SetScript(script, nil) end
        b.Icon.Texture:SetTexture(sample.icon)
        b.Icon.Texture:Show()
        b.Icon.Cooldown:Hide()
        b.Duration:SetFormattedText(SecondsToTimeAbbrev(sample.time))
        local color = sample.time < (BUFF_DURATION_WARNING_TIME or 90) and HIGHLIGHT_FONT_COLOR or NORMAL_FONT_COLOR
        b.Duration:SetVertexColor(color.r, color.g, color.b)
        b.Duration:Show()
        b:Show()
        table.insert(f.buttons, b)
    end
    return f
end

function el:PlacePreview(f, v)
    local left, _, top = LayoutButtons(f, f.buttons, v)
    Place(f, v, left, top, DefaultRef())
end

function el:PreviewPosition(f)
    local b = f.buttons[1]
    local cx, cy = b:GetCenter()
    if not cx then return nil end
    local k = b:GetEffectiveScale() / UIParent:GetEffectiveScale()
    return cx * k, cy * k
end

function el:Refresh()
    Apply()
end

function el:Install()
    if TotemFrame and TotemFrame.Layout then
        -- runs after Blizzard laid the timers out (on every totem change and container layout)
        hooksecurefunc(TotemFrame, "Layout", function()
            if el:IsOn() then Apply() end
        end)
    end
    Apply()
end

----------------------------------------------------------------------
-- Settings dialog
----------------------------------------------------------------------
el.dialogRows = {
    {
        kind = "dropdown", label = "Growth Direction",
        options = function()
            return { { "RIGHT", "Right" }, { "LEFT", "Left" }, { "UP", "Up" }, { "DOWN", "Down" } }
        end,
        get = function(v) return v.dir end,
        set = function(value)
            EM.Modify(el, function(e)
                local wasVertical = Vertical(el:Resolve(e).dir)
                e.dir = value
                if Vertical(value) ~= wasVertical then
                    e.timer = Vertical(value) and "RIGHT" or "BELOW"
                end
            end)
        end,
    },
    {
        kind = "dropdown", label = "Timer Position",
        options = function(v)
            if Vertical(v.dir) then return { { "LEFT", "Left" }, { "RIGHT", "Right" } } end
            return { { "ABOVE", "Above" }, { "BELOW", "Below" } }
        end,
        get = function(v) return v.timer end,
        set = function(value) EM.Modify(el, function(e) e.timer = value end) end,
    },
    {
        kind = "slider", label = "Size", min = SCALE_MIN, max = SCALE_MAX, step = SCALE_STEP,
        format = function(v) return math.floor(v + 0.5) .. "%" end,
        get = function(v) return math.floor(v.scale * 100 + 0.5) end,
        set = function(value) EM.Modify(el, function(e) e.scale = value / 100 end) end,
    },
    {
        kind = "slider", label = "Icon Spacing", min = SPACING_MIN, max = SPACING_MAX, step = 1,
        format = function(v) return tostring(math.floor(v + 0.5)) end,
        get = function(v) return v.spacing end,
        set = function(value) EM.Modify(el, function(e) e.spacing = value end) end,
    },
}

EM:Register(el)
