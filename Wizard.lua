-- ----------------------------------------------------------------------------
--                                   EmpireManager
--                              https://wow.cyberpunk.gr
--                (c) by George Litos (l0neshad0w),  All Rights Reserved
--                   For detailed license information check LICENSE.md
-- ----------------------------------------------------------------------------

local EmpireManager = LibStub("AceAddon-3.0"):GetAddon("EmpireManager")

EMWizardMixin = {}

-------------------------------------------------------------------------------
-- Templates
-------------------------------------------------------------------------------

local TEMPLATES = {
    {
        key = "self_banker",
        label = "Self-Banker",
        desc = "Each Character keeps their Profession mats in their own Character Bank.",
    },
    {
        key = "mule_banker",
        label = "Mule Banker",
        desc = "One designated Character holds every Profession's mats for everyone.",
    },
    {
        key = "guild_warband",
        label = "Guild/Warband Bank",
        desc = "Send everything to a single shared Bank. Pick Guild or Warband on the next screen.",
    },
    {
        key = "hybrid",
        label = "Split by Expansion",
        desc = "Current expansion to Warband Bank, older to Character Bank (or reverse).",
    },
    {
        key = "stash_gear_recipes",
        label = "Stash Everything Else",
        desc = "Send Equipment, Recipes, Consumables, Item Enhancements, Pets, PvP, Lumber, Housing, Cooking, Fishing, and Archaeology to a single shared Bank.",
    },
}

-- Categories assigned by the stash_gear_recipes template. Covers every
-- non-profession storage category plus the three secondary professions
-- (Cooking, Fishing, Archaeology), so a starter setup leaves nothing
-- orphaned. Users can always edit or delete the secondary rules later.
local STASH_CATEGORIES = {
    "equipment_boe",
    "equipment_boa",
    "equipment_prof",
    "recipes",
    "item_enhancements",
    "consumables",
    "pets",
    "pvp",
    "lumber",
    "housing",
    "cooking",
    "fishing",
    "archaeology",
}

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function CurrentExpansionInfo()
    -- Pick the entry with the highest expansionID. On ties (e.g. both 0),
    -- prefer the last one in EXPANSION_DISPLAY, which by convention is the
    -- newer / more relevant entry.
    local best
    for _, info in ipairs(EmpireManager.EXPANSION_DISPLAY) do
        if not best or (info.expansionID or 0) >= (best.expansionID or 0) then
            best = info
        end
    end
    return best
end

local function PreviousExpansionIDs()
    local cur = CurrentExpansionInfo()
    local out = {}
    if not cur then
        return out
    end
    for _, info in ipairs(EmpireManager.EXPANSION_DISPLAY) do
        if (info.expansionID or 0) ~= (cur.expansionID or 0) then
            out[#out + 1] = info.expansionID
        end
    end
    return out
end

-- Class-colored "Name - Realm" for char dropdowns. Both name and realm are
-- wrapped in the class color so the whole label reads as one identity.
local function CharLabel(entry)
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

-- Return sorted (guid, entry) list of registry chars.
local function SortedChars()
    local chars = {}
    for guid, entry in pairs(EmpireManager.db.global.registry or {}) do
        chars[#chars + 1] = { guid = guid, entry = entry }
    end
    table.sort(chars, function(a, b)
        local an = ((a.entry.name or "") .. "-" .. (a.entry.realm or "")):lower()
        local bn = ((b.entry.name or "") .. "-" .. (b.entry.realm or "")):lower()
        return an < bn
    end)
    return chars
end

-- A char is "eligible" once we have profession data for it (detected from a
-- live login or a registry import that included professions).
local function IsEligible(entry)
    return entry and entry.professions and #entry.professions > 0
end

-- Returns sorted list of unique guild names from the registry, excluding blacklist.
-- Returns sorted unique (guild, realm) pairs with disambiguated labels:
-- "Guild" when the name is unique across the roster, "Guild - Realm" when it
-- collides with another realm. Same shape as Tabs.lua's BuildGuildList.
local function SortedGuilds()
    local nameCounts, out, seen = {}, {}, {}
    for _, entry in pairs(EmpireManager.db.global.registry or {}) do
        local g = entry.guild
        local r = entry.guildRealm
        if g and g ~= "" and r and r ~= "" and not EmpireManager:IsGuildBlacklisted(g, r) then
            -- Dedupe through GuildKey (see Tabs.lua BuildGuildList): the realm
            -- is stored in two spellings, so a raw key splits one guild in two.
            local key = EmpireManager:GuildKey(g, r)
            if key and not seen[key] then
                seen[key] = true
                out[#out + 1] = { guild = g, realm = r }
                nameCounts[g] = (nameCounts[g] or 0) + 1
            end
        end
    end
    for _, item in ipairs(out) do
        item.label = (nameCounts[item.guild] > 1) and (item.guild .. " - " .. item.realm) or item.guild
    end
    table.sort(out, function(a, b)
        return a.label:lower() < b.label:lower()
    end)
    return out
end

-- Find the profession keys (artisan/gatherer) that an entry has, returned as a
-- map { profKey = true }. Skips secondary professions (cooking/fishing/archaeology).
local function EntryProfKeys(entry)
    local set = {}
    if not entry or not entry.professions then
        return set
    end
    for _, prof in ipairs(entry.professions) do
        local info = EmpireManager:ProfInfoFromEntryProf(prof)
        if info and (info.category == "crafting" or info.category == "gathering") then
            set[info.key] = true
        end
    end
    return set
end

-- Same as EntryProfKeys but maps profKey -> skill level (0 if missing).
local function EntryProfSkills(entry)
    local out = {}
    if not entry or not entry.professions then
        return out
    end
    for _, prof in ipairs(entry.professions) do
        local info = EmpireManager:ProfInfoFromEntryProf(prof)
        if info and (info.category == "crafting" or info.category == "gathering") then
            out[info.key] = prof.skill or 0
        end
    end
    return out
end

-- For each profession appearing on multiple chars, return the guid with the
-- highest skill. Returns a map { profKey = guid } limited to "winners".
local function MaxSkillCharByProf(scopeChars)
    local best = {}
    for _, c in ipairs(scopeChars) do
        for prof, skill in pairs(EntryProfSkills(c.entry)) do
            local cur = best[prof]
            if not cur or skill > cur.skill then
                best[prof] = { guid = c.guid, skill = skill }
            end
        end
    end
    local winners = {}
    for prof, b in pairs(best) do
        winners[prof] = b.guid
    end
    return winners
end

-------------------------------------------------------------------------------
-- Body widget tracking
-------------------------------------------------------------------------------

-- Every step builds its widgets from pools so a re-render reuses them (WoW
-- never frees a created widget, so recreating leaked on every render).
-- `_pool` holds widgets on `wizard.Body`; `_listPool` holds the text inside the
-- step 5 preview list, which lives on that list's scroll child.
--
-- Release hides and detaches widgets without reparenting them. Calling
-- SetParent(nil) on widgets whose ancestors were touched by Blizzard's
-- protected layout code (e.g. inside dropdown callbacks) propagates taint into
-- shared LayoutFrame state, which then breaks unrelated UI (world-map tooltips,
-- quest offer pins, etc.). The pool never reparents, so that stays safe.
local function ClearBody(self)
    if not self._pool then
        self._pool = EmpireManager:CreateWidgetPool()
        self._listPool = EmpireManager:CreateWidgetPool()
    end
    self._listPool:ReleaseAll()
    self._pool:ReleaseAll()
end

-- Pooled plain text on the body (the pool restores the template's look on reuse).
local function BodyText(self, template)
    return self._pool:AcquireText(self.Body, template)
end

-- Blizzard-template widgets keep their template scripts across releases; every
-- use rebinds its own OnClick and resets the state a previous use may have set.
local function Radio(self)
    local rb = self._pool:Acquire("radio", function()
        local b = CreateFrame("CheckButton", nil, self.Body, "UIRadioButtonTemplate")
        b._poolKeepScripts = true
        return b
    end)
    rb:SetEnabled(true)
    return rb
end

local function CheckBox(self)
    local cb = self._pool:Acquire("check", function()
        local b = CreateFrame("CheckButton", nil, self.Body, "UICheckButtonTemplate")
        b._poolKeepScripts = true
        return b
    end)
    cb:SetEnabled(true)
    return cb
end

-- Callers run SetupMenu and EnableDropdownScrollToSelected on every use; the
-- latter registers its callback with the dropdown as owner, which replaces the
-- previous use's callback instead of stacking another.
local function Dropdown(self)
    return self._pool:Acquire("dropdown", function()
        local dd = CreateFrame("DropdownButton", nil, self.Body, "WowStyle1DropdownTemplate")
        dd._poolKeepScripts = true
        return dd
    end)
end

-- Clickable radio-option row (steps 2 and 3): hover highlight + label. The
-- label anchors to the radio, which changes per use, so the caller anchors it.
local function OptionRow(self)
    local hit = self._pool:Acquire("optionRow", function()
        local b = CreateFrame("Button", nil, self.Body)
        b:RegisterForClicks("LeftButtonUp")
        b.Highlight = b:CreateTexture(nil, "HIGHLIGHT")
        b.Highlight:SetAllPoints(b)
        b.Label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        b.Label:SetJustifyH("LEFT")
        return b
    end)
    hit.Highlight:SetColorTexture(1, 1, 1, 0.06)
    hit.Label:ClearAllPoints()
    return hit
end

-- Pair a label fontstring with a checkbox so clicking the label toggles the
-- box. Caller anchors the returned hit frame next to the checkbox. Every
-- caller passes the body as `parent`, so the kind is keyed on font alone.
local function MakeClickableLabel(self, parent, cb, text, fontObject)
    local font = fontObject or "GameFontNormal"
    local hit = self._pool:Acquire("clickLabel:" .. font, function()
        local b = CreateFrame("Button", nil, parent)
        b:RegisterForClicks("LeftButtonUp")
        b.Label = b:CreateFontString(nil, "OVERLAY", font)
        b.Label:SetPoint("LEFT", b, "LEFT", 0, 0)
        b.Label:SetJustifyH("LEFT")
        return b
    end)
    local fs = hit.Label
    fs:SetText(text)
    fs:SetTextColor(1, 1, 1)
    hit:SetSize(fs:GetStringWidth() + 4, math.max(fs:GetStringHeight() + 4, 26))
    hit:SetScript("OnClick", function() cb:Click() end)
    return hit
end

-------------------------------------------------------------------------------
-- Rule generation
-------------------------------------------------------------------------------

-- Build the new rules from the wizard state. Returns the list of rule tables
-- ready to feed into ApplyImportedRules.
local function GenerateRules(state)
    local rules = {}

    local template = state.template
    if not template then
        return rules
    end

    local scopeChars = state.scopeChars or {}
    if #scopeChars == 0 then
        return rules
    end

    local cur = CurrentExpansionInfo()
    local prevIDs = PreviousExpansionIDs()

    if template == "self_banker" then
        local winners = state.maxSkillOnly and MaxSkillCharByProf(scopeChars) or nil
        for _, c in ipairs(scopeChars) do
            local profSet = EntryProfKeys(c.entry)
            for prof in pairs(profSet) do
                if not winners or winners[prof] == c.guid then
                    rules[#rules + 1] = {
                        profession = prof,
                        type = "charbank",
                        char = c.guid,
                    }
                end
            end
        end
    elseif template == "mule_banker" then
        local muleGuid = state.mule
        if not muleGuid then
            return rules
        end
        -- Union of professions across all in-scope chars (so the mule receives
        -- everything they collectively produce/consume).
        local profUnion = {}
        for _, c in ipairs(scopeChars) do
            for prof in pairs(EntryProfKeys(c.entry)) do
                profUnion[prof] = true
            end
        end
        for prof in pairs(profUnion) do
            rules[#rules + 1] = {
                profession = prof,
                type = "charbank",
                char = muleGuid,
            }
        end
    elseif template == "guild_warband" then
        local dest = state.dest or "warband"
        if dest == "guild" and (not state.guild or state.guild == "") then
            return rules
        end
        local profUnion = {}
        for _, c in ipairs(scopeChars) do
            for prof in pairs(EntryProfKeys(c.entry)) do
                profUnion[prof] = true
            end
        end
        for prof in pairs(profUnion) do
            if dest == "guild" then
                rules[#rules + 1] = {
                    profession = prof,
                    type = "guildbank",
                    guild = state.guild,
                    realm = state.guildRealm,
                }
            else
                rules[#rules + 1] = {
                    profession = prof,
                    type = "warbandbank",
                }
            end
        end
    elseif template == "stash_gear_recipes" then
        local dest = state.dest or "warband"
        if dest == "guild" and (not state.guild or state.guild == "") then
            return rules
        end
        if dest == "char" and not state.stashChar then
            return rules
        end
        for _, cat in ipairs(STASH_CATEGORIES) do
            if dest == "guild" then
                rules[#rules + 1] = {
                    profession = cat,
                    type = "guildbank",
                    guild = state.guild,
                }
            elseif dest == "char" then
                rules[#rules + 1] = {
                    profession = cat,
                    type = "charbank",
                    char = state.stashChar,
                }
            else
                rules[#rules + 1] = {
                    profession = cat,
                    type = "warbandbank",
                }
            end
        end
    elseif template == "hybrid" then
        if not cur then
            return rules
        end
        local currentToWarband = state.hybridDir ~= "current_to_charbank"
        -- Same winners map as self_banker. Only the charbank rule honors it -
        -- warband rules carry no `char` and dedupe naturally.
        local winners = state.maxSkillOnly and MaxSkillCharByProf(scopeChars) or nil
        for _, c in ipairs(scopeChars) do
            local profSet = EntryProfKeys(c.entry)
            for prof in pairs(profSet) do
                local isWinner = (not winners) or (winners[prof] == c.guid)
                if currentToWarband then
                    rules[#rules + 1] = {
                        profession = prof,
                        type = "warbandbank",
                        expansions = { cur.expansionID },
                    }
                    if #prevIDs > 0 and isWinner then
                        rules[#rules + 1] = {
                            profession = prof,
                            type = "charbank",
                            char = c.guid,
                            expansions = prevIDs,
                        }
                    end
                else
                    if isWinner then
                        rules[#rules + 1] = {
                            profession = prof,
                            type = "charbank",
                            char = c.guid,
                            expansions = { cur.expansionID },
                        }
                    end
                    if #prevIDs > 0 then
                        rules[#rules + 1] = {
                            profession = prof,
                            type = "warbandbank",
                            expansions = prevIDs,
                        }
                    end
                end
            end
        end
    end

    return rules
end

local function setsEqual(a, b)
    a = a or {}
    b = b or {}
    if #a ~= #b then
        return false
    end
    local sa = {}
    for _, v in ipairs(a) do
        sa[tostring(v)] = true
    end
    for _, v in ipairs(b) do
        if not sa[tostring(v)] then
            return false
        end
    end
    return true
end

-- Count how many of the new rules are duplicates of existing rules (matches
-- the dedup logic in ApplyImportedRules).
local function CountDuplicates(newRules)
    local existing = EmpireManager.db.global.storageAssignments or {}
    local dups = 0
    for _, r in ipairs(newRules) do
        for _, e in ipairs(existing) do
            if
                e.profession == r.profession
                and e.type == r.type
                and e.char == r.char
                and e.guild == r.guild
                and setsEqual(e.expansions, r.expansions)
                and setsEqual(e.subcategories, r.subcategories)
            then
                dups = dups + 1
                break
            end
        end
    end
    return dups
end

-------------------------------------------------------------------------------
-- Step rendering
-------------------------------------------------------------------------------

-- Vertical offset from the top of the Body where each step starts rendering.
-- Pushes content toward the visual center of the frame so short steps don't
-- look top-heavy. All step renderers use this as the baseline for their first
-- element and stack downward from there.
local STEP_TOP = 80
local STEP_LEFT = 16

-- Step 1: Pick a template
function EMWizardMixin:RenderStep1()
    local body = self.Body
    local top = STEP_TOP - 24
    local title = BodyText(self, "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", body, "TOPLEFT", STEP_LEFT, -top)
    title:SetText("Pick a template")

    local hint = BodyText(self, "GameFontHighlight")
    hint:SetPoint("TOPLEFT", body, "TOPLEFT", STEP_LEFT, -(top + 22))
    hint:SetText("|cffe8d9a8Generates a starter set of Storage Rules. Edit anything later.|r")

    local y = top + 50
    for _, t in ipairs(TEMPLATES) do
        local function pickThis()
            self._state.template = t.key
            -- Reset downstream state when template changes.
            self._state.mule = nil
            self._state.guild = nil
            self._state.guildRealm = nil
            self._state.dest = nil
            self._state.stashChar = nil
            self._state.maxSkillOnly = nil
            self._state.scope = self._state.scope or "all"
            self:Render()
        end

        -- Whole-row clickable hit zone covering the label + description, so the
        -- user doesn't need to hit the small radio circle.
        local hit = self._pool:Acquire("templateRow", function()
            local b = CreateFrame("Button", nil, body)
            b:RegisterForClicks("LeftButtonUp")
            b.Label = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            b.Label:SetPoint("TOPLEFT", b, "TOPLEFT", 6, -6)
            b.Desc = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            b.Desc:SetPoint("TOPLEFT", b.Label, "BOTTOMLEFT", 0, -2)
            b.Desc:SetPoint("RIGHT", b, "RIGHT", -4, 0)
            b.Desc:SetJustifyH("LEFT")
            -- Subtle highlight on hover so users see the row is clickable.
            local hl = b:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints(b)
            hl:SetColorTexture(1, 1, 1, 0.06)
            return b
        end)
        hit:SetPoint("TOPLEFT", body, "TOPLEFT", STEP_LEFT + 24, -y)
        hit:SetPoint("RIGHT", body, "RIGHT", -8, 0)
        hit:SetHeight(42)

        -- pickThis re-renders, which sets every radio's checked state. Do not
        -- touch the clicked button afterwards: the pool may already have handed
        -- it to the new render.
        local rb = Radio(self)
        rb:SetPoint("LEFT", hit, "LEFT", -24, 0)
        rb:SetChecked(self._state.template == t.key)
        rb:SetScript("OnClick", pickThis)
        hit:SetScript("OnClick", pickThis)

        hit.Label:SetText(t.label)
        hit.Label:SetTextColor(1, 0.82, 0)
        hit.Desc:SetText(t.desc)
        hit.Desc:SetTextColor(1, 1, 1)

        y = y + 46
    end

end

-- Step 2: Template parameters
function EMWizardMixin:RenderStep2()
    local body = self.Body
    local tmpl = self._state.template

    local tmplLabel, tmplDesc
    for _, t in ipairs(TEMPLATES) do
        if t.key == tmpl then
            tmplLabel = t.label
            tmplDesc = t.desc
            break
        end
    end

    local title = BodyText(self, "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", body, "TOPLEFT", STEP_LEFT, -STEP_TOP)
    title:SetPoint("RIGHT", body, "RIGHT", -8, 0)
    title:SetJustifyH("LEFT")
    title:SetText(tmplLabel or "Configure template")

    if tmplDesc then
        local subtitle = BodyText(self, "GameFontHighlight")
        subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
        subtitle:SetPoint("RIGHT", body, "RIGHT", -8, 0)
        subtitle:SetJustifyH("LEFT")
        subtitle:SetWordWrap(true)
        subtitle:SetText("|cffe8d9a8" .. tmplDesc .. "|r")
    end

    if tmpl == "self_banker" then
        local hint = BodyText(self, "GameFontHighlight")
        hint:SetPoint("TOPLEFT", body, "TOPLEFT", STEP_LEFT, -(STEP_TOP + 48))
        hint:SetPoint("RIGHT", body, "RIGHT", -8, 0)
        hint:SetJustifyH("LEFT")
        hint:SetWordWrap(true)
        hint:SetText("|cffe8d9a8When multiple Characters have the same Profession, this template normally creates one rule per Character. Check the option below to route to the highest-skill Character only.|r")

        local cb = CheckBox(self)
        cb:SetPoint("TOPLEFT", body, "TOPLEFT", STEP_LEFT - 6, -(STEP_TOP + 106))
        cb:SetChecked(self._state.maxSkillOnly and true or false)
        cb:SetScript("OnClick", function(btn)
            self._state.maxSkillOnly = btn:GetChecked() and true or false
        end)
        local cbLbl = MakeClickableLabel(self, body, cb, "For shared Professions, route only to the highest-skill Character")
        cbLbl:SetPoint("LEFT", cb, "RIGHT", 2, 0)
        return
    end

    if tmpl == "mule_banker" then
        local label = BodyText(self, "GameFontNormal")
        label:SetPoint("TOPLEFT", body, "TOPLEFT", STEP_LEFT, -(STEP_TOP + 54))
        label:SetPoint("RIGHT", body, "RIGHT", -8, 0)
        label:SetJustifyH("LEFT")
        label:SetWordWrap(true)
        label:SetText("Pick the Mule - the Character that will hold every Profession's mats for the rest of the roster.")
        label:SetTextColor(1, 0.82, 0)

        local dd = Dropdown(self)
        dd:SetPoint("TOPLEFT", body, "TOPLEFT", STEP_LEFT, -(STEP_TOP + 96))
        dd:SetWidth(360)
        local chars = SortedChars()
        if #chars > 0 and not self._state.mule then
            -- Default = current char if present, else first
            local pg = EmpireManager.playerGUID
            for _, c in ipairs(chars) do
                if c.guid == pg then
                    self._state.mule = pg
                    break
                end
            end
            if not self._state.mule then
                self._state.mule = chars[1].guid
            end
        end
        local muleSelIdx
        dd:SetupMenu(function(_, root)
            root:SetScrollMode(20 * 20)
            muleSelIdx = nil
            for i, c in ipairs(chars) do
                if c.guid == self._state.mule then muleSelIdx = i end
                root:CreateRadio(CharLabel(c.entry), function()
                    return self._state.mule == c.guid
                end, function()
                    self._state.mule = c.guid
                end)
            end
        end)
        EmpireManager:EnableDropdownScrollToSelected(dd, function() return muleSelIdx end)
        return
    end

    if tmpl == "guild_warband" or tmpl == "stash_gear_recipes" then
        if not self._state.dest then
            self._state.dest = "warband"
        end

        local destLabel = BodyText(self, "GameFontNormal")
        destLabel:SetPoint("TOPLEFT", body, "TOPLEFT", STEP_LEFT, -(STEP_TOP + 54))
        destLabel:SetText("Destination:")
        destLabel:SetTextColor(1, 0.82, 0)

        local destOptions = {
            { key = "warband", text = "Warband Bank" },
            { key = "guild",   text = "Guild Bank" },
        }
        if tmpl == "stash_gear_recipes" then
            destOptions[#destOptions + 1] = { key = "char", text = "Character Bank" }
        end
        local y = STEP_TOP + 76
        for _, opt in ipairs(destOptions) do
            local function pickThis()
                self._state.dest = opt.key
                self:Render()
            end
            -- pickThis re-renders (see RenderStep1 for why the button is not
            -- touched afterwards).
            local rb = Radio(self)
            rb:SetPoint("TOPLEFT", body, "TOPLEFT", STEP_LEFT, -y)
            rb:SetChecked(self._state.dest == opt.key)
            rb:SetScript("OnClick", pickThis)

            local hit = OptionRow(self)
            hit:SetPoint("TOPLEFT", rb, "TOPRIGHT", 0, 0)
            hit:SetPoint("RIGHT", body, "RIGHT", -8, 0)
            hit:SetHeight(24)
            hit:SetScript("OnClick", pickThis)

            local rl = hit.Label
            rl:SetPoint("LEFT", rb, "RIGHT", 4, 0)
            rl:SetPoint("RIGHT", hit, "RIGHT", -4, 0)
            rl:SetJustifyH("LEFT")
            rl:SetText(opt.text)
            rl:SetTextColor(1, 1, 1)
            y = y + 28
        end

        if self._state.dest == "guild" then
            local guildLabel = BodyText(self, "GameFontNormal")
            guildLabel:SetPoint("TOPLEFT", body, "TOPLEFT", STEP_LEFT, -(y + 8))
            guildLabel:SetText("Guild:")
            guildLabel:SetTextColor(1, 0.82, 0)

            local guildDD = Dropdown(self)
            guildDD:SetPoint("TOPLEFT", body, "TOPLEFT", STEP_LEFT, -(y + 30))
            guildDD:SetWidth(360)

            local guilds = SortedGuilds()
            if #guilds == 0 then
                local warn = BodyText(self, "GameFontHighlight")
                warn:SetPoint("TOPLEFT", body, "TOPLEFT", STEP_LEFT, -(y + 70))
                warn:SetPoint("RIGHT", body, "RIGHT", 0, 0)
                warn:SetJustifyH("LEFT")
                warn:SetText("|cffff8800No Guilds found in your roster. Log in on a Character that's in a Guild.|r")
            end

            if not self._state.guild and #guilds > 0 then
                self._state.guild = guilds[1].guild
                self._state.guildRealm = guilds[1].realm
            end

            local guildSelIdx
            guildDD:SetupMenu(function(_, root)
                root:SetScrollMode(20 * 20)
                guildSelIdx = nil
                for i, item in ipairs(guilds) do
                    if item.guild == self._state.guild and item.realm == self._state.guildRealm then
                        guildSelIdx = i
                    end
                    root:CreateRadio(item.label, function()
                        return self._state.guild == item.guild and self._state.guildRealm == item.realm
                    end, function()
                        self._state.guild = item.guild
                        self._state.guildRealm = item.realm
                    end)
                end
            end)
            EmpireManager:EnableDropdownScrollToSelected(guildDD, function() return guildSelIdx end)
        end

        if self._state.dest == "char" then
            local charLabel = BodyText(self, "GameFontNormal")
            charLabel:SetPoint("TOPLEFT", body, "TOPLEFT", STEP_LEFT, -(y + 8))
            charLabel:SetText("Character:")
            charLabel:SetTextColor(1, 0.82, 0)

            local charDD = Dropdown(self)
            charDD:SetPoint("TOPLEFT", body, "TOPLEFT", STEP_LEFT, -(y + 30))
            charDD:SetWidth(360)

            local chars = SortedChars()
            if #chars > 0 and not self._state.stashChar then
                local pg = EmpireManager.playerGUID
                for _, c in ipairs(chars) do
                    if c.guid == pg then
                        self._state.stashChar = pg
                        break
                    end
                end
                if not self._state.stashChar then
                    self._state.stashChar = chars[1].guid
                end
            end

            local stashSelIdx
            charDD:SetupMenu(function(_, root)
                root:SetScrollMode(20 * 20)
                stashSelIdx = nil
                for i, c in ipairs(chars) do
                    if c.guid == self._state.stashChar then stashSelIdx = i end
                    root:CreateRadio(CharLabel(c.entry), function()
                        return self._state.stashChar == c.guid
                    end, function()
                        self._state.stashChar = c.guid
                    end)
                end
            end)
            EmpireManager:EnableDropdownScrollToSelected(charDD, function() return stashSelIdx end)
        end
        return
    end

    if tmpl == "hybrid" then
        local cur = CurrentExpansionInfo()
        local label = BodyText(self, "GameFontNormal")
        label:SetPoint("TOPLEFT", body, "TOPLEFT", STEP_LEFT, -(STEP_TOP + 54))
        label:SetText(string.format("Current expansion: |cffffd100%s|r", cur and cur.label or "?"))
        label:SetTextColor(1, 1, 1)

        local options = {
            { key = "current_to_warband", text = "Current to Warband Bank, older to Character Bank" },
            { key = "current_to_charbank", text = "Current to Character Bank, older to Warband Bank" },
        }
        if not self._state.hybridDir then
            self._state.hybridDir = "current_to_warband"
        end
        local y = STEP_TOP + 86
        for _, opt in ipairs(options) do
            local function pickThis()
                self._state.hybridDir = opt.key
                self:Render()
            end
            -- pickThis re-renders (see RenderStep1 for why the button is not
            -- touched afterwards).
            local rb = Radio(self)
            rb:SetPoint("TOPLEFT", body, "TOPLEFT", STEP_LEFT, -y)
            rb:SetChecked(self._state.hybridDir == opt.key)
            rb:SetScript("OnClick", pickThis)

            local hit = OptionRow(self)
            hit:SetPoint("TOPLEFT", rb, "TOPRIGHT", 0, 0)
            hit:SetPoint("RIGHT", body, "RIGHT", -8, 0)
            hit:SetHeight(24)
            hit:SetScript("OnClick", pickThis)

            local rl = hit.Label
            rl:SetPoint("LEFT", rb, "RIGHT", 4, 0)
            rl:SetPoint("RIGHT", hit, "RIGHT", -4, 0)
            rl:SetJustifyH("LEFT")
            rl:SetText(opt.text)
            rl:SetTextColor(1, 1, 1)
            y = y + 28
        end

        -- Highest-skill toggle (mirrors self_banker). Only the Character Bank
        -- side of the split is per-Character; the Warband side is account-wide
        -- and dedupes by itself, so this toggle only collapses the charbank
        -- rule to one per Profession (the highest-skill Character).
        local hintY = y + 8
        local hint = BodyText(self, "GameFontHighlight")
        hint:SetPoint("TOPLEFT", body, "TOPLEFT", STEP_LEFT, -hintY)
        hint:SetPoint("RIGHT", body, "RIGHT", -8, 0)
        hint:SetJustifyH("LEFT")
        hint:SetWordWrap(true)
        hint:SetText("|cffe8d9a8When multiple Characters have the same Profession, this template normally creates one Character Bank rule per Character. Check the option below to route to the highest-skill Character only.|r")

        local cb = CheckBox(self)
        cb:SetPoint("TOPLEFT", body, "TOPLEFT", STEP_LEFT - 6, -(hintY + 58))
        cb:SetChecked(self._state.maxSkillOnly and true or false)
        cb:SetScript("OnClick", function(btn)
            self._state.maxSkillOnly = btn:GetChecked() and true or false
        end)
        local cbLbl = MakeClickableLabel(self, body, cb, "For shared Professions, route only to the highest-skill Character")
        cbLbl:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    end
end

-- Step 3: Scope (logged-in vs all eligible)
function EMWizardMixin:RenderStep3()
    local body = self.Body

    local title = BodyText(self, "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", body, "TOPLEFT", STEP_LEFT, -STEP_TOP)
    title:SetText("Choose Characters for Storage Rules creation")

    if not self._state.scope then
        self._state.scope = "all"
    end

    local pg = EmpireManager.playerGUID
    local pgEntry = pg and EmpireManager.db.global.registry[pg]
    local loggedInEligible = IsEligible(pgEntry)

    local loggedInLabel = pgEntry and CharLabel(pgEntry) or "this Character"
    local options = {
        { key = "all", text = "All Characters with Professions" },
        { key = "logged_in", text = "Only Professions of " .. loggedInLabel },
    }

    local y = STEP_TOP + 36
    for _, opt in ipairs(options) do
        local disabled = (opt.key == "logged_in" and not loggedInEligible)
        local function pickThis()
            if disabled then
                return
            end
            self._state.scope = opt.key
            self:Render()
        end
        local rb = Radio(self)
        rb:SetPoint("TOPLEFT", body, "TOPLEFT", STEP_LEFT, -y)
        rb:SetChecked(self._state.scope == opt.key)
        if disabled then
            rb:Disable()
        end
        -- An enabled click re-renders (see RenderStep1 for why the button is
        -- not touched afterwards); a disabled radio never fires OnClick.
        rb:SetScript("OnClick", pickThis)

        local hit = OptionRow(self)
        hit:SetPoint("TOPLEFT", rb, "TOPRIGHT", 0, 0)
        hit:SetPoint("RIGHT", body, "RIGHT", -8, 0)
        hit:SetHeight(24)
        hit:SetScript("OnClick", pickThis)
        if disabled then
            -- No hover highlight on a disabled option.
            hit.Highlight:SetColorTexture(1, 1, 1, 0)
        end

        local rl = hit.Label
        rl:SetPoint("LEFT", rb, "RIGHT", 4, 0)
        rl:SetPoint("RIGHT", hit, "RIGHT", -4, 0)
        rl:SetJustifyH("LEFT")
        rl:SetText(opt.text)
        if disabled then
            rl:SetTextColor(0.5, 0.5, 0.5)
        else
            rl:SetTextColor(1, 1, 1)
        end
        y = y + 28
    end

    -- Eligibility summary
    local total, eligible, skipped = 0, 0, {}
    for _, c in ipairs(SortedChars()) do
        total = total + 1
        if IsEligible(c.entry) then
            eligible = eligible + 1
        else
            skipped[#skipped + 1] = CharLabel(c.entry)
        end
    end

    local summary = BodyText(self, "GameFontHighlight")
    summary:SetPoint("TOPLEFT", body, "TOPLEFT", STEP_LEFT, -y - 12)
    summary:SetPoint("RIGHT", body, "RIGHT", 0, 0)
    summary:SetJustifyH("LEFT")
    summary:SetWordWrap(true)
    if self._state.scope == "all" then
        if eligible == total then
            summary:SetText(string.format("Will add rules for every Profession across all %d Characters.", total))
        else
            summary:SetText(
                string.format("Will add rules for every Profession across %d of %d Characters.", eligible, total)
            )
        end
    else
        if loggedInEligible then
            summary:SetText(string.format("Will add rules for every Profession of %s.", CharLabel(pgEntry)))
        else
            summary:SetText("|cffff8800No Professions tracked for this Character yet. Open your profession window once, or pick \"All Characters with Professions\".|r")
        end
    end
    summary:SetTextColor(1, 1, 1)

    -- Skip note only makes sense for the "All Characters" scope - the
    -- "Only Professions of <currentChar>" scope already implies a single
    -- target and the list of skipped names is irrelevant there.
    if self._state.scope == "all" and #skipped > 0 then
        local skipNote = BodyText(self, "GameFontHighlightSmall")
        skipNote:SetPoint("TOPLEFT", summary, "BOTTOMLEFT", 0, -14)
        skipNote:SetPoint("RIGHT", body, "RIGHT", 0, 0)
        skipNote:SetJustifyH("LEFT")
        skipNote:SetWordWrap(true)
        local list = table.concat(skipped, ", ")
        if #list > 240 then
            list = list:sub(1, 237) .. "..."
        end
        skipNote:SetText(string.format(
            "|cffe8d9a8%d Character%s will be skipped because they have no Professions|r\n%s",
            #skipped,
            #skipped == 1 and "" or "s",
            list
        ))
    end
end

-- Step 5: Preview & confirm
function EMWizardMixin:RenderStep5()
    local body = self.Body

    local rules = self._state.previewRules or {}
    -- When clearExisting is on, the wipe runs before ApplyImportedRules,
    -- so the dedup check sees an empty assignments table and nothing is
    -- actually skipped as a duplicate. The summary must reflect that.
    local dups = self._state.clearExisting and 0 or (self._state.previewDups or 0)
    local newCount = #rules - dups
    if newCount < 0 then
        newCount = 0
    end

    -- Count chars touched
    local charsSeen = {}
    for _, r in ipairs(rules) do
        if r.char then
            charsSeen[r.char] = true
        end
    end
    local nChars = 0
    for _ in pairs(charsSeen) do
        nChars = nChars + 1
    end
    if nChars == 0 then
        nChars = #(self._state.scopeChars or {})
    end

    -- Step 5 hand-tuned vertical offset (shifted up 32px from defaults).
    -- X stays aligned with the other steps.
    local STEP5_LEFT = STEP_LEFT
    local STEP5_TOP = STEP_TOP - 32

    local summary = BodyText(self, "GameFontHighlight")
    summary:SetPoint("TOPLEFT", body, "TOPLEFT", STEP5_LEFT, -STEP5_TOP)
    summary:SetPoint("RIGHT", body, "RIGHT", 0, 0)
    summary:SetJustifyH("LEFT")
    summary:SetWordWrap(true)
    summary:SetSpacing(4)
    local rulesText = string.format("|cff00cc00%d|r new rule%s", newCount, newCount == 1 and "" or "s")
    local dupText = ""
    if dups > 0 then
        dupText = string.format(" |cffe8d9a8(%d duplicate%s skipped)|r", dups, dups == 1 and "" or "s")
    end

    -- Per-template summary copy. Two lines: top is the rule count, bottom
    -- describes the routing in plain English. Falls back to a generic line
    -- for templates without dedicated copy.
    local summaryText
    local tmpl = self._state.template
    local headLine = string.format("Will add %s.%s", rulesText, dupText)
    if tmpl == "self_banker" then
        local scopeText
        if nChars == 1 then
            scopeText = "This Character keeps their Profession mats in their own Character Bank"
        else
            scopeText = string.format(
                "Each of the %d Characters keeps their Profession mats in their own Character Bank",
                nChars
            )
        end
        local skillNote = self._state.maxSkillOnly
                and " |cffe8d9a8Shared Professions route to the highest-skill Character only.|r"
            or ""
        summaryText = string.format("%s\n%s.%s", headLine, scopeText, skillNote)
    elseif tmpl == "mule_banker" then
        local muleEntry = self._state.mule and EmpireManager.db.global.registry[self._state.mule]
        local muleLabel = muleEntry and CharLabel(muleEntry) or "?"
        summaryText = string.format(
            "%s\nEvery Profession across the roster routes to %s's Character Bank.",
            headLine,
            muleLabel
        )
    elseif tmpl == "guild_warband" then
        local destText
        if self._state.dest == "guild" then
            destText = string.format("the %s Guild Bank", self._state.guild or "Guild")
        else
            destText = "the Warband Bank"
        end
        summaryText = string.format(
            "%s\nEvery Profession across the roster routes to %s.",
            headLine,
            destText
        )
    elseif tmpl == "hybrid" then
        local cur = CurrentExpansionInfo()
        local curLabel = (cur and cur.label) or "Current expansion"
        local charText = (nChars == 1) and "this Character's Character Bank" or "each Character's Character Bank"
        local line
        if self._state.hybridDir == "current_to_charbank" then
            line = string.format(
                "%s mats route to %s; older mats route to the Warband Bank.",
                curLabel,
                charText
            )
        else
            line = string.format(
                "%s mats route to the Warband Bank; older mats route to %s.",
                curLabel,
                charText
            )
        end
        local skillNote = self._state.maxSkillOnly
                and " |cffe8d9a8Shared Professions route to the highest-skill Character only.|r"
            or ""
        summaryText = string.format("%s\n%s%s", headLine, line, skillNote)
    elseif tmpl == "stash_gear_recipes" then
        local destText
        if self._state.dest == "guild" then
            destText = string.format("the %s Guild Bank", self._state.guild or "Guild")
        elseif self._state.dest == "char" then
            local stashEntry = self._state.stashChar and EmpireManager.db.global.registry[self._state.stashChar]
            local stashLabel = stashEntry and CharLabel(stashEntry) or "?"
            destText = string.format("%s's Character Bank", stashLabel)
        else
            destText = "the Warband Bank"
        end
        summaryText = string.format(
            "%s\nEquipment, Recipes, Consumables, Item Enhancements, Pets, PvP, Lumber, Housing, and the secondary Professions route to %s.",
            headLine,
            destText
        )
    else
        local scopeText
        if nChars == 1 then
            scopeText = "for this Character"
        else
            scopeText = string.format("across %d Characters", nChars)
        end
        summaryText = string.format("%s\nApplies %s.", headLine, scopeText)
    end
    summary:SetText(summaryText)

    local function Divider()
        return self._pool:Acquire("divider", function()
            local t = body:CreateTexture(nil, "ARTWORK")
            t:SetAtlas("perks-divider-short", true)
            return t
        end)
    end

    -- Separator above the scroll frame (sits between summary text and list).
    local sepTop = Divider()
    sepTop:SetPoint("TOP", body, "TOP", 0, -(STEP5_TOP + 52))

    -- Scrollable preview list grouped by char. One per render, so it and its
    -- scroll child are built once and reused; the list text comes from
    -- `_listPool`, parented to that same scroll child.
    local scroll = self._pool:Acquire("previewScroll", function()
        local s = CreateFrame("ScrollFrame", nil, body, "ScrollFrameTemplate")
        s._poolKeepScripts = true
        local c = CreateFrame("Frame", nil, s)
        c:SetSize(1, 1)
        s:SetScrollChild(c)
        -- Match content width to the scroll viewport so rows have a real width to
        -- lay out in. Without this, content stays at width=1 and rows with
        -- SetPoint("RIGHT", content, ...) wrap heavily, leaving big vertical gaps.
        s:HookScript("OnSizeChanged", function(_, w, _)
            c:SetWidth(math.max(1, w))
        end)
        s.Content = c
        return s
    end)
    scroll:SetPoint("TOPLEFT", body, "TOPLEFT", STEP5_LEFT, -(STEP5_TOP + 60))
    scroll:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -22, 86)
    -- A fresh frame used to open at the top; keep that on reuse.
    scroll:SetVerticalScroll(0)

    -- Separator below the scroll frame (between list and clearExisting checkbox).
    local sepBot = Divider()
    sepBot:SetPoint("BOTTOM", body, "BOTTOM", 0, 78)

    local content = scroll.Content
    if scroll:GetWidth() > 1 then
        content:SetWidth(scroll:GetWidth())
    end
    local listPool = self._listPool

    -- Group rules by char (or by destination if no char)
    local groups, order = {}, {}
    for _, r in ipairs(rules) do
        local key = r.char or ("__dest_" .. (r.type or "?") .. "_" .. (r.guild or ""))
        if not groups[key] then
            groups[key] = { rules = {}, isChar = r.char ~= nil, char = r.char, type = r.type, guild = r.guild }
            order[#order + 1] = key
        end
        groups[key].rules[#groups[key].rules + 1] = r
    end

    local y = 0
    local profByKey = EmpireManager.PROF_INFO_BY_KEY or {}
    for _, key in ipairs(order) do
        local g = groups[key]
        local header = listPool:AcquireText(content, "GameFontNormalMed1")
        header:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        local headerText
        if g.isChar then
            local entry = EmpireManager.db.global.registry[g.char]
            headerText = CharLabel(entry)
        else
            if g.type == "warbandbank" then
                headerText = "Warband Bank"
            elseif g.type == "guildbank" then
                headerText = "Guild Bank (" .. (g.guild or "Guild") .. ")"
            else
                headerText = g.type or "?"
            end
        end
        header:SetText(headerText)
        header:SetTextColor(1, 0.82, 0)
        y = y + 20

        for _, r in ipairs(g.rules) do
            local row = listPool:AcquireText(content, "GameFontHighlightSmall")
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 12, -y)
            row:SetPoint("RIGHT", content, "RIGHT", -8, 0)
            row:SetJustifyH("LEFT")
            row:SetWordWrap(false)
            row:SetNonSpaceWrap(false)
            row:SetHeight(14)
            local profInfo = profByKey[r.profession]
            local profLabel = profInfo and profInfo.label or r.profession or "?"
            local destText
            if r.type == "warbandbank" then
                destText = "Warband Bank"
            elseif r.type == "guildbank" then
                destText = "Guild Bank (" .. (r.guild or "Guild") .. ")"
            elseif r.type == "charbank" then
                destText = "Character Bank"
            else
                destText = r.type or "?"
            end
            local expText = ""
            if r.expansions and #r.expansions > 0 then
                if #r.expansions == 1 then
                    local eid = r.expansions[1]
                    for _, info in ipairs(EmpireManager.EXPANSION_DISPLAY) do
                        if info.expansionID == eid then
                            expText = " |cffe8d9a8(" .. info.label .. ")|r"
                            break
                        end
                    end
                else
                    expText = string.format(" |cffe8d9a8(%d expansions)|r", #r.expansions)
                end
            end
            row:SetText(string.format("%s » %s%s", profLabel, destText, expText))
            row:SetTextColor(1, 1, 1)
            y = y + 16
        end
        y = y + 6
    end

    if #order == 0 then
        local empty = listPool:AcquireText(content, "GameFontHighlight")
        empty:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
        empty:SetText("|cffff8800No rules generated. Go back and adjust your selections.|r")
        y = 24
    end
    content:SetHeight(math.max(y, 1))

    -- clearExisting defaults off because it's destructive.
    if self._state.clearExisting == nil then
        self._state.clearExisting = false
    end

    local cbClear = CheckBox(self)
    cbClear:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", STEP5_LEFT, 46)
    cbClear:SetChecked(self._state.clearExisting)
    cbClear:SetScript("OnClick", function(btn)
        self._state.clearExisting = btn:GetChecked() and true or false
        -- Re-render so the summary line updates (dups become 0 when wiping).
        self:Render()
    end)
    local cbClearLbl = MakeClickableLabel(self, body, cbClear, "Clear all existing rules first |cffff6060(destructive)|r")
    cbClearLbl:SetPoint("LEFT", cbClear, "RIGHT", 2, 0)
end

-------------------------------------------------------------------------------
-- Step navigation
-------------------------------------------------------------------------------

-- Display label for the step indicator above the body. Hoisted to file scope
-- so we don't reallocate on every Render call.
local STEP_NAMES = {
    [1] = "Pick a template",
    [2] = "Configure template",
    [3] = "Choose Characters",
    [5] = "Review",
}

-- Returns the ordered list of step numbers we'll actually walk through given
-- the current template selection.
local function StepsForTemplate(tmpl)
    if tmpl == "self_banker" then
        return { 1, 2, 3, 5 }
    elseif tmpl == "mule_banker" then
        return { 1, 2, 3, 5 }
    elseif tmpl == "guild_warband" then
        -- Skip Scope: every character's profession items route to the
        -- same shared bank regardless of who picked them up.
        return { 1, 2, 5 }
    elseif tmpl == "hybrid" then
        return { 1, 2, 3, 5 }
    elseif tmpl == "stash_gear_recipes" then
        -- Same flow as guild_warband: pick destination, review. Categories are
        -- not character-specific, so no Scope step.
        return { 1, 2, 5 }
    end
    return { 1 } -- none selected yet
end

function EMWizardMixin:Render()
    ClearBody(self)

    local steps = StepsForTemplate(self._state.template)
    local stepIdx = self._state.stepIdx or 1
    if stepIdx > #steps then
        stepIdx = #steps
        self._state.stepIdx = stepIdx
    end
    local step = steps[stepIdx]

    -- Step name (no numbering - step lists vary by template, so a step
    -- counter would be misleading). Title is set once at init time.
    local stepLabel = STEP_NAMES[step] or ""
    -- Resolve the active template's display label (used to prefix steps 2+)
    local tmplLabel
    for _, t in ipairs(TEMPLATES) do
        if t.key == self._state.template then
            tmplLabel = t.label
            break
        end
    end
    if step == 2 and tmplLabel then
        stepLabel = tmplLabel
    elseif step >= 3 and tmplLabel then
        stepLabel = tmplLabel .. " - " .. stepLabel
    end
    self.StepBar.StepText:SetText("|cffffd100" .. stepLabel .. "|r")

    -- Render the active step
    if step == 1 then
        self:RenderStep1()
    elseif step == 2 then
        self:RenderStep2()
    elseif step == 3 then
        -- Make sure scopeChars is consistent before rendering
        self:RecomputeScopeChars()
        self:RenderStep3()
    elseif step == 5 then
        self:RecomputeScopeChars()
        self._state.previewRules = GenerateRules(self._state)
        self._state.previewDups = CountDuplicates(self._state.previewRules)
        self:RenderStep5()
    end

    -- Buttons
    self.BackButton:SetEnabled(stepIdx > 1)
    local isLastStep = (stepIdx == #steps)
    self.NextButton:SetText(isLastStep and "Finish" or "Next")

    -- Next/Finish enable rules
    local enableNext = true
    if step == 1 then
        enableNext = self._state.template ~= nil
    elseif step == 2 then
        local t = self._state.template
        if t == "mule_banker" then
            enableNext = self._state.mule ~= nil
        elseif t == "guild_warband" or t == "stash_gear_recipes" then
            if self._state.dest == "guild" then
                enableNext = (self._state.guild ~= nil and self._state.guild ~= "")
            elseif self._state.dest == "char" then
                enableNext = (self._state.stashChar ~= nil)
            else
                enableNext = (self._state.dest == "warband")
            end
        end
    elseif step == 3 then
        local pg = EmpireManager.playerGUID
        local pgEntry = pg and EmpireManager.db.global.registry[pg]
        if self._state.scope == "logged_in" and not IsEligible(pgEntry) then
            enableNext = false
        elseif self._state.scope == "all" then
            local any = false
            for _, c in ipairs(SortedChars()) do
                if IsEligible(c.entry) then
                    any = true
                    break
                end
            end
            enableNext = any
        end
    elseif step == 5 then
        enableNext = (#(self._state.previewRules or {}) > 0)
    end
    self.NextButton:SetEnabled(enableNext)
end

function EMWizardMixin:RecomputeScopeChars()
    local out = {}
    if self._state.scope == "logged_in" then
        local pg = EmpireManager.playerGUID
        local entry = pg and EmpireManager.db.global.registry[pg]
        if entry and IsEligible(entry) then
            out[#out + 1] = { guid = pg, entry = entry }
        end
    else
        for _, c in ipairs(SortedChars()) do
            if IsEligible(c.entry) then
                out[#out + 1] = c
            end
        end
    end
    self._state.scopeChars = out
end

function EMWizardMixin:GoNext()
    local steps = StepsForTemplate(self._state.template)
    local stepIdx = self._state.stepIdx or 1

    if stepIdx >= #steps then
        self:Finish()
        return
    end

    self._state.stepIdx = stepIdx + 1
    self:Render()
end

function EMWizardMixin:GoBack()
    local stepIdx = self._state.stepIdx or 1
    if stepIdx <= 1 then
        return
    end
    self._state.stepIdx = stepIdx - 1
    self:Render()
end

-------------------------------------------------------------------------------
-- Finish
-------------------------------------------------------------------------------

function EMWizardMixin:Finish()
    if self._state.clearExisting then
        local existing = EmpireManager.db.global.storageAssignments or {}
        local n = #existing
        if n > 0 then
            StaticPopupDialogs["EMPIREMANAGER_WIZARD_CLEAR_CONFIRM"] = {
                text = "Wipe all |cffff4444%d|r existing Storage Rule%s before applying the new ones?\n\n|cffff4444This cannot be undone.|r",
                button1 = YES,
                button2 = NO,
                timeout = 0,
                whileDead = true,
                hideOnEscape = true,
                preferredIndex = 3,
            }
            local popup = StaticPopupDialogs["EMPIREMANAGER_WIZARD_CLEAR_CONFIRM"]
            popup.OnAccept = function()
                EmpireManager.db.global.storageAssignments = {}
                self:_DoFinish()
            end
            StaticPopup_Show("EMPIREMANAGER_WIZARD_CLEAR_CONFIRM", n, n == 1 and "" or "s")
            return
        end
    end
    self:_DoFinish()
end

function EMWizardMixin:_DoFinish()
    local rules = self._state.previewRules or {}
    local lenBefore = #(EmpireManager.db.global.storageAssignments or {})
    local imported, skipped = 0, 0
    if #rules > 0 then
        imported, skipped = EmpireManager:ApplyImportedRules(rules)
    end

    -- Auto-assign Artisan/Gatherer for every character that owns at least one
    -- generated rule (charbank or guildbank `char` field). Warband-only rules
    -- carry no `char`, so they don't trigger role assignment. Banker role is
    -- handled by SyncBankerRole inside ApplyImportedRules.
    local touchedGuids = {}
    for _, r in ipairs(rules) do
        if r.char then
            touchedGuids[r.char] = true
        end
    end
    for guid in pairs(touchedGuids) do
        local entry = EmpireManager.db.global.registry[guid]
        if entry then
            EmpireManager:AutoAssignRoles(entry, guid)
        end
    end

    EmpireManager:InvalidateStorageCache()
    EmpireManager.db.global.wizardSeen = true
    -- Scroll to the first newly added rule when the Storage tab repaints,
    -- so the user lands on the new content instead of a stale offset.
    if imported and imported > 0 then
        EmpireManager._storageScrollToIdx = lenBefore + 1
    end

    local msg
    if skipped > 0 then
        msg = string.format(
            "|cffffd100[Wizard]|r Created |cff00cc00%d|r new rule%s, |cffaaaaaa%d|r duplicate%s skipped.",
            imported,
            imported == 1 and "" or "s",
            skipped,
            skipped == 1 and "" or "s"
        )
    else
        msg = string.format(
            "|cffffd100[Wizard]|r Created |cff00cc00%d|r new rule%s.",
            imported,
            imported == 1 and "" or "s"
        )
    end
    EmpireManager:ChatMsg(msg, true)

    self:Close()

    -- Refresh storage tab if open
    if EmpireManager.dashboardFrame and EmpireManager.dashboardFrame:IsShown() then
        if EmpireManager.activeTab and EmpireManager.SelectDashboardTab then
            EmpireManager:SelectDashboardTab("storage")
        end
    end
end

function EMWizardMixin:Close()
    self:Hide()
end

-------------------------------------------------------------------------------
-- Frame init / opening
-------------------------------------------------------------------------------

function EmpireManager:InitWizardFrame()
    local f = EmpireManagerWizardFrame
    if not f or f._initialized then
        return f
    end
    f._initialized = true

    Mixin(f, EMWizardMixin)

    -- PortraitFrameTemplate handles drag, close button, and the backdrop, but
    -- it does NOT set draggability by default - mirror Sidecar's pattern.
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    -- Title + portrait icon (wand to match the Storage page wand button)
    f:SetTitle("EmpireManager - Storage Setup Wizard")
    f:SetPortraitToAsset("Interface\\Icons\\INV_Wand_02")

    -- The portrait frame ships with a help-tip "(?)" button on some skins; the
    -- explicit InfoButton from the dashboard isn't part of this frame, but if
    -- PortraitFrameTemplate exposes one we hide it for now.
    if f.MainHelpButton then
        f.MainHelpButton:Hide()
    end

    f.BackButton:SetText("Back")
    f.NextButton:SetText("Next")

    f.BackButton:SetScript("OnClick", function()
        f:GoBack()
    end)
    f.NextButton:SetScript("OnClick", function()
        f:GoNext()
    end)

    f:HookScript("OnHide", function(self_)
        ClearBody(self_)
    end)

    return f
end

function EmpireManager:OpenWizard()
    local f = self:InitWizardFrame()
    if f:IsShown() then
        return
    end
    -- Fresh state on each open
    f._state = {
        template = nil,
        stepIdx = 1,
        scope = "all",
    }
    f:Render()
    f:Show()
end
