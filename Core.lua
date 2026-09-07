-- ----------------------------------------------------------------------------
--                                   EmpireManager
--                              https://wow.cyberpunk.gr
--                (c) by George Litos (l0neshad0w),  All Rights Reserved
--                   For detailed license information check LICENSE.md
-- ----------------------------------------------------------------------------

local EmpireManager = LibStub("AceAddon-3.0"):NewAddon("EmpireManager", "AceConsole-3.0", "AceEvent-3.0")
EmpireManager.version = C_AddOns.GetAddOnMetadata("EmpireManager", "Version") or "?"
EmpireManager.description = C_AddOns.GetAddOnMetadata("EmpireManager", "Notes") or ""

-- Single source of truth for the slash-command list. Rendered in the Options
-- panel, the About tab, and the `/em help` chat output.
EmpireManager.SLASH_COMMANDS = {
    { cmd = "/em", desc = "Open the Dashboard" },
    { cmd = "/em config", desc = "Configure the current Character" },
    { cmd = "/em triage", desc = "Open Bag Triage overlay" },
    { cmd = "/em options", desc = "Open this settings panel" },
    { cmd = "/em purge <Name-Realm>", desc = "Remove a Character from the Roster" },
    { cmd = "/em keeplist", desc = "Open the Keep List window" },
    { cmd = "/em vendorw", desc = "Open the Vendor Whitelist window" },
    { cmd = "/em gb", desc = "Open the Guild Blacklist window" },
    { cmd = "/em charb", desc = "Open the Character Blacklist window" },
    { cmd = "/em ie", desc = "Open the Import / Export window" },
    { cmd = "/em cc", desc = "Copy chat text (Chat Copy window)" },
    { cmd = "/em wizard", desc = "Open the Storage Setup Wizard" },
    { cmd = "/em wipe <target>", desc = "|cffff8800Destructive|r: <target> = chars / rules / keeplist / vendorw / restock / all" },
    { cmd = "/em help", desc = "Show all commands in chat" },
}

-- DB defaults
local DB_DEFAULTS = {
    global = {
        registry = {}, -- keyed by UnitGUID("player")
        storageAssignments = {}, -- array of { profession, type, tabs?, char?, guild?, expansions? }
        storageCapacity = {
            warbandbank = {}, -- [tabIndex] = { total, used }
            guildbank = {}, -- [guildName .. "-" .. realm] = { [tabIndex] = { total, used } }
            charbank = {}, -- [guid] = { [tabIndex] = { total, used } }
        },
        schemaVersion = 1,
        lastReset = 0,
        lastWeeklyReset = 0,
        charBlacklist = {}, -- [guid] = "Name - Realm"; excluded from data collection
        keepList = {}, -- [itemID] = "Item Name"; protected from all triage actions (vendor, mail, stash)
        vendorWhitelist = {}, -- [itemID] = "Item Name"; always vendored regardless of rules
        stats = {}, -- cumulative operation counters (goldVendored, itemsVendored, itemsStashed, itemsMailed)
        warbandGold = 0, -- account-level: copper held in the warband bank, snapshotted on bank open
        options = {
            defaultVendorThreshold = 0, -- copper; applied to new characters
            minimapButton = true, -- show minimap icon
            escToClose = true, -- register frames with UISpecialFrames
            chatMessages = true, -- print bulk-op status to chat (errors always show)
            verboseMessages = false, -- print internal progress lines (restacking, snapshots, "depositing..." intent)
            showHints = true, -- print [Hint] lines (upgradeable bags, unpurchased tabs, etc.)
            popupOnBank = true, -- triage reminder on bank open
            popupOnGuildBank = true, -- misplaced scan on guild bank open
            popupOnMailbox = true, -- routable reminder on mailbox open
            popupOnVendor = true, -- open triage overlay on vendor open
            autoRepair = false, -- auto-repair gear on opening a repair-capable merchant
            repairWithGuildFunds = false, -- prefer guild bank funds for auto-repair, fall back to personal gold
            closeTriageOnLeave = true, -- auto-close triage overlay when leaving bank/vendor/mailbox
            autoTransferGold = false, -- auto-balance bag gold vs warband gold on warband bank open (per-char amounts in Sidecar > Gold)
            groupMoverBoeOnly = true, -- TSM Group Mover: only claim tradeable (BoE/unbound) items
            groupMoverRespectKeepList = true, -- Keep List still wins over a selected Group
            autoRestock = false, -- auto top-up restock floors on bank open, both directions (off = OK/Cancel dialog).
            skipEquipmentSets = true, -- protect gear in equipment sets from vendor rules
            vendorBoePoor = false, -- also vendor poor quality items that are BoE (off = keep for AH)
            pawnVendorBop = false, -- vendor soulbound non-upgrades via Pawn
            vendorBopIlvl = false, -- vendor soulbound gear with lower ilvl than equipped
            vendorIlvlCeiling = 0, -- iLvl ceiling for BoP vendor checks; gear at or above is kept (0 = disabled)
            confirmVendorQuality = true, -- show confirmation dialog before vendoring uncommon+ gear
            disenchantRouting = false, -- route low-value BoE to enchanter instead of AH
            disenchantThreshold = 0, -- copper; fallback threshold when TSM unavailable
            clampToScreen = true, -- keep addon windows inside the screen bounds
        },
    },
    char = {
        assignments = {}, -- roleKey → { profKey = true, ... }; simple roles = {}
        storageNote = "",
        sortOrder = 0, -- custom sort priority for dashboard grid (lower = higher)
        auctioneerKeepBOE = true, -- Auctioneer: keep BoE equipment instead of routing
        enchanterKeepDE = true, -- Enchanter: keep vendor gear for disenchanting
        keepOwnProfMatsInBank = false, -- Keep own profession materials in character bank
        keepOwnProfMatsInBags = false, -- Keep own profession materials in bags
        keepOwnProfMatsInBagsLatestOnly = false, -- Sub-option: only apply Keep-in-Bags to latest-expansion mats
        stashOldQuestItems = false, -- Route soulbound Quest items from previous expansions to own bank
        ignoreStorageRules = false, -- Exempt this character from all Storage-tab routing (stash/mail/takeout/reorganize)
    },
}

function EmpireManager:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("EmpireManagerDB", DB_DEFAULTS)

    -- Ensure nested saved-data tables exist (AceDB defaults don't materialize them)
    if not rawget(self.db.global, "charBlacklist") then
        self.db.global.charBlacklist = {}
    end
    if not rawget(self.db.global, "keepList") then
        self.db.global.keepList = {}
    end
    if not rawget(self.db.global, "vendorWhitelist") then
        self.db.global.vendorWhitelist = {}
    end
    -- Bank Restock par-level list (ordered array; position = priority).
    if not rawget(self.db.global, "restockList") then
        self.db.global.restockList = {}
    end
    -- Per-item count snapshots for the Restock fill column, keyed by destination
    -- ("warbandbank", "charbank:<guid>", "bags:<guid>", "guildbank:<key>").
    if not rawget(self.db.global, "restockCounts") then
        self.db.global.restockCounts = {}
    end

    -- Prune the snapshots down to what the fill column actually reads: itemIDs a
    -- restock rule names, and destinations that still exist. Earlier builds tallied
    -- every item in every bank and never dropped deleted characters, which left
    -- ~99% of the table unread. Runs on the saved data, so it also cleans up after
    -- a rule or character is removed.
    do
        local counts = self.db.global.restockCounts
        local want = self:GetRestockItemIDs()
        local liveDests = self:GetRestockDestKeys()
        for destKey, tally in pairs(counts) do
            if not liveDests[destKey] then
                counts[destKey] = nil
            elseif type(tally) == "table" then
                for itemID in pairs(tally) do
                    if not want[itemID] then
                        tally[itemID] = nil
                    end
                end
                -- An empty tally is meaningful: RestockFillState treats a missing
                -- key as "No data" but an empty one as a real zero, so keep it.
            end
        end
    end

    -- Resolve legacy Keep/Vendor conflicts: items on BOTH lists. Keep List wins
    -- in classification, so remove conflicting entries from the Vendor List.
    -- New code blocks the conflict at add-time; this only matters for saved data
    -- created before that gate existed.
    do
        local removed = 0
        local kl = self.db.global.keepList
        local vl = self.db.global.vendorWhitelist
        if kl and vl then
            for itemID in pairs(kl) do
                if vl[itemID] then
                    vl[itemID] = nil
                    removed = removed + 1
                end
            end
        end
        if removed > 0 then
            self:Print(
                string.format(
                    "Resolved %d Keep/Vendor List conflict%s (kept on Keep List).",
                    removed,
                    removed == 1 and "" or "s"
                )
            )
        end
    end
    if not rawget(self.db.global, "stats") then
        self.db.global.stats = {
            goldVendored = 0,
            itemsVendored = 0,
            itemsStashed = 0,
            itemsMailed = 0,
            goldRepaired = 0,
        }
    end
    if self.db.global.stats and self.db.global.stats.goldRepaired == nil then
        self.db.global.stats.goldRepaired = 0
    end
    if not rawget(self.db.global, "warbandGold") then
        self.db.global.warbandGold = 0
    end

    -- Migrate storage assignments: resolve stale API-stub keys to real GUIDs
    local registry = self.db.global.registry or {}
    for _, asn in ipairs(self.db.global.storageAssignments or {}) do
        if asn.char and asn.char:sub(1, 4) == "API-" then
            local stubName = asn.char:sub(5):match("^(.+)-(.+)$")
            if stubName then
                for guid, entry in pairs(registry) do
                    if
                        guid:sub(1, 4) ~= "API-"
                        and entry.name
                        and entry.realm
                        and (entry.name .. "-" .. entry.realm) == asn.char:sub(5)
                    then
                        asn.char = guid
                        break
                    end
                end
            end
        end
    end

    -- Migration: registry entries from before entry.guildRealm existed. Assume
    -- the guild's realm equals the character's realm. The next login on that
    -- character (via OnEnable / PLAYER_GUILD_UPDATE) refreshes it from the 4th
    -- return of GetGuildInfo, which corrects cross-realm guilds.
    for _, entry in pairs(registry) do
        if entry.guild and entry.guild ~= "" and (not entry.guildRealm or entry.guildRealm == "") then
            entry.guildRealm = entry.realm
        end
    end

    -- Backfill asn.realm on guild-bank rules created before the realm-aware
    -- composite key existed. Look up the first registry character in that
    -- guild and use the guild's home realm. If no such character exists, leave
    -- realm empty: the rule remains unresolvable until the user logs in to a
    -- character in that guild.
    for _, asn in ipairs(self.db.global.storageAssignments or {}) do
        if asn.type == "guildbank" and asn.guild and asn.guild ~= "" and (not asn.realm or asn.realm == "") then
            for _, entry in pairs(registry) do
                if entry.guild == asn.guild and entry.guildRealm and entry.guildRealm ~= "" then
                    asn.realm = entry.guildRealm
                    break
                end
            end
        end
    end

    -- Drop orphan cap.guildbank entries: any key that doesn't match a known
    -- (guild, guildRealm) pair from the registry. Old bare-guild-name keys end
    -- up here, as do composite keys for guilds no character in the roster is
    -- currently in. The next guild-bank open re-populates the right key.
    if self.db.global.storageCapacity and self.db.global.storageCapacity.guildbank then
        local validKeys = {}
        for _, entry in pairs(registry) do
            if entry.guild and entry.guild ~= "" and entry.guildRealm and entry.guildRealm ~= "" then
                -- Route through GuildKey so the validity set uses the same
                -- realm-normalized form the capacity entries are stored under.
                local vk = self:GuildKey(entry.guild, entry.guildRealm)
                if vk then
                    validKeys[vk] = true
                end
            end
        end
        local gb = self.db.global.storageCapacity.guildbank
        for k in pairs(gb) do
            if not validKeys[k] then
                gb[k] = nil
            end
        end
    end

    self:RegisterChatCommand("em", "SlashHandler")

    -- Native WoW Settings panel (Interface → AddOns → EmpireManager)
    -- Landing page = About info; subcategories for settings sections.
    -- The content (stats + full slash command list) is taller than the settings
    -- panel, so it lives in a scroll frame rather than directly on the canvas.
    local aboutFrame = EmpireManagerSettingsCanvas
    local aboutScroll = aboutFrame.ScrollFrame
    local aboutContent = aboutScroll.Content
    aboutScroll:SetScrollChild(aboutContent)

    -- Rebuild on every show: the Statistics block reads live counters.
    local aboutLines = {}
    local function RebuildAbout()
        local w = aboutScroll:GetWidth()
        if not w or w <= 1 then
            return
        end

        for _, obj in ipairs(aboutLines) do
            obj:Hide()
        end
        wipe(aboutLines)

        aboutContent:SetWidth(w)
        local h = self:BuildAboutPanel(aboutContent, {
            track = function(obj)
                aboutLines[#aboutLines + 1] = obj
                return obj
            end,
        })
        aboutContent:SetHeight(h + 20)
    end

    aboutFrame:SetScript("OnShow", RebuildAbout)
    -- The canvas is resized to the settings panel after it is shown, so the
    -- first OnShow can land before the scroll frame has a real width.
    aboutScroll:SetScript("OnSizeChanged", RebuildAbout)

    local category = Settings.RegisterCanvasLayoutCategory(aboutFrame, "EmpireManager")
    self.settingsCategoryID = category:GetID()

    -- Helper: register a boolean option backed by db.global.options.
    -- Returns (setting, initializer). Pass the parent's initializer as
    -- `parentInitializer` to render this option as an indented sub-option that
    -- auto-disables when the parent is unchecked (Blizzard pattern).
    local function AddCheckbox(cat, key, name, tooltip, onChange, parentInitializer)
        local setting = Settings.RegisterProxySetting(
            cat,
            "EM_" .. key,
            Settings.VarType.Boolean,
            name,
            DB_DEFAULTS.global.options[key],
            function()
                return self.db.global.options[key]
            end,
            function(val)
                self.db.global.options[key] = val
                if onChange then
                    onChange(val)
                end
            end
        )
        local initializer = Settings.CreateCheckbox(cat, setting, tooltip)
        if parentInitializer and initializer and initializer.SetParentInitializer then
            initializer:SetParentInitializer(parentInitializer)
        end
        return setting, initializer
    end

    -- Helper: register a numeric slider backed by db.global.options
    local function AddSlider(cat, key, name, tooltip, minVal, maxVal, step, formatter, onChange)
        local setting = Settings.RegisterProxySetting(
            cat,
            "EM_" .. key,
            Settings.VarType.Number,
            name,
            DB_DEFAULTS.global.options[key],
            function()
                return self.db.global.options[key]
            end,
            function(val)
                self.db.global.options[key] = val
                if onChange then
                    onChange(val)
                end
            end
        )
        local options = Settings.CreateSliderOptions(minVal, maxVal, step)
        if formatter then
            options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, formatter)
        end
        Settings.CreateSlider(cat, setting, options, tooltip)
        return setting
    end

    ---------------------------------------------------------------------------
    -- Subcategory: General
    ---------------------------------------------------------------------------
    local generalCat = Settings.RegisterVerticalLayoutSubcategory(category, "General")

    AddCheckbox(
        generalCat,
        "minimapButton",
        "Minimap Button",
        "Show a minimap icon to open the dashboard.",
        function(val)
            if self.minimapIcon then
                self.db.global.minimapIcon.hide = not val
                if val then
                    self.minimapIcon:Show("EmpireManager")
                else
                    self.minimapIcon:Hide("EmpireManager")
                end
            end
        end
    )

    AddCheckbox(
        generalCat,
        "escToClose",
        "ESC to Close",
        "Allow the Escape key to close EmpireManager windows.",
        function()
            self:UpdateEscBehavior()
        end
    )

    AddCheckbox(
        generalCat,
        "clampToScreen",
        "Clamp Windows to Screen",
        "Keep EmpireManager windows from being dragged off the visible screen area.",
        function()
            self:UpdateClampToScreen()
        end
    )

    local _, chatMsgsInit = AddCheckbox(
        generalCat,
        "chatMessages",
        "Chat Messages",
        "Print bulk-operation status updates (triage, mail, deposit, reorganize) to the chat frame. Errors and command responses are always shown."
    )

    AddCheckbox(
        generalCat,
        "verboseMessages",
        "Verbose Messages",
        'Also print internal progress lines like "Restacking bags", "Depositing N items...", and capacity snapshot confirmations.',
        nil,
        chatMsgsInit
    )

    AddCheckbox(
        generalCat,
        "showHints",
        "Show Hints",
        "Print [Hint] lines like upgradeable bag reminders and unpurchased bank tab notices.",
        nil,
        chatMsgsInit
    )

    -- Always Compare Items (CVar, not stored in our DB)
    do
        local setting = Settings.RegisterProxySetting(
            generalCat,
            "EM_alwaysCompareItems",
            Settings.VarType.Boolean,
            "Always Compare Items",
            false,
            function()
                return GetCVarBool("alwaysCompareItems")
            end,
            function(val)
                SetCVar("alwaysCompareItems", val and "1" or "0")
            end
        )
        Settings.CreateCheckbox(
            generalCat,
            setting,
            "Automatically show comparison tooltips when hovering over items. Hold Shift to compare when disabled."
        )
    end

    AddCheckbox(
        generalCat,
        "autoTransferGold",
        "Auto Transfer Gold at Warband Bank",
        "When you open a Warband Bank, move this character's gold to or from it without asking. "
            .. "Set the per-character Withdraw/Deposit amounts in the character panel (/em config) > Gold tab. "
            .. "When off, you are asked to confirm each transfer."
    )

    AddCheckbox(
        generalCat,
        "autoRestock",
        "Auto Restock at Bank",
        "When you open a bank, top up your Restock floors without asking. "
            .. "Set the floors in the Restock tab. When off, you are asked to confirm each top-up."
    )

    local _, autoRepairInit = AddCheckbox(
        generalCat,
        "autoRepair",
        "Auto-Repair at Vendor",
        "Automatically repair all your gear when you open a repair-capable merchant."
    )

    AddCheckbox(
        generalCat,
        "repairWithGuildFunds",
        "Repair with Guild funds",
        "When auto-repairing, use guild bank funds if available and sufficient, falling back to your own gold otherwise.",
        nil,
        autoRepairInit
    )

    ---------------------------------------------------------------------------
    -- Subcategory: Triage
    ---------------------------------------------------------------------------
    local triageCat, triageLayout = Settings.RegisterVerticalLayoutSubcategory(category, "Triage")

    -- Live-refresh the triage window when classification-affecting options change.
    local function triageRefresh()
        if self.OnTriageOptionChanged then
            self:OnTriageOptionChanged()
        end
    end

    -- Section: Rules
    triageLayout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Rules"))

    AddSlider(
        triageCat,
        "defaultVendorThreshold",
        "Default Vendor Threshold",
        "Common-quality items with a per-item vendor price at or below this value are flagged as junk. Crafting materials, trade goods, consumables, and recipes are excluded. Set to 0 to disable.",
        0,
        1000000,
        1000,
        function(val)
            if val == 0 then
                return "Disabled"
            end
            local g = math.floor(val / 10000)
            local s = math.floor((val % 10000) / 100)
            local parts = {}
            if g > 0 then
                parts[#parts + 1] = g .. "g"
            end
            if s > 0 then
                parts[#parts + 1] = s .. "s"
            end
            return table.concat(parts, " ")
        end,
        triageRefresh
    )

    AddCheckbox(
        triageCat,
        "disenchantRouting",
        "Disenchant Routing",
        "Route BoE gear to your Enchanting Artisan when disenchanting is more profitable than selling on the AH. Uses TSM price data when available.",
        triageRefresh
    )

    AddSlider(
        triageCat,
        "disenchantThreshold",
        "Disenchant Threshold",
        "When TSM is not available, BoE gear with per-unit sell price below this value is routed to the Enchanting Artisan. Set to 0 to disable.",
        0,
        1000000,
        1000,
        function(val)
            if val == 0 then
                return "Disabled"
            end
            local g = math.floor(val / 10000)
            local s = math.floor((val % 10000) / 100)
            local parts = {}
            if g > 0 then
                parts[#parts + 1] = g .. "g"
            end
            if s > 0 then
                parts[#parts + 1] = s .. "s"
            end
            return table.concat(parts, " ")
        end,
        triageRefresh
    )

    -- Section: Equipment
    triageLayout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Vendor"))

    AddCheckbox(
        triageCat,
        "skipEquipmentSets",
        "Protect 'Equipment Set' Items",
        "Skip vendoring soulbound gear that belongs to any saved equipment set.",
        triageRefresh
    )

    AddCheckbox(
        triageCat,
        "vendorBoePoor",
        "Sell BoE Poor Quality Items",
        "Flag poor quality items as vendorable even when they are BoE. Off by default so they can be sold on the Auction House instead.",
        triageRefresh
    )

    AddCheckbox(
        triageCat,
        "pawnVendorBop",
        "BoP Non-Upgrades (Pawn)",
        "Flag soulbound gear that Pawn considers not an upgrade as vendorable. Requires the Pawn addon.",
        triageRefresh
    )

    AddCheckbox(
        triageCat,
        "vendorBopIlvl",
        "BoP Lower iLvl",
        "Flag soulbound equippable gear as vendorable when its item level is lower than the equipped item in the same slot. Pawn takes priority when both are enabled.",
        triageRefresh
    )

    AddSlider(
        triageCat,
        "vendorIlvlCeiling",
        "Keep Above iLvl",
        "Soulbound equippable gear at or above this item level is kept regardless of Pawn/iLvl vendor checks. Set to 0 to disable.",
        0,
        344,
        1,
        function(val)
            if val == 0 then
                return "Disabled"
            end
            return tostring(val)
        end,
        triageRefresh
    )

    AddCheckbox(
        triageCat,
        "confirmVendorQuality",
        "Confirm Before Selling Quality Gear",
        "Show a confirmation dialog before vendoring uncommon (green) or higher quality items. Junk and common items vendor silently."
    )

    -- Section: Actions
    triageLayout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Actions"))

    AddCheckbox(
        triageCat,
        "popupOnBank",
        "Open on Bank/Warband Open",
        "Auto-open the triage overlay when opening the Bank or Warband Bank (if deposit items exist)."
    )

    AddCheckbox(
        triageCat,
        "popupOnGuildBank",
        "Open on Guild Bank Open",
        "Auto-open the triage overlay when opening the Guild Bank (if deposit items exist)."
    )

    AddCheckbox(
        triageCat,
        "popupOnMailbox",
        "Open on Mailbox Open",
        "Auto-open the Triage overlay when opening a Mailbox (if routable items exist)."
    )

    AddCheckbox(
        triageCat,
        "popupOnVendor",
        "Open on Vendor Open",
        "Automatically open the Bag Triage overlay when visiting a Vendor (if there are vendorable items)."
    )

    AddCheckbox(
        triageCat,
        "closeTriageOnLeave",
        "Close on Leaving Bank/Vendor/Mail",
        "Automatically close the Triage overlay when you close the Bank, Guild Bank, Vendor, or Mailbox."
    )

    -- Section: Group Mover. Greyed out rather than hidden when TSM is absent, so
    -- the settings stay discoverable.
    triageLayout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Group Mover"))

    local function TSMLoaded()
        return TSM_API ~= nil
    end

    local moverOpts = {
        {
            "groupMoverBoeOnly",
            "Move Tradeable Items Only",
            "Only move items that can actually leave this character - unbound and BoE. Soulbound items are left alone even when the Group lists them.",
        },
        {
            "groupMoverRespectKeepList",
            "Respect the Keep List",
            "Keep-Listed items are skipped and named in chat. Turn off to let the Group win.",
        },
    }
    for _, opt in ipairs(moverOpts) do
        local _, init = AddCheckbox(triageCat, opt[1], opt[2], opt[3])
        if init and init.AddModifyPredicate then
            init:AddModifyPredicate(TSMLoaded)
        end
    end

    Settings.RegisterAddOnCategory(category)

    -- Minimap button (LibDataBroker + LibDBIcon)
    local ldb = LibStub("LibDataBroker-1.1")
    local icon = LibStub("LibDBIcon-1.0")

    local dataBroker = ldb:NewDataObject("EmpireManager", {
        type = "launcher",
        icon = "Interface\\AddOns\\EmpireManager\\textures\\logo-portrait",
        OnClick = function(btn, button)
            if button == "LeftButton" and IsShiftKeyDown() then
                self:ToggleTriageOverlay()
            elseif button == "LeftButton" then
                self:ToggleDashboard()
            elseif button == "RightButton" then
                MenuUtil.CreateContextMenu(btn, function(_, root)
                    root:CreateTitle("EmpireManager")
                    root:CreateButton("Open Dashboard", function()
                        self:ToggleDashboard()
                    end)
                    root:CreateButton("Open Triage", function()
                        self:ToggleTriageOverlay()
                    end)
                    root:CreateButton("Configure this character", function()
                        self:OpenSidecar(self.playerGUID)
                    end)
                    root:CreateDivider()
                    root:CreateButton("Import / Export", function()
                        self:ToggleIOWindow()
                    end)
                    root:CreateDivider()
                    root:CreateButton("Keep List", function()
                        self:ToggleKeeplistWindow()
                    end)
                    root:CreateButton("Vendor Whitelist", function()
                        self:ToggleVendorlistWindow()
                    end)
                    root:CreateButton("Guild Blacklist", function()
                        self:ToggleGuildBlacklistWindow()
                    end)
                    root:CreateButton("Character Blacklist", function()
                        self:ToggleCharBlacklistWindow()
                    end)
                    root:CreateButton("Copy Chat", function()
                        self:_DumpChat()
                    end)
                    root:CreateDivider()
                    root:CreateButton("Options", function()
                        Settings.OpenToCategory(self.settingsCategoryID)
                    end)
                end)
            end
        end,
        OnTooltipShow = function(tt)
            tt:AddLine("EmpireManager", 1, 0.82, 0)
            tt:AddLine(" ")
            tt:AddLine("Left-click: Open Dashboard", 1, 1, 1)
            tt:AddLine("Shift-click: Open Triage", 1, 1, 1)
            tt:AddLine("Right-click: Menu", 1, 1, 1)
        end,
    })

    if not self.db.global.minimapIcon then
        self.db.global.minimapIcon = {}
    end
    -- Sync LibDBIcon's hide flag with our option BEFORE Register so its delayed
    -- PLAYER_LOGIN handler doesn't re-show a button we wanted hidden.
    self.db.global.minimapIcon.hide = not self.db.global.options.minimapButton
    icon:Register("EmpireManager", dataBroker, self.db.global.minimapIcon)

    self.minimapIcon = icon

    self:ChatMsg("EmpireManager loaded")
end

function EmpireManager:OnEnable()
    local guid = UnitGUID("player")
    self.playerGUID = guid -- cache for event handlers (never changes per session)
    local name = UnitName("player")
    local realm = GetRealmName()

    -- Skip data collection if character is blacklisted
    if self.db.global.charBlacklist[guid] then
        self:ChatMsg(
            string.format("|cff888888%s - %s is excluded from roster. Use /em charb to manage.|r", name, realm)
        )
        return
    end

    -- Ensure this character exists in the global registry.
    -- If an imported stub exists for this name+realm, promote it to the real GUID.
    local stubKey = "API-" .. name .. "-" .. realm
    if not self.db.global.registry[guid] then
        self.db.global.registry[guid] = self.db.global.registry[stubKey] or {}
    end
    if self.db.global.registry[stubKey] then
        self.db.global.registry[stubKey] = nil
        -- Update storage assignments that reference the old stub key
        for _, asn in ipairs(self.db.global.storageAssignments or {}) do
            if asn.char == stubKey then
                asn.char = guid
            end
        end
    end

    local entry = self.db.global.registry[guid]
    entry.name = name
    entry.realm = realm
    entry.class = select(2, UnitClass("player"))
    entry.race = select(2, UnitRace("player")) -- "BloodElf", "Orc", etc.
    entry.level = UnitLevel("player")
    entry.gold = GetMoney()
    local guildName, _, _, guildRealm = GetGuildInfo("player")
    entry.guild = guildName or ""
    -- 4th return of GetGuildInfo is the guild's home realm (normalized, no-space)
    -- when it differs from the player's realm, OR nil when the guild's realm
    -- matches OR (timing) when guild data hasn't loaded yet. We can't tell those
    -- apart at OnEnable time, so defer the write: PLAYER_GUILD_UPDATE fires once
    -- guild data is ready and re-runs the capture with the correct 4th return.
    if entry.guild ~= "" and guildRealm then
        entry.guildRealm = guildRealm
        self:PropagateGuildRealmToRules(entry.guild, entry.guildRealm)
    end
    entry.lastSeen = time()
    entry.ilvl = select(2, GetAverageItemLevel()) -- equipped ilvl
    entry.faction = UnitFactionGroup("player") -- "Horde" or "Alliance"

    -- Session stats (transient, not saved)
    self._sessionStats = {
        goldVendored = 0,
        itemsVendored = 0,
        itemsStashed = 0,
        itemsMailed = 0,
        goldRepaired = 0,
    }

    -- Snapshot bag slots
    local free, total = 0, 0
    for bag = 0, 4 do
        total = total + (C_Container.GetContainerNumSlots(bag) or 0)
        free = free + (C_Container.GetContainerNumFreeSlots(bag) or 0)
    end
    entry.freeBagSlots = free
    entry.totalBagSlots = total

    -- Upgrade hint: undersized bags compared to character's own largest
    local maxBagSize = 0
    for bag = 1, 4 do
        local size = C_Container.GetContainerNumSlots(bag) or 0
        if size > maxBagSize then
            maxBagSize = size
        end
    end
    if maxBagSize > 0 then
        local smallBags = {}
        for bag = 1, 4 do
            local size = C_Container.GetContainerNumSlots(bag) or 0
            if size < maxBagSize then
                if size == 0 then
                    smallBags[#smallBags + 1] = string.format("Bag %d (empty)", bag)
                else
                    smallBags[#smallBags + 1] = string.format("Bag %d (%d)", bag, size)
                end
            end
        end
        if #smallBags > 0 then
            self:ChatHint(
                string.format(
                    "|cff4d99ff[Hint]|r Upgradeable bags (your largest is %d-slot): %s",
                    maxBagSize,
                    table.concat(smallBags, ", ")
                )
            )
        end
    end

    -- Openable-container hint: right-click-to-open loot boxes often sit forgotten
    -- in bags. Also re-runs on BAG_UPDATE_DELAYED (see HintOpenableContainers) so
    -- freshly looted chests get announced even mid-session.
    self:HintOpenableContainers()

    self:SnapshotSpec(entry)

    -- Snapshot professions
    self:SnapshotProfessions(entry)

    -- Sync char-level settings to global registry so the dashboard can read all alts.
    -- If another character edited this entry via the sidecar (dirtyFromSidecar flag),
    -- copy global→char instead of char→global to preserve those remote edits.
    if entry.dirtyFromSidecar then
        self.db.char.assignments = entry.assignments or self.db.char.assignments
        self.db.char.storageNote = entry.storageNote or self.db.char.storageNote
        self.db.char.sortOrder = entry.sortOrder or self.db.char.sortOrder
        if entry.auctioneerKeepBOE ~= nil then
            self.db.char.auctioneerKeepBOE = entry.auctioneerKeepBOE
        end
        if entry.enchanterKeepDE ~= nil then
            self.db.char.enchanterKeepDE = entry.enchanterKeepDE
        end
        if entry.keepOwnProfMatsInBank ~= nil then
            self.db.char.keepOwnProfMatsInBank = entry.keepOwnProfMatsInBank
        end
        if entry.keepOwnProfMatsInBags ~= nil then
            self.db.char.keepOwnProfMatsInBags = entry.keepOwnProfMatsInBags
        end
        if entry.keepOwnProfMatsInBagsLatestOnly ~= nil then
            self.db.char.keepOwnProfMatsInBagsLatestOnly = entry.keepOwnProfMatsInBagsLatestOnly
        end
        if entry.stashOldQuestItems ~= nil then
            self.db.char.stashOldQuestItems = entry.stashOldQuestItems
        end
        if entry.ignoreStorageRules ~= nil then
            self.db.char.ignoreStorageRules = entry.ignoreStorageRules
        end
        if entry.goldLow ~= nil then
            self.db.char.goldLow = entry.goldLow
        end
        if entry.goldHigh ~= nil then
            self.db.char.goldHigh = entry.goldHigh
        end
        entry.dirtyFromSidecar = nil
    else
        entry.assignments = self.db.char.assignments
        entry.storageNote = self.db.char.storageNote
        entry.sortOrder = self.db.char.sortOrder
        entry.auctioneerKeepBOE = self.db.char.auctioneerKeepBOE
        entry.enchanterKeepDE = self.db.char.enchanterKeepDE
        entry.keepOwnProfMatsInBank = self.db.char.keepOwnProfMatsInBank
        entry.keepOwnProfMatsInBags = self.db.char.keepOwnProfMatsInBags
        entry.keepOwnProfMatsInBagsLatestOnly = self.db.char.keepOwnProfMatsInBagsLatestOnly
        entry.stashOldQuestItems = self.db.char.stashOldQuestItems
        entry.ignoreStorageRules = self.db.char.ignoreStorageRules
        entry.goldLow = self.db.char.goldLow
        entry.goldHigh = self.db.char.goldHigh
    end

    -- Lazy trigger events (only the windows we care about)
    self:RegisterEvent("BAG_UPDATE_DELAYED")
    self:RegisterEvent("TRADE_SKILL_SHOW")
    -- Catch profession unlearn (no tradeskill window opens). Also fires on learn,
    -- level-up, etc., so the handler is throttled.
    self:RegisterEvent("SKILL_LINES_CHANGED")
    self:RegisterEvent("BANKFRAME_OPENED")
    self:RegisterEvent("BANKFRAME_CLOSED")
    -- Guild bank: GUILDBANKFRAME_OPENED/CLOSED are dead since 10.0.
    -- Use PLAYER_INTERACTION_MANAGER_FRAME_SHOW/HIDE with type 10 (GuildBanker).
    self:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
    self:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
    -- Register permanently (like Blizzard's GuildBankFrame does in OnLoad).
    -- Dynamic registration inside the SHOW handler can miss the event if it fires
    -- before or during the frame show as part of initial server data load.
    self:RegisterEvent("GUILDBANK_UPDATE_TABS")
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    self:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    self:RegisterEvent("PLAYER_LOGOUT")
    self:RegisterEvent("MERCHANT_SHOW")
    self:RegisterEvent("MERCHANT_CLOSED")
    self:RegisterEvent("MAIL_SHOW")
    self:RegisterEvent("MAIL_CLOSED")
    self:RegisterEvent("PLAYER_GUILD_UPDATE")
    self:RegisterEvent("TIME_PLAYED_MSG")
    self:RegisterEvent("PLAYER_LEVEL_UP")
    self:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    self:RegisterEvent("PLAYER_MONEY")
    -- Catch the initial spec pick on a fresh character (and later respecs);
    -- OnEnable snapshots spec once, so without this it stays stale until relog.
    self:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")

    -- Request playtime (async → triggers TIME_PLAYED_MSG). Silent variant suppresses
    -- Blizzard's chat output for our request; user-typed /played still prints normally.
    self:RequestTimePlayedSilent()

    -- Apply saved clamp preference to any XML frames that already exist
    self:UpdateClampToScreen()
    -- Apply saved ESC-to-close preference (registers UISpecialFrames entries)
    self:UpdateEscBehavior()
end

function EmpireManager:SlashHandler(input)
    local cmd = (self:GetArgs(input) or ""):lower()
    if cmd == "config" then
        local guid = self.playerGUID
        self:OpenSidecar(guid)
    elseif cmd == "triage" then
        local _, sub = self:GetArgs(input, 2)
        if sub and sub:lower() == "debug" then
            EmpireManager._debugShowKeep = not EmpireManager._debugShowKeep
            self:ChatMsg(
                string.format(
                    "Triage KEEP rows: %s",
                    EmpireManager._debugShowKeep and "|cff00ff00ON|r" or "|cffff4444OFF|r"
                ),
                true
            )
            if self.triageFrame and self.triageFrame:IsShown() then
                if self._triageActiveTab == "bank" then
                    self:RefreshBankTriageDisplay()
                else
                    self:RefreshTriageDisplay()
                end
            end
        else
            self:ToggleTriageOverlay()
        end
    elseif cmd == "options" then
        Settings.OpenToCategory(self.settingsCategoryID)
    elseif cmd == "purge" then
        local _, charName = self:GetArgs(input, 2)
        if not charName or charName == "" then
            self:ChatMsg("Usage: /em purge <Name> or <Name-Realm>", true)
            return
        end
        self:PurgeCharacter(charName)
    elseif cmd == "keeplist" then
        self:ToggleKeeplistWindow()
    elseif cmd == "vendorw" then
        self:ToggleVendorlistWindow()
    elseif cmd == "gb" then
        self:ToggleGuildBlacklistWindow()
    elseif cmd == "charb" then
        self:ToggleCharBlacklistWindow()
    elseif cmd == "ie" then
        self:ToggleIOWindow()
    elseif cmd == "cc" then
        self:_DumpChat()
    elseif cmd == "wizard" then
        self:OpenWizard()
    elseif cmd == "wipe" then
        local _, sub = self:GetArgs(input, 2)
        if
            sub == "chars"
            or sub == "rules"
            or sub == "all"
            or sub == "keeplist"
            or sub == "vendorw"
            or sub == "restock"
        then
            self:ConfirmWipe(sub)
        else
            self:ChatMsg("|cffff8800/em wipe|r targets (destructive, prompts to confirm):", true)
            self:ChatMsg("  chars . . . . Character roster", true)
            self:ChatMsg("  rules . . . . Storage Rules", true)
            self:ChatMsg("  keeplist  . . Keep List", true)
            self:ChatMsg("  vendorw . . . Vendor Whitelist", true)
            self:ChatMsg("  restock . . . Restock Rules", true)
            self:ChatMsg("  all . . . . . everything above", true)
        end
    elseif cmd == "inspect" then
        -- Print classID/subClassID of the item currently under the cursor tooltip
        GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
        local _, itemLink = GameTooltip:GetItem()
        GameTooltip:Hide()
        if not itemLink then
            -- Cursor fallback. GetCursorInfo returns a bare itemID, and
            -- GetItemInfo(itemID) hands back the GENERIC template link - no bonusIDs,
            -- no upgrade level - which reports different bindType/ilvl than the item
            -- actually in the bag. Prefer the real link from the first bag slot
            -- holding this itemID; fall back to the template only if it is not in bags.
            local infoType, id = GetCursorInfo()
            if infoType == "item" and id then
                for bag = 0, 5 do
                    for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
                        local info = C_Container.GetContainerItemInfo(bag, slot)
                        if info and info.itemID == id and info.hyperlink then
                            itemLink = info.hyperlink
                            break
                        end
                    end
                    if itemLink then
                        break
                    end
                end
                itemLink = itemLink or select(2, C_Item.GetItemInfo(id))
            end
        end
        if not itemLink then
            self:ChatMsg("Pick up an item, then run /em inspect", true)
            return
        end
        self:EnsureStorageCache()
        local itemID, _, _, itemEquipLoc, icon, classID, subClassID = C_Item.GetItemInfoInstant(itemLink)
        local itemName, _, _, _, _, _, _, maxStack, _, _, _, _, _, bindType, expansionID =
            C_Item.GetItemInfo(itemLink)
        self:ChatMsg(string.format("|cffffcc00[Inspect]|r %s", itemName or itemLink), true)
        self:ChatMsgRaw(
            string.format(
                "  itemID=%d  classID=%d  subClassID=%d  equipLoc=%s",
                itemID or 0,
                classID or -1,
                subClassID or -1,
                itemEquipLoc or ""
            ),
            true
        )
        self:ChatMsgRaw(
            string.format(
                -- From the resolved link. Per-bag-slot lines below carry each instance's
                -- own values; they can differ from this one (upgrade level, bonusIDs).
                -- bindType is the item's DECLARED bind rule, not its current state: a
                -- Warbound-until-equipped piece keeps bindType=2 after being equipped.
                -- Classification trusts isBound/isWarbound, never bindType alone.
                "  bindType=%d  expansionID=%s  icon=%s  maxStack=%s",
                bindType or -1,
                tostring(expansionID or "nil"),
                tostring(icon or "nil"),
                tostring(maxStack or "nil")
            ),
            true
        )
        -- Crafting quality tier (what the Restock chevron uses). Print both API
        -- returns plus the atlas the addon resolves, so we can tell whether a wrong
        -- chevron is a tier-number issue or an atlas-art issue.
        do
            local reagentQ = C_TradeSkillUI and C_TradeSkillUI.GetItemReagentQualityByItemInfo
                and C_TradeSkillUI.GetItemReagentQualityByItemInfo(itemID)
            local craftedQ = C_TradeSkillUI and C_TradeSkillUI.GetItemCraftedQualityByItemInfo
                and C_TradeSkillUI.GetItemCraftedQualityByItemInfo(itemLink)
            local tier = reagentQ or craftedQ
            local atlas = "nil"
            if tier then
                for _, cand in ipairs({
                    "Professions-Icon-Quality-Tier" .. tier .. "-Small",
                    "Professions-Icon-Quality-Tier" .. tier,
                    "Professions-ChatIcon-Quality-Tier" .. tier,
                }) do
                    if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(cand) then
                        atlas = cand
                        break
                    end
                end
            end
            self:ChatMsgRaw(
                string.format(
                    "  quality: reagentTier=%s  craftedTier=%s  -> atlas=%s",
                    tostring(reagentQ or "nil"),
                    tostring(craftedQ or "nil"),
                    atlas
                ),
                true
            )
        end
        -- Bind flags via the classifier's OWN parser, so this line cannot disagree
        -- with what routing acted on. Also reports NeedsTooltipScan: when that gate
        -- is false the classifier never parses at all and every flag stays false,
        -- which a bare "isWarbound=false" would otherwise hide.
        if C_TooltipInfo and C_TooltipInfo.GetHyperlink then
            local td = C_TooltipInfo.GetHyperlink(itemLink)
            local isWarbound, isSoulbound, _, _, _, isConjured, isEquipToken, isKnownAppearance, isPermanentWarbound =
                self.ParseTooltipBind(td)
            local gate = self.NeedsTooltipScan(classID or -1, bindType or 0, itemID)
            self:ChatMsgRaw(
                string.format(
                    "  tooltip: isWarbound=%s  permanentWarbound=%s  isSoulbound=%s  isConjured=%s  isEquipToken=%s  isKnownAppearance=%s",
                    tostring(isWarbound),
                    tostring(isPermanentWarbound),
                    tostring(isSoulbound),
                    tostring(isConjured),
                    tostring(isEquipToken),
                    tostring(isKnownAppearance)
                ),
                true
            )
            self:ChatMsgRaw(
                string.format(
                    "  NeedsTooltipScan=%s%s",
                    tostring(gate),
                    gate and "" or "  (classifier skips bind detection: all flags forced false)"
                ),
                true
            )
        end
        -- Live per-slot bind state. The block above reads the item template, which
        -- always says "Binds when picked up"; triage scans bags with GetBagItem.
        if itemID and C_TooltipInfo and C_TooltipInfo.GetBagItem then
            local found = 0
            for bag = 0, 5 do
                local numSlots = C_Container.GetContainerNumSlots(bag) or 0
                for slot = 1, numSlots do
                    local info = C_Container.GetContainerItemInfo(bag, slot)
                    if info and info.itemID == itemID then
                        found = found + 1
                        -- Run the classifier's own parser on THIS slot's tooltip.
                        -- Previously this listed tooltip lines matching a local
                        -- whitelist, which was narrower than the parser's: a bind
                        -- line the whitelist lacked printed as "(none)" even though
                        -- the parser recognised it.
                        local td = C_TooltipInfo.GetBagItem(bag, slot)
                        local sWarbound, sSoulbound, _, _, _, _, _, _, sPermWarbound =
                            self.ParseTooltipBind(td)
                        -- Per-slot iLvl from that slot's own link: two upgraded copies
                        -- of one itemID differ here, which is what splits them across
                        -- the vendor ceiling (one kept, one flagged by Pawn).
                        local slotLink = C_Container.GetContainerItemLink(bag, slot)
                        local slotIlvl = slotLink and C_Item.GetDetailedItemLevelInfo(slotLink)
                        -- bindType read from THIS slot's link, so two upgraded copies (or
                        -- a generic template link) can be told apart from the header line.
                        local slotBind = slotLink and select(14, C_Item.GetItemInfo(slotLink))
                        -- isBound is the live per-instance check classification relies on
                        -- (see the C_Item.IsBound note in TriageLogic's bag scan). Printing
                        -- it beside bindType shows why a bindType=2 item is not AH-routed.
                        local sloc = ItemLocation:CreateFromBagAndSlot(bag, slot)
                        local slotBound = C_Item.DoesItemExist(sloc) and C_Item.IsBound(sloc)
                        -- Stack size of THIS slot. Read beside maxStack on the header
                        -- line, it gives the room a deposit into this slot would have.
                        local slotInfo = C_Container.GetContainerItemInfo(bag, slot)
                        local slotCount = slotInfo and slotInfo.stackCount
                        self:ChatMsgRaw(
                            string.format(
                                "  bag %d:%d count=%s  ilvl=%s  bindType=%s  isBound=%s  parsed: warbound=%s permanent=%s soulbound=%s",
                                bag,
                                slot,
                                tostring(slotCount or "?"),
                                tostring(slotIlvl or "?"),
                                tostring(slotBind or "?"),
                                tostring(slotBound and true or false),
                                tostring(sWarbound),
                                tostring(sPermWarbound),
                                tostring(sSoulbound)
                            ),
                            true
                        )
                    end
                end
            end
            if found == 0 then
                self:ChatMsgRaw("  (not in bags - live bind state unavailable)", true)
            end
        end
        -- Vendor-gate context: the iLvl ceiling is the rule that most often explains
        -- why one copy of an item is kept and another is flagged for vendor.
        do
            local ceiling = self.db.global.options.vendorIlvlCeiling or 0
            self:ChatMsgRaw(
                string.format(
                    "  vendorIlvlCeiling=%s  pawnVendorBop=%s  vendorBopIlvl=%s",
                    ceiling > 0 and tostring(ceiling) or "0 (disabled)",
                    tostring(self.db.global.options.pawnVendorBop and true or false),
                    tostring(self.db.global.options.vendorBopIlvl and true or false)
                ),
                true
            )
        end
        -- Check profMatchCache
        local cacheKey = (classID or 0) * 1000 + (subClassID or 0)
        local matched = self._profMatchCache[cacheKey]
        if matched then
            local keys = {}
            for k in pairs(matched) do
                keys[#keys + 1] = k
            end
            self:ChatMsgRaw(string.format("  profMatchCache[%d] = {%s}", cacheKey, table.concat(keys, ", ")), true)
        else
            self:ChatMsgRaw(string.format("  profMatchCache[%d] = nil (no category match)", cacheKey), true)
        end
        local override = itemID and self._profOverrideCache[itemID]
        if override then
            local keys = {}
            for k in pairs(override) do
                keys[#keys + 1] = k
            end
            self:ChatMsgRaw(string.format("  profOverrideCache[%d] = {%s}", itemID, table.concat(keys, ", ")), true)
        end
        -- TSM prices (if available)
        if TSM_API then
            local de = self:GetTSMPrice(itemLink, "DBDisenchant")
            local mk = self:GetTSMPrice(itemLink, "DBMarket")
            self:ChatMsgRaw(
                string.format(
                    "  TSM DBDisenchant=%s  DBMarket=%s",
                    de and self:FormatGold(de) or "nil",
                    mk and self:FormatGold(mk) or "nil"
                ),
                true
            )
        else
            self:ChatMsgRaw("  TSM not loaded (no DBDisenchant/DBMarket)", true)
        end
    elseif cmd == "dump" then
        local _, sub = self:GetArgs(input, 2)
        sub = sub and sub:lower() or "bags"
        -- Map sub-commands to {source label, scan type, bankType filter}. `debug`
        -- kept as alias for the default bag dump.
        local target
        if sub == "bags" or sub == "debug" or sub == "" then
            target = { label = "bag", scan = "bags" }
        elseif sub == "bank" then
            target = { label = "bank", scan = "bank", bankType = "charbank" }
        elseif sub == "wb" or sub == "warband" then
            target = { label = "warband bank", scan = "bank", bankType = "warbandbank" }
        elseif sub == "gb" or sub == "guild" then
            target = { label = "Guild Bank", scan = "guildbank" }
        else
            self:ChatMsg(string.format("|cffff4444[dump]|r unknown target: %s", sub), true)
            return
        end
        self:_DumpDebug(target)
    elseif cmd == "gendata" then
        -- Dev helper: dump RESTOCK_ITEMS itemIDs from the loaded AH browse results,
        -- grouped by Trade Goods subclass. Accumulates across runs (one search per
        -- category); `reset` clears the accumulator. Run at the AH after searching
        -- Reagents -> <profession> with "Current Expansion Only".
        local _, gsub = self:GetArgs(input, 2)
        self:_GenRestockData(gsub and gsub:lower() or nil)
    elseif cmd == "help" then
        self:ChatMsg("|cffffcc00Available commands:|r", true)
        for _, c in ipairs(EmpireManager.SLASH_COMMANDS) do
            self:ChatMsg(string.format("  %s %s", c.cmd, c.desc), true)
        end
    else
        self:ToggleDashboard()
    end
end

-- Toggle ESC-to-close behavior for all EmpireManager frames and popups
function EmpireManager:UpdateEscBehavior()
    -- Use the real XML frame names (untainted globals). Aliases created via
    -- _G[name] = frame in Lua are tainted; when Blizzard's secure CloseSpecialWindows
    -- loop reads them on Escape, the secure execution inherits EmpireManager taint,
    -- which later crashes unrelated secret-value comparisons (e.g. world-map POI widgets).
    local frameNames = {
        "EmpireManagerFrame",
        "EmpireManagerTriageFrame",
        "EmpireManagerSidecar",
        "EmpireManagerKeeplistWindow",
        "EmpireManagerVendorlistWindow",
        "EmpireManagerGuildBlacklistWindow",
        "EmpireManagerCharBlacklistWindow",
        "EmpireManagerWizardFrame",
        "EmpireManagerRemapDialog",
        "EmpireManagerIOFrame",
        "EmpireManagerRestockConfirmDialog",
    }
    local enabled = self.db.global.options.escToClose
    if enabled then
        for _, name in ipairs(frameNames) do
            if _G[name] and not tContains(UISpecialFrames, name) then
                tinsert(UISpecialFrames, name)
            end
        end
    else
        for _, name in ipairs(frameNames) do
            for i = #UISpecialFrames, 1, -1 do
                if UISpecialFrames[i] == name then
                    tremove(UISpecialFrames, i)
                end
            end
        end
    end
    -- Apply same preference to our StaticPopup dialogs
    local popups = {
        "EM_CONFIRM_REMOVE",
        "EM_KEEPLIST_ADD",
        "EM_VENDORLIST_ADD",
        "EM_KEEPLIST_MOVE_FROM_VENDOR",
        "EM_VENDORLIST_MOVE_FROM_KEEP",
    }
    for _, key in ipairs(popups) do
        if StaticPopupDialogs[key] then
            StaticPopupDialogs[key].hideOnEscape = enabled
        end
    end
end

-- Render a single triage result as one debug line (inspect-style). Shared by
-- /em dump, /em dump bank, /em dump wb, /em dump gb.
local function FormatDumpLine(addon, r)
    local CATEGORY_INFO = addon.CATEGORY_INFO
    local item = r.item
    local link = item.itemLink or item.itemName or "?"
    -- For display use the plain item name (no brackets, no link escapes).
    -- `link` is still passed to GetItemInfo* below since those APIs accept
    -- both names and links.
    local displayName = item.itemName or link or "?"
    local catInfo = CATEGORY_INFO[r.category]
    local catLabel = catInfo and catInfo.label or "?"
    -- routeCount = units actually moved (surplus above a restock floor); fall back to
    -- the whole stack when the row moves everything.
    local count = item.routeCount or item.stackCount or item.count or 1
    local itemID, _, _, itemEquipLoc, _, classID, subClassID = C_Item.GetItemInfoInstant(link)
    local bindType, expansionID, _, isCraftingReagent = select(14, C_Item.GetItemInfo(link))
    local cacheKey = (classID or 0) * 1000 + (subClassID or 0)
    local override = itemID and addon._profOverrideCache[itemID]
    local matched = override or addon._profMatchCache[cacheKey]
    local profStr
    if matched then
        local keys = {}
        for k in pairs(matched) do
            keys[#keys + 1] = k
        end
        profStr = "{" .. table.concat(keys, ",") .. "}"
        if override then
            profStr = profStr .. "*" -- mark itemID overrides in dump output
        end
    else
        profStr = "nil"
    end
    local reagentStr = isCraftingReagent == true and "yes" or (isCraftingReagent == false and "no" or "?")
    local boundStr = item.isBound and "Y" or "n"
    local warStr = item.isWarbound and "Y" or "n"
    -- Per-instance iLvl. Read from the itemLink (not the itemID) so two upgraded
    -- copies of the same item report their own levels - that difference is what
    -- explains a keep-vs-vendor split on one itemID (ceiling vs Pawn).
    local ilvl = item.itemLink and C_Item.GetDetailedItemLevelInfo(item.itemLink)
    return string.format(
        "%s;%s;%d;%d;%d;%d;%s;%s;%d;%s;%s;%s;%s;%s;%s",
        catLabel,
        displayName,
        count,
        itemID or 0,
        classID or -1,
        subClassID or -1,
        itemEquipLoc ~= "" and itemEquipLoc or "-",
        tostring(ilvl or "-"),
        bindType or -1,
        boundStr,
        warStr,
        tostring(expansionID or "nil"),
        reagentStr,
        profStr,
        r.action or "?"
    )
end

-- Render results into the debug popup. `target` = {label, scan, bankType?}.
-- Handles bags (sync), char/warband bank (async bank scan), guild bank (async).
function EmpireManager:_DumpDebug(target)
    local charName = UnitName("player") or "?"
    local function render(results, filterFn)
        local filtered = {}
        if filterFn then
            for _, r in ipairs(results) do
                if filterFn(r) then
                    filtered[#filtered + 1] = r
                end
            end
        else
            filtered = results
        end
        if not filtered or #filtered == 0 then
            self:ChatMsg(string.format("No items in %s.", target.label), true)
            return
        end
        local lines = {
            string.format("# %s %s dump (%d items)", charName, target.label, #filtered),
            "category;name;count;itemID;classID;subClassID;equipLoc;ilvl;bindType;bound;warbound;expansion;reagent;prof;action",
        }
        for _, r in ipairs(filtered) do
            lines[#lines + 1] = FormatDumpLine(self, r)
        end
        self:ShowDebugPopup(table.concat(lines, "\n"))
    end

    if target.scan == "bags" then
        render(self:RunTriage() or {})
    elseif target.scan == "bank" then
        if not self.bankIsOpen then
            self:ChatMsg("|cffff4444[dump]|r Bank must be open for this dump.", true)
            return
        end
        self:RunBankTriageAsync(function(results)
            render(results, function(r)
                return r.item.bankType == target.bankType
            end)
        end)
    elseif target.scan == "guildbank" then
        if not self:IsGuildBankOpen() then
            self:ChatMsg("|cffff4444[dump]|r Guild Bank must be open for this dump.", true)
            return
        end
        self:RunBankTriageAsync(function(results)
            render(results, function(r)
                return r.item.bankType == "guildbank"
            end)
        end)
    end
end

-- Dev helper (`/em gendata`): dump RESTOCK_ITEMS itemIDs from the loaded AH browse
-- results, grouped by Trade Goods subclass. Workflow: at the AH, search Reagents ->
-- <profession> with the "Current Expansion Only" filter checked, let all pages load,
-- then run `/em gendata`. Reads the FULL result store (not the visible page) - the set
-- is more than one screen, so we request remaining pages until HasFullBrowseResults().
--
-- ACCUMULATES across runs (session-only, `self._genRestockAcc`): a single broad
-- "Reagents (all)" search risks an incomplete stream, so do one search PER category
-- (Cloth, Leather, Metal & Stone, ...) and run `/em gendata` after each - itemIDs merge
-- into one deduped table. The running unique total lets you sanity-check against a broad
-- dump: if the per-category union is larger, the broad search truncated.
--   /em gendata        - merge current AH results, then show the accumulated table
--   /em gendata reset  - clear the accumulator and start over
-- Dev-only; not surfaced in /em help.
function EmpireManager:_GenRestockData(sub)
    if sub == "reset" then
        self._genRestockAcc = nil
        self:ChatMsg("|cffffcc00[gendata]|r Accumulator cleared.", true)
        return
    end
    if not C_AuctionHouse or not C_AuctionHouse.GetBrowseResults then
        self:ChatMsg("|cffff4444[gendata]|r Open the Auction House first.", true)
        return
    end

    -- Merge the current (complete) browse results into the session accumulator, then
    -- render the full accumulated table. Accumulator: { [itemID] = { sub = "7/9",
    -- exp = expansionID } }. Tagging by expansionID lets a broad (all-expansion)
    -- search auto-separate TWW (exp 10) from Midnight (exp 11), etc.
    local function build()
        local results = C_AuctionHouse.GetBrowseResults() or {}
        local complete = not C_AuctionHouse.HasFullBrowseResults or C_AuctionHouse.HasFullBrowseResults()
        self._genRestockAcc = self._genRestockAcc or {}
        local acc = self._genRestockAcc
        local added = 0
        for _, r in ipairs(results) do
            local itemID = r.itemKey and r.itemKey.itemID
            if itemID and not acc[itemID] then
                local _, _, _, _, _, classID, subClassID = C_Item.GetItemInfoInstant(itemID)
                local expID = select(15, C_Item.GetItemInfo(itemID))
                local sub = (classID == 7) and ("7/" .. tostring(subClassID or "?"))
                    or ("class" .. tostring(classID or "?"))
                acc[itemID] = { sub = sub, exp = expID or -1 }
                added = added + 1
            end
        end

        -- Regroup the accumulator by expansion -> subclass for output. Only the three
        -- modern expansions have the crafting-quality tier system and need a restock
        -- table: Dragonflight (9), TWW (10), Midnight (11). Older items are skipped.
        local WANT_EXP = { [9] = true, [10] = true, [11] = true }
        local byExp, total = {}, 0
        for itemID, info in pairs(acc) do
            if WANT_EXP[info.exp] then
                byExp[info.exp] = byExp[info.exp] or {}
                byExp[info.exp][info.sub] = byExp[info.exp][info.sub] or {}
                local bucket = byExp[info.exp][info.sub]
                bucket[#bucket + 1] = itemID
                total = total + 1
            end
        end
        local expKeys = {}
        for e in pairs(byExp) do
            expKeys[#expKeys + 1] = e
        end
        table.sort(expKeys)

        local lines = {
            string.format(
                "-- RESTOCK_ITEMS dump - %d new from %d AH results; %d unique in exp 9/10/11%s",
                added,
                #results,
                total,
                complete and "" or "  |cffff4444(PARTIAL: results not fully loaded)|r"
            ),
            "-- Accumulates across /em gendata runs. /em gendata reset to clear.",
            "-- Paste each block into RESTOCK_ITEMS[<expansionID>]. The picker categorizes by",
            "-- subclass at render time (GetItemInfoInstant); no per-profession bucketing needed.",
            "-- (TWW = exp 10, Midnight = exp 11. exp -1 = uncached/unknown.)",
        }
        for _, e in ipairs(expKeys) do
            lines[#lines + 1] = string.format("-- === expansion %s ===", tostring(e))
            local bySub = byExp[e]
            local subKeys = {}
            for k in pairs(bySub) do
                subKeys[#subKeys + 1] = k
            end
            table.sort(subKeys)
            for _, k in ipairs(subKeys) do
                local ids = bySub[k]
                table.sort(ids)
                lines[#lines + 1] = string.format("--   subclass %s (%d items):", k, #ids)
                lines[#lines + 1] = "{ " .. table.concat(ids, ", ") .. " },"
            end
        end
        self:ShowDebugPopup(table.concat(lines, "\n"))
        if not complete then
            self:ChatMsg("|cffff4444[gendata]|r Results were not fully loaded - re-run after they settle.", true)
        end
    end

    if C_AuctionHouse.HasFullBrowseResults and not C_AuctionHouse.HasFullBrowseResults() then
        self:ChatMsg("|cffffcc00[gendata]|r Loading all pages...", true)
        local frame = CreateFrame("Frame")
        frame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
        frame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
        frame:SetScript("OnEvent", function()
            if C_AuctionHouse.HasFullBrowseResults() then
                frame:UnregisterAllEvents()
                frame:SetScript("OnEvent", nil)
                build()
            else
                C_AuctionHouse.RequestMoreBrowseResults()
            end
        end)
        C_AuctionHouse.RequestMoreBrowseResults()
    else
        build()
    end
end

-- Lazy-created popup used by debug dump commands (/em dumpv etc.)
-- Copyable textarea: plain ScrollFrame + EditBox scroll child. Avoids
-- InputScrollFrameTemplate's character-counter overlay and the selection-rect
-- bugs that come with chat-font templates.
-- Chat Copy (`/em cc`): dump the visible chat frames into the debug popup so the
-- text can be selected and copied out. Same window as `/em dump`.

-- How many messages to pull per chat frame. WoW's own scrollback caps around
-- 1000; 500 keeps a busy General tab responsive.
local CHAT_COPY_MAX_LINES = 500

-- Strip markup that is meaningless once the text leaves the chat frame: textures
-- and atlases render as nothing in an EditBox, and WoW's pluralisation escape has
-- to be resolved by hand.
local function CleanChatLine(msg)
    if not msg or msg == "" then
        return ""
    end
    msg = msg:gsub("|T.-|t", "")
    msg = msg:gsub("|A.-|a", "")
    -- "5 |4second:seconds;" -> "5 seconds". Singular for exactly 1, plural
    -- otherwise (including 0).
    msg = msg:gsub("(%d+) |4([^:|]+):([^;|]+);", function(n, singular, plural)
        return n .. " " .. (tonumber(n) == 1 and singular or plural)
    end)
    return msg
end

-- WoW 12.x marks some chat text as a "secret value": an addon may hold it but any
-- comparison or concatenation raises "attempt to compare ... a secret string value,
-- while execution tainted". Chat inside instanced content (delves, encounters) is
-- routinely secret. issecretvalue is the sanctioned test - Blizzard uses it in their
-- own error handler - and type() short-circuits it for nil. Guarded so a client
-- without the function still works.
local IsSecret = _G.issecretvalue
local function IsCopyableText(v)
    if type(v) ~= "string" then
        return false
    end
    return not (IsSecret and IsSecret(v))
end

function EmpireManager:_DumpChat()
    -- Collected in a table and concatenated once: appending to a string would
    -- reallocate the whole buffer per message, up to 10 x 500 times.
    local lines = {}
    local secretLines = 0
    for i = 1, NUM_CHAT_WINDOWS do
        local frame = _G["ChatFrame" .. i]
        if frame and frame:IsVisible() then
            local numMessages = frame:GetNumMessages() or 0
            if numMessages > 0 then
                local startLine = math.max(1, numMessages - CHAT_COPY_MAX_LINES + 1)
                if #lines > 0 then
                    -- Name the tab rather than its index, so "Combat Log" reads
                    -- as itself in the copied text.
                    local name = frame.name
                    if not name or name == "" then
                        name = GetChatWindowInfo(i) or ("Chat Frame " .. i)
                    end
                    lines[#lines + 1] = ""
                    lines[#lines + 1] = "--- " .. name .. " ---"
                end
                for n = startLine, numMessages do
                    -- GetMessageInfo returns message, r, g, b, id - it does not
                    -- expose the originating chat event, so per-type prefixes
                    -- ([SAY], [GUILD]) are not recoverable here.
                    local ok, message = pcall(frame.GetMessageInfo, frame, n)
                    if ok and IsCopyableText(message) then
                        if message ~= "" then
                            lines[#lines + 1] = CleanChatLine(message)
                        end
                    elseif ok then
                        -- Secret text. Counted so a short copy is explained rather
                        -- than looking like lines went missing.
                        secretLines = secretLines + 1
                    end
                end
            end
        end
    end

    if #lines == 0 then
        self:ChatMsg("|cffff4444[cc]|r No chat content found to copy.", true)
        if secretLines > 0 then
            self:ChatMsg(string.format(
                "|cffff4444[cc]|r %d line%s are protected by the game and cannot be read by addons (instanced content).",
                secretLines,
                secretLines == 1 and "" or "s"
            ), true)
        end
        return
    end
    if secretLines > 0 then
        self:ChatMsg(string.format(
            "|cffff8800[cc]|r Skipped %d protected line%s the game does not let addons read.",
            secretLines,
            secretLines == 1 and "" or "s"
        ), true)
    end
    self:ShowDebugPopup(table.concat(lines, "\n"), "EmpireManager - Chat Copy")
end

function EmpireManager:ShowDebugPopup(text, titleText)
    local f = _G.EmpireManagerDebugFrame
    if not f then
        f = CreateFrame("Frame", "EmpireManagerDebugFrame", UIParent, "BackdropTemplate")
        f:SetSize(800, 520)
        f:SetPoint("CENTER")
        f:SetFrameStrata("HIGH")
        f:SetToplevel(true)
        f:SetMovable(true)
        f:EnableMouse(true)
        f:SetClampedToScreen(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        f:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true,
            tileSize = 32,
            edgeSize = 32,
            insets = { left = 8, right = 8, top = 8, bottom = 8 },
        })
        f:SetBackdropColor(0.06, 0.06, 0.09, 0.95)

        local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
        title:SetPoint("TOP", 0, -16)
        f.TitleText = title

        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -4, -4)

        -- No frame-level keyboard capture. A parent frame with EnableKeyboard(true)
        -- receives every keystroke before the EditBox does, which ate Backspace and
        -- made the text flicker; and the only way to pass keys through,
        -- SetPropagateKeyboardInput, is PROTECTED in combat - calling it there
        -- raises ADDON_ACTION_BLOCKED, and a propagate=false left behind would
        -- swallow movement keys the next time the window opened.
        -- ESC is handled on the EditBox (OnEscapePressed); the X button closes it
        -- otherwise. UISpecialFrames is not an option either: this frame is
        -- CreateFrame'd in Lua (tainted), and a tainted UISpecialFrames entry
        -- taints Blizzard's secure window-close loop.

        -- Plain ScrollFrame (NOT InputScrollFrameTemplate) so there's no
        -- character-counter overlay and no template-imposed font.
        local scroll = CreateFrame("ScrollFrame", nil, f)
        scroll:SetPoint("TOPLEFT", 24, -48)
        scroll:SetPoint("BOTTOMRIGHT", -36, 24)
        scroll:EnableMouse(true)

        -- EditBox is the scroll child. Fills the scroll viewport; auto-grows
        -- vertically when SetText is called.
        local eb = CreateFrame("EditBox", nil, scroll)
        eb:SetMultiLine(true)
        eb:SetAutoFocus(false)
        eb:EnableMouse(true)
        eb:SetCountInvisibleLetters(false) -- fix selection-rect mis-alignment with escapes
        eb:SetTextInsets(4, 4, 4, 4)
        eb:SetFontObject("ChatFontNormal")
        eb:SetMaxBytes(0)
        eb:SetMaxLetters(0)
        if eb.SetHyperlinksEnabled then
            eb:SetHyperlinksEnabled(false)
        end

        scroll:SetScrollChild(eb)
        eb:SetWidth(8000) -- wide so long lines never wrap
        scroll:SetHorizontalScroll(0)

        -- Click anywhere in the scroll viewport (including below the text)
        -- focuses the editbox and parks the cursor at the end.
        scroll:SetScript("OnMouseUp", function()
            eb:SetFocus()
            eb:SetCursorPosition(eb:GetNumLetters())
        end)

        -- Keep the editbox hit-rect aligned with the visible scroll area as
        -- the user scrolls vertically, otherwise clicks outside the visible
        -- region land on hidden text.
        scroll:HookScript("OnVerticalScroll", function(self, offset)
            eb:SetHitRectInsets(0, 0, offset, eb:GetHeight() - offset - self:GetHeight())
        end)

        -- Auto-scroll to keep the cursor in view as the user moves it.
        eb:SetScript("OnCursorChanged", function(_, _, y, _, cursorHeight)
            local sf = scroll
            local cy = -y
            local off = sf:GetVerticalScroll()
            if cy < off then
                sf:SetVerticalScroll(cy)
            else
                cy = cy + cursorHeight - sf:GetHeight()
                if cy > off then
                    sf:SetVerticalScroll(cy)
                end
            end
        end)

        eb:SetScript("OnEscapePressed", function()
            f:Hide()
        end)
        eb:SetScript("OnEditFocusLost", function(self)
            self:HighlightText(0, 0)
        end)

        -- Vertical scrollbar on the right.
        local sbar = CreateFrame("Slider", nil, scroll, "UIPanelScrollBarTemplate")
        sbar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 4, -16)
        sbar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 4, 16)
        sbar:SetMinMaxValues(0, 0)
        sbar:SetValueStep(20)
        sbar:SetValue(0)
        sbar:SetWidth(16)
        sbar:SetScript("OnValueChanged", function(_, value)
            scroll:SetVerticalScroll(value)
        end)
        scroll:HookScript("OnVerticalScroll", function(_, offset)
            sbar:SetValue(offset)
        end)
        scroll:HookScript("OnScrollRangeChanged", function(_, _, yrange)
            sbar:SetMinMaxValues(0, yrange)
        end)
        scroll:EnableMouseWheel(true)
        scroll:SetScript("OnMouseWheel", function(_, delta)
            local cur = scroll:GetVerticalScroll()
            scroll:SetVerticalScroll(math.max(0, math.min(select(2, sbar:GetMinMaxValues()), cur - delta * 40)))
        end)

        f.EditBox = eb
        f.ScrollFrame = scroll
    end
    f.TitleText:SetText(titleText or "EmpireManager DEBUG")
    -- Show BEFORE filling. A multiline EditBox inside a ScrollFrame does not lay
    -- out while hidden, so text set first leaves the scroll child at zero height
    -- and the window renders empty. CreateFrame returns a shown frame, so only
    -- the first call ever worked - every reopen after a close came up blank.
    f:Show()
    f.EditBox:SetText(text or "")
    f.EditBox:SetTextColor(1, 1, 1, 1)
    f.EditBox:HighlightText(0, 0)
    f.EditBox:SetCursorPosition(0)
    f.ScrollFrame:SetVerticalScroll(0)
end

-- Apply the clampToScreen option to all addon windows at runtime.
-- Frames created from XML default to clamped=true; this toggles them all at once.
EmpireManager.CLAMPED_FRAMES = {
    "EmpireManagerFrame",
    "EmpireManagerSidecar",
    "EmpireManagerStorageDialog",
    "EmpireManagerIOFrame",
    "EmpireManagerWizardFrame",
    "EmpireManagerTriageFrame",
    "EmpireManagerMailDialog",
    "EmpireManagerRemapDialog",
    "EmpireManagerKeeplistWindow",
    "EmpireManagerVendorlistWindow",
    "EmpireManagerGuildBlacklistWindow",
    "EmpireManagerCharBlacklistWindow",
}
function EmpireManager:UpdateClampToScreen()
    local clamp = self.db.global.options.clampToScreen
    for _, name in ipairs(self.CLAMPED_FRAMES) do
        local f = _G[name]
        if f and f.SetClampedToScreen then
            f:SetClampedToScreen(clamp)
        end
    end
end

-- Lazy trigger stubs: only do work when the relevant window opens

-- Scan bags 0-5 for `hasLoot` items (right-click-opens-a-loot-window boxes) and
-- print a [Hint] line listing any new ones since the last announcement. Session-
-- scoped dedup via `self._hintedOpenables` so the same chest doesn't re-announce
-- after every BAG_UPDATE_DELAYED.
function EmpireManager:HintOpenableContainers()
    self._hintedOpenables = self._hintedOpenables or {}
    local order, counts, linkByID = {}, {}, {}
    for bag = 0, 5 do
        local slots = C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            -- `hasLoot` is also true for LOCKED lockboxes (Umbral Tin Lockbox,
            -- etc.) - but those can't be right-clicked open; they need a key or a
            -- Rogue/Lockpicker. Excluding `isLocked` keeps the hint honest (locked
            -- boxes route to the Lockpicker via triage's isLockbox flag instead).
            if
                info
                and info.hasLoot
                and not info.isLocked
                and info.itemID
                and not self._hintedOpenables[info.itemID]
            then
                if not counts[info.itemID] then
                    order[#order + 1] = info.itemID
                    linkByID[info.itemID] = info.hyperlink
                end
                counts[info.itemID] = (counts[info.itemID] or 0) + 1
            end
        end
    end
    if #order == 0 then
        return
    end
    local parts = {}
    for _, id in ipairs(order) do
        local qty = counts[id]
        parts[#parts + 1] = qty > 1 and (linkByID[id] .. " x" .. qty) or linkByID[id]
        self._hintedOpenables[id] = true
    end
    self:ChatHint(string.format("|cff4d99ff[Hint]|r Openable containers (right-click): %s", table.concat(parts, ", ")))
end

function EmpireManager:BAG_UPDATE_DELAYED()
    -- Mark bag scan cache stale - RunTriageAsync will re-scan on next call.
    self._bagsDirty = true

    -- Re-check openable containers so freshly looted chests get announced.
    -- Session-scoped dedup inside HintOpenableContainers prevents spam.
    self:HintOpenableContainers()

    -- Update free bag slots snapshot. Gold is handled by PLAYER_MONEY.
    local guid = self.playerGUID
    local entry = self.db.global.registry[guid]
    if entry then
        local free, total = 0, 0
        for bag = 0, 4 do
            local slots = C_Container.GetContainerNumSlots(bag)
            total = total + slots
            free = free + C_Container.GetContainerNumFreeSlots(bag)
        end
        entry.freeBagSlots = free
        entry.totalBagSlots = total
        if self.RefreshVisibleRows then
            self:RefreshVisibleRows()
        end
    end

    -- Debounced triage refresh: resets on each bag event, fires 0.3s after last change
    if self._bagRefreshTimer then
        self._bagRefreshTimer:Cancel()
    end
    self._bagRefreshTimer = C_Timer.NewTimer(0.3, function()
        self._bagRefreshTimer = nil
        self:SendMessage("EM_TRIAGE_REFRESH")
    end)

    -- While the bank is open, rescan capacity so the Storage tab tracks
    -- deposits/withdrawals live. Cheap (~600 reads), runs at most once per
    -- BAG_UPDATE_DELAYED event (already coalesced by the client).
    if self.bankIsOpen then
        self:RefreshBankCapacity()
    end
    -- Also re-snapshot the per-item counts that feed the Restock tab's Fill
    -- column, and refresh the tab. Covers manual drag-out from warband/char
    -- bank and Triage Take Out: the bank stayed open, only bags changed, so
    -- the ledger was stale until the bank got closed and reopened.
    -- Guild bank is deliberately skipped here: SnapshotGuildBank does a full
    -- multi-tab query with server round-trips (~300ms + QueryGuildBankTab per
    -- tab), too expensive to fire on every BAG_UPDATE_DELAYED. Guild-bank
    -- restock deposits already re-snapshot in ExecuteRestockPlan's completion
    -- callback; manual guild-bank withdrawals stay stale until close/reopen.
    if self.bankIsOpen then
        self:SnapshotBankItemCounts()
        self:SnapshotBagItemCounts()
        if self.RefreshRestockTab then
            self:RefreshRestockTab()
        end
    end
end

function EmpireManager:PLAYER_GUILD_UPDATE()
    local guid = self.playerGUID
    local entry = self.db.global.registry[guid]
    if not entry then
        return
    end
    local guildName, _, _, guildRealm = GetGuildInfo("player")
    entry.guild = guildName or ""
    if entry.guild == "" then
        entry.guildRealm = nil
        return
    end
    -- Same logic as OnEnable: only write when the 4th return is non-nil. If
    -- it's nil here too (after a delay) the guild realm genuinely matches the
    -- player's realm, so use the player's normalized realm.
    if guildRealm then
        entry.guildRealm = guildRealm
    elseif not entry.guildRealm then
        entry.guildRealm = GetNormalizedRealmName()
    end
    self:PropagateGuildRealmToRules(entry.guild, entry.guildRealm)
end

function EmpireManager:TRADE_SKILL_SHOW()
    local guid = self.playerGUID
    local entry = self.db.global.registry[guid]
    if not entry then
        return
    end

    -- Re-snapshot professions (may have changed since login)
    self:SnapshotProfessions(entry)

    -- Snapshot per-expansion skill breakdown for the open profession
    self:SnapshotExpansionSkills(entry)

    self:RefreshAfterProfessionChange(guid)
end

-- Build a stable signature of the current GetProfessions() result.
-- Used to skip redundant snapshots when SKILL_LINES_CHANGED fires spuriously.
local function ProfessionSignature()
    local parts = {}
    local prof1, prof2, archaeology, fishing, cooking = GetProfessions()
    for _, idx in pairs({ prof1, prof2, archaeology, fishing, cooking }) do
        if idx then
            local name = GetProfessionInfo(idx)
            if name then
                parts[#parts + 1] = name
            end
        end
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

-- SKILL_LINES_CHANGED catches profession unlearn (no tradeskill window opens).
-- The event also fires on learn, level-up, and other skill changes, so we cheap-
-- compare a profession-name signature to skip redundant work.
function EmpireManager:SKILL_LINES_CHANGED()
    local guid = self.playerGUID
    local entry = self.db.global.registry[guid]
    if not entry then
        return
    end
    local sig = ProfessionSignature()
    if sig == self._lastProfSignature then
        return
    end
    self._lastProfSignature = sig

    self:SnapshotProfessions(entry)
    self:RefreshAfterProfessionChange(guid)
end

-- Fires for party/raid members too, so filter to the player.
function EmpireManager:PLAYER_SPECIALIZATION_CHANGED(_, unit)
    if unit ~= "player" then
        return
    end
    local guid = self.playerGUID
    local entry = self.db.global.registry[guid]
    if not entry then
        return
    end
    local old = entry.spec
    self:SnapshotSpec(entry)
    if entry.spec ~= old then
        self:RefreshAfterProfessionChange(guid)
    end
end

-- Refresh UIs that depend on entry.professions. Called from TRADE_SKILL_SHOW
-- and SKILL_LINES_CHANGED so the Auto button + dashboard prof tags update
-- without a /reload.
function EmpireManager:RefreshAfterProfessionChange(guid)
    if EmpireManagerSidecar and EmpireManagerSidecar:IsShown() and self.sidecarGUID == guid then
        EmpireManagerSidecar:Populate(guid)
    end
    if self.RefreshVisibleRows then
        self:RefreshVisibleRows()
    end
end

-- Decide whether the current character's bag gold is outside its Withdraw/Deposit
-- amounts (per-character, db.char). Returns "deposit"|"withdraw", amount (copper),
-- or nil when nothing is needed. Withdraw is capped by what the warband pool holds.
function EmpireManager:ComputeWarbandGoldTransfer()
    local low = self.db.char.goldLow or 0
    local high = self.db.char.goldHigh or 0
    if low <= 0 and high <= 0 then
        return nil
    end
    local bagGold = GetMoney()
    if high > 0 and bagGold > high then
        return "deposit", bagGold - high
    elseif low > 0 and bagGold < low then
        local pool = self.db.global.warbandGold or 0
        local amount = math.min(low - bagGold, pool)
        if amount > 0 then
            return "withdraw", amount
        end
    end
    return nil
end

-- Move gold to/from warband gold via C_Bank, then re-snapshot the pool.
function EmpireManager:ExecuteWarbandGoldTransfer(dir, amount)
    if not (C_Bank and Enum and Enum.BankType) or not amount or amount <= 0 then
        return
    end
    local bt = Enum.BankType.Account
    if C_Bank.DoesBankTypeSupportMoneyTransfer and not C_Bank.DoesBankTypeSupportMoneyTransfer(bt) then
        return
    end
    if dir == "deposit" then
        if C_Bank.CanDepositMoney and not C_Bank.CanDepositMoney(bt) then
            return
        end
        C_Bank.DepositMoney(bt, amount)
        self:ChatMsg(string.format("Moved %s from bags to the Warband Bank.", self:FormatGold(amount)), true)
    elseif dir == "withdraw" then
        if C_Bank.CanWithdrawMoney and not C_Bank.CanWithdrawMoney(bt) then
            return
        end
        C_Bank.WithdrawMoney(bt, amount)
        self:ChatMsg(string.format("Moved %s from the Warband Bank to bags.", self:FormatGold(amount)), true)
    end
    if C_Bank.FetchDepositedMoney then
        local wb = C_Bank.FetchDepositedMoney(bt)
        if wb then
            self.db.global.warbandGold = wb
        end
    end
end

-- Called on warband bank open: if the character is out of its gold range, either
-- transfer silently (auto option on) or ask first with an OK/Cancel dialog.
function EmpireManager:MaybeWarbandGoldTransfer()
    local dir, amount = self:ComputeWarbandGoldTransfer()
    if not dir then
        return
    end
    if self.db.global.options.autoTransferGold then
        self:ExecuteWarbandGoldTransfer(dir, amount)
    else
        local text = (dir == "deposit")
                and string.format("Move %s from bags to the Warband Bank?", self:FormatGold(amount))
            or string.format("Move %s from the Warband Bank to bags?", self:FormatGold(amount))
        local dialog = StaticPopup_Show("EM_GOLD_TRANSFER_CONFIRM", text)
        if dialog then
            dialog.data = { dir = dir, amount = amount }
        end
    end
end

function EmpireManager:BANKFRAME_OPENED()
    self.bankIsOpen = true

    -- Snapshot warband bank gold (account-level, shared across all alts).
    -- Only snapshot when the warband bank is actually accessible: any warband
    -- container (12-16) with slots, or an explicit AccountBanker interaction.
    local warbandAccessible = false
    if
        C_PlayerInteractionManager
        and C_PlayerInteractionManager.IsInteractingWithNpcOfType
        and C_PlayerInteractionManager.IsInteractingWithNpcOfType(Enum.PlayerInteractionType.AccountBanker)
    then
        warbandAccessible = true
    else
        for bag = 12, 16 do
            if (C_Container.GetContainerNumSlots(bag) or 0) > 0 then
                warbandAccessible = true
                break
            end
        end
    end
    if warbandAccessible and C_Bank and C_Bank.FetchDepositedMoney and Enum and Enum.BankType then
        local wbGold = C_Bank.FetchDepositedMoney(Enum.BankType.Account)
        if wbGold then
            self.db.global.warbandGold = wbGold
        end
    end

    -- Auto-balance this character's bag gold against the warband pool (per-char
    -- amounts in Sidecar > Gold). Runs only when the warband bank is reachable.
    if warbandAccessible then
        self:MaybeWarbandGoldTransfer()
    end

    -- Refresh triage tab visibility + deposit button immediately so the UI
    -- reacts without waiting for the capacity snapshot chain to finish.
    if self.triageFrame and self.triageFrame:IsShown() then
        if self.UpdateTriageTabButtons then
            self:UpdateTriageTabButtons()
        end
        if self.UpdateDepositBtnState then
            self:UpdateDepositBtnState()
        end
    end

    -- Fire the popup trigger early, BEFORE the capacity snapshot chain.
    -- Otherwise: replacement bank UIs like Baganator immediately call
    -- CloseBankFrame() to hide Blizzard's frame, which fires BANKFRAME_CLOSED
    -- and flips bankIsOpen back to false. Our chunked ProcessChunk aborts mid-
    -- scan and EM_BANK_OPENED never fires -> popup never appears. Running the
    -- bag scan up-front is safe since it only reads the player's bags.
    self:RunTriageAsync(function(bagResults)
        local bagActionable = 0
        for _, r in ipairs(bagResults) do
            if r.category ~= "KEEP" then
                bagActionable = bagActionable + 1
            end
        end
        self:SendMessage("EM_BANK_OPENED", bagActionable)
    end)

    -- Snapshot per-item bank counts for the Restock fill column SYNCHRONOUSLY and
    -- up-front. Must not depend on the chunked capacity scan finishing: replacement
    -- bank UIs (Baganator) call CloseBankFrame() immediately, flipping bankIsOpen
    -- false mid-scan, so a tail write there would be skipped. Cheap (sub-ms).
    self:SnapshotBankItemCounts()

    -- Snapshot bank capacity using slot-level chunked C_Timer processing.
    -- Scans SLOTS_PER_CHUNK slots per frame to stay well under the 16ms budget.
    local SLOTS_PER_CHUNK = 20

    local guid = self.playerGUID
    local cap = self.db.global.storageCapacity
    if not cap.charbank[guid] then
        cap.charbank[guid] = {}
    end

    -- Build flat work list of individual slots across all bank containers
    local slots = {} -- { {bag, slot, type, tabIdx} ... }
    -- Character bank tabs (container IDs 6-11)
    for tabIdx = 1, 6 do
        local bag = tabIdx + 5
        local numSlots = C_Container.GetContainerNumSlots(bag)
        if numSlots and numSlots > 0 then
            for slot = 1, numSlots do
                slots[#slots + 1] = { bag = bag, slot = slot, type = "charbank", tabIdx = tabIdx, numSlots = numSlots }
            end
        end
    end
    -- Warband bank tabs (container IDs 12-16, AccountBankTab_1..5)
    local warbandTabIdx = 0
    for bag = 12, 16 do
        local numSlots = C_Container.GetContainerNumSlots(bag)
        if numSlots and numSlots > 0 then
            warbandTabIdx = warbandTabIdx + 1
            for slot = 1, numSlots do
                slots[#slots + 1] =
                    { bag = bag, slot = slot, type = "warbandbank", tabIdx = warbandTabIdx, numSlots = numSlots }
            end
        end
    end

    -- Accumulator: { [type_tabIdx] = { total = N, used = N } }
    -- (Per-item Restock counts are captured synchronously up-front by
    -- SnapshotBankItemCounts, not here, so a mid-scan bank close can't lose them.)
    local accum = {}
    local cursor = 0
    local selfRef = self

    local function ProcessChunk()
        if not selfRef.bankIsOpen then
            return
        end -- bank closed, abort
        local limit = math.min(cursor + SLOTS_PER_CHUNK, #slots)
        for i = cursor + 1, limit do
            local s = slots[i]
            local key = s.type .. "_" .. s.tabIdx
            if not accum[key] then
                accum[key] = { total = s.numSlots, used = 0, type = s.type, tabIdx = s.tabIdx }
            end
            local info = C_Container.GetContainerItemInfo(s.bag, s.slot)
            if info then
                accum[key].used = accum[key].used + 1
            end
        end
        cursor = limit

        if cursor < #slots then
            C_Timer.After(0, ProcessChunk) -- next frame
            return
        end

        -- All slots scanned - write results
        for _, data in pairs(accum) do
            if data.type == "charbank" then
                cap.charbank[guid][data.tabIdx] = { total = data.total, used = data.used }
            else
                cap.warbandbank[data.tabIdx] = { total = data.total, used = data.used }
            end
        end

        -- Capacity changed -> drop cached triage classifications so overflow
        -- routing (HasFreeCapacity) reflects fresh fill levels on next scan.
        selfRef:InvalidateStorageCache()

        local freeBank, totalBank, charTabs = 0, 0, 0
        for _, tabData in pairs(cap.charbank[guid] or {}) do
            if type(tabData) == "table" then
                local t = tabData.total or 0
                freeBank = freeBank + t - (tabData.used or 0)
                totalBank = totalBank + t
                charTabs = charTabs + 1
            end
        end
        cap.charbank[guid]._scannedAt = time()
        local entry = selfRef.db.global.registry[guid]
        if entry then
            entry.freeBankSlots = freeBank
            entry.totalBankSlots = totalBank
        end

        local freeWB, totalWB, wbTabs = 0, 0, 0
        for _, tabData in pairs(cap.warbandbank or {}) do
            if type(tabData) == "table" then
                local t = tabData.total or 0
                freeWB = freeWB + t - (tabData.used or 0)
                totalWB = totalWB + t
                wbTabs = wbTabs + 1
            end
        end
        cap.warbandbank._scannedAt = time()

        selfRef:ChatVerbose(
            string.format(
                "|cff4d99ff[Storage]|r Character Bank: %d tab%s, %d/%d free; Warband Bank: %d tab%s, %d/%d free",
                charTabs,
                charTabs == 1 and "" or "s",
                freeBank,
                totalBank,
                wbTabs,
                wbTabs == 1 and "" or "s",
                freeWB,
                totalWB
            )
        )

        -- Upgrade hint: unpurchased bank tabs (once per login)
        if not selfRef._bankUpgradeHintShown then
            selfRef._bankUpgradeHintShown = true
            local hints = {}
            -- Character bank tabs (containers 6-11) - skip in warband-only mode
            if not selfRef:IsWarbandBankOnly() then
                local unpurchasedChar = 0
                for tabIdx = 1, 6 do
                    local numSlots = C_Container.GetContainerNumSlots(tabIdx + 5)
                    if not numSlots or numSlots == 0 then
                        unpurchasedChar = unpurchasedChar + 1
                    end
                end
                if unpurchasedChar > 0 then
                    hints[#hints + 1] =
                        string.format("%d character Bank Tab%s", unpurchasedChar, unpurchasedChar == 1 and "" or "s")
                end
            end
            -- Warband bank tabs (containers 12-16)
            local unpurchasedWarband = 0
            for bag = 12, 16 do
                local numSlots = C_Container.GetContainerNumSlots(bag)
                if not numSlots or numSlots == 0 then
                    unpurchasedWarband = unpurchasedWarband + 1
                end
            end
            if unpurchasedWarband > 0 then
                hints[#hints + 1] =
                    string.format("%d Warband Bank Tab%s", unpurchasedWarband, unpurchasedWarband == 1 and "" or "s")
            end
            if #hints > 0 then
                selfRef:ChatHint("|cff4d99ff[Hint]|r Unpurchased: " .. table.concat(hints, ", "))
            end
        end

        -- Bag triage / EM_BANK_OPENED was fired up-front (see top of function)
        -- so the popup works even when replacement UIs close Blizzard's bank
        -- frame mid-snapshot. Nothing to do here after capacity is written.
    end

    ProcessChunk()
    self:SnapshotBagItemCounts()

    -- Bank Restock top-up (Stage B). Delay briefly so bank containers are fully
    -- populated before we read live counts. Reads live container counts, not the
    -- snapshot, so it is independent of the chunked capacity scan above.
    C_Timer.After(0.6, function()
        if self.bankIsOpen then
            self:MaybeRestock()
        end
    end)
end

-- Set of itemIDs any restock rule cares about. The fill column only ever reads
-- these, so the snapshots below tally nothing else - storing every item in every
-- bank made restockCounts the second-largest table in SavedVariables for data
-- that was never read.
function EmpireManager:GetRestockItemIDs()
    local want = {}
    for _, rule in ipairs(self.db.global.restockList or {}) do
        if rule.itemID then
            want[rule.itemID] = true
        end
    end
    return want
end

-- Destination keys the fill column can actually read: only the shared banks a
-- rule points at, and only the characters a charbank/bags rule names. Counts for
-- any other destination are written but never looked up.
function EmpireManager:GetRestockDestKeys()
    local keys = {}
    for _, rule in ipairs(self.db.global.restockList or {}) do
        if rule.dest == "warbandbank" then
            keys["warbandbank"] = true
        elseif rule.dest == "guildbank" and rule.guild then
            keys["guildbank:" .. self:GuildKey(rule.guild, rule.realm)] = true
        elseif rule.dest == "charbank" or rule.dest == "bags" then
            local prefix = (rule.dest == "bags") and "bags:" or "charbank:"
            local chars = rule.chars or (rule.char and { rule.char } or {})
            for _, guid in ipairs(chars) do
                keys[prefix .. guid] = true
            end
        end
    end
    return keys
end

-- Snapshot per-item counts in the currently open bank containers into
-- db.global.restockCounts, for the Restock fill column. Warband is account-shared
-- (single key); char bank is keyed per owning character. Reads only containers that
-- actually have slots, so it is safe to call regardless of which bank type is open.
-- Synchronous (sub-ms); call up-front so a mid-scan bank close can't lose the data.
function EmpireManager:SnapshotBankItemCounts()
    local guid = self.playerGUID
    if not guid then
        return
    end
    local counts = self.db.global.restockCounts
    if not counts then
        counts = {}
        self.db.global.restockCounts = counts
    end

    local want = self:GetRestockItemIDs()

    -- Character bank: containers 6-11.
    local charTally, sawChar = {}, false
    for bag = 6, 11 do
        local numSlots = C_Container.GetContainerNumSlots(bag) or 0
        if numSlots > 0 then
            sawChar = true
            for slot = 1, numSlots do
                local info = C_Container.GetContainerItemInfo(bag, slot)
                if info and info.itemID and want[info.itemID] then
                    charTally[info.itemID] = (charTally[info.itemID] or 0) + (info.stackCount or 1)
                end
            end
        end
    end
    if sawChar then
        counts["charbank:" .. guid] = charTally
    end

    -- Warband bank: containers 12-16 (account-shared).
    local wbTally, sawWb = {}, false
    for bag = 12, 16 do
        local numSlots = C_Container.GetContainerNumSlots(bag) or 0
        if numSlots > 0 then
            sawWb = true
            for slot = 1, numSlots do
                local info = C_Container.GetContainerItemInfo(bag, slot)
                if info and info.itemID and want[info.itemID] then
                    wbTally[info.itemID] = (wbTally[info.itemID] or 0) + (info.stackCount or 1)
                end
            end
        end
    end
    if sawWb then
        counts["warbandbank"] = wbTally
    end
end

-- Snapshot the current character's bag item counts (bags 0-5) into
-- db.global.restockCounts["bags:<guid>"], for the Restock fill column on
-- "Character Bags" entries. Cheap synchronous read; safe to call any time.
function EmpireManager:SnapshotBagItemCounts()
    local guid = self.playerGUID
    if not guid then
        return
    end
    local want = self:GetRestockItemIDs()
    local tally = {}
    for bag = 0, 5 do
        local numSlots = C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, numSlots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID and want[info.itemID] then
                tally[info.itemID] = (tally[info.itemID] or 0) + (info.stackCount or 1)
            end
        end
    end
    local counts = self.db.global.restockCounts
    if not counts then
        counts = {}
        self.db.global.restockCounts = counts
    end
    counts["bags:" .. guid] = tally
end

-- Live count of an itemID in the current character's bags (bags 0-5). Used by the
-- restock engine to decide how many to deposit. Synchronous, sub-ms.
function EmpireManager:CountItemInBags(itemID)
    if not itemID then
        return 0
    end
    return C_Item.GetItemCount(itemID, false, false, true, false) or 0
end

-- Lightweight live rescan of character + warband bank capacity. Synchronous;
-- runs only while the bank is open. ~600 cheap C_Container reads, sub-ms.
-- Used to keep Storage tab fill levels in sync with deposits/withdrawals
-- without waiting for the next bank open.
function EmpireManager:RefreshBankCapacity()
    if not self.bankIsOpen then
        return
    end
    local guid = self.playerGUID
    local cap = self.db.global.storageCapacity
    if not cap.charbank[guid] then
        cap.charbank[guid] = {}
    end

    -- Character bank tabs (container IDs 6-11)
    for tabIdx = 1, 6 do
        local bag = tabIdx + 5
        local numSlots = C_Container.GetContainerNumSlots(bag) or 0
        if numSlots > 0 then
            local used = 0
            for slot = 1, numSlots do
                if C_Container.GetContainerItemInfo(bag, slot) then
                    used = used + 1
                end
            end
            cap.charbank[guid][tabIdx] = { total = numSlots, used = used }
        end
    end

    -- Warband bank tabs (container IDs 12-16)
    local wbIdx = 0
    for bag = 12, 16 do
        local numSlots = C_Container.GetContainerNumSlots(bag) or 0
        if numSlots > 0 then
            wbIdx = wbIdx + 1
            local used = 0
            for slot = 1, numSlots do
                if C_Container.GetContainerItemInfo(bag, slot) then
                    used = used + 1
                end
            end
            cap.warbandbank[wbIdx] = { total = numSlots, used = used }
        end
    end

    cap.charbank[guid]._scannedAt = time()
    cap.warbandbank._scannedAt = time()

    -- Roll up totals onto the registry entry (used by dashboard "free/total").
    local freeBank, totalBank = 0, 0
    for _, tabData in pairs(cap.charbank[guid] or {}) do
        if type(tabData) == "table" then
            local t = tabData.total or 0
            freeBank = freeBank + t - (tabData.used or 0)
            totalBank = totalBank + t
        end
    end
    local entry = self.db.global.registry[guid]
    if entry then
        entry.freeBankSlots = freeBank
        entry.totalBankSlots = totalBank
    end

    -- Capacity changed -> drop cached triage classifications so overflow
    -- routing (HasFreeCapacity) reflects fresh fill levels on next scan.
    self:InvalidateStorageCache()

    -- Repaint the Storage tab if it's the active page.
    local frame = EmpireManagerFrame
    if frame and frame.StoragePage and frame.StoragePage:IsShown() and frame.StoragePage.Refresh then
        frame.StoragePage:Refresh()
    end
end

function EmpireManager:BANKFRAME_CLOSED()
    self.bankIsOpen = false
    self:SendMessage("EM_BANK_CLOSED")
end

-- Dispatcher for PLAYER_INTERACTION_MANAGER_FRAME_SHOW (replaces dead GUILDBANKFRAME events)
local INTERACTION_GUILD_BANK = 10
local INTERACTION_ACCOUNT_BANKER = 68
local INTERACTION_MAIL = 17
function EmpireManager:PLAYER_INTERACTION_MANAGER_FRAME_SHOW(_, interactionType)
    if interactionType == INTERACTION_GUILD_BANK then
        self.guildBankIsOpen = true
        self._guildBankSnapshotDone = false
        self.MoveContexts.guildbank._currentTab = nil -- reset cached tab
        -- Refresh triage tab visibility + deposit button immediately so the UI
        -- reacts without waiting for the snapshot chain to finish.
        if self.triageFrame and self.triageFrame:IsShown() then
            if self.UpdateTriageTabButtons then
                self:UpdateTriageTabButtons()
            end
            if self.UpdateDepositBtnState then
                self:UpdateDepositBtnState()
            end
        end
        -- Fast path: tab metadata is often cached client-side, so try the
        -- snapshot immediately. SnapshotGuildBank returns early if data isn't
        -- ready; the GUILDBANK_UPDATE_TABS event handler will catch that case.
        self:SnapshotGuildBank()
        -- Safety net: if neither the immediate call nor the event populates
        -- tab data within 1.5s, force one more attempt.
        C_Timer.After(1.5, function()
            if self.guildBankIsOpen and not self._guildBankSnapshotDone then
                self:SnapshotGuildBank()
            end
        end)
    elseif interactionType == INTERACTION_ACCOUNT_BANKER then
        -- Warband bank opened (possibly remotely via Distance Inhibitor).
        -- other addons may suppress BANKFRAME_OPENED, so handle it here.
        if not self.bankIsOpen then
            self.bankIsOpen = true
            self:BANKFRAME_OPENED()
        end
    end
end
function EmpireManager:PLAYER_INTERACTION_MANAGER_FRAME_HIDE(_, interactionType)
    if interactionType == INTERACTION_GUILD_BANK then
        self.guildBankIsOpen = false
        self._guildBankSnapshotDone = false
        self:SendMessage("EM_BANK_CLOSED")
    elseif interactionType == INTERACTION_ACCOUNT_BANKER then
        if self.bankIsOpen then
            self.bankIsOpen = false
            self:SendMessage("EM_BANK_CLOSED")
        end
    elseif interactionType == INTERACTION_MAIL then
        if self.mailboxOpen then
            self.mailboxOpen = false
            self:SendMessage("EM_MAIL_CLOSED")
            C_Timer.After(0, function()
                self:SendMessage("EM_MAIL_BTN_UPDATE")
            end)
        end
    end
end

-- Fires when guild bank tab data is loaded from the server.
-- Registered permanently in OnEnable (like Blizzard's GuildBankFrame).
function EmpireManager:GUILDBANK_UPDATE_TABS()
    if not self.guildBankIsOpen then
        return
    end
    self:SnapshotGuildBank()
end

-- Idempotent guild bank snapshot - only runs once per open.
-- Queries each tab sequentially (waiting for GUILDBANKBAGSLOTS_CHANGED) so
-- item links are actually loaded before we count used slots. Without the
-- query, only the currently-visible tab reports data and all others read 0%.
function EmpireManager:SnapshotGuildBank()
    if self._guildBankSnapshotDone then
        return
    end

    local guildName, _, _, guildRealm = GetGuildInfo("player")
    if not guildName or guildName == "" then
        return
    end
    local guildKey = self:GuildKey(guildName, guildRealm or GetRealmName())
    if not guildKey then
        return
    end

    local numTabs = GetNumGuildBankTabs()
    if not numTabs or numTabs == 0 then
        return
    end -- data not ready yet

    self._guildBankSnapshotDone = true

    local cap = self.db.global.storageCapacity
    local selfRef = self

    local GUILD_BANK_TAB_SLOTS = 98 -- standard guild bank tab: 14 columns x 7 rows

    -- Build the list of viewable purchased tabs. A tab is purchased only when it has
    -- a non-empty name (numSlots is unreliable: returns bogus 100000 for purchased
    -- tabs and sometimes non-zero for unpurchased ones). isViewable filters out tabs
    -- this character lacks permission to see - querying those triggers "You don't
    -- have permission" spam and yields bogus 0/98 capacity data that would overwrite
    -- a valid snapshot taken from a character with full access.
    local purchasedTabs = {}
    local hiddenTabs = 0
    for tab = 1, numTabs do
        local name, _, isViewable = GetGuildBankTabInfo(tab)
        if name and name ~= "" then
            if isViewable then
                purchasedTabs[#purchasedTabs + 1] = tab
            else
                hiddenTabs = hiddenTabs + 1
            end
        end
    end

    if #purchasedTabs == 0 then
        if hiddenTabs > 0 then
            self:ChatVerbose(
                string.format(
                    "|cff4d99ff[Storage]|r Skipped Guild Bank snapshot for <%s>: no viewable tabs.",
                    guildName
                )
            )
        end
        self:SendMessage("EM_TRIAGE_REFRESH")
        return
    end

    -- Wipe stale tab entries only for tabs we can actually see; preserve data
    -- from other characters' snapshots for tabs hidden from this character.
    if not cap.guildbank[guildKey] then
        cap.guildbank[guildKey] = {}
    end
    local guildCap = cap.guildbank[guildKey]
    for _, tab in ipairs(purchasedTabs) do
        guildCap[tab] = nil
    end

    -- Per-item tally for the Restock fill column and the engine's count read.
    -- Rebuilt from the viewable tabs each scan.
    local guildItemTally = {}

    local listener = self:AcquireListener()
    local finished = false
    local globalTimer
    local eventCount = 0

    local function FinishSnapshot()
        if finished then
            return
        end
        finished = true
        if globalTimer then
            globalTimer:Cancel()
            globalTimer = nil
        end
        selfRef:ReleaseListener(listener)

        local freeGB, totalGB = 0, 0
        for _, tabData in pairs(guildCap or {}) do
            if type(tabData) == "table" then
                local t = tabData.total or 0
                freeGB = freeGB + t - (tabData.used or 0)
                totalGB = totalGB + t
            end
        end
        guildCap._scannedAt = time()

        -- Commit the per-item tally for the Restock fill column (display-only).
        local counts = selfRef.db.global.restockCounts
        if not counts then
            counts = {}
            selfRef.db.global.restockCounts = counts
        end
        counts["guildbank:" .. guildKey] = guildItemTally

        selfRef:ChatVerbose(
            string.format(
                "|cff4d99ff[Storage]|r Guild Bank %d tab%s, %d/%d free",
                #purchasedTabs,
                #purchasedTabs == 1 and "" or "s",
                freeGB,
                totalGB
            )
        )

        -- Capacity changed -> drop cached triage classifications so overflow
        -- routing (HasFreeCapacity) reflects fresh fill levels on next scan.
        selfRef:InvalidateStorageCache()

        -- Chain: bag scan (deposits into GB) → bank scan (takeouts from GB) → open triage if needed.
        -- All scans share a single async slot so they must run sequentially.
        selfRef:RunTriageAsync(function(bagResults)
            -- Count bag items that need to go INTO this guild bank
            local depositCount = 0
            for _, r in ipairs(bagResults) do
                if r.category == "STASH" and r.routing and r.routing.destType == "guildbank" then
                    depositCount = depositCount + 1
                end
            end

            -- Now run bank scan to find items to take OUT + misplaced notifications
            selfRef:RunBankTriageAsync(function(bankResults)
                local takeoutCount = 0
                local reorganizeCount = 0
                for _, r in ipairs(bankResults) do
                    if r.item.bankType == "guildbank" then
                        if r.category == "TAKEOUT" then
                            takeoutCount = takeoutCount + 1
                        elseif r.category == "STASH" then
                            reorganizeCount = reorganizeCount + 1
                        end
                    end
                end

                selfRef:SendMessage("EM_GUILDBANK_OPENED", depositCount, takeoutCount + reorganizeCount)
            end)
        end)

        selfRef:SendMessage("EM_TRIAGE_REFRESH")

        -- Bank Restock top-up for guild floors. The snapshot above committed the
        -- per-item guild count; run after a short delay so tab data is settled.
        C_Timer.After(0.6, function()
            if selfRef:IsGuildBankOpen() then
                selfRef:MaybeRestock()
            end
        end)
    end

    -- Count filled slots on one tab; event doesn't say which tab fired, so
    -- we re-scan all of them after each event (state is cumulative).
    local function ScanTab(tab)
        local _, _, _, _, numSlots = GetGuildBankTabInfo(tab)
        if not numSlots or numSlots <= 0 or numSlots > GUILD_BANK_TAB_SLOTS then
            numSlots = GUILD_BANK_TAB_SLOTS
        end
        local used = 0
        for slot = 1, numSlots do
            local link = GetGuildBankItemLink(tab, slot)
            if link then
                used = used + 1
                local itemID = C_Item.GetItemInfoInstant(link)
                if itemID then
                    local _, count = GetGuildBankItemInfo(tab, slot)
                    guildItemTally[itemID] = (guildItemTally[itemID] or 0) + (count or 1)
                end
            end
        end
        guildCap[tab] = { total = numSlots, used = used }
    end

    local function ScanAllTabs()
        -- Tally is cumulative within one full pass; reset so re-scans after each
        -- GUILDBANKBAGSLOTS_CHANGED event don't double-count.
        wipe(guildItemTally)
        for _, tab in ipairs(purchasedTabs) do
            ScanTab(tab)
        end
    end

    -- Event handler (registered before any query so nothing is missed).
    listener:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED")
    listener:SetScript("OnEvent", function()
        if finished then
            return
        end
        eventCount = eventCount + 1
        ScanAllTabs()
        if eventCount >= #purchasedTabs then
            FinishSnapshot()
        end
    end)

    -- Global fallback: if some events never fire (cached tabs, empty tabs),
    -- finish after 2s no matter what. Scan-all runs regardless so capacities
    -- reflect whatever the client already has.
    globalTimer = C_Timer.NewTimer(2.0, function()
        globalTimer = nil
        if finished then
            return
        end
        ScanAllTabs()
        FinishSnapshot()
    end)

    -- Fire all queries back-to-back. Server is expected to respond per tab.
    for _, tab in ipairs(purchasedTabs) do
        QueryGuildBankTab(tab)
    end
end

function EmpireManager:MERCHANT_SHOW()
    self:SendMessage("EM_MERCHANT_SHOW")
end

function EmpireManager:MERCHANT_CLOSED()
    self:SendMessage("EM_MERCHANT_CLOSED")
end

function EmpireManager:MAIL_SHOW()
    self.mailboxOpen = true
    self:SendMessage("EM_MAIL_SHOW")

    -- Deferred update so the button picks up the triage scan results that the
    -- EM_MAIL_SHOW handlers kick off. Intentionally no MailFrameTab_OnClick
    -- hook: the send flow is gated on mailboxOpen alone, so which tab the
    -- player is looking at (or whether a replacement mail addon has tabs at
    -- all) is none of our business.
    C_Timer.After(0, function()
        self:SendMessage("EM_MAIL_BTN_UPDATE")
    end)
end

function EmpireManager:MAIL_CLOSED()
    self.mailboxOpen = false
    self:SendMessage("EM_MAIL_CLOSED")
end

function EmpireManager:PLAYER_LEVEL_UP(_, newLevel)
    local guid = self.playerGUID
    local entry = guid and self.db.global.registry[guid]
    if not entry then
        return
    end
    entry.level = tonumber(newLevel) or UnitLevel("player")
    if self.RefreshVisibleRows then
        self:RefreshVisibleRows()
    end
end

function EmpireManager:PLAYER_MONEY()
    -- Defer GetMoney() to the next frame to avoid tainting the same execution
    -- context as Blizzard's MoneyFrame update, which fires in the same event.
    C_Timer.After(0, function()
        local guid = self.playerGUID
        local entry = guid and self.db.global.registry[guid]
        if not entry then
            return
        end
        entry.gold = GetMoney()
        if self.RefreshVisibleRows then
            self:RefreshVisibleRows()
        end
    end)
end

function EmpireManager:PLAYER_EQUIPMENT_CHANGED()
    local guid = self.playerGUID
    local entry = guid and self.db.global.registry[guid]
    if not entry then
        return
    end
    local newIlvl = select(2, GetAverageItemLevel())
    if newIlvl and newIlvl ~= entry.ilvl then
        entry.ilvl = newIlvl
        if self.RefreshVisibleRows then
            self:RefreshVisibleRows()
        end
    end
end

function EmpireManager:PLAYER_ENTERING_WORLD()
    local guid = self.playerGUID
    local entry = self.db.global.registry[guid]
    if not entry then
        return
    end

    -- Trust the game over imported/edited values: level can be wrong (typo, post-import
    -- ding, or out-of-date import). Overwrite unconditionally, even if smaller.
    local liveLevel = UnitLevel("player")
    if liveLevel and liveLevel > 0 then
        entry.level = liveLevel
    end

    -- Snapshot bag item counts so "Character Bags" restock entries show a fill
    -- level for this character without needing a bank open.
    self:SnapshotBagItemCounts()

    -- One-time hint: registry has chars but no storage rules yet.
    if not self.db.global.wizardHintSeen and not self.db.global.wizardSeen then
        local hasRules = #(self.db.global.storageAssignments or {}) > 0
        local hasChars = next(self.db.global.registry) ~= nil
        if hasChars and not hasRules then
            self:ChatMsg(
                "|cffffd100[EmpireManager]|r No storage rules yet. Run |cffffd100/em wizard|r to get started.",
                true
            )
            self.db.global.wizardHintSeen = true
        end
    end

    -- Snapshot location for global registry
    if not entry.mapPinned then
        entry.zone = GetRealZoneText()
        entry.subZone = GetSubZoneText()
        local mapID = C_Map.GetBestMapForUnit("player")
        if mapID then
            entry.mapID = mapID
            local ok, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
            if ok and pos then
                entry.mapX, entry.mapY = pos:GetXY()
            end
        end
    end
end

function EmpireManager:ZONE_CHANGED_NEW_AREA()
    local guid = self.playerGUID
    local entry = self.db.global.registry[guid]
    if entry and not entry.mapPinned then
        entry.zone = GetRealZoneText()
        entry.subZone = GetSubZoneText()
        local mapID = C_Map.GetBestMapForUnit("player")
        if mapID then
            entry.mapID = mapID
            local ok, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
            if ok and pos then
                entry.mapX, entry.mapY = pos:GetXY()
            end
        end
    end
end

-- Snapshot exact logout location (PEW/ZCNA don't fire when moving within a zone).
function EmpireManager:PLAYER_LOGOUT()
    local guid = self.playerGUID
    local entry = guid and self.db.global.registry[guid]
    if entry and not entry.mapPinned then
        entry.zone = GetRealZoneText()
        entry.subZone = GetSubZoneText()
        local mapID = C_Map.GetBestMapForUnit("player")
        if mapID then
            entry.mapID = mapID
            local ok, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
            if ok and pos then
                entry.mapX, entry.mapY = pos:GetXY()
            end
        end
    end
end

function EmpireManager:TIME_PLAYED_MSG(_, totalTime, levelTime)
    local guid = self.playerGUID
    local entry = self.db.global.registry[guid]
    if entry then
        entry.playedTotal = totalTime -- seconds
        entry.playedLevel = levelTime -- seconds
    end
    -- Re-register TIME_PLAYED_MSG on chat frames we silenced for this request.
    self:RestoreTimePlayedChatFrames()
end

-- Suppress chat output for RequestTimePlayed(). Blizzard's chat handler writes the
-- "Total time played" lines directly via TIME_PLAYED_MSG (bypassing CHAT_MSG_SYSTEM),
-- so a chat filter does nothing. Instead, temporarily unregister the event from each
-- chat frame around our request and re-register after our own handler runs.
function EmpireManager:RequestTimePlayedSilent()
    local frames = {}
    for i = 1, NUM_CHAT_WINDOWS do
        local f = _G["ChatFrame" .. i]
        if f and f.IsEventRegistered and f:IsEventRegistered("TIME_PLAYED_MSG") then
            f:UnregisterEvent("TIME_PLAYED_MSG")
            frames[#frames + 1] = f
        end
    end
    self._silentTimePlayedFrames = frames
    RequestTimePlayed()
end

function EmpireManager:RestoreTimePlayedChatFrames()
    local frames = self._silentTimePlayedFrames
    if not frames then
        return
    end
    for _, f in ipairs(frames) do
        if f and f.RegisterEvent then
            f:RegisterEvent("TIME_PLAYED_MSG")
        end
    end
    self._silentTimePlayedFrames = nil
end

-- Snapshot spec (e.g. "Frost", "Shadow"). Stores nil rather than "" when the
-- character has no spec chosen yet, so readers can test entry.spec directly.
function EmpireManager:SnapshotSpec(entry)
    local spec
    local specIdx = GetSpecialization()
    if specIdx then
        spec = select(2, GetSpecializationInfo(specIdx))
    end
    if spec == "" then
        spec = nil
    end
    entry.spec = spec
end

function EmpireManager:SnapshotProfessions(entry)
    -- Preserve existing expansionSkills (populated at TRADE_SKILL_SHOW)
    local oldByName = {}
    if entry.professions then
        for _, p in ipairs(entry.professions) do
            oldByName[p.name] = p
        end
    end

    local profs = {}
    local prof1, prof2, archaeology, fishing, cooking = GetProfessions()
    -- Check each slot individually: a sparse list (e.g. prof1 nil but fishing set)
    -- would be skipped by ipairs, so iterate explicit slots with pairs.
    for _, idx in pairs({ prof1, prof2, archaeology, fishing, cooking }) do
        if idx then
            local name, _, skillLevel, maxSkillLevel, _, _, skillLineID = GetProfessionInfo(idx)
            if name then
                local old = oldByName[name]
                -- Prefer the newest expansion skill snapshot (from opening the profession window)
                -- over GetProfessionInfo, which returns overall tier rank (1/100 style).
                local newest = old and self:NewestExpansionSkill(old) or nil
                if newest then
                    skillLevel = newest.skill
                    maxSkillLevel = newest.maxSkill
                end
                table.insert(profs, {
                    name = name,
                    skill = skillLevel,
                    maxSkill = maxSkillLevel,
                    skillLineID = skillLineID,
                    expansionSkills = old and old.expansionSkills or nil,
                })
            end
        end
    end
    entry.professions = profs
end

-- Snapshot per-expansion skill breakdown for the currently open profession.
-- Only callable during TRADE_SKILL_SHOW (C_TradeSkillUI requires an open window).
function EmpireManager:SnapshotExpansionSkills(entry)
    if not C_TradeSkillUI or not C_TradeSkillUI.GetAllProfessionTradeSkillLines then
        return
    end
    local skillLines = C_TradeSkillUI.GetAllProfessionTradeSkillLines()
    if not skillLines or #skillLines == 0 then
        return
    end

    -- Identify which profession is currently open
    local baseProfInfo = C_TradeSkillUI.GetBaseProfessionInfo and C_TradeSkillUI.GetBaseProfessionInfo()
    if not baseProfInfo or not baseProfInfo.professionName then
        return
    end
    local profName = baseProfInfo.professionName

    -- Find matching entry in entry.professions.
    -- Match on the Enum.Profession, NOT on professionName: the open window reports
    -- the decorated TIER name, which in German is "Schmiedekunst von Midnight" while
    -- the stored row is the bare "Schmiedekunst". English happens to work only
    -- because its form ("Midnight Blacksmithing") keeps the bare name as a suffix.
    -- Falling back to the name keeps pre-skillLineID rows working on English clients.
    if not entry.professions then
        return
    end
    local openKey = baseProfInfo.profession and self.ENUM_PROFESSION_TO_KEY[baseProfInfo.profession] or nil
    local profEntry
    for _, p in ipairs(entry.professions) do
        if openKey then
            local pi = self:ProfInfoFromEntryProf(p)
            if pi and pi.key == openKey then
                profEntry = p
                break
            end
        elseif p.name == profName then
            profEntry = p
            break
        end
    end
    if not profEntry then
        return
    end

    -- Build the per-expansion skill map.
    --
    -- ProfessionInfo does NOT carry a numeric expansionID (see
    -- Blizzard_APIDocumentationGenerated/TradeSkillUITypesDocumentation.lua:
    -- profession/professionID/professionName/expansionName/skillLevel/...). An
    -- earlier version gated rows on `info.expansionID >= 0`, which is always nil,
    -- so EVERY row was dropped and expansionSkills stayed empty on all locales.
    -- Resolve the ID from the localized expansionName instead, and keep the row
    -- even when the name is unknown (displayed under its raw name, sorted last).
    --
    -- `GetAllProfessionTradeSkillLines` returns lines for every profession the
    -- character knows, most with maxSkillLevel 0, so filter on maxSkillLevel > 0.
    local byExpKey = {}
    for _, lineID in ipairs(skillLines) do
        local info = C_TradeSkillUI.GetProfessionInfoBySkillLineID(lineID)
        -- Only lines belonging to the profession whose window is open:
        -- GetAllProfessionTradeSkillLines returns lines for EVERY known profession,
        -- so without this an Engineering line lands in Enchanting's breakdown.
        local lineKey = info and info.profession and self.ENUM_PROFESSION_TO_KEY[info.profession] or nil
        local sameProf = (not openKey) or (lineKey == openKey)
        -- Skip the BASE profession line (no parentProfessionID): it reports the
        -- aggregate total across all expansions ("Unbekannt", e.g. 300/700), which
        -- is not an expansion tier and would render as an "Unknown" row.
        local isTierLine = info and info.parentProfessionID ~= nil
        if info and sameProf and isTierLine and info.skillLevel and info.maxSkillLevel and info.maxSkillLevel > 0 then
            local expName = info.expansionName
            local expID = self:ExpansionIDFromAPIName(expName)
            -- Dedupe by ID when known (parent + child lines share an expansion),
            -- else by name so an unmapped locale still collapses duplicates.
            local key = expID or ("name:" .. tostring(expName or lineID):lower())
            local existing = byExpKey[key]
            if not existing or info.skillLevel > existing.skill then
                byExpKey[key] = {
                    skillLineID = lineID,
                    expansionID = expID,
                    expansionName = expName,
                    skill = info.skillLevel,
                    maxSkill = info.maxSkillLevel,
                }
            end
        end
    end

    local expSkills = {}
    for _, e in pairs(byExpKey) do
        expSkills[#expSkills + 1] = e
    end
    -- Unknown expansions (nil ID) sort last rather than colliding at 999.
    table.sort(expSkills, function(a, b)
        local ai, bi = a.expansionID or 998, b.expansionID or 998
        if ai ~= bi then
            return ai < bi
        end
        return (a.expansionName or "") < (b.expansionName or "")
    end)
    profEntry.expansionSkills = expSkills

    -- Promote newest expansion skill to the top-level skill/maxSkill so UI shows
    -- e.g. 6/105 instead of the overall tier rank (1/100) from GetProfessionInfo.
    if #expSkills > 0 then
        local newest = expSkills[#expSkills]
        profEntry.skill = newest.skill
        profEntry.maxSkill = newest.maxSkill
    end
end

-- Count storage assignments that reference a given character GUID.
function EmpireManager:CountDependentAssignments(guid)
    if not guid or guid == "self" then
        return 0
    end
    local n = 0
    for _, asn in ipairs(self.db.global.storageAssignments or {}) do
        if asn.type == "charbank" and asn.char == guid then
            n = n + 1
        end
    end
    return n
end

-- Return the list of storage assignments that reference a given character GUID.
function EmpireManager:GetDependentAssignments(guid)
    local out = {}
    if not guid or guid == "self" then
        return out
    end
    for i, asn in ipairs(self.db.global.storageAssignments or {}) do
        if asn.type == "charbank" and asn.char == guid then
            out[#out + 1] = { index = i, asn = asn }
        end
    end
    return out
end

StaticPopupDialogs["EM_PURGE_CHAR"] = {
    text = "%s",
    button1 = "Remove",
    button2 = "Cancel",
    OnAccept = function(self)
        local guid = self.data and self.data.guid
        if guid then
            EmpireManager:PurgeByGUID(guid)
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    showAlert = true,
    preferredIndex = 3,
}

StaticPopupDialogs["EM_WIPE_CONFIRM"] = {
    text = "%s",
    button1 = YES,
    button2 = CANCEL,
    OnAccept = function(self)
        local target = self.data and self.data.target
        if target then
            EmpireManager:PerformWipe(target)
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    showAlert = true,
    preferredIndex = 3,
}

StaticPopupDialogs["EM_GOLD_TRANSFER_CONFIRM"] = {
    text = "%s",
    button1 = OKAY,
    button2 = CANCEL,
    OnAccept = function(self)
        local d = self.data
        if d then
            EmpireManager:ExecuteWarbandGoldTransfer(d.dir, d.amount)
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

function EmpireManager:ConfirmWipe(target)
    local text
    if target == "chars" then
        text = "Wipe the entire character roster?\n\n|cffff4444This cannot be undone.|r"
    elseif target == "rules" then
        text = "Wipe all Storage Rules?\n\n|cffff4444This cannot be undone.|r"
    elseif target == "keeplist" then
        text = "Wipe the Keep List?\n\n|cffff4444This cannot be undone.|r"
    elseif target == "vendorw" then
        text = "Wipe the Vendor Whitelist?\n\n|cffff4444This cannot be undone.|r"
    elseif target == "restock" then
        text = "Wipe all Restock Rules?\n\n|cffff4444This cannot be undone.|r"
    elseif target == "all" then
        text = "Wipe |cffff4444everything|r: Storage Rules, Restock Rules, Keep List, Vendor Whitelist, and the Character Roster?\n\n|cffff4444This cannot be undone.|r"
    else
        return
    end
    local dialog = StaticPopup_Show("EM_WIPE_CONFIRM", text)
    if dialog then
        dialog.data = { target = target }
    end
end

-- Repaint the tabs that render wiped data. Each guards itself, so calling all of
-- them is safe regardless of which tab is showing.
function EmpireManager:RefreshRuleTabs()
    local f = EmpireManagerFrame
    if f and f.StoragePage and f.StoragePage._nativeInit then
        f.StoragePage:Refresh()
    end
    if self.RefreshRestockTab then
        self:RefreshRestockTab()
    end
    self:SendMessage("EM_DASHBOARD_REFRESH")
end

function EmpireManager:PerformWipe(target)
    if target == "chars" then
        self.db.global.registry = {}
        self:ChatMsg("|cffff4444Wiped Character Roster.|r", true)
        self:RefreshRuleTabs()
    elseif target == "rules" then
        self.db.global.storageAssignments = {}
        self:ChatMsg("|cffff4444Wiped Storage Rules.|r", true)
        self:InvalidateStorageCache()
        self:RefreshRuleTabs()
    elseif target == "keeplist" then
        self.db.global.keepList = {}
        self:ChatMsg("|cffff4444Wiped Keep List.|r", true)
        if self.RefreshKeeplistDisplay and self.keeplistFrame and self.keeplistFrame:IsShown() then
            self:RefreshKeeplistDisplay()
        end
        self._bagsDirty = true
        if self.RefreshTriageIfOpen then
            self:RefreshTriageIfOpen()
        end
    elseif target == "vendorw" then
        self.db.global.vendorWhitelist = {}
        self:ChatMsg("|cffff4444Wiped Vendor Whitelist.|r", true)
        if self.RefreshVendorlistDisplay and self.vendorlistFrame and self.vendorlistFrame:IsShown() then
            self:RefreshVendorlistDisplay()
        end
        self._bagsDirty = true
        if self.RefreshTriageIfOpen then
            self:RefreshTriageIfOpen()
        end
    elseif target == "restock" then
        self.db.global.restockList = {}
        self:ChatMsg("|cffff4444Wiped Restock Rules.|r", true)
        self:InvalidateStorageCache()
        self:RefreshRuleTabs()
        self._bagsDirty = true
        if self.RefreshTriageIfOpen then
            self:RefreshTriageIfOpen()
        end
    elseif target == "all" then
        self.db.global.storageAssignments = {}
        self.db.global.registry = {}
        self.db.global.keepList = {}
        self.db.global.vendorWhitelist = {}
        self.db.global.restockList = {}
        self:ChatMsg("|cffff4444Wiped everything: Storage, Restock, Keep List, Vendor Whitelist, and Roster.|r", true)
        self:InvalidateStorageCache()
        self:RefreshRuleTabs()
        self._bagsDirty = true
        if self.RefreshTriageIfOpen then
            self:RefreshTriageIfOpen()
        end
    end
end

-- Build the confirmation-popup text for a given character GUID.
function EmpireManager:BuildPurgeConfirmText(guid)
    local entry = self.db.global.registry[guid]
    if not entry then
        return nil
    end
    local coloredName = self:ClassColoredName(entry)
    local realm = entry.realm or "?"
    local deps = self:GetDependentAssignments(guid)
    local depCount = #deps
    local lines = { string.format("Remove %s - %s from Character Roster?", coloredName, realm) }
    if depCount > 0 then
        lines[#lines + 1] = string.format(
            "\n|cffff8800%d Storage Rule%s|r reference this character and will be |cffff4444DELETED|r:",
            depCount,
            depCount == 1 and "" or "s"
        )
        local maxShown = 6
        for i = 1, math.min(depCount, maxShown) do
            local dep = deps[i]
            local asn = dep.asn
            local pInfo = self.PROF_INFO_BY_KEY and self.PROF_INFO_BY_KEY[asn.profession]
            local profName
            if pInfo then
                local profColor = string.format("%02x%02x%02x", pInfo.r * 255, pInfo.g * 255, pInfo.b * 255)
                profName = "|cff" .. profColor .. (pInfo.label or asn.profession) .. "|r"
            else
                profName = asn.profession or "?"
            end
            lines[#lines + 1] = string.format("Rule #%d %s", dep.index, profName)
        end
        if depCount > maxShown then
            lines[#lines + 1] = string.format("...and %d more", depCount - maxShown)
        end
        lines[#lines + 1] = "To keep, cancel and edit in the Storage tab."
    end
    lines[#lines + 1] = "\nCharacter will be added to the Character Blacklist."
    return table.concat(lines, "\n")
end

function EmpireManager:ConfirmPurgeByGUID(guid)
    local text = self:BuildPurgeConfirmText(guid)
    if not text then
        return
    end
    local dialog = StaticPopup_Show("EM_PURGE_CHAR", text)
    if dialog then
        dialog.data = { guid = guid }
    end
end

function EmpireManager:PurgeCharacter(charName)
    -- Accept "Name" or "Name-Realm". Realm part lets users disambiguate when
    -- the same name exists on multiple realms.
    local namePart, realmPart = charName:match("^([^-]+)-(.+)$")
    if not namePart then
        namePart = charName
    end
    local needleName = namePart:lower()
    local needleRealm = realmPart and realmPart:lower() or nil

    local found = {}
    for guid, entry in pairs(self.db.global.registry) do
        if (entry.name or ""):lower() == needleName then
            if not needleRealm or (entry.realm or ""):lower() == needleRealm then
                found[#found + 1] = { guid = guid, entry = entry }
            end
        end
    end

    if #found == 0 then
        self:ChatMsg(string.format("No character named '%s' found in roster.", charName), true)
        return
    end

    -- Ambiguous: bare name matched multiple realms. List them and abort so the
    -- user can re-run with Name-Realm instead of silently purging all of them.
    if #found > 1 and not needleRealm then
        self:ChatMsg(string.format("Multiple characters named '%s' - specify the realm:", charName), true)
        for _, match in ipairs(found) do
            self:ChatMsg(string.format("  /em purge %s-%s", match.entry.name or "?", match.entry.realm or "?"), true)
        end
        return
    end

    for _, match in ipairs(found) do
        self:ConfirmPurgeByGUID(match.guid)
    end
end

-------------------------------------------------------------------------------
-- Registry Export / Import
-------------------------------------------------------------------------------

-- Export the character registry in the same format ImportRegistryFromText expects.
function EmpireManager:ExportRegistry()
    local reg = self.db.global.registry or {}
    local lines = {
        "# EmpireManager Registry v1",
        "# name;realm;class;race;faction;level;guild;ilvl;spec;professions;sortOrder(optional)",
    }

    -- Collect and sort entries by name-realm for stable output
    local entries = {}
    for _, entry in pairs(reg) do
        entries[#entries + 1] = entry
    end
    table.sort(entries, function(a, b)
        local ka = ((a.name or "") .. "-" .. (a.realm or "")):lower()
        local kb = ((b.name or "") .. "-" .. (b.realm or "")):lower()
        return ka < kb
    end)

    for _, entry in ipairs(entries) do
        local profStr = ""
        if entry.professions and #entry.professions > 0 then
            local profParts = {}
            for _, p in ipairs(entry.professions) do
                -- Export CANONICAL ENGLISH names, never the client's localized ones.
                -- p.name / t.expansionName are whatever language the character was
                -- snapshotted on ("Ingenieurskunst", "Dracheninseln"), and the import
                -- side resolves professions and expansions by English name - so a
                -- localized export could not be re-imported anywhere.
                local pInfo = self:ProfInfoFromEntryProf(p)
                local profLabel = (pInfo and pInfo.label) or p.name or "Unknown"
                local s = profLabel .. ":" .. (p.skill or 0) .. "/" .. (p.maxSkill or 0)
                if p.expansionSkills and #p.expansionSkills > 0 then
                    local tierParts = {}
                    for _, t in ipairs(p.expansionSkills) do
                        -- Skip rows older builds stored wrongly, so exports stay clean.
                        if not self:IsBogusExpansionSkillRow(t) then
                            local expID = t.expansionID or self:ExpansionIDFromAPIName(t.expansionName)
                            local expLabel = t.expansionName or "?"
                            for _, info in ipairs(self.EXPANSION_DISPLAY) do
                                if info.expansionID == expID then
                                    expLabel = info.label
                                    break
                                end
                            end
                            tierParts[#tierParts + 1] = expLabel
                                .. "="
                                .. (t.skill or 0)
                                .. "/"
                                .. (t.maxSkill or 0)
                        end
                    end
                    s = s .. "[" .. table.concat(tierParts, ",") .. "]"
                end
                profParts[#profParts + 1] = s
            end
            profStr = table.concat(profParts, ",")
        end

        local classLabel = entry.class and self.CLASS_NAMES[entry.class] or entry.class or ""
        local sortOrderStr = (entry.sortOrder and entry.sortOrder > 0) and tostring(entry.sortOrder) or ""
        lines[#lines + 1] = string.format(
            "%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s",
            entry.name or "",
            entry.realm or "",
            classLabel,
            entry.race or "",
            entry.faction or "",
            entry.level or 0,
            entry.guild or "",
            entry.ilvl or "",
            entry.spec or "",
            profStr,
            sortOrderStr
        )
    end
    return table.concat(lines, "\n") .. "\n"
end

-- Parse and apply a registry import string.
-- Format (Registry v1):
--   # EmpireManager Registry v1
--   # name;realm;class;race;faction;level;guild;ilvl;spec;professions(name:skill/max[tier=s/m|...])
--   Zarenna;Silvermoon;Mage;Blood Elf;Horde;80;MyGuild;620;Arcane;Alchemy:300/300[Classic=75/300|Midnight=150/150],Herbalism:150/300
--
-- Only seeds fields that are missing or outdated. Never overwrites gold, bags,
-- assignments - those only come from in-game snapshots.
function EmpireManager:ImportRegistryFromText(text, autoAssign)
    if not text or text:match("^%s*$") then
        return 0, "No text to import"
    end

    -- Validate header (accept v1 or v2)
    if not text:find("# EmpireManager Registry v", 1, true) then
        return 0, "Not a valid EmpireManager Registry export (missing header)"
    end

    -- Build name+realm -> guid reverse lookup (case-insensitive)
    local nameRealmToGUID = {}
    for guid, entry in pairs(self.db.global.registry) do
        local key = ((entry.name or "") .. "-" .. (entry.realm or "")):lower()
        nameRealmToGUID[key] = guid
    end

    -- Build blacklist lookup by name-realm (case-insensitive)
    local blacklistedNames = {}
    for _, label in pairs(self.db.global.charBlacklist or {}) do
        local blName, blRealm = label:match("^(.+) %- (.+)$")
        if blName then
            blacklistedNames[(blName .. "-" .. blRealm):lower()] = true
        end
    end

    local imported = 0
    local updated = 0
    local skipped = 0

    for line in text:gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local parts = {}
            for f in (line .. ";"):gmatch("([^;]*);") do
                parts[#parts + 1] = f:match("^%s*(.-)%s*$")
            end

            local name = parts[1] or ""
            local realm = parts[2] or ""
            local classRaw = parts[3] or ""
            local class = self.CLASS_TOKENS[classRaw:lower()] or classRaw:upper():gsub("%s+", "")
            local race = parts[4] or ""
            local faction = parts[5] or ""
            local level = tonumber(parts[6]) or 0
            local guild = parts[7] or ""
            local ilvl = tonumber(parts[8]) or nil
            local spec = parts[9] or ""
            local profStr = parts[10] or ""
            local sortOrderRaw = tonumber(parts[11])
            local sortOrder = nil
            if
                sortOrderRaw
                and sortOrderRaw == math.floor(sortOrderRaw)
                and sortOrderRaw > 0
                and sortOrderRaw <= 99
            then
                sortOrder = sortOrderRaw
            end

            -- Validate class (must exist in RAID_CLASS_COLORS or be empty)
            if class ~= "" and not (RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]) then
                class = ""
            end
            -- Validate faction
            if faction ~= "" and faction ~= "Alliance" and faction ~= "Horde" and faction ~= "Neutral" then
                faction = ""
            end
            -- Clamp level and ilvl
            local maxLvl = GetMaxLevelForExpansionLevel and GetMaxLevelForExpansionLevel(GetExpansionLevel()) or 90
            if level < 0 then
                level = 0
            elseif level > maxLvl then
                level = maxLvl
            end
            if ilvl and (ilvl < 0 or ilvl > 999) then
                ilvl = nil
            end
            -- Cap free-text fields to prevent UI breakage from oversized imports
            if #name > 32 then
                name = name:sub(1, 32)
            end
            if #realm > 64 then
                realm = realm:sub(1, 64)
            end
            if #race > 32 then
                race = race:sub(1, 32)
            end
            if #spec > 32 then
                spec = spec:sub(1, 32)
            end
            if #guild > 64 then
                guild = guild:sub(1, 64)
            end

            if name ~= "" and realm ~= "" then
                -- Parse professions: "Alchemy:150/300[Classic=75/300|Midnight=150/150],Herbalism:100/300"
                local profs = {}
                if profStr ~= "" then
                    -- Split on commas that are NOT inside brackets
                    local profEntries = {}
                    local depth, start = 0, 1
                    for i = 1, #profStr do
                        local c = profStr:sub(i, i)
                        if c == "[" then
                            depth = depth + 1
                        elseif c == "]" then
                            depth = depth - 1
                        elseif c == "," and depth == 0 then
                            profEntries[#profEntries + 1] = profStr:sub(start, i - 1)
                            start = i + 1
                        end
                    end
                    profEntries[#profEntries + 1] = profStr:sub(start)

                    for _, entry in ipairs(profEntries) do
                        entry = entry:match("^%s*(.-)%s*$")
                        -- Split off optional [tiers] bracket
                        local mainPart, tierBracket = entry:match("^(.-)(%[.+%])$")
                        if not mainPart or mainPart == "" then
                            mainPart = entry
                        end
                        -- mainPart can be "Name:skill/max" OR just "Name" (skill optional)
                        local profName, skillStr, maxStr = mainPart:match("^(.+):(%d*)/(%d*)$")
                        if not profName then
                            profName = mainPart
                            skillStr, maxStr = "", ""
                        end
                        if profName and profName ~= "" then
                            if #profName > 32 then
                                profName = profName:sub(1, 32)
                            end
                            local pSkill = tonumber(skillStr) or 0
                            local pMax = tonumber(maxStr) or 0
                            if pSkill < 0 or pSkill > 1000 then
                                pSkill = 0
                            end
                            if pMax < 0 or pMax > 1000 then
                                pMax = 0
                            end
                            -- Normalize to the canonical English label when the name is
                            -- recognizable. Imported rows carry no skillLineID, so
                            -- ProfInfoFromEntryProf resolves them by label - a localized
                            -- name from an older non-English export would never match.
                            local canonical = EmpireManager.PROF_INFO_BY_LABEL[profName]
                            if not canonical then
                                for _, pi in ipairs(EmpireManager.PROF_DISPLAY) do
                                    if pi.label:lower() == profName:lower() then
                                        canonical = pi
                                        break
                                    end
                                end
                            end
                            local profEntry = {
                                name = (canonical and canonical.label) or profName,
                                skill = pSkill,
                                maxSkill = pMax,
                            }
                            -- Parse per-expansion tiers from bracket: [TierName=skill/max,...]
                            -- Accepts ',' (current), ';' and '|' (backward compatibility).
                            -- Battle.net exports tier names with the profession suffix
                            -- (e.g. "Kul Tiran Herbalism") - strip it so we store
                            -- just the expansion name ("Kul Tiran"), matching the
                            -- format SnapshotExpansionSkills writes from in-game.
                            -- Skip tiers whose name doesn't resolve to a known
                            -- expansion (typos, future expansions we haven't mapped).
                            if tierBracket then
                                local expLookup = {}
                                for _, info in ipairs(EmpireManager.EXPANSION_DISPLAY or {}) do
                                    expLookup[info.label:lower()] = info.expansionID
                                    if info.apiNames then
                                        for _, n in ipairs(info.apiNames) do
                                            expLookup[n:lower()] = info.expansionID
                                        end
                                    end
                                end
                                local expSkills = {}
                                local inner = tierBracket:match("^%[(.+)%]$")
                                local profSuffix = profEntry.name and (" " .. profEntry.name) or nil
                                if inner then
                                    for tierEntry in inner:gmatch("[^|;,]+") do
                                        local tName, tSkill, tMax = tierEntry:match("^(.-)=(%d+)/(%d+)$")
                                        if tName then
                                            tName = tName:match("^%s*(.-)%s*$") -- trim
                                            if profSuffix and tName:sub(-#profSuffix) == profSuffix then
                                                tName = tName:sub(1, -#profSuffix - 1)
                                            end
                                            local expID = expLookup[tName:lower()]
                                            if tName ~= "" and expID then
                                                local tSkillN = tonumber(tSkill) or 0
                                                local tMaxN = tonumber(tMax) or 0
                                                if tSkillN < 0 or tSkillN > 1000 then
                                                    tSkillN = 0
                                                end
                                                if tMaxN < 0 or tMaxN > 1000 then
                                                    tMaxN = 0
                                                end
                                                expSkills[#expSkills + 1] = {
                                                    expansionID = expID,
                                                    expansionName = tName,
                                                    skill = tSkillN,
                                                    maxSkill = tMaxN,
                                                }
                                            end
                                        end
                                    end
                                end
                                if #expSkills > 0 then
                                    profEntry.expansionSkills = expSkills
                                end
                            end
                            profs[#profs + 1] = profEntry
                        end
                    end
                end

                local key = (name .. "-" .. realm):lower()
                if blacklistedNames[key] then
                    skipped = skipped + 1
                else
                    local existingGUID = nameRealmToGUID[key]

                    if existingGUID then
                        -- Update existing entry with API data (fill in blanks or refresh)
                        local entry = self.db.global.registry[existingGUID]
                        if class ~= "" and not (RAID_CLASS_COLORS and RAID_CLASS_COLORS[entry.class]) then
                            entry.class = class
                        end
                        if level > (entry.level or 0) then
                            entry.level = level
                        end
                        if ilvl and (not entry.ilvl or ilvl > entry.ilvl) then
                            entry.ilvl = ilvl
                        end
                        if spec ~= "" and not entry.spec then
                            entry.spec = spec
                        end
                        if guild ~= "" and not entry.guild then
                            entry.guild = guild
                        end
                        if #profs > 0 then
                            if not entry.professions or #entry.professions == 0 then
                                entry.professions = profs
                            else
                                -- Merge imported professions into the existing list.
                                -- Match by name: update skill + expansion skills on an
                                -- existing entry, or append a profession the registry
                                -- never captured (e.g. secondary profs like Fishing).
                                for _, importedProf in ipairs(profs) do
                                    local match
                                    for _, existingProf in ipairs(entry.professions) do
                                        if existingProf.name == importedProf.name then
                                            match = existingProf
                                            break
                                        end
                                    end
                                    if match then
                                        if (importedProf.skill or 0) > 0 then
                                            match.skill = importedProf.skill
                                            match.maxSkill = importedProf.maxSkill
                                        end
                                        if importedProf.expansionSkills then
                                            match.expansionSkills = importedProf.expansionSkills
                                        end
                                    else
                                        entry.professions[#entry.professions + 1] = importedProf
                                    end
                                end
                            end
                        end
                        if sortOrder and (entry.sortOrder or 0) == 0 then
                            self:ResolveSortConflict(existingGUID, sortOrder)
                            entry.sortOrder = sortOrder
                        end
                        if autoAssign then
                            self:AutoAssignRoles(entry, existingGUID)
                        end
                        updated = updated + 1
                    else
                        -- Create a new stub entry (will be fully snapshotted when the char logs in)
                        local stubGUID = "API-" .. name .. "-" .. realm
                        local entry = {
                            name = name,
                            realm = realm,
                            class = class,
                            race = race,
                            faction = faction,
                            level = level,
                            guild = guild,
                            ilvl = ilvl,
                            spec = spec,
                            professions = #profs > 0 and profs or nil,
                            lastSeen = 0,
                            _stub = true, -- marks as API-seeded, not yet in-game confirmed
                        }
                        self.db.global.registry[stubGUID] = entry
                        if sortOrder then
                            self:ResolveSortConflict(stubGUID, sortOrder)
                            entry.sortOrder = sortOrder
                        end
                        if autoAssign then
                            self:AutoAssignRoles(entry, stubGUID)
                        end
                        imported = imported + 1
                    end
                end -- blacklist check
            end -- name ~= "" and realm ~= ""
        end
    end

    if imported > 0 or updated > 0 then
        self:SendMessage("EM_DASHBOARD_REFRESH")
    end
    return imported, updated, skipped
end

function EmpireManager:PurgeByGUID(guid)
    local entry = self.db.global.registry[guid]
    if not entry then
        return
    end

    local name = entry.name or "?"
    local realm = entry.realm or "?"

    local removedRules = 0
    local assignments = self.db.global.storageAssignments
    if assignments then
        for i = #assignments, 1, -1 do
            local asn = assignments[i]
            if asn and asn.type == "charbank" and asn.char == guid then
                table.remove(assignments, i)
                removedRules = removedRules + 1
            end
        end
    end

    self.db.global.registry[guid] = nil
    if not self.db.global.charBlacklist then
        self.db.global.charBlacklist = {}
    end
    local label = name .. " - " .. realm
    local alreadyBlacklisted = false
    for existingGuid, existingLabel in pairs(self.db.global.charBlacklist) do
        if existingGuid == guid or existingLabel == label then
            alreadyBlacklisted = true
            break
        end
    end
    if not alreadyBlacklisted then
        self.db.global.charBlacklist[guid] = label
        self:ChatMsg(string.format("Removed %s - %s from Roster and added to Character Blacklist.", name, realm), true)
    else
        self:ChatMsg(string.format("Removed %s - %s from Roster (already on Character Blacklist).", name, realm), true)
    end
    if removedRules > 0 then
        self:ChatMsg(
            string.format(
                "Deleted %d storage rule%s referencing this character.",
                removedRules,
                removedRules == 1 and "" or "s"
            ),
            true
        )
        if self.InvalidateStorageCache then
            self:InvalidateStorageCache()
        end
    end

    -- Refresh char blacklist window if it's open so the new entry shows up.
    if self.charBlacklistFrame and self.charBlacklistFrame:IsShown() and self.RefreshCharBlacklistDisplay then
        self:RefreshCharBlacklistDisplay()
    end

    -- Close sidecar if it was showing this character
    if self.sidecarGUID == guid then
        self:CloseSidecar()
    end

    self:SendMessage("EM_DASHBOARD_REFRESH")
    if EmpireManagerFrame and EmpireManagerFrame.StoragePage and EmpireManagerFrame.StoragePage._nativeInit then
        EmpireManagerFrame.StoragePage:Refresh()
    end
end
