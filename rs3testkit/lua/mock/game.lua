-- Game state: coordinates, configs, the player, entities, inventories, the
-- Grand Exchange, the world and the MiniMenu.
--
-- Nothing here invents game data. Configs (config.NPC.FromID(81)) exist only
-- when a spec defines them, and reading a config property the spec did not
-- set raises an error naming the fixture to add. The kit computes only what
-- the docs define exactly: coordinate maths, XP <-> level, list searches.
--
-- Fixtures (kit.*):
--   kit.config.npc(11240, { name = "Goblin", gridSize = 1 })
--   kit.player.set{ levels = { MINING = 50 }, runEnergy = 80, coord = { x = 3222, z = 3218 } }
--   kit.player.gainXP("MINING", 35)          fires Event.SkillTransmit
--   kit.world.addNpc{ id = 11240, coord = { x = 3246, z = 3272 } }
--   kit.inventory.set(93, { { 995, 1000 }, { 1511, 1 } })   backpack: coins, logs
--   kit.ge.setOffer(1, { type = "BUY", item = 536, price = 2000, itemCount = 100 })
--   kit.menu.open{ kit.menu.npcEntry{ npc = goblin, verb = "Examine" } }

local Core = require("core")
local Docs = require("docs")
local Events = require("events")
local Ids = require("ids")
local Perms = require("perms")
local Sandbox = require("sandbox")
local Vector = require("vector")

local M = {}

local enums                 -- global enums (SkillType, ...), from Ids.enums()

local function enumValue(enum, v, what)
    if type(v) == "string" then return enum[v] end
    if type(v) == "number" then return v end
    error("rs3testkit: " .. what .. " must be an enum value or its name, got " .. type(v), 3)
end

---------------------------------------------------------------------------
-- Coordinates (exact maths from the docs)
---------------------------------------------------------------------------
-- A grid tile is 512 fine units; a map square is 64 x 64 tiles.
local function coordGrid(level, x, z)
    return Core.new("CoordGrid", { level = level, x = x, z = z,
        mapSquareX = x // 64, mapSquareZ = z // 64, localX = x % 64, localZ = z % 64 })
end

local function coordFine(level, x, y, z)
    local gx, gz = math.floor(x / 512), math.floor(z / 512)
    return Core.new("CoordFine", { level = level, x = x, y = y, z = z, position = Vector.v3(x, y, z),
        mapSquareX = gx // 64, mapSquareZ = gz // 64, localX = gx % 64, localZ = gz % 64 })
end

local function defineCoords()
    local CoordGrid = Docs.class("CoordGrid", {
        native = "jag::game::CoordGrid",
        -- Live client: tostring gives "level,mapSquareX,mapSquareZ,localX,localZ".
        tostring = function(c)
            return string.format("%d,%d,%d,%d,%d", Core.getRaw(c, "level"), Core.getRaw(c, "mapSquareX"),
                Core.getRaw(c, "mapSquareZ"), Core.getRaw(c, "localX"), Core.getRaw(c, "localZ"))
        end,
        impls = {
            ToPacked = function(self)
                return (Core.getRaw(self, "level") << 28) | (Core.getRaw(self, "x") << 14) | Core.getRaw(self, "z")
            end,
            ToCoordFine = function(self, fromCentre)
                local off = fromCentre and 256 or 0
                return coordFine(Core.getRaw(self, "level"), Core.getRaw(self, "x") * 512 + off, 0,
                    Core.getRaw(self, "z") * 512 + off)
            end,
        },
        statics = {
            new = function(a, b, c, d, e)
                if Core.isA(a, "CoordGrid") then
                    return coordGrid(Core.getRaw(a, "level"), Core.getRaw(a, "x"), Core.getRaw(a, "z"))
                elseif Core.isA(a, "CoordFine") then
                    return coordGrid(Core.getRaw(a, "level"), math.floor(Core.getRaw(a, "x") / 512), math.floor(Core.getRaw(a, "z") / 512))
                elseif b == nil then
                    return coordGrid((a >> 28) & 0x3, (a >> 14) & 0x3FFF, a & 0x3FFF)
                elseif Core.isA(b, "Vector3") then
                    return coordGrid(a, math.floor(Core.getRaw(b, "x") / 512), math.floor(Core.getRaw(b, "z") / 512))
                elseif d == nil then
                    return coordGrid(a, b * 64 + 32, c * 64 + 32)   -- centre of the map square
                else
                    return coordGrid(a, b * 64 + d, c * 64 + e)
                end
            end,
            FromCoordFine = function(f)
                return coordGrid(Core.getRaw(f, "level"), math.floor(Core.getRaw(f, "x") / 512), math.floor(Core.getRaw(f, "z") / 512))
            end,
        },
    })
    local CoordFine = Docs.class("CoordFine", {
        native = "jag::game::CoordFine",
        impls = {
            ToCoordGrid = function(self)
                return coordGrid(Core.getRaw(self, "level"), math.floor(Core.getRaw(self, "x") / 512), math.floor(Core.getRaw(self, "z") / 512))
            end,
        },
        statics = {
            new = function(a, b, c, d)
                if Core.isA(a, "CoordGrid") then
                    local off = b and 256 or 0
                    return coordFine(Core.getRaw(a, "level"), Core.getRaw(a, "x") * 512 + off, 0, Core.getRaw(a, "z") * 512 + off)
                elseif Core.isA(a, "CoordFine") then
                    return coordFine(Core.getRaw(a, "level"), Core.getRaw(a, "x"), Core.getRaw(a, "y"), Core.getRaw(a, "z"))
                elseif Core.isA(b, "Vector3") then
                    return coordFine(a, Core.getRaw(b, "x"), Core.getRaw(b, "y"), Core.getRaw(b, "z"))
                elseif d == nil then
                    return coordFine(a, b, 0, c)
                else
                    return coordFine(a, b, c, d)
                end
            end,
            FromCoordGrid = function(g, fromCentre)
                local off = fromCentre and 256 or 0
                return coordFine(Core.getRaw(g, "level"), Core.getRaw(g, "x") * 512 + off, 0, Core.getRaw(g, "z") * 512 + off)
            end,
        },
    })
    return CoordGrid, CoordFine
end

-- { x =, z =, level = } -> CoordGrid
local function toCoord(t, what)
    if t == nil then return nil end
    if Core.isA(t, "CoordGrid") then return t end
    if type(t) ~= "table" or type(t.x) ~= "number" or type(t.z) ~= "number" then
        error("rs3testkit: " .. what .. " needs a coord like { x = 3222, z = 3218, level = 0 }", 3)
    end
    return coordGrid(t.level or 0, t.x, t.z)
end

local function distance(a, b)
    return math.max(math.abs(Core.getRaw(a, "x") - Core.getRaw(b, "x")), math.abs(Core.getRaw(a, "z") - Core.getRaw(b, "z")))
end

---------------------------------------------------------------------------
-- Configs
---------------------------------------------------------------------------
local CONFIG_TYPES = {
    NPC = "NPCType", Obj = "ObjType", Loc = "LocType", Inv = "InvType", Seq = "SeqType", Cursor = "CursorType",
    Struct = "StructType", Enum = "EnumType", DBRow = "DBRowType", DBTable = "DBTableType", Param = "ParamType",
    Quest = "QuestType", Var = "VarType", Achievement = "AchievementType", BaseAnimSet = "BaseAnimSetType",
    Font = "FontType", Headbar = "HeadbarType", Hitmark = "HitmarkType", SpotAnim = "SpotAnimType",
    MapElement = "MapElementType",
}
local configs = {}            -- kind -> { byId = {}, byName = {} }
local configMissingIsNil = false

local function defineConfig(kind, id, fields)
    if math.type(id) ~= "integer" then error("kit.config: id must be an integer", 3) end
    local cls = CONFIG_TYPES[kind]
    local init = { id = id, typeName = kind }
    for k, v in pairs(fields or {}) do
        if not (Docs.data.types[cls] and Docs.data.types[cls].props[k]) then
            error("rs3testkit: kit.config." .. kind .. ": '" .. tostring(k) .. "' is not a documented " .. cls .. " property", 3)
        end
        init[k] = v
    end
    local c = Core.new(cls, init)
    configs[kind].byId[id] = c
    if init.configName then configs[kind].byName[init.configName] = c end
    return c
end

-- Fonts are known by name from id.Font, so config.Font.FromID(n) and
-- config.Font.NAME exist for every font in the id table (id and configName
-- only; metrics stay unset unless a spec gives them).
local function autoFont(id)
    local ok, name = pcall(function() return Sandbox.api.id.Font[id] end)
    if ok and type(name) == "string" then return defineConfig("Font", id, { configName = name }) end
end

local fontMeasure = nil     -- kit.fonts.measureWith(fn)

local function getConfig(kind, id, level)
    local c = configs[kind].byId[id]
    if c == nil and kind == "Font" and id ~= nil then c = autoFont(id) end
    if c == nil and id ~= nil then
        if configMissingIsNil then return nil end
        error("rs3testkit: config." .. kind .. ".FromID(" .. tostring(id) .. "): the spec defined no such config. " ..
            "Add it with kit.config.define(\"" .. kind .. "\", " .. tostring(id) .. ", { name = ... }) " ..
            "(or kit.config.missingIsNil(true) to get nil as an unknown id may give in the client)", level or 3)
    end
    return c
end

local function defineConfigs()
    for kind, cls in pairs(CONFIG_TYPES) do
        configs[kind] = { byId = {}, byName = {} }
        local impls = nil
        if kind == "Font" then
            impls = {
                -- Text width needs the game's font metrics, which the kit does
                -- not have; a spec supplies the measuring rule it wants.
                GetStringWidth = function(self, text)
                    if not fontMeasure then
                        Core.missing("FontType:GetStringWidth", true,
                            "Give the kit a rule in your spec: kit.fonts.measureWith(function(font, text) return #text * 7 end).")
                    end
                    return math.floor(fontMeasure(self, text))
                end,
            }
        end
        Docs.class(cls, {
            impls = impls,
            strict = true,
            missingHint = "(Configs are game data; give it in the fixture: kit.config.define(\"" .. kind .. "\", id, { ... }).)",
            -- Live client: tostring gives "config.BaseAnimSet.POF_COW(4289)".
            tostring = function(c)
                return "config." .. kind .. "." .. tostring(Core.getRaw(c, "configName") or "?") ..
                    "(" .. tostring(Core.getRaw(c, "id")) .. ")"
            end,
        })
    end
    local tables = {}
    for kind in pairs(CONFIG_TYPES) do
        local fromID = Core.static({ "number" }, function(id) return getConfig(kind, id, 4) end)
        local proxy = {}
        local fromIDWrapped
        do
            local ns = Core.namespace("config." .. kind, { members = { FromID = fromID } })
            fromIDWrapped = ns.FromID
        end
        tables[kind] = setmetatable(proxy, {
            __index = function(_, key)
                if key == "FromID" then return fromIDWrapped end
                local c = configs[kind].byName[key]
                if c then return c end
                if kind == "Font" then
                    local ok, number = pcall(function() return Sandbox.api.id.Font[key] end)
                    if ok and type(number) == "number" then return getConfig("Font", number) end
                end
                error("rs3testkit: config." .. kind .. "." .. tostring(key) .. ": no config with that configName " ..
                    "in the fixture (kit.config.define(\"" .. kind .. "\", id, { configName = \"" .. tostring(key) .. "\" }))", 2)
            end,
        })
    end
    return Core.namespace("config", { members = tables })
end

---------------------------------------------------------------------------
-- Player
---------------------------------------------------------------------------
-- Standard XP curve (levels 1-120). Invention uses a different curve, so
-- its levels must be given explicitly.
local XP = { [1] = 0 }
do
    local points = 0
    for level = 1, 119 do
        points = points + math.floor(level + 300 * 2 ^ (level / 7))
        XP[level + 1] = math.floor(points / 4)
    end
end
M.XP = XP

local function levelForXp(xp, cap)
    local level = 1
    for l = 2, cap do
        if xp >= XP[l] then level = l else break end
    end
    return level
end

local player = {}
local function resetPlayer()
    player = {
        available = true, name = "Kit Tester", uid = 1, runEnergy = 100, weight = 0, combatLevel = 3,
        coord = coordGrid(0, 3222, 3218), trackingID = 1234567890123,
        xp = {}, level = {}, gameplay = {}, capped = {}, members = true,
    }
    for name, value in pairs(Docs.data.enums.SkillType.values) do
        local hp = name == "HITPOINTS"
        player.xp[value] = hp and XP[10] or 0
        player.level[value] = hp and 10 or 1
        player.gameplay[value] = player.level[value]
    end
end

local function skillId(skill, what)
    if type(skill) == "string" then
        local v = Docs.data.enums.SkillType.values[skill]
        if v == nil then error("rs3testkit: " .. what .. ": no skill named " .. skill, 3) end
        return v
    end
    return skill
end

local function requirePlayer(fn)
    if not player.available then
        error("rs3testkit: Player." .. fn .. " called while Player.IsAvailable() is false; the docs do not say " ..
            "what it returns then, so check IsAvailable first (or make the player available in the fixture)", 3)
    end
end

local playerEntity     -- the PlayerEntity for the local player

-- Player for one plugin: GetTrackingID depends on that plugin's trackingAccess.
local function definePlayer(desc)
    local function skillGetter(fn, read)
        return function(skill)
            requirePlayer(fn)
            local id = skillId(skill, "Player." .. fn)
            local v = read(id)
            if v == nil then error("rs3testkit: Player." .. fn .. ": unknown skill " .. tostring(skill), 2) end
            return v
        end
    end
    local p = Docs.namespace("Player", {
        IsAvailable = function() return player.available end,
        GetTrackingID = function()
            requirePlayer("GetTrackingID")
            -- nil without the permission, as documented.
            if not Perms.has(desc.name, "trackingAccess") then return nil end
            return player.trackingID
        end,
        GetLevelGameplay = skillGetter("GetLevelGameplay", function(id) return player.gameplay[id] end),
        GetLevelUncapped = skillGetter("GetLevelUncapped", function(id) return player.level[id] end),
        GetLevelCapped = skillGetter("GetLevelCapped", function(id)
            local l = player.level[id]
            if l == nil then return nil end
            local cap = player.capped[id]
            if cap then return math.min(l, cap) end
            return l
        end),
        GetXPUncapped = skillGetter("GetXPUncapped", function(id) return player.xp[id] end),
        GetXPCapped = skillGetter("GetXPCapped", function(id)
            local cap = player.capped[id]
            if cap then return math.min(player.xp[id], XP[cap]) end
            return player.xp[id]
        end),
        GetRunEnergy = function() requirePlayer("GetRunEnergy"); return player.runEnergy end,
        GetWeight = function() requirePlayer("GetWeight"); return player.weight end,
        GetCombatLevel = function() requirePlayer("GetCombatLevel"); return player.combatLevel end,
        GetEntity = function() requirePlayer("GetEntity"); return playerEntity end,
    })
    return p
end

---------------------------------------------------------------------------
-- Entities and lists
---------------------------------------------------------------------------
local npcs, players, locs, stacks = {}, {}, {}, {}
local nextUid = 100

local function entityClasses()
    local hint = "(The kit has no value for this entity property; pass it to the kit.world fixture.)"
    Docs.class("NPCEntity", { strict = true, missingHint = hint, native = "jag::game::NPCEntity" })
    Docs.class("PlayerEntity", { strict = true, missingHint = hint, native = "jag::game::PlayerEntity" })
    Docs.class("LocEntity", { strict = true, missingHint = hint, native = "jag::game::LocEntity" })
    Docs.class("ObjEntry", { strict = true, missingHint = hint })
    Docs.class("ObjStackEntity", {
        strict = true, missingHint = hint, native = "jag::game::ObjStackEntity",
        impls = {
            GetEntry = function(self, i) return Core.getRaw(self, "_entries")[i] end,
            HasObjID = function(self, id)
                for _, e in ipairs(Core.getRaw(self, "_entries")) do
                    if Core.getRaw(e, "configID") == id then return true end
                end
                return false
            end,
            HasObj = function(self, obj)
                local id = Core.getRaw(obj, "id")
                for _, e in ipairs(Core.getRaw(self, "_entries")) do
                    if Core.getRaw(e, "configID") == id then return true end
                end
                return false
            end,
        },
        props = { _entries = { readonly = true } },
    })
end

local function entityBase(spec, kind)
    local coord = toCoord(spec.coord or { x = spec.x or 3222, z = spec.z or 3218, level = spec.level or 0 }, "kit.world.add" .. kind)
    nextUid = nextUid + 1
    local fine = Core.getRaw(coord, "x") * 512 + 256
    local fineZ = Core.getRaw(coord, "z") * 512 + 256
    return {
        isValid = true, uid = spec.uid or nextUid, coordGrid = coord,
        position = Vector.v3(fine, spec.y or 0, fineZ),
        facing = spec.facing or 0, facingTarget = spec.facing or 0,
        route = spec.route or {}, routeEnd = coord,
    }
end

local function makeNpc(spec)
    if math.type(spec.id) ~= "integer" then error("kit.world.addNpc{ id = <NPC id> } is required", 3) end
    local cfg = configs.NPC.byId[spec.id] or defineConfig("NPC", spec.id, { name = spec.name, configName = spec.configName })
    local init = entityBase(spec, "Npc")
    init.config = cfg
    init.configID = spec.id
    init.displayName = spec.name or Core.getRaw(cfg, "name") or error("kit.world.addNpc: give a name (or define the config with one)", 3)
    init.parentConfig = spec.parentConfig and getConfig("NPC", spec.parentConfig)
    init.parentConfigID = spec.parentConfig or -1
    init.isMultiNPC = spec.parentConfig ~= nil
    return Core.new("NPCEntity", init)
end

local function makePlayerEntity(spec)
    local init = entityBase(spec, "Player")
    init.displayName = spec.name or "Player"
    return Core.new("PlayerEntity", init)
end

local function makeLoc(spec)
    if math.type(spec.id) ~= "integer" then error("kit.world.addLoc{ id = <Loc id> } is required", 3) end
    local cfg = configs.Loc.byId[spec.id] or defineConfig("Loc", spec.id, { name = spec.name, configName = spec.configName })
    local init = entityBase(spec, "Loc")
    init.config = cfg
    init.configID = spec.id
    init.displayName = spec.name or Core.getRaw(cfg, "name") or error("kit.world.addLoc: give a name", 3)
    init.parentConfigID = -1
    init.isMultiLoc = false
    init.isHidden = false
    init.isRoofRemoved = false
    init.width = spec.width or 1
    init.length = spec.length or 1
    init.uid = nil; init.facing = nil; init.facingTarget = nil; init.route = nil; init.routeEnd = nil
    return Core.new("LocEntity", init)
end

local function makeStack(spec)
    local init = entityBase(spec, "GroundItem")
    local entries = {}
    for _, item in ipairs(spec.items or error("kit.world.addGroundItems{ items = { { id, count }, ... } } is required", 3)) do
        local id, count = item[1] or item.id, item[2] or item.count or 1
        local cfg = configs.Obj.byId[id] or defineConfig("Obj", id, { name = item.name })
        entries[#entries + 1] = Core.new("ObjEntry", { config = cfg, configID = id, count = count })
    end
    init._entries = entries
    init.stackSize = #entries
    init.uid = nil; init.facing = nil; init.facingTarget = nil; init.route = nil; init.routeEnd = nil
    return Core.new("ObjStackEntity", init)
end

-- Case-insensitive name match; exact unless the pattern has * or ?.
local function nameMatches(pattern, name)
    if name == nil then return false end
    local p = string.lower(pattern)
    local n = string.lower(name)
    if not string.find(p, "[%*%?]") then return p == n end
    local lua = "^" .. string.gsub(p, "[%^%$%(%)%%%.%[%]%+%-]", "%%%0"):gsub("%*", ".*"):gsub("%?", ".") .. "$"
    return string.find(n, lua) ~= nil
end

local function liveList(list)
    local out = {}
    for _, e in ipairs(list) do if Core.getRaw(e, "isValid") then out[#out + 1] = e end end
    return out
end

local function filterList(list, tests)
    local out = {}
    for _, e in ipairs(liveList(list)) do
        local ok = true
        if tests.uid and Core.getRaw(e, "uid") ~= tests.uid then ok = false end
        if ok and tests.name and not nameMatches(tests.name, Core.getRaw(e, "displayName")) then ok = false end
        if ok and tests.coordGrid then
            local c = Core.getRaw(e, "coordGrid")
            if distance(c, tests.coordGrid) > (tests.range or 0) then ok = false end
            if ok and tests.sameLevel ~= false and Core.getRaw(c, "level") ~= Core.getRaw(tests.coordGrid, "level") then ok = false end
        end
        if ok and tests.config and Core.getRaw(e, "config") ~= tests.config and Core.getRaw(e, "parentConfig") ~= tests.config then ok = false end
        if ok and tests.configID and Core.getRaw(e, "configID") ~= tests.configID then ok = false end
        if ok and tests.parentConfig and Core.getRaw(e, "parentConfig") ~= tests.parentConfig then ok = false end
        if ok and tests.parentConfigID and Core.getRaw(e, "parentConfigID") ~= tests.parentConfigID then ok = false end
        if ok and tests.func and not tests.func(e) then ok = false end
        if ok then out[#out + 1] = e end
    end
    return out
end

local KNOWN_TESTS = { uid = true, name = true, coordGrid = true, range = true, sameLevel = true, config = true,
                      configID = true, parentConfig = true, parentConfigID = true, func = true }
local function checkTests(listName, tests)
    for k in pairs(tests) do
        if not KNOWN_TESTS[k] then
            error("rs3testkit: " .. listName .. ".Filter: '" .. tostring(k) .. "' is not a documented filter test", 3)
        end
    end
end

local function listNamespace(name, list, extra)
    local impls = {
        All = function() return liveList(list) end,
        ByUID = function(uid) return filterList(list, { uid = uid }) end,
        ByName = function(n) return filterList(list, { name = n }) end,
        ByDistance = function(c, range, sameLevel) return filterList(list, { coordGrid = c, range = range, sameLevel = sameLevel }) end,
        ByConfig = function(cfg) return filterList(list, { config = cfg }) end,
        ByConfigID = function(id) return filterList(list, { configID = id }) end,
        ByParentConfig = function(cfg) return filterList(list, { parentConfig = cfg }) end,
        ByParentConfigID = function(id) return filterList(list, { parentConfigID = id }) end,
        Filter = function(tests) checkTests(name, tests); return filterList(list, tests) end,
    }
    for k, v in pairs(extra or {}) do impls[k] = v end
    -- Only documented functions of this list are exposed.
    local documented = Docs.data.types[name] and Docs.data.types[name].methods or {}
    for k in pairs(impls) do if not documented[k] then impls[k] = nil end end
    return Docs.namespace(name, impls)
end

---------------------------------------------------------------------------
-- Inventories
---------------------------------------------------------------------------
local inventories = {}     -- id -> Inv

local function makeSlot(id, count)
    local cfg = configs.Obj.byId[id] or defineConfig("Obj", id, {})
    return Core.new("InvSlot", { obj = cfg, count = count })
end

local function invClasses()
    Docs.class("InvSlot", { strict = true })
    Docs.class("Inv", {
        strict = true,
        native = "jag::game::Inv",
        impls = {
            GetSlot = function(self, i)
                local s = Core.getRaw(self, "_slots")[i]
                if s == nil then return nil end
                return makeSlot(s.id, s.count)       -- a copy, as documented
            end,
            GetSlots = function(self)
                local out = {}
                for i = 1, Core.getRaw(self, "slotCount") do
                    local s = Core.getRaw(self, "_slots")[i]
                    out[i] = s and makeSlot(s.id, s.count) or nil
                end
                return out
            end,
            GetTotal = function(self, obj)
                local id = type(obj) == "number" and obj or Core.getRaw(obj, "id")
                local total = 0
                for i = 1, Core.getRaw(self, "slotCount") do
                    local s = Core.getRaw(self, "_slots")[i]
                    if s and s.id == id then total = total + s.count end
                end
                return total
            end,
            GetCategoryTotal = function(self, category)
                local total = 0
                for i = 1, Core.getRaw(self, "slotCount") do
                    local s = Core.getRaw(self, "_slots")[i]
                    if s then
                        local cfg = getConfig("Obj", s.id)
                        local ok, cat = pcall(function() return cfg.category end)
                        if not ok then
                            error("rs3testkit: Inv:GetCategoryTotal needs config.Obj " .. s.id ..
                                " to have a category (kit.config.define(\"Obj\", " .. s.id .. ", { category = ... }))", 3)
                        end
                        if cat == category then total = total + s.count end
                    end
                end
                return total
            end,
        },
        props = { _slots = { readonly = true } },
    })
end

local function refreshCounts(inv)
    local used = 0
    for i = 1, Core.getRaw(inv, "slotCount") do
        if Core.getRaw(inv, "_slots")[i] then used = used + 1 end
    end
    Core.setRaw(inv, "usedSlotCount", used)
    Core.setRaw(inv, "freeSlotCount", Core.getRaw(inv, "slotCount") - used)
end

---------------------------------------------------------------------------
-- Grand Exchange
---------------------------------------------------------------------------
local offers = {}
local maxOffers = 8

---------------------------------------------------------------------------
-- MiniMenu
---------------------------------------------------------------------------
local menuState = { open = false, phase = nil, current = nil }

local function menuClasses()
    local hint = "(Give it in kit.menu.entry{ ... }.)"
    for _, t in ipairs({ "NPCData", "LocData", "ObjData", "PlayerData", "GroundData", "ComponentData", "MapElementData" }) do
        Docs.class(t, { strict = true, missingHint = hint })
    end
    Docs.class("MiniMenuEntry", { strict = true, missingHint = hint, props = { _action = {}, _args = {} } })
    Docs.class("MiniMenu", {
        strict = true,
        impls = {
            Add = function(self, label, fn, ...)
                if menuState.phase ~= "MiniMenuEntryAdded" and menuState.phase ~= "MiniMenuReady" then
                    error("rs3testkit: MiniMenu:Add is only available during Event.MiniMenuEntryAdded and " ..
                        "Event.MiniMenuReady (called " .. (menuState.phase and ("during " .. menuState.phase) or "outside any menu event") .. ")", 2)
                end
                local entries = Core.getRaw(self, "_list")
                local entry = Core.new("MiniMenuEntry", {
                    actionType = -1, actionEntryType = enums.MiniMenuEntryType.PLUGIN,
                    actionVerbType = enums.MiniMenuActionVerbType.UNSPECIFIED,
                    verbText = label, subjectText = "", extraText = "", fullText = label, overrideText = "",
                    cursorID = -1, iconSpriteIDs = {}, subjectOnOtherLevel = false, subjectHash = 0,
                    _action = fn, _args = table.pack(...),
                })
                if menuState.phase == "MiniMenuEntryAdded" then
                    -- Added immediately after the entry being reported.
                    local at = #entries + 1
                    for i, e in ipairs(entries) do if e == menuState.current then at = i + 1 end end
                    table.insert(entries, at, entry)
                else
                    entries[#entries + 1] = entry
                end
                Core.setRaw(self, "entryCount", #entries)
            end,
            Swap = function(self, a, b)
                if menuState.phase ~= "MiniMenuReady" then
                    error("rs3testkit: MiniMenu:Swap is only available during Event.MiniMenuReady", 2)
                end
                local entries = Core.getRaw(self, "_list")
                if not entries[a] or not entries[b] then
                    error("rs3testkit: MiniMenu:Swap(" .. a .. ", " .. b .. "): index out of range 1.." .. #entries, 2)
                end
                entries[a], entries[b] = entries[b], entries[a]
            end,
        },
        props = { _list = {} },
        overrides = {
            entries = { read = function(self)
                local out = {}
                for i, e in ipairs(Core.getRaw(self, "_list")) do out[i] = e end
                return out
            end },
            isOpen = { read = function() return menuState.open end },
        },
    })
end

local MENU_VERBS = { EXAMINE = true, ATTACK = true, OP = true, UNSPECIFIED = true }
-- actionType for "op n" on each source, from MiniMenuActionType.
local function actionFor(kind, op)
    local name = ({ npc = "OP_NPC", loc = "OP_LOC", obj = "OP_OBJ", player = "OP_PLAYER" })[kind]
    if not name then return enums.MiniMenuActionType.WALK end
    return enums.MiniMenuActionType[name .. tostring(op)]
end

---------------------------------------------------------------------------
-- Install
---------------------------------------------------------------------------
function M.install(api, kit)
    local e = Ids.enums()
    enums = e.globals
    for name, enum in pairs(e.globals) do api[name] = enum end

    local CoordGrid, CoordFine = defineCoords()
    resetPlayer()
    api.CoordGrid, api.CoordFine = CoordGrid, CoordFine
    api.config = defineConfigs()
    entityClasses()
    invClasses()
    menuClasses()
    Docs.class("GrandExchangeOffer", { strict = true })

    playerEntity = makePlayerEntity({ name = player.name, coord = player.coord, uid = 1 })

    api.NPCList = listNamespace("NPCList", npcs)
    api.PlayerList = listNamespace("PlayerList", players, { Self = function() requirePlayer("GetEntity"); return playerEntity end })
    api.LocList = listNamespace("LocList", locs)
    api.ObjStackList = listNamespace("ObjStackList", stacks, {
        ByName = function(n)
            local out = {}
            for _, s in ipairs(liveList(stacks)) do
                for _, en in ipairs(Core.getRaw(s, "_entries")) do
                    local ok, nm = pcall(function() return en.config.name end)
                    if ok and nameMatches(n, nm) then out[#out + 1] = s; break end
                end
            end
            return out
        end,
        ByConfigID = function(id)
            local out = {}
            for _, s in ipairs(liveList(stacks)) do
                for _, en in ipairs(Core.getRaw(s, "_entries")) do
                    if Core.getRaw(en, "configID") == id then out[#out + 1] = s; break end
                end
            end
            return out
        end,
    })

    api.Inventory = Docs.namespace("Inventory", {
        Find = function(key)
            local id = type(key) == "number" and key or Core.getRaw(key, "id")
            local inv = inventories[id]
            if inv and Core.getRaw(inv, "isValid") then return inv end
            return nil
        end,
    })

    api.GrandExchange = Docs.namespace("GrandExchange", {
        GetOffer = function(slot)
            if slot < 1 or slot > maxOffers then return nil end
            if offers[slot] == nil then
                offers[slot] = Core.new("GrandExchangeOffer", { stage = enums.GrandExchangeOfferStage.EMPTY,
                    type = enums.GrandExchangeOfferType.BUY, price = 0, itemCount = 0, soldCount = 0, goldFromSale = 0 })
            end
            return offers[slot]
        end,
        MaxOffers = function() return maxOffers end,
    })

    local world = { available = true, members = true, ping = 30, reboot = 0, region = false }
    api.World = Docs.namespace("World", {
        IsAvailable = function() return world.available end,
        IsMembers = function() return world.members end,
        GetPing = function() return world.available and world.ping or -1 end,
        GetRebootTimer = function() return world.available and world.reboot or 0 end,
        IsRegion = function() return world.region end,
    }, { RemoveRoof = Docs.namespace("World.RemoveRoof", {}) })

    api.MiniMenu = Docs.namespace("MiniMenu", { IsOpen = function() return menuState.open end })

    -----------------------------------------------------------------------
    -- Fixtures
    -----------------------------------------------------------------------
    kit.config = {}
    -- Defines a config: kit.config.define("NPC", 81, { name = "Cow", gridSize = 2 }).
    function kit.config.define(kind, id, fields)
        if not CONFIG_TYPES[kind] then error("kit.config.define: unknown config kind " .. tostring(kind), 2) end
        return defineConfig(kind, id, fields)
    end
    function kit.config.npc(id, fields) return defineConfig("NPC", id, fields) end
    function kit.config.obj(id, fields) return defineConfig("Obj", id, fields) end
    function kit.config.loc(id, fields) return defineConfig("Loc", id, fields) end
    function kit.config.inv(id, fields) return defineConfig("Inv", id, fields) end
    function kit.config.missingIsNil(on) configMissingIsNil = on and true or false end

    kit.fonts = {}
    -- FontType:GetStringWidth(text) returns floor(fn(fontConfig, text)).
    -- The kit has no real font metrics, so the spec chooses the rule.
    function kit.fonts.measureWith(fn)
        if type(fn) ~= "function" then error("kit.fonts.measureWith(fn): fn must be a function", 2) end
        fontMeasure = fn
    end

    kit.player = {}
    -- Sets player state. levels/xp are { SKILLNAME = n }; giving only a level
    -- sets the XP for it, giving only XP sets the level (not for Invention).
    function kit.player.set(t)
        for k in pairs(t) do
            if not ({ available = 1, name = 1, runEnergy = 1, weight = 1, combatLevel = 1, coord = 1, trackingID = 1,
                      levels = 1, xp = 1, boosted = 1, capped = 1, members = 1 })[k] then
                error("kit.player.set: unknown field " .. tostring(k), 2)
            end
        end
        for _, k in ipairs({ "available", "name", "runEnergy", "weight", "combatLevel", "trackingID", "members" }) do
            if t[k] ~= nil then player[k] = t[k] end
        end
        if t.name then Core.setRaw(playerEntity, "displayName", t.name) end
        if t.coord then kit.player.moveTo(t.coord) end
        for skill, level in pairs(t.levels or {}) do
            local id = skillId(skill, "kit.player.set")
            player.level[id], player.gameplay[id] = level, level
            if not (t.xp and t.xp[skill]) then player.xp[id] = XP[math.min(level, 120)] end
        end
        for skill, xp in pairs(t.xp or {}) do
            local id = skillId(skill, "kit.player.set")
            player.xp[id] = xp
            if not (t.levels and t.levels[skill]) then
                if id == enums.SkillType.INVENTION then
                    error("kit.player.set: Invention uses its own XP curve; give its level in levels too", 2)
                end
                player.level[id] = levelForXp(xp, 120)
                player.gameplay[id] = player.level[id]
            end
        end
        for skill, level in pairs(t.boosted or {}) do
            player.gameplay[skillId(skill, "kit.player.set")] = level
        end
        -- Free-to-play world limits: { MINING = 5 } caps the capped level/XP.
        for skill, cap in pairs(t.capped or {}) do
            player.capped[skillId(skill, "kit.player.set")] = cap
        end
    end

    function kit.player.moveTo(coord)
        player.coord = toCoord(coord, "kit.player.moveTo")
        Core.setRaw(playerEntity, "coordGrid", player.coord)
        Core.setRaw(playerEntity, "routeEnd", player.coord)
        Core.setRaw(playerEntity, "position", Vector.v3(Core.getRaw(player.coord, "x") * 512 + 256, 0,
            Core.getRaw(player.coord, "z") * 512 + 256))
    end

    function kit.player.entity() return playerEntity end

    -- Adds XP and fires Event.SkillTransmit (as the server's stat update would).
    function kit.player.gainXP(skill, amount)
        local id = skillId(skill, "kit.player.gainXP")
        local oldXP, oldLevel = player.xp[id], player.gameplay[id]
        player.xp[id] = oldXP + amount
        if id ~= enums.SkillType.INVENTION then
            local newLevel = levelForXp(player.xp[id], 120)
            if newLevel ~= player.level[id] then
                local boost = player.gameplay[id] - player.level[id]
                player.level[id] = newLevel
                player.gameplay[id] = newLevel + boost
            end
        end
        Events.fire("SkillTransmit", { skill = id, oldXP = oldXP, newXP = player.xp[id],
            oldGameplayLevel = oldLevel, newGameplayLevel = player.gameplay[id] })
    end

    function kit.player.setRunEnergy(v)
        local old = player.runEnergy
        player.runEnergy = v
        Events.fire("RunEnergyTransmit", { oldRunEnergy = old, newRunEnergy = v })
    end

    function kit.player.setWeight(v)
        local old = player.weight
        player.weight = v
        Events.fire("RunWeightTransmit", { oldRunWeight = old, newRunWeight = v })
    end

    kit.world = {}
    function kit.world.set(t)
        for k, v in pairs(t) do
            if world[k] == nil then error("kit.world.set: unknown field " .. tostring(k), 2) end
            world[k] = v
        end
    end

    -- Adds entities. Pass fire = true to also fire the *EntityAdded event.
    function kit.world.addNpc(spec)
        local n = makeNpc(spec)
        npcs[#npcs + 1] = n
        if spec.fire then Events.fire("NPCEntityAdded", { npcEntity = n, entityType = enums.EntityType.NPC }) end
        return n
    end
    function kit.world.addPlayer(spec)
        local p = makePlayerEntity(spec)
        players[#players + 1] = p
        if spec.fire then Events.fire("PlayerEntityAdded", { playerEntity = p, entityType = enums.EntityType.PLAYER }) end
        return p
    end
    function kit.world.addLoc(spec)
        local l = makeLoc(spec)
        locs[#locs + 1] = l
        return l
    end
    function kit.world.addGroundItems(spec)
        local s = makeStack(spec)
        stacks[#stacks + 1] = s
        if spec.fire then
            local first = Core.getRaw(s, "_entries")[1]
            Events.fire("ObjStackEntityAdded", { objStackEntity = s, entityType = enums.EntityType.OBJSTACK,
                objType = Core.getRaw(first, "config"), count = Core.getRaw(first, "count"), isOwner = spec.isOwner or false })
        end
        return s
    end

    -- Removes an entity: isValid becomes false and any other read raises.
    function kit.world.remove(entity, fire)
        local cls = Core.classOf(entity)
        Core.setRaw(entity, "isValid", false)
        Core.destroyed[entity] = "it left the world (kit.world.remove); check isValid first"
        if fire and cls == "NPCEntity" then
            Events.fire("NPCEntityRemoved", { npcEntity = entity, entityType = enums.EntityType.NPC })
        elseif fire and cls == "PlayerEntity" then
            Events.fire("PlayerEntityRemoved", { playerEntity = entity, entityType = enums.EntityType.PLAYER })
        end
    end

    kit.inventory = {}
    -- Sets an inventory's contents. slots = { { objId, count }, ... } with
    -- false for an empty slot. Common ids: 93 backpack (28), 94 worn, 95 bank.
    function kit.inventory.set(id, slots, opts)
        opts = opts or {}
        local size = opts.size or (id == 93 and 28) or math.max(#slots, 1)
        local cfg = configs.Inv.byId[id] or defineConfig("Inv", id, { size = size, configName = opts.configName })
        local stored = {}
        for i = 1, size do
            local s = slots[i]
            if s then stored[i] = { id = s[1] or s.id, count = s[2] or s.count or 1 } end
        end
        local inv = inventories[id]
        if inv == nil or not Core.getRaw(inv, "isValid") then
            inv = Core.new("Inv", { id = id, config = cfg, isValid = true, slotCount = size, _slots = stored })
            inventories[id] = inv
            refreshCounts(inv)
            if opts.fire then Events.fire("InventoryAdded", { inv = cfg }) end
        else
            Core.setRaw(inv, "_slots", stored)
            refreshCounts(inv)
            if opts.fire then
                local all = {}
                for i = 1, size do all[i] = i end
                Events.fire("InventoryUpdated", { inv = cfg, slotsUpdated = all })
            end
        end
        return inv
    end

    -- Changes one slot and fires Event.InventoryUpdated for it.
    function kit.inventory.setSlot(id, slot, objId, count)
        local inv = inventories[id] or error("kit.inventory.setSlot: inventory " .. id .. " was never set", 2)
        Core.getRaw(inv, "_slots")[slot] = objId and { id = objId, count = count or 1 } or nil
        refreshCounts(inv)
        Events.fire("InventoryUpdated", { inv = Core.getRaw(inv, "config"), slotsUpdated = { slot } })
    end

    -- The server stops sending an inventory (e.g. the bank is closed).
    function kit.inventory.remove(id, fire)
        local inv = inventories[id]
        if inv then
            Core.setRaw(inv, "isValid", false)
            Core.destroyed[inv] = "the server removed it (kit.inventory.remove); check isValid first"
            if fire ~= false then Events.fire("InventoryRemoved", { inv = Core.getRaw(inv, "config") }) end
        end
    end

    kit.ge = {}
    function kit.ge.setMaxOffers(n) maxOffers = n end
    -- Sets an offer slot and fires Event.GrandExchangeOfferUpdated.
    function kit.ge.setOffer(slot, t)
        local item = t.item and (Core.isA(t.item, "ObjType") and t.item or configs.Obj.byId[t.item] or defineConfig("Obj", t.item, {}))
        offers[slot] = Core.new("GrandExchangeOffer", {
            stage = enumValue(enums.GrandExchangeOfferStage, t.stage or "ADDED", "stage"),
            type = enumValue(enums.GrandExchangeOfferType, t.type or "BUY", "type"),
            item = item, price = t.price or 0, itemCount = t.itemCount or 0,
            soldCount = t.soldCount or 0, goldFromSale = t.goldFromSale or 0,
        })
        if t.fire ~= false then
            Events.fire("GrandExchangeOfferUpdated", { slot = slot, listing = offers[slot] })
        end
        return offers[slot]
    end

    ---------------------------------------------------------------------
    -- MiniMenu fixtures
    ---------------------------------------------------------------------
    kit.menu = {}

    -- Builds a game entry. spec: npc = NPCEntity or id | loc = id | obj = id |
    -- player = PlayerEntity; verb ("Examine"), verbType ("EXAMINE" / "OP" /
    -- "ATTACK"), op (1-6, picks actionType), subject (menu text; defaults to
    -- the entity name), plus any MiniMenuEntry property to override.
    function kit.menu.entry(spec)
        local verbType = spec.verbType or ((spec.verb == "Examine") and "EXAMINE") or "OP"
        if not MENU_VERBS[verbType] then error("kit.menu.entry: verbType must be one of EXAMINE, OP, ATTACK, UNSPECIFIED", 2) end
        local init = {
            actionVerbType = enums.MiniMenuActionVerbType[verbType], verbText = spec.verb or "Examine",
            extraText = "", overrideText = "", cursorID = -1, iconSpriteIDs = {}, subjectOnOtherLevel = false,
        }
        local kind, op = nil, spec.op or (verbType == "EXAMINE" and 6) or 1
        if spec.npc then
            kind = "npc"
            local n = type(spec.npc) == "number" and kit.world.addNpc({ id = spec.npc, name = spec.name }) or spec.npc
            init.npcData = Core.new("NPCData", { entity = n })
            init.subjectText = spec.subject or Core.getRaw(n, "displayName")
            init.subjectHash = Core.getRaw(n, "uid")
        elseif spec.loc then
            kind = "loc"
            local cfg = configs.Loc.byId[spec.loc] or defineConfig("Loc", spec.loc, { name = spec.name })
            local c = toCoord(spec.coord or { x = 3222, z = 3218 }, "kit.menu.entry")
            init.locData = Core.new("LocData", { config = cfg, coordGridX = Core.getRaw(c, "x"), coordGridZ = Core.getRaw(c, "z") })
            init.subjectText = spec.subject or spec.name or Core.getRaw(cfg, "name") or ""
            init.subjectHash = spec.loc
        elseif spec.obj then
            kind = "obj"
            local cfg = configs.Obj.byId[spec.obj] or defineConfig("Obj", spec.obj, { name = spec.name })
            local stack = kit.world.addGroundItems({ items = { { spec.obj, spec.count or 1 } }, coord = spec.coord })
            init.objData = Core.new("ObjData", { entity = stack, stackIndex = 1, config = cfg })
            init.subjectText = spec.subject or spec.name or Core.getRaw(cfg, "name") or ""
            init.subjectHash = spec.obj
        elseif spec.player then
            kind = "player"
            init.playerData = Core.new("PlayerData", { entity = spec.player })
            init.subjectText = spec.subject or Core.getRaw(spec.player, "displayName")
            init.subjectHash = Core.getRaw(spec.player, "uid")
        else
            init.subjectText = spec.subject or ""
            init.subjectHash = 0
        end
        init.actionType = spec.actionType or actionFor(kind, op)
        init.actionEntryType = enums.MiniMenuEntryType[({ npc = "NPC", loc = "LOC", obj = "OBJ", player = "PLAYER" })[kind] or "OTHER"]
        init.fullText = init.verbText .. (init.subjectText ~= "" and (" " .. init.subjectText) or "")
        for k, v in pairs(spec) do
            if Docs.data.types.MiniMenuEntry.props[k] then init[k] = v end
        end
        return Core.new("MiniMenuEntry", init)
    end
    function kit.menu.npcEntry(spec) return kit.menu.entry(spec) end

    -- Runs the client's MiniMenu sequence for a right-click over `entries`
    -- (lowest priority first, as the API lists them): MiniMenuEntryAdded for
    -- each, MiniMenuReady, then MiniMenuOpened. Returns a handle:
    --   handle.entries          all entries, including plugin-added ones
    --   handle:labels()         their texts
    --   handle:select(text)     choose one: runs a plugin entry's function,
    --                           fires MiniMenuEntrySelected and MiniMenuClosed
    --   handle:close()          close without choosing
    function kit.menu.open(entries)
        local menu = Core.new("MiniMenu", { _list = {}, entryCount = 0 })
        local list = Core.getRaw(menu, "_list")
        for _, entry in ipairs(entries) do
            list[#list + 1] = entry
            Core.setRaw(menu, "entryCount", #list)
            menuState.phase, menuState.current = "MiniMenuEntryAdded", entry
            local ok, err = pcall(Events.fire, "MiniMenuEntryAdded", { entry = entry, miniMenu = menu })
            menuState.phase, menuState.current = nil, nil
            if not ok then error(err, 0) end
        end
        menuState.phase = "MiniMenuReady"
        local ok, err = pcall(Events.fire, "MiniMenuReady", { miniMenu = menu })
        menuState.phase = nil
        if not ok then error(err, 0) end
        menuState.open = true
        Events.fire("MiniMenuOpened", { miniMenu = menu })

        local handle = { menu = menu }
        handle.entries = list
        function handle:labels()
            local out = {}
            for i, e in ipairs(list) do out[i] = Core.getRaw(e, "fullText") end
            return out
        end
        function handle:find(text)
            for _, e in ipairs(list) do
                if Core.getRaw(e, "fullText") == text or Core.getRaw(e, "verbText") == text then return e end
            end
        end
        function handle:select(text)
            local entry = self:find(text)
            if not entry then
                error("kit.menu: no entry " .. string.format("%q", text) .. " in the menu; entries are: " ..
                    table.concat(self:labels(), " | "), 2)
            end
            menuState.open = false
            Events.fire("MiniMenuEntrySelected", { entry = entry })
            local action = Core.getRaw(entry, "_action")
            if action then
                local args = Core.getRaw(entry, "_args")
                local okA, errA = xpcall(action, debug.traceback, table.unpack(args, 1, args.n))
                if not okA then error("MiniMenu entry '" .. text .. "' action raised:\n" .. tostring(errA), 0) end
            end
            Events.fire("MiniMenuClosed", { miniMenu = menu })
            return entry
        end
        function handle:close()
            menuState.open = false
            Events.fire("MiniMenuClosed", { miniMenu = menu })
        end
        return handle
    end

    -- Shortcut: right-click an NPC and choose `label` (e.g. a plugin's entry).
    function kit.menu.choose(entrySpec, label)
        return kit.menu.open({ kit.menu.entry(entrySpec) }):select(label)
    end
end

function M.perPlugin(desc, ownApi)
    ownApi.Player = definePlayer(desc)
end

return M
