-- GroupMover.lua - route a selected TSM Group through the triage list.
--
-- No move engine here: claiming items in classification lets the existing triage
-- bulk actions (Take Out / Deposit) do the moving, including the guild-bank
-- specifics they already handle.

local EmpireManager = LibStub("AceAddon-3.0"):GetAddon("EmpireManager")

-- Does the selected Group claim this item, given which side it sits on? Only the
-- FROM side is claimed: the group says what to move out of there, not what belongs
-- at the destination.
function EmpireManager:GroupMoverClaims(item, side)
    local from = self._groupMoverFrom
    if not from or not self._groupMoverSet then
        return false
    end
    if side ~= from then
        return false
    end
    if not self:GroupMoverPairValid(from, self._groupMoverTo) then
        return false
    end
    if not item.itemID then
        return false
    end
    if not self._groupMoverSet[item.itemID] then
        -- Caged pet: TSM lists it by species, so resolve this item's species.
        local species = self._groupMoverPetSet
            and C_PetJournal
            and C_PetJournal.GetPetInfoByItemID
            and select(13, C_PetJournal.GetPetInfoByItemID(item.itemID))
        if not species or not self._groupMoverPetSet[species] then
            return false
        end
    end
    local opts = self.db.global.options
    if opts.groupMoverRespectKeepList and self.db.global.keepList[item.itemID] then
        return false
    end
    -- Tradeable only: a soulbound item cannot leave this character at all.
    if opts.groupMoverBoeOnly and not item.bankType and item.isBound and not item.isWarbound then
        return false
    end
    -- Bind rules still apply; reuse triage's check rather than re-deriving them.
    return self.IsBankTypeCompatible(item, { type = self._groupMoverTo })
end

-- Bags are always reachable; a bank needs its frame open.
function EmpireManager:GroupMoverEndpointOpen(endpoint)
    if endpoint == "bags" then
        return true
    elseif endpoint == "guildbank" then
        return self:IsGuildBankOpen()
    elseif endpoint == "charbank" then
        return self.bankIsOpen and not self:IsWarbandBankOnly()
    elseif endpoint == "warbandbank" then
        return self.bankIsOpen and true or false
    end
    return false
end

-- Build the itemID lookup once when a Group is picked, so classification stays O(1).
function EmpireManager:GroupMoverSetItems(items)
    local set, petSet = {}, {}
    for _, itemString in ipairs(items or {}) do
        -- Only "i:<itemID>" is an item. TSM also emits "p:<speciesID>:..." for
        -- battle pets, whose species number is NOT an itemID - matching on it
        -- claimed whatever unrelated item happened to share that number.
        local str = tostring(itemString)
        local id = tonumber(string.match(str, "^i:(%d+)"))
        if id then
            set[id] = true
        else
            -- "p:<speciesID>:..." is a battle pet. The species number is NOT an
            -- itemID; a caged pet in bags is matched by species instead.
            local species = tonumber(string.match(str, "^p:(%d+)"))
            if species then
                petSet[species] = true
            end
        end
    end
    self._groupMoverSet = set
    -- nil when the Group has no pets: an empty table is truthy, and the classifier
    -- would then run a pet journal lookup for every item that misses `set`.
    self._groupMoverPetSet = next(petSet) and petSet or nil
    local n = 0
    for _ in pairs(set) do
        n = n + 1
    end
    for _ in pairs(petSet) do
        n = n + 1
    end
    return n
end

function EmpireManager:ClearGroupMover()
    self._groupMoverSet = nil
    self._groupMoverPetSet = nil
    self._groupMoverPath = nil
    self._groupMoverLabel = nil
    self._groupMoverItems = nil
end
