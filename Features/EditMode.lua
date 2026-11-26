local ADDON, ESF = ...

-- Edit Mode support for frames Blizzard doesn't offer there. Each frame is an element
-- (Features\LootRollFrame.lua, Features\TotemTimers.lua) with its own checkbox in this module.
-- Settings are kept per Edit Mode layout:
--   account and preset layouts in ESFDB[element.db], character layouts in ESFCharDB[element.db],
--   keyed "preset:<index>", "account:<name>", "char:<name>". A missing entry = Blizzard's defaults.
--
-- While Edit Mode is open, changes go to a working copy (`work`). They are written to the saved
-- variables only when Blizzard's Save is used (or "Save and Exit").
--
-- Edit Mode integration without registering a Blizzard system (that would taint Edit Mode):
-- previews with Blizzard's selection look, our own copies of Blizzard's dialogs, and hooks on
-- Save / Revert All / layout rename, delete and creation. Buttons that have to make Blizzard act
-- (open or close Edit Mode) are secure buttons, so Blizzard's code runs untainted.
--
-- An element provides:
--   name, id, key (its checkbox), db, tooltip
--   Resolve(e)            entry -> table of all values with defaults filled in (x, y nil = Blizzard's spot)
--   BuildPreview()        frame shown in Edit Mode
--   PlacePreview(f, v)    position the preview for resolved values v
--   PreviewPosition(f)    x, y to store after the preview was dragged
--   Refresh()             apply the current settings to the real frames (or restore Blizzard's)
--   Install()             optional, at PLAYER_LOGIN
--   dialogRows            { kind = "dropdown", label, options(v), get(v), set(value) }
--                         { kind = "slider", label, min, max, step, format, get(v), set(value) }

local EM = {}
ESF.EditMode = EM

local NAME = "Edit Mode"
local elements = {}
local mod

local LayoutType = Enum and Enum.EditModeLayoutType or {}

local function InEditMode()
    return EditModeManagerFrame and EditModeManagerFrame.IsEditModeActive
        and EditModeManagerFrame:IsEditModeActive() or false
end
EM.InEditMode = InEditMode

local function BlizzardHasChanges()
    return EditModeManagerFrame and EditModeManagerFrame.HasActiveChanges
        and EditModeManagerFrame:HasActiveChanges() or false
end

----------------------------------------------------------------------
-- Layouts and per-layout settings
----------------------------------------------------------------------
local function Layouts()
    local li = EditModeManagerFrame and EditModeManagerFrame.layoutInfo
    return li and li.layouts
end

local function KeyOf(info, index)
    if not info then return nil end
    if info.layoutType == LayoutType.Preset then return "preset:" .. index end
    if info.layoutType == LayoutType.Character then return "char:" .. tostring(info.layoutName) end
    return "account:" .. tostring(info.layoutName)
end

local function ActiveKey()
    local li = EditModeManagerFrame and EditModeManagerFrame.layoutInfo
    if not (li and li.layouts and li.activeLayout) then return nil end
    return KeyOf(li.layouts[li.activeLayout], li.activeLayout)
end

local function StoreFor(el, key)
    if strsub(key, 1, 5) == "char:" then return ESFCharDB[el.db] end
    return ESFDB[el.db]
end

local function Stores(el)
    return { ESFDB[el.db], ESFCharDB[el.db] }
end

local function Near(a, b)
    if type(a) == "number" and type(b) == "number" then return math.abs(a - b) < 0.05 end
    return a == b
end

local function Same(el, a, b)
    local ra, rb = el:Resolve(a or {}), el:Resolve(b or {})
    for k, v in pairs(ra) do
        if not Near(v, rb[k]) then return false end
    end
    for k in pairs(rb) do
        if ra[k] == nil then return false end
    end
    return true
end

local function Clean(el, e)
    if e == nil or Same(el, e, nil) then return nil end
    return CopyTable(e)
end

local work   -- [element] = { [layout key] = entry } while Edit Mode is open, nil otherwise

local function Stored(el, key)
    return key and StoreFor(el, key)[key]
end

local function Entry(el, key)
    if not key then return nil end
    if work then return work[el][key] end
    return StoreFor(el, key)[key]
end

-- Resolved values of the active layout. Disabled elements use Blizzard's defaults.
function EM.Current(el)
    local e = el:IsOn() and Entry(el, ActiveKey()) or nil
    return el:Resolve(e or {})
end

local function SetEntry(el, key, e)       -- pending while in Edit Mode, saved otherwise
    if work then work[el][key] = Clean(el, e) else StoreFor(el, key)[key] = Clean(el, e) end
end

local function SetBoth(el, key, e)        -- saved and pending
    StoreFor(el, key)[key] = Clean(el, e)
    if work then work[el][key] = Clean(el, e) end
end

local function BeginWork()
    work = {}
    for _, el in ipairs(elements) do
        local w = {}
        for _, store in ipairs(Stores(el)) do
            for k, e in pairs(store) do w[k] = CopyTable(e) end
        end
        work[el] = w
    end
end

local function Commit()
    if not work then return end
    for _, el in ipairs(elements) do
        wipe(ESFDB[el.db])
        wipe(ESFCharDB[el.db])
        for k, e in pairs(work[el]) do StoreFor(el, k)[k] = CopyTable(e) end
    end
end

local function Discard()
    if work then BeginWork() end
end

local function IsDirty(el, key)
    if not work then return false end
    local w = work[el]
    if key then return not Same(el, w[key], Stored(el, key)) end
    for k, e in pairs(w) do
        if not Same(el, e, Stored(el, k)) then return true end
    end
    for _, store in ipairs(Stores(el)) do
        for k, e in pairs(store) do
            if not Same(el, e, w[k]) then return true end
        end
    end
    return false
end

local function AnyDirty()
    for _, el in ipairs(elements) do
        if el:IsOn() and IsDirty(el) then return true end
    end
    return false
end

----------------------------------------------------------------------
-- Edit Mode previews with Blizzard's selection look
----------------------------------------------------------------------
local SELECTION_LAYOUT = {   -- Blizzard's EditModeSystemSelectionLayout
    TopRightCorner = { atlas = "%s-NineSlice-Corner", mirrorLayout = true, x = 8, y = 8 },
    TopLeftCorner = { atlas = "%s-NineSlice-Corner", mirrorLayout = true, x = -8, y = 8 },
    BottomLeftCorner = { atlas = "%s-NineSlice-Corner", mirrorLayout = true, x = -8, y = -8 },
    BottomRightCorner = { atlas = "%s-NineSlice-Corner", mirrorLayout = true, x = 8, y = -8 },
    TopEdge = { atlas = "_%s-NineSlice-EdgeTop" },
    BottomEdge = { atlas = "_%s-NineSlice-EdgeBottom" },
    LeftEdge = { atlas = "!%s-NineSlice-EdgeLeft" },
    RightEdge = { atlas = "!%s-NineSlice-EdgeRight" },
    Center = { atlas = "%s-NineSlice-Center", x = -8, y = 8, x1 = 8, y1 = -8 },
}
local KIT_HIGHLIGHT = "editmode-actionbar-highlight"
local KIT_SELECTED = "editmode-actionbar-selected"

local selectedEl, lastSelectedEl
local clearingBlizzard = false
local resetDialogAnchor = true
local Changed, ShowDialog   -- defined below

local function ApplyKit(frame, kit)
    if frame.kit ~= kit and NineSliceUtil then
        NineSliceUtil.ApplyLayout(frame, SELECTION_LAYOUT, kit)
        frame.kit = kit
    end
end

local function UpdateSelectionLook(el)
    local sel = el.selection
    if not sel then return end
    local selected = selectedEl == el
    local hover = sel:IsMouseOver()
    ApplyKit(sel, selected and KIT_SELECTED or KIT_HIGHLIGHT)
    sel.Highlight:SetShown(hover and not selected)
    sel.Label:SetText(selected and el.name or (HUD_EDIT_MODE_INSTRUCTIONS_CLICK_TO_EDIT or "Click to Edit"))
    sel.Label:SetShown(selected or hover)   -- name when selected, hint on hover
end

local function Deselect()
    local el = selectedEl
    if not el then return end
    selectedEl = nil
    if el.dialog then el.dialog:Hide() end
    UpdateSelectionLook(el)
end

local function Select(el)
    if selectedEl == el then return end
    Deselect()
    -- Blizzard's own call for this; it runs through a secure delegate
    clearingBlizzard = true
    if EditModeManagerFrame and EditModeManagerFrame.ClearSelectedSystem then
        EditModeManagerFrame:ClearSelectedSystem()
    end
    clearingBlizzard = false
    if lastSelectedEl ~= el then resetDialogAnchor = true end
    selectedEl, lastSelectedEl = el, el
    UpdateSelectionLook(el)
    GameTooltip:Hide()
    ShowDialog(el)
end

local function Modify(el, fn)
    local key = ActiveKey()
    if not key then return end
    local e = CopyTable(Entry(el, key) or {})
    fn(e)
    SetEntry(el, key, e)
    Changed()
end
EM.Modify = Modify

local function BuildSelection(el, f)
    local sel = CreateFrame("Frame", nil, f, "NineSliceCodeTemplate")
    sel:SetAllPoints()
    sel:SetFrameLevel(f:GetFrameLevel() + 50)
    sel:EnableMouse(true)
    sel:RegisterForDrag("LeftButton")

    sel.Highlight = CreateFrame("Frame", nil, sel, "NineSliceCodeTemplate")
    sel.Highlight:SetAllPoints()
    sel.Highlight:SetAlpha(0.4)
    ApplyKit(sel.Highlight, KIT_HIGHLIGHT)
    if sel.Highlight.SetBlendMode then sel.Highlight:SetBlendMode("ADD") end
    sel.Highlight:Hide()

    sel.Label = sel:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    sel.Label:SetPoint("CENTER")
    if sel.Label.SetIgnoreParentScale then sel.Label:SetIgnoreParentScale(true) end

    sel:SetScript("OnMouseDown", function() Select(el) end)
    sel:SetScript("OnEnter", function(self)
        UpdateSelectionLook(el)
        if selectedEl ~= el then
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            GameTooltip:SetText(el.name)
            GameTooltip:Show()
        end
    end)
    sel:SetScript("OnLeave", function()
        UpdateSelectionLook(el)
        GameTooltip:Hide()
    end)
    sel:SetScript("OnDragStart", function()
        if selectedEl == el then
            f:StartMoving()
            el.dragging = true
        end
    end)
    sel:SetScript("OnDragStop", function()
        if not el.dragging then return end
        f:StopMovingOrSizing()
        el.dragging = false
        local x, y = el:PreviewPosition(f)
        if x and y then
            Modify(el, function(e) e.x, e.y = x, y end)   -- stored in UIParent units
        else
            Changed()
        end
    end)
    el.selection = sel
end

local function PlacePreview(el)
    if el.preview and el.preview:IsShown() then el:PlacePreview(el.preview, EM.Current(el)) end
end

local function ShowPreview(el)
    if not el.preview then
        local f = el:BuildPreview()
        f:SetFrameStrata("MEDIUM")   -- same strata as Blizzard's Edit Mode selections (below the HUD Edit Mode window)
        f:SetToplevel(false)
        f:SetMovable(true)
        f:SetClampedToScreen(true)
        if f.SetDontSavePosition then f:SetDontSavePosition(true) end
        el.preview = f
        BuildSelection(el, f)
    end
    el.preview:Show()
    PlacePreview(el)
    UpdateSelectionLook(el)
end

local function HidePreview(el)
    if selectedEl == el then Deselect() end
    if el.preview then el.preview:Hide() end
end

----------------------------------------------------------------------
-- Settings dialog (copy of Blizzard's Edit Mode settings dialog), one per element
----------------------------------------------------------------------
local DIALOG_W, LABEL_W, ROW_H, PAD = 370, 110, 32, 20
local VALUE_W = 40   -- width of the value text right of a slider

-- Escape on our own frames: a keyboard-enabled frame
-- swallows Escape and lets every other key through. (Keyboard propagation can't be changed in
-- combat; these frames are only shown in Edit Mode and hidden when combat starts.)
local function EscapeHandler(onEscape)
    return function(self, key)
        if InCombatLockdown() then return end
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            onEscape()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end
end

local function EnableEscape(frame, onEscape)
    frame:EnableKeyboard(true)
    frame:SetPropagateKeyboardInput(true)
    frame:SetScript("OnKeyDown", EscapeHandler(onEscape))
end

local function NewBorder(frame, template)
    local ok, border = pcall(CreateFrame, "Frame", nil, frame, template)
    if ok and border then
        border:SetAllPoints()
        return
    end
    Mixin(frame, BackdropTemplateMixin)
    frame:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 } })
end

local function BuildDialog(el)
    local rows = el.dialogRows
    local d = CreateFrame("Frame", "ESF" .. el.id .. "Dialog", UIParent)
    d:SetSize(DIALOG_W, 45 + #rows * (ROW_H + 2) + 12 + 28 + 4 + 28 + 18)
    d:SetFrameStrata("DIALOG")
    d:SetFrameLevel(200)
    d:SetClampedToScreen(true)
    d:SetMovable(true)
    d:EnableMouse(true)
    d:RegisterForDrag("LeftButton")
    d:SetScript("OnDragStart", d.StartMoving)
    d:SetScript("OnDragStop", d.StopMovingOrSizing)
    d:Hide()
    EnableEscape(d, function() d:Hide() end)
    NewBorder(d, "DialogBorderTranslucentTemplate")

    -- everything else on a child above the border
    local inner = CreateFrame("Frame", nil, d)
    inner:SetAllPoints()
    inner:SetFrameLevel(d:GetFrameLevel() + 10)

    local title = inner:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
    title:SetPoint("TOP", 0, -15)
    title:SetText(el.name)

    local close = CreateFrame("Button", nil, inner, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT")
    close:SetScript("OnClick", function() d:Hide() end)

    local function Row(y, text)
        local label = inner:CreateFontString(nil, "ARTWORK", "GameFontHighlightMedium")
        label:SetSize(LABEL_W, ROW_H)
        label:SetPoint("TOPLEFT", PAD, y)
        label:SetJustifyH("LEFT")
        label:SetText(text)
        return label
    end

    local refreshers = {}
    local y = -45
    for _, r in ipairs(rows) do
        local label = Row(y, r.label)
        if r.kind == "dropdown" then
            local dd = CreateFrame("DropdownButton", nil, inner, "WowStyle1DropdownTemplate")
            dd:SetPoint("LEFT", label, "RIGHT", 5, 0)
            dd:SetPoint("RIGHT", inner, "RIGHT", -PAD, 0)
            local function IsSelected(value) return r.get(EM.Current(el)) == value end
            local function SetSelected(value) r.set(value) end
            dd:SetupMenu(function(_, root)
                for _, o in ipairs(r.options(EM.Current(el))) do
                    root:CreateRadio(o[2], IsSelected, SetSelected, o[1])
                end
            end)
            table.insert(refreshers, function(enabled)
                dd:GenerateMenu()
                dd:SetEnabled(enabled)
            end)
        else
            -- the value text ends at the same right edge as the dropdowns and the buttons
            local slider = CreateFrame("Frame", nil, inner, "MinimalSliderWithSteppersTemplate")
            slider:SetHeight(ROW_H)
            slider:SetPoint("LEFT", label, "RIGHT", 5, 0)
            slider:SetPoint("RIGHT", inner, "RIGHT", -PAD, 0)
            local formatters = { [MinimalSliderWithSteppersMixin.Label.Right] = r.format }
            slider:Init(r.get(EM.Current(el)), r.min, r.max, (r.max - r.min) / r.step, formatters)
            if slider.Slider and slider.RightText then
                -- bar ends early enough that arrow + gap + value text fit inside the slider frame
                slider.Slider:ClearAllPoints()
                slider.Slider:SetPoint("TOPLEFT", 19, 0)
                slider.Slider:SetPoint("BOTTOMRIGHT", -(VALUE_W + 12 + 13), 0)
                slider.RightText:ClearAllPoints()
                slider.RightText:SetPoint("RIGHT", slider, "RIGHT", 0, 0)
                slider.RightText:SetWidth(VALUE_W)
                slider.RightText:SetJustifyH("RIGHT")
            end
            local updating = false
            slider:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged, function(_, v)
                if updating then return end
                r.set(math.floor(v / r.step + 0.5) * r.step)
            end, slider)
            table.insert(refreshers, function(enabled)
                updating = true
                slider:SetValue(r.get(EM.Current(el)))
                updating = false
                slider:SetEnabled(enabled)
            end)
        end
        y = y - ROW_H - 2
    end

    local revert = CreateFrame("Button", nil, inner, "UIPanelButtonTemplate")
    revert:SetSize(180, 28)
    revert:SetPoint("TOPLEFT", PAD, y - 12)
    revert:SetText(HUD_EDIT_MODE_REVERT_CHANGES or "Revert Changes")
    revert:SetScript("OnClick", function()
        local key = ActiveKey()
        if key then
            SetEntry(el, key, Stored(el, key))
            Changed()
        end
    end)

    local reset = CreateFrame("Button", nil, inner, "UIPanelButtonTemplate")
    reset:SetSize(DIALOG_W - 2 * PAD, 28)
    reset:SetPoint("TOPLEFT", revert, "BOTTOMLEFT", 0, -4)
    reset:SetText(HUD_EDIT_MODE_RESET_POSITION or "Reset To Default Position")
    reset:SetScript("OnClick", function()
        Modify(el, function(e) e.x, e.y = nil, nil end)
    end)

    d:SetScript("OnHide", function()
        if selectedEl == el then Deselect() end
    end)

    function d:Refresh()
        local key = ActiveKey()
        for _, refresh in ipairs(refreshers) do refresh(key ~= nil) end
        revert:SetEnabled(key ~= nil and IsDirty(el, key))
        reset:SetEnabled(EM.Current(el).x ~= nil)
    end

    el.dialog = d
end

function ShowDialog(el)
    if not el.dialog then BuildDialog(el) end
    local d = el.dialog
    if resetDialogAnchor then
        d:ClearAllPoints()
        d:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -250, 200)   -- Blizzard's default spot
        resetDialogAnchor = false
    end
    d:Refresh()
    d:Show()
end

local function RefreshDialogs()
    for _, el in ipairs(elements) do
        if el.dialog and el.dialog:IsShown() then el.dialog:Refresh() end
    end
end

local function HideDialogs()
    for _, el in ipairs(elements) do
        if el.dialog then el.dialog:Hide() end
    end
end

----------------------------------------------------------------------
-- Unsaved changes on exit, when only our frames changed (Blizzard only asks for its own changes).
-- A copy of Blizzard's dialog; Save and Exit / Exit click Blizzard's close button through
-- secure buttons, so Edit Mode closes the same way as with its own dialog.
----------------------------------------------------------------------
local prompt, closeGuard

local function NeedsPrompt()
    return mod:IsOn() and InEditMode() and AnyDirty() and not BlizzardHasChanges()
end

local function HidePrompt()
    if prompt and prompt:IsShown() and not InCombatLockdown() then prompt:Hide() end
end

local function BuildPrompt()
    local m = EditModeManagerFrame
    local p = CreateFrame("Frame", "ESFEditModeUnsavedDialog", UIParent)
    p:SetSize(450, 130)
    p:SetPoint("TOP", UIParent, "TOP", 0, -135)   -- where Blizzard's static popups (and its own dialog) sit
    p:SetFrameStrata("DIALOG")
    p:SetFrameLevel(300)
    p:EnableMouse(true)
    p:Hide()
    EnableEscape(p, HidePrompt)
    NewBorder(p, "DialogBorderTemplate")

    local inner = CreateFrame("Frame", nil, p)
    inner:SetAllPoints()
    inner:SetFrameLevel(p:GetFrameLevel() + 10)

    local title = inner:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    title:SetWidth(400)
    title:SetPoint("TOP", 0, -25)
    title:SetSpacing(10)
    title:SetText(HUD_EDIT_MODE_UNSAVED_CHANGES_EXIT_DIALOG_TITLE
        or "If you exit now you will lose any unsaved changes.\nHow would you like to proceed?")

    local function SecureClose(text, width, onPreClick)
        local b = CreateFrame("Button", nil, inner, "UIPanelButtonTemplate, SecureActionButtonTemplate")
        b:SetSize(width, 22)
        b:SetText(text)
        b:RegisterForClicks("AnyUp", "AnyDown")
        b:SetAttribute("type", "click")
        b:SetAttribute("clickbutton", m.CloseButton)
        b:SetScript("PreClick", onPreClick)   -- runs before Blizzard's close (safe to run twice)
        return b
    end

    local save = SecureClose(HUD_EDIT_MODE_SAVE_AND_EXIT or "Save and Exit", 160, function() Commit() end)
    save:SetPoint("BOTTOMLEFT", 25, 25)

    local exit = SecureClose(HUD_EDIT_MODE_EXIT or "Exit", 115, function() Discard() end)
    exit:SetPoint("BOTTOM", 22, 25)

    local cancel = CreateFrame("Button", nil, inner, "UIPanelButtonTemplate")
    cancel:SetSize(115, 22)
    cancel:SetText(CANCEL or "Cancel")
    cancel:SetPoint("BOTTOMRIGHT", -25, 25)
    cancel:SetScript("OnClick", HidePrompt)

    prompt = p
end

local function ShowPrompt()
    if InCombatLockdown() then return end
    if not prompt then BuildPrompt() end
    PlaySound(SOUNDKIT.IG_MAINMENU_OPEN)
    prompt:Show()
end

-- Invisible button over Blizzard's close button, only while just our changes are unsaved
local function UpdateCloseGuard()
    local m = EditModeManagerFrame
    if not (m and m.CloseButton) then return end
    if not closeGuard then
        local g = CreateFrame("Button", nil, m)
        g:SetAllPoints(m.CloseButton)
        g:SetFrameLevel(m.CloseButton:GetFrameLevel() + 5)
        g:SetScript("OnClick", ShowPrompt)
        g:SetScript("OnEnter", function(self)
            m.CloseButton:LockHighlight()
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip_AddNormalLine(GameTooltip, HUD_EDIT_MODE_UNSAVED_CHANGES or "You have unsaved changes")
            GameTooltip:Show()
        end)
        g:SetScript("OnLeave", function()
            m.CloseButton:UnlockHighlight()
            GameTooltip:Hide()
        end)
        EnableEscape(g, ShowPrompt)   -- Escape asks too
        g:Hide()
        closeGuard = g
    end
    closeGuard:SetShown(NeedsPrompt())
end

----------------------------------------------------------------------
-- Blizzard's Save / Revert All buttons light up for our changes too
----------------------------------------------------------------------
local function UpdateBlizzardButtons()
    local m = EditModeManagerFrame
    if not (m and m.SaveChangesButton and m.RevertAllChangesButton and InEditMode()) then return end
    if AnyDirty() then
        m.SaveChangesButton:SetEnabled(true)
        m.RevertAllChangesButton:SetEnabled(true)
    elseif not BlizzardHasChanges() then
        m.SaveChangesButton:SetEnabled(false)
        m.RevertAllChangesButton:SetEnabled(false)
    end
    UpdateCloseGuard()
end

function Changed()
    if not ESFDB then return end
    for _, el in ipairs(elements) do
        PlacePreview(el)
        el:Refresh()
    end
    RefreshDialogs()
    UpdateBlizzardButtons()
end
EM.Changed = Changed

----------------------------------------------------------------------
-- Layout list changes: rename, delete, create (copy)
----------------------------------------------------------------------
local knownKeys      -- layout keys by index, as last seen
local pendingSource  -- layout a new one is being created from (nil = import / defaults)

local function CurrentKeys()
    local list = Layouts()
    if not list then return nil end
    local keys = {}
    for i, info in ipairs(list) do keys[i] = KeyOf(info, i) end
    return keys
end

local function MoveKey(from, to)
    for _, el in ipairs(elements) do
        local e = StoreFor(el, from)[from]
        StoreFor(el, from)[from] = nil
        if e and StoreFor(el, to)[to] == nil then StoreFor(el, to)[to] = e end
        if work then
            local w = work[el][from]
            work[el][from] = nil
            if w and work[el][to] == nil then work[el][to] = w end
        end
    end
end

local function DropKey(key)
    for _, el in ipairs(elements) do
        StoreFor(el, key)[key] = nil
        if work then work[el][key] = nil end
    end
end

local function SyncLayouts()
    local keys = CurrentKeys()
    if not keys then return end
    if knownKeys then
        local now, before = {}, {}
        for _, k in ipairs(keys) do now[k] = true end
        for _, k in ipairs(knownKeys) do before[k] = true end

        if #keys == #knownKeys then
            -- same count: a different name at the same index is a rename
            for i, k in ipairs(keys) do
                local old = knownKeys[i]
                if old ~= k and not now[old] and not before[k] then MoveKey(old, k) end
            end
        elseif #keys < #knownKeys then
            for _, old in ipairs(knownKeys) do
                if not now[old] then DropKey(old) end
            end
        else
            for _, k in ipairs(keys) do
                if not before[k] then
                    for _, el in ipairs(elements) do
                        -- new layout: saved with the source's current (also unsaved) settings
                        if pendingSource then SetBoth(el, k, Entry(el, pendingSource)) end
                        -- Blizzard drops unsaved changes of the other layouts when one is created
                        if work then
                            for _, other in ipairs(keys) do
                                if before[other] then work[el][other] = Clean(el, Stored(el, other)) end
                            end
                        end
                    end
                end
            end
            pendingSource = nil
        end
    end
    knownKeys = keys
end

local function SourceKey(info)
    local list = Layouts()
    if not info then return ActiveKey() end
    if list then
        for i, l in ipairs(list) do
            if l == info or (l.layoutType == info.layoutType and l.layoutName == info.layoutName) then
                return KeyOf(l, i)
            end
        end
    end
    return ActiveKey()
end

----------------------------------------------------------------------
-- Events and hooks
----------------------------------------------------------------------
local function OnEditModeEnter()
    if not ESFDB then return end
    BeginWork()
    resetDialogAnchor = true
    for _, el in ipairs(elements) do
        if el:IsOn() then ShowPreview(el) end
    end
    UpdateBlizzardButtons()
end

local function OnEditModeExit()
    for _, el in ipairs(elements) do HidePreview(el) end
    HidePrompt()
    work = nil   -- anything not saved is dropped
    if closeGuard then closeGuard:Hide() end
    Changed()
end

local function OnSavedLayouts()
    if not ESFDB then return end
    SyncLayouts()
    Commit()
    Changed()
end

local function InstallHooks()
    for _, el in ipairs(elements) do
        if el.Install then el:Install() end
    end

    local m = EditModeManagerFrame
    if not m then return end

    EventRegistry:RegisterCallback("EditMode.Enter", OnEditModeEnter, ESF)
    EventRegistry:RegisterCallback("EditMode.Exit", OnEditModeExit, ESF)
    EventRegistry:RegisterCallback("EditMode.SavedLayouts", OnSavedLayouts, ESF)

    -- Blizzard selects or clears its own systems -> ours gets deselected
    hooksecurefunc(m, "SelectSystem", function()
        resetDialogAnchor = true
        lastSelectedEl = nil
        Deselect()
    end)
    hooksecurefunc(m, "ClearSelectedSystem", function()
        if not clearingBlizzard then Deselect() end
    end)
    hooksecurefunc(m, "SetHasActiveChanges", UpdateBlizzardButtons)

    -- where a new layout comes from
    if m.ShowNewLayoutDialog then
        hooksecurefunc(m, "ShowNewLayoutDialog", function(_, info) pendingSource = SourceKey(info) end)
    end
    if m.ShowImportLayoutDialog then
        hooksecurefunc(m, "ShowImportLayoutDialog", function() pendingSource = nil end)
    end

    if m.RevertAllChangesButton then
        m.RevertAllChangesButton:HookScript("OnClick", function()
            Discard()
            Changed()
        end)
    end

    -- "Exit" / "Switch" without saving in Blizzard's own unsaved-changes dialog
    local unsaved = EditModeUnsavedChangesDialog
    if unsaved and unsaved.ProceedButton then
        unsaved.ProceedButton:HookScript("PreClick", function()
            Discard()
            Changed()
        end)
    end
end

----------------------------------------------------------------------
-- "Open Edit Mode" in the ESF options: a secure /editmode macro button.
-- It is parented to UIParent and only laid over the visible (normal) button out of combat,
-- so the options frames never become protected.
----------------------------------------------------------------------
local inCombat = InCombatLockdown()
local openPlaceholder, openSecure

local function UpdateOpenButton()
    if not openPlaceholder or InCombatLockdown() then return end
    local onPage = openPlaceholder:IsVisible()
    local usable = onPage and mod:IsOn() and not inCombat
    if not openSecure then
        local b = CreateFrame("Button", "ESFOpenEditModeButton", UIParent, "UIPanelButtonTemplate, SecureActionButtonTemplate")
        b:SetText("Open Edit Mode")
        b:RegisterForClicks("AnyUp", "AnyDown")
        b:SetAttribute("type", "macro")
        b:SetAttribute("macrotext", _G.SLASH_EDITMODE1 or "/editmode")
        -- close the options once Edit Mode is open
        b:SetScript("PostClick", function()
            if EditModeManagerFrame and EditModeManagerFrame:IsShown() and SettingsPanel and SettingsPanel:IsShown() then
                SettingsPanel:Close(true)
            end
        end)
        b:Hide()
        openSecure = b
    end
    if usable then
        openSecure:ClearAllPoints()
        openSecure:SetAllPoints(openPlaceholder)
        -- one strata above the options panel (HIGH), so the panel can never be raised above it
        openSecure:SetFrameStrata("DIALOG")
        openSecure:Show()
    else
        openSecure:Hide()
        openSecure:ClearAllPoints()   -- no anchor to the options frames while hidden
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("EDIT_MODE_LAYOUTS_UPDATED")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("UI_SCALE_CHANGED")
events:RegisterEvent("DISPLAY_SIZE_CHANGED")
events:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        InstallHooks()
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- secure buttons can still be changed here, right before the lockdown starts
        inCombat = true
        if openSecure then
            openSecure:Hide()
            openSecure:ClearAllPoints()
        end
        if prompt then prompt:Hide() end
        if closeGuard then closeGuard:Hide() end
        HideDialogs()
        ESF:RefreshSettings()
    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        ESF:RefreshSettings()
        UpdateOpenButton()
    else
        -- let Blizzard's manager process the event first
        C_Timer.After(0, function()
            if not ESFDB then return end
            SyncLayouts()
            Changed()
        end)
    end
end)

----------------------------------------------------------------------
-- Module and elements
----------------------------------------------------------------------
local function OnToggle(el)
    if InEditMode() then
        if el:IsOn() then ShowPreview(el) else HidePreview(el) end
        UpdateBlizzardButtons()
    end
    el:Refresh()
    UpdateOpenButton()
end

local function ElementIsOn(el)
    return mod:IsOn() and ESF:Get(el.spec) and true or false
end

table.insert(ESF.onLoad, function()
    -- Loot Roll Frame was a module of its own before: carry its state over
    if ESFDB.editMode == nil and ESFDB.lootRollFrame ~= nil then
        ESFDB.editMode = ESFDB.lootRollFrame
    end
    for _, el in ipairs(elements) do
        ESFDB[el.db] = ESFDB[el.db] or {}
        ESFCharDB[el.db] = ESFCharDB[el.db] or {}
    end
end)

mod = ESF:Module({
    name = NAME, key = "editMode",
    desc = "Move and resize more frames in edit mode",
    note = "Adds the loot roll window and the totem timers to edit mode.",
    onChange = function()
        for _, el in ipairs(elements) do OnToggle(el) end
    end,
})

-- Adds an element and its checkbox (rows the element adds next belong under it).
function EM:Register(el)
    ESF:Module(NAME)
    el.IsOn = ElementIsOn
    el.spec = ESF:Checkbox({
        key = el.key, label = el.name, tooltip = el.tooltip, default = false,
        onChange = function() OnToggle(el) end,
    })
    table.insert(elements, el)
    return el
end

-- Hint and Open Edit Mode button below all elements (their files are loaded after this one)
table.insert(ESF.onLoad, function()
    ESF:Module(NAME)

    ESF:Custom({
        noLabel = true,
        create = function(row)
            local text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            text:SetPoint("LEFT", row, "LEFT", row.labelX, 0)
            text:SetText("Saved per Edit Mode layout. Select a frame in Edit Mode to change it.")
            return text
        end,
        update = function(text, on) text:SetFontObject(on and GameFontHighlight or GameFontDisable) end,
    })

    ESF:Custom({
        noLabel = true,
        create = function(row)
            local btn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            btn:SetSize(200, 22)
            btn:SetPoint("LEFT", row, "LEFT", row.labelX, 0)
            btn:SetText("Open Edit Mode")
            btn:HookScript("OnShow", function() C_Timer.After(0, UpdateOpenButton) end)
            btn:HookScript("OnHide", UpdateOpenButton)

            btn.hint = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
            btn.hint:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 2, -4)
            btn.hint:SetText("Edit Mode is not available during combat.")
            btn.hint:Hide()

            openPlaceholder = btn
            return btn
        end,
        update = function(btn, on)
            btn.hint:SetShown(inCombat)
            btn:SetEnabled(on and not inCombat)
            UpdateOpenButton()
        end,
    })
end)
