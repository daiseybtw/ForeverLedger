--[[
Forever Ledger
Tracks gold + bag/bank items for every character, and shares that data between
WoW accounts. SavedVariables are per-account in WoW, so cross-account sharing is
done two ways:
  1. Live: whisper-based sync between characters you list with /ledger link
  2. Manual: /ledger export on one account, /ledger import on the other
Nothing is ever sent to anyone who is not on your link list.
]]

local ADDON = ...
local PREFIX = "FLedger"
local ROW_H = 20
local DB
local LX = {} -- functions exported from the ledger-capture block

local state = {
    bankOpen = false,
    staging = {},
    lastReply = {},
    lastSender = {},
    lastSend = 0,
}

------------------------------------------------------------------------
-- helpers
------------------------------------------------------------------------
local function chat(msg)
    print("|cff33ccffLedger|r: " .. tostring(msg))
end

local function split(s, sep)
    local t, start = {}, 1
    while true do
        local i = s:find(sep, start, true)
        if not i then
            t[#t + 1] = s:sub(start)
            break
        end
        t[#t + 1] = s:sub(start, i - 1)
        start = i + 1
    end
    return t
end

local function cleanLabel(s)
    s = tostring(s or ""):gsub("[^%w _%-]", "")
    return (s:sub(1, 24))
end

-- profession names: keep letters (including accented ones), spaces, apostrophes, hyphens
local function cleanName(s)
    s = tostring(s or ""):gsub("[%^,:|%c]", "")
    return (s:sub(1, 30))
end

-- free text kept in notes, to-dos and ledger lines: nothing that could break the sync format
local function cleanText(s, n)
    s = tostring(s or ""):gsub("[%^|,;:~%c]", " ")
    s = s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    return (s:sub(1, n or 80))
end

-- ids sort by creation time; the counter keeps tasks made in the same second in order
local idSeq
local function newId()
    idSeq = ((idSeq or math.random(0, 2000)) + 1) % 4096
    return string.format("%x%03x", time(), idSeq)
end

local function validKey(key)
    return type(key) == "string" and #key <= 48 and key:match("^[^%^%-]+%-[^%^]+$") ~= nil
end

local function clamp(n, lo, hi)
    n = tonumber(n) or 0
    if n < lo then return lo end
    if n > hi then return hi end
    return n
end

local function formatNum(n)
    local s, k = tostring(math.floor(n)), 0
    repeat
        s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
    until k == 0
    return s
end

local function moneyStr(m)
    m = math.floor(m or 0)
    local g, s, c = math.floor(m / 10000), math.floor(m / 100) % 100, m % 100
    if g > 0 then
        return string.format("%s|cffffd700g|r %d|cffc7c7cfs|r %d|cffeda55fc|r", formatNum(g), s, c)
    elseif s > 0 then
        return string.format("%d|cffc7c7cfs|r %d|cffeda55fc|r", s, c)
    end
    return string.format("%d|cffeda55fc|r", c)
end

local function goldStr(m)
    return formatNum((m or 0) / 10000) .. "|cffffd700g|r"
end

local function deltaStr(n)
    n = math.floor(n or 0)
    if n > 0 then return "|cff4dc77f+" .. moneyStr(n) .. "|r" end
    if n < 0 then return "|cffe66155-" .. moneyStr(-n) .. "|r" end
    return "|cff8a93a3no change|r"
end

local DAY = 86400
local function dayNum(t) return math.floor((t or time()) / DAY) end
local function dayLabel(d)
    local fn = date or (os and os.date)
    if not fn then return tostring(d) end
    return fn("%d %b", d * DAY + 43200)
end

local function ago(t)
    if not t then return "?" end
    local d = time() - t
    if d < 60 then return "just now" end
    if d < 3600 then return math.floor(d / 60) .. "m ago" end
    if d < 86400 then return math.floor(d / 3600) .. "h ago" end
    return math.floor(d / 86400) .. "d ago"
end

local function classColor(class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c then
        return string.format("|cff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
    end
    return "|cffffffff"
end

local function nameOf(key)
    return (key:match("^([^%-]+)"))
end

-- Forever characters have a first AND a last name, and first names repeat (two "Shorkiee"s can
-- live on one account), so everything is keyed on the full "First Last" name. The game returns the
-- last name as the second value of UnitName. Comparisons use canon(): lower case, "-" or spaces
-- between the parts all become a single space, so "Shorkiee-Smith" == "shorkiee smith".
local function canon(n)
    n = tostring(n or ""):lower():gsub("[%-%s]+", " ")
    n = n:gsub("^ ", ""):gsub(" $", "")
    return n
end

local function normName(n)
    return canon(n)
end

local function titleCase(n)
    n = canon(n):gsub("(%S+)", function(w) return w:sub(1, 1):upper() .. w:sub(2) end)
    return n
end

local function selfLast()
    local _, last = UnitName("player")
    if type(last) == "string" and last ~= "" and last ~= (GetRealmName and GetRealmName() or "") then return last end
end

local function selfName()
    local first = UnitName("player")
    local last = selfLast()
    return last and (first .. " " .. last) or first
end

local function myKey()
    return selfName() .. "-" .. GetRealmName()
end

-- does a typed name refer to this local character key? A bare first name matches too.
local function sameChar(typed, key)
    local t, k = canon(typed), canon(nameOf(key))
    if t == "" then return false end
    return t == k or t == (k:match("^(%S+)") or k)
end

-- find a character of THIS account from the start of a command argument, which may be
-- "First Last roles..." or "First roles...". Returns key, character, rest, or nil, "ambiguous".
local function findLocalChar(arg)
    local w1, w2, after2 = arg:match("^(%S+)%s+(%S+)%s*(.-)$")
    local w1only, rest1 = arg:match("^(%S+)%s*(.-)$")
    if w1 and w2 then
        for key, c in pairs(DB.chars) do
            if c.localChar and canon(nameOf(key)) == canon(w1 .. " " .. w2) then return key, c, after2 end
        end
    end
    if not w1only then return nil end
    local found, n = nil, 0
    for key, c in pairs(DB.chars) do
        if c.localChar then
            local k = canon(nameOf(key))
            if k == canon(w1only) then return key, c, rest1 end
            if (k:match("^(%S+)") or k) == canon(w1only) then found, n = key, n + 1 end
        end
    end
    if n == 1 then return found, DB.chars[found], rest1 end
    if n > 1 then return nil, "ambiguous" end
end

-- a trusted (linked) character, found by canonical name; old links held only a first name
local function trustedKey(who)
    if DB.trusted[who] then return who end
    local first = who:match("^(%S+)")
    if first and DB.trusted[first] then return first end
end

-- addon whispers need a target name; Forever puts the last name where other clients put the realm,
-- so we address "First Last" (confirmed on Forever). /ledger whisperstyle dash switches it, and the style
-- is learnt automatically from whatever the other account's sender names look like.
local function whisperName(display)
    if DB.whisperStyle == "dash" then return (display:gsub(" ", "-")) end
    return display
end

------------------------------------------------------------------------
-- container scanning (works with legacy and C_Container APIs)
------------------------------------------------------------------------
local function slotsOf(bag)
    if C_Container and C_Container.GetContainerNumSlots then
        return C_Container.GetContainerNumSlots(bag) or 0
    end
    return GetContainerNumSlots and GetContainerNumSlots(bag) or 0
end

local function slotItem(bag, slot)
    if C_Container and C_Container.GetContainerItemInfo then
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info then return info.hyperlink, info.stackCount or 1 end
        return nil
    end
    local _, count, _, _, _, _, link = GetContainerItemInfo(bag, slot)
    return link, count
end

local function scanBags(bagList)
    local t = {}
    for _, bag in ipairs(bagList) do
        for slot = 1, slotsOf(bag) do
            local link, count = slotItem(bag, slot)
            local id = link and tonumber(link:match("item:(%d+)"))
            if id then
                t[id] = (t[id] or 0) + (count or 1)
                -- remember the item's name from its link so we can show and sync it later
                if DB and DB.itemNames and not DB.itemNames[id] then
                    local nm = link:match("%[(.-)%]")
                    if nm then DB.itemNames[id] = nm:sub(1, 60) end
                end
            end
        end
    end
    return t
end

local function bagIDs()
    local ids = {}
    for b = 0, (NUM_BAG_SLOTS or 4) do ids[#ids + 1] = b end
    return ids
end

local function bankIDs()
    local ids = { -1 }
    local first = (NUM_BAG_SLOTS or 4) + 1
    for b = first, first + (NUM_BANKBAGSLOTS or 6) - 1 do ids[#ids + 1] = b end
    return ids
end

local function merge(a, b)
    local t = {}
    for id, n in pairs(a or {}) do t[id] = n end
    for id, n in pairs(b or {}) do t[id] = (t[id] or 0) + n end
    return t
end

-- One gold reading per character per day (the last one of the day), kept for ~4 months.
local function recordHistory(c)
    if not state.entered or c.money == nil then return end
    local today = dayNum()
    c.hist = c.hist or {}
    if not c.hist0 then c.hist0 = { d = today, m = c.money } end -- first reading ever: lets "today" show growth on day one
    c.hist[today] = c.money
    local cutoff = today - 120
    for d in pairs(c.hist) do
        if d < cutoff then c.hist[d] = nil end
    end
end

local function updateSelf(fullScan, trustMoney)
    if not DB then return end
    local key = myKey()
    local c = DB.chars[key] or {}
    DB.chars[key] = c
    c.account = DB.account
    c.class = select(2, UnitClass("player"))
    c.faction = UnitFactionGroup("player")
    c.level = UnitLevel("player")
    -- GetMoney() can report 0 during the first moments of login, so don't trust it until
    -- the character has entered the world (unless we have nothing stored yet).
    -- A reading of 0 is only believed when the game just told us the gold changed (PLAYER_MONEY),
    -- because GetMoney() also returns 0 during login/logout and would wipe the stored amount.
    local m = GetMoney() or 0
    if c.money == nil then
        c.money = m
    elseif state.entered and (m > 0 or trustMoney) then
        c.money = m
    end
    c.time = time()
    c.localChar = true
    c.remote = nil
    recordHistory(c)
    if fullScan then
        local ok, err = pcall(function()
            c.bags = scanBags(bagIDs())
            if state.bankOpen then c.bank = scanBags(bankIDs()) end
            c.items = merge(c.bags, c.bank)
        end)
        if not ok then state.lastError = "bags: " .. tostring(err) end
    end
end


------------------------------------------------------------------------
-- warehouse roles: categories by item class/subclass (Classic IDs)
-- {classID, subclassID or nil for "any subclass"}
------------------------------------------------------------------------
local CATEGORIES = {
    herbs     = { label = "Herbs",           { 7, 9 } },
    cloth     = { label = "Cloth",           { 7, 5 } },
    leather   = { label = "Leather",         { 7, 6 } },
    ore       = { label = "Metal & Stone",   { 7, 7 } },
    cooking   = { label = "Cooking goods",   { 7, 8 } },
    elemental = { label = "Elemental",       { 7, 10 } },
    enchant   = { label = "Enchanting mats", { 7, 12 } },
    tradegood = { label = "All trade goods", { 7, nil } },
    potions   = { label = "Potions/elixirs", { 0, 1 }, { 0, 2 }, { 0, 3 } },
    gems      = { label = "Gems",            { 3, nil } },
    recipes   = { label = "Recipes",         { 9, nil } },
}
local CATEGORY_ORDER = { "herbs", "cloth", "leather", "ore", "cooking", "elemental", "enchant", "tradegood", "potions", "gems", "recipes" }

-- classID, subClassID for any valid item id (no server query). The function moved into C_Item in
-- recent clients (including Forever); the old global is kept as a fallback for older ones.
local function itemClassInfo(id)
    local fn = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not fn then return nil end
    local _, _, _, _, _, a, b = fn(id)
    return a, b
end

local catCache = {}
local function itemCats(id)
    local r = catCache[id]
    if r then return r end
    r = {}
    local class, sub = itemClassInfo(id)
    if class then
        for name, def in pairs(CATEGORIES) do
            for _, rule in ipairs(def) do
                if rule[1] == class and (rule[2] == nil or rule[2] == sub) then r[name] = true end
            end
        end
        catCache[id] = r -- only cache once the game actually knew the item
    end
    return r
end

-- Item names: the client's own cache first, then names we remembered or received from synced characters.
local function itemName(id)
    local fn = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local n = fn and fn(id)
    if n then
        if DB and DB.itemNames and not DB.itemNames[id] then DB.itemNames[id] = n end
        return n
    end
    return DB and DB.itemNames and DB.itemNames[id] or nil
end

-- Trade goods grouped for the Materials view. nil means "not a trade good".
local TRADE_GROUP_ORDER = { "herbs", "cloth", "leather", "ore", "cooking", "elemental", "enchant", "other" }
local function tradeGroup(id)
    local cats = itemCats(id)
    if not cats.tradegood then return nil end
    for _, k in ipairs(TRADE_GROUP_ORDER) do
        if cats[k] then return k end
    end
    return "other"
end

-- "herbs,ah" -> { "herbs", "ah" }; unknown or duplicate tokens dropped
local function parseRoles(s)
    local out, seen = {}, {}
    for tok in tostring(s or ""):gmatch("[^,%s]+") do
        tok = tok:lower()
        if (CATEGORIES[tok] or tok == "ah") and not seen[tok] and #out < 12 then
            seen[tok] = true
            out[#out + 1] = tok
        end
    end
    return out
end

-- Professions a character can be ASSIGNED (planned), separate from what the skill scan finds.
-- The first nine are primary professions (a character can learn two); the rest are secondary.
local PROFESSIONS = {
    { "alchemy", "Alchemy" }, { "blacksmithing", "Blacksmithing" }, { "enchanting", "Enchanting" },
    { "engineering", "Engineering" }, { "herbalism", "Herbalism" }, { "leatherworking", "Leatherworking" },
    { "mining", "Mining" }, { "skinning", "Skinning" }, { "tailoring", "Tailoring" },
    { "cooking", "Cooking" }, { "firstaid", "First Aid" }, { "fishing", "Fishing" },
}
local PROF_LABEL, PROF_PRIMARY = {}, {}
for i, p in ipairs(PROFESSIONS) do
    PROF_LABEL[p[1]] = p[2]
    PROF_PRIMARY[p[1]] = i <= 9
end

-- "First Aid" -> "firstaid", to match scanned skill names against assignments (English clients)
local function profToken(name)
    return (tostring(name or ""):lower():gsub("[^%a]", ""))
end

local function parseAssigned(s)
    local out, seen = {}, {}
    for tok in tostring(s or ""):gmatch("[^,%s]+") do
        tok = tok:lower()
        if PROF_LABEL[tok] and not seen[tok] and #out < 12 then
            seen[tok] = true
            out[#out + 1] = tok
        end
    end
    return out
end

local function hasRole(c, role)
    for _, r in ipairs(c.roles or {}) do
        if r == role then return true end
    end
    return false
end

local function roleTag(c)
    if not c.roles or #c.roles == 0 then return "" end
    local names = {}
    for _, r in ipairs(c.roles) do
        names[#names + 1] = (r == "ah") and "AH" or r
    end
    return " |cff66ccff[" .. table.concat(names, ", ") .. "]|r"
end

-- Skill list access. Forever provides C_SkillInfo (GetSkillLineInfo returns a table); older
-- Classic clients have the global functions that return several values. Both are supported.
local function skillNum()
    if C_SkillInfo and C_SkillInfo.GetNumSkillLines then return C_SkillInfo.GetNumSkillLines() or 0 end
    if GetNumSkillLines then return GetNumSkillLines() or 0 end
    return 0
end

-- returns name, isHeader, isExpanded, rank, maxRank
local function skillLine(i)
    if C_SkillInfo and C_SkillInfo.GetSkillLineInfo then
        local info = C_SkillInfo.GetSkillLineInfo(i)
        if not info then return nil end
        return info.name, info.isHeader, not info.isCollapsed, info.rank, info.maxRank
    end
    if GetSkillLineInfo then
        local name, header, isExpanded, rank, _, _, maxRank = GetSkillLineInfo(i)
        return name, header, isExpanded, rank, maxRank
    end
end

local function skillSetHeader(i, expand)
    local ns = C_SkillInfo
    if expand then
        if ns and ns.ExpandSkillHeader then ns.ExpandSkillHeader(i) elseif ExpandSkillHeader then ExpandSkillHeader(i) end
    else
        if ns and ns.CollapseSkillHeader then ns.CollapseSkillHeader(i) elseif CollapseSkillHeader then CollapseSkillHeader(i) end
    end
end

-- Professions + secondary skills (name, rank, max). The skill list hides entries under collapsed
-- headers, so we expand everything, read it, and collapse again what the player had collapsed.
local function scanProfessions()
    if not DB then return false end
    if SkillFrame and SkillFrame.IsShown and SkillFrame:IsShown() then return false end -- leave the skills window alone
    if skillNum() == 0 then return false end -- skills not loaded yet (or no skill API on this client)
    local profHeader = TRADE_SKILLS or "Professions"
    local secHeader = SECONDARY_SKILLS or "Secondary Skills"
    local ok, profs = pcall(function()
        local collapsed, names = {}, {}
        for i = 1, skillNum() do
            local name, header, isExpanded = skillLine(i)
            if header and not isExpanded then collapsed[#collapsed + 1] = { i = i, name = name } end
        end
        for n = #collapsed, 1, -1 do -- last to first so earlier indices stay valid
            names[collapsed[n].name] = true
            skillSetHeader(collapsed[n].i, true)
        end
        local found, section, seen = {}, nil, {}
        for i = 1, skillNum() do
            local name, header, _, rank, maxRank = skillLine(i)
            if header then
                section = name
            elseif name and (maxRank or 0) > 0 and #found < 8 then
                -- accept by section header (any language) or by a known profession name
                local token = profToken(name)
                if (section == profHeader or section == secHeader or PROF_LABEL[token]) and not seen[token] then
                    seen[token] = true
                    found[#found + 1] = { name = cleanName(name), rank = rank or 0, max = maxRank }
                end
            end
        end
        for i = skillNum(), 1, -1 do
            local name, header = skillLine(i)
            if header and names[name] then skillSetHeader(i, false) end
        end
        return found
    end)
    state.skillScanAt = GetTime()
    if not ok or type(profs) ~= "table" then
        state.lastError = "professions: " .. tostring(profs)
        return false
    end
    local c = DB.chars[myKey()]
    if not c then return false end
    c.profs = profs
    c.time = time()
    return true
end

------------------------------------------------------------------------
-- shared notes, to-dos, ledger entries and play time
------------------------------------------------------------------------
local function changed()
    if state.onChange then state.onChange() end
end

-- records that sync between accounts use a timestamp that always moves forward
local function bumpTs(rec)
    rec.ts = math.max(time(), (rec.ts or 0) + 1)
end

-- Zone layout for the map: { continent, name, column, row }. A tile-grid map: each zone is a tile
-- placed roughly where it sits in the world.
local ZONE_LAYOUT = {
    { "ek", "Tirisfal Glades", 1, 1 }, { "ek", "Western Plaguelands", 2, 1 }, { "ek", "Eastern Plaguelands", 3, 1 },
    { "ek", "Silverpine Forest", 1, 2 }, { "ek", "Hillsbrad Foothills", 2, 2 }, { "ek", "Alterac Mountains", 3, 2 },
    { "ek", "Arathi Highlands", 3, 3 }, { "ek", "The Hinterlands", 4, 3 },
    { "ek", "Wetlands", 3, 4 },
    { "ek", "Dun Morogh", 1, 5 }, { "ek", "Loch Modan", 2, 5 }, { "ek", "Badlands", 3, 5 },
    { "ek", "Searing Gorge", 2, 6 }, { "ek", "Burning Steppes", 3, 6 },
    { "ek", "Elwynn Forest", 1, 7 }, { "ek", "Redridge Mountains", 2, 7 }, { "ek", "Deadwind Pass", 3, 7 },
    { "ek", "Westfall", 1, 8 }, { "ek", "Duskwood", 2, 8 }, { "ek", "Swamp of Sorrows", 3, 8 },
    { "ek", "Stranglethorn Vale", 2, 9 }, { "ek", "Blasted Lands", 3, 9 },
    { "kal", "Teldrassil", 1, 1 }, { "kal", "Winterspring", 3, 1 }, { "kal", "Moonglade", 4, 1 },
    { "kal", "Darkshore", 1, 2 }, { "kal", "Felwood", 3, 2 }, { "kal", "Azshara", 5, 2 },
    { "kal", "Ashenvale", 2, 3 }, { "kal", "Durotar", 4, 3 },
    { "kal", "Stonetalon Mountains", 2, 4 }, { "kal", "The Barrens", 3, 4 },
    { "kal", "Desolace", 1, 5 }, { "kal", "Mulgore", 3, 5 }, { "kal", "Dustwallow Marsh", 4, 5 },
    { "kal", "Feralas", 1, 6 }, { "kal", "Thousand Needles", 3, 6 },
    { "kal", "Un'Goro Crater", 3, 7 }, { "kal", "Tanaris", 4, 7 },
    { "kal", "Silithus", 3, 8 },
}
local BUILTIN_ZONE = {}
for _, z in ipairs(ZONE_LAYOUT) do BUILTIN_ZONE[z[2]] = true end
local RATING_NAMES = { [0] = "Unrated", "Poor", "Okay", "Good", "Great" }

local function ensureZone(name)
    DB.zones = DB.zones or {}
    local z = DB.zones[name]
    if not z then
        z = { rating = 0, ts = 0, notes = {} }
        DB.zones[name] = z
    end
    if (z.rating or 0) < 0 then z.rating = 0 end -- an area that was removed and is being added again
    return z
end

local function currentZoneName()
    local z = (GetRealZoneText and GetRealZoneText()) or (GetZoneText and GetZoneText()) or ""
    if z == nil or z == "" then z = (GetZoneText and GetZoneText()) or "" end
    return cleanText(z, 40)
end

-- player position on the current map, in tenths of a percent (so 42.1 is stored as 421)
local function playerCoords()
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then return end
    local ok, x, y = pcall(function()
        local id = C_Map.GetBestMapForUnit("player")
        if not id then return end
        local pos = C_Map.GetPlayerMapPosition(id, "player")
        if not pos then return end
        return pos:GetXY()
    end)
    if ok and type(x) == "number" and type(y) == "number" and x > 0 and y > 0 then
        local mapID
        pcall(function() mapID = C_Map.GetBestMapForUnit("player") end)
        return math.floor(x * 1000 + 0.5), math.floor(y * 1000 + 0.5), mapID
    end
end

local MAX_NOTES = 8
local function addZoneNote(name, text, withCoords, at)
    text = cleanText(text, 80)
    if name == "" or text == "" then return false, "empty" end
    local z = ensureZone(name)
    if #z.notes >= MAX_NOTES then return false, "full" end
    local x, y, mapID = 0, 0, nil
    if at then
        x, y, mapID = at.x, at.y, at.m
    elseif withCoords and currentZoneName() == name then
        x, y, mapID = playerCoords()
    end
    z.notes[#z.notes + 1] = { id = newId(), x = x or 0, y = y or 0, m = mapID or 0, text = text }
    bumpTs(z)
    return true
end

local function noteText(n)
    if n.x and n.x > 0 then
        return string.format("(%.1f, %.1f) %s", n.x / 10, n.y / 10, n.text)
    end
    return n.text
end

-- to-do items: DB.todos[id] = { text, char ("" = anyone), done, del (removed, kept briefly so removal syncs), ts }
local MAX_TODOS = 150
local function addTodo(text, charName)
    text = cleanText(text, 80)
    if text == "" then return false end
    DB.todos = DB.todos or {}
    local n = 0
    for _ in pairs(DB.todos) do n = n + 1 end
    if n >= MAX_TODOS then return false, "full" end
    local t = { text = text, char = cleanText(charName or "", 30), done = false, del = false, ts = 0 }
    bumpTs(t)
    DB.todos[newId()] = t
    return true
end

local function todoCreated(id)
    return tonumber(id:sub(1, math.max(1, #id - 3)), 16) or 0
end

local function purgeTodos()
    local cutoff = time() - 30 * 86400
    for id, t in pairs(DB.todos or {}) do
        if t.del and (t.ts or 0) < cutoff then DB.todos[id] = nil end
    end
end

-- ledger entries: c.ledger = { { t = time, k = "v"|"p"|"a"|"l"(loot)|"q"(quest), d = text, m = copper change }, ... }
local LEDGER_CAP = 300
local function plainMoney(m)
    m = math.floor(math.abs(m or 0))
    local g, s, c = math.floor(m / 10000), math.floor(m / 100) % 100, m % 100
    local out = {}
    if g > 0 then out[#out + 1] = formatNum(g) .. "g" end
    if s > 0 then out[#out + 1] = s .. "s" end
    if c > 0 or #out == 0 then out[#out + 1] = c .. "c" end
    return table.concat(out, " ")
end

-- merge: a function(count) -> text. Entries of the same kind that arrive close together (loot drops while
-- farming) are folded into one line so a gold farm doesn't push everything else out of the ledger.
local function addEntry(kind, desc, amount, merge)
    if not DB then return end
    local c = DB.chars[myKey()]
    if not c then return end
    c.ledger = c.ledger or {}
    local now = time()
    local last = c.ledger[#c.ledger]
    if merge and last and last.k == kind and now - last.t < 180 and now - (last.s or last.t) < 900 then
        last.n = (last.n or 1) + 1
        last.m = last.m + math.floor(amount or 0)
        last.t = now
        last.d = cleanText(merge(last.n), 70)
        c.time = now
        state.entries = (state.entries or 0) + 1
        changed()
        return
    end
    c.ledger[#c.ledger + 1] = { t = now, k = kind, d = cleanText(merge and merge(1) or desc, 70), m = math.floor(amount or 0), s = now, n = 1 }
    while #c.ledger > LEDGER_CAP do table.remove(c.ledger, 1) end
    c.time = time() -- so the other account accepts the new entries
    state.entries = (state.entries or 0) + 1
    changed()
end

-- time played, in seconds, for a character (the one you are playing keeps counting up)
local function playedSeconds(key, c)
    local p = c.played
    if not (p and p.total) then return nil end
    if c.localChar and key == myKey() and state.entered then
        return p.total + math.max(0, time() - (p.at or time()))
    end
    return p.total
end

-- Zone notes and to-dos are shared as individual lines; newer timestamp wins.
local function sharedLines()
    local out = {}
    for name, z in pairs(DB.zones or {}) do
        local nn = cleanText(name, 40)
        if nn ~= "" then
            local base = string.format("Z^%s^%d^%d", nn, z.rating or 0, z.ts or 0)
            if z.notes and #z.notes > 0 then
                for _, n in ipairs(z.notes) do
                    out[#out + 1] = string.format("%s^%s^%d^%d^%s^%d", base, n.id, n.x or 0, n.y or 0, cleanText(n.text, 80), n.m or 0)
                end
            else
                out[#out + 1] = base .. "^^0^0^"
            end
        end
    end
    for id, t in pairs(DB.todos or {}) do
        out[#out + 1] = string.format("K^%s^%d^%d^%d^%s^%s", id, t.done and 1 or 0, t.del and 1 or 0, t.ts or 0,
            cleanText(t.char or "", 24), cleanText(t.text, 80))
    end
    return out
end

local function handleShared(kind, f)
    DB.zones = DB.zones or {}
    DB.todos = DB.todos or {}
    if kind == "Z" then
        local name = cleanText(f[2], 40)
        if name == "" then return end
        local rating, ts = clamp(f[3], -1, 4), clamp(f[4], 0, 4e9)
        local z = DB.zones[name]
        if not z then
            local count = 0
            for _ in pairs(DB.zones) do count = count + 1 end
            if count >= 200 then return end
            z = { rating = rating, ts = 0, notes = {} }
            DB.zones[name] = z
        end
        if ts > (z.ts or 0) then
            z.rating, z.ts, z.notes = rating, ts, {}
        elseif ts < (z.ts or 0) or ts == 0 then
            return
        end
        local id = f[5] or ""
        if id:match("^%x+$") and #id <= 12 and #z.notes < MAX_NOTES then
            for _, n in ipairs(z.notes) do
                if n.id == id then return "shared" end
            end
            z.notes[#z.notes + 1] = { id = id, x = clamp(f[6], 0, 1000), y = clamp(f[7], 0, 1000), text = cleanText(f[8], 80), m = clamp(f[9], 0, 100000) }
        end
        return "shared"
    elseif kind == "K" then
        local id = f[2] or ""
        if not (id:match("^%x+$") and #id <= 12) then return end
        local ts = clamp(f[5], 0, 4e9)
        local t = DB.todos[id]
        if t and (t.ts or 0) >= ts then return end
        if not t then
            local count = 0
            for _ in pairs(DB.todos) do count = count + 1 end
            if count >= MAX_TODOS then return end
        end
        DB.todos[id] = { done = f[3] == "1", del = f[4] == "1", ts = ts, char = cleanText(f[6], 30), text = cleanText(f[7], 80) }
        return "shared"
    end
end

------------------------------------------------------------------------
-- serialisation (one line per addon message / per export line)
------------------------------------------------------------------------
local function charLines(key, c)
    local lines = {}
    lines[1] = table.concat({
        "C", key, c.account or "", c.class or "", c.faction or "",
        c.level or 0, c.money or 0, c.time or 0,
        table.concat(c.roles or {}, ","),
        (c.auctions and c.auctions.n) or 0, (c.auctions and c.auctions.value) or 0,
    }, "^")
    local buf, n = {}, 0
    for id, cnt in pairs(c.items or {}) do
        local s = id .. ":" .. cnt
        if n + #s + 1 > 180 then
            lines[#lines + 1] = "I^" .. key .. "^" .. table.concat(buf, ",")
            buf, n = {}, 0
        end
        buf[#buf + 1] = s
        n = n + #s + 1
    end
    if #buf > 0 then lines[#lines + 1] = "I^" .. key .. "^" .. table.concat(buf, ",") end
    if c.profs and #c.profs > 0 then
        local parts, plen = {}, 0
        for i, p in ipairs(c.profs) do
            local entry = p.name .. ":" .. p.rank .. ":" .. p.max
            if i > 8 or plen + #entry + 1 > 170 then break end -- keep the whole addon message under 255 bytes
            parts[#parts + 1] = entry
            plen = plen + #entry + 1
        end
        lines[#lines + 1] = "P^" .. key .. "^" .. table.concat(parts, ",")
    end
    if c.assigned and #c.assigned > 0 then
        lines[#lines + 1] = "A^" .. key .. "^" .. table.concat(c.assigned, ",")
    end
    if c.auctionList and #c.auctionList > 0 then
        local abuf, an = {}, 0
        for _, a in ipairs(c.auctionList) do
            local e = a.id .. ":" .. a.qty .. ":" .. a.buyout
            if an + #e + 1 > 180 then
                lines[#lines + 1] = "L^" .. key .. "^" .. table.concat(abuf, ",")
                abuf, an = {}, 0
            end
            abuf[#abuf + 1] = e
            an = an + #e + 1
        end
        if #abuf > 0 then lines[#lines + 1] = "L^" .. key .. "^" .. table.concat(abuf, ",") end
    end
    -- daily gold history (last 90 days) for the wealth chart
    if c.hist then
        local days = {}
        for d in pairs(c.hist) do days[#days + 1] = d end
        table.sort(days)
        local hbuf, hn = {}, 0
        for i = math.max(1, #days - 89), #days do
            local e = string.format("%d:%d", days[i], c.hist[days[i]])
            if hn + #e + 1 > 170 then
                lines[#lines + 1] = "H^" .. key .. "^" .. table.concat(hbuf, ",")
                hbuf, hn = {}, 0
            end
            hbuf[#hbuf + 1] = e
            hn = hn + #e + 1
        end
        if #hbuf > 0 then lines[#lines + 1] = "H^" .. key .. "^" .. table.concat(hbuf, ",") end
    end
    if c.played and c.played.total then
        lines[#lines + 1] = string.format("Y^%s^%d^%d", key, c.played.total, c.played.at or 0)
    end
    -- recent ledger entries (last 14 days, at most 30)
    if c.ledger and #c.ledger > 0 then
        local picked, cutoff = {}, time() - 14 * 86400
        for i = #c.ledger, 1, -1 do
            local e = c.ledger[i]
            if e.t < cutoff or #picked >= 30 then break end
            table.insert(picked, 1, e)
        end
        local gbuf, gn = {}, 0
        for _, e in ipairs(picked) do
            local enc = string.format("%d:%s:%d:%s", e.t, e.k, e.m, cleanText(e.d, 70))
            if gn + #enc + 1 > 170 and #gbuf > 0 then
                lines[#lines + 1] = "G^" .. key .. "^" .. table.concat(gbuf, ";")
                gbuf, gn = {}, 0
            end
            gbuf[#gbuf + 1] = enc
            gn = gn + #enc + 1
        end
        if #gbuf > 0 then lines[#lines + 1] = "G^" .. key .. "^" .. table.concat(gbuf, ";") end
    end
    -- names for this character's trade goods and listed items, so the other account can show them
    -- without having seen the items
    local names, nlen = {}, 0
    local function flushNames()
        if #names > 0 then
            lines[#lines + 1] = "N^" .. key .. "^" .. table.concat(names, ",")
            names, nlen = {}, 0
        end
    end
    local want = {}
    for id in pairs(c.items or {}) do
        if tradeGroup(id) then want[id] = true end
    end
    for _, a in ipairs(c.auctionList or {}) do want[a.id] = true end
    for id in pairs(want) do
        local nm = itemName(id)
        if nm then
            local entry = id .. "=" .. (nm:gsub("[%^,=|%c]", ""))
            if nlen + #entry + 1 > 180 then flushNames() end
            names[#names + 1] = entry
            nlen = nlen + #entry + 1
        end
    end
    flushNames()
    lines[#lines + 1] = "E^" .. key
    return lines
end

local function localChars()
    local list = {}
    for key, c in pairs(DB.chars) do
        if c.localChar then list[#list + 1] = key end
    end
    table.sort(list)
    return list
end

-- Returns "committed" when a full character record was stored.
local function handleLine(line, source)
    local f = split(line, "^")
    local kind, key = f[1], f[2]
    if kind == "Z" or kind == "K" then return handleShared(kind, f) end
    if not validKey(key) then return end
    local existing = DB.chars[key]
    if existing and existing.localChar then return end -- never overwrite our own account's characters
    local sk = source .. "|" .. key

    if kind == "C" then
        local faction = f[5]
        if faction ~= "Alliance" and faction ~= "Horde" then faction = nil end
        local class = (f[4] or ""):upper()
        if not class:match("^%u+$") then class = nil end
        local label = cleanLabel(f[3])
        if label == "" then label = "Other" end
        state.staging[sk] = {
            account = label, class = class, faction = faction,
            level = clamp(f[6], 0, 100), money = clamp(f[7], 0, 1e10),
            time = tonumber(f[8]) or 0, items = {}, n = 0, names = {}, nn = 0, alist = {}, hist = {}, hn = 0, ledger = {}, ln = 0,
            roles = parseRoles(f[9]),
            auctions = { n = clamp(f[10], 0, 10000), value = clamp(f[11], 0, 1e10) },
        }
    elseif kind == "I" then
        local s = state.staging[sk]
        if not s then return end
        for id, cnt in (f[3] or ""):gmatch("(%d+):(%d+)") do
            if s.n < 3000 then
                s.items[tonumber(id)] = clamp(cnt, 0, 1000000)
                s.n = s.n + 1
            end
        end
    elseif kind == "P" then
        local s = state.staging[sk]
        if not s then return end
        s.profs = {}
        for entry in (f[3] or ""):gmatch("[^,]+") do
            local name, rank, max = entry:match("^([^:]+):(%d+):(%d+)$")
            if name and #s.profs < 8 then
                s.profs[#s.profs + 1] = {
                    name = cleanName(name), rank = clamp(rank, 0, 1000), max = clamp(max, 0, 1000),
                }
            end
        end
    elseif kind == "A" then
        local s = state.staging[sk]
        if not s then return end
        s.assigned = parseAssigned(f[3])
    elseif kind == "L" then
        local s = state.staging[sk]
        if not s then return end
        for id, qty, buyout in (f[3] or ""):gmatch("(%d+):(%d+):(%d+)") do
            if #s.alist < 60 and #id <= 7 then -- real item ids are at most 7 digits
                s.alist[#s.alist + 1] = { id = tonumber(id), qty = clamp(qty, 0, 100000), buyout = clamp(buyout, 0, 1e10) }
            end
        end
    elseif kind == "H" then
        local s = state.staging[sk]
        if not s then return end
        for d, m in (f[3] or ""):gmatch("(%d+):(%d+)") do
            local day = tonumber(d)
            if s.hn < 200 and #m <= 11 and day > 10000 and day < 100000 then
                s.hist[day] = clamp(m, 0, 1e10)
                s.hn = s.hn + 1
            end
        end
    elseif kind == "Y" then
        local s = state.staging[sk]
        if not s then return end
        s.played = { total = clamp(f[3], 0, 1e9), at = clamp(f[4], 0, 4e9) }
    elseif kind == "G" then
        local s = state.staging[sk]
        if not s then return end
        for t, k, m, d in (f[3] or ""):gmatch("(%d+):(%a):(%-?%d+):([^;]*)") do
            local tt = tonumber(t)
            if s.ln < 60 and tt > 1e9 and tt < 4e9 and (k == "v" or k == "p" or k == "a" or k == "l" or k == "q") then
                s.ledger[#s.ledger + 1] = { t = tt, k = k, m = clamp(m, -1e10, 1e10), d = cleanText(d, 70) }
                s.ln = s.ln + 1
            end
        end
    elseif kind == "N" then
        local s = state.staging[sk]
        if not s then return end
        for id, nm in (f[3] or ""):gmatch("(%d+)=([^,]+)") do
            if s.nn < 400 then
                s.names[tonumber(id)] = (cleanName(nm):gsub("=", ""))
                s.nn = s.nn + 1
            end
        end
    elseif kind == "E" then
        local s = state.staging[sk]
        state.staging[sk] = nil
        if not s then return end
        if existing and (existing.time or 0) > s.time then return end
        -- an older version stored this character under its first name only; the full-name record replaces it
        local first, realmPart = key:match("^(%S+)%s.-%-(.+)$")
        if first and realmPart then
            local old = DB.chars[first .. "-" .. realmPart]
            if old and not old.localChar and (old.class == nil or s.class == nil or old.class == s.class) then
                DB.chars[first .. "-" .. realmPart] = nil
            end
        end
        DB.itemNames = DB.itemNames or {}
        for id, nm in pairs(s.names) do
            if not DB.itemNames[id] and nm ~= "" then DB.itemNames[id] = nm end
        end
        -- keep older history we already hold and add the incoming days on top
        local merged = {}
        for d, m in pairs(existing and existing.hist or {}) do merged[d] = m end
        local newest = 0
        for d, m in pairs(s.hist) do merged[d] = m if d > newest then newest = d end end
        for d in pairs(merged) do
            if d < newest - 120 then merged[d] = nil end
        end
        DB.chars[key] = {
            hist = merged, ledger = s.ledger, played = s.played,
            account = s.account, class = s.class, faction = s.faction,
            level = s.level, money = s.money, time = s.time,
            items = s.items, remote = true, synced = time(),
            roles = s.roles, auctions = s.auctions, profs = s.profs or {}, assigned = s.assigned or {}, auctionList = s.alist,
        }
        return "committed"
    end
end

------------------------------------------------------------------------
-- live sync (whispers between linked characters)
------------------------------------------------------------------------
local outq, ticker = {}, nil

local function rawSend(msg, to)
    local send = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
    if send then send(PREFIX, msg, "WHISPER", to) end
end

local function pump()
    local m = table.remove(outq, 1)
    if not m then
        if ticker then ticker:Cancel() ticker = nil end
        return
    end
    rawSend(m.msg, m.to)
end

local function enqueue(to, msg)
    outq[#outq + 1] = { to = to, msg = msg }
    if not ticker then ticker = C_Timer.NewTicker(0.25, pump) end
end

local function syncTo(target, mode)
    state.lastSend = GetTime()
    for _, key in ipairs(localChars()) do
        for _, line in ipairs(charLines(key, DB.chars[key])) do
            enqueue(target, mode .. "^" .. line)
        end
    end
    for _, line in ipairs(sharedLines()) do
        enqueue(target, mode .. "^" .. line)
    end
end

local function syncAll()
    updateSelf(false) -- make sure the current character's gold/time are fresh before sending
    local me = canon(selfName())
    local any = false
    for lower, display in pairs(DB.trusted) do
        if lower ~= me then
            syncTo(state.lastSender[lower] or whisperName(display), "D")
            any = true
        end
    end
    return any
end

------------------------------------------------------------------------
-- UI
------------------------------------------------------------------------
local ui = { rows = {}, pages = {}, refreshers = {} }
local openSetup -- defined with the setup window further down

-- Professions for the detail line: assigned ones in blue (with a note if not learned yet), others grey.
local function profBits(c)
    local bits, assigned, seen = {}, {}, {}
    for _, t in ipairs(c.assigned or {}) do assigned[t] = true end
    for _, p in ipairs(c.profs or {}) do
        local t = profToken(p.name)
        seen[t] = true
        local txt = p.name .. " " .. p.rank
        bits[#bits + 1] = assigned[t] and ("|cff66ccff" .. txt .. "|cff999999") or txt
    end
    for _, t in ipairs(c.assigned or {}) do
        if not seen[t] then
            local note = (#(c.profs or {}) > 0) and " (not learned)" or " (assigned)"
            bits[#bits + 1] = "|cff66ccff" .. (PROF_LABEL[t] or t) .. note .. "|cff999999"
        end
    end
    return bits
end

local function realmOf(key)
    return key:match("^[^%-]+%-(.+)$")
end

-- For every warehouse character: what sits on OTHER characters that belongs to it.
local function buildMoveRows()
    local rows = {}
    local keys = {}
    for key in pairs(DB.chars) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, wkey in ipairs(keys) do
        local w = DB.chars[wkey]
        local cats = {}
        for _, r in ipairs(w.roles or {}) do
            if CATEGORIES[r] then cats[#cats + 1] = r end
        end
        if #cats > 0 then
            local labels = {}
            for _, r in ipairs(cats) do labels[#labels + 1] = CATEGORIES[r].label end
            rows[#rows + 1] = { header = true, left = nameOf(wkey) .. " stocks: " .. table.concat(labels, ", "), right = "" }
            local found = false
            for _, ckey in ipairs(keys) do
                local c = DB.chars[ckey]
                -- mail only works for same realm and faction
                if ckey ~= wkey and realmOf(ckey) == realmOf(wkey) and c.faction == w.faction then
                    local total, kinds = 0, 0
                    for id, n in pairs(c.items or {}) do
                        local mine = itemCats(id)
                        for _, cat in ipairs(cats) do
                            if mine[cat] then total = total + n kinds = kinds + 1 break end
                        end
                    end
                    if total > 0 then
                        found = true
                        rows[#rows + 1] = {
                            left = "  " .. classColor(c.class) .. nameOf(ckey) .. "|r |cff888888@" .. (c.account or "?") .. "  (" .. kinds .. " types)|r",
                            right = total .. " items",
                        }
                    end
                end
            end
            if not found then
                rows[#rows + 1] = { left = "  |cff888888Nothing to move.|r", right = "" }
            end
        end
    end
    if #rows == 0 then
        rows[1] = { left = "|cff888888No warehouse set. Try /ledger warehouse <Character> herbs ah|r", right = "" }
    end
    return rows
end

-- Every character's active auctions. Buyout is shown exactly as the game reports it.
local function buildAuctionRows(query)
    local rows = { { sub = true, left = "|cff888888Active auctions as last loaded at the auction house. Prices are the buyout as the game reports it.|r", right = "" } }
    local q = (query or ""):lower()
    local keys = {}
    for key in pairs(DB.chars) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b)
        local aa, ab = DB.chars[a].account or "", DB.chars[b].account or ""
        if aa ~= ab then return aa < ab end
        return a < b
    end)
    local any = false
    for _, key in ipairs(keys) do
        local c = DB.chars[key]
        local shown = {}
        for _, a in ipairs(c.auctionList or {}) do
            local name = itemName(a.id) or ("item:" .. a.id)
            if q == "" or name:lower():find(q, 1, true) then
                shown[#shown + 1] = { name = name, a = a }
            end
        end
        local count = c.auctions and c.auctions.n or 0
        if #shown > 0 or (q == "" and count > 0) then
            any = true
            table.sort(shown, function(x, y) return x.name < y.name end)
            rows[#rows + 1] = { header = true, left = nameOf(key) .. "  @" .. (c.account or "?"), right = count .. " listed" }
            for _, it in ipairs(shown) do
                rows[#rows + 1] = {
                    left = "      " .. it.name .. (it.a.qty > 1 and ("  x" .. it.a.qty) or ""),
                    right = moneyStr(it.a.buyout),
                }
            end
            if #shown == 0 then
                rows[#rows + 1] = { sub = true, left = "      |cff888888Open the Auctions tab at the auction house to load the details.|r", right = "" }
            end
        end
    end
    if not any then
        rows[#rows + 1] = { left = "|cff888888No auctions recorded yet. Open the Auctions tab at the auction house on your selling character.|r", right = "" }
    end
    return rows
end

-- Every character's trade goods, grouped by type. The search box filters by item name.
local function buildMaterialRows(query)
    local rows = { { sub = true, left = "|cff888888Trade goods in bags and bank, as last seen on each character.|r", right = "" } }
    local q = (query or ""):lower()
    local keys = {}
    for key in pairs(DB.chars) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b)
        local aa, ab = DB.chars[a].account or "", DB.chars[b].account or ""
        if aa ~= ab then return aa < ab end
        return a < b
    end)
    local any = false
    for _, key in ipairs(keys) do
        local c = DB.chars[key]
        local groups, types = {}, 0
        for id, n in pairs(c.items or {}) do
            local g = tradeGroup(id)
            if g then
                local name = itemName(id) or ("item:" .. id)
                if q == "" or name:lower():find(q, 1, true) then
                    groups[g] = groups[g] or {}
                    table.insert(groups[g], { name = name, n = n })
                    types = types + 1
                end
            end
        end
        if types > 0 then
            any = true
            rows[#rows + 1] = {
                header = true,
                left = nameOf(key) .. "  @" .. (c.account or "?"),
                right = types .. (types == 1 and " type" or " types"),
            }
            for _, g in ipairs(TRADE_GROUP_ORDER) do
                local list = groups[g]
                if list then
                    table.sort(list, function(a, b) return a.name < b.name end)
                    rows[#rows + 1] = {
                        sub = true,
                        left = "  |cff66ccff" .. (g == "other" and "Other trade goods" or CATEGORIES[g].label) .. "|r",
                        right = "",
                    }
                    for _, it in ipairs(list) do
                        rows[#rows + 1] = { left = "      " .. it.name, right = tostring(it.n) }
                    end
                end
            end
        end
    end
    if not any then
        rows[#rows + 1] = { left = "|cff888888No trade goods found" .. (q ~= "" and " matching that search" or " yet") .. ".|r", right = "" }
    end
    return rows
end

do
local LEDGER_TAG = { v = "|cffd9a441Vendor|r", p = "|cff66ccefPlayer|r", a = "|cffc084fcAuction|r", l = "|cff7ddc7dLoot|r", q = "|cfff0c24dQuest|r" }

local function ledgerEntries(filter, q)
    local all = {}
    for key, c in pairs(DB.chars) do
        for _, e in ipairs(c.ledger or {}) do
            if (filter == "all" or e.k == filter)
                and (q == "" or e.d:lower():find(q, 1, true) or nameOf(key):lower():find(q, 1, true)) then
                all[#all + 1] = { e = e, key = key, c = c }
            end
        end
    end
    table.sort(all, function(a, b)
        if a.e.t ~= b.e.t then return a.e.t > b.e.t end
        return a.key < b.key
    end)
    return all
end

function ui.buildLedgerRows(query)
    local q = (query or ""):lower()
    local list = ledgerEntries(ui.ledgerFilter or "all", q)
    local fn = date or (os and os.date)
    local rows = {}
    if #list == 0 then
        rows[1] = { left = "|cff888888Nothing recorded yet. Vendor deals, trades, mail, auction house deals, loot and quest gold are logged as they happen.|r", right = "" }
        return rows, nil, ""
    end
    local today = fn("%d %b", time())
    local yesterday = fn("%d %b", time() - 86400)
    local week, income, spent = time() - 7 * 86400, 0, 0
    local dayLabelNow, daySum, headerRow
    for i, item in ipairs(list) do
        local e = item.e
        if e.t >= week then
            if e.m > 0 then income = income + e.m elseif e.m < 0 then spent = spent - e.m end
        end
        if i <= 200 then
            local label = fn("%d %b", e.t)
            if label ~= dayLabelNow then
                dayLabelNow = label
                headerRow = { header = true, left = (label == today and "Today") or (label == yesterday and "Yesterday") or label, net = 0 }
                rows[#rows + 1] = headerRow
            end
            headerRow.net = headerRow.net + e.m
            rows[#rows + 1] = {
                left = string.format("|cff8a93a3%s|r  %s  %s%s|r  %s", fn("%H:%M", e.t), LEDGER_TAG[e.k] or "", classColor(item.c.class), nameOf(item.key), e.d),
                right = e.m ~= 0 and deltaStr(e.m) or "",
            }
        end
    end
    for _, r in ipairs(rows) do
        if r.header then r.right = deltaStr(r.net) end
    end
    local footer = string.format("|cff8a93a3Last 7 days|r  in %s  out %s  net %s",
        "|cff4dc77f" .. moneyStr(income) .. "|r", "|cffe66155" .. moneyStr(spent) .. "|r", deltaStr(income - spent))
    return rows, nil, footer
end

end

local function buildRows(query)
    local rows, grand = {}, 0
    if ui.mode == "ledger" then
        return ui.buildLedgerRows(query)
    end
    if ui.mode == "auctions" then
        return buildAuctionRows(query), nil
    end
    if ui.mode == "materials" then
        return buildMaterialRows(query), nil
    end
    if (not query or query == "") and ui.mode == "move" then
        return buildMoveRows(), nil
    end
    if query and query ~= "" then
        local q, seen, hits = query:lower(), {}, {}
        for _, c in pairs(DB.chars) do
            for id in pairs(c.items or {}) do
                if not seen[id] then
                    seen[id] = true
                    local name = itemName(id)
                    if name and name:lower():find(q, 1, true) then
                        hits[#hits + 1] = { id = id, name = name }
                    end
                end
            end
        end
        table.sort(hits, function(a, b) return a.name < b.name end)
        for i, it in ipairs(hits) do
            if i > 40 then break end
            local owners, total = {}, 0
            for key, c in pairs(DB.chars) do
                local n = c.items and c.items[it.id]
                if n and n > 0 then
                    owners[#owners + 1] = { key = key, c = c, n = n }
                    total = total + n
                end
            end
            table.sort(owners, function(a, b) return a.key < b.key end)
            rows[#rows + 1] = { header = true, left = it.name, right = tostring(total) }
            for _, o in ipairs(owners) do
                rows[#rows + 1] = {
                    left = "  " .. classColor(o.c.class) .. nameOf(o.key) .. "|r |cff888888(" .. (o.c.account or "?") .. ")|r",
                    right = tostring(o.n),
                }
            end
        end
        if #rows == 0 then
            rows[1] = { left = "|cff888888No cached item names match. Item names load as the game sees them; try again in a moment.|r", right = "" }
        end
        return rows, nil
    end

    local groups, labels = {}, {}
    for key, c in pairs(DB.chars) do
        local a = c.account or "Other"
        if not groups[a] then groups[a] = {} labels[#labels + 1] = a end
        table.insert(groups[a], { key = key, c = c })
    end
    table.sort(labels)
    for _, label in ipairs(labels) do
        local list, sub = groups[label], 0
        table.sort(list, function(a, b) return a.key < b.key end)
        for _, e in ipairs(list) do sub = sub + (e.c.money or 0) end
        grand = grand + sub
        rows[#rows + 1] = { header = true, left = "Account: " .. label, right = moneyStr(sub) }
        for _, e in ipairs(list) do
            local c = e.c
            rows[#rows + 1] = {
                left = "  " .. classColor(c.class) .. nameOf(e.key) .. "|r |cff888888L" .. (c.level or "?")
                    .. "  @" .. (c.account or "?") .. "|r" .. roleTag(c),
                right = moneyStr(c.money),
            }
            -- detail line: professions, listings, and how fresh the data is
            local bits = profBits(c)
            if c.auctions and c.auctions.n > 0 then bits[#bits + 1] = c.auctions.n .. " listed" end
            if c.remote then bits[#bits + 1] = "synced " .. ago(c.synced or c.time) end
            if #bits > 0 then
                rows[#rows + 1] = { sub = true, left = "      |cff999999" .. table.concat(bits, "  ·  ") .. "|r", right = "" }
            end
        end
    end
    if #rows == 0 then
        rows[1] = { left = "|cff888888Nothing tracked yet.|r", right = "" }
    end
    return rows, grand
end

------------------------------------------------------------------------
-- look and feel
------------------------------------------------------------------------
local FLAT = "Interface\\Buttons\\WHITE8X8"
local T = {
    bg = { 0.055, 0.063, 0.082, 0.97 },
    panel = { 0.105, 0.118, 0.149, 1 },
    hover = { 0.16, 0.18, 0.235, 1 },
    border = { 0.19, 0.21, 0.27, 1 },
    accent = { 0.25, 0.68, 1.0, 1 },
    green = { 0.30, 0.78, 0.50, 1 },
    red = { 0.90, 0.38, 0.34, 1 },
    steel = { 0.40, 0.55, 0.75, 1 },
    gold = { 1.0, 0.82, 0.20, 1 },
}

local function setc(tex, c, a)
    local al = a or c[4] or 1
    if tex.SetColorTexture then tex:SetColorTexture(c[1], c[2], c[3], al) else tex:SetTexture(c[1], c[2], c[3], al) end
end

-- flat background with a 1px border, drawn with plain textures (no backdrop API needed)
local function skin(f, bg, border)
    local t = f:CreateTexture(nil, "BACKGROUND")
    t:SetAllPoints(f)
    setc(t, bg)
    local function edge(p1, p2, w, h)
        local e = f:CreateTexture(nil, "BORDER")
        e:SetPoint(p1)
        e:SetPoint(p2)
        if w then e:SetWidth(w) else e:SetHeight(h) end
        setc(e, border)
    end
    edge("TOPLEFT", "TOPRIGHT", nil, 1)
    edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
    edge("TOPLEFT", "BOTTOMLEFT", 1, nil)
    edge("TOPRIGHT", "BOTTOMRIGHT", 1, nil)
    return t
end

local function flatButton(parent, text, w, h, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.base = T.panel
    setc(b.bg, b.base)
    b.txt = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.txt:SetPoint("CENTER")
    b.txt:SetText(text)
    b:SetScript("OnEnter", function() setc(b.bg, T.hover) end)
    b:SetScript("OnLeave", function() setc(b.bg, b.base) end)
    if onClick then b:SetScript("OnClick", onClick) end
    return b
end

-- selected look for tabs and range buttons
local function setActive(b, on)
    b.base = on and T.hover or T.panel
    setc(b.bg, b.base)
    if b.hasLine == true then
        if on then b.line:Show() else b.line:Hide() end
    end
    if on then b.txt:SetTextColor(1, 1, 1) else b.txt:SetTextColor(0.62, 0.66, 0.74) end
end

local function newBackdropFrame(name, w, h)
    local f = CreateFrame("Frame", name, UIParent)
    f:SetSize(w, h)
    f:SetPoint("CENTER")
    skin(f, T.bg, T.border)
    local top = f:CreateTexture(nil, "ARTWORK")
    top:SetPoint("TOPLEFT", 1, -1)
    top:SetPoint("TOPRIGHT", -1, -1)
    top:SetHeight(2)
    setc(top, T.accent)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("HIGH")
    f:Hide()
    local close = flatButton(f, "x", 22, 22, function() f:Hide() end)
    close:SetPoint("TOPRIGHT", -8, -10)
    if name then table.insert(UISpecialFrames, name) end
    return f
end

------------------------------------------------------------------------
-- wealth history: totals per day, growth and motivation stats
------------------------------------------------------------------------
local HISTORY_DAYS = 91 -- today plus 90 days back
local MILESTONES = { 1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000, 25000, 50000, 100000, 250000, 500000, 1000000 } -- gold

local function totalMoney()
    local t = 0
    for _, c in pairs(DB.chars) do t = t + (c.money or 0) end
    return t
end

-- Total gold of every character on each of the last n days (index n is today).
-- A character that starts being tracked part-way through does not make the total "jump".
local function wealthSeries(n)
    local today = dayNum()
    local list, have = {}, {}
    local first = today
    for _, c in pairs(DB.chars) do
        local days = {}
        for d in pairs(c.hist or {}) do
            days[#days + 1] = d
            have[d] = true
            if d < first then first = d end
        end
        table.sort(days)
        list[#list + 1] = { c = c, days = days }
    end
    local function valueAt(e, d)
        local c, days = e.c, e.days
        if d >= today then return c.money or 0 end
        local v
        for i = 1, #days do
            if days[i] <= d then v = c.hist[days[i]] else break end
        end
        if v == nil then
            if c.hist0 and days[1] and c.hist0.d == days[1] then v = c.hist0.m
            else v = (days[1] and c.hist[days[1]]) or c.money or 0 end
        end
        return v
    end
    local totals = {}
    for i = 1, n do
        local d, t = today - (n - i), 0
        for _, e in ipairs(list) do t = t + valueAt(e, d) end
        totals[i] = t
    end
    return totals, today, first, have
end

local function wealthStats()
    local n = HISTORY_DAYS
    local totals, today, first, have = wealthSeries(n)
    local st = { totals = totals, today = today, first = first, n = n, now = totals[n] }
    st.d1, st.d7, st.d30 = st.now - totals[n - 1], st.now - totals[n - 7], st.now - totals[n - 30]
    st.bestGain, st.bestDay = 0, nil
    for i = 2, n do
        local day = today - (n - i)
        if day >= first then
            local g = totals[i] - totals[i - 1]
            if g > st.bestGain then st.bestGain, st.bestDay = g, day end
        end
    end
    st.streak = 0
    local d = have[today] and today or today - 1
    while have[d] do st.streak = st.streak + 1 d = d - 1 end
    st.chars, st.accounts, st.ahN, st.ahChars, st.goods = 0, {}, 0, 0, 0
    st.richest = nil
    for key, c in pairs(DB.chars) do
        st.chars = st.chars + 1
        st.accounts[c.account or "?"] = true
        if c.auctions and c.auctions.n > 0 then st.ahN = st.ahN + c.auctions.n st.ahChars = st.ahChars + 1 end
        for id, cnt in pairs(c.items or {}) do
            if tradeGroup(id) then st.goods = st.goods + cnt end
        end
        if not st.richest or (c.money or 0) > (st.richest.c.money or 0) then st.richest = { key = key, c = c } end
    end
    st.nAccounts = 0
    for _ in pairs(st.accounts) do st.nAccounts = st.nAccounts + 1 end
    st.nextGold, st.prevGold = nil, 0
    for _, g in ipairs(MILESTONES) do
        if g * 10000 > st.now then st.nextGold = g break else st.prevGold = g end
    end
    return st
end

------------------------------------------------------------------------
-- list rows
------------------------------------------------------------------------
local WIN_W, WIN_H = 740, 620
local INNER_W = WIN_W - 32
local CONTENT_W = INNER_W - 18
local VIEW_TOP, VIEW_BOTTOM = 112, 70
local VIEW_H = WIN_H - VIEW_TOP - VIEW_BOTTOM

local function getRow(i)
    local r = ui.rows[i]
    if not r then
        r = {}
        r.bg = ui.content:CreateTexture(nil, "BACKGROUND")
        r.bg:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
        r.bg:SetSize(CONTENT_W, ROW_H - 2)
        setc(r.bg, T.panel)
        r.left = ui.content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        r.left:SetJustifyH("LEFT")
        r.left:SetWidth(540)
        r.left:SetWordWrap(false)
        r.left:SetPoint("TOPLEFT", 8, -(i - 1) * ROW_H - 3)
        r.right = ui.content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        r.right:SetJustifyH("RIGHT")
        r.right:SetPoint("TOPRIGHT", -8, -(i - 1) * ROW_H - 3)
        ui.rows[i] = r
    end
    return r
end

local function updateThumb()
    if not ui.thumb then return end
    local ch = ui.contentH or 0
    if not (ui.scroll and ui.scroll:IsShown()) or ch <= VIEW_H then
        ui.thumb:Hide()
        return
    end
    local max = ch - VIEW_H
    local cur = (ui.scroll and ui.scroll:GetVerticalScroll()) or 0
    local th = math.max(24, VIEW_H * VIEW_H / ch)
    local off = (cur / max) * (VIEW_H - th)
    ui.thumb:ClearAllPoints()
    ui.thumb:SetPoint("TOPRIGHT", ui.frame, "TOPRIGHT", -12, -VIEW_TOP - off)
    ui.thumb:SetHeight(th)
    ui.thumb:Show()
end

local PLOT_W, PLOT_H = INNER_W - 78, 96
local WEALTH_W = INNER_W

local function getBar(i)
    local plot = ui.wealth.chart.plot
    local b = ui.wealth.bars[i]
    if not b then
        b = CreateFrame("Button", nil, plot)
        b.tex = b:CreateTexture(nil, "ARTWORK")
        b.tex:SetAllPoints()
        b:SetScript("OnEnter", function()
            if b.color then setc(b.tex, { math.min(1, b.color[1] + 0.2), math.min(1, b.color[2] + 0.2), math.min(1, b.color[3] + 0.2), 1 }) end
            GameTooltip:SetOwner(b, "ANCHOR_TOP")
            GameTooltip:SetText(b.tipDay or "")
            GameTooltip:AddLine(b.tipTotal or "", 1, 1, 1)
            GameTooltip:AddLine(b.tipDelta or "", 1, 1, 1)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function()
            if b.color then setc(b.tex, b.color) end
            GameTooltip:Hide()
        end)
        ui.wealth.bars[i] = b
    end
    return b
end

local function refreshWealth()
    local w = ui.wealth
    if not w then return end
    local st = wealthStats()
    local n, today, totals = st.n, st.today, st.totals

    w.big:SetText(moneyStr(st.now))
    w.chips[1].value:SetText(deltaStr(st.d1))
    w.chips[2].value:SetText(deltaStr(st.d7))
    w.chips[3].value:SetText(deltaStr(st.d30))

    -- chart
    local range = ui.range or 30
    local cp = w.chart
    cp.title:SetText("Total wealth, last " .. range .. " days")
    for _, rb in ipairs(cp.rangeBtns) do setActive(rb, rb.days == range) end
    local startI = n - range + 1
    local lo, hi
    for i = startI, n do
        if today - (n - i) >= st.first then
            local v = totals[i]
            lo = (not lo or v < lo) and v or lo
            hi = (not hi or v > hi) and v or hi
        end
    end
    local step = PLOT_W / range
    local bw = math.max(1, step - (range > 45 and 1 or 2))
    for i = startI, n do
        local day = today - (n - i)
        local bar = getBar(i - startI + 1)
        if day >= st.first and lo then
            local v = totals[i]
            local frac = (hi == lo) and 0.55 or (0.12 + 0.88 * (v - lo) / (hi - lo))
            bar:ClearAllPoints()
            bar:SetPoint("BOTTOMLEFT", cp.plot, "BOTTOMLEFT", (i - startI) * step, 0)
            bar:SetSize(bw, math.max(2, frac * PLOT_H))
            local prev = totals[i - 1] or v
            bar.color = (i == n) and T.gold or (v > prev and T.green or (v < prev and T.red or T.accent))
            setc(bar.tex, bar.color)
            bar.tipDay = (i == n) and "Today" or dayLabel(day)
            bar.tipTotal = moneyStr(v)
            bar.tipDelta = (i == startI and day == st.first) and "" or deltaStr(v - prev)
            bar:Show()
        else
            bar:Hide()
        end
    end
    for i = range + 1, #w.bars do w.bars[i]:Hide() end
    cp.hi:SetText(hi and goldStr(hi) or "")
    cp.lo:SetText(lo and goldStr(lo) or "")
    cp.d1:SetText(dayLabel(math.max(today - range + 1, st.first)))
    cp.d2:SetText("Today")
    if st.first >= today then
        cp.empty:SetText("Tracking started today. The chart grows by a bar every day you play, and syncs across your accounts.")
    else
        cp.empty:SetText("")
    end

    -- next milestone
    if st.nextGold then
        local from, to = st.prevGold * 10000, st.nextGold * 10000
        local pct = math.max(0, math.min(1, (st.now - from) / (to - from)))
        w.mLeft:SetText("|cff8a93a3Next milestone|r  " .. formatNum(st.nextGold) .. "|cffffd700g|r")
        local extra = ""
        if st.d7 > 0 then
            local days = math.ceil((to - st.now) / (st.d7 / 7))
            if days <= 365 then extra = "  |cff8a93a3about " .. days .. (days == 1 and " day" or " days") .. " at your 7-day pace|r" end
        end
        w.mRight:SetText(math.floor(pct * 100) .. "%" .. extra)
        w.mFill:SetWidth(math.max(1, pct * WEALTH_W))
    else
        w.mLeft:SetText("|cffffd700Every milestone cleared. Legendary!|r")
        w.mRight:SetText("100%")
        w.mFill:SetWidth(WEALTH_W)
    end

    -- stat tiles
    local dim = "|cff8a93a3"
    local cells = w.cells
    cells[1]:SetText(dim .. "Best day|r  " .. (st.bestDay and (deltaStr(st.bestGain) .. dim .. "  on " .. dayLabel(st.bestDay) .. "|r") or "|cff8a93a3none yet, go earn one!|r"))
    cells[2]:SetText(dim .. "Day streak|r  " .. st.streak .. (st.streak == 1 and " day" or " days") .. (st.streak >= 3 and "  |cffffd700keep it going!|r" or ""))
    local r = st.richest
    local share = (r and st.now > 0) and math.floor((r.c.money or 0) / st.now * 100 + 0.5) or 0
    cells[3]:SetText(dim .. "Biggest wallet|r  " .. (r and (classColor(r.c.class) .. nameOf(r.key) .. "|r " .. dim .. share .. "%|r") or "-"))
    cells[4]:SetText(dim .. "On the auction house|r  " .. (st.ahN > 0 and (st.ahN .. " listed") or "nothing yet"))
    cells[5]:SetText(dim .. "Trade goods stockpiled|r  " .. formatNum(st.goods))
    cells[6]:SetText(dim .. "Tracking|r  " .. st.chars .. (st.chars == 1 and " character" or " characters") .. ", " .. st.nAccounts .. (st.nAccounts == 1 and " account" or " accounts"))
end

------------------------------------------------------------------------
-- zone map, to-do list and play time
------------------------------------------------------------------------
local refreshUI
do
local RATING_COLOR = {
    [0] = { 0.105, 0.118, 0.149, 1 }, { 0.50, 0.22, 0.24, 1 }, { 0.66, 0.50, 0.18, 1 },
    { 0.24, 0.58, 0.40, 1 }, { 0.14, 0.76, 0.54, 1 },
}
local NOTE_ROWS = 4
local TODO_ROWS = 14
local PLAY_ROWS = 10

local function customAreaList()
    local list = {}
    for name, z in pairs(DB.zones or {}) do
        if not BUILTIN_ZONE[name] and (z.rating or 0) >= 0 then list[#list + 1] = name end
    end
    table.sort(list)
    return list
end

local function mapTileState(tile, name)
    local z = DB.zones and DB.zones[name]
    local r = (z and z.rating and z.rating >= 0 and z.rating) or 0
    setc(tile.bg, RATING_COLOR[r])
    if z and z.notes and #z.notes > 0 then tile.dot:Show() else tile.dot:Hide() end
    for _, x in ipairs(tile.sel) do
        if ui.mapSel == name then x:Show() else x:Hide() end
    end
end

local function refreshMap()
    local m = ui.map
    if not m then return end
    for name, tile in pairs(m.tiles) do mapTileState(tile, name) end
    local customs = customAreaList()
    for i, tile in ipairs(m.custom) do
        local name = customs[i]
        if name then
            tile.zone = name
            tile.txt:SetText(name)
            tile:Show()
            mapTileState(tile, name)
        else
            tile.zone = ""
            tile:Hide()
        end
    end
    m.customLabel:SetText(#customs > 0 and "|cff8a93a3OTHER AREAS|r" or "|cff8a93a3OTHER AREAS|r  |cff6b7280dungeons, instances, or anywhere not shown above: add your own name here|r")

    local name = ui.mapSel
    local z = name and DB.zones and DB.zones[name]
    if not name then
        m.pTitle:SetText("Pick a zone")
        m.pSub:SetText("|cff8a93a3Click a zone to select it, then rate it and add notes (good farms, grind spots, herb routes...).|r")
        for _, b in ipairs(m.rateBtns) do b:Hide() end
        m.noteBox:Hide() m.addBtn:Hide() m.delBtn:Hide()
        m.overlayBtn.txt:SetText("World map: " .. (DB.mapOverlay == false and "off" or "on"))
        for i = 1, NOTE_ROWS do m.noteRows[i]:Hide() end
        m.pMore:SetText("")
        return
    end
    local rating = (z and z.rating and z.rating >= 0 and z.rating) or 0
    m.pTitle:SetText(name)
    local notes = (z and z.notes) or {}
    m.pSub:SetText("|cff8a93a3" .. #notes .. (#notes == 1 and " note" or " notes") .. "  ·  rated: |r" .. RATING_NAMES[rating])
    for r, b in ipairs(m.rateBtns) do
        b:Show()
        for _, x in ipairs(b.sel) do
            if (r - 1) == rating then x:Show() else x:Hide() end
        end
    end
    m.noteBox:Show() m.addBtn:Show()
    m.overlayBtn.txt:SetText("World map: " .. (DB.mapOverlay == false and "off" or "on"))
    if BUILTIN_ZONE[name] then m.delBtn:Hide() else m.delBtn:Show() end
    local off = math.max(0, math.min(m.noteOff or 0, math.max(0, #notes - NOTE_ROWS)))
    m.noteOff = off
    for i = 1, NOTE_ROWS do
        local n = notes[off + i]
        local row = m.noteRows[i]
        if n then
            row.noteId = n.id
            row.txt:SetText(noteText(n))
            row:Show()
        else
            row:Hide()
        end
    end
    m.pMore:SetText(#notes > NOTE_ROWS and ("|cff6b7280scroll for " .. (#notes - NOTE_ROWS) .. " more|r") or "")
end

local function todoRank(t, me)
    if t.done then return 3 end
    if t.char == me then return 0 end
    if t.char == "" then return 1 end
    return 2
end

local function sortedTodos()
    local me = selfName()
    local list = {}
    for id, t in pairs(DB.todos or {}) do
        if not t.del then list[#list + 1] = { id = id, t = t } end
    end
    table.sort(list, function(a, b)
        local ra, rb = todoRank(a.t, me), todoRank(b.t, me)
        if ra ~= rb then return ra < rb end
        local ca, cb = todoCreated(a.id), todoCreated(b.id)
        if ca ~= cb then return ca < cb end
        return a.id < b.id
    end)
    return list
end

local function refreshTodo()
    local p = ui.todo
    if not p then return end
    local me = selfName()
    local list = sortedTodos()
    local open, done = 0, 0
    for _, e in ipairs(list) do
        if e.t.done then done = done + 1 else open = open + 1 end
    end
    local maxOff = math.max(0, #list - TODO_ROWS)
    p.off = math.max(0, math.min(p.off or 0, maxOff))
    for i = 1, TODO_ROWS do
        local e = list[p.off + i]
        local row = p.rows[i]
        if e then
            row.todoId = e.id
            row.txt:SetText(e.t.done and ("|cff6b7280" .. e.t.text .. "|r") or e.t.text)
            local who = e.t.char or ""
            if who == "" then
                row.who:SetText("|cff6b7280anyone|r")
            else
                local class
                for key, c in pairs(DB.chars) do
                    if nameOf(key) == who then class = c.class break end
                end
                row.who:SetText((who == me and "|cffffd700> |r" or "") .. classColor(class) .. who .. "|r")
            end
            setc(row.check.bg, e.t.done and T.green or T.hover)
            row:Show()
        else
            row:Hide()
        end
    end
    p.count:SetText(string.format("|cff8a93a3%d open, %d done|r%s", open, done, maxOff > 0 and "   |cff6b7280scroll for more|r" or ""))
    p.charBtn.txt:SetText("For: " .. ((p.target or "") == "" and "anyone" or p.target))
    p.empty:SetText(#list == 0 and "|cff8a93a3Nothing here yet. Add your first task above, and tag it for a character if it is theirs to do.|r" or "")
end

local function fmtDuration(sec)
    sec = math.floor(sec or 0)
    local d, h, m = math.floor(sec / 86400), math.floor(sec / 3600) % 24, math.floor(sec / 60) % 60
    if d > 0 then return string.format("%dd %dh", d, h) end
    if h > 0 then return string.format("%dh %dm", h, m) end
    return string.format("%dm", m)
end

local FUN_FACTS = {
    { 2.0, function(n) return string.format("That is about %d films back to back.", n) end },
    { 11.9, function(n) return string.format("That is the extended Lord of the Rings trilogy, %d times over.", n) end },
    { 8.0, function(n) return string.format("That is %d flights from London to New York.", n) end },
    { 40.0, function(n) return string.format("That is %d full working weeks. Azeroth is a demanding employer.", n) end },
    { 4.5, function(n) return string.format("That is %d marathons of running, but with better loot.", n) end },
    { 8.0, function(n) return string.format("That is %d full nights of sleep swapped for pixels.", n) end },
}

local function refreshPlay()
    local p = ui.play
    if not p then return end
    local rows, total, missing = {}, 0, 0
    for key, c in pairs(DB.chars) do
        local secs = playedSeconds(key, c)
        if secs then
            rows[#rows + 1] = { key = key, c = c, secs = secs }
            total = total + secs
        else
            missing = missing + 1
        end
    end
    table.sort(rows, function(a, b)
        if a.secs ~= b.secs then return a.secs > b.secs end
        return a.key < b.key
    end)
    local hours = total / 3600
    p.cards[1].value:SetText(total > 0 and fmtDuration(total) or "-")
    if hours >= 1 then
        p.cards[2].value:SetText(moneyStr(math.floor(totalMoney() / hours)))
    else
        p.cards[2].value:SetText("-")
    end
    local top = rows[1]
    if top and total > 0 then
        p.cards[3].value:SetText(classColor(top.c.class) .. nameOf(top.key) .. "|r |cff8a93a3" .. math.floor(top.secs / total * 100 + 0.5) .. "%|r")
    else
        p.cards[3].value:SetText("-")
    end

    local fun = "Just getting started. The legend begins here!"
    local start = dayNum() % #FUN_FACTS
    for i = 0, #FUN_FACTS - 1 do
        local f = FUN_FACTS[((start + i) % #FUN_FACTS) + 1]
        local n = math.floor(hours / f[1])
        if n >= 2 then fun = f[2](n) break end
    end
    p.fun:SetText(total > 0 and fun or "Log in on each character once with this version and their time played will appear here.")

    local maxSecs = rows[1] and rows[1].secs or 1
    for i = 1, PLAY_ROWS do
        local e = rows[i]
        local row = p.rows[i]
        if e then
            row.name:SetText(classColor(e.c.class) .. nameOf(e.key) .. "|r |cff8a93a3L" .. (e.c.level or "?") .. "  @" .. (e.c.account or "?") .. "|r")
            row.bar:SetWidth(math.max(2, 300 * e.secs / math.max(1, maxSecs)))
            row.time:SetText(fmtDuration(e.secs))
            local h = e.secs / 3600
            row.gph:SetText(h >= 1 and ("|cff8a93a3" .. goldStr(math.floor((e.c.money or 0) / h)) .. "/h|r") or "")
            row:Show()
        else
            row:Hide()
        end
    end
    local note = ""
    if #rows > PLAY_ROWS then note = "+" .. (#rows - PLAY_ROWS) .. " more characters. " end
    if missing > 0 then note = note .. missing .. " character(s) have no play time yet: log in on them once. " end
    p.note:SetText("|cff6b7280" .. note .. "Time played is read each time you log in.|r")
end

local function outline(f, c)
    local t = {}
    local function edge(p1, p2, w, h)
        local x = f:CreateTexture(nil, "OVERLAY")
        x:SetPoint(p1)
        x:SetPoint(p2)
        if w then x:SetWidth(w) else x:SetHeight(h) end
        setc(x, c)
        t[#t + 1] = x
    end
    edge("TOPLEFT", "TOPRIGHT", nil, 2)
    edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 2)
    edge("TOPLEFT", "BOTTOMLEFT", 2, nil)
    edge("TOPRIGHT", "BOTTOMRIGHT", 2, nil)
    return t
end

local function smallFont(fs, size)
    fs:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", size, "")
end

local function inputBox(parent, w, hintText, onEnter)
    local box = CreateFrame("Frame", nil, parent)
    box:SetSize(w, 24)
    local bg = box:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    setc(bg, T.panel)
    local hint = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("LEFT", 8, 0)
    hint:SetText("|cff6b7280" .. hintText .. "|r")
    local eb = CreateFrame("EditBox", nil, box)
    eb:SetSize(w - 16, 18)
    eb:SetPoint("LEFT", 8, 0)
    eb:SetFontObject(GameFontHighlight)
    eb:SetAutoFocus(false)
    eb:SetScript("OnTextChanged", function()
        if eb:GetText() == "" then hint:Show() else hint:Hide() end
    end)
    eb:SetScript("OnEscapePressed", eb.ClearFocus)
    eb:SetScript("OnEnterPressed", function()
        if onEnter then onEnter() end
        eb:ClearFocus()
    end)
    box.edit = eb
    return box
end

local function createMap(f)
    local p = CreateFrame("Frame", nil, f)
    p:SetPoint("TOPLEFT", 16, -84)
    p:SetSize(INNER_W, 466)
    p:Hide()
    p.tiles, p.custom = {}, {}
    ui.map = p
    ui.pages.map = p

    local hint = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", 2, 0)
    hint:SetText("|cff8a93a3ZONE MAP|r  |cff6b7280click to select, right-click to rate|r")
    -- colour key
    for r = 0, 4 do
        local sw = p:CreateTexture(nil, "ARTWORK")
        sw:SetSize(12, 10)
        sw:SetPoint("TOPRIGHT", -(4 - r) * 66 - 40, -2)
        setc(sw, RATING_COLOR[r])
        local lb = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        lb:SetPoint("LEFT", sw, "RIGHT", 4, 0)
        lb:SetText("|cff8a93a3" .. RATING_NAMES[r] .. "|r")
    end

    local TW, TH, GAPX, PITCH = 66, 23, 3, 25
    local function makeTile(w, h, fontSize)
        local b = CreateFrame("Button", nil, p)
        b:SetSize(w, h)
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        b.bg = b:CreateTexture(nil, "BACKGROUND")
        b.bg:SetAllPoints()
        b.txt = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.txt:SetPoint("CENTER")
        b.txt:SetWidth(w - 4)
        b.txt:SetJustifyH("CENTER")
        smallFont(b.txt, fontSize)
        b.dot = b:CreateTexture(nil, "OVERLAY")
        b.dot:SetSize(5, 5)
        b.dot:SetPoint("TOPRIGHT", -2, -2)
        setc(b.dot, T.gold)
        b.sel = outline(b, { 1, 1, 1, 1 })
        b.zone = ""
        b:SetScript("OnClick", function(_, button)
            local name = b.zone
            if type(name) ~= "string" or name == "" then return end
            if button == "RightButton" then
                local z = ensureZone(name)
                z.rating = ((z.rating or 0) + 1) % 5
                bumpTs(z)
            end
            ui.mapSel = name
            p.noteOff = 0
            refreshUI()
        end)
        b:SetScript("OnEnter", function()
            local name = b.zone
            if type(name) ~= "string" or name == "" then return end
            local z = DB.zones and DB.zones[name]
            GameTooltip:SetOwner(b, "ANCHOR_TOP")
            GameTooltip:SetText(name)
            GameTooltip:AddLine("Rated: " .. RATING_NAMES[(z and z.rating and z.rating >= 0 and z.rating) or 0], 1, 1, 1)
            for i, n in ipairs(z and z.notes or {}) do
                if i > 4 then GameTooltip:AddLine("...", 0.6, 0.6, 0.6) break end
                GameTooltip:AddLine(noteText(n), 0.8, 0.85, 0.9, true)
            end
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return b
    end

    local x0 = { ek = 0, kal = 5 * (TW + GAPX) + 18 }
    for cont, label in pairs({ ek = "EASTERN KINGDOMS", kal = "KALIMDOR" }) do
        local t = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        t:SetPoint("TOPLEFT", x0[cont] + 2, -16)
        t:SetText("|cff8a93a3" .. label .. "|r")
    end
    for _, z in ipairs(ZONE_LAYOUT) do
        local tile = makeTile(TW, TH, 9)
        tile:SetPoint("TOPLEFT", x0[z[1]] + (z[3] - 1) * (TW + GAPX), -30 - (z[4] - 1) * PITCH)
        tile.zone = z[2]
        tile.txt:SetText(z[2])
        p.tiles[z[2]] = tile
    end

    p.customLabel = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.customLabel:SetPoint("TOPLEFT", 2, -259)
    for i = 1, 12 do
        local tile = makeTile(54, TH, 8)
        tile:SetPoint("TOPLEFT", (i - 1) * 57, -281)
        tile:Hide()
        p.custom[i] = tile
    end
    local areaBox
    local function addArea()
        local nm = cleanText(areaBox.edit:GetText(), 40)
        if nm == "" then return end
        ensureZone(nm)
        bumpTs(DB.zones[nm])
        areaBox.edit:SetText("")
        ui.mapSel = nm
        refreshUI()
    end
    areaBox = inputBox(p, 190, "new area name, e.g. Deadmines", addArea)
    areaBox:SetPoint("TOPRIGHT", -92, -253)
    local areaBtn = flatButton(p, "+ Add area", 86, 24, addArea)
    areaBtn:SetPoint("TOPRIGHT", 0, -253)

    -- detail panel for the selected zone
    local panel = CreateFrame("Frame", nil, p)
    panel:SetSize(INNER_W, 160)
    panel:SetPoint("TOPLEFT", 0, -306)
    local pbg = panel:CreateTexture(nil, "BACKGROUND")
    pbg:SetAllPoints()
    setc(pbg, T.panel)
    p.panel = panel
    p.pTitle = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    p.pTitle:SetPoint("TOPLEFT", 12, -10)
    p.pSub = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.pSub:SetPoint("TOPLEFT", 12, -34)
    p.pSub:SetWidth(INNER_W - 24)
    p.pSub:SetJustifyH("LEFT")

    local here = flatButton(panel, "My zone", 80, 22, function()
        local name = currentZoneName()
        if name == "" then chat("couldn't read your current zone.") return end
        ensureZone(name)
        if not BUILTIN_ZONE[name] then bumpTs(DB.zones[name]) end
        ui.mapSel = name
        p.noteOff = 0
        refreshUI()
    end)
    here:SetPoint("TOPRIGHT", -10, -10)
    p.delBtn = flatButton(panel, "Delete area", 80, 22, function()
        local z = ui.mapSel and DB.zones and DB.zones[ui.mapSel]
        if z and not BUILTIN_ZONE[ui.mapSel] then
            z.rating, z.notes = -1, {}
            bumpTs(z)
            ui.mapSel = nil
            refreshUI()
        end
    end)
    p.delBtn:SetPoint("TOPRIGHT", -96, -10)
    p.overlayBtn = flatButton(panel, "World map: on", 104, 22, function()
        DB.mapOverlay = (DB.mapOverlay == false)
        refreshUI()
    end)
    p.overlayBtn:SetPoint("TOPRIGHT", -182, -10)

    p.rateBtns = {}
    for r = 0, 4 do
        local b = flatButton(panel, RATING_NAMES[r], 90, 22, function()
            local name = ui.mapSel
            if not name then return end
            local z = ensureZone(name)
            z.rating = r
            bumpTs(z)
            refreshUI()
        end)
        b:SetPoint("TOPLEFT", 12 + r * 94, -54)
        b.base = RATING_COLOR[r]
        setc(b.bg, b.base)
        b.sel = outline(b, { 1, 1, 1, 1 })
        p.rateBtns[#p.rateBtns + 1] = b
    end
    p.rateBtns[1].base = T.panel
    -- note entry
    local function submitNote()
        local name = ui.mapSel
        if not name then return end
        local ok, why = addZoneNote(name, p.noteBox.edit:GetText(), true)
        if ok then
            p.noteBox.edit:SetText("")
        elseif why == "full" then
            chat("that area already has " .. MAX_NOTES .. " notes. Delete one to add another.")
        end
        refreshUI()
    end
    p.noteBox = inputBox(panel, 480, "add a note (your map position is saved when you are standing in this zone)", submitNote)
    p.noteBox:SetPoint("TOPLEFT", 12, -82)
    p.addBtn = flatButton(panel, "Add note", 80, 24, submitNote)
    p.addBtn:SetPoint("TOPLEFT", 498, -82)
    p.pMore = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.pMore:SetPoint("TOPRIGHT", -12, -34)
    p.pMore:SetJustifyH("RIGHT")
    p.noteRows = {}
    for i = 1, NOTE_ROWS do
        local row = CreateFrame("Frame", nil, panel)
        row:SetSize(INNER_W - 24, 13)
        row:SetPoint("TOPLEFT", 12, -108 - (i - 1) * 13)
        row.txt = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.txt:SetPoint("LEFT", 0, 0)
        row.txt:SetWidth(INNER_W - 70)
        row.txt:SetJustifyH("LEFT")
        row.txt:SetWordWrap(false)
        row.del = flatButton(row, "x", 16, 13, function()
            local z = ui.mapSel and DB.zones and DB.zones[ui.mapSel]
            if not z then return end
            for idx, n in ipairs(z.notes) do
                if n.id == row.noteId then
                    table.remove(z.notes, idx)
                    bumpTs(z)
                    break
                end
            end
            refreshUI()
        end)
        row.del:SetPoint("RIGHT", 0, 0)
        row.noteId = ""
        p.noteRows[i] = row
    end
    p:EnableMouseWheel(true)
    p:SetScript("OnMouseWheel", function(_, delta)
        p.noteOff = math.max(0, (p.noteOff or 0) - delta)
        refreshUI()
    end)
    p.noteOff = 0
end

local function todoTargets()
    local names, seen = { "" }, {}
    local list = {}
    for key in pairs(DB.chars) do
        local n = nameOf(key)
        if not seen[n] then seen[n] = true list[#list + 1] = n end
    end
    table.sort(list)
    for _, n in ipairs(list) do names[#names + 1] = n end
    return names
end

local function createTodo(f)
    local p = CreateFrame("Frame", nil, f)
    p:SetPoint("TOPLEFT", 16, -84)
    p:SetSize(INNER_W, 466)
    p:Hide()
    p.off, p.target = 0, ""
    ui.todo = p
    ui.pages.todo = p

    local function submit()
        local ok, why = addTodo(p.input.edit:GetText(), p.target)
        if ok then
            p.input.edit:SetText("")
        elseif why == "full" then
            chat("the to-do list is full. Clear some completed tasks first.")
        end
        refreshUI()
    end
    p.input = inputBox(p, 400, "add a task, e.g. Restock herbs for Alchemy", submit)
    p.input:SetPoint("TOPLEFT", 0, 0)
    p.charBtn = flatButton(p, "For: anyone", 170, 24, function()
        local names = todoTargets()
        local idx = 1
        for i, n in ipairs(names) do
            if n == p.target then idx = i end
        end
        p.target = names[(idx % #names) + 1]
        refreshUI()
    end)
    p.charBtn:SetPoint("TOPLEFT", 408, 0)
    local add = flatButton(p, "Add", 70, 24, submit)
    add:SetPoint("TOPLEFT", 586, 0)

    p.rows = {}
    for i = 1, TODO_ROWS do
        local row = CreateFrame("Frame", nil, p)
        row:SetSize(INNER_W, 26)
        row:SetPoint("TOPLEFT", 0, -34 - (i - 1) * 28)
        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        setc(bg, T.panel)
        row.check = flatButton(row, "", 18, 18, function()
            local t = DB.todos and DB.todos[row.todoId]
            if t then
                t.done = not t.done
                bumpTs(t)
                refreshUI()
            end
        end)
        row.check:SetPoint("LEFT", 8, 0)
        row.txt = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.txt:SetPoint("LEFT", 36, 0)
        row.txt:SetWidth(470)
        row.txt:SetJustifyH("LEFT")
        row.txt:SetWordWrap(false)
        row.who = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.who:SetPoint("LEFT", 520, 0)
        row.who:SetWidth(140)
        row.who:SetJustifyH("LEFT")
        row.del = flatButton(row, "x", 22, 18, function()
            local t = DB.todos and DB.todos[row.todoId]
            if t then
                t.del = true
                bumpTs(t)
                refreshUI()
            end
        end)
        row.del:SetPoint("RIGHT", -6, 0)
        row.todoId = ""
        p.rows[i] = row
    end
    p.empty = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    p.empty:SetPoint("TOPLEFT", 4, -50)
    p.empty:SetWidth(INNER_W - 8)
    p.empty:SetJustifyH("LEFT")
    p.count = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.count:SetPoint("BOTTOMLEFT", 2, 6)
    local clear = flatButton(p, "Clear completed", 110, 22, function()
        for _, t in pairs(DB.todos or {}) do
            if t.done and not t.del then
                t.del = true
                bumpTs(t)
            end
        end
        refreshUI()
    end)
    clear:SetPoint("BOTTOMRIGHT", 0, 2)
    p:EnableMouseWheel(true)
    p:SetScript("OnMouseWheel", function(_, delta)
        p.off = math.max(0, (p.off or 0) - delta * 2)
        refreshUI()
    end)
end

local function createPlay(f)
    local p = CreateFrame("Frame", nil, f)
    p:SetPoint("TOPLEFT", 16, -84)
    p:SetSize(INNER_W, 466)
    p:Hide()
    ui.play = p
    ui.pages.play = p

    p.cards = {}
    local titles = { "Total time played", "Lifetime gold per hour", "Most dedicated" }
    local cw = math.floor((INNER_W - 12) / 3)
    for i = 1, 3 do
        local card = CreateFrame("Frame", nil, p)
        card:SetSize(cw, 56)
        card:SetPoint("TOPLEFT", (i - 1) * (cw + 6), 0)
        local bg = card:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        setc(bg, T.panel)
        card.cap = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        card.cap:SetPoint("TOPLEFT", 10, -8)
        card.cap:SetText("|cff8a93a3" .. titles[i] .. "|r")
        card.value = card:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        card.value:SetPoint("TOPLEFT", 10, -26)
        p.cards[i] = card
    end
    p.fun = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    p.fun:SetPoint("TOPLEFT", 2, -70)
    p.fun:SetWidth(INNER_W - 4)
    p.fun:SetJustifyH("LEFT")

    local cap = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cap:SetPoint("TOPLEFT", 2, -102)
    cap:SetText("|cff8a93a3TIME PLAYED BY CHARACTER|r")
    p.rows = {}
    for i = 1, PLAY_ROWS do
        local row = CreateFrame("Frame", nil, p)
        row:SetSize(INNER_W, 30)
        row:SetPoint("TOPLEFT", 0, -120 - (i - 1) * 32)
        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        setc(bg, T.panel)
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.name:SetPoint("LEFT", 10, 0)
        row.name:SetWidth(250)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)
        row.bar = row:CreateTexture(nil, "ARTWORK")
        row.bar:SetPoint("LEFT", 270, 0)
        row.bar:SetSize(2, 12)
        setc(row.bar, T.accent)
        row.time = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.time:SetPoint("RIGHT", -100, 0)
        row.time:SetWidth(90)
        row.time:SetJustifyH("RIGHT")
        row.gph = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.gph:SetPoint("RIGHT", -8, 0)
        row.gph:SetWidth(90)
        row.gph:SetJustifyH("RIGHT")
        p.rows[i] = row
    end
    p.note = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.note:SetPoint("BOTTOMLEFT", 2, 2)
    p.note:SetWidth(INNER_W - 4)
    p.note:SetJustifyH("LEFT")
end


ui.refreshers = { wealth = refreshWealth, map = refreshMap, todo = refreshTodo, play = refreshPlay }
ui.inputBox, ui.ratingColor = inputBox, RATING_COLOR
ui.createPages = function(f)
    createMap(f)
    createTodo(f)
    createPlay(f)
end
end -- pages

------------------------------------------------------------------------
-- world map overlay: zone colours on continent maps, note pins on zone maps
-- Uses the game's own map frame, so it also follows any map add-on that keeps it.
------------------------------------------------------------------------
do
local wm = { pins = {}, tints = {} }

local function mapAvailable()
    return WorldMapFrame and WorldMapFrame.GetCanvas and C_Map and C_Map.GetMapInfo
end

local function mapInfo(id)
    if not id then return nil end
    local ok, info = pcall(C_Map.GetMapInfo, id)
    if ok and type(info) == "table" then return info end
end

local function getPin(i)
    local pin = wm.pins[i]
    if not pin then
        pin = CreateFrame("Frame", nil, wm.host)
        pin:SetSize(12, 12)
        pin:EnableMouse(true)
        pin:SetFrameLevel((wm.host:GetFrameLevel() or 1) + 20)
        local border = pin:CreateTexture(nil, "ARTWORK")
        border:SetAllPoints()
        setc(border, { 0.05, 0.05, 0.07, 1 })
        local fill = pin:CreateTexture(nil, "OVERLAY")
        fill:SetPoint("TOPLEFT", 2, -2)
        fill:SetPoint("BOTTOMRIGHT", -2, 2)
        setc(fill, T.gold)
        pin.tipTitle, pin.tipText, pin.zoneName, pin.noteId = "", "", "", ""
        pin:SetScript("OnEnter", function()
            GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
            GameTooltip:SetText(pin.tipTitle)
            GameTooltip:AddLine(pin.tipText, 1, 1, 1, true)
            GameTooltip:AddLine("Shift+right-click to delete", 0.5, 0.55, 0.6)
            GameTooltip:Show()
        end)
        pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
        pin:SetScript("OnMouseUp", function(_, button)
            if button == "RightButton" and IsShiftKeyDown and IsShiftKeyDown() then
                local z = DB.zones and DB.zones[pin.zoneName]
                if not z then return end
                for idx, n in ipairs(z.notes) do
                    if n.id == pin.noteId then
                        table.remove(z.notes, idx)
                        bumpTs(z)
                        break
                    end
                end
                GameTooltip:Hide()
                refreshUI()
            end
        end)
        wm.pins[i] = pin
    end
    return pin
end

local function getTint(i)
    local t = wm.tints[i]
    if not t then
        t = wm.host:CreateTexture(nil, "ARTWORK")
        wm.tints[i] = t
    end
    return t
end

function wm.refresh()
    if not wm.ready or not WorldMapFrame:IsShown() then return end
    for _, p in ipairs(wm.pins) do p:Hide() end
    for _, t in ipairs(wm.tints) do t:Hide() end
    if DB.mapOverlay == false then return end
    local id = WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()
    local info = mapInfo(id)
    if not id then return end
    local w, h = wm.canvas:GetWidth(), wm.canvas:GetHeight()
    if type(w) ~= "number" or type(h) ~= "number" or w <= 0 or h <= 0 then return end
    local scale = 1
    if WorldMapFrame.GetCanvasScale then
        local ok, sc = pcall(WorldMapFrame.GetCanvasScale, WorldMapFrame)
        if ok and type(sc) == "number" and sc > 0 then scale = sc end
    end
    local zname = info and cleanText(info.name, 40) or ""

    -- note pins: on the map the note was made on (or by zone name for older notes)
    local n = 0
    for name, z in pairs(DB.zones or {}) do
        for _, note in ipairs(z.notes or {}) do
            local hasMap = note.m and note.m ~= 0
            if ((hasMap and note.m == id) or (not hasMap and name == zname)) and note.x and note.x > 0 and n < 60 then
                n = n + 1
                local pin = getPin(n)
                pin:ClearAllPoints()
                pin:SetPoint("CENTER", wm.canvas, "TOPLEFT", note.x / 1000 * w, -note.y / 1000 * h)
                pin:SetScale(1 / scale)
                pin.tipTitle, pin.tipText, pin.zoneName, pin.noteId = name, noteText(note), name, note.id
                pin:Show()
            end
        end
    end

    -- zone colours on a map that contains zones (continents)
    if C_Map.GetMapChildrenInfo and C_Map.GetMapRectOnMap then
        local ok, kids = pcall(C_Map.GetMapChildrenInfo, id, (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3)
        if ok and type(kids) == "table" then
            local count = 0
            for _, k in ipairs(kids) do
                local z = DB.zones and DB.zones[cleanText(k.name or "", 40)]
                local r = z and z.rating or 0
                if r > 0 and count < 60 and k.mapID then
                    local ok2, l, rr, tp, bt = pcall(C_Map.GetMapRectOnMap, k.mapID, id)
                    if ok2 and type(l) == "number" and type(rr) == "number" and type(tp) == "number" and type(bt) == "number" then
                        count = count + 1
                        local tint = getTint(count)
                        tint:ClearAllPoints()
                        tint:SetPoint("TOPLEFT", wm.canvas, "TOPLEFT", l * w, -tp * h)
                        tint:SetSize(math.max(1, (rr - l) * w), math.max(1, (bt - tp) * h))
                        setc(tint, ui.ratingColor[r] or T.accent, 0.42)
                        tint:Show()
                    end
                end
            end
        end
    end
end

function wm.ask(d)
    if not wm.pop then
        local f = newBackdropFrame("ForeverLedgerNoteAsk", 380, 130)
        f:SetFrameStrata("FULLSCREEN_DIALOG") -- the world map sits above normal windows
        f.head = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        f.head:SetPoint("TOPLEFT", 16, -14)
        f.box = ui.inputBox(f, 348, "note text, e.g. Great Mageweave spawns here", function() wm.save() end)
        f.box:SetPoint("TOPLEFT", 16, -52)
        local save = flatButton(f, "Save note", 90, 24, function() wm.save() end)
        save:SetPoint("BOTTOMRIGHT", -16, 14)
        wm.pop = f
    end
    wm.pending = d
    local info = mapInfo(d.id)
    wm.pop.head:SetText("Note for " .. (info and info.name or "this map"))
    wm.pop.box.edit:SetText("")
    wm.pop:Show()
    wm.pop.box.edit:SetFocus()
end

function wm.save()
    local d = wm.pending
    if not d then return end
    local info = mapInfo(d.id)
    local name = info and cleanText(info.name, 40) or ""
    if name == "" then return end
    local ok, why = addZoneNote(name, wm.pop.box.edit:GetText(), false,
        { x = math.floor(d.x * 1000 + 0.5), y = math.floor(d.y * 1000 + 0.5), m = d.id })
    if ok then
        wm.pending = nil
        wm.pop:Hide()
        refreshUI()
    elseif why == "full" then
        chat(name .. " already has " .. MAX_NOTES .. " notes. Shift+right-click a pin to delete one.")
    end
end

function wm.init()
    if wm.ready or not mapAvailable() then return end
    local canvas = WorldMapFrame:GetCanvas()
    if not canvas then return end
    wm.canvas = canvas
    wm.host = CreateFrame("Frame", nil, canvas)
    wm.host:SetAllPoints(canvas)
    wm.host:SetFrameLevel((canvas:GetFrameLevel() or 1) + 20)
    wm.ready = true
    local hooked = false
    if WorldMapFrame.HookScript then
        pcall(WorldMapFrame.HookScript, WorldMapFrame, "OnShow", function()
            wm.refresh()
            if not DB.mapHintShown then
                DB.mapHintShown = true
                chat("tip: Ctrl+click anywhere on a zone map to drop a note there. Zones you rate in the Ledger's Map tab are coloured on continent maps.")
            end
        end)
        hooked = true
    end
    if hooksecurefunc then
        for _, fn in ipairs({ "OnMapChanged", "OnCanvasScaleChanged" }) do
            if type(WorldMapFrame[fn]) == "function" then
                pcall(hooksecurefunc, WorldMapFrame, fn, function() wm.refresh() end)
                hooked = true
            end
        end
    end
    local sc = WorldMapFrame.ScrollContainer
    if sc and sc.HookScript and sc.GetNormalizedCursorPosition then
        pcall(sc.HookScript, sc, "OnMouseDown", function(_, button)
            wm.down = nil
            if button == "LeftButton" and IsControlKeyDown and IsControlKeyDown() then
                local x, y = sc:GetNormalizedCursorPosition()
                local id = WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()
                local info = mapInfo(id)
                if id and type(x) == "number" and x > 0 and x < 1 and y > 0 and y < 1 and not (info and info.mapType and info.mapType < 3) then
                    wm.down = { id = id, x = x, y = y }
                end
            end
        end)
        pcall(sc.HookScript, sc, "OnMouseUp", function(_, button)
            local d = wm.down
            wm.down = nil
            if d and button == "LeftButton" then
                local x, y = sc:GetNormalizedCursorPosition()
                if type(x) == "number" and math.abs(x - d.x) < 0.01 and math.abs(y - d.y) < 0.01 then wm.ask(d) end
            end
        end)
    end
    LX.mapHooked = hooked
    wm.refresh()
end

state.mapRefresh = function() if wm.ready then wm.refresh() end end
LX.initMap = wm.init
LX.mapState = wm
end -- world map overlay

function refreshUI()
    if state.mapRefresh then state.mapRefresh() end
    if not ui.frame or not ui.frame:IsShown() then return end
    if ui.headTotal then ui.headTotal:SetText("|cff8a93a3All characters|r  " .. moneyStr(totalMoney())) end
    local page = ui.refreshers[ui.mode]
    if page then
        page()
        ui.total:SetText("")
        updateThumb()
        return
    end
    if ui.filterBtns then
        for _, b in ipairs(ui.filterBtns) do setActive(b, b.filterKey == (ui.ledgerFilter or "all")) end
    end
    local rows, grand, footer = buildRows(ui.search:GetText())
    for i, row in ipairs(rows) do
        local r = getRow(i)
        r.left:SetFontObject(row.header and GameFontNormal or (row.sub and GameFontHighlightSmall or GameFontHighlight))
        r.right:SetFontObject(row.header and GameFontNormal or GameFontHighlight)
        r.left:SetText(row.left)
        r.right:SetText(row.right or "")
        if row.header then r.bg:Show() else r.bg:Hide() end
        r.left:Show() r.right:Show()
    end
    for i = #rows + 1, #ui.rows do
        ui.rows[i].left:Hide() ui.rows[i].right:Hide() ui.rows[i].bg:Hide()
    end
    ui.contentH = math.max(1, #rows * ROW_H)
    ui.content:SetHeight(ui.contentH)
    ui.total:SetText(footer or (grand and ("|cff8a93a3All accounts|r  " .. moneyStr(grand)) or ""))
    updateThumb()
end

local SEARCH_MODES = { overview = true, materials = true, auctions = true, ledger = true }
local LIST_MODES = { overview = true, materials = true, auctions = true, ledger = true, move = true }

local function setMode(mode)
    ui.mode = mode
    if ui.tabs then
        for key, b in pairs(ui.tabs) do setActive(b, key == mode) end
        for key, page in pairs(ui.pages) do
            if key == mode then page:Show() else page:Hide() end
        end
        if LIST_MODES[mode] then ui.scroll:Show() else ui.scroll:Hide() end
        if SEARCH_MODES[mode] then ui.searchBox:Show() else ui.searchBox:Hide() end
        if mode == "ledger" then ui.filterBar:Show() else ui.filterBar:Hide() end
        if ui.search:GetText() ~= "" then ui.search:SetText("") end
        ui.scroll:SetVerticalScroll(0)
    end
    refreshUI()
end

local function showText(title, text, acceptLabel, onAccept)
    if not ui.tf then
        local tf = newBackdropFrame("ForeverLedgerTextFrame", 440, 360)
        tf.title = tf:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        tf.title:SetPoint("TOPLEFT", 20, -18)
        local sf = CreateFrame("ScrollFrame", "ForeverLedgerTextScroll", tf, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT", 20, -48)
        sf:SetPoint("BOTTOMRIGHT", -36, 50)
        local eb = CreateFrame("EditBox", nil, sf)
        eb:SetMultiLine(true)
        eb:SetFontObject(ChatFontNormal)
        eb:SetWidth(370)
        eb:SetMaxLetters(0)
        eb:SetAutoFocus(false)
        eb:SetScript("OnEscapePressed", eb.ClearFocus)
        sf:SetScrollChild(eb)
        tf.eb = eb
        local btn = CreateFrame("Button", nil, tf, "UIPanelButtonTemplate")
        btn:SetSize(110, 24)
        btn:SetPoint("BOTTOM", 0, 18)
        tf.btn = btn
        ui.tf = tf
    end
    local tf = ui.tf
    tf.title:SetText(title)
    tf.eb:SetText(text or "")
    tf.btn:SetText(acceptLabel or "Close")
    tf.btn:SetScript("OnClick", function()
        if onAccept then onAccept(tf.eb:GetText()) end
        tf:Hide()
    end)
    tf:Show()
    tf.eb:SetFocus()
    if text and text ~= "" then tf.eb:HighlightText() end
end

local function doExport()
    local out = {}
    for _, key in ipairs(localChars()) do
        for _, line in ipairs(charLines(key, DB.chars[key])) do
            out[#out + 1] = "X^" .. line
        end
    end
    for _, line in ipairs(sharedLines()) do out[#out + 1] = "X^" .. line end
    showText("Export: copy this (Ctrl+C), paste into /ledger import on your other account", table.concat(out, "\n"), "Close")
end

local function doImport(text)
    local n, shared = 0, 0
    for line in text:gmatch("[^\r\n]+") do
        local l = line:match("^%a%^(.*)$")
        local r = l and handleLine(l, "import")
        if r == "committed" then n = n + 1 elseif r == "shared" then shared = shared + 1 end
    end
    for k in pairs(state.staging) do
        if k:find("^import|") then state.staging[k] = nil end
    end
    chat("imported " .. n .. " character(s)" .. (shared > 0 and (" and " .. shared .. " note/to-do records") or "") .. ".")
    refreshUI()
end

local function showImport()
    showText("Import: paste exported text, then press Import", "", "Import", doImport)
end

local function createWealth(f)
    local w = CreateFrame("Frame", nil, f)
    w:SetPoint("TOPLEFT", 16, -84)
    w:SetSize(WEALTH_W, 452)
    w:Hide()
    w.bars = {}
    ui.wealth = w
    ui.pages.wealth = w

    local cap = w:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cap:SetPoint("TOPLEFT", 2, 0)
    cap:SetText("|cff8a93a3TOTAL WEALTH|r")
    w.big = w:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    w.big:SetPoint("TOPLEFT", 2, -14)
    w.big:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 26, "")

    w.chips = {}
    local chipLabels = { "Today", "Last 7 days", "Last 30 days" }
    for i = 1, 3 do
        local card = CreateFrame("Frame", nil, w)
        card:SetSize(math.floor((INNER_W - 12) / 3), 50)
        card:SetPoint("TOPLEFT", (i - 1) * (math.floor((INNER_W - 12) / 3) + 6), -54)
        local bg = card:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        setc(bg, T.panel)
        card.cap = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        card.cap:SetPoint("TOPLEFT", 10, -8)
        card.cap:SetText("|cff8a93a3" .. chipLabels[i] .. "|r")
        card.value = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        card.value:SetPoint("TOPLEFT", 10, -26)
        w.chips[i] = card
    end

    local cp = CreateFrame("Frame", nil, w)
    cp:SetSize(WEALTH_W, 160)
    cp:SetPoint("TOPLEFT", 0, -114)
    local cbg = cp:CreateTexture(nil, "BACKGROUND")
    cbg:SetAllPoints()
    setc(cbg, T.panel)
    w.chart = cp
    cp.title = cp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cp.title:SetPoint("TOPLEFT", 12, -14)
    cp.rangeBtns = {}
    for i, days in ipairs({ 90, 30, 7 }) do
        local b = flatButton(cp, days .. "d", 38, 20, function()
            ui.range = days
            refreshUI()
        end)
        b:SetPoint("TOPRIGHT", -10 - (i - 1) * 42, -8)
        b.days = days
        cp.rangeBtns[#cp.rangeBtns + 1] = b
    end
    cp.plot = CreateFrame("Frame", nil, cp)
    cp.plot:SetSize(PLOT_W, PLOT_H)
    cp.plot:SetPoint("TOPLEFT", 64, -38)
    local base = cp.plot:CreateTexture(nil, "BORDER")
    base:SetPoint("BOTTOMLEFT", 0, -1)
    base:SetPoint("BOTTOMRIGHT", 0, -1)
    base:SetHeight(1)
    setc(base, T.border)
    cp.hi = cp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cp.hi:SetPoint("TOPLEFT", 10, -38)
    cp.lo = cp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cp.lo:SetPoint("TOPLEFT", 10, -38 - PLOT_H + 12)
    cp.d1 = cp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cp.d1:SetPoint("TOPLEFT", 64, -38 - PLOT_H - 8)
    cp.d2 = cp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cp.d2:SetPoint("TOPRIGHT", -14, -38 - PLOT_H - 8)
    cp.d2:SetJustifyH("RIGHT")
    cp.empty = cp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cp.empty:SetPoint("TOPLEFT", 76, -52)
    cp.empty:SetWidth(280)
    cp.empty:SetJustifyH("LEFT")

    w.mLeft = w:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    w.mLeft:SetPoint("TOPLEFT", 2, -286)
    w.mRight = w:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    w.mRight:SetPoint("TOPRIGHT", -2, -288)
    w.mRight:SetJustifyH("RIGHT")
    local track = w:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("TOPLEFT", 0, -308)
    track:SetSize(WEALTH_W, 10)
    setc(track, T.panel)
    w.mFill = w:CreateTexture(nil, "ARTWORK")
    w.mFill:SetPoint("TOPLEFT", 0, -308)
    w.mFill:SetSize(1, 10)
    setc(w.mFill, T.accent)

    w.cells = {}
    for i = 1, 6 do
        local fs = w:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
        fs:SetPoint("TOPLEFT", 2 + col * math.floor(INNER_W / 2), -336 - row * 26)
        fs:SetWidth(math.floor(INNER_W / 2) - 8)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        w.cells[i] = fs
    end
end

local TAB_ORDER = {
    { "overview", "Overview" }, { "wealth", "Wealth" }, { "ledger", "Ledger" }, { "map", "Map" }, { "todo", "To-do" },
    { "play", "Playtime" }, { "materials", "Materials" }, { "auctions", "Auctions" }, { "move", "Move list" },
}

local function createUI()
    local f = newBackdropFrame("ForeverLedgerFrame", WIN_W, WIN_H)
    ui.frame = f

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -14)
    title:SetText("|cff40adffForever Ledger|r")

    local setupBtn = flatButton(f, "Setup", 52, 22, function() openSetup(1) end)
    setupBtn:SetPoint("TOPRIGHT", -36, -10)
    ui.headTotal = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.headTotal:SetPoint("TOPRIGHT", -98, -16)
    ui.headTotal:SetJustifyH("RIGHT")

    -- one button per view
    ui.tabs = {}
    for i, t in ipairs(TAB_ORDER) do
        local key = t[1]
        local b = flatButton(f, t[2], 76, 28, function() setMode(key) end)
        b:SetPoint("TOPLEFT", 16 + (i - 1) * 78, -42)
        b.hasLine = true
        b.line = b:CreateTexture(nil, "OVERLAY")
        b.line:SetPoint("BOTTOMLEFT")
        b.line:SetPoint("BOTTOMRIGHT")
        b.line:SetHeight(2)
        setc(b.line, T.accent)
        ui.tabs[key] = b
    end

    -- search
    local sb = CreateFrame("Frame", nil, f)
    sb:SetSize(300, 24)
    sb:SetPoint("TOPLEFT", 16, -80)
    local sbg = sb:CreateTexture(nil, "BACKGROUND")
    sbg:SetAllPoints()
    setc(sbg, T.panel)
    ui.searchBox = sb
    local hint = sb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("LEFT", 10, 0)
    hint:SetText("|cff6b7280Search items...|r")
    local search = CreateFrame("EditBox", nil, sb)
    search:SetSize(280, 18)
    search:SetPoint("LEFT", 10, 0)
    search:SetFontObject(GameFontHighlight)
    search:SetAutoFocus(false)
    search:SetScript("OnTextChanged", function()
        if search:GetText() == "" then hint:Show() else hint:Hide() end
        refreshUI()
    end)
    search:SetScript("OnEscapePressed", search.ClearFocus)
    search:SetScript("OnEnterPressed", search.ClearFocus)
    ui.search = search

    -- scrolling list
    local sf = CreateFrame("ScrollFrame", nil, f)
    sf:SetPoint("TOPLEFT", 16, -VIEW_TOP)
    sf:SetPoint("BOTTOMRIGHT", -34, VIEW_BOTTOM)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
        local cur = self:GetVerticalScroll() or 0
        local max = self:GetVerticalScrollRange() or 0
        self:SetVerticalScroll(math.max(0, math.min(max, cur - delta * ROW_H * 3)))
        updateThumb()
    end)
    sf:SetScript("OnVerticalScroll", function() updateThumb() end)
    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(CONTENT_W, 1)
    sf:SetScrollChild(content)
    ui.content, ui.scroll = content, sf
    ui.thumb = f:CreateTexture(nil, "ARTWORK")
    ui.thumb:SetSize(3, 30)
    setc(ui.thumb, T.steel)
    ui.thumb:Hide()

    createWealth(f)
    ui.createPages(f)

    -- ledger filters
    local fb = CreateFrame("Frame", nil, f)
    fb:SetSize(360, 24)
    fb:SetPoint("TOPLEFT", 332, -80)
    ui.filterBar = fb
    ui.filterBtns = {}
    for i, opt in ipairs({ { "all", "All" }, { "v", "Vendor" }, { "p", "Players" }, { "a", "Auction" }, { "l", "Loot" }, { "q", "Quest" } }) do
        local b = flatButton(fb, opt[2], 56, 24, function()
            ui.ledgerFilter = opt[1]
            refreshUI()
        end)
        b:SetPoint("LEFT", (i - 1) * 60, 0)
        b.filterKey = opt[1]
        ui.filterBtns[#ui.filterBtns + 1] = b
    end
    fb:Hide()

    -- footer
    local foot = f:CreateTexture(nil, "BORDER")
    foot:SetPoint("BOTTOMLEFT", 16, 46)
    foot:SetPoint("BOTTOMRIGHT", -16, 46)
    foot:SetHeight(1)
    setc(foot, T.border)
    ui.total = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ui.total:SetPoint("BOTTOMLEFT", 18, 52)
    local function footer(text, x, fn)
        local b = flatButton(f, text, 84, 24, fn)
        b:SetPoint("BOTTOMLEFT", x, 14)
        return b
    end
    footer("Sync now", 16, function()
        if syncAll() then chat("sync sent to linked characters.") else chat("nothing to sync with: no characters from another account are linked. (Characters on this account share data automatically.)") end
    end)
    footer("Export", 106, doExport)
    footer("Import", 196, showImport)

    f:SetScript("OnShow", refreshUI)
    ui.range = ui.range or 30
    ui.ledgerFilter = ui.ledgerFilter or "all"
    state.onChange = refreshUI
    setMode(ui.mode or "overview")
end

local function toggleUI()
    if not ui.frame then createUI() end
    if ui.frame:IsShown() then ui.frame:Hide() else ui.frame:Show() end
end

------------------------------------------------------------------------
-- guided setup window (3 steps) + minimap button
------------------------------------------------------------------------
local setup = { page = 1, charIndex = 1 }
local SETUP_PAGES = 4
local ROLE_ORDER = { "ah" }
for _, k in ipairs(CATEGORY_ORDER) do ROLE_ORDER[#ROLE_ORDER + 1] = k end

local function roleLabel(role)
    if role == "ah" then return "Auction house seller" end
    return CATEGORIES[role].label .. " warehouse"
end

local function currentChar()
    local list = localChars()
    if #list == 0 then return nil end
    if setup.charIndex > #list then setup.charIndex = 1 end
    if setup.charIndex < 1 then setup.charIndex = #list end
    return list[setup.charIndex], DB.chars[list[setup.charIndex]]
end

local function refreshSetupRoles()
    if not setup.checks then return end
    local key, c = currentChar()
    if not c then
        setup.charLabel:SetText("|cff888888No characters recorded yet|r")
        for _, cb in pairs(setup.checks) do cb:Hide() end
        return
    end
    setup.charLabel:SetText(classColor(c.class) .. nameOf(key) .. "|r")
    for role, cb in pairs(setup.checks) do
        cb:Show()
        cb:SetChecked(hasRole(c, role))
    end
end

local function refreshSetupProfs()
    if not setup.profChecks then return end
    local key, c = currentChar()
    if not c then
        setup.profLabel:SetText("|cff888888No characters recorded yet|r")
        setup.profKnown:SetText("")
        for _, cb in pairs(setup.profChecks) do cb:Hide() end
        return
    end
    setup.profLabel:SetText(classColor(c.class) .. nameOf(key) .. "|r")
    local assigned = {}
    for _, t in ipairs(c.assigned or {}) do assigned[t] = true end
    for token, cb in pairs(setup.profChecks) do
        cb:Show()
        cb:SetChecked(assigned[token] and true or false)
    end
    local learned = {}
    for _, p in ipairs(c.profs or {}) do learned[#learned + 1] = p.name .. " " .. p.rank end
    if #learned > 0 then
        setup.profKnown:SetText("Currently learned: " .. table.concat(learned, ", "))
    else
        setup.profKnown:SetText("|cff888888No professions read from this character yet. They are detected automatically after you log in on it.|r")
    end
end

local function refreshSetupLinks()
    if not setup.linkRows then return end
    local names = {}
    for _, display in pairs(DB.trusted) do names[#names + 1] = display end
    table.sort(names)
    for i, row in ipairs(setup.linkRows) do
        local name = names[i]
        if name then
            row.name:SetText(name)
            row.btn:SetScript("OnClick", function()
                DB.trusted[canon(name)] = nil
                refreshSetupLinks()
            end)
            row.name:Show()
            row.btn:Show()
        else
            row.name:Hide()
            row.btn:Hide()
        end
    end
    setup.noLinks:SetText(#names == 0 and "|cff888888No characters linked yet.|r" or "")
end

local function showSetupPage(n)
    setup.page = n
    for i, p in ipairs(setup.pages) do
        if i == n then p:Show() else p:Hide() end
    end
    local titles = { "Name this account", "Warehouses and selling", "Assign professions", "Link your other account" }
    setup.frame.title:SetText(titles[n])
    setup.frame.step:SetText("Step " .. n .. " of " .. SETUP_PAGES)
    if n == 1 then setup.back:Hide() else setup.back:Show() end
    setup.next:SetText(n == SETUP_PAGES and "Done" or "Next")
    if n == 1 then
        setup.nameBox:SetText(DB.account or "")
    elseif n == 2 then
        refreshSetupRoles()
    elseif n == 3 then
        refreshSetupProfs()
    else
        refreshSetupLinks()
    end
end

local function setupNext()
    if setup.page == 1 then
        local label = cleanLabel(setup.nameBox:GetText())
        if label ~= "" then
            DB.account = label
            for _, c in pairs(DB.chars) do
                if c.localChar then c.account = label end
            end
            updateSelf(false)
        end
    end
    if setup.page < SETUP_PAGES then
        showSetupPage(setup.page + 1)
        return
    end
    setup.frame:Hide()
    local syncing = next(DB.trusted) ~= nil and syncAll()
    chat("setup complete." .. (syncing and " Syncing with your linked characters." or " Click the coin button on your minimap any time to open the ledger."))
    if not ui.frame then createUI() end
    ui.frame:Show()
end

local function addLink()
    local raw = setup.linkBox:GetText():match("^%s*(%S.-)%s*$")
    if not raw then return end
    local name = titleCase(cleanName(raw))
    if not name:find(" ") then
        chat("Forever characters have a first and last name. Type both, like 'First Last'.")
    end
    for key, c in pairs(DB.chars) do
        if c.localChar and canon(nameOf(key)) == canon(name) then
            chat(name .. " is on this account, so no link is needed. Enter a character from your OTHER account.")
            return
        end
    end
    local count = 0
    for _ in pairs(DB.trusted) do count = count + 1 end
    if count >= 8 then
        chat("that's the maximum of 8 linked characters. Remove one first.")
        return
    end
    DB.trusted[canon(name)] = name
    setup.linkBox:SetText("")
    refreshSetupLinks()
end

local function toggleRole(role, checked)
    local _, c = currentChar()
    if not c then return end
    local out = {}
    for _, r in ipairs(c.roles or {}) do
        if r ~= role then out[#out + 1] = r end
    end
    if checked then out[#out + 1] = role end
    c.roles = out
    c.time = time() -- so the other account accepts the change as newer
    refreshUI()
end

local function toggleAssigned(token, checked, cb)
    local _, c = currentChar()
    if not c then return end
    local out, primaries = {}, 0
    for _, t in ipairs(c.assigned or {}) do
        if t ~= token then
            out[#out + 1] = t
            if PROF_PRIMARY[t] then primaries = primaries + 1 end
        end
    end
    if checked then
        if PROF_PRIMARY[token] and primaries >= 2 then
            cb:SetChecked(false)
            chat("a character can only have two primary professions. Untick one first. (Cooking, First Aid and Fishing are free.)")
            return
        end
        out[#out + 1] = token
    end
    c.assigned = out
    c.time = time() -- so the other account accepts the change as newer
    refreshUI()
end

local function createSetup()
    local f = newBackdropFrame("ForeverLedgerSetup", 440, 430)
    setup.frame = f
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOPLEFT", 22, -20)
    f.step = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.step:SetPoint("TOPRIGHT", -44, -26)

    setup.pages = {}
    for i = 1, SETUP_PAGES do
        local p = CreateFrame("Frame", nil, f)
        p:SetPoint("TOPLEFT", 24, -58)
        p:SetPoint("BOTTOMRIGHT", -24, 58)
        p:Hide()
        setup.pages[i] = p
    end

    local function text(parent, str, x, y)
        local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("TOPLEFT", x, y)
        fs:SetWidth(380)
        fs:SetJustifyH("LEFT")
        fs:SetText(str)
        return fs
    end

    -- step 1: account name
    text(setup.pages[1], "Give this WoW account a name so you can tell your accounts apart, for example Main or Bank.\n\nEvery character you play on this account will be listed under it.", 0, 0)
    local nameBox = CreateFrame("EditBox", nil, setup.pages[1], "InputBoxTemplate")
    nameBox:SetSize(220, 24)
    nameBox:SetPoint("TOPLEFT", 8, -120)
    nameBox:SetAutoFocus(false)
    nameBox:SetMaxLetters(24)
    nameBox:SetScript("OnEnterPressed", nameBox.ClearFocus)
    nameBox:SetScript("OnEscapePressed", nameBox.ClearFocus)
    setup.nameBox = nameBox

    -- step 2: roles per character
    local p2 = setup.pages[2]
    text(p2, "Optional. Pick a character, then tick what it is for. A warehouse character stores one kind of item (like herbs); an auction house seller does the listing. The ledger will then show you what to mail to them.", 0, 0)
    local prev = CreateFrame("Button", nil, p2, "UIPanelButtonTemplate")
    prev:SetSize(28, 22)
    prev:SetPoint("TOPLEFT", 0, -82)
    prev:SetText("<")
    prev:SetScript("OnClick", function() setup.charIndex = setup.charIndex - 1 refreshSetupRoles() end)
    local nextChar = CreateFrame("Button", nil, p2, "UIPanelButtonTemplate")
    nextChar:SetSize(28, 22)
    nextChar:SetPoint("TOPLEFT", 232, -82)
    nextChar:SetText(">")
    nextChar:SetScript("OnClick", function() setup.charIndex = setup.charIndex + 1 refreshSetupRoles() end)
    setup.charLabel = p2:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    setup.charLabel:SetPoint("TOPLEFT", 36, -84)
    setup.checks = {}
    for i, role in ipairs(ROLE_ORDER) do
        local cb = CreateFrame("CheckButton", nil, p2, "UICheckButtonTemplate")
        local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
        cb:SetPoint("TOPLEFT", col * 195, -118 - row * 28)
        local label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
        label:SetText(roleLabel(role))
        cb:SetScript("OnClick", function(self) toggleRole(role, self:GetChecked() and true or false) end)
        setup.checks[role] = cb
    end

    -- step 3: assign professions per character
    local pp = setup.pages[3]
    text(pp, "Optional. Tick the professions each character should have, even if they haven't learned them yet. The ledger shows these in blue next to what has actually been learned, so you can see your plan at a glance.", 0, 0)
    local pprev = CreateFrame("Button", nil, pp, "UIPanelButtonTemplate")
    pprev:SetSize(28, 22)
    pprev:SetPoint("TOPLEFT", 0, -72)
    pprev:SetText("<")
    pprev:SetScript("OnClick", function() setup.charIndex = setup.charIndex - 1 refreshSetupProfs() end)
    local pnext = CreateFrame("Button", nil, pp, "UIPanelButtonTemplate")
    pnext:SetSize(28, 22)
    pnext:SetPoint("TOPLEFT", 232, -72)
    pnext:SetText(">")
    pnext:SetScript("OnClick", function() setup.charIndex = setup.charIndex + 1 refreshSetupProfs() end)
    setup.profLabel = pp:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    setup.profLabel:SetPoint("TOPLEFT", 36, -74)
    setup.profChecks = {}
    for i, p in ipairs(PROFESSIONS) do
        local token = p[1]
        local cb = CreateFrame("CheckButton", nil, pp, "UICheckButtonTemplate")
        local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
        cb:SetPoint("TOPLEFT", col * 195, -102 - row * 26)
        local label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
        label:SetText(p[2] .. (PROF_PRIMARY[token] and "" or "  (secondary)"))
        cb:SetScript("OnClick", function(self) toggleAssigned(token, self:GetChecked() and true or false, self) end)
        setup.profChecks[token] = cb
    end
    setup.profKnown = text(pp, "", 0, -266)

    -- step 4: link other account
    local p3 = setup.pages[4]
    text(p3, "Only needed if you play a second WoW account. Type the full name (first and last) of a character on your OTHER account, and do the same over there with a character from this one. They sync whenever both are online. Only one account? Just press Done.", 0, 0)
    local linkBox = CreateFrame("EditBox", nil, p3, "InputBoxTemplate")
    linkBox:SetSize(240, 24)
    linkBox:SetPoint("TOPLEFT", 8, -92)
    linkBox:SetAutoFocus(false)
    linkBox:SetMaxLetters(40)
    linkBox:SetScript("OnEnterPressed", addLink)
    linkBox:SetScript("OnEscapePressed", linkBox.ClearFocus)
    setup.linkBox = linkBox
    local add = CreateFrame("Button", nil, p3, "UIPanelButtonTemplate")
    add:SetSize(70, 24)
    add:SetPoint("LEFT", linkBox, "RIGHT", 8, 0)
    add:SetText("Link")
    add:SetScript("OnClick", addLink)
    setup.noLinks = p3:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    setup.noLinks:SetPoint("TOPLEFT", 8, -128)
    setup.linkRows = {}
    for i = 1, 8 do
        local y = -128 - (i - 1) * 24
        local row = {}
        row.name = p3:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.name:SetPoint("TOPLEFT", 8, y)
        row.btn = CreateFrame("Button", nil, p3, "UIPanelButtonTemplate")
        row.btn:SetSize(70, 20)
        row.btn:SetPoint("TOPLEFT", 200, y + 3)
        row.btn:SetText("Remove")
        setup.linkRows[i] = row
    end

    setup.back = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    setup.back:SetSize(90, 24)
    setup.back:SetPoint("BOTTOMLEFT", 24, 20)
    setup.back:SetText("Back")
    setup.back:SetScript("OnClick", function() showSetupPage(math.max(1, setup.page - 1)) end)
    setup.next = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    setup.next:SetSize(90, 24)
    setup.next:SetPoint("BOTTOMRIGHT", -24, 20)
    setup.next:SetScript("OnClick", setupNext)
end

function openSetup(page)
    if not DB then return end
    if not setup.frame then createSetup() end
    showSetupPage(page or 1)
    setup.frame:Show()
end

local function applyMinimapPosition()
    local b = setup.minimap
    if not b then return end
    local a = math.rad(DB.minimapAngle or 215)
    b:ClearAllPoints()
    b:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(a), 80 * math.sin(a))
    if DB.hideMinimap then b:Hide() else b:Show() end
end

local function createMinimapButton()
    if setup.minimap or not Minimap then return end
    local b = CreateFrame("Button", "ForeverLedgerMinimapButton", Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    local icon = b:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 1)
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    b:SetScript("OnClick", function(_, button)
        if button == "RightButton" then openSetup(1) else toggleUI() end
    end)
    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local s = Minimap:GetEffectiveScale()
            DB.minimapAngle = math.deg(math.atan2(py / s - my, px / s - mx))
            applyMinimapPosition()
        end)
    end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Forever Ledger")
        GameTooltip:AddLine("Left-click: open the ledger", 1, 1, 1)
        GameTooltip:AddLine("Right-click: setup", 1, 1, 1)
        GameTooltip:AddLine("Drag: move this button", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    setup.minimap = b
    applyMinimapPosition()
end

------------------------------------------------------------------------
-- tooltip
------------------------------------------------------------------------
local function addTooltip(tt, id)
    if not DB or not id then return end
    local me, total, list = myKey(), 0, {}
    for key, c in pairs(DB.chars) do
        local n = c.items and c.items[id]
        if n and n > 0 then
            total = total + n
            if key ~= me then list[#list + 1] = { key = key, c = c, n = n } end
        end
    end
    -- which warehouse (if any) is meant to hold this item?
    local cats, homes = itemCats(id), {}
    for key, c in pairs(DB.chars) do
        if key ~= me then
            for _, r in ipairs(c.roles or {}) do
                if cats[r] then homes[#homes + 1] = nameOf(key) break end
            end
        end
    end
    table.sort(homes)
    if #list == 0 and #homes == 0 then return end
    table.sort(list, function(a, b) return a.key < b.key end)
    tt:AddLine(" ")
    if #homes > 0 then
        tt:AddLine("|cff33ccffLedger|r warehouse: " .. table.concat(homes, ", "))
    end
    if #list == 0 then tt:Show() return end
    tt:AddDoubleLine("|cff33ccffLedger|r (all characters)", tostring(total))
    for _, e in ipairs(list) do
        tt:AddDoubleLine(
            classColor(e.c.class) .. nameOf(e.key) .. "|r |cff888888(" .. (e.c.account or "?") .. ")|r",
            tostring(e.n))
    end
    tt:Show()
end

local function hookTooltips()
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt, data)
            if data and data.id and (tt == GameTooltip or tt == ItemRefTooltip) then addTooltip(tt, data.id) end
        end)
    else
        for _, tt in ipairs({ GameTooltip, ItemRefTooltip }) do
            if tt and tt.HookScript then
                tt:HookScript("OnTooltipSetItem", function(self)
                    local _, link = self:GetItem()
                    addTooltip(self, link and tonumber(link:match("item:(%d+)")))
                end)
            end
        end
    end
end

------------------------------------------------------------------------
-- hide "No player named X is currently playing" for linked characters
------------------------------------------------------------------------
local notFoundPat = (ERR_CHAT_PLAYER_NOT_FOUND_S or "No player named '%s' is currently playing.")
notFoundPat = notFoundPat:gsub("([%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
notFoundPat = notFoundPat:gsub("%%s", "(.+)")

local function systemFilter(_, _, msg)
    if DB and GetTime() - state.lastSend < 20 then
        local who = msg:match(notFoundPat)
        if who and trustedKey(canon(who)) then return true end
    end
    return false
end

------------------------------------------------------------------------
-- slash commands
------------------------------------------------------------------------
local function help()
    chat("commands:")
    print("  /ledger : open or close the window (or click the coin button on your minimap)")
    print("  /ledger setup : guided setup window (no need for the commands below)")
    print("  /ledger minimap : show or hide the minimap button")
    print("  /ledger account <label> : name THIS account (e.g. Main, Alts)")
    print("  /ledger link <First Last> : trust a character on your other account for live sync")
    print("  /ledger unlink <First Last>, /ledger links, /ledger whisperstyle dash|space")
    print("  /ledger sync : push this account's data to linked characters")
    print("  /ledger item <text> : who has it?")
    print("  /ledger export, /ledger import : copy/paste sync (no need to be online together)")
    print("  /ledger warehouse <Character> <roles> : e.g. herbs, cloth, ah (auction house alt); see /ledger warehouse")
    print("  /ledger prof [name] : who has which profession (e.g. /ledger prof alchemy)")
    print("  /ledger auctions [text] : every character's active auctions")
    print("  /ledger materials [text] : every character's trade goods, grouped by type")
    print("  /ledger wealth : total wealth chart, growth and milestones")
    print("  /ledger tx [text] : transaction ledger (vendors, trades, mail, auction house)")
    print("  /ledger map : zone map with ratings and notes;  /ledger note <text> adds a note where you stand")
    print("  /ledger mapoverlay : show or hide your notes and zone colours on the world map (Ctrl+click a zone map to add a note)")
    print("  /ledger todo [Name:] <text> : add a to-do (optionally for one character) and open the list")
    print("  /ledger played : time played across all your characters")
    print("  /ledger move : what is sitting on other characters that belongs in a warehouse")
    print("  /ledger forget <Character> : remove a synced character")
end

SLASH_FOREVERLEDGER1 = "/ledger"
SLASH_FOREVERLEDGER2 = "/al"
SLASH_FOREVERLEDGER3 = "/fl"
SlashCmdList["FOREVERLEDGER"] = function(msg)
    msg = msg or ""
    local cmd, arg = msg:match("^(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()

    if cmd == "" then
        toggleUI()
    elseif cmd == "help" then
        help()
    elseif cmd == "status" then
        local keys = {}
        for key in pairs(DB.chars) do keys[#keys + 1] = key end
        table.sort(keys)
        chat("what is stored right now (version " .. (((C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata or function() end)(ADDON, "Version") or "?") .. "):")
        for _, key in ipairs(keys) do
            local c = DB.chars[key]
            print(string.format("  %s @%s: %s (%s copper), %s, updated %s",
                nameOf(key), c.account or "?", moneyStr(c.money), tostring(c.money),
                c.localChar and "this account" or "synced", ago(c.time)))
        end
    elseif cmd == "debug" then
        local function yn(v) return v and "yes" or "NO" end
        chat("diagnostics (send me this if something isn't working):")
        print("  bag API: C_Container " .. yn(C_Container and C_Container.GetContainerItemInfo) .. ", legacy " .. yn(GetContainerItemInfo))
        print("  item type lookup: C_Item " .. yn(C_Item and C_Item.GetItemInfoInstant) .. ", legacy " .. yn(GetItemInfoInstant))
        print("  skills API: C_SkillInfo " .. yn(C_SkillInfo and C_SkillInfo.GetSkillLineInfo) .. ", legacy " .. yn(GetSkillLineInfo) .. ", skill lines " .. skillNum())
        print("  auction API: C_AuctionHouse owned-auctions " .. yn(C_AuctionHouse and C_AuctionHouse.GetNumOwnedAuctions and C_AuctionHouse.GetOwnedAuctionInfo) .. ", legacy " .. yn(GetNumAuctionItems))
        print("  auction scans this session: " .. (state.auctionScans or 0) .. ", last result: " .. tostring(state.auctionLast or "none yet") .. " active")
        local ids, slots, types, trade, noClass = bagIDs(), 0, 0, 0, 0
        local live = {}
        local ok, err = pcall(function() live = scanBags(ids) end)
        if not ok then print("  bag scan ERROR: " .. tostring(err)) end
        for _, b in ipairs(ids) do slots = slots + (slotsOf(b) or 0) end
        for id in pairs(live) do
            types = types + 1
            if tradeGroup(id) then trade = trade + 1 end
            if itemClassInfo(id) == nil then noClass = noClass + 1 end
        end
        print(string.format("  bags right now: %d slots, %d item types, %d trade goods, %d with no type data", slots, types, trade, noClass))
        local c = DB.chars[myKey()] or {}
        local stored = 0
        for _ in pairs(c.items or {}) do stored = stored + 1 end
        print(string.format("  stored for this character: %d item types, %d professions, %d assigned", stored, #(c.profs or {}), #(c.assigned or {})))
        print(string.format("  ledger hooks: vendor %s, mail %s, mail-send %s, auction house %s, quest %s; entries recorded this session: %d",
            yn(LX.hooks and LX.hooks.merchant), yn(LX.hooks and LX.hooks.mail), yn(LX.hooks and LX.hooks.send), yn(LX.hooks and LX.hooks.ah), yn(LX.hooks and LX.hooks.quest), state.entries or 0))
        print("  world map overlay: " .. (LX.mapState and LX.mapState.ready and "ready" or "NOT ready (map frame not found yet)") .. ", map hooks " .. yn(LX.mapHooked) .. ", overlay " .. (DB.mapOverlay == false and "off" or "on"))
        print("  time played: " .. (c.played and (tostring(c.played.total) .. "s recorded") or "not received yet") .. ", RequestTimePlayed " .. yn(RequestTimePlayed))
        print("  my identity: " .. selfName() .. " (key " .. myKey() .. "), whisper style " .. (DB.whisperStyle or "space"))
        print("  last error: " .. tostring(state.lastError or "none"))
    elseif cmd == "setup" then
        openSetup(1)
    elseif cmd == "minimap" then
        DB.hideMinimap = not DB.hideMinimap
        if setup.minimap then applyMinimapPosition() end
        chat("minimap button " .. (DB.hideMinimap and "hidden" or "shown") .. ".")
    elseif cmd == "account" then
        local label = cleanLabel(arg)
        if label == "" then chat("current account label: " .. DB.account) return end
        DB.account = label
        for _, c in pairs(DB.chars) do
            if c.localChar then c.account = label end
        end
        updateSelf(false)
        chat("this account is now called '" .. label .. "'.")
        refreshUI()
    elseif cmd == "link" then
        if arg == "" then chat("usage: /ledger link <First Last>") return end
        local name = titleCase(cleanName(arg))
        if not name:find(" ") then
            chat("note: Forever characters have a first and last name. Use /ledger link First Last so two characters sharing a first name aren't mixed up.")
        end
        for key, c in pairs(DB.chars) do
            if c.localChar and canon(nameOf(key)) == canon(name) then
                chat(name .. " is on this account, so no link is needed: characters on one account share their data automatically. Just play each one and log out normally. Linking is only for a character on a different account.")
                return
            end
        end
        DB.trusted[canon(name)] = name
        chat("linked " .. name .. ". Do the same on that account (link one of THIS account's characters), then /ledger sync.")
    elseif cmd == "unlink" then
        local name = titleCase(arg)
        DB.trusted[canon(name)] = nil
        chat("unlinked " .. name .. ".")
    elseif cmd == "whisperstyle" then
        local v = arg:lower()
        if v == "dash" or v == "space" then
            DB.whisperStyle = v
            chat("sync whispers will address linked characters as " .. (v == "dash" and "First-Last" or "First Last") .. ".")
        else
            chat("whisper style is '" .. (DB.whisperStyle or "space") .. "'. Use /ledger whisperstyle dash or space if syncing doesn't reach the other account. It is normally learnt automatically.")
        end
    elseif cmd == "links" then
        local any = false
        for _, display in pairs(DB.trusted) do print("  " .. display) any = true end
        if not any then chat("no linked characters.") end
    elseif cmd == "sync" then
        if syncAll() then chat("sync sent. Linked characters that are online will update.") else chat("nothing to sync with: no characters from another account are linked. (Characters on this account share data automatically.)") end
    elseif cmd == "item" then
        if not ui.frame then createUI() end
        setMode("overview")
        ui.frame:Show()
        ui.search:SetText(arg)
        refreshUI()
    elseif cmd == "export" then
        doExport()
    elseif cmd == "import" then
        showImport()
    elseif cmd == "warehouse" or cmd == "role" then
        local who, rest = arg:match("^(%S*)%s*(.-)$")
        if who == "" then
            local any = false
            for key, c in pairs(DB.chars) do
                if c.roles and #c.roles > 0 then
                    print("  " .. nameOf(key) .. roleTag(c))
                    any = true
                end
            end
            if not any then chat("no warehouse characters yet.") end
            local names = {}
            for _, k in ipairs(CATEGORY_ORDER) do names[#names + 1] = k end
            print("  usage: /ledger warehouse <Character> <roles...>  or  clear")
            print("  roles: ah (auction house alt), " .. table.concat(names, ", "))
            print("  example: /ledger warehouse Bankalt herbs ah")
            return
        end
        local tkey, target, rest2 = findLocalChar(arg)
        if tkey then
            who, rest = nameOf(tkey), rest2
        elseif target == "ambiguous" then
            chat("more than one character on this account starts with '" .. who .. "'. Use the full name, like /ledger warehouse First Last herbs.")
            return
        else
            target = nil
        end
        if not target then
            chat("'" .. who .. "' isn't a character on this account. Roles are set on the account the character lives on; they sync to your other account.")
            return
        end
        target.time = time() -- so the other account accepts the change as newer
        if rest:lower() == "clear" then
            target.roles = {}
            chat(titleCase(who) .. " has no roles now.")
        else
            local roles = parseRoles(rest)
            if #roles == 0 then chat("no valid roles in '" .. rest .. "'. Try /ledger warehouse for the list.") return end
            target.roles = roles
            chat(titleCase(who) .. " is now:" .. roleTag(target) .. ". Run /ledger sync to update your other account.")
        end
        refreshUI()
    elseif cmd == "prof" or cmd == "profs" then
        local q = arg:lower()
        local hits = {}
        for key, c in pairs(DB.chars) do
            local mine, seen = {}, {}
            for _, p in ipairs(c.profs or {}) do
                seen[profToken(p.name)] = true
                if q == "" or p.name:lower():find(q, 1, true) then
                    mine[#mine + 1] = p.name .. " " .. p.rank .. "/" .. p.max
                end
            end
            for _, t in ipairs(c.assigned or {}) do
                local label = PROF_LABEL[t] or t
                if not seen[t] and (q == "" or label:lower():find(q, 1, true)) then
                    mine[#mine + 1] = label .. " (assigned, not learned)"
                end
            end
            if #mine > 0 then
                hits[#hits + 1] = "  " .. classColor(c.class) .. nameOf(key) .. "|r |cff888888@" .. (c.account or "?") .. "|r: " .. table.concat(mine, ", ")
            end
        end
        table.sort(hits)
        if #hits == 0 then
            chat(q == "" and "no professions recorded yet. They are read a few seconds after you log in." or ("nobody has '" .. arg .. "' recorded."))
        else
            for _, h in ipairs(hits) do print(h) end
        end
    elseif cmd == "auctions" or cmd == "ah" then
        if not ui.frame then createUI() end
        setMode("auctions")
        ui.search:SetText(arg)
        ui.frame:Show()
        refreshUI()
    elseif cmd == "materials" or cmd == "mats" then
        if not ui.frame then createUI() end
        setMode("materials")
        ui.search:SetText(arg)
        ui.frame:Show()
        refreshUI()
    elseif cmd == "wealth" or cmd == "stats" then
        if not ui.frame then createUI() end
        setMode("wealth")
        ui.frame:Show()
        refreshUI()
    elseif cmd == "note" then
        local zone = currentZoneName()
        if arg == "" then chat("usage: /ledger note <text>  (adds a note, with your map position, to the zone you are standing in)") return end
        if zone == "" then chat("couldn't read your current zone.") return end
        local ok, why = addZoneNote(zone, arg, true)
        if ok then
            chat("note added to " .. zone .. ". Open the Map tab to rate the zone.")
            refreshUI()
        else
            chat(why == "full" and (zone .. " already has " .. MAX_NOTES .. " notes. Delete one on the Map tab first.") or "nothing to add.")
        end
    elseif cmd == "mapoverlay" then
        DB.mapOverlay = (DB.mapOverlay == false)
        chat("world map overlay " .. (DB.mapOverlay == false and "off" or "on") .. ".")
        refreshUI()
    elseif cmd == "map" then
        if not ui.frame then createUI() end
        local zone = currentZoneName()
        if zone ~= "" and (BUILTIN_ZONE[zone] or (DB.zones and DB.zones[zone])) then ui.mapSel = zone end
        setMode("map")
        ui.frame:Show()
        refreshUI()
    elseif cmd == "todo" then
        if arg ~= "" then
            local who, rest = arg:match("^(%a+%s?%a*):%s*(.+)$")
            local target = ""
            if who then
                for key in pairs(DB.chars) do
                    if canon(nameOf(key)) == canon(who) or (not who:find(" ") and sameChar(who, key) and target == "") then target = nameOf(key) end
                end
                if target == "" then rest = arg end
            else
                rest = arg
            end
            local ok, why = addTodo(rest, target)
            chat(ok and ("added to your to-do list" .. (target ~= "" and (" for " .. target) or "") .. ".") or (why == "full" and "the to-do list is full." or "nothing to add."))
        end
        if not ui.frame then createUI() end
        setMode("todo")
        ui.frame:Show()
        refreshUI()
    elseif cmd == "tx" or cmd == "transactions" or cmd == "ledger" then
        if not ui.frame then createUI() end
        setMode("ledger")
        ui.search:SetText(arg)
        ui.frame:Show()
        refreshUI()
    elseif cmd == "played" or cmd == "playtime" then
        if not ui.frame then createUI() end
        setMode("play")
        ui.frame:Show()
        refreshUI()
    elseif cmd == "move" then
        if not ui.frame then createUI() end
        setMode("move")
        ui.search:SetText("")
        ui.frame:Show()
        refreshUI()
    elseif cmd == "forget" then
        local n = 0
        for key, c in pairs(DB.chars) do
            if not c.localChar and sameChar(arg, key) then DB.chars[key] = nil n = n + 1 end
        end
        chat("removed " .. n .. " character(s).")
        refreshUI()
    else
        help()
    end
end

------------------------------------------------------------------------
-- events
------------------------------------------------------------------------
local frame = CreateFrame("Frame")
local bagTimerPending = false

local function scheduleScan()
    if bagTimerPending then return end
    bagTimerPending = true
    C_Timer.After(0.6, function()
        bagTimerPending = false
        updateSelf(true)
        refreshUI()
    end)
end

local handlers = {}

function handlers.ADDON_LOADED(name)
    if name == "Blizzard_WorldMap" and DB then LX.initMap() end
    if name ~= ADDON then return end
    -- this add-on was called Account Ledger before: if its saved data was copied across
    -- (ForeverLedger.lua in SavedVariables, still holding AccountLedgerDB), carry it over
    if (not ForeverLedgerDB or not next(ForeverLedgerDB)) and type(AccountLedgerDB) == "table" and next(AccountLedgerDB) then
        ForeverLedgerDB = AccountLedgerDB
        AccountLedgerDB = nil
    end
    ForeverLedgerDB = ForeverLedgerDB or {}
    DB = ForeverLedgerDB
    DB.chars = DB.chars or {}
    DB.trusted = DB.trusted or {}
    DB.itemNames = DB.itemNames or {}
    DB.account = DB.account or "Account 1"
    frame:UnregisterEvent("ADDON_LOADED")
end

function handlers.PLAYER_LOGIN()
    local reg = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix
    if reg then reg(PREFIX) end
    -- characters saved by an older version are filed under their first name only: move the one we are
    -- now logged in on to its full-name key (class must match, as first names can repeat)
    do
        local last = selfLast()
        local old = UnitName("player") .. "-" .. GetRealmName()
        local oc = DB.chars[old]
        if last and oc and oc.localChar and not DB.chars[myKey()] and (oc.class == nil or oc.class == select(2, UnitClass("player"))) then
            DB.chars[myKey()] = oc
            DB.chars[old] = nil
        end
    end
    updateSelf(true)
    -- drop links to characters that live on this account (an earlier version let you add them)
    for lower in pairs(DB.trusted) do
        for key, c in pairs(DB.chars) do
            if c.localChar and canon(nameOf(key)) == lower then DB.trusted[lower] = nil end
        end
    end
    hookTooltips()
    purgeTodos()
    LX.initMap()
    C_Timer.After(5, function() LX.initMap() end)
    LX.install()
    if ChatFrame_AddMessageEventFilter then
        ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", systemFilter)
    end
    createMinimapButton()
    if DB.setupDone == nil then
        -- first run on this account: walk the person through setup once.
        -- Accounts that were already configured under an older version are not nagged.
        DB.setupDone = true
        if DB.account == "Account 1" then
            C_Timer.After(4, function() openSetup(1) end)
        end
    end
    C_Timer.After(15, function()
        if next(DB.trusted) then syncAll() end
    end)
end

function handlers.PLAYER_ENTERING_WORLD()
    -- gold and bags are reliable from here on; take a clean snapshot shortly after
    state.entered = true
    C_Timer.After(2, function()
        updateSelf(true)
        state.prevMoney = GetMoney() or 0 -- from here on, gold changes can be matched to what caused them
        refreshUI()
    end)
    C_Timer.After(6, function() if not state.playedRequested then state.playedRequested = true LX.requestPlayed() end end)
    C_Timer.After(5, function()
        if scanProfessions() then refreshUI() end
    end)
end

local profTimerPending = false
function handlers.SKILL_LINES_CHANGED()
    -- expanding/collapsing headers also fires this event, so ignore the echo of our own scan
    if profTimerPending or not state.entered then return end
    if state.skillScanAt and GetTime() - state.skillScanAt < 3 then return end
    profTimerPending = true
    C_Timer.After(1.5, function()
        profTimerPending = false
        if scanProfessions() then refreshUI() end
    end)
end

function handlers.BAG_UPDATE() scheduleScan() end
function handlers.PLAYERBANKSLOTS_CHANGED() if state.bankOpen then scheduleScan() end end
function handlers.BANKFRAME_OPENED() state.bankOpen = true scheduleScan() end
function handlers.BANKFRAME_CLOSED() state.bankOpen = false end
-- Active auctions for this character: count plus a list of {id, qty, buyout}. Forever only has the
-- newer C_AuctionHouse API; older clients have the legacy functions. We never ask the server to refresh
-- (that call is restricted), we just read the data whenever the game reports it has updated.
local function ahIsOpen()
    -- prefer the real window state: the game fires update events while the window is closing
    local f = AuctionHouseFrame or AuctionFrame
    if f and f.IsShown then return f:IsShown() and true or false end
    if state.ahOpen then return true end
    if AuctionHouseFrame and AuctionHouseFrame.IsShown and AuctionHouseFrame:IsShown() then return true end
    if AuctionFrame and AuctionFrame.IsShown and AuctionFrame:IsShown() then return true end
    return false
end

local function scanAuctions()
    if not DB then return end
    -- The game clears its list of your auctions when the window closes, so only read while it is open.
    if not ahIsOpen() then return end
    local n, value, list = nil, 0, {}
    local ah = C_AuctionHouse
    if ah and ah.GetNumOwnedAuctions and ah.GetOwnedAuctionInfo then
        local ok, num = pcall(ah.GetNumOwnedAuctions)
        if not ok or type(num) ~= "number" then return end
        n = 0
        for i = 1, num do
            pcall(function()
                local info = ah.GetOwnedAuctionInfo(i)
                if type(info) == "table" and info.status == 0 then -- 0 = active, 1 = sold
                    n = n + 1
                    local buyout = tonumber(info.buyoutAmount) or 0
                    value = value + buyout
                    local id = info.itemKey and tonumber(info.itemKey.itemID)
                    if not id and type(info.itemLink) == "string" then id = tonumber(info.itemLink:match("item:(%d+)")) end
                    if id and #list < 60 then
                        list[#list + 1] = { id = id, qty = tonumber(info.quantity) or 1, buyout = buyout }
                        -- remember the name from the link so we can show and sync it
                        if DB.itemNames and not DB.itemNames[id] and type(info.itemLink) == "string" then
                            local nm = info.itemLink:match("%[(.-)%]")
                            if nm then DB.itemNames[id] = nm:sub(1, 60) end
                        end
                    end
                end
            end)
        end
    elseif GetNumAuctionItems then
        local ok, num = pcall(GetNumAuctionItems, "owner")
        if not ok or not num then return end
        n = num
        for i = 1, num do
            pcall(function()
                local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemId = GetAuctionItemInfo("owner", i)
                buyout = tonumber(buyout) or 0
                value = value + buyout
                if tonumber(itemId) and #list < 60 then
                    list[#list + 1] = { id = tonumber(itemId), qty = tonumber(count) or 1, buyout = buyout }
                end
            end)
        end
    else
        return
    end
    -- An empty list right after opening is usually "not loaded yet", not "you have nothing listed".
    -- Only believe zero once the game has told us it loaded your auctions this visit.
    if n == 0 and not state.ownedLoaded then return end
    state.auctionScans = (state.auctionScans or 0) + 1
    state.auctionLast = n
    local c = DB.chars[myKey()]
    if c then
        c.auctions = { n = n, value = value }
        c.auctionList = list
        c.time = time()
        refreshUI()
    end
end

function handlers.AUCTION_HOUSE_SHOW()
    state.ahOpen = true
    state.ownedLoaded = false
    if GetOwnerAuctionItems then pcall(GetOwnerAuctionItems) end
    C_Timer.After(2, function() scanAuctions() end) -- reads whatever the game has loaded for your auctions so far
end
function handlers.AUCTION_HOUSE_CLOSED()
    -- keep what we saved: the game empties its own list now, so reading it would wipe our copy
    state.ahOpen = false
    state.ownedLoaded = false
end
function handlers.AUCTION_HOUSE_AUCTION_CREATED() C_Timer.After(1, function() scanAuctions() end) end
function handlers.AUCTION_CANCELED() C_Timer.After(1, function() scanAuctions() end) end
function handlers.AUCTION_OWNED_LIST_UPDATE() state.ownedLoaded = ahIsOpen() scanAuctions() end
function handlers.OWNED_AUCTIONS_UPDATED() state.ownedLoaded = ahIsOpen() scanAuctions() end
------------------------------------------------------------------------
-- transaction ledger: vendors, other players (trades and mail) and the auction house
-- Everything here is wrapped so that a problem in one place can never break the rest of the add-on.
------------------------------------------------------------------------
do
local function safe(tag, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then state.lastError = tag .. ": " .. tostring(err) end
    return ok
end

local function linkName(link)
    return type(link) == "string" and link:match("%[(.-)%]") or nil
end

local function idName(id)
    if not id then return nil end
    local nm = itemName(id)
    if nm then return nm end
    if C_Item and C_Item.GetItemNameByID then
        local ok, n = pcall(C_Item.GetItemNameByID, id)
        if ok and n then return n end
    end
    return "item " .. tostring(id)
end

local function stackText(name, count)
    if (count or 1) > 1 then return name .. " x" .. count end
    return name
end

local function listCounts(map)
    local ids = {}
    for id in pairs(map) do ids[#ids + 1] = id end
    table.sort(ids)
    local parts = {}
    for i, id in ipairs(ids) do
        if i > 3 then parts[#parts + 1] = "+" .. (#ids - 3) .. " more" break end
        parts[#parts + 1] = stackText(idName(id), map[id])
    end
    return table.concat(parts, ", ")
end

local function bagCounts()
    local ok, t = pcall(function() return scanBags(bagIDs()) end)
    return ok and t or nil
end

local function bagDiff(before, after)
    local lost, gained = {}, {}
    for id, n in pairs(before or {}) do
        local a = (after or {})[id] or 0
        if a < n then lost[id] = n - a end
    end
    for id, n in pairs(after or {}) do
        local b = (before or {})[id] or 0
        if n > b then gained[id] = n - b end
    end
    return lost, gained
end

local tx = { vendor = { delta = 0 }, ah = {}, hooks = {} }

-- vendors -------------------------------------------------------------
local function flushVendor()
    local vb = tx.vendor
    vb.pending = false
    local delta = vb.delta
    vb.delta = 0
    local after = bagCounts()
    local lost, gained = bagDiff(vb.snap, after)
    vb.snap = after or vb.snap
    if delta == 0 then return end
    local desc
    if delta > 0 then
        desc = next(lost) and ("sold " .. listCounts(lost)) or "vendor income"
    elseif next(gained) then
        desc = "bought " .. listCounts(gained)
    elseif vb.hint then
        desc = "bought " .. vb.hint
    elseif vb.repair and GetTime() - vb.repair < 15 then
        desc = "repairs"
    else
        desc = "vendor spending"
    end
    vb.hint = nil
    addEntry("v", desc, delta)
end

-- mail ---------------------------------------------------------------
local function subjectIs(subject, globalName, fallback)
    local fmt = _G[globalName] or fallback
    if not fmt or type(subject) ~= "string" then return false end
    local pat = "^" .. fmt:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"):gsub("%%%%s", ".+")
    return subject:find(pat) ~= nil
end

local mailCache = {}
local function cacheInbox()
    mailCache = {}
    if not GetInboxNumItems or not GetInboxHeaderInfo then return end
    local n = GetInboxNumItems() or 0
    for i = 1, math.min(n, 50) do
        local ok, _, _, sender, subject, money, cod = pcall(GetInboxHeaderInfo, i)
        if ok then
            local m = { sender = cleanText(sender or "unknown", 24), subject = subject or "", money = money or 0, cod = cod or 0, items = {} }
            if GetInboxItem then
                for j = 1, 16 do
                    local ok2, nm, _, _, cnt = pcall(GetInboxItem, i, j)
                    if ok2 and nm and nm ~= "" then m.items[#m.items + 1] = stackText(nm, cnt) end
                end
            end
            if GetInboxInvoiceInfo then
                local ok3, kind, item, who, bid, buyout, deposit, fee, _, _, _, count = pcall(GetInboxInvoiceInfo, i)
                if ok3 and kind then m.inv = { kind = kind, item = item, who = who, bid = bid or 0, fee = fee or 0, count = count or 1 } end
            end
            mailCache[i] = m
        end
    end
end

local function recordMailTake(index, takeMoney, takeItems)
    local m = mailCache[index]
    if not m then return end
    local itemsTxt = table.concat(m.items, ", ")
    if takeMoney and m.money > 0 and not m.tookMoney then
        m.tookMoney = true
        if m.inv and m.inv.kind == "seller" then
            addEntry("a", string.format("sold %s to %s (fee %s)", stackText(m.inv.item or "item", m.inv.count),
                cleanText(m.inv.who or "a buyer", 24), plainMoney(m.inv.fee)), m.money)
        elseif subjectIs(m.subject, "AUCTION_OUTBID_MAIL_SUBJECT", "Outbid on %s")
            or subjectIs(m.subject, "AUCTION_REMOVED_MAIL_SUBJECT", "Auction cancelled: %s") then
            addEntry("a", "refund - " .. cleanText(m.subject, 40), m.money)
        else
            addEntry("p", "mail from " .. m.sender .. (m.subject ~= "" and (" - " .. cleanText(m.subject, 30)) or ""), m.money)
        end
    end
    if takeItems and #m.items > 0 and not m.tookItems then
        m.tookItems = true
        if subjectIs(m.subject, "AUCTION_WON_MAIL_SUBJECT", "Auction won: %s") then
            addEntry("a", "collected won auction - " .. itemsTxt, 0)
        elseif m.cod > 0 then
            addEntry("p", "COD from " .. m.sender .. " - " .. itemsTxt, -m.cod)
        elseif not (m.inv or subjectIs(m.subject, "AUCTION_EXPIRED_MAIL_SUBJECT", "Auction expired: %s")) then
            addEntry("p", "received from " .. m.sender .. " - " .. itemsTxt, 0)
        end
    end
end

-- trades --------------------------------------------------------------
local function tradePartner()
    local n = UnitName and UnitName("NPC")
    if n and n ~= "" then return n end
    return "someone"
end

local function snapTrade()
    local t = state.trade or { who = tradePartner() }
    state.trade = t
    t.give, t.get = {}, {}
    for i = 1, 6 do
        if GetTradePlayerItemInfo then
            local ok, nm, _, cnt = pcall(GetTradePlayerItemInfo, i)
            if ok and nm and nm ~= "" then t.give[#t.give + 1] = stackText(nm, cnt) end
        end
        if GetTradeTargetItemInfo then
            local ok, nm, _, cnt = pcall(GetTradeTargetItemInfo, i)
            if ok and nm and nm ~= "" then t.get[#t.get + 1] = stackText(nm, cnt) end
        end
    end
    t.giveMoney = (GetPlayerTradeMoney and GetPlayerTradeMoney()) or 0
    t.getMoney = (GetTargetTradeMoney and GetTargetTradeMoney()) or 0
end

local function commitTrade()
    local t = state.trade
    state.trade = nil
    if not t then return end
    local parts = {}
    if #t.give > 0 then parts[#parts + 1] = "gave " .. table.concat(t.give, ", ") end
    if #t.get > 0 then parts[#parts + 1] = "got " .. table.concat(t.get, ", ") end
    local net = (t.getMoney or 0) - (t.giveMoney or 0)
    if #parts == 0 and net == 0 then return end
    addEntry("p", "trade with " .. cleanText(t.who, 24) .. " - " .. table.concat(parts, " / "), net)
end

-- money changes ---------------------------------------------------------
local function ledgerMoneyChanged()
    local m = GetMoney() or 0
    local prev = state.prevMoney
    state.prevMoney = m
    if not state.entered or prev == nil then return end
    local delta = m - prev
    if delta == 0 then return end
    if state.tradeOpen or (state.ignoreMoneyUntil or 0) > GetTime() then return end
    if state.merchantOpen then
        local vb = tx.vendor
        vb.delta = vb.delta + delta
        if not vb.pending then
            vb.pending = true
            C_Timer.After(1.2, function() safe("vendor", flushVendor) end)
        end
        return
    end
    if state.mailOpen then
        -- with the mail hooks working, mail entries are written when you take the money or items
        if not tx.hooks.mail and delta > 0 then addEntry("p", "mail: collected gold", delta) end
        return
    end
    if delta > 0 then
        local now = GetTime()
        if tx.questAt and now - tx.questAt < 5 then
            local title = tx.questTitle and tx.questTitle ~= "" and tx.questTitle or "quest"
            tx.questAt, tx.questTitle = nil, nil
            addEntry("q", "quest reward - " .. title, delta)
            return
        end
        if tx.lootAt and now - tx.lootAt < 4 then
            addEntry("l", "looted gold", delta, function(n) return n == 1 and "looted gold" or ("looted gold (" .. n .. " drops)") end)
            return
        end
    end
    if delta < 0 and ahIsOpen() then
        local ah = tx.ah
        local desc
        if ah.postAt and GetTime() - ah.postAt < 6 then
            desc = "posted an auction (deposit)"
        elseif ah.hint and GetTime() - (ah.hintAt or 0) < 10 then
            desc = "bought " .. ah.hint
        else
            desc = "auction house purchase"
        end
        ah.hint = nil
        addEntry("a", desc, delta)
    end
end

-- hooks (installed once at login; each one is optional) ----------------------
local function installLedgerHooks()
    if tx.installed then return end
    tx.installed = true
    local function hook(target, name, fn)
        if type(target) == "table" and type(target[name]) == "function" and hooksecurefunc then
            return pcall(hooksecurefunc, target, name, function(...) safe("hook " .. name, fn, ...) end)
        end
        return false
    end
    local ok1 = hook(_G, "BuyMerchantItem", function(index, qty)
        local name
        if GetMerchantItemInfo then name = GetMerchantItemInfo(index) end
        if not name and C_MerchantFrame and C_MerchantFrame.GetItemInfo then
            local info = C_MerchantFrame.GetItemInfo(index)
            name = type(info) == "table" and info.name or nil
        end
        if name then tx.vendor.hint = stackText(name, qty) end
    end)
    local ok2 = hook(_G, "RepairAllItems", function() tx.vendor.repair = GetTime() end)
    tx.hooks.merchant = (ok1 or ok2) and true or false

    local m1 = hook(_G, "TakeInboxMoney", function(i) recordMailTake(i, true, false) end)
    local m2 = hook(_G, "TakeInboxItem", function(i) recordMailTake(i, false, true) end)
    local m3 = hook(_G, "AutoLootMailItem", function(i) recordMailTake(i, true, true) end)
    local m4 = hook(_G, "SendMail", function(to)
        local items = {}
        for i = 1, 12 do
            if GetSendMailItem then
                local ok, nm, _, _, cnt = pcall(GetSendMailItem, i)
                if ok and nm and nm ~= "" then items[#items + 1] = stackText(nm, cnt) end
            end
        end
        state.mailOut = { to = cleanText(to or "?", 24), items = items,
            money = (GetSendMailMoney and GetSendMailMoney()) or 0, cod = (GetSendMailCOD and GetSendMailCOD()) or 0, at = GetTime() }
    end)
    tx.hooks.mail = (m1 and m2 and m3) and true or false
    tx.hooks.send = m4 and true or false

    local ah = tx.ah
    local a1 = hook(C_AuctionHouse, "ConfirmCommoditiesPurchase", function(itemID, qty)
        ah.hint, ah.hintAt = stackText(idName(itemID) or "item", qty), GetTime()
    end)
    local a2 = hook(C_AuctionHouse, "PlaceBid", function()
        ah.hint, ah.hintAt = "an item (bid or buyout)", GetTime()
    end)
    local a3 = hook(C_AuctionHouse, "PostItem", function() ah.postAt = GetTime() end)
    local a4 = hook(C_AuctionHouse, "PostCommodity", function() ah.postAt = GetTime() end)
    tx.hooks.ah = (a1 or a2 or a3 or a4) and true or false

    -- handing in a quest: remember it before the money arrives
    local q1 = hook(_G, "GetQuestReward", function()
        local rm = GetRewardMoney and GetRewardMoney()
        if rm == nil or rm > 0 then tx.questAt = GetTime() end -- quests with no gold must not claim the next loot
    end)
    local q2 = false
    if C_QuestLog and C_QuestLog.GetQuestInfo then q2 = true end
    tx.hooks.quest = (q1 or q2) and true or false
end

function handlers.QUEST_COMPLETE()
    local t = GetTitleText and GetTitleText()
    tx.questTitle = cleanText(t or "", 40)
end
function handlers.QUEST_TURNED_IN(questID, _, money)
    if type(money) == "number" then
        tx.questAt = money > 0 and GetTime() or nil
    else
        tx.questAt = tx.questAt or GetTime()
    end
    if (not tx.questTitle or tx.questTitle == "") and C_QuestLog and C_QuestLog.GetQuestInfo and questID then
        local ok, t = pcall(C_QuestLog.GetQuestInfo, questID)
        if ok and type(t) == "string" then tx.questTitle = cleanText(t, 40) end
    end
end
local function lootSeen() tx.lootAt = GetTime() end
handlers.LOOT_OPENED = lootSeen
handlers.LOOT_READY = lootSeen
handlers.LOOT_CLOSED = lootSeen
handlers.CHAT_MSG_MONEY = lootSeen

-- time played ------------------------------------------------------------
local function restoreTimePlayedChat()
    if state.chatMuted then
        local cf = DEFAULT_CHAT_FRAME
        if cf and cf.RegisterEvent then pcall(cf.RegisterEvent, cf, "TIME_PLAYED_MSG") end
        state.chatMuted = false
    end
end

local function requestPlayed()
    if not RequestTimePlayed then return end
    state.playedAsked = GetTime()
    local cf = DEFAULT_CHAT_FRAME
    if cf and cf.UnregisterEvent then
        pcall(cf.UnregisterEvent, cf, "TIME_PLAYED_MSG") -- keep the game from printing it into chat
        state.chatMuted = true
    end
    pcall(RequestTimePlayed)
    C_Timer.After(6, restoreTimePlayedChat)
end

function handlers.PLAYER_MONEY()
    updateSelf(false, true)
    safe("money", ledgerMoneyChanged)
    refreshUI()
end

function handlers.MERCHANT_SHOW()
    state.merchantOpen = true
    tx.vendor.snap = bagCounts()
    tx.vendor.delta = 0
end
function handlers.MERCHANT_CLOSED()
    state.merchantOpen = false
    if tx.vendor.delta ~= 0 then safe("vendor", flushVendor) end
end

function handlers.MAIL_SHOW() state.mailOpen = true safe("mail", cacheInbox) end
function handlers.MAIL_INBOX_UPDATE() if state.mailOpen then safe("mail", cacheInbox) end end
function handlers.MAIL_CLOSED() state.mailOpen = false end
function handlers.MAIL_SEND_SUCCESS()
    local o = state.mailOut
    state.mailOut = nil
    if not o or GetTime() - o.at > 20 then return end
    if #o.items == 0 and (o.money or 0) == 0 then return end
    local what = #o.items > 0 and table.concat(o.items, ", ") or "gold"
    local cod = (o.cod or 0) > 0 and (" (COD " .. plainMoney(o.cod) .. ")") or ""
    safe("mail", addEntry, "p", "mailed " .. what .. " to " .. o.to .. cod, -(o.money or 0))
end
function handlers.MAIL_FAILED() state.mailOut = nil end

function handlers.TRADE_SHOW() state.tradeOpen = true state.tradeResult = nil state.trade = { who = tradePartner() } end
local function tradeChanged() if state.tradeOpen then safe("trade", snapTrade) end end
function handlers.TRADE_PLAYER_ITEM_CHANGED() tradeChanged() end
function handlers.TRADE_TARGET_ITEM_CHANGED() tradeChanged() end
function handlers.TRADE_MONEY_CHANGED() tradeChanged() end
function handlers.TRADE_ACCEPT_UPDATE(player, target)
    if not state.tradeOpen then return end
    safe("trade", snapTrade)
    if state.trade then state.trade.both = (player == 1 and target == 1) or state.trade.both end
end
function handlers.TRADE_CLOSED()
    if not state.tradeOpen then return end
    state.tradeOpen = false
    state.ignoreMoneyUntil = GetTime() + 3
    C_Timer.After(0.6, function()
        local t = state.trade
        if t and (state.tradeResult == "complete" or (state.tradeResult == nil and t.both)) then
            safe("trade", commitTrade)
        end
        state.trade = nil
    end)
end
local function tradeMessage(msg)
    if not msg then return end
    if ERR_TRADE_COMPLETE and msg == ERR_TRADE_COMPLETE then state.tradeResult = "complete" end
    if ERR_TRADE_CANCELLED and msg == ERR_TRADE_CANCELLED then state.tradeResult = "cancelled" end
end
function handlers.UI_INFO_MESSAGE(_, msg) tradeMessage(msg) end
function handlers.CHAT_MSG_SYSTEM(msg) tradeMessage(msg) end

function handlers.TIME_PLAYED_MSG(total, level)
    local c = DB and DB.chars[myKey()]
    if c and type(total) == "number" then
        c.played = { total = math.floor(total), level = math.floor(level or 0), at = time() }
        c.time = time()
        changed()
    end
    restoreTimePlayedChat()
end

LX.safe, LX.install, LX.requestPlayed, LX.hooks = safe, installLedgerHooks, requestPlayed, tx.hooks
end -- ledger capture

function handlers.PLAYER_LEVEL_UP() updateSelf(false) end
-- (nothing is read at logout: game data is not reliable at that moment, and everything
-- is already kept up to date by events while you play)
function handlers.GET_ITEM_INFO_RECEIVED()
    if ui.frame and ui.frame:IsShown() and (ui.search:GetText() ~= "" or ui.mode == "materials") then refreshUI() end
end

function handlers.CHAT_MSG_ADDON(prefix, msg, channel, sender)
    if prefix ~= PREFIX or channel ~= "WHISPER" or not DB then return end
    local who = trustedKey(normName(sender))
    if not who then return end
    local mode, line = msg:match("^(%a)%^(.*)$")
    if not mode then return end
    state.lastSender[who] = sender
    if canon(sender):find(" ") then DB.whisperStyle = sender:find(" ") and "space" or "dash" end
    local res = handleLine(line, who)
    if mode == "D" and line:sub(1, 2) == "C^" then
        local now = GetTime()
        if (state.lastReply[who] or -999) + 120 < now then
            state.lastReply[who] = now
            syncTo(sender, "R")
        end
    end
    if res then refreshUI() end
end

frame:SetScript("OnEvent", function(_, event, ...)
    local h = handlers[event]
    if h then h(...) end
end)

for event in pairs(handlers) do
    pcall(frame.RegisterEvent, frame, event)
end
