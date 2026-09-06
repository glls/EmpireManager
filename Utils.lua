-- ----------------------------------------------------------------------------
--                                   EmpireManager
--                              https://wow.cyberpunk.gr
--                (c) by George Litos (l0neshad0w),  All Rights Reserved
--                   For detailed license information check LICENSE.md
-- ----------------------------------------------------------------------------

local EmpireManager = LibStub("AceAddon-3.0"):GetAddon("EmpireManager")

-- Role display: single-character abbreviations with colors
-- profType = "crafting"/"gathering" means the role supports a profession dropdown
EmpireManager.ROLE_DISPLAY = {
    {
        key = "artisan",
        label = "Artisan",
        icon = "Interface\\Icons\\INV_Scroll_02",
        r = 0.576,
        g = 0.439,
        b = 0.859,
        profType = "crafting",
    },
    {
        key = "gatherer",
        label = "Gatherer",
        icon = "Interface\\Icons\\INV_Misc_Bag_HerbPouch",
        r = 0.0,
        g = 0.8,
        b = 0.0,
        profType = "gathering",
    },
    {
        key = "auctioneer",
        label = "Auctioneer",
        icon = "Interface\\Icons\\INV_Misc_Coin_01",
        r = 1.0,
        g = 0.843,
        b = 0.0,
    },
    {
        key = "banker",
        label = "Banker",
        icon = "Interface\\Icons\\INV_Misc_Bag_07",
        r = 1.0,
        g = 0.843,
        b = 0.0,
    },
    {
        key = "lockpicker",
        label = "Lockpicker",
        icon = "Interface\\Icons\\INV_Misc_Key_04",
        r = 1.0,
        g = 0.2,
        b = 0.6,
    },
    {
        key = "zookeeper",
        label = "Zookeeper",
        icon = "Interface\\Icons\\INV_Box_PetCarrier_01",
        r = 0.4,
        g = 0.9,
        b = 0.4,
    },
    {
        key = "pvper",
        label = "PvPer",
        icon = "Interface\\Icons\\Ability_DualWield",
        r = 0.95,
        g = 0.95,
        b = 0.95,
    },
}

-- Expansion display (kept for future expansion filter, Phase 2)
EmpireManager.EXPANSION_DISPLAY = {
    {
        key = "classic",
        label = "Classic",
        r = 0.8,
        g = 0.7,
        b = 0.3,
        expansionID = 0,
        iconWidth = 34,
        icon = "Interface\\AddOns\\EmpireManager\\Textures\\Expansions\\classic",
    },
    {
        key = "tbc",
        label = "The Burning Crusade",
        apiNames = { "Outland" },
        r = 0.1,
        g = 0.8,
        b = 0.1,
        expansionID = 1,
        iconWidth = 32,
        icon = "Interface\\AddOns\\EmpireManager\\Textures\\Expansions\\bc",
    },
    {
        key = "wotlk",
        label = "Wrath of the Lich King",
        apiNames = { "Northrend" },
        r = 0.4,
        g = 0.6,
        b = 0.9,
        expansionID = 2,
        iconWidth = 38,
        icon = "Interface\\AddOns\\EmpireManager\\Textures\\Expansions\\wrath",
    },
    {
        key = "cata",
        label = "Cataclysm",
        r = 0.9,
        g = 0.4,
        b = 0.0,
        expansionID = 3,
        iconWidth = 42,
        icon = "Interface\\AddOns\\EmpireManager\\Textures\\Expansions\\cata",
    },
    {
        key = "mop",
        label = "Mists of Pandaria",
        apiNames = { "Pandaria" },
        r = 0.0,
        g = 0.8,
        b = 0.3,
        expansionID = 4,
        iconWidth = 44,
        icon = "Interface\\AddOns\\EmpireManager\\Textures\\Expansions\\mop",
    },
    {
        key = "wod",
        label = "Warlords of Draenor",
        apiNames = { "Draenor" },
        r = 0.7,
        g = 0.3,
        b = 0.0,
        expansionID = 5,
        iconWidth = 44,
        icon = "Interface\\AddOns\\EmpireManager\\Textures\\Expansions\\wod",
    },
    {
        key = "legion",
        label = "Legion",
        r = 0.1,
        g = 0.9,
        b = 0.1,
        expansionID = 6,
        iconWidth = 42,
        icon = "Interface\\AddOns\\EmpireManager\\Textures\\Expansions\\legion",
    },
    {
        key = "bfa",
        label = "Battle for Azeroth",
        apiNames = { "Kul Tiran", "Zandalari" },
        r = 0.0,
        g = 0.5,
        b = 0.8,
        expansionID = 7,
        iconWidth = 42,
        icon = "Interface\\AddOns\\EmpireManager\\Textures\\Expansions\\bfa",
    },
    {
        key = "shadowlands",
        label = "Shadowlands",
        r = 0.5,
        g = 0.5,
        b = 0.7,
        expansionID = 8,
        iconWidth = 44,
        icon = "Interface\\AddOns\\EmpireManager\\Textures\\Expansions\\sl",
    },
    {
        key = "dragonflight",
        label = "Dragonflight",
        apiNames = { "Dragon Isles" },
        r = 0.2,
        g = 0.7,
        b = 0.5,
        expansionID = 9,
        iconWidth = 44,
        icon = "Interface\\AddOns\\EmpireManager\\Textures\\Expansions\\df",
    },
    {
        key = "tww",
        label = "The War Within",
        apiNames = { "Khaz Algar" },
        r = 0.4,
        g = 0.2,
        b = 0.6,
        expansionID = 10,
        iconWidth = 42,
        icon = "Interface\\AddOns\\EmpireManager\\Textures\\Expansions\\tww",
    },
    {
        key = "midnight",
        label = "Midnight",
        r = 0.5,
        g = 0.0,
        b = 0.8,
        expansionID = 11,
        iconWidth = 42,
        icon = "Interface\\AddOns\\EmpireManager\\Textures\\Expansions\\mn",
    },
}

-- Localized expansion names as returned by C_TradeSkillUI (ProfessionInfo.expansionName).
-- ProfessionInfo carries NO numeric expansionID, so the name is the only handle we get
-- and it is localized - hence this table. Keyed by lowercased API name -> expansionID.
-- Add a language by appending its names; unknown names simply fall back to no ID
-- (the row is still stored and displayed under its raw name).
-- deDE names captured from a live German client.
EmpireManager.EXPANSION_API_NAME_TO_ID = {
    -- deDE
    ["klassisch"] = 0,
    ["scherbenwelt"] = 1,
    ["nordend"] = 2,
    ["kataklysmus"] = 3,
    ["schattenlande"] = 8,
    ["dracheninseln"] = 9,
    ["kul tiras"] = 7,
    -- Names identical across enUS/deDE (Pandaria, Draenor, Legion, Khaz Algar,
    -- Midnight, Classic) are covered by EXPANSION_DISPLAY label/apiNames already,
    -- but listed here too so this table alone is sufficient.
    ["classic"] = 0,
    ["pandaria"] = 4,
    ["draenor"] = 5,
    ["legion"] = 6,
    ["khaz algar"] = 10,
    ["midnight"] = 11,
}

-- Returns an inline texture string for an expansion icon, cropped to its iconWidth
function EmpireManager:ExpIconString(expInfo, yOffset)
    local w = expInfo.iconWidth or 44
    local x1 = math.floor((64 - w) / 2)
    local x2 = x1 + w
    return string.format("|T%s:22:%d:0:%d:64:32:%d:%d:5:27|t", expInfo.icon, w, yOffset or 0, x1, x2)
end

-- Apply the yellow-with-hover icon-button look (same as storage row up/down arrows)
-- to a Button that already has a NormalTexture set (via XML or code).
-- `alpha` is optional and defaults to 1 (applied to the normal and pushed textures).
function EmpireManager:StyleIconButton(btn, alpha)
    if not btn then
        return
    end
    local nt = btn:GetNormalTexture()
    if not nt then
        return
    end
    local tex = nt:GetTexture()
    if not tex then
        return
    end

    alpha = alpha or 1
    nt:SetVertexColor(1, 0.82, 0)
    nt:SetAlpha(alpha)

    btn:SetPushedTexture(tex)
    local pt = btn:GetPushedTexture()
    if pt then
        pt:SetVertexColor(0.8, 0.65, 0)
        pt:SetAlpha(alpha)
    end

    btn:SetHighlightTexture(tex, "ADD")
    local ht = btn:GetHighlightTexture()
    if ht then
        ht:SetVertexColor(1, 1, 0.6)
        ht:SetAlpha(0.5)
    end
end

-- For scrollable WowStyle1DropdownTemplate dropdowns: scroll the popup so the
-- currently selected radio is visible on open. MenuUtil itself does not do
-- this. Pattern lifted from Blizzard_DelvesDifficultyPicker.lua. The getter
-- runs at open time and returns the 1-based index of the selected radio in
-- the order it was added in SetupMenu, or nil if nothing is selected.
function EmpireManager:EnableDropdownScrollToSelected(dd, getSelectedIndex)
    dd:RegisterCallback(DropdownButtonMixin.Event.OnMenuOpen, function(dropdown)
        if not dropdown.menu or not dropdown.menu.ScrollBox then
            return
        end
        if not dropdown.menu.ScrollBox:HasScrollableExtent() then
            return
        end
        local idx = getSelectedIndex and getSelectedIndex()
        if idx and idx > 0 then
            dropdown.menu.ScrollBox:ScrollToElementDataIndex(idx, ScrollBoxConstants.AlignCenter)
        end
    end, dd)
end

-- Safeguard: backfill a freshly-captured guildRealm onto storage rules and
-- registry entries for that guild that don't have one yet.
--
-- This ONLY fills blanks. It must never overwrite a populated realm with a
-- different one: guild names are not unique across realms, and two guilds
-- called "Vanguard" on different realms (a legacy Alliance/Horde pair, say)
-- are distinct banks. An earlier version matched on guild name alone and
-- stamped the current character's guild realm onto every same-named guild,
-- collapsing the pair into one - which made BuildGuildList show a single
-- entry and made triage mail items to a banker while the correct guild bank
-- was open. A rule whose realm is already set is either correct or is fixed
-- by logging in on a character in that specific guild.
function EmpireManager:PropagateGuildRealmToRules(guildName, guildRealm)
    if not guildName or guildName == "" or not guildRealm or guildRealm == "" then
        return
    end
    for _, asn in ipairs(self.db.global.storageAssignments or {}) do
        if asn.type == "guildbank" and asn.guild == guildName and (asn.realm or "") == "" then
            asn.realm = guildRealm
        end
    end
    -- Backfill guildRealm on registry entries in this guild that lack one.
    -- Entries that already carry a realm are left alone - an alt in the
    -- same-named guild on another realm must keep its own value.
    for _, entry in pairs(self.db.global.registry or {}) do
        if entry.guild == guildName and (entry.guildRealm or "") == "" then
            entry.guildRealm = guildRealm
        end
    end
end

-- Composite key for cap.guildbank and any other guild-keyed table. Guild names
-- are not unique across realms (two "Vanguard" guilds on different realms are
-- distinct), so the storage key must include realm. Returns nil if either
-- component is missing so callers can early-out cleanly.
function EmpireManager:GuildKey(guildName, realm)
    if not guildName or guildName == "" then
        return nil
    end
    if not realm or realm == "" then
        return nil
    end
    -- Normalize realm: the same realm shows up with a space ("Steamwheedle Cartel"
    -- via GetRealmName) and without ("SteamwheedleCartel" via GetNormalizedRealmName),
    -- depending on which API the caller used. Collapse to one form so snapshot keys
    -- and rule lookups always match.
    realm = realm:gsub("%s+", "")
    return guildName .. "-" .. realm
end

-- Is this (guild, realm) pair blacklisted?
--
-- Blacklist entries are keyed by GuildKey ("Guild-Realm") so that two guilds
-- sharing a name on different realms can be hidden independently. Entries
-- written before the key was realm-aware are bare guild names; those are still
-- honoured for any realm, since the user's intent back then was "hide this
-- name" and there was no way to express a narrower one. Re-adding a guild
-- through the blacklist window upgrades it to the composite form.
function EmpireManager:IsGuildBlacklisted(guildName, realm)
    if not guildName or guildName == "" then
        return false
    end
    local bl = self.db.global.guildBlacklist
    if not bl then
        return false
    end
    if bl[guildName] then
        return true -- legacy bare-name entry
    end
    local key = self:GuildKey(guildName, realm)
    return key ~= nil and bl[key] == true
end

-- Normalize a realm name for equality checks. The same realm shows up with a
-- space ("Steamwheedle Cartel" via GetRealmName) and without ("SteamwheedleCartel"
-- via GetNormalizedRealmName / rule storage), so any realm comparison that might
-- mix the two sources must normalize both sides. Matches GuildKey's normalization.
function EmpireManager:NormRealm(realm)
    if not realm or realm == "" then
        return ""
    end
    return (realm:gsub("%s+", ""))
end

-- Single source of truth for the About panel layout. Called from both the
-- Dashboard's About tab and the Interface > AddOns > EmpireManager canvas.
-- `parent` is the frame to lay content into. `opts.track`, if provided, is
-- called with each created child so the caller can hide/clear them on a
-- subsequent rebuild (Dashboard re-renders on every OnShow; the Settings
-- canvas is one-shot and passes no track).
-- Returns the total content height in pixels.
function EmpireManager:BuildAboutPanel(parent, opts)
    opts = opts or {}
    local track = opts.track or function(o) return o end
    local LINE_HEIGHT = 20
    local FONT_NORMAL = "GameFontHighlight"

    -- Divider width: the atlas is 512px at native size, which overhangs the
    -- narrower Settings canvas. Inset it from the parent and cap it so it stays
    -- a decorative rule rather than a full-bleed line.
    local DIVIDER_HEIGHT = 8
    local parentWidth = parent:GetWidth() or 0
    local dividerWidth = parentWidth > 0 and (parentWidth - 80) or 380
    if dividerWidth > 380 then
        dividerWidth = 380
    elseif dividerWidth < 160 then
        dividerWidth = 160
    end

    local y = 8

    local LOGO_SIZE = 96
    local TEXT_LEFT = 8 + LOGO_SIZE + 12

    local logo = track(parent:CreateTexture(nil, "ARTWORK"))
    logo:SetTexture("Interface\\AddOns\\EmpireManager\\textures\\logo256")
    logo:SetSize(LOGO_SIZE, LOGO_SIZE)
    logo:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -y)

    y = y - 2

    local title = track(parent:CreateTexture(nil, "ARTWORK"))
    title:SetTexture("Interface\\AddOns\\EmpireManager\\textures\\em")
    title:SetSize(192, 48)
    title:SetPoint("TOPLEFT", parent, "TOPLEFT", TEXT_LEFT, -(y + 4))
    y = y + 52

    local ver = track(parent:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
    ver:SetPoint("TOPLEFT", parent, "TOPLEFT", TEXT_LEFT, -y)
    ver:SetText("Version " .. (self.version or "?"))
    ver:SetTextColor(0.91, 0.85, 0.66)
    y = y + LINE_HEIGHT

    local author = track(parent:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
    author:SetPoint("TOPLEFT", parent, "TOPLEFT", TEXT_LEFT, -y)
    author:SetText("|cffe8d9a8Author:|r  l0neshad0w")
    author:SetTextColor(1, 1, 1)
    y = y + LINE_HEIGHT

    if y < 8 + LOGO_SIZE then
        y = 8 + LOGO_SIZE
    end

    -- Clickable header (logo + title + version + author) opens the website URL popup.
    local linkBtn = track(CreateFrame("Button", nil, parent))
    linkBtn:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -8)
    linkBtn:SetPoint("BOTTOMRIGHT", parent, "TOPLEFT", 8 + LOGO_SIZE + 12 + 220, -y)
    linkBtn:SetScript("OnClick", function()
        StaticPopup_Show("EM_URL_SITE")
    end)
    linkBtn:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_CURSOR")
        GameTooltip:AddLine("https://wow.cyberpunk.gr", 1, 0.82, 0)
        GameTooltip:AddLine("Click to copy the website link", 1, 1, 1)
        GameTooltip:Show()
    end)
    linkBtn:SetScript("OnLeave", GameTooltip_Hide)

    y = y + 8

    local h1 = track(parent:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
    h1:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -y)
    h1:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
    h1:SetJustifyH("LEFT")
    h1:SetText(self.description)
    h1:SetTextColor(1, 1, 1)
    y = y + LINE_HEIGHT

    local lead = track(parent:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
    lead:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -y)
    lead:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
    lead:SetJustifyH("LEFT")
    lead:SetText("Track inventory, route materials, and stay in control of your entire roster.")
    lead:SetTextColor(1, 1, 1)
    y = y + LINE_HEIGHT + 8

    -- Statistics
    y = y + 4
    local statDivider = track(parent:CreateTexture(nil, "ARTWORK"))
    statDivider:SetAtlas("ui-journeys-renown-divider")
    statDivider:SetSize(dividerWidth, DIVIDER_HEIGHT)
    statDivider:SetPoint("TOP", parent, "TOP", 0, -y)
    y = y + 28
    local statHdr = track(parent:CreateFontString(nil, "OVERLAY", "GameFontNormal"))
    statHdr:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -y)
    statHdr:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
    statHdr:SetJustifyH("LEFT")
    statHdr:SetText("|cffffff88Statistics|r")
    y = y + LINE_HEIGHT
    y = y - 12

    local gStats = self.db.global.stats or {}
    local sStats = self._sessionStats or {}

    local function FmtNum(n)
        n = n or 0
        local s = tostring(math.floor(n))
        return s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    end

    local statDefs = {
        { key = "goldVendored",   label = "Gold from Vendors",       icon = "Interface\\Icons\\INV_Misc_Coin_17", fmt = "gold" },
        { key = "itemsVendored",  label = "Items Vendored",          icon = "Interface\\Icons\\INV_Misc_Bag_10",  fmt = "num"  },
        { key = "itemsStashed",   label = "Items Deposited to Bank", icon = "Interface\\Icons\\INV_Misc_Bag_07",  fmt = "num"  },
        { key = "itemsMailed",    label = "Items Mailed",            icon = "Interface\\Icons\\INV_Letter_15",    fmt = "num"  },
        { key = "goldRepaired",   label = "Gold on Repairs",         icon = "Interface\\Icons\\Trade_BlackSmithing", fmt = "gold" },
    }

    local STAT_LABEL_X = 12
    local STAT_LABEL_WIDTH = 220
    local STAT_SESSION_X = STAT_LABEL_X + STAT_LABEL_WIDTH
    local STAT_ALLTIME_X = STAT_SESSION_X + 120
    local STAT_COL_WIDTH = 100

    local hdrSession = track(parent:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
    hdrSession:SetPoint("TOPLEFT", parent, "TOPLEFT", STAT_SESSION_X, -y)
    hdrSession:SetWidth(STAT_COL_WIDTH)
    hdrSession:SetJustifyH("RIGHT")
    hdrSession:SetText("|cff88ccffThis Session|r")

    local hdrAll = track(parent:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
    hdrAll:SetPoint("TOPLEFT", parent, "TOPLEFT", STAT_ALLTIME_X, -y)
    hdrAll:SetWidth(STAT_COL_WIDTH)
    hdrAll:SetJustifyH("RIGHT")
    hdrAll:SetText("|cffffcc00All Time|r")
    y = y + LINE_HEIGHT

    for _, stat in ipairs(statDefs) do
        local sVal = sStats[stat.key] or 0
        local gVal = gStats[stat.key] or 0
        local sFmt = stat.fmt == "gold" and self:FormatGold(sVal) or FmtNum(sVal)
        local gFmt = stat.fmt == "gold" and self:FormatGold(gVal) or FmtNum(gVal)

        local lbl = track(parent:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
        lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", STAT_LABEL_X, -y)
        lbl:SetWidth(STAT_LABEL_WIDTH)
        lbl:SetJustifyH("LEFT")
        lbl:SetText(string.format("  |T%s:14:14|t  |cffe8d9a8%s|r", stat.icon, stat.label))

        local sFs = track(parent:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
        sFs:SetPoint("TOPLEFT", parent, "TOPLEFT", STAT_SESSION_X, -y)
        sFs:SetWidth(STAT_COL_WIDTH)
        sFs:SetJustifyH("RIGHT")
        sFs:SetText("|cff88ccff" .. sFmt .. "|r")

        local gFs = track(parent:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
        gFs:SetPoint("TOPLEFT", parent, "TOPLEFT", STAT_ALLTIME_X, -y)
        gFs:SetWidth(STAT_COL_WIDTH)
        gFs:SetJustifyH("RIGHT")
        gFs:SetText("|cffffffff" .. gFmt .. "|r")

        y = y + LINE_HEIGHT
    end

    y = y + 8

    -- Slash Commands divider + heading (inline version of AddSeparator).
    y = y + 4
    local cmdDivider = track(parent:CreateTexture(nil, "ARTWORK"))
    cmdDivider:SetAtlas("ui-journeys-renown-divider")
    cmdDivider:SetSize(dividerWidth, DIVIDER_HEIGHT)
    cmdDivider:SetPoint("TOP", parent, "TOP", 0, -y)
    y = y + 28
    local cmdHdr = track(parent:CreateFontString(nil, "OVERLAY", "GameFontNormal"))
    cmdHdr:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -y)
    cmdHdr:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
    cmdHdr:SetJustifyH("LEFT")
    cmdHdr:SetText("|cffffff88Slash Commands|r")
    y = y + 24

    local CMD_LABEL_WIDTH = 170
    for _, c in ipairs(EmpireManager.SLASH_COMMANDS) do
        local cmdFs = track(parent:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
        cmdFs:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, -y)
        cmdFs:SetWidth(CMD_LABEL_WIDTH)
        cmdFs:SetJustifyH("LEFT")
        cmdFs:SetText("|cffffd100" .. c.cmd .. "|r")

        local descFs = track(parent:CreateFontString(nil, "OVERLAY", FONT_NORMAL))
        descFs:SetPoint("TOPLEFT", parent, "TOPLEFT", 12 + CMD_LABEL_WIDTH, -y)
        descFs:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
        descFs:SetJustifyH("LEFT")
        descFs:SetText(c.desc)
        descFs:SetTextColor(1, 1, 1)
        y = y + 18
    end

    return y
end

-- Hardcoded: which item subclasses each profession consumes/produces
-- Values are {classID, subClassID} pairs from WoW's item classification
EmpireManager.PROF_ITEM_MAP = {
    alchemy = { { 7, 9 }, { 7, 11 } }, -- Herbs, Other (vials/oils/transmutagens)
    blacksmithing = { { 7, 7 } }, -- Metal & Stone
    enchanting = { { 7, 12 } }, -- Enchanting
    engineering = { { 7, 7 }, { 7, 1 } }, -- Metal & Stone, Parts
    inscription = { { 7, 9 }, { 7, 16 } }, -- Herbs, Inscription pigments
    jewelcrafting = {
        { 7, 4 },
        { 7, 7 }, -- Raw gems (Trade Goods), Metal & Stone
        { 3, 0 },
        { 3, 1 },
        { 3, 2 },
        { 3, 3 },
        { 3, 4 },
        { 3, 5 },
        { 3, 6 },
        { 3, 7 }, -- Cut gems (Gem classID 3)
        { 3, 8 },
        { 3, 9 },
        { 3, 10 },
        { 3, 11 },
        { 3, 12 },
        { 3, 13 },
        { 3, 14 },
    },
    leatherworking = { { 7, 6 } }, -- Leather
    tailoring = { { 7, 5 } }, -- Cloth
    herbalism = { { 7, 9 } }, -- Herbs
    mining = { { 7, 7 } }, -- Metal & Stone
    skinning = { { 7, 6 } }, -- Leather
    fishing = { { 7, 0 } }, -- Fish
    -- Secondary professions
    cooking = { { 7, 8 } }, -- Cooking mats. Do NOT add subclass 19 - it's the generic "Finishing Reagent" bucket shared across Tailoring/Alchemy/Inscription (Petal Powder, Mycobloom Culture, Weavercloth Embroidery Thread) and cannot route to a single profession.
    -- archaeology: no clean subclass match (fragments are not standard tradegoods)
    -- Neutral material category, and the only key that claims 7/10. Alchemy,
    -- Blacksmithing, Enchanting and Engineering all consume these materials, so
    -- listing the subclass under any one of them sends the whole bucket to that
    -- profession's banker and leaves the others empty. Giving it its own key means a
    -- single Elemental rule routes the material itself rather than whichever
    -- profession rule happens to sit highest in storageAssignments. Herbs, Metal &
    -- Stone and Leather need no equivalent - Herbalism, Mining and Skinning are
    -- already narrowed to exactly those subclasses.
    elemental = { { 7, 10 } }, -- Elemental/Primal materials
    -- Non-profession storage categories
    consumables = {
        { 0, 0 },
        { 0, 1 },
        { 0, 2 },
        { 0, 3 }, -- Generic, Potion, Elixir, Flask
        { 0, 5 },
        { 0, 7 },
        { 0, 8 },
        { 0, 9 }, -- Food & Drink, Bandage, Other, Vantus Runes
    },
    item_enhancements = {
        { 8, 0 },
        { 8, 1 },
        { 8, 2 },
        { 8, 3 },
        { 8, 4 },
        { 8, 5 },
        { 8, 6 },
        { 8, 7 },
        { 8, 8 },
        { 8, 9 },
        { 8, 10 }, -- Ring (confirmed in-game from Enchant Ring scrolls)
        { 8, 11 },
        { 8, 12 }, -- all armor/weapon slots: enchant scrolls, armor kits, etc.
    },
    pets = {
        { 15, 2 }, -- Old companion pet items (Miscellaneous > Companion)
        { 17, 0 },
        { 17, 1 },
        { 17, 2 },
        { 17, 3 }, -- Caged battle pets: Humanoid, Dragonkin, Flying, Undead
        { 17, 4 },
        { 17, 5 },
        { 17, 6 },
        { 17, 7 }, -- Critter, Magic, Elemental, Beast
        { 17, 8 },
        { 17, 9 },
        { 17, 10 }, -- Aquatic, Mechanical, Nocturnal
    },
    equipment_boe = {
        -- Weapons (classID 2)
        { 2, 0 },
        { 2, 1 },
        { 2, 2 },
        { 2, 3 },
        { 2, 4 },
        { 2, 5 },
        { 2, 6 },
        { 2, 7 },
        { 2, 8 },
        { 2, 9 },
        { 2, 10 },
        { 2, 11 },
        { 2, 13 },
        { 2, 14 },
        { 2, 15 },
        { 2, 16 },
        { 2, 17 },
        { 2, 18 },
        { 2, 19 },
        { 2, 20 },
        -- Armor (classID 4)
        { 4, 0 },
        { 4, 1 },
        { 4, 2 },
        { 4, 3 },
        { 4, 4 },
        { 4, 5 },
        { 4, 6 },
        { 4, 7 },
        { 4, 8 },
        { 4, 9 },
        { 4, 10 },
        { 4, 11 },
    },
    equipment_boa = {
        -- Weapons (classID 2)
        { 2, 0 },
        { 2, 1 },
        { 2, 2 },
        { 2, 3 },
        { 2, 4 },
        { 2, 5 },
        { 2, 6 },
        { 2, 7 },
        { 2, 8 },
        { 2, 9 },
        { 2, 10 },
        { 2, 11 },
        { 2, 13 },
        { 2, 14 },
        { 2, 15 },
        { 2, 16 },
        { 2, 17 },
        { 2, 18 },
        { 2, 19 },
        { 2, 20 },
        -- Armor (classID 4)
        { 4, 0 },
        { 4, 1 },
        { 4, 2 },
        { 4, 3 },
        { 4, 4 },
        { 4, 5 },
        { 4, 6 },
        { 4, 7 },
        { 4, 8 },
        { 4, 9 },
        { 4, 10 },
        { 4, 11 },
    },
    -- Profession equipment (classID 19): tools and accessories worn in the
    -- profession gear slots. subClassID IS the profession (Enum.ItemProfessionSubclass),
    -- so this needs no itemID curation. The subclass list mirrors Blizzard's own
    -- "Profession Equipment" AH category, which omits Archaeology (13).
    equipment_prof = {
        { 19, 0 }, -- Blacksmithing
        { 19, 1 }, -- Leatherworking
        { 19, 2 }, -- Alchemy
        { 19, 3 }, -- Herbalism
        { 19, 4 }, -- Cooking
        { 19, 5 }, -- Mining
        { 19, 6 }, -- Tailoring
        { 19, 7 }, -- Engineering
        { 19, 8 }, -- Enchanting
        { 19, 9 }, -- Fishing
        { 19, 10 }, -- Skinning
        { 19, 11 }, -- Jewelcrafting
        { 19, 12 }, -- Inscription
    },
    housing = {
        { 20, 0 }, -- Furniture
        { 20, 1 }, -- Dyes
    },
    recipes = {
        -- Recipes (classID 9): Pattern, Plans, Recipe, Book, etc.
        { 9, 0 },
        { 9, 1 },
        { 9, 2 },
        { 9, 3 },
        { 9, 4 },
        { 9, 5 },
        { 9, 6 },
        { 9, 7 },
        { 9, 8 },
        { 9, 9 },
        { 9, 10 },
        { 9, 11 },
    },
}

-- itemID → list of profession keys this item is consumed by.
-- Use this when a single classID/subClassID bucket can't disambiguate the
-- profession (e.g. Trade Goods subclass 11 "Other" is shared by alchemy
-- reagents, engineering crafting widgets, and cross-profession Midnight motes).
-- Override entries take precedence over PROF_ITEM_MAP for routing decisions:
-- the resulting match set replaces the subclass-derived match set entirely
-- (no merging) so an item misclassified by subclass can be reassigned cleanly.
EmpireManager.PROF_ITEM_OVERRIDES = {
    -- Midnight (expansion 11) cross-profession motes - Trade Goods 7/11.
    -- Subclass 11 currently maps to alchemy only; these are cross-profession
    -- transmute/recycle reagents used by every crafting profession.
    [236949] = { "alchemy", "engineering", "tailoring", "leatherworking", "inscription", "blacksmithing", "jewelcrafting", "enchanting" }, -- Mote of Light
    [236950] = { "alchemy", "engineering", "tailoring", "leatherworking", "inscription", "blacksmithing", "jewelcrafting", "enchanting" }, -- Mote of Primal Energy
    [236951] = { "alchemy", "engineering", "tailoring", "leatherworking", "inscription", "blacksmithing", "jewelcrafting", "enchanting" }, -- Mote of Wild Magic
    [236952] = { "alchemy", "engineering", "tailoring", "leatherworking", "inscription", "blacksmithing", "jewelcrafting", "enchanting" }, -- Mote of Pure Void
    -- Engineering crafting widgets that share Trade Goods 7/11 with alchemy reagents.
    [253302] = { "engineering" }, -- Malleable Wireframe
    [253303] = { "engineering" }, -- Pile of Junk

    -- Midnight Trade Goods 7/11 profession-specific reagents.
    [240990] = { "jewelcrafting" },            -- Sunglass Vial (JC variant per Wowhead spell link)
    [240991] = { "alchemy", "jewelcrafting" }, -- Sunglass Vial
    [241131] = { "jewelcrafting" },            -- Amani Lapis Prism
    [241132] = { "jewelcrafting" },            -- Amani Lapis Prism (variant)
    [241133] = { "jewelcrafting" },            -- Tenebrous Amethyst Prism
    [241134] = { "jewelcrafting" },            -- Tenebrous Amethyst Prism (variant)
    [241135] = { "jewelcrafting" },            -- Sanguine Garnet Prism
    [241136] = { "jewelcrafting" },            -- Sanguine Garnet Prism (variant)
    [241137] = { "jewelcrafting" },            -- Harandar Peridot Prism
    [241138] = { "jewelcrafting" },            -- Harandar Peridot Prism (variant)
    [251665] = { "tailoring" },                -- Silverleaf Thread
    [251691] = { "tailoring" },                -- Embroidery Floss
    [251283] = { "blacksmithing", "inscription", "engineering", "alchemy", "tailoring", "leatherworking", "jewelcrafting" }, -- Tormented Tantalum (cross-profession Midnight reagent)
    [251285] = { "alchemy", "leatherworking", "enchanting", "blacksmithing", "jewelcrafting", "tailoring", "cooking" }, -- Petrified Root (cross-profession Midnight reagent)
    [237505] = { "alchemy", "blacksmithing", "enchanting", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Artisan's Moxie (universal Midnight crafting reagent)
    -- Note: Soul Cipher (245766), Codified Azeroot (245764, 245765), Thalassian Songwater (245882),
    -- pigments, inks, and Darkmoon cards are all classID 7 / subClassID 16 (Inscription)
    -- per the Wowhead inscription bucket, so they already route via PROF_ITEM_MAP.
    -- The Thalassian Treatise items (245756/Tailoring, 245757/Inscription, 245758/LW) need
    -- in-game verification of their actual subclass before adding overrides.

    -- Trade Goods 7/19 ("Finishing Reagent") - not in PROF_ITEM_MAP because
    -- the bucket is shared across professions. Per-itemID assignment is required.
    -- TWW finishing reagents:
    [228404] = { "alchemy" },                  -- Petal Powder
    [228401] = { "alchemy" },                  -- Bubbling Mycobloom Culture
    [222882] = { "tailoring" },                -- Weavercloth Embroidery Thread
    [210814] = { "alchemy", "blacksmithing", "enchanting", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Artisan's Acuity
    -- Midnight finishing reagents - universal crafting helpers used across professions.
    [225673] = { "alchemy", "blacksmithing", "enchanting", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Artisan's Consortium Seal of Approval
    [246447] = { "alchemy", "blacksmithing", "enchanting", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Apprentice's Scribbles
    [246448] = { "alchemy", "blacksmithing", "enchanting", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Artisan's Ledger
    [246449] = { "alchemy", "blacksmithing", "enchanting", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Mentor's Helpful Handiwork
    [246450] = { "alchemy", "blacksmithing", "enchanting", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Artisan's Consortium Gold Star
    [247719] = { "alchemy", "blacksmithing", "enchanting", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Multicraft Matrix
    [247724] = { "alchemy", "blacksmithing", "enchanting", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Multicraft Manifold
    [247725] = { "alchemy", "blacksmithing", "enchanting", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Resourceful Rebar
    [247726] = { "alchemy", "blacksmithing", "enchanting", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Resourceful Routing
    [247788] = { "alchemy", "blacksmithing", "enchanting", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Ingenious Identity
    [260630] = { "alchemy", "blacksmithing", "enchanting", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Ingenious Identifier
    -- Cooking finishing reagents (item-level dropped by zone, garnishes/bites for food crafting):
    [265800] = { "cooking" },                  -- Earthy Garnish
    [265801] = { "cooking" },                  -- Savory Anomaly
    [265803] = { "cooking" },                  -- Bazaar Bites
    -- Vendor cooking ingredients that report Trade Goods 7/11 (Other) and falsely match alchemy:
    [2678] = { "cooking" },                    -- Mild Spices
    [3713] = { "cooking" },                    -- Soothing Spices
    [2692] = { "cooking" },                    -- Hot Spices
    [17194] = { "cooking" },                   -- Holiday Spices
    [30817] = { "cooking" },                   -- Simple Flour

    -- Legacy Trade Goods 7/11 items that PROF_ITEM_MAP's alchemy-only default gets
    -- wrong. Verified against real recipe reagent data (AllTheThings' ReagentsDB,
    -- cross-referenced with each recipe's requireSkill), not guessed from item names.
    -- Some of these have zero Alchemy usage at all - the alchemy-only default was
    -- simply wrong for them, not just incomplete.
    [47556] = { "blacksmithing", "leatherworking", "tailoring" }, -- Crusader Orb
    [45087] = { "blacksmithing", "leatherworking", "tailoring" }, -- Runed Orb
    [17010] = { "blacksmithing", "leatherworking", "tailoring", "engineering", "enchanting", "mining" }, -- Fiery Core
    [17011] = { "blacksmithing", "leatherworking", "tailoring", "engineering", "jewelcrafting" }, -- Lava Core
    [69237] = { "blacksmithing", "leatherworking", "tailoring", "alchemy", "enchanting" }, -- Living Ember
    [71998] = { "blacksmithing", "leatherworking", "tailoring" }, -- Essence of Destruction
    [160298] = { "blacksmithing" }, -- Durable Flux (not Alchemy at all)
    [49908] = { "blacksmithing", "leatherworking", "tailoring" }, -- Primordial Saronite
    [221757] = { "blacksmithing", "leatherworking" }, -- Gloomfathom Hide
    [221758] = { "blacksmithing", "leatherworking", "alchemy", "enchanting" }, -- Profaned Tinderbox
    [221754] = { "blacksmithing", "leatherworking", "jewelcrafting", "enchanting", "inscription", "cooking" }, -- Ringing Deeps Ingot
    [213610] = { "blacksmithing", "leatherworking", "alchemy", "enchanting", "engineering", "inscription", "skinning" }, -- Crystalline Powder
    [211806] = { "alchemy", "engineering" }, -- Gilded Vial
    [191474] = { "alchemy", "inscription", "engineering" }, -- Draconic Vial
    [213611] = { "alchemy", "leatherworking", "engineering", "inscription", "tailoring", "skinning" }, -- Writhing Sample
    [221756] = { "blacksmithing", "leatherworking", "alchemy", "enchanting", "engineering" }, -- Vial of Kaheti Oils
    [221763] = { "alchemy", "enchanting" }, -- Viridian Charmcap
    [19943] = { "alchemy", "blacksmithing", "inscription", "jewelcrafting", "leatherworking" }, -- Massive Mojo
    [12804] = { "alchemy", "blacksmithing", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Powerful Mojo
    [124438] = { "alchemy", "blacksmithing", "leatherworking", "tailoring" }, -- Unbroken Claw
    [124439] = { "alchemy", "blacksmithing", "leatherworking", "tailoring" }, -- Unbroken Tooth
    [190456] = { "alchemy", "blacksmithing", "enchanting", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Artisan's Mettle
    [230287] = { "blacksmithing", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Astral Gladiator's Heraldry (not Alchemy at all)
    [230906] = { "alchemy", "blacksmithing", "enchanting", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Spark of Fortunes
    [190453] = { "alchemy", "blacksmithing", "enchanting", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Spark of Ingenuity
    [211296] = { "alchemy", "blacksmithing", "enchanting", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Spark of Omens
    [232875] = { "alchemy", "blacksmithing", "enchanting", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Spark of Radiance
    [211516] = { "alchemy", "blacksmithing", "enchanting", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Spark of Awakening
    [206959] = { "alchemy", "blacksmithing", "enchanting", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Spark of Dreams
    [204440] = { "alchemy", "blacksmithing", "enchanting", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Spark of Shadowflame
    [231756] = { "alchemy", "blacksmithing", "enchanting", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Spark of Starlight
    [2325] = { "tailoring", "leatherworking" }, -- Black Dye (not Alchemy at all)
    [6260] = { "tailoring", "leatherworking" }, -- Blue Dye (not Alchemy at all)
    [2604] = { "tailoring", "leatherworking", "blacksmithing" }, -- Red Dye (not Alchemy at all)
    [10290] = { "tailoring" }, -- Pink Dye (not Alchemy at all)
    [3371] = { "alchemy", "enchanting", "inscription" }, -- Crystal Vial
    [22682] = { "leatherworking", "tailoring", "blacksmithing", "inscription", "jewelcrafting" }, -- Frozen Rune (not Alchemy at all)
    [180732] = { "alchemy", "inscription" }, -- Rune Etched Vial
    [191493] = { "alchemy", "jewelcrafting" }, -- Primal Convergent
    [207702] = { "blacksmithing", "engineering", "jewelcrafting", "leatherworking", "tailoring" }, -- Wartorn Scrap (not Alchemy at all)
    [177062] = { "tailoring", "leatherworking", "engineering" }, -- Penumbra Thread (not Alchemy at all)
    [224764] = { "leatherworking", "tailoring" }, -- Mosswool Thread (not Alchemy at all)
    [228930] = { "tailoring" }, -- Adorning Ribbon (not Alchemy at all)
    [229390] = { "leatherworking", "blacksmithing", "tailoring", "engineering", "inscription", "jewelcrafting" }, -- Prized Gladiator's Heraldry (not Alchemy at all)
    [241281] = { "alchemy", "leatherworking" }, -- Composite Flora
    [5637] = { "alchemy", "blacksmithing", "jewelcrafting", "leatherworking" }, -- Large Fang
    [11291] = { "enchanting", "engineering", "leatherworking" }, -- Star Wood (not Alchemy at all)
    [2880] = { "blacksmithing", "engineering" }, -- Weak Flux (not Alchemy at all)
    -- Flux (Metal & Stone 7/7). The subclass is shared by Blacksmithing,
    -- Engineering, Mining and Jewelcrafting, so a Mining rule sitting above the
    -- Blacksmithing rule claims these. Flux is a smithing consumable ("used for
    -- removing impurities from metal", sold by Blacksmithing vendors) with no
    -- Mining or Jewelcrafting use, so the override strips both.
    [18567] = { "blacksmithing" },  -- Elemental Flux
    [190452] = { "blacksmithing" }, -- Primal Flux
    [226202] = { "blacksmithing" }, -- Echoing Flux
    [180733] = { "blacksmithing" }, -- Luminous Flux
    [243060] = { "blacksmithing" }, -- Luminant Flux
    [3466] = { "blacksmithing" },   -- Strong Flux (7/11, "used by blacksmiths to remove impurities")
    [2324] = { "leatherworking", "tailoring" }, -- Bleach (not Alchemy at all)
    [251768] = { "alchemy", "blacksmithing", "enchanting", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Darkpine Lumber
    [191475] = { "alchemy", "engineering", "inscription" }, -- Draconic Vial (2nd variant)
    [201401] = { "tailoring" }, -- Iridescent Plume (not Alchemy at all)
    [201402] = { "blacksmithing" }, -- Large Sturdy Femur (not Alchemy at all)
    [201403] = { "blacksmithing", "leatherworking" }, -- Mastodon Tusk (not Alchemy at all)
    [242691] = { "alchemy", "blacksmithing", "enchanting", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Olemba Lumber
    [191497] = { "alchemy", "engineering", "leatherworking", "tailoring" }, -- Omnium Draconis
    [142335] = { "tailoring" }, -- Pristine Falcosaur Feather (not Alchemy at all)
    [229388] = { "blacksmithing", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Prized Combatant's Heraldry (not Alchemy at all)
    [210221] = { "blacksmithing", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Forged Combatant's Heraldry (not Alchemy at all)
    [124436] = { "blacksmithing" }, -- Foxflower Flux (not Alchemy at all)
    [256559] = { "blacksmithing", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Galactic Combatant's Heraldry (not Alchemy at all)
    [160059] = { "leatherworking" }, -- Amber Tanning Oil (not Alchemy at all)
    [183955] = { "leatherworking" }, -- Curing Salt (not Alchemy at all)
    [201399] = { "leatherworking", "blacksmithing" }, -- Primal Bear Spine (not Alchemy at all)
    [38682] = { "enchanting" }, -- Enchanting Vellum (not Alchemy at all)
    [115524] = { "jewelcrafting" }, -- Taladite Crystal (not Alchemy at all)
    [112377] = { "inscription" }, -- War Paints (not Alchemy at all)
    [80433] = { "blacksmithing", "leatherworking", "tailoring" }, -- Blood Spirit (not Alchemy at all)
    [52078] = { "blacksmithing", "engineering", "jewelcrafting", "leatherworking", "tailoring" }, -- Chaos Orb (not Alchemy at all)
    [127759] = { "alchemy", "blacksmithing", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Felblight
    [43102] = { "alchemy", "blacksmithing", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Frozen Orb
    [94289] = { "blacksmithing", "enchanting", "leatherworking", "tailoring" }, -- Haunting Spirit (not Alchemy at all)
    [32428] = { "blacksmithing", "leatherworking", "tailoring" }, -- Heart of Darkness (not Alchemy at all)
    [213613] = { "alchemy", "enchanting", "engineering", "herbalism", "inscription", "leatherworking", "tailoring" }, -- Leyline Residue
    [12811] = { "blacksmithing", "enchanting", "inscription", "tailoring" }, -- Righteous Orb (not Alchemy at all)
    [118472] = { "alchemy", "blacksmithing", "enchanting", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Savage Blood
    [21882] = { "tailoring" }, -- Soul Essence (not Alchemy at all)
    [34664] = { "blacksmithing", "jewelcrafting", "leatherworking", "tailoring" }, -- Sunmote (not Alchemy at all)
    [12662] = { "blacksmithing", "jewelcrafting", "tailoring" }, -- Demonic Rune (not Alchemy at all)
    [245345] = { "blacksmithing", "enchanting", "engineering", "inscription", "jewelcrafting", "leatherworking", "tailoring" }, -- Fused Vitality (not Alchemy at all)
    [201406] = { "blacksmithing", "alchemy" }, -- Glowing Titan Orb
    [201832] = { "engineering" }, -- Smudged Lens (not Alchemy at all)
    [213612] = { "enchanting", "inscription", "alchemy", "leatherworking" }, -- Viridescent Spores
    -- Left unresolved for now (found in the same audit, but not fixed here):
    -- 87399 Restored Artifact, 114781 Timber, 190455 Concentrated Primal Focus,
    -- 63128 Troll Tablet, 64396 Nerubian Obelisk, 118225 Highmaul Hops, 210828
    -- Dilution Solution, and 168262 Sentry Fish all show isCraftingReagent=true
    -- but zero recipes reference them in reagent data - unclear what consumes
    -- them, if anything. 13757 Lightning Eel and 162515 Midnight Salmon resolve
    -- only to Cooking, which isn't a tracked crafting profession here - no valid
    -- override target, left as-is. 114836 Hexweave Embroidery and 119293 Secret
    -- of Draenor Enchanting also show zero recipe usage. 40195 Pygmy Oil and 6358
    -- Oily Blackmouth are genuinely Alchemy-only and need no change.
}

-- RESTOCK_ITEMS: curated reagent itemIDs per expansion, used as the source pool by
-- the Bank Restock picker. itemIDs only; name/icon/tier resolved
-- on demand via C_Item.GetItemInfo + C_TradeSkillUI.GetItemReagentQualityByItemInfo.
--
-- Flat list per expansion. The picker categorizes each itemID at render time via
-- GetItemInfoInstant (classID/subClassID -> AH_SECTIONS label), so no per-profession
-- bucketing or duplication is needed here. Subclass comments below are for reader
-- orientation only; they are not part of the schema.
--
-- Generated via `/em gendata` at the AH (Reagents -> <category>, "Current Expansion
-- Only"). May contain a few old-expansion strays (low itemIDs) pending in-game
-- curation - harmless; the picker's Expansion filter uses GetItemInfo's expansionID
-- return so strays surface only under "All Expansions".
EmpireManager.RESTOCK_ITEMS = {
    [11] = { -- Midnight
        -- 7/1 Parts (Aetherlume + Evercore; low IDs are old-expansion strays)
        4400, 39684, 40533, 52188, 90146,
        243574, 243575, 243576, 243577, 243578, 243579, 243581, 243582,
        -- 7/4 Gems (Jewelcrafting)
        240972, 240973, 240974, 240975, 242553, 242554, 242606, 242607, 242608, 242610,
        242611, 242612, 242613, 242620, 242621, 242712, 242720, 242721, 242722, 242723,
        242724, 242725, 242726, 242727, 242786, 242787, 242788, 242789, 253307,
        -- 7/5 Cloth
        2321, 8343, 14341, 38426, 236963, 236965, 237015, 237016, 237017, 237018,
        239198, 239200, 239201, 239202, 239700, 239701, 239702, 239703,
        -- 7/6 Leather
        238511, 238512, 238513, 238514, 238518, 238519, 238520, 238521, 238522, 238523,
        238525, 238528, 238529, 238530, 244631, 244632, 244633, 244634, 244635, 244636,
        244637, 244638,
        -- 7/7 Metal & Stone
        18567, 180733, 237359, 237361, 237362, 237363, 237364, 237365, 237366, 238197,
        238198, 238202, 238203, 238204, 238205, 243060,
        -- 7/8 Cooking
        17194, 238365, 238366, 238367, 238368, 238369, 238370, 238371, 238372, 238373,
        238374, 238375, 238376, 238377, 238378, 238379, 238380, 238381, 238382, 238383,
        238384, 242639, 242640, 242641, 242642, 242643, 242644, 242645, 242646, 242647,
        253403, 259894,
        -- 7/9 Herb
        13468, 236761, 236767, 236770, 236771, 236774, 236775, 236776, 236777, 236778,
        236779, 236780,
        -- 7/11 Other (cross-profession). 256559 (Galactic Combatant's Heraldry) is a
        -- PvP token, not a reagent - excluded.
        2325, 2604, 2605, 3371, 4341, 4342, 4470, 6260, 10290, 11291,
        30817, 38682, 39354, 177062, 183955, 236949, 236950, 236951, 236952, 240990,
        240991, 241280, 241281, 241282, 241283, 251283, 251285, 251665, 251691, 253302,
        253303,
        -- Removed 2026-08-25: 260947, 262625, 262628, 262639, 262642, 262643,
        -- 262647, 262648, 262655, 262656. C_Item.GetItemInfoInstant does not know
        -- any of them on this build (they never resolve, not even client-side), so
        -- their picker rows sat at "Loading..." forever and kept re-arming the
        -- GET_ITEM_INFO_RECEIVED watcher - which is what drove the endless refresh
        -- loop / flicker. Artefacts of the /em gendata AH scan.
        -- 7/12 Enchanting
        243599, 243600, 243602, 243603, 243605, 243606,
        -- 7/16 Inscription (pigments, inks, missives)
        245764, 245765, 245766, 245767, 245801, 245802, 245803, 245804, 245805, 245806,
        245807, 245808, 245830, 245831, 245832, 245833, 245834, 245835, 245836, 245837,
        245838, 245839, 245840, 245841, 245842, 245843, 245844, 245845, 245847, 245848,
        245849, 245850, 245851, 245852, 245853, 245854, 245856, 245857, 245858, 245859,
        245860, 245861, 245862, 245863, 245864, 245865, 245866, 245867, 245881, 245882,
        251923,
        -- 7/18 Optional Reagents (cross-profession)
        180055, 180057, 180058, 180059, 180060, 228368, 244603, 244604, 244607, 244608,
        244674, 244675, 244697, 244698, 244699, 244701, 244703, 245781, 245783, 245784,
        245785, 245786, 245787, 245789, 245790, 245791, 245792, 245814, 245815, 245816,
        245818, 245820, 245821, 245822, 245823, 245824, 245826, 248130, 248132, 248133,
        248135, 248136, 248592, 251487, 251489, 255843, 255844, 257735, 257741,
        -- 7/19 Finishing Reagents (cross-profession)
        246447, 246448, 246449, 265800, 265801, 265803,
    },
}

-- AH_SECTIONS: Trade Goods (classID 7) subclass -> AH Reagents category label + icon.
-- Used by the Restock picker's Category filter to group items the way the Auction
-- House does, avoiding per-item profession attribution for cross-profession reagents.
-- Keyed as "classID/subClassID" strings so future non-tradegoods sections could be
-- added without a schema change. Icons picked from Blizzard's atlas/interface icons.
EmpireManager.AH_SECTIONS = {
    ["7/1"]  = { label = "Parts",              icon = "Interface\\Icons\\INV_Misc_Wrench_01" },
    ["7/4"]  = { label = "Jewelcrafting",      icon = "Interface\\Icons\\INV_Misc_Gem_02" },
    ["7/5"]  = { label = "Cloth",              icon = "Interface\\Icons\\INV_Fabric_Silk_01" },
    ["7/6"]  = { label = "Leather",            icon = "Interface\\Icons\\INV_Misc_LeatherScrap_02" },
    ["7/7"]  = { label = "Metal & Stone",      icon = "Interface\\Icons\\INV_Ore_Copper_01" },
    ["7/8"]  = { label = "Cooking",            icon = "Interface\\Icons\\INV_Misc_Food_15" },
    ["7/9"]  = { label = "Herb",               icon = "Interface\\Icons\\INV_Misc_Herb_02" },
    ["7/10"] = { label = "Elemental",          icon = "Interface\\Icons\\INV_Elemental_Primal_Fire" },
    ["7/11"] = { label = "Other",              icon = "Interface\\Icons\\INV_Misc_Gear_08" },
    ["7/12"] = { label = "Enchanting",         icon = "Interface\\Icons\\Trade_Engraving" },
    ["7/16"] = { label = "Inscription",        icon = "Interface\\Icons\\INV_Inscription_Tradeskill01" },
    ["7/18"] = { label = "Optional Reagents",  icon = "Interface\\Icons\\INV_Misc_Gear_02" },
    ["7/19"] = { label = "Finishing Reagents", icon = "Interface\\Icons\\INV_Misc_Gear_05" },
}

-- Display order for the Category dropdown - mirrors the live AH Reagents sidebar
-- so users see the same order they know from browsing at an Auctioneer.
EmpireManager.AH_SECTION_ORDER = {
    "7/5",  -- Cloth
    "7/6",  -- Leather
    "7/7",  -- Metal & Stone
    "7/8",  -- Cooking
    "7/9",  -- Herb
    "7/12", -- Enchanting
    "7/16", -- Inscription
    "7/4",  -- Jewelcrafting
    "7/1",  -- Parts
    "7/10", -- Elemental
    "7/18", -- Optional Reagents
    "7/19", -- Finishing Reagents
    "7/11", -- Other
}

-- Resolve an itemID to its AH section key ("classID/subClassID") via GetItemInfoInstant.
-- Returns nil for uncached itemIDs (rare - the source pool comes from prior AH scrapes).
function EmpireManager.GetAHSectionKey(itemID)
    local _, _, _, _, _, classID, subClassID = C_Item.GetItemInfoInstant(itemID)
    if not classID or not subClassID then
        return nil
    end
    return tostring(classID) .. "/" .. tostring(subClassID)
end

-- Profession display: crafting, gathering, and secondary professions
EmpireManager.PROF_DISPLAY = {
    -- Crafting professions
    {
        key = "alchemy",
        label = "Alchemy",
        category = "crafting",
        icon = "Interface\\Icons\\Trade_Alchemy",
        r = 0.0,
        g = 0.8,
        b = 0.6,
    },
    {
        key = "blacksmithing",
        label = "Blacksmithing",
        category = "crafting",
        icon = "Interface\\Icons\\Trade_BlackSmithing",
        r = 0.75,
        g = 0.8,
        b = 0.9,
    },
    {
        key = "enchanting",
        label = "Enchanting",
        category = "crafting",
        icon = "Interface\\Icons\\Trade_Engraving",
        r = 0.6,
        g = 0.4,
        b = 0.9,
    },
    {
        key = "engineering",
        label = "Engineering",
        category = "crafting",
        icon = "Interface\\Icons\\Trade_Engineering",
        r = 0.45,
        g = 0.6,
        b = 0.75,
    },
    {
        key = "inscription",
        label = "Inscription",
        category = "crafting",
        icon = "Interface\\Icons\\INV_Inscription_Tradeskill01",
        r = 0.8,
        g = 0.7,
        b = 0.5,
    },
    {
        key = "jewelcrafting",
        label = "Jewelcrafting",
        category = "crafting",
        icon = "Interface\\Icons\\INV_Misc_Gem_02",
        r = 0.9,
        g = 0.2,
        b = 0.4,
    },
    {
        key = "leatherworking",
        label = "Leatherworking",
        category = "crafting",
        icon = "Interface\\Icons\\Trade_LeatherWorking",
        r = 0.6,
        g = 0.4,
        b = 0.2,
    },
    {
        key = "tailoring",
        label = "Tailoring",
        category = "crafting",
        icon = "Interface\\Icons\\Trade_Tailoring",
        r = 0.8,
        g = 0.5,
        b = 0.8,
    },
    -- Gathering professions
    {
        key = "herbalism",
        label = "Herbalism",
        category = "gathering",
        icon = "Interface\\Icons\\Trade_Herbalism",
        r = 0.2,
        g = 0.8,
        b = 0.2,
    },
    {
        key = "mining",
        label = "Mining",
        category = "gathering",
        icon = "Interface\\Icons\\Trade_Mining",
        r = 0.7,
        g = 0.5,
        b = 0.3,
    },
    {
        key = "skinning",
        label = "Skinning",
        category = "gathering",
        icon = "Interface\\Icons\\INV_Misc_Pelt_Wolf_01",
        r = 0.7,
        g = 0.5,
        b = 0.4,
    },
    -- Secondary professions
    {
        key = "fishing",
        label = "Fishing",
        category = "secondary",
        icon = "Interface\\Icons\\Trade_Fishing",
        r = 0.3,
        g = 0.6,
        b = 0.9,
    },
    {
        key = "cooking",
        label = "Cooking",
        category = "secondary",
        icon = "Interface\\Icons\\INV_Misc_Food_15",
        r = 0.9,
        g = 0.6,
        b = 0.1,
    },
    {
        key = "archaeology",
        label = "Archaeology",
        category = "secondary",
        icon = "Interface\\Icons\\Trade_Archaeology",
        -- Light tan. Was 0.7/0.5/0.3, identical to Mining; kept in the same warm
        -- family but lightened so the two read apart at a glance (Skinning sits
        -- at 0.7/0.5/0.4, so brightness alone was not enough separation).
        r = 0.85,
        g = 0.7,
        b = 0.5,
    },
}

-- Role help text used by Sidecar role checkboxes and Roster → Roles headings
EmpireManager.ROLE_TOOLTIPS = {
    artisan = "Crafting character. Maximum 2 professions.\n\nItems matching those professions will be routed to assigned storage.",
    gatherer = "Gathering character. Maximum 2 professions.\n\nGathered materials are categorized and routed automatically.",
    auctioneer = "Receives BoE items for selling.\n\nTriage routes non-Warbound BoE gear to this character via mail. Only one Auctioneer per realm is typical.",
    banker = "Bank mule for Guild or personal Bank storage.\n\nAuto-assigned when a character is set as a storage destination. Receives mail from other characters.",
    lockpicker = "Opens locked items (Rogue, Mechagnome, or Blacksmith with Skeleton Keys).\n\nMark this character so you remember who can pick locks.",
    zookeeper = "Battle pet manager.\n\nTag your pet collection character for quick identification.",
    pvper = "PvP-focused character.\n\nTag for quick identification in the roster.",
}

-- Non-profession item categories for storage routing (not shown in Sidecar/Roster).
-- Grouped by source: Gear, then crafting-adjacent materials/goods, then Consumables,
-- then Collection & Utility (not profession/crafting-related at all).
EmpireManager.STORAGE_CATEGORY_DISPLAY = {
    -- Gear
    {
        key = "equipment_boe",
        label = "Equipment (BoE)",
        category = "general",
        icon = "Interface\\Icons\\INV_Sword_39",
        r = 0.35,
        g = 0.45,
        b = 0.95,
    },
    {
        key = "equipment_boa",
        label = "Equipment (BoA)",
        category = "general",
        icon = "Interface\\Icons\\INV_Shield_06",
        r = 0.0,
        g = 0.8,
        b = 0.8,
    },
    {
        key = "equipment_prof",
        label = "Equipment (Professions)",
        category = "general",
        icon = "Interface\\Icons\\Trade_BlackSmithing",
        -- Midpoint between BoE indigo (0.35,0.45,0.95) and BoA cyan (0,0.8,0.8),
        -- so the three Equipment categories read as a related set without colliding.
        r = 0.18,
        g = 0.63,
        b = 0.88,
    },
    -- Crafting materials & goods
    {
        -- Neutral material category: 7/10 is shared by Alchemy/Blacksmithing/Enchanting/
        -- Engineering with none of them narrowed to just this subclass alone (see
        -- PROF_ITEM_MAP comment above), unlike Herbs/Metal & Stone/Leather which are
        -- already exactly Herbalism/Mining/Skinning and don't need a separate category.
        key = "elemental",
        label = "Elemental",
        category = "general",
        icon = "Interface\\Icons\\INV_Elemental_Primal_Fire",
        r = 0.95,
        g = 0.45,
        b = 0.15,
    },
    {
        key = "recipes",
        label = "Recipes",
        category = "general",
        icon = "Interface\\Icons\\INV_Scroll_06",
        r = 0.9,
        g = 0.8,
        b = 0.4,
    },
    {
        key = "item_enhancements",
        label = "Item Enhancements",
        category = "general",
        icon = "Interface\\Icons\\INV_Enchant_FormulaEpic_01",
        r = 0.7,
        g = 0.4,
        b = 0.9,
    },
    -- Consumables
    {
        key = "consumables",
        label = "Consumables",
        category = "general",
        icon = "Interface\\Icons\\INV_Potion_54",
        r = 0.9,
        g = 0.3,
        b = 0.3,
    },
    -- Collection & Utility
    {
        key = "lumber",
        label = "Lumber",
        category = "general",
        icon = "Interface\\Icons\\INV_TradeskillItem_03",
        r = 0.7,
        g = 0.5,
        b = 0.2,
    },
    {
        key = "housing",
        label = "Housing",
        category = "general",
        icon = "Interface\\Icons\\Garrison_Building_Storehouse",
        r = 0.5,
        g = 0.75,
        b = 0.4,
    },
    {
        key = "pets",
        label = "Pets",
        category = "general",
        icon = "Interface\\Icons\\INV_Box_PetCarrier_01",
        r = 0.4,
        g = 0.9,
        b = 0.4,
    },
    {
        key = "pvp",
        label = "PvP",
        category = "general",
        icon = "Interface\\Icons\\Ability_DualWield",
        r = 0.95,
        g = 0.95,
        b = 0.95,
    },
}

-- Subcategory definitions per storage category
-- mode: "single" = single-select required, "multi" = multi-select optional (empty = all)
EmpireManager.SUBCATEGORY_DISPLAY = {
    equipment_boe = {
        mode = "multi",
        anyLabel = "Any Equipment",
        items = {
            { key = "weapons", label = "Weapons" },
            { key = "armor", label = "Armor" },
            { key = "jewelry", label = "Jewelry" },
            { key = "other", label = "Other" },
        },
    },
    equipment_boa = {
        mode = "multi",
        anyLabel = "Any Equipment",
        items = {
            { key = "weapons", label = "Weapons" },
            { key = "armor", label = "Armor" },
            { key = "jewelry", label = "Jewelry" },
            { key = "other", label = "Other" },
        },
    },
    -- Profession equipment: one subcategory per profession. Keys match the
    -- PROF_DISPLAY profession keys and resolve to subClassID via
    -- PROF_EQUIP_SUBCLASS (below). Selecting none = all professions.
    equipment_prof = {
        mode = "multi",
        anyLabel = "Any Profession",
        items = {
            { key = "alchemy", label = "Alchemy" },
            { key = "blacksmithing", label = "Blacksmithing" },
            { key = "cooking", label = "Cooking" },
            { key = "enchanting", label = "Enchanting" },
            { key = "engineering", label = "Engineering" },
            { key = "fishing", label = "Fishing" },
            { key = "herbalism", label = "Herbalism" },
            { key = "inscription", label = "Inscription" },
            { key = "jewelcrafting", label = "Jewelcrafting" },
            { key = "leatherworking", label = "Leatherworking" },
            { key = "mining", label = "Mining" },
            { key = "skinning", label = "Skinning" },
            { key = "tailoring", label = "Tailoring" },
        },
    },
    recipes = {
        mode = "multi",
        anyLabel = "Any Profession",
        items = {
            { key = "alchemy", label = "Alchemy" },
            { key = "blacksmithing", label = "Blacksmithing" },
            { key = "enchanting", label = "Enchanting" },
            { key = "engineering", label = "Engineering" },
            { key = "inscription", label = "Inscription" },
            { key = "jewelcrafting", label = "Jewelcrafting" },
            { key = "leatherworking", label = "Leatherworking" },
            { key = "tailoring", label = "Tailoring" },
            { key = "cooking", label = "Cooking" },
        },
    },
    consumables = {
        mode = "multi",
        anyLabel = "Any Consumable",
        items = {
            { key = "potions", label = "Potions" },
            { key = "flasks", label = "Flasks & Elixirs" },
            { key = "food", label = "Food & Drink" },
            { key = "other", label = "Other" },
        },
    },
}

-- Profession equipment subClassID → profession key (classID 19).
-- Straight from Enum.ItemProfessionSubclass; Archaeology (13) is omitted because
-- Blizzard's own Profession Equipment AH category omits it (no such gear exists).
EmpireManager.PROF_EQUIP_SUBCLASS_TO_PROF = {
    [0] = "blacksmithing",
    [1] = "leatherworking",
    [2] = "alchemy",
    [3] = "herbalism",
    [4] = "cooking",
    [5] = "mining",
    [6] = "tailoring",
    [7] = "engineering",
    [8] = "enchanting",
    [9] = "fishing",
    [10] = "skinning",
    [11] = "jewelcrafting",
    [12] = "inscription",
}

-- Recipe subClassID → profession key (classID 9)
EmpireManager.RECIPE_SUBCLASS_TO_PROF = {
    [1] = "leatherworking",
    [2] = "tailoring",
    [3] = "engineering",
    [4] = "blacksmithing",
    [5] = "cooking",
    [6] = "alchemy",
    [8] = "enchanting",
    [10] = "jewelcrafting",
    [11] = "inscription",
}

-- Build reverse lookups for profession icons, keys, and full info
EmpireManager.PROF_ICON_BY_LABEL = {}
EmpireManager.PROF_INFO_BY_KEY = {}
EmpireManager.PROF_INFO_BY_LABEL = {}
EmpireManager.VALID_PROF_KEYS = {}
for _, info in ipairs(EmpireManager.PROF_DISPLAY) do
    EmpireManager.PROF_ICON_BY_LABEL[info.label] = info.icon
    EmpireManager.PROF_INFO_BY_KEY[info.key] = info
    EmpireManager.PROF_INFO_BY_LABEL[info.label] = info
    EmpireManager.VALID_PROF_KEYS[info.key] = true
end

-- True if a stored `expansionSkills` row should NOT be displayed.
--
-- Read-time filter, so no SavedVariables migration is needed: rows written by older
-- builds can be wrong in two ways, and both are detectable without touching the DB.
--   1. Base-profession aggregate rows. GetAllProfessionTradeSkillLines includes the
--      profession's own line, whose expansionName is the client's "unknown" string
--      ("Unknown" / "Unbekannt") and whose skill is the total across all expansions
--      (e.g. 300/700). Not an expansion tier.
--   2. Cross-profession rows. Older builds stored every profession's lines under
--      whichever profession's window was open, so a breakdown could blend two
--      professions. Those rows are indistinguishable per-row, but they always came
--      with the aggregate rows above, so a row whose maxSkill exceeds any real tier
--      cap is a strong signal. We only filter case 1 (provably bogus) and leave the
--      rest: the write path is fixed, so rows repopulate correctly on the next
--      profession-window open.
-- `maxTierCap` guards case 1 without hardcoding locale strings: a tier's cap is a
-- few hundred at most, while aggregates sum every expansion.
function EmpireManager:IsBogusExpansionSkillRow(exp)
    if type(exp) ~= "table" then
        return true
    end
    -- No resolvable expansion AND no usable name -> nothing to show.
    local name = exp.expansionName
    if not exp.expansionID and (type(name) ~= "string" or name == "") then
        return true
    end
    -- Unresolvable expansion name = the client's "unknown" string in any locale.
    -- A real tier always resolves (we keep the localized-name table in sync), so an
    -- unresolvable name on a row with no numeric ID is the base-profession aggregate.
    if not exp.expansionID and not self:ExpansionIDFromAPIName(name) then
        return true
    end
    return false
end

-- The newest displayable expansion tier for a stored profession row, or nil.
-- Rows are stored oldest-first, so the newest is the last non-bogus entry. Callers
-- use this for the headline "62/105" figure instead of indexing the raw array, which
-- could land on a base-profession aggregate written by an older build.
function EmpireManager:NewestExpansionSkill(prof)
    local list = type(prof) == "table" and prof.expansionSkills or nil
    if type(list) ~= "table" then
        return nil
    end
    for i = #list, 1, -1 do
        local exp = list[i]
        if not self:IsBogusExpansionSkillRow(exp) then
            return exp
        end
    end
    return nil
end

-- expansionName (from ProfessionInfo) -> numeric expansionID, or nil if unknown.
-- Checks the English label/apiNames in EXPANSION_DISPLAY first, then the localized
-- table. ProfessionInfo has no expansionID field, so this name lookup is the only
-- way to order and dedupe per-expansion skill rows.
function EmpireManager:ExpansionIDFromAPIName(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    local lower = name:lower()
    for _, info in ipairs(self.EXPANSION_DISPLAY) do
        if info.label and info.label:lower() == lower then
            return info.expansionID
        end
        for _, alt in ipairs(info.apiNames or {}) do
            if alt:lower() == lower then
                return info.expansionID
            end
        end
    end
    return self.EXPANSION_API_NAME_TO_ID[lower]
end

-- Enum.Profession -> our profession key. Values are Blizzard's own enum
-- (Blizzard_APIDocumentationGenerated/ProfessionConstantsDocumentation.lua), so
-- they are identical on every client locale. FirstAid (0) has no counterpart here.
EmpireManager.ENUM_PROFESSION_TO_KEY = {
    [1] = "blacksmithing",
    [2] = "leatherworking",
    [3] = "alchemy",
    [4] = "herbalism",
    [5] = "cooking",
    [6] = "mining",
    [7] = "tailoring",
    [8] = "engineering",
    [9] = "enchanting",
    [10] = "fishing",
    [11] = "skinning",
    [12] = "jewelcrafting",
    [13] = "inscription",
    [14] = "archaeology",
}

-- Resolves a stored `entry.professions` row to its PROF_DISPLAY info, WITHOUT
-- depending on the client language.
--
-- `prof.name` comes from GetProfessionInfo and is localized ("Kräuterkunde" on a
-- German client), while PROF_DISPLAY.label is hardcoded English - so matching on
-- the name silently fails on every non-English client. `prof.skillLineID` is a
-- server-side ID and is locale-independent, so resolve through that first and
-- keep the label match only as a fallback for rows snapshotted before
-- skillLineID was recorded.
function EmpireManager:ProfInfoFromEntryProf(prof)
    if type(prof) ~= "table" then
        return nil
    end
    local slid = prof.skillLineID
    if slid and C_TradeSkillUI and C_TradeSkillUI.GetProfessionInfoBySkillLineID then
        local ok, info = pcall(C_TradeSkillUI.GetProfessionInfoBySkillLineID, slid)
        if ok and info and info.profession then
            local key = self.ENUM_PROFESSION_TO_KEY[info.profession]
            if key and self.PROF_INFO_BY_KEY[key] then
                return self.PROF_INFO_BY_KEY[key]
            end
        end
    end
    -- Legacy fallback: pre-skillLineID rows, or an ID the client can't resolve.
    -- Only ever matches on an English client, which is why it is not the primary path.
    return prof.name and self.PROF_INFO_BY_LABEL[prof.name] or nil
end
-- Also register non-profession storage categories so display lookups resolve them
for _, info in ipairs(EmpireManager.STORAGE_CATEGORY_DISPLAY) do
    EmpireManager.PROF_INFO_BY_KEY[info.key] = info
end

-------------------------------------------------------------------------------
-- Storage capacity helpers
-------------------------------------------------------------------------------

function EmpireManager:FormatStaleAge(scannedAt)
    if not scannedAt or scannedAt == 0 then
        return nil
    end
    local d = time() - scannedAt
    if d < 60 then
        return "just now"
    end
    if d < 3600 then
        return string.format("%dm ago", math.floor(d / 60))
    end
    if d < 86400 then
        return string.format("%dh ago", math.floor(d / 3600))
    end
    return string.format("%dd ago", math.floor(d / 86400))
end

-- Aggregate { total, used } across specific tabs (array) or all tabs (nil).
-- capSection is one of: cap.warbandbank, cap.guildbank[GuildKey(name, realm)], cap.charbank[guid].
-- Returns { total, used } or nil if no data.
function EmpireManager:AggregateCapacity(capSection, tabs)
    if not capSection then
        return nil
    end
    local totalSum, usedSum = 0, 0
    if tabs and #tabs > 0 then
        for _, t in ipairs(tabs) do
            local td = capSection[t]
            if td and td.total then
                totalSum = totalSum + td.total
                usedSum = usedSum + td.used
            end
        end
    else
        for _, td in pairs(capSection) do
            if type(td) == "table" and td.total then
                totalSum = totalSum + td.total
                usedSum = usedSum + td.used
            end
        end
    end
    return totalSum > 0 and { total = totalSum, used = usedSum } or nil
end

-- Resolve the capacity section for an assignment and check if any free slots
-- are available. Returns true when:
--   - no snapshot exists yet (unknown -> optimistic, don't block routing on
--     first scan before any bank has been opened), or
--   - aggregated free > 0.
-- Returns false only when we have positive evidence the destination is full.
function EmpireManager:HasFreeCapacity(assignment)
    local cap = self.db and self.db.global and self.db.global.storageCapacity
    if not cap then
        return true
    end
    local capSection
    if assignment.type == "warbandbank" then
        capSection = cap.warbandbank
    elseif assignment.type == "guildbank" and assignment.guild then
        local key = self:GuildKey(assignment.guild, assignment.realm)
        capSection = key and cap.guildbank and cap.guildbank[key]
    elseif assignment.type == "charbank" and assignment.char then
        capSection = cap.charbank and cap.charbank[assignment.char]
    end
    local agg = self:AggregateCapacity(capSection, assignment.tabs)
    if not agg then
        return true -- no snapshot for this destination yet
    end
    return (agg.total - agg.used) > 0
end

-------------------------------------------------------------------------------
-- Assignment helpers
-------------------------------------------------------------------------------

function EmpireManager:HasRole(entry, roleKey)
    return entry.assignments and entry.assignments[roleKey] ~= nil
end

-- Check if a character has artisan or gatherer role with a specific profession key
function EmpireManager:HasProfessionRole(entry, profKey)
    if not entry.assignments then
        return false
    end
    for _, roleKey in ipairs({ "artisan", "gatherer" }) do
        local roleData = entry.assignments[roleKey]
        if type(roleData) == "table" and roleData[profKey] then
            return true
        end
    end
    return false
end

-- Get all profession keys assigned across artisan/gatherer roles
function EmpireManager:GetAssignedProfs(entry)
    local profs = {}
    if not entry.assignments then
        return profs
    end
    for _, roleKey in ipairs({ "artisan", "gatherer" }) do
        local roleData = entry.assignments[roleKey]
        if type(roleData) == "table" then
            for key in pairs(roleData) do
                if self.VALID_PROF_KEYS[key] then
                    profs[key] = true
                end
            end
        end
    end
    return profs
end

-------------------------------------------------------------------------------
-- Shared format strings
-------------------------------------------------------------------------------

local ICON16_FMT = "|T%s:16:16|t %s" -- icon + label

EmpireManager.ICON16_FMT = ICON16_FMT

-------------------------------------------------------------------------------
-- Formatting helpers
-------------------------------------------------------------------------------

local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:12:12|t"

local function ThousandSep(n)
    local s = tostring(n)
    local pos = #s % 3
    if pos == 0 then
        pos = 3
    end
    local parts = { s:sub(1, pos) }
    for i = pos + 1, #s, 3 do
        parts[#parts + 1] = s:sub(i, i + 2)
    end
    return table.concat(parts, ",")
end

-- Gold-only formatter (no silver/copper), for dense displays like the dashboard.
function EmpireManager:FormatGoldOnly(copper)
    if not copper or copper == 0 then
        return "0" .. GOLD_ICON
    end
    if copper < 0 then
        return "-" .. self:FormatGoldOnly(-copper)
    end
    local g = math.floor(copper / 10000)
    if g > 0 then
        return ThousandSep(g) .. GOLD_ICON
    end
    local s = math.floor((copper % 10000) / 100)
    if s > 0 then
        return s .. SILVER_ICON
    end
    return (copper % 100) .. COPPER_ICON
end

function EmpireManager:FormatGold(copper)
    if not copper or copper == 0 then
        return "0" .. GOLD_ICON
    end
    if copper < 0 then
        return "-" .. self:FormatGold(-copper)
    end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    if g > 0 and s > 0 then
        return ThousandSep(g) .. GOLD_ICON .. " " .. s .. SILVER_ICON
    elseif g > 0 then
        return ThousandSep(g) .. GOLD_ICON
    elseif s > 0 and c > 0 then
        return s .. SILVER_ICON .. " " .. c .. COPPER_ICON
    elseif s > 0 then
        return s .. SILVER_ICON
    else
        return c .. COPPER_ICON
    end
end

function EmpireManager:ClassColoredName(entry)
    local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[entry.class]
    local name = entry.name or "?"
    local display = name
    if color then
        return color:WrapTextInColorCode(display)
    end
    return display
end

function EmpireManager:FormatRoles(assignments)
    if not assignments then
        return ""
    end
    local parts = {}
    for _, display in ipairs(self.ROLE_DISPLAY) do
        if assignments[display.key] then
            parts[#parts + 1] = display.icon
        end
    end
    if #parts == 0 then
        return ""
    end
    for i, icon in ipairs(parts) do
        parts[i] = string.format("|T%s:24:24|t", icon)
    end
    return table.concat(parts, " ")
end

function EmpireManager:FormatProfTags(assignments)
    if not assignments then
        return ""
    end
    local profSet = self:GetAssignedProfs({ assignments = assignments })
    local parts = {}
    for _, info in ipairs(self.PROF_DISPLAY) do
        if profSet[info.key] then
            parts[#parts + 1] = string.format("|T%s:24:24|t", info.icon)
        end
    end
    return #parts > 0 and table.concat(parts, " ") or ""
end

function EmpireManager:FormatTimeSince(timestamp)
    if not timestamp or timestamp == 0 then
        return "Never"
    end
    local diff = time() - timestamp
    if diff < 60 then
        return "Just now"
    elseif diff < 3600 then
        return string.format("%dm ago", math.floor(diff / 60))
    elseif diff < 86400 then
        return string.format("%dh ago", math.floor(diff / 3600))
    else
        return string.format("%dd ago", math.floor(diff / 86400))
    end
end

function EmpireManager:CalculateGrandTotals()
    local charGold = 0
    local charCount = 0
    for _, entry in pairs(self.db.global.registry) do
        charCount = charCount + 1
        charGold = charGold + (entry.gold or 0)
    end
    local warbandGold = self.db.global.warbandGold or 0
    return charGold + warbandGold, charCount, warbandGold
end

-- Readable class names from engine tokens
local CLASS_NAMES = {
    WARRIOR = "Warrior",
    PALADIN = "Paladin",
    HUNTER = "Hunter",
    ROGUE = "Rogue",
    PRIEST = "Priest",
    DEATHKNIGHT = "Death Knight",
    SHAMAN = "Shaman",
    MAGE = "Mage",
    WARLOCK = "Warlock",
    MONK = "Monk",
    DRUID = "Druid",
    DEMONHUNTER = "Demon Hunter",
    EVOKER = "Evoker",
}

local RACE_NAMES = {
    Human = "Human",
    Orc = "Orc",
    Dwarf = "Dwarf",
    NightElf = "Night Elf",
    Scourge = "Undead",
    Tauren = "Tauren",
    Gnome = "Gnome",
    Troll = "Troll",
    Goblin = "Goblin",
    BloodElf = "Blood Elf",
    Draenei = "Draenei",
    Worgen = "Worgen",
    Pandaren = "Pandaren",
    Nightborne = "Nightborne",
    HighmountainTauren = "Highmountain Tauren",
    VoidElf = "Void Elf",
    LightforgedDraenei = "Lightforged Draenei",
    ZandalariTroll = "Zandalari Troll",
    KulTiran = "Kul Tiran",
    DarkIronDwarf = "Dark Iron Dwarf",
    Vulpera = "Vulpera",
    MagharOrc = "Mag'har Orc",
    Mechagnome = "Mechagnome",
    Dracthyr = "Dracthyr",
    EarthenDwarf = "Earthen",
    Harronir = "Haranir",
}
EmpireManager.CLASS_NAMES = CLASS_NAMES
EmpireManager.RACE_NAMES = RACE_NAMES

-- Inverse of CLASS_NAMES: readable name → engine token (case-insensitive lookup).
local CLASS_TOKENS = {}
for token, label in pairs(CLASS_NAMES) do
    CLASS_TOKENS[label:lower()] = token
end
EmpireManager.CLASS_TOKENS = CLASS_TOKENS

-------------------------------------------------------------------------------
-- Class gear usability (drives the triage "unusable soulbound gear → vendor"
-- rules in TriageLogic.lua). Keyed by class file token (UnitClass 2nd return).
-------------------------------------------------------------------------------

-- A class's PRIMARY (and highest) armor tier. Armor subclass is ordered:
-- 1=Cloth, 2=Leather, 3=Mail, 4=Plate. A class wears its own tier at endgame;
-- lower tiers are suboptimal, higher tiers are permanently unusable.
EmpireManager.CLASS_PRIMARY_ARMOR_TIER = {
    WARRIOR = 4,
    PALADIN = 4,
    DEATHKNIGHT = 4,
    HUNTER = 3,
    SHAMAN = 3,
    EVOKER = 3,
    ROGUE = 2,
    DRUID = 2,
    MONK = 2,
    DEMONHUNTER = 2,
    MAGE = 1,
    PRIEST = 1,
    WARLOCK = 1,
}

-- Armor-bearing equipment slots (exclude neck/back/rings/trinkets - those are
-- Misc subclass 0, usable by all and not a proficiency signal).
EmpireManager.ARMOR_TIER_SLOTS = { 1, 3, 5, 6, 7, 8, 9, 10 } -- head, shoulder, chest, waist, legs, feet, wrist, hands

-- Equip locations that carry the class armor-tier restriction. ONLY these are
-- tier-bound. Cloaks report subClassID 1 (Cloth) but are back-slot items every
-- class wears, so INVTYPE_CLOAK must be excluded or a geared non-cloth character
-- would wrongly vendor its cloaks. Shirts/tabards are subclass 0 (already skipped).
EmpireManager.ARMOR_TIER_EQUIPLOC = {
    INVTYPE_HEAD = true,
    INVTYPE_SHOULDER = true,
    INVTYPE_CHEST = true,
    INVTYPE_ROBE = true,
    INVTYPE_WAIST = true,
    INVTYPE_LEGS = true,
    INVTYPE_FEET = true,
    INVTYPE_WRIST = true,
    INVTYPE_HAND = true,
}

-- Shields are Armor subclass 6. Only these classes can ever equip one; every
-- other class's shield drop is permanently unusable (per Pawn's IsShield flags).
EmpireManager.CLASS_CAN_USE_SHIELD = {
    WARRIOR = true,
    PALADIN = true,
    SHAMAN = true,
}

-- Weapon subclasses each class can NEVER equip, regardless of spec. Subclass IDs
-- are Enum.ItemWeaponSubclass:
--   Axe1H=0 Axe2H=1 Bow=2 Gun=3 Mace1H=4 Mace2H=5 Polearm=6 Sword1H=7 Sword2H=8
--   Warglaive=9 Staff=10 Fist=13 Dagger=15 Thrown=16 Crossbow=18 Wand=19
-- Derived from Pawn's PawnNeverUsableStats (ScaleTemplates.lua), translated from
-- its type-flags to subclass IDs. Off-hand frills, relics, fishing poles and the
-- dead Thrown slot are not listed - they're handled by the equip-loc/quality
-- guards or simply left alone.
EmpireManager.CLASS_NEVER_USABLE_WEAPON = {
    WARRIOR = { [9] = true, [19] = true },
    PALADIN = { [2] = true, [3] = true, [9] = true, [10] = true, [13] = true, [15] = true, [18] = true, [19] = true },
    HUNTER = { [4] = true, [5] = true, [9] = true, [19] = true },
    ROGUE = { [1] = true, [5] = true, [6] = true, [8] = true, [9] = true, [10] = true, [19] = true },
    PRIEST = {
        [0] = true, [1] = true, [2] = true, [3] = true, [5] = true, [6] = true,
        [7] = true, [8] = true, [9] = true, [13] = true, [18] = true,
    },
    DEATHKNIGHT = { [2] = true, [3] = true, [9] = true, [10] = true, [13] = true, [15] = true, [18] = true, [19] = true },
    SHAMAN = { [2] = true, [3] = true, [6] = true, [7] = true, [8] = true, [9] = true, [18] = true, [19] = true },
    MAGE = {
        [0] = true, [1] = true, [2] = true, [3] = true, [4] = true, [5] = true,
        [6] = true, [8] = true, [9] = true, [13] = true, [18] = true,
    },
    WARLOCK = {
        [0] = true, [1] = true, [2] = true, [3] = true, [4] = true, [5] = true,
        [6] = true, [8] = true, [9] = true, [13] = true, [18] = true,
    },
    MONK = { [1] = true, [2] = true, [3] = true, [5] = true, [8] = true, [9] = true, [15] = true, [18] = true, [19] = true },
    DRUID = { [0] = true, [1] = true, [2] = true, [3] = true, [7] = true, [8] = true, [9] = true, [18] = true, [19] = true },
    DEMONHUNTER = {
        [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true,
        [8] = true, [10] = true, [15] = true, [18] = true, [19] = true,
    },
    EVOKER = { [2] = true, [3] = true, [6] = true, [9] = true, [18] = true, [19] = true },
}

function EmpireManager:FormatPlaytime(seconds)
    if not seconds or seconds == 0 then
        return nil
    end
    local years = math.floor(seconds / 31536000) -- 365-day years
    local days = math.floor((seconds % 31536000) / 86400)
    local hours = math.floor((seconds % 86400) / 3600)
    if years > 0 then
        return string.format("%dy %dd", years, days)
    elseif days > 0 then
        return string.format("%dd %dh", days, hours)
    else
        local mins = math.floor((seconds % 3600) / 60)
        return string.format("%dh %dm", hours, mins)
    end
end

function EmpireManager:AddTooltipHeader(entry)
    GameTooltip:AddLine(entry.name or "?", 1, 1, 1)
    local guild = (entry.guild and entry.guild ~= "") and entry.guild or nil
    if guild then
        GameTooltip:AddLine(guild, 0.51, 0.35, 0.76)
    end
    GameTooltip:AddLine(entry.realm or "?", 1, 0.82, 0)
end

-- "Frost Mage", or just "Mage" when no spec is chosen yet. Guards against an
-- empty-string spec, which is truthy in Lua and would render a leading space.
function EmpireManager:GetSpecClassLine(entry)
    local className = CLASS_NAMES[entry.class] or entry.class or "?"
    if entry.spec and entry.spec ~= "" then
        return entry.spec .. " " .. className
    end
    return className
end

function EmpireManager:ShowNameTooltip(widget, entry, anchor)
    GameTooltip:SetOwner(widget.frame, anchor or "ANCHOR_CURSOR")
    self:AddTooltipHeader(entry)

    -- Spec + Class (class-colored, like game's "Protection Paladin")
    GameTooltip:AddLine(" ")
    local specLine = self:GetSpecClassLine(entry)
    local cc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[entry.class]
    if cc then
        GameTooltip:AddLine(specLine, cc.r, cc.g, cc.b)
    else
        GameTooltip:AddLine(specLine, 0.8, 0.8, 0.8)
    end

    -- Level (white)
    GameTooltip:AddLine(string.format("Level %d", entry.level or 0), 1, 1, 1)

    -- Zone (light blue, like the game)
    if entry.zone then
        local subZonePart = (entry.subZone and entry.subZone ~= "") and (" - " .. entry.subZone) or ""
        GameTooltip:AddLine(entry.zone .. subZonePart, 0.51, 0.77, 1.0)
    end

    -- Professions (warm yellow, comma-separated). Only the two main professions;
    -- secondaries (Fishing/Cooking/Archaeology) are skipped.
    if entry.professions and #entry.professions > 0 then
        -- Classify via ProfInfoFromEntryProf, not the localized name: on a
        -- non-English client a label-keyed set never matches, so every secondary
        -- (Fishing/Cooking/Archaeology) leaked into this list.
        local names = {}
        for _, p in ipairs(entry.professions) do
            if type(p.name) == "string" and p.name ~= "" then
                local pi = self:ProfInfoFromEntryProf(p)
                if not pi or pi.category ~= "secondary" then
                    names[#names + 1] = p.name
                end
            end
        end
        if #names > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(table.concat(names, ", "), 1, 0.82, 0)
        end
    end

    -- Gold (with coin icons, matching game tooltip)
    if entry.gold and entry.gold > 0 then
        local g = math.floor(entry.gold / 10000)
        local s = math.floor((entry.gold % 10000) / 100)
        local c = entry.gold % 100
        GameTooltip:AddLine(string.format("%d%s %d%s %d%s", g, GOLD_ICON, s, SILVER_ICON, c, COPPER_ICON), 1, 1, 1)
    end

    -- Bag / Bank free slots
    if entry.freeBagSlots or entry.freeBankSlots then
        GameTooltip:AddLine(" ")
        if entry.freeBagSlots then
            GameTooltip:AddLine(string.format("Bags: %d free", entry.freeBagSlots), 1, 1, 1)
        end
        if entry.freeBankSlots then
            GameTooltip:AddLine(string.format("Bank: %d free", entry.freeBankSlots), 1, 1, 1)
        end
    end

    -- Metadata (dimmer, bottom section)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(string.format("Last Seen: %s", self:FormatTimeSince(entry.lastSeen)), 1, 1, 1)
    local played = self:FormatPlaytime(entry.playedTotal)
    if played then
        GameTooltip:AddLine(string.format("Played: %s", played), 1, 1, 1)
    end

    -- Note (gold, wrapped, max 10 lines)
    if entry.storageNote and entry.storageNote ~= "" then
        GameTooltip:AddLine(" ")
        local lines, count = {}, 0
        for line in entry.storageNote:gmatch("[^\n]+") do
            count = count + 1
            if count > 10 then
                lines[#lines + 1] = "..."
                break
            end
            lines[#lines + 1] = line
        end
        GameTooltip:AddLine(table.concat(lines, "\n"), 1, 0.82, 0, true)
    end

    GameTooltip:Show()
end

-------------------------------------------------------------------------------
-- Statistics: Increment a named stat counter (global + session)
-------------------------------------------------------------------------------

function EmpireManager:IncrementStat(statKey, amount)
    amount = amount or 1
    local gStats = self.db.global.stats
    if gStats then
        gStats[statKey] = (gStats[statKey] or 0) + amount
    end
    if self._sessionStats then
        self._sessionStats[statKey] = (self._sessionStats[statKey] or 0) + amount
    end
end

-- Central chat output. Gated by db.global.options.chatMessages unless `always`
-- is true (used for errors and direct command responses).
function EmpireManager:ChatMsg(text, always)
    if not always then
        local opts = self.db and self.db.global and self.db.global.options
        if opts and opts.chatMessages == false then
            return
        end
    end
    self:Print(text)
end

--- Continuation line of a multi-line report: no addon-name prefix, so only the
--- heading carries it.
function EmpireManager:ChatMsgRaw(text, always)
    if not always then
        local opts = self.db and self.db.global and self.db.global.options
        if opts and opts.chatMessages == false then
            return
        end
    end
    DEFAULT_CHAT_FRAME:AddMessage(text)
end

-- Verbose chat output: internal progress/debug lines (restacking, capacity
-- snapshots, action-intent lines). Silenced unless both chatMessages AND
-- verboseMessages are enabled.
function EmpireManager:ChatVerbose(text)
    local opts = self.db and self.db.global and self.db.global.options
    if not opts or opts.chatMessages == false or opts.verboseMessages ~= true then
        return
    end
    self:Print(text)
end

-- Hint chat output: advisory [Hint] lines (upgradeable bags, unpurchased tabs).
-- Silenced unless both chatMessages AND showHints are enabled.
function EmpireManager:ChatHint(text)
    local opts = self.db and self.db.global and self.db.global.options
    if not opts or opts.chatMessages == false or opts.showHints == false then
        return
    end
    self:Print(text)
end

-- Colored chat prefix constants. Centralized so future localization or
-- color-scheme changes touch one place.
EmpireManager.MSG = {
    STORAGE = "|cff4d99ff[Storage]|r",
    TRIAGE = "|cff4d99ff[Triage]|r",
    BANK = "|cff4d99ff[Bank]|r",
    HINT = "|cff4d99ff[Hint]|r",
    ERROR = "|cffff4444", -- prepend to [Triage]/[Bank] for errors; close with |r
}
