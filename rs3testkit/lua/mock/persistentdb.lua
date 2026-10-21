-- PersistentDB: a plugin's saved settings, one store per plugin.
--
-- The client keeps these in RuneScape/plugins/PluginData.db (SQLite table
-- DataStore: PluginID, Key, Type, Value), keyed by the plugin's name. Values
-- are typed (PersistentDBType: BOOL, INT, FLOAT, STRING, STRUCTURED_DATA).
-- The typed getters return nil on a type mismatch, as documented; the kit
-- also reports that as a lint because it is almost always a bug.
--
-- Methods are called with ":" (PersistentDB:GetInt("x")).
--
-- Fixtures:
--   kit.db.set("windowX", 80)        seed a value for the plugin under test
--   kit.db.get("windowX")            what the plugin saved (nil if never)
--   kit.db.all()                     { key = value, ... }
--   kit.db.failWrites(true)          make every write return false

local Core = require("core")
local Docs = require("docs")

local M = {}

local stores = {}          -- plugin name -> { key -> { kind, value } }
local failWrites = false
local rootName = nil

local function storeFor(name)
    stores[name] = stores[name] or {}
    return stores[name]
end

local function kindOf(value)
    if type(value) == "boolean" then return "BOOL" end
    if math.type(value) == "integer" then return "INT" end
    if type(value) == "number" then return "FLOAT" end
    if type(value) == "string" then return "STRING" end
    if type(value) == "table" then return "STRUCTURED_DATA" end
end

-- Structured data is serialised by the client, so later changes to the
-- table the plugin passed must not show up in the store: keep a copy.
local function copy(v, seen)
    if type(v) ~= "table" then return v end
    seen = seen or {}
    if seen[v] then error("rs3testkit: PersistentDB structured data cannot contain cycles", 4) end
    seen[v] = true
    local out = {}
    for k, x in pairs(v) do
        -- Only tables can carry a kit/API metatable here (every string has
        -- the string library's metatable, so it must not be checked).
        if type(x) == "function" or type(x) == "userdata" or type(k) == "table"
            or (type(x) == "table" and getmetatable(x) ~= nil) then
            error("rs3testkit: PersistentDB structured data can hold only plain tables, strings, numbers and booleans", 4)
        end
        out[k] = copy(x, seen)
    end
    seen[v] = nil
    return out
end

local NAMES = { BOOL = "Bool", INT = "Int", FLOAT = "Float", STRING = "String", STRUCTURED_DATA = "StructuredData" }

local function defineClass(enumValues)
    local function getter(kind)
        return function(self, key)
            local cell = storeFor(Core.getRaw(self, "_plugin"))[key]
            if cell == nil then return nil end
            if kind and cell.kind ~= kind then
                Core.warn("db-type", string.format("PersistentDB:Get%s(%q) read a key saved as %s (returns nil)",
                    NAMES[kind], key, cell.kind))
                return nil
            end
            return copy(cell.value)
        end
    end
    local function setter(kind)
        return function(self, key, value)
            if failWrites then return false end
            local k = kind or kindOf(value)
            if k == "INT" and math.type(value) ~= "integer" then
                if value ~= math.floor(value) then
                    error("rs3testkit: PersistentDB:SetInt(" .. key .. ") needs a whole number, got " .. tostring(value), 2)
                end
                value = math.tointeger(value)
            end
            storeFor(Core.getRaw(self, "_plugin"))[key] = { kind = k, value = copy(value) }
            return true
        end
    end
    Docs.class("PersistentDB", {
        native = "jag::plugin::PersistentDB",
        props = { _plugin = { readonly = true } },
        impls = {
            Get = getter(nil), GetBool = getter("BOOL"), GetInt = getter("INT"), GetFloat = getter("FLOAT"),
            GetString = getter("STRING"), GetStructuredData = getter("STRUCTURED_DATA"),
            Set = setter(nil), SetBool = setter("BOOL"), SetInt = setter("INT"), SetFloat = setter("FLOAT"),
            SetString = setter("STRING"), SetStructuredData = setter("STRUCTURED_DATA"),
            CheckExists = function(self, key) return storeFor(Core.getRaw(self, "_plugin"))[key] ~= nil end,
            CheckExistsTyped = function(self, key, t)
                local cell = storeFor(Core.getRaw(self, "_plugin"))[key]
                return cell ~= nil and enumValues[cell.kind] == t
            end,
            IterateEntries = function(self, fn)
                local store = storeFor(Core.getRaw(self, "_plugin"))
                local keys = {}
                for k in pairs(store) do keys[#keys + 1] = k end
                table.sort(keys)
                local n = 0
                for _, k in ipairs(keys) do
                    n = n + 1
                    if fn(k, copy(store[k].value)) == true then break end
                end
                return n
            end,
            Delete = function(self, key)
                if failWrites then return false end
                storeFor(Core.getRaw(self, "_plugin"))[key] = nil
                return true
            end,
            Clear = function(self)
                if failWrites then return false end
                stores[Core.getRaw(self, "_plugin")] = {}
                return true
            end,
        },
    })
end

function M.install(api, kit)
    defineClass(Docs.data.enums.PersistentDBType.values)
    kit.db = {}
    local function name(plugin) return plugin or rootName or error("kit.db: no plugin loaded", 3) end
    function kit.db.set(key, value, plugin)
        local kind = kindOf(value)
        if not kind then error("kit.db.set: value must be a boolean, number, string or table", 2) end
        storeFor(name(plugin))[key] = { kind = kind, value = copy(value) }
    end
    function kit.db.get(key, plugin)
        local cell = storeFor(name(plugin))[key]
        return cell and copy(cell.value)
    end
    function kit.db.kind(key, plugin)
        local cell = storeFor(name(plugin))[key]
        return cell and cell.kind
    end
    function kit.db.all(plugin)
        local out = {}
        for k, cell in pairs(storeFor(name(plugin))) do out[k] = copy(cell.value) end
        return out
    end
    function kit.db.failWrites(on) failWrites = on and true or false end
end

-- Each plugin gets its own PersistentDB object over its own store. The
-- plugin under test is prepared last, so it ends up as the default.
function M.perPlugin(desc, ownApi)
    rootName = desc.name
    ownApi.PersistentDB = Core.new("PersistentDB", { _plugin = desc.name })
end

return M
