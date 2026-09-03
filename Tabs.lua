-- ----------------------------------------------------------------------------
--                                   EmpireManager
--                              https://wow.cyberpunk.gr
--                (c) by George Litos (l0neshad0w),  All Rights Reserved
--                   For detailed license information check LICENSE.md
-- ----------------------------------------------------------------------------

local EmpireManager = LibStub("AceAddon-3.0"):GetAddon("EmpireManager")
-------------------------------------------------------------------------------
-- Storage Import / Export
-------------------------------------------------------------------------------

function EmpireManager:ExportStorageAssignments()
    local assignments = self.db.global.storageAssignments or {}
    if #assignments == 0 then
        return "# EmpireManager Storage Rules v1\n# category;type;tabs;char;guild;expansions;subcategories;realm\n# (no rules configured)\n"
    end

    -- Build GUID -> "Name-Realm" lookup
    local guidToName = {}
    for guid, entry in pairs(self.db.global.registry) do
        guidToName[guid] = (entry.name or "Unknown") .. "-" .. (entry.realm or "Unknown")
    end

    local lines = {
        "# EmpireManager Storage Rules v1",
        "# category;type;tabs;char;guild;expansions;subcategories;realm",
    }
    for _, asn in ipairs(assignments) do
        if type(asn) == "table" then
            local tabStr = ""
            if type(asn.tabs) == "table" and #asn.tabs > 0 then
                local parts = {}
                for _, t in ipairs(asn.tabs) do
                    parts[#parts + 1] = tostring(t)
                end
                tabStr = table.concat(parts, ",")
            end

            local charStr = ""
            if asn.type ~= "guildbank" and asn.char and asn.char ~= "" then
                charStr = guidToName[asn.char] or tostring(asn.char)
            end

            local guildStr = ""
            local realmStr = ""
            if type(asn.guild) == "string" and asn.guild ~= "" then
                guildStr = asn.guild
                if type(asn.realm) == "string" and asn.realm ~= "" then
                    realmStr = asn.realm
                end
            end

            local expStr = ""
            if type(asn.expansions) == "table" and #asn.expansions > 0 then
                local parts = {}
                for _, eid in ipairs(asn.expansions) do
                    parts[#parts + 1] = tostring(eid)
                end
                expStr = table.concat(parts, ",")
            end

            local subcatStr = ""
            if type(asn.subcategories) == "table" and #asn.subcategories > 0 then
                local parts = {}
                for _, sc in ipairs(asn.subcategories) do
                    parts[#parts + 1] = tostring(sc)
                end
                subcatStr = table.concat(parts, ",")
            end

            lines[#lines + 1] = string.format(
                "%s;%s;%s;%s;%s;%s;%s;%s",
                tostring(asn.profession or ""),
                tostring(asn.type or ""),
                tabStr,
                charStr,
                guildStr,
                expStr,
                subcatStr,
                realmStr
            )
        end
    end
    return table.concat(lines, "\n") .. "\n"
end

function EmpireManager:ImportStorageAssignments(text)
    if not text or text:match("^%s*$") then
        return nil, nil, "No text to import"
    end

    -- Build "Name-Realm" -> GUID reverse lookup
    local nameToGUID = {}
    for guid, entry in pairs(self.db.global.registry) do
        local nameRealm = (entry.name or "Unknown") .. "-" .. (entry.realm or "Unknown")
        nameToGUID[nameRealm] = guid
        -- Also store lowercase for case-insensitive matching
        nameToGUID[nameRealm:lower()] = guid
    end

    local readyRules = {}
    local unresolvedRules = {}
    local skippedCount = 0

    for line in text:gmatch("[^\r\n]+") do
        -- Skip comments and blanks
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local parts = {}
            for f in (line .. ";"):gmatch("([^;]*);") do
                parts[#parts + 1] = f:match("^%s*(.-)%s*$") -- trim whitespace
            end

            local category = parts[1] or ""
            local bankType = parts[2] or ""
            local tabStr = parts[3] or ""
            local charStr = parts[4] or ""
            local guildStr = parts[5] or ""
            local expStr = parts[6] or ""
            local subcatStr = parts[7] or ""
            -- Column 8 (realm) was added later. Old exports omit it and fall
            -- back to the registry lookup below for cross-realm guilds.
            local realmStr = parts[8] or ""

            -- Cap free-text fields so a malformed export can't break the UI / chat
            if #category > 32 then category = category:sub(1, 32) end
            if #bankType > 32 then bankType = bankType:sub(1, 32) end
            if #charStr > 96 then charStr = charStr:sub(1, 96) end
            if #guildStr > 64 then guildStr = guildStr:sub(1, 64) end
            if #tabStr > 64 then tabStr = tabStr:sub(1, 64) end
            if #expStr > 128 then expStr = expStr:sub(1, 128) end
            if #subcatStr > 256 then subcatStr = subcatStr:sub(1, 256) end

            -- Validate category (professions + storage categories)
            if not self.PROF_INFO_BY_KEY[category] then
                skippedCount = skippedCount + 1
                self:ChatMsg("Import warning: skipped unknown category '" .. category .. "'.", true)
            -- Validate bank type
            elseif bankType ~= "warbandbank" and bankType ~= "guildbank" and bankType ~= "charbank" then
                skippedCount = skippedCount + 1
                self:ChatMsg(string.format(
                    "Import warning: skipped rule '%s' - unknown bank type '%s'.",
                    category, bankType
                ), true)
            else
                -- Parse tabs (valid: 1-7 for guild, 1-6 for charbank, 1-5 for warband)
                local tabs = nil
                if tabStr ~= "" then
                    tabs = {}
                    local invalid = {}
                    local maxTab = (bankType == "charbank") and 6 or (bankType == "warbandbank") and 5 or 7
                    for t in tabStr:gmatch("[^,]+") do
                        local n = tonumber(t)
                        if n and n >= 1 and n <= maxTab then
                            tabs[#tabs + 1] = n
                        else
                            invalid[#invalid + 1] = t
                        end
                    end

                    -- Drop tabs that don't exist on the destination (only when we
                    -- have a capacity snapshot; absence of snapshot just means the
                    -- bank hasn't been opened on this machine yet).
                    local missing = {}
                    if #tabs > 0 then
                        local cap = self.db.global.storageCapacity or {}
                        local capSection
                        if bankType == "warbandbank" then
                            capSection = cap.warbandbank
                        elseif bankType == "guildbank" and guildStr ~= "" then
                            local realm = realmStr ~= "" and realmStr or nil
                            if not realm then
                                for _, entry in pairs(self.db.global.registry) do
                                    if entry.guild == guildStr and entry.guildRealm and entry.guildRealm ~= "" then
                                        realm = entry.guildRealm
                                        break
                                    end
                                end
                            end
                            local key = realm and self:GuildKey(guildStr, realm)
                            capSection = key and cap.guildbank and cap.guildbank[key]
                        elseif bankType == "charbank" and charStr ~= "" then
                            local guid = nameToGUID[charStr] or nameToGUID[charStr:lower()]
                            if guid then
                                capSection = cap.charbank and cap.charbank[guid]
                            end
                        end
                        if capSection and next(capSection) then
                            local kept = {}
                            for _, n in ipairs(tabs) do
                                if capSection[n] then
                                    kept[#kept + 1] = n
                                else
                                    missing[#missing + 1] = tostring(n)
                                end
                            end
                            tabs = kept
                        end
                    end

                    if #invalid > 0 or #missing > 0 then
                        local bankLabel = (bankType == "charbank") and "Character Bank"
                            or (bankType == "warbandbank") and "Warband Bank"
                            or "Guild Bank"
                        local dest
                        if bankType == "guildbank" and guildStr ~= "" then
                            dest = bankLabel .. " <" .. guildStr .. ">"
                        elseif bankType == "charbank" and charStr ~= "" then
                            dest = bankLabel .. " (" .. charStr .. ")"
                        else
                            dest = bankLabel
                        end
                        local dropped = {}
                        if #invalid > 0 then
                            dropped[#dropped + 1] = "invalid: " .. table.concat(invalid, ",")
                        end
                        if #missing > 0 then
                            dropped[#dropped + 1] = "not purchased: " .. table.concat(missing, ",")
                        end
                        if #tabs == 0 then
                            tabs = nil
                            self:ChatMsg(string.format(
                                "Import warning: %s rule '%s' had no usable tabs (%s); using AnyTab.",
                                dest, category, table.concat(dropped, "; ")
                            ), true)
                        else
                            local nDropped = #invalid + #missing
                            self:ChatMsg(string.format(
                                "Import warning: %s rule '%s' dropped %d tab%s (%s).",
                                dest, category, nDropped, nDropped == 1 and "" or "s", table.concat(dropped, "; ")
                            ), true)
                        end
                    elseif #tabs == 0 then
                        tabs = nil
                    end
                end

                -- Parse expansions (validate against EXPANSION_DISPLAY)
                local expansions = nil
                if expStr ~= "" then
                    local validExpIDs = {}
                    for _, exp in ipairs(self.EXPANSION_DISPLAY) do
                        validExpIDs[exp.expansionID] = true
                    end
                    expansions = {}
                    for e in expStr:gmatch("[^,]+") do
                        local n = tonumber(e)
                        if n and validExpIDs[n] then
                            expansions[#expansions + 1] = n
                        end
                    end
                    if #expansions == 0 then
                        expansions = nil
                    end
                end

                -- Parse subcategories (validate against SUBCATEGORY_DISPLAY)
                local subcategories = nil
                if subcatStr ~= "" then
                    local subcatDef = self.SUBCATEGORY_DISPLAY[category]
                    local validKeys = {}
                    if subcatDef then
                        for _, item in ipairs(subcatDef.items) do
                            validKeys[item.key] = true
                        end
                    end
                    subcategories = {}
                    for s in subcatStr:gmatch("[^,]+") do
                        if subcatDef and validKeys[s] then
                            subcategories[#subcategories + 1] = s
                        end
                    end
                    if #subcategories == 0 then
                        subcategories = nil
                    end
                end

                local rule = {
                    profession = category,
                    type = bankType,
                    tabs = tabs,
                    guild = guildStr ~= "" and guildStr or nil,
                    expansions = expansions,
                    subcategories = subcategories,
                    _origChar = charStr, -- keep original for resolution
                    _origGuild = guildStr, -- keep original for resolution
                }

                -- Resolve character / guild
                if bankType == "warbandbank" then
                    readyRules[#readyRules + 1] = rule
                elseif bankType == "guildbank" then
                    -- Prefer the realm from column 8 of the export. Fall back to
                    -- registry lookup (by guild name) for old exports without it.
                    -- entry.guildRealm is the guild's home realm, NOT the
                    -- character's realm - they differ for cross-realm guilds.
                    local resolvedRealm = realmStr ~= "" and realmStr or nil
                    if not resolvedRealm and guildStr ~= "" then
                        for _, entry in pairs(self.db.global.registry) do
                            if entry.guild == guildStr and entry.guildRealm and entry.guildRealm ~= "" then
                                resolvedRealm = entry.guildRealm
                                break
                            end
                        end
                    end
                    if resolvedRealm then
                        rule.realm = resolvedRealm
                        local bankerGuid = self:FindCharInGuild(guildStr, nil, resolvedRealm)
                        if bankerGuid then
                            rule.char = bankerGuid
                            readyRules[#readyRules + 1] = rule
                        else
                            -- Guild name known but no matching banker - surface in remap dialog
                            unresolvedRules[#unresolvedRules + 1] = rule
                        end
                    else
                        -- Unknown / missing guild - surface in remap dialog
                        unresolvedRules[#unresolvedRules + 1] = rule
                    end
                elseif charStr == "" then
                    unresolvedRules[#unresolvedRules + 1] = rule
                else
                    local guid = nameToGUID[charStr] or nameToGUID[charStr:lower()]
                    if guid then
                        rule.char = guid
                        readyRules[#readyRules + 1] = rule
                    else
                        unresolvedRules[#unresolvedRules + 1] = rule
                    end
                end
            end
        end
    end

    return readyRules, unresolvedRules, nil, skippedCount
end

-- Order-insensitive set comparison for expansions/subcategories.
-- Matches the UI dedup behaviour (OpenStorageDialog).
local function setsEqual(a, b)
    if type(a) ~= "table" then a = {} end
    if type(b) ~= "table" then b = {} end
    if #a ~= #b then
        return false
    end
    local setA = {}
    for _, v in ipairs(a) do
        setA[tostring(v)] = true
    end
    for _, v in ipairs(b) do
        if not setA[tostring(v)] then
            return false
        end
    end
    return true
end

-- Pure dup-count helper. Mirrors the dedup check in ApplyImportedRules so the
-- remap dialog's Summary can pre-warn the user how many rules would collapse
-- to duplicates against the current storage list. Does NOT mutate anything.
local function CountDuplicatesAgainst(self, rules, existingList)
    if not rules or #rules == 0 then
        return 0
    end
    existingList = existingList or self.db.global.storageAssignments or {}
    local dup = 0
    for _, rule in ipairs(rules) do
        for _, existing in ipairs(existingList) do
            if
                existing.profession == rule.profession
                and existing.type == rule.type
                and existing.char == rule.char
                and existing.guild == rule.guild
                and setsEqual(existing.expansions, rule.expansions)
                and setsEqual(existing.subcategories, rule.subcategories)
            then
                dup = dup + 1
                break
            end
        end
    end
    return dup
end

-- ----------------------------------------------------------------------------
-- Import Remap Dialog
-- Stepper that walks one unknown-char group at a time. Apply remaps every rule
-- in the group to a chosen local GUID; Skip drops the group; Cancel aborts the
-- whole import. After the last group, a Summary step shows totals and offers
-- [Import] / [Cancel].
-- ----------------------------------------------------------------------------

-- Class-colored "Name - Realm" label for the remap dropdown.
local function RemapCharLabel(entry)
    if not entry then
        return "?"
    end
    local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[entry.class]
    local name = entry.name or "?"
    local realm = entry.realm or ""
    local text = realm == "" and name or (name .. " - " .. realm)
    if color then
        return color:WrapTextInColorCode(text)
    end
    return text
end

-- Group unresolvedRules by their unresolved identity. Charbank rules group by
-- _origChar; guildbank rules group by _origGuild. Char groups first (sorted),
-- then guild groups (sorted) so the dialog has a stable order.
-- Returns: array of
--   { type = "char",  origChar  = "Name-Realm",  rules = {...} }
--   { type = "guild", origGuild = "GuildName",   rules = {...} }
local function GroupUnresolved(unresolvedRules)
    local byChar = {}
    local charOrder = {}
    local byGuild = {}
    local guildOrder = {}
    for _, rule in ipairs(unresolvedRules) do
        if rule.type == "guildbank" then
            local key = (rule._origGuild and rule._origGuild ~= "") and rule._origGuild or "<unspecified>"
            if not byGuild[key] then
                byGuild[key] = { type = "guild", origGuild = key, rules = {} }
                guildOrder[#guildOrder + 1] = key
            end
            table.insert(byGuild[key].rules, rule)
        else
            local key = (rule._origChar and rule._origChar ~= "") and rule._origChar or "<unspecified>"
            if not byChar[key] then
                byChar[key] = { type = "char", origChar = key, rules = {} }
                charOrder[#charOrder + 1] = key
            end
            table.insert(byChar[key].rules, rule)
        end
    end
    table.sort(charOrder, function(a, b) return a:lower() < b:lower() end)
    table.sort(guildOrder, function(a, b) return a:lower() < b:lower() end)
    local groups = {}
    for _, key in ipairs(charOrder) do groups[#groups + 1] = byChar[key] end
    for _, key in ipairs(guildOrder) do groups[#groups + 1] = byGuild[key] end
    return groups
end

-- Sorted, deduped list of {guild, realm} pairs from the registry (excluding blacklist).
-- Keyed on guild.."\1"..realm so same-name guilds on different realms are distinct.
local function RemapCandidateGuilds(self, excludeGuild)
    local seen, list = {}, {}
    for _, entry in pairs(self.db.global.registry or {}) do
        local g = entry.guild
        local r = entry.guildRealm or ""
        if g and g ~= "" and not self:IsGuildBlacklisted(g, r) and g ~= excludeGuild then
            -- GuildKey when the realm is known (it collapses the two stored realm
            -- spellings into one key); raw concat when it isn't, since GuildKey
            -- returns nil on an empty realm and those entries still belong here.
            local key = self:GuildKey(g, r) or (g .. "\1" .. r)
            if not seen[key] then
                seen[key] = true
                list[#list + 1] = { guild = g, realm = r }
            end
        end
    end
    table.sort(list, function(a, b)
        local la, lb = a.guild:lower(), b.guild:lower()
        if la ~= lb then return la < lb end
        return a.realm:lower() < b.realm:lower()
    end)
    return list
end

-- Sorted list of registry chars (excluding blacklist) for the remap dropdown.
local function RemapCandidateChars(self)
    local chars = {}
    local blacklist = self.db.global.charBlacklist or {}
    for guid, entry in pairs(self.db.global.registry or {}) do
        if not blacklist[guid] and entry.name then
            chars[#chars + 1] = { guid = guid, entry = entry }
        end
    end
    table.sort(chars, function(a, b)
        local an = ((a.entry.name or "") .. "-" .. (a.entry.realm or "")):lower()
        local bn = ((b.entry.name or "") .. "-" .. (b.entry.realm or "")):lower()
        return an < bn
    end)
    return chars
end

-- Human label for a rule's destination (profession + bank type + optional tab/guild).
local function RemapRuleDescription(rule)
    local profKey = rule.profession or "?"
    local info = EmpireManager.PROF_INFO_BY_KEY and EmpireManager.PROF_INFO_BY_KEY[profKey]
    local profLabel = (info and info.label) or profKey
    local destText
    if rule.type == "warbandbank" then
        destText = "Warband Bank"
    elseif rule.type == "guildbank" then
        destText = "Guild Bank (" .. (rule.guild or "?") .. ")"
    elseif rule.type == "charbank" then
        destText = "Character Bank"
    else
        destText = rule.type or "?"
    end
    if rule.tabs and #rule.tabs > 0 then
        destText = destText .. " Tab " .. table.concat(rule.tabs, ", ")
    end
    return profLabel, destText
end

function EmpireManager:ShowRemapDialog(groups, readyRules, doReplace, onCommit)
    local f = EmpireManagerRemapDialog
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
    f.TitleText:SetText("EmpireManager - Remap Import")

    -- Decisions[origChar] = { action = "remap"|"skip", guid = "Player-..." }
    local decisions = {}
    local index = 1
    local self_ = self

    local function ClearBody()
        if f._widgets then
            for _, w in ipairs(f._widgets) do
                if w.Hide then w:Hide() end
                if w.SetScript and w.HasScript then
                    if w:HasScript("OnClick") then w:SetScript("OnClick", nil) end
                    if w:HasScript("OnEnter") then w:SetScript("OnEnter", nil) end
                    if w:HasScript("OnLeave") then w:SetScript("OnLeave", nil) end
                end
            end
        end
        f._widgets = {}
        if f._btns then
            for _, b in ipairs(f._btns) do b:Hide() end
        end
        f._btns = {}
    end
    local function Track(obj)
        f._widgets[#f._widgets + 1] = obj
        return obj
    end

    -- Build the final rule list from decisions + readyRules.
    local function BuildFinalRules()
        local finalRules = {}
        for _, r in ipairs(readyRules) do
            finalRules[#finalRules + 1] = r
        end
        local remappedCount = 0
        for _, group in ipairs(groups) do
            local key = group.type == "guild" and group.origGuild or group.origChar
            local d = decisions[key]
            if d and d.action == "remap" then
                if group.type == "guild" and d.guild then
                    -- Guildbank rules: replace guild + auto-resolve a banker char
                    -- the same way the parser's resolved-guild path does.
                    local bankerGuid = self_:FindCharInGuild(d.guild, nil, d.realm)
                    for _, r in ipairs(group.rules) do
                        r.guild = d.guild
                        r.realm = d.realm
                        if bankerGuid then
                            r.char = bankerGuid
                        end
                        finalRules[#finalRules + 1] = r
                        remappedCount = remappedCount + 1
                    end
                elseif group.type ~= "guild" and d.guid then
                    -- Charbank rules: replace target char.
                    for _, r in ipairs(group.rules) do
                        r.char = d.guid
                        finalRules[#finalRules + 1] = r
                        remappedCount = remappedCount + 1
                    end
                end
            end
        end
        return finalRules, remappedCount
    end

    -- Set by every explicit close path (Cancel/Import/X). OnHide checks it so
    -- that ESC (or any other implicit hide) still fires the cancel callback.
    local intentionalClose = false
    local function CloseDialog()
        intentionalClose = true
        f:Hide()
        self_.remapDialogFrame = nil
    end
    f:SetScript("OnHide", function()
        -- Re-enable the IE window's Import button (which we disabled at open
        -- to prevent re-entry while the user is mid-remap).
        local ie = EmpireManagerIOFrame
        if ie and ie._importBtn then
            ie._importBtn:Enable()
        end
        if intentionalClose then
            return
        end
        self_.remapDialogFrame = nil
        if onCommit then onCommit(false, nil, 0, 0) end
    end)

    local renderStep
    local renderSummary

    -- Per-group step renderer (handles both char and guild types).
    renderStep = function()
        if index > #groups then
            renderSummary()
            return
        end
        local group = groups[index]
        ClearBody()
        local sf = f.ScrollFrame
        local content = sf.Content
        content:SetWidth(sf:GetWidth())
        local contentW = sf:GetWidth() or 400
        local y = 8

        local isGuild = group.type == "guild"
        local groupKey = isGuild and group.origGuild or group.origChar
        local unspecifiedLabel = isGuild and "<no guild specified>" or "<no character specified>"
        local refLine = isGuild
            and "%d rule%s reference this guild:"
            or "%d rule%s reference this character:"

        f.SubTitleText:SetText(string.format(
            "|cffdaa520%s %d of %d|r",
            isGuild and "Unknown Guild" or "Unknown Character",
            index, #groups
        ))

        local origName = groupKey == "<unspecified>"
            and ("|cffff8800" .. unspecifiedLabel .. "|r")
            or ("|cffffffff" .. groupKey .. "|r")
        local toFs = Track(content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"))
        toFs:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
        toFs:SetText(origName)
        y = y + 26

        local countFs = Track(content:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
        countFs:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
        local n = #group.rules
        countFs:SetText(string.format(refLine, n, n == 1 and "" or "s"))
        y = y + 18
        y = y + 4

        for _, r in ipairs(group.rules) do
            local row = Track(content:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 16, -y)
            row:SetWidth(contentW - 24)
            row:SetJustifyH("LEFT")
            if row.SetIndentedWordWrap then
                row:SetIndentedWordWrap(true)
            end
            local profLabel, destText = RemapRuleDescription(r)
            row:SetText(string.format("%s » %s", profLabel, destText))
            local h = row:GetStringHeight() or 14
            y = y + math.max(16, math.ceil(h) + 2)
        end
        y = y + 8

        local pickLabel = Track(content:CreateFontString(nil, "OVERLAY", "GameFontNormal"))
        pickLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
        pickLabel:SetText("Remap to:")
        pickLabel:SetTextColor(1, 0.82, 0)
        y = y + 18

        -- Candidates: char or guild. The renderer keeps a single `chosen` token
        -- and dispatches to the right dropdown source.
        local chars = (not isGuild) and RemapCandidateChars(self_) or nil
        local guilds = isGuild and RemapCandidateGuilds(self_) or nil
        local candidateCount = isGuild and #guilds or #chars

        local existing = decisions[groupKey]
        local chosenGUID = (not isGuild and existing and existing.action == "remap") and existing.guid or nil
        local chosenGuild = (isGuild and existing and existing.action == "remap")
            and { guild = existing.guild, realm = existing.realm or "" } or nil

        -- Forward decl: Next button is created below; the dropdown callbacks
        -- need to re-enable it when the user makes a pick.
        local nextBtn
        local function HasPick()
            return (isGuild and chosenGuild ~= nil) or (not isGuild and chosenGUID ~= nil)
        end
        local function RefreshNextBtn()
            if nextBtn then
                nextBtn:SetEnabled(HasPick())
            end
        end

        local dd = Track(CreateFrame("DropdownButton", nil, content, "WowStyle1DropdownTemplate"))
        dd:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
        dd:SetSize(contentW - 24, 26)
        if dd.SetDefaultText then
            if candidateCount == 0 then
                dd:SetDefaultText(isGuild and "(no guilds)" or "(no characters)")
            else
                dd:SetDefaultText(isGuild and "Pick a guild..." or "Pick a character...")
            end
        end
        local selIdx
        dd:SetupMenu(function(_, root)
            root:SetScrollMode(20 * 20)
            selIdx = nil
            if isGuild then
                if #guilds == 0 then return end
                for i, g in ipairs(guilds) do
                    local isChosen = chosenGuild and chosenGuild.guild == g.guild and chosenGuild.realm == g.realm
                    if isChosen then selIdx = i end
                    local label = g.realm ~= "" and (g.guild .. " (" .. g.realm .. ")") or g.guild
                    root:CreateRadio(label, function()
                        return chosenGuild and chosenGuild.guild == g.guild and chosenGuild.realm == g.realm
                    end, function()
                        chosenGuild = g
                        RefreshNextBtn()
                    end)
                end
            else
                if #chars == 0 then return end
                for i, c in ipairs(chars) do
                    if c.guid == chosenGUID then selIdx = i end
                    root:CreateRadio(RemapCharLabel(c.entry), function()
                        return chosenGUID == c.guid
                    end, function()
                        chosenGUID = c.guid
                        RefreshNextBtn()
                    end)
                end
            end
        end)
        self_:EnableDropdownScrollToSelected(dd, function() return selIdx end)
        y = y + 30

        if candidateCount == 0 then
            local empty = Track(content:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
            empty:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
            empty:SetWidth(contentW - 16)
            empty:SetJustifyH("LEFT")
            if isGuild then
                empty:SetText("|cffff8800No guilds in your roster to remap to. Log in to a character in a guild first, then re-import.|r")
            else
                empty:SetText("|cffff8800No characters in your roster to remap to. Log in to your alts first, then re-import.|r")
            end
            y = y + 28
        end

        content:SetHeight(y + 10)

        -- Bottom buttons: Cancel (left) | Skip (center) | Next (right)
        local cancelBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        cancelBtn:SetSize(100, 22)
        cancelBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 24, 20)
        cancelBtn:SetText("Cancel")
        cancelBtn:SetScript("OnClick", function()
            CloseDialog()
            if onCommit then onCommit(false, nil, 0, 0) end
        end)
        f._btns[1] = cancelBtn

        local skipBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        skipBtn:SetSize(100, 22)
        skipBtn:SetPoint("BOTTOM", f, "BOTTOM", 0, 20)
        skipBtn:SetText("Skip")
        skipBtn:SetScript("OnClick", function()
            decisions[groupKey] = { action = "skip" }
            index = index + 1
            renderStep()
        end)
        f._btns[2] = skipBtn

        nextBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        nextBtn:SetSize(100, 22)
        nextBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -24, 20)
        nextBtn:SetText("Next")
        nextBtn:SetScript("OnClick", function()
            if isGuild then
                decisions[groupKey] = { action = "remap", guild = chosenGuild.guild, realm = chosenGuild.realm }
            else
                decisions[groupKey] = { action = "remap", guid = chosenGUID }
            end
            index = index + 1
            renderStep()
        end)
        f._btns[3] = nextBtn
        RefreshNextBtn()
    end

    -- Summary step renderer
    renderSummary = function()
        ClearBody()
        local sf = f.ScrollFrame
        local content = sf.Content
        content:SetWidth(sf:GetWidth())
        local contentW = sf:GetWidth() or 400
        local y = 8

        f.SubTitleText:SetText("|cffdaa520Import Summary|r")

        local readyN = #readyRules
        local remappedTotal, skippedTotal = 0, 0
        local remapLines, skipLines = {}, {}
        local registry = self_.db.global.registry or {}
        for _, group in ipairs(groups) do
            local key = group.type == "guild" and group.origGuild or group.origChar
            local d = decisions[key]
            if d and d.action == "remap" then
                local label
                if group.type == "guild" then
                    label = (d.realm and d.realm ~= "") and (d.guild .. " (" .. d.realm .. ")") or (d.guild or "?")
                else
                    local rEntry = registry[d.guid]
                    label = rEntry and RemapCharLabel(rEntry) or d.guid
                end
                remapLines[#remapLines + 1] = string.format(
                    "%s » %s  (%d)",
                    key, label, #group.rules
                )
                remappedTotal = remappedTotal + #group.rules
            else
                skipLines[#skipLines + 1] = string.format(
                    "%s  (%d)",
                    key, #group.rules
                )
                skippedTotal = skippedTotal + #group.rules
            end
        end

        local function AddLine(text, color, indent, font)
            local leftPad = 8 + (indent or 0)
            local fs = Track(content:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight"))
            fs:SetPoint("TOPLEFT", content, "TOPLEFT", leftPad, -y)
            fs:SetWidth(contentW - leftPad - 8)
            fs:SetJustifyH("LEFT")
            if fs.SetIndentedWordWrap then
                fs:SetIndentedWordWrap(true)
            end
            fs:SetText(text)
            if color then fs:SetTextColor(color[1], color[2], color[3]) end
            -- Advance y by the actual rendered height so wrapped lines (long
            -- realm names, etc.) don't draw on top of the next row.
            local h = fs:GetStringHeight() or 14
            y = y + math.max(16, math.ceil(h) + 2)
        end

        AddLine(string.format("|cff00cc00%d rule%s ready to import|r", readyN, readyN == 1 and "" or "s"), nil, nil, "GameFontNormalLarge")
        y = y + 4

        if remappedTotal > 0 then
            AddLine(string.format("|cff88ccff%d rule%s remapped:|r", remappedTotal, remappedTotal == 1 and "" or "s"), nil, nil, "GameFontNormalLarge")
            for _, line in ipairs(remapLines) do AddLine(line) end
            y = y + 4
        end
        if skippedTotal > 0 then
            AddLine(string.format("|cffdddd00%d rule%s skipped:|r", skippedTotal, skippedTotal == 1 and "" or "s"), nil, nil, "GameFontNormalLarge")
            for _, line in ipairs(skipLines) do AddLine(line) end
            y = y + 4
        end

        -- Pre-commit duplicate check against the current storage list (skipped
        -- in Replace mode since the list will be wiped before applying).
        local previewRules, _ = BuildFinalRules()
        local dupTotal = doReplace and 0 or CountDuplicatesAgainst(self_, previewRules)
        if dupTotal > 0 then
            AddLine(string.format(
                "|cffe8d9a8%d rule%s already exist (will be skipped as duplicates)|r",
                dupTotal, dupTotal == 1 and "" or "s"
            ))
            y = y + 4
        end

        local total = readyN + remappedTotal - dupTotal
        y = y + 8
        AddLine(string.format("|cffffd100%d total rule%s to import|r", total, total == 1 and "" or "s"), nil, nil, "GameFontNormalLarge")

        if doReplace then
            y = y + 6
            AddLine("|cffff8800Existing storage rules will be replaced first.|r")
        end

        content:SetHeight(y + 10)

        -- Buttons: Cancel (left) | Import (right)
        local cancelBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        cancelBtn:SetSize(120, 22)
        cancelBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 24, 20)
        cancelBtn:SetText("Cancel")
        cancelBtn:SetScript("OnClick", function()
            CloseDialog()
            if onCommit then onCommit(false, nil, 0, 0) end
        end)
        f._btns[1] = cancelBtn

        local importBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        importBtn:SetSize(120, 22)
        importBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -24, 20)
        importBtn:SetText("Import")
        if total == 0 then
            importBtn:Disable()
        end
        importBtn:SetScript("OnClick", function()
            local finalRules, mappedN = BuildFinalRules()
            CloseDialog()
            if onCommit then onCommit(true, finalRules, mappedN, skippedTotal) end
        end)
        f._btns[2] = importBtn
    end

    -- Closing via X = cancel
    f.CloseButton:SetScript("OnClick", function()
        CloseDialog()
        if onCommit then onCommit(false, nil, 0, 0) end
    end)

    -- Block re-entry: disable the IE window's Import button while the remap
    -- dialog is active. OnHide re-enables it via every close path.
    local ie = EmpireManagerIOFrame
    if ie and ie._importBtn then
        ie._importBtn:Disable()
    end

    f:Show()
    self.remapDialogFrame = f
    renderStep()
end

function EmpireManager:ApplyImportedRules(rules)
    if not self.db.global.storageAssignments then
        self.db.global.storageAssignments = {}
    end
    local assignments = self.db.global.storageAssignments
    local imported = 0
    local skipped = 0

    for _, rule in ipairs(rules) do
        -- Clean internal fields
        rule._origChar = nil
        rule._origGuild = nil

        -- Duplicate check - matches the UI rule: same category + destination = dup,
        -- regardless of tab list (set-based for expansions/subcategories).
        local isDupe = false
        for _, existing in ipairs(assignments) do
            if
                existing.profession == rule.profession
                and existing.type == rule.type
                and existing.char == rule.char
                and existing.guild == rule.guild
                and setsEqual(existing.expansions, rule.expansions)
                and setsEqual(existing.subcategories, rule.subcategories)
            then
                isDupe = true
                break
            end
        end

        if isDupe then
            skipped = skipped + 1
        else
            assignments[#assignments + 1] = rule
            if rule.char and rule.char ~= "self" then
                self:SyncBankerRole(rule.char)
            end
            imported = imported + 1
        end
    end

    if imported > 0 then
        self:InvalidateStorageCache()
    end

    return imported, skipped
end

-------------------------------------------------------------------------------
-- Keep List / Vendor Whitelist / Restock Rules Import / Export
--
-- Same paste-in IE window as characters + storage rules. Sections are recognized
-- by their header comment (e.g. "# EmpireManager Keep List v1"); unrecognized
-- sections are silently ignored so old exports still parse.
--
-- Skip-reason chat lines are gated behind ChatVerbose so a normal user gets a
-- clean status line and a verbose user gets per-item diagnostics.
-------------------------------------------------------------------------------

-- Format helpers ---------------------------------------------------------------

-- "itemID;name" lines. Names are display cache only; the local copy always wins.
function EmpireManager:ExportKeepList()
    local list = self.db.global.keepList or {}
    local lines = {
        "# EmpireManager Keep List v1",
        "# itemID;name",
    }
    -- Sort by itemID for stable output (diffable exports).
    local ids = {}
    for id in pairs(list) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
        lines[#lines + 1] = string.format("%d;%s", id, tostring(list[id] or ""))
    end
    if #ids == 0 then
        lines[#lines + 1] = "# (no items)"
    end
    return table.concat(lines, "\n") .. "\n"
end

function EmpireManager:ExportVendorList()
    local list = self.db.global.vendorWhitelist or {}
    local lines = {
        "# EmpireManager Vendor Whitelist v1",
        "# itemID;name",
    }
    local ids = {}
    for id in pairs(list) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
        lines[#lines + 1] = string.format("%d;%s", id, tostring(list[id] or ""))
    end
    if #ids == 0 then
        lines[#lines + 1] = "# (no items)"
    end
    return table.concat(lines, "\n") .. "\n"
end

-- Restock: "itemID;target;dest;chars;guild;realm;name". `chars` is comma-
-- separated Name-Realm (portable across accounts; GUIDs would break on import).
function EmpireManager:ExportRestockList()
    local list = self.db.global.restockList or {}
    local lines = {
        "# EmpireManager Restock Rules v1",
        "# itemID;target;dest;chars;guild;realm;name",
    }
    if #list == 0 then
        lines[#lines + 1] = "# (no rules configured)"
        return table.concat(lines, "\n") .. "\n"
    end

    local guidToName = {}
    for guid, entry in pairs(self.db.global.registry) do
        guidToName[guid] = (entry.name or "Unknown") .. "-" .. (entry.realm or "Unknown")
    end

    for _, e in ipairs(list) do
        if type(e) == "table" and e.itemID and e.target and e.dest then
            local charStr = ""
            if e.chars and #e.chars > 0 then
                local parts = {}
                for _, g in ipairs(e.chars) do
                    parts[#parts + 1] = guidToName[g] or g
                end
                charStr = table.concat(parts, ",")
            elseif e.char then
                charStr = guidToName[e.char] or e.char
            end
            lines[#lines + 1] = string.format(
                "%d;%d;%s;%s;%s;%s;%s",
                e.itemID,
                e.target,
                tostring(e.dest),
                charStr,
                tostring(e.guild or ""),
                tostring(e.realm or ""),
                tostring(e.name or "")
            )
        end
    end
    return table.concat(lines, "\n") .. "\n"
end

-- Parse "itemID;name" lines from a Keep/Vendor list section. Returns
-- { {itemID=..., name=...}, ... }, skippedCount. Invalid itemIDs are dropped
-- with a verbose chat warning per line.
local function ParseItemNameSection(self, text)
    local out, skipped = {}, 0
    for line in text:gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local idStr, name = line:match("^([^;]+);(.*)$")
            local id = tonumber(idStr)
            if id and id > 0 then
                if #name > 128 then
                    name = name:sub(1, 128)
                end
                out[#out + 1] = { itemID = id, name = name or "" }
            else
                skipped = skipped + 1
                self:ChatVerbose("|cff88ccff[Import]|r Skipped malformed line: " .. line)
            end
        end
    end
    return out, skipped
end

function EmpireManager:ImportKeepList(text)
    return ParseItemNameSection(self, text or "")
end

function EmpireManager:ImportVendorList(text)
    return ParseItemNameSection(self, text or "")
end

-- Apply Keep entries. Conflict rule (Keep wins by design):
-- an incoming Keep item that's on the local Vendor Whitelist MOVES to Keep
-- (Vendor entry dropped). Existing Keep entries are left untouched.
-- Returns imported, skipped, moved.
function EmpireManager:ApplyImportedKeepList(entries)
    if not self.db.global.keepList then
        self.db.global.keepList = {}
    end
    if not self.db.global.vendorWhitelist then
        self.db.global.vendorWhitelist = {}
    end
    local keep, vendor = self.db.global.keepList, self.db.global.vendorWhitelist
    local imported, skipped, moved = 0, 0, 0
    for _, e in ipairs(entries or {}) do
        local id, name = e.itemID, e.name ~= "" and e.name or nil
        if keep[id] then
            skipped = skipped + 1
            self:ChatVerbose(string.format(
                "|cff88ccff[Import]|r Keep List: itemID %d already present, skipped.",
                id
            ))
        else
            keep[id] = name or ("Item " .. id)
            imported = imported + 1
            if vendor[id] then
                vendor[id] = nil
                moved = moved + 1
                self:ChatVerbose(string.format(
                    "|cff88ccff[Import]|r itemID %d moved from Vendor Whitelist to Keep List.",
                    id
                ))
            end
        end
    end
    return imported, skipped, moved
end

-- Apply Vendor entries. Conflict rule: Keep wins - vendor entries whose itemID
-- is already on the Keep List are silently skipped.
-- Returns imported, skipped.
function EmpireManager:ApplyImportedVendorList(entries)
    if not self.db.global.vendorWhitelist then
        self.db.global.vendorWhitelist = {}
    end
    local vendor = self.db.global.vendorWhitelist
    local keep = self.db.global.keepList or {}
    local imported, skipped = 0, 0
    for _, e in ipairs(entries or {}) do
        local id, name = e.itemID, e.name ~= "" and e.name or nil
        if keep[id] then
            skipped = skipped + 1
            self:ChatVerbose(string.format(
                "|cff88ccff[Import]|r Vendor Whitelist: itemID %d is on Keep List (Keep wins), skipped.",
                id
            ))
        elseif vendor[id] then
            skipped = skipped + 1
            self:ChatVerbose(string.format(
                "|cff88ccff[Import]|r Vendor Whitelist: itemID %d already present, skipped.",
                id
            ))
        else
            vendor[id] = name or ("Item " .. id)
            imported = imported + 1
        end
    end
    return imported, skipped
end

-- Parse a Restock Rules section. Returns readyRules, unresolvedRules, skipped.
-- Char/bags rules whose Name-Realm can't be resolved to a local GUID land in
-- unresolvedRules for the remap dialog. Warband + guild rules never unresolve.
function EmpireManager:ImportRestockList(text)
    if not text or text:match("^%s*$") then
        return {}, {}, 0
    end

    local nameToGUID = {}
    for guid, entry in pairs(self.db.global.registry) do
        local key = ((entry.name or "Unknown") .. "-" .. (entry.realm or "Unknown"))
        nameToGUID[key] = guid
        nameToGUID[key:lower()] = guid
    end

    local ready, unresolved = {}, {}
    local skipped = 0

    for line in text:gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local parts = {}
            for f in (line .. ";"):gmatch("([^;]*);") do
                parts[#parts + 1] = f:match("^%s*(.-)%s*$")
            end

            local itemID = tonumber(parts[1])
            local target = tonumber(parts[2])
            local dest = parts[3] or ""
            local charStr = parts[4] or ""
            local guildStr = parts[5] or ""
            local realmStr = parts[6] or ""
            local name = parts[7] or ""

            -- Cap free-text fields so a malformed export can't wreck chat/UI.
            if #guildStr > 64 then guildStr = guildStr:sub(1, 64) end
            if #realmStr > 64 then realmStr = realmStr:sub(1, 64) end
            if #charStr > 512 then charStr = charStr:sub(1, 512) end
            if #name > 128 then name = name:sub(1, 128) end

            if not itemID or itemID <= 0 or not target or target <= 0 then
                skipped = skipped + 1
                self:ChatVerbose("|cff88ccff[Import]|r Restock: malformed line: " .. line)
            elseif
                dest ~= "warbandbank"
                and dest ~= "guildbank"
                and dest ~= "charbank"
                and dest ~= "bags"
            then
                skipped = skipped + 1
                self:ChatVerbose(string.format(
                    "|cff88ccff[Import]|r Restock: unknown dest '%s' for itemID %d, skipped.",
                    dest, itemID
                ))
            else
                local rule = {
                    itemID = itemID,
                    target = target,
                    dest = dest,
                    name = name ~= "" and name or ("Item " .. itemID),
                    _origChar = charStr,
                    _origGuild = guildStr,
                }

                if dest == "warbandbank" then
                    ready[#ready + 1] = rule
                elseif dest == "guildbank" then
                    if guildStr ~= "" then
                        rule.guild = guildStr
                        rule.realm = realmStr ~= "" and realmStr or nil
                        ready[#ready + 1] = rule
                    else
                        skipped = skipped + 1
                        self:ChatVerbose(string.format(
                            "|cff88ccff[Import]|r Restock: guildbank rule for itemID %d has no guild, skipped.",
                            itemID
                        ))
                    end
                else
                    -- charbank / bags: resolve Name-Realm list to local GUIDs.
                    -- If NONE resolve, mark unresolved (remap dialog will handle
                    -- via _origChar). If SOME resolve, keep resolved subset and
                    -- verbose-log the dropped ones.
                    if charStr == "" then
                        unresolved[#unresolved + 1] = rule
                    else
                        local resolvedGuids = {}
                        local dropped = {}
                        for nm in charStr:gmatch("[^,]+") do
                            local trimmed = nm:match("^%s*(.-)%s*$")
                            local g = nameToGUID[trimmed] or nameToGUID[trimmed:lower()]
                            if g then
                                resolvedGuids[#resolvedGuids + 1] = g
                            else
                                dropped[#dropped + 1] = trimmed
                            end
                        end
                        if #resolvedGuids == 0 then
                            unresolved[#unresolved + 1] = rule
                        else
                            rule.chars = resolvedGuids
                            ready[#ready + 1] = rule
                            if #dropped > 0 then
                                self:ChatVerbose(string.format(
                                    "|cff88ccff[Import]|r Restock itemID %d: dropped %d unknown char%s (%s).",
                                    itemID, #dropped, #dropped == 1 and "" or "s",
                                    table.concat(dropped, ", ")
                                ))
                            end
                        end
                    end
                end
            end
        end
    end

    return ready, unresolved, skipped
end

-- Restock dedup key = itemID + dest + sorted-chars + guild + realm. Same shape
-- as the storage-rule dedup (order-insensitive char set).
local function restockDupKey(rule)
    local chars = rule.chars or (rule.char and { rule.char } or {})
    local sorted = {}
    for _, c in ipairs(chars) do
        sorted[#sorted + 1] = tostring(c)
    end
    table.sort(sorted)
    return string.format(
        "%d|%s|%s|%s|%s",
        rule.itemID or 0,
        rule.dest or "",
        table.concat(sorted, ","),
        rule.guild or "",
        rule.realm or ""
    )
end

-- Append imported restock rules. Duplicates (same key) skip. Returns imported, skipped.
function EmpireManager:ApplyImportedRestockRules(rules)
    if not self.db.global.restockList then
        self.db.global.restockList = {}
    end
    local list = self.db.global.restockList
    local existingKeys = {}
    for _, r in ipairs(list) do
        existingKeys[restockDupKey(r)] = true
    end

    local imported, skipped = 0, 0
    for _, rule in ipairs(rules or {}) do
        rule._origChar = nil
        rule._origGuild = nil
        local key = restockDupKey(rule)
        if existingKeys[key] then
            skipped = skipped + 1
            self:ChatVerbose(string.format(
                "|cff88ccff[Import]|r Restock: itemID %d (%s) duplicate, skipped.",
                rule.itemID or 0, rule.dest or "?"
            ))
        else
            list[#list + 1] = rule
            existingKeys[key] = true
            imported = imported + 1
        end
    end
    if imported > 0 then
        self:InvalidateStorageCache()
    end
    return imported, skipped
end

function EmpireManager:ParseImportSections(text)
    local sections = {}
    local currentType = nil
    local currentLines = {}

    for line in text:gmatch("[^\r\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed:find("^# EmpireManager Registry v") then
            if currentType then
                sections[#sections + 1] = { type = currentType, text = table.concat(currentLines, "\n") }
            end
            currentType = "registry"
            currentLines = { trimmed }
        elseif trimmed:find("^# EmpireManager Storage Rules v") then
            if currentType then
                sections[#sections + 1] = { type = currentType, text = table.concat(currentLines, "\n") }
            end
            currentType = "storage"
            currentLines = { trimmed }
        elseif trimmed:find("^# EmpireManager Keep List v") then
            if currentType then
                sections[#sections + 1] = { type = currentType, text = table.concat(currentLines, "\n") }
            end
            currentType = "keeplist"
            currentLines = { trimmed }
        elseif trimmed:find("^# EmpireManager Vendor Whitelist v") then
            if currentType then
                sections[#sections + 1] = { type = currentType, text = table.concat(currentLines, "\n") }
            end
            currentType = "vendorlist"
            currentLines = { trimmed }
        elseif trimmed:find("^# EmpireManager Restock Rules v") then
            if currentType then
                sections[#sections + 1] = { type = currentType, text = table.concat(currentLines, "\n") }
            end
            currentType = "restock"
            currentLines = { trimmed }
        elseif currentType then
            currentLines[#currentLines + 1] = trimmed
        end
    end

    if currentType then
        sections[#sections + 1] = { type = currentType, text = table.concat(currentLines, "\n") }
    end

    return sections
end

-------------------------------------------------------------------------------

-- Shared helpers for native pages
local FONT_NORMAL = "GameFontHighlight"
local LINE_HEIGHT = 20
local HEADING_HEIGHT = 32

-- Aggregate capacity across specific tabs or all tabs (used by Roster Banks and Storage page).
-- Delegates to EmpireManager:AggregateCapacity (Utils.lua) - shared with triage routing.
local function AggregateCapacity(capSection, tabs)
    return EmpireManager:AggregateCapacity(capSection, tabs)
end

-------------------------------------------------------------------------------
-- ABOUT PAGE MIXIN
-------------------------------------------------------------------------------

-- Popup that lets the user copy the EmpireManager website URL.
-- WoW cannot launch a browser; the standard pattern is a read-only edit box
-- pre-selected for Ctrl+C.
StaticPopupDialogs["EM_URL_SITE"] = {
    text = "EmpireManager website (Ctrl+C to copy):",
    button1 = OKAY,
    hasEditBox = true,
    editBoxWidth = 280,
    OnShow = function(self)
        local eb = self.editBox or self.EditBox
        if not eb then return end
        eb:SetText("https://wow.cyberpunk.gr/")
        eb:HighlightText()
        eb:SetFocus()
    end,
    EditBoxOnEscapePressed = function(self)
        self:GetParent():Hide()
    end,
    EditBoxOnEnterPressed = function(self)
        self:GetParent():Hide()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

function EMAboutPageMixin:OnLoad()
    self.ScrollFrame = self.Inset.ScrollFrame
    local sf = self.ScrollFrame
    sf:SetScrollChild(sf.Content)

    local inset = self.Inset
    if inset then
        if inset.BGCornerTopLeft then
            inset.BGCornerTopLeft:Hide()
        end
        if inset.BGCornerTopRight then
            inset.BGCornerTopRight:Hide()
        end
        if inset.BGCornerBottomLeft then
            inset.BGCornerBottomLeft:Hide()
        end
        if inset.BGCornerBottomRight then
            inset.BGCornerBottomRight:Hide()
        end
    end
end

function EMAboutPageMixin:OnShow()
    self:Refresh()
end

function EMAboutPageMixin:Refresh()
    local sf = self.ScrollFrame
    local content = sf.Content
    content:SetWidth(sf:GetWidth())

    -- Clear previous content
    if self._lines then
        for _, obj in ipairs(self._lines) do
            obj:Hide()
        end
    end
    self._lines = {}

    local lines = self._lines
    local y = EmpireManager:BuildAboutPanel(content, {
        track = function(obj)
            lines[#lines + 1] = obj
            return obj
        end,
    })

    content:SetHeight(y + 20)
end

-------------------------------------------------------------------------------
-- MAP PAGE MIXIN
-------------------------------------------------------------------------------

-- Map column definitions. `sortKey` enables clickable header sort.
local MAP_COLUMNS = {
    { key = "name", width = 130, label = "Name", justify = "LEFT", padLeft = 8, sortKey = "name" },
    { key = "zone", width = 170, label = "Zone", justify = "LEFT", padLeft = 8, sortKey = "zone" },
    { key = "subZone", width = 200, label = "SubZone", justify = "LEFT", padLeft = 8, sortKey = "subZone" },
    { key = "seen", width = 100, label = "Last Seen", justify = "RIGHT", padRight = 16, sortKey = "seen" },
    { key = "coords", width = 110, label = "Coords", justify = "CENTER" },
}

-- Sort key functions per column. Tiebreak handled by caller (name asc).
local MAP_SORT_KEYS = {
    name = function(e)
        return (e.name or ""):lower()
    end,
    zone = function(e)
        return (e.zone or ""):lower()
    end,
    subZone = function(e)
        return (e.subZone or ""):lower()
    end,
    seen = function(e)
        return e.lastSeen or 0
    end,
}

function EMMapPageMixin:OnLoad()
    self.ScrollBox = self.Inset.ScrollBox
    self.ScrollBar = self.Inset.ScrollBar

    -- Default sort: first column (name), ascending
    self.sortColumn = "name"
    self.sortAscending = true
    self.headerButtons = {}

    local view = CreateScrollBoxListLinearView()
    view:SetElementInitializer("EMMapRowTemplate", function(frame, elementData)
        if not frame._mixinApplied then
            Mixin(frame, EMMapRowMixin)
            frame:OnLoad()
            frame._mixinApplied = true
        end
        frame:Populate(elementData)
    end)
    view:SetElementExtent(22)
    ScrollUtil.InitScrollBoxListWithScrollBar(self.ScrollBox, self.ScrollBar, view)

    -- Build column headers
    self:InitMapHeaders()
end

function EMMapPageMixin:InitMapHeaders()
    local container = self.Inset.HeaderContainer
    local xOffset = 6
    for _, col in ipairs(MAP_COLUMNS) do
        local btn = CreateFrame("Button", nil, container, "ColumnDisplayButtonShortTemplate")
        btn:SetSize(col.width, 19)
        btn:SetPoint("LEFT", container, "LEFT", xOffset, 0)
        btn:SetText(col.label)
        btn:SetNormalFontObject(GameFontHighlightSmall)
        btn:GetFontString():SetJustifyH(col.justify)
        btn._text = btn:GetFontString()

        if col.sortKey then
            local arrow = btn:CreateTexture(nil, "OVERLAY")
            arrow:SetAtlas("auctionhouse-ui-sortarrow", true)
            arrow:SetPoint("LEFT", btn._text, "RIGHT", 1, 0)
            arrow:Hide()
            btn._arrow = arrow

            local page = self
            btn:SetScript("OnClick", function()
                if page.sortColumn == col.sortKey then
                    page.sortAscending = not page.sortAscending
                else
                    page.sortColumn = col.sortKey
                    page.sortAscending = true
                end
                page:UpdateHeaderArrows()
                page:Refresh()
            end)

            self.headerButtons[#self.headerButtons + 1] = { btn = btn, sortKey = col.sortKey }
        else
            btn:SetEnabled(false)
        end

        xOffset = xOffset + col.width
    end

    self:UpdateHeaderArrows()
end

function EMMapPageMixin:UpdateHeaderArrows()
    for _, h in ipairs(self.headerButtons) do
        if self.sortColumn == h.sortKey then
            h.btn._arrow:Show()
            if self.sortAscending then
                h.btn._arrow:SetTexCoord(0, 1, 1, 0)
            else
                h.btn._arrow:SetTexCoord(0, 1, 0, 1)
            end
            h.btn:SetNormalFontObject(GameFontHighlight)
        else
            h.btn._arrow:Hide()
            h.btn:SetNormalFontObject(GameFontHighlightSmall)
        end
    end
end

function EMMapPageMixin:OnShow()
    self:Refresh()
end

function EMMapPageMixin:Refresh()
    -- Flat list of all characters with a known zone
    local data = {}
    for guid, entry in pairs(EmpireManager.db.global.registry) do
        if entry.zone and entry.zone ~= "" then
            data[#data + 1] = { guid = guid, entry = entry }
        end
    end

    local keyFn = MAP_SORT_KEYS[self.sortColumn] or MAP_SORT_KEYS.name
    local asc = self.sortAscending
    table.sort(data, function(a, b)
        local kA = keyFn(a.entry)
        local kB = keyFn(b.entry)
        if kA == kB then
            return (a.entry.name or ""):lower() < (b.entry.name or ""):lower()
        end
        if asc then
            return kA < kB
        else
            return kA > kB
        end
    end)

    -- Add index for row tracking
    for i, d in ipairs(data) do
        d.index = i
    end

    local dataProvider = CreateDataProvider(data)
    self.ScrollBox:SetDataProvider(dataProvider)
end

-- Map Row Mixin
function EMMapRowMixin:OnLoad()
    self:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    self:SetScript("OnClick", function(f, button)
        f:OnClick(button)
    end)
    self:SetScript("OnEnter", function(f)
        f:OnEnter()
    end)
    self:SetScript("OnLeave", function(f)
        f:OnLeave()
    end)

    self.cells = {}
    local x = 6
    for _, col in ipairs(MAP_COLUMNS) do
        local padL = col.padLeft or 0
        local padR = col.padRight or 0
        local fs = self:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
        fs:SetJustifyH(col.justify)
        fs:SetWidth(col.width - 4 - padL - padR)
        fs:SetHeight(22)
        fs:SetPoint("LEFT", self, "LEFT", x + 2 + padL, 0)
        self.cells[col.key] = fs
        x = x + col.width
    end
end

function EMMapRowMixin:Populate(data)
    self._data = data
    local entry = data.entry

    self.cells.name:SetText(EmpireManager:ClassColoredName(entry))
    self.cells.zone:SetText(entry.zone or "")
    self.cells.zone:SetTextColor(1, 0.82, 0)
    self.cells.subZone:SetText((entry.subZone and entry.subZone ~= "") and entry.subZone or "")
    self.cells.subZone:SetTextColor(0.8, 0.72, 0.5)
    self.cells.seen:SetText(EmpireManager:FormatTimeSince(entry.lastSeen))
    self.cells.seen:SetTextColor(1, 1, 1)

    local pinPrefix = entry.mapPinned and "|cff4488cc*|r " or ""
    if entry.mapX and entry.mapY then
        self.cells.coords:SetText(pinPrefix .. string.format("%.1f, %.1f", entry.mapX * 100, entry.mapY * 100))
        self.cells.coords:SetTextColor(0.5, 0.7, 0.5)
    else
        self.cells.coords:SetText(pinPrefix .. "-")
        self.cells.coords:SetTextColor(0.7, 0.65, 0.5)
    end

    -- Zebra stripe (AH-style atlas, matches Characters/Storage tabs)
    if data.index and data.index % 2 == 0 then
        self.Stripe:SetAtlas("auctionhouse-rowstripe-1")
    else
        self.Stripe:SetAtlas("auctionhouse-rowstripe-2")
    end
end

function EMMapRowMixin:OnClick(button)
    local data = self._data
    if not data then
        return
    end
    local entry = data.entry

    if button == "RightButton" then
        -- Toggle map pin
        entry.mapPinned = not entry.mapPinned
        local state = entry.mapPinned and "pinned" or "unpinned"
        EmpireManager:Print(string.format("%s location %s", entry.name or "?", state))
        -- Refresh the row display
        self:Populate(data)
        return
    end

    if entry.mapID and entry.mapX then
        local point = UiMapPoint.CreateFromCoordinates(entry.mapID, entry.mapX, entry.mapY or 0)
        C_Map.SetUserWaypoint(point)
        -- NOTE: do NOT call C_SuperTrack.SetSuperTrackedUserWaypoint here. Supertracking
        -- from an insecure click handler taints the user-waypoint state, which later breaks
        -- Blizzard's WorldMap flight-point pins (SetPropagateMouseClicks) in combat and
        -- gets the whole ADDON_ACTION_BLOCKED error blamed on us.
        -- Print clickable waypoint link
        local link = C_Map.GetUserWaypointHyperlink()
        if link then
            EmpireManager:Print(string.format("%s: %s", entry.name or "?", link))
        end
    else
        EmpireManager:Print(string.format("No location data for %s", entry.name or "?"))
    end
end

function EMMapRowMixin:OnEnter()
    local data = self._data
    if not data then
        return
    end
    local entry = data.entry
    GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT")
    local cc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[entry.class]
    local cr, cg, cb = cc and cc.r or 1, cc and cc.g or 1, cc and cc.b or 1
    local header = string.format("%s - %s (%d)", entry.name or "?", entry.realm or "?", entry.level or 0)
    GameTooltip:AddLine(header, cr, cg, cb)
    if entry.zone then
        local loc = entry.zone
        if entry.subZone and entry.subZone ~= "" then
            loc = loc .. " - " .. entry.subZone
        end
        GameTooltip:AddLine(loc, 0.7, 0.7, 0.7)
    end
    if entry.mapPinned then
        GameTooltip:AddLine("Pinned (coordinates locked)", 0.27, 0.53, 0.8)
    end
    if entry.mapX and entry.mapY and entry.mapID then
        GameTooltip:AddLine(
            string.format("%.1f, %.1f  (Map %d)", entry.mapX * 100, entry.mapY * 100, entry.mapID),
            0.5,
            0.7,
            0.5
        )
        GameTooltip:AddLine("Click to set waypoint", 1, 0.82, 0)
    end
    GameTooltip:AddLine(entry.mapPinned and "Right-click to unpin" or "Right-click to pin location", 0.5, 0.8, 1.0)
    GameTooltip:Show()
end

function EMMapRowMixin:OnLeave()
    GameTooltip:Hide()
end

-------------------------------------------------------------------------------
-- ROSTER PAGE MIXIN (PanelTemplates sub-tabs)
-------------------------------------------------------------------------------

function EMRosterPageMixin:OnLoad()
    self._selectedTab = 1

    self.ScrollFrame = self.Inset.ScrollFrame
    local sf = self.ScrollFrame
    sf:SetScrollChild(sf.Content)

    -- Override CollectionsBackgroundTemplate's built-in anchors so the inset
    -- sits directly under the sub-tabs (Wardrobe pattern, matches Sidecar).
    local inset = self.Inset
    if inset then
        inset:ClearAllPoints()
        inset:SetPoint("TOPLEFT", self, "TOPLEFT", 0, 8)
        inset:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", 0, 0)
        if inset.BGCornerTopLeft then
            inset.BGCornerTopLeft:Hide()
        end
        if inset.BGCornerTopRight then
            inset.BGCornerTopRight:Hide()
        end
        if inset.BGCornerBottomLeft then
            inset.BGCornerBottomLeft:Hide()
        end
        if inset.BGCornerBottomRight then
            inset.BGCornerBottomRight:Hide()
        end
    end

    -- Top tabs (Appearances-style TabSystemTopButtonTemplate)
    Mixin(self, TabSystemOwnerMixin)
    TabSystemOwnerMixin.OnLoad(self)
    self:SetTabSystem(self.TabSystem)

    local tabNames = { "Info", "Banks", "Professions", "Categories", "Roles" }
    self._tabNames = tabNames
    self._tabIDs = {}
    for i, name in ipairs(tabNames) do
        self._tabIDs[i] = self:AddNamedTab(name)
        self:SetTabCallback(self._tabIDs[i], function()
            self._selectedTab = i
            self:Refresh()
            -- Refresh InfoButton tooltip if it's visible (sub-tab help)
            if
                EmpireManager.dashboardFrame
                and EmpireManager.dashboardFrame.InfoButton:IsShown()
                and GameTooltip:GetOwner() == EmpireManager.dashboardFrame.InfoButton
            then
                EmpireManager.dashboardFrame.InfoButton:GetScript("OnEnter")(EmpireManager.dashboardFrame.InfoButton)
            end
        end)
    end
end

function EMRosterPageMixin:OnShow()
    if self._tabIDs and self._tabIDs[self._selectedTab or 1] then
        self:SetTab(self._tabIDs[self._selectedTab or 1])
    end
    self:Refresh()
end

function EMRosterPageMixin:Refresh()
    local sf = self.ScrollFrame
    local content = sf.Content
    content:SetWidth(sf:GetWidth())

    -- Clear previous: hide objects and release closure references
    if self._lines then
        for _, obj in ipairs(self._lines) do
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
            end
        end
    end
    self._lines = {}

    local tab = self._selectedTab or 1
    local y = 8

    if tab == 1 then
        y = self:BuildInfoContent(content, y)
    elseif tab == 2 then
        y = self:BuildBankContent(content, y)
    elseif tab == 3 then
        y = self:BuildDeptContent(content, y)
    elseif tab == 4 then
        y = self:BuildCategoriesContent(content, y)
    elseif tab == 5 then
        y = self:BuildRoleContent(content, y)
    end

    content:SetHeight(y + 20)
    sf:SetVerticalScroll(0)
end

function EMRosterPageMixin:Track(obj)
    self._lines[#self._lines + 1] = obj
    return obj
end

-- Helper: add a heading with separator. Returns (newY, headingFontString).
-- Fill bar with subtle vertical gradient; pct left, used/total right (Blizz health-bar style).
-- `anchor` is either a region (anchored "TOPLEFT" to its "BOTTOMLEFT" with -12 y-offset) or
-- nil (anchored to `content` "TOPLEFT" at offset 8, -y).
-- Returns new y value after the bar.
function EMRosterPageMixin:DrawFillBar(content, anchor, y, pct, used, total, free, scannedAt)
    local function colorForPct(p)
        if p >= 0.85 then
            return 1.0, 0.2, 0.2
        elseif p >= 0.60 then
            return 1.0, 0.8, 0.0
        else
            return 0.0, 0.8, 0.0
        end
    end

    local BAR_W, BAR_H = 400, 19
    local row = self:Track(CreateFrame("Frame", nil, content))
    row:SetSize(BAR_W, BAR_H)
    if anchor then
        row:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -12)
    else
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
    end

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.1, 0.1, 0.1, 0.85)

    local fill = row:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT", row, "TOPLEFT", 1, -1)
    fill:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 1, 1)
    local fw = math.max(1, math.floor((BAR_W - 2) * pct))
    fill:SetWidth(fw)
    fill:SetColorTexture(1, 1, 1, 1)
    local r, g, b = colorForPct(pct)
    fill:SetGradient(
        "VERTICAL",
        CreateColor(r * 0.7, g * 0.7, b * 0.7, 0.6),
        CreateColor(math.min(1, r * 1.1), math.min(1, g * 1.1), math.min(1, b * 1.1), 0.6)
    )

    local border = CreateFrame("Frame", nil, row, "BackdropTemplate")
    border:SetAllPoints()
    border:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    border:SetBackdropBorderColor(0, 0, 0, 0.7)

    local pctFS = row:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
    pctFS:SetPoint("LEFT", row, "LEFT", 6, 0)
    pctFS:SetShadowColor(0, 0, 0, 1)
    pctFS:SetShadowOffset(1, -1)
    pctFS:SetTextColor(1, 1, 1)
    pctFS:SetText(string.format("%d%%", math.floor(pct * 100 + 0.5)))

    local valFS = row:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
    valFS:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    valFS:SetShadowColor(0, 0, 0, 1)
    valFS:SetShadowOffset(1, -1)
    valFS:SetTextColor(1, 1, 1)
    valFS:SetText(string.format("%s / %s", BreakUpLargeNumbers(used), BreakUpLargeNumbers(total)))

    local freeFS = self:Track(content:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
    freeFS:SetPoint("LEFT", row, "RIGHT", 8, 0)
    freeFS:SetTextColor(0.85, 0.85, 0.85)
    local age = EmpireManager:FormatStaleAge(scannedAt)
    if age then
        freeFS:SetText(string.format("%s free, scanned %s", BreakUpLargeNumbers(free), age))
    else
        freeFS:SetText(string.format("%s free", BreakUpLargeNumbers(free)))
    end

    return y + BAR_H + 4
end

function EMRosterPageMixin:AddHeading(content, y, text, skipDivider)
    if not skipDivider then
        y = y + 4 -- extra spacing above divider

        local divider = self:Track(content:CreateTexture(nil, "ARTWORK"))
        divider:SetAtlas("ui-journeys-renown-divider", true)
        divider:SetPoint("TOP", content, "TOP", 0, -y)
        y = y + 28
    end

    local fs = self:Track(content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"))
    fs:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
    fs:SetText("|cffffd100" .. text .. "|r")
    return y + HEADING_HEIGHT, fs
end

-- Helper: add a stat line "Label   Value" in a row
function EMRosterPageMixin:AddStatLine(content, y, label, value, lr, lg, lb, vr, vg, vb)
    local fs = self:Track(content:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
    fs:SetPoint("TOPLEFT", content, "TOPLEFT", 12, -y)
    fs:SetPoint("RIGHT", content, "RIGHT", -8, 0)
    fs:SetJustifyH("LEFT")
    local lColor = string.format("|cff%02x%02x%02x", (lr or 0.87) * 255, (lg or 0.87) * 255, (lb or 0.87) * 255)
    local vColor = string.format("|cff%02x%02x%02x", (vr or 1) * 255, (vg or 1) * 255, (vb or 1) * 255)
    fs:SetText(lColor .. label .. "|r    " .. vColor .. value .. "|r")
    return y + LINE_HEIGHT
end

-- Helper: interactive label with tooltip
function EMRosterPageMixin:AddClickLabel(content, y, text, width, tooltipTitle, chars, tooltipFmt)
    local btn = self:Track(CreateFrame("Button", nil, content))
    btn:SetSize(width, LINE_HEIGHT)
    btn:SetPoint("TOPLEFT", content, "TOPLEFT", 12 + (self._flowX or 0), -y)

    local fs = btn:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
    fs:SetAllPoints()
    fs:SetJustifyH("LEFT")
    fs:SetText(text)

    if chars and #chars > 0 then
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT")
            GameTooltip:AddLine(tooltipTitle, 1, 0.82, 0)
            for _, c in ipairs(chars) do
                local cc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[c.class]
                local r2, g2, b2 = cc and cc.r or 1, cc and cc.g or 1, cc and cc.b or 1
                local line
                if tooltipFmt == "no_realm" then
                    line = string.format("%s - %d", c.name or "?", c.level)
                elseif tooltipFmt == "no_level" then
                    line = string.format("%s - %s", c.name or "?", c.realm or "?")
                else
                    line = string.format("%s - %s (%d)", c.name or "?", c.realm or "?", c.level or 0)
                end
                GameTooltip:AddLine(line, r2, g2, b2)
            end
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
    end

    return btn
end

-------------------------------------------------------------------------------
-- Roster: Info sub-tab
-------------------------------------------------------------------------------

-- Helper: render a horizontal bar row.
--   opts: { label, valueText, value, maxValue, r, g, b, tooltipTitle, chars, iconText }
function EMRosterPageMixin:AddBarRow(content, y, opts)
    local BAR_W = 660
    local BAR_H = LINE_HEIGHT - 4
    local LABEL_PAD = 8

    local row = self:Track(CreateFrame("Button", nil, content))
    row:SetSize(BAR_W, LINE_HEIGHT)
    row:SetPoint("TOPLEFT", content, "TOPLEFT", 12, -y)

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -1)
    bg:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 1)
    bg:SetColorTexture(0.1, 0.1, 0.1, 0.5)

    local frac = (opts.maxValue and opts.maxValue > 0) and (opts.value / opts.maxValue) or 0
    local barWidth = math.max(2, math.floor(BAR_W * frac))
    local bar = row:CreateTexture(nil, "ARTWORK")
    bar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -1)
    bar:SetSize(barWidth, BAR_H)
    bar:SetColorTexture(1, 1, 1, 1)
    local br, bg2, bb = opts.r or 0.7, opts.g or 0.7, opts.b or 0.7
    bar:SetGradient(
        "VERTICAL",
        CreateColor(br * 0.7, bg2 * 0.7, bb * 0.7, 0.6),
        CreateColor(math.min(1, br * 1.1), math.min(1, bg2 * 1.1), math.min(1, bb * 1.1), 0.6)
    )

    local labelText = opts.iconText and (opts.iconText .. " " .. opts.label) or opts.label

    local fs = row:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
    fs:SetPoint("LEFT", row, "LEFT", LABEL_PAD, 1)
    fs:SetJustifyH("LEFT")
    fs:SetShadowColor(0, 0, 0, 1)
    fs:SetShadowOffset(1, -1)
    fs:SetAlpha(0.85)
    fs:SetText(string.format("|cffffffff%s|r", labelText))

    -- Value text rendered inside the filled bar (right-aligned at the fill's right
    -- edge). If the fill is too short to hold the text, it's placed just outside, to
    -- the right of the fill instead. Heavier shadow for readability over the bar.
    local valFs = row:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
    valFs:SetShadowColor(0, 0, 0, 1)
    valFs:SetShadowOffset(2, -2)
    valFs:SetText(string.format("|cffe8d9a8%s|r", opts.valueText or tostring(opts.value)))
    local textW = valFs:GetStringWidth()
    local labelEnd = LABEL_PAD + fs:GetStringWidth() + LABEL_PAD
    -- Fits inside the fill ONLY if the fill also clears the label (so right-aligned
    -- value text can't land on top of the label).
    if textW + LABEL_PAD * 2 <= barWidth and barWidth >= labelEnd + textW then
        valFs:SetJustifyH("RIGHT")
        valFs:SetPoint("RIGHT", bar, "RIGHT", -LABEL_PAD, 0)
    else
        -- Spill out to the right, left-justified, clearing BOTH the fill and the label.
        local startX = math.max(barWidth + LABEL_PAD, labelEnd)
        valFs:SetJustifyH("LEFT")
        valFs:SetPoint("LEFT", row, "LEFT", startX, 0)
    end

    if opts.chars and #opts.chars > 0 then
        local r, g, b = opts.r or 1, opts.g or 0.82, opts.b or 0
        local title = opts.tooltipTitle or opts.label
        local fmt = opts.tooltipFmt
        row:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT")
            GameTooltip:AddLine(title, r, g, b)
            for _, c in ipairs(opts.chars) do
                local cc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[c.class]
                local r2, g2, b2 = cc and cc.r or 1, cc and cc.g or 1, cc and cc.b or 1
                local line
                if fmt == "no_realm" then
                    line = string.format("%s - %d", c.name or "?", c.level)
                elseif fmt == "no_level" then
                    line = string.format("%s - %s", c.name or "?", c.realm or "?")
                else
                    line = string.format("%s - %s (%d)", c.name or "?", c.realm or "?", c.level or 0)
                end
                if c.played and c.played > 0 then
                    line = line .. " - |cffe8d9a8" .. (EmpireManager:FormatPlaytime(c.played) or "") .. "|r"
                end
                GameTooltip:AddLine(line, r2, g2, b2)
            end
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
    end

    return y + LINE_HEIGHT
end

local NEUTRAL_RACES = { Pandaren = true, Dracthyr = true, EarthenDwarf = true, Harronir = true }

-- "3 (25%)" for count-share bars. Drops the percent for zero counts (shows "0").
local function CountPct(count, total)
    if count <= 0 then
        return "0"
    end
    local pct = total > 0 and (count / total * 100) or 0
    return string.format("%d (%.0f%%)", count, pct)
end

function EMRosterPageMixin:BuildInfoContent(content, y)
    local MAX_LEVEL = GetMaxLevelForExpansionLevel(GetExpansionLevel())

    -- Gather stats
    local totalChars, totalPlayed, maxLevelChars = 0, 0, 0
    local maxLevelChars_list = {}
    local classData, raceData, factionData, realmData, guildData, profData = {}, {}, {}, {}, {}, {}

    local function addChar(tbl, key, ci)
        if not tbl[key] then
            tbl[key] = { count = 0, chars = {} }
        end
        tbl[key].count = tbl[key].count + 1
        tbl[key].chars[#tbl[key].chars + 1] = ci
    end

    local classPlayed = {}

    for _, entry in pairs(EmpireManager.db.global.registry) do
        totalChars = totalChars + 1
        totalPlayed = totalPlayed + (entry.playedTotal or 0)
        local ci = {
            name = entry.name or "?",
            level = entry.level or 0,
            realm = entry.realm or "?",
            class = entry.class or "UNKNOWN",
            played = entry.playedTotal or 0,
        }

        if ci.level >= MAX_LEVEL then
            maxLevelChars = maxLevelChars + 1
            maxLevelChars_list[#maxLevelChars_list + 1] = ci
        end

        local classKey = entry.class or "UNKNOWN"
        classPlayed[classKey] = (classPlayed[classKey] or 0) + (entry.playedTotal or 0)
        addChar(classData, classKey, ci)
        local raceKey = entry.race or "Unknown"
        raceKey = raceKey:gsub("[%s']", "") -- "Night Elf" → "NightElf", "Mag'har Orc" → "MagharOrc"
        if NEUTRAL_RACES[raceKey] and entry.faction then
            raceKey = raceKey .. "|" .. entry.faction
        end
        addChar(raceData, raceKey, ci)
        addChar(factionData, entry.faction or "Unknown", ci)
        addChar(realmData, entry.realm or "Unknown", ci)

        local guild = entry.guild
        if guild and guild ~= "" then
            addChar(guildData, guild, ci)
        else
            addChar(guildData, "Not in a Guild", ci)
        end

        if entry.professions then
            for _, prof in ipairs(entry.professions) do
                -- Key by profession KEY, not the localized name: prof.name is
                -- language-specific, so keying on it made every lookup below miss
                -- on non-English clients and every bar read 0.
                local pInfo = EmpireManager:ProfInfoFromEntryProf(prof)
                if pInfo then
                    addChar(
                        profData,
                        pInfo.key,
                        { name = ci.name, level = ci.level, realm = ci.realm, class = ci.class }
                    )
                end
            end
        end
    end

    local function sortChars(list)
        table.sort(list, function(a, b)
            return a.name < b.name
        end)
    end
    sortChars(maxLevelChars_list)
    for _, d in pairs(classData) do
        sortChars(d.chars)
    end
    for _, d in pairs(raceData) do
        sortChars(d.chars)
    end
    for _, d in pairs(factionData) do
        sortChars(d.chars)
    end
    for _, d in pairs(realmData) do
        sortChars(d.chars)
    end
    for _, d in pairs(guildData) do
        sortChars(d.chars)
    end
    for _, d in pairs(profData) do
        sortChars(d.chars)
    end

    -- Roster Overview
    y = self:AddHeading(content, y, "Roster Overview", true)

    -- Row 1: Total | Max Level | Gold
    local totalGold, _, warbandGold = EmpireManager:CalculateGrandTotals()
    local playedText = EmpireManager:FormatPlaytime(totalPlayed) or "0h 0m"
    local colW = 220

    -- Total Characters
    self:AddClickLabel(content, y, string.format("|cffe8d9a8Total Characters:|r  |cffffffff%d|r", totalChars), colW)
    self._flowX = colW
    self:AddClickLabel(
        content,
        y,
        string.format("|cffe8d9a8Max Level (%d):|r  |cff00cc00%d|r", MAX_LEVEL, maxLevelChars),
        colW,
        string.format("Max Level (%d)", MAX_LEVEL),
        maxLevelChars_list,
        "no_level"
    )
    self._flowX = colW * 2
    local goldText = string.format("|cffe8d9a8Gold:|r  |cffffff00%s|r", EmpireManager:FormatGold(totalGold))
    local goldBtn = self:AddClickLabel(content, y, goldText, colW)
    if warbandGold and warbandGold > 0 then
        local charGold = totalGold - warbandGold
        goldBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT")
            GameTooltip:AddLine("Gold", 1, 0.82, 0)
            GameTooltip:AddDoubleLine("Characters", EmpireManager:FormatGold(charGold), 1, 1, 1, 1, 1, 0)
            GameTooltip:AddDoubleLine("Warband Bank", EmpireManager:FormatGold(warbandGold), 1, 1, 1, 1, 1, 0)
            GameTooltip:Show()
        end)
        goldBtn:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
    end
    self._flowX = nil
    y = y + LINE_HEIGHT

    -- Row 2: /played
    self:AddClickLabel(content, y, string.format("|cffe8d9a8Total /played:|r  |cffffffff%s|r", playedText), colW * 2)
    y = y + LINE_HEIGHT + 4

    -- By Faction
    y = self:AddHeading(content, y, "Characters by Faction")
    local factionColors = { Alliance = { 0.2, 0.4, 1.0 }, Horde = { 0.8, 0.15, 0.15 } }
    local factionSorted = {}
    local factionMax = 0
    for faction, d in pairs(factionData) do
        factionSorted[#factionSorted + 1] = { faction = faction, count = d.count, chars = d.chars }
        if d.count > factionMax then
            factionMax = d.count
        end
    end
    table.sort(factionSorted, function(a, b)
        return a.count > b.count
    end)
    for _, data in ipairs(factionSorted) do
        local fc = factionColors[data.faction] or { 0.7, 0.7, 0.7 }
        y = self:AddBarRow(content, y, {
            label = data.faction,
            value = data.count,
            valueText = CountPct(data.count, totalChars),
            maxValue = factionMax,
            r = fc[1],
            g = fc[2],
            b = fc[3],
            tooltipTitle = data.faction,
            chars = data.chars,
            tooltipFmt = "full",
        })
    end
    y = y + 4

    -- By Guild
    y = self:AddHeading(content, y, "Characters by Guild")
    local guildSorted = {}
    local guildMax = 0
    for guild, d in pairs(guildData) do
        guildSorted[#guildSorted + 1] = { guild = guild, count = d.count, chars = d.chars }
        if d.count > guildMax then
            guildMax = d.count
        end
    end
    table.sort(guildSorted, function(a, b)
        if a.guild == "Not in a Guild" then
            return false
        end
        if b.guild == "Not in a Guild" then
            return true
        end
        return a.count > b.count
    end)
    local guildColors = { "44ddaa", "dd8844", "8899ee", "ddcc44", "cc66aa", "66ccdd", "aacc55", "cc7777" }
    local guildIdx = 0
    for _, data in ipairs(guildSorted) do
        local color
        if data.guild == "Not in a Guild" then
            color = "666666"
        else
            guildIdx = guildIdx + 1
            color = guildColors[((guildIdx - 1) % #guildColors) + 1]
        end
        local r = tonumber(color:sub(1, 2), 16) / 255
        local g = tonumber(color:sub(3, 4), 16) / 255
        local b = tonumber(color:sub(5, 6), 16) / 255
        y = self:AddBarRow(content, y, {
            label = data.guild,
            value = data.count,
            valueText = CountPct(data.count, totalChars),
            maxValue = guildMax,
            r = r,
            g = g,
            b = b,
            tooltipTitle = data.guild,
            chars = data.chars,
            tooltipFmt = "full",
        })
    end
    y = y + 4

    -- By Class
    y = self:AddHeading(content, y, "Characters by Class")
    -- Pre-seed every known class at 0 so they all render
    for classKey in pairs(EmpireManager.CLASS_NAMES) do
        if not classData[classKey] then
            classData[classKey] = { count = 0, chars = {} }
        end
    end
    local classSorted = {}
    local classMax = 0
    for class, d in pairs(classData) do
        classSorted[#classSorted + 1] = { class = class, count = d.count, chars = d.chars }
        if d.count > classMax then
            classMax = d.count
        end
    end
    table.sort(classSorted, function(a, b)
        return a.count > b.count
    end)
    for _, data in ipairs(classSorted) do
        local cc = RAID_CLASS_COLORS[data.class]
        local r, g, b = cc and cc.r or 0.7, cc and cc.g or 0.7, cc and cc.b or 0.7
        local displayName = EmpireManager.CLASS_NAMES[data.class] or data.class
        y = self:AddBarRow(content, y, {
            label = displayName,
            value = data.count,
            valueText = CountPct(data.count, totalChars),
            maxValue = classMax,
            r = r,
            g = g,
            b = b,
            tooltipTitle = displayName,
            chars = data.chars,
            tooltipFmt = "full",
        })
    end
    y = y + 4

    -- Played by Class (pre-seed every class so all render, even with 0 time)
    for classKey in pairs(EmpireManager.CLASS_NAMES) do
        if not classPlayed[classKey] then
            classPlayed[classKey] = 0
        end
    end
    local playedSorted = {}
    local maxPlayed = 0
    for class, secs in pairs(classPlayed) do
        playedSorted[#playedSorted + 1] =
            { class = class, secs = secs, chars = (classData[class] and classData[class].chars) or {} }
        if secs > maxPlayed then
            maxPlayed = secs
        end
    end
    table.sort(playedSorted, function(a, b)
        return a.secs > b.secs
    end)

    if #playedSorted > 0 then
        y = self:AddHeading(content, y, "Time Played by Class")
        for _, data in ipairs(playedSorted) do
            local cc = RAID_CLASS_COLORS[data.class]
            local r, g, b = cc and cc.r or 0.7, cc and cc.g or 0.7, cc and cc.b or 0.7
            local displayName = EmpireManager.CLASS_NAMES[data.class] or data.class
            local playedStr = EmpireManager:FormatPlaytime(data.secs) or "0h"
            local pct = totalPlayed > 0 and (data.secs / totalPlayed * 100) or 0
            if data.secs > 0 then
                playedStr = string.format("%s (%.0f%%)", playedStr, pct)
            end
            y = self:AddBarRow(content, y, {
                label = displayName,
                value = data.secs,
                valueText = playedStr,
                maxValue = maxPlayed,
                r = r,
                g = g,
                b = b,
                tooltipTitle = displayName,
                chars = data.chars,
                tooltipFmt = "full",
            })
        end
        y = y + 4
    end

    -- By Profession
    y = self:AddHeading(content, y, "Characters by Profession")
    local profSorted = {}
    local profMax = 0
    for _, pInfo in ipairs(EmpireManager.PROF_DISPLAY) do
        if pInfo.category ~= "secondary" then
            local pd = profData[pInfo.key] or { count = 0, chars = {} }
            profSorted[#profSorted + 1] = { info = pInfo, count = pd.count, chars = pd.chars }
            if pd.count > profMax then
                profMax = pd.count
            end
        end
    end
    table.sort(profSorted, function(a, b)
        return a.count > b.count
    end)
    for _, data in ipairs(profSorted) do
        local pInfo = data.info
        y = self:AddBarRow(content, y, {
            label = pInfo.label,
            value = data.count,
            valueText = tostring(data.count),
            maxValue = profMax,
            r = pInfo.r,
            g = pInfo.g,
            b = pInfo.b,
            iconText = string.format("|T%s:14:14|t", pInfo.icon),
            tooltipTitle = pInfo.label,
            chars = data.chars,
            tooltipFmt = "full",
        })
    end
    y = y + 4

    -- By Race
    y = self:AddHeading(content, y, "Characters by Race")
    -- Pre-seed every known race at 0 so they all render
    for raceKey in pairs(EmpireManager.RACE_NAMES) do
        if NEUTRAL_RACES[raceKey] then
            if not raceData[raceKey .. "|Alliance"] then
                raceData[raceKey .. "|Alliance"] = { count = 0, chars = {} }
            end
            if not raceData[raceKey .. "|Horde"] then
                raceData[raceKey .. "|Horde"] = { count = 0, chars = {} }
            end
        else
            if not raceData[raceKey] then
                raceData[raceKey] = { count = 0, chars = {} }
            end
        end
    end
    local raceSorted = {}
    local raceMax = 0
    for race, d in pairs(raceData) do
        raceSorted[#raceSorted + 1] = { race = race, count = d.count, chars = d.chars }
        if d.count > raceMax then
            raceMax = d.count
        end
    end
    table.sort(raceSorted, function(a, b)
        return a.count > b.count
    end)

    local RACE_NAMES = EmpireManager.RACE_NAMES
    local HORDE_RACES = {
        Orc = true,
        Troll = true,
        Tauren = true,
        Scourge = true,
        Undead = true,
        BloodElf = true,
        Goblin = true,
        Nightborne = true,
        HighmountainTauren = true,
        MagharOrc = true,
        ZandalariTroll = true,
        Vulpera = true,
    }
    local ALLIANCE_RACES = {
        Human = true,
        Dwarf = true,
        NightElf = true,
        Gnome = true,
        Draenei = true,
        Worgen = true,
        VoidElf = true,
        LightforgedDraenei = true,
        DarkIronDwarf = true,
        KulTiran = true,
        Mechagnome = true,
    }
    for _, data in ipairs(raceSorted) do
        local race, faction = data.race:match("^(.+)|(.+)$")
        if not race then
            race = data.race
        end
        local displayName = RACE_NAMES[race] or race
        local color
        if faction then
            displayName = displayName .. " (" .. faction .. ")"
            color = faction == "Horde" and "cc3333" or faction == "Alliance" and "3399ff" or "cc99ff"
        elseif HORDE_RACES[race] then
            color = "cc3333"
        elseif ALLIANCE_RACES[race] then
            color = "3399ff"
        else
            color = "cc99ff"
        end
        local r = tonumber(color:sub(1, 2), 16) / 255
        local g = tonumber(color:sub(3, 4), 16) / 255
        local b = tonumber(color:sub(5, 6), 16) / 255
        y = self:AddBarRow(content, y, {
            label = displayName,
            value = data.count,
            valueText = CountPct(data.count, totalChars),
            maxValue = raceMax,
            r = r,
            g = g,
            b = b,
            tooltipTitle = displayName,
            chars = data.chars,
            tooltipFmt = "full",
        })
    end
    y = y + 4

    -- By Realm
    y = self:AddHeading(content, y, "Characters by Realm")
    local realmSorted = {}
    local realmMax = 0
    for realm, d in pairs(realmData) do
        realmSorted[#realmSorted + 1] = { realm = realm, count = d.count, chars = d.chars }
        if d.count > realmMax then
            realmMax = d.count
        end
    end
    table.sort(realmSorted, function(a, b)
        return a.count > b.count
    end)
    local realmColors = { "55bbff", "ffaa33", "55dd77", "dd77cc", "bbbb44", "77cccc", "cc8855", "99aadd" }
    for idx, data in ipairs(realmSorted) do
        local rc = realmColors[((idx - 1) % #realmColors) + 1]
        local r = tonumber(rc:sub(1, 2), 16) / 255
        local g = tonumber(rc:sub(3, 4), 16) / 255
        local b = tonumber(rc:sub(5, 6), 16) / 255
        y = self:AddBarRow(content, y, {
            label = data.realm,
            value = data.count,
            valueText = CountPct(data.count, totalChars),
            maxValue = realmMax,
            r = r,
            g = g,
            b = b,
            tooltipTitle = data.realm,
            chars = data.chars,
            tooltipFmt = "no_realm",
        })
    end

    return y
end

-------------------------------------------------------------------------------
-- Roster: Professions sub-tab
-------------------------------------------------------------------------------

-- Lookup: expansion label OR apiName (lowercased) -> { id, label }. apiName is
-- what C_TradeSkillUI returns (e.g. "Outland", "Northrend", "Kul Tiran",
-- "Dragon Isles"); label is the display name. Both keys map to the same entry
-- so we can sort by id and re-label the API name when rendering tooltips.
local EXPANSION_LOOKUP = {}
local EXPANSION_ENTRY_BY_ID = {}
for _, info in ipairs(EmpireManager.EXPANSION_DISPLAY) do
    local entry = { id = info.expansionID, label = info.label }
    EXPANSION_LOOKUP[info.label:lower()] = entry
    EXPANSION_ENTRY_BY_ID[info.expansionID] = entry
    if info.apiNames then
        for _, n in ipairs(info.apiNames) do
            EXPANSION_LOOKUP[n:lower()] = entry
        end
    end
end
-- Localized API names (e.g. deDE "Dracheninseln") so a non-English client's stored
-- expansionName still re-labels to the English display label instead of rendering raw.
for lname, id in pairs(EmpireManager.EXPANSION_API_NAME_TO_ID or {}) do
    if EXPANSION_ENTRY_BY_ID[id] and not EXPANSION_LOOKUP[lname] then
        EXPANSION_LOOKUP[lname] = EXPANSION_ENTRY_BY_ID[id]
    end
end
local EXPANSION_ID_BY_LABEL = {}
for k, v in pairs(EXPANSION_LOOKUP) do
    EXPANSION_ID_BY_LABEL[k] = v.id
end

-- Return a numeric expansion order for an `expansionSkills` entry. Unknown names sort last.
local function ExpansionOrder(expEntry, fallbackIndex)
    if not expEntry or not expEntry.expansionName then
        return 1000 + (fallbackIndex or 0)
    end
    return EXPANSION_ID_BY_LABEL[expEntry.expansionName:lower()] or (1000 + (fallbackIndex or 0))
end

-- Return the skill in the latest expansion this character has data for, in a given profession.
-- profKey is a PROF_DISPLAY key, not a localized name - resolve each stored row
-- through ProfInfoFromEntryProf so this works on any client language.
local function GetLatestExpansionSkill(entry, profKey)
    if not entry.professions then
        return 0
    end
    for _, p in ipairs(entry.professions) do
        local pi = EmpireManager:ProfInfoFromEntryProf(p)
        if pi and pi.key == profKey then
            if p.expansionSkills and #p.expansionSkills > 0 then
                local bestOrder, bestSkill = -1, 0
                for i, exp in ipairs(p.expansionSkills) do
                    -- Ignore rows older builds stored wrongly (base-profession totals),
                    -- otherwise the aggregate 300/700 would win as "latest".
                    if not EmpireManager:IsBogusExpansionSkillRow(exp) then
                        local order = ExpansionOrder(exp, i)
                        if order > bestOrder then
                            bestOrder = order
                            bestSkill = exp.skill or 0
                        end
                    end
                end
                if bestOrder >= 0 then
                    return bestSkill
                end
            end
            return p.skill or 0
        end
    end
    return 0
end

-- Render the "Storage: ..." line and combined fill bar for a profession/category.
-- Returns new y. No-op (returns y unchanged) when profAssignments is empty.
function EMRosterPageMixin:RenderStorageSection(content, y, profAssignments)
    if #profAssignments == 0 then
        return y
    end

    -- Build subcat suffix for assignments belonging to a category that has
    -- subcategories defined (equipment_boe/boa, recipes, consumables).
    -- Professions don't have subcats so this is a no-op there.
    local function subcatSuffix(asn)
        if not (asn.subcategories and #asn.subcategories > 0) then
            return ""
        end
        local subcatDef = EmpireManager.SUBCATEGORY_DISPLAY[asn.profession]
        if not subcatDef then
            return ""
        end
        local labels = {}
        for _, sc in ipairs(asn.subcategories) do
            for _, def in ipairs(subcatDef.items) do
                if def.key == sc then
                    labels[#labels + 1] = def.label
                    break
                end
            end
        end
        if #labels == 0 then
            return ""
        end
        return " |cffe0d4a8(" .. table.concat(labels, ", ") .. ")|r"
    end

    local parts = {}
    for _, asn in ipairs(profAssignments) do
        local tabStr = ""
        if asn.tabs and #asn.tabs > 0 then
            tabStr = #asn.tabs == 1 and (" Tab " .. asn.tabs[1]) or (" Tabs " .. table.concat(asn.tabs, ","))
        end
        local sub = subcatSuffix(asn)
        if asn.type == "warbandbank" then
            parts[#parts + 1] = "|cff66b3ffWarband|r Bank" .. tabStr .. sub
        elseif asn.type == "guildbank" then
            local guildPrefix = (asn.guild and asn.guild ~= "") and ("|cff40ff40" .. asn.guild .. "|r ") or ""
            parts[#parts + 1] = guildPrefix .. "|cff40ff40Guild|r Bank" .. tabStr .. sub
        elseif asn.type == "charbank" then
            local charName = "?"
            if asn.char then
                local e = EmpireManager.db.global.registry[asn.char]
                if e then
                    charName = EmpireManager:ClassColoredName(e)
                end
            end
            parts[#parts + 1] = charName .. " Bank" .. tabStr .. sub
        end
    end
    local ROW_H = 24
    local LABEL_COL_W = 64
    local TEXT_TOP_PAD = 5
    local cw = content:GetWidth()
    local totalW = (cw > 20 and cw or 740) - 20

    local row = self:Track(CreateFrame("Frame", nil, content))
    row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
    row:SetSize(totalW, ROW_H)

    local labelFS = row:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
    labelFS:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -TEXT_TOP_PAD)
    labelFS:SetWidth(LABEL_COL_W)
    labelFS:SetJustifyH("RIGHT")
    labelFS:SetJustifyV("TOP")
    labelFS:SetWordWrap(false)
    labelFS:SetText("|cffdaa520Storage:|r")

    local fs = row:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
    fs:SetPoint("TOPLEFT", labelFS, "TOPRIGHT", 6, 0)
    fs:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    fs:SetWordWrap(true)
    fs:SetSpacing(6)
    fs:SetText(table.concat(parts, ", "))

    local contentH = math.max(fs:GetStringHeight(), labelFS:GetStringHeight())
    local finalH = math.max(ROW_H, contentH + TEXT_TOP_PAD + 6)
    row:SetHeight(finalH)
    y = y + finalH

    local cap = EmpireManager.db.global.storageCapacity or {}
    local totalSum, usedSum = 0, 0
    for _, asn in ipairs(profAssignments) do
        local capSection
        if asn.type == "warbandbank" then
            capSection = cap.warbandbank
        elseif asn.type == "guildbank" and asn.guild then
            local key = EmpireManager:GuildKey(asn.guild, asn.realm)
            capSection = key and cap.guildbank and cap.guildbank[key]
        elseif asn.type == "charbank" and asn.char then
            capSection = cap.charbank and cap.charbank[asn.char]
        end
        local agg = AggregateCapacity(capSection, asn.tabs)
        if agg then
            totalSum = totalSum + agg.total
            usedSum = usedSum + agg.used
        end
    end
    if totalSum > 0 then
        local pct = usedSum / totalSum
        local free = totalSum - usedSum
        y = self:DrawFillBar(content, nil, y, pct, usedSum, totalSum, free) + 2
    end

    return y
end

function EMRosterPageMixin:BuildDeptContent(content, y)
    local assignments = EmpireManager.db.global.storageAssignments or {}

    local firstProf = true
    for _, info in ipairs(EmpireManager.PROF_DISPLAY) do
        local isSecondary = info.category == "secondary"
        local profKey = info.key
        y = self:AddHeading(
            content,
            y,
            string.format(
                "|T%s:16:16|t |cff%02x%02x%02x%s|r",
                info.icon,
                info.r * 255,
                info.g * 255,
                info.b * 255,
                info.label
            ),
            firstProf
        )
        firstProf = false

        -- Collect members and capture each member's latest-expansion skill (for sorting).
        local members = {}
        for guid, entry in pairs(EmpireManager.db.global.registry) do
            local skill = GetLatestExpansionSkill(entry, info.key)
            if EmpireManager:HasProfessionRole(entry, profKey) or skill > 0 then
                members[#members + 1] = { guid = guid, entry = entry, skill = skill }
            end
        end
        -- Highest skill first; tie-break alphabetically by name.
        table.sort(members, function(a, b)
            if a.skill ~= b.skill then
                return a.skill > b.skill
            end
            return (a.entry.name or ""):lower() < (b.entry.name or ""):lower()
        end)

        local profAssignments = {}
        for _, asn in ipairs(assignments) do
            if asn.profession == profKey then
                profAssignments[#profAssignments + 1] = asn
            end
        end

        y = self:RenderStorageSection(content, y, profAssignments)

        if isSecondary then -- luacheck: ignore 542
        elseif #members > 0 then
            local colW = 160
            local colCount = 0
            for _, m in ipairs(members) do
                local btn = self:Track(CreateFrame("Button", nil, content))
                btn:SetSize(colW, LINE_HEIGHT)
                btn:SetPoint("TOPLEFT", content, "TOPLEFT", 12 + (colCount % 3) * colW, -y)
                local fs = btn:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
                fs:SetAllPoints()
                fs:SetJustifyH("LEFT")
                local nameText = EmpireManager:ClassColoredName(m.entry)
                if m.skill > 0 then
                    nameText = nameText .. string.format(" (%d)", m.skill)
                end
                fs:SetText(nameText)

                local cGuid, cEntry, memberProfKey = m.guid, m.entry, info.key
                btn:SetScript("OnClick", function()
                    EmpireManager:OpenSidecar(cGuid)
                end)
                btn:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT")
                    local cc = RAID_CLASS_COLORS[cEntry.class or ""] or NORMAL_FONT_COLOR
                    GameTooltip:AddLine(
                        string.format("%s - %s (%d)", cEntry.name or "?", cEntry.realm or "?", cEntry.level or 0),
                        cc.r,
                        cc.g,
                        cc.b
                    )
                    if cEntry.professions then
                        for _, p in ipairs(cEntry.professions) do
                            local ppi = EmpireManager:ProfInfoFromEntryProf(p)
                            if ppi and ppi.key == memberProfKey and p.expansionSkills then
                                -- Dedupe by expansion. Prefer numeric expansionID
                                -- (locale-proof, written by SnapshotExpansionSkills).
                                -- Fall back to label lookup for legacy/import data.
                                local byKey = {}
                                for _, exp in ipairs(p.expansionSkills) do
                                    local lookup = exp.expansionName and EXPANSION_LOOKUP[exp.expansionName:lower()]
                                        or nil
                                    local id = exp.expansionID or (lookup and lookup.id)
                                    local displayName = (lookup and lookup.label) or exp.expansionName
                                    -- Drop rows older builds stored wrongly (base-profession
                                    -- aggregates in any locale). No DB migration needed.
                                    if EmpireManager:IsBogusExpansionSkillRow(exp) then
                                        displayName = nil
                                    end
                                    if displayName and displayName ~= "" and displayName:lower() ~= "unknown" then
                                        local key = id or ("name:" .. displayName:lower())
                                        local existing = byKey[key]
                                        if not existing or (exp.skill or 0) > (existing.skill or 0) then
                                            byKey[key] = {
                                                expansionID = id,
                                                expansionName = displayName,
                                                skill = exp.skill,
                                                maxSkill = exp.maxSkill,
                                            }
                                        end
                                    end
                                end
                                local sorted = {}
                                for _, exp in pairs(byKey) do
                                    local order = exp.expansionID or ExpansionOrder(exp, 0)
                                    sorted[#sorted + 1] = { exp = exp, order = order }
                                end
                                table.sort(sorted, function(a, b)
                                    return a.order < b.order
                                end)
                                for _, e in ipairs(sorted) do
                                    GameTooltip:AddDoubleLine(
                                        string.format("  %s", e.exp.expansionName),
                                        string.format("%d / %d", e.exp.skill, e.exp.maxSkill),
                                        1,
                                        1,
                                        1,
                                        1,
                                        1,
                                        1
                                    )
                                end
                            end
                        end
                    end
                    GameTooltip:AddLine(" ")
                    if cEntry.totalBankSlots and cEntry.totalBankSlots > 0 then
                        local total = cEntry.totalBankSlots
                        local free = cEntry.freeBankSlots or 0
                        local used = total - free
                        local pct = math.floor((used / total) * 100 + 0.5)
                        GameTooltip:AddLine(string.format("Bank: %d/%d (%d%%)", used, total, pct), 1, 0.82, 0)
                    else
                        GameTooltip:AddLine("Bank: no data", 1, 0.82, 0)
                    end
                    GameTooltip:Show()
                end)
                btn:SetScript("OnLeave", function()
                    GameTooltip:Hide()
                end)

                colCount = colCount + 1
                if colCount % 3 == 0 then
                    y = y + LINE_HEIGHT
                end
            end
            if colCount % 3 ~= 0 then
                y = y + LINE_HEIGHT
            end
        else
            local fs = self:Track(content:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
            fs:SetPoint("TOPLEFT", content, "TOPLEFT", 12, -y)
            fs:SetText("|cff999999No members|r")
            y = y + LINE_HEIGHT
        end
        y = y + 4
    end

    return y
end

-------------------------------------------------------------------------------
-- Roster: Categories sub-tab (non-profession storage targets)
-------------------------------------------------------------------------------

function EMRosterPageMixin:BuildCategoriesContent(content, y)
    local assignments = EmpireManager.db.global.storageAssignments or {}

    local firstCat = true
    for _, info in ipairs(EmpireManager.STORAGE_CATEGORY_DISPLAY) do
        local catKey = info.key
        y = self:AddHeading(
            content,
            y,
            string.format(
                "|T%s:16:16|t |cff%02x%02x%02x%s|r",
                info.icon,
                info.r * 255,
                info.g * 255,
                info.b * 255,
                info.label
            ),
            firstCat
        )
        firstCat = false

        local catAssignments = {}
        for _, asn in ipairs(assignments) do
            if asn.profession == catKey then
                catAssignments[#catAssignments + 1] = asn
            end
        end

        if #catAssignments > 0 then
            y = self:RenderStorageSection(content, y, catAssignments)
        else
            local fs = self:Track(content:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
            fs:SetPoint("TOPLEFT", content, "TOPLEFT", 12, -y)
            fs:SetText("|cff999999No storage assigned|r")
            y = y + LINE_HEIGHT
        end
        y = y + 4
    end

    return y
end

-------------------------------------------------------------------------------
-- Roster: Roles sub-tab
-------------------------------------------------------------------------------

function EMRosterPageMixin:BuildRoleContent(content, y)
    local ICON16_FMT = EmpireManager.ICON16_FMT

    local firstRole = true
    for _, display in ipairs(EmpireManager.ROLE_DISPLAY) do
        local roleKey = display.key
        local roleColor = string.format("|cff%02x%02x%02x", display.r * 255, display.g * 255, display.b * 255)

        local members = {}
        for guid, entry in pairs(EmpireManager.db.global.registry) do
            if EmpireManager:HasRole(entry, roleKey) then
                members[#members + 1] = { guid = guid, entry = entry }
            end
        end
        table.sort(members, function(a, b)
            return (a.entry.name or ""):lower() < (b.entry.name or ""):lower()
        end)

        local headingFS
        y, headingFS = self:AddHeading(
            content,
            y,
            string.format("%s" .. ICON16_FMT .. " (%d)|r", roleColor, display.icon, display.label or roleKey, #members),
            firstRole
        )
        firstRole = false

        -- Tooltip (reused from sidecar role-checkbox tooltips)
        local tipText = EmpireManager.ROLE_TOOLTIPS and EmpireManager.ROLE_TOOLTIPS[roleKey]
        if tipText and headingFS then
            local hitRect = self:Track(CreateFrame("Frame", nil, content))
            hitRect:SetAllPoints(headingFS)
            local roleLabel = display.label or roleKey
            hitRect:SetScript("OnEnter", function(f)
                GameTooltip:SetOwner(f, "ANCHOR_CURSOR_RIGHT")
                GameTooltip:AddLine(roleLabel, 1, 0.82, 0)
                GameTooltip:AddLine(" ")
                for line in tipText:gmatch("[^\n]+") do
                    GameTooltip:AddLine(line, 1, 1, 1, true)
                end
                GameTooltip:Show()
            end)
            hitRect:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)
        end

        if #members > 0 then
            local colW = 160
            local maxCols = 4
            local colCount = 0
            for _, m in ipairs(members) do
                local nameText = EmpireManager:ClassColoredName(m.entry)
                if display.profType and m.entry.assignments and m.entry.assignments[roleKey] then
                    local tags = {}
                    for _, pInfo in ipairs(EmpireManager.PROF_DISPLAY) do
                        if m.entry.assignments[roleKey][pInfo.key] then
                            tags[#tags + 1] = string.format("|T%s:14:14|t", pInfo.icon)
                        end
                    end
                    if #tags > 0 then
                        -- 8px transparent spacer between name and profession icons
                        local spacer = "|TInterface\\Common\\Spacer:1:8:0:0:1:1:0:1:0:1|t"
                        nameText = nameText .. spacer .. table.concat(tags, "")
                    end
                end

                local btn = self:Track(CreateFrame("Button", nil, content))
                btn:SetSize(colW, LINE_HEIGHT)
                btn:SetPoint("TOPLEFT", content, "TOPLEFT", 12 + (colCount % maxCols) * colW, -y)
                local fs = btn:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
                fs:SetAllPoints()
                fs:SetJustifyH("LEFT")
                fs:SetText(nameText)

                local cGuid, cEntry = m.guid, m.entry
                btn:SetScript("OnClick", function()
                    EmpireManager:OpenSidecar(cGuid)
                end)
                btn:SetScript("OnEnter", function(self)
                    EmpireManager:ShowNameTooltip({ frame = self }, cEntry, "ANCHOR_CURSOR_RIGHT")
                end)
                btn:SetScript("OnLeave", function()
                    GameTooltip:Hide()
                end)

                colCount = colCount + 1
                if colCount % maxCols == 0 then
                    y = y + LINE_HEIGHT
                end
            end
            if colCount % maxCols ~= 0 then
                y = y + LINE_HEIGHT
            end
        else
            local fs = self:Track(content:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
            fs:SetPoint("TOPLEFT", content, "TOPLEFT", 12, -y)
            fs:SetText("|cff555555None|r")
            y = y + LINE_HEIGHT
        end
        y = y + 4
    end

    -- Unassigned
    y = self:AddHeading(content, y, "|cff888888Unassigned|r")
    local unassigned = {}
    for guid, entry in pairs(EmpireManager.db.global.registry) do
        if not entry.assignments or not next(entry.assignments) then
            unassigned[#unassigned + 1] = { guid = guid, entry = entry }
        end
    end
    table.sort(unassigned, function(a, b)
        return (a.entry.name or ""):lower() < (b.entry.name or ""):lower()
    end)

    if #unassigned > 0 then
        local colW = 160
        local colCount = 0
        for _, m in ipairs(unassigned) do
            local btn = self:Track(CreateFrame("Button", nil, content))
            btn:SetSize(colW, LINE_HEIGHT)
            btn:SetPoint("TOPLEFT", content, "TOPLEFT", 12 + (colCount % 3) * colW, -y)
            local fs = btn:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
            fs:SetAllPoints()
            fs:SetJustifyH("LEFT")
            fs:SetText(EmpireManager:ClassColoredName(m.entry))

            local cGuid, cEntry = m.guid, m.entry
            btn:SetScript("OnClick", function()
                EmpireManager:OpenSidecar(cGuid)
            end)
            btn:SetScript("OnEnter", function(self)
                EmpireManager:ShowNameTooltip({ frame = self }, cEntry, "ANCHOR_CURSOR_RIGHT")
            end)
            btn:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)

            colCount = colCount + 1
            if colCount % 3 == 0 then
                y = y + LINE_HEIGHT
            end
        end
        if colCount % 3 ~= 0 then
            y = y + LINE_HEIGHT
        end
    else
        local fs = self:Track(content:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
        fs:SetPoint("TOPLEFT", content, "TOPLEFT", 12, -y)
        fs:SetText("|cff555555(all characters assigned)|r")
        y = y + LINE_HEIGHT
    end

    return y
end

-------------------------------------------------------------------------------
-- Roster: Banks sub-tab
-------------------------------------------------------------------------------

function EMRosterPageMixin:BuildBankContent(content, y)
    local assignments = EmpireManager.db.global.storageAssignments or {}
    local cap = EmpireManager.db.global.storageCapacity or {}

    local function CharBankLabel(charEntry)
        local base = EmpireManager:ClassColoredName(charEntry)
        local realm = charEntry.realm
        if not realm or realm == "" then
            return base
        end
        local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[charEntry.class]
        if color then
            return base .. color:WrapTextInColorCode(" - " .. realm)
        end
        return base .. " - " .. realm
    end

    -- Group assignments by bank destination
    local bankOrder, bankMap = {}, {}
    for _, asn in ipairs(assignments) do
        local bankKey, bankLabel, capSection
        if asn.type == "warbandbank" then
            bankKey = "warbandbank"
            bankLabel = "Warband Bank"
            capSection = cap.warbandbank
        elseif asn.type == "guildbank" then
            local guild = asn.guild or "Unknown Guild"
            local realm = asn.realm or ""
            if EmpireManager:IsGuildBlacklisted(guild, realm) then
                bankKey = nil
            else
                bankKey = "guildbank:" .. guild .. "\1" .. realm
                bankLabel = guild .. " Guild Bank"
                local key = EmpireManager:GuildKey(asn.guild, asn.realm)
                capSection = key and cap.guildbank and cap.guildbank[key]
            end
        elseif asn.type == "charbank" then
            local charEntry = asn.char and EmpireManager.db.global.registry[asn.char]
            if charEntry then
                bankKey = "charbank:" .. asn.char
                bankLabel = CharBankLabel(charEntry)
                capSection = cap.charbank and cap.charbank[asn.char]
            end
        end
        if bankKey then
            if not bankMap[bankKey] then
                bankMap[bankKey] = {
                    label = bankLabel,
                    assignments = {},
                    capSection = capSection,
                    charGuid = (asn.type == "charbank") and asn.char or nil,
                    charEntry = (asn.type == "charbank") and EmpireManager.db.global.registry[asn.char] or nil,
                }
                bankOrder[#bankOrder + 1] = bankKey
            end
            bankMap[bankKey].assignments[#bankMap[bankKey].assignments + 1] = asn
        end
    end

    -- Also include banks we've snapshotted even if no rules reference them yet
    if cap.warbandbank and next(cap.warbandbank) and not bankMap["warbandbank"] then
        bankMap["warbandbank"] = { label = "Warband Bank", assignments = {}, capSection = cap.warbandbank }
        bankOrder[#bankOrder + 1] = "warbandbank"
    end
    if cap.charbank then
        for charGuid, section in pairs(cap.charbank) do
            local key = "charbank:" .. charGuid
            if not bankMap[key] then
                local charEntry = EmpireManager.db.global.registry[charGuid]
                if charEntry then
                    bankMap[key] = {
                        label = CharBankLabel(charEntry),
                        assignments = {},
                        capSection = section,
                        charGuid = charGuid,
                        charEntry = charEntry,
                    }
                    bankOrder[#bankOrder + 1] = key
                end
            end
        end
    end
    if cap.guildbank then
        -- cap.guildbank keys are "GuildName-Realm" composites. Realm names CAN
        -- contain "-" (e.g. "Azjol-Nerub"), so we can't reliably regex-split.
        -- Instead, match each composite against the registry's known
        -- (guild, guildRealm) pairs.
        local knownPairs = {}
        for _, entry in pairs(EmpireManager.db.global.registry or {}) do
            if entry.guild and entry.guild ~= "" and entry.guildRealm and entry.guildRealm ~= "" then
                knownPairs[entry.guild .. "-" .. entry.guildRealm] = { entry.guild, entry.guildRealm }
            end
        end
        for composite, section in pairs(cap.guildbank) do
            local pair = knownPairs[composite]
            local guildName, realm
            if pair then
                guildName, realm = pair[1], pair[2]
            else
                guildName, realm = composite:match("^(.+)-([^-]+)$")
                guildName = guildName or composite
                realm = realm or ""
            end
            local key = "guildbank:" .. guildName .. "\1" .. realm
            if not bankMap[key] and not EmpireManager:IsGuildBlacklisted(guildName, realm) then
                bankMap[key] = {
                    label = guildName .. " Guild Bank",
                    assignments = {},
                    capSection = section,
                }
                bankOrder[#bankOrder + 1] = key
            end
        end
    end

    if #bankOrder == 0 then
        local fs = self:Track(content:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
        fs:SetPoint("TOPLEFT", content, "TOPLEFT", 12, -y)
        fs:SetText("No bank data yet. Open a bank on any character to record capacity.")
        return y + LINE_HEIGHT
    end

    local typePriority = { warbandbank = 1, guildbank = 2, charbank = 3 }
    table.sort(bankOrder, function(a, b)
        local pa = typePriority[a:match("^(%w+)")] or 9
        local pb = typePriority[b:match("^(%w+)")] or 9
        if pa ~= pb then
            return pa < pb
        end
        -- Within the same type, banks WITH rules come before banks without.
        local ruledA = (#bankMap[a].assignments > 0) and 0 or 1
        local ruledB = (#bankMap[b].assignments > 0) and 0 or 1
        if ruledA ~= ruledB then
            return ruledA < ruledB
        end
        return a < b
    end)

    local drawFillBar = function(anchorFS, y, pct, used, total, free, scannedAt)
        return self:DrawFillBar(content, anchorFS, y, pct, used, total, free, scannedAt)
    end

    -- Pre-compute the aggregate capacity across all charbanks so we can show a summary
    -- line above the individual charbank entries. Oldest snapshot wins (worst-case signal).
    local charTotal, charUsed = 0, 0
    local oldestCharScannedAt
    for _, bankKey in ipairs(bankOrder) do
        if bankKey:match("^charbank") then
            local capSection = bankMap[bankKey].capSection
            local agg = AggregateCapacity(capSection, nil)
            if agg then
                charTotal = charTotal + agg.total
                charUsed = charUsed + agg.used
            end
            local sa = capSection and capSection._scannedAt
            if sa and (not oldestCharScannedAt or sa < oldestCharScannedAt) then
                oldestCharScannedAt = sa
            end
        end
    end

    -- Draw a divider only when the bank type changes (e.g., warband→guild, guild→charbank).
    -- Within a type group (especially charbanks), headings flow without a separator.
    local prevType = nil
    local charSummaryDrawn = false
    for _, bankKey in ipairs(bankOrder) do
        local bank = bankMap[bankKey]
        local bankType = bankKey:match("^(%w+)")

        local skipDivider = (prevType == nil)

        -- Insert the "Character Banks" summary above the first charbank entry
        if bankType == "charbank" and not charSummaryDrawn then
            local sumHeadingFS
            y, sumHeadingFS = self:AddHeading(content, y, "All Character Banks", skipDivider)
            charSummaryDrawn = true

            if charTotal > 0 then
                local pct = charUsed / charTotal
                local free = charTotal - charUsed
                y = drawFillBar(sumHeadingFS, y, pct, charUsed, charTotal, free, oldestCharScannedAt)
            end
            -- First charbank below still gets its own divider as a separator after the summary
            skipDivider = false
        end

        local headingFS
        y, headingFS = self:AddHeading(content, y, bank.label, skipDivider)
        prevType = bankType

        -- Charbank headers are clickable - open sidecar for that character
        if bank.charGuid and bank.charEntry then
            local btn = self:Track(CreateFrame("Button", nil, content))
            btn:SetAllPoints(headingFS)
            local cGuid = bank.charGuid
            btn:SetScript("OnClick", function()
                EmpireManager:OpenSidecar(cGuid)
            end)
        end

        -- Aggregate capacity across all tabs for this bank (uses AggregateCapacity helper)
        local agg = AggregateCapacity(bank.capSection, nil)

        if agg then
            local pct = agg.used / agg.total
            local free = agg.total - agg.used
            y = drawFillBar(headingFS, y, pct, agg.used, agg.total, free, bank.capSection and bank.capSection._scannedAt)
        else
            local val = self:Track(content:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
            val:SetPoint("TOPLEFT", headingFS, "BOTTOMLEFT", 0, -2)
            val:SetText("No data")
            val:SetTextColor(0.5, 0.5, 0.5)
            y = y + LINE_HEIGHT
        end

        local tabMap, anyTab = {}, {}
        for _, asn in ipairs(bank.assignments) do
            local profInfo = EmpireManager.PROF_INFO_BY_KEY[asn.profession]
            local catEntry = { profession = asn.profession, info = profInfo, expansions = asn.expansions }
            if asn.tabs and #asn.tabs > 0 then
                for _, tabNum in ipairs(asn.tabs) do
                    if not tabMap[tabNum] then
                        tabMap[tabNum] = {}
                    end
                    tabMap[tabNum][#tabMap[tabNum] + 1] = catEntry
                end
            else
                anyTab[#anyTab + 1] = catEntry
            end
        end

        local function renderTabRow(labelText, cats, tabCap)
            local parts = {}
            for _, cat in ipairs(cats) do
                local text
                if cat.info then
                    text = string.format(
                        "|cff%02x%02x%02x%s|r",
                        cat.info.r * 255,
                        cat.info.g * 255,
                        cat.info.b * 255,
                        cat.info.label
                    )
                else
                    text = cat.profession
                end
                if cat.expansions and #cat.expansions > 0 then
                    for _, eid in ipairs(cat.expansions) do
                        for _, expInfo in ipairs(EmpireManager.EXPANSION_DISPLAY) do
                            if expInfo.expansionID == eid then
                                text = text .. " " .. EmpireManager:ExpIconString(expInfo, 6)
                                break
                            end
                        end
                    end
                end
                parts[#parts + 1] = text
            end
            local ROW_H = 24
            local LABEL_COL_W = 64
            local TEXT_TOP_PAD = 5
            local cw = content:GetWidth()
            local totalW = (cw > 20 and cw or 740) - 20

            local row = self:Track(CreateFrame("Frame", nil, content))
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
            row:SetSize(totalW, ROW_H)

            local labelFS = row:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
            labelFS:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -TEXT_TOP_PAD)
            labelFS:SetWidth(LABEL_COL_W)
            labelFS:SetJustifyH("RIGHT")
            labelFS:SetJustifyV("TOP")
            labelFS:SetWordWrap(false)
            labelFS:SetText(labelText)

            if tabCap and tabCap.total and tabCap.total > 0 then
                local pct = math.floor((tabCap.used / tabCap.total) * 100)
                local r, g, b
                if pct >= 85 then
                    r, g, b = 1.0, 0.2, 0.2
                elseif pct >= 60 then
                    r, g, b = 1.0, 0.8, 0.0
                else
                    r, g, b = 0.0, 0.8, 0.0
                end
                row:EnableMouse(true)
                local tabLabelClean = labelText:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub(":%s*$", "")
                local catsText = table.concat(parts, ", ")
                local slotsText = string.format("Slots: %d/%d (%d%%), %d free", tabCap.used, tabCap.total, pct, tabCap.total - tabCap.used)
                row:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT")
                    GameTooltip:AddLine(bank.label, 1, 0.82, 0)
                    GameTooltip:AddLine(tabLabelClean, 1, 1, 1)
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine(catsText, 1, 1, 1, true)
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine(slotsText, r, g, b)
                    GameTooltip:Show()
                end)
                row:SetScript("OnLeave", function()
                    GameTooltip:Hide()
                end)
            end

            local fs = row:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
            fs:SetPoint("TOPLEFT", labelFS, "TOPRIGHT", 6, 0)
            fs:SetPoint("RIGHT", row, "RIGHT", 0, 0)
            fs:SetJustifyH("LEFT")
            fs:SetJustifyV("TOP")
            fs:SetWordWrap(true)
            fs:SetText(table.concat(parts, ", "))

            local contentH = math.max(fs:GetStringHeight(), labelFS:GetStringHeight())
            local finalH = math.max(ROW_H, contentH + TEXT_TOP_PAD + 2)
            row:SetHeight(finalH)
            y = y + finalH
        end

        if #anyTab > 0 then
            renderTabRow("|cffdaa520Any Tab:|r", anyTab, nil)
        end
        local tabNums = {}
        for t in pairs(tabMap) do
            tabNums[#tabNums + 1] = t
        end
        table.sort(tabNums)
        for _, tabNum in ipairs(tabNums) do
            local tabCap = bank.capSection and bank.capSection[tabNum]
            renderTabRow("|cffdaa520Tab " .. tabNum .. ":|r", tabMap[tabNum], tabCap)
        end
    end

    return y
end

-------------------------------------------------------------------------------
-- STORAGE PAGE MIXIN
-------------------------------------------------------------------------------

local NO_EXPANSION_FILTER = { pets = true }

-- Storage column layout
local STORAGE_COLUMNS = {
    { key = "reorder", width = 60, label = "" },
    { key = "category", width = 148, label = "Category" },
    { key = "fill", width = 120, label = "Fill Level" },
    { key = "dest", width = 0, label = "Destination", fill = true },
}
local STORAGE_ROW_HEIGHT = 24

-------------------------------------------------------------------------------
-- Helpers (file-local)
-------------------------------------------------------------------------------

-- Empty band kept above the first row / below the last one so the first and last
-- slots stay reachable for drag-to-reorder.
local LIST_END_DROP_ZONE = 8

-- Drag-to-reorder for a single-column, one-row-per-item ScrollBox whose order is
-- meaningful (Storage rules, Restock rules) - the same family as the character-select
-- list. The default init wires up the drag cursor + drop-line previews; SetReorderable
-- turns a drop into a real reorder of the data provider; the pure-insertion predicate
-- forbids the default "Inside = swap" so a drop always inserts above/below a neighbour.
-- SetPostDrop reads the new order back out of the provider and commits it via opts,
-- then repaints.
--
-- opts.entryType    - elementData.type marking a draggable row ("rule" / "entry")
-- opts.entryKey     - elementData field holding the backing item (".asn" / ".entry")
-- opts.listKey      - db.global key of the ordered array to rewrite
-- opts.rowHeight    - row extent, used to size the insert hit-band
-- opts.afterReorder - optional side effects (cache invalidation, etc.)
local function InitListDragToReorder(page, opts)
    -- Reserve an empty band above the first row and below the last one. This is what
    -- makes the first/last slots reachable: hovering the band reads as an
    -- insert-before-first / insert-after-last drop. Without it, with the list scrolled
    -- to the top there is nothing above row 1 to aim at, so slot 1 is unreachable.
    page.ScrollBox:GetView():SetPadding(LIST_END_DROP_ZONE, LIST_END_DROP_ZONE, 0, 0, 0)

    local dragBehavior = ScrollUtil.InitDefaultLinearDragBehavior(page.ScrollBox)
    dragBehavior:SetReorderable(true)
    dragBehavior:SetDragPredicate(function(_frame, elementData)
        return elementData.type == opts.entryType
    end)
    -- Split each row on its vertical midpoint (top half -> insert above, bottom half ->
    -- insert below), removing the default "Inside = swap" band; the drop predicate then
    -- guards the exact midpoint so an "onto a row" drop can never fall into the swap path.
    dragBehavior:SetAreaIntersectMargin(opts.rowHeight * 0.5)
    dragBehavior:SetDropPredicate(function(_sourceElementData, contextData)
        return contextData.area ~= DragIntersectionArea.Inside
    end)
    dragBehavior:SetPostDrop(function(contextData)
        local dataProvider = contextData.dataProvider
        if not dataProvider then
            return
        end

        local ordered = {}
        for _, elementData in dataProvider:Enumerate() do
            if elementData.type == opts.entryType then
                ordered[#ordered + 1] = elementData[opts.entryKey]
            end
        end

        local list = EmpireManager.db.global[opts.listKey]
        for i = 1, #ordered do
            list[i] = ordered[i]
        end
        for i = #ordered + 1, #list do
            list[i] = nil
        end

        if opts.afterReorder then
            opts.afterReorder()
        end

        -- Repaint via the page's own Refresh. The ScrollBox re-populates rows
        -- synchronously during the drop, i.e. before this callback runs, so the
        -- up/down arrow enabled states (derived from the row index) are computed
        -- against the pre-move order and go stale - most visibly on the new first /
        -- last rows. Refresh rebuilds from the saved list, recomputing every index.
        -- Deferred a frame so it can't fight the drag behaviour's frame release.
        C_Timer.After(0, function()
            page:Refresh()
        end)
    end)
end

-- Returns true if an assignment references a character no longer in the registry.
local function IsOrphanedAssignment(asn)
    if not asn or asn.type ~= "charbank" then
        return false
    end
    if not asn.char or asn.char == "self" then
        return false
    end
    local reg = EmpireManager.db and EmpireManager.db.global and EmpireManager.db.global.registry
    return reg and reg[asn.char] == nil
end

-- Get the number of purchased tabs from capacity data
local function GetTabCount(cap, bankType, charGUID, guildName, guildRealm)
    local section
    if bankType == "warbandbank" then
        section = cap.warbandbank
    elseif bankType == "charbank" and charGUID then
        section = (cap.charbank or {})[charGUID]
    elseif bankType == "guildbank" and guildName then
        local key = EmpireManager:GuildKey(guildName, guildRealm)
        section = key and (cap.guildbank or {})[key]
    end
    if not section then
        return 0
    end
    local n = 0
    for _, v in pairs(section) do
        if type(v) == "table" then
            n = n + 1
        end
    end
    return n
end

-- Format a tab label with fill % from capacity data
local function GetTabLabel(cap, bankType, charGUID, guildName, tabNum, guildRealm)
    local capData
    if bankType == "warbandbank" then
        capData = (cap.warbandbank or {})[tabNum]
    elseif bankType == "charbank" and charGUID then
        capData = ((cap.charbank or {})[charGUID] or {})[tabNum]
    elseif bankType == "guildbank" and guildName then
        local key = EmpireManager:GuildKey(guildName, guildRealm)
        capData = key and (((cap.guildbank or {})[key]) or {})[tabNum]
    end
    if capData and capData.total and capData.total > 0 then
        local pct = math.floor((capData.used / capData.total) * 100)
        return string.format("Tab %d - %d%%", tabNum, pct)
    end
    return "Tab " .. tabNum
end

-- Build destination text for a storage assignment
local function FormatDestText(asn)
    local tabSuffix = ""
    if asn.tabs and #asn.tabs > 0 then
        if #asn.tabs == 1 then
            tabSuffix = " Tab " .. asn.tabs[1]
        else
            tabSuffix = " Tabs " .. table.concat(asn.tabs, ",")
        end
    end
    local destText
    if asn.type == "warbandbank" then
        destText = "|cff66b3ffWarband|r Bank" .. tabSuffix
    elseif asn.type == "guildbank" then
        local prefix = asn.guild and ("|cff40ff40" .. asn.guild .. "|r ") or ""
        destText = prefix .. "|cff40ff40Guild|r Bank" .. tabSuffix
    elseif asn.type == "charbank" then
        if asn.char == "self" then
            destText = "Character Bank" .. tabSuffix
        else
            local charName = "?"
            if asn.char then
                local e = EmpireManager.db.global.registry[asn.char]
                if e then
                    charName = EmpireManager:ClassColoredName(e)
                end
            end
            destText = charName .. " Bank" .. tabSuffix
        end
    else
        destText = (asn.type or "?") .. tabSuffix
    end
    -- Expansion filter tags
    if asn.expansions and #asn.expansions > 0 then
        for _, eid in ipairs(asn.expansions) do
            for _, expInfo in ipairs(EmpireManager.EXPANSION_DISPLAY) do
                if expInfo.expansionID == eid then
                    destText = destText .. " " .. EmpireManager:ExpIconString(expInfo)
                    break
                end
            end
        end
    end
    -- Subcategory tags
    if asn.subcategories and #asn.subcategories > 0 then
        local subcatDef = EmpireManager.SUBCATEGORY_DISPLAY[asn.profession]
        if subcatDef then
            local labels = {}
            for _, sc in ipairs(asn.subcategories) do
                for _, def in ipairs(subcatDef.items) do
                    if def.key == sc then
                        labels[#labels + 1] = def.label
                        break
                    end
                end
            end
            if #labels > 0 then
                destText = destText .. " |cffe0d4a8" .. table.concat(labels, ", ") .. "|r"
            end
        end
    end
    return destText
end

function EmpireManager:FormatStorageDestText(asn)
    return FormatDestText(asn)
end

-- Build sorted char list from registry. Labels are class-colored; sort uses a
-- separate plain-text key so color escapes don't break alphabetical order.
local function BuildCharList()
    local list, plain, order = {}, {}, {}
    for guid, entry in pairs(EmpireManager.db.global.registry) do
        list[guid] = RemapCharLabel(entry)
        plain[guid] = (entry.name or "?") .. " - " .. (entry.realm or "?")
        order[#order + 1] = guid
    end
    table.sort(order, function(a, b)
        return (plain[a] or ""):lower() < (plain[b] or ""):lower()
    end)
    return list, order
end

-- Build guild list from registry, excluding blacklisted
-- Returns a sorted list of unique (guild, realm) pairs across the roster,
-- skipping blacklisted guild names. Display label is "Guild" when the name is
-- unique, "Guild - Realm" when the same name appears on multiple realms.
-- Each entry: { guild = "Vanguard", realm = "Stormrage", label = "Vanguard" }.
local function BuildGuildList()
    local nameCounts, pairs_ = {}, {}
    local seen = {}
    for _, entry in pairs(EmpireManager.db.global.registry) do
        local g = entry.guild
        local r = entry.guildRealm
        if g and g ~= "" and r and r ~= "" and not EmpireManager:IsGuildBlacklisted(g, r) then
            -- Dedupe through GuildKey, not a raw concat: registry entries store
            -- the realm in two spellings ("Argent Dawn" from GetRealmName vs
            -- "ArgentDawn" from GetGuildInfo's 4th return), which a raw key
            -- treats as two guilds.
            local key = EmpireManager:GuildKey(g, r)
            if key and not seen[key] then
                seen[key] = true
                pairs_[#pairs_ + 1] = { guild = g, realm = r }
                nameCounts[g] = (nameCounts[g] or 0) + 1
            end
        end
    end
    for _, item in ipairs(pairs_) do
        if nameCounts[item.guild] > 1 then
            item.label = item.guild .. " - " .. item.realm
        else
            item.label = item.guild
        end
    end
    table.sort(pairs_, function(a, b)
        return a.label:lower() < b.label:lower()
    end)
    return pairs_
end

-------------------------------------------------------------------------------
-- EMStorageRowMixin (virtualized row for ScrollBox pool)
-------------------------------------------------------------------------------

function EMStorageRowMixin:OnLoad()
    local UP_PATH = "Interface\\AddOns\\EmpireManager\\Textures\\up"
    local DOWN_PATH = "Interface\\AddOns\\EmpireManager\\Textures\\down"

    -- Up button (icon, vertically centered in row)
    self.UpBtn = CreateFrame("Button", nil, self)
    self.UpBtn:SetSize(16, 16)
    self.UpBtn:SetPoint("LEFT", self, "LEFT", 12, 0)
    self.UpBtn:SetNormalTexture(UP_PATH)
    self.UpBtn:GetNormalTexture():SetVertexColor(1, 0.82, 0)
    self.UpBtn:SetPushedTexture(UP_PATH)
    self.UpBtn:GetPushedTexture():SetVertexColor(0.8, 0.65, 0)
    self.UpBtn:SetDisabledTexture(UP_PATH)
    self.UpBtn:GetDisabledTexture():SetDesaturated(true)
    self.UpBtn:GetDisabledTexture():SetVertexColor(0.4, 0.4, 0.4)
    self.UpBtn:SetHighlightTexture(UP_PATH, "ADD")
    self.UpBtn:GetHighlightTexture():SetVertexColor(1, 1, 0.6)
    self.UpBtn:GetHighlightTexture():SetAlpha(0.5)
    self.UpBtn:SetScript("OnClick", function()
        local d = self._data
        if not d then
            return
        end
        local a = EmpireManager.db.global.storageAssignments
        local idx = d.idx
        local newIdx = idx
        if IsShiftKeyDown() then
            local target = idx
            for i = idx - 1, 1, -1 do
                if a[i].profession == d.asn.profession then
                    target = i
                    break
                end
            end
            if target < idx then
                local rule = table.remove(a, idx)
                table.insert(a, target, rule)
                newIdx = target
            end
        elseif IsControlKeyDown() then
            local target = math.max(1, idx - 5)
            local rule = table.remove(a, idx)
            table.insert(a, target, rule)
            newIdx = target
        else
            a[idx], a[idx - 1] = a[idx - 1], a[idx]
            newIdx = idx - 1
        end
        EmpireManager._storageScrollToIdx = newIdx
        EmpireManager:InvalidateStorageCache()
        EmpireManager:SelectDashboardTab("storage")
    end)

    -- Down button (icon)
    self.DownBtn = CreateFrame("Button", nil, self)
    self.DownBtn:SetSize(16, 16)
    self.DownBtn:SetPoint("LEFT", self.UpBtn, "RIGHT", 6, 0)
    self.DownBtn:SetNormalTexture(DOWN_PATH)
    self.DownBtn:GetNormalTexture():SetVertexColor(1, 0.82, 0)
    self.DownBtn:SetPushedTexture(DOWN_PATH)
    self.DownBtn:GetPushedTexture():SetVertexColor(0.8, 0.65, 0)
    self.DownBtn:SetDisabledTexture(DOWN_PATH)
    self.DownBtn:GetDisabledTexture():SetDesaturated(true)
    self.DownBtn:GetDisabledTexture():SetVertexColor(0.4, 0.4, 0.4)
    self.DownBtn:SetHighlightTexture(DOWN_PATH, "ADD")
    self.DownBtn:GetHighlightTexture():SetVertexColor(1, 1, 0.6)
    self.DownBtn:GetHighlightTexture():SetAlpha(0.5)
    self.DownBtn:SetScript("OnClick", function()
        local d = self._data
        if not d then
            return
        end
        local a = EmpireManager.db.global.storageAssignments
        local idx = d.idx
        local newIdx = idx
        if IsShiftKeyDown() then
            local target = idx
            for i = idx + 1, #a do
                if a[i].profession == d.asn.profession then
                    target = i
                    break
                end
            end
            if target > idx then
                local rule = table.remove(a, idx)
                table.insert(a, target, rule)
                newIdx = target
            end
        elseif IsControlKeyDown() then
            local target = math.min(#a, idx + 5)
            local rule = table.remove(a, idx)
            table.insert(a, target, rule)
            newIdx = target
        else
            a[idx], a[idx + 1] = a[idx + 1], a[idx]
            newIdx = idx + 1
        end
        EmpireManager._storageScrollToIdx = newIdx
        EmpireManager:InvalidateStorageCache()
        EmpireManager:SelectDashboardTab("storage")
    end)

    -- Category FontString (vertically centered)
    self.CategoryFs = self:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
    self.CategoryFs:SetPoint("LEFT", self, "LEFT", 68, 0)
    self.CategoryFs:SetWidth(144)
    self.CategoryFs:SetJustifyH("LEFT")
    self.CategoryFs:SetWordWrap(false)

    -- Fill level bar (full-height, faded; behind the text)
    self.FillBar = self:CreateTexture(nil, "ARTWORK")
    self.FillBar:SetPoint("TOPLEFT", self, "TOPLEFT", 210, -2)
    self.FillBar:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", 210, 2)
    self.FillBar:SetColorTexture(1, 1, 1, 1)
    self.FillBar:Hide()

    -- Fill level FontString (right-justified, vertically centered)
    self.FillFs = self:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
    self.FillFs:SetPoint("LEFT", self, "LEFT", 200, 0)
    self.FillFs:SetWidth(116)
    self.FillFs:SetJustifyH("RIGHT")
    self.FillFs:SetWordWrap(false)

    -- Destination FontString (vertically centered)
    self.DestFs = self:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
    self.DestFs:SetPoint("LEFT", self, "LEFT", 336, 0)
    self.DestFs:SetJustifyH("LEFT")
    self.DestFs:SetWordWrap(false)

    -- Click handlers
    self:SetScript("OnClick", function(f, button)
        if button == "RightButton" and f._data then
            EmpireManager:OpenStorageDialog(f._data.idx)
        end
    end)
    self:SetScript("OnDoubleClick", function(f)
        if f._data then
            EmpireManager:OpenStorageDialog(f._data.idx)
        end
    end)
    local function showRowTooltip(f)
        local d = f._data
        if not d then
            return
        end
        GameTooltip:SetOwner(f, "ANCHOR_CURSOR_RIGHT")
        local titleText
        if d.catTotal and d.catTotal > 1 then
            titleText = string.format("Rule #%d  %s (%d/%d)", d.idx, d.profName, d.catIndex or 1, d.catTotal)
        else
            titleText = string.format("Rule #%d  %s", d.idx, d.profName)
        end
        GameTooltip:AddLine(titleText, 1, 0.82, 0)
        GameTooltip:AddLine(" ")
        local destText = FormatDestText(d.asn)
        if d.asn.expansions and #d.asn.expansions > 0 then
            destText = destText:gsub("(|T)", "\n%1", 1)
        end
        GameTooltip:AddLine(destText, 1, 1, 1, true)
        local fillText = f.FillFs:GetText()
        if fillText and fillText ~= "" and fillText ~= "No data" then
            local suffix = ""
            if d.tabData and d.tabData.total then
                suffix = string.format(", %d free", d.tabData.total - (d.tabData.used or 0))
            end
            GameTooltip:AddLine("Slots: " .. fillText .. suffix, f.FillFs:GetTextColor())
        end
        local cap = EmpireManager.db.global.storageCapacity or {}
        local section
        if d.asn.type == "warbandbank" then
            section = cap.warbandbank
        elseif d.asn.type == "guildbank" and d.asn.guild then
            local key = EmpireManager:GuildKey(d.asn.guild, d.asn.realm)
            section = key and cap.guildbank and cap.guildbank[key]
        elseif d.asn.type == "charbank" and d.asn.char then
            section = cap.charbank and cap.charbank[d.asn.char]
        end
        local age = section and EmpireManager:FormatStaleAge(section._scannedAt)
        if age then
            GameTooltip:AddLine("Scanned: " .. age, 1, 1, 1)
        end
        if d.isOrphan then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("|cffff4444Orphaned rule|r", 1, 0.3, 0.3)
            GameTooltip:AddLine(
                "This rule references a character no longer in the roster. Edit or delete it.",
                1,
                1,
                1,
                true
            )
        end
        GameTooltip:Show()
    end

    local function inReorderCol(f)
        local cursorX = GetCursorPosition()
        local scale = f:GetEffectiveScale()
        local relX = (cursorX / scale) - f:GetLeft()
        return relX < 60
    end

    self:SetScript("OnEnter", function(f)
        if not f._data then
            return
        end
        f._tooltipShown = not inReorderCol(f)
        if f._tooltipShown then
            showRowTooltip(f)
        end
        f._tooltipTimer = 0
        f:SetScript("OnUpdate", function(fr, elapsed)
            fr._tooltipTimer = (fr._tooltipTimer or 0) + elapsed
            if fr._tooltipTimer < 0.1 then
                return
            end
            fr._tooltipTimer = 0
            if not fr._data then
                return
            end
            local inCol = inReorderCol(fr)
            if inCol and fr._tooltipShown then
                GameTooltip:Hide()
                fr._tooltipShown = false
            elseif not inCol and not fr._tooltipShown then
                showRowTooltip(fr)
                fr._tooltipShown = true
            end
        end)
    end)
    self:SetScript("OnLeave", function(f)
        f:SetScript("OnUpdate", nil)
        f._tooltipShown = false
        GameTooltip:Hide()
    end)
end

function EMStorageRowMixin:Populate(data)
    self._data = data
    local idx = data.idx
    local asn = data.asn

    -- Zebra stripe (AH-style atlas, matches Characters tab)
    if idx % 2 == 0 then
        self.Stripe:SetAtlas("auctionhouse-rowstripe-1")
    else
        self.Stripe:SetAtlas("auctionhouse-rowstripe-2")
    end

    -- Up/down enable state
    self.UpBtn:SetEnabled(idx > 1)
    self.DownBtn:SetEnabled(idx < data.totalCount)

    -- Category
    local pInfo = EmpireManager.PROF_INFO_BY_KEY[asn.profession]
    local profColor = "ffffff"
    local profIcon = ""
    if pInfo then
        profColor = string.format("%02x%02x%02x", pInfo.r * 255, pInfo.g * 255, pInfo.b * 255)
        profIcon = string.format("|T%s:16:16|t ", pInfo.icon)
    end
    local profName = (pInfo and pInfo.label) or (asn.profession:sub(1, 1):upper() .. asn.profession:sub(2))
    data.profName = profName
    self.CategoryFs:SetText(profIcon .. "|cff" .. profColor .. profName .. "|r")

    -- Destination (flag orphaned charbank rules whose character is no longer in the registry)
    local isOrphan = IsOrphanedAssignment(asn)
    data.isOrphan = isOrphan
    local destText = FormatDestText(asn)
    if isOrphan then
        destText = "|cffff4444[!]|r " .. destText
    end
    self.DestFs:SetText(destText)
    self.DestFs:SetTextColor(1, 1, 1)

    -- Fill level
    local tabData = data.tabData
    if tabData and tabData.total and tabData.total > 0 then
        local pct = math.floor((tabData.used / tabData.total) * 100)
        self.FillFs:SetText(string.format("%d/%d (%d%%)", tabData.used, tabData.total, pct))
        local r, g, b
        if pct >= 85 then
            r, g, b = 1.0, 0.2, 0.2
        elseif pct >= 60 then
            r, g, b = 1.0, 0.8, 0.0
        else
            r, g, b = 0.0, 0.8, 0.0
        end
        self.FillFs:SetTextColor(r, g, b)
        local barWidth = math.max(1, math.floor(116 * (pct / 100) + 0.5))
        self.FillBar:SetWidth(barWidth)
        self.FillBar:SetVertexColor(r, g, b, 0.18)
        self.FillBar:Show()
    elseif asn.type == "charbank" and asn.char == "self" then
        self.FillFs:SetText("")
        self.FillBar:Hide()
    else
        self.FillFs:SetText("No data")
        self.FillFs:SetTextColor(0.5, 0.5, 0.5)
        self.FillBar:Hide()
    end
end

-------------------------------------------------------------------------------
-- EMStoragePageMixin
-------------------------------------------------------------------------------

function EMStoragePageMixin:OnLoad()
    self.ScrollBox = self.Inset.ScrollBox
    self.ScrollBar = self.Inset.ScrollBar

    -- ScrollBox view with two element types
    local view = CreateScrollBoxListLinearView()
    view:SetElementFactory(function(factory, elementData)
        if elementData.type == "rule" then
            factory("EMStorageRowTemplate", function(frame, data)
                if not frame._mixinApplied then
                    Mixin(frame, EMStorageRowMixin)
                    frame:OnLoad()
                    frame._mixinApplied = true
                end
                frame:Populate(data)
            end)
        else
            factory("EMStorageNoticeTemplate", function(frame, data)
                if not frame._noticeInit then
                    frame.Text = frame:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
                    frame.Text:SetPoint("TOPLEFT", 8, -4)
                    frame.Text:SetPoint("RIGHT", -8, 0)
                    frame.Text:SetJustifyH("LEFT")
                    frame._noticeInit = true
                end
                frame.Text:SetWordWrap(true)
                frame.Text:SetNonSpaceWrap(true)
                if data.type == "empty_notice" then
                    frame.Text:SetText("\nNo storage assignments configured yet. Click 'Add Rule' to create one, or click the wand icon to use the Setup Wizard.")
                    frame.Text:SetTextColor(1, 1, 1)
                else
                    frame.Text:SetText(data.text)
                    frame.Text:SetTextColor(1, 1, 1)
                end
            end)
        end
    end)
    view:SetElementExtentCalculator(function(_dataIndex, elementData)
        if elementData.type == "empty_notice" then
            return 40
        end
        if elementData.type == "notice" then
            return elementData.height or 24
        end
        return STORAGE_ROW_HEIGHT
    end)
    ScrollUtil.InitScrollBoxListWithScrollBar(self.ScrollBox, self.ScrollBar, view)

    -- Import/Export button (icon-only, texture set in XML)
    local ieBtn = self.IEButton
    EmpireManager:StyleIconButton(ieBtn, 0.5)
    ieBtn:SetScript("OnClick", function()
        local ie = EmpireManagerIOFrame
        if ie and ie:IsShown() then
            return
        end
        local sd = EmpireManagerStorageDialog
        if sd and sd:IsShown() then
            sd:Hide()
        end
        EmpireManager:ToggleIOWindow()
    end)
    ieBtn:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Import / Export", 1, 0.82, 0)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Import or export storage rules and character roster.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    ieBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Add Rule icon button (texture set in XML)
    EmpireManager:StyleIconButton(self.AddButton, 0.5)
    self.AddButton:SetScript("OnClick", function()
        local sd = EmpireManagerStorageDialog
        if sd and sd:IsShown() then
            return
        end
        local ie = EmpireManagerIOFrame
        if ie and ie:IsShown() then
            ie:Hide()
        end
        EmpireManager:OpenStorageDialog(nil)
    end)
    self.AddButton:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Add Rule", 1, 0.82, 0)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Create a new storage assignment.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    self.AddButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Wand icon button: opens the Storage Setup Wizard (texture set in XML)
    if self.WandButton then
        EmpireManager:StyleIconButton(self.WandButton, 0.5)
        self.WandButton:SetScript("OnClick", function()
            local sd = EmpireManagerStorageDialog
            if sd and sd:IsShown() then
                sd:Hide()
            end
            local ie = EmpireManagerIOFrame
            if ie and ie:IsShown() then
                ie:Hide()
            end
            EmpireManager:OpenWizard()
        end)
        self.WandButton:SetScript("OnEnter", function(btn)
            GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Storage Setup Wizard", 1, 0.82, 0)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Quickly create Storage Rules from a template.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        self.WandButton:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
    end

    -- Column headers
    self:InitStorageHeaders()

    -- Drag-to-reorder (needs the ScrollBox initialized above)
    self:InitDragToReorder()
end

function EMStoragePageMixin:InitDragToReorder()
    InitListDragToReorder(self, {
        entryType = "rule",
        entryKey = "asn",
        listKey = "storageAssignments",
        rowHeight = STORAGE_ROW_HEIGHT,
        afterReorder = function()
            EmpireManager:InvalidateStorageCache()
        end,
    })
end

function EMStoragePageMixin:InitStorageHeaders()
    local container = self.Inset.HeaderContainer
    local xOffset = 0
    for _, col in ipairs(STORAGE_COLUMNS) do
        local btn = CreateFrame("Button", nil, container, "ColumnDisplayButtonShortTemplate")
        if col.fill then
            btn:SetPoint("LEFT", container, "LEFT", xOffset, 0)
            btn:SetPoint("RIGHT", container, "RIGHT", 0, 0)
            btn:SetHeight(19)
        else
            btn:SetSize(col.width, 19)
            btn:SetPoint("LEFT", container, "LEFT", xOffset, 0)
        end
        btn:SetText(col.label)
        btn:SetNormalFontObject(GameFontHighlightSmall)
        btn:GetFontString():SetJustifyH("LEFT")
        btn:SetEnabled(false)
        xOffset = xOffset + col.width
    end
end

function EMStoragePageMixin:OnShow()
    self:Refresh()
end

function EMStoragePageMixin:Refresh()
    local assignments = EmpireManager.db.global.storageAssignments or {}
    local cap = EmpireManager.db.global.storageCapacity or {}
    local data = {}

    if #assignments == 0 then
        data[#data + 1] = { type = "empty_notice" }
    else
        -- Per-category totals (for "Rule #N <Category> (x/y)" tooltip).
        local catTotals = {}
        for _, asn in ipairs(assignments) do
            local k = asn.profession or ""
            catTotals[k] = (catTotals[k] or 0) + 1
        end
        local catSeen = {}

        for i, asn in ipairs(assignments) do
            local tabData
            if asn.type == "warbandbank" then
                tabData = AggregateCapacity(cap.warbandbank, asn.tabs)
            elseif asn.type == "guildbank" and asn.guild then
                local key = EmpireManager:GuildKey(asn.guild, asn.realm)
                tabData = AggregateCapacity(key and cap.guildbank and cap.guildbank[key], asn.tabs)
            elseif asn.type == "charbank" and asn.char then
                tabData = AggregateCapacity(cap.charbank and cap.charbank[asn.char], asn.tabs)
            end
            local catKey = asn.profession or ""
            catSeen[catKey] = (catSeen[catKey] or 0) + 1
            data[#data + 1] = {
                type = "rule",
                idx = i,
                asn = asn,
                tabData = tabData,
                totalCount = #assignments,
                catIndex = catSeen[catKey],
                catTotal = catTotals[catKey] or 1,
            }
        end
    end

    -- Unconfigured notice (estimate height from text length for wrapping)
    local noticeText = self:BuildUnconfiguredText(assignments)
    if noticeText then
        -- strip color codes for length estimate
        local plainLen = #(noticeText:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
        local lines = math.max(1, math.ceil(plainLen / 95))
        local noticeHeight = lines * 16 + 12
        data[#data + 1] = { type = "notice", text = noticeText, height = noticeHeight }
    end

    -- Preserve scroll position across rebuilds (live capacity refresh in
    -- particular replaces the data provider without changing the rule list).
    local savedOffset = self.ScrollBox:GetScrollPercentage()

    local dataProvider = CreateDataProvider(data)
    self.ScrollBox:SetDataProvider(dataProvider)

    -- Scroll-follow after reorder wins over saved-offset restore.
    local scrollTo = EmpireManager._storageScrollToIdx
    EmpireManager._storageScrollToIdx = nil
    if scrollTo and scrollTo > 0 then
        C_Timer.After(0, function()
            local dp = self.ScrollBox:GetDataProvider()
            if not dp then
                return
            end
            for _, elementData in dp:Enumerate() do
                if elementData.type == "rule" and elementData.idx == scrollTo then
                    self.ScrollBox:ScrollToElementData(elementData, ScrollBoxConstants.AlignCenter)
                    break
                end
            end
        end)
    elseif savedOffset and savedOffset >= 0 then
        C_Timer.After(0, function()
            if self.ScrollBox:GetDataProvider() then
                self.ScrollBox:SetScrollPercentage(savedOffset)
            end
        end)
    end
end

-------------------------------------------------------------------------------
-- Storage Dialog (Modal - Add/Edit)
-------------------------------------------------------------------------------

function EmpireManager:InitStorageDialog()
    local f = EmpireManagerStorageDialog
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
    f:SetBackdropColor(0.06, 0.06, 0.09, 0.95)
    f:RegisterForDrag("LeftButton")

    f.SaveButton:SetText("Save")
    f.DeleteButton:SetText("|cffff4444Delete|r")
    f.CancelButton:SetText("Cancel")

    f.CancelButton:ClearAllPoints()
    f.CancelButton:SetPoint("RIGHT", f.SaveButton, "LEFT", -4, 0)
    f.CancelButton:SetScript("OnClick", function()
        f:Hide()
    end)
    f.CloseButton:SetScript("OnClick", function()
        f:Hide()
    end)

    -- ESC closes the dialog (not the dashboard behind it)
    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            self:Hide()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)

    -- Create dropdowns (persistent across opens, menus rebuilt each time)
    local DD_WIDTH = 270
    local function MakeDropdown(row, template)
        local dd = CreateFrame("DropdownButton", nil, row, template or "WowStyle1DropdownTemplate")
        dd:SetPoint("LEFT", row.Label, "RIGHT", 4, 0)
        dd:SetWidth(DD_WIDTH)
        return dd
    end

    f.CategoryDD = MakeDropdown(f.Row1)
    f.BankTypeDD = MakeDropdown(f.Row2)
    f.TabsDD = MakeDropdown(f.Row3, "WowStyle1FilterDropdownTemplate")
    f.CharDD = MakeDropdown(f.Row4)
    f.GuildDD = MakeDropdown(f.Row5)
    f.ExpDD = MakeDropdown(f.Row6, "WowStyle1FilterDropdownTemplate")
    f.SubcatDD = MakeDropdown(f.Row7)

    return f
end

function EmpireManager:OpenStorageDialog(editIdx)
    local f = self:InitStorageDialog()
    local isEdit = editIdx ~= nil
    local asn = isEdit and self.db.global.storageAssignments[editIdx] or nil

    f.TitleText:SetText(
        isEdit and ("EmpireManager - Edit Storage Rule #" .. editIdx) or "EmpireManager - Add Storage Rule"
    )
    f.DeleteButton:SetShown(isEdit)

    -- Dialog state
    local st = {}
    if isEdit and asn then
        st.prof = asn.profession
        st.bankType = asn.type
        st.char = asn.char
        st.guild = asn.guild
        st.guildRealm = asn.realm
        st.tabs = {}
        for _, t in ipairs(asn.tabs or {}) do
            st.tabs[tostring(t)] = true
        end
        st.expansions = {}
        for _, eid in ipairs(asn.expansions or {}) do
            st.expansions[tostring(eid)] = true
        end
        st.subcategories = {}
        for _, sc in ipairs(asn.subcategories or {}) do
            st.subcategories[sc] = true
        end
    else
        st.prof = nil
        st.bankType = nil
        st.char = nil
        st.guild = nil
        st.guildRealm = nil
        st.tabs = {}
        st.expansions = {}
        st.subcategories = {}
    end
    f._state = st

    local cap = self.db.global.storageCapacity or {}

    -- Helper: rebuild layout (show/hide conditional rows, resize dialog)
    local function UpdateLayout()
        local showChar = (st.bankType == "charbank")
        local showGuild = (st.bankType == "guildbank")
        local showExp = st.prof and not NO_EXPANSION_FILTER[st.prof]
        local subcatDef = st.prof and self.SUBCATEGORY_DISPLAY[st.prof]
        local hasSubcat = subcatDef ~= nil

        f.Row4:SetShown(showChar)
        f.Row5:SetShown(showGuild)
        f.Row6:SetShown(showExp or false)
        f.Row7:SetShown(true)
        f.SubcatDD:SetEnabled(hasSubcat)

        -- Two segments, top to bottom:
        --   WHAT we route  - Category, Subcategory, Expansion
        --   WHERE it goes  - Bank Type, Tab, Character/Guild
        -- Subcategory is always shown (greyed when the category has none) so the
        -- dialog doesn't resize on every category change. The XML anchors are
        -- defaults only; the real order is built here.
        local function Chain(row, prev)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", prev, "BOTTOMLEFT")
            row:SetPoint("RIGHT", f, "RIGHT", -14, 0)
            return row
        end

        -- Segment 1: what we route
        local prevRow = Chain(f.Row7, f.Row1)
        if showExp then
            prevRow = Chain(f.Row6, prevRow)
        end
        -- Segment 2: where it goes
        prevRow = Chain(f.Row2, prevRow)
        prevRow = Chain(f.Row3, prevRow)
        if showChar then
            prevRow = Chain(f.Row4, prevRow)
        end
        if showGuild then
            prevRow = Chain(f.Row5, prevRow)
        end

        -- Resize dialog to fit visible rows
        -- Layout: 56 top padding (title) + rows + 24 gap + 40 button area
        -- Base 4 = Category + Subcategory (always shown) + Bank Type + Tab.
        local rowCount = 4
            + (showChar and 1 or 0)
            + (showGuild and 1 or 0)
            + (showExp and 1 or 0)
        f:SetHeight(56 + rowCount * 32 + 24 + 40)

        -- Update dropdown display text
        -- Category
        local catInfo = self.PROF_INFO_BY_KEY and self.PROF_INFO_BY_KEY[st.prof]
        f.CategoryDD:OverrideText((catInfo and catInfo.label) or "Select category")

        -- Bank type
        local btLabels = { warbandbank = "Warband Bank", guildbank = "Guild Bank", charbank = "Character Bank" }
        f.BankTypeDD:OverrideText(st.bankType and btLabels[st.bankType] or "Select bank type")

        -- Tabs
        local tabNums = {}
        for k in pairs(st.tabs) do
            tabNums[#tabNums + 1] = tonumber(k)
        end
        table.sort(tabNums)
        if #tabNums > 0 then
            local parts = {}
            for _, t in ipairs(tabNums) do
                parts[#parts + 1] = tostring(t)
            end
            f.TabsDD:SetText("Tab " .. table.concat(parts, ", "))
        else
            f.TabsDD:SetText("Any Tab")
        end

        -- Character
        if showChar then
            if st.char then
                local charList = BuildCharList()
                f.CharDD:OverrideText(charList[st.char] or st.char)
            else
                f.CharDD:OverrideText("Select Character")
            end
        end

        -- Guild
        if showGuild then
            f.GuildDD:OverrideText(st.guild or "Select Guild")
        end

        -- Expansions
        if showExp then
            local expIcons = {}
            for i = #self.EXPANSION_DISPLAY, 1, -1 do
                local expInfo = self.EXPANSION_DISPLAY[i]
                if st.expansions[tostring(expInfo.expansionID)] then
                    expIcons[#expIcons + 1] = EmpireManager:ExpIconString(expInfo)
                end
            end
            local total = #expIcons
            local text
            if total == 0 or total == #self.EXPANSION_DISPLAY then
                text = "Any Expansion"
            elseif total > 4 then
                text = table.concat(expIcons, " ", 1, 4) .. string.format(" +%d", total - 4)
            else
                text = table.concat(expIcons, " ")
            end
            f.ExpDD:SetText(text)
        end

        -- Subcategory. Always rendered; shows a dash when the category has none
        -- so the greyed-out control reads as "not applicable", not "unset".
        if subcatDef then
            local scNames = {}
            for _, sc in ipairs(subcatDef.items) do
                if st.subcategories[sc.key] then
                    scNames[#scNames + 1] = sc.label
                end
            end
            -- None selected and ALL selected both mean "match the whole category"
            -- (see MatchesSubcategory), so both render as the category's "any"
            -- label rather than concatenating every item into the button.
            if #scNames == 0 or #scNames == #subcatDef.items then
                f.SubcatDD:OverrideText(subcatDef.anyLabel or "Any")
            else
                f.SubcatDD:OverrideText(table.concat(scNames, ", "))
            end
        else
            f.SubcatDD:OverrideText("-")
        end

        -- Save button: enable only when all required fields are filled.
        local valid = st.prof and st.bankType
        if st.bankType == "charbank" and not st.char then
            valid = false
        end
        if st.bankType == "guildbank" and (not st.guild or st.guild == "") then
            valid = false
        end
        if subcatDef and subcatDef.mode == "single" and not next(st.subcategories) then
            valid = false
        end
        f.SaveButton:SetEnabled(valid and true or false)
    end

    -- Category dropdown
    f.CategoryDD:SetEnabled(not isEdit)
    f.CategoryDD:SetupMenu(function(_, rootDescription)
        -- Professions
        for _, info in ipairs(self.PROF_DISPLAY) do
            rootDescription:CreateRadio(string.format("|T%s:14:14|t %s", info.icon, info.label), function()
                return st.prof == info.key
            end, function()
                st.prof = info.key
                st.subcategories = {}
                C_Timer.After(0, UpdateLayout)
            end)
        end
        rootDescription:CreateDivider()
        -- Storage categories
        for _, info in ipairs(self.STORAGE_CATEGORY_DISPLAY) do
            rootDescription:CreateRadio(string.format("|T%s:14:14|t %s", info.icon, info.label), function()
                return st.prof == info.key
            end, function()
                st.prof = info.key
                st.subcategories = {}
                C_Timer.After(0, UpdateLayout)
            end)
        end
    end)

    -- Bank Type dropdown
    f.BankTypeDD:SetupMenu(function(_, rootDescription)
        for _, bt in ipairs({ "warbandbank", "guildbank", "charbank" }) do
            local labels = { warbandbank = "Warband Bank", guildbank = "Guild Bank", charbank = "Character Bank" }
            rootDescription:CreateRadio(labels[bt], function()
                return st.bankType == bt
            end, function()
                st.bankType = bt
                st.char = nil
                st.guild = nil
                st.guildRealm = nil
                st.tabs = {}
                C_Timer.After(0, UpdateLayout)
            end)
        end
    end)

    -- Tabs filter dropdown
    f.TabsDD:SetupMenu(function(_, rootDescription)
        rootDescription:SetTag("EM_STORAGE_TABS")
        local count = GetTabCount(cap, st.bankType, st.char, st.guild, st.guildRealm)
        if count == 0 then
            local msg
            if not st.bankType then
                msg = "Select a Bank Type first"
            elseif st.bankType == "guildbank" and not st.guild then
                msg = "Select a Guild first"
            elseif st.bankType == "charbank" and not st.char then
                msg = "Select a Character first"
            else
                msg = "No tabs found (open bank first)"
            end
            rootDescription:CreateTitle(msg)
        else
            for t = 1, count do
                local key = tostring(t)
                rootDescription:CreateCheckbox(GetTabLabel(cap, st.bankType, st.char, st.guild, t, st.guildRealm), function()
                    return st.tabs[key] or false
                end, function()
                    st.tabs[key] = not st.tabs[key] or nil
                    C_Timer.After(0, UpdateLayout)
                end)
            end
        end
    end)

    -- Character dropdown
    local charSelIdx
    f.CharDD:SetupMenu(function(_, rootDescription)
        rootDescription:SetScrollMode(20 * 20)
        charSelIdx = nil
        local charList, charOrder = BuildCharList()
        for i, guid in ipairs(charOrder) do
            if guid == st.char then charSelIdx = i end
            rootDescription:CreateRadio(charList[guid], function()
                return st.char == guid
            end, function()
                st.char = guid
                st.tabs = {}
                C_Timer.After(0, UpdateLayout)
            end)
        end
    end)
    self:EnableDropdownScrollToSelected(f.CharDD, function() return charSelIdx end)

    -- Guild dropdown
    local guildSelIdx
    f.GuildDD:SetupMenu(function(_, rootDescription)
        rootDescription:SetScrollMode(20 * 20)
        guildSelIdx = nil
        local guilds = BuildGuildList()
        for i, item in ipairs(guilds) do
            if item.guild == st.guild and item.realm == st.guildRealm then guildSelIdx = i end
            rootDescription:CreateRadio(item.label, function()
                return st.guild == item.guild and st.guildRealm == item.realm
            end, function()
                st.guild = item.guild
                st.guildRealm = item.realm
                st.tabs = {}
                local banker = self:FindCharInGuild(item.guild, nil, item.realm)
                if banker then
                    st.char = banker
                end
                C_Timer.After(0, UpdateLayout)
            end)
        end
    end)
    self:EnableDropdownScrollToSelected(f.GuildDD, function() return guildSelIdx end)

    -- Expansions filter dropdown
    f.ExpDD:SetupMenu(function(_, rootDescription)
        rootDescription:SetTag("EM_STORAGE_EXP")

        -- Toggle-all button: if any are checked, clear all; otherwise select all.
        local anyChecked = false
        for _, expInfo in ipairs(self.EXPANSION_DISPLAY) do
            if st.expansions[tostring(expInfo.expansionID)] then
                anyChecked = true
                break
            end
        end
        local toggleLabel = anyChecked and "Clear All" or "Select All"
        rootDescription:CreateButton(toggleLabel, function()
            if anyChecked then
                wipe(st.expansions)
            else
                for _, expInfo in ipairs(self.EXPANSION_DISPLAY) do
                    st.expansions[tostring(expInfo.expansionID)] = true
                end
            end
            C_Timer.After(0, UpdateLayout)
        end)
        rootDescription:CreateDivider()

        for i = #self.EXPANSION_DISPLAY, 1, -1 do
            local expInfo = self.EXPANSION_DISPLAY[i]
            local key = tostring(expInfo.expansionID)
            rootDescription:CreateCheckbox(
                EmpireManager:ExpIconString(expInfo)
                    .. string.format(
                        " |cff%02x%02x%02x%s|r",
                        expInfo.r * 255,
                        expInfo.g * 255,
                        expInfo.b * 255,
                        expInfo.label
                    ),
                function()
                    return st.expansions[key] or false
                end,
                function()
                    st.expansions[key] = not st.expansions[key] or nil
                    C_Timer.After(0, UpdateLayout)
                end
            )
        end
    end)

    -- Subcategory dropdown
    f.SubcatDD:SetupMenu(function(_, rootDescription)
        local subcatDef = self.SUBCATEGORY_DISPLAY[st.prof]
        if not subcatDef then
            return
        end
        if subcatDef.mode == "single" then
            for _, sc in ipairs(subcatDef.items) do
                rootDescription:CreateRadio(sc.label, function()
                    return st.subcategories[sc.key] or false
                end, function()
                    wipe(st.subcategories)
                    st.subcategories[sc.key] = true
                    C_Timer.After(0, UpdateLayout)
                end)
            end
        else
            rootDescription:SetTag("EM_STORAGE_SUBCAT")

            -- Toggle-all button: if any are checked, clear all; otherwise select all.
            -- Same pattern as the Expansion dropdown above.
            local anyChecked = false
            for _, sc in ipairs(subcatDef.items) do
                if st.subcategories[sc.key] then
                    anyChecked = true
                    break
                end
            end
            local toggleLabel = anyChecked and "Clear All" or "Select All"
            rootDescription:CreateButton(toggleLabel, function()
                if anyChecked then
                    wipe(st.subcategories)
                else
                    for _, sc in ipairs(subcatDef.items) do
                        st.subcategories[sc.key] = true
                    end
                end
                C_Timer.After(0, UpdateLayout)
            end)
            rootDescription:CreateDivider()

            for _, sc in ipairs(subcatDef.items) do
                rootDescription:CreateCheckbox(sc.label, function()
                    return st.subcategories[sc.key] or false
                end, function()
                    st.subcategories[sc.key] = not st.subcategories[sc.key] or nil
                    C_Timer.After(0, UpdateLayout)
                end)
            end
        end
    end)

    -- Save button
    f.SaveButton:SetScript("OnClick", function()
        if not st.prof then
            self:ChatMsg("Select a category", true)
            return
        end
        if not st.bankType then
            self:ChatMsg("Select a bank type", true)
            return
        end
        if st.bankType == "charbank" and not st.char then
            self:ChatMsg("Select a banker character", true)
            return
        end
        if st.bankType == "guildbank" and (not st.guild or st.guild == "") then
            self:ChatMsg("Select a Guild", true)
            return
        end

        local subcatDef = self.SUBCATEGORY_DISPLAY[st.prof]
        if subcatDef and subcatDef.mode == "single" and not next(st.subcategories) then
            self:ChatMsg("Select a subcategory", true)
            return
        end

        -- Build entry
        local tabsArray = {}
        for k in pairs(st.tabs) do
            tabsArray[#tabsArray + 1] = tonumber(k)
        end
        table.sort(tabsArray)
        local expArray = {}
        for k in pairs(st.expansions) do
            expArray[#expArray + 1] = tonumber(k)
        end
        local subcatArray = {}
        for k in pairs(st.subcategories) do
            subcatArray[#subcatArray + 1] = k
        end

        -- Collapse "all selected" to "none selected": both mean "any", so clear
        -- the list to keep display/runtime consistent.
        local tabTotal = GetTabCount(cap, st.bankType, st.char, st.guild, st.guildRealm)
        if tabTotal > 0 and #tabsArray >= tabTotal then
            tabsArray = {}
        end
        if #expArray >= #EmpireManager.EXPANSION_DISPLAY then
            expArray = {}
        end
        if subcatDef and subcatDef.items and #subcatArray >= #subcatDef.items then
            subcatArray = {}
        end

        local newEntry = {
            profession = st.prof,
            type = st.bankType,
            tabs = #tabsArray > 0 and tabsArray or nil,
        }
        if st.bankType == "charbank" then
            newEntry.char = st.char
        end
        if st.bankType == "guildbank" then
            newEntry.guild = st.guild
            newEntry.realm = st.guildRealm
            if st.char then
                newEntry.char = st.char
            end
        end
        if #expArray > 0 then
            newEntry.expansions = expArray
        end
        if #subcatArray > 0 then
            newEntry.subcategories = subcatArray
        end

        -- Duplicate check (skip self in edit mode)
        local function SameSet(a, b)
            -- Compare two arrays-as-sets (nil/empty treated as equal)
            a = a or {}
            b = b or {}
            if #a ~= #b then
                return false
            end
            local setA = {}
            for _, v in ipairs(a) do
                setA[tostring(v)] = true
            end
            for _, v in ipairs(b) do
                if not setA[tostring(v)] then
                    return false
                end
            end
            return true
        end
        local assignments = self.db.global.storageAssignments
        for i, existing in ipairs(assignments) do
            if
                (not isEdit or i ~= editIdx)
                and existing.profession == newEntry.profession
                and existing.type == newEntry.type
                and existing.char == newEntry.char
                and existing.guild == newEntry.guild
                and (existing.realm or "") == (newEntry.realm or "")
                and SameSet(existing.expansions, newEntry.expansions)
                and SameSet(existing.subcategories, newEntry.subcategories)
            then
                self:ChatMsg("A rule for this category and destination already exists", true)
                return
            end
        end

        if isEdit then
            assignments[editIdx] = newEntry
            EmpireManager._storageScrollToIdx = editIdx
        else
            assignments[#assignments + 1] = newEntry
            EmpireManager._storageScrollToIdx = #assignments
        end

        if newEntry.char and newEntry.char ~= "self" then
            self:SyncBankerRole(newEntry.char)
        end
        self:InvalidateStorageCache()
        f:Hide()
        self:SelectDashboardTab("storage")
    end)

    -- Delete button (edit only)
    f.DeleteButton:SetScript("OnClick", function()
        if not isEdit then
            return
        end
        StaticPopupDialogs["EM_DELETE_STORAGE_RULE"] = StaticPopupDialogs["EM_DELETE_STORAGE_RULE"]
            or {
                text = "Delete this storage rule?",
                button1 = "Delete",
                button2 = "Cancel",
                OnAccept = function() end,
                timeout = 0,
                whileDead = true,
                hideOnEscape = true,
                showAlert = true,
                preferredIndex = 3,
            }
        StaticPopupDialogs["EM_DELETE_STORAGE_RULE"].OnAccept = function()
            table.remove(self.db.global.storageAssignments, editIdx)
            self:InvalidateStorageCache()
            f:Hide()
            self:SelectDashboardTab("storage")
        end
        StaticPopup_Show("EM_DELETE_STORAGE_RULE")
    end)

    UpdateLayout()
    f:Show()
end

-------------------------------------------------------------------------------
-- Unconfigured Categories Notice
-------------------------------------------------------------------------------

function EMStoragePageMixin:BuildUnconfiguredText(assignments)
    local configuredProfs = {}
    for _, asn in ipairs(assignments) do
        configuredProfs[asn.profession] = true
    end
    local missing = {}
    for _, info in ipairs(EmpireManager.PROF_DISPLAY) do
        if not configuredProfs[info.key] then
            missing[#missing + 1] =
                string.format("|cff%02x%02x%02x%s|r", info.r * 255, info.g * 255, info.b * 255, info.label)
        end
    end
    for _, info in ipairs(EmpireManager.STORAGE_CATEGORY_DISPLAY) do
        if not configuredProfs[info.key] then
            missing[#missing + 1] =
                string.format("|cff%02x%02x%02x%s|r", info.r * 255, info.g * 255, info.b * 255, info.label)
        end
    end
    if #missing > 0 then
        local lines = { "Not configured:" }
        for i = 1, #missing, 7 do
            local row = {}
            for j = i, math.min(i + 6, #missing) do
                row[#row + 1] = missing[j]
            end
            lines[#lines + 1] = table.concat(row, ", ")
        end
        return table.concat(lines, "\n")
    end
    return nil
end

-------------------------------------------------------------------------------
-- Bank Restock (par-level stocking) - Stage A: data + UI only.
-- Mirrors the Storage page (list, reorder, fill display) and adds an AH-browse
-- style Add/Edit item picker. The deposit engine lives in Restock.lua.
-------------------------------------------------------------------------------

-- EMRestockRowMixin / EMRestockItemRowMixin / EMRestockPageMixin are forward-declared
-- in Dashboard.lua (loaded first) so the dashboard's nativePages table can reference
-- them before this file populates their methods. Do not reassign them to {} here.

-- Columns mirror STORAGE_COLUMNS but add Quality + Profession. The Destination
-- column fills remaining width (fill = true), like Storage.
local RESTOCK_COLUMNS = {
    { key = "reorder", width = 60, label = "" },
    { key = "item", width = 200, label = "Item" },
    { key = "prof", width = 90, label = "Professions" },
    { key = "target", width = 56, label = "Target" },
    { key = "fill", width = 104, label = "Fill Level" },
    { key = "dest", width = 0, label = "Destination", fill = true },
}
local RESTOCK_ROW_HEIGHT = 24
-- Picker row height (Add/Edit dialog item list)
local RESTOCK_ITEM_ROW_HEIGHT = 22
-- Cap of profession icons shown inline before the "+N" overflow indicator.
local RESTOCK_MAX_PROF_ICONS = 4

-------------------------------------------------------------------------------
-- Restock helpers (file-local)
-------------------------------------------------------------------------------

-- Resolve an item's name/icon from cache; returns name, icon (both nil if uncached).
local function RestockItemInfo(itemID)
    local name, _, _, _, _, _, _, _, _, icon = C_Item.GetItemInfo(itemID)
    return name, icon
end

-- Quality info for an itemID: returns the Blizzard CraftingQualityInfo struct (or
-- nil for non-quality items). We ask the game for the struct rather than mapping a
-- tier number to an atlas name ourselves, because the atlas-per-quality mapping is
-- expansion-specific: Midnight reagents have only 2 qualities (silver/gold), so a
-- quality of 1 must render the SILVER chevron, not the old 3-tier copper Tier1 art.
-- This mirrors Blizzard's ItemButtonTemplate (SetItemCraftingQualityOverlay).
local function RestockQualityInfo(itemID, itemLink)
    if not C_TradeSkillUI then
        return nil
    end
    local info
    if C_TradeSkillUI.GetItemReagentQualityInfo then
        info = C_TradeSkillUI.GetItemReagentQualityInfo(itemID)
    end
    if not info and itemLink and C_TradeSkillUI.GetItemCraftedQualityInfo then
        info = C_TradeSkillUI.GetItemCraftedQualityInfo(itemLink)
    end
    return info
end

-- Tier number (1/2/.. as the game reports it) for tooltips/debug, or nil.
local function RestockItemTier(itemID, itemLink)
    local info = RestockQualityInfo(itemID, itemLink)
    return info and info.quality
end

-- The small quality chevron atlas for an item, straight from the game's quality
-- struct (.iconSmall). Correct across expansions including Midnight's 2-tier scale.
local function RestockTierAtlas(itemID, itemLink)
    local info = RestockQualityInfo(itemID, itemLink)
    return info and info.iconSmall
end

-- All professions whose curated set or subclass match contains the itemID, as an
-- ordered list of PROF_DISPLAY entries (stable display order). Uses the same match
-- set triage routing uses so the column stays consistent.
local function RestockProfList(itemID)
    local set = EmpireManager:GetItemProfMatchSet(itemID)
    if not set then
        return {}
    end
    local out = {}
    for _, info in ipairs(EmpireManager.PROF_DISPLAY) do
        if set[info.key] then
            out[#out + 1] = info
        end
    end
    return out
end

-- The "category" of a restock entry for same-profession shift-jump reordering:
-- the first matching profession key (best effort - entries store itemID, not a
-- profKey, so this is derived).
local function RestockEntryCategory(entry)
    if not entry or not entry.itemID then
        return ""
    end
    local list = RestockProfList(entry.itemID)
    return (list[1] and list[1].key) or ""
end

-- Destination text for a restock entry. Warband is marked account-shared; guild
-- shows its name; char shows the owner (class-colored).
-- Resolve a charbank/bags entry's target characters as an array of GUIDs.
-- New entries store `entry.chars` (multi-select); older entries store a single
-- `entry.char`. Returns a (possibly empty) array.
local function RestockEntryChars(entry)
    if entry.chars and #entry.chars > 0 then
        return entry.chars
    end
    if entry.char then
        return { entry.char }
    end
    return {}
end

local function RestockDestText(entry)
    if entry.dest == "warbandbank" then
        return "|cff66b3ffWarband|r Bank"
    elseif entry.dest == "guildbank" then
        local prefix = entry.guild and ("|cff40ff40" .. entry.guild .. "|r ") or ""
        return prefix .. "|cff40ff40Guild|r Bank"
    elseif entry.dest == "charbank" or entry.dest == "bags" then
        local suffix = (entry.dest == "bags") and " Bags" or " Bank"
        local chars = RestockEntryChars(entry)
        if #chars == 0 then
            return "?" .. suffix
        end
        if #chars == 1 then
            local guid = chars[1]
            if guid == "self" and entry.dest == "charbank" then
                return "Character Bank"
            end
            local e = EmpireManager.db.global.registry[guid]
            local charName = e and EmpireManager:ClassColoredName(e) or "?"
            return charName .. suffix
        end
        -- Multiple characters: list as many names as fit a plain-text budget,
        -- then "+N" for the overflow. The Destination column is the fill column,
        -- so this stays on one line at the row's available width.
        local CHAR_BUDGET = 32 -- approx plain-text chars before the suffix
        local parts, plainLen, shown = {}, 0, 0
        for i, guid in ipairs(chars) do
            local e = EmpireManager.db.global.registry[guid]
            local nm = e and e.name or "?"
            local addLen = (#parts > 0 and 2 or 0) + #nm -- ", " separator
            if shown > 0 and plainLen + addLen > CHAR_BUDGET then
                break
            end
            parts[#parts + 1] = (e and EmpireManager:ClassColoredName(e)) or "?"
            plainLen = plainLen + addLen
            shown = i
        end
        local text = table.concat(parts, ", ")
        if shown < #chars then
            text = text .. string.format(" |cffffd200+%d|r", #chars - shown)
        end
        return text .. suffix
    end
    return entry.dest or "?"
end

-- Per-character snapshot counts for a charbank/bags entry. Returns an ordered
-- array { {guid, name, count, hasData}, ... } - count is 0 when the char has been
-- snapshotted but holds none; hasData is false when that char was never snapshotted.
local function RestockPerCharCounts(entry)
    local counts = EmpireManager.db.global.restockCounts or {}
    local prefix = (entry.dest == "bags") and "bags:" or "charbank:"
    local out = {}
    for _, guid in ipairs(RestockEntryChars(entry)) do
        local byDest = counts[prefix .. guid]
        local reg = EmpireManager.db.global.registry[guid]
        out[#out + 1] = {
            guid = guid,
            name = reg and EmpireManager:ClassColoredName(reg) or "?",
            count = byDest and (byDest[entry.itemID] or 0) or 0,
            hasData = byDest ~= nil,
        }
    end
    return out
end

-- Fill state of an entry, read from the per-item snapshot (db.global.restockCounts).
-- Returns: current, effectiveTarget (or nil when no data at all).
--   * warband / guild: a single shared destination - current vs entry.target.
--   * charbank / bags: target is PER CHARACTER. current = sum across all target
--     chars; effectiveTarget = entry.target * N (so 54/70 = 54 held across 7 chars
--     with a floor of 10 each). Color follows the sum ratio.
-- "0" (snapshotted, item absent) is distinct from nil (never snapshotted -> "No data").
local function RestockFillState(entry)
    local counts = EmpireManager.db.global.restockCounts
    if not counts then
        return nil
    end
    local target = entry.target or 0
    if entry.dest == "guildbank" and entry.guild then
        local byDest = counts["guildbank:" .. EmpireManager:GuildKey(entry.guild, entry.realm)]
        if not byDest then
            return nil
        end
        return byDest[entry.itemID] or 0, target
    elseif entry.dest == "charbank" or entry.dest == "bags" then
        local per = RestockPerCharCounts(entry)
        local n = #per
        if n == 0 then
            return nil
        end
        local total, any = 0, false
        for _, c in ipairs(per) do
            if c.hasData then
                any = true
            end
            total = total + c.count
        end
        if not any then
            return nil
        end
        return total, target * n
    end
    local byDest = counts[entry.dest]
    if not byDest then
        return nil
    end
    return byDest[entry.itemID] or 0, target
end

-------------------------------------------------------------------------------
-- EMRestockRowMixin (virtualized list row; mirrors EMStorageRowMixin)
-------------------------------------------------------------------------------

function EMRestockRowMixin:OnLoad()
    local UP_PATH = "Interface\\AddOns\\EmpireManager\\Textures\\up"
    local DOWN_PATH = "Interface\\AddOns\\EmpireManager\\Textures\\down"

    -- Shared reorder handler factory (dir = -1 up, +1 down)
    local function MakeReorder(dir)
        return function()
            local d = self._data
            if not d then
                return
            end
            local a = EmpireManager.db.global.restockList
            local idx = d.idx
            -- Target index in the FINAL list (after the move). nil = no-op.
            local target
            if IsShiftKeyDown() then
                -- Jump to just past the next rule of the same category in `dir`.
                local cat = RestockEntryCategory(d.entry)
                if dir < 0 then
                    for i = idx - 1, 1, -1 do
                        if RestockEntryCategory(a[i]) == cat then
                            target = i
                            break
                        end
                    end
                else
                    for i = idx + 1, #a do
                        if RestockEntryCategory(a[i]) == cat then
                            target = i
                            break
                        end
                    end
                end
            elseif IsControlKeyDown() then
                target = idx + dir * 5
            else
                target = idx + dir
            end
            -- Clamp to a valid slot and ignore no-ops / out-of-range edge clicks
            -- (e.g. Up on the first row, Down on the last).
            if target then
                target = math.max(1, math.min(#a, target))
            end
            if not target or target == idx then
                return
            end
            -- remove-then-insert keeps the list contiguous regardless of distance.
            local rule = table.remove(a, idx)
            table.insert(a, target, rule)
            EmpireManager._restockScrollToIdx = target
            EmpireManager:InvalidateStorageCache() -- priority changed: recalc triage
            EmpireManager:RefreshTriageIfOpen()
            EmpireManager:SelectDashboardTab("restock")
        end
    end

    -- Up button
    self.UpBtn = CreateFrame("Button", nil, self)
    self.UpBtn:SetSize(16, 16)
    self.UpBtn:SetPoint("LEFT", self, "LEFT", 12, 0)
    self.UpBtn:SetNormalTexture(UP_PATH)
    self.UpBtn:GetNormalTexture():SetVertexColor(1, 0.82, 0)
    self.UpBtn:SetPushedTexture(UP_PATH)
    self.UpBtn:GetPushedTexture():SetVertexColor(0.8, 0.65, 0)
    self.UpBtn:SetDisabledTexture(UP_PATH)
    self.UpBtn:GetDisabledTexture():SetDesaturated(true)
    self.UpBtn:GetDisabledTexture():SetVertexColor(0.4, 0.4, 0.4)
    self.UpBtn:SetHighlightTexture(UP_PATH, "ADD")
    self.UpBtn:GetHighlightTexture():SetVertexColor(1, 1, 0.6)
    self.UpBtn:GetHighlightTexture():SetAlpha(0.5)
    self.UpBtn:SetScript("OnClick", MakeReorder(-1))

    -- Down button
    self.DownBtn = CreateFrame("Button", nil, self)
    self.DownBtn:SetSize(16, 16)
    self.DownBtn:SetPoint("LEFT", self.UpBtn, "RIGHT", 6, 0)
    self.DownBtn:SetNormalTexture(DOWN_PATH)
    self.DownBtn:GetNormalTexture():SetVertexColor(1, 0.82, 0)
    self.DownBtn:SetPushedTexture(DOWN_PATH)
    self.DownBtn:GetPushedTexture():SetVertexColor(0.8, 0.65, 0)
    self.DownBtn:SetDisabledTexture(DOWN_PATH)
    self.DownBtn:GetDisabledTexture():SetDesaturated(true)
    self.DownBtn:GetDisabledTexture():SetVertexColor(0.4, 0.4, 0.4)
    self.DownBtn:SetHighlightTexture(DOWN_PATH, "ADD")
    self.DownBtn:GetHighlightTexture():SetVertexColor(1, 1, 0.6)
    self.DownBtn:GetHighlightTexture():SetAlpha(0.5)
    self.DownBtn:SetScript("OnClick", MakeReorder(1))

    -- Cells are anchored to the RESTOCK_COLUMNS header edges (cumulative widths:
    -- reorder 0-60, item 60-260, prof 260-350, target 350-406, fill 406-510,
    -- dest 510+) so the data lines up with the header row. Do not retune these
    -- piecemeal; they are derived from the column widths.

    -- Item icon + name (item column: left edge 60)
    self.ItemIcon = self:CreateTexture(nil, "ARTWORK")
    self.ItemIcon:SetSize(18, 18)
    self.ItemIcon:SetPoint("LEFT", self, "LEFT", 66, 0)
    self.ItemIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    -- Crafting-quality tier chevron overlaid on the icon corner (Blizzard pattern:
    -- ProfessionQualityOverlay, TOPLEFT -3,2, native atlas size).
    self.TierOverlay = self:CreateTexture(nil, "OVERLAY", nil, 7)
    self.TierOverlay:SetPoint("CENTER", self.ItemIcon, "TOPLEFT", 2, -2)
    self.TierOverlay:Hide()

    self.NameFs = self:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
    self.NameFs:SetPoint("LEFT", self.ItemIcon, "RIGHT", 4, 0)
    self.NameFs:SetWidth(168) -- ends before the prof column (260)
    self.NameFs:SetJustifyH("LEFT")
    self.NameFs:SetWordWrap(false)

    -- Same insets Storage uses: left text at col_left+8 width col_width-4; right
    -- text at col_left-8 width col_width-4 (right edge = col_right-12); bar col_left+2.

    -- Profession icons (prof column 260-350, left)
    self.ProfFs = self:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
    self.ProfFs:SetPoint("LEFT", self, "LEFT", 268, 0)
    self.ProfFs:SetWidth(86)
    self.ProfFs:SetJustifyH("LEFT")
    self.ProfFs:SetWordWrap(false)

    -- Target count (target column 350-406, right-justified - Storage fill recipe)
    self.TargetFs = self:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
    self.TargetFs:SetPoint("LEFT", self, "LEFT", 342, 0)
    self.TargetFs:SetWidth(52)
    self.TargetFs:SetJustifyH("RIGHT")
    self.TargetFs:SetWordWrap(false)

    -- Fill bar (col_left+2) + fill text (right-justified, Storage recipe) - fill
    -- column 406-510.
    self.FillBar = self:CreateTexture(nil, "ARTWORK")
    self.FillBar:SetPoint("TOPLEFT", self, "TOPLEFT", 408, -2)
    self.FillBar:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", 408, 2)
    self.FillBar:SetColorTexture(1, 1, 1, 1)
    self.FillBar:Hide()

    self.FillFs = self:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
    self.FillFs:SetPoint("LEFT", self, "LEFT", 398, 0)
    self.FillFs:SetWidth(100)
    self.FillFs:SetJustifyH("RIGHT")
    self.FillFs:SetWordWrap(false)

    -- Destination (dest column left edge 510, fills remaining width; text inset +8)
    self.DestFs = self:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
    self.DestFs:SetPoint("LEFT", self, "LEFT", 518, 0)
    self.DestFs:SetJustifyH("LEFT")
    self.DestFs:SetWordWrap(false)

    -- Click handlers (right/double-click -> edit, like Storage rows)
    self:SetScript("OnClick", function(f, button)
        if button == "RightButton" and f._data then
            EmpireManager:OpenRestockDialog(f._data.idx)
        end
    end)
    self:SetScript("OnDoubleClick", function(f)
        if f._data then
            EmpireManager:OpenRestockDialog(f._data.idx)
        end
    end)

    local function showRowTooltip(f)
        local d = f._data
        if not d then
            return
        end
        local entry = d.entry
        GameTooltip:SetOwner(f, "ANCHOR_CURSOR_RIGHT")
        -- Game item tooltip first, then a separator + our restock info below it.
        GameTooltip:SetItemByID(entry.itemID)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(string.format("Restock #%d", d.idx), 1, 0.82, 0)
        local ttTier = RestockItemTier(entry.itemID, select(2, C_Item.GetItemInfo(entry.itemID)))
        if ttTier then
            GameTooltip:AddLine("Quality: Tier " .. tostring(ttTier), 1, 1, 1)
        end
        GameTooltip:AddLine("Target: " .. tostring(entry.target or 0), 1, 1, 1)
        if entry.dest == "charbank" or entry.dest == "bags" then
            -- List every target character (the column / RestockDestText caps with +N).
            local suffix = (entry.dest == "bags") and "Bags" or "Bank"
            local chars = RestockEntryChars(entry)
            if #chars <= 1 then
                GameTooltip:AddLine("Keep in: " .. RestockDestText(entry):gsub("|cff%x%x%x%x%x%x", ""):gsub("|r", ""), 1, 1, 1)
            else
                -- Per-character fill: "8/10  Name" (count colored by met/short/no-data).
                local target = entry.target or 0
                GameTooltip:AddLine(string.format("Keep in: %s (%d characters, %d each)", suffix, #chars, target), 1, 1, 1)
                for _, c in ipairs(RestockPerCharCounts(entry)) do
                    -- "8/10  Name": fill colored by met (green) / short (red) /
                    -- no-data (grey), then the class-colored name inline after it.
                    local hex, fill
                    if not c.hasData then
                        hex, fill = "ff808080", "?/" .. target
                    elseif c.count >= target then
                        hex, fill = "ff00cc00", c.count .. "/" .. target
                    else
                        hex, fill = "ffff3333", c.count .. "/" .. target
                    end
                    GameTooltip:AddLine(string.format("   |c%s%s|r  %s", hex, fill, c.name), 1, 1, 1)
                end
            end
        else
            GameTooltip:AddLine("Keep in: " .. RestockDestText(entry):gsub("|cff%x%x%x%x%x%x", ""):gsub("|r", ""), 1, 1, 1)
        end
        -- Full profession list (the column caps with +N)
        local profs = RestockProfList(entry.itemID)
        if #profs > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Used by:", 1, 0.82, 0)
            for _, info in ipairs(profs) do
                GameTooltip:AddLine(
                    string.format("|T%s:14:14|t %s", info.icon, info.label),
                    info.r,
                    info.g,
                    info.b
                )
            end
        end
        GameTooltip:Show()
    end

    local function inReorderCol(f)
        local cursorX = GetCursorPosition()
        local scale = f:GetEffectiveScale()
        local relX = (cursorX / scale) - f:GetLeft()
        return relX < 60
    end

    self:SetScript("OnEnter", function(f)
        if not f._data then
            return
        end
        f._tooltipShown = not inReorderCol(f)
        if f._tooltipShown then
            showRowTooltip(f)
        end
        f._tooltipTimer = 0
        f:SetScript("OnUpdate", function(fr, elapsed)
            fr._tooltipTimer = (fr._tooltipTimer or 0) + elapsed
            if fr._tooltipTimer < 0.1 then
                return
            end
            fr._tooltipTimer = 0
            if not fr._data then
                return
            end
            local inCol = inReorderCol(fr)
            if inCol and fr._tooltipShown then
                GameTooltip:Hide()
                fr._tooltipShown = false
            elseif not inCol and not fr._tooltipShown then
                showRowTooltip(fr)
                fr._tooltipShown = true
            end
        end)
    end)
    self:SetScript("OnLeave", function(f)
        f:SetScript("OnUpdate", nil)
        f._tooltipShown = false
        GameTooltip:Hide()
    end)
end

function EMRestockRowMixin:Populate(data)
    self._data = data
    local idx = data.idx
    local entry = data.entry

    -- Zebra stripe
    if idx % 2 == 0 then
        self.Stripe:SetAtlas("auctionhouse-rowstripe-1")
    else
        self.Stripe:SetAtlas("auctionhouse-rowstripe-2")
    end

    -- Up/down enable state
    self.UpBtn:SetEnabled(idx > 1)
    self.DownBtn:SetEnabled(idx < data.totalCount)

    -- Item name/icon (load-on-demand; placeholder + request if uncached)
    local name, icon = RestockItemInfo(entry.itemID)
    if name then
        data.resolvedName = name
        local q = select(3, C_Item.GetItemInfo(entry.itemID))
        local color = (q and ITEM_QUALITY_COLORS[q]) or HIGHLIGHT_FONT_COLOR
        self.NameFs:SetText(name)
        self.NameFs:SetTextColor(color.r, color.g, color.b)
        self.ItemIcon:SetTexture(icon)
        self.ItemIcon:Show()
    else
        self.NameFs:SetText(entry.name or "Loading...")
        self.NameFs:SetTextColor(1, 1, 1)
        self.ItemIcon:SetTexture(134400) -- "?" placeholder
        self.ItemIcon:Show()
        C_Item.RequestLoadItemDataByID(entry.itemID)
        EmpireManager:RestockWatchItem(entry.itemID)
    end

    -- Tier chevron overlaid on the item icon corner (not a separate column).
    local rowAtlas = RestockTierAtlas(entry.itemID, select(2, C_Item.GetItemInfo(entry.itemID)))
    if rowAtlas then
        self.TierOverlay:SetAtlas(rowAtlas, false)
        self.TierOverlay:SetSize(16, 16)
        self.TierOverlay:Show()
    else
        self.TierOverlay:Hide()
    end

    -- Profession icons (capped with +N overflow; full list in row tooltip)
    local profs = RestockProfList(entry.itemID)
    local parts = {}
    local shown = math.min(#profs, RESTOCK_MAX_PROF_ICONS)
    for i = 1, shown do
        parts[#parts + 1] = string.format("|T%s:18:18|t", profs[i].icon)
    end
    local text = table.concat(parts, " ")
    if #profs > shown then
        text = text .. string.format(" |cffffd200+%d|r", #profs - shown)
    end
    self.ProfFs:SetText(text)

    -- Target count (always visible, independent of whether a current-count exists)
    local target = entry.target or 0
    self.TargetFs:SetText(BreakUpLargeNumbers(target))
    self.TargetFs:SetTextColor(1, 1, 1)

    -- Fill level (INVERTED colors vs storage: green = at/above target = good).
    -- For multi-character charbank/bags rules the target is per-character, so the
    -- effective target is target x (number of chars) and current sums all of them
    -- (e.g. 54/70 = 54 across 7 chars, floor 10 each). Color follows the sum ratio.
    local current, effTarget = RestockFillState(entry)
    if current and effTarget and effTarget > 0 then
        local pct = math.floor((current / effTarget) * 100)
        self.FillFs:SetText(string.format("%d/%d", current, effTarget))
        local r, g, b
        if pct >= 100 then
            r, g, b = 0.0, 0.8, 0.0
        elseif pct >= 50 then
            r, g, b = 1.0, 0.8, 0.0
        else
            r, g, b = 1.0, 0.2, 0.2
        end
        self.FillFs:SetTextColor(r, g, b)
        local frac = math.min(1, current / effTarget)
        local barWidth = math.max(1, math.floor(100 * frac + 0.5))
        self.FillBar:SetWidth(barWidth)
        self.FillBar:SetVertexColor(r, g, b, 0.18)
        self.FillBar:Show()
    else
        self.FillFs:SetText("No data")
        self.FillFs:SetTextColor(0.5, 0.5, 0.5)
        self.FillBar:Hide()
    end

    -- Destination
    self.DestFs:SetText(RestockDestText(entry))
    self.DestFs:SetTextColor(1, 1, 1)
end

-------------------------------------------------------------------------------
-- EMRestockItemRowMixin (Add/Edit dialog item-picker row)
-------------------------------------------------------------------------------

function EMRestockItemRowMixin:OnLoad()
    self.Icon = self:CreateTexture(nil, "ARTWORK")
    self.Icon:SetSize(18, 18)
    self.Icon:SetPoint("LEFT", self, "LEFT", 4, 0)
    self.Icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    -- Tier chevron overlaid on the icon corner (Blizzard ProfessionQualityOverlay).
    self.TierOverlay = self:CreateTexture(nil, "OVERLAY", nil, 7)
    self.TierOverlay:SetPoint("CENTER", self.Icon, "TOPLEFT", 2, -2)
    self.TierOverlay:Hide()

    -- Profession icons for the item (right side), shown regardless of the active
    -- profession filter so the player can see what each item is used by.
    self.ProfFs = self:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
    self.ProfFs:SetPoint("RIGHT", self, "RIGHT", -6, 0)
    self.ProfFs:SetJustifyH("RIGHT")
    self.ProfFs:SetWordWrap(false)

    self.NameFs = self:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
    self.NameFs:SetPoint("LEFT", self.Icon, "RIGHT", 4, 0)
    self.NameFs:SetPoint("RIGHT", self.ProfFs, "LEFT", -6, 0)
    self.NameFs:SetJustifyH("LEFT")
    self.NameFs:SetWordWrap(false)

    -- Selected highlight (kept under HIGHLIGHT; tinted gold when selected)
    self.SelTex = self:CreateTexture(nil, "BACKGROUND", nil, 1)
    self.SelTex:SetAllPoints(self)
    self.SelTex:SetColorTexture(1, 0.82, 0, 0.18)
    self.SelTex:Hide()

    self:SetScript("OnClick", function(f)
        -- Ignore clicks while dragging an item on the cursor. Without this the
        -- click both selects the row AND WoW's default drop behavior fires,
        -- causing the picked-up item to land somewhere unexpected and the
        -- row's onSelect to run with a mismatched itemID.
        if GetCursorInfo() then
            return
        end
        if f._data and f._data.onSelect then
            f._data.onSelect(f._data.itemID)
        end
    end)

    -- Item tooltip on the right of the dialog (like triage rows).
    self:SetScript("OnEnter", function(f)
        if not (f._data and f._data.itemID) then
            return
        end
        GameTooltip:SetOwner(EmpireManagerRestockDialog, "ANCHOR_NONE")
        GameTooltip:SetPoint("TOPLEFT", EmpireManagerRestockDialog, "TOPRIGHT", 4, 0)
        GameTooltip:SetItemByID(f._data.itemID)
        GameTooltip:Show()
    end)
    self:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

function EMRestockItemRowMixin:Populate(data)
    self._data = data
    local idx = data.idx or 1
    if idx % 2 == 0 then
        self.Stripe:SetAtlas("auctionhouse-rowstripe-1")
    else
        self.Stripe:SetAtlas("auctionhouse-rowstripe-2")
    end

    local name, icon = RestockItemInfo(data.itemID)
    if name then
        local q = select(3, C_Item.GetItemInfo(data.itemID))
        local color = (q and ITEM_QUALITY_COLORS[q]) or HIGHLIGHT_FONT_COLOR
        self.NameFs:SetText(name)
        self.NameFs:SetTextColor(color.r, color.g, color.b)
        self.Icon:SetTexture(icon)
        -- Tier chevron overlaid on the icon corner.
        local atlas = RestockTierAtlas(data.itemID, select(2, C_Item.GetItemInfo(data.itemID)))
        if atlas then
            self.TierOverlay:SetAtlas(atlas, false)
            self.TierOverlay:SetSize(16, 16)
            self.TierOverlay:Show()
        else
            self.TierOverlay:Hide()
        end
    else
        self.NameFs:SetText("Loading...")
        self.NameFs:SetTextColor(1, 1, 1)
        self.Icon:SetTexture(134400)
        self.TierOverlay:Hide()
        C_Item.RequestLoadItemDataByID(data.itemID)
        EmpireManager:RestockWatchItem(data.itemID)
    end

    -- Profession icons (capped; full list is implicit, this is a glance hint).
    local profs = RestockProfList(data.itemID)
    local parts = {}
    local shown = math.min(#profs, 3)
    for i = 1, shown do
        parts[#parts + 1] = string.format("|T%s:16:16|t", profs[i].icon)
    end
    local profText = table.concat(parts, " ")
    if #profs > shown then
        profText = profText .. string.format(" |cffffd200+%d|r", #profs - shown)
    end
    self.ProfFs:SetText(profText)

    self.SelTex:SetShown(data.selected and true or false)
end

-------------------------------------------------------------------------------
-- EMRestockPageMixin
-------------------------------------------------------------------------------

function EMRestockPageMixin:OnLoad()
    self.ScrollBox = self.Inset.ScrollBox
    self.ScrollBar = self.Inset.ScrollBar

    local view = CreateScrollBoxListLinearView()
    view:SetElementFactory(function(factory, elementData)
        if elementData.type == "entry" then
            factory("EMRestockRowTemplate", function(frame, data)
                if not frame._mixinApplied then
                    Mixin(frame, EMRestockRowMixin)
                    frame:OnLoad()
                    frame._mixinApplied = true
                end
                frame:Populate(data)
            end)
        else
            factory("EMStorageNoticeTemplate", function(frame, data)
                if not frame._noticeInit then
                    frame.Text = frame:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
                    frame.Text:SetPoint("TOPLEFT", 8, -4)
                    frame.Text:SetPoint("RIGHT", -8, 0)
                    frame.Text:SetJustifyH("LEFT")
                    frame._noticeInit = true
                end
                frame.Text:SetWordWrap(true)
                frame.Text:SetNonSpaceWrap(true)
                frame.Text:SetText(data.text or "")
                frame.Text:SetTextColor(1, 1, 1)
            end)
        end
    end)
    view:SetElementExtentCalculator(function(_dataIndex, elementData)
        if elementData.type == "empty_notice" then
            return 56
        end
        return RESTOCK_ROW_HEIGHT
    end)
    ScrollUtil.InitScrollBoxListWithScrollBar(self.ScrollBox, self.ScrollBar, view)

    -- Import/Export button (icon-only, texture set in XML) - mirrors the Storage
    -- tab's IEButton: opens the shared IE window, hiding the Add dialog first if
    -- it is up so the two modals don't fight for focus.
    local ieBtn = self.IEButton
    EmpireManager:StyleIconButton(ieBtn, 0.5)
    ieBtn:SetScript("OnClick", function()
        local ie = EmpireManagerIOFrame
        if ie and ie:IsShown() then
            return
        end
        local rd = EmpireManagerRestockDialog
        if rd and rd:IsShown() then
            rd:Hide()
        end
        EmpireManager:ToggleIOWindow()
    end)
    ieBtn:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Import / Export", 1, 0.82, 0)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Import or export restock rules.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    ieBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Add button
    EmpireManager:StyleIconButton(self.AddButton, 0.5)
    self.AddButton:SetScript("OnClick", function()
        local rd = EmpireManagerRestockDialog
        if rd and rd:IsShown() then
            return
        end
        local ie = EmpireManagerIOFrame
        if ie and ie:IsShown() then
            ie:Hide()
        end
        EmpireManager:OpenRestockDialog(nil)
    end)
    self.AddButton:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Add Restock Rule", 1, 0.82, 0)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Keep a minimum quantity of an item topped up in a bank.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    self.AddButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Column headers
    self:InitRestockHeaders()

    -- Drag-to-reorder (needs the ScrollBox initialized above)
    self:InitDragToReorder()

    -- Private GET_ITEM_INFO_RECEIVED listener: refresh the page when item data for
    -- a watched itemID lands (load-on-demand for names/icons/tiers).
    self._itemWatch = {}
    self._itemEvents = CreateFrame("Frame", nil, self)
    self._itemEvents:SetScript("OnEvent", function(_, _event, itemID)
        if not self._itemWatch[itemID] then
            return
        end
        self._itemWatch[itemID] = nil
        if not next(self._itemWatch) then
            self._itemEvents:UnregisterEvent("GET_ITEM_INFO_RECEIVED")
        end
        -- Throttle: coalesce a burst of GET_ITEM_INFO_RECEIVED into one refresh of
        -- both the page (if shown) and the open Add/Edit dialog item list.
        if self._refreshThrottle then
            return
        end
        self._refreshThrottle = true
        C_Timer.After(0.1, function()
            self._refreshThrottle = nil
            if self:IsShown() then
                self:Refresh()
            end
            local rd = EmpireManagerRestockDialog
            if rd and rd:IsShown() and rd._refreshItemList then
                rd._refreshItemList()
                if rd._updateLayout then
                    rd._updateLayout()
                end
            end
        end)
    end)
end

function EMRestockPageMixin:InitDragToReorder()
    InitListDragToReorder(self, {
        entryType = "entry",
        entryKey = "entry",
        listKey = "restockList",
        rowHeight = RESTOCK_ROW_HEIGHT,
        afterReorder = function()
            EmpireManager:InvalidateStorageCache() -- priority changed: recalc triage
            EmpireManager:RefreshTriageIfOpen()
        end,
    })
end

function EMRestockPageMixin:InitRestockHeaders()
    local container = self.Inset.HeaderContainer
    local xOffset = 0
    for _, col in ipairs(RESTOCK_COLUMNS) do
        local btn = CreateFrame("Button", nil, container, "ColumnDisplayButtonShortTemplate")
        if col.fill then
            btn:SetPoint("LEFT", container, "LEFT", xOffset, 0)
            btn:SetPoint("RIGHT", container, "RIGHT", 0, 0)
            btn:SetHeight(19)
        else
            btn:SetSize(col.width, 19)
            btn:SetPoint("LEFT", container, "LEFT", xOffset, 0)
        end
        btn:SetText(col.label)
        btn:SetNormalFontObject(GameFontHighlightSmall)
        -- Right-justify numeric columns (Target, Fill) so headers line up with the
        -- right-aligned cell values; everything else stays left like Storage.
        local justify = (col.key == "target" or col.key == "fill") and "RIGHT" or "LEFT"
        btn:GetFontString():SetJustifyH(justify)
        btn:SetEnabled(false)
        xOffset = xOffset + col.width
    end
end

function EMRestockPageMixin:OnShow()
    -- Refresh this character's bag counts so "Character Bags" rules show a live
    -- fill level the moment the tab opens (cheap synchronous read).
    if EmpireManager.SnapshotBagItemCounts then
        EmpireManager:SnapshotBagItemCounts()
    end
    self:Refresh()
end

-- Refresh the Restock list if it is currently shown (no-op otherwise). Called by
-- the restock engine after deposits update the fill counts.
function EmpireManager:RefreshRestockTab()
    local page = EmpireManagerFrame and EmpireManagerFrame.RestockPage
    if page and page:IsShown() and page.Refresh then
        page:Refresh()
    end
end

-- Register an itemID so the page refreshes when its data arrives.
function EmpireManager:RestockWatchItem(itemID)
    local page = EmpireManagerFrame and EmpireManagerFrame.RestockPage
    if page and page._itemEvents then
        if not next(page._itemWatch) then
            page._itemEvents:RegisterEvent("GET_ITEM_INFO_RECEIVED")
        end
        page._itemWatch[itemID] = true
    end
end

function EMRestockPageMixin:Refresh()
    local list = EmpireManager.db.global.restockList or {}
    local data = {}

    if #list == 0 then
        data[#data + 1] = {
            type = "empty_notice",
            text = "\nNo restock rules configured yet. Click 'Add Restock Rule' to keep a minimum quantity of an item topped up in a bank.",
        }
    else
        for i, entry in ipairs(list) do
            data[#data + 1] = {
                type = "entry",
                idx = i,
                entry = entry,
                totalCount = #list,
            }
        end
    end

    local savedOffset = self.ScrollBox:GetScrollPercentage()
    local dataProvider = CreateDataProvider(data)
    self.ScrollBox:SetDataProvider(dataProvider)

    -- Scroll-follow after reorder wins over saved-offset restore.
    local scrollTo = EmpireManager._restockScrollToIdx
    EmpireManager._restockScrollToIdx = nil
    if scrollTo and scrollTo > 0 then
        C_Timer.After(0, function()
            local dp = self.ScrollBox:GetDataProvider()
            if not dp then
                return
            end
            for _, elementData in dp:Enumerate() do
                if elementData.type == "entry" and elementData.idx == scrollTo then
                    self.ScrollBox:ScrollToElementData(elementData, ScrollBoxConstants.AlignCenter)
                    break
                end
            end
        end)
    elseif savedOffset and savedOffset >= 0 then
        C_Timer.After(0, function()
            if self.ScrollBox:GetDataProvider() then
                self.ScrollBox:SetScrollPercentage(savedOffset)
            end
        end)
    end
end

-------------------------------------------------------------------------------
-- Restock Add/Edit Dialog (AH-browse style picker)
-------------------------------------------------------------------------------

function EmpireManager:InitRestockDialog()
    local f = EmpireManagerRestockDialog
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

    f.SaveButton:SetText("Save")
    f.DeleteButton:SetText("|cffff4444Delete|r")
    f.CancelButton:SetText("Cancel")
    f.CancelButton:SetScript("OnClick", function()
        f:Hide()
    end)
    f.CloseButton:SetScript("OnClick", function()
        f:Hide()
    end)

    -- ESC closes the dialog (not the dashboard behind it)
    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            self:Hide()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)

    -- On close (Cancel / X / ESC), blank the visible widgets and drop the
    -- attached state so nothing lingers when the dialog is reopened.
    f:SetScript("OnHide", function()
        if f.SelectedIcon then
            f.SelectedIcon:Hide()
        end
        if f.SelectedTier then
            f.SelectedTier:Hide()
        end
        if f.SelectedFs then
            f.SelectedFs:SetText("|cff9d9d9dSelect an item above|r")
        end
        if f.SearchBox then
            f.SearchBox:SetText("")
            f.SearchBox:ClearFocus()
        end
        -- Drop the session's spinner callback. The next Open sets a fresh one,
        -- but the first Open-time SetValue (edit branch) fires BEFORE the new
        -- callback is registered - the still-attached previous-session callback
        -- would run with a wiped st and schedule a deferred UpdateLayout that
        -- lands after the new session's UpdateLayout, blanking the visible state.
        if f.TargetBox and f.TargetBox.SetOnValueChangedCallback then
            f.TargetBox:SetOnValueChangedCallback(nil)
        end
        if f._state then
            wipe(f._state)
            f._state = nil
        end
    end)

    -- Filter row: Category DD + Search box split 50/50. Category filter uses the
    -- AH's Trade Goods subclass tree (Herb / Cloth / Other / Optional Reagents /
    -- etc.) so cross-profession reagents don't need per-item PROF_ITEM_OVERRIDES
    -- entries - the picker groups by GetItemInfoInstant subclass at render time.
    f.SectionDD = CreateFrame("DropdownButton", nil, f.FilterRow, "WowStyle1DropdownTemplate")
    f.SectionDD:SetPoint("LEFT", f.FilterRow, "LEFT", 0, 0)
    f.SectionDD:SetPoint("RIGHT", f.FilterRow, "CENTER", -4, 0)

    f.SearchBox = CreateFrame("EditBox", nil, f.FilterRow, "SearchBoxTemplate")
    f.SearchBox:SetPoint("LEFT", f.FilterRow, "CENTER", 4, 0)
    f.SearchBox:SetPoint("RIGHT", f.FilterRow, "RIGHT", 0, 0)
    f.SearchBox:SetHeight(22)

    -- Item list ScrollBox view
    f.ListScrollBox = f.ListInset.ScrollBox
    f.ListScrollBar = f.ListInset.ScrollBar
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(RESTOCK_ITEM_ROW_HEIGHT)
    view:SetElementInitializer("EMRestockItemRowTemplate", function(frame, elementData)
        if not frame._mixinApplied then
            Mixin(frame, EMRestockItemRowMixin)
            frame:OnLoad()
            frame._mixinApplied = true
        end
        frame:Populate(elementData)
    end)
    ScrollUtil.InitScrollBoxListWithScrollBar(f.ListScrollBox, f.ListScrollBar, view)

    -- Detail rows (anchored to f.DetailRow). "Selected" echo.
    local detailRow = f.DetailRow

    -- Bordered inset that groups the selected item + target + "Keep in:" controls,
    -- matching the item-list inset style (Blizzard NineSlice / InsetFrameTemplate).
    f.DetailInset = CreateFrame("Frame", nil, detailRow)
    f.DetailInset:SetPoint("TOPLEFT", detailRow, "TOPLEFT", 0, 6)
    f.DetailInset:SetPoint("TOPRIGHT", detailRow, "TOPRIGHT", 0, 6)
    f.DetailInset:SetHeight(98)
    f.DetailInset.Bg = f.DetailInset:CreateTexture(nil, "BACKGROUND")
    f.DetailInset.Bg:SetPoint("TOPLEFT", 3, -3)
    f.DetailInset.Bg:SetPoint("BOTTOMRIGHT", -3, 3)
    f.DetailInset.Bg:SetAtlas("auctionhouse-background-index")
    f.DetailInset.NineSlice = CreateFrame("Frame", nil, f.DetailInset, "NineSlicePanelTemplate")
    f.DetailInset.NineSlice:SetAllPoints(f.DetailInset)
    if NineSliceUtil and NineSliceUtil.ApplyLayout then
        NineSliceUtil.ApplyLayout(f.DetailInset.NineSlice, NineSliceUtil.GetLayout("InsetFrameTemplate"))
    end

    -- The inset is a drop target: drag (or click while holding) an item onto it to
    -- select that itemID, same as dropping on the search box.
    local function dropSelect()
        local infoType, id = GetCursorInfo()
        if infoType == "item" and id and f._selectItemID then
            f._selectItemID(id)
            ClearCursor()
        end
    end
    f.DetailInset:EnableMouse(true)
    f.DetailInset:RegisterForDrag("LeftButton")
    f.DetailInset:SetScript("OnReceiveDrag", dropSelect)
    f.DetailInset:SetScript("OnMouseUp", dropSelect)

    -- Controls live INSIDE the inset, padded from its edges.
    local detail = f.DetailInset
    local PAD = 12

    -- Rectangle frame around the selected-item icon.
    f.SelectedIconFrame = CreateFrame("Frame", nil, detail, "BackdropTemplate")
    f.SelectedIconFrame:SetSize(31, 31)
    f.SelectedIconFrame:SetPoint("TOPLEFT", detail, "TOPLEFT", PAD, -12)
    f.SelectedIconFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    f.SelectedIconFrame:SetBackdropColor(0, 0, 0, 0)
    f.SelectedIconFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

    -- Show the real item tooltip on hover (only when an item is selected).
    f.SelectedIconFrame:EnableMouse(true)
    f.SelectedIconFrame:SetScript("OnEnter", function(self)
        local id = f._state and f._state.itemID
        if not id then
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetItemByID(id)
        GameTooltip:Show()
    end)
    f.SelectedIconFrame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    -- Dropping an item directly on the icon slot also selects it.
    f.SelectedIconFrame:RegisterForDrag("LeftButton")
    f.SelectedIconFrame:SetScript("OnReceiveDrag", dropSelect)
    f.SelectedIconFrame:SetScript("OnMouseUp", dropSelect)

    f.SelectedIcon = detail:CreateTexture(nil, "ARTWORK")
    f.SelectedIcon:SetSize(27, 27)
    f.SelectedIcon:SetPoint("CENTER", f.SelectedIconFrame, "CENTER", 0, 0)
    f.SelectedIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    f.SelectedIcon:Hide()

    -- Tier chevron overlaid on the selected-item icon corner.
    f.SelectedTier = detail:CreateTexture(nil, "OVERLAY", nil, 7)
    f.SelectedTier:SetPoint("CENTER", f.SelectedIcon, "TOPLEFT", 3, -3)
    f.SelectedTier:Hide()

    f.SelectedFs = detail:CreateFontString(nil, "OVERLAY", FONT_NORMAL)
    -- Vertically centered on the icon frame.
    f.SelectedFs:SetPoint("LEFT", f.SelectedIconFrame, "RIGHT", 6, 0)
    f.SelectedFs:SetJustifyH("LEFT")
    f.SelectedFs:SetText("|cff9d9d9dSelect an item above|r")

    -- Quality is implicit in the itemID (each tier is a distinct item), so there is
    -- no tier selector and entries store no tier field.

    -- Target spinner: Blizzard NumericInputSpinnerTemplate (numeric edit + up/down
    -- arrows, like the profession create-multiple box). On the same line as the
    -- selected item. No "Target:" label.
    f.TargetBox = CreateFrame("EditBox", nil, detail, "NumericInputSpinnerTemplate")
    -- Right-aligned in the inset; leave room for the increment arrow + padding.
    f.TargetBox:SetPoint("RIGHT", detail, "RIGHT", -(PAD + 22 + 16), 0)
    f.TargetBox:SetPoint("TOP", f.SelectedIconFrame, "TOP", 0, -4)
    f.TargetBox:SetSize(40, 22)
    f.TargetBox:SetMinMaxValues(1, 9999)
    f.TargetBox:SetMaxLetters(4) -- allow up to 9999 (4 digits)
    -- Clamp at the limits (stock behaviour) and grey the arrow you can't use:
    -- Decrement disabled at 1, Increment disabled at 9999.
    local function UpdateTargetArrows()
        local v = f.TargetBox:GetValue() or 1
        if f.TargetBox.DecrementButton then
            f.TargetBox.DecrementButton:SetEnabled(v > 1)
        end
        if f.TargetBox.IncrementButton then
            f.TargetBox.IncrementButton:SetEnabled(v < 9999)
        end
    end
    f._updateTargetArrows = UpdateTargetArrows
    -- Keep the selected-item name from overlapping the spinner.
    f.SelectedFs:SetPoint("RIGHT", f.TargetBox, "LEFT", -8, 0)

    -- Destination row (label + Bank type DD + conditional Char/Guild/Tabs DD),
    -- second line of the inset. "Keep in:" aligns under the item icon's left edge.
    f.BankTypeDD = CreateFrame("DropdownButton", nil, detail, "WowStyle1DropdownTemplate")
    f.BankTypeDD:SetPoint("TOPLEFT", f.SelectedIconFrame, "BOTTOMLEFT", 60, -12)
    f.BankTypeDD:SetWidth(140)

    f.DestLabel = detail:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    -- "Keep in:" label, vertically centered on the dropdown, left-padded in the inset.
    f.DestLabel:SetPoint("RIGHT", f.BankTypeDD, "LEFT", -8, 0)
    f.DestLabel:SetText("|cffffd200Keep in:|r")
    f.DestLabel:SetJustifyH("LEFT")

    -- Second destination dropdown reused for Char OR Guild (shown conditionally)
    f.DestSubDD = CreateFrame("DropdownButton", nil, detail, "WowStyle1DropdownTemplate")
    f.DestSubDD:SetPoint("LEFT", f.BankTypeDD, "RIGHT", 6, 0)
    f.DestSubDD:SetWidth(170)

    return f
end

function EmpireManager:OpenRestockDialog(editIdx)
    local f = self:InitRestockDialog()
    local isEdit = editIdx ~= nil
    local entry = isEdit and self.db.global.restockList[editIdx] or nil

    f.TitleText:SetText(
        isEdit
            and string.format("EmpireManager - Edit Restock Rule #%d", editIdx)
            or "EmpireManager - Add Restock Rule"
    )
    if f.DescText then
        f.DescText:SetText(
            "Pick an item: click one in the list below, type a name to search, enter an item ID and press Enter, "
                .. "or drag an item onto the search box or the item frame at the bottom. "
                .. "Then set a target quantity and choose where to keep it stocked."
        )
    end
    -- Delete stays visible on a new rule but is disabled (nothing to delete yet).
    f.DeleteButton:SetShown(true)
    f.DeleteButton:SetEnabled(isEdit)

    -- Dialog state
    local st = {
        section = nil, -- AH category filter ("classID/subClassID" key), nil = all
        search = "",
        itemID = nil,
        bankType = nil,
        char = nil, -- guild banker (single)
        chars = {}, -- charbank/bags target characters (multi-select set: guid -> true)
        guild = nil,
        guildRealm = nil,
    }
    if isEdit and entry then
        st.itemID = entry.itemID
        st.bankType = entry.dest
        st.char = entry.char
        st.guild = entry.guild
        st.guildRealm = entry.realm
        for _, guid in ipairs(RestockEntryChars(entry)) do
            st.chars[guid] = true
        end
        f.TargetBox:SetValue(entry.target or 1)
        -- Default the picker's Category filter to the item's own AH section so
        -- the rest of the same-bucket items are the initial browse view - but
        -- only if the item falls into a known AH Reagents subclass. Items
        -- outside Trade Goods (e.g. Consumables like potions, added via shift-
        -- click) have no matching bucket in the picker; leave the filter at
        -- "All Categories" so the list isn't empty.
        local key = EmpireManager.GetAHSectionKey(entry.itemID)
        if key and self.AH_SECTIONS[key] then
            st.section = key
        end
    else
        f.TargetBox:SetValue(1)
    end
    if f._updateTargetArrows then
        f._updateTargetArrows() -- reflect the loaded value before any change
    end
    f._state = st

    -- Forward declarations
    local UpdateLayout, RefreshItemList

    UpdateLayout = function()
        -- Selected echo
        if st.itemID then
            local name, icon = RestockItemInfo(st.itemID)
            f.SelectedIcon:SetTexture(icon or 134400)
            f.SelectedIcon:Show()
            -- Tier chevron on the selected-item icon (if the item has a quality).
            local selAtlas = RestockTierAtlas(st.itemID, select(2, C_Item.GetItemInfo(st.itemID)))
            if selAtlas then
                f.SelectedTier:SetAtlas(selAtlas, false)
                f.SelectedTier:SetSize(20, 20)
                f.SelectedTier:Show()
            else
                f.SelectedTier:Hide()
            end
            if name then
                local q = select(3, C_Item.GetItemInfo(st.itemID))
                -- ITEM_QUALITY_COLORS[q] is a plain {r,g,b,hex} table (no ColorMixin
                -- methods), so set the text then color it via SetTextColor.
                local color = (q and ITEM_QUALITY_COLORS[q]) or HIGHLIGHT_FONT_COLOR
                f.SelectedFs:SetText(name)
                f.SelectedFs:SetTextColor(color.r, color.g, color.b)
            else
                f.SelectedFs:SetTextColor(1, 1, 1)
                f.SelectedFs:SetText("Loading...")
                C_Item.RequestLoadItemDataByID(st.itemID)
                EmpireManager:RestockWatchItem(st.itemID)
            end
        else
            f.SelectedIcon:Hide()
            f.SelectedTier:Hide()
            f.SelectedFs:SetTextColor(0.616, 0.616, 0.616)
            f.SelectedFs:SetText("Select an item above")
        end

        -- Category filter display. If the section key is unknown (e.g. an item
        -- outside AH_SECTIONS somehow got picked), fall back to "All Categories"
        -- instead of rendering the raw "classID/subClassID" string.
        local sectionLabel = "All Categories"
        if st.section then
            local info = self.AH_SECTIONS[st.section]
            if info then
                sectionLabel = info.label
            end
        end
        f.SectionDD:OverrideText(sectionLabel)

        -- Destination
        local btLabels = {
            warbandbank = "Warband Bank",
            guildbank = "Guild Bank",
            charbank = "Character Bank",
            bags = "Character Bags",
        }
        f.BankTypeDD:OverrideText(st.bankType and btLabels[st.bankType] or "Select destination")
        local showChar = (st.bankType == "charbank" or st.bankType == "bags")
        local showGuild = (st.bankType == "guildbank")
        f.DestSubDD:SetShown(showChar or showGuild)
        if showChar then
            local charList = BuildCharList()
            local picked = {}
            for guid in pairs(st.chars) do
                picked[#picked + 1] = guid
            end
            if #picked == 0 then
                f.DestSubDD:OverrideText("Select Characters")
            elseif #picked == 1 then
                f.DestSubDD:OverrideText(charList[picked[1]] or picked[1])
            else
                f.DestSubDD:OverrideText(string.format("%d characters", #picked))
            end
        elseif showGuild then
            f.DestSubDD:OverrideText(st.guild or "Select Guild")
        end

        -- Save gating: item + target(>0) + destination valid.
        local target = f.TargetBox:GetValue()
        local valid = st.itemID and target and target > 0 and st.bankType
        if (st.bankType == "charbank" or st.bankType == "bags") and not next(st.chars) then
            valid = false
        end
        if st.bankType == "guildbank" and (not st.guild or st.guild == "") then
            valid = false
        end
        f.SaveButton:SetEnabled(valid and true or false)
    end

    -- Build the filtered item list for the picker. Filters: AH Category (Trade Goods
    -- subclass, from GetItemInfoInstant) and a substring name search. Search is a
    -- GLOBAL find: when there is text, the Category dropdown is ignored and the
    -- whole RESTOCK_ITEMS pool is matched by name. Uncached items are request-loaded
    -- and reappear on refresh.
    RefreshItemList = function()
        local seen = {}
        local items = {}
        local search = (st.search or ""):lower()

        local function consider(itemID)
            if seen[itemID] then
                return
            end
            seen[itemID] = true
            if search ~= "" then
                local name = RestockItemInfo(itemID)
                if not name then
                    -- Not yet cached: request and skip for now (will reappear on refresh).
                    C_Item.RequestLoadItemDataByID(itemID)
                    EmpireManager:RestockWatchItem(itemID)
                    return
                end
                if not name:lower():find(search, 1, true) then
                    return
                end
            end
            items[#items + 1] = itemID
        end

        local searching = (search ~= "")

        -- AH section filter: classID/subClassID from GetItemInfoInstant (synchronous,
        -- no cache wait). Items whose subclass doesn't resolve fall into no bucket
        -- and only surface when the Category filter is "All".
        local function matchesSection(itemID)
            if not st.section then
                return true
            end
            return EmpireManager.GetAHSectionKey(itemID) == st.section
        end

        for _, pool in pairs(self.RESTOCK_ITEMS) do
            for _, itemID in ipairs(pool) do
                -- Skip itemIDs this client does not know. GetItemInfoInstant is
                -- client-side and synchronous (no server round trip), so a nil here
                -- means the item does not exist on this build - a stale entry from
                -- the /em gendata AH scan, or an item removed by a patch. Such rows
                -- never resolve: they render "Loading..." forever and re-arm the
                -- GET_ITEM_INFO_RECEIVED watcher on every repaint, which kept the
                -- picker rebuilding itself endlessly (the flicker). Filtering here
                -- makes the picker immune to bad data instead of relying on the
                -- table being perfectly curated.
                if C_Item.GetItemInfoInstant(itemID) then
                    if searching or matchesSection(itemID) then
                        consider(itemID)
                    end
                end
            end
        end

        -- Sort by resolved name (cached first, alphabetical), then by itemID.
        table.sort(items, function(a, b)
            local na = RestockItemInfo(a)
            local nb = RestockItemInfo(b)
            if na and nb then
                return na:lower() < nb:lower()
            elseif na then
                return true
            elseif nb then
                return false
            end
            return a < b
        end)

        local data = {}
        local selectedIdx
        for i, itemID in ipairs(items) do
            if itemID == st.itemID then
                selectedIdx = i
            end
            data[#data + 1] = {
                idx = i,
                itemID = itemID,
                selected = (itemID == st.itemID),
                onSelect = function(id)
                    -- Just move the highlight; don't rebuild the list (that flickers).
                    st.itemID = id
                    f.ListScrollBox:ForEachFrame(function(frame, elementData)
                        if frame.SelTex then
                            frame.SelTex:SetShown(elementData.itemID == id)
                        end
                    end)
                    UpdateLayout()
                end,
            }
            -- Request-load uncached items so names/icons fill in.
            if not RestockItemInfo(itemID) then
                C_Item.RequestLoadItemDataByID(itemID)
                EmpireManager:RestockWatchItem(itemID)
            end
        end
        local savedPct = f.ListScrollBox:GetScrollPercentage()
        f.ListScrollBox:SetDataProvider(CreateDataProvider(data))
        if f._scrollToSelected and selectedIdx then
            -- Requested by the caller (dialog open in edit mode): bring the selected
            -- item into view. Two subtleties:
            --  1. Use ScrollToElementData(..., AlignCenter) instead of
            --     ScrollToElementDataIndex(idx). Without an alignment, the ScrollBox
            --     may treat the top-of-list default position as "close enough" and
            --     skip the scroll entirely when the target is technically off-screen;
            --     AlignCenter forces the row to the middle of the viewport.
            --  2. Keep the flag alive until the selected item's own name has resolved,
            --     since the list re-sorts alphabetically each time
            --     GET_ITEM_INFO_RECEIVED fires - if we cleared the flag now, the
            --     target row would move on the next refresh and never re-scroll.
            if RestockItemInfo(st.itemID) then
                f._scrollToSelected = nil
            end
            local targetItemID = st.itemID
            C_Timer.After(0, function()
                local dp = f.ListScrollBox:GetDataProvider()
                if not dp then
                    return
                end
                for _, elementData in dp:Enumerate() do
                    if elementData.itemID == targetItemID then
                        f.ListScrollBox:ScrollToElementData(elementData, ScrollBoxConstants.AlignCenter)
                        break
                    end
                end
            end)
        elseif savedPct and savedPct >= 0 then
            -- Preserve scroll position across rebuilds (e.g. selecting an item just
            -- updates the highlight; the list should not jump back to the top).
            C_Timer.After(0, function()
                f.ListScrollBox:SetScrollPercentage(savedPct)
            end)
        end
    end
    f._refreshItemList = RefreshItemList
    f._updateLayout = UpdateLayout

    -- Category filter dropdown (All + each AH Trade Goods subclass present in the
    -- source pool). Uses GetItemInfoInstant at menu-build time to compute which
    -- sections have items - no static profession -> subclass map needed.
    f.SectionDD:SetupMenu(function(_, rootDescription)
        rootDescription:CreateRadio("All Categories", function()
            return st.section == nil
        end, function()
            st.section = nil
            RefreshItemList()
            UpdateLayout()
        end)
        rootDescription:CreateDivider()

        -- Compute which section keys are present in the current RESTOCK_ITEMS pool.
        local present = {}
        for _, pool in pairs(self.RESTOCK_ITEMS) do
            for _, itemID in ipairs(pool) do
                local key = EmpireManager.GetAHSectionKey(itemID)
                if key then
                    present[key] = true
                end
            end
        end

        for _, key in ipairs(self.AH_SECTION_ORDER) do
            if present[key] then
                local info = self.AH_SECTIONS[key]
                rootDescription:CreateRadio(
                    string.format("|T%s:14:14|t %s", info.icon, info.label),
                    function()
                        return st.section == key
                    end,
                    function()
                        st.section = key
                        RefreshItemList()
                        UpdateLayout()
                    end
                )
            end
        end
    end)



    -- Search box doubles as an item drop target: dragging an item onto it (any
    -- item, even non-reagents) selects that itemID directly. Plain typed text
    -- filters the picker list. Handled directly (not via SetupItemInputBox)
    -- so no SetText(link)->OnTextChanged detour leaves the SearchBox in a
    -- state Blizzard's spinner arrow-click chain could clobber.
    local function selectItemID(id)
        f.SearchBox:SetText("")
        f.SearchBox:ClearFocus()
        st.search = ""
        st.itemID = id
        if not RestockItemInfo(id) then
            C_Item.RequestLoadItemDataByID(id)
            EmpireManager:RestockWatchItem(id)
        end
        RefreshItemList()
        UpdateLayout()
    end
    -- Expose for the detail inset's drop handler (created once in InitRestockDialog).
    f._selectItemID = selectItemID
    -- Direct drop handlers on SearchBox: drag-drop and click-with-item-on-cursor
    -- route through selectItemID, same as a click on the DetailInset.
    local function searchDropSelect()
        local infoType, id = GetCursorInfo()
        if infoType == "item" and id then
            selectItemID(id)
            ClearCursor()
        end
    end
    f.SearchBox:SetScript("OnReceiveDrag", searchDropSelect)
    f.SearchBox:SetScript("OnMouseDown", searchDropSelect)
    -- Type-to-filter and itemID+Enter hooks were previously HookScript'd inside
    -- OpenRestockDialog, but HookScript ACCUMULATES - every reopen added another
    -- closure over the current-then st, and old ones kept firing on later opens
    -- against wiped state. Register them ONCE via f._initHooksDone flag, and
    -- route through f._state / f._selectItemID which the current session sets.
    if not f._initHooksDone then
        f.SearchBox:HookScript("OnTextChanged", function(box)
            local s = f._state
            if not s then
                return
            end
            local text = box:GetText() or ""
            if text ~= (s.search or "") then
                s.search = text
                if f._refreshItemList then
                    f._refreshItemList()
                end
            end
        end)
        f.SearchBox:HookScript("OnEnterPressed", function(box)
            local text = (box:GetText() or ""):gsub("%s", "")
            local id = tonumber(text:match("^(%d+)$"))
            if id and f._selectItemID then
                f._selectItemID(id)
                box:ClearFocus()
            end
        end)
        f._initHooksDone = true
    end
    f.SearchBox:SetText("")

    -- Session-ID guard: each OpenRestockDialog call bumps f._sessionId; the
    -- callback and its deferred timer capture this session's ID and bail if
    -- the current session has moved on. Without this, a pending C_Timer.After
    -- from the previous session's arrow-callback would fire after the new
    -- session's UpdateLayout, overwriting the new item with the previous
    -- session's (from savedItemID) - which is exactly the "edit/cancel cycle"
    -- bug: the arrows the user pressed in the Add session left a timer
    -- pending that fired inside the following Edit session.
    f._sessionId = (f._sessionId or 0) + 1
    local mySession = f._sessionId

    -- Target spinner: re-validate Save on every value change (typed or arrows).
    -- Defer UpdateLayout one frame to avoid a same-frame race in Blizzard's
    -- spinner event chain that clobbered st.itemID; save/restore + session
    -- guard together keep the selection intact regardless.
    f.TargetBox:SetOnValueChangedCallback(function()
        if f._sessionId ~= mySession then
            return
        end
        local savedItemID = st.itemID
        if f._updateTargetArrows then
            f._updateTargetArrows()
        end
        C_Timer.After(0, function()
            if f._sessionId ~= mySession then
                return
            end
            if savedItemID and not st.itemID then
                st.itemID = savedItemID
            end
            UpdateLayout()
        end)
    end)

    -- Bank type dropdown (REUSES the storage destination model)
    f.BankTypeDD:SetupMenu(function(_, rootDescription)
        local labels = {
            warbandbank = "Warband Bank",
            guildbank = "Guild Bank",
            charbank = "Character Bank",
            bags = "Character Bags",
        }
        for _, bt in ipairs({ "warbandbank", "guildbank", "charbank", "bags" }) do
            rootDescription:CreateRadio(labels[bt], function()
                return st.bankType == bt
            end, function()
                st.bankType = bt
                st.char = nil
                wipe(st.chars)
                st.guild = nil
                st.guildRealm = nil
                C_Timer.After(0, UpdateLayout)
            end)
        end
    end)

    -- Destination sub dropdown (Char when charbank; Guild when guildbank). Mirrors
    -- the storage rule editor's Char/Guild dropdowns.
    local subSelIdx
    f.DestSubDD:SetupMenu(function(_, rootDescription)
        subSelIdx = nil
        if st.bankType == "charbank" or st.bankType == "bags" then
            rootDescription:SetScrollMode(20 * 20)
            local charList, charOrder = BuildCharList()
            for i, guid in ipairs(charOrder) do
                if st.chars[guid] then
                    subSelIdx = subSelIdx or i
                end
                rootDescription:CreateCheckbox(charList[guid], function()
                    return st.chars[guid] == true
                end, function()
                    if st.chars[guid] then
                        st.chars[guid] = nil
                    else
                        st.chars[guid] = true
                    end
                    C_Timer.After(0, UpdateLayout)
                end)
            end
        elseif st.bankType == "guildbank" then
            rootDescription:SetScrollMode(20 * 20)
            local guilds = BuildGuildList()
            for i, item in ipairs(guilds) do
                if item.guild == st.guild and item.realm == st.guildRealm then
                    subSelIdx = i
                end
                rootDescription:CreateRadio(item.label, function()
                    return st.guild == item.guild and st.guildRealm == item.realm
                end, function()
                    st.guild = item.guild
                    st.guildRealm = item.realm
                    local banker = self:FindCharInGuild(item.guild, nil, item.realm)
                    if banker then
                        st.char = banker
                    end
                    C_Timer.After(0, UpdateLayout)
                end)
            end
        end
    end)
    self:EnableDropdownScrollToSelected(f.DestSubDD, function()
        return subSelIdx
    end)

    -- Save button
    f.SaveButton:SetScript("OnClick", function()
        local target = f.TargetBox:GetValue()
        if not st.itemID then
            self:ChatMsg("Select an item", true)
            return
        end
        if not target or target <= 0 then
            self:ChatMsg("Enter a target quantity", true)
            return
        end
        if not st.bankType then
            self:ChatMsg("Select a bank type", true)
            return
        end
        if (st.bankType == "charbank" or st.bankType == "bags") and not next(st.chars) then
            self:ChatMsg("Select at least one character", true)
            return
        end
        if st.bankType == "guildbank" and (not st.guild or st.guild == "") then
            self:ChatMsg("Select a guild", true)
            return
        end

        local newEntry = {
            itemID = st.itemID,
            target = target,
            dest = st.bankType,
            name = RestockItemInfo(st.itemID) or (entry and entry.name) or ("Item " .. st.itemID),
        }
        if st.bankType == "guildbank" then
            newEntry.guild = st.guild
            newEntry.realm = st.guildRealm
        elseif st.bankType == "charbank" or st.bankType == "bags" then
            -- Multi-select: keep a stable, char-list-ordered array of GUIDs.
            local _, charOrder = BuildCharList()
            local chars = {}
            for _, guid in ipairs(charOrder) do
                if st.chars[guid] then
                    chars[#chars + 1] = guid
                end
            end
            newEntry.chars = chars
        end

        -- Duplicate check (same item+tier+destination), skip self in edit mode. For
        -- char/bags the destination is the *set* of characters, so a rule differing
        -- only by which characters it targets is not a duplicate.
        local function sameChars(a, b)
            local ca, cb = RestockEntryChars(a), RestockEntryChars(b)
            if #ca ~= #cb then
                return false
            end
            local set = {}
            for _, g in ipairs(ca) do
                set[g] = true
            end
            for _, g in ipairs(cb) do
                if not set[g] then
                    return false
                end
            end
            return true
        end
        local list = self.db.global.restockList
        for i, ex in ipairs(list) do
            if
                (not isEdit or i ~= editIdx)
                and ex.itemID == newEntry.itemID
                and tostring(ex.tier) == tostring(newEntry.tier)
                and ex.dest == newEntry.dest
                and ex.guild == newEntry.guild
                and (ex.realm or "") == (newEntry.realm or "")
                and sameChars(ex, newEntry)
            then
                self:ChatMsg("A restock rule for this item and destination already exists", true)
                return
            end
        end

        if isEdit then
            list[editIdx] = newEntry
            EmpireManager._restockScrollToIdx = editIdx
        else
            list[#list + 1] = newEntry
            EmpireManager._restockScrollToIdx = #list
        end

        -- A restock rule change alters the floor, so the triage classification is
        -- stale. Drop the cached results and repaint (same as storage-rule edits).
        self:InvalidateStorageCache()
        self:RefreshTriageIfOpen()

        if newEntry.dest == "charbank" then
            -- Char-bank deposits require a banker on each target character.
            for _, guid in ipairs(newEntry.chars or {}) do
                if guid ~= "self" then
                    self:SyncBankerRole(guid)
                end
            end
        elseif newEntry.char and newEntry.char ~= "self" then
            self:SyncBankerRole(newEntry.char)
        end
        f:Hide()
        self:SelectDashboardTab("restock")
    end)

    -- Delete button (edit only)
    f.DeleteButton:SetScript("OnClick", function()
        if not isEdit then
            return
        end
        StaticPopupDialogs["EM_DELETE_RESTOCK_RULE"] = StaticPopupDialogs["EM_DELETE_RESTOCK_RULE"]
            or {
                text = "Delete this restock rule?",
                button1 = "Delete",
                button2 = "Cancel",
                OnAccept = function() end,
                timeout = 0,
                whileDead = true,
                hideOnEscape = true,
                showAlert = true,
                preferredIndex = 3,
            }
        StaticPopupDialogs["EM_DELETE_RESTOCK_RULE"].OnAccept = function()
            table.remove(self.db.global.restockList, editIdx)
            self:InvalidateStorageCache() -- floor removed: recalc triage
            self:RefreshTriageIfOpen()
            f:Hide()
            self:SelectDashboardTab("restock")
        end
        StaticPopup_Show("EM_DELETE_RESTOCK_RULE")
    end)

    -- On open, bring the pre-selected item (edit mode) into view in the picker.
    if st.itemID then
        f._scrollToSelected = true
    end
    -- Show() FIRST so the ScrollBox has real layout metrics before RefreshItemList
    -- schedules its C_Timer.After(0) scroll-to-selected. Building the list before
    -- Show() made the initial scroll no-op because ScrollToElementDataIndex ran on
    -- an unlaid-out frame - the picked item would sit off-screen until a second
    -- refresh (triggered by GET_ITEM_INFO_RECEIVED) fired the scroll on a settled
    -- frame. The scroll flag is kept alive across refreshes until the item's own
    -- name resolves (see RefreshItemList), so any lingering race resolves itself.
    f:Show()
    RefreshItemList()
    UpdateLayout()
end

-------------------------------------------------------------------------------
-- Import / Export
-------------------------------------------------------------------------------

function EmpireManager:InitIOFrame()
    local f = EmpireManagerIOFrame
    if f._initialized then
        return
    end
    f._initialized = true

    -- Backdrop
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })
    f:SetBackdropColor(0.06, 0.06, 0.09, 0.95)

    -- Title
    f.TitleText:SetText("EmpireManager - Import/Export")

    -- Subtitle: explain the dialog handles both directions
    local subtitle = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    subtitle:SetPoint("TOP", f.TitleText, "BOTTOM", 0, -8)
    subtitle:SetPoint("LEFT", f, "LEFT", 24, 0)
    subtitle:SetPoint("RIGHT", f, "RIGHT", -24, 0)
    subtitle:SetJustifyH("CENTER")
    subtitle:SetWordWrap(true)
    subtitle:SetText("|cffdaa520Characters and Storage Rules can be exported for sharing/backup or imported.|r")
    -- Push the EditScroll down to clear the new line.
    f.EditScroll:ClearAllPoints()
    f.EditScroll:SetPoint("TOPLEFT", f, "TOPLEFT", 32, -84)

    -- Close button
    f.CloseButton:SetScript("OnClick", function()
        PlaySound(SOUNDKIT.IG_CHARACTER_INFO_CLOSE)
        f:Hide()
    end)

    -- Draggable
    f:RegisterForDrag("LeftButton")

    -- ESC registration. Register the real XML frame name (untainted), not a Lua
    -- _G alias - a tainted alias taints Blizzard's secure CloseSpecialWindows loop.
    if self.db.global.options.escToClose and not tContains(UISpecialFrames, "EmpireManagerIOFrame") then
        tinsert(UISpecialFrames, "EmpireManagerIOFrame")
    end

    -- Edit box reference
    local editBox = f.EditScroll.EditBox

    -- Disable wrap: force a wide fixed width so long lines scroll horizontally
    -- instead of wrapping. InputScrollFrameTemplate normally resizes the
    -- EditBox to match the ScrollFrame width on every size change, so we
    -- clear that script and pin it wide.
    f.EditScroll:SetScript("OnSizeChanged", nil)
    editBox:SetWidth(4000)
    f.EditScroll:SetHorizontalScroll(0)

    -- Move the scrollbar outside the bordered input area, to the right
    local sb = f.EditScroll.ScrollBar
    if sb then
        sb:ClearAllPoints()
        sb:SetPoint("TOPLEFT", f.EditScroll, "TOPRIGHT", 10, 0)
        sb:SetPoint("BOTTOMLEFT", f.EditScroll, "BOTTOMRIGHT", 10, 0)
    end

    -- Status text (below edit box)
    local statusText = f.StatusFrame.StatusText
    statusText:SetText(" ")

    -- Bottom row: [ExportDD][Export]          [Auto-assign] [Import]
    -- Export type dropdown
    local exportDD = CreateFrame("DropdownButton", nil, f, "WowStyle1DropdownTemplate")
    exportDD:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 24, 20)
    exportDD:SetWidth(160)
    f._exportType = "all"

    -- Auto-assign checkbox
    local autoAssignCB = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    autoAssignCB:SetChecked(true)
    f._autoAssign = autoAssignCB

    local cbLabel = autoAssignCB:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    cbLabel:SetText("Auto-assign roles")
    local function showAutoAssignTip(anchor)
        GameTooltip:SetOwner(anchor, "ANCHOR_CURSOR")
        GameTooltip:AddLine("Auto-Assign Roles", 1, 0.82, 0)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(
            "Assign Artisan/Gatherer roles from detected professions for all imported characters.",
            1,
            1,
            1,
            true
        )
        GameTooltip:Show()
    end
    local function hideAutoAssignTip()
        GameTooltip:Hide()
    end
    autoAssignCB:SetScript("OnEnter", function(btn)
        showAutoAssignTip(btn)
    end)
    autoAssignCB:SetScript("OnLeave", hideAutoAssignTip)
    local autoAssignHit = CreateFrame("Frame", nil, f)
    autoAssignHit:SetAllPoints(cbLabel)
    autoAssignHit:SetScript("OnEnter", function(h)
        showAutoAssignTip(h)
    end)
    autoAssignHit:SetScript("OnLeave", hideAutoAssignTip)

    -- Replace rules checkbox
    local replaceCB = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    replaceCB:SetChecked(false)
    f._replaceRules = replaceCB

    local replaceLabel = replaceCB:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    replaceLabel:SetText("Replace existing")
    replaceLabel:SetPoint("LEFT", replaceCB, "RIGHT", 2, 0)
    local function showReplaceTip(anchor)
        GameTooltip:SetOwner(anchor, "ANCHOR_CURSOR")
        GameTooltip:AddLine("Replace Existing", 1, 0.82, 0)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(
            "When checked, each section present in the paste wipes its target list before importing:",
            1, 1, 1, true
        )
        GameTooltip:AddLine("  " .. "|cffffd200Storage Rules|r wipes Storage Rules", 1, 1, 1)
        GameTooltip:AddLine("  " .. "|cffffd200Keep List|r wipes Keep List", 1, 1, 1)
        GameTooltip:AddLine("  " .. "|cffffd200Vendor Whitelist|r wipes Vendor Whitelist", 1, 1, 1)
        GameTooltip:AddLine("  " .. "|cffffd200Restock Rules|r wipes Restock Rules", 1, 1, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("When unchecked, entries merge (duplicates skipped).", 1, 1, 1, true)
        GameTooltip:Show()
    end
    local function hideReplaceTip()
        GameTooltip:Hide()
    end
    replaceCB:SetScript("OnEnter", function(btn)
        showReplaceTip(btn)
    end)
    replaceCB:SetScript("OnLeave", hideReplaceTip)
    local replaceHit = CreateFrame("Frame", nil, f)
    replaceHit:SetAllPoints(replaceLabel)
    replaceHit:SetScript("OnEnter", function(h)
        showReplaceTip(h)
    end)
    replaceHit:SetScript("OnLeave", hideReplaceTip)

    exportDD:SetupMenu(function(_, rootDescription)
        local types = {
            { key = "chars", label = "Characters" },
            { key = "storage", label = "Storage Rules" },
            { key = "keeplist", label = "Keep List" },
            { key = "vendorlist", label = "Vendor Whitelist" },
            { key = "restock", label = "Restock Rules" },
            { key = "all", label = "All" },
        }
        for _, t in ipairs(types) do
            rootDescription:CreateRadio(t.label, function()
                return f._exportType == t.key
            end, function()
                f._exportType = t.key
            end)
        end
    end)
    -- Export button
    local exportBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    exportBtn:SetSize(80, 22)
    exportBtn:SetPoint("LEFT", exportDD, "RIGHT", 8, 0)
    exportBtn:SetText("Export")
    exportBtn:SetScript("OnClick", function()
        local val = f._exportType
        if not val then
            statusText:SetText("|cffff4444Select an export type first.|r")
            return
        end
        local ok, text = pcall(function()
            if val == "chars" then
                return self:ExportRegistry()
            elseif val == "storage" then
                return self:ExportStorageAssignments()
            elseif val == "keeplist" then
                return self:ExportKeepList()
            elseif val == "vendorlist" then
                return self:ExportVendorList()
            elseif val == "restock" then
                return self:ExportRestockList()
            elseif val == "all" then
                return self:ExportRegistry()
                    .. "\n"
                    .. self:ExportStorageAssignments()
                    .. "\n"
                    .. self:ExportKeepList()
                    .. "\n"
                    .. self:ExportVendorList()
                    .. "\n"
                    .. self:ExportRestockList()
            end
        end)
        if not ok then
            statusText:SetText("|cffff4444Export error: " .. tostring(text) .. "|r")
            return
        end
        if text then
            editBox:SetText(text)
            editBox:SetFocus()
            statusText:SetText(string.format("|cff00cc00Exported %d lines|r", select(2, text:gsub("\n", "\n"))))
        else
            statusText:SetText("|cffff4444Export returned nil.|r")
        end
    end)

    -- Import button (right-aligned)
    local importBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    importBtn:SetSize(80, 22)
    importBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -24, 20)
    importBtn:SetText("Import")
    f._importBtn = importBtn

    -- Position checkboxes above the import button (right-aligned)
    replaceCB:ClearAllPoints()
    replaceCB:SetPoint("BOTTOMRIGHT", importBtn, "TOPRIGHT", 0, 2)

    autoAssignCB:ClearAllPoints()
    autoAssignCB:SetPoint("BOTTOMRIGHT", replaceCB, "TOPRIGHT", 0, 2)
    cbLabel:SetPoint("RIGHT", autoAssignCB, "LEFT", -2, 0)
    replaceLabel:ClearAllPoints()
    replaceLabel:SetPoint("RIGHT", replaceCB, "LEFT", -2, 0)
    local function PerformImport(sections)
        local statusParts = {}
        local doReplace = replaceCB:GetChecked()

        for _, section in ipairs(sections) do
            if section.type == "registry" then
                local numNew, numUpdated, numSkipped =
                    self:ImportRegistryFromText(section.text, autoAssignCB:GetChecked())
                if type(numSkipped) == "string" then
                    statusParts[#statusParts + 1] = "|cffff4444Import Characters: " .. numSkipped .. "|r"
                else
                    local msg = string.format(
                        "|cff88ccffImport Characters:|r |cff00cc00%d new|r, |cffffcc00%d updated|r",
                        numNew,
                        numUpdated
                    )
                    if numSkipped and numSkipped > 0 then
                        msg = msg .. string.format(", |cff888888%d blacklisted|r", numSkipped)
                    end
                    statusParts[#statusParts + 1] = msg
                end
            elseif section.type == "storage" then
                local readyRules, unresolvedRules, errMsg, parseSkipped =
                    self:ImportStorageAssignments(section.text)
                if errMsg and not readyRules then
                    self:ChatMsg("Storage import error: " .. errMsg, true)
                    statusParts[#statusParts + 1] = "|cff88ccffStorage:|r |cffff4444failed|r"
                elseif unresolvedRules and #unresolvedRules > 0 then
                    -- Unknown chars in the export. Open the remap dialog and
                    -- apply everything atomically when the user clicks Import
                    -- on the summary step.
                    local groups = GroupUnresolved(unresolvedRules)
                    statusParts[#statusParts + 1] = "|cff88ccffStorage:|r |cffffaa00awaiting remap...|r"
                    self:ShowRemapDialog(groups, readyRules, doReplace, function(commit, finalRules, mappedN, skippedN)
                        if not commit then
                            self:ChatMsg("Storage import cancelled.", true)
                            statusText:SetText("|cffff8800Storage import cancelled.|r")
                            return
                        end
                        if doReplace then
                            self.db.global.storageAssignments = {}
                        end
                        local lenBefore = #(self.db.global.storageAssignments or {})
                        local imp, dup = 0, 0
                        if finalRules and #finalRules > 0 then
                            imp, dup = self:ApplyImportedRules(finalRules)
                        end
                        if imp > 0 then
                            self._storageScrollToIdx = lenBefore + 1
                        end
                        local totalSkipped = (parseSkipped or 0) + dup + (skippedN or 0)
                        local parts = {}
                        if imp > 0 then
                            parts[#parts + 1] = string.format("|cff00cc00%d imported|r", imp)
                        end
                        if mappedN and mappedN > 0 then
                            parts[#parts + 1] = string.format("|cff88ccff%d remapped|r", mappedN)
                        end
                        if totalSkipped > 0 then
                            parts[#parts + 1] = string.format("|cffdddd00%d skipped|r", totalSkipped)
                        end
                        local msg2 = "|cff88ccffStorage:|r "
                            .. (#parts > 0 and table.concat(parts, " ") or "|cff00cc00OK|r")
                        statusText:SetText(msg2)
                        self:ChatMsg(msg2:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""), true)
                        if self.dashboardFrame and self.dashboardFrame:IsShown() and self.activeTab then
                            C_Timer.After(0, function() self:SelectDashboardTab(self.activeTab) end)
                        end
                    end)
                else
                    if doReplace then
                        self.db.global.storageAssignments = {}
                    end
                    local lenBefore = #(self.db.global.storageAssignments or {})
                    local imp, dup = 0, 0
                    if readyRules and #readyRules > 0 then
                        imp, dup = self:ApplyImportedRules(readyRules)
                    end
                    -- After a bulk import the prior scroll offset maps to a
                    -- different region of the new list; jump to the first
                    -- imported rule so the user lands on the new content.
                    if imp > 0 then
                        self._storageScrollToIdx = lenBefore + 1
                    end
                    local totalSkipped = (parseSkipped or 0) + dup
                    local parts = {}
                    if imp > 0 then
                        parts[#parts + 1] = string.format("|cff00cc00%d imported|r", imp)
                    end
                    if totalSkipped > 0 then
                        parts[#parts + 1] = string.format("|cffdddd00%d skipped|r", totalSkipped)
                    end
                    statusParts[#statusParts + 1] = "|cff88ccffStorage:|r "
                        .. (#parts > 0 and table.concat(parts, " ") or "|cff00cc00OK|r")
                end
            elseif section.type == "keeplist" then
                if doReplace then
                    self.db.global.keepList = {}
                end
                local entries, parseSkipped = self:ImportKeepList(section.text)
                local imp, dup, moved = self:ApplyImportedKeepList(entries)
                local parts = {}
                if imp > 0 then
                    parts[#parts + 1] = string.format("|cff00cc00%d imported|r", imp)
                end
                if moved > 0 then
                    parts[#parts + 1] = string.format("|cff88ccff%d moved from Vendor|r", moved)
                end
                local totalSkipped = (parseSkipped or 0) + dup
                if totalSkipped > 0 then
                    parts[#parts + 1] = string.format("|cffdddd00%d skipped|r", totalSkipped)
                end
                statusParts[#statusParts + 1] = "|cff88ccffKeep List:|r "
                    .. (#parts > 0 and table.concat(parts, " ") or "|cff00cc00OK|r")
                -- Refresh the Keep List window if it's open.
                if self.keeplistFrame and self.keeplistFrame:IsShown() and self.RefreshKeeplistDisplay then
                    self:RefreshKeeplistDisplay()
                end
                if self.vendorlistFrame and self.vendorlistFrame:IsShown() and self.RefreshVendorlistDisplay then
                    self:RefreshVendorlistDisplay()
                end
                self._bagsDirty = true
                if self.RefreshTriageIfOpen then
                    self:RefreshTriageIfOpen()
                end
            elseif section.type == "vendorlist" then
                if doReplace then
                    self.db.global.vendorWhitelist = {}
                end
                local entries, parseSkipped = self:ImportVendorList(section.text)
                local imp, dup = self:ApplyImportedVendorList(entries)
                local parts = {}
                if imp > 0 then
                    parts[#parts + 1] = string.format("|cff00cc00%d imported|r", imp)
                end
                local totalSkipped = (parseSkipped or 0) + dup
                if totalSkipped > 0 then
                    parts[#parts + 1] = string.format("|cffdddd00%d skipped|r", totalSkipped)
                end
                statusParts[#statusParts + 1] = "|cff88ccffVendor Whitelist:|r "
                    .. (#parts > 0 and table.concat(parts, " ") or "|cff00cc00OK|r")
                if self.vendorlistFrame and self.vendorlistFrame:IsShown() and self.RefreshVendorlistDisplay then
                    self:RefreshVendorlistDisplay()
                end
                self._bagsDirty = true
                if self.RefreshTriageIfOpen then
                    self:RefreshTriageIfOpen()
                end
            elseif section.type == "restock" then
                if doReplace then
                    self.db.global.restockList = {}
                end
                local readyRules, unresolvedRules, parseSkipped =
                    self:ImportRestockList(section.text)
                -- v1: silent-skip unresolved char/bags rules with a verbose log.
                -- Reusing the storage remap dialog would need dialog refactoring
                -- (it hard-codes storage rule shape); flagged as follow-up.
                local unresolvedN = unresolvedRules and #unresolvedRules or 0
                if unresolvedN > 0 then
                    for _, r in ipairs(unresolvedRules) do
                        self:ChatVerbose(string.format(
                            "|cff88ccff[Import]|r Restock: itemID %d (%s) unresolved char '%s', skipped.",
                            r.itemID or 0, r.dest or "?", r._origChar or ""
                        ))
                    end
                end
                local imp, dup = self:ApplyImportedRestockRules(readyRules)
                local parts = {}
                if imp > 0 then
                    parts[#parts + 1] = string.format("|cff00cc00%d imported|r", imp)
                end
                local totalSkipped = (parseSkipped or 0) + dup + unresolvedN
                if totalSkipped > 0 then
                    parts[#parts + 1] = string.format("|cffdddd00%d skipped|r", totalSkipped)
                end
                statusParts[#statusParts + 1] = "|cff88ccffRestock:|r "
                    .. (#parts > 0 and table.concat(parts, " ") or "|cff00cc00OK|r")
                self._bagsDirty = true
                if self.RefreshTriageIfOpen then
                    self:RefreshTriageIfOpen()
                end
            end
        end

        local msg = table.concat(statusParts, "  ")
        statusText:SetText(msg)
        self:ChatMsg(msg:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""), true)

        -- Refresh dashboard if visible
        if self.dashboardFrame and self.dashboardFrame:IsShown() then
            C_Timer.After(0, function()
                if self.activeTab then
                    self:SelectDashboardTab(self.activeTab)
                end
            end)
        end
    end

    importBtn:SetScript("OnClick", function()
        local text = editBox:GetText()
        if not text or text:match("^%s*$") then
            statusText:SetText("|cffff4444No text to import|r")
            return
        end

        local sections = self:ParseImportSections(text)
        if #sections == 0 then
            statusText:SetText("|cffff4444No recognized EmpireManager headers found.|r")
            return
        end

        -- Build a short summary of what will be imported, then confirm.
        -- Line counts here are raw payload lines (comments excluded) - a rough
        -- upper bound on entries. Actual import de-dups against the current DB.
        local counts = { registry = 0, storage = 0, keeplist = 0, vendorlist = 0, restock = 0 }
        local function countPayload(section)
            local n = 0
            for line in section.text:gmatch("[^\r\n]+") do
                local trimmed = line:match("^%s*(.-)%s*$")
                if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
                    n = n + 1
                end
            end
            return n
        end
        for _, section in ipairs(sections) do
            if counts[section.type] ~= nil then
                counts[section.type] = counts[section.type] + countPayload(section)
            end
        end
        local summary = {}
        if counts.registry > 0 then
            summary[#summary + 1] = string.format("%d Character%s",
                counts.registry, counts.registry == 1 and "" or "s")
        end
        if counts.storage > 0 then
            summary[#summary + 1] = string.format("%d Storage Rule%s",
                counts.storage, counts.storage == 1 and "" or "s")
        end
        if counts.keeplist > 0 then
            summary[#summary + 1] = string.format("%d Keep List item%s",
                counts.keeplist, counts.keeplist == 1 and "" or "s")
        end
        if counts.vendorlist > 0 then
            summary[#summary + 1] = string.format("%d Vendor Whitelist item%s",
                counts.vendorlist, counts.vendorlist == 1 and "" or "s")
        end
        if counts.restock > 0 then
            summary[#summary + 1] = string.format("%d Restock Rule%s",
                counts.restock, counts.restock == 1 and "" or "s")
        end
        if replaceCB:GetChecked() then
            local replacing = {}
            if counts.storage > 0 then replacing[#replacing + 1] = "Storage" end
            if counts.keeplist > 0 then replacing[#replacing + 1] = "Keep List" end
            if counts.vendorlist > 0 then replacing[#replacing + 1] = "Vendor Whitelist" end
            if counts.restock > 0 then replacing[#replacing + 1] = "Restock" end
            if #replacing > 0 then
                summary[#summary + 1] = "|cffff8800replace: " .. table.concat(replacing, ", ") .. "|r"
            end
        end
        local summaryText = #summary > 0 and (table.concat(summary, ", ") .. ".") or "no recognized data."

        local dialog = StaticPopup_Show("EM_IMPORT_CONFIRM", summaryText)
        if dialog then
            dialog.data = { sections = sections }
        end
    end)

    StaticPopupDialogs["EM_IMPORT_CONFIRM"] = StaticPopupDialogs["EM_IMPORT_CONFIRM"]
        or {
            text = "Import the following?\n\n%s",
            button1 = "Import",
            button2 = "Cancel",
            OnAccept = function(popup)
                if popup.data and popup.data.sections then
                    PerformImport(popup.data.sections)
                end
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            showAlert = true,
            preferredIndex = 3,
        }
end

function EmpireManager:ToggleIOWindow()
    local f = EmpireManagerIOFrame
    if not f then
        return
    end

    self:InitIOFrame()

    if f:IsShown() then
        f:Hide()
    else
        f:Show()
    end
end
