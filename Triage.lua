-- ----------------------------------------------------------------------------
--                                   EmpireManager
--                              https://wow.cyberpunk.gr
--                (c) by George Litos (l0neshad0w),  All Rights Reserved
--                   For detailed license information check LICENSE.md
-- ----------------------------------------------------------------------------

local EmpireManager = LibStub("AceAddon-3.0"):GetAddon("EmpireManager")

EmpireManager._debugShowKeep = false -- toggled by /em triage debug

-- Invalidate the cached classification on option change. RunTriageAsync
-- short-circuits to cached results when bags haven't changed, but option
-- changes mean the existing classification is stale and must be redone -
-- whether the window is open now or opens later.
-- When the triage window IS open, also schedule a debounced live rescan
-- (~0.5s) so dragging a slider repaints the view without manual rescan.
function EmpireManager:OnTriageOptionChanged()
    -- Always invalidate, even when the window is closed.
    self._bagsDirty = true
    self.triageResults = nil
    self.bankTriageResults = nil

    -- Live refresh only when the window is open.
    if not self.triageFrame or not self.triageFrame:IsShown() then
        return
    end
    if self._triageOptionRescanPending then
        return
    end
    self._triageOptionRescanPending = true
    C_Timer.After(0.5, function()
        self._triageOptionRescanPending = nil
        if not self.triageFrame or not self.triageFrame:IsShown() then
            return
        end
        if self._triageActiveTab == "bags" then
            self:RefreshTriageDisplay(true)
        else
            self:RefreshBankTriageDisplay(true)
        end
    end)
end

-------------------------------------------------------------------------------
-- Frame Pool - reuse hidden frames instead of creating new ones each rebuild.
-- WoW frames cannot be garbage-collected; without pooling, every triage tab
-- switch or refresh leaks frame objects and drives memory up over time.
-------------------------------------------------------------------------------

local rowPool = {} -- pool of { frame, hl, nameFs, actionFs }
local sepPool = {} -- pool of separator Texture objects
local hdrPool = {} -- pool of header FontString objects
local fsPool = {} -- pool of generic FontString objects
local allRowFrames = {} -- every row Button, for drag-time mouse suppression

local function AcquireRow(content)
    local entry = table.remove(rowPool)
    if entry then
        entry.frame:SetParent(content)
        entry.frame:ClearAllPoints()
        entry.frame:Show()
        return entry
    end
    local row = CreateFrame("Button", nil, content)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    -- Per-half highlights so the user can see which side a right-click will hit.
    -- Layered as ARTWORK and toggled in the row's OnEnter/OnUpdate; HIGHLIGHT layer
    -- is used by the standard mouseover overlay below.
    -- Full-row red wash for capacity-blocked rows (assigned tabs full). Sits below
    -- the per-half hover highlights; shown only when result.blocked is set.
    local blockedBg = row:CreateTexture(nil, "BACKGROUND", nil, -1)
    blockedBg:SetAllPoints()
    blockedBg:SetColorTexture(0.7, 0.1, 0.1, 0.2)
    blockedBg:Hide()
    local hlLeft = row:CreateTexture(nil, "BACKGROUND")
    hlLeft:SetPoint("TOPLEFT")
    hlLeft:SetPoint("BOTTOM")
    hlLeft:SetColorTexture(1, 1, 1, 0.03)
    hlLeft:Hide()
    local hlRight = row:CreateTexture(nil, "BACKGROUND")
    hlRight:SetPoint("TOPRIGHT")
    hlRight:SetPoint("BOTTOM")
    hlRight:SetColorTexture(1, 1, 1, 0.03)
    hlRight:Hide()
    -- Vertical mid-divider, only visible on hover.
    local divider = row:CreateTexture(nil, "OVERLAY")
    divider:SetSize(1, 12)
    divider:SetColorTexture(1, 1, 1, 0.15)
    divider:Hide()
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.04)
    allRowFrames[#allRowFrames + 1] = row
    local nameFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    nameFs:SetPoint("LEFT", 2, 0)
    nameFs:SetJustifyH("LEFT")
    nameFs:SetWordWrap(false)
    nameFs:SetNonSpaceWrap(false)
    nameFs:SetMaxLines(1)
    local actionFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    actionFs:SetPoint("RIGHT", -2, 0)
    actionFs:SetJustifyH("LEFT")
    actionFs:SetWordWrap(false)
    actionFs:SetNonSpaceWrap(false)
    actionFs:SetMaxLines(1)
    return {
        frame = row,
        hl = hl,
        blockedBg = blockedBg,
        hlLeft = hlLeft,
        hlRight = hlRight,
        divider = divider,
        nameFs = nameFs,
        actionFs = actionFs,
    }
end

local function ReleaseRow(entry)
    entry.frame:Hide()
    entry.frame:SetScript("OnClick", nil)
    entry.frame:SetScript("OnEnter", nil)
    entry.frame:SetScript("OnLeave", nil)
    entry.frame:SetScript("OnUpdate", nil)
    if entry.blockedBg then
        entry.blockedBg:Hide()
    end
    if entry.hlLeft then
        entry.hlLeft:Hide()
    end
    if entry.hlRight then
        entry.hlRight:Hide()
    end
    if entry.divider then
        entry.divider:Hide()
    end
    rowPool[#rowPool + 1] = entry
end

local function AcquireSep(content)
    local tex = table.remove(sepPool)
    if tex then
        tex:SetParent(content)
        tex:ClearAllPoints()
        tex:Show()
        return tex
    end
    return content:CreateTexture(nil, "ARTWORK")
end

local function ReleaseSep(tex)
    tex:Hide()
    sepPool[#sepPool + 1] = tex
end

local function AcquireHeader(content)
    local btn = table.remove(hdrPool)
    if btn then
        btn:SetParent(content)
        btn:ClearAllPoints()
        btn:SetScript("OnClick", nil)
        btn:SetScript("OnEnter", nil)
        btn:SetScript("OnLeave", nil)
        btn:Show()
        return btn
    end
    local b = CreateFrame("Button", nil, content)
    b:SetHeight(18)
    b:RegisterForClicks("RightButtonUp")
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:SetAllPoints(b)
    fs:SetJustifyH("CENTER")
    fs:SetJustifyV("MIDDLE")
    b.text = fs
    b.SetText = function(self, s)
        self.text:SetText(s)
    end
    return b
end

local function ReleaseHeader(btn)
    btn:SetScript("OnClick", nil)
    btn:SetScript("OnEnter", nil)
    btn:SetScript("OnLeave", nil)
    btn:Hide()
    hdrPool[#hdrPool + 1] = btn
end

local function AcquireFs(content)
    local fs = table.remove(fsPool)
    if fs then
        fs:SetParent(content)
        fs:ClearAllPoints()
        fs:Show()
        return fs
    end
    local f = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f:SetJustifyH("LEFT")
    return f
end

local function ReleaseFs(fs)
    fs:Hide()
    fsPool[#fsPool + 1] = fs
end

-------------------------------------------------------------------------------
-- Summary-bar jump chips: clickable counts that scroll to section headings.
-------------------------------------------------------------------------------
local CHIP_GAP = 14
local CHIP_PAD = 8

local function AcquireChip(bar)
    local pool = bar._chipPool
    if not pool then
        pool = {}
        bar._chipPool = pool
    end
    local chip = table.remove(pool)
    if chip then
        chip:SetScript("OnClick", nil)
        chip:Show()
        return chip
    end
    local b = CreateFrame("Button", nil, bar)
    b:SetHeight(20)
    b:RegisterForClicks("LeftButtonUp")
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:SetPoint("LEFT", b, "LEFT", CHIP_PAD, 0)
    fs:SetPoint("RIGHT", b, "RIGHT", -CHIP_PAD, 0)
    fs:SetJustifyH("CENTER")
    b.text = fs
    return b
end

local function LayoutSummaryChips(bar, chips)
    if bar._activeChips then
        for _, c in ipairs(bar._activeChips) do
            c:SetScript("OnClick", nil)
            c:Hide()
            bar._chipPool[#bar._chipPool + 1] = c
        end
        wipe(bar._activeChips)
    else
        bar._activeChips = {}
    end
    if #chips == 0 then
        return
    end

    local widths = {}
    local totalW = 0
    for i, spec in ipairs(chips) do
        local chip = AcquireChip(bar)
        chip.text:SetText(spec.text)
        chip.text:SetTextColor(spec.r, spec.g, spec.b)
        chip:SetScript("OnClick", spec.onClick)
        local w = chip.text:GetStringWidth() + CHIP_PAD * 2
        chip:SetWidth(w)
        widths[i] = w
        totalW = totalW + w
        bar._activeChips[i] = chip
    end
    if #chips > 1 then
        totalW = totalW + CHIP_GAP * (#chips - 1)
    end

    local barW = bar:GetWidth()
    if not barW or barW < 10 then
        barW = totalW
    end
    local x = math.floor((barW - totalW) / 2 + 0.5)
    for i, chip in ipairs(bar._activeChips) do
        chip:ClearAllPoints()
        chip:SetPoint("LEFT", bar, "LEFT", x, 0)
        x = x + widths[i] + CHIP_GAP
    end
end

-------------------------------------------------------------------------------
-- Per-operation maxStack cache (itemID → maxStackSize). Cleared at the start
-- of each bulk op to avoid stale values; reuses across slot lookups within
-- a single deposit/restack/reorganize pass.
-------------------------------------------------------------------------------
local maxStackCache = {}
local function GetMaxStack(itemID)
    if not itemID then
        return 0
    end
    local cached = maxStackCache[itemID]
    if cached ~= nil then
        return cached
    end
    local ms = select(8, C_Item.GetItemInfo(itemID)) or 0
    maxStackCache[itemID] = ms
    return ms
end
local function ResetMaxStackCache()
    maxStackCache = {}
end

-------------------------------------------------------------------------------
-- Bag slot counters (bags 0-5, includes reagent bag)
-------------------------------------------------------------------------------
local function CountFreeBagSlots()
    local free = 0
    for bag = 0, 5 do
        free = free + (C_Container.GetContainerNumFreeSlots(bag) or 0)
    end
    return free
end

local function CountOccupiedBagSlots()
    local count = 0
    for bag = 0, 5 do
        local numSlots = C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, numSlots do
            if C_Container.GetContainerItemInfo(bag, slot) then
                count = count + 1
            end
        end
    end
    return count
end

-- Total quantity held in bags across a set of itemIDs. Slot counting cannot see a
-- partial move (a restock-floor straddle leaves the slot occupied with the floor),
-- so progress for those is measured in items, not slots.
local function CountBagQuantities(itemIDs)
    local total = 0
    for bag = 0, 5 do
        local numSlots = C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, numSlots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID and itemIDs[info.itemID] then
                total = total + (info.stackCount or 1)
            end
        end
    end
    return total
end

-------------------------------------------------------------------------------
-- Bags-full warning: call after any bulk action completes
-------------------------------------------------------------------------------
local function CheckBagsFull()
    if CountFreeBagSlots() == 0 then
        EmpireManager:Print("|cffff6600[Warning]|r Bags are full!")
    end
end

-- Find a free bag slot to drop an item into.
-- If itemID is a crafting reagent, tries the reagent bag (5) first.
-- Otherwise searches bags 0-4. Returns bag, slot or nil.
local function FindFreeBagSlotForItem(itemID)
    -- Try reagent bag (5) first if the item is a crafting reagent
    if itemID then
        local isCraftingReagent = select(17, C_Item.GetItemInfo(itemID))
        if isCraftingReagent then
            local reagentSlots = C_Container.GetContainerNumSlots(5) or 0
            for slot = 1, reagentSlots do
                if not C_Container.GetContainerItemInfo(5, slot) then
                    return 5, slot
                end
            end
        end
    end
    -- Fall back to regular bags
    for bag = 0, 4 do
        local numSlots = C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, numSlots do
            if not C_Container.GetContainerItemInfo(bag, slot) then
                return bag, slot
            end
        end
    end
    return nil, nil
end

-------------------------------------------------------------------------------
-- Message Bus Handlers (decoupled from Core.lua)
-------------------------------------------------------------------------------

EmpireManager:RegisterMessage("EM_TRIAGE_REFRESH", function()
    if EmpireManager._triageBulkOperating then
        return
    end
    if EmpireManager.triageFrame and EmpireManager.triageFrame:IsShown() then
        local at = EmpireManager._triageActiveTab
        if at == "bank" or at == "warband" or at == "guildbank" then
            -- EM_TRIAGE_REFRESH fires from BAG_UPDATE_DELAYED which only means
            -- bag contents changed, not bank contents. Skip the expensive bank
            -- rescan; the bank tab will refresh when the user switches to it or
            -- via EM_BANK_OPENED / EM_GUILDBANK_OPENED.
            return
        else
            -- Silent rescan: run async scan in background without tearing down
            -- the current UI. Only rebuild when results are ready and changed.
            EmpireManager:RefreshTriageDisplay(false, true)
        end
    end
end)

EmpireManager:RegisterMessage("EM_BANK_OPENED", function(_, _stashCount)
    local triageOpen = EmpireManager.triageFrame and EmpireManager.triageFrame:IsShown()
    if EmpireManager.db.global.options.popupOnBank and not triageOpen then
        -- Always open when popupOnBank is set. Bank takeouts aren't counted
        -- in stashCount (bag-only), so gating on stashCount>0 would miss the
        -- common "bags empty, bank full of takeouts" case.
        C_Timer.After(0.3, function()
            if not EmpireManager.bankIsOpen then
                return
            end
            EmpireManager:ToggleTriageOverlay()
        end)
    elseif triageOpen then
        EmpireManager:UpdateTriageTabButtons()
        EmpireManager:UpdateDepositBtnState()
        -- Delay bank tab refresh to let container data settle
        C_Timer.After(0.3, function()
            if not EmpireManager.triageFrame or not EmpireManager.triageFrame:IsShown() then
                return
            end
            if EmpireManager._triageActiveTab == "bags" then
                EmpireManager:RefreshTriageDisplay()
            else
                EmpireManager.bankTriageResults = nil
                EmpireManager:RefreshBankTriageDisplay(true)
            end
            EmpireManager:UpdateDepositBtnState()
        end)
    end
end)

EmpireManager:RegisterMessage("EM_GUILDBANK_OPENED", function(_, depositCount, takeoutCount)
    depositCount = depositCount or 0
    takeoutCount = takeoutCount or 0
    local triageOpen = EmpireManager.triageFrame and EmpireManager.triageFrame:IsShown()
    local popupEnabled = EmpireManager.db.global.options.popupOnGuildBank
    if popupEnabled and not triageOpen then
        if depositCount > 0 or takeoutCount > 0 then
            EmpireManager._guildBankAutoTab = depositCount > 0 and "bags" or "guildbank"
            C_Timer.After(0.3, function()
                if not EmpireManager.guildBankIsOpen then
                    return
                end
                EmpireManager:ToggleTriageOverlay()
            end)
        end
    elseif triageOpen then
        EmpireManager:UpdateTriageTabButtons()
        -- Always invalidate bank cache: user may have clicked a bank tab during
        -- the snapshot window and captured stale results.
        EmpireManager.bankTriageResults = nil
        EmpireManager._triageBankBuilt = false
        EmpireManager._bankTriageFingerprint = nil
        if EmpireManager._triageActiveTab == "bags" then
            EmpireManager:RefreshTriageDisplay()
        else
            EmpireManager:RefreshBankTriageDisplay(true)
        end
        EmpireManager:UpdateDepositBtnState()
    end
end)

EmpireManager:RegisterMessage("EM_BANK_CLOSED", function()
    -- Abort any running bulk operation (take out, reorganize, deposit)
    if EmpireManager._triageBulkOperating then
        EmpireManager:AbortBulkOperation()
    end
    -- Update bag tab deposit button
    if EmpireManager.triageDepositBtn then
        EmpireManager.triageDepositBtn:SetText("Deposit All Stash")
        EmpireManager.triageDepositBtn._disabledReason = "Open a bank to deposit"
        EmpireManager.triageDepositBtn:SetEnabled(false)
    end
    -- Invalidate cached bank scan so next reopen triggers a fresh build.
    EmpireManager.bankTriageResults = nil
    EmpireManager._triageBankBuilt = false
    EmpireManager._bankTriageFingerprint = nil
    -- If on any bank tab, switch back to bags
    local at = EmpireManager._triageActiveTab
    if (at == "bank" or at == "warband" or at == "guildbank") and EmpireManager.triageFrame then
        EmpireManager:SwitchTriageTab("bags")
    end
    EmpireManager:UpdateTriageTabButtons()
    EmpireManager:CloseTriageOnLeave()
end)

EmpireManager:RegisterMessage("EM_MERCHANT_SHOW", function()
    EmpireManager:OnMerchantShow()
end)

EmpireManager:RegisterMessage("EM_MERCHANT_CLOSED", function()
    -- Abort any running bulk vendor operation (closing the merchant cancels everything)
    if EmpireManager._triageBulkOperating then
        EmpireManager:AbortBulkOperation()
    end
    -- Close the vendor confirmation dialog if open (merchant is gone, can't sell)
    if EmpireManager.vendorConfirmFrame then
        EmpireManager.vendorConfirmFrame:Hide()
        EmpireManager.vendorConfirmFrame = nil
    end
    if EmpireManager.triageFrame and EmpireManager.triageFrame:IsShown() then
        EmpireManager:UpdateVendorBtnState()
    end
    EmpireManager:CloseTriageOnLeave()
end)

EmpireManager:RegisterMessage("EM_MAIL_SHOW", function()
    EmpireManager:OnMailShow()
end)

EmpireManager:RegisterMessage("EM_MAIL_CLOSED", function()
    -- Abort any running bulk mail operation (closing the mailbox cancels everything)
    if EmpireManager._triageBulkOperating then
        EmpireManager:AbortBulkOperation()
    end
    -- Close the per-character mail confirmation dialog if open
    if EmpireManager.mailConfirmFrame then
        EmpireManager.mailConfirmFrame:Hide()
        EmpireManager.mailConfirmFrame = nil
    end
    EmpireManager._mailingSending = nil
    if EmpireManager.triageFrame and EmpireManager.triageFrame:IsShown() then
        EmpireManager:UpdateMailBtnState()
    end
    EmpireManager:CloseTriageOnLeave()
end)

EmpireManager:RegisterMessage("EM_MAIL_BTN_UPDATE", function()
    if EmpireManager.triageFrame and EmpireManager.triageFrame:IsShown() then
        EmpireManager:UpdateMailBtnState()
    end
end)

-- Local aliases for constants defined in TriageLogic.lua
local CAT_KEEP = EmpireManager.CAT_KEEP
local CAT_ROUTE = EmpireManager.CAT_ROUTE
local CAT_STASH = EmpireManager.CAT_STASH
local CAT_VENDOR = EmpireManager.CAT_VENDOR
local CAT_TAKEOUT = EmpireManager.CAT_TAKEOUT
local CATEGORY_INFO = EmpireManager.CATEGORY_INFO
local MoveContexts = EmpireManager.MoveContexts

-- All logic (MoveContexts, classification, routing, scanning, etc.) is in TriageLogic.lua

-------------------------------------------------------------------------------
-- Keep List / Vendor White List add helpers
-- Items must never appear on both lists at once: Keep wins in classification,
-- so an item silently on Vendor White List that the user *meant* to keep would
-- be vendored. We block the conflict at add-time by asking the user to choose.
-------------------------------------------------------------------------------

local function _PerformKeeplistAdd(itemID, itemName)
    if not EmpireManager.db.global.keepList then
        EmpireManager.db.global.keepList = {}
    end
    EmpireManager.db.global.keepList[itemID] = itemName
    EmpireManager:Print(string.format("Added %s to Keep List.", itemName))
    EmpireManager._bagsDirty = true -- force reclassification on next scan
    EmpireManager.bankTriageResults = nil
    -- Hide all rows of the newly keep-listed item until the next reclassify scan
    -- moves them to KEEP. Skip table is per-row, so add a row key per matching row.
    if EmpireManager._triageActiveTab == "bags" then
        EmpireManager.triageSkippedItems = EmpireManager.triageSkippedItems or {}
        for _, r in ipairs(EmpireManager.triageResults or {}) do
            if r.item and r.item.itemID == itemID then
                EmpireManager.triageSkippedItems[(r.item.bag or 0) .. ":" .. (r.item.slot or 0)] = true
            end
        end
        EmpireManager._triageFingerprint = nil
        EmpireManager:RefreshTriageDisplay()
    else
        EmpireManager.bankTriageSkippedItems = EmpireManager.bankTriageSkippedItems or {}
        for _, r in ipairs(EmpireManager.bankTriageResults or {}) do
            if r.item and r.item.itemID == itemID then
                local rowKey = (r.item.bankType or "") .. ":" .. (r.item.bag or 0) .. ":" .. (r.item.slot or 0)
                EmpireManager.bankTriageSkippedItems[rowKey] = true
            end
        end
        EmpireManager._bankTriageFingerprint = nil
        EmpireManager:RefreshBankTriageDisplay(true)
    end
    if EmpireManager.keeplistFrame and EmpireManager.keeplistFrame:IsShown() then
        EmpireManager:RefreshKeeplistDisplay()
    end
    if EmpireManager.vendorlistFrame and EmpireManager.vendorlistFrame:IsShown() then
        EmpireManager:RefreshVendorlistDisplay()
    end
end

local function _PerformVendorlistAdd(itemID, itemName)
    if not EmpireManager.db.global.vendorWhitelist then
        EmpireManager.db.global.vendorWhitelist = {}
    end
    EmpireManager.db.global.vendorWhitelist[itemID] = itemName
    EmpireManager:Print(string.format("Whitelisted %s - will always be vendored.", itemName))
    EmpireManager._bagsDirty = true -- force reclassification on next scan
    EmpireManager.bankTriageResults = nil
    if EmpireManager._triageActiveTab == "bags" then
        EmpireManager._triageFingerprint = nil
        EmpireManager:RefreshTriageDisplay(true)
    else
        EmpireManager._bankTriageFingerprint = nil
        EmpireManager:RefreshBankTriageDisplay(true)
    end
    if EmpireManager.vendorlistFrame and EmpireManager.vendorlistFrame:IsShown() then
        EmpireManager:RefreshVendorlistDisplay()
    end
    if EmpireManager.keeplistFrame and EmpireManager.keeplistFrame:IsShown() then
        EmpireManager:RefreshKeeplistDisplay()
    end
end

-- Public: prompt the user to add an item to the Keep List. If the item is
-- already on the Vendor White List, the dialog asks the user to move it instead;
-- accepting removes it from the Vendor List. Keep List wins in classification
-- (TriageLogic.lua: keepList check before vendorWhitelist), but we still block
-- the conflict at add-time so the lists never disagree about user intent.
function EmpireManager:AddToKeepList(itemID, itemName)
    if not itemID then
        return
    end
    itemName = itemName or ("Item " .. itemID)
    if self.db.global.keepList and self.db.global.keepList[itemID] then
        self:ChatMsg(string.format("%s is already on the Keep List.", itemName), true)
        return
    end
    local dialogKey = (self.db.global.vendorWhitelist and self.db.global.vendorWhitelist[itemID])
            and "EM_KEEPLIST_MOVE_FROM_VENDOR"
        or "EM_KEEPLIST_ADD"
    local dialog = StaticPopup_Show(dialogKey, itemName)
    if dialog then
        dialog.data = { itemID = itemID, itemName = itemName }
    end
end

-- Public: prompt the user to add an item to the Vendor White List. If the item
-- is already on the Keep List, the dialog asks the user to move it instead.
function EmpireManager:AddToVendorList(itemID, itemName)
    if not itemID then
        return
    end
    itemName = itemName or ("Item " .. itemID)
    if self.db.global.vendorWhitelist and self.db.global.vendorWhitelist[itemID] then
        self:ChatMsg(string.format("%s is already on the Vendor List.", itemName), true)
        return
    end
    local dialogKey = (self.db.global.keepList and self.db.global.keepList[itemID]) and "EM_VENDORLIST_MOVE_FROM_KEEP"
        or "EM_VENDORLIST_ADD"
    local dialog = StaticPopup_Show(dialogKey, itemName)
    if dialog then
        dialog.data = { itemID = itemID, itemName = itemName }
    end
end

-------------------------------------------------------------------------------
-- StaticPopup: "Add to Keep List?"
-------------------------------------------------------------------------------

StaticPopupDialogs["EM_KEEPLIST_ADD"] = {
    text = "Add %s to Keep List?",
    button1 = "Yes",
    button2 = "Cancel",
    OnAccept = function(self)
        _PerformKeeplistAdd(self.data.itemID, self.data.itemName)
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    showAlert = true,
    preferredIndex = 3,
}

-------------------------------------------------------------------------------
-- StaticPopup: "Add to vendor whitelist?"
-------------------------------------------------------------------------------

StaticPopupDialogs["EM_VENDORLIST_ADD"] = {
    text = "Add %s to vendor whitelist?\nThis item will always be vendored.",
    button1 = "Yes",
    button2 = "Cancel",
    OnAccept = function(self)
        _PerformVendorlistAdd(self.data.itemID, self.data.itemName)
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    showAlert = true,
    preferredIndex = 3,
}

-------------------------------------------------------------------------------
-- StaticPopup: conflict resolution - item is on the OTHER list, move it?
-- Keep List wins in classification, so the user must explicitly choose which
-- list the item should live on. Selecting Move removes it from the other list.
-------------------------------------------------------------------------------

StaticPopupDialogs["EM_KEEPLIST_MOVE_FROM_VENDOR"] = {
    text = "%s is on the Vendor List.\nMove it to the Keep List?",
    button1 = "Move",
    button2 = "Cancel",
    OnAccept = function(self)
        local itemID = self.data.itemID
        local itemName = self.data.itemName
        if EmpireManager.db.global.vendorWhitelist then
            EmpireManager.db.global.vendorWhitelist[itemID] = nil
        end
        _PerformKeeplistAdd(itemID, itemName)
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    showAlert = true,
    preferredIndex = 3,
}

StaticPopupDialogs["EM_VENDORLIST_MOVE_FROM_KEEP"] = {
    text = "%s is on the Keep List.\nMove it to the Vendor List?\n\n|cffff8800This item will always be vendored.|r",
    button1 = "Move",
    button2 = "Cancel",
    OnAccept = function(self)
        local itemID = self.data.itemID
        local itemName = self.data.itemName
        if EmpireManager.db.global.keepList then
            EmpireManager.db.global.keepList[itemID] = nil
        end
        _PerformVendorlistAdd(itemID, itemName)
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    showAlert = true,
    preferredIndex = 3,
}

-------------------------------------------------------------------------------
-- StaticPopup: generic remove-from-list confirm. Caller passes label and
-- onConfirm via .data on the returned popup.
-------------------------------------------------------------------------------

StaticPopupDialogs["EM_CONFIRM_REMOVE"] = {
    text = "%s",
    button1 = "Yes",
    button2 = "Cancel",
    OnAccept = function(self)
        if self.data and type(self.data.onConfirm) == "function" then
            self.data.onConfirm()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-------------------------------------------------------------------------------
-- Triage Overlay UI
-------------------------------------------------------------------------------

-- Anchor triage overlay next to the most relevant open frame
-- Clamp the triage frame to fit the current screen so its bottom tabs/buttons stay reachable.
-- Leaves margin for the Blizzard menu bar (~80px) and a top buffer (~40px). Safe to call
-- from anywhere and respects the user's moved/resized state.
function EmpireManager:ClampTriageToScreen()
    local f = self.triageFrame
    if not f then
        return
    end
    local screenH = (UIParent and UIParent:GetHeight()) or 768
    local maxH = math.max(300, math.floor(screenH - 120))
    if f:GetHeight() > maxH then
        f:SetHeight(maxH)
    end
end

-- Convert the triage frame's current position to an absolute UIParent anchor so
-- subsequent resize/move operations aren't "stuck" to another frame's edge.
-- Safe to call after any relative SetPoint: reads GetLeft/GetTop (which flushes
-- layout) and rebinds TOPLEFT to UIParent BOTTOMLEFT at the same screen coords.
local function DetachToUIParent(f)
    local left, top = f:GetLeft(), f:GetTop()
    if not left or not top then
        return false
    end
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    return true
end

function EmpireManager:AnchorTriageOverlay()
    local f = self.triageFrame
    if not f then
        return
    end
    if self._triageUserMoved then
        self:ClampTriageToScreen() -- still cap height in case a saved position was oversized
        return
    end

    -- Cap the triage height so the bottom tabs/buttons stay reachable on smaller screens.
    local screenH = (UIParent and UIParent:GetHeight()) or 768
    local maxH = math.max(300, math.floor(screenH - 120))
    local function fit(h)
        return math.min(h or 0, maxH)
    end

    -- Priority: Dashboard > Vendor > Mailbox > Bank > standalone
    local dash = self.dashboardFrame
    if dash and dash:IsShown() then
        f:SetHeight(fit(dash:GetHeight()))
        f:ClearAllPoints()
        f:SetPoint("TOPRIGHT", dash, "TOPLEFT", -2, 0)
    elseif MerchantFrame and MerchantFrame:IsShown() then
        f:SetHeight(fit(MerchantFrame:GetHeight()))
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", MerchantFrame, "TOPRIGHT", 2, 0)
    elseif MailFrame and MailFrame:IsShown() then
        f:SetHeight(fit(MailFrame:GetHeight()))
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", MailFrame, "TOPRIGHT", 2, 0)
    elseif BankFrame and BankFrame:IsShown() then
        f:SetHeight(fit(BankFrame:GetHeight()))
        f:ClearAllPoints()
        -- +50px offset leaves room for the side tab buttons on warband/char/guild banks
        f:SetPoint("TOPLEFT", BankFrame, "TOPRIGHT", 52, 0)
    else
        -- Guild bank: Blizzard's native frame or Baganator's replacement
        local gbFrame = (GuildBankFrame and GuildBankFrame:IsShown() and GuildBankFrame)
            or (_G["Baganator_SingleViewGuildViewFrame1"] and _G["Baganator_SingleViewGuildViewFrame1"]:IsShown() and _G["Baganator_SingleViewGuildViewFrame1"])
            or (
                _G["Baganator_SingleViewGuildViewFrame2"]
                and _G["Baganator_SingleViewGuildViewFrame2"]:IsShown()
                and _G["Baganator_SingleViewGuildViewFrame2"]
            )
        if gbFrame then
            f:SetHeight(fit(gbFrame:GetHeight()))
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", gbFrame, "TOPRIGHT", 52, 0)
        end
    end

    -- Detach from the anchoring frame immediately. Keeping a relative anchor
    -- causes the "sticky resize" bug: when the user drags the resize grip, the
    -- frame we're anchored to (MailFrame, MerchantFrame, etc.) may move or
    -- reflow mid-drag, yanking the triage along. Rebind to absolute UIParent
    -- coords so resize grows cleanly from the current top-left.
    DetachToUIParent(f)
end

-- Hide the triage overlay when the player leaves a bank/vendor/mailbox, if the
-- closeTriageOnLeave option is set. Skipped while a bulk operation is running or
-- if another interaction source is still open (the close events for one source
-- shouldn't dismiss triage while another is active).
function EmpireManager:CloseTriageOnLeave()
    if not self.db.global.options.closeTriageOnLeave then
        return
    end
    if self._triageBulkOperating then
        return
    end
    if self.bankIsOpen or self.guildBankIsOpen or self.mailboxOpen then
        return
    end
    if self.triageFrame and self.triageFrame:IsShown() then
        self.triageFrame:Hide()
    end
end

function EmpireManager:ToggleTriageOverlay()
    if self.triageFrame then
        if self.triageFrame:IsShown() then
            self.triageFrame:Hide()
            return
        else
            self:AnchorTriageOverlay()
            self.triageFrame:Show()
            -- Reset all locks and per-tab state for fresh rebuild on reopen
            self._triageTabLocked = false
            self._triageScanning = false
            self._bankTriageScanning = false
            self._triageFingerprint = nil
            self._bankTriageFingerprint = nil
            self._triageBagsBuilt = false
            self._triageBankBuilt = false
            self:_ReleaseTabWidgets("bags")
            self:_ReleaseTabWidgets("bank")
            self.triageSkippedItems = {}
            self.triageSkippedActions = {}
            self.bankTriageSkippedItems = {}
            self.bankTriageSkippedActions = {}
            -- Select tab based on what's open (defer to next frame so layout resolves)
            self:UpdateTriageTabButtons()
            local defaultTab = self:GetDefaultTriageTab()
            C_Timer.After(0, function()
                self:SwitchTriageTab(defaultTab)
            end)
            return
        end
    end
    self:CreateTriageOverlay()
end

function EmpireManager:InitTriageTabs(f)
    if f._tabsInitialized then
        return
    end
    f._tabsInitialized = true

    Mixin(f, TabSystemOwnerMixin)
    TabSystemOwnerMixin.OnLoad(f)
    f:SetTabSystem(f.TabSystem)

    local tabNames = { "Bags", "Bank", "Warband Bank", "Guild Bank" }
    local tabKeys = { "bags", "bank", "warband", "guildbank" }
    f._triageTabIDs = {}
    f._triageTabKeyToID = {}
    for i, name in ipairs(tabNames) do
        f._triageTabIDs[i] = f:AddNamedTab(name)
        f._triageTabKeyToID[tabKeys[i]] = f._triageTabIDs[i]
        f:SetTabCallback(f._triageTabIDs[i], function()
            if self._triageBulkOperating then
                return
            end
            self._triageTabFromCallback = true
            self:SwitchTriageTab(tabKeys[i])
            self._triageTabFromCallback = false
        end)
    end
    f:SetTab(f._triageTabIDs[1])
end

function EmpireManager:CreateTriageOverlay()
    local f = EmpireManagerTriageFrame

    -- Tabs must always (re-)init - XML children are fresh after /reload
    self:InitTriageTabs(f)

    -- Guard: only create buttons/backdrop once (survives /reload)
    if f._initialized then
        self.triageFrame = f
        self._triageUserMoved = false
        self._triageActiveTab = "bags"
        self._triageTabLocked = false
        self._triageScanning = false
        self._bankTriageScanning = false
        self._triageBagsBuilt = false
        self._triageBankBuilt = false
        self._triageFingerprint = nil
        self._bankTriageFingerprint = nil
        self._triagePooledRows = {}
        self._triagePooledSeps = {}
        self._triagePooledHdrs = {}
        self._triagePooledFs = {}
        self.triageSkippedItems = {}
        self.triageSkippedActions = {}
        self.bankTriageSkippedItems = {}
        self.bankTriageSkippedActions = {}
        self:AnchorTriageOverlay()
        f:Show()
        self:UpdateTriageTabButtons()
        C_Timer.After(0, function()
            self:SwitchTriageTab(self:GetDefaultTriageTab())
        end)
        return
    end

    -- PortraitFrameTemplate setup (matches main dashboard)
    f:SetTitle("EmpireManager - Triage")
    f:SetPortraitToAsset("Interface\\AddOns\\EmpireManager\\textures\\logo-portrait")

    -- Darken the ListPanel's tooltip-style border (default beige top is too light)
    -- and shift the fill off Blizzard's default blue-black tooltip tone toward a
    -- warm neutral that harmonises with the portrait frame's parchment trim.
    if f.ListPanel and f.ListPanel.SetBackdropBorderColor then
        f.ListPanel:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.9)
    end
    if f.ListPanel and f.ListPanel.SetBackdropColor then
        f.ListPanel:SetBackdropColor(0.133, 0.125, 0.114, 0.95)
    end

    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(frame)
        frame:StartMoving()
        if GameTooltip then
            GameTooltip:Hide()
        end
        for _, row in ipairs(allRowFrames) do
            row:EnableMouse(false)
        end
    end)
    f:SetScript("OnDragStop", function(frame)
        frame:StopMovingOrSizing()
        for _, row in ipairs(allRowFrames) do
            row:EnableMouse(true)
        end
    end)

    -- OnHide cleanup: any close path (ESC, X button, /em triage, dashboard T)
    -- must cancel running operations and free caches.
    f:HookScript("OnHide", function()
        EmpireManager:CancelAsyncScan()
        EmpireManager:AbortBulkOperation()
        if GameTooltip then
            GameTooltip:Hide()
        end
        EmpireManager._triageTabLocked = false
        EmpireManager:_ReleaseTabWidgets("bags")
        EmpireManager:_ReleaseTabWidgets("bank")
        EmpireManager._equipSetItems = nil
        EmpireManager._equipSetGUIDs = nil
        EmpireManager._classifyCtx = nil
    end)

    -- ESC to close. Register the real XML frame name (untainted), not a Lua _G
    -- alias - a tainted alias taints Blizzard's secure CloseSpecialWindows loop.
    if self.db and self.db.global.options.escToClose then
        if not tContains(UISpecialFrames, "EmpireManagerTriageFrame") then
            tinsert(UISpecialFrames, "EmpireManagerTriageFrame")
        end
    end

    -- Track user drag
    f:HookScript("OnDragStart", function()
        self._triageUserMoved = true
    end)

    -- Resize grip (bottom-right corner)
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -4, 4)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    self._triageGrip = grip
    grip:SetScript("OnMouseDown", function()
        -- Belt-and-suspenders: AnchorTriageOverlay already detaches to UIParent,
        -- but re-assert here in case something re-anchored to MailFrame / etc.
        -- between the initial anchor and the resize. Without this the frame may
        -- grow away from an anchored sibling, causing the whole window to shift.
        if DetachToUIParent(f) then
            self._triageUserMoved = true
        end
        f:StartSizing("BOTTOMRIGHT")
    end)
    grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        self:ClampTriageToScreen()
        -- Rebuild content at new width using cached scan results (no rescan).
        if self._triageActiveTab == "bags" then
            self._triageFingerprint = nil
            self:RefreshTriageDisplay(false)
        else
            self._bankTriageFingerprint = nil
            self:RefreshBankTriageDisplay(false)
        end
    end)

    -- Close button (PortraitFrameTemplate provides CloseButton)
    f.CloseButton:SetScript("OnClick", function()
        GameTooltip:Hide()
        self:CancelAsyncScan()
        self:_ReleaseTabWidgets("bags")
        self:_ReleaseTabWidgets("bank")
        self._equipSetItems = nil
        self._equipSetGUIDs = nil
        self._classifyCtx = nil
        f:Hide()
    end)

    -- ScrollFrame setup
    local sf = f.ScrollFrame
    sf:SetScrollChild(sf.Content)

    -- Default height, then anchor to nearest relevant frame
    f:SetHeight(500)
    self.triageFrame = f
    self._triageUserMoved = false
    self._triageActiveTab = "bags"
    self:AnchorTriageOverlay()
    f:Show()

    -- Info button (right of portrait): help tooltip for triage interactions
    if f.InfoButton then
        local HELP_LINES = {
            "Bag Triage",
            "Review and confirm moves before committing.",
            " ",
            "Summary counts: click to jump to that section.",
            " ",
            "Right-click an item (left side): skip this item.",
            "Right-click an action (right side): skip this action.",
            "Right-click a section header: skip all items.",
            " ",
            "Ctrl-click a Vendor/Route/Stash row: add to Keep List.",
            " ",
            "Rescan button: left-click to rescan bags, right-click to clear skipped items and rescan.",
        }
        f.InfoButton:SetScript("OnEnter", function(btn)
            GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
            for i, line in ipairs(HELP_LINES) do
                if i <= 2 then
                    GameTooltip:AddLine(line, 1, 0.82, 0, true)
                else
                    GameTooltip:AddLine(line, 1, 1, 1, true)
                end
            end
            GameTooltip:Show()
        end)
        f.InfoButton:SetScript("OnLeave", GameTooltip_Hide)
        f.InfoButton:Show()
    end

    local btnW, btnH = 170, 24

    ---------------------------------------------------------------------------
    -- Shared refresh button (AH-style icon) - dispatches to the active tab.
    ---------------------------------------------------------------------------
    local refreshBtn = CreateFrame("Button", nil, f, "RefreshButtonTemplate")
    refreshBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -26)
    refreshBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    refreshBtn:SetScript("OnClick", function(_, button)
        -- A rescan clears the selected Group, as it clears skipped rows.
        self:ClearGroupMover()
        if button == "RightButton" then
            if self._triageActiveTab == "bags" then
                self.triageSkippedItems = {}
                self.triageSkippedActions = {}
                self:RefreshTriageDisplay(true)
            else
                self.bankTriageSkippedItems = {}
                self.bankTriageSkippedActions = {}
                self:RefreshBankTriageDisplay(true)
            end
        else
            if self._triageActiveTab == "bags" then
                self:RefreshTriageDisplay(true)
            else
                self:RefreshBankTriageDisplay(true)
            end
        end
    end)
    refreshBtn:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_TOP")
        GameTooltip:SetText("Rescan")
        GameTooltip:AddLine("Left-click: apply rules and rescan", 1, 1, 1, true)
        GameTooltip:AddLine("Right-click: clear skipped items first", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    refreshBtn:SetScript("OnLeave", GameTooltip_Hide)
    self._triageRescanBtn = refreshBtn

    -- TSM group mover. Absent (not disabled) when TSM is not loaded.
    if TSM_API then
        -- Same Blizzard square-button frame as Rescan, with our icon inside it.
        local moverBtn = CreateFrame("Button", nil, f, "SquareIconButtonTemplate")
        moverBtn:SetPoint("RIGHT", refreshBtn, "LEFT", 2, 0)
        if moverBtn.Icon then
            moverBtn.Icon:SetTexture([[Interface\AddOns\EmpireManager\Textures\mover]])
            moverBtn.Icon:SetSize(16, 16)
            moverBtn.Icon:SetVertexColor(1, 0.82, 0)
        end
        moverBtn:SetScript("OnClick", function()
            self:OpenGroupMoverPicker()
        end)
        moverBtn:SetScript("OnEnter", function(btn)
            GameTooltip:SetOwner(btn, "ANCHOR_TOP")
            GameTooltip:SetText("Move TSM Group")
            GameTooltip:AddLine(self:GroupMoverDirectionText(), 1, 1, 1, true)
            local selected = self._groupMoverLabel or self._groupMoverPath
            if selected then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Selected: " .. selected, 1, 0.82, 0, true)
                GameTooltip:AddLine("Rescan to clear it.", 1, 1, 1, true)
            end
            GameTooltip:Show()
        end)
        moverBtn:SetScript("OnLeave", GameTooltip_Hide)
        self._triageMoverBtn = moverBtn
    end

    -- Tooltip installer: shows btn._disabledReason on hover when the button is disabled.
    -- SetMotionScriptsWhileDisabled is required so OnEnter still fires while the
    -- button is in the disabled state - otherwise no tooltip would ever appear
    -- on a disabled button (this matches Blizzard's UIButtonTemplate behaviour).
    local function AttachDisabledTooltip(btn)
        btn:SetMotionScriptsWhileDisabled(true)
        btn:SetScript("OnEnter", function(b)
            local reason = b._disabledReason
            if reason and not b:IsEnabled() then
                GameTooltip:SetOwner(b, "ANCHOR_TOP")
                GameTooltip:AddLine(reason, 1, 1, 1, true)
                GameTooltip:Show()
            end
        end)
        btn:SetScript("OnLeave", GameTooltip_Hide)
    end

    ---------------------------------------------------------------------------
    -- Bags tab buttons (row 1 = top, row 2 = bottom, above tabs)
    ---------------------------------------------------------------------------
    -- Mail/Vendor/Deposit share the BOTTOMRIGHT slot; only one is visible at
    -- a time (mutually exclusive externals: mailbox vs merchant vs bank).
    local depositBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    depositBtn:SetSize(btnW, btnH)
    depositBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 20)
    depositBtn:SetText("Deposit All Stash")
    depositBtn._disabledReason = "Open a bank to deposit"
    depositBtn:Disable()
    depositBtn:Hide()
    depositBtn:SetScript("OnClick", function()
        self:BankTriageStash()
    end)
    AttachDisabledTooltip(depositBtn)
    self.triageDepositBtn = depositBtn

    local mailBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    mailBtn:SetSize(btnW, btnH)
    mailBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 20)
    mailBtn:SetText("Mail All Routable")
    mailBtn._disabledReason = "Open a mailbox to send"
    mailBtn:Disable()
    mailBtn:Hide()
    mailBtn:SetScript("OnClick", function()
        self:MailTriageRoutable()
    end)
    AttachDisabledTooltip(mailBtn)
    self.triageMailBtn = mailBtn

    local vendorBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    vendorBtn:SetSize(btnW, btnH)
    vendorBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 20)
    vendorBtn:SetText("Vendor All")
    vendorBtn._disabledReason = "Open a merchant to vendor"
    vendorBtn:Disable()
    vendorBtn:Hide()
    vendorBtn:SetScript("OnClick", function()
        self:VendorTriageJunk()
    end)
    AttachDisabledTooltip(vendorBtn)
    self.triageVendorBtn = vendorBtn

    self._triageBagButtons = { mailBtn, vendorBtn, depositBtn }

    ---------------------------------------------------------------------------
    -- Bank tab buttons
    ---------------------------------------------------------------------------
    local reorganizeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    reorganizeBtn:SetSize(btnW, btnH)
    reorganizeBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 20, 20)
    reorganizeBtn:SetText("Reorganize")
    reorganizeBtn._disabledReason = "Nothing to Reorganize"
    reorganizeBtn:Disable()
    reorganizeBtn:SetScript("OnClick", function()
        self:ReorganizeBankItems()
    end)
    AttachDisabledTooltip(reorganizeBtn)
    self._triageReorganizeBtn = reorganizeBtn

    local takeOutBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    takeOutBtn:SetSize(btnW, btnH)
    takeOutBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 20)
    takeOutBtn:SetText("Take Out")
    takeOutBtn._disabledReason = "Nothing to Take Out"
    takeOutBtn:Disable()
    takeOutBtn:SetScript("OnClick", function()
        self:TakeOutBankItems()
    end)
    AttachDisabledTooltip(takeOutBtn)
    self._triageTakeOutBtn = takeOutBtn

    self._triageBankButtons = { reorganizeBtn, takeOutBtn }
    for _, btn in ipairs(self._triageBankButtons) do
        btn:Hide()
    end

    ---------------------------------------------------------------------------
    -- Per-tab state
    self._triageBagsBuilt = false
    self._triageBankBuilt = false
    self._triagePooledRows = {}
    self._triagePooledSeps = {}
    self._triagePooledHdrs = {}
    self._triagePooledFs = {}
    self.triageSkippedItems = {}
    self.triageSkippedActions = {}
    self.bankTriageSkippedItems = {}
    self.bankTriageSkippedActions = {}

    f._initialized = true

    self:UpdateTriageTabButtons()
    C_Timer.After(0, function()
        self:SwitchTriageTab(self:GetDefaultTriageTab())
    end)
end

-- Return tracked widgets to their pools. Called before rebuild or on close.
function EmpireManager:_ReleaseTabWidgets(tabKey)
    if tabKey == "bags" then
        self._triageBagsBuilt = false
    elseif tabKey == "bank" then
        self._triageBankBuilt = false
    end
    -- Return pooled widgets
    if self._triagePooledRows then
        for _, entry in ipairs(self._triagePooledRows) do
            ReleaseRow(entry)
        end
        wipe(self._triagePooledRows)
    end
    if self._triagePooledSeps then
        for _, tex in ipairs(self._triagePooledSeps) do
            ReleaseSep(tex)
        end
        wipe(self._triagePooledSeps)
    end
    if self._triagePooledHdrs then
        for _, fs in ipairs(self._triagePooledHdrs) do
            ReleaseHeader(fs)
        end
        wipe(self._triagePooledHdrs)
    end
    if self._triagePooledFs then
        for _, fs in ipairs(self._triagePooledFs) do
            ReleaseFs(fs)
        end
        wipe(self._triagePooledFs)
    end
end

-------------------------------------------------------------------------------
-- Bulk Operation Abort
-------------------------------------------------------------------------------

-- Bulk operation cancellation via generation counter.
-- Each operation captures the current generation at start.
-- AbortBulkOperation bumps the generation so stale closures stop.

-- Lock/unlock all triage action buttons + resize grip + tabs during long
-- operations. After unlock, callers should invoke the relevant Update*BtnState
-- functions so buttons settle back into their correct context-dependent state.
function EmpireManager:_SetAllTriageActionsLocked(locked)
    if self._triageBagButtons then
        for _, b in ipairs(self._triageBagButtons) do
            if locked then
                b:Disable()
            else
                b:Enable()
            end
        end
    end
    if self._triageBankButtons then
        for _, b in ipairs(self._triageBankButtons) do
            if locked then
                b:Disable()
            else
                b:Enable()
            end
        end
    end
    if self._triageRescanBtn then
        if locked then
            self._triageRescanBtn:Disable()
        else
            self._triageRescanBtn:Enable()
        end
    end
    if self._triageMoverBtn then
        if locked then
            self._triageMoverBtn:Disable()
        else
            self._triageMoverBtn:Enable()
        end
    end
    if self._triageGrip then
        self._triageGrip:EnableMouse(not locked)
    end
    -- Lock row click/tooltip interaction during bulk ops so the user can't race
    -- the classifier by skipping/adding items while moves are in flight.
    -- When disabling mouse on a hovered row, OnLeave does not fire, so the
    -- left/right hover highlights, divider, and tooltip get stuck. Force-hide
    -- them here to clear that state.
    if self._triagePooledRows then
        for _, entry in ipairs(self._triagePooledRows) do
            if entry and entry.frame then
                entry.frame:EnableMouse(not locked)
                if locked then
                    if entry.hlLeft then
                        entry.hlLeft:Hide()
                    end
                    if entry.hlRight then
                        entry.hlRight:Hide()
                    end
                    if entry.divider then
                        entry.divider:Hide()
                    end
                end
            end
        end
        if locked then
            GameTooltip:Hide()
        end
    end
    local f = self.triageFrame
    if f and f.TabSystem and f._triageTabIDs then
        if locked then
            for _, tabID in ipairs(f._triageTabIDs) do
                -- nil errorReason avoids Blizzard's red AddErrorLine; tooltipText shows in normal color
                f.TabSystem:SetTabEnabled(tabID, false, nil)
                local tabBtn = f.TabSystem.tabs and f.TabSystem.tabs[tabID]
                if tabBtn and tabBtn.SetTooltipText then
                    tabBtn:SetTooltipText("Operation in progress")
                end
            end
        else
            -- On unlock, restore contextual per-tab enable state (bank open? guild open? etc.)
            self:UpdateTriageTabButtons()
        end
    end
end

function EmpireManager:StartBulkOperation()
    self._bulkGeneration = (self._bulkGeneration or 0) + 1
    self._triageBulkOperating = true
    -- Close the Group picker: leaving it open would show an enabled Move button
    -- that then refuses the click.
    if EmpireManagerGroupMoverDialog and EmpireManagerGroupMoverDialog:IsShown() then
        EmpireManagerGroupMoverDialog:Hide()
    end
    ResetMaxStackCache()
    self:_SetAllTriageActionsLocked(true)
    return self._bulkGeneration
end

function EmpireManager:IsBulkCancelled(gen)
    return gen ~= self._bulkGeneration
end

function EmpireManager:AbortBulkOperation()
    self._bulkGeneration = (self._bulkGeneration or 0) + 1
    self._triageBulkOperating = false
    self._vendorSelling = false
    self:_SetAllTriageActionsLocked(false)
    self:ReleaseAllListeners()
end

-------------------------------------------------------------------------------
-- Tab Switching
-------------------------------------------------------------------------------

function EmpireManager:GetDefaultTriageTab()
    -- If a specific tab was requested (e.g. by guild bank auto-open), use it once
    if self._guildBankAutoTab then
        local tab = self._guildBankAutoTab
        self._guildBankAutoTab = nil
        return tab
    end
    if self.guildBankIsOpen then
        return "guildbank"
    end
    if self.bankIsOpen then
        -- Default to bags tab on bank open - bag triage is fast.
        -- User can switch to bank/warband tab manually (avoids 770+ slot scan on open).
        return "bags"
    end
    return "bags"
end

function EmpireManager:UpdateTriageTabButtons()
    local f = self.triageFrame
    if not f or not f._triageTabIDs then
        return
    end

    local ids = f._triageTabIDs
    -- All 4 tabs are always visible. Each is enabled/disabled per context.
    -- Tab1 = Bags (always enabled)
    -- Tab2 = Bank (char bank - enabled when a regular banker is open)
    -- Tab3 = Warband Bank (enabled when a bank is open)
    -- Tab4 = Guild Bank (enabled when a guild bank is open)

    local bankOpen = self.bankIsOpen
    local warbandOnly = bankOpen and self:IsWarbandBankOnly()
    local guildOpen = self.guildBankIsOpen
    local warbandAccessible = bankOpen

    local bankEnabled = bankOpen and not warbandOnly
    local warbandEnabled = warbandAccessible
    local guildEnabled = guildOpen

    -- Use tooltipText (normal color) instead of errorReason (red) for disabled-tab tooltips.
    local function applyTab(tabID, enabled, reason)
        f.TabSystem:SetTabEnabled(tabID, enabled, nil)
        local tabBtn = f.TabSystem.tabs and f.TabSystem.tabs[tabID]
        if tabBtn and tabBtn.SetTooltipText then
            -- NB: not `enabled and nil or reason` - that ternary returns reason in both branches.
            if enabled then
                tabBtn:SetTooltipText(nil)
            else
                tabBtn:SetTooltipText(reason)
            end
        end
    end

    applyTab(ids[1], true, nil)
    applyTab(ids[2], bankEnabled, "Visit a Banker to view the Bank")
    applyTab(ids[3], warbandEnabled, "Visit a Banker to view the Warband Bank")
    applyTab(ids[4], guildEnabled, "Visit a Vault to view the Guild Bank")
    f.TabSystem:Layout()

    -- If current tab has become disabled, fall back to bags
    local current = f:GetTab()
    if current then
        local disabled = (current == ids[2] and not bankEnabled)
            or (current == ids[3] and not warbandEnabled)
            or (current == ids[4] and not guildEnabled)
        if disabled then
            f:SetTab(ids[1])
        end
    end
end

function EmpireManager:SwitchTriageTab(tab)
    if self._triageBulkOperating then
        return
    end
    if self._triageTabLocked then
        -- Cancel in-progress scan so the tab switch can proceed
        self:CancelAsyncScan()
        self._triageTabLocked = false
        self._triageScanning = false
        self._bankTriageScanning = false
        self:_SetAllTriageActionsLocked(false)
    end
    local prevTab = self._triageActiveTab
    self._triageActiveTab = tab

    -- Update tab visual via TabSystem (skip if already set by callback)
    local f = self.triageFrame
    if f and f._triageTabKeyToID and not self._triageTabFromCallback then
        local tabID = f._triageTabKeyToID[tab]
        if tabID then
            f:SetTab(tabID)
        end
    end

    -- Show/hide correct button set
    local bagBtns = self._triageBagButtons or {}
    local bankBtns = self._triageBankButtons or {}

    if tab == "bags" then
        for _, btn in ipairs(bankBtns) do
            btn:Hide()
        end
        -- Bag action buttons (Mail/Vendor/Deposit) manage their own visibility
        -- via Update*BtnState based on which external frame is open.
        self:UpdateMailBtnState()
        self:UpdateVendorBtnState()
        self:UpdateDepositBtnState()
    else
        for _, btn in ipairs(bagBtns) do
            btn:Hide()
        end
        for _, btn in ipairs(bankBtns) do
            btn:Show()
        end
    end

    -- Clear content for rebuild
    self:_ReleaseTabWidgets(tab == "bags" and "bags" or "bank")

    -- Bank sub-tab switch (bank/warband/guildbank share one container)
    local prevKey = prevTab == "bags" and "bags" or "bank"
    local newKey = tab == "bags" and "bags" or "bank"
    if prevKey == newKey and newKey == "bank" then
        self._bankTriageFingerprint = nil
        self:RefreshBankTriageDisplay()
        return
    end

    -- If target tab already built, just update button states
    local isBags = (tab == "bags")
    if isBags and self._triageBagsBuilt then
        self:UpdateVendorBtnState()
        self:UpdateMailBtnState()
        self:UpdateDepositBtnState()
        return
    elseif not isBags and self._triageBankBuilt then
        self:UpdateBankBtnState()
        return
    end

    -- First visit to this tab - trigger build
    if isBags then
        self:RefreshTriageDisplay()
    else
        self:RefreshBankTriageDisplay()
    end
end

-------------------------------------------------------------------------------
-- Bags Tab: Refresh Display
-------------------------------------------------------------------------------

-- Refresh the bags tab of the Triage overlay if it is open. Used by
-- restock-rule edits (add/save/delete/reorder) so a floor change reflects
-- immediately. No-op when the overlay is hidden or on a different tab.
function EmpireManager:RefreshTriageIfOpen()
    if not (self.triageFrame and self.triageFrame:IsShown()) then
        return
    end
    if self._triageActiveTab ~= "bags" then
        return
    end
    self:RefreshTriageDisplay(true)
end

function EmpireManager:RefreshTriageDisplay(forceRescan, silent)
    if self._triageBulkOperating then
        return
    end
    -- Consolidation in progress: skip ALL refreshes (silent AND non-silent). Each
    -- merge fires BAG_UPDATE_DELAYED; the 0.3s debounce sends EM_TRIAGE_REFRESH ->
    -- silent RefreshTriageDisplay, but on first open `_triageBagsBuilt` is false
    -- so the silent path falls through to the non-silent branch and starts a
    -- SECOND consolidation racing against the first, corrupting bags.
    if self._triageConsolidating then
        return
    end
    local f = self.triageFrame
    if not f then
        return
    end
    if self._triageActiveTab ~= "bags" then
        return
    end

    if forceRescan then
        self._triageBagsBuilt = false
        -- Invalidate the cached classification so RunTriageAsync re-classifies
        -- with current options instead of returning the stale result set.
        self._bagsDirty = true
        self.triageResults = nil
    end

    -- Save scroll position before rebuild
    local savedOffset = 0
    if f and f.ScrollFrame then
        savedOffset = f.ScrollFrame:GetVerticalScroll() or 0
    end

    -- Use cached results only for tab switches (built flag was set on first build).
    -- First open / force rescan always does a fresh scan to pick up uncached item names.
    if not forceRescan and not silent and self._triageBagsBuilt and self.triageResults then
        self._triageFingerprint = nil
        self:_BuildBagTriageUI(self.triageResults, savedOffset)
        return
    end

    -- Silent mode (bag change events): run async scan in background without
    -- tearing down the existing UI. Fingerprint check in _BuildBagTriageUI
    -- will skip the rebuild if nothing actually changed.
    if silent and self._triageBagsBuilt then
        self:CancelAsyncScan()
        self:RunTriageAsync(function(results)
            if not self.triageFrame or not self.triageFrame:IsShown() then
                return
            end
            if self._triageActiveTab ~= "bags" then
                return
            end
            self:_BuildBagTriageUI(results, savedOffset)
        end)
        return
    end

    self:CancelAsyncScan()
    self._triageScanning = true
    self._triageTabLocked = true
    self._triageFingerprint = nil
    self:_SetAllTriageActionsLocked(true)

    -- Show "Scanning..." immediately
    self:_ReleaseTabWidgets("bags")
    LayoutSummaryChips(f.SummaryBar, {})
    f.SummaryBar.SummaryLabel:Show()
    f.SummaryBar.SummaryLabel:SetText("|cffffffffScanning bags...|r")

    -- Pre-scan step: consolidate partial stacks of every bags-floor itemID for
    -- this character so the classifier and display see one clean stack instead
    -- of N partials. User-initiated path only (not silent auto-refresh). No-op
    -- when nothing to merge, so cheap to always run.
    self._triageConsolidating = true
    self:ConsolidateBagsFloors(function()
        self._triageConsolidating = false
        if not self.triageFrame or not self.triageFrame:IsShown() then
            self._triageScanning = false
            self:_SetAllTriageActionsLocked(false)
            return
        end
        if self._triageActiveTab ~= "bags" then
            self._triageScanning = false
            self:_SetAllTriageActionsLocked(false)
            return
        end
        self:RunTriageAsync(function(results)
            self._triageScanning = false
            self:_SetAllTriageActionsLocked(false)
            if not self.triageFrame or not self.triageFrame:IsShown() then
                return
            end
            if self._triageActiveTab ~= "bags" then
                return
            end

            self:_BuildBagTriageUI(results, savedOffset)
        end)
    end)
end

-- Separated UI builder so it can be called from the async callback
function EmpireManager:_BuildBagTriageUI(results, savedOffset)
    -- Filter out session-skipped rows/actions for display and counts.
    -- Skip key is per-row (bag:slot), not per-itemID, so 3 separate rows of the same
    -- non-stacking item (e.g. caged pets) skip independently.
    local skippedItems = self.triageSkippedItems or {}
    local skippedActions = self.triageSkippedActions or {}
    local visibleResults = {}
    for _, r in ipairs(results) do
        local rowKey = (r.item.bag or 0) .. ":" .. (r.item.slot or 0)
        if not skippedItems[rowKey] and not skippedActions[r.action] then
            visibleResults[#visibleResults + 1] = r
        end
    end

    local counts, vendorValue = self:GetTriageSummary(visibleResults)

    -- Cheap gate: count mismatch → definitely changed, skip the O(N) string build.
    -- On count match, do the full fingerprint compare. Including itemName here
    -- so a "" -> populated transition (uncached item names from a cold scan)
    -- still forces a rebuild on the deferred 1.5s rescan.
    local nVisible = #visibleResults
    if nVisible == self._triageFingerprintCount then
        local fp = {}
        for i, r in ipairs(visibleResults) do
            fp[i] = (r.item.itemID or 0)
                .. ":"
                .. (r.category or "")
                .. ":"
                .. (r.item.stackCount or 0)
                .. ":"
                .. (r.item.itemName or "")
        end
        local fingerprint = table.concat(fp, "|")
        if fingerprint == self._triageFingerprint then
            -- Results unchanged - just update button states without rebuilding UI
            if self.triageVendorBtn then
                self.triageVendorBtn._hasVendor = counts[CAT_VENDOR] > 0
                self.triageVendorBtn._vendorCount = counts[CAT_VENDOR]
                self.triageVendorBtn._vendorValue = vendorValue
                self:UpdateVendorBtnState()
            end
            if self.triageMailBtn then
                self.triageMailBtn._hasRoute = counts[CAT_ROUTE] > 0
                self.triageMailBtn._routeCount = counts[CAT_ROUTE]
                self:UpdateMailBtnState()
            end
            self:UpdateDepositBtnState()
            return
        end
        self._triageFingerprint = fingerprint
    else
        self._triageFingerprint = nil -- force full rebuild below; fingerprint will be set on next count-match cycle
    end
    self._triageFingerprintCount = nVisible

    GameTooltip:Hide()
    local ff = self.triageFrame

    -- Release previous widgets
    self:_ReleaseTabWidgets("bags")

    -- Summary line / jump chips
    local vendorSuffix = vendorValue > 0 and string.format("  (%s)", self:FormatGold(vendorValue)) or ""
    local actionable = counts[CAT_ROUTE] + counts[CAT_STASH] + counts[CAT_VENDOR]
    self._triageSectionY = {}
    local function JumpToSection(cat)
        local yy = self._triageSectionY and self._triageSectionY[cat]
        if yy then
            ff.ScrollFrame:SetVerticalScroll(math.max(0, yy - 8))
        end
    end
    if actionable == 0 then
        LayoutSummaryChips(ff.SummaryBar, {})
        ff.SummaryBar.SummaryLabel:Show()
        ff.SummaryBar.SummaryLabel:SetText("|cff00cc00All sorted|r")
    else
        local chips = {}
        local info
        if counts[CAT_ROUTE] > 0 then
            info = CATEGORY_INFO[CAT_ROUTE]
            chips[#chips + 1] = {
                text = string.format("%d Route", counts[CAT_ROUTE]),
                r = info.r,
                g = info.g,
                b = info.b,
                onClick = function()
                    JumpToSection(CAT_ROUTE)
                end,
            }
        end
        if counts[CAT_STASH] > 0 then
            info = CATEGORY_INFO[CAT_STASH]
            chips[#chips + 1] = {
                text = string.format("%d Stash", counts[CAT_STASH]),
                r = info.r,
                g = info.g,
                b = info.b,
                onClick = function()
                    JumpToSection(CAT_STASH)
                end,
            }
        end
        if counts[CAT_VENDOR] > 0 then
            info = CATEGORY_INFO[CAT_VENDOR]
            chips[#chips + 1] = {
                text = string.format("%d Vendor%s", counts[CAT_VENDOR], vendorSuffix),
                r = info.r,
                g = info.g,
                b = info.b,
                onClick = function()
                    JumpToSection(CAT_VENDOR)
                end,
            }
        end
        ff.SummaryBar.SummaryLabel:Hide()
        LayoutSummaryChips(ff.SummaryBar, chips)
    end

    -- Build items into ScrollFrame content
    local sf = ff.ScrollFrame
    local content = sf.Content
    local contentW = sf:GetWidth()
    if not contentW or contentW < 10 then
        C_Timer.After(0, function()
            if ff and ff:IsShown() then
                self._triageFingerprint = nil
                self:_BuildBagTriageUI(results, savedOffset)
            end
        end)
        return
    end
    content:SetWidth(contentW)
    local pooledRows = {}
    local pooledSeps = {}
    local pooledHdrs = {}
    local pooledFs = {}
    self._triagePooledRows = pooledRows
    self._triagePooledSeps = pooledSeps
    self._triagePooledHdrs = pooledHdrs
    self._triagePooledFs = pooledFs

    local function TrackRow(entry)
        pooledRows[#pooledRows + 1] = entry
        return entry
    end
    local function TrackSep(tex)
        pooledSeps[#pooledSeps + 1] = tex
        return tex
    end
    local function TrackHdr(fs)
        pooledHdrs[#pooledHdrs + 1] = fs
        return fs
    end
    local function TrackFs(fs)
        pooledFs[#pooledFs + 1] = fs
        return fs
    end

    local y = 4
    local showKeep = EmpireManager._debugShowKeep
    local currentCat = nil
    for _, r in ipairs(visibleResults) do
        if showKeep or r.category ~= CAT_KEEP then
            if r.category ~= currentCat then
                currentCat = r.category
                local catInfo = CATEGORY_INFO[r.category]
                -- Heading first
                if y > 4 then
                    y = y + 12
                end -- gap before next section heading (skip top)
                self._triageSectionY[r.category] = y
                local hdr = TrackHdr(AcquireHeader(content))
                hdr:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
                hdr:SetPoint("TOPRIGHT", content, "TOPRIGHT", -8, -y)
                hdr:SetText(
                    string.format(
                        "|cff%02x%02x%02x%s|r",
                        catInfo.r * 255,
                        catInfo.g * 255,
                        catInfo.b * 255,
                        catInfo.label
                    )
                )
                local headerCat = r.category
                local headerLabel = catInfo.label
                hdr:SetScript("OnClick", function(_, btn)
                    if btn == "RightButton" then
                        self.triageSkippedItems = self.triageSkippedItems or {}
                        for _, res in ipairs(visibleResults) do
                            if res.category == headerCat then
                                local rowKey = (res.item.bag or 0) .. ":" .. (res.item.slot or 0)
                                self.triageSkippedItems[rowKey] = true
                            end
                        end
                        self._triageFingerprint = nil
                        GameTooltip:Hide()
                        self:RefreshTriageDisplay(false)
                    end
                end)
                hdr:SetScript("OnEnter", function(b)
                    GameTooltip:SetOwner(b, "ANCHOR_TOP")
                    GameTooltip:AddLine("Right-click: skip all " .. headerLabel .. " items", 1, 1, 1, true)
                    GameTooltip:Show()
                end)
                hdr:SetScript("OnLeave", GameTooltip_Hide)
                y = y + 18
                -- Faded divider under heading, tinted by category
                local sep = TrackSep(AcquireSep(content))
                sep:ClearAllPoints()
                sep:SetAtlas("ui-journeys-renown-divider", true)
                sep:SetPoint("TOP", content, "TOP", 0, -y)
                sep:SetVertexColor(catInfo.r, catInfo.g, catInfo.b, 1.0)
                y = y + 12
            end

            y = self:BuildTriageRow(content, y, r, TrackRow)
        end
    end

    -- If nothing actionable
    if counts[CAT_ROUTE] + counts[CAT_STASH] + counts[CAT_VENDOR] == 0 then
        local fs = TrackFs(AcquireFs(content))
        fs:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
        fs:SetPoint("RIGHT", content, "RIGHT", -8, 0)
        fs:SetText("|cff00cc00Nothing to Route, Stash or Vendor.|r")
        y = y + 30
    end

    content:SetHeight(y + 10)
    sf:SetVerticalScroll(savedOffset or 0)

    -- Update button states based on counts and context
    if self.triageMailBtn then
        self.triageMailBtn._hasRoute = counts[CAT_ROUTE] > 0
        self.triageMailBtn._routeCount = counts[CAT_ROUTE]
        self:UpdateMailBtnState()
    end
    if self.triageVendorBtn then
        self.triageVendorBtn._hasVendor = counts[CAT_VENDOR] > 0
        self.triageVendorBtn._vendorCount = counts[CAT_VENDOR]
        self.triageVendorBtn._vendorValue = vendorValue
        self:UpdateVendorBtnState()
    end
    self:UpdateDepositBtnState()
    self._triageBagsBuilt = true
    self._triageTabLocked = false
end

function EmpireManager:UpdateDepositBtnState()
    local btn = self.triageDepositBtn
    if not btn then
        return
    end
    if self._triageActiveTab ~= "bags" or not self:IsBankOpen() then
        btn:Hide()
        return
    end
    btn:Show()
    local depositableCount = self:CountDepositableStash()
    if self:IsRemoteBankOpen() then
        btn:SetText("Deposit All Stash")
        btn._disabledReason = "Remote bank: deposits not supported"
        btn:Disable()
    elseif depositableCount == 0 then
        btn:SetText("Deposit All Stash")
        btn._disabledReason = "No items to deposit in bags"
        btn:Disable()
    else
        btn:SetText(string.format("Deposit All Stash (%d)", depositableCount))
        btn._disabledReason = nil
        btn:Enable()
    end
end

-- Descriptions for built-in routing (actions without a user storage rule).
-- PATTERNS match an action suffix tag; EXACT matches literal action strings.
local SYSTEM_RULE_PATTERNS = {
    { match = "%(Lockbox%)$", role = "Lockpicker", desc = "Lockbox routed to your Lockpicker." },
    { match = "%(pets%)$", role = "Zookeeper", desc = "Pet item - no storage rule set, routed to a Zookeeper." },
    { match = "%(PvP%)$", role = "PvPer", desc = "PvP token - no storage rule set, routed to a PvPer." },
    { match = "%(DE%)$", role = "Enchanter", desc = "BoE gear - disenchanting is more profitable than selling." },
    { match = "%(AH%)$", role = "Auctioneer", desc = "BoE item - routed to your Auctioneer." },
}
local SYSTEM_RULE_EXACT = {
    ["Auctioneer (sell on AH)"] = { role = "Auctioneer", desc = "Own Auctioneer keeps BoE gear." },
    ["Enchanter (disenchant)"] = { role = "Enchanter", desc = "Own Enchanter keeps BoE gear." },
}
local function GetSystemRuleInfo(action)
    if type(action) ~= "string" then
        return
    end
    local exact = SYSTEM_RULE_EXACT[action]
    if exact then
        return exact
    end
    for _, p in ipairs(SYSTEM_RULE_PATTERNS) do
        if action:find(p.match) then
            return p
        end
    end
end

function EmpireManager:BuildTriageRow(content, y, result, TrackRow, opts)
    opts = opts or {}
    local skipItemsTable = opts.skipItems or self.triageSkippedItems
    local skipActionsTable = opts.skipActions or self.triageSkippedActions
    local fingerprintKey = opts.fingerprintKey or "_triageFingerprint"
    local refreshFunc = opts.refresh or function()
        self:RefreshTriageDisplay()
    end

    local catInfo = CATEGORY_INFO[result.category]
    local contentW = content:GetWidth() or 450

    -- Acquire pooled row
    local entry = TrackRow(AcquireRow(content))
    local row = entry.frame
    local nameFs = entry.nameFs
    local actionFs = entry.actionFs
    local hlLeft = entry.hlLeft
    local hlRight = entry.hlRight
    local divider = entry.divider

    -- Red full-row wash for capacity-blocked rows (assigned tabs full).
    if entry.blockedBg then
        entry.blockedBg:SetShown(result.blocked == true)
    end

    row:SetSize(contentW - 8, 20)
    row:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -y)

    -- Anchor the half-highlights and the mid-divider to the row's true center,
    -- so they always match the click handler's `(GetLeft+GetRight)/2` midpoint.
    -- Bias 8px left so the divider sits between item-name and action text,
    -- not exactly at row center (action text leans right of true middle).
    local CLICK_BIAS = -8
    if hlLeft then
        hlLeft:ClearAllPoints()
        hlLeft:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
        hlLeft:SetPoint("BOTTOMRIGHT", row, "CENTER", CLICK_BIAS, 0)
        hlLeft:Hide()
    end
    if hlRight then
        hlRight:ClearAllPoints()
        hlRight:SetPoint("TOPLEFT", row, "CENTER", CLICK_BIAS, 0)
        hlRight:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
        hlRight:Hide()
    end
    if divider then
        divider:ClearAllPoints()
        divider:SetPoint("CENTER", row, "CENTER", CLICK_BIAS, 0)
        divider:Hide()
    end
    row._clickBias = CLICK_BIAS

    -- Item name (left) - cut before midpoint so there's a visible gap before the action text
    nameFs:SetWidth(contentW * 0.5 - 12)
    local qc = ITEM_QUALITY_COLORS[result.item.quality]
    local nr, ng, nb = qc and qc.r or catInfo.r, qc and qc.g or catInfo.g, qc and qc.b or catInfo.b
    -- Show the moved count: routeCount (surplus above a restock floor) when set,
    -- otherwise the full stack.
    local shownCount = result.item.routeCount or result.item.stackCount
    local qty = shownCount > 1 and (" x" .. shownCount) or ""
    local icon = result.item.iconID or (result.item.itemID and C_Item.GetItemIconByID(result.item.itemID))
    local iconStr = icon and string.format("|T%s:14:14:0:0:64:64:5:59:5:59|t ", icon) or ""
    nameFs:SetText(
        string.format("%s|cff%02x%02x%02x%s|r%s", iconStr, nr * 255, ng * 255, nb * 255, result.item.itemName, qty)
    )

    -- Action text (right)
    actionFs:SetWidth(contentW * 0.5)
    actionFs:SetText(result.action)
    actionFs:SetTextColor(catInfo.r, catInfo.g, catInfo.b)

    -- Tooltip on hover - anchored to the right of the triage frame (Auctionator-style)
    -- so the row + cursor stay visible. Falls back to cursor anchor if the frame is gone.
    row:SetScript("OnEnter", function(self)
        local triageF = EmpireManager.triageFrame
        if triageF and triageF:IsShown() then
            GameTooltip:SetOwner(triageF, "ANCHOR_NONE")
            GameTooltip:ClearAllPoints()
            GameTooltip:SetPoint("TOPLEFT", triageF, "TOPRIGHT", 4, 0)
        else
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT")
        end
        if result.item.bankType == "guildbank" then
            if result.item.itemLink then
                GameTooltip:SetHyperlink(result.item.itemLink)
            end
        elseif result.item.bag and result.item.slot then
            GameTooltip:SetBagItem(result.item.bag, result.item.slot)
        elseif result.item.itemLink then
            GameTooltip:SetHyperlink(result.item.itemLink)
        end

        -- Matched storage rule info
        local ruleIndex = result.routing and result.routing.ruleIndex
        local sysRule = not ruleIndex and GetSystemRuleInfo(result.action) or nil
        local hasRuleBlock = false
        if ruleIndex then
            local rules = EmpireManager.db and EmpireManager.db.global and EmpireManager.db.global.storageAssignments
                or {}
            local rule = rules[ruleIndex]
            if rule then
                local pInfo = EmpireManager.PROF_INFO_BY_KEY[rule.profession]
                local label = pInfo and pInfo.label or rule.profession or "?"
                -- Count same-category rules to compute X/Y position
                local total, pos = 0, 0
                for i, r in ipairs(rules) do
                    if r.profession == rule.profession then
                        total = total + 1
                        if i == ruleIndex then
                            pos = total
                        end
                    end
                end
                GameTooltip:AddLine(" ")
                local suffix = total > 1 and string.format(" (%d/%d)", pos, total) or ""
                GameTooltip:AddLine(string.format("|cffffd100Rule #%d|r  %s%s", ruleIndex, label, suffix), 1, 1, 1)
                hasRuleBlock = true
                -- Subcategory names (if any)
                if rule.subcategories and #rule.subcategories > 0 then
                    local subs = EmpireManager.SUBCATEGORY_DISPLAY
                        and EmpireManager.SUBCATEGORY_DISPLAY[rule.profession]
                    local keyToLabel = {}
                    if subs and subs.items then
                        for _, sItem in ipairs(subs.items) do
                            keyToLabel[sItem.key] = sItem.label
                        end
                    end
                    local subLabels = {}
                    for _, key in ipairs(rule.subcategories) do
                        subLabels[#subLabels + 1] = keyToLabel[key] or key
                    end
                    GameTooltip:AddLine(table.concat(subLabels, ", "), 1, 1, 1)
                end
            end
        elseif sysRule then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(string.format("|cffffd100Default routing|r  %s", sysRule.role), 1, 1, 1)
            GameTooltip:AddLine(sysRule.desc, 0.8, 0.8, 0.8, true)
            hasRuleBlock = true
        elseif result.blockedRules and #result.blockedRules > 0 then
            -- Capacity-blocked row: there is no winning rule to name (routing is
            -- nil by design), so list every rule that matched but was full. This
            -- is what tells the user which rule to reorder or free space on.
            local rules = EmpireManager.db and EmpireManager.db.global and EmpireManager.db.global.storageAssignments
                or {}
            local added = false
            for _, idx in ipairs(result.blockedRules) do
                local rule = rules[idx]
                if rule then
                    if not added then
                        GameTooltip:AddLine(" ")
                        added = true
                    end
                    local pInfo = EmpireManager.PROF_INFO_BY_KEY[rule.profession]
                    local label = pInfo and pInfo.label or rule.profession or "?"
                    local total, pos = 0, 0
                    for i, r in ipairs(rules) do
                        if r.profession == rule.profession then
                            total = total + 1
                            if i == idx then
                                pos = total
                            end
                        end
                    end
                    local suffix = total > 1 and string.format(" (%d/%d)", pos, total) or ""
                    GameTooltip:AddDoubleLine(
                        string.format("|cffffd100Rule #%d|r  %s%s", idx, label, suffix),
                        "full",
                        1,
                        1,
                        1,
                        1,
                        0.3,
                        0.3
                    )
                end
            end
            hasRuleBlock = added
        end

        -- Calculated destination (trailing "(...)" split onto its own line, no parens)
        if result.action and result.action ~= "" then
            if not hasRuleBlock then
                GameTooltip:AddLine(" ")
            end
            local head, tail = result.action:match("^(.-)%s*%((.+)%)%s*$")
            if head and head ~= "" then
                GameTooltip:AddLine(head, 1, 0.82, 0, true)
                GameTooltip:AddLine(tail, 1, 0.82, 0, true)
            else
                GameTooltip:AddLine(result.action, 1, 0.82, 0, true)
            end
        end

        GameTooltip:Show()
        if IsModifiedClick("COMPAREITEMS") or GetCVarBool("alwaysCompareItems") then
            GameTooltip_ShowCompareItem()
        end
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
        if divider then
            divider:Hide()
        end
        if hlLeft then
            hlLeft:Hide()
        end
        if hlRight then
            hlRight:Hide()
        end
    end)

    -- While hovered, show the divider and highlight the half the cursor is on,
    -- so the user can see which side a right-click will hit (left=skip item /
    -- keeplist, right=skip action). Throttled to ~30fps.
    local lastUpdate = 0
    row:HookScript("OnUpdate", function(self, elapsed)
        lastUpdate = lastUpdate + elapsed
        if lastUpdate < 0.033 then
            return
        end
        lastUpdate = 0
        if not self:IsMouseOver() then
            return
        end
        -- Skip the half-highlight while controls are locked (bulk op in progress).
        -- Showing only one side looks broken; the lock UI already conveys "disabled".
        if not self:IsMouseEnabled() then
            return
        end
        if divider then
            divider:Show()
        end
        local cx = GetCursorPosition()
        local scale = self:GetEffectiveScale()
        local midX = ((self:GetLeft() + self:GetRight()) / 2 + (self._clickBias or 0)) * scale
        if cx > midX then
            if hlRight then
                hlRight:Show()
            end
            if hlLeft then
                hlLeft:Hide()
            end
        else
            if hlLeft then
                hlLeft:Show()
            end
            if hlRight then
                hlRight:Hide()
            end
        end
    end)

    -- Click handling
    -- Keep List popup fires on any row whose action triage would perform (vendor, route, stash,
    -- or vendor-junk takeout) - adding to Keep List stops triage from touching the item at all.
    local canAddToKeepList = result.category == CAT_VENDOR
        or result.category == CAT_ROUTE
        or result.category == CAT_STASH
        or result.category == CAT_TAKEOUT
    row:SetScript("OnClick", function(_, button)
        if button == "LeftButton" then
            -- Ctrl-click: add to Keep List. (KEEP rows are hidden, so no Vendor-List branch.)
            if IsControlKeyDown() then
                if canAddToKeepList then
                    EmpireManager:AddToKeepList(result.item.itemID, result.item.itemName)
                end
                return
            end
            -- Bare click: standard modified-click on the itemlink.
            if result.item.itemLink and HandleModifiedItemClick(result.item.itemLink) then
                return
            end
        elseif button == "RightButton" then
            -- Side decides between skip-row (left) and skip-action (right).
            -- Skip-row is per bag/slot so duplicates (e.g. 3 caged pets) skip independently.
            local cx = GetCursorPosition()
            local scale = row:GetEffectiveScale()
            local midX = ((row:GetLeft() + row:GetRight()) / 2 + (row._clickBias or 0)) * scale
            if cx > midX then
                local skipKey = result.item.bankType and (result.item.bankType .. ":" .. result.action) or result.action
                skipActionsTable[skipKey] = true
            else
                local rowKey = result.item.bankType
                    and (result.item.bankType .. ":" .. (result.item.bag or 0) .. ":" .. (result.item.slot or 0))
                    or ((result.item.bag or 0) .. ":" .. (result.item.slot or 0))
                skipItemsTable[rowKey] = true
            end
            EmpireManager[fingerprintKey] = nil
            refreshFunc()
        end
    end)

    return y + 20
end

-------------------------------------------------------------------------------
-- Bank Tab: Refresh Display
-------------------------------------------------------------------------------

function EmpireManager:RefreshBankTriageDisplay(forceRescan)
    if self._triageBulkOperating then
        return
    end
    -- forceRescan must override the in-flight guard: a snapshot completion may
    -- have silently cancelled a manual scan via CancelAsyncScan, leaving the
    -- flag stuck true. Clearing here also ensures CancelAsyncScan below starts
    -- clean.
    if self._bankTriageScanning and not forceRescan then
        return
    end
    self._bankTriageScanning = false
    local f = self.triageFrame
    if not f then
        return
    end
    local activeTab = self._triageActiveTab
    if activeTab ~= "bank" and activeTab ~= "warband" and activeTab ~= "guildbank" then
        return
    end

    if forceRescan then
        self._triageBankBuilt = false
    end

    local savedOffset = 0
    if f and f.ScrollFrame then
        savedOffset = f.ScrollFrame:GetVerticalScroll() or 0
    end

    -- Use cached results only for tab switches (built flag was set on first build)
    if not forceRescan and self._triageBankBuilt and self.bankTriageResults then
        self._bankTriageFingerprint = nil
        self:_BuildBankTriageUI(self.bankTriageResults, savedOffset)
        return
    end

    self:CancelAsyncScan()
    self._bankTriageScanning = true
    self._triageTabLocked = true
    self._bankTriageFingerprint = nil
    self._triageBankBuilt = false
    self:_SetAllTriageActionsLocked(true)

    -- Show "Scanning..." immediately
    self:_ReleaseTabWidgets("bank")
    LayoutSummaryChips(f.SummaryBar, {})
    f.SummaryBar.SummaryLabel:Show()
    f.SummaryBar.SummaryLabel:SetText("|cffffffffScanning bank...|r")

    self:RunBankTriageAsync(function(results)
        self._bankTriageScanning = false
        self:_SetAllTriageActionsLocked(false)
        if not self.triageFrame or not self.triageFrame:IsShown() then
            return
        end
        local curTab = self._triageActiveTab
        if curTab ~= "bank" and curTab ~= "warband" and curTab ~= "guildbank" then
            return
        end

        self:_BuildBankTriageUI(results, savedOffset)
    end)
end

-- Separated UI builder so it can be called from the async callback
function EmpireManager:_BuildBankTriageUI(results, savedOffset)
    -- Determine bank type filter based on active tab
    local activeTab = self._triageActiveTab
    local bankTypeFilter
    if activeTab == "bank" then
        bankTypeFilter = "charbank"
    elseif activeTab == "warband" then
        bankTypeFilter = "warbandbank"
    elseif activeTab == "guildbank" then
        bankTypeFilter = "guildbank"
    end

    -- Filter by bank type and session-skipped rows/actions.
    -- Skip key is per-row (bankType:bag:slot), not per-itemID.
    local skippedItems = self.bankTriageSkippedItems or {}
    local skippedActions = self.bankTriageSkippedActions or {}
    local visibleResults = {}
    for _, r in ipairs(results) do
        local actionKey = r.item.bankType and (r.item.bankType .. ":" .. r.action) or r.action
        local rowKey = (r.item.bankType or "") .. ":" .. (r.item.bag or 0) .. ":" .. (r.item.slot or 0)
        if
            (not bankTypeFilter or r.item.bankType == bankTypeFilter)
            and not skippedItems[rowKey]
            and not skippedActions[actionKey]
        then
            visibleResults[#visibleResults + 1] = r
        end
    end

    -- Count by category
    local counts = { [CAT_STASH] = 0, [CAT_TAKEOUT] = 0, [CAT_KEEP] = 0 }
    for _, r in ipairs(visibleResults) do
        counts[r.category] = (counts[r.category] or 0) + 1
    end

    -- Cheap gate: count mismatch → definitely changed, skip the O(N) string build.
    -- Includes itemName so a "" -> populated transition forces a rebuild on the
    -- deferred 1.5s rescan after a cold open.
    local nVisible = #visibleResults
    if nVisible == self._bankTriageFingerprintCount then
        local fp = {}
        for i, r in ipairs(visibleResults) do
            fp[i] = (r.item.itemID or 0)
                .. ":"
                .. (r.category or "")
                .. ":"
                .. (r.item.srcTab or 0)
                .. ":"
                .. (r.item.slot or 0)
                .. ":"
                .. (r.item.itemName or "")
        end
        local fingerprint = table.concat(fp, "|")
        if fingerprint == self._bankTriageFingerprint then
            self:UpdateBankBtnState(counts)
            return
        end
        self._bankTriageFingerprint = fingerprint
    else
        self._bankTriageFingerprint = nil
    end
    self._bankTriageFingerprintCount = nVisible

    GameTooltip:Hide()
    local ff = self.triageFrame

    -- Release previous bank widgets
    self:_ReleaseTabWidgets("bank")

    -- Collect actionable rows (no display cap - native ScrollFrame handles any count)
    local showKeep = EmpireManager._debugShowKeep
    local actionableRows = {}
    for _, r in ipairs(visibleResults) do
        if showKeep or r.category ~= CAT_KEEP then
            actionableRows[#actionableRows + 1] = r
        end
    end

    -- Summary line / jump chips
    local actionable = counts[CAT_STASH] + counts[CAT_TAKEOUT]
    self._bankTriageSectionY = {}
    local function JumpToBankSection(cat)
        local yy = self._bankTriageSectionY and self._bankTriageSectionY[cat]
        if yy then
            ff.ScrollFrame:SetVerticalScroll(math.max(0, yy - 8))
        end
    end
    if actionable == 0 then
        LayoutSummaryChips(ff.SummaryBar, {})
        ff.SummaryBar.SummaryLabel:Show()
        ff.SummaryBar.SummaryLabel:SetText("|cff00cc00All sorted|r")
    else
        local chips = {}
        local info
        if counts[CAT_STASH] > 0 then
            info = CATEGORY_INFO[CAT_STASH]
            chips[#chips + 1] = {
                text = string.format("%d Stash", counts[CAT_STASH]),
                r = info.r,
                g = info.g,
                b = info.b,
                onClick = function()
                    JumpToBankSection(CAT_STASH)
                end,
            }
        end
        if counts[CAT_TAKEOUT] > 0 then
            info = CATEGORY_INFO[CAT_TAKEOUT]
            chips[#chips + 1] = {
                text = string.format("%d Take Out", counts[CAT_TAKEOUT]),
                r = info.r,
                g = info.g,
                b = info.b,
                onClick = function()
                    JumpToBankSection(CAT_TAKEOUT)
                end,
            }
        end
        ff.SummaryBar.SummaryLabel:Hide()
        LayoutSummaryChips(ff.SummaryBar, chips)
    end

    -- Build items into ScrollFrame content
    local sf = ff.ScrollFrame
    local content = sf.Content
    local contentW = sf:GetWidth()
    if not contentW or contentW < 10 then
        C_Timer.After(0, function()
            if ff and ff:IsShown() then
                self._bankTriageFingerprint = nil
                self:_BuildBankTriageUI(results, savedOffset)
            end
        end)
        return
    end
    content:SetWidth(contentW)
    local pooledRows = {}
    local pooledSeps = {}
    local pooledHdrs = {}
    local pooledFs = {}
    self._triagePooledRows = pooledRows
    self._triagePooledSeps = pooledSeps
    self._triagePooledHdrs = pooledHdrs
    self._triagePooledFs = pooledFs

    local function TrackRow(entry)
        pooledRows[#pooledRows + 1] = entry
        return entry
    end
    local function TrackSep(tex)
        pooledSeps[#pooledSeps + 1] = tex
        return tex
    end
    local function TrackHdr(fs)
        pooledHdrs[#pooledHdrs + 1] = fs
        return fs
    end
    local function TrackFs(fs)
        pooledFs[#pooledFs + 1] = fs
        return fs
    end

    local y = 4
    local rowOpts = {
        skipItems = self.bankTriageSkippedItems,
        skipActions = self.bankTriageSkippedActions,
        fingerprintKey = "_bankTriageFingerprint",
        refresh = function()
            self:RefreshBankTriageDisplay()
        end,
    }
    local currentCat = nil

    -- Empty state
    if #actionableRows == 0 then
        local fs = TrackFs(AcquireFs(content))
        fs:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
        fs:SetPoint("RIGHT", content, "RIGHT", -8, 0)
        fs:SetText("|cff00cc00All Bank items are where they belong.|r")
        y = y + 30
        content:SetHeight(y + 10)
        self:UpdateBankBtnState(counts)
        self._triageBankBuilt = true
        self._triageTabLocked = false
        return
    end

    for _, r in ipairs(actionableRows) do
        if r.category ~= currentCat then
            currentCat = r.category
            local catInfo = CATEGORY_INFO[r.category]
            if y > 4 then
                y = y + 12
            end -- gap before next section heading (skip top)
            self._bankTriageSectionY[r.category] = y
            local hdr = TrackHdr(AcquireHeader(content))
            hdr:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
            hdr:SetPoint("TOPRIGHT", content, "TOPRIGHT", -8, -y)
            hdr:SetText(
                string.format("|cff%02x%02x%02x%s|r", catInfo.r * 255, catInfo.g * 255, catInfo.b * 255, catInfo.label)
            )
            local headerCat = r.category
            local headerLabel = catInfo.label
            hdr:SetScript("OnClick", function(_, btn)
                if btn == "RightButton" then
                    self.bankTriageSkippedItems = self.bankTriageSkippedItems or {}
                    for _, res in ipairs(actionableRows) do
                        if res.category == headerCat then
                            local rowKey = (res.item.bankType or "")
                                .. ":"
                                .. (res.item.bag or 0)
                                .. ":"
                                .. (res.item.slot or 0)
                            self.bankTriageSkippedItems[rowKey] = true
                        end
                    end
                    self._bankTriageFingerprint = nil
                    GameTooltip:Hide()
                    self:RefreshBankTriageDisplay(false)
                end
            end)
            hdr:SetScript("OnEnter", function(b)
                GameTooltip:SetOwner(b, "ANCHOR_TOP")
                GameTooltip:AddLine("Right-click: skip all " .. headerLabel .. " items", 1, 1, 1, true)
                GameTooltip:Show()
            end)
            hdr:SetScript("OnLeave", GameTooltip_Hide)
            y = y + 18
            local sep = TrackSep(AcquireSep(content))
            sep:ClearAllPoints()
            sep:SetAtlas("ui-journeys-renown-divider", true)
            sep:SetPoint("TOP", content, "TOP", 0, -y)
            sep:SetVertexColor(catInfo.r, catInfo.g, catInfo.b, 1.0)
            y = y + 12
        end
        y = self:BuildTriageRow(content, y, r, TrackRow, rowOpts)
    end

    content:SetHeight(y + 10)
    sf:SetVerticalScroll(savedOffset or 0)
    self:UpdateBankBtnState(counts)
    self._triageBankBuilt = true
    self._triageTabLocked = false
end

function EmpireManager:UpdateBankBtnState(counts)
    counts = counts or { [CAT_STASH] = 0, [CAT_TAKEOUT] = 0 }
    local reorganizeBtn = self._triageReorganizeBtn
    local takeOutBtn = self._triageTakeOutBtn
    if not reorganizeBtn or not takeOutBtn then
        return
    end

    -- Detect remote bank open (e.g. Distance Inhibitor spell) - item moves won't work
    local remoteBankOpen = self:IsRemoteBankOpen()

    -- For guild bank: check which tabs have withdrawals available.
    -- Items on depleted tabs can't be moved - adjust actionable counts.
    local stashCount = counts[CAT_STASH] or 0
    local takeoutCount = counts[CAT_TAKEOUT] or 0
    local withdrawalWarning = false

    if self:IsGuildBankOpen() and (stashCount > 0 or takeoutCount > 0) then
        -- Build set of tabs with available withdrawals
        local tabsOK = {}
        local numTabs = GetNumGuildBankTabs()
        for tab = 1, numTabs do
            local _, _, _, _, _, remaining = GetGuildBankTabInfo(tab)
            if remaining == -1 or (remaining and remaining > 0) then
                tabsOK[tab] = true
            end
        end

        -- Count only items on tabs with withdrawals
        local results = self.bankTriageResults or {}
        local skipped = self.bankTriageSkippedItems or {}
        local skippedAct = self.bankTriageSkippedActions or {}
        local actionableStash, actionableTakeout = 0, 0
        for _, r in ipairs(results) do
            if r.item.bankType == "guildbank" and not skipped[r.item.itemID] then
                local actionKey = r.item.bankType .. ":" .. (r.action or "")
                if not skippedAct[actionKey] then
                    if r.category == CAT_STASH and tabsOK[r.item.srcTab] then
                        actionableStash = actionableStash + 1
                    elseif r.category == CAT_TAKEOUT and tabsOK[r.item.srcTab] then
                        actionableTakeout = actionableTakeout + 1
                    end
                end
            end
        end

        if actionableStash < stashCount or actionableTakeout < takeoutCount then
            withdrawalWarning = true
        end
        stashCount = actionableStash
        takeoutCount = actionableTakeout
    end

    if remoteBankOpen then
        reorganizeBtn:SetText("Reorganize")
        reorganizeBtn._disabledReason = "Remote bank: moves not supported"
        reorganizeBtn:Disable()
        takeOutBtn:SetText("Take Out")
        takeOutBtn._disabledReason = "Remote bank: moves not supported"
        takeOutBtn:Disable()
    else
        if stashCount > 0 then
            local suffix = withdrawalWarning and "*" or ""
            reorganizeBtn:SetText(string.format("Reorganize (%d%s)", stashCount, suffix))
            reorganizeBtn._disabledReason = nil
            reorganizeBtn:Enable()
        elseif withdrawalWarning and (counts[CAT_STASH] or 0) > 0 then
            reorganizeBtn:SetText("Reorganize")
            reorganizeBtn._disabledReason = "No withdrawals available on these tabs"
            reorganizeBtn:Disable()
        else
            reorganizeBtn:SetText("Reorganize")
            reorganizeBtn._disabledReason = "Nothing to reorganize"
            reorganizeBtn:Disable()
        end

        if takeoutCount > 0 then
            local suffix = withdrawalWarning and "*" or ""
            takeOutBtn:SetText(string.format("Take Out (%d%s)", takeoutCount, suffix))
            takeOutBtn._disabledReason = nil
            takeOutBtn:Enable()
        elseif withdrawalWarning and (counts[CAT_TAKEOUT] or 0) > 0 then
            takeOutBtn:SetText("Take Out")
            takeOutBtn._disabledReason = "No withdrawals available on these tabs"
            takeOutBtn:Disable()
        else
            takeOutBtn:SetText("Take Out")
            takeOutBtn._disabledReason = "Nothing to take out"
            takeOutBtn:Disable()
        end
    end

    -- Always re-enable rescan after a bulk operation completes
    local rescanBtn = self._triageRescanBtn
    if rescanBtn then
        rescanBtn:Enable()
    end
end

-------------------------------------------------------------------------------
-- Vendor Auto-Sell
-------------------------------------------------------------------------------

function EmpireManager:VendorTriageJunk()
    if not MerchantFrame or not MerchantFrame:IsShown() then
        self:ChatMsg("Open a vendor first to sell items", true)
        return
    end

    -- Rescan to get fresh bag/slot positions (items may have moved since last async scan)
    self:RunTriage()

    -- Collect vendor items, partitioned by quality:
    --   autoItems    = junk/common (quality < 2) → sell silently as before
    --   confirmItems = uncommon+   (quality >= 2) → gated behind confirmation dialog
    local skippedItems = self.triageSkippedItems or {}
    local skippedActions = self.triageSkippedActions or {}
    local autoItems = {}
    local confirmItems = {}
    for _, r in ipairs(self.triageResults) do
        local rowKey = (r.item.bag or 0) .. ":" .. (r.item.slot or 0)
        if r.category == CAT_VENDOR and not skippedItems[rowKey] and not skippedActions[r.action] then
            local entry = {
                bag = r.item.bag,
                slot = r.item.slot,
                value = r.item.sellPrice or 0,
                item = r.item,
                action = r.action,
            }
            if (r.item.quality or 0) >= 2 then
                confirmItems[#confirmItems + 1] = entry
            else
                autoItems[#autoItems + 1] = entry
            end
        end
    end

    if #autoItems == 0 and #confirmItems == 0 then
        self:ChatMsg("No vendorable items to sell", true)
        return
    end

    -- Guard against re-entry (button clicked while already selling, or dialog open)
    if self._vendorSelling or self.vendorConfirmFrame then
        return
    end

    -- If quality items present and option enabled, ask for confirmation.
    -- Sell -> auto + confirm; Skip -> auto only; Cancel -> nothing.
    local opts = self.db.global.options or {}
    if #confirmItems > 0 and opts.confirmVendorQuality ~= false then
        self:ShowVendorConfirmDialog(autoItems, confirmItems)
        return
    end

    -- No confirmation needed → sell everything together
    self:_StartVendorSell(autoItems, confirmItems)
end

-- Begin the actual sell loop. autoItems (junk/common) are sold BEFORE confirmItems
-- (uncommon+) intentionally: WoW's buyback queue is FIFO and holds only the last
-- 12 items sold. Selling junk first means quality items sit at the top of the
-- buyback list and remain recoverable if the user realizes a mistake.
function EmpireManager:_StartVendorSell(autoItems, confirmItems)
    if not MerchantFrame or not MerchantFrame:IsShown() then
        self:ChatMsg("Open a vendor first to sell items", true)
        return
    end

    local vendorItems = {}
    for _, e in ipairs(autoItems) do
        vendorItems[#vendorItems + 1] = e
    end
    if confirmItems then
        for _, e in ipairs(confirmItems) do
            vendorItems[#vendorItems + 1] = e
        end
    end

    if #vendorItems == 0 then
        return
    end

    if self._vendorSelling then
        return
    end
    self._vendorSelling = true
    local gen = self:StartBulkOperation()

    local addon = self
    local totalSold = 0
    local goldBefore = GetMoney()
    local maxRetries = 5
    local attempt = 0

    local function finishSelling(message)
        if addon:IsBulkCancelled(gen) then
            return
        end
        if totalSold > 0 then
            local earned = GetMoney() - goldBefore
            addon:Print(string.format("Sold %d items for %s", totalSold, addon:FormatGold(earned)))
            addon:IncrementStat("itemsVendored", totalSold)
            addon:IncrementStat("goldVendored", earned)
        elseif message then
            addon:Print(message)
        end
        addon._vendorSelling = false
        addon._triageBulkOperating = false
        addon:_SetAllTriageActionsLocked(false)
        addon:UpdateVendorBtnState()
        addon:RefreshTriageDisplay(true)
        CheckBagsFull()
    end

    -- Sell remaining items, wait for bags to settle, retry unsold ones
    local function sellBatch()
        if addon:IsBulkCancelled(gen) then
            return
        end
        attempt = attempt + 1
        if not MerchantFrame or not MerchantFrame:IsShown() then
            finishSelling("Merchant closed")
            return
        end

        -- Filter to items still in bags
        local remaining = {}
        for _, item in ipairs(vendorItems) do
            if C_Container.GetContainerItemInfo(item.bag, item.slot) then
                remaining[#remaining + 1] = item
            end
        end

        if #remaining == 0 then
            finishSelling()
            return
        end

        -- Stagger sells: one item per frame to avoid "item is busy" errors
        local idx = 0
        local function sellNext()
            if addon:IsBulkCancelled(gen) then
                return
            end
            idx = idx + 1
            if idx <= #remaining then
                if MerchantFrame and MerchantFrame:IsShown() then
                    C_Container.UseContainerItem(remaining[idx].bag, remaining[idx].slot)
                end
                C_Timer.After(0, sellNext)
            end
        end
        sellNext()

        -- Debounce: wait for bags to settle, then check results. A fallback timer
        -- covers the case where a game confirmation popup (e.g. selling a still-
        -- refundable dungeon drop) blocks a sale so no BAG_UPDATE_DELAYED ever
        -- fires - without it the loop would hang and never refresh the list,
        -- leaving already-sold junk still showing.
        local debounceTimer, fallbackTimer
        local listener = self:AcquireListener()
        local settled = false

        local function settle()
            if settled then
                return
            end
            settled = true
            if debounceTimer then
                debounceTimer:Cancel()
            end
            if fallbackTimer then
                fallbackTimer:Cancel()
            end
            if addon:IsBulkCancelled(gen) then
                return
            end
            addon:ReleaseListener(listener)

            -- Count what sold this round
            local soldThisRound = 0
            for _, item in ipairs(remaining) do
                if not C_Container.GetContainerItemInfo(item.bag, item.slot) then
                    soldThisRound = soldThisRound + 1
                    totalSold = totalSold + 1
                end
            end

            if soldThisRound == 0 then
                -- Nothing moved: either an empty merchant or a popup blocked the
                -- last item(s). Either way, finish and refresh so the list clears.
                finishSelling(totalSold == 0 and "This merchant doesn't buy items" or nil)
            elseif soldThisRound < #remaining and attempt < maxRetries then
                -- Some items were busy - retry the rest
                sellBatch()
            else
                finishSelling()
            end
        end

        local function onBagUpdate()
            if debounceTimer then
                debounceTimer:Cancel()
            end
            debounceTimer = C_Timer.NewTimer(0.5, settle)
        end
        listener:SetScript("OnEvent", onBagUpdate)
        listener:RegisterEvent("BAG_UPDATE_DELAYED")

        -- Fallback: if no bag update arrives (a popup blocked every remaining
        -- sale), force a settle so the operation always completes and refreshes.
        fallbackTimer = C_Timer.NewTimer(2, settle)
    end

    sellBatch()
end

-------------------------------------------------------------------------------
-- Vendor Confirmation Dialog: shown before selling uncommon+ quality items.
-- Sell = vendor everything (auto + quality); Cancel = abort.
-------------------------------------------------------------------------------

function EmpireManager:ShowVendorConfirmDialog(autoItems, confirmItems)
    if self.vendorConfirmFrame then
        self.vendorConfirmFrame:Hide()
        self.vendorConfirmFrame = nil
    end

    local f = EmpireManagerVendorDialog
    if not f then
        -- XML frame missing (defensive) - fall back to selling everything.
        self:_StartVendorSell(autoItems, confirmItems)
        return
    end

    if not f._initialized then
        f:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true,
            tileSize = 32,
            edgeSize = 32,
            insets = { left = 8, right = 8, top = 8, bottom = 8 },
        })
        f:SetBackdropColor(0.06, 0.06, 0.09, 0.95)
        f:RegisterForDrag("LeftButton")
        f.ScrollFrame:SetScrollChild(f.ScrollFrame.Content)
        f._initialized = true
    end

    f.TitleText:SetText("EmpireManager - Confirm Vendor")
    f:SetHeight(320)

    -- Clear previous content
    if f._widgets then
        for _, w in ipairs(f._widgets) do
            if w.Hide then
                w:Hide()
            end
            if w.SetScript then
                pcall(w.SetScript, w, "OnEnter", nil)
                pcall(w.SetScript, w, "OnLeave", nil)
            end
        end
    end
    f._widgets = {}
    local function Track(obj)
        f._widgets[#f._widgets + 1] = obj
        return obj
    end

    local sf = f.ScrollFrame
    local content = sf.Content
    content:SetWidth(sf:GetWidth())

    local y = 8

    -- Header
    local hdr = Track(content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"))
    hdr:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
    local autoCount = #autoItems
    local confirmCount = #confirmItems
    if autoCount > 0 then
        hdr:SetText(
            string.format(
                "|cffffcc00Vendor %d quality item%s?|r  |cff999999(+ %d Junk)|r",
                confirmCount,
                confirmCount == 1 and "" or "s",
                autoCount
            )
        )
    else
        hdr:SetText(
            string.format("|cffffcc00Vendor %d quality item%s?|r", confirmCount, confirmCount == 1 and "" or "s")
        )
    end
    y = y + 26

    -- Warning line
    local warn = Track(content:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
    warn:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
    warn:SetText("|cffff8800These are uncommon or higher quality - check before selling.|r")
    y = y + 22

    y = y + 6 -- spacer

    -- Item list (only the confirm group; junk auto-vendors silently)
    for _, entry in ipairs(confirmItems) do
        local item = entry.item
        local qty = item.stackCount and item.stackCount > 1 and (" x" .. item.stackCount) or ""
        local btn = Track(CreateFrame("Button", nil, content))
        btn:SetSize(content:GetWidth() - 16, 16)
        btn:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
        local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetAllPoints()
        fs:SetJustifyH("LEFT")
        local text = "  " .. (item.itemName or "?") .. qty
        local qc = ITEM_QUALITY_COLORS[item.quality]
        if qc then
            text = qc.hex .. text .. "|r"
        end
        fs:SetText(text)
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT")
            if item.bag and item.slot then
                GameTooltip:SetBagItem(item.bag, item.slot)
            elseif item.itemLink then
                GameTooltip:SetHyperlink(item.itemLink)
            end
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        y = y + 16
    end

    content:SetHeight(y + 10)

    -- Clean up old buttons
    if f._btns then
        for _, btn in ipairs(f._btns) do
            btn:Hide()
        end
    end
    f._btns = {}

    local intentionalClose = false

    local sellBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    sellBtn:SetSize(100, 28)
    sellBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 24, 18)
    sellBtn:SetText("Sell")
    sellBtn:SetScript("OnClick", function()
        intentionalClose = true
        f:Hide()
        self.vendorConfirmFrame = nil
        self:_StartVendorSell(autoItems, confirmItems)
    end)
    f._btns[1] = sellBtn

    local cancelBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    cancelBtn:SetSize(100, 28)
    cancelBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -24, 18)
    cancelBtn:SetText("Cancel")
    cancelBtn:SetScript("OnClick", function()
        intentionalClose = true
        f:Hide()
        self.vendorConfirmFrame = nil
        self:UpdateVendorBtnState()
    end)
    f._btns[2] = cancelBtn

    f.CloseButton:SetScript("OnClick", function()
        if intentionalClose then
            return
        end
        f:Hide()
        self.vendorConfirmFrame = nil
        self:UpdateVendorBtnState()
    end)

    f:Show()
    self.vendorConfirmFrame = f
    self:UpdateVendorBtnState()
end

-------------------------------------------------------------------------------
-- MERCHANT_SHOW Hook: Auto-prompt for vendor junk
-------------------------------------------------------------------------------

function EmpireManager:CountDEItems(results)
    local count = 0
    local links = {}
    for _, r in ipairs(results) do
        if r.action and r.action:find("disenchant") then
            count = count + 1
            local link = r.item and r.item.itemLink
            if link then
                links[#links + 1] = link
            end
        end
    end
    return count, links
end

function EmpireManager:DoAutoRepair()
    if not self.db.global.options.autoRepair then
        return
    end
    if not CanMerchantRepair() then
        return
    end

    local cost, canRepair = GetRepairAllCost()
    if not canRepair or not cost or cost <= 0 then
        return -- nothing needs repair
    end

    -- Prefer guild funds when enabled, available, and within the withdraw limit.
    if self.db.global.options.repairWithGuildFunds and CanGuildBankRepair() then
        local guildLimit = GetGuildBankWithdrawMoney()
        -- GetGuildBankWithdrawMoney returns -1 for unlimited (guild master).
        if guildLimit == -1 or guildLimit >= cost then
            RepairAllItems(true)
            self:IncrementStat("goldRepaired", cost)
            self:ChatMsg(
                string.format("|cff00ff96[Repair]|r Repaired with Guild funds for %s.", self:FormatGold(cost)),
                true
            )
            return
        end
    end

    -- Personal gold: only repair if we can actually afford it.
    if GetMoney() >= cost then
        RepairAllItems(false)
        self:IncrementStat("goldRepaired", cost)
        self:ChatMsg(
            string.format("|cff00ff96[Repair]|r Repaired for %s.", self:FormatGold(cost)),
            true
        )
    else
        self:ChatMsg(
            string.format(
                "|cffff5555[Repair]|r Not enough gold to repair (need %s).",
                self:FormatGold(cost)
            ),
            true
        )
    end
end

function EmpireManager:OnMerchantShow()
    self:DoAutoRepair()

    local function notify(results)
        local counts, vendorValue = self:GetTriageSummary(results)
        local triageOpen = self.triageFrame and self.triageFrame:IsShown()

        if counts[CAT_VENDOR] > 0 then
            self:ChatMsg(
                string.format(
                    "|cff999999[Triage]|r %d vendorable items worth %s",
                    counts[CAT_VENDOR],
                    self:FormatGold(vendorValue)
                )
            )
        end

        local deCount, deLinks = self:CountDEItems(results)
        if deCount > 0 then
            self:ChatMsg(
                string.format(
                    "|cff9966ff[Triage]|r %d items kept for disenchanting: %s",
                    deCount,
                    table.concat(deLinks, " ")
                )
            )
        end

        if self.db.global.options.popupOnVendor and not triageOpen then
            if counts[CAT_VENDOR] > 0 then
                self:ToggleTriageOverlay()
            end
        elseif triageOpen then
            self:RefreshTriageDisplay()
        end

        -- MerchantFrame may not be visible yet (our handler can fire before
        -- Blizzard's ShowUIPanel), so force-update vendor button after a frame.
        if counts[CAT_VENDOR] > 0 and self.triageVendorBtn then
            self.triageVendorBtn._hasVendor = true
            C_Timer.After(0, function()
                self:UpdateVendorBtnState()
            end)
        end
    end

    -- Always run a fresh scan on merchant open - cached results may miss
    -- items picked up since the last scan, causing the popup to not appear.
    self:RunTriageAsync(function(results)
        notify(results)
    end)
end

-------------------------------------------------------------------------------
-- MAIL_SHOW Hook: Inform about routable items
-------------------------------------------------------------------------------

function EmpireManager:OnMailShow()
    local function notify(results)
        local counts = self:GetTriageSummary(results)
        local triageOpen = self.triageFrame and self.triageFrame:IsShown()

        if counts[CAT_ROUTE] > 0 then
            self:ChatMsg(string.format("|cffffcc00[Triage]|r %d items to route", counts[CAT_ROUTE]))
        end

        local deCount, deLinks = self:CountDEItems(results)
        if deCount > 0 then
            self:ChatMsg(
                string.format(
                    "|cff9966ff[Triage]|r %d items kept for disenchanting: %s",
                    deCount,
                    table.concat(deLinks, " ")
                )
            )
        end

        if self.db.global.options.popupOnMailbox and not triageOpen then
            if counts[CAT_ROUTE] > 0 then
                self:ToggleTriageOverlay()
            end
        elseif triageOpen then
            self:RefreshTriageDisplay()
        end
    end

    -- Always run a fresh scan on mailbox open
    self:RunTriageAsync(function(results)
        notify(results)
    end)
end

-------------------------------------------------------------------------------
-- Mail button state (reacts to tab switches)
-------------------------------------------------------------------------------

-- True when MAIL_SHOW has fired and MAIL_CLOSED has not. The mail send APIs
-- (ClearSendMail, ClickSendMailItemButton, SendMail) work whenever this is
-- true - they don't care if Blizzard's MailFrame is visible. TSM hides
-- MailFrame entirely while its own UI is up, so checking MailFrame:IsShown()
-- would incorrectly disable our send flow.
function EmpireManager:IsMailboxOpen()
    return self.mailboxOpen == true
end

function EmpireManager:UpdateMailBtnState()
    local btn = self.triageMailBtn
    if not btn then
        return
    end
    if self._triageActiveTab ~= "bags" or not self:IsMailboxOpen() then
        btn:Hide()
        return
    end
    btn:Show()
    -- Send-tab gate only applies when Blizzard's MailFrame is the active UI.
    -- With TSM (or any addon that hides MailFrame), the SendMail API works
    -- regardless of which tab the player would be on visually.
    local blizzardMailVisible = MailFrame and MailFrame:IsShown()
    local sendTabOpen = (not blizzardMailVisible) or (SendMailFrame and SendMailFrame:IsShown())
    local hasRoute = btn._hasRoute
    local routeCount = btn._routeCount or 0
    if not hasRoute then
        btn:SetText("Mail All Routable")
        btn._disabledReason = "Nothing to route"
        btn:Disable()
    elseif not sendTabOpen then
        btn:SetText("Mail All Routable")
        btn._disabledReason = "Switch to the Send Mail tab"
        btn:Disable()
    elseif self.mailConfirmFrame or self._mailingSending then
        btn:SetText("Mailing...")
        btn._disabledReason = nil
        btn:Disable()
    else
        if routeCount > 0 then
            btn:SetText(string.format("Mail All Routable (%d)", routeCount))
        else
            btn:SetText("Mail All Routable")
        end
        btn._disabledReason = nil
        btn:Enable()
    end
end

-------------------------------------------------------------------------------
-- Vendor button state (reacts to merchant open/close)
-------------------------------------------------------------------------------

function EmpireManager:UpdateVendorBtnState()
    local btn = self.triageVendorBtn
    if not btn then
        return
    end
    local merchantOpen = MerchantFrame and MerchantFrame:IsShown()
    if self._triageActiveTab ~= "bags" or not merchantOpen then
        btn:Hide()
        return
    end
    btn:Show()
    if self._vendorSelling then
        btn:SetText("Selling...")
        btn._disabledReason = nil
        btn:Disable()
        return
    end
    if self.vendorConfirmFrame then
        btn:SetText("Confirm Vendor...")
        btn._disabledReason = nil
        btn:Disable()
        return
    end
    if not btn._hasVendor then
        btn:SetText("Vendor All")
        btn._disabledReason = "Nothing to vendor"
        btn:Disable()
    else
        local vendorCount = btn._vendorCount or 0
        if vendorCount > 0 then
            btn:SetText(string.format("Vendor All (%d)", vendorCount))
        else
            btn:SetText("Vendor All")
        end
        btn._disabledReason = nil
        btn:Enable()
    end
end

-------------------------------------------------------------------------------
-- Mail Routable Items (groups by recipient, sends one mail per destination)
-------------------------------------------------------------------------------

-- The restock floor is protected by classification (RestockProtectWithinFloor keeps
-- whole slots up to the floor); routable slots are entirely surplus, so mailing moves
-- whole stacks - no per-slot splitting here.

function EmpireManager:MailTriageRoutable()
    if not self:IsMailboxOpen() then
        self:ChatMsg("Open a mailbox first to mail routable items", true)
        return
    end

    -- Rescan to get fresh bag/slot positions (items may have moved since last async scan)
    self:RunTriage()

    -- Group routable items by recipient name (respect session skips)
    local skippedItems = self.triageSkippedItems or {}
    local skippedActions = self.triageSkippedActions or {}
    local byRecipient = {}
    for _, r in ipairs(self.triageResults) do
        local rowKey = (r.item.bag or 0) .. ":" .. (r.item.slot or 0)
        if r.category == CAT_ROUTE and not skippedItems[rowKey] and not skippedActions[r.action] then
            local recipient = r.action:match("^Mail to ([^<%(]+)")
            if recipient then
                recipient = strtrim(recipient)
                if not byRecipient[recipient] then
                    byRecipient[recipient] = {}
                end
                byRecipient[recipient][#byRecipient[recipient] + 1] = r.item
            end
        end
    end

    if not next(byRecipient) then
        self:ChatMsg("No routable items with known recipients", true)
        return
    end

    -- Sort recipients alphabetically, then start per-character confirmation
    local recipients = {}
    for recipient in pairs(byRecipient) do
        recipients[#recipients + 1] = recipient
    end
    table.sort(recipients)

    -- Lock all triage controls; user closes the mailbox or per-recipient dialog to cancel.
    self:StartBulkOperation()

    self:ShowMailPerCharDialog(byRecipient, recipients, 1, 0)
end

-------------------------------------------------------------------------------
-- Per-Character Mail Confirmation Dialog
-------------------------------------------------------------------------------

function EmpireManager:ShowMailPerCharDialog(byRecipient, recipients, index, totalSent)
    -- Close existing dialog
    if self.mailConfirmFrame then
        self.mailConfirmFrame:Hide()
        self.mailConfirmFrame = nil
    end

    local function reportMailed()
        -- Release the bulk lock applied by MailTriageRoutable. Safe to call when
        -- _triageBulkOperating is already false (e.g. EM_MAIL_CLOSED aborted).
        self._triageBulkOperating = false
        self:_SetAllTriageActionsLocked(false)
        if totalSent > 0 then
            self:ChatMsg(string.format("|cffffcc00[Triage]|r Mailed %d items", totalSent))
            -- Drop the cache and rescan after the last send's bag update settles, so
            -- the list reflects post-mail bags (not the stale pre-mail rows).
            self._bagsDirty = true
            self.triageResults = nil
            C_Timer.After(0.5, function()
                self._triageBulkOperating = false -- ensure the refresh isn't bailed
                self._bagsDirty = true
                self.triageResults = nil
                self:RefreshTriageDisplay(true)
            end)
        end
        CheckBagsFull()
    end

    -- Mailbox closed mid-flow (walked away between recipients): never re-show the
    -- Send dialog or attempt another send. Finalize what we already sent and bail.
    if not self:IsMailboxOpen() then
        self:UpdateMailBtnState()
        reportMailed()
        return
    end

    -- All recipients processed
    if index > #recipients then
        self:UpdateMailBtnState()
        reportMailed()
        return
    end

    local recipient = recipients[index]
    local items = byRecipient[recipient]
    local count = #items

    local f = EmpireManagerMailDialog
    if not f._initialized then
        f:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true,
            tileSize = 32,
            edgeSize = 32,
            insets = { left = 8, right = 8, top = 8, bottom = 8 },
        })
        f:SetBackdropColor(0.06, 0.06, 0.09, 0.95)
        f:RegisterForDrag("LeftButton")
        f.ScrollFrame:SetScrollChild(f.ScrollFrame.Content)
        f._initialized = true
    end

    f.TitleText:SetText("EmpireManager - Mail")
    f:SetHeight(400)

    -- Look up realm + class from registry (class drives the name color).
    -- Cross-realm warbound recipients arrive as "Name-Realm" (the SendMail
    -- address form); split off the realm so the registry name match still works.
    local lookupName, addrRealm = recipient, nil
    local dashName, dashRealm = recipient:match("^(.+)%-(.+)$")
    if dashName then
        lookupName, addrRealm = dashName, dashRealm
    end
    local recipientRealm, recipientClass = nil, nil
    for _, e in pairs(self.db.global.registry) do
        if e.name == lookupName and (not addrRealm or e.realm == addrRealm) then
            recipientRealm = e.realm
            recipientClass = e.class
            break
        end
    end
    local displayName = recipientRealm and recipientRealm ~= "" and (lookupName .. " - " .. recipientRealm)
        or recipient
    local cc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[recipientClass]
    local displayNameColored = cc
            and cc:WrapTextInColorCode(displayName)
        or ("|cffffffff" .. displayName .. "|r")

    -- Clear previous content
    if f._widgets then
        for _, w in ipairs(f._widgets) do
            if w.Hide then
                w:Hide()
            end
            if w.SetScript then
                pcall(w.SetScript, w, "OnEnter", nil)
                pcall(w.SetScript, w, "OnLeave", nil)
            end
        end
    end
    f._widgets = {}
    local function Track(obj)
        f._widgets[#f._widgets + 1] = obj
        return obj
    end

    local sf = f.ScrollFrame
    local content = sf.Content
    content:SetWidth(sf:GetWidth())

    local y = 8

    -- Line 1: "Sending Mail 1 of x"
    local hdr = Track(content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"))
    hdr:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
    hdr:SetText(string.format("|cffffcc00Sending Mail %d of %d|r", index, #recipients))
    y = y + 26

    -- Line 2: "To: CharName - Realm"
    local toFs = Track(content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"))
    toFs:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
    toFs:SetText("|cffffffffTo:  |r" .. displayNameColored)
    y = y + 26

    y = y + 6 -- spacer

    -- Subheading: item count
    local subFs = Track(content:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
    subFs:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
    subFs:SetText(string.format("%d %s:", count, count == 1 and "item" or "items"))
    y = y + 18

    y = y + 4 -- spacer

    -- Item list
    for _, item in ipairs(items) do
        -- Show the amount actually mailed: routeCount (surplus above a restock floor)
        -- when set, else the whole stack.
        local shownCount = item.routeCount or item.stackCount or 0
        local qty = shownCount > 1 and (" x" .. shownCount) or ""
        local btn = Track(CreateFrame("Button", nil, content))
        btn:SetSize(content:GetWidth() - 16, 16)
        btn:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
        local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetAllPoints()
        fs:SetJustifyH("LEFT")
        local text = "  " .. (item.itemName or "?") .. qty
        local qc = ITEM_QUALITY_COLORS[item.quality]
        if qc then
            text = qc.hex .. text .. "|r"
        end
        fs:SetText(text)
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT")
            if item.bag and item.slot then
                GameTooltip:SetBagItem(item.bag, item.slot)
            elseif item.itemLink then
                GameTooltip:SetHyperlink(item.itemLink)
            end
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        y = y + 16
    end

    content:SetHeight(y + 10)

    -- Clean up old buttons
    if f._btns then
        for _, btn in ipairs(f._btns) do
            btn:Hide()
        end
    end
    f._btns = {}

    -- Bottom buttons: Send | Skip | Cancel
    local intentionalClose = false

    local sendBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    sendBtn:SetSize(100, 28)
    sendBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 14)
    sendBtn:SetText("Send")
    sendBtn:SetScript("OnClick", function()
        intentionalClose = true
        f:Hide()
        self.mailConfirmFrame = nil
        -- Guard: mailbox may have closed while the dialog was up (walked away).
        if not self:IsMailboxOpen() then
            self:UpdateMailBtnState()
            reportMailed()
            return
        end
        self._mailingSending = true
        self:UpdateMailBtnState()
        self:ExecuteMailForRecipient(recipient, items, function(sent)
            self._mailingSending = nil
            self:ShowMailPerCharDialog(byRecipient, recipients, index + 1, totalSent + sent)
        end)
    end)
    f._btns[1] = sendBtn

    local skipBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    skipBtn:SetSize(100, 28)
    skipBtn:SetPoint("BOTTOM", f, "BOTTOM", 0, 14)
    skipBtn:SetText("Skip")
    skipBtn:SetScript("OnClick", function()
        intentionalClose = true
        f:Hide()
        self.mailConfirmFrame = nil
        self:ShowMailPerCharDialog(byRecipient, recipients, index + 1, totalSent)
    end)
    f._btns[2] = skipBtn

    local cancelBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    cancelBtn:SetSize(100, 28)
    cancelBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 14)
    cancelBtn:SetText("Cancel")
    cancelBtn:SetScript("OnClick", function()
        intentionalClose = true
        f:Hide()
        self.mailConfirmFrame = nil
        self:UpdateMailBtnState()
        reportMailed()
    end)
    f._btns[3] = cancelBtn

    f.CloseButton:SetScript("OnClick", function()
        if intentionalClose then
            return
        end
        f:Hide()
        self.mailConfirmFrame = nil
        self:UpdateMailBtnState()
        reportMailed()
    end)

    f:Show()
    self.mailConfirmFrame = f
    self:UpdateMailBtnState()
end

-------------------------------------------------------------------------------
-- Restock floor mail prep: consolidate -> split off the floor -> callback.
-- For each floored itemID: merge all its bag stacks (cross-bag; a reagent-bag stack
-- can only merge onto another reagent-bag stack), then split off exactly `floor` into
-- its own stack. Result: [floor stack] + clean full surplus stacks. One settled move
-- at a time (waits BAG_UPDATE_DELAYED), so no split race and no per-scan churn.
-------------------------------------------------------------------------------
function EmpireManager:PrepMailFloors(flooredIDs, onDone)
    local ids = {}
    for id in pairs(flooredIDs) do
        ids[#ids + 1] = id
    end

    -- All bag stacks of an itemID: { {bag, slot, count}, ... }, skipping locked.
    local function stacksOf(id)
        local out = {}
        for bag = 0, 5 do
            local n = C_Container.GetContainerNumSlots(bag) or 0
            for slot = 1, n do
                local info = C_Container.GetContainerItemInfo(bag, slot)
                if info and info.itemID == id and not info.isLocked then
                    out[#out + 1] = { bag = bag, slot = slot, count = info.stackCount or 1 }
                end
            end
        end
        return out
    end

    -- Run `fn` after the next BAG_UPDATE_DELAYED settles (fallback timer if it doesn't).
    local function afterSettle(fn)
        local listener = self:AcquireListener()
        local fired = false
        local function go()
            if fired then
                return
            end
            fired = true
            listener:UnregisterAllEvents()
            self:ReleaseListener(listener)
            fn()
        end
        listener:SetScript("OnEvent", function()
            listener:UnregisterAllEvents()
            C_Timer.After(0.05, go)
        end)
        listener:RegisterEvent("BAG_UPDATE_DELAYED")
        C_Timer.NewTimer(1.0, go)
    end

    local idIdx = 0
    local nextId -- fwd

    -- Consolidation lives on EmpireManager:ConsolidateBagStacksFor (Restock.lua),
    -- shared with the pre-Triage-scan step so both paths use identical logic.

    -- Split off exactly `floor` of `id` into its own stack (kept), leaving surplus as
    -- whole stacks. Walk consolidated stacks; the one crossing the floor is split.
    -- Fast path: if a stack already equals the floor exactly, it IS the floor - no
    -- carve needed. Consolidate preserves such stacks (skips them from the merge
    -- pool), so this is the common case after a settled prep pass.
    local function carveFloor(id, floor, after)
        for _, s in ipairs(stacksOf(id)) do
            if s.count == floor then
                after()
                return
            end
        end
        local running = 0
        for _, s in ipairs(stacksOf(id)) do
            if running + s.count == floor then
                after() -- already aligned
                return
            elseif running + s.count > floor then
                local keep = floor - running
                -- free slot: source bag first, then any bag (reagent stays reagent).
                local order = { s.bag }
                for _, b in ipairs({ 0, 1, 2, 3, 4, 5 }) do
                    if b ~= s.bag then
                        order[#order + 1] = b
                    end
                end
                local fb, fs
                for _, bag in ipairs(order) do
                    local n = C_Container.GetContainerNumSlots(bag) or 0
                    for slot = 1, n do
                        if not C_Container.GetContainerItemInfo(bag, slot) then
                            fb, fs = bag, slot
                            break
                        end
                    end
                    if fb then
                        break
                    end
                end
                if keep > 0 and fb then
                    -- Split the KEEP portion into a fresh slot so the floor is its own
                    -- clean stack; the surplus stays where it was.
                    ClearCursor()
                    C_Container.SplitContainerItem(s.bag, s.slot, keep)
                    C_Container.PickupContainerItem(fb, fs)
                    ClearCursor()
                    afterSettle(after)
                    return
                end
                after()
                return
            end
            running = running + s.count
        end
        after() -- floor >= total: nothing to carve
    end

    nextId = function()
        idIdx = idIdx + 1
        local id = ids[idIdx]
        if not id then
            onDone()
            return
        end
        local floor = self:RestockFloorTarget(id, "bags")
        if floor <= 0 then
            nextId()
            return
        end
        self:ConsolidateBagStacksFor(id, function()
            carveFloor(id, floor, nextId)
        end)
    end
    nextId()
end

-------------------------------------------------------------------------------
-- Send mail for a single recipient (batches if > ATTACHMENTS_MAX_SEND)
-------------------------------------------------------------------------------

function EmpireManager:ExecuteMailForRecipient(recipient, items, onComplete)
    if not self:IsMailboxOpen() then
        self:ChatMsg("Mailbox closed before sending")
        if onComplete then
            onComplete(0)
        end
        return
    end

    -- Restock floor prep (once per send): for each floored item that has a surplus,
    -- CONSOLIDATE its stacks, then SPLIT off exactly the floor to keep, so what remains
    -- to mail is clean whole stacks and the floor is one stack left behind. Done as a
    -- settled step BEFORE mailing (SplitContainerItem is async; doing it inline in the
    -- attach loop races and mails the whole stack). After prep we re-run and mail whole.
    if not self._mailFloorPrepDone then
        -- Which itemIDs here straddle their floor (surplus present)?
        local floored = {}
        for _, item in ipairs(items) do
            if item.routeCount and item.itemID then
                floored[item.itemID] = true
            end
        end
        if next(floored) then
            self._mailFloorPrepDone = true
            self:PrepMailFloors(floored, function()
                -- Re-run after prep. Bags now: [floor stack] + [clean surplus stacks].
                -- Keep _mailFloorPrepDone = true so the re-run SKIPS prep and goes
                -- straight to send (setting it false here re-entered prep -> endless
                -- consolidate/split loop). The floor is now a Keep stack; only surplus
                -- routes, mailed whole. The flag is reset AFTER this recipient sends.
                self:RunTriage()
                local fresh = {}
                for _, r in ipairs(self.triageResults) do
                    if r.category == CAT_ROUTE then
                        local rc = r.action and r.action:match("^Mail to ([^<%(]+)")
                        if rc and strtrim(rc) == recipient then
                            fresh[#fresh + 1] = r.item
                        end
                    end
                end
                self:ExecuteMailForRecipient(recipient, fresh, onComplete)
            end)
            return
        end
    end
    self._mailFloorPrepDone = nil -- reset for the next recipient/run

    -- Filter to only mailable (unlocked, still present) items
    local mailable = {}
    for _, item in ipairs(items) do
        local loc = ItemLocation:CreateFromBagAndSlot(item.bag, item.slot)
        if loc and loc:IsValid() and C_Item.DoesItemExist(loc) and not C_Item.IsLocked(loc) then
            mailable[#mailable + 1] = item
        end
    end

    if #mailable == 0 then
        self:ChatMsg("|cffffcc00[Triage]|r No mailable items (all locked or missing)")
        if onComplete then
            onComplete(0)
        end
        return
    end

    -- Build batches (max ATTACHMENTS_MAX_SEND per mail)
    local batches = {}
    local batch = {}
    for _, item in ipairs(mailable) do
        batch[#batch + 1] = item
        if #batch >= ATTACHMENTS_MAX_SEND then
            batches[#batches + 1] = batch
            batch = {}
        end
    end
    if #batch > 0 then
        batches[#batches + 1] = batch
    end

    local totalSent = 0
    local MAIL_TIMEOUT = 5 -- seconds before giving up on server response

    local function SendNextBatch(batchIndex)
        if batchIndex > #batches then
            if onComplete then
                onComplete(totalSent)
            end
            return
        end

        if not self:IsMailboxOpen() then
            self:ChatMsg(
                string.format("|cffffcc00[Triage]|r Mailbox closed, mailed %d items before interruption", totalSent)
            )
            if onComplete then
                onComplete(totalSent)
            end
            return
        end

        local b = batches[batchIndex]
        ClearSendMail()
        SendMailNameEditBox:SetText(recipient)
        SendMailSubjectEditBox:SetText("EmpireManager Triage")

        -- Attach items via pickup + ClickSendMailItemButton. This pattern
        -- works whether or not SendMailFrame is visible (TSM and other mail
        -- replacement addons hide it). UseContainerItem only attaches when
        -- the Blizzard mail UI is the active frame; without that it no-ops
        -- and we'd silently send empty mail.
        local attached = 0
        for _, item in ipairs(b) do
            local loc = ItemLocation:CreateFromBagAndSlot(item.bag, item.slot)
            if loc and loc:IsValid() and C_Item.DoesItemExist(loc) and not C_Item.IsLocked(loc) then
                ClearCursor()
                -- Honor routeCount when a restock floor straddler survived PrepMailFloors
                -- (scan order can re-flag the surplus slot as a straddler even after
                -- carve). Split off exactly the surplus, else whole-stack pickup.
                local sInfo = C_Container.GetContainerItemInfo(item.bag, item.slot)
                local have = sInfo and sInfo.stackCount or 0
                local send = item.routeCount or have
                if send > 0 and send < have then
                    C_Container.SplitContainerItem(item.bag, item.slot, send)
                else
                    C_Container.PickupContainerItem(item.bag, item.slot)
                end
                if CursorHasItem() then
                    ClickSendMailItemButton()
                    if CursorHasItem() then
                        -- Attach refused (mailbox closed, attachment slots full,
                        -- bound item, etc). Drop the item back and stop counting it.
                        ClearCursor()
                    else
                        attached = attached + 1
                    end
                end
            end
        end

        if attached == 0 then
            -- Nothing attached, skip to next batch
            SendNextBatch(batchIndex + 1)
            return
        end

        -- Wait for MAIL_SUCCESS or MAIL_FAILED before proceeding
        local handled = false
        local eventFrame = self:AcquireListener()

        local function Cleanup()
            if handled then
                return
            end
            handled = true
            self:ReleaseListener(eventFrame)
        end

        local fallbackTimer = C_Timer.NewTimer(MAIL_TIMEOUT, function()
            if handled then
                return
            end
            Cleanup()
            self:ChatMsg("|cffffcc00[Triage]|r Mail send timed out, skipping remaining batches")
            if onComplete then
                onComplete(totalSent)
            end
        end)

        eventFrame:RegisterEvent("MAIL_SUCCESS")
        eventFrame:RegisterEvent("MAIL_FAILED")
        eventFrame:SetScript("OnEvent", function(_, event)
            if handled then
                return
            end
            Cleanup()
            fallbackTimer:Cancel()

            if event == "MAIL_SUCCESS" then
                totalSent = totalSent + attached
                self:IncrementStat("itemsMailed", attached)
                -- Brief delay for server to settle before next batch
                C_Timer.After(0.3, function()
                    SendNextBatch(batchIndex + 1)
                end)
            else
                self:ChatMsg(
                    string.format(
                        "|cffffcc00[Triage]|r Mail to %s failed, mailed %d items before failure",
                        recipient,
                        totalSent
                    )
                )
                if onComplete then
                    onComplete(totalSent)
                end
            end
        end)

        -- Final guard: verify at least one attachment slot is populated.
        -- Belt-and-braces against future cases where the attach loop silently
        -- fails (mail UI replaced, slot blocked, etc).
        local hasAnyAttachment = false
        for i = 1, ATTACHMENTS_MAX_SEND do
            if GetSendMailItem(i) then
                hasAnyAttachment = true
                break
            end
        end
        if not hasAnyAttachment then
            Cleanup()
            fallbackTimer:Cancel()
            self:ChatMsg(
                string.format(
                    "|cffffcc00[Triage]|r Mail to %s aborted: no items attached (mail UI may have refused the attach)",
                    recipient
                )
            )
            if onComplete then
                onComplete(totalSent)
            end
            return
        end

        SendMail(recipient, "EmpireManager Triage", "")
    end

    SendNextBatch(1)
end

-------------------------------------------------------------------------------
-- Bank Deposit: Move STASH items into bank containers
-------------------------------------------------------------------------------

function EmpireManager:IsBankOpen()
    return self.bankIsOpen or self.guildBankIsOpen
end

function EmpireManager:IsGuildBankOpen()
    return self.guildBankIsOpen or false
end

function EmpireManager:IsWarbandBankOnly()
    if not self.bankIsOpen then
        return false
    end
    return C_PlayerInteractionManager
        and C_PlayerInteractionManager.IsInteractingWithNpcOfType
        and C_PlayerInteractionManager.IsInteractingWithNpcOfType(Enum.PlayerInteractionType.AccountBanker)
end

function EmpireManager:IsRemoteBankOpen()
    return self:IsWarbandBankOnly() and not UnitExists("npc")
end

-- Count STASH items from bag triage that can actually be deposited to a currently open bank
function EmpireManager:CountDepositableStash()
    local results = self.triageResults
    if not results then
        return 0
    end
    local bankOpen = self.bankIsOpen
    local warbandOnly = self:IsWarbandBankOnly()
    local guildOpen = self.guildBankIsOpen
    local warbandAccessible = bankOpen
    local skippedItems = self.triageSkippedItems or {}
    local skippedActions = self.triageSkippedActions or {}
    local count = 0
    for _, r in ipairs(results) do
        local rowKey = (r.item.bag or 0) .. ":" .. (r.item.slot or 0)
        if
            r.category == CAT_STASH
            and r.routing
            and not skippedItems[rowKey]
            and not skippedActions[r.action]
        then
            local dt = r.routing.destType
            if dt == "warbandbank" and warbandAccessible then
                count = count + 1
            elseif dt == "charbank" and bankOpen and not warbandOnly then
                count = count + 1
            elseif dt == "guildbank" and guildOpen then
                count = count + 1
            end
        end
    end
    return count
end

-- Resolve a routing's destination to an address (container ID or guild bank tab).
-- Supports multi-tab (destTabs array) and guild bank.
-- For charbank/warbandbank: returns C_Container bag IDs.
-- For guildbank: returns guild bank tab numbers.
-- Returns an ordered array of candidate addresses, starting from the currently viewed tab.
local function ResolveCandidateAddresses(routing)
    if not routing then
        return {}
    end

    local ctx = MoveContexts[routing.destType]
    if not ctx then
        return {}
    end

    -- Build candidate tab list
    local candidates
    if routing.destTabs and #routing.destTabs > 0 then
        candidates = routing.destTabs
    else
        -- No specific tabs: start from the currently viewed tab, rotate through all
        local lo, hi = ctx.TabRange()
        local startTab = lo
        if
            routing.destType == "warbandbank"
            and AccountBankPanel
            and AccountBankPanel:IsShown()
            and AccountBankPanel.selectedTab
        then
            local sel = AccountBankPanel.selectedTab
            if sel >= lo and sel <= hi then
                startTab = sel
            end
        elseif
            routing.destType == "charbank"
            and CharacterBankPanel
            and CharacterBankPanel:IsShown()
            and CharacterBankPanel.selectedTab
        then
            local sel = CharacterBankPanel.selectedTab
            if sel >= lo and sel <= hi then
                startTab = sel
            end
        end
        candidates = {}
        local count = hi - lo + 1
        for i = 0, count - 1 do
            candidates[#candidates + 1] = ((startTab - lo + i) % count) + lo
        end
    end

    -- Convert tab numbers to addresses, skip tabs with 0 slots
    local addrs = {}
    for _, tabNum in ipairs(candidates) do
        local addr = ctx.ResolveAddress(tabNum)
        local numSlots = ctx.GetNumSlots(addr)
        if numSlots and numSlots > 0 then
            addrs[#addrs + 1] = addr
        end
    end
    return addrs
end

-- Lightweight capacity re-snapshot after deposit (no triage re-check or misplaced scan)
function EmpireManager:SnapshotOpenBankCapacity()
    if not self:IsBankOpen() then
        return
    end

    local guid = self.playerGUID
    local cap = self.db.global.storageCapacity

    -- Character bank tabs (6-11)
    if self.bankIsOpen then
        if not cap.charbank[guid] then
            cap.charbank[guid] = {}
        end
        for tabIdx = 1, 6 do
            local bag = 5 + tabIdx
            local numSlots = C_Container.GetContainerNumSlots(bag)
            if numSlots and numSlots > 0 then
                local used = 0
                for slot = 1, numSlots do
                    if C_Container.GetContainerItemInfo(bag, slot) then
                        used = used + 1
                    end
                end
                cap.charbank[guid][tabIdx] = { total = numSlots, used = used }
            end
        end

        -- Update freeBankSlots/totalBankSlots on the registry entry
        local entry = self.db.global.registry[guid]
        if entry and cap.charbank[guid] then
            local freeBank, totalBank = 0, 0
            for _, tabData in pairs(cap.charbank[guid]) do
                if type(tabData) == "table" then
                    local t = tabData.total or 0
                    freeBank = freeBank + t - (tabData.used or 0)
                    totalBank = totalBank + t
                end
            end
            entry.freeBankSlots = freeBank
            entry.totalBankSlots = totalBank
        end

        -- Warband bank tabs (containers 12-16)
        local warbandIdx = 0
        for bag = 12, 16 do
            local numSlots = C_Container.GetContainerNumSlots(bag)
            if numSlots and numSlots > 0 then
                warbandIdx = warbandIdx + 1
                local used = 0
                for slot = 1, numSlots do
                    if C_Container.GetContainerItemInfo(bag, slot) then
                        used = used + 1
                    end
                end
                cap.warbandbank[warbandIdx] = { total = numSlots, used = used }
            end
        end
    end

    -- Guild bank tabs
    if self.guildBankIsOpen then
        local guildName, _, _, guildRealm = GetGuildInfo("player")
        local guildKey = self:GuildKey(guildName, guildRealm or GetRealmName())
        if guildKey then
            if not cap.guildbank[guildKey] then
                cap.guildbank[guildKey] = {}
            end
            local numTabs = GetNumGuildBankTabs()
            for tab = 1, numTabs do
                local _, _, _, _, numSlots = GetGuildBankTabInfo(tab)
                if not numSlots or numSlots <= 0 or numSlots > 98 then
                    numSlots = 98
                end
                if numSlots > 0 then
                    local used = 0
                    for slot = 1, numSlots do
                        local link = GetGuildBankItemLink(tab, slot)
                        if link then
                            used = used + 1
                        end
                    end
                    cap.guildbank[guildKey][tab] = { total = numSlots, used = used }
                end
            end
        end
    end
end

function EmpireManager:BankTriageStash()
    if not self:IsBankOpen() then
        self:ChatMsg("Open a bank first to deposit stash items", true)
        return
    end
    if InCombatLockdown() then
        self:ChatMsg("Cannot deposit items during combat", true)
        return
    end

    local gen = self:StartBulkOperation()

    -- Disable deposit button while operation is in progress
    if self.triageDepositBtn then
        self.triageDepositBtn:SetText("Depositing...")
        self.triageDepositBtn._disabledReason = nil
        self.triageDepositBtn:Disable()
    end

    -- Restack bags first to consolidate partial stacks, then deposit.
    -- After restack, wait for one more BAG_UPDATE_DELAYED to ensure bag data is current.
    self:ChatVerbose("|cff4d99ff[Triage]|r Restacking bags.")
    self:RestackBags(function()
        if self:IsBulkCancelled(gen) then
            return
        end
        local listener = self:AcquireListener()
        local fallback
        local function Proceed()
            self:ReleaseListener(listener)
            if fallback then
                fallback:Cancel()
            end
            if self:IsBulkCancelled(gen) then
                return
            end
            self:BankTriageStashAfterRestack(gen)
        end
        listener:SetScript("OnEvent", function()
            listener:UnregisterAllEvents()
            Proceed()
        end)
        listener:RegisterEvent("BAG_UPDATE_DELAYED")
        fallback = C_Timer.NewTimer(1.0, function()
            listener:UnregisterAllEvents()
            Proceed()
        end)
    end)
end

function EmpireManager:RestoreDepositBtn()
    self:UpdateDepositBtnState()
end

function EmpireManager:BankTriageStashAfterRestack(gen)
    if not self:IsBankOpen() then
        self:ChatMsg("Bank closed during restack")
        self._triageBulkOperating = false
        self:RestoreDepositBtn()
        return
    end

    -- Rescan to get fresh bag/slot positions (items may have moved since last async scan)
    self:RunTriage()

    -- Split move lists by bank type (respect session skips).
    -- Unique items are no longer pre-skipped - they're attempted like anything
    -- else; if the bank rejects them (already at limit), the move silently
    -- fails and the per-path verification counts it toward the final "(N failed)"
    -- chat line. The item then remains in bags and re-appears in the next scan.
    local skippedItems = self.triageSkippedItems or {}
    local skippedActions = self.triageSkippedActions or {}
    local movesByType = { charbank = {}, warbandbank = {}, guildbank = {} }
    -- Track every move we attempt so we can name the failures at FinishAll
    -- (one entry per (bag, slot, itemID); itemLink kept for chat output).
    local attemptedMoves = {}
    for _, r in ipairs(self.triageResults) do
        local rowKey = (r.item.bag or 0) .. ":" .. (r.item.slot or 0)
        if
            r.category == CAT_STASH
            and r.routing
            and not skippedItems[rowKey]
            and not skippedActions[r.action]
        then
            local dType = r.routing.destType
            if movesByType[dType] then
                local move = {
                    srcBag = r.item.bag,
                    srcSlot = r.item.slot,
                    itemID = r.item.itemID,
                    itemName = r.item.itemName or "?",
                    itemLink = r.item.itemLink,
                    routing = r.routing,
                    routeCount = r.item.routeCount, -- surplus above a restock floor, or nil
                }
                movesByType[dType][#movesByType[dType] + 1] = move
                attemptedMoves[#attemptedMoves + 1] = move
            end
        end
    end

    -- Only count items for bank types that are actually accessible right now
    local regularBankOpen = self.bankIsOpen
    local warbandOnly = self:IsWarbandBankOnly()
    local guildBankOpen = self:IsGuildBankOpen()
    local warbandAccessible = regularBankOpen

    -- Charbank not accessible when only warband bank is open (Distance Inhibitor)
    if warbandOnly then
        movesByType.charbank = {}
    end

    local totalItems = 0
    if regularBankOpen then
        totalItems = totalItems + #movesByType.charbank
    end
    if warbandAccessible then
        totalItems = totalItems + #movesByType.warbandbank
    end
    if guildBankOpen then
        totalItems = totalItems + #movesByType.guildbank
    end
    if totalItems == 0 then
        self:ChatMsg("|cff4d99ff[Triage]|r No depositable stash items found")
        self._triageBulkOperating = false
        self:RestoreDepositBtn()
        return
    end

    -- Preflight: if every destination type we have moves for has zero capacity
    -- (e.g. visiting warband bank with no tabs purchased), bail with one line
    -- instead of attempting 24 doomed moves and dumping a per-item failure list.
    local function bagsHaveSlots(firstBag, lastBag)
        for bag = firstBag, lastBag do
            if (C_Container.GetContainerNumSlots(bag) or 0) > 0 then
                return true
            end
        end
        return false
    end
    local destHasCapacity = {
        charbank = regularBankOpen and not warbandOnly and bagsHaveSlots(6, 11),
        warbandbank = warbandAccessible and bagsHaveSlots(12, 16),
        -- Trust guild-bank-open: if it's open at all there's at least one tab.
        guildbank = guildBankOpen,
    }
    local anyCapacity = false
    for dt, moves in pairs(movesByType) do
        if #moves > 0 and destHasCapacity[dt] then
            anyCapacity = true
            break
        end
    end
    if not anyCapacity then
        local missing = {}
        if #movesByType.warbandbank > 0 and not destHasCapacity.warbandbank then
            missing[#missing + 1] = "Warband Bank (no tabs purchased)"
        end
        if #movesByType.charbank > 0 and not destHasCapacity.charbank then
            missing[#missing + 1] = "Character Bank (no tabs purchased)"
        end
        local detail = #missing > 0 and (" - " .. table.concat(missing, ", ")) or ""
        self:ChatMsg("|cff4d99ff[Triage]|r No accessible storage" .. detail)
        self._triageBulkOperating = false
        self:RestoreDepositBtn()
        return
    end

    -- Build destination label for the summary message
    local destParts = {}
    if regularBankOpen and #movesByType.charbank > 0 then
        destParts[#destParts + 1] = "Character Bank"
    end
    if warbandAccessible and #movesByType.warbandbank > 0 then
        destParts[#destParts + 1] = "Warband Bank"
    end
    if guildBankOpen and #movesByType.guildbank > 0 then
        destParts[#destParts + 1] = "Guild Bank"
    end
    local destLabel = #destParts > 0 and (" to " .. table.concat(destParts, " & ")) or ""
    self:ChatVerbose(
        string.format(
            "|cff4d99ff[Triage]|r Depositing %d item%s%s...",
            totalItems,
            totalItems == 1 and "" or "s",
            destLabel
        )
    )

    -- Shared state across all phases
    local totalMoved = 0
    local skippedNotAllowed = 0
    local skippedByType = {} -- destType -> count (for accurate per-bank messaging)
    local fullTabs = {} -- [key] = { type, addr } ; key is numeric for char/warband, "g:<tab>" for guild
    -- Track per-move failure reason for the named-failure chat report.
    -- Key: bag * 1000 + slot. Value: "bind" or "fulltab". Items with no entry
    -- but still in bags after FinishAll are "unknown" (locked, unique limit,
    -- guild bank rejection without a tab signal, etc.).
    local moveFailReason = {}
    -- Moves that actually fired. A later pass can stamp a transient reason ("locked",
    -- "moved") on the same slot, so success has to be recorded separately rather than
    -- inferred from the absence of a reason.
    local moveSucceeded = {}

    local function UpdateDepositBtn()
        if self.triageDepositBtn then
            self.triageDepositBtn:SetText(string.format("Depositing... (%d left)", totalItems - totalMoved))
        end
    end

    ---------------------------------------------------------------------------
    -- Context-aware helpers
    ---------------------------------------------------------------------------

    -- Find a destination slot in a bank address, respecting allocated slots.
    -- Uses the move context to read items (works for guild bank too).
    local function FindDestSlot(ctx, destAddr, itemID, allocated, send)
        local numSlots = ctx.GetNumSlots(destAddr)
        if not numSlots or numSlots == 0 then
            return nil
        end
        local aSlots = allocated[destAddr] or {}
        local maxStack = GetMaxStack(itemID)
        -- Pass 1: partial stacks of same item, but only ones with room for the whole
        -- amount being sent. A stack that is merely non-full is not enough: dropping
        -- 5 onto a 998/1000 stack merges 2 and strands 3 on the cursor, which
        -- ClearCursor then discards and the move counts as failed. Falling through to
        -- an empty slot costs a slot but always completes.
        if maxStack > 1 then
            local need = send or 1
            for slot = 1, numSlots do
                if not aSlots[slot] then
                    local info = ctx.GetItemInfo(destAddr, slot)
                    if info and info.itemID == itemID and (maxStack - info.stackCount) >= need then
                        return slot
                    end
                end
            end
        end
        -- Pass 2: empty slots
        for slot = 1, numSlots do
            if not aSlots[slot] then
                if not ctx.GetItemInfo(destAddr, slot) then
                    return slot
                end
            end
        end
        return nil
    end

    -- Attempt a single bags→bank move. Returns (fired, destAddr).
    local function TryMove(move, ctx, allocated)
        local moveKey = move.srcBag * 1000 + move.srcSlot
        local srcLoc = ItemLocation:CreateFromBagAndSlot(move.srcBag, move.srcSlot)
        if not C_Item.DoesItemExist(srcLoc) or C_Item.IsLocked(srcLoc) then
            -- Transient: the slot is mid-move (cursor still settling from an earlier
            -- split) or the item is gone. Retried on the next pass.
            moveFailReason[moveKey] = "locked"
            return false
        end
        local srcInfo = C_Container.GetContainerItemInfo(move.srcBag, move.srcSlot)
        if not srcInfo or srcInfo.itemID ~= move.itemID then
            -- The slot no longer holds what the scan classified: bags shifted under
            -- us (restack, manual move) since the move list was built.
            moveFailReason[moveKey] = "moved"
            return false
        end

        -- Bank-type-specific item filter
        if not ctx.IsItemAllowedInBank(move.srcBag, move.srcSlot) then
            skippedNotAllowed = skippedNotAllowed + 1
            local dt = move.routing and move.routing.destType
            if dt then
                skippedByType[dt] = (skippedByType[dt] or 0) + 1
            end
            moveFailReason[moveKey] = "bind"
            return false
        end

        -- Try all candidate addresses until we find a slot
        local candidates = ResolveCandidateAddresses(move.routing)
        if #candidates == 0 then
            -- The rule's tabs resolved to nothing: pinned tabs that are unpurchased
            -- (0 slots), or the bank was not populated when the deposit ran.
            moveFailReason[moveKey] = "notabs"
            return false
        end

        -- How many this move sends, needed up front so FindDestSlot can reject a
        -- partial stack that cannot take the whole amount. A restock-floor straddling
        -- slot carries routeCount = surplus above the floor; otherwise the full stack.
        local sInfo = C_Container.GetContainerItemInfo(move.srcBag, move.srcSlot)
        local have = sInfo and sInfo.stackCount or 0
        local send = move.routeCount or have

        for _, destAddr in ipairs(candidates) do
            local destSlot = FindDestSlot(ctx, destAddr, move.itemID, allocated, send)
            if destSlot then
                -- Execute the move: pick up from bag, place in bank. Split off exactly
                -- the surplus (leaving the floor in bags), else move the whole stack.
                if send > 0 and send < have then
                    C_Container.SplitContainerItem(move.srcBag, move.srcSlot, send)
                else
                    C_Container.PickupContainerItem(move.srcBag, move.srcSlot)
                end
                ctx.PickupItem(destAddr, destSlot)
                ClearCursor()
                if not allocated[destAddr] then
                    allocated[destAddr] = {}
                end
                allocated[destAddr][destSlot] = true
                -- Clear any stale fail-reason in case this move was retried.
                moveFailReason[moveKey] = nil
                moveSucceeded[moveKey] = true
                return true, destAddr
            else
                if not fullTabs[destAddr] then
                    fullTabs[destAddr] = { type = move.routing.destType, addr = destAddr }
                end
            end
        end
        moveFailReason[moveKey] = "fulltab"
        return false
    end

    ---------------------------------------------------------------------------
    -- Finish handler: final report + UI refresh
    ---------------------------------------------------------------------------
    local function FinishAll()
        if totalMoved > 0 then
            self:IncrementStat("itemsStashed", totalMoved)
        end
        local remaining = totalItems - totalMoved
        local noSpace = remaining - skippedNotAllowed
        if noSpace < 0 then
            noSpace = 0
        end

        self:ChatMsg(
            string.format(
                "|cff4d99ff[Triage]|r Deposited %d of %d item%s.",
                totalMoved,
                totalItems,
                totalItems == 1 and "" or "s"
            )
        )

        -- Line 2: no-space breakdown, grouped by bank type, listing full tabs
        if noSpace > 0 then
            local tabsByType = {}
            for _, info in pairs(fullTabs) do
                local tabNum
                if info.type == "warbandbank" then
                    tabNum = info.addr - 11
                elseif info.type == "charbank" then
                    tabNum = info.addr - 5
                elseif info.type == "guildbank" then
                    tabNum = info.addr
                end
                if tabNum then
                    tabsByType[info.type] = tabsByType[info.type] or {}
                    table.insert(tabsByType[info.type], tabNum)
                end
            end
            local parts = {}
            for _, typeKey in ipairs({ "guildbank", "warbandbank", "charbank" }) do
                local nums = tabsByType[typeKey]
                if nums and #nums > 0 then
                    table.sort(nums)
                    local ctx = MoveContexts[typeKey]
                    local label = ctx and ctx.name or typeKey
                    local suffix = (#nums == 1) and (" tab " .. nums[1]) or (" tabs " .. table.concat(nums, ", "))
                    parts[#parts + 1] = label .. suffix .. " full"
                end
            end
            local detail = #parts > 0 and (" (" .. table.concat(parts, "; ") .. ")") or ""
            self:ChatMsg(string.format("|cff4d99ff[Triage]|r   %d no space%s", noSpace, detail))
        end

        -- Line 3: bind-restriction breakdown, per bank type that rejected items
        if skippedNotAllowed > 0 then
            local lines = {}
            for _, typeKey in ipairs({ "guildbank", "warbandbank", "charbank" }) do
                local cnt = skippedByType[typeKey] or 0
                if cnt > 0 then
                    local ctx = MoveContexts[typeKey]
                    local label = ctx and ctx.name or typeKey
                    local reason = (typeKey == "guildbank") and "soulbound"
                        or (typeKey == "warbandbank") and "not warbound"
                        or "bind restriction"
                    lines[#lines + 1] = string.format("%d can't go in %s (%s)", cnt, label, reason)
                end
            end
            -- Fallback if per-type tracking missed something
            if #lines == 0 then
                lines[1] = string.format("%d can't be stored here (bind restriction)", skippedNotAllowed)
            end
            for _, line in ipairs(lines) do
                self:ChatMsg("|cff4d99ff[Triage]|r   " .. line)
            end
        end

        -- Line 4+: named failure list. Walk the original attempted moves and
        -- report any whose source slot still holds the same item (move never
        -- succeeded). Reasons: tracked "bind"/"fulltab" from TryMove; otherwise
        -- "unknown" (likely unique limit, locked slot, or guild bank rejection
        -- with no tab signal). Grouped by item name so duplicates collapse.
        -- Skip moves whose destType wasn't accessible this run (e.g. guild-bank
        -- targets when only the character bank was open) - those weren't
        -- attempted, so they aren't failures.
        local accessibleType = {
            charbank = regularBankOpen and not warbandOnly,
            warbandbank = warbandAccessible,
            guildbank = guildBankOpen,
        }
        local namedFails = {}
        local namedFailOrder = {}
        for _, m in ipairs(attemptedMoves) do
            local dt = m.routing and m.routing.destType
            if accessibleType[dt] then
                local info = C_Container.GetContainerItemInfo(m.srcBag, m.srcSlot)
                local moveKey = m.srcBag * 1000 + m.srcSlot
                -- "Item still in the slot" only proves failure for a whole-stack move.
                -- A restock-floor straddle deposits the surplus and leaves the floor
                -- behind, so the slot legitimately still holds the same itemID on
                -- success. Treat those as failed only when nothing actually left:
                -- the recorded fail reason is the reliable signal there.
                local stillThere = info and info.itemID == m.itemID
                local partial = m.routeCount and m.routeCount > 0
                local failed
                if partial then
                    -- The surplus left but the floor stayed, so the slot still holds the
                    -- item either way. Only a move that never fired is a failure.
                    failed = stillThere and not moveSucceeded[moveKey]
                else
                    failed = stillThere
                end
                if failed then
                    local reasonKey = moveFailReason[moveKey] or "unknown"
                    -- Name the storage rule that routed this item. Which tabs are full
                    -- is on the "no space" line above; the rule number is what the user
                    -- actually has to go edit, and it is not derivable from the tabs.
                    local ruleTag = ""
                    local rIdx = m.routing and m.routing.ruleIndex
                    if rIdx then
                        ruleTag = string.format(" (rule #%d)", rIdx)
                    end
                    local reasonText
                    if reasonKey == "bind" then
                        reasonText = "bind restriction"
                    elseif reasonKey == "fulltab" then
                        reasonText = "destination full" .. ruleTag
                    elseif reasonKey == "notabs" then
                        reasonText = "no usable destination tab" .. ruleTag
                    elseif reasonKey == "locked" then
                        reasonText = "slot busy"
                    elseif reasonKey == "moved" then
                        reasonText = "item moved during deposit"
                    else
                        reasonText = "unknown"
                    end
                    local nameLabel = m.itemLink or m.itemName or ("Item " .. m.itemID)
                    local key = nameLabel .. "|" .. reasonText
                    if not namedFails[key] then
                        namedFails[key] = { name = nameLabel, reason = reasonText, count = 0 }
                        namedFailOrder[#namedFailOrder + 1] = key
                    end
                    namedFails[key].count = namedFails[key].count + 1
                end
            end
        end
        if #namedFailOrder > 0 then
            self:ChatMsg("|cff4d99ff[Triage]|r   Failed:")
            local maxLines = 5
            local shown = math.min(#namedFailOrder, maxLines)
            for i = 1, shown do
                local f = namedFails[namedFailOrder[i]]
                local qty = f.count > 1 and string.format(" x%d", f.count) or ""
                -- Explicit |r after the item link: WoW chat occasionally lets the
                -- link's quality color bleed onto trailing text; force reset.
                self:ChatMsg(string.format("|cff4d99ff[Triage]|r     %s|r%s - %s", f.name, qty, f.reason))
            end
            if #namedFailOrder > shown then
                self:ChatMsg(string.format("|cff4d99ff[Triage]|r     ... and %d more", #namedFailOrder - shown))
            end
        end
        self._triageBulkOperating = false
        CheckBagsFull()
        -- Drop stale bag classifications so the upcoming rescan doesn't short-circuit
        -- on the cached pre-deposit results.
        self.triageResults = nil
        self._bagsDirty = true
        self._triageFingerprint = nil
        self._triageFingerprintCount = nil
        -- Immediate refresh so the list reflects the new state without a visible gap.
        if self.triageFrame and self.triageFrame:IsShown() then
            self:RefreshTriageDisplay(true)
        end
        -- Delayed second pass to catch any final BAG_UPDATE_DELAYED after the last move settles.
        C_Timer.After(0.5, function()
            self:SnapshotOpenBankCapacity()
            if self.triageFrame and self.triageFrame:IsShown() then
                self:RefreshTriageDisplay(true)
            end
        end)
    end

    ---------------------------------------------------------------------------
    -- Generic move phase: event-driven batched deposit loop
    --
    -- destType: "charbank", "warbandbank", or "guildbank"
    -- moves: array of move records for this bank type
    -- onComplete: callback when this phase finishes
    ---------------------------------------------------------------------------
    local function RunMovePhase(destType, moves, onComplete)
        if #moves == 0 then
            onComplete()
            return
        end

        local ctx = MoveContexts[destType]
        if not ctx then
            onComplete()
            return
        end

        local isGuildBank = (destType == "guildbank")

        local moveList = moves
        local listener = self:AcquireListener()
        local fallbackTimer
        local running = true
        local noProgressRetries = 0
        local MAX_NO_PROGRESS_RETRIES = 5
        local bagCountBefore = 0
        local allocated = {}
        local batchLimit = ctx.batchSize > 0 and ctx.batchSize or 999
        local lastMovedAddr = nil -- track which bank address the last move targeted

        -- Count occupied bag slots (source side) to detect items leaving bags.
        -- Slot-based bank counting fails when items merge into existing stacks.
        local CountBagItems = CountOccupiedBagSlots

        -- Partial moves (restock-floor straddle) never free the slot, so slot counting
        -- reports no progress and the whole deposit reads as failed. Track the summed
        -- quantity of the straddling itemIDs alongside the slot count.
        local partialItemIDs = {}
        local hasPartial = false
        for _, mv in ipairs(moveList or {}) do
            if mv.routeCount and mv.routeCount > 0 and mv.itemID then
                partialItemIDs[mv.itemID] = true
                hasPartial = true
            end
        end
        local partialQtyBefore = hasPartial and CountBagQuantities(partialItemIDs) or 0

        local function Cleanup()
            running = false
            self:ReleaseListener(listener)
            if fallbackTimer then
                fallbackTimer:Cancel()
                fallbackTimer = nil
            end
        end

        local function Finish()
            Cleanup()
            onComplete()
        end

        local function RebuildMoveList()
            self:RunTriage()
            moveList = {}
            for _, r in ipairs(self.triageResults) do
                local rowKey = (r.item.bag or 0) .. ":" .. (r.item.slot or 0)
                if
                    r.category == CAT_STASH
                    and r.routing
                    and r.routing.destType == destType
                    and not skippedItems[rowKey]
                    and not skippedActions[r.action]
                then
                    moveList[#moveList + 1] = {
                        srcBag = r.item.bag,
                        srcSlot = r.item.slot,
                        itemID = r.item.itemID,
                        itemName = r.item.itemName or "?",
                        routing = r.routing,
                        routeCount = r.item.routeCount, -- surplus above a restock floor, or nil
                    }
                end
            end
        end

        local CheckProgress

        local function WaitForUpdate()
            listener:RegisterEvent("BAG_UPDATE_DELAYED")
            local timeout = isGuildBank and 2.0 or 1.5
            fallbackTimer = C_Timer.NewTimer(timeout, function()
                fallbackTimer = nil
                listener:UnregisterAllEvents()
                if not running or self:IsBulkCancelled(gen) then
                    return
                end
                CheckProgress()
            end)
        end

        local function RunBatch()
            if not running or self:IsBulkCancelled(gen) then
                return
            end
            if not self:IsBankOpen() then
                Cleanup()
                self:ChatMsg("|cff4d99ff[Triage]|r Bank closed during deposit")
                onComplete()
                return
            end

            bagCountBefore = CountBagItems()
            allocated = {} -- reset each batch
            lastMovedAddr = nil

            local batchFired = 0
            for _, move in ipairs(moveList) do
                if batchFired >= batchLimit then
                    break
                end
                local fired, addr = TryMove(move, ctx, allocated)
                if fired then
                    batchFired = batchFired + 1
                    lastMovedAddr = addr
                end
            end

            if batchFired == 0 then
                Finish()
                return
            end

            WaitForUpdate()
        end

        CheckProgress = function()
            if not running or self:IsBulkCancelled(gen) then
                return
            end

            -- Guild bank: only query the tab we actually deposited to (not all tabs)
            if ctx.needsQueryAfterMove and ctx.QueryAfterMove then
                if lastMovedAddr then
                    ctx.QueryAfterMove(lastMovedAddr)
                end
            end

            local bagCountAfter = CountBagItems()
            local actualMoved = bagCountBefore - bagCountAfter
            -- Credit a partial move too: the slot stayed occupied but the stack shrank.
            if hasPartial then
                local qtyAfter = CountBagQuantities(partialItemIDs)
                if qtyAfter < partialQtyBefore and actualMoved <= 0 then
                    actualMoved = 1
                end
                partialQtyBefore = qtyAfter
            end
            if actualMoved > 0 then
                totalMoved = totalMoved + actualMoved
                UpdateDepositBtn()
                noProgressRetries = 0
                RebuildMoveList()
                if #moveList == 0 then
                    Finish()
                else
                    RunBatch()
                end
            else
                noProgressRetries = noProgressRetries + 1
                if noProgressRetries >= MAX_NO_PROGRESS_RETRIES then
                    Finish()
                else
                    WaitForUpdate()
                end
            end
        end

        local settleTimer
        listener:SetScript("OnEvent", function()
            if fallbackTimer then
                fallbackTimer:Cancel()
                fallbackTimer = nil
            end
            -- Debounce: reset settle timer on each BAG_UPDATE_DELAYED so we wait
            -- until all items have finished moving before checking progress
            if settleTimer then
                settleTimer:Cancel()
            end
            local delay = isGuildBank and 0.3 or 0.5
            settleTimer = C_Timer.NewTimer(delay, function()
                settleTimer = nil
                listener:UnregisterAllEvents()
                if not running then
                    return
                end
                CheckProgress()
            end)
        end)

        RunBatch()
    end

    ---------------------------------------------------------------------------
    -- Guild bank deposit: tab-by-tab sequential approach.
    -- Switch to tab → query server → wait for data → deposit one item →
    -- wait for BAG_UPDATE_DELAYED → repeat until tab full → next tab.
    ---------------------------------------------------------------------------
    local function RunGuildBankDeposit(moves, onComplete)
        if #moves == 0 then
            onComplete()
            return
        end

        -- Build candidate tabs: assigned tabs or rotate from current
        local candidateTabs = {}
        local seen = {}
        local hasAssigned = false
        for _, move in ipairs(moves) do
            local tabs = move.routing and move.routing.destTabs
            if tabs and #tabs > 0 then
                hasAssigned = true
                for _, t in ipairs(tabs) do
                    if not seen[t] then
                        seen[t] = true
                        candidateTabs[#candidateTabs + 1] = t
                    end
                end
            end
        end
        if not hasAssigned then
            -- No assigned tabs: start from currently open tab, then rotate
            local numTabs = GetNumGuildBankTabs() or 0
            local current = GetCurrentGuildBankTab() or 1
            if current < 1 or current > numTabs then
                current = 1
            end
            for i = 0, numTabs - 1 do
                local t = ((current - 1 + i) % numTabs) + 1
                candidateTabs[#candidateTabs + 1] = t
            end
        end

        if #candidateTabs == 0 then
            onComplete()
            return
        end

        local tabIdx = 0
        local listener = self:AcquireListener()
        local timer
        local running = true

        local function Cleanup()
            running = false
            self:ReleaseListener(listener)
            if timer then
                timer:Cancel()
                timer = nil
            end
        end

        local function Finish()
            Cleanup()
            onComplete()
        end

        local NextTab -- forward declaration

        -- Scan a guild bank tab and return a list of empty slot indices
        -- plus a table of {slot -> itemID} for partial-stack matching.
        -- Must be called AFTER QueryGuildBankTab data has arrived.
        local function ScanTabSlots(tab)
            local _, _, _, canDeposit, numSlots = GetGuildBankTabInfo(tab)
            -- Guild bank tabs are always 98 slots (14x7). API returns -1 or
            -- bogus values like 100000 for purchased tabs.
            if not numSlots or numSlots <= 0 or numSlots > 98 then
                numSlots = 98
            end
            if not canDeposit then
                return {}, {}
            end
            local emptySlots = {}
            local filledSlots = {} -- slot -> { itemID, count }
            for slot = 1, numSlots do
                local tex, count = GetGuildBankItemInfo(tab, slot)
                if tex then
                    local link = GetGuildBankItemLink(tab, slot)
                    local itemID = link and select(1, C_Item.GetItemInfoInstant(link))
                    if itemID then
                        filledSlots[slot] = { itemID = itemID, count = count }
                    end
                else
                    emptySlots[#emptySlots + 1] = slot
                end
            end
            return emptySlots, filledSlots
        end

        -- Find a dest slot: first partial stacks of same item, then first empty.
        local function FindGuildSlot(emptySlots, filledSlots, usedSlots, itemID, send)
            local maxStack = GetMaxStack(itemID)
            -- Pass 1: partial stacks of same item with room for the whole amount.
            -- A merely non-full stack is not enough - see the note in FindDestSlot.
            if maxStack > 1 then
                local need = send or 1
                for slot, info in pairs(filledSlots) do
                    if not usedSlots[slot] and info.itemID == itemID and (maxStack - info.count) >= need then
                        return slot
                    end
                end
            end
            -- Pass 2: first empty slot
            for _, slot in ipairs(emptySlots) do
                if not usedSlots[slot] then
                    return slot
                end
            end
            return nil
        end

        -- Deposit loop on a single tab.  emptySlots/filledSlots come from ScanTabSlots.
        local function DepositOnTab(tab, emptySlots, filledSlots)
            if not running or self:IsBulkCancelled(gen) or not self:IsGuildBankOpen() then
                Cleanup()
                self:ChatMsg("|cff4d99ff[Triage]|r Guild Bank closed during deposit")
                onComplete()
                return
            end
            if #moves == 0 then
                Finish()
                return
            end

            -- Try to find one item to deposit
            local usedSlots = {}
            local fired = false
            local firedMove
            local tabWasTargeted = false -- at least one move wanted this tab but couldn't fit
            for i, move in ipairs(moves) do
                local srcLoc = ItemLocation:CreateFromBagAndSlot(move.srcBag, move.srcSlot)
                if C_Item.DoesItemExist(srcLoc) and not C_Item.IsLocked(srcLoc) then
                    local srcInfo = C_Container.GetContainerItemInfo(move.srcBag, move.srcSlot)
                    if srcInfo and srcInfo.itemID == move.itemID then
                        if not C_Item.IsBound(srcLoc) then
                            -- Check if this move targets this tab
                            local validTab = true
                            if move.routing.destTabs and #move.routing.destTabs > 0 then
                                validTab = false
                                for _, dt in ipairs(move.routing.destTabs) do
                                    if dt == tab then
                                        validTab = true
                                        break
                                    end
                                end
                            end
                            if validTab then
                                tabWasTargeted = true
                                -- Amount up front so FindGuildSlot can reject a partial
                                -- stack too small to take it. Restock straddle: split off
                                -- routeCount (surplus), else the whole stack.
                                local gInfo = C_Container.GetContainerItemInfo(move.srcBag, move.srcSlot)
                                local gHave = gInfo and gInfo.stackCount or 0
                                local gSend = move.routeCount or gHave
                                local destSlot =
                                    FindGuildSlot(emptySlots, filledSlots, usedSlots, move.itemID, gSend)
                                if destSlot then
                                    -- Execute the move: PickupGuildBankItem takes tab param directly.
                                    if gSend > 0 and gSend < gHave then
                                        C_Container.SplitContainerItem(move.srcBag, move.srcSlot, gSend)
                                    else
                                        C_Container.PickupContainerItem(move.srcBag, move.srcSlot)
                                    end
                                    PickupGuildBankItem(tab, destSlot)
                                    ClearCursor()
                                    -- Save move to verify after events
                                    firedMove = move
                                    table.remove(moves, i)
                                    fired = true
                                    break
                                end
                            end
                        else
                            -- Bound item, remove from list
                            skippedNotAllowed = skippedNotAllowed + 1
                            skippedByType.guildbank = (skippedByType.guildbank or 0) + 1
                            table.remove(moves, i)
                            return DepositOnTab(tab, emptySlots, filledSlots)
                        end
                    end
                end
            end

            if not fired then
                -- Tab is full (items wanted it but no slot was available) or
                -- no items target this tab. Only record as "full" in the former case.
                if tabWasTargeted then
                    local key = "g:" .. tab
                    if not fullTabs[key] then
                        fullTabs[key] = { type = "guildbank", addr = tab }
                    end
                end
                NextTab()
                return
            end

            -- Wait for BOTH bag and guild bank to confirm the move.
            -- BAG_UPDATE_DELAYED = item left bag.
            -- GUILDBANKBAGSLOTS_CHANGED = item arrived in guild bank.
            -- After both fire, verify the item actually left, re-scan, continue.
            local gotBag, gotGuild = false, false
            local function AfterEvents()
                if not running or self:IsBulkCancelled(gen) then
                    return
                end
                -- Verify the item actually left the source slot
                local srcInfo = C_Container.GetContainerItemInfo(firedMove.srcBag, firedMove.srcSlot)
                if srcInfo and srcInfo.itemID == firedMove.itemID then
                    -- Move failed silently - put it back in list
                    firedMove._failCount = (firedMove._failCount or 0) + 1
                    if firedMove._failCount < 3 then
                        table.insert(moves, 1, firedMove)
                    end
                    -- Don't count as moved
                else
                    totalMoved = totalMoved + 1
                    UpdateDepositBtn()
                end
                -- Re-scan tab for accurate empty/filled state
                local freshEmpty, freshFilled = ScanTabSlots(tab)
                DepositOnTab(tab, freshEmpty, freshFilled)
            end
            local function TryProceed()
                if not running then
                    return
                end
                if gotBag and gotGuild then
                    listener:UnregisterAllEvents()
                    if timer then
                        timer:Cancel()
                        timer = nil
                    end
                    C_Timer.After(0.05, function()
                        AfterEvents()
                    end)
                end
            end

            listener:RegisterEvent("BAG_UPDATE_DELAYED")
            listener:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED")
            timer = C_Timer.NewTimer(2.0, function()
                timer = nil
                listener:UnregisterAllEvents()
                if not running then
                    return
                end
                C_Timer.After(0.1, function()
                    AfterEvents()
                end)
            end)
            listener:SetScript("OnEvent", function(_, event)
                if event == "BAG_UPDATE_DELAYED" then
                    gotBag = true
                elseif event == "GUILDBANKBAGSLOTS_CHANGED" then
                    gotGuild = true
                end
                TryProceed()
            end)
        end

        -- Switch to the next candidate tab, query it, then start depositing
        NextTab = function()
            tabIdx = tabIdx + 1
            if tabIdx > #candidateTabs then
                Finish()
                return
            end
            local tab = candidateTabs[tabIdx]

            -- Query this tab's data from server
            SetCurrentGuildBankTab(tab)
            QueryGuildBankTab(tab)

            -- Wait for GUILDBANKBAGSLOTS_CHANGED to confirm data loaded
            listener:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED")
            timer = C_Timer.NewTimer(2.0, function()
                timer = nil
                listener:UnregisterAllEvents()
                if not running then
                    return
                end
                -- Timeout: try scanning anyway (data may have loaded already)
                local emptySlots, filledSlots = ScanTabSlots(tab)
                if #emptySlots > 0 then
                    DepositOnTab(tab, emptySlots, filledSlots)
                else
                    NextTab()
                end
            end)
            listener:SetScript("OnEvent", function()
                listener:UnregisterAllEvents()
                if timer then
                    timer:Cancel()
                    timer = nil
                end
                if not running then
                    return
                end
                -- Data loaded; scan tab for empty slots
                C_Timer.After(0.05, function()
                    if not running then
                        return
                    end
                    local emptySlots, filledSlots = ScanTabSlots(tab)
                    DepositOnTab(tab, emptySlots, filledSlots)
                end)
            end)
        end

        NextTab()
    end

    ---------------------------------------------------------------------------
    -- Chain phases: charbank → warband → guildbank → finish
    -- When only the guild bank is open (not the regular bank), skip
    -- charbank/warbandbank phases - those containers aren't accessible.
    ---------------------------------------------------------------------------
    if regularBankOpen then
        RunMovePhase("charbank", movesByType.charbank, function()
            RunMovePhase("warbandbank", movesByType.warbandbank, function()
                if guildBankOpen then
                    RunGuildBankDeposit(movesByType.guildbank, function()
                        FinishAll()
                    end)
                else
                    FinishAll()
                end
            end)
        end)
    elseif guildBankOpen then
        RunGuildBankDeposit(movesByType.guildbank, function()
            FinishAll()
        end)
    else
        FinishAll()
    end
end

-------------------------------------------------------------------------------
-- Restack: consolidate partial stacks in bags and/or open bank
-------------------------------------------------------------------------------

-- Restack a single container/tab using the given move context.
-- Finds partial stacks of the same item and merges them one at a time.
-- Calls onComplete() when done.
function EmpireManager:RestackAddress(ctx, addr, onComplete)
    -- 1. Scan all slots, group by itemID
    local numSlots = ctx.GetNumSlots(addr)
    if not numSlots or numSlots == 0 then
        if onComplete then
            onComplete()
        end
        return
    end

    local stacks = {} -- [itemID] = { {slot, count}, ... }
    for slot = 1, numSlots do
        local info = ctx.GetItemInfo(addr, slot)
        if info and info.itemID then
            local maxStack = GetMaxStack(info.itemID)
            if maxStack > 1 and info.stackCount < maxStack then
                if not stacks[info.itemID] then
                    stacks[info.itemID] = {}
                end
                stacks[info.itemID][#stacks[info.itemID] + 1] = { slot = slot, count = info.stackCount }
            end
        end
    end

    -- 2. Build merge queue: for each itemID with 2+ partial stacks, pair them
    local merges = {} -- { {fromSlot, toSlot}, ... }
    for _, partials in pairs(stacks) do
        if #partials >= 2 then
            -- Sort smallest first so we merge small into large
            table.sort(partials, function(a, b)
                return a.count < b.count
            end)
            for i = 1, #partials - 1 do
                merges[#merges + 1] = { from = partials[i].slot, to = partials[#partials].slot }
            end
        end
    end

    if #merges == 0 then
        if onComplete then
            onComplete()
        end
        return
    end

    -- 3. Execute merges one at a time (event-driven)
    local idx = 1
    local listener = self:AcquireListener()
    local fallbackTimer
    local running = true

    local function Cleanup()
        running = false
        self:ReleaseListener(listener)
        if fallbackTimer then
            fallbackTimer:Cancel()
            fallbackTimer = nil
        end
    end

    local function DoNext()
        if not running then
            return
        end
        if idx > #merges then
            Cleanup()
            if onComplete then
                onComplete()
            end
            return
        end

        local merge = merges[idx]
        idx = idx + 1

        -- Verify both slots still have the same item and the destination has room
        local fromInfo = ctx.GetItemInfo(addr, merge.from)
        local toInfo = ctx.GetItemInfo(addr, merge.to)
        if not fromInfo or not toInfo or fromInfo.itemID ~= toInfo.itemID then
            DoNext()
            return
        end
        local maxStack = GetMaxStack(fromInfo.itemID)
        if maxStack < 1 then
            maxStack = 1
        end
        if toInfo.stackCount >= maxStack then
            DoNext()
            return
        end

        ctx.PickupItem(addr, merge.from)
        ctx.PickupItem(addr, merge.to)
        ClearCursor()

        -- Wait for confirmation
        listener:RegisterEvent("BAG_UPDATE_DELAYED")
        fallbackTimer = C_Timer.NewTimer(1.5, function()
            fallbackTimer = nil
            listener:UnregisterAllEvents()
            if running then
                DoNext()
            end
        end)
    end

    listener:SetScript("OnEvent", function()
        listener:UnregisterAllEvents()
        if fallbackTimer then
            fallbackTimer:Cancel()
            fallbackTimer = nil
        end
        C_Timer.After(0.3, function()
            if running then
                if ctx.needsQueryAfterMove and ctx.QueryAfterMove then
                    ctx.QueryAfterMove(addr)
                end
                DoNext()
            end
        end)
    end)

    DoNext()
end

-- Restack bags (0-4 + reagent bag 5) using C_Container
function EmpireManager:RestackBags(onComplete)
    local bagCtx = {
        GetItemInfo = function(bag, slot)
            return C_Container.GetContainerItemInfo(bag, slot)
        end,
        GetNumSlots = function(bag)
            return C_Container.GetContainerNumSlots(bag) or 0
        end,
        PickupItem = function(bag, slot)
            C_Container.PickupContainerItem(bag, slot)
        end,
        needsQueryAfterMove = false,
    }

    local bags = { 0, 1, 2, 3, 4, 5 }
    local idx = 1

    local function NextBag()
        if idx > #bags then
            if onComplete then
                onComplete()
            end
            return
        end
        local bag = bags[idx]
        idx = idx + 1
        self:RestackAddress(bagCtx, bag, NextBag)
    end

    NextBag()
end

-- Restack all: bags first, then open bank tabs
function EmpireManager:Restack()
    if InCombatLockdown() then
        self:ChatMsg("Cannot restack during combat", true)
        return
    end

    ResetMaxStackCache()
    self:ChatVerbose("|cff4d99ff[Storage]|r Restacking.")

    self:RestackBags(function()
        if not self:IsBankOpen() then
            self:ChatMsg("|cff4d99ff[Storage]|r Restack complete (bags only, no bank open)")
            return
        end

        -- Determine which bank is open and restack its tabs
        if self:IsGuildBankOpen() then
            local gCtx = MoveContexts.guildbank
            local lo, hi = gCtx.TabRange()
            local tabIdx = lo
            local function NextGuildTab()
                if tabIdx > hi then
                    self:SnapshotOpenBankCapacity()
                    self:ChatMsg("|cff4d99ff[Storage]|r Restack complete")
                    return
                end
                local tab = tabIdx
                tabIdx = tabIdx + 1
                self:RestackAddress(gCtx, tab, NextGuildTab)
            end
            NextGuildTab()
        else
            -- Restack character bank tabs (6-11), then warband tabs (12-16)
            local containers = {}
            for bag = 6, 11 do
                if (C_Container.GetContainerNumSlots(bag) or 0) > 0 then
                    containers[#containers + 1] = { ctx = MoveContexts.charbank, addr = bag }
                end
            end
            for bag = 12, 16 do
                if (C_Container.GetContainerNumSlots(bag) or 0) > 0 then
                    containers[#containers + 1] = { ctx = MoveContexts.warbandbank, addr = bag }
                end
            end

            local cIdx = 1
            local function NextContainer()
                if cIdx > #containers then
                    self:SnapshotOpenBankCapacity()
                    self:ChatMsg("|cff4d99ff[Storage]|r Restack complete")
                    return
                end
                local c = containers[cIdx]
                cIdx = cIdx + 1
                self:RestackAddress(c.ctx, c.addr, NextContainer)
            end
            NextContainer()
        end
    end)
end

-------------------------------------------------------------------------------
-- Bank Triage: Reorganize (move STASH items to correct tabs)
-- Follows proven pattern: two queues (empty-slot moves, then swaps),
-- one move per frame, lock checking, BAG_UPDATE_DELAYED + 1s fallback timer.
-------------------------------------------------------------------------------

-- Helper: check if a bank slot's item is locked (safe for containers 6-18)
local function IsBankSlotLocked(container, slot)
    local loc = ItemLocation:CreateFromBagAndSlot(container, slot)
    return not C_Item.DoesItemExist(loc) or C_Item.IsLocked(loc)
end

function EmpireManager:ReorganizeBankItems()
    if not self:IsBankOpen() then
        self:ChatMsg("Open a bank first", true)
        return
    end
    if InCombatLockdown() then
        self:ChatMsg("Cannot reorganize during combat", true)
        return
    end

    local activeTab = self._triageActiveTab

    -- Guild bank uses a separate implementation (guild bank API, no swaps)
    if activeTab == "guildbank" then
        self:ReorganizeGuildBankItems()
        return
    end

    local results = self.bankTriageResults or {}
    local skippedItems = self.bankTriageSkippedItems or {}
    local skippedActions = self.bankTriageSkippedActions or {}

    -- Pick the correct MoveContext based on active tab
    local ctx
    if activeTab == "warband" then
        ctx = MoveContexts.warbandbank
    else
        ctx = MoveContexts.charbank
    end
    local bankTypeFilter
    if activeTab == "bank" then
        bankTypeFilter = "charbank"
    elseif activeTab == "warband" then
        bankTypeFilter = "warbandbank"
    end

    -- Collect all candidate items that need reorganizing, with all eligible dest addrs
    local candidateItems = {}
    for _, r in ipairs(results) do
        local actionKey = r.item.bankType and (r.item.bankType .. ":" .. r.action) or r.action
        local rowKey = (r.item.bankType or "") .. ":" .. (r.item.bag or 0) .. ":" .. (r.item.slot or 0)
        if
            r.category == CAT_STASH
            and r.destTabs
            and (not bankTypeFilter or r.item.bankType == bankTypeFilter)
            and not skippedItems[rowKey]
            and not skippedActions[actionKey]
        then
            local destAddrs = {}
            for _, tab in ipairs(r.destTabs) do
                destAddrs[#destAddrs + 1] = ctx.ResolveAddress(tab)
            end
            candidateItems[#candidateItems + 1] = {
                srcAddr = r.item.bankContainer or r.item.bag,
                srcSlot = r.item.slot,
                itemID = r.item.itemID,
                destAddrs = destAddrs,
            }
        end
    end

    if #candidateItems == 0 then
        self:ChatMsg("|cff4d99ff[Bank]|r Nothing to reorganize")
        return
    end

    ---------------------------------------------------------------------------
    -- Build two move queues:
    --   moveQueue0: moves to empty slots (safe, no displacement)
    --   moveQueue1: swaps with occupied slots (WoW auto-swaps on PickupItem)
    ---------------------------------------------------------------------------
    local function BuildMoveQueues(items)
        local queue0 = {} -- to empty slots
        local queue1 = {} -- swaps with occupied slots
        local allocated = {} -- [addr][slot] = true: already claimed as destination

        for _, c in ipairs(items) do
            local info = ctx.GetItemInfo(c.srcAddr, c.srcSlot)
            if info and info.itemID == c.itemID then
                local placed = false
                -- Pass 1: prefer empty slots across all eligible dest addresses
                for _, destAddr in ipairs(c.destAddrs) do
                    if placed then
                        break
                    end
                    local numSlots = ctx.GetNumSlots(destAddr)
                    if numSlots and numSlots > 0 then
                        local aSlots = allocated[destAddr] or {}
                        for slot = 1, numSlots do
                            if not aSlots[slot] and not ctx.GetItemInfo(destAddr, slot) then
                                queue0[#queue0 + 1] = {
                                    srcAddr = c.srcAddr,
                                    srcSlot = c.srcSlot,
                                    destAddr = destAddr,
                                    destSlot = slot,
                                    itemID = c.itemID,
                                }
                                if not allocated[destAddr] then
                                    allocated[destAddr] = {}
                                end
                                allocated[destAddr][slot] = true
                                placed = true
                                break
                            end
                        end
                    end
                end
                -- Pass 2: swap with any occupied slot not already allocated
                if not placed then
                    for _, destAddr in ipairs(c.destAddrs) do
                        if placed then
                            break
                        end
                        local numSlots = ctx.GetNumSlots(destAddr)
                        if numSlots and numSlots > 0 then
                            local aSlots = allocated[destAddr] or {}
                            for slot = 1, numSlots do
                                if not aSlots[slot] then
                                    local destInfo = ctx.GetItemInfo(destAddr, slot)
                                    -- Only swap if dest slot has a different item
                                    -- (avoid swapping with itself or same itemID in same addr)
                                    if destInfo and not (destAddr == c.srcAddr and slot == c.srcSlot) then
                                        queue1[#queue1 + 1] = {
                                            srcAddr = c.srcAddr,
                                            srcSlot = c.srcSlot,
                                            destAddr = destAddr,
                                            destSlot = slot,
                                            itemID = c.itemID,
                                        }
                                        if not allocated[destAddr] then
                                            allocated[destAddr] = {}
                                        end
                                        allocated[destAddr][slot] = true
                                        placed = true
                                        break
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        return queue0, queue1
    end

    local queue0, queue1 = BuildMoveQueues(candidateItems)
    local totalMoves = #queue0 + #queue1

    if totalMoves == 0 then
        self:ChatMsg("|cff4d99ff[Bank]|r Nothing to reorganize - all destination tabs are full")
        return
    end

    local gen = self:StartBulkOperation()
    local parts = {}
    if #queue0 > 0 then parts[#parts + 1] = string.format("%d move%s", #queue0, #queue0 == 1 and "" or "s") end
    if #queue1 > 0 then parts[#parts + 1] = string.format("%d swap%s", #queue1, #queue1 == 1 and "" or "s") end
    self:ChatVerbose(
        string.format(
            "|cff4d99ff[Bank]|r Reorganizing %d item%s (%s)...",
            totalMoves,
            totalMoves == 1 and "" or "s",
            table.concat(parts, ", ")
        )
    )

    -- Disable all bank buttons during operation
    if self._triageTakeOutBtn then
        self._triageTakeOutBtn:Disable()
    end
    if self._triageReorganizeBtn then
        self._triageReorganizeBtn:Disable()
    end
    if self._triageRescanBtn then
        self._triageRescanBtn:Disable()
    end

    -- Merge queues: empty-slot moves first, then swaps
    local allMoves = {}
    for _, m in ipairs(queue0) do
        allMoves[#allMoves + 1] = m
    end
    for _, m in ipairs(queue1) do
        allMoves[#allMoves + 1] = m
    end

    local moveIdx = 1
    local movedCount = 0
    local listener = self:AcquireListener()
    local fallbackTimer
    local running = true

    local function Cleanup()
        running = false
        self:ReleaseListener(listener)
        if fallbackTimer then
            fallbackTimer:Cancel()
            fallbackTimer = nil
        end
    end

    local function Finish()
        Cleanup()
        self._triageBulkOperating = false
        self:SnapshotOpenBankCapacity()
        local remaining = totalMoves - movedCount
        if movedCount > 0 and remaining > 0 then
            self:ChatMsg(
                string.format(
                    "|cff4d99ff[Bank]|r Reorganized %d item%s. %d remaining - destination tabs need more space.",
                    movedCount,
                    movedCount == 1 and "" or "s",
                    remaining
                )
            )
        elseif movedCount > 0 then
            self:ChatMsg(
                string.format("|cff4d99ff[Bank]|r Reorganized %d item%s.", movedCount, movedCount == 1 and "" or "s")
            )
        else
            self:ChatMsg("|cff4d99ff[Bank]|r Could not reorganize - destination tabs are full.")
        end
        C_Timer.After(0.3, function()
            self._bankTriageFingerprint = nil
            self.bankTriageResults = nil -- invalidate cache - bank contents changed
            self:RefreshBankTriageDisplay(true)
        end)
    end

    ---------------------------------------------------------------------------
    -- One-move-per-frame loop:
    -- Fire one pickup-pair → wait for BAG_UPDATE_DELAYED or 1s fallback → next
    ---------------------------------------------------------------------------
    local DoNextMove

    local function WaitForUpdate()
        listener:RegisterEvent("BAG_UPDATE_DELAYED")
        fallbackTimer = C_Timer.NewTimer(1, function()
            fallbackTimer = nil
            listener:UnregisterAllEvents()
            if running and not self:IsBulkCancelled(gen) then
                DoNextMove()
            end
        end)
    end

    DoNextMove = function()
        if not running or self:IsBulkCancelled(gen) then
            return
        end
        if InCombatLockdown() then
            -- Pause until combat ends, then resume
            listener:RegisterEvent("PLAYER_REGEN_ENABLED")
            listener:SetScript("OnEvent", function(_, event)
                if event == "PLAYER_REGEN_ENABLED" then
                    listener:UnregisterAllEvents()
                    listener:SetScript("OnEvent", nil)
                    DoNextMove()
                end
            end)
            return
        end

        -- Find next valid move (skip locked or missing items)
        while moveIdx <= #allMoves do
            local m = allMoves[moveIdx]
            moveIdx = moveIdx + 1

            -- Check source exists and is not locked
            if not IsBankSlotLocked(m.srcAddr, m.srcSlot) then
                local destInfo = ctx.GetItemInfo(m.destAddr, m.destSlot)
                if destInfo then
                    -- Swap: check dest is also not locked
                    if not IsBankSlotLocked(m.destAddr, m.destSlot) then
                        ctx.PickupItem(m.srcAddr, m.srcSlot)
                        ctx.PickupItem(m.destAddr, m.destSlot)
                        ClearCursor()
                        movedCount = movedCount + 1
                        if self._triageReorganizeBtn then
                            self._triageReorganizeBtn:SetText(
                                string.format("Reorganizing... (%d left)", totalMoves - movedCount)
                            )
                        end
                        WaitForUpdate()
                        return
                    end
                else
                    -- Empty slot: just move
                    ctx.PickupItem(m.srcAddr, m.srcSlot)
                    ctx.PickupItem(m.destAddr, m.destSlot)
                    ClearCursor()
                    movedCount = movedCount + 1
                    if self._triageReorganizeBtn then
                        self._triageReorganizeBtn:SetText(
                            string.format("Reorganizing... (%d left)", totalMoves - movedCount)
                        )
                    end
                    WaitForUpdate()
                    return
                end
            end
        end

        -- All moves processed
        Finish()
    end

    -- Event handler: on BAG_UPDATE_DELAYED, proceed to next move
    listener:SetScript("OnEvent", function()
        listener:UnregisterAllEvents()
        if fallbackTimer then
            fallbackTimer:Cancel()
            fallbackTimer = nil
        end
        if running and not self:IsBulkCancelled(gen) then
            DoNextMove()
        end
    end)

    DoNextMove()
end

-------------------------------------------------------------------------------
-- Bank Triage: Reorganize Guild Bank (move STASH items between guild bank tabs)
-- Follows proven pattern: one move at a time, no swaps (unreliable for guild
-- bank), QueryGuildBankTab before accessing each tab, verify each move.
-------------------------------------------------------------------------------

function EmpireManager:ReorganizeGuildBankItems()
    if not self:IsGuildBankOpen() then
        self:ChatMsg("|cff4d99ff[Bank]|r Guild Bank is not open", true)
        return
    end
    if InCombatLockdown() then
        self:ChatMsg("|cff4d99ff[Bank]|r Cannot reorganize during combat", true)
        return
    end

    local results = self.bankTriageResults or {}
    local skippedItems = self.bankTriageSkippedItems or {}
    local skippedActions = self.bankTriageSkippedActions or {}
    -- Collect STASH items with all eligible destination tabs
    local candidateItems = {}
    for _, r in ipairs(results) do
        local actionKey = r.item.bankType and (r.item.bankType .. ":" .. r.action) or r.action
        local rowKey = (r.item.bankType or "") .. ":" .. (r.item.bag or 0) .. ":" .. (r.item.slot or 0)
        if
            r.category == CAT_STASH
            and r.destTabs
            and r.item.bankType == "guildbank"
            and not skippedItems[rowKey]
            and not skippedActions[actionKey]
        then
            candidateItems[#candidateItems + 1] = {
                srcTab = r.item.srcTab,
                srcSlot = r.item.slot,
                itemID = r.item.itemID,
                destTabs = r.destTabs,
            }
        end
    end

    if #candidateItems == 0 then
        self:ChatMsg("|cff4d99ff[Bank]|r Nothing to reorganize")
        return
    end

    -- Read per-tab withdrawal limits
    local withdrawalsLeft = {}
    local numTabs = GetNumGuildBankTabs()
    for tab = 1, numTabs do
        local _, _, _, _, _, remaining = GetGuildBankTabInfo(tab)
        withdrawalsLeft[tab] = remaining or -1
    end

    -- Filter out items from tabs with 0 withdrawals remaining
    local limitedTabs = {}
    local filtered = {}
    for _, item in ipairs(candidateItems) do
        local tab = item.srcTab or 0
        local left = withdrawalsLeft[tab]
        if left == 0 then
            limitedTabs[tab] = true
        else
            filtered[#filtered + 1] = item
        end
    end
    if next(limitedTabs) then
        local tabList = {}
        for tab in pairs(limitedTabs) do
            tabList[#tabList + 1] = tab
        end
        table.sort(tabList)
        local tabStrs = {}
        for i, tab in ipairs(tabList) do
            tabStrs[i] = tostring(tab)
        end
        self:ChatMsg(
            string.format(
                "|cff4d99ff[Bank]|r Skipping tab%s %s - no withdrawals remaining today",
                #tabList == 1 and "" or "s",
                table.concat(tabStrs, ", ")
            )
        )
    end
    candidateItems = filtered

    if #candidateItems == 0 then
        self:ChatMsg("|cff4d99ff[Bank]|r Nothing to reorganize (withdrawal limits)")
        return
    end

    local gen = self:StartBulkOperation()
    self:ChatVerbose(
        string.format(
            "|cff4d99ff[Bank]|r Reorganizing %d Guild Bank item%s...",
            #candidateItems,
            #candidateItems == 1 and "" or "s"
        )
    )

    -- Disable all bank buttons
    if self._triageTakeOutBtn then
        self._triageTakeOutBtn:Disable()
    end
    if self._triageReorganizeBtn then
        self._triageReorganizeBtn:Disable()
    end
    if self._triageRescanBtn then
        self._triageRescanBtn:Disable()
    end

    local listener = self:AcquireListener()
    local timer
    local running = true
    local movedCount = 0
    local moveIdx = 1
    local totalItems = #candidateItems

    local function Cleanup()
        running = false
        self:ReleaseListener(listener)
        if timer then
            timer:Cancel()
            timer = nil
        end
    end

    local function Finish()
        Cleanup()
        self._triageBulkOperating = false
        self:SnapshotOpenBankCapacity()
        local remaining = totalItems - movedCount
        if movedCount > 0 and remaining > 0 then
            self:ChatMsg(
                string.format(
                    "|cff4d99ff[Bank]|r Reorganized %d item%s. %d remaining - destination tabs need more space.",
                    movedCount,
                    movedCount == 1 and "" or "s",
                    remaining
                )
            )
        elseif movedCount > 0 then
            self:ChatMsg(
                string.format("|cff4d99ff[Bank]|r Reorganized %d item%s.", movedCount, movedCount == 1 and "" or "s")
            )
        else
            self:ChatMsg("|cff4d99ff[Bank]|r Could not reorganize - destination tabs are full.")
        end
        C_Timer.After(0.3, function()
            self._bankTriageFingerprint = nil
            self.bankTriageResults = nil -- invalidate cache - bank contents changed
            self:RefreshBankTriageDisplay(true)
        end)
    end

    -- Scan a guild bank tab for empty slots (must be called after QueryGuildBankTab data arrives)
    local function ScanTabEmpty(tab)
        local _, _, _, canDeposit, numSlots = GetGuildBankTabInfo(tab)
        if not numSlots or numSlots <= 0 or numSlots > 98 then
            numSlots = 98
        end
        if not canDeposit then
            return {}
        end
        local empty = {}
        for slot = 1, numSlots do
            local tex = GetGuildBankItemInfo(tab, slot)
            if not tex then
                empty[#empty + 1] = slot
            end
        end
        return empty
    end

    -- Verify source item still exists at the expected location
    local function VerifySource(srcTab, srcSlot, itemID)
        local tex, _, locked = GetGuildBankItemInfo(srcTab, srcSlot)
        if not tex or locked then
            return false
        end
        local link = GetGuildBankItemLink(srcTab, srcSlot)
        local id = link and select(1, C_Item.GetItemInfoInstant(link))
        return id == itemID
    end

    ---------------------------------------------------------------------------
    -- Sort candidates by destination tab (first preference), then source tab.
    -- This minimizes tab switches: process all items going to the same dest tab
    -- together, and within each dest tab, group by source tab.
    ---------------------------------------------------------------------------
    table.sort(candidateItems, function(a, b)
        if a.destTabs[1] ~= b.destTabs[1] then
            return a.destTabs[1] < b.destTabs[1]
        end
        return a.srcTab < b.srcTab
    end)

    local DoNextCandidate -- forward declare
    local lastQueriedTab = nil -- track last queried tab to skip redundant queries

    -- Query a guild bank tab from the server and call callback when data is ready.
    -- Skips the query if we already have fresh data for this tab.
    -- Neither QueryGuildBankTab nor PickupGuildBankItem require SetCurrentGuildBankTab
    -- (both take tab as a parameter). We never call SetCurrentGuildBankTab to avoid
    -- visual tab flickering in the Blizzard UI.
    local function QueryTab(tab, callback)
        if not running or self:IsBulkCancelled(gen) then
            return
        end
        if not self:IsGuildBankOpen() then
            self:ChatMsg("|cff4d99ff[Bank]|r Guild Bank closed, stopping")
            Finish()
            return
        end
        -- Skip redundant query if we just queried this tab
        if lastQueriedTab == tab then
            callback()
            return
        end
        QueryGuildBankTab(tab)
        listener:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED")
        timer = C_Timer.NewTimer(2.0, function()
            timer = nil
            listener:UnregisterAllEvents()
            lastQueriedTab = tab
            if running and not self:IsBulkCancelled(gen) then
                callback()
            end
        end)
        listener:SetScript("OnEvent", function()
            listener:UnregisterAllEvents()
            if timer then
                timer:Cancel()
                timer = nil
            end
            if not running or self:IsBulkCancelled(gen) then
                return
            end
            lastQueriedTab = tab
            C_Timer.After(0.05, function()
                if running and not self:IsBulkCancelled(gen) then
                    callback()
                end
            end)
        end)
    end

    -- Update the Reorganize button with remaining count
    local function UpdateBtn()
        local btn = self._triageReorganizeBtn
        if btn then
            btn:SetText(string.format("Reorganizing... (%d left)", totalItems - movedCount))
        end
    end

    local fullTabs = {} -- tabs confirmed full, skip without querying
    local swappedTabs = {} -- tabs we already attempted a swap on (avoid infinite loops)

    -- Find a misplaced item in a guild bank tab (an item that doesn't belong there).
    -- Uses bankTriageResults: any STASH or TAKEOUT item in this tab is misplaced.
    local function FindMisplacedInTab(tab)
        local bankResults = self.bankTriageResults or {}
        for _, r in ipairs(bankResults) do
            if
                r.item.bankType == "guildbank"
                and r.item.srcTab == tab
                and (r.category == CAT_STASH or r.category == CAT_TAKEOUT)
            then
                return r.item.slot
            end
        end
        return nil
    end

    -- Wait for both GUILDBANKBAGSLOTS_CHANGED and BAG_UPDATE_DELAYED (or 2s timeout)
    local function WaitForGuildAndBag(callback)
        local gotGuild, gotBag = false, false
        local function TryProceed()
            if not running then
                return
            end
            if gotGuild and gotBag then
                listener:UnregisterAllEvents()
                if timer then
                    timer:Cancel()
                    timer = nil
                end
                C_Timer.After(0.1, function()
                    if running and not self:IsBulkCancelled(gen) then
                        callback()
                    end
                end)
            end
        end
        listener:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED")
        listener:RegisterEvent("BAG_UPDATE_DELAYED")
        timer = C_Timer.NewTimer(2.0, function()
            timer = nil
            listener:UnregisterAllEvents()
            if running and not self:IsBulkCancelled(gen) then
                callback()
            end
        end)
        listener:SetScript("OnEvent", function(_, event)
            if event == "GUILDBANKBAGSLOTS_CHANGED" then
                gotGuild = true
            end
            if event == "BAG_UPDATE_DELAYED" then
                gotBag = true
            end
            TryProceed()
        end)
    end

    -- Wait for just GUILDBANKBAGSLOTS_CHANGED (or 2s timeout)
    local function WaitForGuild(callback)
        listener:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED")
        timer = C_Timer.NewTimer(2.0, function()
            timer = nil
            listener:UnregisterAllEvents()
            if running and not self:IsBulkCancelled(gen) then
                callback()
            end
        end)
        listener:SetScript("OnEvent", function()
            listener:UnregisterAllEvents()
            if timer then
                timer:Cancel()
                timer = nil
            end
            if not running or self:IsBulkCancelled(gen) then
                return
            end
            C_Timer.After(0.1, function()
                if running and not self:IsBulkCancelled(gen) then
                    callback()
                end
            end)
        end)
    end

    -- Bag-staged swap: take a misplaced item from destTab to bags, then move candidate in
    local function TryBagStagedSwap(candidate, destTab)
        local misplacedSlot = FindMisplacedInTab(destTab)
        if not misplacedSlot then
            -- No misplaced item found in this tab, can't swap
            DoNextCandidate()
            return
        end

        local misplacedLink = GetGuildBankItemLink(destTab, misplacedSlot)
        local misplacedItemID = misplacedLink and select(1, C_Item.GetItemInfoInstant(misplacedLink))
        local freeBag, freeSlot = FindFreeBagSlotForItem(misplacedItemID)
        if not freeBag then
            self:ChatMsg("|cff4d99ff[Bank]|r No free bag space for swap staging")
            DoNextCandidate()
            return
        end

        -- Step 1: Take misplaced item from dest tab → bags
        QueryTab(destTab, function()
            -- Verify misplaced item still there
            local tex, _, locked = GetGuildBankItemInfo(destTab, misplacedSlot)
            if not tex or locked then
                DoNextCandidate()
                return
            end

            PickupGuildBankItem(destTab, misplacedSlot)
            C_Container.PickupContainerItem(freeBag, freeSlot)
            ClearCursor()
            lastQueriedTab = nil

            WaitForGuildAndBag(function()
                -- Verify item arrived in bags
                local bagInfo = C_Container.GetContainerItemInfo(freeBag, freeSlot)
                if not bagInfo then
                    -- Failed, skip
                    DoNextCandidate()
                    return
                end
                -- Track withdrawal from dest tab (step 1)
                if withdrawalsLeft[destTab] and withdrawalsLeft[destTab] > 0 then
                    withdrawalsLeft[destTab] = withdrawalsLeft[destTab] - 1
                end

                -- Step 2: Move candidate from source tab → freed dest slot
                if not VerifySource(candidate.srcTab, candidate.srcSlot, candidate.itemID) then
                    DoNextCandidate()
                    return
                end

                PickupGuildBankItem(candidate.srcTab, candidate.srcSlot)
                PickupGuildBankItem(destTab, misplacedSlot)
                ClearCursor()
                lastQueriedTab = nil

                WaitForGuild(function()
                    -- Verify the item actually left
                    QueryTab(candidate.srcTab, function()
                        if not VerifySource(candidate.srcTab, candidate.srcSlot, candidate.itemID) then
                            movedCount = movedCount + 1
                            fullTabs[candidate.srcTab] = nil
                            -- Track withdrawal from source tab (step 2)
                            local srcTab = candidate.srcTab
                            if withdrawalsLeft[srcTab] and withdrawalsLeft[srcTab] > 0 then
                                withdrawalsLeft[srcTab] = withdrawalsLeft[srcTab] - 1
                            end
                        end
                        UpdateBtn()
                        DoNextCandidate()
                    end)
                end)
            end)
        end)
    end

    -- Try to move a candidate item to one of its destination tabs
    local function TryMoveToDests(candidate, destIdx)
        if not running or self:IsBulkCancelled(gen) then
            return
        end
        if destIdx > #candidate.destTabs then
            -- All dest tabs full - try bag-staged swap on the first dest tab
            -- that has a misplaced item we can extract
            for _, dTab in ipairs(candidate.destTabs) do
                if not swappedTabs[dTab] then
                    swappedTabs[dTab] = true
                    local misplacedSlot = FindMisplacedInTab(dTab)
                    if misplacedSlot then
                        TryBagStagedSwap(candidate, dTab)
                        return
                    end
                end
            end
            -- No swap possible, skip this item
            DoNextCandidate()
            return
        end

        local destTab = candidate.destTabs[destIdx]

        -- Skip tabs we already know are full (no server round-trip needed)
        if fullTabs[destTab] then
            TryMoveToDests(candidate, destIdx + 1)
            return
        end

        QueryTab(destTab, function()
            local emptySlots = ScanTabEmpty(destTab)
            if #emptySlots == 0 then
                -- Mark as full so we don't query it again
                fullTabs[destTab] = true
                TryMoveToDests(candidate, destIdx + 1)
                return
            end

            -- Query source tab to verify item is still there (fresh data)
            QueryTab(candidate.srcTab, function()
                if not VerifySource(candidate.srcTab, candidate.srcSlot, candidate.itemID) then
                    -- Item already moved or gone, skip
                    DoNextCandidate()
                    return
                end

                -- Execute the move: PickupGuildBankItem takes tab as parameter,
                -- no SetCurrentGuildBankTab needed (confirmed by Blizzard source)
                local destSlot = emptySlots[1]
                PickupGuildBankItem(candidate.srcTab, candidate.srcSlot)
                PickupGuildBankItem(destTab, destSlot)
                ClearCursor()
                -- Invalidate cache for both tabs (contents changed)
                lastQueriedTab = nil

                -- Wait for confirmation, then verify the item actually left
                WaitForGuild(function()
                    QueryTab(candidate.srcTab, function()
                        if not VerifySource(candidate.srcTab, candidate.srcSlot, candidate.itemID) then
                            -- Item left source - success
                            movedCount = movedCount + 1
                            fullTabs[candidate.srcTab] = nil
                            -- Track withdrawal from source tab
                            local srcTab = candidate.srcTab
                            if withdrawalsLeft[srcTab] and withdrawalsLeft[srcTab] > 0 then
                                withdrawalsLeft[srcTab] = withdrawalsLeft[srcTab] - 1
                            end
                        end
                        -- (if still there, move failed silently - don't count it)
                        UpdateBtn()
                        DoNextCandidate()
                    end)
                end)
            end)
        end)
    end

    DoNextCandidate = function()
        if not running or self:IsBulkCancelled(gen) then
            return
        end
        if not self:IsGuildBankOpen() then
            self:ChatMsg("|cff4d99ff[Bank]|r Guild Bank closed, stopping")
            Finish()
            return
        end
        if moveIdx > #candidateItems then
            Finish()
            return
        end

        local candidate = candidateItems[moveIdx]
        moveIdx = moveIdx + 1

        -- Check withdrawal limit for source tab
        local srcTab = candidate.srcTab or 0
        local left = withdrawalsLeft[srcTab]
        if left == 0 then
            self:ChatMsg(
                string.format("|cff4d99ff[Bank]|r Tab %d: withdrawal limit reached, skipping remaining items", srcTab)
            )
            -- Skip all remaining items from this source tab
            while moveIdx <= #candidateItems and (candidateItems[moveIdx].srcTab or 0) == srcTab do
                moveIdx = moveIdx + 1
            end
            UpdateBtn()
            if moveIdx > #candidateItems then
                Finish()
            else
                C_Timer.After(0.1, DoNextCandidate)
            end
            return
        end

        TryMoveToDests(candidate, 1)
    end

    UpdateBtn()
    DoNextCandidate()
end

-------------------------------------------------------------------------------
-- Bank Triage: Take Out - charbank / warbandbank (C_Container API, reliable)
-------------------------------------------------------------------------------

function EmpireManager:TakeOutBankItems()
    if not self:IsBankOpen() then
        self:ChatMsg("Open a bank first", true)
        return
    end
    if InCombatLockdown() then
        self:ChatMsg("Cannot move items during combat", true)
        return
    end

    -- Guild bank uses a completely different API - delegate
    if self._triageActiveTab == "guildbank" then
        self:TakeOutGuildBankItems()
        return
    end

    local results = self.bankTriageResults or {}
    local skippedItems = self.bankTriageSkippedItems or {}
    local skippedActions = self.bankTriageSkippedActions or {}

    local activeTab = self._triageActiveTab
    local bankTypeFilter
    if activeTab == "bank" then
        bankTypeFilter = "charbank"
    elseif activeTab == "warband" then
        bankTypeFilter = "warbandbank"
    end

    local takeItems = {}
    for _, r in ipairs(results) do
        local actionKey = r.item.bankType and (r.item.bankType .. ":" .. r.action) or r.action
        local rowKey = (r.item.bankType or "") .. ":" .. (r.item.bag or 0) .. ":" .. (r.item.slot or 0)
        if
            r.category == CAT_TAKEOUT
            and (not bankTypeFilter or r.item.bankType == bankTypeFilter)
            and not skippedItems[rowKey]
            and not skippedActions[actionKey]
        then
            takeItems[#takeItems + 1] = r.item
        end
    end

    if #takeItems == 0 then
        self:ChatMsg("|cff4d99ff[Bank]|r No items to take out")
        return
    end

    -- Check bag space (includes reagent bag)
    local freeSlots = CountFreeBagSlots()
    if freeSlots == 0 then
        self:ChatMsg("|cff4d99ff[Bank]|r No free bag space")
        return
    end

    local gen = self:StartBulkOperation()
    local count = math.min(#takeItems, freeSlots)
    self:ChatVerbose(string.format("|cff4d99ff[Bank]|r Taking out %d item%s...", count, count == 1 and "" or "s"))

    -- Disable all bank buttons during operation
    local takeOutBtn = self._triageTakeOutBtn
    local reorganizeBtn = self._triageReorganizeBtn
    local rescanBtn = self._triageRescanBtn
    if takeOutBtn then
        takeOutBtn:SetText(string.format("Taking out... (%d left)", count))
        takeOutBtn:Disable()
    end
    if reorganizeBtn then
        reorganizeBtn:Disable()
    end
    if rescanBtn then
        rescanBtn:Disable()
    end

    local moveIdx = 1
    local movedCount = 0
    local failCount = 0
    local remaining = count
    local running = true

    local function UpdateProgress()
        if takeOutBtn then
            takeOutBtn:SetText(string.format("Taking out... (%d left)", remaining))
        end
    end

    local function Finish()
        running = false
        self._triageBulkOperating = false
        self:SnapshotOpenBankCapacity()
        local msg = string.format("|cff4d99ff[Bank]|r Took out %d item%s.", movedCount, movedCount == 1 and "" or "s")
        if failCount > 0 then
            msg = msg .. string.format(" (%d failed)", failCount)
        end
        self:ChatMsg(msg)
        CheckBagsFull()
        C_Timer.After(0.3, function()
            self._bankTriageFingerprint = nil
            self.bankTriageResults = nil -- invalidate cache - bank contents changed
            self:RefreshBankTriageDisplay(true)
        end)
    end

    local DoNext

    DoNext = function()
        if not running or self:IsBulkCancelled(gen) then
            return
        end
        if moveIdx > count then
            Finish()
            return
        end
        if not self:IsBankOpen() then
            self:ChatMsg("|cff4d99ff[Bank]|r Bank closed, stopping")
            Finish()
            return
        end

        local item = takeItems[moveIdx]
        moveIdx = moveIdx + 1

        -- Verify item still exists at the scanned location
        local srcLoc = ItemLocation:CreateFromBagAndSlot(item.bag, item.slot)
        if not C_Item.DoesItemExist(srcLoc) or C_Item.IsLocked(srcLoc) then
            failCount = failCount + 1
            remaining = remaining - 1
            UpdateProgress()
            C_Timer.After(0.1, function()
                if running and not self:IsBulkCancelled(gen) then
                    DoNext()
                end
            end)
            return
        end
        local srcInfo = C_Container.GetContainerItemInfo(item.bag, item.slot)
        if not srcInfo or srcInfo.itemID ~= item.itemID then
            failCount = failCount + 1
            remaining = remaining - 1
            UpdateProgress()
            C_Timer.After(0.1, function()
                if running and not self:IsBulkCancelled(gen) then
                    DoNext()
                end
            end)
            return
        end

        local freeBag, freeSlot = FindFreeBagSlotForItem(item.itemID)
        if not freeBag then
            self:ChatMsg("|cff4d99ff[Bank]|r Bags full, stopping")
            Finish()
            return
        end

        C_Container.PickupContainerItem(item.bag, item.slot)
        C_Container.PickupContainerItem(freeBag, freeSlot)
        ClearCursor()

        -- Poll the destination bag slot to verify the item actually arrived
        local pollCount = 0
        local maxPolls = 10 -- 10 * 0.2 = 2s
        local function PollSlot()
            if not running or self:IsBulkCancelled(gen) then
                return
            end
            if not self:IsBankOpen() then
                self:ChatMsg("|cff4d99ff[Bank]|r Bank closed, stopping")
                Finish()
                return
            end
            pollCount = pollCount + 1
            local info = C_Container.GetContainerItemInfo(freeBag, freeSlot)
            if info then
                -- Item arrived in the bag slot - success
                movedCount = movedCount + 1
                remaining = remaining - 1
                UpdateProgress()
                C_Timer.After(0.3, function()
                    if running and not self:IsBulkCancelled(gen) then
                        DoNext()
                    end
                end)
            elseif pollCount >= maxPolls then
                -- Timed out - item never arrived
                failCount = failCount + 1
                remaining = remaining - 1
                UpdateProgress()
                C_Timer.After(0.3, function()
                    if running and not self:IsBulkCancelled(gen) then
                        DoNext()
                    end
                end)
            else
                -- Not there yet, poll again
                C_Timer.After(0.2, PollSlot)
            end
        end
        -- Start polling after a short initial delay
        C_Timer.After(0.2, PollSlot)
    end

    DoNext()
end

-------------------------------------------------------------------------------
-- Guild Bank Take Out - cursor-based API, one item at a time, verified moves
-------------------------------------------------------------------------------

function EmpireManager:TakeOutGuildBankItems()
    if not self:IsGuildBankOpen() then
        self:ChatMsg("Open the Guild Bank first", true)
        return
    end

    local results = self.bankTriageResults or {}
    local skippedItems = self.bankTriageSkippedItems or {}
    local skippedActions = self.bankTriageSkippedActions or {}

    local takeItems = {}
    for _, r in ipairs(results) do
        local actionKey = r.item.bankType and (r.item.bankType .. ":" .. r.action) or r.action
        local rowKey = (r.item.bankType or "") .. ":" .. (r.item.bag or 0) .. ":" .. (r.item.slot or 0)
        if
            r.category == CAT_TAKEOUT
            and r.item.bankType == "guildbank"
            and not skippedItems[rowKey]
            and not skippedActions[actionKey]
        then
            takeItems[#takeItems + 1] = r.item
        end
    end

    if #takeItems == 0 then
        self:ChatMsg("|cff4d99ff[Bank]|r No items to take out")
        return
    end

    -- Sort by tab to minimize tab switches
    table.sort(takeItems, function(a, b)
        return (a.srcTab or 0) < (b.srcTab or 0)
    end)

    -- Read per-tab withdrawal limits
    local withdrawalsLeft = {}
    local numTabs = GetNumGuildBankTabs()
    for tab = 1, numTabs do
        local _, _, _, _, _, remaining = GetGuildBankTabInfo(tab)
        -- -1 means unlimited withdrawals
        withdrawalsLeft[tab] = remaining or -1
    end

    -- Filter out items from tabs with 0 withdrawals remaining
    local limitedTabs = {}
    local filtered = {}
    for _, item in ipairs(takeItems) do
        local tab = item.srcTab or 0
        local left = withdrawalsLeft[tab]
        if left == 0 then
            limitedTabs[tab] = true
        else
            filtered[#filtered + 1] = item
        end
    end
    if next(limitedTabs) then
        local tabList = {}
        for tab in pairs(limitedTabs) do
            tabList[#tabList + 1] = tab
        end
        table.sort(tabList)
        local tabStrs = {}
        for i, tab in ipairs(tabList) do
            tabStrs[i] = tostring(tab)
        end
        self:ChatMsg(
            string.format(
                "|cff4d99ff[Bank]|r Skipping tab%s %s - no withdrawals remaining today",
                #tabList == 1 and "" or "s",
                table.concat(tabStrs, ", ")
            )
        )
    end
    takeItems = filtered

    if #takeItems == 0 then
        self:ChatMsg("|cff4d99ff[Bank]|r No items to take out (withdrawal limits)")
        return
    end

    -- Check bag space (includes reagent bag)
    local freeSlots = CountFreeBagSlots()
    if freeSlots == 0 then
        self:ChatMsg("|cff4d99ff[Bank]|r No free bag space")
        return
    end

    local gen = self:StartBulkOperation()
    local count = math.min(#takeItems, freeSlots)
    self:ChatVerbose(
        string.format("|cff4d99ff[Bank]|r Taking out %d item%s from Guild Bank...", count, count == 1 and "" or "s")
    )

    -- Disable buttons during operation
    local takeOutBtn = self._triageTakeOutBtn
    local reorganizeBtn = self._triageReorganizeBtn
    local rescanBtn = self._triageRescanBtn
    if takeOutBtn then
        takeOutBtn:SetText(string.format("Taking out... (%d left)", count))
        takeOutBtn:Disable()
    end
    if reorganizeBtn then
        reorganizeBtn:Disable()
    end
    if rescanBtn then
        rescanBtn:Disable()
    end

    local moveIdx = 1
    local movedCount = 0
    local failCount = 0
    local listener = self:AcquireListener()
    local fallbackTimer
    local running = true
    local currentGBTab = nil
    local remaining = count

    local function UpdateProgress()
        if takeOutBtn then
            takeOutBtn:SetText(string.format("Taking out... (%d left)", remaining))
        end
    end

    local function Cleanup()
        running = false
        self:ReleaseListener(listener)
        if fallbackTimer then
            fallbackTimer:Cancel()
            fallbackTimer = nil
        end
    end

    local function Finish()
        Cleanup()
        self._triageBulkOperating = false
        self:SnapshotOpenBankCapacity()
        local msg = string.format("|cff4d99ff[Bank]|r Took out %d item%s.", movedCount, movedCount == 1 and "" or "s")
        if failCount > 0 then
            msg = msg .. string.format(" (%d failed)", failCount)
        end
        self:ChatMsg(msg)
        CheckBagsFull()
        -- Re-query all guild bank tabs we touched so the rescan gets fresh data.
        -- Collect unique tabs that were in takeItems.
        local queriedTabs = {}
        local tabsToQuery = {}
        for i = 1, math.min(moveIdx - 1, count) do
            local t = takeItems[i].srcTab
            if t and not queriedTabs[t] then
                queriedTabs[t] = true
                tabsToQuery[#tabsToQuery + 1] = t
            end
        end
        local function RefreshAfterRequery()
            self._bankTriageFingerprint = nil
            self.bankTriageResults = nil -- invalidate cache - bank contents changed
            self:RefreshBankTriageDisplay(true)
        end
        if #tabsToQuery == 0 then
            C_Timer.After(0.3, RefreshAfterRequery)
        else
            -- Query each tab sequentially, then refresh
            local qi = 1
            local reqListener = self:AcquireListener()
            local reqTimer
            local function QueryNext()
                if qi > #tabsToQuery then
                    self:ReleaseListener(reqListener)
                    if reqTimer then
                        reqTimer:Cancel()
                    end
                    C_Timer.After(0.3, RefreshAfterRequery)
                    return
                end
                local tab = tabsToQuery[qi]
                qi = qi + 1
                reqListener:UnregisterAllEvents()
                reqListener:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED")
                reqListener:SetScript("OnEvent", function()
                    reqListener:UnregisterAllEvents()
                    if reqTimer then
                        reqTimer:Cancel()
                        reqTimer = nil
                    end
                    C_Timer.After(0.1, QueryNext)
                end)
                reqTimer = C_Timer.NewTimer(2.0, function()
                    reqTimer = nil
                    reqListener:UnregisterAllEvents()
                    QueryNext()
                end)
                QueryGuildBankTab(tab)
            end
            QueryNext()
        end
    end

    local DoNext, QueryTab, MoveItem

    -- Query a guild bank tab, wait for data, and verify it's ready
    QueryTab = function(tab, item, callback)
        local retries = 0
        local maxRetries = 3

        local function TryQuery()
            listener:UnregisterAllEvents()
            listener:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED")
            listener:SetScript("OnEvent", function()
                listener:UnregisterAllEvents()
                if fallbackTimer then
                    fallbackTimer:Cancel()
                    fallbackTimer = nil
                end
                currentGBTab = tab
                -- Verify the item is visible in this tab before proceeding
                C_Timer.After(0.2, function()
                    if not running or self:IsBulkCancelled(gen) then
                        return
                    end
                    local link = GetGuildBankItemLink(item.srcTab, item.slot)
                    if link then
                        callback()
                    elseif retries < maxRetries then
                        retries = retries + 1
                        -- Data not ready yet, re-query
                        TryQuery()
                    else
                        callback() -- give up, MoveItem will handle the nil check
                    end
                end)
            end)
            fallbackTimer = C_Timer.NewTimer(3.0, function()
                fallbackTimer = nil
                listener:UnregisterAllEvents()
                currentGBTab = tab
                if running and not self:IsBulkCancelled(gen) then
                    callback()
                end
            end)
            QueryGuildBankTab(tab)
        end

        TryQuery()
    end

    -- Pick up one item, place it, poll destination slot to confirm arrival
    MoveItem = function(item)
        local freeBag, freeSlot = FindFreeBagSlotForItem(item.itemID)
        if not freeBag then
            self:ChatMsg("|cff4d99ff[Bank]|r Bags full, stopping")
            Finish()
            return
        end

        -- Verify item is still in the source slot
        local link = GetGuildBankItemLink(item.srcTab, item.slot)
        if not link then
            failCount = failCount + 1
            remaining = remaining - 1
            UpdateProgress()
            C_Timer.After(0.1, function()
                if running and not self:IsBulkCancelled(gen) then
                    DoNext()
                end
            end)
            return
        end

        -- Get the stack count to split
        local _, stackCount = GetGuildBankItemInfo(item.srcTab, item.slot)
        stackCount = stackCount or 1

        -- Use SplitGuildBankItem (like TSM) - more reliable than PickupGuildBankItem
        SplitGuildBankItem(item.srcTab, item.slot, stackCount)

        -- Verify cursor actually grabbed the item before placing
        if GetCursorInfo() ~= "item" then
            ClearCursor()
            failCount = failCount + 1
            remaining = remaining - 1
            UpdateProgress()
            C_Timer.After(0.5, function()
                if running and not self:IsBulkCancelled(gen) then
                    DoNext()
                end
            end)
            return
        end

        -- Place it in the bag slot and clear cursor
        C_Container.PickupContainerItem(freeBag, freeSlot)
        ClearCursor()

        -- Poll the destination bag slot to verify the item actually arrived.
        -- BAG_UPDATE_DELAYED is unreliable (fires even on failed moves).
        -- Poll every 0.2s up to 2s total.
        local pollCount = 0
        local maxPolls = 10 -- 10 * 0.2 = 2s
        local function PollSlot()
            if not running or self:IsBulkCancelled(gen) then
                return
            end
            if not self:IsGuildBankOpen() then
                self:ChatMsg("|cff4d99ff[Bank]|r Guild Bank closed, stopping")
                Finish()
                return
            end
            pollCount = pollCount + 1
            local info = C_Container.GetContainerItemInfo(freeBag, freeSlot)
            if info then
                -- Item arrived in the bag slot - success
                movedCount = movedCount + 1
                remaining = remaining - 1
                -- Track withdrawal limit
                local tab = item.srcTab or 0
                if withdrawalsLeft[tab] and withdrawalsLeft[tab] > 0 then
                    withdrawalsLeft[tab] = withdrawalsLeft[tab] - 1
                end
                UpdateProgress()
                -- Wait a beat before next move to avoid overwhelming the server
                C_Timer.After(0.3, function()
                    if not running or self:IsBulkCancelled(gen) then
                        return
                    end
                    if not self:IsGuildBankOpen() then
                        self:ChatMsg("|cff4d99ff[Bank]|r Guild Bank closed, stopping")
                        Finish()
                        return
                    end
                    DoNext()
                end)
            elseif pollCount >= maxPolls then
                -- Timed out - item never arrived
                failCount = failCount + 1
                remaining = remaining - 1
                UpdateProgress()
                C_Timer.After(0.3, function()
                    if not running or self:IsBulkCancelled(gen) then
                        return
                    end
                    if not self:IsGuildBankOpen() then
                        self:ChatMsg("|cff4d99ff[Bank]|r Guild Bank closed, stopping")
                        Finish()
                        return
                    end
                    DoNext()
                end)
            else
                -- Not there yet, poll again
                C_Timer.After(0.2, PollSlot)
            end
        end
        -- Start polling after a short initial delay
        C_Timer.After(0.2, PollSlot)
    end

    -- Process next item in the queue
    DoNext = function()
        if not running or self:IsBulkCancelled(gen) then
            return
        end
        if not self:IsGuildBankOpen() then
            self:ChatMsg("|cff4d99ff[Bank]|r Guild Bank closed, stopping")
            Finish()
            return
        end
        if moveIdx > count then
            Finish()
            return
        end

        local item = takeItems[moveIdx]
        moveIdx = moveIdx + 1

        -- Check withdrawal limit for this tab
        local tab = item.srcTab or 0
        local left = withdrawalsLeft[tab]
        if left == 0 then
            -- Skip remaining items from this tab
            self:ChatMsg(
                string.format("|cff4d99ff[Bank]|r Tab %d: withdrawal limit reached, skipping remaining items", tab)
            )
            -- Skip all remaining items from this tab
            while moveIdx <= count and (takeItems[moveIdx].srcTab or 0) == tab do
                remaining = remaining - 1
                failCount = failCount + 1
                moveIdx = moveIdx + 1
            end
            remaining = remaining - 1
            failCount = failCount + 1
            UpdateProgress()
            if moveIdx > count then
                Finish()
            else
                C_Timer.After(0.1, DoNext)
            end
            return
        end

        -- Query tab if we need to switch
        if item.srcTab ~= currentGBTab then
            QueryTab(item.srcTab, item, function()
                MoveItem(item)
            end)
        else
            MoveItem(item)
        end
    end

    DoNext()
end

-------------------------------------------------------------------------------
-- Item Input Box Helper (shift-click + drag-drop support)
-------------------------------------------------------------------------------

do
    local itemInputBoxes = {}
    -- hooksecurefunc avoids tainting ChatFrameUtil (which would propagate into
    -- secure Blizzard code like PopOutChat that compares secret-number accessIDs).
    -- The original InsertLink returns false when no chat box is active (ACTIVE_CHAT_EDIT_BOX
    -- is nil while our plain EditBox has focus), so the link is not inserted into chat
    -- and our hook below is the only handler that fires.
    hooksecurefunc(ChatFrameUtil, "InsertLink", function(link)
        if not link then return end
        for _, box in ipairs(itemInputBoxes) do
            if box:HasFocus() then
                box:SetText(link)
                return
            end
        end
    end)

    function EmpireManager:SetupItemInputBox(box)
        itemInputBoxes[#itemInputBoxes + 1] = box
        box:SetScript("OnReceiveDrag", function(self)
            local infoType, id = GetCursorInfo()
            if infoType == "item" then
                local link = select(2, C_Item.GetItemInfo(id))
                self:SetText(link or tostring(id))
                ClearCursor()
            end
        end)
        box:SetScript("OnMouseDown", function(self)
            local infoType, id = GetCursorInfo()
            if infoType == "item" then
                local link = select(2, C_Item.GetItemInfo(id))
                self:SetText(link or tostring(id))
                ClearCursor()
            end
        end)
    end
end

-- Helper: stretch the AddBox across the dialog width and pin AddButton to the right edge.
-- Call this BEFORE AddDialogSubtitle so the subtitle's shift logic picks up the new anchors.
local function StretchAddRow(frame)
    if not (frame.AddBox and frame.AddButton) then
        return
    end
    frame.AddButton:ClearAllPoints()
    frame.AddButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -24, -68)
    frame.AddBox:ClearAllPoints()
    frame.AddBox:SetPoint("TOPLEFT", frame, "TOPLEFT", 24, -68)
    frame.AddBox:SetPoint("RIGHT", frame.AddButton, "LEFT", -8, 0)
    -- Add breathing room between the controls and the scroll list below.
    if frame.ScrollFrame then
        frame.ScrollFrame:ClearAllPoints()
        frame.ScrollFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 24, -96)
        frame.ScrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -32, 16)
    end
end

-- Helper: add a gold subtitle below a dialog's TitleText, then push every direct child
-- frame down by SHIFT so the new line doesn't overlap existing widgets.
local function AddDialogSubtitle(frame, text)
    if frame._subtitle then
        frame._subtitle:SetText("|cffdaa520" .. text .. "|r")
        return
    end

    local SHIFT = 18
    -- Shift any child anchored relative to the frame's top edge before adding the subtitle.
    -- We only adjust each child's first anchor point; this matches the XML pattern where
    -- subtitleable widgets (AddBox, AddRow, ScrollFrame) are anchored TOP* to the parent.
    local skip = { CloseButton = true }
    for _, child in ipairs({ frame:GetChildren() }) do
        local key
        for k, v in pairs(frame) do
            if v == child then
                key = k
                break
            end
        end
        if not (key and skip[key]) then
            for i = 1, child:GetNumPoints() do
                local p, rel, rp, x, yo = child:GetPoint(i)
                if p and (p:find("TOP") or rp and rp:find("TOP")) then
                    child:SetPoint(p, rel, rp, x or 0, (yo or 0) - SHIFT)
                end
            end
        end
    end

    local fs = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fs:SetPoint("TOP", frame.TitleText, "BOTTOM", 0, -8)
    fs:SetPoint("LEFT", frame, "LEFT", 24, 0)
    fs:SetPoint("RIGHT", frame, "RIGHT", -24, 0)
    fs:SetJustifyH("CENTER")
    fs:SetWordWrap(true)
    fs:SetText("|cffdaa520" .. text .. "|r")
    frame._subtitle = fs
end

-------------------------------------------------------------------------------
-- Keep List Window
-------------------------------------------------------------------------------

function EmpireManager:ToggleKeeplistWindow()
    if self.keeplistFrame and self.keeplistFrame:IsShown() then
        self.keeplistFrame:Hide()
        return
    end
    if not self.keeplistFrame then
        self:CreateKeeplistWindow()
    else
        self.keeplistFrame:Show()
    end
    self:RefreshKeeplistDisplay()
end

function EmpireManager:CreateKeeplistWindow()
    local f = EmpireManagerKeeplistWindow
    f.TitleText:SetText("EmpireManager - Keep List")
    StretchAddRow(f)
    AddDialogSubtitle(
        f,
        "Items here are never touched by Triage. They stay wherever they are (bags or any bank), on any character, and are never Vendored, Mailed, or Stashed."
    )
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })
    f:SetBackdropColor(0.06, 0.06, 0.09, 0.95)
    f:RegisterForDrag("LeftButton")
    f:SetFrameStrata("HIGH")
    f.ScrollFrame:SetScrollChild(f.ScrollFrame.Content)

    self:SetupItemInputBox(f.AddBox)

    f.AddButton:SetText("Add")
    f.AddButton:SetScript("OnClick", function()
        local text = f.AddBox:GetText()
        local id = text and (tonumber(text:match("item:(%d+)")) or tonumber(text))
        if not id then
            self:ChatMsg("Invalid input. Shift-click an item or enter an item ID", true)
            return
        end
        local name = C_Item.GetItemInfo(id) or ("Item " .. id)
        f.AddBox:SetText("")
        self:AddToKeepList(id, name)
    end)

    f:Show()
    self.keeplistFrame = f
end

function EmpireManager:RefreshKeeplistDisplay()
    local f = self.keeplistFrame
    if not f then
        return
    end
    local sf = f.ScrollFrame
    local content = sf.Content
    content:SetWidth(sf:GetWidth())

    -- Clear previous
    if f._widgets then
        for _, w in ipairs(f._widgets) do
            if w.Hide then
                w:Hide()
            end
        end
    end
    f._widgets = {}
    local function Track(obj)
        f._widgets[#f._widgets + 1] = obj
        return obj
    end

    local bl = self.db.global.keepList or {}
    local sorted = {}
    for itemID, itemName in pairs(bl) do
        sorted[#sorted + 1] = { id = itemID, name = itemName }
    end
    table.sort(sorted, function(a, b)
        return a.name < b.name
    end)

    local y = 4

    if #sorted == 0 then
        local fs = Track(content:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
        fs:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
        fs:SetText("|cff999999No items on the Keep List.|r")
        y = y + 30
    else
        for _, entry in ipairs(sorted) do
            local row = Track(CreateFrame("Button", nil, content))
            row:SetSize(content:GetWidth() - 8, 20)
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -y)
            row:RegisterForClicks("LeftButtonUp")

            local itemName, itemLink, quality = C_Item.GetItemInfo(entry.id)
            local qc = ITEM_QUALITY_COLORS[(itemName and quality) or 1] or ITEM_QUALITY_COLORS[1]
            local icon = C_Item.GetItemIconByID(entry.id)
            local iconStr = icon and string.format("|T%s:16:16|t ", icon) or ""

            local nameFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            nameFs:SetPoint("LEFT", 2, 0)
            nameFs:SetWidth(row:GetWidth() - 30)
            nameFs:SetJustifyH("LEFT")
            nameFs:SetText(
                iconStr .. qc.hex .. entry.name .. "|r"
            )

            row:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT")
                if itemLink then
                    GameTooltip:SetHyperlink(itemLink)
                else
                    GameTooltip:SetItemByID(entry.id)
                end
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)

            -- Remove X button
            local xBtn = Track(CreateFrame("Button", nil, row))
            xBtn:SetSize(20, 20)
            xBtn:SetPoint("RIGHT", -2, 0)
            local xFs = xBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            xFs:SetAllPoints()
            xFs:SetText("|cffff4444X|r")
            xBtn:SetScript("OnClick", function()
                local popup =
                    StaticPopup_Show("EM_CONFIRM_REMOVE", string.format("Remove %s from Keep List?", entry.name))
                if popup then
                    popup.data = {
                        onConfirm = function()
                            bl[entry.id] = nil
                            self._bagsDirty = true -- force reclassification on next scan
                            self.bankTriageResults = nil
                            self:ChatMsg(string.format("Removed %s from Keep List.", entry.name), true)
                            self:RefreshKeeplistDisplay()
                            if self.triageFrame and self.triageFrame:IsShown() then
                                self:RefreshTriageDisplay(true)
                            end
                        end,
                    }
                end
            end)

            y = y + 22
        end
    end

    content:SetHeight(y + 10)
    sf:SetVerticalScroll(0)
end

-------------------------------------------------------------------------------
-- Vendor Whitelist Window
-------------------------------------------------------------------------------

function EmpireManager:ToggleVendorlistWindow()
    if self.vendorlistFrame and self.vendorlistFrame:IsShown() then
        self.vendorlistFrame:Hide()
        return
    end
    if not self.vendorlistFrame then
        self:CreateVendorlistWindow()
    else
        self.vendorlistFrame:Show()
    end
    self:RefreshVendorlistDisplay()
end

function EmpireManager:CreateVendorlistWindow()
    local f = EmpireManagerVendorlistWindow
    f.TitleText:SetText("EmpireManager - Vendor Whitelist")
    StretchAddRow(f)
    AddDialogSubtitle(f, "Items here are always sold by Triage, even if rules would normally protect them.")
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })
    f:SetBackdropColor(0.06, 0.06, 0.09, 0.95)
    f:RegisterForDrag("LeftButton")
    f:SetFrameStrata("HIGH")
    f.ScrollFrame:SetScrollChild(f.ScrollFrame.Content)

    self:SetupItemInputBox(f.AddBox)

    f.AddButton:SetText("Add")
    f.AddButton:SetScript("OnClick", function()
        local text = f.AddBox:GetText()
        local id = text and (tonumber(text:match("item:(%d+)")) or tonumber(text))
        if not id then
            self:ChatMsg("Invalid input. Shift-click an item or enter an item ID", true)
            return
        end
        local name = C_Item.GetItemInfo(id) or ("Item " .. id)
        f.AddBox:SetText("")
        self:AddToVendorList(id, name)
    end)

    f:Show()
    self.vendorlistFrame = f
end

function EmpireManager:RefreshVendorlistDisplay()
    local f = self.vendorlistFrame
    if not f then
        return
    end
    local sf = f.ScrollFrame
    local content = sf.Content
    content:SetWidth(sf:GetWidth())

    if f._widgets then
        for _, w in ipairs(f._widgets) do
            if w.Hide then
                w:Hide()
            end
        end
    end
    f._widgets = {}
    local function Track(obj)
        f._widgets[#f._widgets + 1] = obj
        return obj
    end

    local wl = self.db.global.vendorWhitelist or {}
    local sorted = {}
    for itemID, itemName in pairs(wl) do
        sorted[#sorted + 1] = { id = itemID, name = itemName }
    end
    table.sort(sorted, function(a, b)
        return a.name < b.name
    end)

    local y = 4

    if #sorted == 0 then
        local fs = Track(content:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
        fs:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
        fs:SetText("|cff999999No items on the Vendor Whitelist.|r")
        y = y + 30
    else
        for _, entry in ipairs(sorted) do
            local row = Track(CreateFrame("Button", nil, content))
            row:SetSize(content:GetWidth() - 8, 20)
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -y)
            row:RegisterForClicks("LeftButtonUp")

            local itemName, itemLink, quality = C_Item.GetItemInfo(entry.id)
            local qc = ITEM_QUALITY_COLORS[(itemName and quality) or 1] or ITEM_QUALITY_COLORS[1]
            local icon = C_Item.GetItemIconByID(entry.id)
            local iconStr = icon and string.format("|T%s:16:16|t ", icon) or ""

            local nameFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            nameFs:SetPoint("LEFT", 2, 0)
            nameFs:SetWidth(row:GetWidth() - 30)
            nameFs:SetJustifyH("LEFT")
            nameFs:SetText(
                iconStr .. qc.hex .. entry.name .. "|r"
            )

            row:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT")
                if itemLink then
                    GameTooltip:SetHyperlink(itemLink)
                else
                    GameTooltip:SetItemByID(entry.id)
                end
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)

            local xBtn = Track(CreateFrame("Button", nil, row))
            xBtn:SetSize(20, 20)
            xBtn:SetPoint("RIGHT", -2, 0)
            local xFs = xBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            xFs:SetAllPoints()
            xFs:SetText("|cffff4444X|r")
            xBtn:SetScript("OnClick", function()
                local popup =
                    StaticPopup_Show("EM_CONFIRM_REMOVE", string.format("Remove %s from Vendor Whitelist?", entry.name))
                if popup then
                    popup.data = {
                        onConfirm = function()
                            wl[entry.id] = nil
                            self._bagsDirty = true -- force reclassification on next scan
                            self.bankTriageResults = nil
                            self:ChatMsg(string.format("Removed %s from Vendor Whitelist.", entry.name), true)
                            self:RefreshVendorlistDisplay()
                            if self.triageFrame and self.triageFrame:IsShown() then
                                self:RefreshTriageDisplay(true)
                            end
                        end,
                    }
                end
            end)

            y = y + 22
        end
    end

    content:SetHeight(y + 10)
    sf:SetVerticalScroll(0)
end

-------------------------------------------------------------------------------
-- Guild Blacklist Window (hides guilds from storage dropdowns)
-------------------------------------------------------------------------------

function EmpireManager:ToggleGuildBlacklistWindow()
    if self.guildBlacklistFrame and self.guildBlacklistFrame:IsShown() then
        self.guildBlacklistFrame:Hide()
        return
    end
    if not self.guildBlacklistFrame then
        self:CreateGuildBlacklistWindow()
    else
        self.guildBlacklistFrame:Show()
    end
    self:RefreshGuildBlacklistDisplay()
end

function EmpireManager:CreateGuildBlacklistWindow()
    local f = EmpireManagerGuildBlacklistWindow
    f.TitleText:SetText("EmpireManager - Guild Blacklist")
    StretchAddRow(f)
    AddDialogSubtitle(f, "Guilds here are hidden from storage dropdowns (e.g. trial guilds).")
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })
    f:SetBackdropColor(0.06, 0.06, 0.09, 0.95)
    f:RegisterForDrag("LeftButton")
    f:SetFrameStrata("HIGH")
    f.ScrollFrame:SetScrollChild(f.ScrollFrame.Content)

    -- Guild dropdown + Add button in AddRow
    local addRow = f.AddRow
    -- Selection is a (guild, realm) pair: two guilds can share a name on
    -- different realms and must be blacklistable independently.
    local selectedGuild, selectedRealm = nil, nil

    local guildDD = CreateFrame("DropdownButton", nil, addRow, "WowStyle1DropdownTemplate")
    f._guildDD = guildDD

    local guildSelIdx
    local function RebuildGuildDropdown()
        guildDD:SetupMenu(function(_, rootDescription)
            rootDescription:SetScrollMode(20 * 20)
            guildSelIdx = nil
            -- Dedupe on name+realm, and disambiguate the label with the realm
            -- only when the same guild name exists on more than one realm.
            local nameCounts, guilds, seen = {}, {}, {}
            for _, entry in pairs(self.db.global.registry) do
                local g, r = entry.guild, entry.guildRealm or ""
                if g and g ~= "" and not self:IsGuildBlacklisted(g, r) then
                    -- GuildKey collapses the two stored realm spellings; fall
                    -- back to a raw key when the realm is empty (GuildKey nils).
                    local key = self:GuildKey(g, r) or (g .. "\1" .. r)
                    if not seen[key] then
                        seen[key] = true
                        guilds[#guilds + 1] = { guild = g, realm = r }
                        nameCounts[g] = (nameCounts[g] or 0) + 1
                    end
                end
            end
            for _, item in ipairs(guilds) do
                if nameCounts[item.guild] > 1 and item.realm ~= "" then
                    item.label = item.guild .. " - " .. item.realm
                else
                    item.label = item.guild
                end
            end
            table.sort(guilds, function(a, b)
                return a.label:lower() < b.label:lower()
            end)
            for i, item in ipairs(guilds) do
                if item.guild == selectedGuild and item.realm == selectedRealm then
                    guildSelIdx = i
                end
                rootDescription:CreateRadio(item.label, function()
                    return selectedGuild == item.guild and selectedRealm == item.realm
                end, function()
                    selectedGuild, selectedRealm = item.guild, item.realm
                end)
            end
        end)
    end
    self:EnableDropdownScrollToSelected(guildDD, function() return guildSelIdx end)
    RebuildGuildDropdown()
    self._guildBlacklistRebuildDD = RebuildGuildDropdown

    local addBtn = CreateFrame("Button", nil, addRow, "UIPanelButtonTemplate")
    addBtn:SetSize(60, 24)
    addBtn:SetPoint("RIGHT", addRow, "RIGHT", 0, 0)
    addBtn:SetText("Add")
    guildDD:SetPoint("LEFT", addRow, "LEFT", 4, 0)
    guildDD:SetPoint("RIGHT", addBtn, "LEFT", -8, 0)
    addBtn:SetScript("OnClick", function()
        if not selectedGuild or selectedGuild == "" then
            self:ChatMsg("Select a Guild first", true)
            return
        end
        if not self.db.global.guildBlacklist then
            self.db.global.guildBlacklist = {}
        end
        -- Store under the composite GuildKey so a same-named guild on another
        -- realm stays visible. Falls back to the bare name when the realm is
        -- unknown (registry entry captured before guildRealm existed).
        local blKey = self:GuildKey(selectedGuild, selectedRealm) or selectedGuild
        self.db.global.guildBlacklist[blKey] = true
        local shown = (selectedRealm and selectedRealm ~= "")
                and (selectedGuild .. " - " .. selectedRealm)
            or selectedGuild
        self:ChatMsg(string.format("Blacklisted Guild |cffffcc00%s|r - hidden from storage options.", shown), true)
        selectedGuild, selectedRealm = nil, nil
        RebuildGuildDropdown()
        self:RefreshGuildBlacklistDisplay()
    end)

    f:Show()
    self.guildBlacklistFrame = f
end

function EmpireManager:RefreshGuildBlacklistDisplay()
    local f = self.guildBlacklistFrame
    if not f then
        return
    end
    local sf = f.ScrollFrame
    local content = sf.Content
    content:SetWidth(sf:GetWidth())

    if f._widgets then
        for _, w in ipairs(f._widgets) do
            if w.Hide then
                w:Hide()
            end
        end
    end
    f._widgets = {}
    local function Track(obj)
        f._widgets[#f._widgets + 1] = obj
        return obj
    end

    local bl = self.db.global.guildBlacklist or {}
    -- Keys are "Guild-Realm" composites (or bare guild names for legacy
    -- entries). Show the realm as a readable suffix but remove by the raw key.
    local sorted = {}
    for blKey in pairs(bl) do
        local g, r = blKey:match("^(.+)-([^-]+)$")
        sorted[#sorted + 1] = {
            key = blKey,
            label = (g and r) and (g .. " - " .. r) or blKey,
        }
    end
    table.sort(sorted, function(a, b)
        return a.label:lower() < b.label:lower()
    end)

    local y = 4

    if #sorted == 0 then
        local fs = Track(content:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
        fs:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
        fs:SetPoint("RIGHT", content, "RIGHT", -8, 0)
        fs:SetJustifyH("LEFT")
        fs:SetText("|cff999999No Guilds on the Blacklist. All Guilds appear in storage options.|r")
        y = y + 30
    else
        for _, blItem in ipairs(sorted) do
            local guildName = blItem.label
            local row = Track(CreateFrame("Button", nil, content))
            row:SetSize(content:GetWidth() - 8, 20)
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -y)

            local nameFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            nameFs:SetPoint("LEFT", 2, 0)
            nameFs:SetWidth(row:GetWidth() - 30)
            nameFs:SetJustifyH("LEFT")
            nameFs:SetText("|cffffcc00" .. guildName .. "|r")

            local xBtn = Track(CreateFrame("Button", nil, row))
            xBtn:SetSize(20, 20)
            xBtn:SetPoint("RIGHT", -2, 0)
            local xFs = xBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            xFs:SetAllPoints()
            xFs:SetText("|cffff4444X|r")
            xBtn:SetScript("OnClick", function()
                local popup = StaticPopup_Show(
                    "EM_CONFIRM_REMOVE",
                    string.format("Remove |cffffcc00%s|r from Guild Blacklist?", guildName)
                )
                if popup then
                    popup.data = {
                        onConfirm = function()
                            bl[blItem.key] = nil
                            self:ChatMsg(string.format("Removed |cffffcc00%s|r from Guild Blacklist.", guildName), true)
                            if self._guildBlacklistRebuildDD then
                                self._guildBlacklistRebuildDD()
                            end
                            self:RefreshGuildBlacklistDisplay()
                        end,
                    }
                end
            end)
            xBtn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                GameTooltip:SetText("Remove from Blacklist", 1, 0.3, 0.3)
                GameTooltip:Show()
            end)
            xBtn:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)

            y = y + 22
        end
    end

    content:SetHeight(y + 10)
    sf:SetVerticalScroll(0)
end

-------------------------------------------------------------------------------
-- Character Blacklist Window
-------------------------------------------------------------------------------

function EmpireManager:ToggleCharBlacklistWindow()
    if self.charBlacklistFrame and self.charBlacklistFrame:IsShown() then
        self.charBlacklistFrame:Hide()
        return
    end
    if not self.charBlacklistFrame then
        self:CreateCharBlacklistWindow()
    else
        self.charBlacklistFrame:Show()
    end
    self:RefreshCharBlacklistDisplay()
end

function EmpireManager:CreateCharBlacklistWindow()
    local f = EmpireManagerCharBlacklistWindow
    f.TitleText:SetText("EmpireManager - Character Blacklist")
    StretchAddRow(f)
    AddDialogSubtitle(f, "Characters here are excluded from the Roster and all data tracking.")
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })
    f:SetBackdropColor(0.06, 0.06, 0.09, 0.95)
    f:RegisterForDrag("LeftButton")
    f:SetFrameStrata("HIGH")
    f.ScrollFrame:SetScrollChild(f.ScrollFrame.Content)

    f:Show()
    self.charBlacklistFrame = f
end

function EmpireManager:RefreshCharBlacklistDisplay()
    local f = self.charBlacklistFrame
    if not f then
        return
    end
    local sf = f.ScrollFrame
    local content = sf.Content
    content:SetWidth(sf:GetWidth())

    if f._widgets then
        for _, w in ipairs(f._widgets) do
            if w.Hide then
                w:Hide()
            end
        end
    end
    f._widgets = {}
    local function Track(obj)
        f._widgets[#f._widgets + 1] = obj
        return obj
    end

    local bl = self.db.global.charBlacklist or {}
    local sorted = {}
    for guid, label in pairs(bl) do
        sorted[#sorted + 1] = { guid = guid, label = label }
    end
    table.sort(sorted, function(a, b)
        return a.label:lower() < b.label:lower()
    end)

    local y = 4

    if #sorted == 0 then
        local fs = Track(content:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
        fs:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
        fs:SetPoint("RIGHT", content, "RIGHT", -8, 0)
        fs:SetJustifyH("LEFT")
        fs:SetText("|cff999999No characters on the Blacklist. All characters are tracked.|r")
        y = y + 30
    else
        for _, entry in ipairs(sorted) do
            local row = Track(CreateFrame("Button", nil, content))
            row:SetSize(content:GetWidth() - 8, 20)
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -y)

            local nameFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            nameFs:SetPoint("LEFT", 2, 0)
            nameFs:SetWidth(row:GetWidth() - 30)
            nameFs:SetJustifyH("LEFT")
            nameFs:SetText("|cffffcc00" .. entry.label .. "|r")

            local xBtn = Track(CreateFrame("Button", nil, row))
            xBtn:SetSize(20, 20)
            xBtn:SetPoint("RIGHT", -2, 0)
            local xFs = xBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            xFs:SetAllPoints()
            xFs:SetText("|cffff4444X|r")
            xBtn:SetScript("OnClick", function()
                local popup = StaticPopup_Show(
                    "EM_CONFIRM_REMOVE",
                    string.format("Remove |cffffcc00%s|r from character Blacklist?", entry.label)
                )
                if popup then
                    popup.data = {
                        onConfirm = function()
                            bl[entry.guid] = nil
                            if entry.guid == self.playerGUID then
                                self:OnEnable()
                            end
                            self:SendMessage("EM_DASHBOARD_REFRESH")
                            self:ChatMsg(
                                string.format("Removed |cffffcc00%s|r from character Blacklist.", entry.label),
                                true
                            )
                            self:RefreshCharBlacklistDisplay()
                        end,
                    }
                end
            end)
            xBtn:SetScript("OnEnter", function(btn)
                GameTooltip:SetOwner(btn, "ANCHOR_CURSOR")
                GameTooltip:SetText("Remove from Blacklist", 1, 0.3, 0.3)
                GameTooltip:Show()
            end)
            xBtn:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)

            y = y + 22
        end
    end

    content:SetHeight(y + 10)
    sf:SetVerticalScroll(0)
end

-------------------------------------------------------------------------------
-- TSM Group Mover
-------------------------------------------------------------------------------

function EmpireManager:GroupMoverDirectionText()
    local from = self._groupMoverFrom
    local to = self._groupMoverTo
    if from and to then
        return string.format("%s to %s",
            self:GroupMoverEndpointLabel(from) or "?",
            self:GroupMoverEndpointLabel(to) or "?")
    end
    return "No Group selected"
end

-- Button press only: TSM API calls must stay user-initiated.
function EmpireManager:GetTSMGroupPaths()
    if not TSM_API then
        return {}
    end
    local ok, paths = pcall(function()
        local result = {}
        TSM_API.GetGroupPaths(result)
        return result
    end)
    if not ok or type(paths) ~= "table" then
        return {}
    end
    table.sort(paths)
    return paths
end

local GROUPMOVER_ROW_HEIGHT = 22

-- TSM paths use backticks: "A`B`C" is C inside B inside A. Returns a flat list;
-- depth drives the indent.
local function BuildGroupTree(paths, expanded, search)
    local nodes, seen = {}, {}
    search = (search or ""):lower()

    local all = {}
    for _, path in ipairs(paths) do
        all[path] = true
        local acc = nil
        for part in string.gmatch(path, "[^`]+") do
            acc = acc and (acc .. "`" .. part) or part
            all[acc] = true
        end
    end
    local ordered = {}
    for path in pairs(all) do
        ordered[#ordered + 1] = path
    end
    table.sort(ordered)

    local hasChildren = {}
    for _, path in ipairs(ordered) do
        local parent = string.match(path, "^(.*)`[^`]+$")
        if parent then
            hasChildren[parent] = true
        end
    end

    for _, path in ipairs(ordered) do
        local leaf = string.match(path, "([^`]+)$") or path
        local depth = 0
        for _ in string.gmatch(path, "`") do
            depth = depth + 1
        end

        local visible
        if search ~= "" then
            visible = leaf:lower():find(search, 1, true) ~= nil
            depth = 0
        else
            visible = true
            local acc = nil
            for part in string.gmatch(path, "[^`]+") do
                local nextAcc = acc and (acc .. "`" .. part) or part
                if nextAcc ~= path and not expanded[nextAcc] then
                    visible = false
                    break
                end
                acc = nextAcc
            end
        end

        if visible and not seen[path] then
            seen[path] = true
            nodes[#nodes + 1] = {
                path = path,
                label = leaf,
                depth = depth,
                hasChildren = hasChildren[path] or false,
            }
        end
    end
    return nodes
end

-- Not filtered by which bank is open: reachability is checked at move time.
EmpireManager.GROUPMOVER_ENDPOINTS = {
    { key = "bags", label = "Character Bags" },
    { key = "warbandbank", label = "Warband Bank" },
    { key = "guildbank", label = "Guild Bank" },
    { key = "charbank", label = "Character Bank" },
}

function EmpireManager:GroupMoverEndpointLabel(key)
    for _, e in ipairs(self.GROUPMOVER_ENDPOINTS) do
        if e.key == key then
            return e.label
        end
    end
    return nil
end

-- Exactly one end must be bags: WoW has no bank-to-bank move.
function EmpireManager:GroupMoverPairValid(from, to)
    if not from or not to or from == to then
        return false
    end
    return (from == "bags") ~= (to == "bags")
end

function EmpireManager:InitGroupMoverDialog()
    local f = EmpireManagerGroupMoverDialog
    if f._initialized then
        return f
    end
    f._initialized = true

    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })
    f:SetBackdropColor(0.06, 0.06, 0.09, 1)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f.TitleText:SetText("Select TSM Group")
    f.CancelButton:SetText("Cancel")
    f.SelectButton:SetText("Move")
    f.CancelButton:SetScript("OnClick", function()
        f:Hide()
    end)
    f:SetScript("OnKeyDown", function(frame, key)
        if key == "ESCAPE" then
            frame:SetPropagateKeyboardInput(false)
            frame:Hide()
        else
            frame:SetPropagateKeyboardInput(true)
        end
    end)

    f.SearchBox = CreateFrame("EditBox", nil, f.FilterRow, "SearchBoxTemplate")
    f.SearchBox:SetPoint("LEFT", f.FilterRow, "LEFT", 8, 0)
    f.SearchBox:SetPoint("RIGHT", f.FilterRow, "RIGHT", 0, 0)
    f.SearchBox:SetHeight(22)

    local LABEL_W = 44
    local fromLabel = f.RouteRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fromLabel:SetPoint("TOPLEFT", f.RouteRow, "TOPLEFT", 0, -4)
    fromLabel:SetWidth(LABEL_W)
    fromLabel:SetJustifyH("LEFT")
    fromLabel:SetText("From:")
    f.FromDD = CreateFrame("DropdownButton", nil, f.RouteRow, "WowStyle1DropdownTemplate")
    f.FromDD:SetPoint("LEFT", fromLabel, "RIGHT", 6, 0)
    f.FromDD:SetWidth(302)
    f.FromDD:SetHeight(24)

    local toLabel = f.RouteRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    toLabel:SetPoint("TOPLEFT", fromLabel, "BOTTOMLEFT", 0, -10)
    toLabel:SetWidth(LABEL_W)
    toLabel:SetJustifyH("LEFT")
    toLabel:SetText("To:")
    f.ToDD = CreateFrame("DropdownButton", nil, f.RouteRow, "WowStyle1DropdownTemplate")
    f.ToDD:SetPoint("LEFT", toLabel, "RIGHT", 6, 0)
    f.ToDD:SetWidth(302)
    f.ToDD:SetHeight(24)

    -- Swap button, vertically centred between the two dropdowns so neither moves.
    f.SwapButton = CreateFrame("Button", nil, f.RouteRow)
    f.SwapButton:SetSize(22, 22)
    f.SwapButton:SetPoint("LEFT", f.FromDD, "RIGHT", 8, -11)
    local swapTex = [[Interface\AddOns\EmpireManager\Textures\swap]]
    f.SwapButton:SetNormalTexture(swapTex)
    f.SwapButton:SetHighlightTexture(swapTex, "ADD")
    f.SwapButton:GetHighlightTexture():SetAlpha(0.4)
    f.SwapButton:SetPushedTexture(swapTex)
    f.SwapButton:GetPushedTexture():SetVertexColor(0.7, 0.7, 0.7)
    f.SwapButton:SetScript("OnClick", function()
        f._from, f._to = f._to, f._from
        f._toUserSet = true
        if f._refreshRoute then
            f._refreshRoute()
        end
    end)
    f.SwapButton:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
        GameTooltip:SetText("Swap From and To")
        GameTooltip:Show()
    end)
    f.SwapButton:SetScript("OnLeave", GameTooltip_Hide)

    f.RouteWarn = f.RouteRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.RouteWarn:SetPoint("TOPLEFT", f.RouteRow, "BOTTOMLEFT", 0, 12)
    f.RouteWarn:SetPoint("TOPRIGHT", f.RouteRow, "BOTTOMRIGHT", 0, 12)
    f.RouteWarn:SetJustifyH("LEFT")
    f.RouteWarn:SetTextColor(1, 0.3, 0.3)
    f.RouteWarn:Hide()

    f.ScrollBox = f.ListInset.ScrollBox
    f.ScrollBar = f.ListInset.ScrollBar
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(GROUPMOVER_ROW_HEIGHT)
    view:SetElementInitializer("EMGroupMoverRowTemplate", function(frame, node)
        if not frame._built then
            frame._built = true
            frame.Expand = frame:CreateTexture(nil, "OVERLAY")
            frame.Expand:SetSize(14, 14)
            frame.NameFs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            frame.NameFs:SetJustifyH("LEFT")
            -- One line, ellipsis on overflow: the row is 22px, a wrapped second
            -- line would be clipped.
            frame.NameFs:SetWordWrap(false)
            frame.NameFs:SetMaxLines(1)
            frame.CountFs = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            frame.CountFs:SetPoint("RIGHT", frame, "RIGHT", -8, 0)
            frame.SelTex = frame:CreateTexture(nil, "ARTWORK")
            frame.SelTex:SetAllPoints(frame)
            frame.SelTex:SetColorTexture(1, 0.82, 0, 0.20)
            frame.SelTex:Hide()
        end
        frame.Stripe:SetAtlas((node.index % 2 == 0) and "auctionhouse-rowstripe-1"
            or "auctionhouse-rowstripe-2")

        local indent = 14 + node.depth * 14
        frame.Expand:ClearAllPoints()
        frame.Expand:SetPoint("LEFT", frame, "LEFT", indent - 12, 0)
        if node.hasChildren then
            frame.Expand:SetTexture(node.expanded
                and [[Interface\Buttons\UI-MinusButton-UP]]
                or [[Interface\Buttons\UI-PlusButton-UP]])
            frame.Expand:Show()
        else
            frame.Expand:Hide()
        end
        frame.NameFs:ClearAllPoints()
        frame.NameFs:SetPoint("LEFT", frame, "LEFT", indent + 6, 0)
        frame.NameFs:SetPoint("RIGHT", frame.CountFs, "LEFT", -6, 0)
        frame.NameFs:SetText(node.label)
        frame.CountFs:SetText("")
        frame.SelTex:SetShown(node.selected and true or false)

        frame:SetScript("OnClick", function()
            -- +/- icon or double-click folds; anywhere else selects.
            local dlg = EmpireManagerGroupMoverDialog
            local now = GetTime()
            local cursorX = GetCursorPosition()
            local scale = frame:GetEffectiveScale()
            local localX = (cursorX / scale) - frame:GetLeft()
            local onIcon = node.hasChildren and localX < indent + 4

            local isDouble = dlg._lastClickPath == node.path
                and dlg._lastClickAt
                and (now - dlg._lastClickAt) < 0.4
            dlg._lastClickPath = node.path
            dlg._lastClickAt = now

            if onIcon or (isDouble and node.hasChildren) then
                dlg._lastClickAt = nil
                dlg._toggle(node.path)
            else
                dlg._select(node.path)
            end
        end)
    end)
    ScrollUtil.InitScrollBoxListWithScrollBar(f.ScrollBox, f.ScrollBar, view)

    return f
end

-- Group picker: search + expand/collapse tree. Parents are selectable directly.
function EmpireManager:OpenGroupMoverPicker()
    if self._triageBulkOperating then
        self:ChatMsg("|cff4d99ff[Mover]|r Wait for the current operation to finish.", true)
        return
    end
    -- Already open: raise it rather than rebuilding the tree and losing the
    -- current search / selection.
    local existing = EmpireManagerGroupMoverDialog
    if existing and existing:IsShown() then
        existing:Raise()
        return
    end
    local paths = self:GetTSMGroupPaths()
    if #paths == 0 then
        self:ChatMsg("|cff4d99ff[Mover]|r No TSM Groups found.", true)
        return
    end

    local f = self:InitGroupMoverDialog()
    f._expanded = f._expanded or {}
    f._selected = self._groupMoverPath
    f._paths = paths

    if not f._from then
        f._from = "bags"
    end
    -- Re-evaluate the destination on every open unless the user picked one this
    -- session: the open bank is almost always the one meant.
    if not f._toUserSet then
        if self:IsGuildBankOpen() then
            f._to = "guildbank"
        elseif self.bankIsOpen and self:IsWarbandBankOnly() then
            f._to = "warbandbank"
        elseif self.bankIsOpen then
            f._to = "charbank"
        else
            f._to = "warbandbank"
        end
    end

    local function RefreshRoute()
        f.FromDD:OverrideText(self:GroupMoverEndpointLabel(f._from) or "?")
        f.ToDD:OverrideText(self:GroupMoverEndpointLabel(f._to) or "?")

        -- Both menus list all four endpoints, always. Only the entry matching the
        -- Both dropdowns stay free; an invalid pair just disables Move. Disabling
        -- options deadlocked the pair, and auto-flipping fought the user.
        f.FromDD:SetupMenu(function(_, root)
            for _, e in ipairs(self.GROUPMOVER_ENDPOINTS) do
                root:CreateRadio(e.label, function()
                    return f._from == e.key
                end, function()
                    f._from = e.key
                    if f._refreshRoute then
                        f._refreshRoute()
                    end
                end)
            end
        end)

        f.ToDD:SetupMenu(function(_, root)
            for _, e in ipairs(self.GROUPMOVER_ENDPOINTS) do
                root:CreateRadio(e.label, function()
                    return f._to == e.key
                end, function()
                    f._to = e.key
                    f._toUserSet = true
                    if f._refreshRoute then
                        f._refreshRoute()
                    end
                end)
            end
        end)

        -- Warn when an end is a bank the character is not standing at.
        local warn
        if f._from == f._to then
            warn = "Pick two different places."
        elseif not self:GroupMoverPairValid(f._from, f._to) then
            warn = "Items cannot move bank to bank - one end must be Character Bags."
        else
            for _, key in ipairs({ f._from, f._to }) do
                if key ~= "bags" and not self:GroupMoverEndpointOpen(key) then
                    warn = "You must be at the " .. self:GroupMoverEndpointLabel(key) .. " for this move."
                    break
                end
            end
        end
        if warn then
            f.RouteWarn:SetText(warn)
            f.RouteWarn:Show()
        else
            f.RouteWarn:Hide()
        end

        local reason
        if not f._selected then
            reason = "Select a Group first"
        elseif f._from == f._to then
            reason = "From and To are the same"
        elseif not self:GroupMoverPairValid(f._from, f._to) then
            reason = "One end must be Character Bags"
        end
        f.SelectButton._disabledReason = reason
        f.SelectButton:SetEnabled(reason == nil)
    end
    f._refreshRoute = RefreshRoute

    local function Rebuild()
        local nodes = BuildGroupTree(f._paths, f._expanded, f.SearchBox:GetText())
        local data = {}
        for i, node in ipairs(nodes) do
            node.index = i
            node.expanded = f._expanded[node.path]
            node.selected = (node.path == f._selected)
            data[#data + 1] = node
        end
        -- SetDataProvider resets scroll to the top; a fold/unfold should not move
        -- the view out from under the user.
        local savedPct = f.ScrollBox:GetScrollPercentage()
        f.ScrollBox:SetDataProvider(CreateDataProvider(data))
        if savedPct and savedPct > 0 then
            C_Timer.After(0, function()
                f.ScrollBox:SetScrollPercentage(savedPct)
            end)
        end
        f.DescText:SetText(string.format(
            "%d Group%s shown. Click a Group to select it, +/- to expand.",
            #data, #data == 1 and "" or "s"))
        if f._refreshRoute then
            f._refreshRoute()
        end
    end
    f._rebuild = Rebuild

    f._toggle = function(path)
        f._expanded[path] = (not f._expanded[path]) or nil
        Rebuild()
    end
    f._select = function(path)
        f._selected = path
        Rebuild()
    end

    if not f._searchHooked then
        f._searchHooked = true
        f.SearchBox:HookScript("OnTextChanged", function()
            if f._rebuild then
                f._rebuild()
            end
        end)
    end

    f.SelectButton:SetScript("OnClick", function()
        local path = f._selected
        if not path then
            return
        end
        if self._triageBulkOperating then
            self:ChatMsg("|cff4d99ff[Mover]|r Wait for the current operation to finish.", true)
            return
        end
        local items = {}
        pcall(function()
            TSM_API.GetGroupItems(path, true, items)
        end)
        local label = path
        if TSM_API.FormatGroupPath then
            local ok, formatted = pcall(TSM_API.FormatGroupPath, path)
            if ok and formatted then
                label = formatted
            end
        end
        self._groupMoverPath = path
        self._groupMoverLabel = label
        self._groupMoverItems = items
        self._groupMoverFrom = f._from
        self._groupMoverTo = f._to
        local usable = self:GroupMoverSetItems(items)
        self:ChatMsg(string.format(
            "|cff4d99ff[Mover]|r Selected |cffffd200%s|r - %d item%s. %s to %s.",
            label, usable, usable == 1 and "" or "s",
            self:GroupMoverEndpointLabel(f._from) or "?",
            self:GroupMoverEndpointLabel(f._to) or "?"))
        f:Hide()
        -- Group items now claim their rows on the next scan; the existing bulk
        -- actions do the moving.
        -- Show the tab the items will appear on, so the result is visible.
        local tabForEndpoint = {
            bags = "bags",
            charbank = "bank",
            warbandbank = "warband",
            guildbank = "guildbank",
        }
        -- Tab enable states are computed on bank open; refresh them here so a
        -- tab that became reachable since the window opened can be switched to.
        self:UpdateTriageTabButtons()
        local wantTab = tabForEndpoint[f._from]
        if wantTab and wantTab ~= self._triageActiveTab then
            self:InvalidateStorageCache()
            self:SwitchTriageTab(wantTab)
        else
            self:InvalidateStorageCache(true)
        end
    end)

    -- Bank state changes while the dialog is open, so re-check rather than
    -- only computing this when the user touches a control.
    f:SetScript("OnUpdate", function(frame, elapsed)
        frame._warnTick = (frame._warnTick or 0) + elapsed
        if frame._warnTick < 0.5 then
            return
        end
        frame._warnTick = 0
        if f._refreshRoute then
            f._refreshRoute()
        end
    end)

    f.SearchBox:SetText("")
    RefreshRoute()
    Rebuild()
    f:Show()
end
