-- Track.lua: what you have, what is done, what to do next, and where it is.
local ADDON_NAME, ns = ...
local T = {}
ns.T = T

local ZONES = ns.ZONES
local all, byKey, keyOrder = {}, {}, {}
local itemIndex, questIndex, petIndex = {}, {}, {}
T.all = all

local function lower(s) return tostring(s or ""):lower() end
local function qkey(s) return (lower(s or ""):gsub("[^%w]+", "")) end
local function asList(v) if v == nil then return {} elseif type(v) == "table" then return v end return { v } end

-- zones the list does not have a map number for: look them up by name in this client
local mapsResolved = false
function T.ResolveMaps()
    if mapsResolved or not (C_Map and C_Map.GetMapInfo) then return end
    mapsResolved = true
    local wanted = {}
    for k, z in pairs(ZONES) do if not z[2] then wanted[z[1]] = k end end
    if next(wanted) == nil then return end
    for id = 1, 3000 do
        local ok, info = pcall(C_Map.GetMapInfo, id)
        local name = ok and info and info.name
        local k = name and wanted[name]
        if k and not ZONES[k][2] then
            ZONES[k][2] = id
            for _, e in ipairs(ns.Entries) do
                if e.zone == k then e.map = id end
            end
        end
    end
end

function T.Rebuild()
    wipe(all) wipe(byKey) wipe(keyOrder) wipe(itemIndex) wipe(questIndex) wipe(petIndex)
    local function Add(e)
        all[#all + 1] = e
        if not byKey[e.key] then byKey[e.key] = {} keyOrder[#keyOrder + 1] = e.key end
        table.insert(byKey[e.key], e)
        for _, n in ipairs(asList(e.item)) do local k = qkey(n) itemIndex[k] = itemIndex[k] or {} table.insert(itemIndex[k], e) end
        for _, n in ipairs(asList(e.quest)) do local k = qkey(n) questIndex[k] = questIndex[k] or {} table.insert(questIndex[k], e) end
        if e.pet then local k = lower(e.pet) petIndex[k] = petIndex[k] or {} table.insert(petIndex[k], e) end
    end
    T.ResolveMaps()
    for _, e in ipairs(ns.Entries) do Add(e) end
    for _, c in ipairs(ns.db.custom or {}) do
        Add({ cat = "custom", key = c.key, name = c.name, note = c.note, custom = true })
    end
end

---------------------------------------------------------------------------
-- Character, state, pursuit
---------------------------------------------------------------------------
local function RealmFallback(db, name)
    local r = GetRealmName and GetRealmName()
    if type(r) ~= "string" or r == "" then r = GetNormalizedRealmName and GetNormalizedRealmName() end
    if type(r) == "string" and r ~= "" then
        if type(db) == "table" then db.lastRealm = r end
        return r
    end
    if type(db) == "table" then
        if type(db.lastRealm) == "string" and db.lastRealm ~= "" then return db.lastRealm end
        local pre = (name or "?") .. "-"
        for _, t in pairs(db) do
            if type(t) == "table" then
                for k in pairs(t) do
                    if type(k) == "string" and #k > #pre and k:sub(1, #pre) == pre then
                        local s = k:sub(#pre + 1)
                        db.lastRealm = s
                        return s
                    end
                end
            end
        end
    end
    return ""
end
-- the game can hand back a name it will not let us use as a table key or save (a secret value); treat that as no name
local function NpcName()
    local n = UnitName("npc") or UnitName("target")
    if n ~= nil and issecretvalue and issecretvalue(n) then return nil end
    return n
end

-- two-part names ("Dr Flamel") come back from UnitName as first name + last name in the realm slot;
-- without the second part every "Dr ..." character shared one record
local function FullName()
    local first, second = UnitName("player")
    local name = first or "?"
    if type(first) == "string" and type(second) == "string" and second ~= "" and not first:find(" ", 1, true) then
        local r1 = GetRealmName and GetRealmName()
        local r2 = GetNormalizedRealmName and GetNormalizedRealmName()
        if second ~= r1 and second ~= r2 then name = first .. " " .. second end
    end
    return name
end
function T.Me() local n = FullName() return n .. "-" .. RealmFallback(_G.WhatnotDB, n) end
-- Horde or Alliance, found from the character itself (faction group first, then race)
local HORDE_RACES = { Orc = true, Tauren = true, Troll = true, Scourge = true, Undead = true, BloodElf = true, Goblin = true }
local ALLIANCE_RACES = { Human = true, Dwarf = true, NightElf = true, Gnome = true, Draenei = true, Worgen = true }
function T.Faction()
    if T.viewKey and ns.db.chars[T.viewKey] and ns.db.chars[T.viewKey].faction then return ns.db.chars[T.viewKey].faction end
    local f = UnitFactionGroup and UnitFactionGroup("player")
    if f == "Horde" then return "H" elseif f == "Alliance" then return "A" end
    local _, race = UnitRace and UnitRace("player")
    if race and HORDE_RACES[race] then return "H" end
    if race and ALLIANCE_RACES[race] then return "A" end
    return "A"
end
function T.FactionName() return T.Faction() == "H" and "Horde" or "Alliance" end

-- Viewing another character: the window reads that character's progress (nothing is ever written to it)
T.viewKey = nil
function T.ViewKey()
    local k = ns.db and ns.db.viewChar
    if k and k ~= T.Me() and ns.db.chars[k] then return k end
end
function T.ViewingOther() return T.ViewKey() ~= nil end
function T.View(fn, ...)
    T.viewKey = T.ViewKey()
    local ok, err = pcall(fn, ...)
    T.viewKey = nil
    if not ok then error(err, 0) end
end

function T.Char()
    if T.viewKey and ns.db.chars[T.viewKey] then
        local v = ns.db.chars[T.viewKey]
        v.s = v.s or {} v.p = v.p or {}
        return v
    end
    local k = T.Me()
    local c = ns.db.chars[k]
    if not c then c = { s = {}, p = {} } ns.db.chars[k] = c end
    c.s = c.s or {} c.p = c.p or {}
    c.faction = T.Faction()
    c.level = UnitLevel("player")
    return c
end

-- Progress belongs to the character, except for things that unlock for the whole account (e.acct)
function T.State(key)
    local mine = T.Char().s[key] or 0
    local e = byKey[key] and byKey[key][1]
    if e and e.acct and ns.db and ns.db.chars then
        for _, c in pairs(ns.db.chars) do
            local v = c.s and c.s[key]
            if v and v > mine then mine = v end
        end
    end
    return mine
end

-- which of your characters have finished this (state 2), as short names, you first
function T.DoneBy(key)
    local out, me = {}, T.Me()
    if not (ns.db and ns.db.chars) then return out end
    local keys = {}
    for k, c in pairs(ns.db.chars) do if c.s and (c.s[key] or 0) >= 2 then keys[#keys + 1] = k end end
    table.sort(keys, function(a, b) if a == me then return true elseif b == me then return false end return a:lower() < b:lower() end)
    for _, k in ipairs(keys) do out[#out + 1] = (k:gsub("%-.*$", "")) end
    return out
end

-- finishing a step of the sleeping-bag chain finishes the ones before it
local function ChainBefore(key)
    local n = key:match("^bag:(%d+)$")
    if not n then return nil end
    return tonumber(n)
end

function T.SetState(key, v, why)
    local c = T.Char()
    local old = c.s[key] or 0
    if v <= 0 then c.s[key] = nil else c.s[key] = v end
    if v == old then return false end
    local n = ChainBefore(key)
    if n and v >= 1 then
        for i = 1, n - 1 do
            if (c.s["bag:" .. i] or 0) < 2 then c.s["bag:" .. i] = 2 end
        end
    end
    ns.Fire("changed", key, old, v, why)
    return true
end

-- raise only (detection never lowers what you have set by hand)
function T.Raise(key, v, why)
    if T.State(key) < v then return T.SetState(key, v, why) end
    return false
end

function T.CycleState(key)
    local e = byKey[key] and byKey[key][1]
    local s = T.State(key)
    local nxt = s + 1
    if nxt > 2 then nxt = 0 end
    -- things with no "have" stage go straight to done
    if e and (e.cat == "pet" or e.cat == "secret" or e.cat == "custom" or e.cat == "perk" or e.cat == "toy") and nxt == 1 then nxt = 2 end
    T.SetState(key, nxt, "manual")
end

function T.Pursued(key) return T.Char().p[key] and true or false end
function T.SetPursued(key, on)
    local c = T.Char()
    local was = c.p[key] and true or false
    c.p[key] = on and true or nil
    if was ~= (on and true or false) then ns.Fire("pursuit", key, on) end
end
function T.TogglePursued(key) T.SetPursued(key, not T.Pursued(key)) end

---------------------------------------------------------------------------
-- Filters
---------------------------------------------------------------------------
function T.Entry(key) return byKey[key] and byKey[key][1] end
function T.Alternatives(key) return byKey[key] or {} end

local function ClassToken()
    local _, c = UnitClass and UnitClass("player")
    return c
end
T.ClassToken = ClassToken
local function FactionOK(e)
    if ns.db.factionFilter == "all" then return true end
    -- looking at one class's section of Gear and perks shows that class even when you are not it
    local browsing = ns.db.cat == "perk" and ns.db.perkGroup
    -- Gear and perks always lists every class's entries (the sections divide them)
    if e.class and not browsing and e.cat ~= "perk" and e.class ~= ClassToken() then return false end
    return e.fac == nil or e.fac == T.Faction()
end
T.FactionOK = FactionOK

local function LevelOK(e)
    if not ns.db.hideTooHigh then return true end
    return (e.lvl or 1) <= (UnitLevel("player") or 1) + (ns.db.levelGap or 10)
end

---------------------------------------------------------------------------
-- Where we are and how far things are
---------------------------------------------------------------------------
function T.PlayerPos()
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then return nil end
    local map = C_Map.GetBestMapForUnit("player")
    if not map then return nil end
    local p = C_Map.GetPlayerMapPosition(map, "player")
    if not p then return nil end
    local x, y = p:GetXY()
    if not x or (x == 0 and y == 0) then return nil end
    return map, x * 100, y * 100
end

local sizes = {}
function T.MapSize(map)
    if sizes[map] then return sizes[map][1], sizes[map][2] end
    if C_Map and C_Map.GetMapWorldSize then
        local ok, w, h = pcall(C_Map.GetMapWorldSize, map)
        if ok and w and h and w > 0 and h > 0 then sizes[map] = { w, h } return w, h end
    end
end

-- yards east and north of the player to a point on the same map; nil when we cannot tell
function T.Offset(map, x, y, pm, px, py)
    if not (map and x and y) then return nil end
    if not pm then pm, px, py = T.PlayerPos() end
    if pm ~= map then return nil end
    local w, h = T.MapSize(map)
    if not w then return nil end
    return (x - px) / 100 * w, -(y - py) / 100 * h
end

function T.Distance(e, pm, px, py)
    local t = T.Target(e)
    if not t or not t.map then return nil end
    local dx, dy = T.Offset(t.map, t.x, t.y, pm, px, py)
    if not dx then return nil end
    return math.sqrt(dx * dx + dy * dy)
end

---------------------------------------------------------------------------
-- What to do next for one thing
---------------------------------------------------------------------------
local function Where(e)
    local s = ""
    if e.zoneName then
        s = e.zoneName
        if e.x and ns.db.showCoords then s = s .. (" (%.1f, %.1f)"):format(e.x, e.y) end
    end
    return s
end
T.Where = Where

function T.ChainInfo()
    local total, done, cur = 0, 0, nil
    for i = 1, 20 do
        local k = "bag:" .. i
        if not byKey[k] then break end
        total = total + 1
        if T.State(k) >= 2 then done = done + 1 elseif not cur then cur = k end
    end
    return total, done, cur
end

-- what the person should do for this entry right now: { map, x, y, zone, text, kind }

---------------------------------------------------------------------------
-- Getting there: boats, zeppelins and flight masters
---------------------------------------------------------------------------
local KALIMDOR = { orgrimmar=1, darkshore=1, barrens=1, stonetalon=1, needles=1, desolace=1, dustwallow=1, tanaris=1,
    azshara=1, felwood=1, winterspring=1, thunderbluff=1, darnassus=1, feralas=1,
    teldrassil=1, durotar=1, mulgore=1 }
local FM = {   -- zone key = { Alliance flight master town, Horde flight master town }
    elwynn = { "Goldshire", nil }, stormwind = { "Stormwind", nil }, westfall = { "Sentinel Hill", nil },
    duskwood = { "Darkshire", nil }, redridge = { "Lakeshire", nil }, lochmodan = { "Thelsamar", nil },
    wetlands = { "Menethil Harbor", nil }, ironforge = { "Ironforge", nil }, dunmorogh = { "Kharanos", nil },
    stv = { "Booty Bay", "Booty Bay" }, swamp = { "Booty Bay", "Stonard" }, arathi = { "Refuge Pointe", "Hammerfall" },
    hinterlands = { "Aerie Peak", "Revantusk Village" }, hillsbrad = { "Southshore", "Tarren Mill" },
    alterac = { "Southshore", "Tarren Mill" }, badlands = { "Thelsamar", "Kargath" }, searing = { "Thorium Point", "Thorium Point" },
    blasted = { "Nethergarde Keep", "Stonard" }, burning = { "Morgan's Vigil", "Flame Crest" },
    wpl = { "Chillwind Camp", "The Bulwark" }, epl = { "Light's Hope Chapel", "Light's Hope Chapel" },
    tirisfal = { nil, "Brill" }, silverpine = { nil, "The Sepulcher" }, undercity = { nil, "Undercity" },
    barrens = { "Ratchet", "The Crossroads" }, stonetalon = { "Sun Rock Retreat", "Sun Rock Retreat" },
    needles = { "Thalanaar", "Freewind Post" }, desolace = { "Nijel's Point", "Shadowprey Village" },
    dustwallow = { "Theramore Isle", "Brackenwall Village" }, tanaris = { "Gadgetzan", "Gadgetzan" },
    azshara = { "Talrendis Point", "Valormok" }, felwood = { "Talonbranch Glade", "Bloodvenom Post" },
    winterspring = { "Everlook", "Everlook" }, darkshore = { "Auberdine", nil }, feralas = { "Feathermoon Stronghold", "Camp Mojache" },
    durotar = { nil, "Razor Hill" }, mulgore = { nil, "Bloodhoof Village" }, teldrassil = { "Rut'theran Village", nil },
    orgrimmar = { nil, "Orgrimmar" }, thunderbluff = { nil, "Thunder Bluff" }, darnassus = { "Darnassus", nil },
}
local zoneOfMap
local function ZoneKeyOfMap(map)
    if not zoneOfMap then
        zoneOfMap = {}
        for k, z in pairs(ZONES) do if z[2] then zoneOfMap[z[2]] = k end end
    end
    return map and zoneOfMap[map]
end
-- "K" for Kalimdor, "E" for the Eastern Kingdoms, nil when unknown
local function ContinentOfMap(map)
    local k = ZoneKeyOfMap(map)
    if k then return KALIMDOR[k] and "K" or "E" end
    local id, n = map, 0
    while id and n < 8 do
        if id == 1414 then return "K" elseif id == 1415 then return "E" end
        local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(id)
        id = info and info.parentMapID
        if id == 0 then id = nil end
        n = n + 1
    end
end
function T.Travel(e, target)
    if not ns.db.trackerTravel then return nil end
    local t = target or T.Target(e)
    if not (t and t.map) then return nil end
    local pm = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if not pm or pm == t.map then return nil end
    local here, there = ContinentOfMap(pm), ContinentOfMap(t.map)
    if not (here and there) then return nil end
    local horde = T.Faction() == "H"
    if here ~= there then
        if horde then
            if here == "K" then
                return "Wrong continent. Take the zeppelin from Orgrimmar to Undercity (or to Grom'gol Base Camp in Stranglethorn Vale)."
            else
                return "Wrong continent. Take the zeppelin from Undercity or Grom'gol Base Camp to Orgrimmar."
            end
        else
            if here == "E" then
                return "Wrong continent. Take the boat from Menethil Harbor (Wetlands) to Auberdine (Darkshore), or from Stormwind Harbor to Rut'theran Village (Teldrassil)."
            else
                return "Wrong continent. Take the boat from Auberdine to Menethil Harbor, or from Rut'theran Village to Stormwind Harbor."
            end
        end
    end
    local tk = ZoneKeyOfMap(t.map)
    local fm = tk and FM[tk]
    local town = fm and fm[horde and 2 or 1]
    if town then
        return ("Far away? Fly to %s with a flight master, then go on to %s."):format(town, t.zone or "the spot")
    end
    return nil
end

function T.Target(e)
    local st = T.State(e.key)
    if e.cat == "book" then
        if st == 1 then
            local lp = ns.LIBRARIAN_POINTS[T.Faction()] or ns.LIBRARIAN_POINTS.A
            local z = ZONES[lp.zone]
            return { map = z[2], x = lp.x, y = lp.y, zone = z[1],
                text = ("You have it. Turn it in to %s."):format(lp.name), kind = "turnin" }
        end
        local text = ("Go to %s: %s."):format(Where(e), e.place or "")
        if e.note and ns.db.showHints then text = text .. " " .. e.note end
        return { map = e.map, x = e.x, y = e.y, zone = e.zoneName, text = text, kind = "find" }
    elseif e.cat == "bag" then
        local total, done = T.ChainInfo()
        local n = tonumber(e.key:match("(%d+)$")) or 0
        if n == 1 and st == 1 then
            -- the note sends you to the other faction's site as the second stop
            for _, v in ipairs(byKey["bag:1"] or {}) do
                if v ~= e and v.fac ~= e.fac and v.x then
                    return { map = v.map, x = v.x, y = v.y, zone = v.zoneName, kind = "step", step = 1, steps = total,
                        text = ("Second stop, the note sends you here: %s: %s"):format(Where(v), v.place or "") }
                end
            end
        end
        local text
        if st == 1 then
            text = ("Started. Finish '%s'. %s"):format(e.quest or e.name, e.place or "")
        else
            text = ("%s: %s"):format(Where(e), e.place or "")
        end
        if e.note and ns.db.showHints then text = text .. " " .. e.note end
        return { map = e.map, x = e.x, y = e.y, zone = e.zoneName, text = text, kind = "step", step = n, steps = total }
    else
        local text = e.note or e.name
        if e.zoneName and e.cat ~= "custom" and not (e.note or ""):find(e.zoneName, 1, true) then text = Where(e) .. ": " .. text end
        return { map = e.map, x = e.x, y = e.y, zone = e.zoneName, text = text, kind = "find" }
    end
end

---------------------------------------------------------------------------
-- Counts and the library milestones
---------------------------------------------------------------------------
function T.Counts(cat)
    local total, have, done = 0, 0, 0
    for _, key in ipairs(keyOrder) do
        local list = byKey[key]
        local e = list[1]
        if (cat == nil or e.cat == cat) then
            local ok = false
            for _, x in ipairs(list) do if FactionOK(x) then ok = true break end end
            if ok then
                total = total + 1
                local s = T.State(key)
                if s >= 2 then done = done + 1 elseif s == 1 then have = have + 1 end
            end
        end
    end
    return total, have, done
end

-- the next library reward: { books, lvl, quest, rewards, done, have, need }
function T.Milestone()
    local _, have, done = T.Counts("book")
    for _, m in ipairs(ns.MILESTONES) do
        if done < m.books then
            return { books = m.books, lvl = m.lvl, quest = m.quest, rewards = m.rewards, done = done, have = have, need = m.books - done }
        end
    end
    return nil, done, have
end

---------------------------------------------------------------------------
-- Lists for the window and the tracker
---------------------------------------------------------------------------
local function ZoneMatches(e, map)
    return map and e.map == map
end

function T.List()
    local db = ns.db
    local out = {}
    local pm, px, py = T.PlayerPos()
    local cat = db.cat
    local seen = {}
    for _, e in ipairs(all) do
        local ok = FactionOK(e) and LevelOK(e)
        if ok and cat == "pursuing" then
            ok = T.Pursued(e.key) and not seen[e.key]
            if ok then
                -- one row per thing: the nearest way to do it
                e = T.Best(e.key, pm, px, py) or e
                seen[e.key] = true
            end
        elseif ok and cat ~= "all" then
            ok = e.cat == cat
        end
        if ok and db.hideDone and T.State(e.key) >= 2 then ok = false end
        if ok and db.thisZoneOnly and not ZoneMatches(e, pm) then ok = false end
        if ok then out[#out + 1] = e end
    end
    local idx = {}
    for i, e in ipairs(out) do idx[e] = i end
    if db.sort == "level" then
        table.sort(out, function(a, b) if (a.lvl or 0) ~= (b.lvl or 0) then return (a.lvl or 0) < (b.lvl or 0) end return idx[a] < idx[b] end)
    elseif db.sort == "zone" then
        table.sort(out, function(a, b)
            local am, bm = ZoneMatches(a, pm) and 0 or 1, ZoneMatches(b, pm) and 0 or 1
            if am ~= bm then return am < bm end
            return idx[a] < idx[b]
        end)
    elseif db.sort == "distance" then
        local d = {}
        for _, e in ipairs(out) do d[e] = T.Distance(e, pm, px, py) or 1e9 end
        table.sort(out, function(a, b) if d[a] ~= d[b] then return d[a] < d[b] end return idx[a] < idx[b] end)
    end
    if cat == "perk" and db.perkGroup and ns.PerkGroup then
        local f = {}
        for _, e in ipairs(out) do if ns.PerkGroup(e) == db.perkGroup then f[#f + 1] = e end end
        out = f
    end
    return out
end

-- of several ways to do one thing (a book in two places), the nearest, else the first
function T.Best(key, pm, px, py)
    local best, bd
    for _, e in ipairs(byKey[key] or {}) do
        if FactionOK(e) then
            local d = T.Distance(e, pm, px, py)
            if not best or (d and (not bd or d < bd)) then best, bd = e, d end
        end
    end
    return best
end

-- pursued things that still need doing, one entry each; sleeping-bag steps only as the current step
function T.Pursuits()
    local out = {}
    local pm, px, py = T.PlayerPos()
    local _, _, curStep = T.ChainInfo()
    for _, key in ipairs(keyOrder) do
        if T.Pursued(key) and T.State(key) < 2 then
            local e = T.Best(key, pm, px, py)
            if e and LevelOK(e) then
                if e.cat ~= "bag" or key == curStep then out[#out + 1] = e end
            end
        end
    end
    if ns.db.trackerOrder == "distance" then
        local d = {}
        for _, e in ipairs(out) do d[e] = T.Distance(e, pm, px, py) or 1e9 end
        local idx = {}
        for i, e in ipairs(out) do idx[e] = i end
        table.sort(out, function(a, b) if d[a] ~= d[b] then return d[a] < d[b] end return idx[a] < idx[b] end)
    end
    return out
end

-- the one thing the arrows and the Blizzard waypoint point at
T.manualKey = nil
function T.Active()
    local list = T.Pursuits()
    if #list == 0 then return nil, list end
    if T.manualKey then
        for _, e in ipairs(list) do if e.key == T.manualKey then return e, list end end
        T.manualKey = nil
    end
    for _, e in ipairs(list) do
        local t = T.Target(e)
        if t.map then return e, list end
    end
    return list[1], list
end

---------------------------------------------------------------------------
-- Waypoint
---------------------------------------------------------------------------
local lastWp
function T.SetWaypoint(e, quiet)
    local t = e and T.Target(e)
    local mode = ns.db.waypoint
    if not t or not t.map or not t.x then
        if not quiet then ns.Print("no map coordinates for that one (" .. (e and e.name or "?") .. ").") end
        return false
    end
    if mode == "none" then return false end
    local sig = ("%s:%s:%s:%s"):format(t.map, t.x, t.y, mode)
    if quiet and sig == lastWp then return true end
    lastWp = sig
    if mode == "blizzard" or mode == "both" then
        if C_Map and C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates then
            pcall(function()
                C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(t.map, t.x / 100, t.y / 100))
                if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then C_SuperTrack.SetSuperTrackedUserWaypoint(true) end
            end)
        end
    end
    if (mode == "tomtom" or mode == "both") and TomTom and TomTom.AddWaypoint then
        pcall(TomTom.AddWaypoint, TomTom, t.map, t.x / 100, t.y / 100, { title = e.name, from = "Whatnot", persistent = false, minimap = true, world = true })
    end
    if not quiet then ns.Print(("waypoint set: %s, %s"):format(e.name, Where({ zoneName = t.zone, x = t.x, y = t.y }))) end
    return true
end
function T.ClearWaypoint()
    lastWp = nil
    if C_Map and C_Map.ClearUserWaypoint then pcall(C_Map.ClearUserWaypoint) end
end

---------------------------------------------------------------------------
-- Detection: bags, quests, companions, the librarian
---------------------------------------------------------------------------
local prevBags, bagsReady = {}, false
local function ScanBags()
    local set, raw = {}, {}
    local getN = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
    local getLink = (C_Container and C_Container.GetContainerItemLink) or GetContainerItemLink
    if not (getN and getLink) then return nil end
    -- the bags you are wearing count too
    if ContainerIDToInventoryID and GetInventoryItemLink then
        for bag = 1, 4 do
            local ok, inv = pcall(ContainerIDToInventoryID, bag)
            local link = ok and inv and GetInventoryItemLink("player", inv)
            local name = link and link:match("|h%[(.-)%]|h")
            if name then set[qkey(name)] = (set[qkey(name)] or 0) + 1 raw[#raw + 1] = name end
        end
    end
    for bag = 0, 5 do
        local n = getN(bag) or 0
        for slot = 1, n do
            local link = getLink(bag, slot)
            if link then
                local name = link:match("|h%[(.-)%]|h")
                if name then set[qkey(name)] = (set[qkey(name)] or 0) + 1 raw[#raw + 1] = name end
            end
        end
    end
    T.lastBagNames = raw
    return set
end
T.ScanBagsRaw = ScanBags

local libUntil = 0
function T.AtLibrarian() return GetTime() < libUntil end

-- Learning tool: does handing in a library book flag a hidden quest id? Snapshot the finished-quest ids
-- when a librarian is opened, and after each turn-in record which ids are new. The result goes into
-- the saved data (probe.turnins) so the book-to-id pattern can be worked out, and old turn-ins read back.
local snapIds
local function FinishedSet()
    local ok0, raw = pcall(function() return GetQuestsCompleted and GetQuestsCompleted() end)
    if not ok0 or type(raw) ~= "table" then return nil end
    local set = {}
    -- the game can hand back a list it will not let us walk (secret keys); then there is nothing to compare
    local ok = pcall(function() for id, v in pairs(raw) do if type(v) == "number" then set[v] = true elseif v then set[id] = true end end end)
    if not ok then return nil end
    return set
end
function T.SnapFinished()
    snapIds = FinishedSet()
end
local function RecordTurnIn(bookName)
    C_Timer.After(1.5, function()
        local now, before = FinishedSet(), snapIds
        if not (now and before) then return end
        local new = {}
        for id in pairs(now) do if not before[id] then new[#new + 1] = id end end
        table.sort(new)
        local p = ns.db.probe or {}
        ns.db.probe = p
        p.turnins = p.turnins or {}
        p.turnins[#p.turnins + 1] = { book = bookName, newIds = table.concat(new, ","), when = date and date("%Y-%m-%d %H:%M") or "?" }
        snapIds = now
        ns.Print(("recorded the turn-in of %s (%d new quest flag%s)."):format(bookName, #new, #new == 1 and "" or "s"))
    end)
end

function T.CheckBags()
    local set = ScanBags()
    if not set then return end
    -- things that are in the bags now
    for name in pairs(set) do
        for _, e in ipairs(itemIndex[name] or {}) do
            if e.cat == "book" then
                if T.Raise(e.key, 1, "bags") and ns.db.noticePickup then
                    local _, _, done = T.Counts("book")
                    ns.Print(("picked up the book |cffffd100%s|r. Turn it in at the library (%d turned in so far)."):format(e.name, done))
                end
            else
                T.Raise(e.key, 2, "item")
            end
        end
    end
    -- a plain list of what is in the bags, for working out names that do not match (saved data: bagDump)
    do
        local names = {}
        for _, n in ipairs(T.lastBagNames or {}) do names[#names + 1] = n end
        table.sort(names)
        local sig = table.concat(names, "|")
        if sig ~= T.bagSig then
            T.bagSig = sig
            ns.db.bagDump = { when = date and date("%Y-%m-%d %H:%M") or "?", items = names }
        end
    end
    -- books that left the bags while talking to a librarian, or right after a quest was handed in, were turned in
    local atLib = T.AtLibrarian()
    local justTurned = GetTime() - (T.lastTurnIn or -999) < 20
    if bagsReady then
        for name in pairs(prevBags) do
            if not set[name] then
                for _, e in ipairs(itemIndex[name] or {}) do
                    if e.cat == "book" then
                        local log = ns.db.bagLog or {}
                        ns.db.bagLog = log
                        log[#log + 1] = { book = e.name, atLibrarian = atLib and true or false, afterQuest = justTurned and true or false,
                            npc = NpcName(), when = date and date("%Y-%m-%d %H:%M") or "?" }
                        while #log > 30 do table.remove(log, 1) end
                        if atLib or justTurned then
                            if T.State(e.key) < 2 then T.SetState(e.key, 2, "turnin") end
                            RecordTurnIn(e.name)
                        end
                    end
                end
            end
        end
        if atLib then T.ProbeLibrarian("bags") end
    end
    prevBags = set
    bagsReady = true
end

local function QuestStarted(title)
    for _, e in ipairs(questIndex[qkey(title)] or {}) do
        if e.cat == "bag" or e.cat == "secret" or e.cat == "bagq" or e.cat == "perk" or e.cat == "toy" then T.Raise(e.key, 1, "quest") end
    end
end
local function QuestDone(title)
    for _, e in ipairs(questIndex[qkey(title)] or {}) do T.Raise(e.key, 2, "quest") end
    for _, m in ipairs(ns.MILESTONES) do
        if qkey(m.quest) == qkey(title) then
            ns.Print("library reward quest turned in. Well read!")
            break
        end
    end
end

local titles = {}
local function TitleFor(questID, logIndex)
    if questID and titles[questID] then return titles[questID] end
    local t
    if questID and C_QuestLog and C_QuestLog.GetTitleForQuestID then t = C_QuestLog.GetTitleForQuestID(questID) end
    if not t and logIndex and GetQuestLogTitle then t = (GetQuestLogTitle(logIndex)) end
    if not t and logIndex and C_QuestLog and C_QuestLog.GetInfo then
        local info = C_QuestLog.GetInfo(logIndex)
        t = info and info.title
    end
    if t and questID then titles[questID] = t end
    return t
end

function T.ScanQuestLog()
    local n = 0
    if C_QuestLog and C_QuestLog.GetNumQuestLogEntries then n = C_QuestLog.GetNumQuestLogEntries() or 0
    elseif GetNumQuestLogEntries then n = GetNumQuestLogEntries() or 0 end
    for i = 1, n do
        local title, header, questID
        if C_QuestLog and C_QuestLog.GetInfo then
            local info = C_QuestLog.GetInfo(i)
            if info then title, header, questID = info.title, info.isHeader, info.questID end
        elseif GetQuestLogTitle then
            title, _, _, header, _, _, _, questID = GetQuestLogTitle(i)
        end
        if title and not header then
            if questID then titles[questID] = title end
            QuestStarted(title)
        end
    end
end

function T.ScanCompanions()
    if not (GetNumCompanions and GetCompanionInfo) then return end
    local n = GetNumCompanions("CRITTER") or 0
    for i = 1, n do
        local cid, name = GetCompanionInfo("CRITTER", i)
        if name then
            local ln = lower(name)
            if tonumber(cid) and ns.db then ns.db.seenModels = ns.db.seenModels or {} ns.db.seenModels[ln] = tonumber(cid) end
            for pname, list in pairs(petIndex) do
                if ln == pname or ln:find(pname, 1, true) or pname:find(ln, 1, true) then
                    for _, e in ipairs(list) do T.Raise(e.key, 2, "pet") end
                end
            end
        end
    end
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "BAG_UPDATE_DELAYED", "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_LOG_UPDATE", "COMPANION_LEARNED",
    "COMPANION_UPDATE", "NEW_PET_ADDED", "GOSSIP_SHOW", "QUEST_GREETING", "QUEST_DETAIL", "QUEST_PROGRESS", "QUEST_COMPLETE",
    "GOSSIP_CLOSED", "QUEST_FINISHED", "PLAYER_ENTERING_WORLD" }) do
    pcall(ev.RegisterEvent, ev, e)
end


-- the game keeps a plain finished/in-log flag for every quest number, so this needs no names at all
function T.ScanQuestIDs()
    if not (C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted) then return end
    local changed = false
    for _, e in ipairs(all) do
        local q = e.qid
        if q then
            local ok, done = pcall(C_QuestLog.IsQuestFlaggedCompleted, q)
            if ok and done then
                if T.Raise(e.key, 2, "quest") then changed = true end
            else
                local onLog = false
                if C_QuestLog.GetLogIndexForQuestID then
                    local ok2, idx = pcall(C_QuestLog.GetLogIndexForQuestID, q)
                    onLog = ok2 and idx and idx > 0
                elseif C_QuestLog.IsOnQuest then
                    local ok2, on = pcall(C_QuestLog.IsOnQuest, q)
                    onLog = ok2 and on
                end
                if onLog and T.Raise(e.key, 1, "quest") then changed = true end
            end
        end
    end
    return changed
end

-- quests finished before the add-on was installed (or on an earlier session) still count
local histBusy = false
function T.ScanHistory(quiet)
    if histBusy then return end
    local raw
    if GetQuestsCompleted then
        local ok, r = pcall(GetQuestsCompleted)
        if ok then raw = r end
    end
    if not raw and C_QuestLog and C_QuestLog.GetAllCompletedQuestIDs then
        local ok, r = pcall(C_QuestLog.GetAllCompletedQuestIDs)
        if ok then raw = r end
    end
    if type(raw) ~= "table" then
        if not quiet then ns.Print("this client cannot list finished quests, so tick them by hand.") end
        return
    end
    local ids = {}
    for k, v in pairs(raw) do
        -- the game can hand back {id1, id2, ...} (the numbers are the values) or {[id] = true} (the numbers are the keys)
        if type(v) == "number" then ids[#ids + 1] = v elseif type(k) == "number" and v then ids[#ids + 1] = k end
    end
    histBusy = true
    local found, missing, pos = 0, {}, 1
    local rewardHits = 0
    local seenTitles, resolved, allTitles = {}, 0, {}
    -- a finished quest named after a library book (the turn-in) means that book is done
    local bookKeys = {}
    for _, e in ipairs(all) do
        if e.cat == "book" then
            local k = qkey(e.name)
            if #k >= 8 then bookKeys[#bookKeys + 1] = { k = k, e = e } end
            local k2 = qkey((e.name:gsub("^[Tt]he%s+", "")))
            if k2 ~= k and #k2 >= 8 then bookKeys[#bookKeys + 1] = { k = k2, e = e } end
        end
    end
    local rewardTitle = {}
    for _, m in ipairs(ns.MILESTONES) do rewardTitle[qkey(m.quest)] = true end
    local function TitleOf(id)
        local title
        if C_QuestLog and C_QuestLog.GetTitleForQuestID then title = C_QuestLog.GetTitleForQuestID(id) end
        if not title and C_QuestLog and C_QuestLog.GetQuestInfo then title = C_QuestLog.GetQuestInfo(id) end
        if not title and QuestUtils_GetQuestName then title = QuestUtils_GetQuestName(id) end
        if type(title) == "string" and title ~= "" then return title end
    end
    local function Check(id, collectMissing)
        local ok, title = pcall(TitleOf, id)
        if ok and title then
            resolved = resolved + 1
            allTitles[#allTitles + 1] = ('%s (%d)'):format(title, id)
            if rewardTitle[qkey(title)] then rewardHits = rewardHits + 1 end
            local lt = title:lower()
            if questIndex[qkey(title)] or lt:find("note you found") or lt:find("stepping") or lt:find("scramble") or lt:find("wet job") or lt:find("eagle") or lt:find("must be the place") or lt:find("library") then
                seenTitles[#seenTitles + 1] = ("%s (%d)"):format(title, id)
            end
            local tk = qkey(title)
            for _, b in ipairs(bookKeys) do
                if tk == b.k or tk:find(b.k, 1, true) then
                    if T.State(b.e.key) < 2 and T.Raise(b.e.key, 2, "history") then found = found + 1 end
                end
            end
            local list = questIndex[qkey(title)]
            if list then
                for _, e in ipairs(list) do
                    if T.State(e.key) < 2 and T.Raise(e.key, 2, "history") then found = found + 1 end
                end
            end
        elseif collectMissing then
            missing[#missing + 1] = id
        end
    end
    local function Finish()
        histBusy = false
        -- a plain record of what the game says is finished, so it can be compared with the list
        local log = {}
        local n = (C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetNumQuestLogEntries()) or 0
        for i = 1, n do
            local info = C_QuestLog.GetInfo and C_QuestLog.GetInfo(i)
            if info and not info.isHeader and info.title then log[#log + 1] = info.title end
        end
        local st = {}
        for _, e in ipairs(all) do
            local s = T.State(e.key)
            if s > 0 and FactionOK(e) then st[#st + 1] = ("%s = %d"):format(e.key, s) end
        end
        ns.db.debug = {
            when = date and date("%Y-%m-%d %H:%M") or "?",
            character = T.Me(),
            completedTotal = #ids, titlesKnown = resolved,
            finishedThatMatter = seenTitles,
            allFinished = allTitles,
            inQuestLog = log,
            listStates = st,
        }
        if rewardHits > 0 then
            -- each library reward quest finished means that many more books were handed in
            local m = ns.MILESTONES[math.min(rewardHits, #ns.MILESTONES)]
            if m then T.Char().libMin = m.books end
        end
        if not quiet or found > 0 then
            ns.Print(("checked %d finished quests and ticked %d of your list."):format(#ids, found))
        end
        if ns.UI and ns.UI.RefreshAll then ns.UI.RefreshAll() end
    end
    local function Second()
        -- quests whose names the game has not loaded yet: ask for them in batches, then look again
        if not (C_QuestLog and C_QuestLog.RequestLoadQuestByID) or #missing == 0 then Finish() return end
        local idx = 1
        local function Chunk()
            local from = idx
            local last = math.min(idx + 199, #missing)
            for i = from, last do pcall(C_QuestLog.RequestLoadQuestByID, missing[i]) end
            idx = last + 1
            C_Timer.After(1.2, function()
                for i = from, last do Check(missing[i], false) end
                if idx <= #missing then
                    Chunk()
                else
                    -- one last look at anything that was slow to arrive
                    C_Timer.After(3, function()
                        for i = 1, #missing do Check(missing[i], false) end
                        Finish()
                    end)
                end
            end)
        end
        Chunk()
    end
    local function Step()
        local last = math.min(pos + 249, #ids)
        for i = pos, last do Check(ids[i], true) end
        pos = last + 1
        if pos <= #ids then C_Timer.After(0.02, Step) else Second() end
    end
    Step()
end


-- notes what the game shows at a librarian, so the add-on can learn how hand-ins are counted
function T.ProbeLibrarian(why)
    local p = ns.db.probe or {}
    ns.db.probe = p
    p.when = date and date("%Y-%m-%d %H:%M") or nil
    p.why = why
    p.npc = NpcName()
    pcall(function()
        if C_GossipInfo then
            p.text = C_GossipInfo.GetText and C_GossipInfo.GetText() or p.text
            local o = C_GossipInfo.GetOptions and C_GossipInfo.GetOptions() or {}
            p.options = {}
            for i, x in ipairs(o) do p.options[i] = x.name or x.text or "?" end
            local a = C_GossipInfo.GetAvailableQuests and C_GossipInfo.GetAvailableQuests() or {}
            p.available = {}
            for i, x in ipairs(a) do p.available[i] = x.title or "?" end
            local ac = C_GossipInfo.GetActiveQuests and C_GossipInfo.GetActiveQuests() or {}
            p.active = {}
            for i, x in ipairs(ac) do p.active[i] = x.title or "?" end
        end
    end)
    pcall(function()
        local raw = GetQuestsCompleted and GetQuestsCompleted()
        if type(raw) == "table" then
            local n = 0
            for _ in pairs(raw) do n = n + 1 end
            p.completedCount = n
        end
    end)
end

local npcSeen, qlTimer
ev:SetScript("OnEvent", function(_, event, a1, a2)
    if not ns.db then return end
    if event == "BAG_UPDATE_DELAYED" then
        T.CheckBags()
    elseif event == "QUEST_ACCEPTED" then
        C_Timer.After(0.5, T.ScanQuestIDs)
        local questID = tonumber(a2) or (type(a1) == "number" and a1 > 100000 and a1) or nil
        local title = TitleFor(questID, a1)
        if title then QuestStarted(title) end
    elseif event == "QUEST_TURNED_IN" then
        C_Timer.After(0.5, T.ScanQuestIDs)
        local title = TitleFor(a1)
        T.lastTurnIn = GetTime()
        do   -- what was handed in, and to whom (saved data: turnLog)
            local log = ns.db.turnLog or {}
            ns.db.turnLog = log
            log[#log + 1] = { id = a1, title = title or "?", npc = NpcName(), when = date and date("%Y-%m-%d %H:%M") or "?" }
            while #log > 40 do table.remove(log, 1) end
        end
        C_Timer.After(1.5, T.CheckBags)
        if title then QuestDone(title) end
    elseif event == "QUEST_LOG_UPDATE" then
        if not qlTimer then
            qlTimer = true
            C_Timer.After(1, function() qlTimer = false T.ScanQuestIDs() end)
        end
    elseif event == "COMPANION_LEARNED" or event == "COMPANION_UPDATE" or event == "NEW_PET_ADDED" then
        T.ScanCompanions()
    elseif event == "GOSSIP_SHOW" or event == "QUEST_GREETING" or event == "QUEST_DETAIL" or event == "QUEST_PROGRESS" or event == "QUEST_COMPLETE" then
        local npc = NpcName()
        if npc and ns.LIBRARIANS[npc] then
            libUntil = GetTime() + 25
            if event == "GOSSIP_SHOW" then T.ProbeLibrarian("gossip") T.SnapFinished() end
            if event == "GOSSIP_SHOW" and ns.db.noticeLibrarian and npc ~= npcSeen then
                npcSeen = npc
                T.CheckBags()
                local _, have = T.Counts("book")
                if have > 0 then ns.Print(("you are carrying %d book%s to turn in."):format(have, have == 1 and "" or "s")) end
            end
        end
    elseif event == "GOSSIP_CLOSED" or event == "QUEST_FINISHED" then
        npcSeen = nil
        if T.AtLibrarian() then libUntil = GetTime() + 8 end
        C_Timer.After(1, T.CheckBags)
    elseif event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(2, function() T.CheckBags() T.ScanQuestLog() T.ScanQuestIDs() T.ScanCompanions() end)
        C_Timer.After(5, function() T.ScanHistory(true) end)
    end
end)

ns.AddHook("login", T.Rebuild)
