-- ----------------------------------------------------------------------------
--                                   EmpireManager
--                              https://wow.cyberpunk.gr
--                (c) by George Litos (l0neshad0w),  All Rights Reserved
--                   For detailed license information check LICENSE.md
-- ----------------------------------------------------------------------------

local EmpireManager = LibStub("AceAddon-3.0"):GetAddon("EmpireManager")

-------------------------------------------------------------------------------
-- Reusable event listener frame pool (WoW frames can't be GC'd)
-- Exposed as addon methods since deposit/mail actions in Triage.lua need them.
-------------------------------------------------------------------------------

local listenerPool = {}
local activeListeners = {}
function EmpireManager:AcquireListener()
    local f = table.remove(listenerPool)
    if not f then
        f = CreateFrame("Frame")
    end
    activeListeners[f] = true
    return f
end
function EmpireManager:ReleaseListener(f)
    activeListeners[f] = nil
    f:UnregisterAllEvents()
    f:SetScript("OnEvent", nil)
    listenerPool[#listenerPool + 1] = f
end
function EmpireManager:ReleaseAllListeners()
    for f in pairs(activeListeners) do
        activeListeners[f] = nil
        f:UnregisterAllEvents()
        f:SetScript("OnEvent", nil)
        listenerPool[#listenerPool + 1] = f
    end
end

-------------------------------------------------------------------------------
-- Async Coroutine Scanner (spreads work across frames to avoid UI freezes)
-------------------------------------------------------------------------------

-- Time budget per frame in milliseconds. Scanning yields when this is exceeded.
local ASYNC_BUDGET_MS = 1 -- ~1ms per frame - very conservative to prevent any stutter

-- Active async scan state (only one scan at a time)
local asyncCoroutine = nil
local asyncOnComplete = nil
local asyncTickerFrame = nil
local asyncFrameSkip = 0 -- gate: resume every 2nd frame

-- Drive the coroutine: resume once per frame then return.
-- This guarantees at most one yield-to-yield work unit per frame, preventing
-- any single expensive slot scan from monopolizing the frame.
-- When the coroutine finishes, the callback is deferred to the next frame
-- via C_Timer.After(0) so the completion handler never blocks the current frame.
local function AsyncTick()
    if not asyncCoroutine then
        if asyncTickerFrame then
            asyncTickerFrame:SetScript("OnUpdate", nil)
        end
        return
    end
    -- Resume every 2nd frame so each batch (BANK_BATCH_SIZE=100) gets a clean
    -- frame to recover, esp. when GetItemInfo is uncached on first bank open.
    asyncFrameSkip = asyncFrameSkip + 1
    if asyncFrameSkip < 2 then
        return
    end
    asyncFrameSkip = 0
    local startMs = debugprofilestop()
    local ok, result = coroutine.resume(asyncCoroutine, startMs)
    if not ok then
        -- Coroutine errored - abort
        local err = result
        asyncCoroutine = nil
        if asyncTickerFrame then
            asyncTickerFrame:SetScript("OnUpdate", nil)
        end
        local cb = asyncOnComplete
        asyncOnComplete = nil
        if cb then
            C_Timer.After(0, function()
                local f = cb
                cb = nil
                f(nil, err)
            end)
        end
        return
    end
    if coroutine.status(asyncCoroutine) == "dead" then
        -- Coroutine finished - defer callback to next frame
        local cb = asyncOnComplete
        local res = result
        asyncCoroutine = nil
        asyncOnComplete = nil
        asyncTickerFrame:SetScript("OnUpdate", nil)
        if cb then
            C_Timer.After(0, function()
                local f, r = cb, res
                cb, res = nil, nil
                f(r)
            end)
        end
        return
    end
    -- Coroutine yielded - always return, resume next frame.
    -- No budget loop: one resume per frame keeps each frame fast.
end

-- Cancel any running async scan (e.g., when tab switches or overlay closes)
function EmpireManager:CancelAsyncScan()
    if asyncCoroutine then
        asyncCoroutine = nil
        asyncOnComplete = nil
        if asyncTickerFrame then
            asyncTickerFrame:SetScript("OnUpdate", nil)
        end
    end
end

-- Start an async scan. scanFn is a function(yieldCheck) that calls yieldCheck()
-- periodically; yieldCheck() yields when the frame budget is exhausted.
-- onComplete(results, err) is called when done.
-- Exposed as both local (for this file) and addon method (for Core.lua).
local function StartAsyncScan(scanFn, onComplete)
    -- Cancel any existing scan
    EmpireManager:CancelAsyncScan()

    if not asyncTickerFrame then
        asyncTickerFrame = CreateFrame("Frame")
    end

    asyncOnComplete = onComplete
    asyncFrameSkip = 0
    asyncCoroutine = coroutine.create(function(frameStartMs)
        -- yieldCheck: call this inside the scan loop. It yields when the
        -- time budget for the current frame is exceeded, and returns the
        -- new frame start time after resumption.
        local currentFrameStart = frameStartMs
        local function yieldCheck()
            local elapsed = debugprofilestop() - currentFrameStart
            if elapsed >= ASYNC_BUDGET_MS then
                currentFrameStart = coroutine.yield() -- resumed next frame with new startMs
            end
        end
        return scanFn(yieldCheck)
    end)

    asyncTickerFrame:SetScript("OnUpdate", AsyncTick)
    -- Kick off the first resume (pass current time)
    AsyncTick()
end

-- Expose for use in Core.lua (bank capacity snapshots, etc.)
function EmpireManager:StartAsyncScan(scanFn, onComplete)
    StartAsyncScan(scanFn, onComplete)
end

-------------------------------------------------------------------------------
-- Category Constants
-------------------------------------------------------------------------------

local CAT_KEEP = "KEEP"
local CAT_ROUTE = "ROUTE"
local CAT_STASH = "STASH"
local CAT_VENDOR = "VENDOR"
local CAT_TAKEOUT = "TAKEOUT"

-- Expose for Triage.lua UI
EmpireManager.CAT_KEEP = CAT_KEEP
EmpireManager.CAT_ROUTE = CAT_ROUTE
EmpireManager.CAT_STASH = CAT_STASH
EmpireManager.CAT_VENDOR = CAT_VENDOR
EmpireManager.CAT_TAKEOUT = CAT_TAKEOUT

-- Category display info
EmpireManager.CATEGORY_INFO = {
    [CAT_KEEP] = { label = "Keep", r = 0.0, g = 0.8, b = 0.0 },
    [CAT_ROUTE] = { label = "Route", r = 1.0, g = 0.8, b = 0.0 },
    [CAT_STASH] = { label = "Stash", r = 0.3, g = 0.6, b = 1.0 },
    [CAT_VENDOR] = { label = "Vendor", r = 0.6, g = 0.6, b = 0.6 },
    [CAT_TAKEOUT] = { label = "Take Out", r = 1.0, g = 0.8, b = 0.0 },
}

-- Category sort order for display grouping (bag triage)
EmpireManager.CATEGORY_ORDER = { CAT_KEEP, CAT_ROUTE, CAT_STASH, CAT_VENDOR }

-- Cached triage results
EmpireManager.triageResults = nil
EmpireManager.triageLastScan = 0
-- Flipped true by BAG_UPDATE_DELAYED; cleared after a successful scan.
-- When false, RunTriageAsync returns cached results without re-scanning.
EmpireManager._bagsDirty = true

-------------------------------------------------------------------------------
-- Move Contexts - bank-type-specific API strategies
--
-- Each context provides a uniform interface so the move engine works
-- identically for character bank, warband bank, and guild bank.
-- Guild bank uses entirely different WoW APIs and must be moved one item
-- at a time with a server query after each move.
-------------------------------------------------------------------------------

EmpireManager.MoveContexts = {}
local MoveContexts = EmpireManager.MoveContexts

MoveContexts.charbank = {
    name = "Character Bank",
    batchSize = 0, -- 0 = unlimited (fire all at once)
    GetItemInfo = function(container, slot)
        return C_Container.GetContainerItemInfo(container, slot)
    end,
    GetNumSlots = function(container)
        return C_Container.GetContainerNumSlots(container) or 0
    end,
    PickupItem = function(container, slot)
        C_Container.PickupContainerItem(container, slot)
    end,
    SplitItem = function(container, slot, qty)
        C_Container.SplitContainerItem(container, slot, qty)
    end,
    IsItemAllowedInBank = function(_srcBag, _srcSlot)
        return true -- no restrictions for character bank
    end,
    ResolveAddress = function(tabNum)
        return 5 + tabNum -- tab 1-6 → container 6-11
    end,
    TabRange = function()
        return 1, 6
    end,
    ContainerRange = function()
        return 6, 11
    end,
    needsQueryAfterMove = false,
}

MoveContexts.warbandbank = {
    name = "Warband Bank",
    batchSize = 5, -- batched by 5 (WoW rate limiting)
    GetItemInfo = function(container, slot)
        return C_Container.GetContainerItemInfo(container, slot)
    end,
    GetNumSlots = function(container)
        return C_Container.GetContainerNumSlots(container) or 0
    end,
    PickupItem = function(container, slot)
        C_Container.PickupContainerItem(container, slot)
    end,
    SplitItem = function(container, slot, qty)
        C_Container.SplitContainerItem(container, slot, qty)
    end,
    IsItemAllowedInBank = function(srcBag, srcSlot)
        local loc = ItemLocation:CreateFromBagAndSlot(srcBag, srcSlot)
        if not C_Item.DoesItemExist(loc) then
            return false
        end
        if C_Bank and C_Bank.IsItemAllowedInBankType then
            local allowed = C_Bank.IsItemAllowedInBankType(Enum.BankType.Account, loc)
            if not allowed then
                local info = C_Container.GetContainerItemInfo(srcBag, srcSlot)
                EmpireManager:Print(
                    "|cffff0000[Bank]|r Not allowed in Warband Bank: " .. tostring(info and info.itemName)
                )
            end
            return allowed
        end
        return true
    end,
    ResolveAddress = function(tabNum)
        return 11 + tabNum -- tab 1-5 → container 12-16
    end,
    TabRange = function()
        return 1, 5
    end,
    ContainerRange = function()
        return 12, 16
    end,
    needsQueryAfterMove = false,
}

MoveContexts.guildbank = {
    name = "Guild Bank",
    batchSize = 1, -- ONE move at a time (proven rule)
    _currentTab = nil, -- cached to avoid redundant SetCurrentGuildBankTab calls
    EnsureTab = function(self, tab)
        if self._currentTab ~= tab then
            SetCurrentGuildBankTab(tab)
            self._currentTab = tab
        end
    end,
    GetItemInfo = function(tab, slot)
        MoveContexts.guildbank:EnsureTab(tab)
        local tex, count, locked = GetGuildBankItemInfo(tab, slot)
        if not tex then
            return nil
        end
        local link = GetGuildBankItemLink(tab, slot)
        local itemID = link and select(1, C_Item.GetItemInfoInstant(link))
        return {
            itemID = itemID,
            stackCount = count,
            isLocked = locked,
            itemLink = link,
            iconFileID = tex,
        }
    end,
    GetNumSlots = function(tab)
        local _, _, _, _, numSlots = GetGuildBankTabInfo(tab)
        -- Guild bank tabs are always 98 slots (14x7). API returns -1 or
        -- bogus values like 100000 for purchased tabs.
        if not numSlots or numSlots <= 0 or numSlots > 98 then
            numSlots = 98
        end
        return numSlots
    end,
    PickupItem = function(tab, slot)
        MoveContexts.guildbank:EnsureTab(tab)
        PickupGuildBankItem(tab, slot)
    end,
    SplitItem = function(tab, slot, qty)
        SplitGuildBankItem(tab, slot, qty)
    end,
    IsItemAllowedInBank = function(srcBag, srcSlot)
        -- Bound items cannot go in guild bank
        local loc = ItemLocation:CreateFromBagAndSlot(srcBag, srcSlot)
        if not C_Item.DoesItemExist(loc) then
            return false
        end
        return not C_Item.IsBound(loc)
    end,
    ResolveAddress = function(tabNum)
        return tabNum -- guild bank tab number IS the address directly
    end,
    TabRange = function()
        return 1, GetNumGuildBankTabs()
    end,
    ContainerRange = function()
        return 1, GetNumGuildBankTabs()
    end,
    needsQueryAfterMove = true, -- QueryGuildBankTab after each move
    QueryAfterMove = function(tab)
        QueryGuildBankTab(tab)
    end,
}

-------------------------------------------------------------------------------
-- Profession Storage Cache (built from PROF_ITEM_MAP + storageAssignments)
-------------------------------------------------------------------------------

-- (classID*1000 + subClassID) → array of profession keys that consume this item type
-- Exposed on addon object so bank triage scanner can access it.
EmpireManager._profMatchCache = {}
local profMatchCache = EmpireManager._profMatchCache
-- itemID → set of profession keys (built from PROF_ITEM_OVERRIDES). Takes
-- precedence over profMatchCache so misclassified subclass buckets can be fixed
-- without remapping the whole subclass.
EmpireManager._profOverrideCache = {}
local profOverrideCache = EmpireManager._profOverrideCache
local storageCacheBuilt = false

-- True if the keep-own-mat-in-bags rule should be skipped for this item due to
-- the "latest expansion only" sub-option. Items without an expansionID (legacy
-- vanilla items) are always treated as "old".
local function IsBlockedByLatestOnly(entry, item)
    if not entry.keepOwnProfMatsInBagsLatestOnly then
        return false
    end
    local latest = GetExpansionLevel and GetExpansionLevel() or 0
    local exp = item and item.expansionID
    return not exp or exp < latest
end

-- Resolve the profession match set for an item: itemID override wins over the
-- subclass cache. Returns nil when neither matches.
local function GetProfMatchSet(item)
    if not item then
        return nil
    end
    local override = item.itemID and profOverrideCache[item.itemID]
    if override then
        return override
    end
    local classID = item.itemClassID
    if not classID or classID < 0 then
        return nil
    end
    return profMatchCache[classID * 1000 + (item.itemSubClassID or 0)]
end

-- Public wrapper around GetProfMatchSet keyed by itemID alone (Bank Restock UI).
-- Builds the minimal item record GetProfMatchSet needs (itemID + class/subclass via
-- GetItemInfoInstant) and returns the same profKey->true set triage routing uses, so
-- the Restock tab's Profession column stays consistent with routing. Returns nil if
-- the item has no profession match (or the itemID can't be resolved).
function EmpireManager:GetItemProfMatchSet(itemID)
    if not itemID then
        return nil
    end
    self:EnsureStorageCache()
    local _, _, _, _, _, classID, subClassID = C_Item.GetItemInfoInstant(itemID)
    return GetProfMatchSet({ itemID = itemID, itemClassID = classID, itemSubClassID = subClassID })
end

-- Check if an item matches a storage assignment's subcategory filter.
-- No subcategories = match all (backward compatible).
local RECIPE_SUBCLASS_TO_PROF = EmpireManager.RECIPE_SUBCLASS_TO_PROF
local PROF_EQUIP_SUBCLASS_TO_PROF = EmpireManager.PROF_EQUIP_SUBCLASS_TO_PROF

local function MatchesSubcategory(assignment, item)
    local subcats = assignment.subcategories
    if not subcats or #subcats == 0 then
        return true
    end

    local subcatSet = {}
    for _, sc in ipairs(subcats) do
        subcatSet[sc] = true
    end
    local prof = assignment.profession

    if prof == "equipment_boe" or prof == "equipment_boa" then
        if subcatSet["weapons"] and item.itemClassID == 2 then
            return true
        end
        if subcatSet["armor"] and item.itemClassID == 4 and item.itemSubClassID >= 1 and item.itemSubClassID <= 4 then
            return true
        end
        if subcatSet["jewelry"] and item.itemClassID == 4 and item.itemSubClassID == 0 then
            return true
        end
        if subcatSet["other"] then
            local isKnown = item.itemClassID == 2
                or (item.itemClassID == 4 and item.itemSubClassID >= 0 and item.itemSubClassID <= 4)
            if not isKnown then
                return true
            end
        end
        return false
    elseif prof == "recipes" then
        local recipeProfKey = RECIPE_SUBCLASS_TO_PROF[item.itemSubClassID]
        return recipeProfKey and (subcatSet[recipeProfKey] or false) or false
    elseif prof == "equipment_prof" then
        -- classID 19: subClassID IS the profession.
        local equipProfKey = PROF_EQUIP_SUBCLASS_TO_PROF[item.itemSubClassID]
        return equipProfKey and (subcatSet[equipProfKey] or false) or false
    elseif prof == "consumables" then
        local sub = item.itemSubClassID
        if subcatSet["potions"] and sub == 1 then
            return true
        end
        if subcatSet["flasks"] and (sub == 2 or sub == 3) then
            return true
        end
        if subcatSet["food"] and sub == 5 then
            return true
        end
        if subcatSet["other"] and sub ~= 1 and sub ~= 2 and sub ~= 3 and sub ~= 5 then
            return true
        end
        return false
    end

    return true
end

-- Can this assignment's destination bank type physically accept the item,
-- given its bind state? Guild banks reject warbound AND soulbound items.
-- Warband banks reject soulbound (non-warbound). Character banks accept anything.
-- Skipped when the item is already in a bank (we're reorganizing, not depositing).
local function IsBankTypeCompatible(item, assignment)
    if item.bankType then
        return true -- already in a bank, blizzard already accepted it there
    end
    if item.isWarbound then
        return assignment.type == "charbank" or assignment.type == "warbandbank"
    end
    if item.isBound then
        return assignment.type == "charbank"
    end
    return true
end
EmpireManager.IsBankTypeCompatible = IsBankTypeCompatible

-- Check if an assignment passes expansion + subcategory filters for an item.
-- Array order = priority: first eligible assignment wins.
local function IsAssignmentEligible(assignment, item)
    -- Expansion filter: skip if item's expansion doesn't match any selected
    if assignment.expansions and #assignment.expansions > 0 then
        if not item.expansionID then
            return false
        end
        local match = false
        for _, eid in ipairs(assignment.expansions) do
            if item.expansionID == eid then
                match = true
                break
            end
        end
        if not match then
            return false
        end
    end
    -- Subcategory filter
    if not MatchesSubcategory(assignment, item) then
        return false
    end
    return true
end

local function RebuildStorageCache(self)
    -- Rebuild into the shared table (clear + repopulate, not reassign)
    for k in pairs(profMatchCache) do
        profMatchCache[k] = nil
    end
    for profKey, subclasses in pairs(self.PROF_ITEM_MAP) do
        for _, pair in ipairs(subclasses) do
            local cacheKey = pair[1] * 1000 + pair[2]
            if not profMatchCache[cacheKey] then
                profMatchCache[cacheKey] = {}
            end
            profMatchCache[cacheKey][profKey] = true
        end
    end
    for k in pairs(profOverrideCache) do
        profOverrideCache[k] = nil
    end
    if self.PROF_ITEM_OVERRIDES then
        for itemID, profs in pairs(self.PROF_ITEM_OVERRIDES) do
            local set = {}
            for _, profKey in ipairs(profs) do
                set[profKey] = true
            end
            profOverrideCache[itemID] = set
        end
    end
    storageCacheBuilt = true
end

function EmpireManager:EnsureStorageCache()
    if not storageCacheBuilt then
        RebuildStorageCache(self)
    end
end

-- Invalidate caches when storage assignments change.
-- Also drops cached triage classifications so the next scan re-runs ClassifyItem
-- against the fresh rule set (otherwise the bag-scan fast-path in RunTriageAsync
-- returns stale results when bags haven't changed).
-- `immediate` skips OnTriageOptionChanged's 0.5s debounce, which exists to
-- coalesce option-panel edits. A deliberate button press should repaint at once.
function EmpireManager:InvalidateStorageCache(immediate)
    storageCacheBuilt = false
    self.triageResults = nil
    self.bankTriageResults = nil
    self._triageFingerprint = nil
    self._bankTriageFingerprint = nil
    self._triageFingerprintCount = nil
    self._bankTriageFingerprintCount = nil
    -- Repaint whichever tab is showing. Not EM_TRIAGE_REFRESH: that also fires
    -- from BAG_UPDATE_DELAYED, so its handler ignores the bank tabs.
    if immediate then
        self._bagsDirty = true
        if self.triageFrame and self.triageFrame:IsShown() then
            if self._triageActiveTab == "bags" then
                self:RefreshTriageDisplay(true)
            else
                self:RefreshBankTriageDisplay(true)
            end
        end
    elseif self.OnTriageOptionChanged then
        self:OnTriageOptionChanged()
    else
        self:SendMessage("EM_TRIAGE_REFRESH")
    end
end

-------------------------------------------------------------------------------
-- Tooltip Bind Helpers (shared by bag and bank scanning)
-------------------------------------------------------------------------------

-- Tooltip bind detection is expensive (parses tooltip lines per item).
-- Only needed for items where ClassifyItem checks bind state:
--   classID 2 (Weapon) / 4 (Armor) → soulbound gear vendor check
-- Tooltip scan is needed for:
--   classID 1 (Container) / 15 (Miscellaneous) → lockbox detection
--   classID 2 (Weapon) / 4 (Armor) → equipment warbound/BoE detection
--   classID 12 (Quest) → subcategory soulbound/warbound filtering
--   bindType 2 (BoE) → auctioneer/disenchant routing
--   Any storable category (consumables, gems, item enhancements, recipes,
--   battle pets, housing) can be warbound with misleading bindType=1.
--   Scan all classIDs used in PROF_ITEM_MAP to catch warbound items.
local TOOLTIP_SCAN_CLASSES = {
    [0] = true, -- Consumable
    [1] = true, -- Container (lockbox)
    [2] = true, -- Weapon
    [3] = true, -- Gem
    [4] = true, -- Armor
    [7] = true, -- Trade Goods (reagents can be warbound despite bindType=1)
    [8] = true, -- Item Enhancement
    [9] = true, -- Recipe
    [12] = true, -- Quest
    [15] = true, -- Miscellaneous
    [17] = true, -- Battle Pet
    [19] = true, -- Profession equipment (tools/accessories can be warbound)
    [20] = true, -- Housing
}
-- Forward-declared; populated at ITEM_CATEGORY_MAP definition below.
local ITEM_CATEGORY_MAP

-- Resolve a display name for a scanned slot. C_Container.GetContainerItemInfo and
-- C_Item.GetItemInfo both return nil names for items the client has not cached yet
-- (common on a fresh login when a bank tab holds items never seen this session), and
-- the old `name or ""` fallback rendered those rows as a bare icon + count. The
-- hyperlink carries the name inside its [brackets] even when the item cache is cold,
-- so fall back to that before giving up.
local function ResolveItemName(name, link)
    -- Reagents with a quality tier carry an |A:...|a atlas marker for the star icon.
    -- GetContainerItemInfo sometimes hands back a name that is nothing but that
    -- marker, which paints the row as a lone quality star with no text, so strip the
    -- markup and treat what is left as the name only if there is anything to show.
    if name and name ~= "" then
        local stripped = name:gsub("|A:.-|a", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if stripped ~= "" then
            return stripped
        end
    end
    -- Nothing usable: the client has not cached this item yet, or the name was pure
    -- markup. The hyperlink still carries the real name inside its brackets.
    if link then
        local bracketed = link:match("%[(.-)%]")
        if bracketed then
            bracketed = bracketed:gsub("|A:.-|a", ""):gsub("^%s+", ""):gsub("%s+$", "")
            if bracketed ~= "" then
                return bracketed
            end
        end
    end
    return ""
end

local function NeedsTooltipScan(classID, bindType, itemID)
    if TOOLTIP_SCAN_CLASSES[classID] or bindType == 2 then
        return true
    end
    -- Items with an explicit category assignment need tooltip-accurate bind detection
    -- regardless of classID (e.g. lumber reagents routed to warband bank).
    if itemID and ITEM_CATEGORY_MAP and ITEM_CATEGORY_MAP[itemID] then
        return true
    end
    return false
end

-- Parse tooltip data for warbound/soulbound/lockbox/teleport flags.
-- isTeleport: a "Use:" line that mentions teleport (trinkets/rings like Runed
-- Signet of the Kirin Tor, Time-Lost Artifact). Used to preserve these from
-- vendor. Both conditions must hold on the same line - see the check below.
-- Prefix of ITEM_CLASSES_ALLOWED ("Classes: %s"), used to spot the class
-- restriction line that gear tokens (Unsullied set, etc.) carry. Stripped to the
-- literal text before the format token so we can match by prefix, locale-safe.
local CLASSES_ALLOWED_PREFIX = (ITEM_CLASSES_ALLOWED or "Classes: %s"):gsub("%%s.*$", "")
-- Prefix of ITEM_SPELL_TRIGGER_ONUSE ("Use: %s") - same stripping.
local USE_LINE_PREFIX = (ITEM_SPELL_TRIGGER_ONUSE or "Use: %s"):gsub("%%s.*$", "")
-- Red "Already known" line shown on a learnable item the player has collected
-- (illusions, etc.). Used to vendor known cosmetics that can't be relearned.
local KNOWN_LINE = ITEM_SPELL_KNOWN or "Already known"

local function ParseTooltipBind(tooltipData)
    local isWarbound, isSoulbound, isLockbox, isUnique, isTeleport, isConjured, isKnownAppearance =
        false, false, false, false, false, false, false
    -- Permanent account-bound ("Warbound") vs "Warbound Until Equipped". Both set
    -- isWarbound, but only the former survives being bound: an "until equipped"
    -- item becomes plain soulbound once equipped, while a permanently warbound
    -- item stays account-bound and must keep routing to Equipment (BoA).
    local isPermanentWarbound = false
    -- A "Use:" line AND a "Classes:" restriction together mark an equipment token
    -- (e.g. Unsullied Leather Belt): a consumable-classed item that grants gear on
    -- use. Real consumables (potions/flasks) have a Use line but no class line.
    local hasUseLine, hasClassLine = false, false
    if tooltipData and tooltipData.lines then
        for _, line in ipairs(tooltipData.lines) do
            local txt = line.leftText
            if txt then
                if
                    txt == ITEM_ACCOUNTBOUND
                    or txt == ITEM_BIND_TO_ACCOUNT
                    or txt == ITEM_BNETACCOUNTBOUND
                    or txt == ITEM_BIND_TO_BNETACCOUNT
                then
                    isWarbound = true
                    isPermanentWarbound = true
                elseif txt == ITEM_ACCOUNTBOUND_UNTIL_EQUIP or txt == ITEM_BIND_TO_ACCOUNT_UNTIL_EQUIP then
                    isWarbound = true
                elseif txt == ITEM_SOULBOUND then
                    isSoulbound = true
                elseif txt == LOCKED then
                    isLockbox = true
                elseif txt == ITEM_UNIQUE or txt:match("^Unique %(%d+%)$") then
                    isUnique = true
                elseif txt == ITEM_CONJURED then
                    isConjured = true
                elseif txt == KNOWN_LINE then
                    isKnownAppearance = true
                end
                -- Teleport must be on a "Use:" line of the SAME tooltip row. A bare
                -- substring match anywhere in the tooltip catches flavor text and
                -- spell descriptions (e.g. Artisanal Blink Trap, a consumable whose
                -- blurb mentions teleporting), and the guard that reads this flag
                -- outranks the vendor whitelist - so a false hit is unoverridable.
                if
                    not isTeleport
                    and USE_LINE_PREFIX ~= ""
                    and txt:find(USE_LINE_PREFIX, 1, true) == 1
                    and txt:find("[Tt]eleport")
                then
                    isTeleport = true
                end
                if not hasUseLine and USE_LINE_PREFIX ~= "" and txt:find(USE_LINE_PREFIX, 1, true) == 1 then
                    hasUseLine = true
                end
                if
                    not hasClassLine
                    and CLASSES_ALLOWED_PREFIX ~= ""
                    and txt:find(CLASSES_ALLOWED_PREFIX, 1, true) == 1
                then
                    hasClassLine = true
                end
            end
        end
    end
    if isSoulbound and not isPermanentWarbound then
        isWarbound = false
    end
    local isEquipToken = hasUseLine and hasClassLine
    return isWarbound,
        isSoulbound,
        isLockbox,
        isUnique,
        isTeleport,
        isConjured,
        isEquipToken,
        isKnownAppearance,
        isPermanentWarbound
end

-- Parse bag slot count from an item's tooltip. Returns slot count or nil.
-- Used by Rule D.2a-bag to compare a BoP container against equipped bags.
-- Matches leftText lines like "24 Slot Bag" / "30 Slot Reagent Bag".
local function ParseBagSlots(itemLink)
    if not itemLink or not C_TooltipInfo or not C_TooltipInfo.GetHyperlink then
        return nil
    end
    local tooltipData = C_TooltipInfo.GetHyperlink(itemLink)
    if not tooltipData or not tooltipData.lines then
        return nil
    end
    for _, line in ipairs(tooltipData.lines) do
        local txt = line.leftText
        if txt then
            local n = txt:match("^(%d+)%s+Slot")
            if n then
                return tonumber(n)
            end
        end
    end
    return nil
end

-- Exposed so diagnostics (/em inspect) can report the SAME bind flags the
-- classifier acts on. Inspect used to carry its own copy of this matching, which
-- drifted: it omitted constants ParseTooltipBind checks, so it could print a bind
-- state routing had never used.
EmpireManager.ParseTooltipBind = ParseTooltipBind
-- Exposed for the same reason: bind flags are only computed when this gate passes,
-- so a diagnostic that does not show it can imply detection ran when it did not.
EmpireManager.NeedsTooltipScan = NeedsTooltipScan

-- Per-scan tooltip cache: avoids re-parsing tooltips for the same itemID.
-- Cleared at the start of each async scan via ResetTooltipCache().
-- Key = itemID, Value = { isWarbound, isLockbox, isUnique, isTeleport, isConjured, isEquipToken, isKnownAppearance }
-- isSoulbound is NOT cached: it is per-slot state (one stack of an itemID may
-- be bound while another slot of the same itemID is a fresh BoE), so we must
-- re-parse the tooltip each call to get the slot-specific soulbound flag.
local tooltipCache = {}
local function ResetTooltipCache()
    tooltipCache = {}
end

local function CachedTooltipBind(itemID, tooltipDataFn)
    local tooltipData = tooltipDataFn()
    local isWarbound, isSoulbound, isLockbox, isUnique, isTeleport, isConjured, isEquipToken, isKnownAppearance, isPermanentWarbound =
        ParseTooltipBind(tooltipData)
    local cached = tooltipCache[itemID]
    if cached then
        -- Per-slot bind state (isWarbound / isSoulbound / isPermanentWarbound) comes
        -- from THIS slot's freshly parsed tooltip; only the itemID-static flags come
        -- from the cache. Two slots of one itemID can differ: a "Warbound until
        -- equipped" copy can sit beside a "Soulbound" copy of the same item.
        --
        -- This used to AND the live value with cached[1], so whichever copy was
        -- scanned first decided for every other one. A Soulbound copy scanned first
        -- cached false, and the Warbound copy's own correct parse was discarded: it
        -- classified as plain BoE and was mailed to the BoE banker for the auction
        -- house, which cannot sell a Warbound item at all. Items with only one copy
        -- in bags were unaffected, which is why this stayed hidden.
        --
        -- ParseTooltipBind already applies the soulbound override, so its isWarbound
        -- is correct for this slot as it stands.
        return isWarbound,
            isSoulbound,
            cached[2],
            cached[3],
            cached[4],
            cached[5],
            cached[6],
            cached[7],
            isPermanentWarbound
    end
    -- Only cache when the tooltip actually returned data; an empty `lines`
    -- table means the client hasn't fetched item data yet and parsing returned
    -- all-false flags. Caching that would lock in a wrong answer for the
    -- session.
    if tooltipData and tooltipData.lines and #tooltipData.lines > 0 then
        tooltipCache[itemID] =
            { isWarbound, isLockbox, isUnique, isTeleport, isConjured, isEquipToken, isKnownAppearance }
    end
    return isWarbound,
        isSoulbound,
        isLockbox,
        isUnique,
        isTeleport,
        isConjured,
        isEquipToken,
        isKnownAppearance,
        isPermanentWarbound
end

-------------------------------------------------------------------------------
-- Bag Scanning (shared core: optional yieldCheck for async mode)
-------------------------------------------------------------------------------

-- Scan a single bag slot and append item record to items table
local function ScanBagSlot(items, bag, slot)
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if not info then
        return
    end

    local _, _, _, itemEquipLoc, _, classID, subClassID = C_Item.GetItemInfoInstant(info.itemID)
    local _, _, _, _, _, _, _, maxStack, _, _, sellPrice, _, _, bindType, expansionID, _, isCraftingReagent =
        C_Item.GetItemInfo(info.hyperlink or info.itemID)

    -- Use C_Item.IsBound (live API) as primary bound check - more reliable than
    -- info.isBound which can return false for soulbound items when data isn't cached.
    local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
    local isBound = (C_Item.DoesItemExist(loc) and C_Item.IsBound(loc)) or info.isBound or false

    local isWarbound, isSoulbound, isLockbox, isUnique, isTeleport, isConjured, isEquipToken, isKnownAppearance, isPermanentWarbound =
        false, false, false, false, false, false, false, false, false
    if NeedsTooltipScan(classID or -1, bindType or 0, info.itemID) then
        if C_TooltipInfo and C_TooltipInfo.GetBagItem then
            local bagRef, slotRef = bag, slot -- capture for closure
            isWarbound, isSoulbound, isLockbox, isUnique, isTeleport, isConjured, isEquipToken, isKnownAppearance, isPermanentWarbound = CachedTooltipBind(
                info.itemID,
                function()
                    return C_TooltipInfo.GetBagItem(bagRef, slotRef)
                end
            )
        end
    end

    -- Tooltip soulbound detection as additional fallback
    if isSoulbound then
        isBound = true
    end

    -- C_Item.IsBound is the authoritative per-slot bind check. The tooltip only
    -- prints ITEM_SOULBOUND in some states, so isSoulbound alone misses gear
    -- that is already bound in bags - leaving isWarbound set from the
    -- "Warbound Until Equipped" tooltip line and routing soulbound gear to the
    -- Equipment (BoA) rule instead of Keep/Vendor.
    -- Deliberately NOT gated on bindType: Blizzard reports bindType=2 for BoP
    -- gear here (same unreliability as guild bank items), so gating on it would
    -- exempt the exact case this guard exists to catch. Once a slot is bound,
    -- "until equipped" has already resolved - a bound item is soulbound unless
    -- its tooltip still shows a permanent account-bound line.
    if isBound and isWarbound and not isPermanentWarbound then
        isWarbound = false
    end

    local hasNoValue = info.hasNoValue or false
    local uncached = not sellPrice -- GetItemInfo returned nil → data not cached yet
    local sp = 0
    if hasNoValue then
        sp = 0
    elseif sellPrice then
        sp = sellPrice
    end

    items[#items + 1] = {
        bag = bag,
        slot = slot,
        itemID = info.itemID,
        itemName = ResolveItemName(info.itemName, info.hyperlink),
        itemLink = info.hyperlink,
        stackCount = info.stackCount or 1,
        maxStack = maxStack or 1,
        quality = info.quality or 0,
        isBound = isBound,
        isWarbound = isWarbound,
        isLockbox = isLockbox,
        isUnique = isUnique,
        isTeleport = isTeleport,
        isConjured = isConjured,
        isEquipToken = isEquipToken,
        isKnownAppearance = isKnownAppearance,
        iconID = info.iconFileID,
        itemClassID = classID or -1,
        itemSubClassID = subClassID or -1,
        itemEquipLoc = itemEquipLoc or "",
        expansionID = expansionID,
        sellPrice = sp * (info.stackCount or 1),
        sellPricePerUnit = sp,
        hasNoValue = hasNoValue,
        bindType = bindType or 0,
        isCraftingReagent = isCraftingReagent,
        _uncached = uncached,
    }
end

-- Core bag scan loop. yieldCheck is nil (sync) or a function that yields when
-- the frame time budget is exceeded.
local function ScanBagsCore(yieldCheck)
    ResetTooltipCache()
    local items = {}
    for bag = 0, 5 do
        local numSlots = C_Container.GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            ScanBagSlot(items, bag, slot)
            if yieldCheck then
                yieldCheck()
            end
        end
    end
    return items
end

-------------------------------------------------------------------------------
-- Bank Scanning (shared core: optional yieldCheck for async mode)
-------------------------------------------------------------------------------

-- Scan a single guild bank slot and append item record to items table
local function ScanGuildBankSlot(items, tab, slot)
    local link = GetGuildBankItemLink(tab, slot)
    if not link then
        return
    end

    local _, count = GetGuildBankItemInfo(tab, slot)
    local itemID, _, _, itemEquipLoc, _, classID, subClassID = C_Item.GetItemInfoInstant(link)
    if not itemID then
        return
    end

    local itemName, _, quality, _, _, _, _, _, _, icon, sellPrice, _, _, bindType, expansionID, _, isCraftingReagent =
        C_Item.GetItemInfo(link)

    local isWarbound, isSoulbound, isLockbox, isUnique, isTeleport, isConjured, _isEquipToken, isKnownAppearance =
        false, false, false, false, false, false, false, false
    if NeedsTooltipScan(classID or -1, bindType or 0, itemID) then
        if C_TooltipInfo and C_TooltipInfo.GetHyperlink then
            local linkRef = link -- capture for closure
            isWarbound, isSoulbound, isLockbox, isUnique, isTeleport, isConjured, _isEquipToken, isKnownAppearance = CachedTooltipBind(
                itemID,
                function()
                    return C_TooltipInfo.GetHyperlink(linkRef)
                end
            )
        end
    end

    items[#items + 1] = {
        bag = tab,
        slot = slot,
        itemID = itemID,
        itemName = ResolveItemName(itemName, link),
        itemLink = link,
        stackCount = count or 1,
        quality = quality or 0,
        isBound = isSoulbound or isWarbound,
        isWarbound = isWarbound,
        isLockbox = isLockbox,
        isTeleport = isTeleport,
        isConjured = isConjured,
        isKnownAppearance = isKnownAppearance,
        iconID = icon,
        itemClassID = classID or -1,
        itemSubClassID = subClassID or -1,
        itemEquipLoc = itemEquipLoc or "",
        expansionID = expansionID,
        sellPrice = (sellPrice or 0) * (count or 1),
        sellPricePerUnit = sellPrice or 0,
        hasNoValue = not sellPrice or sellPrice == 0,
        bindType = bindType or 0,
        isCraftingReagent = isCraftingReagent,
        srcTab = tab,
        bankType = "guildbank",
        bankContainer = tab,
    }
end

-- Scan a single container bank slot (charbank/warbandbank) and append item record
local function ScanContainerBankSlot(items, container, slot, tabNum, bankType)
    local info = C_Container.GetContainerItemInfo(container, slot)
    if not info then
        return
    end

    local _, _, _, itemEquipLoc, _, classID, subClassID = C_Item.GetItemInfoInstant(info.itemID)
    local _, _, _, _, _, _, _, _, _, _, sellPrice, _, _, bindType, expansionID, _, isCraftingReagent =
        C_Item.GetItemInfo(info.hyperlink or info.itemID)

    -- Use C_Item.IsBound (live API) as primary bound check
    local loc = ItemLocation:CreateFromBagAndSlot(container, slot)
    local isBound = (C_Item.DoesItemExist(loc) and C_Item.IsBound(loc)) or info.isBound or false

    local isWarbound, isSoulbound, isLockbox, isUnique, isTeleport, isConjured, _isEquipToken, isKnownAppearance, isPermanentWarbound =
        false, false, false, false, false, false, false, false, false
    if NeedsTooltipScan(classID or -1, bindType or 0, info.itemID) then
        if C_TooltipInfo and C_TooltipInfo.GetBagItem then
            local cRef, sRef = container, slot -- capture for closure
            isWarbound, isSoulbound, isLockbox, isUnique, isTeleport, isConjured, _isEquipToken, isKnownAppearance, isPermanentWarbound = CachedTooltipBind(
                info.itemID,
                function()
                    return C_TooltipInfo.GetBagItem(cRef, sRef)
                end
            )
        end
    end

    -- Tooltip soulbound detection as additional fallback
    if isSoulbound then
        isBound = true
    end

    -- See ScanBagSlot: a bound slot is soulbound unless its tooltip still shows a
    -- permanent account-bound line ("Warbound until equipped" resolves on equip).
    if isBound and isWarbound and not isPermanentWarbound then
        isWarbound = false
    end

    local hasNoValue = info.hasNoValue or false
    local sp = hasNoValue and 0 or (sellPrice or 0)
    items[#items + 1] = {
        bag = container,
        slot = slot,
        itemID = info.itemID,
        itemName = ResolveItemName(info.itemName, info.hyperlink),
        itemLink = info.hyperlink,
        stackCount = info.stackCount or 1,
        quality = info.quality or 0,
        isBound = isBound,
        isWarbound = isWarbound,
        isLockbox = isLockbox,
        isTeleport = isTeleport,
        isConjured = isConjured,
        isKnownAppearance = isKnownAppearance,
        iconID = info.iconFileID,
        itemClassID = classID or -1,
        itemSubClassID = subClassID or -1,
        itemEquipLoc = itemEquipLoc or "",
        expansionID = expansionID,
        sellPrice = sp * (info.stackCount or 1),
        sellPricePerUnit = sp,
        hasNoValue = hasNoValue,
        bindType = bindType or 0,
        isCraftingReagent = isCraftingReagent,
        srcTab = tabNum,
        bankType = bankType,
        bankContainer = container,
    }
end

-- Core bank scan loop. yieldCheck is nil (sync) or a function that yields
-- when the frame time budget is exceeded.
-- Bank slots are expensive (tooltip parsing), so we force-yield every
-- BANK_BATCH_SIZE slots to guarantee frame time stays low.
local BANK_BATCH_SIZE = 100

local function ScanBankCore(addon, yieldCheck)
    ResetTooltipCache()
    local items = {}
    local isGuild = addon:IsGuildBankOpen()
    local count = 0

    if isGuild then
        local numTabs = GetNumGuildBankTabs()
        for tab = 1, numTabs do
            local _, _, isViewable = GetGuildBankTabInfo(tab)
            if isViewable then
                local numSlots = MoveContexts.guildbank.GetNumSlots(tab)
                for slot = 1, numSlots do
                    ScanGuildBankSlot(items, tab, slot)
                    if yieldCheck then
                        count = count + 1
                        if count >= BANK_BATCH_SIZE then
                            count = 0
                            coroutine.yield()
                        end
                    end
                end
            end
        end
    elseif addon.bankIsOpen then
        local bankRanges = {
            { type = "charbank", startContainer = 6, endContainer = 11, tabOffset = 5 },
            { type = "warbandbank", startContainer = 12, endContainer = 16, tabOffset = 11 },
        }
        for _, br in ipairs(bankRanges) do
            for container = br.startContainer, br.endContainer do
                local numSlots = C_Container.GetContainerNumSlots(container)
                if numSlots and numSlots > 0 then
                    local tabNum = container - br.tabOffset
                    for slot = 1, numSlots do
                        ScanContainerBankSlot(items, container, slot, tabNum, br.type)
                        if yieldCheck then
                            count = count + 1
                            if count >= BANK_BATCH_SIZE then
                                count = 0
                                coroutine.yield()
                            end
                        end
                    end
                end
            end
        end
    end

    return items
end

-------------------------------------------------------------------------------
-- Item Class Constants (Enum.ItemClass)
-------------------------------------------------------------------------------

local ITEM_CLASS_TRADEGOODS = 7 -- Enum.ItemClass.Tradegoods
local ITEM_CLASS_MISC = 15 -- Enum.ItemClass.Miscellaneous
local ITEM_SUBCLASS_COMPANION = 2 -- companion pets under Miscellaneous
local ITEM_SUBCLASS_MOUNT = 5 -- mounts under Miscellaneous

-- Known pet charm / pet consumable item IDs (add more as needed)
local ZOOKEEPER_ITEMS = {
    [86143] = true, -- Battle Pet Bandage
    [116415] = true, -- Shiny Pet Charm
    [163036] = true, -- Polished Pet Charm
    [122457] = true, -- Ultimate Battle-Training Stone
    [98715] = true, -- Marked Flawless Battle-Stone
    [116429] = true, -- Flawless Battle-Training Stone
    [116374] = true, -- Beast Battle-Training Stone
    [116416] = true, -- Humanoid Battle-Training Stone
    [116417] = true, -- Mechanical Battle-Training Stone
    [116418] = true, -- Critter Battle-Training Stone
    [116419] = true, -- Dragonkin Battle-Training Stone
    [116420] = true, -- Elemental Battle-Training Stone
    [116421] = true, -- Flying Battle-Training Stone
    [116422] = true, -- Magic Battle-Training Stone
    [116423] = true, -- Undead Battle-Training Stone
    [116424] = true, -- Aquatic Battle-Training Stone
    [127755] = true, -- Fel-Touched Battle-Training Stone
}

-- Known PvP BoA/BoE item IDs (add more as needed)
local PVPER_ITEMS = {
    [137642] = true, -- Mark of Honor
    [230285] = true, -- Astral Combatant's Heraldry
    [230287] = true, -- Astral Gladiator's Heraldry
}

-- Quest-class items (classID 12) and Miscellaneous items (classID 15 sub 0/4)
-- that look like "old" items by expansionID but are still actively useful
-- (evergreen currencies, cross-expansion tokens, hearthstones, etc.) and
-- must NOT be auto-stashed by the stashOldQuestItems rule.
local OLD_QUEST_STASH_BLOCKLIST = {
    [143776] = true, -- Shrouded Timewarped Coin (Timewalking currency)
    [6948] = true, -- Hearthstone (always needed in bags)
    [249699] = true, -- Shadowguard Translocator (still used during Nightfall)
    [231510] = true, -- Timewarped Relic Coffer Key (Legion Timewalking weeks)
}

-- itemEquipLoc → inventory slot IDs (for ilvl comparison fallback)
local EQUIPLOC_TO_SLOTS = {
    INVTYPE_HEAD = { 1 },
    INVTYPE_NECK = { 2 },
    INVTYPE_SHOULDER = { 3 },
    INVTYPE_CHEST = { 5 },
    INVTYPE_ROBE = { 5 },
    INVTYPE_WAIST = { 6 },
    INVTYPE_LEGS = { 7 },
    INVTYPE_FEET = { 8 },
    INVTYPE_WRIST = { 9 },
    INVTYPE_HAND = { 10 },
    INVTYPE_FINGER = { 11, 12 },
    INVTYPE_TRINKET = { 13, 14 },
    INVTYPE_CLOAK = { 15 },
    INVTYPE_WEAPON = { 16, 17 },
    INVTYPE_SHIELD = { 17 },
    INVTYPE_2HWEAPON = { 16 },
    INVTYPE_WEAPONMAINHAND = { 16 },
    INVTYPE_WEAPONOFFHAND = { 17 },
    INVTYPE_HOLDABLE = { 17 },
    INVTYPE_RANGED = { 16 },
    INVTYPE_RANGEDRIGHT = { 16 },
}

-- ItemID → storage category key (for items that can't be matched by classID/subClassID alone)
ITEM_CATEGORY_MAP = {
    -- Pet consumables / charms
    [86143] = "pets", -- Battle Pet Bandage
    [116415] = "pets", -- Shiny Pet Charm
    [163036] = "pets", -- Polished Pet Charm
    [122457] = "pets", -- Ultimate Battle-Training Stone
    [98715] = "pets", -- Marked Flawless Battle-Stone
    [116429] = "pets", -- Flawless Battle-Training Stone
    [116374] = "pets", -- Beast Battle-Training Stone
    [116416] = "pets", -- Humanoid Battle-Training Stone
    [116417] = "pets", -- Mechanical Battle-Training Stone
    [116418] = "pets", -- Critter Battle-Training Stone
    [116419] = "pets", -- Dragonkin Battle-Training Stone
    [116420] = "pets", -- Elemental Battle-Training Stone
    [116421] = "pets", -- Flying Battle-Training Stone
    [116422] = "pets", -- Magic Battle-Training Stone
    [116423] = "pets", -- Undead Battle-Training Stone
    [116424] = "pets", -- Aquatic Battle-Training Stone
    [127755] = "pets", -- Fel-Touched Battle-Training Stone
    -- Archaeology keystones (no clean subclass match - itemID routing)
    [52843] = "archaeology", -- Dwarf Rune Stone
    [63127] = "archaeology", -- Highborne Scroll
    [63128] = "archaeology", -- Troll Tablet
    [64392] = "archaeology", -- Orc Blood Text
    [64394] = "archaeology", -- Draenei Tome
    [64395] = "archaeology", -- Vrykul Rune Stick
    [64396] = "archaeology", -- Nerubian Obelisk
    [64397] = "archaeology", -- Tol'vir Hieroglyphic
    -- PvP tokens
    [137642] = "pvp", -- Mark of Honor
    [230285] = "pvp", -- Astral Combatant's Heraldry
    [230287] = "pvp", -- Astral Gladiator's Heraldry
    [256559] = "pvp", -- Galactic Combatant's Heraldry (Midnight)
    [256607] = "pvp", -- Galactic Aspirant's Heraldry (Midnight)
    [256608] = "pvp", -- Galactic Gladiator's Heraldry (Midnight)
    -- Lumber (housing crafting reagents)
    [242691] = "lumber", -- Olemba Lumber
    [245586] = "lumber", -- Ironwood Lumber
    [248012] = "lumber", -- Dornic Fir Lumber
    [251762] = "lumber", -- Coldwind Lumber
    [251763] = "lumber", -- Bamboo Lumber
    [251764] = "lumber", -- Ashwood Lumber
    [251766] = "lumber", -- Shadowmoon Lumber
    [251767] = "lumber", -- Fel-Touched Lumber
    [251768] = "lumber", -- Darkpine Lumber
    [251772] = "lumber", -- Arden Lumber
    [251773] = "lumber", -- Dragonpine Lumber
    [256963] = "lumber", -- Thalassian Lumber
}

-- Category key → owning role (characters with this role keep the items)
local CATEGORY_ROLE_MAP = {
    pets = "zookeeper",
    pvp = "pvper",
}

-------------------------------------------------------------------------------
-- Role Recipient Lookup
-------------------------------------------------------------------------------

-- Recipient lookup for mail routing, driven by a predicate on registry entries.
-- Warbound items can be mailed cross-realm (same Battle.net account).
-- Regular tradeable items can only be mailed within the same realm.
-- Returns: method ("mail"|"stash"|nil), recipientName
local function FindRecipientBy(addon, isWarbound, predicate)
    local currentEntry = addon.db.global.registry[addon.playerGUID]
    local currentRealm = currentEntry and currentEntry.realm
    local currentName = currentEntry and currentEntry.name

    local sameRealm, anyRealm = nil, nil
    for guid, e in pairs(addon.db.global.registry) do
        -- Skip self by GUID or by name+realm (imported stub may have a different GUID)
        local isSelf = guid == addon.playerGUID or (currentName and e.name == currentName and e.realm == currentRealm)
        if not isSelf and predicate(e) then
            local eRealm = e.realm
            if not currentRealm or not eRealm or eRealm == currentRealm then
                sameRealm = e
                break
            elseif not anyRealm then
                anyRealm = e
            end
        end
    end

    if sameRealm then
        return "mail", sameRealm.name
    elseif anyRealm then
        if isWarbound then
            return "mail", anyRealm.name .. "-" .. (anyRealm.realm or "")
        else
            return "stash", anyRealm.name
        end
    end
    return nil, nil
end

local function HasEnchanting(e)
    return e.assignments and e.assignments.artisan and e.assignments.artisan.enchanting
end

-- Cached recipient lookup: returns results from per-scan cache to avoid
-- iterating the registry for every routable item.
function EmpireManager:CachedFindRecipient(roleKey, isWarbound)
    local ctx = self._classifyCtx
    local cacheKey = roleKey .. (isWarbound and "_wb" or "_nw")
    local cached = ctx and ctx.recipientCache[cacheKey]
    if cached ~= nil then
        return cached.method, cached.name
    end

    local predicate
    if roleKey == "enchanter" then
        predicate = HasEnchanting
    else
        predicate = function(e)
            return e.assignments and e.assignments[roleKey]
        end
    end
    local method, name = FindRecipientBy(self, isWarbound, predicate)
    if ctx then
        ctx.recipientCache[cacheKey] = { method = method, name = name }
    end
    return method, name
end

-------------------------------------------------------------------------------
-- ilvl Comparison (fallback when Pawn is not installed)
-------------------------------------------------------------------------------

-- Returns the lowest equipped ilvl across the slots matching an itemEquipLoc.
-- For dual slots (rings, trinkets), returns the min of the two equipped items.
-- Returns nil if no item is equipped in any matching slot.
function EmpireManager:GetEquippedIlvlForSlot(itemEquipLoc)
    local slots = EQUIPLOC_TO_SLOTS[itemEquipLoc]
    if not slots then
        return nil
    end
    local minIlvl = nil
    for _, slotID in ipairs(slots) do
        local link = GetInventoryItemLink("player", slotID)
        if link then
            local ilvl = C_Item.GetDetailedItemLevelInfo(link)
            if ilvl and (not minIlvl or ilvl < minIlvl) then
                minIlvl = ilvl
            end
        end
    end
    return minIlvl
end

-- Returns true if any currently-equipped item in the slots matching itemEquipLoc
-- shares the same classID+subClassID as the dropped item. Purpose: prevent
-- vendoring a gear type the player is not actually using (e.g. 2H sword while
-- equipping daggers, mail drop while wearing leather). Returns false if the
-- slot is empty or every equipped piece is a different weapon/armor subtype.
function EmpireManager:HasMatchingEquippedType(itemEquipLoc, classID, subClassID)
    local slots = EQUIPLOC_TO_SLOTS[itemEquipLoc]
    if not slots then
        return false
    end
    for _, slotID in ipairs(slots) do
        local link = GetInventoryItemLink("player", slotID)
        if link then
            local _, _, _, _, _, eqClassID, eqSubClassID = C_Item.GetItemInfoInstant(link)
            if eqClassID == classID and eqSubClassID == subClassID then
                return true
            end
        end
    end
    return false
end

-------------------------------------------------------------------------------
-- TSM Price Lookup (optional dependency)
-------------------------------------------------------------------------------

-- Returns price in copper from TSM, or nil if TSM is not loaded / has no data.
function EmpireManager:GetTSMPrice(itemLink, priceSource)
    if not TSM_API or not TSM_API.GetCustomPriceValue then
        return nil
    end
    local tsmItem = TSM_API.ToItemString(itemLink)
    if not tsmItem then
        return nil
    end
    local price = TSM_API.GetCustomPriceValue(priceSource, tsmItem)
    if price and price > 0 then
        return price
    end
    return nil
end

-- Item class constants for disenchant eligibility
local ITEM_CLASS_WEAPON = 2 -- Enum.ItemClass.Weapon
local ITEM_CLASS_ARMOR = 4 -- Enum.ItemClass.Armor

-- True if the player currently has any equipped armor of the given tier. Used as
-- a proxy for "has this class unlocked its primary armor proficiency" so we don't
-- vendor the lower-tier gear a leveling alt is still wearing before that unlock.
function EmpireManager:HasArmorTierEquipped(tier)
    for _, slotID in ipairs(self.ARMOR_TIER_SLOTS) do
        local link = GetInventoryItemLink("player", slotID)
        if link then
            local _, _, _, _, _, classID, subClassID = C_Item.GetItemInfoInstant(link)
            if classID == ITEM_CLASS_ARMOR and subClassID == tier then
                return true
            end
        end
    end
    return false
end

-- Vendor reason for a soulbound weapon the class can never equip, or nil.
-- Data: EmpireManager.CLASS_NEVER_USABLE_WEAPON (Utils.lua).
function EmpireManager:WeaponVendorReason(item, entry)
    if item.itemClassID ~= ITEM_CLASS_WEAPON then
        return nil
    end
    local neverSet = self.CLASS_NEVER_USABLE_WEAPON[entry.class or ""]
    if not neverSet then
        return nil -- unknown class: don't guess
    end
    if neverSet[item.itemSubClassID] then
        return "Unusable weapon type"
    end
    return nil
end

-- Vendor reason for soulbound armor that isn't the class's primary tier, or nil.
--   subclass > primary  → permanently unusable (priest+plate): always vendor.
--   subclass < primary  → suboptimal lower tier: vendor only once the character
--                          has its primary-tier proficiency (proficient == true),
--                          so leveling alts keep the gear they're still wearing.
--   subclass == primary  → keep.
-- Only the four wearable tiers (subclass 1-4) qualify; misc (0) is excluded.
-- Data: EmpireManager.CLASS_PRIMARY_ARMOR_TIER (Utils.lua).
function EmpireManager:ArmorTierVendorReason(item, entry, proficient)
    if item.itemClassID ~= ITEM_CLASS_ARMOR then
        return nil
    end
    local sub = item.itemSubClassID
    local class = entry.class or ""
    -- Shields (subclass 6): unusable unless the class is a shield user. Always
    -- vendor for everyone else - level-independent, like an over-tier piece.
    if sub == 6 then
        if self.CLASS_CAN_USE_SHIELD[class] or not self.CLASS_PRIMARY_ARMOR_TIER[class] then
            return nil -- shield user, or unknown class: don't guess
        end
        return "Unusable shield"
    end
    if not sub or sub < 1 or sub > 4 then
        return nil
    end
    -- Tier restriction applies only to real body-armor slots. Cloaks are
    -- subClassID 1 (Cloth) but worn by every class, so they must not be treated
    -- as off-tier; same for shirts/tabards (those are subclass 0 anyway).
    if not self.ARMOR_TIER_EQUIPLOC[item.itemEquipLoc or ""] then
        return nil
    end
    local primary = self.CLASS_PRIMARY_ARMOR_TIER[class]
    if not primary then
        return nil -- unknown class: don't guess
    end
    if sub > primary then
        return "Unusable armor type"
    end
    if sub < primary and proficient then
        return "Off-tier armor (suboptimal)"
    end
    return nil
end

-- Set name protecting this specific item, or nil. Prefers a unique-GUID match so
-- duplicates of a set piece are not protected; falls back to the itemID map,
-- which only holds set slots whose location couldn't be resolved to a GUID.
-- Guild-bank items have no resolvable ItemLocation, so they use the fallback too.
function EmpireManager:EquipSetNameForItem(item)
    if self._equipSetGUIDs and item.bag and item.slot and ItemLocation and C_Item and C_Item.GetItemGUID then
        local loc = ItemLocation:CreateFromBagAndSlot(item.bag, item.slot)
        if loc and loc:IsValid() then
            local ok, guid = pcall(C_Item.GetItemGUID, loc)
            if ok and guid then
                local name = self._equipSetGUIDs[guid]
                if name then
                    return name
                end
            end
        end
    end
    if self._equipSetItems then
        return self._equipSetItems[item.itemID]
    end
    return nil
end

-- True if this Miscellaneous item teaches a mount the player already has, or a
-- battle pet already owned up to the species cap. Soulbound such items are dead
-- weight (can't relearn, can't trade), so they route to vendor. Mounts are binary
-- (known or not); pets must be at their collection limit so a soulbound dupe can
-- still be learned to fill an open slot. Only call for classID 15 sub 2/5 items.
function EmpireManager:IsKnownCollectible(item)
    if item.itemClassID ~= ITEM_CLASS_MISC then
        return false
    end
    if item.itemSubClassID == ITEM_SUBCLASS_MOUNT then
        if C_MountJournal and C_MountJournal.GetMountFromItem then
            local mountID = C_MountJournal.GetMountFromItem(item.itemID)
            if mountID then
                -- GetMountInfoByID: isCollected is the 11th return value.
                return select(11, C_MountJournal.GetMountInfoByID(mountID)) == true
            end
        end
    elseif item.itemSubClassID == ITEM_SUBCLASS_COMPANION then
        if C_PetJournal and C_PetJournal.GetPetInfoByItemID then
            -- GetPetInfoByItemID: speciesID is the 13th return value.
            local speciesID = select(13, C_PetJournal.GetPetInfoByItemID(item.itemID))
            if speciesID then
                local numCollected, limit = C_PetJournal.GetNumCollectedInfo(speciesID)
                return numCollected and limit and limit > 0 and numCollected >= limit
            end
        end
    end
    return false
end

-- Determine if a BoE item should be disenchanted rather than sold on the AH.
-- With TSM: disenchant value > market value → DE is more profitable.
-- Without TSM: per-unit sell price < threshold → DE (user-configured fallback).
function EmpireManager:ShouldDisenchant(item)
    -- Only weapons and armor can be disenchanted
    if item.itemClassID ~= ITEM_CLASS_WEAPON and item.itemClassID ~= ITEM_CLASS_ARMOR then
        return false
    end
    -- WoW requires uncommon (green, quality >= 2) or higher for disenchanting
    if (item.quality or 0) < 2 then
        return false
    end

    local deValue = self:GetTSMPrice(item.itemLink, "DBDisenchant")
    local marketValue = self:GetTSMPrice(item.itemLink, "DBMarket")

    if deValue and marketValue then
        return deValue > marketValue
    end

    -- Fallback: threshold-based (when TSM is unavailable or has no data).
    -- Threshold is stored in copper (same unit as item sell price).
    local thresholdCopper = self.db.global.options.disenchantThreshold or 0
    if thresholdCopper > 0 then
        local value = marketValue or item.sellPricePerUnit or 0
        return value > 0 and value < thresholdCopper
    end

    return false
end

-------------------------------------------------------------------------------
-- Classification Logic
-------------------------------------------------------------------------------

-- Build per-scan context to avoid repeated lookups inside ClassifyItem.
-- Called once before the classification loop in RunTriage/RunTriageAsync/RunBankTriageAsync.
local function PrepareClassificationContext(addon)
    if not storageCacheBuilt then
        RebuildStorageCache(addon)
    end

    local opts = addon.db.global.options or {}
    local ctx = {
        keepList = addon.db.global.keepList or {},
        vendorWhitelist = addon.db.global.vendorWhitelist or {},
        storageAssignments = addon.db.global.storageAssignments or {},
        vendorBopIlvl = opts.vendorBopIlvl,
        pawnVendorBop = opts.pawnVendorBop,
        vendorIlvlCeiling = opts.vendorIlvlCeiling or 0,
        disenchantRouting = opts.disenchantRouting,
        playerLevel = UnitLevel("player") or 0,
    }

    -- Cache recipient lookups (registry doesn't change during a scan)
    local recipientCache = {}
    ctx.recipientCache = recipientCache
    -- Lazily populated: recipientCache["lockpicker_true"] = { method, name }

    -- Cache equipped ilvl per equip location (gear doesn't change during a scan)
    ctx.equippedIlvlCache = {}
    -- Cache "does equipped gear share this item's classID+subClassID?" per (loc, type)
    -- to avoid repeated GetInventoryItemLink/GetItemInfoInstant calls.
    ctx.equippedTypeCache = {}

    -- Cache smallest equipped bag size per container subtype (Rule D.2a-bag).
    -- Regular bags: bag IDs 1-4 (backpack 0 excluded - it can't be replaced).
    -- Reagent bag: bag ID 5 (single slot, only one can ever be equipped).
    local smallestRegular
    for bag = 1, 4 do
        local slots = C_Container.GetContainerNumSlots(bag) or 0
        if slots > 0 and (not smallestRegular or slots < smallestRegular) then
            smallestRegular = slots
        end
    end
    ctx.smallestEquippedBag = smallestRegular
    ctx.reagentBagSlots = C_Container.GetContainerNumSlots(5) or 0

    addon._classifyCtx = ctx
end

-- True if a restock entry targets the current character (charbank/bags are
-- per-character; warband/guild are shared so always "true" for the matching dest).
local function RestockEntryTargetsMe(addon, e)
    if e.dest == "charbank" or e.dest == "bags" then
        local guid = addon.playerGUID
        if e.chars then
            for _, g in ipairs(e.chars) do
                if g == guid then
                    return true
                end
            end
            return false
        end
        return e.char == guid
    end
    return true
end

-- The Restock floor target for `itemID` in destination `dest` (the bank type the
-- item sits in, or "bags"), or 0 if no matching floor. Restock is a floor: up to
-- `target` of the item is protected from being moved/vendored; the surplus above it
-- is free to follow Storage Rules. The running per-scan count lives in the classify
-- context (ctx.restockUsed) so protection releases once the floor is met.
function EmpireManager:RestockFloorTarget(itemID, dest)
    if not itemID or not dest then
        return 0
    end
    local list = self.db.global.restockList
    if not list or #list == 0 then
        return 0
    end
    local total = 0
    for _, e in ipairs(list) do
        if e.itemID == itemID and e.dest == dest and RestockEntryTargetsMe(self, e) then
            total = total + (e.target or 0)
        end
    end
    return total
end

-- Restock floor for an item, per-scan running tally. Quantity-aware, NO scan-time bag
-- manipulation:
--   remaining = target - used (units the floor still wants)
--   remaining <= 0  : floor met -> route whole slot (false)
--   qty <= remaining: whole slot is floor -> KEEP (true), consume qty
--   qty >  remaining: slot STRADDLES -> keep `remaining` units, set
--                     item._restockSurplus = qty - remaining, return false so the slot
--                     routes; the surplus quantity is split off at ACTION time (mail/
--                     deposit), never on scan. This keeps exactly the floor (e.g. 208)
--                     and sends the rest, with no scan churn.
local function RestockProtectWithinFloor(addon, item, dest)
    local itemID = item.itemID
    local target = addon:RestockFloorTarget(itemID, dest)
    if target <= 0 then
        return false
    end
    local ctx = addon._classifyCtx
    local used = (ctx and ctx.restockUsed and ctx.restockUsed[dest] and ctx.restockUsed[dest][itemID]) or 0
    local remaining = target - used
    if remaining <= 0 then
        return false -- floor already met by earlier slots: route this surplus slot
    end
    local qty = item.stackCount or 1
    local function consume(n)
        if ctx then
            ctx.restockUsed = ctx.restockUsed or {}
            ctx.restockUsed[dest] = ctx.restockUsed[dest] or {}
            ctx.restockUsed[dest][itemID] = used + n
        end
    end
    if qty <= remaining then
        consume(qty)
        return true -- entire slot is within the floor: keep it
    end
    -- Straddles: keep `remaining`, release the surplus (split at action time).
    consume(remaining)
    item._restockSurplus = qty - remaining
    return false
end

-- Public entry point. Wraps the classification logic so a per-character
-- "Skip all Storage Rules" opt-out (entry.ignoreStorageRules) can neutralize any
-- storage-routing outcome in one place, no matter which inner rule produced it.
-- STASH/ROUTE results collapse to KEEP "Ignoring storage rules"; KEEP and VENDOR
-- results (Keep List, vendor whitelist, gray junk, class-unusable gear, etc.)
-- pass through unchanged. ClassifyBankItem derives takeout/reorganize from the
-- returned category, so this single guard also suppresses bank-side moves.
function EmpireManager:ClassifyItem(item, entry)
    -- A selected TSM Group is an explicit user instruction: it wins over every rule.
    -- Derive the side from the item: ClassifyItem also runs for bank items (via
    -- ClassifyBankItem), so hardcoding "bags" claimed bank items too.
    if self:GroupMoverClaims(item, item.bankType or "bags") then
        local dest = self:GroupMoverEndpointLabel(self._groupMoverTo) or "?"
        return CAT_STASH, "TSM Group: to " .. dest, {
            destType = self._groupMoverTo,
            destTabs = nil,
        }
    end
    local category, action, routing, blocked, blockedRules = self:_ClassifyItemInner(item, entry)
    if entry.ignoreStorageRules and (category == CAT_STASH or category == CAT_ROUTE) then
        return CAT_KEEP, "Ignoring storage rules"
    end
    return category, action, routing, blocked, blockedRules
end

function EmpireManager:_ClassifyItemInner(item, entry)
    local ctx = self._classifyCtx -- per-scan context from PrepareClassificationContext

    -- Overflow tracking: when a matching assignment is skipped because the
    -- destination has no free slots, set this flag. If no later rule wins,
    -- we surface "All destinations full" instead of generic "No matching Rule".
    -- Skipped for items already in a bank (reorg path) - we shouldn't refuse
    -- to leave items in place when their assigned tab is full of themselves.
    --
    -- Capacity is gauged from EMPTY slots only; the snapshot can't see partial
    -- stacks. Two outcomes when a matching rule's tabs have no empty slot:
    --   * Non-stackable item: genuinely can't fit -> block it (greyed, warned)
    --     as "All matching destinations are full".
    --   * Stackable item: MIGHT still merge into a partial stack already in a
    --     "full" tab. We remember the first such rule but keep scanning for a
    --     rule with real free space. If none wins, we route to the remembered
    --     rule anyway (so the deposit button works and the merge is attempted)
    --     AND still surface the "may be full" advisory so the user isn't blind
    --     to it. The deposit engine merges if it can; if not, the move fails
    --     silently and the item reappears next scan (documented graceful path).
    local capacityBlocked = false
    local itemStackable = (item.maxStack or 1) > 1
    local blockedStackAsn, blockedStackRule = nil, nil
    -- Every rule index skipped for lack of capacity, in match order. The blocked
    -- result carries no routing (that is what keeps it out of the deposit move
    -- list), so this is the only record of WHICH rules were full - the tooltip
    -- needs it to name them instead of showing a bare message.
    local blockedRules = nil
    local function NoteBlocked(ruleIndex)
        if not ruleIndex then
            return
        end
        blockedRules = blockedRules or {}
        for _, idx in ipairs(blockedRules) do
            if idx == ruleIndex then
                return
            end
        end
        blockedRules[#blockedRules + 1] = ruleIndex
    end
    local function HasCapacity(assignment, ruleIndex)
        if item.bankType then
            return true -- reorganizing - bind/capacity checks deferred to Blizzard
        end
        if self:HasFreeCapacity(assignment) then
            return true
        end
        NoteBlocked(ruleIndex)
        if itemStackable then
            -- Remember the first full-but-maybe-mergeable rule; keep looking for
            -- a rule with real free space before falling back to this one.
            if not blockedStackAsn then
                blockedStackAsn, blockedStackRule = assignment, ruleIndex
            end
            return false
        end
        capacityBlocked = true
        return false
    end

    -- Keep List: items here are protected from every triage action (vendor, mail, stash).
    -- Wins over every other rule, including vendorWhitelist.
    if ctx and ctx.keepList[item.itemID] then
        return CAT_KEEP, "Keep List"
    end

    -- Character Bags restock floor: keeps whole slots up to `floor` in bags (may
    -- over-keep the straddling slot; never routes the floor away). Slots above the
    -- floor route as surplus per the storage rules.
    if not item.bankType then
        if RestockProtectWithinFloor(self, item, "bags") then
            return CAT_KEEP, "Restock floor (bags)"
        end
    end

    -- Teleport guard: trinkets/rings/cloaks with "Use: Teleport" effects are
    -- irreplaceable utility (Cloak of Coordination, Runed Signet of the Kirin
    -- Tor, Time-Lost Artifact). Wins over vendor whitelist and gear-vendor
    -- rules so a stale whitelist entry can't burn a teleport.
    if item.isTeleport then
        return CAT_KEEP, "Teleport item"
    end

    -- Vendor whitelist: force specific items to VENDOR
    if ctx and ctx.vendorWhitelist[item.itemID] and item.sellPrice > 0 then
        return CAT_VENDOR, "Vendor (whitelisted)"
    end

    -- Conjured guard: mage food/water, healthstones, soulwells, etc. cannot be
    -- mailed, deposited in any bank, or sold on the AH (ERR_AUCTION_CONJURED_ITEM),
    -- so Route/Stash are dead ends. Keep them in bags. An explicit vendor whitelist
    -- entry above still wins for a user who wants to clear them at a merchant.
    if item.isConjured then
        return CAT_KEEP, "Conjured item"
    end

    -- Equipment-token guard: items classed as Consumables (classID 0) that are
    -- really "right-click for a piece of gear" tokens (BfA Unsullied set, etc.).
    -- They carry a "Use:" line AND a "Classes:" restriction, which real
    -- consumables never do. Without this they match the consumables subclass map
    -- (0/8 "Other") and get mailed to a consumables banker, which is wrong - the
    -- player should keep the token and open it. Keep in bags.
    if item.isEquipToken and item.itemClassID == 0 then
        return CAT_KEEP, "Equipment token (right-click to open)"
    end

    -- Known appearance (weapon enchant illusions, etc.): classed as a Consumable
    -- (0/8 "Other") but really a right-click-to-learn cosmetic. The tooltip
    -- carries the red "Already known" line once collected. Known + soulbound +
    -- sellable → VENDOR: can't be relearned or traded, so a known duplicate is
    -- dead weight (mirrors "Mount already known").
    --
    -- There is NO positive "teaches an appearance" signal here - isKnownAppearance
    -- comes from ITEM_SPELL_KNOWN, a collection-state line shared by known
    -- recipes/toys/mounts. So we must NOT infer "unlearned appearance" from a
    -- missing known-line: 0/8 is Blizzard's Consumable dumping ground (upgrade
    -- currency, reputation contracts, lockbox scrolls, utility consumables), and
    -- an unconditional keep here swallowed the whole bucket and short-circuited
    -- the consumables subclass match below. Everything that isn't a known
    -- appearance falls through to normal classification.
    if item.itemClassID == 0 and item.itemSubClassID == 8 and item.isKnownAppearance then
        if item.isBound and not item.isWarbound and item.sellPrice > 0 then
            return CAT_VENDOR, "Illusion already known"
        end
    end

    -- Rule D.1: Poor quality items with a sell price → VENDOR (skip unsellable ones
    -- like books). BoE poor quality items (bindType 2) are left alone so the user can
    -- sell/AH them, unless the vendorBoePoor option opts them back in. Vendor trash
    -- (bindType 0) and soulbound poor quality items always vendor.
    if item.quality == 0 and item.sellPrice > 0 and not item.isWarbound then
        if item.bindType ~= 2 or self.db.global.options.vendorBoePoor then
            return CAT_VENDOR, "Vendor junk"
        end
    end

    -- Rule D.2a-bag: Soulbound container smaller than smallest equipped → VENDOR.
    -- classID 1 = Container. Subclass 0 = regular bag (bags 1-4), subclass 11 =
    -- reagent bag (bag 5). Profession bags (1-10) are situational - left alone.
    if
        item.isBound
        and not item.isWarbound
        and item.itemClassID == 1
        and (item.itemSubClassID == 0 or item.itemSubClassID == 11)
        and item.sellPrice > 0
    then
        local bagSlots = ParseBagSlots(item.itemLink)
        local compareTo
        if item.itemSubClassID == 11 then
            compareTo = ctx and ctx.reagentBagSlots
        else
            compareTo = ctx and ctx.smallestEquippedBag
        end
        if bagSlots and compareTo and compareTo > 0 and bagSlots < compareTo then
            return CAT_VENDOR, string.format("Inferior bag (%d slots)", bagSlots)
        end
    end

    -- Rule D.2a: Soulbound equippable gear → Pawn/iLvl vendor check
    -- Only actual gear (Weapon=2, Armor=4) qualifies - recipes, consumables, etc. skip.
    -- Warbound gear skips this - it can be routed to other characters.
    -- Enchanter override: if the character has Enchanting and enchanterKeepDE is on,
    -- gear that would be vendored is kept for disenchanting instead.
    if item.isBound and not item.isWarbound then
        local isEquipGear = item.itemEquipLoc ~= ""
            and (item.itemClassID == ITEM_CLASS_WEAPON or item.itemClassID == ITEM_CLASS_ARMOR)
        if isEquipGear and item.sellPrice > 0 and item.quality < 5 then
            -- Equipment set guard: skip vendoring gear in any saved set (O(1) lookup).
            -- Match on the item's unique GUID so a duplicate of a set piece sitting
            -- in bags is NOT protected - only the exact instance the set references.
            -- _equipSetItems holds itemID entries only for set slots whose location
            -- couldn't be resolved, so those keep the old (broad) protection.
            local setName = self:EquipSetNameForItem(item)
            if setName then
                return CAT_KEEP, "Equipment set: " .. setName
            end
            -- Required-level guard: gear the character can't equip yet (its required
            -- level is above the player's level) is a future upgrade, not junk. Pawn
            -- reports it as "not an upgrade" because it can't be equipped now, and the
            -- iLvl comparison would flag it too - keep it until the character can use it.
            local reqLevel = select(5, C_Item.GetItemInfo(item.itemLink))
            if reqLevel and ctx and ctx.playerLevel > 0 and reqLevel > ctx.playerLevel then
                return CAT_KEEP, string.format("Requires level %d", reqLevel)
            end
            -- Off-tier armor: anything that isn't the class's primary armor tier.
            -- Higher tiers are never usable (priest+plate); lower tiers are
            -- suboptimal and vendored only once the class has primary-tier
            -- proficiency (so leveling alts keep what they're still wearing).
            -- Vendored regardless of iLvl/ceiling and independent of the Pawn/iLvl
            -- options. The enchanter-DE override still applies.
            do
                local primaryTier = self.CLASS_PRIMARY_ARMOR_TIER[entry.class or ""]
                local proficient = false
                if primaryTier then
                    if ctx then
                        if ctx.armorTierProficient == nil then
                            ctx.armorTierProficient = self:HasArmorTierEquipped(primaryTier)
                        end
                        proficient = ctx.armorTierProficient
                    else
                        proficient = self:HasArmorTierEquipped(primaryTier)
                    end
                end
                local gearReason = self:ArmorTierVendorReason(item, entry, proficient)
                    or self:WeaponVendorReason(item, entry)
                if gearReason then
                    local asn = entry.assignments or {}
                    if entry.enchanterKeepDE ~= false and asn.artisan and asn.artisan.enchanting then
                        return CAT_KEEP, "Keep for disenchant"
                    end
                    return CAT_VENDOR, gearReason
                end
            end
            -- iLvl ceiling: gear at or above the configured ceiling is preserved
            -- regardless of Pawn/iLvl checks. Guards against vendoring upgrades
            -- triage misclassified (e.g. greens close to current gear).
            local ceiling = ctx and ctx.vendorIlvlCeiling or 0
            if ceiling > 0 then
                local itemIlvl = C_Item.GetDetailedItemLevelInfo(item.itemLink)
                if itemIlvl and itemIlvl >= ceiling then
                    return CAT_KEEP, string.format("Above iLvl limit (%d)", ceiling)
                end
            end
            -- Gear-type guard: only vendor if the player is actually using
            -- this exact classID+subClassID (e.g. vendor a dagger only when a
            -- dagger is equipped; vendor mail only when mail is equipped).
            -- Protects off-spec weapons (2H when dual-wielding, bows for a
            -- rogue alt, etc.) and wrong-armor-type drops without needing the
            -- user to curate the Keep List in advance.
            if ctx and (ctx.vendorBopIlvl or ctx.pawnVendorBop) then
                local typeKey = (item.itemClassID or 0) * 100000 + (item.itemSubClassID or 0)
                local typeCacheKey = item.itemEquipLoc .. ":" .. typeKey
                if ctx.equippedTypeCache[typeCacheKey] == nil then
                    ctx.equippedTypeCache[typeCacheKey] =
                        self:HasMatchingEquippedType(item.itemEquipLoc, item.itemClassID, item.itemSubClassID)
                end
                if not ctx.equippedTypeCache[typeCacheKey] then
                    return CAT_KEEP, "Off-type Gear (No matching slot equipped)"
                end
            end
            -- ilvl comparison: vendor if item ilvl < lowest equipped in that slot
            -- BUG (12.0): GetDetailedItemLevelInfo returns pre-squish ilvl for old items
            -- (e.g. 554 instead of 79). Comparison is broken until Blizzard fixes it.
            local equippedIlvl, itemIlvl
            if ctx and ctx.vendorBopIlvl then
                -- Use cached ilvl per equip location
                local loc = item.itemEquipLoc
                if ctx.equippedIlvlCache[loc] == nil then
                    ctx.equippedIlvlCache[loc] = self:GetEquippedIlvlForSlot(loc) or false
                end
                equippedIlvl = ctx.equippedIlvlCache[loc] or nil
                itemIlvl = C_Item.GetDetailedItemLevelInfo(item.itemLink)
            end
            -- Collect vendor reason instead of returning immediately
            -- (enchanter override checked after all vendor checks)
            local vendorReason
            -- Pawn check (if installed and enabled)
            local pawnResult = nil -- nil = unavailable/uncertain
            if ctx and ctx.pawnVendorBop and PawnIsItemDefinitivelyAnUpgrade then
                pawnResult = PawnIsItemDefinitivelyAnUpgrade(item.itemLink)
                if pawnResult == false then
                    -- Pawn says not an upgrade, but for dual slots (rings/trinkets)
                    -- keep it if ilvl >= lowest equipped (could replace the weaker one).
                    -- Guard: GetDetailedItemLevelInfo returns pre-squish ilvl for old
                    -- expansion items (e.g. 554 instead of 79). Detect by checking if
                    -- itemIlvl is more than 2x equippedIlvl - trust Pawn in that case.
                    if
                        not (equippedIlvl and itemIlvl and itemIlvl >= equippedIlvl and itemIlvl <= equippedIlvl * 2)
                    then
                        vendorReason = "Soulbound non-upgrade (Pawn)"
                    end
                    -- pawnResult == true: Pawn says upgrade - skip ilvl check, keep
                end
            end
            -- ilvl fallback: runs when Pawn is unavailable, uncertain (nil), or not enabled
            if not vendorReason and pawnResult == nil and ctx and ctx.vendorBopIlvl then
                if equippedIlvl and equippedIlvl > 0 and itemIlvl and itemIlvl < equippedIlvl then
                    vendorReason = "Soulbound lower iLvl"
                end
            end
            -- Enchanter override: keep for DE instead of vendoring
            if vendorReason then
                local asn = entry.assignments or {}
                if entry.enchanterKeepDE ~= false and asn.artisan and asn.artisan.enchanting then
                    return CAT_KEEP, "Keep for disenchant"
                end
                return CAT_VENDOR, vendorReason
            end
        end
    end

    local assignments = entry.assignments or {}

    -- ItemID-based category matching (lumber, archaeology, PvP tokens, etc.)
    -- Checked before soulbound - these are known categories that route by itemID
    -- regardless of bind status (WoW reports warbound reagents as isBound=true).
    local itemCategory = ITEM_CATEGORY_MAP[item.itemID]
    if itemCategory then
        -- Own role check: zookeeper keeps pet consumables, pvper keeps PvP tokens
        local ownerRole = CATEGORY_ROLE_MAP[itemCategory]
        if ownerRole and assignments[ownerRole] then
            return CAT_KEEP, "Own role item"
        end
        -- Check storage assignments for this category
        local assignments_list = ctx and ctx.storageAssignments or {}
        for ruleIndex, assignment in ipairs(assignments_list) do
            if assignment.profession == itemCategory then
                if
                    IsBankTypeCompatible(item, assignment)
                    and IsAssignmentEligible(assignment, item)
                    and HasCapacity(assignment, ruleIndex)
                then
                    return self:GetStorageRouting(assignment, entry, itemCategory, ruleIndex, item)
                end
            end
        end
        -- No storage assignment matched - fall through to remaining rules
    end

    -- Rule D.2b-quest: Quest items (classID 12) and Keys (classID 13) → check storage assignment with bind restrictions
    -- Soulbound: charbank only. Warbound: charbank or warbandbank. Unbound: any.
    if item.itemClassID == 12 or item.itemClassID == 13 then
        local matchSet = GetProfMatchSet(item)
        if matchSet then
            local assignments_list = ctx and ctx.storageAssignments or {}
            for ruleIndex, assignment in ipairs(assignments_list) do
                if matchSet[assignment.profession] then
                    -- Enforce physical bind constraints on bank type
                    local typeOK = true
                    if item.isBound and not item.isWarbound then
                        typeOK = assignment.type == "charbank"
                    elseif item.isWarbound then
                        typeOK = assignment.type == "charbank" or assignment.type == "warbandbank"
                    end
                    if typeOK and IsAssignmentEligible(assignment, item) and HasCapacity(assignment, ruleIndex) then
                        return self:GetStorageRouting(assignment, entry, assignment.profession, ruleIndex, item)
                    end
                end
            end
        end
        -- Stash old quest items and keys to character bank (opt-in via Sidecar).
        -- Covers bound AND unbound, the expansion filter prevents touching current-content items.
        if
            entry.stashOldQuestItems
            and not item.isWarbound
            and not item.bankType
            and not OLD_QUEST_STASH_BLOCKLIST[item.itemID]
            and item.expansionID
            and item.expansionID < GetExpansionLevel()
        then
            return CAT_STASH, "Move to Bank (Old Quest item)", { destType = "charbank", profKey = "quest_old" }
        end
        -- No assignment matched: soulbound quest items → KEEP
        if item.isBound and not item.isWarbound then
            return CAT_KEEP, "Soulbound"
        end
        -- Warbound/unbound quest items fall through to remaining rules
    end

    -- Rule D.2b-artifact: Legion artifact weapons -> charbank.
    if (item.quality or 0) == 6 and item.itemClassID == 2 and not item.bankType then
        return CAT_STASH, "Move to Bank (Artifact Weapon)", { destType = "charbank", profKey = "quest_old" }
    end

    -- Rule D.2b-oldmisc: Extend stashOldQuestItems to BoP/warbound clutter.
    --   classID 15 sub 0 (Misc/Junk) + sub 4 (Misc/Other): legacy quest-reward
    --     clutter (faction tokens, lore items, relics, fragments, NPC gifts,
    --     legacy raid tier tokens like Conqueror's Mark of Sanctification).
    --     Both soulbound and warbound items in this bucket - they're all stuck
    --     legacy junk regardless of bind state.
    --   classID 0 sub 0 (Consumable/Generic) + sub 8 (Consumable/Other): legacy
    --     event toys, challenge-mode cosmetics, old buffs (War Ravaged Armor
    --     Set, Battle Standard, Blossoming Branch, Elixir of Shadow Sight...).
    --     Soulbound only - warbound consumables already route via the
    --     Consumables category match in the profession loop above.
    -- Items of current expansion level are spared. Blocklist protects always-
    -- useful items (Hearthstone, Shadowguard Translocator, Timewalking keys).
    if
        entry.stashOldQuestItems
        and item.isBound
        and not item.bankType
        and not OLD_QUEST_STASH_BLOCKLIST[item.itemID]
        and item.expansionID
        and item.expansionID < GetExpansionLevel()
        and (
            (item.itemClassID == 15 and (item.itemSubClassID == 0 or item.itemSubClassID == 4))
            or (
                item.itemClassID == 0
                and (item.itemSubClassID == 0 or item.itemSubClassID == 8)
                and not item.isWarbound
            )
        )
    then
        return CAT_STASH, "Move to Bank (Legacy item)", { destType = "charbank", profKey = "quest_old" }
    end

    -- Rule D.2b-own: Soulbound (BoP) items that match a profession via subclass
    -- and for which THIS character has an own charbank rule → deposit to own bank.
    -- Own charbank accepts BoP items (unlike mail/warband), so bankers can
    -- auto-stash their own-profession BoP reagents (e.g. Truesteel Ingot on
    -- Ax, Artisan's Acuity on Krotos). Skipped if itemCategory was already
    -- considered by the earlier ITEM_CATEGORY_MAP loop.
    if item.isBound and not item.isWarbound and not item.bankType and not itemCategory and item.itemClassID >= 0 then
        local matchSet = GetProfMatchSet(item)
        if
            matchSet
            and item.itemClassID == 7
            and item.isCraftingReagent == false
            and not profOverrideCache[item.itemID or 0]
        then
            matchSet = nil
        end
        if matchSet then
            -- Respect keepOwnProfMatsInBags: if the user wants their own mats kept
            -- in bags for convenience, don't move them to bank even when banker.
            -- The "latest expansion only" sub-option lets old-expansion mats route out.
            if entry.keepOwnProfMatsInBags and not IsBlockedByLatestOnly(entry, item) then
                for _, roleKey in ipairs({ "artisan", "gatherer" }) do
                    local roleData = assignments[roleKey]
                    if roleData and type(roleData) == "table" then
                        for profKey in pairs(roleData) do
                            if matchSet[profKey] then
                                return CAT_KEEP, "Own Profession material"
                            end
                        end
                    end
                end
            end
            local guid = self.playerGUID
            local assignments_list = ctx and ctx.storageAssignments or {}
            for ruleIndex, assignment in ipairs(assignments_list) do
                if
                    assignment.type == "charbank"
                    and assignment.char == guid
                    and matchSet[assignment.profession]
                    and IsAssignmentEligible(assignment, item)
                    and HasCapacity(assignment, ruleIndex)
                then
                    return self:GetStorageRouting(assignment, entry, assignment.profession, ruleIndex, item)
                end
            end
        end
    end

    -- Rule D.2b-collectible: a soulbound mount/pet item teaching something the
    -- player already has is dead weight - it can't be relearned or traded, so
    -- vendor it (when sellable). Mounts vendor once known; pets only at the
    -- species collection cap. Checked before the blanket soulbound keep below.
    if
        item.isBound
        and not item.isWarbound
        and item.sellPrice > 0
        and item.itemClassID == ITEM_CLASS_MISC
        and (item.itemSubClassID == ITEM_SUBCLASS_COMPANION or item.itemSubClassID == ITEM_SUBCLASS_MOUNT)
        and self:IsKnownCollectible(item)
    then
        local reason = (item.itemSubClassID == ITEM_SUBCLASS_MOUNT) and "Mount already known" or "Pet already collected"
        return CAT_VENDOR, reason
    end

    -- Rule D.2b: Non-gear soulbound items → KEEP (never route soulbound).
    -- Warbound items continue to routing rules (can be mailed/warband-banked).
    -- isBound needs an exact "Soulbound" tooltip line, which BoP reagents often
    -- lack ("Binds when picked up" only), so trust bindType: a BoP item in our
    -- bags was picked up, therefore bound.
    local bindsOnPickup = item.bindType == 1 and not item.bankType
    if (item.isBound or bindsOnPickup) and not item.isWarbound then
        return CAT_KEEP, "Soulbound"
    end

    -- Rule B.1: Lockpicker - mail lockboxes to designated lockpicker,
    -- or if this alt IS the lockpicker, keep as own-role item.
    -- Guard: never route a soulbound (non-warbound) lockbox - mail and warband deposit will fail.
    if item.isLockbox and not (item.isBound and not item.isWarbound) then
        if assignments.lockpicker then
            return CAT_KEEP, "Own role item (Lockbox)"
        end
        local method, name = self:CachedFindRecipient("lockpicker", item.isWarbound)
        if method == "mail" then
            return CAT_ROUTE, "Mail to " .. name .. " (Lockbox)"
        elseif method == "stash" then
            return CAT_STASH, "Stash in Warband for " .. name .. " (Lockbox)", { destType = "warbandbank" }
        end
        -- Lockpicker role unassigned or holder unreachable → surface, don't silently keep.
        return CAT_KEEP, "Lockpicker unreachable"
    end

    -- Check if this item matches any profession/category via item subclass
    if not itemCategory and item.itemClassID >= 0 then
        local matchSet = GetProfMatchSet(item)
        -- Trade Goods (classID 7) items that Blizzard explicitly does NOT mark as
        -- crafting reagents (isCraftingReagent == false) are not actual profession
        -- materials despite sharing a subclass with reagents. Subclass 11 ("Other")
        -- especially is a dumping ground for PvP currencies, tokens, Heraldries,
        -- flavor items - none of which should route by profession tag.
        -- Note: this is distinct from nil, which means the cache isn't populated yet;
        -- only `== false` is a definitive "not a reagent" signal.
        -- Itemid overrides bypass this guard - they're explicit reagent declarations.
        if
            matchSet
            and item.itemClassID == 7
            and item.isCraftingReagent == false
            and not profOverrideCache[item.itemID or 0]
        then
            matchSet = nil
        end
        if matchSet then
            -- Own profession mat check (bags): if this character has artisan/gatherer
            -- with a matching profession, keep the mat in bags. Gated by the
            -- per-character keepOwnProfMatsInBags flag, and optionally narrowed to
            -- the latest expansion via keepOwnProfMatsInBagsLatestOnly.
            if not item.bankType and entry.keepOwnProfMatsInBags and not IsBlockedByLatestOnly(entry, item) then
                for _, roleKey in ipairs({ "artisan", "gatherer" }) do
                    local roleData = assignments[roleKey]
                    if roleData and type(roleData) == "table" then
                        for profKey in pairs(roleData) do
                            if matchSet[profKey] then
                                return CAT_KEEP, "Own Profession material"
                            end
                        end
                    end
                end
            end

            local assignments_list = ctx and ctx.storageAssignments or {}

            -- Single pass: array order = priority (first eligible match wins).
            -- Users control priority via up/down reorder buttons.
            for ruleIndex, assignment in ipairs(assignments_list) do
                if matchSet[assignment.profession] then
                    -- Equipment (BoE): only match unbound BoE gear (not bound, not warbound).
                    -- Guild bank items: bindType is unreliable (Blizzard returns BoP for
                    -- Warbound Until Equipped items). If it's in the guild bank, treat all
                    -- equipment as eligible - the guild bank enforced bind rules on deposit.
                    if assignment.profession == "equipment_boe" then
                        local eligible = false
                        if item.bankType == "guildbank" then
                            -- Guild bank: skip bind check, all equipment is eligible
                            eligible = true
                        elseif item.bindType == 2 and not item.isBound and not item.isWarbound then
                            -- Unbound BoE in bags/other bank
                            if not item.bankType and assignments.auctioneer and entry.auctioneerKeepBOE ~= false then
                                -- Auctioneer keeps BoE equipment in bags - skip storage routing
                                eligible = false
                            else
                                eligible = true
                            end
                        end
                        if
                            eligible
                            and IsAssignmentEligible(assignment, item)
                            and HasCapacity(assignment, ruleIndex)
                        then
                            return self:GetStorageRouting(assignment, entry, assignment.profession, ruleIndex, item)
                        end
                    -- Equipment (BoA): only match warbound (account-bound) gear
                    elseif assignment.profession == "equipment_boa" then
                        if
                            item.isWarbound
                            and IsBankTypeCompatible(item, assignment)
                            and IsAssignmentEligible(assignment, item)
                            and HasCapacity(assignment, ruleIndex)
                        then
                            return self:GetStorageRouting(assignment, entry, assignment.profession, ruleIndex, item)
                        end
                    elseif
                        IsBankTypeCompatible(item, assignment)
                        and IsAssignmentEligible(assignment, item)
                        and HasCapacity(assignment, ruleIndex)
                    then
                        return self:GetStorageRouting(assignment, entry, assignment.profession, ruleIndex, item)
                    end
                end
            end
        end
    end

    -- Rule B.2: Zookeeper fallback - pet items with no storage assignment configured.
    -- Guard: never route a soulbound (non-warbound) pet item - the destination will reject it.
    if not assignments.zookeeper and not (item.isBound and not item.isWarbound) then
        local isPetItem = (item.itemClassID == ITEM_CLASS_MISC and item.itemSubClassID == ITEM_SUBCLASS_COMPANION)
            or ZOOKEEPER_ITEMS[item.itemID]
        if isPetItem then
            local method, name = self:CachedFindRecipient("zookeeper", item.isWarbound)
            if method == "mail" then
                return CAT_ROUTE, "Mail to " .. name .. " (pets)"
            elseif method == "stash" then
                return CAT_STASH, "Stash in Warband for " .. name .. " (pets)", { destType = "warbandbank" }
            end
            -- Zookeeper role unassigned or holder unreachable → surface, don't silently keep.
            return CAT_KEEP, "Zookeeper unreachable"
        end
    end

    -- Rule B.3: PvPer fallback - PvP tokens with no storage assignment configured.
    -- Guard: never route a soulbound (non-warbound) PvP token - it can't be mailed or
    -- deposited to warband bank. If the item is truly soulbound, keep it here.
    if not assignments.pvper and PVPER_ITEMS[item.itemID] and not (item.isBound and not item.isWarbound) then
        local method, name = self:CachedFindRecipient("pvper", item.isWarbound)
        if method == "mail" then
            return CAT_ROUTE, "Mail to " .. name .. " (PvP)"
        elseif method == "stash" then
            return CAT_STASH, "Stash in Warband for " .. name .. " (PvP)", { destType = "warbandbank" }
        end
        -- PvPer role unassigned or holder unreachable → surface, don't silently keep.
        return CAT_KEEP, "PvPer unreachable"
    end

    -- Capacity wall: a storage rule matched this item but every matching
    -- destination is full. That is an explicit user rule hitting a limit, so it
    -- must resolve here rather than being silently claimed by a later
    -- fall-through rule. Without this, B.4 below grabs any unbound equippable
    -- item (profession tools, BoE gear) and mails it to the Auctioneer, making
    -- the capacity outcomes unreachable for exactly the items most likely to
    -- trigger them.
    if blockedStackAsn then
        -- Stackable: may still merge into a partial stack the snapshot can't see.
        -- Route to it so the deposit is attempted, flagged "(may be full)".
        local category, action, routing =
            self:GetStorageRouting(blockedStackAsn, entry, blockedStackAsn.profession, blockedStackRule, item)
        if routing then
            return category, action .. " (may be full)", routing
        end
        -- Non-move outcome (e.g. unreachable banker) - treat as hard-blocked.
        capacityBlocked = true
    end
    if capacityBlocked then
        -- routing stays nil: that is what excludes the row from the deposit
        -- move list and the [Deposit All Stash] count. The rule indices ride
        -- along separately so the tooltip can name the full destinations.
        return CAT_STASH, "All matching destinations are full", nil, true, blockedRules
    end

    -- Rule B.4: Auctioneer / Disenchant - any unbound BoE item
    -- Covers weapons, armor, recipes, containers, etc. - anything sellable on the AH.
    -- Excludes warbound (account-bound) items - they can't be sold on the AH.
    -- When disenchant routing is enabled, low-value equippable BoE goes to the
    -- Enchanting Artisan instead (TSM: DBDisenchant > DBMarket, or threshold fallback).
    -- Guild bank equippable gear: skip bind check - bindType is unreliable for GB items.
    -- "Warbound Until Equipped" gear has isWarbound=true AND itemEquipLoc set; permanently
    -- warbound consumables/gems have isWarbound=true but itemEquipLoc="".
    -- Also covers bindType=0 equippable gear (vintage "no bind" items like Cubic Zirconia Ring,
    -- Shiny Silver Necklace) - they have a sell price and valid equip loc, so they're AH-eligible.
    -- Skipped entirely when this character ignores storage rules: every B.4
    -- outcome is either a STASH/ROUTE the wrapper would discard or a KEEP the
    -- fall-through below also produces, so this is behavior-equivalent while
    -- avoiding the per-item TSM disenchant lookups (ShouldDisenchant).
    local loc = item.itemEquipLoc or ""
    local isRealEquip = loc ~= "" and loc ~= "INVTYPE_NON_EQUIP" and loc ~= "INVTYPE_NON_EQUIP_IGNORE"
    local isGuildBankEquip = item.bankType == "guildbank" and isRealEquip and not (item.isBound and not item.isWarbound) -- exclude truly soulbound gear
    local isUnboundBoE = item.bindType == 2 and not item.isBound and not item.isWarbound
    local isNoBindEquip = item.bindType == 0 and isRealEquip and not item.isBound and not item.isWarbound
    if not entry.ignoreStorageRules and (isGuildBankEquip or isUnboundBoE or isNoBindEquip) then
        local isOwnAuctioneer = assignments.auctioneer
        local isOwnEnchanter = assignments.artisan and assignments.artisan.enchanting

        -- Gate: B.4 only fires if an Auctioneer exists somewhere on the account.
        -- No auctioneer = no rule for BoE gear → fall through to KEEP.
        -- DE is a modifier on auctioneer routing, not an independent rule.
        local auctioneerMethod, auctioneerName = self:CachedFindRecipient("auctioneer", false)
        local auctioneerExists = isOwnAuctioneer or auctioneerMethod ~= nil
        if auctioneerExists then
            -- Determine if item should be disenchanted
            local shouldDE = false
            if ctx and ctx.disenchantRouting then
                shouldDE = self:ShouldDisenchant(item)
            end

            -- Own role: enchanter keeps DE items, auctioneer keeps AH items.
            -- For bag items this resolves to KEEP; for guild-bank items the ClassifyBankItem
            -- wrapper converts KEEP-on-GB into TAKEOUT so the auctioneer pulls them into bags.
            if shouldDE and isOwnEnchanter then
                return CAT_KEEP, "Enchanter (disenchant)"
            end
            if
                isOwnAuctioneer
                and entry.auctioneerKeepBOE ~= false
                and (not item.bankType or item.bankType == "guildbank")
            then
                return CAT_KEEP, "Auctioneer (sell on AH)"
            end

            -- Route to enchanting artisan if DE is more profitable
            if shouldDE then
                local method, name = self:CachedFindRecipient("enchanter", false)
                if method == "mail" then
                    return CAT_ROUTE, "Mail to " .. name .. " (DE)"
                elseif method == "stash" then
                    return CAT_STASH, "Stash in Warband for " .. name .. " (DE)", { destType = "warbandbank" }
                end
                -- No enchanter found - fall through to auctioneer
            end

            -- Default: route to auctioneer
            if auctioneerMethod == "mail" then
                return CAT_ROUTE, "Mail to " .. auctioneerName .. " (AH)"
            elseif auctioneerMethod == "stash" then
                return CAT_STASH, "Stash in Warband for " .. auctioneerName .. " (AH)", { destType = "warbandbank" }
            end
        end
    end

    -- Vendor threshold: white-quality (common) items below per-unit sell price → VENDOR
    -- Only quality 0-1. Gray already caught by D.1. Green+ never auto-vendored.
    -- Excluded: items matching any profession in PROF_ITEM_MAP (crafting materials),
    -- plus trade goods (7), consumables (0), reagents (5), recipes (9).
    local threshold = self.db.global.options.defaultVendorThreshold or 0
    local hasProfMatch = GetProfMatchSet(item)
    if
        threshold > 0
        and item.quality <= 1
        and item.sellPrice > 0
        and not hasProfMatch
        and item.itemClassID ~= ITEM_CLASS_TRADEGOODS
        and item.itemClassID ~= 0
        and item.itemClassID ~= 5
        and item.itemClassID ~= 9
        and item.itemClassID ~= ITEM_CLASS_MISC
    then
        local perUnit = item.sellPricePerUnit or (item.sellPrice / item.stackCount)
        if perUnit <= threshold then
            return CAT_VENDOR, "Vendor below threshold (Common)"
        end
    end

    -- Rule D.3: Unrecognized items → KEEP (avoid false positives).
    -- Capacity-blocked items are resolved earlier (before B.4), so anything
    -- reaching here genuinely matched no rule.
    return CAT_KEEP, "No matching Rule"
end

-------------------------------------------------------------------------------
-- Routing Decision Tree (profession-based)
-------------------------------------------------------------------------------

function EmpireManager:GetStorageRouting(assignment, entry, profKey, ruleIndex, item)
    local guid = self.playerGUID
    local sType = assignment.type or "warbandbank"

    -- Build tab suffix for display (e.g., " Tabs 1, 3" or " Tab 2" or "")
    local tabSuffix = ""
    if assignment.tabs and #assignment.tabs > 0 then
        if #assignment.tabs == 1 then
            tabSuffix = " Tab " .. assignment.tabs[1]
        else
            tabSuffix = " Tabs " .. table.concat(assignment.tabs, ", ")
        end
    end

    -- Resolve profession label for display
    local pInfo = self.PROF_INFO_BY_KEY[profKey]
    local profLabel = pInfo and pInfo.label or profKey

    -- Warband bank: any character can deposit directly
    if sType == "warbandbank" then
        return CAT_STASH,
            "Deposit in Warband Bank" .. tabSuffix .. " (" .. profLabel .. ")",
            { destType = "warbandbank", destTabs = assignment.tabs, profKey = profKey, ruleIndex = ruleIndex }
    end

    if sType == "guildbank" then
        local guildName = assignment.guild or ""
        local guildRealm = assignment.realm or ""
        local myGuild = entry.guild or ""
        -- Compare against the guild's home realm, since that is what asn.realm
        -- stores (same field FindCharInGuild matches on). Fall back to the
        -- character's realm when guildRealm hasn't been captured yet: guild data
        -- can be unavailable at login, and an empty guildRealm would otherwise
        -- fail the compare and wrongly route to mail with the bank open.
        --
        -- NOTE: this is a consistency fix, not a confirmed bug fix. Whether a
        -- character's realm can actually differ from their guild's home realm
        -- (connected realms) was never measured. If a user reports "wants to
        -- mail with the guild bank open" and the guild-name collision in
        -- PropagateGuildRealmToRules is ruled out, check here next: log
        -- entry.realm, entry.guildRealm and asn.realm for the affected rule.
        local myRealm = entry.guildRealm
        if not myRealm or myRealm == "" then
            myRealm = entry.realm or ""
        end
        -- Same guild AND realm? Deposit directly. Two guilds with the same
        -- name on different realms are distinct, so realm has to match. Normalize
        -- both sides: stored realms mix the space form (GetRealmName) and the
        -- no-space form, so a raw compare wrongly fails on spaced realms.
        if
            guildName ~= ""
            and myGuild == guildName
            and (guildRealm == "" or self:NormRealm(myRealm) == self:NormRealm(guildRealm))
        then
            return CAT_STASH,
                "Deposit in <" .. guildName .. ">" .. tabSuffix .. " (" .. profLabel .. ")",
                {
                    destType = "guildbank",
                    destTabs = assignment.tabs,
                    guild = guildName,
                    realm = guildRealm,
                    profKey = profKey,
                    ruleIndex = ruleIndex,
                }
        end
        -- Different guild - find a banker in that guild to mail to, or stash in warband
        local bankerEntry
        if assignment.char then
            bankerEntry = self.db.global.registry[assignment.char]
        end
        -- Auto-resolve: find any character in the target guild (on the same realm)
        if not bankerEntry then
            local resolvedGuid = self:FindCharInGuild(guildName, guid, guildRealm)
            if resolvedGuid then
                bankerEntry = self.db.global.registry[resolvedGuid]
            end
        end
        if bankerEntry and bankerEntry.name then
            if (entry.realm or "") == (bankerEntry.realm or "") then
                return CAT_ROUTE,
                    "Mail to " .. bankerEntry.name .. " <" .. guildName .. "> (" .. profLabel .. ")",
                    { profKey = profKey, ruleIndex = ruleIndex }
            elseif item.isWarbound then
                -- Cross-realm warbound (BoA): mailable cross-realm AND cross-faction
                -- on the same Battle.net account. Mail the banker (Name-Realm form);
                -- they deposit into the guild bank on their end.
                return CAT_ROUTE,
                    "Mail to "
                        .. bankerEntry.name
                        .. "-"
                        .. (bankerEntry.realm or "")
                        .. " <"
                        .. guildName
                        .. "> ("
                        .. profLabel
                        .. ")",
                    { profKey = profKey, ruleIndex = ruleIndex }
            else
                -- Cross-realm, not warbound: regular items can't be mailed cross-realm,
                -- so transit via warband bank. Warband bank rejects truly soulbound
                -- items, so there's no physical path - keep in place.
                if item.isBound and not item.isWarbound then
                    return CAT_KEEP, "Soulbound (cross-realm, no path)"
                end
                return CAT_STASH,
                    "Stash in Warband for <" .. guildName .. "> (" .. profLabel .. ")",
                    { destType = "warbandbank", profKey = profKey, ruleIndex = ruleIndex }
            end
        end
        -- Guild bank rule with no resolvable banker → surface, don't silently route to a dead end.
        return CAT_KEEP, "Banker unreachable (" .. profLabel .. ")"
    end

    if sType == "charbank" then
        -- Am I the assigned banker? ("self" = always own character's bank)
        if assignment.char and (assignment.char == guid or assignment.char == "self") then
            return CAT_STASH,
                "Move to Bank" .. tabSuffix .. " (" .. profLabel .. ")",
                { destType = "charbank", destTabs = assignment.tabs, profKey = profKey, ruleIndex = ruleIndex }
        end
        -- Not the banker - mail or warband-stash
        if assignment.char then
            local bankerEntry = self.db.global.registry[assignment.char]
            if bankerEntry and bankerEntry.name then
                if (entry.realm or "") == (bankerEntry.realm or "") then
                    return CAT_ROUTE,
                        "Mail to " .. bankerEntry.name .. " (" .. profLabel .. ")",
                        { profKey = profKey, ruleIndex = ruleIndex }
                elseif item.isWarbound then
                    -- Cross-realm warbound (BoA): can be mailed cross-realm AND
                    -- cross-faction on the same Battle.net account. Address with the
                    -- Name-Realm form so the mail addresses the right server.
                    return CAT_ROUTE,
                        "Mail to " .. bankerEntry.name .. "-" .. (bankerEntry.realm or "") .. " (" .. profLabel .. ")",
                        { profKey = profKey, ruleIndex = ruleIndex }
                else
                    -- Cross-realm, not warbound: regular items can't be mailed
                    -- cross-realm, so transit via the warband bank. Warband bank
                    -- rejects truly soulbound items, so there's no physical path - keep.
                    if item.isBound and not item.isWarbound then
                        return CAT_KEEP, "Soulbound (cross-realm, no path)"
                    end
                    return CAT_STASH,
                        "Stash in Warband for " .. bankerEntry.name .. " (" .. profLabel .. ")",
                        { destType = "warbandbank", profKey = profKey, ruleIndex = ruleIndex }
                end
            end
        end
        -- Charbank rule with no resolvable banker character → destination unreachable.
        return CAT_KEEP, "Banker unreachable (" .. profLabel .. ")"
    end

    -- Fallback: unrecognized storage type (defensive; should never fire).
    return CAT_KEEP, "Storage rule invalid (" .. profLabel .. ")"
end

-------------------------------------------------------------------------------
-- Equipment Set Lookup (shared by sync and async paths)
-------------------------------------------------------------------------------

-- Unpacks a C_EquipmentSet.GetItemLocations() entry into a unique item GUID.
-- Mirrors Blizzard's EquipmentManager_GetLocationData (Shared/EquipmentManager.lua):
-- the packed value carries PLAYER/BAGS/BANK bitflags, and the flag is SUBTRACTED
-- to leave the slot; for bag locations the bag index sits ITEM_INVENTORY_BAG_BIT_OFFSET
-- bits up, and bank bags are shifted past the equipped bags by ITEM_INVENTORY_BANK_BAG_OFFSET.
-- Returns nil when the location is missing/unresolvable (negative = ignored slot, or
-- the item isn't currently reachable), which sends the caller to the itemID fallback.
--
-- `expectedID` is a sanity check: the location must still hold the item the set names.
-- In practice the two agree, but a location can go stale between the set being saved
-- and the scan (item moved/replaced). Registering the wrong GUID there would protect
-- an unrelated item and leave the real set piece unprotected, so on mismatch we return
-- nil and let the caller fall back to itemID matching.
-- Second return: true when the GUID came from a bag slot (an instance the bag scan
-- can actually match), false when it came from an equipped slot. Callers use it to
-- decide whether the GUID is enough on its own or still needs the itemID fallback.
local function ResolveEquipSetGUID(packed, expectedID)
    if not packed or packed < 0 or not ItemLocation or not C_Item or not C_Item.GetItemGUID then
        return nil
    end
    local isPlayer = bit.band(packed, ITEM_INVENTORY_LOCATION_PLAYER) ~= 0
    local isBank = bit.band(packed, ITEM_INVENTORY_LOCATION_BANK) ~= 0
    local isBags = bit.band(packed, ITEM_INVENTORY_LOCATION_BAGS) ~= 0
    local slot = packed
    if isPlayer then
        slot = slot - ITEM_INVENTORY_LOCATION_PLAYER
    elseif isBank then
        slot = slot - ITEM_INVENTORY_LOCATION_BANK
    end
    -- BAGS wins over PLAYER. Mirrors EquipmentManager_GetLocationData
    -- (Blizzard_FrameXML/Shared/EquipmentManager.lua), where the isBags branch is an
    -- independent `if` after the PLAYER/BANK flag is subtracted - NOT an elseif on
    -- isPlayer. Measured in-game: a worn set slot packs PLAYER only (0x100001), while
    -- an item sitting in bags packs PLAYER|BAGS (e.g. 0x3000CC = bag 3 slot 12).
    -- Treating isPlayer as the winning branch sent every bagged set item to
    -- CreateFromEquipmentSlot(204), which is invalid, so GUID resolution always failed
    -- and every set fell back to itemID - keeping every duplicate of a set piece.
    local loc
    local fromBags = false
    if isBags then
        fromBags = true
        slot = slot - ITEM_INVENTORY_LOCATION_BAGS
        local bag = bit.rshift(slot, ITEM_INVENTORY_BAG_BIT_OFFSET)
        slot = slot - bit.lshift(bag, ITEM_INVENTORY_BAG_BIT_OFFSET)
        if isBank then
            bag = bag + ITEM_INVENTORY_BANK_BAG_OFFSET
        end
        loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
    elseif isPlayer then
        loc = ItemLocation:CreateFromEquipmentSlot(slot)
    end
    if not loc or not loc:IsValid() then
        return nil
    end
    -- Stale-entry guard: the location must still hold the item the set names.
    if expectedID and C_Item.GetItemID then
        local okID, actualID = pcall(C_Item.GetItemID, loc)
        if not okID or actualID ~= expectedID then
            return nil
        end
    end
    local ok, guid = pcall(C_Item.GetItemGUID, loc)
    if ok then
        return guid, fromBags
    end
    return nil
end

-- Builds two lookups from the player's saved equipment sets:
--   _equipSetGUIDs[itemGUID] = setName  - the exact item instances a set uses.
--   _equipSetItems[itemID]   = setName  - itemID fallback, populated for every set
--                                         slot EXCEPT those resolved to a GUID that
--                                         names an item currently in bags.
-- C_EquipmentSet.GetItemIDs returns plain itemIDs, so matching on it alone keeps
-- every duplicate of a set piece sitting in bags (3x Glorious Crusader's Keepsake
-- all read "Equipment set: Tank"). GetItemLocations gives a per-slot packed
-- location, which resolves to a unique GUID and tells the copies apart.
--
-- The GUID only replaces the itemID floor when it names a BAG instance. A set slot
-- that is currently WORN resolves to an equipped-slot GUID, which no bag row can
-- ever match, so those slots keep the itemID floor - otherwise an off-spec set piece
-- in bags is protected by neither table and falls through to Pawn, which scores only
-- the ACTIVE spec and flags it "Soulbound non-upgrade".
local function BuildEquipSetLookup(addon)
    addon._equipSetItems = nil
    addon._equipSetGUIDs = nil
    if addon.db.global.options.skipEquipmentSets and C_EquipmentSet and C_EquipmentSet.GetEquipmentSetIDs then
        local lookup = {}
        local guidLookup = {}
        local setIDs = C_EquipmentSet.GetEquipmentSetIDs()
        for _, setID in ipairs(setIDs) do
            local setName = C_EquipmentSet.GetEquipmentSetInfo(setID)
            local itemIDs = C_EquipmentSet.GetItemIDs(setID)
            local locations = C_EquipmentSet.GetItemLocations(setID)
            for invSlot, id in pairs(itemIDs or {}) do
                if id and id > 0 then
                    local guid, fromBags = ResolveEquipSetGUID(locations and locations[invSlot], id)
                    if guid and not guidLookup[guid] then
                        guidLookup[guid] = setName or "?"
                    end
                    -- Narrow to the single GUID only when it names an instance sitting
                    -- in bags - that is the case the spare-copy fix is for, and the bag
                    -- scan can match it. Anything else (no resolvable location, or a
                    -- GUID belonging to an EQUIPPED item) leaves the bag copies with no
                    -- matching GUID, so they need the itemID floor or they fall through
                    -- to Pawn and get vendored as off-spec gear.
                    if not (guid and fromBags) and not lookup[id] then
                        lookup[id] = setName or "?"
                    end
                end
            end
        end
        addon._equipSetItems = lookup
        addon._equipSetGUIDs = guidLookup
    end
end

-------------------------------------------------------------------------------
-- Run Triage (scan + classify)
-------------------------------------------------------------------------------

-- Sync wrapper: used only by mid-deposit RebuildMoveList and TriageDebugCheck.
-- All other callers use RunTriageAsync or cached self.triageResults.
function EmpireManager:RunTriage()
    local guid = self.playerGUID
    local entry = self.db.global.registry[guid]
    if not entry then
        return {}
    end

    local bagItems = ScanBagsCore(nil) -- synchronous, no yielding
    local results = {}

    BuildEquipSetLookup(self)
    PrepareClassificationContext(self)

    for _, item in ipairs(bagItems) do
        item._restockSurplus = nil -- reset per scan; set by the restock-floor rule
        local category, action, routing, blocked, blockedRules = self:ClassifyItem(item, entry)
        -- routeCount = units this row actually moves. Whole stack normally; when a slot
        -- straddles the restock floor, only the surplus above the floor (the floor stays
        -- in bags). Display + mail/deposit read routeCount and split at action time.
        if (category == CAT_ROUTE or category == CAT_STASH) and item._restockSurplus then
            item.routeCount = item._restockSurplus
        else
            item.routeCount = nil
        end
        results[#results + 1] = {
            item = item,
            category = category,
            action = action,
            routing = routing,
            blocked = blocked,
            blockedRules = blockedRules,
        }
    end
    self._classifyCtx = nil

    -- Sort by category order, then by destination, then by item name
    local catOrder = {}
    for i, cat in ipairs(EmpireManager.CATEGORY_ORDER) do
        catOrder[cat] = i
    end
    table.sort(results, function(a, b)
        local oa = catOrder[a.category] or 99
        local ob = catOrder[b.category] or 99
        if oa ~= ob then
            return oa < ob
        end
        -- Within VENDOR rows, sort by quality DESC so uncommon+ gear floats to
        -- the top of the section (more visible to the user before bulk vendor).
        if a.category == CAT_VENDOR then
            local qa = a.item.quality or 0
            local qb = b.item.quality or 0
            if qa ~= qb then
                return qa > qb
            end
            return a.item.itemName < b.item.itemName
        end
        local da = a.action or ""
        local db = b.action or ""
        if da ~= db then
            return da < db
        end
        return a.item.itemName < b.item.itemName
    end)

    self.triageResults = results
    self.triageLastScan = time()
    self:WarnOnUnreachableDestinations(results)
    return results
end

-------------------------------------------------------------------------------
-- Unreachable-destination chat warnings
-- Surfaces broken role/storage rules (deleted lockpicker, missing banker, etc.)
-- that would otherwise be hidden because CAT_KEEP rows are not rendered in the
-- triage list. Dedup'd per session by (itemID, reason) so repeated scans of
-- the same item don't spam chat.
-------------------------------------------------------------------------------

function EmpireManager:WarnOnUnreachableDestinations(results)
    if not results or #results == 0 then
        return
    end
    self._unreachableWarned = self._unreachableWarned or {}
    local seen = self._unreachableWarned

    -- Group newly-seen items by their reason so we print one chat line per
    -- reason instead of one per item. Session-dedup is still keyed per
    -- (itemID, reason) so re-scans don't repeat already-warned items.
    -- Surfaces both role/banker "unreachable" reasons and the
    -- "All matching destinations are full" capacity case - batched so a
    -- stack of affected items collapses to a single chat line.
    local byReason = {}
    local reasonOrder = {}
    for _, r in ipairs(results) do
        local action = r.action or ""
        if action:find("unreachable", 1, true) or action:find("destinations are full", 1, true) then
            local key = (r.item.itemID or 0) .. ":" .. action
            if not seen[key] then
                seen[key] = true
                local label = r.item.itemLink or r.item.itemName or "?"
                if not byReason[action] then
                    byReason[action] = {}
                    reasonOrder[#reasonOrder + 1] = action
                end
                table.insert(byReason[action], label)
            end
        end
    end

    -- Print one line per reason, listing items inline. The trailing |r after
    -- each item link prevents the quality color from bleeding onto the next
    -- entry or the reason text.
    for _, action in ipairs(reasonOrder) do
        local items = byReason[action]
        local n = #items
        local labelStr
        if n == 1 then
            labelStr = items[1] .. "|r"
        else
            labelStr = string.format("%d items (%s|r", n, table.concat(items, "|r, "))
            labelStr = labelStr .. ")"
        end
        self:Print(string.format("|cffff8800[Triage]|r %s - %s", labelStr, action))
    end
end

-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
-- Triage Summary Counts
-------------------------------------------------------------------------------

function EmpireManager:GetTriageSummary(results)
    local counts = { [CAT_KEEP] = 0, [CAT_ROUTE] = 0, [CAT_STASH] = 0, [CAT_VENDOR] = 0 }
    local vendorValue = 0
    for _, r in ipairs(results) do
        counts[r.category] = (counts[r.category] or 0) + 1
        if r.category == CAT_VENDOR then
            vendorValue = vendorValue + (r.item.sellPrice or 0)
        end
    end
    return counts, vendorValue
end

-------------------------------------------------------------------------------
-- Bank Triage: Classify bank item (wraps ClassifyItem with bank-aware logic)
-------------------------------------------------------------------------------

-- Check if a bank item is already in one of the routing's destination tabs.
local function IsItemInDestination(item, routing)
    if not routing or not routing.destType then
        return false
    end
    if item.bankType ~= routing.destType then
        return false
    end
    -- No specific tabs = "any tab in this bank type" → already home
    if not routing.destTabs or #routing.destTabs == 0 then
        return true
    end
    for _, tab in ipairs(routing.destTabs) do
        if item.srcTab == tab then
            return true
        end
    end
    return false
end

-- Check if a bank item's routing points to a different tab of the same bank type.
-- Returns an array of all eligible destination tabs (excluding the item's current tab), or nil.
local function FindIntraBankDests(item, routing)
    if not routing or not routing.destType or not routing.destTabs then
        return nil
    end
    if item.bankType ~= routing.destType then
        return nil
    end
    -- Same bank type, different tabs -> reorganize candidates
    local tabs = {}
    for _, tab in ipairs(routing.destTabs) do
        if item.srcTab ~= tab then
            tabs[#tabs + 1] = tab
        end
    end
    if #tabs == 0 then
        return nil
    end
    return tabs
end

function EmpireManager:ClassifyBankItem(item, entry)
    -- A selected TSM Group is an explicit user instruction, so it wins over every
    -- rule below.
    if self:GroupMoverClaims(item, item.bankType) then
        return CAT_TAKEOUT, "TSM Group: to " .. (self:GroupMoverEndpointLabel(self._groupMoverTo) or "?")
    end

    -- Restock floor protection (decision A): keep up to the floor in the bank it
    -- pins the item to; surplus above the floor falls through to Storage Rules
    -- (reorganize / take out / route as normal). Restock and Storage work together -
    -- Restock guards the minimum, Storage governs everything above it.
    if item.itemID and item.bankType then
        if RestockProtectWithinFloor(self, item, item.bankType) then
            return CAT_KEEP, "Restock floor", nil
        end
    end

    -- Keep own profession mats in character bank
    if item.bankType == "charbank" and entry.keepOwnProfMatsInBank then
        local matchSet = GetProfMatchSet(item)
        if matchSet then
            local asn = entry.assignments or {}
            for _, roleKey in ipairs({ "artisan", "gatherer" }) do
                local roleData = asn[roleKey]
                if roleData and type(roleData) == "table" then
                    for profKey in pairs(roleData) do
                        if matchSet[profKey] then
                            return CAT_KEEP, "Own profession mat (charbank)"
                        end
                    end
                end
            end
        end
    end

    local category, action, routing = self:ClassifyItem(item, entry)

    -- Skip all Storage Rules: this character's bank items stay put. The wrapper
    -- already collapsed STASH/ROUTE to KEEP, but VENDOR (e.g. class-unusable junk
    -- sitting in a bank) and the guild-bank "Auctioneer (sell on AH)" KEEP would
    -- otherwise become TAKEOUT below. Suppress those too - vendor junk is only
    -- flagged once it's already in bags, never pulled out of a bank on its behalf.
    if entry.ignoreStorageRules then
        return CAT_KEEP, "Ignoring storage rules", routing
    end

    if category == CAT_STASH then
        -- Item wants to be stashed somewhere - check if it's already there
        if IsItemInDestination(item, routing) then
            return CAT_KEEP, "Correct storage", routing
        end
        -- Same bank type but wrong tab → intra-bank move (reorganize)
        local destTabs = FindIntraBankDests(item, routing)
        if destTabs then
            local pInfo = routing and routing.profKey and self.PROF_INFO_BY_KEY[routing.profKey]
            local profLabel = pInfo and pInfo.label or ""
            local suffix = profLabel ~= "" and (" (" .. profLabel .. ")") or ""
            local bankLabel = routing.destType == "warbandbank" and "Warband Bank"
                or routing.destType == "guildbank" and ("<" .. (routing.guild or "Guild") .. ">")
                or "Bank"
            -- Display text shows all eligible destination tabs
            local tabStrs = {}
            for _, t in ipairs(destTabs) do
                tabStrs[#tabStrs + 1] = tostring(t)
            end
            local tabText = #destTabs == 1 and ("Tab " .. tabStrs[1]) or ("Tabs " .. table.concat(tabStrs, ", "))
            return CAT_STASH, string.format("Move to %s %s%s", bankLabel, tabText, suffix), routing, destTabs
        end
        -- Different bank type or no tab match → take out. Category implies the
        -- takeout; the action text keeps the destination-focused wording.
        return CAT_TAKEOUT, action, routing
    end

    if category == CAT_KEEP then
        -- Guild bank items classified as "keep for auctioneer" belong in bags, not the GB.
        -- Pull them out so the auctioneer can list them on the AH.
        if item.bankType == "guildbank" and action == "Auctioneer (sell on AH)" then
            return CAT_TAKEOUT, action, routing
        end
        return CAT_KEEP, action, routing
    end

    -- ROUTE, VENDOR, or anything else → take out with original reason
    -- e.g. "Mail to Metanoia (Alchemy)", "Vendor junk", "Soulbound non-upgrade (Pawn)"
    return CAT_TAKEOUT, action, routing
end

-------------------------------------------------------------------------------
-- Async Triage (scan across frames, classify when done, invoke callback)
-- Primary scan path: used by UI refresh and chat notification callers.
-------------------------------------------------------------------------------

function EmpireManager:RunTriageAsync(callback)
    local guid = self.playerGUID
    local entry = self.db.global.registry[guid]
    if not entry then
        callback({})
        return
    end

    -- Cache hit: bags haven't changed since last scan, serve cached results.
    if not self._bagsDirty and self.triageResults then
        callback(self.triageResults)
        return
    end

    local addon = self
    StartAsyncScan(function(yieldCheck)
        -- Phase 1: scan bag slots (yields between slots)
        local bagItems = ScanBagsCore(yieldCheck)

        -- Phase 2: classify each item (yields between items)
        BuildEquipSetLookup(addon)
        PrepareClassificationContext(addon)
        local results = {}
        for _, item in ipairs(bagItems) do
            item._restockSurplus = nil -- reset per scan; set by the restock-floor rule
            local category, action, routing, blocked, blockedRules = addon:ClassifyItem(item, entry)
            -- routeCount = surplus above a straddled restock floor (floor stays in bags),
            -- else nil = whole stack. Display + mail/deposit split at action time.
            if (category == CAT_ROUTE or category == CAT_STASH) and item._restockSurplus then
                item.routeCount = item._restockSurplus
            else
                item.routeCount = nil
            end
            results[#results + 1] = {
                item = item,
                category = category,
                action = action,
                routing = routing,
                blocked = blocked,
                blockedRules = blockedRules,
            }
            yieldCheck()
        end
        addon._classifyCtx = nil

        -- Sort by category order, then by destination, then by item name
        local catOrder = {}
        for i, cat in ipairs(EmpireManager.CATEGORY_ORDER) do
            catOrder[cat] = i
        end
        table.sort(results, function(a, b)
            local oa = catOrder[a.category] or 99
            local ob = catOrder[b.category] or 99
            if oa ~= ob then
                return oa < ob
            end
            -- Within VENDOR rows, sort by quality ASC (junk first, quality last).
            -- This is intentional for vendor buyback: WoW's merchant buyback queue
            -- holds only the last 12 items sold and is FIFO - when the queue fills,
            -- the oldest items drop off and become unrecoverable. Selling junk first
            -- means uncommon+ items are the *last* things sold, so they sit at the
            -- top of the buyback list and are still recoverable if the user
            -- realizes a mistake right after the bulk vendor.
            if a.category == CAT_VENDOR then
                local qa = a.item.quality or 0
                local qb = b.item.quality or 0
                if qa ~= qb then
                    return qa < qb
                end
                return a.item.itemName < b.item.itemName
            end
            local da = a.action or ""
            local db = b.action or ""
            if da ~= db then
                return da < db
            end
            return a.item.itemName < b.item.itemName
        end)

        addon.triageResults = results
        addon.triageLastScan = time()
        addon._bagsDirty = false
        addon:WarnOnUnreachableDestinations(results)

        -- Track uncached count for deferred rescan
        local uncachedCount = 0
        for _, item in ipairs(bagItems) do
            if item._uncached then
                uncachedCount = uncachedCount + 1
            end
        end

        return { results = results, uncachedCount = uncachedCount }
    end, function(packed, err)
        if not packed then
            if err then
                addon:Print("|cffff4444[Triage]|r Scan error: " .. tostring(err))
            end
            callback({})
            return
        end

        if packed.uncachedCount > 0 and addon.triageFrame and addon.triageFrame:IsShown() then
            C_Timer.After(1.5, function()
                if addon.triageFrame and addon.triageFrame:IsShown() then
                    addon:RefreshTriageDisplay(false, true)
                end
            end)
        end

        callback(packed.results)
    end)
end

function EmpireManager:RunBankTriageAsync(callback)
    local guid = self.playerGUID
    local entry = self.db.global.registry[guid]
    if not entry then
        callback({})
        return
    end

    local addon = self
    StartAsyncScan(function(yieldCheck)
        -- Phase 1: scan bank slots (yields between slots)
        local bankItems = ScanBankCore(addon, yieldCheck)

        -- Phase 1b: a cold bank tab holds items the client has not cached, whose names
        -- come back empty. Touching the itemID asks the server for the data; yield until
        -- it lands so the list paints once, complete. Painting early and refreshing on
        -- GET_ITEM_INFO_RECEIVED redraws the list under the user's cursor, which is worse
        -- than a short wait on the "Scanning bank..." state. Capped so a permanently
        -- unresolvable item cannot hang the scan - those rows just paint nameless.
        local WAIT_TICKS = 40 -- ~2s at one yield per frame
        for _ = 1, WAIT_TICKS do
            local pending = false
            for _, item in ipairs(bankItems) do
                if item.itemName == "" and item.itemID then
                    -- Name and quality both come back empty/0 for an uncached item, and
                    -- quality drives the row's text colour - backfill both together or
                    -- resolved rows paint their name in grey (quality 0 = Poor).
                    local name, _, quality = C_Item.GetItemInfo(item.itemID)
                    if name and name ~= "" then
                        item.itemName = name
                        if quality then
                            item.quality = quality
                        end
                    else
                        pending = true
                    end
                end
            end
            if not pending then
                break
            end
            coroutine.yield()
        end

        -- Phase 2: classify each item (yields between items)
        BuildEquipSetLookup(addon)
        PrepareClassificationContext(addon)
        local results = {}
        for _, item in ipairs(bankItems) do
            item._restockSurplus = nil -- reset per scan; set by the restock-floor rule
            local category, action, routing, destTabs = addon:ClassifyBankItem(item, entry)
            -- routeCount = surplus above a straddled restock floor (floor stays in the
            -- bank it is pinned to), else nil = whole stack. Same contract as the bag
            -- scan: display + mail/deposit split at action time.
            if (category == CAT_STASH or category == CAT_TAKEOUT) and item._restockSurplus then
                item.routeCount = item._restockSurplus
            else
                item.routeCount = nil
            end
            results[#results + 1] = {
                item = item,
                category = category,
                action = action,
                routing = routing,
                destTabs = destTabs,
            }
            yieldCheck()
        end
        addon._classifyCtx = nil

        local bankCatOrder = { [CAT_STASH] = 1, [CAT_TAKEOUT] = 2, [CAT_KEEP] = 3 }
        table.sort(results, function(a, b)
            local oa = bankCatOrder[a.category] or 99
            local ob = bankCatOrder[b.category] or 99
            if oa ~= ob then
                return oa < ob
            end
            local da = a.action or ""
            local db = b.action or ""
            if da ~= db then
                return da < db
            end
            return (a.item.itemName or "") < (b.item.itemName or "")
        end)

        addon.bankTriageResults = results
        return results
    end, function(results, err)
        if not results then
            if err then
                addon:Print("|cffff4444[Triage]|r Bank scan error: " .. tostring(err))
            end
            callback({})
            return
        end
        callback(results)
    end)
end
