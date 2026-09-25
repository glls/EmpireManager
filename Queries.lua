-- ----------------------------------------------------------------------------
--                                   EmpireManager
--                              https://wow.cyberpunk.gr
--                (c) by George Litos (l0neshad0w),  All Rights Reserved
--                   For detailed license information check LICENSE.md
-- ----------------------------------------------------------------------------

local EmpireManager = LibStub("AceAddon-3.0"):GetAddon("EmpireManager")

-------------------------------------------------------------------------------
-- Data Accessors (convenience wrappers)
-------------------------------------------------------------------------------

function EmpireManager:GetRegistry()
    return self.db.global.registry
end

function EmpireManager:GetEntry(guid)
    return self.db.global.registry[guid]
end

function EmpireManager:GetCurrentEntry()
    return self.db.global.registry[self.playerGUID]
end

function EmpireManager:GetStorageAssignments()
    return self.db.global.storageAssignments
end

function EmpireManager:GetStorageCapacity()
    return self.db.global.storageCapacity
end

function EmpireManager:GetOptions()
    return self.db.global.options
end

function EmpireManager:GetKeepList()
    return self.db.global.keepList
end

function EmpireManager:GetVendorWhitelist()
    return self.db.global.vendorWhitelist
end

-------------------------------------------------------------------------------
-- Rule-Ownership Predicates (Dashboard smart filters)
-------------------------------------------------------------------------------

-- True if any storage rule names this character as its banker. Warband rules
-- carry no `char` (any alt can deposit), so they belong to nobody and never
-- match - the question is "is this character a destination", not "does a rule
-- exist that this character could use".
function EmpireManager:HasStorageRules(guid)
    if not guid then
        return false
    end
    for _, asn in ipairs(self.db.global.storageAssignments or {}) do
        if asn.char == guid then
            return true
        end
    end
    return false
end

-- True if any restock rule targets this character. Only charbank/bags entries
-- carry target characters; warband/guild floors are shared and match nobody,
-- for the same reason as HasStorageRules above. Handles both the `chars` array
-- and the legacy single `char` GUID (see RESTOCK.md build delta 3).
function EmpireManager:HasRestockRules(guid)
    if not guid then
        return false
    end
    for _, entry in ipairs(self.db.global.restockList or {}) do
        if entry.chars then
            for _, g in ipairs(entry.chars) do
                if g == guid then
                    return true
                end
            end
        elseif entry.char == guid then
            return true
        end
    end
    return false
end

-------------------------------------------------------------------------------
-- Registry Filtering (Dashboard:ApplyFilters)
-------------------------------------------------------------------------------

-- Pure filter: returns a table of { [guid] = entry } matching filterState.
-- No UI calls - caller decides what to do with the result.
function EmpireManager:FilterRegistry(filterState)
    local filtered = {}
    local state = filterState

    local blacklist = self.db.global.charBlacklist or {}

    for guid, entry in pairs(self.db.global.registry) do
        local pass = true

        -- Skip blacklisted characters
        if blacklist[guid] then
            pass = false
        end

        -- Search filter: space-separated tokens, AND logic across name/realm/guild/note/level/class/race/faction/professions
        if pass and state.searchText ~= "" then
            local haystack = {}
            if entry.name then
                haystack[#haystack + 1] = entry.name:lower()
            end
            if entry.realm then
                haystack[#haystack + 1] = entry.realm:lower()
            end
            if entry.guild then
                haystack[#haystack + 1] = entry.guild:lower()
            end
            if entry.storageNote then
                haystack[#haystack + 1] = entry.storageNote:lower()
            end
            if entry.level then
                haystack[#haystack + 1] = tostring(entry.level)
            end
            if entry.class then
                haystack[#haystack + 1] = entry.class:lower()
            end
            local className = (self.CLASS_NAMES and self.CLASS_NAMES[entry.class]) or ""
            if className ~= "" then
                haystack[#haystack + 1] = className:lower()
            end
            if entry.faction then
                haystack[#haystack + 1] = entry.faction:lower()
            end
            if entry.race then
                haystack[#haystack + 1] = entry.race:lower()
                local raceName = (self.RACE_NAMES and self.RACE_NAMES[entry.race]) or ""
                if raceName ~= "" then
                    haystack[#haystack + 1] = raceName:lower()
                end
            end
            if entry.professions then
                for _, p in ipairs(entry.professions) do
                    if p.name then
                        haystack[#haystack + 1] = p.name:lower()
                    end
                end
            end
            local hay = table.concat(haystack, " ")
            for token in state.searchText:lower():gmatch("%S+") do
                if not hay:find(token, 1, true) then
                    pass = false
                    break
                end
            end
        end

        -- Smart filters (multiple toggles, AND logic: must match ALL active filters)
        -- Most keys are role keys; the rule-ownership keys below are properties
        -- of the character rather than roles, so they dispatch separately.
        if pass and next(state.activeSmartFilters) then
            for key in pairs(state.activeSmartFilters) do
                local matches
                if key == "hasStorageRules" then
                    matches = self:HasStorageRules(guid)
                elseif key == "hasRestockRules" then
                    matches = self:HasRestockRules(guid)
                else
                    matches = self:HasRole(entry, key)
                end
                if not matches then
                    pass = false
                    break
                end
            end
        end

        if pass then
            filtered[guid] = entry
        end
    end

    return filtered
end

-------------------------------------------------------------------------------
-- Sort Key Functions (Dashboard)
-------------------------------------------------------------------------------

EmpireManager.SORT_KEYS = {
    sortOrder = function(e)
        local s = e.sortOrder or 0
        return s > 0 and s or 9999
    end,
    name = function(e)
        return (e.name or ""):lower()
    end,
    gold = function(e)
        return e.gold or 0
    end,
    roles = function(e)
        local n = 0
        if e.assignments then
            for _ in pairs(e.assignments) do
                n = n + 1
            end
        end
        return n
    end,
    prof_tags = function(e)
        local n = 0
        if e.assignments then
            for _, roleKey in ipairs({ "artisan", "gatherer" }) do
                local roleData = e.assignments[roleKey]
                if type(roleData) == "table" then
                    for _ in pairs(roleData) do
                        n = n + 1
                    end
                end
            end
        end
        return n
    end,

    level = function(e)
        return e.level or 0
    end,
    ilvl = function(e)
        return e.ilvl or 0
    end,
    storage = function(e)
        local total = e.totalBagSlots or 0
        if total <= 0 then
            return -1
        end
        return (e.freeBagSlots or 0) / total
    end,
}

-------------------------------------------------------------------------------
-- Sidecar Business Logic (Sidecar)
-------------------------------------------------------------------------------

-- Resolve sort order conflicts: clear any other character using the same number.
-- Returns true if a conflict was found and resolved.
function EmpireManager:ResolveSortConflict(guid, newSortOrder)
    if not newSortOrder or newSortOrder == 0 then
        return false
    end
    local resolved = false
    for otherGuid, otherEntry in pairs(self.db.global.registry) do
        if otherGuid ~= guid and otherEntry.sortOrder == newSortOrder then
            otherEntry.sortOrder = 0
            resolved = true
        end
    end
    return resolved
end

-- Check if a profession can be added (max 2 per role).
-- Returns true if the role has fewer than 2 professions assigned.
function EmpireManager:CanAddProfession(entry, roleKey, profKey)
    local roleData = entry.assignments and entry.assignments[roleKey]
    -- Already assigned? Toggle is always allowed
    if roleData and type(roleData) == "table" and roleData[profKey] then
        return true
    end
    -- Count total professions across artisan + gatherer (max 2 in-game)
    local total = 0
    for _, rk in ipairs({ "artisan", "gatherer" }) do
        local rd = entry.assignments and entry.assignments[rk]
        if rd and type(rd) == "table" then
            for _ in pairs(rd) do
                total = total + 1
            end
        end
    end
    return total < 2
end

-- Auto-assign Artisan/Gatherer roles from detected professions, plus Banker
-- if the character is a charbank or guild bank storage destination. Mutates entry.assignments.
function EmpireManager:AutoAssignRoles(entry, guid)
    if not entry.assignments then
        entry.assignments = {}
    end
    -- Reset existing profession selections
    entry.assignments.artisan = nil
    entry.assignments.gatherer = nil
    for _, prof in ipairs(entry.professions or {}) do
        local info = self:ProfInfoFromEntryProf(prof)
        if info then
            if info.category == "gathering" then
                if not entry.assignments.gatherer then
                    entry.assignments.gatherer = {}
                end
                entry.assignments.gatherer[info.key] = true
            elseif info.category == "crafting" then
                if not entry.assignments.artisan then
                    entry.assignments.artisan = {}
                end
                entry.assignments.artisan[info.key] = true
            end
        end
    end
    -- Auto-detect Lockpicker: rogues and Mechagnomes can pick lockboxes.
    -- Add-only: never clears a manual tag (e.g. a blacksmith with skeleton keys).
    if entry.class == "ROGUE" or entry.race == "Mechagnome" then
        entry.assignments.lockpicker = true
    end

    -- Auto-detect banker: check if any charbank or guildbank storage assignment targets this character.
    -- For guildbank rules, realm must also match - guild names aren't unique across realms.
    for _, asn in ipairs(self.db.global.storageAssignments or {}) do
        local guildbankMatch = asn.type == "guildbank"
            and (entry.guild or "") ~= ""
            and (entry.guild or "") == (asn.guild or "")
            and ((asn.realm or "") == "" or (entry.guildRealm or "") == asn.realm)
        if (asn.type == "charbank" and asn.char == guid) or guildbankMatch then
            if not entry.assignments.banker then
                entry.assignments.banker = {}
            end
            break
        end
    end
end

-------------------------------------------------------------------------------
-- Banker Role Sync - auto-assign/remove Banker based on storage assignments
-------------------------------------------------------------------------------

-- Sync Banker role for a character GUID based on whether any charbank or
-- guildbank storage assignment targets them. Call after add/edit/delete of
-- storage assignments.
function EmpireManager:SyncBankerRole(guid)
    if not guid then
        return
    end
    local charEntry = self.db.global.registry[guid]
    if not charEntry then
        return
    end
    local needed = false
    for _, asn in ipairs(self.db.global.storageAssignments or {}) do
        local guildbankMatch = asn.type == "guildbank"
            and (charEntry.guild or "") ~= ""
            and (charEntry.guild or "") == (asn.guild or "")
            and ((asn.realm or "") == "" or (charEntry.guildRealm or "") == asn.realm)
        if (asn.type == "charbank" and asn.char == guid) or guildbankMatch then
            needed = true
            break
        end
    end
    if not charEntry.assignments then
        charEntry.assignments = {}
    end
    if needed then
        if not charEntry.assignments.banker then
            charEntry.assignments.banker = {}
        end
    else
        charEntry.assignments.banker = nil
    end
end

-------------------------------------------------------------------------------
-- Guild Auto-Resolve (Dashboard/Triage)
-------------------------------------------------------------------------------

-- Find the first character in a guild (excluding a given GUID or its name+realm).
-- If guildRealm is given, requires the entry's guildRealm (the guild's home realm,
-- NOT the character's realm) to match - needed for cross-realm guilds where the
-- character can be on a different connected realm than the guild's home.
-- Returns guid, entry or nil, nil.
function EmpireManager:FindCharInGuild(guildName, excludeGUID, guildRealm)
    -- Resolve name+realm of the excluded character so stubs with a different GUID
    -- (e.g. "API-Name-Realm") are also excluded.
    local exEntry = excludeGUID and self.db.global.registry[excludeGUID]
    local exName = exEntry and exEntry.name
    local exRealm = exEntry and exEntry.realm

    local fallbackGuid, fallbackEntry
    for guid, entry in pairs(self.db.global.registry) do
        local isExcluded = guid == excludeGUID or (exName and entry.name == exName and entry.realm == exRealm)
        local guildMatches = (entry.guild or "") == guildName
        local realmMatches = not guildRealm
            or guildRealm == ""
            or self:NormRealm(entry.guildRealm) == self:NormRealm(guildRealm)
        if not isExcluded and guildMatches and realmMatches then
            -- Prefer characters with the Banker role
            if entry.assignments and entry.assignments.banker then
                return guid, entry
            end
            if not fallbackGuid then
                fallbackGuid, fallbackEntry = guid, entry
            end
        end
    end
    return fallbackGuid, fallbackEntry
end
