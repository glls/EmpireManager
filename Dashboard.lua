-- ----------------------------------------------------------------------------
--                                   EmpireManager
--                              https://wow.cyberpunk.gr
--                (c) by George Litos (l0neshad0w),  All Rights Reserved
--                   For detailed license information check LICENSE.md
-- ----------------------------------------------------------------------------

local EmpireManager = LibStub("AceAddon-3.0"):GetAddon("EmpireManager")
local ICON16_FMT = EmpireManager.ICON16_FMT

-- Transient filter state (not saved across sessions)
EmpireManager.filterState = {
    searchText = "",
    activeSmartFilters = {},
}

-- Sort state for column header clicks
EmpireManager.sortColumn = "sortOrder"
EmpireManager.sortAscending = true

-- Forward-declare page mixins (populated in Tabs.lua, must exist before XML creates frames)
EMAboutPageMixin = {}
EMMapPageMixin = {}
EMMapRowMixin = {}
EMRosterPageMixin = {}
EMStoragePageMixin = {}
EMStorageRowMixin = {}
EMRestockPageMixin = {}
EMRestockRowMixin = {}
EMRestockItemRowMixin = {}
EMSidecarMixin = {}

-------------------------------------------------------------------------------
-- Column Definitions (single source of truth for headers + row cells)
-------------------------------------------------------------------------------

local COLUMNS = {
    { key = "faction", width = 30, label = "", sortKey = nil, justify = "CENTER" },
    {
        key = "sortOrder",
        width = 30,
        label = "#",
        sortKey = "sortOrder",
        justify = "CENTER",
        tip = "Sort priority",
    },
    {
        key = "name",
        width = 120,
        label = "Name",
        sortKey = "name",
        justify = "LEFT",
        tip = "Character name",
        padLeft = 8,
    },
    {
        key = "level",
        width = 40,
        label = "Lvl",
        sortKey = "level",
        justify = "CENTER",
        tip = "Character level",
    },
    {
        key = "ilvl",
        width = 44,
        label = "iLvl",
        sortKey = "ilvl",
        justify = "CENTER",
        tip = "Equipped item level",
    },
    {
        key = "gold",
        width = 92,
        label = "Gold",
        sortKey = "gold",
        justify = "RIGHT",
        tip = "Gold",
        padRight = 8,
    },
    {
        key = "storage",
        width = 114,
        label = "Storage",
        sortKey = "storage",
        justify = "CENTER",
        tip = "Bag / Bank fill level (sorted by bag free %)",
        custom = true,
    },
    {
        key = "profTags",
        width = 86,
        label = "Profession",
        sortKey = "prof_tags",
        justify = "CENTER",
        tip = "Assigned professions",
    },
    {
        key = "roles",
        width = 204,
        label = "Roles",
        sortKey = "roles",
        justify = "LEFT",
        tip = "Assigned roles",
        padLeft = 8,
    },
}

-------------------------------------------------------------------------------
-- Character Row Mixin (applied to EMCharacterRowTemplate via XML)
-------------------------------------------------------------------------------

EMCharacterRowMixin = {}

function EMCharacterRowMixin:OnLoad()
    self.cells = {}
    local xOffset = 0
    for _, col in ipairs(COLUMNS) do
        if col.custom and col.key == "storage" then
            -- Two stacked thin bars: bags on top, bank on bottom
            local container = CreateFrame("Frame", nil, self)
            container:SetSize(col.width - 8, 16)
            container:SetPoint("LEFT", self, "LEFT", xOffset + 4, 0)

            local bagBar = CreateFrame("StatusBar", nil, container)
            bagBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
            bagBar:SetMinMaxValues(0, 1)
            bagBar:SetSize(col.width - 8, 6)
            bagBar:SetPoint("TOP", container, "TOP", 0, 0)
            bagBar:GetStatusBarTexture():SetAlpha(1.0)

            local bankBar = CreateFrame("StatusBar", nil, container)
            bankBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
            bankBar:SetMinMaxValues(0, 1)
            bankBar:SetSize(col.width - 8, 6)
            bankBar:SetPoint("BOTTOM", container, "BOTTOM", 0, 0)
            bankBar:GetStatusBarTexture():SetAlpha(0.6)

            self.cells.storage = { container = container, bagBar = bagBar, bankBar = bankBar }
        elseif col.key ~= "config" then
            local fs = self:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            fs:SetJustifyH(col.justify)
            fs:SetHeight(20)
            local padL = col.padLeft or 0
            local padR = col.padRight or 0
            fs:SetWidth(col.width - 4 - padL - padR)
            fs:SetPoint("LEFT", self, "LEFT", xOffset + 2 + padL, 0)
            self.cells[col.key] = fs
        end
        xOffset = xOffset + col.width
    end
end

function EMCharacterRowMixin:Populate(data)
    local entry = data.entry
    local guid = data.guid
    self._guid = guid
    self._entry = entry

    -- Zebra stripe (AH-style atlas)
    if data.index % 2 == 0 then
        self.Stripe:SetAtlas("auctionhouse-rowstripe-1")
    else
        self.Stripe:SetAtlas("auctionhouse-rowstripe-2")
    end

    self:UpdateSelected()

    -- Faction icon
    if entry.faction == "Horde" then
        self.cells.faction:SetText("|TInterface\\PVPFrame\\PVP-Currency-Horde:20:20|t")
    elseif entry.faction == "Alliance" then
        self.cells.faction:SetText("|TInterface\\PVPFrame\\PVP-Currency-Alliance:20:20|t")
    else
        self.cells.faction:SetText("")
    end

    -- Sort order
    local so = entry.sortOrder or 0
    self.cells.sortOrder:SetText(so > 0 and tostring(so) or "")
    self.cells.sortOrder:SetTextColor(1, 1, 1)

    -- Name (class-colored)
    self.cells.name:SetText(EmpireManager:ClassColoredName(entry))

    -- Level
    self.cells.level:SetText(tostring(entry.level or "?"))
    self.cells.level:SetTextColor(0.9, 0.9, 0.9)

    -- iLvl
    self.cells.ilvl:SetText(entry.ilvl and tostring(math.floor(entry.ilvl)) or "")
    self.cells.ilvl:SetTextColor(0.6, 0.8, 1)

    -- Gold (gold only, no silver)
    self.cells.gold:SetText(EmpireManager:FormatGoldOnly(entry.gold))
    self.cells.gold:SetTextColor(1, 0.82, 0)

    -- Storage bars (bags + bank)
    local storageCell = self.cells.storage
    if storageCell then
        local function setBar(bar, free, total)
            if total and total > 0 then
                local used = total - (free or 0)
                local pct = used / total
                bar:SetValue(pct)
                if pct >= 0.85 then
                    bar:SetStatusBarColor(1.0, 0.2, 0.2)
                elseif pct >= 0.60 then
                    bar:SetStatusBarColor(1.0, 0.8, 0.0)
                else
                    bar:SetStatusBarColor(0.0, 0.8, 0.0)
                end
                bar:Show()
            else
                bar:SetValue(0)
                bar:SetStatusBarColor(0.3, 0.3, 0.3)
            end
        end
        setBar(storageCell.bagBar, entry.freeBagSlots, entry.totalBagSlots)
        setBar(storageCell.bankBar, entry.freeBankSlots, entry.totalBankSlots)
    end

    -- Profession tags
    self.cells.profTags:SetText(EmpireManager:FormatProfTags(entry.assignments))

    -- Roles
    self.cells.roles:SetText(EmpireManager:FormatRoles(entry.assignments))
end

function EMCharacterRowMixin:UpdateSelected()
    local isSelected = self._guid ~= nil and EmpireManager:GetSelectedGUID() == self._guid
    self.Selected:SetShown(isSelected)
    self.SelectedEdge:SetShown(isSelected)
end

function EMCharacterRowMixin:OnClick(_button)
    if self._guid then
        EmpireManager:OpenSidecar(self._guid)
        EmpireManager:UpdateRowSelection()
    end
end

function EMCharacterRowMixin:GetHitColumn()
    local cursorX = GetCursorPosition()
    local scale = self:GetEffectiveScale()
    local relX = (cursorX / scale) - self:GetLeft()

    local xOffset = 0
    for _, col in ipairs(COLUMNS) do
        if relX >= xOffset and relX < xOffset + col.width then
            return col.key
        end
        xOffset = xOffset + col.width
    end
    return nil
end

function EMCharacterRowMixin:ShowTooltipForColumn(hitCol)
    if hitCol == "profTags" then
        self:ShowProfTooltip()
    elseif hitCol == "roles" then
        self:ShowRoleTooltip()
    elseif hitCol == "storage" then
        self:ShowStorageTooltip()
    else
        EmpireManager:ShowNameTooltip({ frame = self }, self._entry, "ANCHOR_CURSOR_RIGHT")
    end
end

function EMCharacterRowMixin:OnEnter()
    if not self._entry then
        return
    end
    local hitCol = self:GetHitColumn()
    self._hitCol = hitCol
    self:ShowTooltipForColumn(hitCol)
    self._tooltipTimer = 0
    self:SetScript("OnUpdate", EMCharacterRowMixin.OnUpdate)
end

function EMCharacterRowMixin:OnUpdate(elapsed)
    self._tooltipTimer = (self._tooltipTimer or 0) + elapsed
    if self._tooltipTimer < 0.1 then
        return
    end
    self._tooltipTimer = 0
    if not self._entry then
        return
    end
    local hitCol = self:GetHitColumn()
    if hitCol ~= self._hitCol then
        self._hitCol = hitCol
        self:ShowTooltipForColumn(hitCol)
    end
end

function EMCharacterRowMixin:ShowStorageTooltip()
    local entry = self._entry
    GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT")
    EmpireManager:AddTooltipHeader(entry)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Storage", 1, 0.82, 0)

    local function colorForPct(pct)
        if pct >= 0.85 then
            return 1.0, 0.2, 0.2
        elseif pct >= 0.60 then
            return 1.0, 0.8, 0.0
        else
            return 0.0, 0.8, 0.0
        end
    end

    if entry.totalBagSlots and entry.totalBagSlots > 0 then
        local free = entry.freeBagSlots or 0
        local used = entry.totalBagSlots - free
        local pct = used / entry.totalBagSlots
        local r, g, b = colorForPct(pct)
        GameTooltip:AddDoubleLine(
            "Bag",
            string.format("%d / %d  (%d%%)", used, entry.totalBagSlots, math.floor(pct * 100 + 0.5)),
            1,
            1,
            1,
            r,
            g,
            b
        )
    else
        GameTooltip:AddDoubleLine("Bag", "No data", 1, 1, 1, 0.5, 0.5, 0.5)
    end

    if entry.totalBankSlots ~= nil then
        if entry.totalBankSlots == 0 then
            GameTooltip:AddDoubleLine("Banks", "No tabs purchased", 1, 1, 1, 0.7, 0.7, 0.7)
        else
            local free = entry.freeBankSlots or 0
            local used = entry.totalBankSlots - free
            local pct = used / entry.totalBankSlots
            local r, g, b = colorForPct(pct)
            GameTooltip:AddDoubleLine(
                "Banks",
                string.format("%d / %d  (%d%%)", used, entry.totalBankSlots, math.floor(pct * 100 + 0.5)),
                1,
                1,
                1,
                r,
                g,
                b
            )
        end
    else
        GameTooltip:AddDoubleLine("Banks", "No data (open bank)", 1, 1, 1, 0.5, 0.5, 0.5)
    end

    local cap = EmpireManager.db.global.storageCapacity
    local charSection = cap and cap.charbank and self._guid and cap.charbank[self._guid]
    local age = charSection and EmpireManager:FormatStaleAge(charSection._scannedAt)
    if age then
        GameTooltip:AddDoubleLine("Scanned", age, 1, 1, 1, 1, 1, 1)
    end

    GameTooltip:Show()
end

function EMCharacterRowMixin:OnLeave()
    self:SetScript("OnUpdate", nil)
    self._hitCol = nil
    GameTooltip:Hide()
end

function EMCharacterRowMixin:ShowProfTooltip()
    local entry = self._entry
    local profSet = EmpireManager:GetAssignedProfs(entry)
    -- Secondary professions have no role assignment, so a character with only
    -- Fishing/Cooking/Archaeology has an empty profSet but still has prof data
    -- worth showing. Fall back to the name tooltip only when there is nothing.
    local hasCapturedProf = entry.professions and #entry.professions > 0
    if not next(profSet) and not hasCapturedProf then
        EmpireManager:ShowNameTooltip({ frame = self }, entry, "ANCHOR_CURSOR_RIGHT")
        return
    end

    GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT")
    EmpireManager:AddTooltipHeader(entry)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Professions", 1, 0.82, 0)
    -- Keyed by profession key, not the localized name (see ProfInfoFromEntryProf).
    local profByName = {}
    if entry.professions then
        for _, p in ipairs(entry.professions) do
            local pi = EmpireManager:ProfInfoFromEntryProf(p)
            if pi then
                profByName[pi.key] = p
            end
        end
    end
    for _, info in ipairs(EmpireManager.PROF_DISPLAY) do
        if profSet[info.key] then
            local profData = profByName[info.key]
            local label = info.label
            if profData and profData.skill then
                label = string.format("%s (%d)", info.label, profData.skill)
            end
            GameTooltip:AddLine(string.format(ICON16_FMT, info.icon, label), info.r, info.g, info.b)
        end
    end
    -- Secondary professions (Fishing/Cooking/Archaeology) have no role assignment,
    -- so they never appear in profSet. Show any that were captured from skill data.
    for _, info in ipairs(EmpireManager.PROF_DISPLAY) do
        if info.category == "secondary" and not profSet[info.key] then
            local profData = profByName[info.key]
            if profData and profData.skill then
                local label = string.format("%s (%d)", info.label, profData.skill)
                GameTooltip:AddLine(string.format(ICON16_FMT, info.icon, label), info.r, info.g, info.b)
            end
        end
    end
    GameTooltip:Show()
end

function EMCharacterRowMixin:ShowRoleTooltip()
    local entry = self._entry
    if not (entry.assignments and next(entry.assignments)) then
        EmpireManager:ShowNameTooltip({ frame = self }, entry, "ANCHOR_CURSOR_RIGHT")
        return
    end

    GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT")
    EmpireManager:AddTooltipHeader(entry)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Roles", 1, 0.82, 0)
    for _, display in ipairs(EmpireManager.ROLE_DISPLAY) do
        if entry.assignments[display.key] then
            GameTooltip:AddLine(
                string.format(ICON16_FMT, display.icon, display.label or display.key),
                display.r,
                display.g,
                display.b
            )
        end
    end
    GameTooltip:Show()
end

-------------------------------------------------------------------------------
-- Main Frame Mixin (applied to EmpireManagerFrame via XML)
-------------------------------------------------------------------------------

EmpireManagerFrameMixin = {}

function EmpireManagerFrameMixin:OnLoad()
    self:SetTitle("EmpireManager")
    self:SetPortraitToAsset("Interface\\AddOns\\EmpireManager\\textures\\logo-portrait")

    -- Make draggable
    self:RegisterForDrag("LeftButton")
    self:SetScript("OnDragStart", self.StartMoving)
    self:SetScript("OnDragStop", self.StopMovingOrSizing)

    -- Tab system
    Mixin(self, TabSystemOwnerMixin)
    TabSystemOwnerMixin.OnLoad(self)
    self:SetTabSystem(self.TabSystem)

    self.tabIDs = {}
    self.tabIDs.ledger = self:AddNamedTab("Characters", self.CharactersPage)
    self.tabIDs.storage = self:AddNamedTab("Storage", self.StoragePage)
    self.tabIDs.restock = self:AddNamedTab("Restock", self.RestockPage)
    self.tabIDs.roster = self:AddNamedTab("Roster", self.RosterPage)
    self.tabIDs.map = self:AddNamedTab("Map", self.MapPage)
    self.tabIDs.about = self:AddNamedTab("About", self.AboutPage)

    -- Close open rule editors on tab switch (both button clicks and SelectDashboardTab).
    hooksecurefunc(self.TabSystem, "SetTab", function()
        if EmpireManagerStorageDialog then EmpireManagerStorageDialog:Hide() end
        if EmpireManagerRestockDialog then EmpireManagerRestockDialog:Hide() end
    end)

    -- Info button (Appearances-style, per-tab help tips)
    local infoBtn = self.InfoButton
    local TAB_HELP = {
        ledger = {
            "Characters",
            "Your alt roster at a glance.",
            " ",
            "Click a row to open the Character config panel (roles, options, notes).",
            "Click column headers to sort. Click again to reverse.",
            "Hover Profession or Roles columns for details.",
            "Use the search box to filter by name, realm, guild, class, or profession. Separate words with spaces to AND them (e.g. 'eternal steam').",
            "Use the filter dropdown for role and status filters.",
        },
        storage = {
            "Storage Rules",
            "Configure where profession materials and categories are routed.",
            " ",
            "Right-click or double-click a rule to edit it.",
            " ",
            "Rules are checked top-to-bottom: the first matching rule wins, so put higher-priority rules above lower ones.",
            "If that rule's destination is full, the item overflows to the next matching rule.",
            "Use the up/down arrows to reorder.",
            "Ctrl-click an arrow to move 5 positions.",
            "Shift-click to jump to the next rule of the same category.",
        },
        restock = {
            "Restock",
            "Keep a minimum quantity (a floor) of specific items topped up in a bank.",
            " ",
            "Right-click or double-click a rule to edit it.",
            " ",
            "Each rule keeps at least the target amount in its destination. The Warband Bank is a shared pool any alt can fill and craft from.",
            "Fill Level shows current vs target: green is at or above target, red is well below.",
            " ",
            "Restock runs first and wins over Storage Rules: the floor is protected and stays put, and anything above the floor follows your Storage Rules. Character Bags floors are kept in bags and never vendored or routed away.",
            " ",
            "Use the up/down arrows to reorder priority. Higher rules top up first.",
            "Ctrl-click an arrow to move 5 positions.",
            "Shift-click to jump to the next rule of the same profession.",
        },
        roster = {
            Info = {
                "Roster: Info",
                "Aggregated stats across your alt army.",
                " ",
                "Charts grouped by faction, guild, class, profession, race, and realm.",
                "Click any bar to see member characters in a tooltip.",
                " ",
                "Time Played by Class shows /played time per class color.",
            },
            Banks = {
                "Roster: Banks",
                "Bank capacity overview across your roster.",
                " ",
                "Shows tab fill levels for character banks, the Warband Bank, and Guild Banks.",
                "Color codes the bars by how full each tab is.",
            },
            Professions = {
                "Roster: Professions",
                "Characters grouped by profession.",
                " ",
                "Each profession lists members with their skill level.",
                "Click a member to open their config panel.",
                "Shows storage assignments configured for that profession.",
                "The fill bar aggregates the total storage capacity across all destinations assigned to that profession.",
            },
            Categories = {
                "Roster: Categories",
                "Non-profession storage targets (Pets, PvP, Lumber, Housing, Equipment, Recipes, Consumables, Item Enhancements).",
                " ",
                "Each category shows its configured storage destinations.",
                "The fill bar aggregates the total storage capacity across all destinations assigned to that category.",
            },
            Roles = {
                "Roster: Roles",
                "Characters grouped by assigned role.",
                " ",
                "Roles: Artisan, Auctioneer, Gatherer, Banker, Lockpicker, Zookeeper, PvPer.",
                "Assign roles in the Character config panel. Storage destinations require a Banker.",
            },
        },
    }
    local function ResolveTabHelp(tabKey)
        local entry = TAB_HELP[tabKey]
        if not entry then
            return nil
        end
        -- Sub-tab table: roster has Info/Banks/Professions/Categories/Roles
        if tabKey == "roster" and self.RosterPage and self.RosterPage._tabNames then
            local idx = self.RosterPage._selectedTab or 1
            local subName = self.RosterPage._tabNames[idx]
            return subName and entry[subName] or nil
        end
        return entry
    end
    infoBtn:SetScript("OnEnter", function(btn)
        local lines = ResolveTabHelp(EmpireManager.activeTab)
        if not lines then
            return
        end
        GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
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

    -- Characters tab callbacks
    self:SetTabCallback(self.tabIDs.ledger, function()
        EmpireManager.activeTab = "ledger"
        EmpireManager.ledgerScroll = true -- compat flag for Sidecar
        EmpireManager:ApplyFilters()
        infoBtn:Show()
    end)
    self:SetTabDeselectCallback(self.tabIDs.ledger, function()
        EmpireManager.activeTab = nil
        EmpireManager.ledgerScroll = nil
    end)

    -- Native tab callbacks (lazy-init mixin on first select)
    local nativePages = {
        storage = { page = self.StoragePage, mixin = EMStoragePageMixin },
        restock = { page = self.RestockPage, mixin = EMRestockPageMixin },
        about = { page = self.AboutPage, mixin = EMAboutPageMixin },
        map = { page = self.MapPage, mixin = EMMapPageMixin },
        roster = { page = self.RosterPage, mixin = EMRosterPageMixin },
    }
    for tabKey, info in pairs(nativePages) do
        self:SetTabCallback(self.tabIDs[tabKey], function()
            EmpireManager.activeTab = tabKey
            local page = info.page
            if not page._nativeInit then
                Mixin(page, info.mixin)
                page:OnLoad()
                page._nativeInit = true
            end
            page:OnShow()
            infoBtn:SetShown(TAB_HELP[tabKey] ~= nil)
        end)
        self:SetTabDeselectCallback(self.tabIDs[tabKey], function()
            EmpireManager.activeTab = nil
        end)
    end

    -- Initialize ScrollBox for characters grid
    self:InitCharactersGrid()

    -- Initialize filter bar
    self:InitFilterBar()

    -- Initialize column headers
    self:InitColumnHeaders()

    -- Store reference for compat
    EmpireManager.dashboardFrame = self
    self.frame = self -- shim for Sidecar/Triage that use .frame

    -- Message bus: refresh grid when registry data changes
    EmpireManager:RegisterMessage("EM_DASHBOARD_REFRESH", function()
        if self:IsShown() then
            EmpireManager:ApplyFilters()
        end
    end)
end

function EmpireManagerFrameMixin:OnShow()
    if EmpireManager.db then
        -- ESC to close (db not available during OnLoad, so sync here every show).
        -- Register the real XML frame name (untainted), not a Lua _G alias.
        local idx = tIndexOf(UISpecialFrames, "EmpireManagerFrame")
        if EmpireManager.db.global.options.escToClose then
            if not idx then
                tinsert(UISpecialFrames, "EmpireManagerFrame")
            end
        elseif idx then
            tremove(UISpecialFrames, idx)
        end
    end
end

function EmpireManagerFrameMixin:OnHide()
    if EmpireManagerSidecar and EmpireManagerSidecar:IsShown() then
        EmpireManager:CloseSidecar()
    end
    EmpireManager._hasScrolledToPlayer = nil
end

function EmpireManagerFrameMixin:InitCharactersGrid()
    local page = self.CharactersPage
    page.ScrollBox = page.Inset.ScrollBox
    page.ScrollBar = page.Inset.ScrollBar

    local view = CreateScrollBoxListLinearView()
    view:SetElementInitializer("EMCharacterRowTemplate", function(frame, elementData)
        frame:Populate(elementData)
    end)
    view:SetElementExtent(20)
    ScrollUtil.InitScrollBoxListWithScrollBar(page.ScrollBox, page.ScrollBar, view)
end

function EmpireManagerFrameMixin:InitFilterBar()
    local bar = self.CharactersPage.FilterBar

    -- Search box
    bar.SearchBox:HookScript("OnTextChanged", function(editBox)
        local text = editBox:GetText() or ""
        if text == EmpireManager.filterState.searchText then
            return
        end
        EmpireManager.filterState.searchText = text
        EmpireManager:ApplyFilters()
        EmpireManager:UpdateFilterClearButton()
    end)

    -- Filter dropdown (AH-style WowStyle1FilterDropdown)
    bar.FilterButton:SetupMenu(function(_dropdown, rootDescription)
        rootDescription:SetTag("EM_FILTER_MENU")

        local function AddFilter(desc, label, key)
            desc:CreateCheckbox(label, function()
                return EmpireManager.filterState.activeSmartFilters[key] or false
            end, function(_data)
                local af = EmpireManager.filterState.activeSmartFilters
                af[key] = (not af[key]) or nil
                -- Defer to avoid taint: menu callback runs in insecure context,
                -- immediate ScrollBox refresh taints Blizzard's internal scroll state
                C_Timer.After(0, function()
                    EmpireManager:ApplyFilters()
                    EmpireManager:UpdateFilterClearButton()
                end)
            end)
        end

        for _, display in ipairs(EmpireManager.ROLE_DISPLAY) do
            AddFilter(rootDescription, display.label or display.key, display.key)
        end

        -- Rule ownership: properties of the character, not roles, so they sit
        -- below a divider. Warband/guild rules name no character and match none.
        rootDescription:CreateDivider()
        AddFilter(rootDescription, "Has Storage Rules", "hasStorageRules")
        AddFilter(rootDescription, "Has Restock Rules", "hasRestockRules")
    end)

    -- Clear X button (AH-style red X on filter dropdown)
    bar.FilterButton.ClearFiltersButton:SetScript("OnClick", function()
        EmpireManager.filterState.searchText = ""
        bar.SearchBox:SetText("")
        EmpireManager.filterState.activeSmartFilters = {}
        EmpireManager:ApplyFilters()
        EmpireManager:UpdateFilterClearButton()
    end)
    bar.FilterButton.ClearFiltersButton:Hide() -- hidden until filters are active

    -- Triage button (icon-only, texture set in XML)
    local triageBtn = self.CharactersPage.TriageButton
    EmpireManager:StyleIconButton(triageBtn, 0.5)
    triageBtn:SetScript("OnClick", function()
        EmpireManager:ToggleTriageOverlay()
    end)
    triageBtn:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Triage", 1, 0.82, 0)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Open cleanup assistant.", 1, 1, 1)
        GameTooltip:Show()
    end)
    triageBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Import/Export button (icon-only, texture set in XML)
    local ieBtn = self.CharactersPage.IEButton
    EmpireManager:StyleIconButton(ieBtn, 0.5)
    ieBtn:SetScript("OnClick", function()
        EmpireManager:ToggleIOWindow()
    end)
    ieBtn:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Import/Export", 1, 0.82, 0)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Open the Import/Export window.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    ieBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

function EmpireManagerFrameMixin:InitColumnHeaders()
    local container = self.CharactersPage.Inset.HeaderContainer
    EmpireManager.headerButtons = {}

    local xOffset = 0
    for _, col in ipairs(COLUMNS) do
        local btn = CreateFrame("Button", nil, container, "ColumnDisplayButtonShortTemplate")
        btn:SetSize(col.width, 19)
        btn:SetPoint("LEFT", container, "LEFT", xOffset, 0)
        btn:SetText(col.label)
        btn:SetNormalFontObject(GameFontHighlightSmall)
        btn:GetFontString():SetJustifyH(col.justify)

        -- Store ref to text for color updates
        btn._text = btn:GetFontString()
        btn._label = col.label

        if col.sortKey then
            local arrow = btn:CreateTexture(nil, "OVERLAY")
            arrow:SetAtlas("auctionhouse-ui-sortarrow", true)
            arrow:SetPoint("LEFT", btn._text, "RIGHT", 1, 0)
            arrow:Hide()
            btn._arrow = arrow

            btn:SetScript("OnClick", function()
                if EmpireManager.sortColumn == col.sortKey then
                    EmpireManager.sortAscending = not EmpireManager.sortAscending
                else
                    EmpireManager.sortColumn = col.sortKey
                    EmpireManager.sortAscending = true
                end
                EmpireManager:UpdateHeaderArrows()
                EmpireManager:ApplyFilters()
            end)

            EmpireManager.headerButtons[#EmpireManager.headerButtons + 1] = {
                btn = btn,
                text = col.label,
                sortKey = col.sortKey,
            }
        else
            btn:SetEnabled(false)
        end

        xOffset = xOffset + col.width
    end

    EmpireManager:UpdateHeaderArrows()
end

-------------------------------------------------------------------------------
-- Dashboard: Toggle / Select Tab
-------------------------------------------------------------------------------

function EmpireManager:ToggleDashboard()
    local frame = EmpireManagerFrame
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
        self:SelectDashboardTab("ledger")
    end
end

function EmpireManager:SelectDashboardTab(tabName)
    local frame = EmpireManagerFrame
    if frame and frame.tabIDs and frame.tabIDs[tabName] then
        frame:SetTab(frame.tabIDs[tabName])
    end
end

-------------------------------------------------------------------------------
-- Filter Clear Button Visibility (AH-style red X)
-------------------------------------------------------------------------------

function EmpireManager:UpdateFilterClearButton()
    local frame = EmpireManagerFrame
    if not frame then
        return
    end
    local clearBtn = frame.CharactersPage.FilterBar.FilterButton.ClearFiltersButton
    local hasFilters = self.filterState.searchText ~= "" or next(self.filterState.activeSmartFilters)
    clearBtn:SetShown(hasFilters)
end

-------------------------------------------------------------------------------
-- Header Arrow Updates
-------------------------------------------------------------------------------

function EmpireManager:UpdateHeaderArrows()
    if not self.headerButtons then
        return
    end
    for _, h in ipairs(self.headerButtons) do
        if self.sortColumn == h.sortKey then
            h.btn._arrow:Show()
            if self.sortAscending then
                h.btn._arrow:SetTexCoord(0, 1, 1, 0) -- flipped = ascending
            else
                h.btn._arrow:SetTexCoord(0, 1, 0, 1) -- normal = descending
            end
            h.btn:SetNormalFontObject(GameFontHighlight)
        else
            h.btn._arrow:Hide()
            h.btn:SetNormalFontObject(GameFontHighlightSmall)
        end
    end
end

-------------------------------------------------------------------------------
-- Filtering & Grid Rendering (virtualized via DataProvider)
-------------------------------------------------------------------------------

function EmpireManager:ApplyFilters()
    local filtered = self:FilterRegistry(self.filterState)
    self:RebuildGrid(filtered)
end

-- Lightweight refresh: re-populate visible rows without replacing the DataProvider.
-- Use this when entry data has changed in-place (e.g. role assignments) but the
-- filtered set / sort order hasn't changed.
function EmpireManager:RefreshVisibleRows()
    local frame = EmpireManagerFrame
    if not frame then
        return
    end
    local scrollBox = frame.CharactersPage.ScrollBox
    if not scrollBox or not scrollBox:GetDataProvider() then
        return
    end
    scrollBox:ForEachFrame(function(rowFrame)
        local elementData = rowFrame:GetElementData()
        if elementData and rowFrame.Populate then
            rowFrame:Populate(elementData)
        end
    end)
end

-- Which row the grid highlights: the Sidecar's character, or none when it's closed.
-- No fallback to the logged-in character: re-clicking a row closes its Sidecar, and a
-- highlight jumping to another row then read as navigating away.
function EmpireManager:GetSelectedGUID()
    return self.sidecarGUID
end

-- Repaint only the selection highlight on visible rows. Cheaper than
-- RefreshVisibleRows: no cell text/atlas work, just two texture toggles per row.
function EmpireManager:UpdateRowSelection()
    local frame = EmpireManagerFrame
    if not frame then
        return
    end
    local scrollBox = frame.CharactersPage.ScrollBox
    if not scrollBox or not scrollBox:GetDataProvider() then
        return
    end
    scrollBox:ForEachFrame(function(rowFrame)
        if rowFrame.UpdateSelected then
            rowFrame:UpdateSelected()
        end
    end)
end

function EmpireManager:RebuildGrid(filteredData)
    local frame = EmpireManagerFrame
    if not frame then
        return
    end
    local scrollBox = frame.CharactersPage.ScrollBox
    if not scrollBox then
        return
    end

    -- Build sorted array
    local sorted = {}
    for guid, entry in pairs(filteredData) do
        sorted[#sorted + 1] = { guid = guid, entry = entry }
    end

    local col = self.sortColumn or "name"
    local asc = self.sortAscending
    local keyFn = self.SORT_KEYS[col] or self.SORT_KEYS.name

    table.sort(sorted, function(a, b)
        local aKey = keyFn(a.entry)
        local bKey = keyFn(b.entry)
        if aKey == bKey then
            return (a.entry.name or ""):lower() < (b.entry.name or ""):lower()
        end
        if asc then
            return aKey < bKey
        else
            return aKey > bKey
        end
    end)

    -- Add index for zebra striping + find player
    local playerIndex = nil
    for i, data in ipairs(sorted) do
        data.index = i
        if data.guid == self.playerGUID then
            playerIndex = i
        end
    end

    -- Row count, right of the filter dropdown. Shown always, so it doubles as a
    -- roster total when nothing is filtered.
    local countText = frame.CharactersPage.FilterBar.CountText
    if countText then
        local n = #sorted
        countText:SetText(n == 1 and "1 character" or (n .. " characters"))
    end

    -- Preserve scroll position across rebuilds
    local savedOffset = scrollBox:GetScrollPercentage()

    -- Create DataProvider and set on ScrollBox
    local dataProvider = CreateDataProvider(sorted)
    scrollBox:SetDataProvider(dataProvider)

    -- Scroll to current player on first open, otherwise restore position
    if playerIndex and not self._hasScrolledToPlayer then
        self._hasScrolledToPlayer = true
        -- Defer to next frame so ScrollBox has laid out
        C_Timer.After(0, function()
            if not scrollBox:GetDataProvider() then
                return
            end
            local elementData = sorted[playerIndex]
            if elementData then
                scrollBox:ScrollToElementData(elementData, ScrollBoxConstants.AlignCenter)
            end
        end)
    elseif savedOffset and savedOffset >= 0 then
        C_Timer.After(0, function()
            if scrollBox:GetDataProvider() then
                scrollBox:SetScrollPercentage(savedOffset)
            end
        end)
    end
end
