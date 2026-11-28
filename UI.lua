-- UI.lua: the pick-and-choose window, the live tracker, the minimap button and the slash commands.
-- Colors, fonts, backgrounds, scale and opacity are in Look.lua / LookSetup.lua (Alt-click the minimap button).
local ADDON_NAME, ns = ...
local UI = {}
ns.UI = UI
local T = ns.T
local P = ns.Pins

local CATS = {
    { id = "pursuing", name = "What I am tracking" },
    { id = "all", name = "Everything" },
    { id = "book", name = "Library books" },
    { id = "bag", name = "Cozy Sleeping Bag" },
    { id = "pet", name = "Companion pets" },
    { id = "secret", name = "Secrets and extras" },
    { id = "bagq", name = "Bags and storage" },
    { id = "perk", name = "Gear and perks" },
    { id = "toy", name = "Oddities" },
    { id = "custom", name = "My own list" },
}
UI.CATS = CATS
local SORTS = { { "list", "Guide order" }, { "zone", "This zone first" }, { "level", "Level" }, { "distance", "Nearest first" } }
UI.SORTS = SORTS

local function CatName(id)
    if id == "perk" and ns.db and ns.db.perkGroup then return "Gear and perks: " .. ns.db.perkGroup end
    for _, c in ipairs(CATS) do if c.id == id then return c.name end end
    return id
end

local STATE_COLOR = { [0] = { 0.28, 0.28, 0.3 }, [1] = { 1, 0.8, 0.15 }, [2] = { 0.3, 0.9, 0.4 } }
local STATE_WORD = { [0] = "Not yet", [1] = "In hand", [2] = "Done" }

local function Btn(parent, text, w, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, 20)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

local function Dist(d)
    if not d then return "" end
    if d >= 1000 then return ("%.1f km"):format(d / 1000) end
    return ("%d yd"):format(math.floor(d + 0.5))
end

---------------------------------------------------------------------------
-- A progress bar that looks like the XP bar: solid = done, lighter = held but not handed in (rested XP)
---------------------------------------------------------------------------
local function MakeBar(parent)
    local b = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    b:SetHeight(14)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.bg:SetColorTexture(0.05, 0.05, 0.07, 0.9)
    b.rest = b:CreateTexture(nil, "ARTWORK")
    b.rest:SetPoint("TOPLEFT") b.rest:SetPoint("BOTTOMLEFT")
    b.done = b:CreateTexture(nil, "OVERLAY")
    b.done:SetPoint("TOPLEFT") b.done:SetPoint("BOTTOMLEFT")
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetPoint("CENTER")
    return b
end

local function SetBar(b, label, done, have, total, goal)
    goal = goal or total
    local w = b:GetWidth()
    if not w or w <= 1 then w = 200 end
    local frac = goal > 0 and math.min(1, done / goal) or 0
    local fracRest = goal > 0 and math.min(1, (done + have) / goal) or 0
    local bc, rc = ns.db.barColor or { 0.58, 0.1, 0.62 }, ns.db.restColor or { 0.1, 0.45, 0.95 }
    b.done:SetColorTexture(bc[1], bc[2], bc[3], 1)
    b.rest:SetColorTexture(rc[1], rc[2], rc[3], 0.85)
    b.done:SetWidth(math.max(0.001, w * frac))
    b.rest:SetWidth(math.max(0.001, w * fracRest))
    if frac <= 0 then b.done:Hide() else b.done:Show() end
    if fracRest <= frac then b.rest:Hide() else b.rest:Show() end
    local t = ("%s  %d / %d"):format(label, done, goal)
    if have > 0 then t = t .. ("  (+%d in hand)"):format(have) end
    b.text:SetText(t)
end

-- the bars worth showing for what you are pursuing
local function BarsFor(pursuedOnly)
    local out = {}
    local function Any(cat)
        if not pursuedOnly then return true end
        for _, e in ipairs(T.all) do if e.cat == cat and T.Pursued(e.key) and T.State(e.key) < 2 then return true end end
        return false
    end
    if Any("book") then
        local total, have, done = T.Counts("book")
        local m = T.Milestone()
        out[#out + 1] = { label = m and ("Library, next reward at " .. m.books) or "Library", done = done, have = have, total = total, goal = m and m.books or total }
    end
    if Any("bag") then
        local total, done = T.ChainInfo()
        local _, _, cur = T.ChainInfo()
        local started = (cur and T.State(cur) == 1) and 1 or 0
        out[#out + 1] = { label = "Sleeping Bag steps", done = done, have = started, total = total, goal = total }
    end
    if Any("pet") then
        local total, have, done = T.Counts("pet")
        out[#out + 1] = { label = "Pets", done = done, have = 0, total = total, goal = total }
    end
    if Any("secret") then
        local total, _, done = T.Counts("secret")
        out[#out + 1] = { label = "Secrets", done = done, have = 0, total = total, goal = total }
    end
    if Any("bagq") then
        local total, have, done = T.Counts("bagq")
        out[#out + 1] = { label = "Bags", done = done, have = have, total = total, goal = total }
    end
    if Any("perk") then
        local total, _, done = T.Counts("perk")
        out[#out + 1] = { label = "Gear and perks", done = done, have = 0, total = total, goal = total }
    end
    if Any("toy") then
        local total, _, done = T.Counts("toy")
        out[#out + 1] = { label = "Oddities", done = done, have = 0, total = total, goal = total }
    end
    return out
end

---------------------------------------------------------------------------
-- Popups
---------------------------------------------------------------------------
local function EditOf(popup) return popup.editBox or popup.EditBox or (popup.GetName and _G[popup:GetName() .. "EditBox"]) end
local function Ask(which, text, data) if StaticPopup_Show then StaticPopup_Show(which, text, nil, data) end end

StaticPopupDialogs["WHATNOT_ADD"] = {
    text = "%s", button1 = ACCEPT or "OK", button2 = CANCEL or "Cancel", hasEditBox = 1, maxLetters = 80, editBoxWidth = 280,
    timeout = 0, whileDead = 1, hideOnEscape = 1,
    OnShow = function(self) local eb = EditOf(self) if eb then eb:SetText("") eb:SetFocus() end end,
    OnAccept = function(self, data) local eb = EditOf(self) if data and data.fn and eb then data.fn(eb:GetText()) end end,
    EditBoxOnEnterPressed = function(self)
        local p = self:GetParent()
        if p.data and p.data.fn then p.data.fn(self:GetText()) end
        p:Hide()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
}
StaticPopupDialogs["WHATNOT_DELETE"] = {
    text = "%s", button1 = YES or "Yes", button2 = NO or "No", timeout = 0, whileDead = 1, hideOnEscape = 1,
    OnAccept = function(self, data) if data and data.fn then data.fn() end end,
}

function UI.AddCustom(name)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return end
    local n = ns.db.nextCustom or 1
    ns.db.nextCustom = n + 1
    local key = "cu:" .. n
    table.insert(ns.db.custom, { key = key, name = name })
    T.Rebuild()
    T.SetPursued(key, true)
    ns.Print("added to your own list and tracking: " .. name)
    UI.Refresh()
end

function UI.AskAdd() Ask("WHATNOT_ADD", "What do you want to collect? (it goes on your own list)", { fn = UI.AddCustom }) end

function UI.AskDelete(e)
    Ask("WHATNOT_DELETE", ("Remove \"%s\" from your own list?"):format(e.name), { fn = function()
        for i, c in ipairs(ns.db.custom) do if c.key == e.key then table.remove(ns.db.custom, i) break end end
        for _, ch in pairs(ns.db.chars) do if ch.s then ch.s[e.key] = nil end if ch.p then ch.p[e.key] = nil end end
        T.Rebuild()
        UI.Refresh()
    end })
end

---------------------------------------------------------------------------
-- The main window
---------------------------------------------------------------------------
local W
local ROWH = 32
local MAXROWS = 24
local TOP_LIST = 198

local function MakeSelector(label, y, onLeft, onRight)
    local lbl = W:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("TOPLEFT", 12, y - 4) lbl:SetText(label)
    local l = Btn(W, "<", 22, onLeft) l:SetPoint("TOPLEFT", 52, y)
    local r = Btn(W, ">", 22, onRight) r:SetPoint("TOPRIGHT", -12, y)
    local fs = W:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("LEFT", l, "RIGHT", 6, 0) fs:SetPoint("RIGHT", r, "LEFT", -6, 0)
    fs:SetJustifyH("CENTER")
    return fs
end

local function Cycle(list, cur, dir, idField)
    local idx = 1
    for i, v in ipairs(list) do if (idField and v[idField] or v[1]) == cur then idx = i end end
    idx = ((idx - 1 + dir) % #list) + 1
    return list[idx]
end

-- a drop-down: a button showing the current choice that opens a list of all choices
local openMenu
local function CloseMenu() if openMenu then openMenu:Hide() openMenu = nil end end
local function MakeDropdown(label, y, getChoices, onPick, width)
    local btn = CreateFrame("Button", nil, W, "UIPanelButtonTemplate")
    btn:SetHeight(22)
    if width then
        btn:SetPoint("TOPRIGHT", -34, y) btn:SetWidth(width)
    else
        local lbl = W:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        lbl:SetPoint("TOPLEFT", 12, y - 4) lbl:SetText(label)
        btn:SetPoint("TOPLEFT", 52, y) btn:SetPoint("TOPRIGHT", -12, y)
    end
    btn:SetText("")
    local arrow = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    arrow:SetPoint("RIGHT", -8, 0) arrow:SetText("v")
    local menu
    btn:SetScript("OnClick", function(self)
        if openMenu and openMenu == menu then CloseMenu() return end
        CloseMenu()
        local choices = getChoices()
        if not menu then
            menu = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
            menu:SetFrameStrata("FULLSCREEN_DIALOG")
            menu:SetClampedToScreen(true)
            if menu.SetBackdrop then
                menu:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
                menu:SetBackdropColor(0.08, 0.08, 0.1, 0.98)
                menu:SetBackdropBorderColor(0.4, 0.87, 1, 0.8)
            end
            menu.items = {}
            -- clicking anywhere else closes it
            menu.catch = CreateFrame("Button", nil, UIParent)
            menu.catch:SetAllPoints(UIParent)
            menu.catch:SetFrameStrata("FULLSCREEN")
            menu.catch:SetScript("OnClick", CloseMenu)
            menu:HookScript("OnHide", function() menu.catch:Hide() end)
            menu:HookScript("OnShow", function() menu.catch:Show() end)
        end
        local w = self:GetWidth()
        menu:SetWidth(w)
        menu:SetHeight(#choices * 22 + 8)
        menu:ClearAllPoints()
        menu:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -1)
        for i, c in ipairs(choices) do
            local it = menu.items[i]
            if not it then
                it = CreateFrame("Button", nil, menu)
                it:SetHeight(22)
                it.hl = it:CreateTexture(nil, "BACKGROUND") it.hl:SetAllPoints() it.hl:SetColorTexture(1, 1, 1, 0.12) it.hl:Hide()
                it.text = it:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                it.text:SetPoint("LEFT", 8, 0) it.text:SetPoint("RIGHT", -8, 0) it.text:SetJustifyH("LEFT")
                it:SetScript("OnEnter", function(s) s.hl:Show() end)
                it:SetScript("OnLeave", function(s) s.hl:Hide() end)
                menu.items[i] = it
            end
            it:ClearAllPoints()
            it:SetPoint("TOPLEFT", menu, "TOPLEFT", 4, -4 - (i - 1) * 22)
            it:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -4, -4 - (i - 1) * 22)
            it.text:SetText(c.label)
            if c.current then it.text:SetTextColor(1, 0.82, 0) else it.text:SetTextColor(1, 1, 1) end
            it:SetScript("OnClick", function() CloseMenu() onPick(c.id) end)
            it:Show()
        end
        for i = #choices + 1, #menu.items do menu.items[i]:Hide() end
        menu:Show()
        openMenu = menu
    end)
    return { SetText = function(_, s) btn:SetText(s) end }
end

local CAT_WORD = { book = "Library book", bag = "Cozy Sleeping Bag step", pet = "Companion pet", secret = "Secret or extra", bagq = "Bag or storage", perk = "Gear or perk", toy = "Oddity step", custom = "My own list" }
local CAT_COLOR = { book = "ffd9a441", bag = "ff9fd35c", pet = "ffff9ecb", secret = "ffb48cff", bagq = "ff7fc4ff", perk = "ffffd100", toy = "ff5fd7c8", custom = "ffcccccc" }
local STATE_HEX = { [0] = "ff9a9a9a", [1] = "ffffd100", [2] = "ff55e070" }
local CLASS_WORD = { HUNTER = "Hunter", ROGUE = "Rogue", WARRIOR = "Warrior", SHAMAN = "Shaman", PALADIN = "Paladin", MAGE = "Mage", WARLOCK = "Warlock", DRUID = "Druid", PRIEST = "Priest" }

-- a small 3D preview that sits beside the tooltip, so you can see what a pet or summon looks like before you chase it
local PV
local function Preview()
    if PV then return PV end
    PV = CreateFrame("Frame", "WhatnotPreview", UIParent, "BackdropTemplate")
    PV:SetSize(190, 230)
    PV:SetFrameStrata("TOOLTIP")
    PV:SetClampedToScreen(true)
    if PV.SetBackdrop then
        PV:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        PV:SetBackdropColor(0.04, 0.04, 0.06, 0.95)
        PV:SetBackdropBorderColor(1, 0.82, 0, 0.9)
    end
    PV.title = PV:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    PV.title:SetPoint("TOP", 0, -8)
    PV.title:SetWidth(170)
    PV.model = CreateFrame("PlayerModel", nil, PV)
    PV.model:SetPoint("TOPLEFT", 8, -26)
    PV.model:SetPoint("BOTTOMRIGHT", -8, 8)
    PV.spin = 0
    PV.model:SetScript("OnUpdate", function(self, el)
        PV.spin = (PV.spin + (el or 0) * 0.6) % 6.2832
        if self.SetFacing then self:SetFacing(PV.spin) elseif self.SetRotation then self:SetRotation(PV.spin) end
    end)
    PV:Hide()
    return PV
end
function UI.HidePreview() if PV then PV:Hide() end end

-- which creature to show: a checked id from the list, or the id the game gave us when you owned that pet
local function CreatureFor(e)
    if e.npc then return e.npc end
    local seen = ns.db and ns.db.seenModels
    local nm = e.pet or e.name
    if seen and nm then return seen[string.lower(nm)] end
    return nil
end

local function ShowPreview(e)
    local id = CreatureFor(e)
    if not id then UI.HidePreview() return false end
    local pv = Preview()
    pv.title:SetText(e.name)
    pv:ClearAllPoints()
    pv:SetPoint("TOPLEFT", GameTooltip, "TOPRIGHT", 6, 0)
    local ok = pcall(function()
        pv.model:ClearModel()
        pv.model:SetCreature(id)
    end)
    if not ok then pv:Hide() return false end
    pv:Show()
    return true
end

-- long notes read better as short lines: split numbered steps, otherwise sentences
local function NoteLines(text)
    local out = {}
    if text:find("%d%) ") then
        local marked = text:gsub(" ?(%d)%) ", "\n%1) ")
        for ln in marked:gmatch("[^\n]+") do
            local trimmed = ln:gsub("^%s+", ""):gsub("%s+$", "")
            if trimmed ~= "" then out[#out + 1] = trimmed end
        end
    else
        for sent in (text .. " "):gmatch("(.-[%.!?])%s+") do out[#out + 1] = sent end
    end
    if #out == 0 then out[1] = text end
    return out
end

local function Section(G, label)
    G:AddLine(" ")
    G:AddLine(label, 0.5, 0.75, 1)
end


-- "Gear and perks" in guide order is grouped under little headers: general, fishing, mounts, Legacy rewards, then by class
local PERK_CLASSES = { "Druid", "Hunter", "Mage", "Paladin", "Priest", "Rogue", "Shaman", "Warlock", "Warrior" }
local PERK_ORDER = { "General", "Fishing", "Mounts", "Legacy rewards", "All classes" }
for _, c in ipairs(PERK_CLASSES) do PERK_ORDER[#PERK_ORDER + 1] = c end
local PERK_RANK = {}
for i, g in ipairs(PERK_ORDER) do PERK_RANK[g] = i end
local function PerkGroup(e)
    local n = e.name or ""
    local l = n:lower()
    if l:find("legacy reward", 1, true) then return "Legacy rewards" end
    if l:find("fishing", 1, true) or l:find("angler", 1, true) or l:find("lure", 1, true) or l:find("pagle", 1, true) or l:find("trunk", 1, true) then return "Fishing" end
    if l:find("mount", 1, true) or l:find("riding", 1, true) or l:find("warhorse", 1, true) or l:find("charger", 1, true) or l:find("stallion", 1, true) then return "Mounts" end
    if l:find("class quest", 1, true) then return "All classes" end
    if type(e.class) == "string" then
        local c = e.class:sub(1, 1):upper() .. e.class:sub(2):lower()
        if PERK_RANK[c] then return c end
    end
    for _, c in ipairs(PERK_CLASSES) do if n:find(c, 1, true) then return c end end
    return "General"
end
-- the list plus a header line before each group; only headers and rows, in guide order
local function WithHeaders(list)
    local groups, order = {}, {}
    for i, e in ipairs(list) do
        local g = PerkGroup(e)
        if not groups[g] then groups[g] = {} order[#order + 1] = g end
        table.insert(groups[g], e)
    end
    table.sort(order, function(a, b) return PERK_RANK[a] < PERK_RANK[b] end)
    local out = {}
    for _, g in ipairs(order) do
        out[#out + 1] = { header = g, count = #groups[g] }
        for _, e in ipairs(groups[g]) do out[#out + 1] = e end
    end
    return out
end

ns.PerkGroup = PerkGroup
-- the groups that have something in them, in display order
local function PerkGroupsPresent()
    local have = {}
    for _, e in ipairs(T.all) do if e.cat == "perk" then have[PerkGroup(e)] = true end end
    local out = {}
    for _, g in ipairs(PERK_ORDER) do if have[g] then out[#out + 1] = g end end
    return out
end

local function RowTooltipBody(row)
    local e = row.entry
    if not e then return end
    local st = T.State(e.key)
    local G = GameTooltip
    G:SetOwner(row, "ANCHOR_RIGHT")
    if G.SetMinimumWidth then G:SetMinimumWidth(280) end

    -- header: icon, name, then a one-line chip row
    local icon
    local it = type(e.item) == "table" and e.item[1] or e.item
    if it and GetItemInfo then local _, _, _, _, _, _, _, _, _, ic = GetItemInfo(it) icon = ic end
    G:AddLine((icon and ("|T" .. icon .. ":20|t ") or "") .. "|cffffd100" .. e.name .. "|r", 1, 1, 1, true)
    local chips = "|c" .. (CAT_COLOR[e.cat] or "ffcccccc") .. (CAT_WORD[e.cat] or "Collectible") .. "|r   |c" .. STATE_HEX[st] .. STATE_WORD[st] .. "|r"
    if T.Pursued(e.key) then chips = chips .. "   |cff66ddfftracking|r" end
    G:AddLine(chips)
    do
        local by = T.DoneBy(e.key)
        if #by > 0 then G:AddLine("|cff66dd66Done on:|r " .. table.concat(by, ", "), 1, 1, 1, true) end
    end
    local need = {}
    if e.class then need[#need + 1] = "|cffffffff" .. (CLASS_WORD[e.class] or e.class) .. " only|r" end
    if e.fac == "A" then need[#need + 1] = "|cff4a9dffAlliance|r" elseif e.fac == "H" then need[#need + 1] = "|cffff5050Horde|r" end
    if e.lvl and e.lvl > 1 then need[#need + 1] = "level " .. e.lvl end
    if #need > 0 then G:AddLine(table.concat(need, "  |cff888888-|r  ")) end

    -- where
    local zone = e.zoneName or e.zone
    if zone or (e.place and e.place ~= "") then
        Section(G, "WHERE")
        if zone then
            local line = "|cffffffff" .. zone .. "|r"
            if e.x and e.y then line = line .. ("  |cffaaaaaa(%.1f, %.1f)|r"):format(e.x, e.y) end
            G:AddLine(line)
        end
        if e.place and e.place ~= "" then G:AddLine(e.place, 0.85, 0.85, 0.85, true) end
    end

    -- quest and item
    local q = type(e.quest) == "table" and e.quest[1] or e.quest
    local showQ = q and q ~= e.name
    local itemTxt = e.item and ((type(e.item) == "table") and table.concat(e.item, ", ") or e.item)
    if (showQ) or (itemTxt and itemTxt ~= e.name) then
        Section(G, "QUEST AND ITEM")
        if showQ then G:AddDoubleLine("Quest", tostring(q) .. (e.qid and ("  #" .. e.qid) or ""), 0.6, 0.8, 1, 1, 1, 1) end
        if itemTxt and itemTxt ~= e.name then G:AddDoubleLine("Item", itemTxt, 0.6, 0.8, 1, 1, 1, 1) end
    end

    -- how to get it, and what it gives
    local note = e.note
    if note and note ~= "" and ns.db.showHints ~= false then
        local reward = note:match("[Rr]eward:%s*([^\n]+)")
        local how = reward and (note:gsub("%s*[Rr]eward:%s*[^\n]+", "")) or note
        how = how:gsub("^%s+", ""):gsub("%s+$", "")
        if how ~= "" then
            Section(G, e.cat == "pet" and "SOURCE" or "HOW TO GET IT")
            for _, line in ipairs(NoteLines(how)) do G:AddLine("|cff888888-|r " .. line, 0.92, 0.92, 0.92, true) end
        end
        if reward then
            Section(G, "REWARD")
            G:AddLine(reward, 0.45, 1, 0.55, true)
        end
    end

    -- progress
    if e.cat == "book" then
        local _, have, done = T.Counts("book")
        local m = T.Milestone()
        Section(G, "LIBRARY")
        G:AddLine(("%d handed in, %d in hand"):format(done or 0, have or 0), 0.8, 0.9, 1)
        if m then G:AddLine(("Next reward at %d books (%d to go): %s"):format(m.books, m.need, m.rewards), 0.6, 0.8, 1, true) end
        local lp = ns.LIBRARIAN_POINTS[T.Faction()] or ns.LIBRARIAN_POINTS.A
        if lp then G:AddLine("Hand it in to " .. lp.name, 0.8, 0.8, 0.8, true) end
    elseif e.cat == "bag" then
        local total = T.ChainInfo and select(1, T.ChainInfo())
        local n = tonumber((e.key or ""):match("(%d+)$"))
        if n and total then Section(G, "CHAIN") G:AddLine(("Step %d of %s"):format(n, tostring(total)), 0.8, 0.9, 1) end
    end

    local d = T.Distance(e)
    if d then G:AddLine(" ") G:AddLine(Dist(d) .. " away", 0.5, 1, 0.5) end

    -- model preview for pets, tames and summons
    local wantsModel = e.cat == "pet" or e.npc or e.pet
    if wantsModel then
        if not CreatureFor(e) then
            G:AddLine(" ")
            G:AddLine("3D preview: not available yet", 0.5, 0.5, 0.5)
        end
    end

    G:AddLine(" ")
    G:AddLine("Box: tick it   Track: show it on the maps   Go: point the arrow", 0.55, 0.55, 0.55, true)
    G:Show()
    if wantsModel or e.npc then ShowPreview(e) else UI.HidePreview() end
end
UI.RowTooltip = RowTooltip

local function RowTooltip(row) T.View(RowTooltipBody, row) end

local function ApplyLook()
    if not W then return end
    local rows = math.min(MAXROWS, math.max(5, math.floor(ns.db.listRows or 12)))
    W:SetHeight(TOP_LIST + rows * ROWH + 66)
end
UI.ApplyLook = ApplyLook

local function ShortChar(k) return (((k or "?"):gsub("%-.*$", ""))) end

local function RefreshBody()
    if W and W:IsShown() then
        local db = ns.db
        do
            local vk = T.ViewKey()
            W.who:SetText(vk and ("Viewing: " .. ShortChar(vk)) or ("Viewing: " .. ShortChar(T.Me()) .. " (you)"))
        end
        W.cat:SetText(CatName(db.cat))
        for _, s in ipairs(SORTS) do if s[1] == db.sort then W.sort:SetText(s[2]) end end
        local bars = BarsFor(false)
        local primary
        if db.cat == "book" then primary = "Library" elseif db.cat == "bag" then primary = "Sleeping Bag" elseif db.cat == "pet" then primary = "Pets" elseif db.cat == "secret" then primary = "Secrets" elseif db.cat == "bagq" then primary = "Bags" elseif db.cat == "perk" then primary = "Gear" elseif db.cat == "toy" then primary = "Oddities" end
        local bar
        if db.cat == "all" or db.cat == "pursuing" then
            local tt, th, td = T.Counts(nil)
            bar = { label = "Everything", done = td, have = th, total = tt, goal = tt }
            bars = { bar }
        end
        for _, b in ipairs(bars) do if primary and b.label:find(primary, 1, true) then bar = b end end
        bar = bar or bars[1]
        if bar then SetBar(W.bar, bar.label, bar.done, bar.have, bar.total, bar.goal) W.bar:Show() else W.bar:Hide() end
        -- one line about the next library reward
        local m = T.Milestone()
        if db.cat == "book" or db.cat == "all" or db.cat == "pursuing" then
            local lib = T.Char().libMin
            local btotal, bhave, ticked = T.Counts("book")
            local prefix = ("|cffffffff%d of %d books turned in|r%s.  "):format(ticked, btotal, bhave > 0 and (" (" .. bhave .. " in your bags)") or "")
            if lib and ticked < lib then
                W.info:SetText(prefix .. ("|cffffd100Your reward quests show at least %d are done: tick the rest by hand.|r"):format(lib))
            elseif m then
                W.info:SetText(prefix .. ("|cffaaaaaaNext reward:|r %d books (%d to go, level %d): %s"):format(m.books, m.need, m.lvl, m.rewards))
            else
                W.info:SetText(prefix .. "|cff55ff55Every library reward earned.|r")
            end
        else
            W.info:SetText("")
        end
        local fh = T.Faction() == "H"
        W.faction:SetText(("%s%s|r%s"):format(fh and "|cffff5555" or "|cff4da6ff", T.FactionName(), db.factionFilter == "all" and " (showing both)" or " (detected)"))
        W.cbDone:SetChecked(db.hideDone and true or false)
        W.cbZone:SetChecked(db.thisZoneOnly and true or false)

        local list = T.List()
        W.shown = list
        local tracking = 0
        for _, e in ipairs(list) do if T.Pursued(e.key) then tracking = tracking + 1 end end
        W.count:SetText(("%d shown, %d tracked"):format(#list, tracking))
        local display = list
        if db.cat == "perk" and not db.perkGroup and (db.sort or "list") == "list" and #list > 0 then display = WithHeaders(list) end
        local nrows = math.min(MAXROWS, math.max(5, math.floor(db.listRows or 12)))
        local maxOff = math.max(0, #display - nrows)
        W.offset = math.min(math.max(W.offset or 0, 0), maxOff)
        local pm, px, py = T.PlayerPos()
        for i = 1, MAXROWS do
            local r = W.rows[i]
            local e = i <= nrows and display[W.offset + i] or nil
            if e and e.header then
                -- a divider with a header: no tick box or buttons, just the group name and a line under it
                r.entry = nil
                r.box:Hide() r.go:Hide() r.track:Hide() r.have:SetText("") r.sub:SetText("")
                if not r.div then
                    r.div = r:CreateTexture(nil, "ARTWORK")
                    r.div:SetHeight(1)
                    r.div:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 14, 2)
                    r.div:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -16, 2)
                    r.div:SetColorTexture(1, 0.82, 0, 0.45)
                end
                r.div:Show()
                r.name:ClearAllPoints()
                r.name:SetPoint("LEFT", r, "LEFT", 14, 2)
                r.name:SetText(("|cffffd100%s|r  |cff888888(%d)|r"):format(e.header, e.count or 0))
                r:Show()
            elseif e then
                r.box:Show() r.go:Show() r.track:Show()
                if r.div then r.div:Hide() end
                r.name:ClearAllPoints()
                r.name:SetPoint("TOPLEFT", r, "TOPLEFT", 56, -4)
                r.entry = e
                local st = T.State(e.key)
                local c = STATE_COLOR[st]
                r.box.fill:SetVertexColor(c[1], c[2], c[3])
                r.box.check:SetShown(st >= 2)
                local pursued = T.Pursued(e.key)
                if pursued then
                    r.track:SetText("Tracking")
                    r.track.label:SetTextColor(0.4, 1, 0.5)
                else
                    r.track:SetText("Track")
                    r.track.label:SetTextColor(1, 0.82, 0)
                end
                if st == 1 then r.have:SetText("in hand") elseif st >= 2 then r.have:SetText("done") else r.have:SetText("") end
                local name = e.name
                if st >= 2 then name = "|cff888888" .. name .. "|r" elseif st == 1 then name = "|cffffd100" .. name .. "|r" end
                r.name:SetText(name)
                local sub = {}
                if e.zoneName then sub[#sub + 1] = e.zoneName end
                if e.lvl and e.lvl > 1 then sub[#sub + 1] = "Level " .. e.lvl end
                if e.fac and db.factionFilter == "all" then sub[#sub + 1] = e.fac == "A" and "|cff4da6ffAlliance|r" or "|cffff5555Horde|r" end
                local d = T.Distance(e, pm, px, py)
                if d then sub[#sub + 1] = Dist(d) end
                if e.cat == "perk" then
                    local by = T.DoneBy(e.key)
                    if #by > 0 then sub[#sub + 1] = "|cff66dd66done: " .. table.concat(by, ", ") .. "|r" end
                end
                r.sub:SetText(table.concat(sub, "  "))
                r:Show()
            else
                r.entry = nil
                if r.div then r.div:Hide() end
                r:Hide()
            end
        end
        W.syncing = true
        W.scroll:SetMinMaxValues(0, maxOff)
        W.scroll:SetValue(W.offset)
        W.scroll:SetShown(maxOff > 0)
        W.syncing = false
        if #list == 0 then
            W.empty:SetText(db.cat == "pursuing" and "You are not tracking anything yet.\nPick something in 'Show' above, then press its Track button." or ((db.factionFilter ~= "all" and db.cat ~= "custom" and T.Counts(db.cat ~= "all" and db.cat or nil) == 0) and "Nothing here for your faction.\nOptions > 'Show things for' > 'Both factions' shows the other side's entries." or "Nothing to show with these filters.\nTry turning off 'Hide finished' or 'This zone only'."))
            W.empty:Show()
        else
            W.empty:Hide()
        end
    end
end

function UI.Refresh()
    T.View(RefreshBody)
    UI.RefreshTracker()
end

function UI.GoTo(e)
    T.manualKey = e.key
    if not T.Pursued(e.key) then T.SetPursued(e.key, true) end
    T.SetWaypoint(e)
    UI.Refresh()
end

-- nothing is ever changed on a character you are only looking at
local function ReadOnly()
    local k = T.ViewKey()
    if not k then return false end
    ns.Print(("You are looking at %s. Pick your own character at the top to change things."):format(ShortChar(k)))
    return true
end

local function BuildWindow()
    W = CreateFrame("Frame", "WhatnotFrame", UIParent, "BackdropTemplate")
    W:SetSize(520, 480)
    W:SetFrameStrata("DIALOG")
    W:SetToplevel(true)
    W:SetClampedToScreen(true)
    W:EnableMouse(true)
    W:SetMovable(true)
    if W.SetBackdrop then
        W:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        W:SetBackdropColor(0.06, 0.06, 0.08, 0.96)
        W:SetBackdropBorderColor(0.4, 0.87, 1, 0.8)
    end
    local p = ns.db.pos
    if p then W:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else W:SetPoint("CENTER", UIParent, "CENTER", -300, 0) end
    W:RegisterForDrag("LeftButton")
    W:SetScript("OnDragStart", function(self) self:StartMoving() end)
    W:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local a, _, b, x, y = self:GetPoint()
        ns.db.pos = { a, b, x, y }
    end)
    W:Hide()
    tinsert(UISpecialFrames, "WhatnotFrame")

    W.titleFS = W:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    W.titleFS:SetPoint("TOPLEFT", 12, -10)
    W.titleFS:SetText("Whatnot")
    local close = CreateFrame("Button", nil, W, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)

    W.who = MakeDropdown("", -8, function()
        local out, me = {}, T.Me()
        local keys = {}
        for k in pairs(ns.db.chars) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b)
            if a == me then return true elseif b == me then return false end
            return a:lower() < b:lower()
        end)
        local cur = T.ViewKey() or me
        for _, k in ipairs(keys) do
            local c = ns.db.chars[k]
            local col = c.faction == "H" and "|cffff6060" or (c.faction == "A" and "|cff60a8ff" or "|cffffffff")
            out[#out + 1] = { id = k, label = col .. k:gsub("%-.*$", "") .. "|r" .. (k == me and "  (you)" or "") .. ((c.level and c.level > 0) and ("  " .. c.level) or ""), current = (k == cur) }
        end
        return out
    end, function(id) ns.db.viewChar = (id ~= T.Me()) and id or nil W.offset = 0 UI.Refresh() end, 200)
    W.cat = MakeDropdown("Show", -34, function()
        local out = {}
        for _, c in ipairs(CATS) do
            out[#out + 1] = { id = c.id, label = c.name, current = ns.db.cat == c.id and not (c.id == "perk" and ns.db.perkGroup) }
            if c.id == "perk" then
                -- gear and perks split by section: general, fishing, mounts, then each class
                for _, g in ipairs(PerkGroupsPresent()) do
                    out[#out + 1] = { id = "perk:" .. g, label = "    " .. g, current = ns.db.cat == "perk" and ns.db.perkGroup == g }
                end
            end
        end
        return out
    end, function(id)
        local g = type(id) == "string" and id:match("^perk:(.+)$")
        if g then ns.db.cat = "perk" ns.db.perkGroup = g else ns.db.cat = id ns.db.perkGroup = nil end
        W.offset = 0 UI.Refresh()
    end)
    W.sort = MakeDropdown("Sort", -58, function()
        local out = {}
        for _, s in ipairs(SORTS) do out[#out + 1] = { id = s[1], label = s[2], current = ns.db.sort == s[1] } end
        return out
    end, function(id) ns.db.sort = id UI.Refresh() end)

    W.bar = MakeBar(W)
    W.bar:SetPoint("TOPLEFT", 12, -88) W.bar:SetPoint("TOPRIGHT", -12, -88)
    W.info = W:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    W.info:SetPoint("TOPLEFT", 12, -106) W.info:SetWidth(496) W.info:SetJustifyH("LEFT") W.info:SetHeight(26)

    -- filters
    local function Check(text, x, y, get, set)
        local cb = CreateFrame("Button", nil, W)
        cb:SetSize(18, 18) cb:SetPoint("TOPLEFT", x, y)
        cb.edge = cb:CreateTexture(nil, "BACKGROUND") cb.edge:SetAllPoints() cb.edge:SetColorTexture(0.75, 0.75, 0.78, 1)
        cb.bg = cb:CreateTexture(nil, "BORDER") cb.bg:SetPoint("TOPLEFT", 1, -1) cb.bg:SetPoint("BOTTOMRIGHT", -1, 1) cb.bg:SetColorTexture(0.08, 0.08, 0.1, 1)
        cb.tick = cb:CreateTexture(nil, "OVERLAY") cb.tick:SetTexture("Interface\\Buttons\\UI-CheckBox-Check") cb.tick:SetAllPoints()
        cb.label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        cb.label:SetPoint("LEFT", cb, "RIGHT", 6, 0) cb.label:SetText(text)
        function cb:SetChecked(v) self.on = v self.tick:SetShown(v) end
        cb:SetScript("OnClick", function(self) set(not get()) UI.Refresh() end)
        return cb
    end
    W.cbDone = Check("Hide finished", 12, -134, function() return ns.db.hideDone end, function(v) ns.db.hideDone = v W.offset = 0 end)
    W.cbZone = Check("This zone only", 150, -134, function() return ns.db.thisZoneOnly end, function(v) ns.db.thisZoneOnly = v W.offset = 0 end)
    W.count = W:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    W.count:SetPoint("TOPRIGHT", -14, -138) W.count:SetTextColor(0.65, 0.65, 0.7)

    local all = Btn(W, "Track all shown", 120, function()
        if ReadOnly() then return end
        for _, e in ipairs(W.shown or {}) do if T.State(e.key) < 2 then T.SetPursued(e.key, true) end end
        UI.Refresh()
    end)
    all:SetPoint("TOPLEFT", 12, -160)
    local none = Btn(W, "Untrack all shown", 130, function()
        if ReadOnly() then return end
        for _, e in ipairs(W.shown or {}) do T.SetPursued(e.key, false) end
        UI.Refresh()
    end)
    none:SetPoint("LEFT", all, "RIGHT", 6, 0)
    local tick = Btn(W, "Tick all shown", 110, function()
        if ReadOnly() then return end
        for _, e in ipairs(W.shown or {}) do if T.State(e.key) < 2 then T.SetState(e.key, 2, "manual") end end
        UI.Refresh()
    end)
    tick:SetPoint("LEFT", none, "RIGHT", 6, 0)
    tick:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Tick all shown", 1, 0.82, 0)
        GameTooltip:AddLine("Marks everything in the list as finished. Handy for catching up: filter the list first, then press this. You can untick any box afterwards.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    tick:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local hdr = W:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdr:SetPoint("TOPLEFT", 12, -186) hdr:SetText("Done")
    local hdr2 = W:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdr2:SetPoint("TOPLEFT", 56, -186) hdr2:SetText("Collectible")
    local hdr3 = W:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdr3:SetPoint("TOPRIGHT", -85, -186) hdr3:SetText("Track")
    local hdr4 = W:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdr4:SetPoint("TOPRIGHT", -38, -186) hdr4:SetText("Go")

    -- rows
    W.rows = {}
    W.offset = 0
    for i = 1, MAXROWS do
        local r = CreateFrame("Button", nil, W)
        r:SetHeight(ROWH)
        r:SetPoint("TOPLEFT", 12, -TOP_LIST - (i - 1) * ROWH)
        r:SetPoint("TOPRIGHT", -12, -TOP_LIST - (i - 1) * ROWH)
        r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        r.hl = r:CreateTexture(nil, "BACKGROUND")
        r.hl:SetAllPoints() r.hl:SetColorTexture(1, 1, 1, 0.06) r.hl:Hide()
        r.box = CreateFrame("Button", nil, r)
        r.box:SetSize(18, 18) r.box:SetPoint("LEFT", 14, 0)
        r.box.edge = r.box:CreateTexture(nil, "BACKGROUND") r.box.edge:SetAllPoints() r.box.edge:SetColorTexture(0.75, 0.75, 0.78, 1)
        r.box.fill = r.box:CreateTexture(nil, "ARTWORK")
        r.box.fill:SetPoint("TOPLEFT", 1, -1) r.box.fill:SetPoint("BOTTOMRIGHT", -1, 1) r.box.fill:SetColorTexture(1, 1, 1, 1)
        r.box.check = r.box:CreateTexture(nil, "OVERLAY")
        r.box.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check") r.box.check:SetAllPoints()
        r.go = Btn(r, "Go", 34, function() if r.entry then UI.GoTo(r.entry) end end)
        r.go:SetPoint("RIGHT", -16, 0) r.go:SetHeight(18)
        r.track = Btn(r, "Track", 62, function() if r.entry and not ReadOnly() then T.TogglePursued(r.entry.key) UI.Refresh() end end)
        r.track:SetPoint("RIGHT", r.go, "LEFT", -4, 0) r.track:SetHeight(18)
        r.track.label = r.track.GetFontString and r.track:GetFontString() or r.track
        r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        r.name:SetPoint("TOPLEFT", r, "TOPLEFT", 56, -4) r.name:SetJustifyH("LEFT") r.name:SetWidth(265) r.name:SetHeight(14)
        if r.name.SetWordWrap then r.name:SetWordWrap(false) end
        r.have = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.have:SetPoint("RIGHT", r.track, "LEFT", -8, 0) r.have:SetTextColor(1, 0.82, 0)
        r.sub = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.sub:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -1) r.sub:SetJustifyH("LEFT") r.sub:SetWidth(265) r.sub:SetHeight(12)
        if r.sub.SetWordWrap then r.sub:SetWordWrap(false) end
        r.sub:SetTextColor(0.65, 0.65, 0.7)
        r.box:SetScript("OnClick", function()
            if not r.entry or ReadOnly() then return end
            local k = r.entry.key
            if r.entry.cat == "bag" then T.CycleState(k)   -- chain steps: not started, accepted, done
            else T.SetState(k, T.State(k) >= 2 and 0 or 2, "manual") end
            UI.Refresh()
        end)
        r.box:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Finished?", 1, 0.82, 0)
            GameTooltip:AddLine("Tick it when you are done with this one. The add-on also ticks things for you when it sees them happen. Sleeping Bag steps go Not started, Accepted, Done as you click.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        r.box:SetScript("OnLeave", function() GameTooltip:Hide() end)
        r.track:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Track", 1, 0.82, 0)
            GameTooltip:AddLine("Puts it on the tracker and shows it on the world map and minimap.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        r.track:SetScript("OnLeave", function() GameTooltip:Hide() end)
        r.go:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Go", 1, 0.82, 0)
            GameTooltip:AddLine("Sets your map arrow to this one and starts tracking it.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        r.go:SetScript("OnLeave", function() GameTooltip:Hide() end)
        r:SetScript("OnEnter", function(self) if not self.entry then return end self.hl:Show() RowTooltip(self) end)
        r:SetScript("OnLeave", function(self) self.hl:Hide() GameTooltip:Hide() UI.HidePreview() end)
        r:SetScript("OnClick", function(self, btn)
            local e = self.entry
            if not e then return end
            if btn == "RightButton" and e.custom then UI.AskDelete(e) return end
            UI.GoTo(e)
        end)
        W.rows[i] = r
    end
    W:EnableMouseWheel(true)
    W:SetScript("OnMouseWheel", function(self, delta) self.offset = (self.offset or 0) - delta * 3 UI.Refresh() end)
    W.scroll = CreateFrame("Slider", nil, W)
    W.scroll:SetOrientation("VERTICAL")
    W.scroll:SetWidth(10)
    W.scroll:SetPoint("TOPRIGHT", -3, -TOP_LIST)
    W.scroll:SetPoint("BOTTOMRIGHT", -3, 64)
    W.scroll.track = W.scroll:CreateTexture(nil, "BACKGROUND") W.scroll.track:SetAllPoints() W.scroll.track:SetColorTexture(1, 1, 1, 0.08)
    W.scroll:SetThumbTexture("Interface\\Buttons\\WHITE8X8")
    local th = W.scroll:GetThumbTexture()
    if th then th:SetSize(10, 36) th:SetVertexColor(0.4, 0.87, 1, 0.7) end
    W.scroll:SetValueStep(1)
    W.scroll:SetScript("OnValueChanged", function(self, v)
        if W.syncing then return end
        W.offset = math.floor(v + 0.5)
        UI.Refresh()
    end)

    W.empty = W:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    W.empty:SetPoint("TOP", W, "TOP", 0, -TOP_LIST - 20) W.empty:SetWidth(400) W.empty:SetTextColor(0.7, 0.7, 0.75)

    local add = Btn(W, "Add my own", 90, UI.AskAdd) add:SetPoint("BOTTOMLEFT", 10, 8)
    local go = Btn(W, "Go to next", 90, function()
        local a = P.live.active
        if a then T.SetWaypoint(a) else ns.Print("you are not tracking anything. Press Track on something in the list first.") end
    end)
    go:SetPoint("LEFT", add, "RIGHT", 4, 0)
    local tr = Btn(W, "Tracker", 70, function() ns.db.tracker = not ns.db.tracker UI.RefreshTracker() end) tr:SetPoint("LEFT", go, "RIGHT", 4, 0)
    local op = Btn(W, "Options", 70, function() UI.OpenOptions() end) op:SetPoint("LEFT", tr, "RIGHT", 4, 0)
    W.status = W:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    W.status:SetPoint("BOTTOMLEFT", 12, 34) W.status:SetWidth(496) W.status:SetJustifyH("LEFT")
    W.status:SetTextColor(0.65, 0.65, 0.7)
    W.status:SetText("Tick the box when finished. Track shows it on your maps. Go points your arrow at it.")
    W.faction = W:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    -- tied to the character picker (not to the title, which a window look can move), so it can never sit on top of it
    W.faction:SetPoint("RIGHT", W.who, "LEFT", -8, 0)
    W.faction:SetWidth(170) W.faction:SetJustifyH("RIGHT") W.faction:SetWordWrap(false)

    ApplyLook()
    W:SetScript("OnShow", function() ApplyLook() UI.Refresh() end)
    W:HookScript("OnHide", CloseMenu)
    if ns.WinLook then pcall(ns.WinLook.Attach, "main", W) end
end

function UI.Toggle()
    if not W then BuildWindow() end
    if W:IsShown() then W:Hide() else W:Show() end
end
function UI.Show() if not W then BuildWindow() end W:Show() end
function UI.OpenOptions() if ns.WinLook then ns.WinLook.Toggle() else ns.Print("options are not available.") end end

---------------------------------------------------------------------------
-- The tracker: what you are chasing, the step to do now, and how far away it is, updating live
---------------------------------------------------------------------------
local TR
local TROWH = 84
local TMAX = 10

local function BuildTracker()
    TR = CreateFrame("Frame", "WhatnotTracker", UIParent, "BackdropTemplate")
    TR:SetSize(310, 120)
    TR:SetFrameStrata("HIGH")
    TR:SetClampedToScreen(true)
    TR:EnableMouse(true)
    TR:SetMovable(true)
    if TR.SetBackdrop then
        TR:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        TR:SetBackdropColor(0.06, 0.06, 0.08, 0.85)
        TR:SetBackdropBorderColor(0.4, 0.87, 1, 0.6)
    end
    local p = ns.db.trackerPos
    if p then TR:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else TR:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -40, -260) end
    TR:RegisterForDrag("LeftButton")
    TR:SetScript("OnDragStart", function(self) self:StartMoving() end)
    TR:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local a, _, b, x, y = self:GetPoint()
        ns.db.trackerPos = { a, b, x, y }
    end)
    TR.titleFS = TR:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    TR.titleFS:SetPoint("TOPLEFT", 8, -6)
    TR.titleFS:SetText("Whatnot")
    TR.count = TR:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    TR.count:SetPoint("TOPRIGHT", -8, -8)
    TR.rows = {}
    for i = 1, TMAX do
        local r = CreateFrame("Button", nil, TR)
        r:SetHeight(TROWH)
        r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(26, 26) r.icon:SetPoint("TOPLEFT", 0, -2) r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        r.glow = r:CreateTexture(nil, "OVERLAY")
        r.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border") r.glow:SetBlendMode("ADD")
        r.glow:SetPoint("CENTER", r.icon, "CENTER") r.glow:SetSize(48, 48)
        r.title = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        r.title:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 6, 0) r.title:SetJustifyH("LEFT") r.title:SetWidth(190)
        r.dist = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.dist:SetPoint("TOPRIGHT", 0, -2) r.dist:SetJustifyH("RIGHT")
        r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.text:SetPoint("TOPLEFT", r.title, "BOTTOMLEFT", 0, -1) r.text:SetWidth(262) r.text:SetJustifyH("LEFT") r.text:SetJustifyV("TOP")
        r.text:SetHeight(34) r.text:SetTextColor(0.85, 0.85, 0.88)
        r.travel = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.travel:SetPoint("TOPLEFT", r.text, "BOTTOMLEFT", 0, -1) r.travel:SetWidth(262) r.travel:SetJustifyH("LEFT") r.travel:SetJustifyV("TOP")
        r.travel:SetHeight(24) r.travel:SetTextColor(0.5, 0.85, 1)
        r:SetScript("OnClick", function(self, btn)
            local e = self.entry
            if not e then return end
            if btn == "RightButton" then T.SetPursued(e.key, false) UI.Refresh()
            elseif IsShiftKeyDown() then UI.Show()
            else T.manualKey = e.key T.SetWaypoint(e) P.Refresh() end
        end)
        r:SetScript("OnEnter", function(self)
            local e = self.entry
            if not e then return end
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:SetText(e.name, 1, 0.82, 0)
            local t = T.Target(e)
            if t then GameTooltip:AddLine(t.text, 1, 1, 1, true) end
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Click: make it the active target (waypoint and arrow).", 0.7, 0.7, 0.7)
            GameTooltip:AddLine("Right-click: stop tracking it.", 0.7, 0.7, 0.7)
            GameTooltip:AddLine("Shift-click: open the list.", 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        TR.rows[i] = r
    end
    TR.bars = {}
    for i = 1, 4 do
        local b = MakeBar(TR)
        TR.bars[i] = b
    end
    if ns.WinLook then pcall(ns.WinLook.Attach, "tracker", TR) end
end

function UI.RefreshTracker()
    if not ns.db then return end
    if not TR then
        if not ns.db.tracker then return end
        BuildTracker()
    end
    local L = P.live
    local list = L.list or {}
    if not ns.db.tracker or (#list == 0 and ns.db.trackerHideEmpty) then TR:Hide() return end
    if WorldMapFrame and not TR.mapHooked then
        TR.mapHooked = true
        WorldMapFrame:HookScript("OnShow", function() UI.RefreshTracker() end)
        WorldMapFrame:HookScript("OnHide", function() UI.RefreshTracker() end)
    end
    if ns.db.trackerHideOnMap ~= false and WorldMapFrame and WorldMapFrame:IsShown() then TR:Hide() return end
    TR:Show()
    local nrows = math.min(TMAX, math.max(1, math.floor(ns.db.trackerRows or 5)))
    local y = -26
    local shown = 0
    local activeKey = L.active and L.active.key
    local _, _, curStep = T.ChainInfo()
    for i = 1, TMAX do
        local r = TR.rows[i]
        local e = i <= nrows and list[i] or nil
        if e then
            shown = shown + 1
            r.entry = e
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", TR, "TOPLEFT", 8, y)
            r:SetPoint("TOPRIGHT", TR, "TOPRIGHT", -8, y)
            y = y - TROWH
            local t = T.Target(e)
            r.icon:SetTexture(P.ICONS[e.cat] or P.ICONS.custom)
            r.glow:SetShown(e.key == activeKey)
            local c = ns.db.activeColor or { 1, 0.82, 0.1 }
            r.glow:SetVertexColor(c[1], c[2], c[3])
            local title = e.name
            if e.cat == "bag" and t.step then
                local sst = T.State(e.key)
                title = ("Sleeping Bag, step %d of %d (%s)"):format(t.step, t.steps, sst >= 2 and "done" or (sst == 1 and "accepted" or "not started"))
            end
            r.title:SetText(title)
            local text = t.text or ""
            if e.cat == "bag" and ns.db.trackerSteps then
                local ladder = {}
                for k = 1, 20 do
                    local en = T.Entry("bag:" .. k)
                    if not en then break end
                    local ks = T.State("bag:" .. k)
                    local col = ks >= 2 and "|cff55ff55" or (ks == 1 and "|cffffd100" or "|cff888888")
                    ladder[#ladder + 1] = col .. k .. "|r"
                end
                if #ladder > 0 then text = text .. "  |cffaaaaaaSteps (green done, yellow accepted):|r " .. table.concat(ladder, " ") end
            end
            r.text:SetText(text)
            local tv = T.Travel(e, t)
            r.travel:SetText(tv or "")
            local d = ns.db.trackerDistance and T.Distance(e, L.pm, L.px, L.py)
            if d then r.dist:SetText(Dist(d)) elseif t.map and L.pm and t.map ~= L.pm then r.dist:SetText("|cff888888other zone|r") else r.dist:SetText("") end
            r:Show()
        else
            r.entry = nil
            r:Hide()
        end
    end
    -- progress bars (solid = done, lighter = held, like rested XP)
    local bars = ns.db.trackerBar and BarsFor(true) or {}
    for i = 1, 4 do
        local b = TR.bars[i]
        local data = bars[i]
        if data then
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", TR, "TOPLEFT", 8, y - 2)
            b:SetPoint("TOPRIGHT", TR, "TOPRIGHT", -8, y - 2)
            y = y - 18
            SetBar(b, data.label, data.done, data.have, data.total, data.goal)
            b:Show()
        else
            b:Hide()
        end
    end
    TR.count:SetText(#list > nrows and ("%d of %d"):format(nrows, #list) or (#list .. " tracked"))
    TR:SetHeight(-y + 8)
end

ns.AddHook("live", function() UI.RefreshTracker() end)

---------------------------------------------------------------------------
-- Notices
---------------------------------------------------------------------------
local lastMap
ns.AddHook("live", function()
    local L = P.live
    if L.pm and L.pm ~= lastMap then
        lastMap = L.pm
        if ns.db.noticeZone then
            local here = {}
            for _, e in ipairs(L.list or {}) do
                local t = T.Target(e)
                if t.map == L.pm then here[#here + 1] = e.name end
            end
            if #here > 0 then
                ns.Print(("you are tracking %d thing%s in this zone: %s"):format(#here, #here == 1 and "" or "s", table.concat(here, ", ")))
            end
        end
    end
end)

ns.AddHook("changed", function(key, old, new, why)
    local e = T.Entry(key)
    if not e then return end
    if UI.RefreshAll then UI.RefreshAll() end
    if new == 2 and why ~= "manual" and why ~= "history" and ns.db.noticePickup and (T.Pursued(key) or e.cat == "bag") then
        ns.Print(("done: |cff55ff55%s|r"):format(e.name))
        if e.cat == "bag" then
            local _, _, cur = T.ChainInfo()
            local nx = cur and T.Entry(cur)
            if nx then ns.Print("next step: " .. T.Target(nx).text) else ns.Print("the Cozy Sleeping Bag chain is finished.") end
        end
    end
    if new == 2 and why ~= "manual" and why ~= "history" and ns.db.noticeSound and (T.Pursued(key) or e.cat == "bag") then
        pcall(function() PlaySound((SOUNDKIT and SOUNDKIT.IG_QUEST_LIST_COMPLETE) or 878) end)
    end
end)
ns.AddHook("pursuit", function() if UI.RefreshAll then UI.RefreshAll() end end)
function UI.RefreshAll() UI.Refresh() end

---------------------------------------------------------------------------
-- Minimap button
---------------------------------------------------------------------------
local mini
local function PlaceMini()
    local a = math.rad(ns.db.minimap.angle or 150)
    local r = ((Minimap and Minimap:GetWidth() or 140) / 2) + 6
    mini:ClearAllPoints()
    mini:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end

local function Progress()
    local lines = {}
    local t, h, d = T.Counts("book")
    lines[#lines + 1] = ("Library: %d of %d turned in%s"):format(d, t, h > 0 and (", " .. h .. " in hand") or "")
    local bt, bd = T.ChainInfo()
    lines[#lines + 1] = ("Sleeping Bag: step %d of %d done"):format(bd, bt)
    local pt, _, pd = T.Counts("pet")
    lines[#lines + 1] = ("Pets: %d of %d"):format(pd, pt)
    local st, _, sd = T.Counts("secret")
    lines[#lines + 1] = ("Secrets: %d of %d"):format(sd, st)
    local qt, _, qd = T.Counts("bagq")
    lines[#lines + 1] = ("Bags: %d of %d"):format(qd, qt)
    local gt, _, gd = T.Counts("perk")
    lines[#lines + 1] = ("Gear and perks: %d of %d"):format(gd, gt)
    local tt, _, td = T.Counts("toy")
    lines[#lines + 1] = ("Oddities: %d of %d"):format(td, tt)
    return lines
end

local function BuildMini()
    if not Minimap then return end
    mini = CreateFrame("Button", "WhatnotMinimapButton", Minimap)
    mini:SetSize(31, 31)
    mini:SetFrameStrata("MEDIUM")
    mini:SetFrameLevel(8)
    mini:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    mini:RegisterForDrag("LeftButton")
    mini:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    local icon = mini:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20) icon:SetPoint("CENTER", 0, 1)
    icon:SetTexture("Interface\\AddOns\\Whatnot\\Media\\Icon") icon:SetTexCoord(0.02, 0.98, 0.02, 0.98)
    local border = mini:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53) border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    mini:SetScript("OnClick", function(_, btn)
        if IsControlKeyDown() and _G.DavidIssues then _G.DavidIssues.Toggle("Whatnot")
        elseif IsAltKeyDown() then UI.OpenOptions()
        elseif btn == "RightButton" then ns.db.tracker = not ns.db.tracker UI.RefreshTracker()
            ns.Print("tracker " .. (ns.db.tracker and "shown" or "hidden") .. ".")
        elseif IsShiftKeyDown() then for _, l in ipairs(Progress()) do ns.Print(l) end
        else UI.Toggle() end
    end)
    mini:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            ns.db.minimap.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
            PlaceMini()
        end)
    end)
    mini:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    mini:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Whatnot", 0.4, 0.87, 1)
        for _, l in ipairs(Progress()) do GameTooltip:AddLine(l, 1, 1, 1) end
        local a = P.live.active
        if a then GameTooltip:AddLine("Chasing: " .. a.name, 1, 0.82, 0) end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Left-click: open the list.", 0.85, 0.85, 0.85)
        GameTooltip:AddLine("Right-click: show or hide the tracker.", 0.85, 0.85, 0.85)
        GameTooltip:AddLine("Shift-click: say my progress in chat.", 0.85, 0.85, 0.85)
        GameTooltip:AddLine("Alt-click: options (look, pins, tracker, notices).", 0.85, 0.85, 0.85)
        GameTooltip:AddLine("Ctrl-click: issue log (what went wrong, if anything).", 0.85, 0.85, 0.85)
        GameTooltip:AddLine("Drag: move this button.", 0.85, 0.85, 0.85)
        GameTooltip:Show()
    end)
    mini:SetScript("OnLeave", function() GameTooltip:Hide() end)
    PlaceMini()
end

function UI.UpdateMinimap()
    if not mini then BuildMini() end
    if mini then mini:SetShown(ns.db.minimap.show and true or false) end
end

ns.AddHook("login", function()
    UI.UpdateMinimap()
    C_Timer.After(3, function() P.Refresh() UI.Refresh() end)
end)

---------------------------------------------------------------------------
-- Slash command
---------------------------------------------------------------------------
local function Help()
    ns.Print("/whatnot  (or /wn) opens the list; Alt-click the minimap button for the options.")
    ns.Print("/ch pursue books | bag | pets | secrets | all   tracks a whole group; /ch stop  clears all.")
    ns.Print("/ch go  points the waypoint at the active target; /ch next  says what to do next.")
    ns.Print("/ch verify  checks every map and coordinate against your game client.")
    ns.Print("/ch chain  shows the Sleeping Bag order and where you are in it.")
    ns.Print("/ch rescan  looks again at your bags, quests and pets for things you already finished.")
    ns.Print("/ch add <name>  adds something of your own; /ch tracker  shows or hides the tracker; /ch status  shows progress.")
end

SLASH_WHATNOT1 = "/whatnot"
SLASH_WHATNOT2 = "/wn"
SLASH_WHATNOT3 = "/ch"
SlashCmdList["WHATNOT"] = function(msg)
    local cmd, rest = (msg or ""):match("^(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    if cmd == "" then UI.Toggle()
    elseif cmd == "options" or cmd == "look" then UI.OpenOptions()
    elseif cmd == "tracker" then ns.db.tracker = not ns.db.tracker UI.RefreshTracker()
    elseif cmd == "status" then for _, l in ipairs(Progress()) do ns.Print(l) end
    elseif cmd == "go" then
        local a = P.live.active
        if a then T.SetWaypoint(a) else ns.Print("nothing is being tracked.") end
    elseif cmd == "next" then
        local a = P.live.active
        if a then ns.Print(a.name .. ": " .. T.Target(a).text) else ns.Print("nothing is being tracked.") end
    elseif cmd == "chain" then
        local fac = T.FactionName()
        ns.Print("Sleeping Bag order for " .. fac .. ": " .. (T.Faction() == "H" and "Barrens burnt tower, then Westfall farmstead" or "Westfall farmstead, then Barrens burnt tower") .. ", then Stonetalon camp, Stonetalon mound, Stonewrought Dam, Thoradin's Wall (two steps).")
        for i = 1, 6 do
            local e = T.Best("bag:" .. i)
            if e then ns.Print(("step %d %s: %s"):format(i, T.State("bag:" .. i) >= 2 and "done" or (T.State("bag:" .. i) == 1 and "accepted" or "not started"), e.name)) end
        end
        local n = (C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetNumQuestLogEntries()) or 0
        for i = 1, n do
            local info = C_QuestLog.GetInfo and C_QuestLog.GetInfo(i)
            if info and not info.isHeader and info.title then
                local l = info.title:lower()
                if l:find("note") or l:find("stepping") or l:find("scramble") or l:find("wet job") or l:find("eagle") or l:find("the place") then
                    ns.Print("in your quest log: " .. info.title)
                end
            end
        end
    elseif cmd == "verify" then
        local bad, seen, n = 0, {}, 0
        for _, e in ipairs(T.all) do
            n = n + 1
            if e.map and not seen[e.map] then
                seen[e.map] = true
                local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(e.map)
                local name = info and info.name
                if not name then
                    bad = bad + 1 ns.Print(("map %d (%s) does not exist in this client."):format(e.map, e.zoneName or "?"))
                elseif e.zoneName and name ~= e.zoneName then
                    bad = bad + 1 ns.Print(("map %d is '%s' here but the list calls it '%s'."):format(e.map, name, e.zoneName))
                end
            end
            if e.x and not (e.x > 0 and e.x < 100 and e.y and e.y > 0 and e.y < 100) then
                bad = bad + 1 ns.Print("bad coordinates: " .. e.name)
            end
            if e.x and not e.map then bad = bad + 1 ns.Print(("coordinates but this client has no map called '%s': %s"):format(e.zoneName or "?", e.name)) end
        end
        ns.Print(("checked %d entries: %s"):format(n, bad == 0 and "every map and coordinate is valid in this client." or (bad .. " problem(s) above.")))
    elseif cmd == "rescan" then
        T.CheckBags() T.ScanQuestLog() T.ScanCompanions() T.ScanHistory(false)
    elseif cmd == "stop" then
        for _, e in ipairs(T.all) do T.SetPursued(e.key, false) end
        ns.Print("stopped tracking everything.")
    elseif cmd == "pursue" then
        local want = rest:lower()
        local map = { book = "book", books = "book", bag = "bag", sleeping = "bag", pet = "pet", pets = "pet", secret = "secret", secrets = "secret", bags = "bagq", storage = "bagq", gear = "perk", perks = "perk", toys = "toy", toy = "toy", disguises = "toy", oddities = "toy", oddity = "toy", novelties = "toy", masquerade = "toy" }
        local cat = map[want]
        if want ~= "all" and not cat then Help() return end
        local n = 0
        for _, e in ipairs(T.all) do
            if (want == "all" or e.cat == cat) and e.cat ~= "custom" and T.FactionOK(e) and T.State(e.key) < 2 and not T.Pursued(e.key) then
                T.SetPursued(e.key, true) n = n + 1
            end
        end
        ns.Print(("now tracking %d more thing%s."):format(n, n == 1 and "" or "s"))
    elseif cmd == "add" then
        if rest == "" then UI.AskAdd() else UI.AddCustom(rest) end
    else
        Help()
    end
end
