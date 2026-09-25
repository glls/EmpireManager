-- ----------------------------------------------------------------------------
--                                   EmpireManager
--                              https://wow.cyberpunk.gr
--                (c) by George Litos (l0neshad0w),  All Rights Reserved
--                   For detailed license information check LICENSE.md
-- ----------------------------------------------------------------------------

local EmpireManager = LibStub("AceAddon-3.0"):GetAddon("EmpireManager")
local ICON16_FMT = EmpireManager.ICON16_FMT

-- Shared font constants
local FONT_NORMAL = "GameFontHighlight"
local LINE_HEIGHT = 20

-- Sidecar-only tab width override (used by EMCompactTabTemplate in the XML).
-- Blizzard's TabSystemButtonMixin:UpdateTabWidth floors every tab at
-- Left+Right+TabSideExtraSpacing(20), which makes short tabs wider than their
-- text and overflows the 5-tab sidecar strip. We size to the label instead,
-- still clamped to the TabSystem's min/max width. Applied after the inherited
-- TabSystemButtonMixin, so this overrides its UpdateTabWidth.
local TAB_EXTRA = 26 -- horizontal breathing room added to each label (the sidecar has spare width)
EMTopTabMixin = {}
function EMTopTabMixin:UpdateTabWidth()
    local minW, maxW = self:GetTabSystem():GetTabWidthConstraints()
    local textWidth = self.Text:GetWidth() + (self.textPadding or 0)
    local width = textWidth + TAB_EXTRA
    if maxW and width > maxW then
        width = maxW
        textWidth = width - TAB_EXTRA
    end
    if minW and width < minW then
        width = minW
        textWidth = width - TAB_EXTRA
    end
    self.Text:SetWidth(textWidth or 0)
    self:SetTabWidth(width)
end

-- Toggle a checkbox when its label hit-rect is clicked. Mirrors native
-- UICheckButtonTemplate behaviour: respects disabled state, plays the
-- right sound, and fires the box's existing OnClick handler so persistence
-- logic stays in one place.
local function WireLabelClick(hit, cb)
    hit:EnableMouse(true)
    hit:SetScript("OnMouseUp", function(_, button)
        if button ~= "LeftButton" then
            return
        end
        if not cb:IsEnabled() then
            return
        end
        cb:SetChecked(not cb:GetChecked())
        PlaySound(cb:GetChecked() and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
        local onClick = cb:GetScript("OnClick")
        if onClick then
            onClick(cb, "LeftButton")
        end
    end)
end

-------------------------------------------------------------------------------
-- Sidecar: Open / Close
-------------------------------------------------------------------------------

function EmpireManager:OpenSidecar(guid)
    if self.sidecarGUID == guid and EmpireManagerSidecar:IsShown() then
        self:CloseSidecar()
        return
    end

    local entry = self.db.global.registry[guid]
    if not entry then
        self:ChatMsg("Character not found in roster", true)
        return
    end

    local f = EmpireManagerSidecar
    if not f._initialized then
        Mixin(f, EMSidecarMixin)
        f:Init()
        -- Single choke point for every close path: the X button and ESC both just
        -- Hide() without going through CloseSidecar, so clearing the selection here
        -- keeps the grid highlight in sync no matter how the panel was dismissed.
        -- Hooked in Lua, not XML: the XML is parsed before this file loads, so an
        -- <OnHide function=".."/> there can't resolve the handler.
        f:HookScript("OnHide", function()
            EmpireManager.sidecarGUID = nil
            EmpireManager:UpdateRowSelection()
        end)
        f._initialized = true
    end
    -- Tab system must always re-init - XML TabSystem is fresh after /reload
    f:InitTabSystem()

    self.sidecarGUID = guid

    -- Anchor to dashboard right edge
    f:ClearAllPoints()
    if self.dashboardFrame and self.dashboardFrame:IsShown() then
        f:SetHeight(self.dashboardFrame:GetHeight())
        f:SetPoint("TOPLEFT", self.dashboardFrame, "TOPRIGHT", 2, 0)
    else
        f:SetHeight(500)
        f:SetPoint("CENTER")
    end

    -- Title + class icon portrait
    f:SetTitle("EmpireManager - " .. (entry.name or "?"))
    local classToken = entry.class or "WARRIOR"
    local coords = CLASS_ICON_TCOORDS[classToken]
    if coords then
        f:SetPortraitToAsset("Interface\\TargetingFrame\\UI-Classes-Circles")
        f.PortraitContainer.portrait:SetTexCoord(unpack(coords))
    else
        f:SetPortraitToAsset("Interface\\Icons\\Achievement_GuildPerk_MobileBanking")
    end

    f._selectedTab = 1
    if f._tabIDs and f._tabIDs._area then
        f._tabIDs._area:SetTab(f._tabIDs[1])
    end
    f._guid = guid
    -- ESC-to-close: sync UISpecialFrames on every Show (db not available during OnLoad)
    local idx = tIndexOf(UISpecialFrames, "EmpireManagerSidecar")
    if self.db.global.options.escToClose then
        if not idx then
            tinsert(UISpecialFrames, "EmpireManagerSidecar")
        end
    elseif idx then
        tremove(UISpecialFrames, idx)
    end
    f:Show()
    -- Defer populate so ScrollFrame has resolved its width
    C_Timer.After(0, function()
        if f:IsShown() and f._guid == guid then
            f:Populate(guid)
        end
    end)
end

function EmpireManager:CloseSidecar()
    EmpireManagerSidecar:Hide()
end

-------------------------------------------------------------------------------
-- Sidecar Mixin
-------------------------------------------------------------------------------

function EMSidecarMixin:InitTabSystem()
    local area = self.ContentArea
    local tabSys = area.TabSystem
    -- Skip if already initialized on this TabSystem instance
    if self._tabSystemRef == tabSys then
        return
    end
    self._tabSystemRef = tabSys

    Mixin(area, TabSystemOwnerMixin)
    TabSystemOwnerMixin.OnLoad(area)
    area:SetTabSystem(tabSys)

    local TAB_HELP = {
        [1] = {
            "Assignments",
            "Set roles and professions for this character.",
            " ",
            "Check a role to assign it. Hover each Role for more information.",
        },
        [2] = {
            "Details",
            "Overview of the tracked data for this character.",
        },
        [3] = {
            "Gold",
            "Gold held in bags and the Warband Bank, plus auto-balance settings.",
        },
        [4] = {
            "Notes",
            "Free-text notes for this character.",
            " ",
            "Notes appear in the dashboard tooltip when hovering this character.",
        },
        [5] = {
            "Options",
            "Per-character settings and overrides.",
        },
    }

    local infoBtn = self.InfoButton
    infoBtn:SetScript("OnEnter", function(btn)
        local lines = TAB_HELP[self._selectedTab]
        if not lines then
            return
        end
        GameTooltip:SetOwner(btn, "ANCHOR_CURSOR_RIGHT")
        for i, line in ipairs(lines) do
            if i <= 2 then
                GameTooltip:AddLine(line, 1, 0.82, 0, true)
            else
                GameTooltip:AddLine(line, 1, 1, 1, true)
            end
        end
        GameTooltip:Show()
    end)
    infoBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    infoBtn:Show()

    local tabNames = { "Assignments", "Details", "Gold", "Notes", "Options" }
    self._tabIDs = {}
    for i, name in ipairs(tabNames) do
        self._tabIDs[i] = area:AddNamedTab(name)
        area:SetTabCallback(self._tabIDs[i], function()
            self._selectedTab = i
            infoBtn:SetShown(TAB_HELP[i] ~= nil)
            if self._guid then
                self:Populate(self._guid)
            end
        end)
    end
    self._tabIDs._area = area
    self._selectedTab = 1
end

function EMSidecarMixin:Init()
    -- Override CollectionsBackgroundTemplate's built-in anchors so the
    -- inset sits directly under the sub-tabs (Wardrobe-style: tabs overlap
    -- the top edge of the inset by ~2px).
    local inset = self.ContentArea.Inset
    if inset then
        inset:ClearAllPoints()
        inset:SetPoint("TOPLEFT", self.ContentArea, "TOPLEFT", 4, -28)
        inset:SetPoint("BOTTOMRIGHT", self.ContentArea, "BOTTOMRIGHT", -4, 0)

        -- Hide top corner accents (same as Blizzard's Wardrobe) since our
        -- frame is narrow and they dominate the visible area.
        if inset.BGCornerTopLeft then
            inset.BGCornerTopLeft:Hide()
        end
        if inset.BGCornerTopRight then
            inset.BGCornerTopRight:Hide()
        end
    end

    -- Push ContentPanel inward so widgets don't touch the decorative border.
    local panel = self.ContentArea.ContentPanel
    if panel then
        panel:ClearAllPoints()
        panel:SetPoint("TOPLEFT", self.ContentArea, "TOPLEFT", 16, -40)
        panel:SetPoint("BOTTOMRIGHT", self.ContentArea, "BOTTOMRIGHT", -16, 12)
    end

    -- Close button - PortraitFrameTemplate provides CloseButton
    self.CloseButton:SetScript("OnClick", function()
        EmpireManager:CloseSidecar()
    end)

    -- Drag by the title bar (PortraitFrameTemplate doesn't wire this for us).
    self:RegisterForDrag("LeftButton")
    self:SetScript("OnDragStart", self.StartMoving)
    self:SetScript("OnDragStop", self.StopMovingOrSizing)

    -- Notes edit box scripts - bound once; handlers resolve current entry via self._guid
    local notesEdit = self.ContentArea.NotesEdit
    if notesEdit and notesEdit.EditBox then
        local editBox = notesEdit.EditBox
        editBox:SetScript("OnEscapePressed", function(eb)
            eb:ClearFocus()
        end)
        editBox:SetScript("OnEditFocusLost", function(eb)
            local guid = self._guid
            local entry = guid and EmpireManager.db.global.registry[guid]
            if not entry then
                return
            end
            local text = eb:GetText()
            entry.storageNote = text
            if EmpireManager.ledgerScroll then
                EmpireManager:RefreshVisibleRows()
            end
        end)
    end
end

function EMSidecarMixin:Populate(guid)
    self._guid = guid
    local entry = EmpireManager.db.global.registry[guid]
    if not entry then
        return
    end
    if not entry.assignments then
        entry.assignments = {}
    end

    local content = self.ContentArea.ContentPanel

    -- Clear previous content: hide + release closure references
    if self._widgets then
        for _, obj in ipairs(self._widgets) do
            if obj.Hide then
                obj:Hide()
            end
            if obj.HasScript then
                if obj:HasScript("OnClick") then
                    obj:SetScript("OnClick", nil)
                end
                if obj:HasScript("OnEnter") then
                    obj:SetScript("OnEnter", nil)
                end
                if obj:HasScript("OnLeave") then
                    obj:SetScript("OnLeave", nil)
                end
                if obj:HasScript("OnTextChanged") then
                    obj:SetScript("OnTextChanged", nil)
                end
                if obj:HasScript("OnEnterPressed") then
                    obj:SetScript("OnEnterPressed", nil)
                end
            end
        end
    end
    self._widgets = {}

    local isCurrentChar = (guid == EmpireManager.playerGUID)
    local tab = self._selectedTab or 1
    local y = 8

    -- Toggle visibility for NotesEdit / ContentPanel
    local notesEdit = self.ContentArea.NotesEdit
    notesEdit:Hide()
    if self._notesHdr then
        self._notesHdr:Hide()
    end
    if self._notesHdrTip then
        self._notesHdrTip:Hide()
    end
    content:Show()

    if tab == 1 then
        y = self:BuildAssignments(content, y, entry, guid, isCurrentChar)
    elseif tab == 2 then
        y = self:BuildDetails(content, y, entry, guid)
    elseif tab == 3 then
        y = self:BuildGold(content, y, entry, guid, isCurrentChar)
    elseif tab == 4 then
        content:Hide()
        notesEdit:Show()
        self:BuildNotes(entry, guid, isCurrentChar)
    elseif tab == 5 then
        y = self:BuildOptions(content, y, entry, guid, isCurrentChar)
    end
end

function EMSidecarMixin:Track(obj)
    self._widgets[#self._widgets + 1] = obj
    return obj
end

function EMSidecarMixin:SyncAssignments()
    if EmpireManager.ledgerScroll then
        EmpireManager:RefreshVisibleRows()
    end
end

-- Deferred sync+refresh to avoid tainting Blizzard secure widgets (ScrollBox, etc.)
-- All callbacks that modify data AND rebuild UI should go through this.
function EMSidecarMixin:DeferredRefresh(_entry, guid, _isCurrentChar, syncType)
    C_Timer.After(0, function()
        if syncType == "assignments" or syncType == "both" then
            self:SyncAssignments()
            EmpireManager:OnTriageOptionChanged()
        end
        self:Populate(guid)
    end)
end

-------------------------------------------------------------------------------
-- Assignments Tab
-------------------------------------------------------------------------------

local ROLE_TOOLTIPS = EmpireManager.ROLE_TOOLTIPS

function EMSidecarMixin:BuildAssignments(content, y, entry, guid, isCurrentChar)
    -- Heading
    local hdr = self:Track(content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"))
    hdr:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
    hdr:SetText("|cffffd100Select your character roles|r")
    y = y + LINE_HEIGHT + 6

    -- Auto button: rebuild Artisan/Gatherer prof selections to match the
    -- character's actual professions. Always enabled - the operation is
    -- idempotent and clicking it with no profs just clears stale selections.
    local autoBtn = self:Track(CreateFrame("Button", nil, content, "UIPanelButtonTemplate"))
    autoBtn:SetSize(80, 22)
    autoBtn:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
    autoBtn:SetText("Auto")
    autoBtn:SetScript("OnClick", function()
        EmpireManager:AutoAssignRoles(entry, guid)
        self:DeferredRefresh(entry, guid, isCurrentChar, "assignments")
    end)
    autoBtn:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_CURSOR_RIGHT")
        GameTooltip:AddLine("Auto-Assign Roles", 1, 0.82, 0)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Detects professions and assigns roles.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    autoBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    y = y + 28

    -- Build profession lookup by category
    local profsByCategory = { crafting = {}, gathering = {} }
    for _, info in ipairs(EmpireManager.PROF_DISPLAY) do
        if profsByCategory[info.category] then
            profsByCategory[info.category][#profsByCategory[info.category] + 1] = info
        end
    end

    for _, display in ipairs(EmpireManager.ROLE_DISPLAY) do
        local roleKey = display.key
        local hasProfType = display.profType and profsByCategory[display.profType]
        local isActive = entry.assignments[roleKey] ~= nil

        -- For artisan/gatherer: checked = has any prof selected
        if hasProfType then
            local roleData = entry.assignments[roleKey]
            isActive = roleData and type(roleData) == "table" and next(roleData) ~= nil
        end

        -- Role checkbox
        local cb = self:Track(CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate"))
        cb:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
        cb:SetChecked(isActive)

        local cbLabel = self:Track(content:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
        cbLabel:SetPoint("LEFT", cb, "RIGHT", 2, 0)
        cbLabel:SetText(string.format(ICON16_FMT, display.icon, display.label or roleKey))

        -- Tooltip on checkbox + label hit-rect
        local tipText = ROLE_TOOLTIPS[roleKey]
        if tipText then
            local function showTip(anchor)
                GameTooltip:SetOwner(anchor, "ANCHOR_CURSOR_RIGHT")
                GameTooltip:AddLine(display.label or roleKey, 1, 0.82, 0)
                GameTooltip:AddLine(" ")
                for line in tipText:gmatch("[^\n]+") do
                    GameTooltip:AddLine(line, 1, 1, 1, true)
                end
                GameTooltip:Show()
            end
            local function hideTip()
                GameTooltip:Hide()
            end
            cb:SetScript("OnEnter", function(btn)
                showTip(btn)
            end)
            cb:SetScript("OnLeave", hideTip)
            -- Invisible hit-rect over the label so tooltip works on text too
            local hitRect = self:Track(CreateFrame("Frame", nil, content))
            hitRect:SetAllPoints(cbLabel)
            hitRect:SetScript("OnEnter", function(f)
                showTip(f)
            end)
            hitRect:SetScript("OnLeave", hideTip)
            WireLabelClick(hitRect, cb)
        end

        if hasProfType then
            -- Artisan/Gatherer: checkbox is read-only, driven by dropdown
            cb:SetEnabled(false)
            cb:SetMotionScriptsWhileDisabled(true)

            -- Profession multi-select dropdown (max 2)
            local profs = profsByCategory[display.profType]
            local profDD = self:Track(CreateFrame("DropdownButton", nil, content, "WowStyle1DropdownTemplate"))
            profDD:SetPoint("TOPLEFT", content, "TOPLEFT", 170, -(y - 2))
            profDD:SetWidth(220)

            local capturedRole = roleKey
            profDD:SetupMenu(function(_, rootDescription)
                for _, pInfo in ipairs(profs) do
                    local capturedKey = pInfo.key
                    rootDescription:CreateCheckbox(string.format("|T%s:14:14|t %s", pInfo.icon, pInfo.label), function()
                        local roleData = entry.assignments[capturedRole]
                        return roleData and roleData[capturedKey] or false
                    end, function()
                        if not entry.assignments[capturedRole] then
                            entry.assignments[capturedRole] = {}
                        end
                        local roleData = entry.assignments[capturedRole]
                        if roleData[capturedKey] then
                            roleData[capturedKey] = nil
                            -- If no profs left, remove the role
                            if not next(roleData) then
                                entry.assignments[capturedRole] = nil
                            end
                        else
                            if not EmpireManager:CanAddProfession(entry, capturedRole, capturedKey) then
                                return
                            end
                            roleData[capturedKey] = true
                        end
                        EmpireManagerSidecar:DeferredRefresh(entry, guid, isCurrentChar, "assignments")
                    end)
                end
            end)
        else
            -- Normal roles: checkbox toggles directly
            cb:SetScript("OnClick", function(btn)
                local checked = btn:GetChecked()
                if checked then
                    entry.assignments[roleKey] = entry.assignments[roleKey] or {}
                else
                    entry.assignments[roleKey] = nil
                end
                self:DeferredRefresh(entry, guid, isCurrentChar, "assignments")
            end)
        end

        y = y + 34
    end

    return y
end

-------------------------------------------------------------------------------
-- Details Tab (read-only character info)
-------------------------------------------------------------------------------

function EMSidecarMixin:BuildDetails(content, y, entry, _guid)
    local RACE_NAMES = EmpireManager.RACE_NAMES
    local parent = content

    -- Clear previous detail widgets
    if self._detailWidgets then
        for _, obj in ipairs(self._detailWidgets) do
            if obj.Hide then
                obj:Hide()
            end
        end
    end
    self._detailWidgets = {}

    local function track(obj)
        self._detailWidgets[#self._detailWidgets + 1] = obj
        self._widgets[#self._widgets + 1] = obj
        return obj
    end

    -- Divider above every heading; the unlabelled Identity rows open the tab.
    local function addSection(label)
        y = y + 4
        local sep = track(parent:CreateTexture(nil, "ARTWORK"))
        sep:SetAtlas("perks-divider-short", true)
        sep:SetPoint("TOP", parent, "TOP", 0, -y)
        y = y + 16
        local hdr = track(parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"))
        hdr:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -y)
        hdr:SetText("|cffffd100" .. label .. "|r")
        y = y + LINE_HEIGHT + 6
    end

    local function addRow(label, value, r, g, b)
        if not value or value == "" then
            return
        end
        if label ~= nil and label ~= "" then
            local lbl = track(parent:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
            lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, -y)
            lbl:SetText(label)
        end
        local val = track(parent:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
        -- label == nil → full-width row at x=12; label == "" → value column at x=120 (continuation row)
        local valX = (label == nil) and 12 or 120
        val:SetPoint("TOPLEFT", parent, "TOPLEFT", valX, -y)
        val:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
        val:SetJustifyH("LEFT")
        val:SetWordWrap(true)
        val:SetNonSpaceWrap(true)
        val:SetText(value)
        val:SetTextColor(r or 1, g or 1, b or 1)
        -- Grow row height when text wraps so subsequent rows don't overlap
        local h = val:GetStringHeight()
        y = y + math.max(LINE_HEIGHT, math.ceil(h) + 2)
    end

    local cc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[entry.class]
    local specLine = EmpireManager:GetSpecClassLine(entry)
    addRow("Class", specLine, cc and cc.r or 0.8, cc and cc.g or 0.8, cc and cc.b or 0.8)

    -- Race & Faction on one row
    local raceStr = RACE_NAMES[entry.race] or entry.race or "?"
    local raceFaction = raceStr
    if entry.faction and entry.faction ~= "" then
        raceFaction = raceStr .. "  |cff888888·|r  " .. entry.faction
    end
    addRow("Race", raceFaction, 1, 1, 1)

    -- Level & iLvl on one row
    local levelStr = tostring(entry.level or 0)
    if entry.ilvl and entry.ilvl > 0 then
        levelStr = levelStr .. string.format("  |cff888888·|r  |cffffd100iLvl %.0f|r", entry.ilvl)
    end
    addRow("Level", levelStr, 1, 1, 1)

    addRow("Guild", entry.guild ~= "" and entry.guild or nil, 1, 1, 1)
    addRow("Realm", entry.realm ~= "" and entry.realm or nil, 1, 1, 1)

    -- Last Seen & /played on one row (inside Identity)
    local seenStr = EmpireManager:FormatTimeSince(entry.lastSeen)
    local playedStr = EmpireManager:FormatPlaytime(entry.playedTotal)
    local metaLine = seenStr or ""
    if playedStr then
        metaLine = (seenStr and (seenStr .. "  |cff888888·|r  ") or "") .. "/played " .. playedStr
    end
    addRow("Last Seen", metaLine ~= "" and metaLine or nil, 1, 1, 1)

    -- Zone (last in Identity, no Location header)
    if entry.zone then
        local zoneLine = entry.zone
        if entry.subZone and entry.subZone ~= "" then
            zoneLine = zoneLine .. " - " .. entry.subZone
        end
        addRow("Zone", zoneLine, 0.85, 0.92, 1.0)
    end

    -- Professions section (holds Roles row + profession list)
    local roleNames = {}
    if entry.assignments then
        for _, display in ipairs(EmpireManager.ROLE_DISPLAY) do
            if entry.assignments[display.key] then
                roleNames[#roleNames + 1] = display.label or display.key
            end
        end
    end
    local hasProfs = entry.professions and #entry.professions > 0
    if hasProfs or #roleNames > 0 then
        y = y + 6
        addSection("Professions")
        if #roleNames > 0 then
            addRow("Roles", table.concat(roleNames, ", "), 1, 1, 1)
        end
        if hasProfs then
            for _, p in ipairs(entry.professions) do
                local skill, maxSkill = p.skill or 0, p.maxSkill or 0
                local newest = EmpireManager:NewestExpansionSkill(p)
                if newest then
                    skill, maxSkill = newest.skill, newest.maxSkill
                end
                local profInfo = EmpireManager:ProfInfoFromEntryProf(p)
                local r, g, b = 1, 1, 1
                if profInfo then
                    r, g, b = profInfo.r, profInfo.g, profInfo.b
                end
                addRow("", string.format("%s %d/%d", p.name, skill, maxSkill), r, g, b)
            end
        end
    end

    -- Storage (with fill bars)
    y = y + 6
    addSection("Storage")

    local function colorForPct(pct)
        if pct >= 0.85 then
            return 1.0, 0.2, 0.2
        elseif pct >= 0.60 then
            return 1.0, 0.8, 0.0
        else
            return 0.0, 0.8, 0.0
        end
    end

    local function addBarRow(label, free, total)
        if not total or total <= 0 then
            addRow(label, "No data", 0.5, 0.5, 0.5)
            return
        end
        local used = total - (free or 0)
        local pct = used / total

        -- Label on the left
        local lbl = track(parent:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
        lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, -y)
        lbl:SetText(label)

        -- Status bar (aligned with other addRow values at x=120)
        local bar = track(CreateFrame("StatusBar", nil, parent))
        bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(pct)
        bar:SetSize(90, 10)
        bar:SetPoint("TOPLEFT", parent, "TOPLEFT", 120, -y)
        local r, g, b = colorForPct(pct)
        bar:SetStatusBarColor(r, g, b)
        local bg = bar:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.1, 0.1, 0.1, 0.8)

        -- Used/total text on the right
        local val = track(parent:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
        val:SetPoint("LEFT", bar, "RIGHT", 6, 1)
        val:SetText(string.format("%d/%d  (%d%%)", used, total, math.floor(pct * 100 + 0.5)))
        val:SetTextColor(1, 1, 1)

        y = y + LINE_HEIGHT
    end

    addBarRow("Bags", entry.freeBagSlots, entry.totalBagSlots)
    addBarRow("Bank", entry.freeBankSlots, entry.totalBankSlots)

    return y
end

-------------------------------------------------------------------------------
-- Gold Tab
-------------------------------------------------------------------------------

local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:12:12|t"

local function FormatMoneyGSC(copper)
    copper = copper or 0
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    return string.format("%d%s %d%s %d%s", g, GOLD_ICON, s, SILVER_ICON, c, COPPER_ICON)
end

function EMSidecarMixin:BuildGold(content, y, entry, _guid, isCurrentChar)
    local parent = content

    local function track(obj)
        self._widgets[#self._widgets + 1] = obj
        return obj
    end

    -- Section header in the Details/Storage style (no leading divider on the first).
    local function addSection(label, first)
        if not first then
            y = y + 4
            local sep = track(parent:CreateTexture(nil, "ARTWORK"))
            sep:SetAtlas("perks-divider-short", true)
            sep:SetPoint("TOP", parent, "TOP", 0, -y)
            y = y + 16
        end
        local hdr = track(parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"))
        hdr:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -y)
        hdr:SetText("|cffffd100" .. label .. "|r")
        y = y + LINE_HEIGHT + 6
    end

    local function addRow(label, value)
        local lbl = track(parent:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
        lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, -y)
        lbl:SetText(label)
        local val = track(parent:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
        val:SetPoint("TOPLEFT", parent, "TOPLEFT", 120, -y)
        val:SetText(value)
        val:SetTextColor(1, 1, 1)
        y = y + LINE_HEIGHT
    end

    addSection("Gold", true)
    -- Bags: live money for the logged-in character, last snapshot for others.
    local bagsGold = isCurrentChar and GetMoney() or (entry.gold or 0)
    addRow("Bags", FormatMoneyGSC(bagsGold))
    -- Warband Bank gold is account-wide (shared pool), snapshotted on bank open.
    addRow("Warband", FormatMoneyGSC(EmpireManager.db.global.warbandGold or 0))

    -- Auto-Balance: keep this character's bag gold between a low and high amount
    -- by moving gold to/from warband gold. Whole-gold input, stored as copper on
    -- the registry entry (entry.goldLow / goldHigh). 0 = that
    -- side off; low must be <= high. The transfer itself runs on warband bank
    -- open (see EmpireManager:MaybeWarbandGoldTransfer), gated by the General
    -- "Auto transfer gold at Warband Bank" option.
    addSection("Auto-Balance")
    local hint = track(parent:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
    hint:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, -y)
    hint:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
    hint:SetJustifyH("LEFT")
    hint:SetWordWrap(true)
    hint:SetSpacing(4) -- leading between wrapped lines so the paragraph isn't cramped
    hint:SetText(
        "At a Warband Bank, keep this character's bag gold in range: withdraw warband gold when below the first amount, deposit the excess when above the second. Leave either at 0 to turn that side off."
    )
    hint:SetTextColor(1, 1, 1)
    -- Extra breathing room after the description before the input rows.
    y = y + math.max(LINE_HEIGHT, math.ceil(hint:GetStringHeight()) + 2) + 14

    local function commitGoldLimit(field, box, prevGold)
        local txt = box:GetText()
        local num = tonumber(txt)
        local copper = (num and num > 0) and math.floor(num) * 10000 or 0
        local low = (field == "goldLow") and copper or (entry.goldLow or 0)
        local high = (field == "goldHigh") and copper or (entry.goldHigh or 0)
        if low > 0 and high > 0 and low > high then
            -- low above high is contradictory - revert to the previous value
            box:SetText(prevGold > 0 and tostring(prevGold) or "")
            box:ClearFocus()
            return
        end
        entry[field] = copper
        box:ClearFocus()
    end

    local function addGoldLimitRow(label, field)
        local lbl = track(parent:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
        lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, -y)
        lbl:SetText(label)
        local box = track(CreateFrame("EditBox", nil, parent, "InputBoxTemplate"))
        box:SetSize(80, 20)
        box:SetPoint("TOPLEFT", parent, "TOPLEFT", 150, -y + 2)
        box:SetAutoFocus(false)
        box:SetNumeric(true)
        box:SetMaxLetters(6)
        box:SetJustifyH("RIGHT")
        -- Right-justified text hugs the border; pad the right so it isn't flush.
        box:SetTextInsets(5, 8, 0, 0)
        local prevGold = math.floor((entry[field] or 0) / 10000)
        box:SetText(prevGold > 0 and tostring(prevGold) or "")
        local goldIcon = track(parent:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
        goldIcon:SetPoint("LEFT", box, "RIGHT", 4, 0)
        goldIcon:SetText(GOLD_ICON)
        box:SetScript("OnEnterPressed", function(self)
            commitGoldLimit(field, self, prevGold)
        end)
        box:SetScript("OnEscapePressed", function(self)
            self:SetText(prevGold > 0 and tostring(prevGold) or "")
            self:ClearFocus()
        end)
        box:SetScript("OnEditFocusLost", function(self)
            commitGoldLimit(field, self, prevGold)
        end)
        y = y + 26
    end

    addGoldLimitRow("Withdraw if below", "goldLow")
    addGoldLimitRow("Deposit if above", "goldHigh")

    return y
end

-------------------------------------------------------------------------------
-- Notes Tab
-------------------------------------------------------------------------------

function EMSidecarMixin:BuildNotes(entry, _guid, _isCurrentChar)
    -- Heading
    local panel = self.ContentArea.ContentPanel
    if not self._notesHdr then
        self._notesHdr = self.ContentArea:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        self._notesHdr:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -8)
        self._notesHdr:SetText("|cffffd100Edit Notes|r")

        -- Tooltip hit-rect explaining when notes save
        self._notesHdrTip = CreateFrame("Frame", nil, self.ContentArea)
        self._notesHdrTip:SetAllPoints(self._notesHdr)
        self._notesHdrTip:SetScript("OnEnter", function(f)
            GameTooltip:SetOwner(f, "ANCHOR_CURSOR_RIGHT")
            GameTooltip:AddLine("Edit Notes", 1, 0.82, 0)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(
                "Notes are saved automatically when you click outside the text box or press Escape.",
                1,
                1,
                1,
                true
            )
            GameTooltip:Show()
        end)
        self._notesHdrTip:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
    end
    self._notesHdr:Show()
    if self._notesHdrTip then
        self._notesHdrTip:Show()
    end

    local notesEdit = self.ContentArea.NotesEdit
    -- Anchor NotesEdit to ContentPanel so it inherits the same margins as other tabs
    notesEdit:ClearAllPoints()
    notesEdit:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -40)
    notesEdit:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -14, 80)
    local editBox = notesEdit.EditBox
    editBox:SetFontObject(ChatFontNormal)
    editBox:SetText(entry.storageNote or "")
end

-------------------------------------------------------------------------------
-- Options Tab
-------------------------------------------------------------------------------

function EMSidecarMixin:BuildOptions(content, y, entry, guid, _isCurrentChar)
    -- Dashboard section
    local dashHdr = self:Track(content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"))
    dashHdr:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
    dashHdr:SetText("|cffffd100Dashboard|r")
    y = y + LINE_HEIGHT + 6

    -- Sort order
    local sortLabel = self:Track(content:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
    sortLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 12, -y)
    sortLabel:SetText("Sort Order (#)")
    local sortTip = self:Track(CreateFrame("Frame", nil, content))
    sortTip:SetAllPoints(sortLabel)
    sortTip:SetScript("OnEnter", function(f)
        GameTooltip:SetOwner(f, "ANCHOR_CURSOR_RIGHT")
        GameTooltip:AddLine("Sort Order", 1, 0.82, 0)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(
            "Sets this character's sort position when the dashboard is sorted by #. Leave blank or 0 to remove.",
            1,
            1,
            1,
            true
        )
        GameTooltip:Show()
    end)
    sortTip:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    local sortBox = self:Track(CreateFrame("EditBox", nil, content, "InputBoxTemplate"))
    sortBox:SetSize(60, 20)
    sortBox:SetPoint("LEFT", sortLabel, "LEFT", 120, 0)
    sortBox:SetAutoFocus(false)
    sortBox:SetNumeric(true)
    sortBox:SetMaxLetters(2)
    local currentSort = entry.sortOrder or 0
    sortBox:SetText(currentSort > 0 and tostring(currentSort) or "")
    local commitSort = function(self)
        local text = self:GetText()
        local num = tonumber(text)
        if text == "" or text == nil then
            num = 0
        elseif not num or num ~= math.floor(num) or num < 0 or num > 99 then
            self:SetText(currentSort > 0 and tostring(currentSort) or "")
            self:ClearFocus()
            return
        end
        if num == (entry.sortOrder or 0) then
            self:ClearFocus()
            return
        end
        EmpireManager:ResolveSortConflict(guid, num)
        entry.sortOrder = num
        currentSort = num
        self:SetText(num > 0 and tostring(num) or "")
        self:ClearFocus()
        if EmpireManager.dashboardFrame and EmpireManager.dashboardFrame:IsShown() then
            EmpireManager:ApplyFilters()
        end
    end
    sortBox:SetScript("OnEnterPressed", commitSort)
    sortBox:SetScript("OnEditFocusLost", commitSort)
    sortBox:SetScript("OnEscapePressed", function(self)
        self:SetText(currentSort > 0 and tostring(currentSort) or "")
        self:ClearFocus()
    end)
    y = y + 28

    -- Separator
    y = y + 4
    local sep1 = self:Track(content:CreateTexture(nil, "ARTWORK"))
    sep1:SetAtlas("perks-divider-short", true)
    sep1:SetPoint("TOP", content, "TOP", 0, -y)
    y = y + 16

    -- Role Behavior section header
    local roleHdr = self:Track(content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"))
    roleHdr:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
    roleHdr:SetText("|cffffd100Role Behavior|r")
    y = y + LINE_HEIGHT + 6

    -- Auctioneer: Keep BoE
    local asnData = entry.assignments or {}
    local hasAuctioneer = asnData.auctioneer
    local ahCB = self:Track(CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate"))
    ahCB:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
    ahCB:SetChecked(entry.auctioneerKeepBOE ~= false)
    ahCB:SetEnabled(hasAuctioneer)
    ahCB:SetMotionScriptsWhileDisabled(true)
    local ahLabel = self:Track(content:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
    ahLabel:SetPoint("LEFT", ahCB, "RIGHT", 2, 0)
    ahLabel:SetText("Auctioneer: Keep BoE Equipment")
    ahLabel:SetTextColor(hasAuctioneer and 1 or 0.5, hasAuctioneer and 1 or 0.5, hasAuctioneer and 1 or 0.5)
    local function showAhTip(anchor)
        GameTooltip:SetOwner(anchor, "ANCHOR_CURSOR_RIGHT")
        GameTooltip:AddLine("Keep BoE Equipment", 1, 0.82, 0)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(
            "When checked, Triage keeps unbound BoE equipment in this character's bags for AH listing instead of routing it to storage.",
            1,
            1,
            1,
            true
        )
        if not hasAuctioneer then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Requires the Auctioneer role.", 1, 0.5, 0.5, true)
        end
        GameTooltip:Show()
    end
    local function hideAhTip()
        GameTooltip:Hide()
    end
    ahCB:SetScript("OnEnter", function(btn)
        showAhTip(btn)
    end)
    ahCB:SetScript("OnLeave", hideAhTip)
    local ahHit = self:Track(CreateFrame("Frame", nil, content))
    ahHit:SetAllPoints(ahLabel)
    ahHit:SetScript("OnEnter", function(f)
        showAhTip(f)
    end)
    ahHit:SetScript("OnLeave", hideAhTip)
    WireLabelClick(ahHit, ahCB)
    ahCB:SetScript("OnClick", function(self)
        entry.auctioneerKeepBOE = self:GetChecked()
        EmpireManager:OnTriageOptionChanged()
    end)
    y = y + 32

    -- Enchanter: Keep for DE
    local hasEnchanting = asnData.artisan and asnData.artisan.enchanting
    local deCB = self:Track(CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate"))
    deCB:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
    deCB:SetChecked(entry.enchanterKeepDE ~= false)
    deCB:SetEnabled(hasEnchanting)
    deCB:SetMotionScriptsWhileDisabled(true)
    local deLabel = self:Track(content:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
    deLabel:SetPoint("LEFT", deCB, "RIGHT", 2, 0)
    deLabel:SetText("Enchanter: Keep Vendor Gear for DE")
    deLabel:SetTextColor(hasEnchanting and 1 or 0.5, hasEnchanting and 1 or 0.5, hasEnchanting and 1 or 0.5)
    local function showDeTip(anchor)
        GameTooltip:SetOwner(anchor, "ANCHOR_CURSOR_RIGHT")
        GameTooltip:AddLine("Keep Gear for Disenchanting", 1, 0.82, 0)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(
            "When checked, Triage keeps soulbound gear that would be vendored in bags for disenchanting instead.",
            1,
            1,
            1,
            true
        )
        if not hasEnchanting then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Requires the Artisan role with Enchanting.", 1, 0.5, 0.5, true)
        end
        GameTooltip:Show()
    end
    local function hideDeTip()
        GameTooltip:Hide()
    end
    deCB:SetScript("OnEnter", function(btn)
        showDeTip(btn)
    end)
    deCB:SetScript("OnLeave", hideDeTip)
    local deHit = self:Track(CreateFrame("Frame", nil, content))
    deHit:SetAllPoints(deLabel)
    deHit:SetScript("OnEnter", function(f)
        showDeTip(f)
    end)
    deHit:SetScript("OnLeave", hideDeTip)
    WireLabelClick(deHit, deCB)
    deCB:SetScript("OnClick", function(self)
        entry.enchanterKeepDE = self:GetChecked()
        EmpireManager:OnTriageOptionChanged()
    end)
    y = y + 32

    -- Keep own profession mats in character bank
    local hasAnyProf = (asnData.artisan and next(asnData.artisan)) or (asnData.gatherer and next(asnData.gatherer))
    local profMatCB = self:Track(CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate"))
    profMatCB:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
    profMatCB:SetChecked(entry.keepOwnProfMatsInBank == true)
    profMatCB:SetEnabled(hasAnyProf)
    profMatCB:SetMotionScriptsWhileDisabled(true)
    local profMatLabel = self:Track(content:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
    profMatLabel:SetPoint("LEFT", profMatCB, "RIGHT", 2, 0)
    profMatLabel:SetText("Keep Profession materials in Character Bank")
    profMatLabel:SetTextColor(hasAnyProf and 1 or 0.5, hasAnyProf and 1 or 0.5, hasAnyProf and 1 or 0.5)
    local function showProfMatTip(anchor)
        GameTooltip:SetOwner(anchor, "ANCHOR_CURSOR_RIGHT")
        GameTooltip:AddLine("Keep Profession materials in Bank", 1, 0.82, 0)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(
            "When checked, Bank Triage will not move items matching this character's assigned professions out of their personal bank.",
            1,
            1,
            1,
            true
        )
        if not hasAnyProf then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Requires Artisan or Gatherer role with at least one profession.", 1, 0.5, 0.5, true)
        end
        GameTooltip:Show()
    end
    local function hideProfMatTip()
        GameTooltip:Hide()
    end
    profMatCB:SetScript("OnEnter", function(btn)
        showProfMatTip(btn)
    end)
    profMatCB:SetScript("OnLeave", hideProfMatTip)
    local profMatHit = self:Track(CreateFrame("Frame", nil, content))
    profMatHit:SetAllPoints(profMatLabel)
    profMatHit:SetScript("OnEnter", function(f)
        showProfMatTip(f)
    end)
    profMatHit:SetScript("OnLeave", hideProfMatTip)
    WireLabelClick(profMatHit, profMatCB)
    profMatCB:SetScript("OnClick", function(self)
        entry.keepOwnProfMatsInBank = self:GetChecked()
        EmpireManager:OnTriageOptionChanged()
    end)
    y = y + 28

    -- Keep own profession mats in bags
    local bagMatCB = self:Track(CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate"))
    bagMatCB:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
    bagMatCB:SetChecked(entry.keepOwnProfMatsInBags == true)
    bagMatCB:SetEnabled(hasAnyProf)
    bagMatCB:SetMotionScriptsWhileDisabled(true)
    local bagMatLabel = self:Track(content:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
    bagMatLabel:SetPoint("LEFT", bagMatCB, "RIGHT", 2, 0)
    bagMatLabel:SetText("Keep Profession materials in Bags")
    bagMatLabel:SetTextColor(hasAnyProf and 1 or 0.5, hasAnyProf and 1 or 0.5, hasAnyProf and 1 or 0.5)
    local function showBagMatTip(anchor)
        GameTooltip:SetOwner(anchor, "ANCHOR_CURSOR_RIGHT")
        GameTooltip:AddLine("Keep Profession materials in Bags", 1, 0.82, 0)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(
            "When checked, Triage will not route items matching this character's assigned professions out of bags to storage.",
            1,
            1,
            1,
            true
        )
        if not hasAnyProf then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Requires Artisan or Gatherer role with at least one profession.", 1, 0.5, 0.5, true)
        end
        GameTooltip:Show()
    end
    bagMatCB:SetScript("OnEnter", function(btn)
        showBagMatTip(btn)
    end)
    bagMatCB:SetScript("OnLeave", hideProfMatTip)
    local bagMatHit = self:Track(CreateFrame("Frame", nil, content))
    bagMatHit:SetAllPoints(bagMatLabel)
    bagMatHit:SetScript("OnEnter", function(f)
        showBagMatTip(f)
    end)
    bagMatHit:SetScript("OnLeave", hideProfMatTip)
    WireLabelClick(bagMatHit, bagMatCB)
    -- Forward declaration: parent OnClick toggles the sub-checkbox enabled state.
    local bagMatLatestCB, bagMatLatestLabel
    bagMatCB:SetScript("OnClick", function(self)
        entry.keepOwnProfMatsInBags = self:GetChecked()
        EmpireManager:OnTriageOptionChanged()
        if bagMatLatestCB then
            local subEnabled = hasAnyProf and (entry.keepOwnProfMatsInBags == true)
            bagMatLatestCB:SetEnabled(subEnabled)
            local c = subEnabled and 1 or 0.5
            bagMatLatestLabel:SetTextColor(c, c, c)
        end
    end)
    y = y + 28

    -- Sub-option: only keep latest-expansion mats in bags
    bagMatLatestCB = self:Track(CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate"))
    bagMatLatestCB:SetPoint("TOPLEFT", content, "TOPLEFT", 28, -y)
    bagMatLatestCB:SetChecked(entry.keepOwnProfMatsInBagsLatestOnly == true)
    local bagMatLatestEnabled = hasAnyProf and (entry.keepOwnProfMatsInBags == true)
    bagMatLatestCB:SetEnabled(bagMatLatestEnabled)
    bagMatLatestCB:SetMotionScriptsWhileDisabled(true)
    bagMatLatestLabel = self:Track(content:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
    bagMatLatestLabel:SetPoint("LEFT", bagMatLatestCB, "RIGHT", 2, 0)
    bagMatLatestLabel:SetText("Latest expansion only")
    bagMatLatestLabel:SetTextColor(
        bagMatLatestEnabled and 1 or 0.5,
        bagMatLatestEnabled and 1 or 0.5,
        bagMatLatestEnabled and 1 or 0.5
    )
    local function showBagMatLatestTip(anchor)
        GameTooltip:SetOwner(anchor, "ANCHOR_CURSOR_RIGHT")
        GameTooltip:AddLine("Keep latest-expansion mats only", 1, 0.82, 0)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(
            "When checked, only materials from the latest expansion are kept in bags. Older expansion materials route to storage as usual.",
            1,
            1,
            1,
            true
        )
        if not hasAnyProf then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Requires Artisan or Gatherer role with at least one profession.", 1, 0.5, 0.5, true)
        elseif not entry.keepOwnProfMatsInBags then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Requires \"Keep Profession materials in Bags\" to be enabled.", 1, 0.5, 0.5, true)
        end
        GameTooltip:Show()
    end
    bagMatLatestCB:SetScript("OnEnter", function(btn)
        showBagMatLatestTip(btn)
    end)
    bagMatLatestCB:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    local bagMatLatestHit = self:Track(CreateFrame("Frame", nil, content))
    bagMatLatestHit:SetAllPoints(bagMatLatestLabel)
    bagMatLatestHit:SetScript("OnEnter", function(f)
        showBagMatLatestTip(f)
    end)
    bagMatLatestHit:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    WireLabelClick(bagMatLatestHit, bagMatLatestCB)
    bagMatLatestCB:SetScript("OnClick", function(self)
        entry.keepOwnProfMatsInBagsLatestOnly = self:GetChecked()
        EmpireManager:OnTriageOptionChanged()
    end)
    y = y + 28

    -- Stash Old Quest items to character bank
    local questCB = self:Track(CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate"))
    questCB:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
    questCB:SetChecked(entry.stashOldQuestItems == true)
    local questLabel = self:Track(content:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
    questLabel:SetPoint("LEFT", questCB, "RIGHT", 2, 0)
    questLabel:SetText("Stash Old Quest items in Character Bank")
    local function showQuestTip(anchor)
        GameTooltip:SetOwner(anchor, "ANCHOR_CURSOR_RIGHT")
        GameTooltip:AddLine("Stash Old Quest items", 1, 0.82, 0)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(
            "When checked, Soulbound Quest items from previous expansions are routed to this character's Bank instead of cluttering bags.",
            1,
            1,
            1,
            true
        )
        GameTooltip:Show()
    end
    local function hideQuestTip()
        GameTooltip:Hide()
    end
    questCB:SetScript("OnEnter", function(btn)
        showQuestTip(btn)
    end)
    questCB:SetScript("OnLeave", hideQuestTip)
    local questHit = self:Track(CreateFrame("Frame", nil, content))
    questHit:SetAllPoints(questLabel)
    questHit:SetScript("OnEnter", function(f)
        showQuestTip(f)
    end)
    questHit:SetScript("OnLeave", hideQuestTip)
    WireLabelClick(questHit, questCB)
    questCB:SetScript("OnClick", function(self)
        entry.stashOldQuestItems = self:GetChecked()
        EmpireManager:OnTriageOptionChanged()
    end)
    y = y + 28

    -- Skip all Storage Rules for this character
    local skipCB = self:Track(CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate"))
    skipCB:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
    skipCB:SetChecked(entry.ignoreStorageRules == true)
    local skipLabel = self:Track(content:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
    skipLabel:SetPoint("LEFT", skipCB, "RIGHT", 2, 0)
    skipLabel:SetText("Skip All Storage Rules")
    local function showSkipTip(anchor)
        GameTooltip:SetOwner(anchor, "ANCHOR_CURSOR_RIGHT")
        GameTooltip:AddLine("Skip All Storage Rules", 1, 0.82, 0)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(
            "When checked, this Character is exempt from all Storage Rules: Triage will not stash, mail, take out, or reorganize materials and equipment on its behalf. Items stay in Bags. Vendor Rules and other Roles' routing still apply.",
            1,
            1,
            1,
            true
        )
        GameTooltip:Show()
    end
    local function hideSkipTip()
        GameTooltip:Hide()
    end
    skipCB:SetScript("OnEnter", function(btn)
        showSkipTip(btn)
    end)
    skipCB:SetScript("OnLeave", hideSkipTip)
    local skipHit = self:Track(CreateFrame("Frame", nil, content))
    skipHit:SetAllPoints(skipLabel)
    skipHit:SetScript("OnEnter", function(f)
        showSkipTip(f)
    end)
    skipHit:SetScript("OnLeave", hideSkipTip)
    WireLabelClick(skipHit, skipCB)
    skipCB:SetScript("OnClick", function(self)
        entry.ignoreStorageRules = self:GetChecked()
        EmpireManager:OnTriageOptionChanged()
    end)
    y = y + 44

    -- Separator
    y = y + 4
    local sep2 = self:Track(content:CreateTexture(nil, "ARTWORK"))
    sep2:SetAtlas("perks-divider-short", true)
    sep2:SetPoint("TOP", content, "TOP", 0, -y)
    y = y + 16

    -- Danger Zone
    local dangerHdr = self:Track(content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"))
    dangerHdr:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
    dangerHdr:SetText("|cffff4444Danger Zone|r")
    y = y + LINE_HEIGHT + 6

    local deleteBtn = self:Track(CreateFrame("Button", nil, content, "UIPanelButtonTemplate"))
    deleteBtn:SetSize(160, 24)
    deleteBtn:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
    deleteBtn:SetText("Remove from Roster")
    deleteBtn:SetScript("OnClick", function()
        EmpireManager:ConfirmPurgeByGUID(guid)
    end)
    deleteBtn:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_CURSOR_RIGHT")
        GameTooltip:AddLine("Remove from Roster", 1, 0.3, 0.3)
        GameTooltip:AddLine("Removes this Character and adds it to the Character Blacklist.", 1, 1, 1, true)
        GameTooltip:AddLine("Use /em charb to restore.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    deleteBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    y = y + 30

    return y
end
