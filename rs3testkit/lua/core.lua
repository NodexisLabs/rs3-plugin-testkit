-- core.lua: building blocks for the mock API.
--
-- Everything a plugin can touch is made from four kinds of object:
--   namespace  a table of static functions, called with "." (Player.GetEntity())
--   class      an object type with properties and methods, called with ":"
--              (box:SetPos(x, y), text.content = "hi")
--   enum       named numbers (ui.AlignMode.CENTRE)
--   id table   game config names <-> numbers (id.Font.MUSEO_SANS_13PT_REGULAR)
--
-- All four fail loudly. Reading a member the kit does not know raises an
-- error that says whether the member is documented-but-not-mocked-yet or not
-- part of the documented API at all (usually a typo). Calling a function with
-- the wrong separator ("." vs ":"), the wrong number of arguments or the wrong
-- types raises an error, as the real client's binding layer (sol2) does.
--
-- Every call into the mock is appended to Core.trace, so a failing test can
-- show exactly what the plugin asked the game for.

local Core = {}

Core.trace = {}       -- { api = "Player.GetEntity", args = {...} } per call
Core.warnings = {}    -- lint findings: { code, message }, deduplicated
Core.TRACE_LIMIT = 20000

local warned = {}

-- Records a lint finding once per (code, message).
function Core.warn(code, message)
    local key = code .. "\0" .. message
    if warned[key] then return end
    warned[key] = true
    Core.warnings[#Core.warnings + 1] = { code = code, message = message }
end

function Core.resetWarnings()
    Core.warnings = {}
    warned = {}
end

local function record(api, args)
    if #Core.trace >= Core.TRACE_LIMIT then table.remove(Core.trace, 1) end
    Core.trace[#Core.trace + 1] = { api = api, args = args }
end

-- Error raised when a plugin touches something the kit does not provide.
-- Level 3 blames the plugin line that did the lookup, not the kit.
function Core.missing(path, documented, extra)
    local why
    if documented then
        why = "is in the documented API but the kit does not mock it yet. " ..
              "Mock it in your spec (kit.mock(\"" .. path .. "\", fn)) or add it to rs3testkit/lua/mock/."
    else
        why = "is not part of the documented plugin API (typo, or an undocumented member?)."
    end
    error("rs3testkit: " .. path .. " " .. why .. (extra and (" " .. extra) or ""), 3)
end

---------------------------------------------------------------------------
-- Argument checking
---------------------------------------------------------------------------
-- A param spec is a type name with an optional "?" (may be nil):
--   "number", "integer", "string", "boolean", "function", "table", "any",
--   or a class name registered with Core.class ("Vector3", "ui.Component").
local classes = {}            -- name -> class definition
local instanceClass = setmetatable({}, { __mode = "k" })   -- proxy -> class

local function isA(value, className)
    local cls = instanceClass[value]
    while cls do
        if cls.name == className then return true end
        cls = cls.parent and classes[cls.parent]
    end
    return false
end
Core.isA = isA

function Core.typeOk(value, spec)
    local optional = string.sub(spec, -1) == "?"
    if optional then spec = string.sub(spec, 1, -2) end
    if value == nil then return optional end
    if spec == "any" then return true end
    if spec == "integer" then return math.type(value) == "integer" or (type(value) == "number" and value == math.floor(value)) end
    if spec == "number" or spec == "string" or spec == "boolean" or spec == "function" or spec == "table" then
        return type(value) == spec
    end
    -- "a|b": either type
    if string.find(spec, "|", 1, true) then
        for alt in string.gmatch(spec, "[^|]+") do
            if Core.typeOk(value, alt) then return true end
        end
        return false
    end
    -- A type the kit has no class for (yet) cannot be checked.
    if not classes[spec] then return true end
    return isA(value, spec)
end

function Core.typeName(value)
    local cls = instanceClass[value]
    if cls then return cls.name end
    if math.type(value) then return math.type(value) end
    return type(value)
end

-- The message mirrors the real client's sol2 error, plus what the kit expected.
function Core.badCall(path, params, args, n)
    local want = {}
    for i, p in ipairs(params) do want[i] = p end
    local got = {}
    for i = 1, n do got[i] = Core.typeName(args[i]) end
    error(string.format(
        "sol: no matching function call takes this number of arguments and the specified types " ..
        "(rs3testkit: %s expects (%s), got (%s))",
        path, table.concat(want, ", "), table.concat(got, ", ")), 3)
end

function Core.checkArgs(path, params, args, n)
    if params == nil then return end
    local required = 0
    for i, p in ipairs(params) do if string.sub(p, -1) ~= "?" then required = i end end
    if n > #params or n < required then Core.badCall(path, params, args, n) end
    for i, p in ipairs(params) do
        if not Core.typeOk(args[i], p) then Core.badCall(path, params, args, n) end
    end
end

---------------------------------------------------------------------------
-- Namespaces: tables of static functions and values
---------------------------------------------------------------------------
-- Core.namespace("Player", { documented = {...names}, members = {...} })
-- `members` maps a name to a value; use Core.static to make functions.
local namespaces = {}

local function staticWrapper(path, owner, params, impl, check)
    return function(...)
        local n = select("#", ...)
        local args = { ... }
        if n > 0 and rawequal(args[1], owner) then
            error("rs3testkit: " .. path .. " is a static function: call it with '.', not ':'", 2)
        end
        if check then check(path, args, n) else Core.checkArgs(path, params, args, n) end
        record(path, args)
        return impl(...)
    end
end

-- Marks a namespace member as a static function: Core.static({"number"}, fn).
-- `check(path, args, n)`, if given, replaces the params check (docs.lua uses
-- it to accept any documented overload).
function Core.static(params, impl, check)
    return { __static = true, params = params, impl = impl, check = check }
end

function Core.namespace(path, spec)
    local documented = {}
    for _, name in ipairs(spec.documented or {}) do documented[name] = true end
    local store = {}
    local proxy = {}
    namespaces[path] = proxy
    for name, value in pairs(spec.members or {}) do
        documented[name] = true
        if type(value) == "table" and rawget(value, "__static") then
            store[name] = staticWrapper(path .. "." .. name, proxy, value.params, value.impl, value.check)
        else
            store[name] = value
        end
    end
    setmetatable(proxy, {
        __index = function(_, key)
            local v = store[key]
            if v ~= nil then return v end
            Core.missing(path .. "." .. tostring(key), documented[key])
        end,
        __newindex = function(_, key, value)
            Core.warn("api-write", "plugin assigned " .. path .. "." .. tostring(key) ..
                " (writing into a game API table is almost always a mistake)")
            store[key] = value
        end,
        __pairs = function() return next, store, nil end,
        __tostring = function() return "rs3testkit namespace " .. path end,
        __kit = { path = path, store = store, documented = documented },
    })
    return proxy
end

-- Replace or add a member of a namespace from a spec (kit.mock).
function Core.setMember(proxy, name, value)
    local mt = getmetatable(proxy)
    if not (mt and mt.__kit) then error("rs3testkit: not a mock namespace", 2) end
    if type(value) == "function" then
        local path = mt.__kit.path .. "." .. name
        local fn = value
        value = function(...) record(path, { ... }); return fn(...) end
    end
    mt.__kit.store[name] = value
end

function Core.namespaceStore(proxy)
    local mt = getmetatable(proxy)
    return mt and mt.__kit and mt.__kit.store
end

---------------------------------------------------------------------------
-- Classes: objects with properties and methods
---------------------------------------------------------------------------
-- Core.class("ui.Text", {
--     parent = "ui.Component",
--     props = { content = { type = "string", default = "" },
--               numLines = { type = "integer", default = 1, readonly = true } },
--     methods = { SetPos = { params = {"number", "number"}, impl = function(self, x, y) ... end } },
--     documented = { "SomeUnmockedMethod", ... },
-- })
-- Property `type` uses the same specs as params. `readonly` props can only
-- be changed by the kit (Core.setRaw). `onSet(self, value)` runs after a write.
-- `reject = "message"` makes any write fail with that message (an API gap).

local function findProp(cls, key)
    while cls do
        local p = cls.props and cls.props[key]
        if p then return p end
        cls = cls.parent and classes[cls.parent]
    end
end

local function findMethod(cls, key)
    while cls do
        local m = cls.wrapped and cls.wrapped[key]
        if m then return m end
        cls = cls.parent and classes[cls.parent]
    end
end

local function isDocumented(cls, key)
    while cls do
        if cls.documentedSet[key] then return true end
        cls = cls.parent and classes[cls.parent]
    end
    return false
end

local function propNames(cls)
    local names = {}
    while cls do
        for k in pairs(cls.props or {}) do names[#names + 1] = k end
        cls = cls.parent and classes[cls.parent]
    end
    table.sort(names)
    return table.concat(names, ", ")
end

local state = setmetatable({}, { __mode = "k" })   -- proxy -> property values
Core.destroyed = setmetatable({}, { __mode = "k" }) -- proxies whose object is gone
Core.state = state
local instanceMeta = {}

local function deadCheck(self, key)
    local why = Core.destroyed[self]
    if why and key ~= "isValid" then
        error("rs3testkit: " .. instanceClass[self].name .. "." .. tostring(key) .. " read after " .. why, 3)
    end
end

instanceMeta.__index = function(self, key)
    deadCheck(self, key)
    local cls = instanceClass[self]
    local m = findMethod(cls, key)
    if m then return m end
    local p = findProp(cls, key)
    if p then
        local v = state[self][key]
        if v == nil and p.read then return p.read(self) end
        return v
    end
    Core.missing(cls.name .. "." .. tostring(key), isDocumented(cls, key), "Known properties: " .. propNames(cls) .. ".")
end

instanceMeta.__newindex = function(self, key, value)
    deadCheck(self, key)
    local cls = instanceClass[self]
    local p = findProp(cls, key)
    if not p then
        if findMethod(cls, key) then
            error("rs3testkit: " .. cls.name .. "." .. tostring(key) .. " is a method and cannot be assigned", 2)
        end
        error("rs3testkit: " .. cls.name .. " has no property '" .. tostring(key) .. "'" ..
            (isDocumented(cls, key) and " mocked yet (it is documented)" or "") ..
            ". Known properties: " .. propNames(cls) .. ".", 2)
    end
    if p.reject then error(p.reject, 2) end
    if p.readonly then error("rs3testkit: " .. cls.name .. "." .. key .. " is read-only", 2) end
    if p.type and not Core.typeOk(value, p.type) then
        error(string.format("sol: bad argument into '%s.%s' (rs3testkit: expected %s, got %s)",
            cls.name, key, p.type, Core.typeName(value)), 2)
    end
    state[self][key] = value
    if p.onSet then p.onSet(self, value) end
end

instanceMeta.__tostring = function(self)
    local cls = instanceClass[self]
    if cls.tostring then return cls.tostring(self) end
    return "sol." .. (cls.native or cls.name) .. ": " .. string.format("%p", state[self])
end

local function wrapMethod(className, name, spec)
    local path = className .. ":" .. name
    return function(self, ...)
        if not isA(self, className) then
            error("rs3testkit: " .. path .. " is a method: call it with ':', not '.'", 2)
        end
        if Core.destroyed[self] then
            error("rs3testkit: " .. path .. " called on a component that was destroyed", 2)
        end
        local n = select("#", ...)
        local args = { ... }
        if spec.check then spec.check(path, args, n) else Core.checkArgs(path, spec.params, args, n) end
        record(path, args)
        return spec.impl(self, ...)
    end
end

function Core.class(name, def)
    def.name = name
    def.documentedSet = {}
    for _, k in ipairs(def.documented or {}) do def.documentedSet[k] = true end
    def.wrapped = {}
    for mname, spec in pairs(def.methods or {}) do
        def.wrapped[mname] = wrapMethod(name, mname, spec)
        def.documentedSet[mname] = true
    end
    for pname in pairs(def.props or {}) do def.documentedSet[pname] = true end
    classes[name] = def
    return def
end

function Core.getClass(name) return classes[name] end

-- Creates an instance with defaults, then `init` values (bypassing readonly).
function Core.new(className, init)
    local cls = classes[className]
    if not cls then error("rs3testkit internal: unknown class " .. className, 2) end
    local proxy = setmetatable({}, instanceMeta)
    instanceClass[proxy] = cls
    local values = {}
    local c = cls
    while c do
        for k, p in pairs(c.props or {}) do
            if values[k] == nil and p.default ~= nil then
                local d = p.default
                if type(d) == "function" then d = d() end
                values[k] = d
            end
        end
        c = c.parent and classes[c.parent]
    end
    for k, v in pairs(init or {}) do values[k] = v end
    state[proxy] = values
    return proxy
end

-- Sets a property without the readonly/type checks (for the kit's fixtures).
function Core.setRaw(proxy, key, value) state[proxy][key] = value end
function Core.getRaw(proxy, key) return state[proxy][key] end
function Core.classOf(proxy) local c = instanceClass[proxy]; return c and c.name end

-- Add or replace a method on a class from a spec (kit.mockMethod).
function Core.setMethod(className, name, impl)
    local cls = classes[className]
    if not cls then error("rs3testkit: unknown class " .. tostring(className), 2) end
    cls.wrapped[name] = wrapMethod(className, name, { impl = impl })
    cls.documentedSet[name] = true
end

---------------------------------------------------------------------------
-- Enums
---------------------------------------------------------------------------
-- Real client enums (ui.AlignMode, ui.ModelType, ...) keep their members in
-- the metatable __index, so pairs() lists only FromID. The kit does the same,
-- so code that iterates an enum behaves as it will in the client.
-- `listed = true` makes members visible to pairs (ui.Hook is a plain table).
-- Unknown members raise an error; the real client returns nil, which turns a
-- typo such as ui.AlignMode.LEFT into a silent bug.
function Core.enum(path, members, opts)
    opts = opts or {}
    local byValue = {}
    for k, v in pairs(members) do byValue[v] = k end
    local function fromID(n)
        local name = byValue[n]
        if name == nil then return nil end
        return name
    end
    local visible = {}
    if opts.listed then for k, v in pairs(members) do visible[k] = v end end
    visible.FromID = fromID
    return setmetatable(visible, {
        __index = function(_, key)
            local v = members[key]
            if v ~= nil then return v end
            Core.missing(path .. "." .. tostring(key), false,
                "(The real client returns nil for unknown enum members.)")
        end,
        __newindex = function(_, key)
            error("rs3testkit: enum " .. path .. " is read-only (tried to set " .. tostring(key) .. ")", 2)
        end,
        __kit = { path = path, members = members },
    })
end

---------------------------------------------------------------------------
-- id tables
---------------------------------------------------------------------------
-- In the client, id.Font, id.StyleSheet, id.Component, ... map numbers to
-- names when iterated (pairs gives 10 = "BUTTON_ACCORDION_24PX_MOBILE"), and
-- a name gives its number. The real tables are large game data. The kit
-- seeds them with entries seen in a live client, and `resolver` (when the
-- run has a local clone of the LuaLS stubs, see stubs.py) looks up the rest:
--   resolver.number(kind, name) -> number | nil
--   resolver.name(kind, number) -> name | nil
-- A name found nowhere raises an error instead of returning nil.
-- pairs() lists only the entries looked up or seeded so far.
function Core.idTable(path, entries, resolver)
    local kind = string.gsub(path, "^id%.", "")
    local byName = {}
    local t = {}
    for name, number in pairs(entries) do
        byName[name] = number
        rawset(t, number, name)
    end
    local function fromID(n)
        local name = rawget(t, n)
        if name == nil and resolver and resolver.active then
            name = resolver.name(kind, n)
            if name ~= nil then byName[name] = n; rawset(t, n, name) end
        end
        return name
    end
    return setmetatable(t, {
        __index = function(_, key)
            local v = byName[key]
            if v ~= nil then return v end
            if key == "FromID" then return fromID end
            if type(key) == "number" then return fromID(key) end
            if resolver and resolver.active then
                v = resolver.number(kind, key)
                if v ~= nil then
                    byName[key] = v
                    rawset(t, v, key)
                    return v
                end
            end
            Core.missing(path .. "." .. tostring(key), false,
                ((resolver and resolver.active) and "It is not in the stub id tables either. " or
                    "The kit ships only part of this game table; run with --ids <clone of runescape-api-stubs> " ..
                    "for the full tables, or ") ..
                "add it in your spec: kit.ids.add(\"" .. kind .. "\", \"" .. tostring(key) .. "\", <number>).")
        end,
        __kit = { path = path, byName = byName },
    })
end

function Core.idAdd(t, name, number)
    local mt = getmetatable(t)
    mt.__kit.byName[name] = number
    rawset(t, number, name)
end

return Core
