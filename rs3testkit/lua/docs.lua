-- docs.lua: builds strict mock namespaces and classes from api_docs.lua.
--
-- api_docs.lua is generated from the official API docs (tools/extract_api.py)
-- and lists every documented function, method, property, enum and event
-- payload with its parameter types. This module turns that into:
--   * argument checks: a call must match one documented overload (count and
--     types), and "." / ":" must match the docs;
--   * class property schemas: names, types, and which are read-only;
--   * "documented but not mocked" errors for anything the kit has no
--     behaviour for yet.
--
-- The kit's own behaviour (what a function returns) is written by hand in
-- the mock modules and passed in as `impls`.

local Core = require("core")
local Data = require("api_docs")

local Docs = {}
Docs.data = Data

-- Doc type name -> kit type spec (see Core.typeOk).
local SCALARS = {
    Int = "number", Integer = "number", Uint = "number", Uint8 = "number", Uint16 = "number",
    Uint64 = "number", Long = "number", uint8 = "number", int = "number", float = "number", Float = "number", Number = "number", number = "number",
    String = "string", PluginURL = "string", IntegerString = "number|string",
    Bool = "boolean", Boolean = "boolean", bool = "boolean",
    ["function"] = "function", Function = "function", Table = "table", Args = "any",
}
local ALIASES = { ["Component<T>"] = "ui.Component", ["ui.Component<T>"] = "ui.Component", Component = "ui.Component" }

function Docs.spec(docType)
    if docType == nil or docType == "" or docType == "?" then return "any" end
    local optional = string.sub(docType, -1) == "?"
    local t = optional and string.sub(docType, 1, -2) or docType
    t = string.gsub(t, "^%s+", "")
    t = string.gsub(t, "%s+$", "")
    local out
    if SCALARS[t] then
        out = SCALARS[t]
    elseif string.find(t, "^%[") or string.find(t, "^{") then
        out = "table"
    elseif string.find(t, "/", 1, true) or string.find(t, "|", 1, true) then
        out = "any"
    elseif Data.enums[t] or t == "ui.Hook" or t == "PluginPermissions" then
        out = "number|string"
    else
        -- A class name; checked only once the kit defines that class.
        out = ALIASES[t] or t
    end
    return optional and (out .. "?") or out
end

-- Methods and properties of a type, including its documented parents.
function Docs.typeInfo(name)
    return Data.types[name]
end

local function chain(name)
    local out = {}
    local t = Data.types[name]
    while t do
        out[#out + 1] = t
        t = t.parent and Data.types[t.parent]
    end
    return out
end

function Docs.method(typeName, name)
    for _, t in ipairs(chain(typeName)) do
        if t.methods[name] then return t.methods[name] end
    end
end

-- A check(path, args, n) that passes when the call matches any documented
-- overload. Signatures the extractor could not parse accept anything.
function Docs.checker(typeName, name, skipSelf)
    local m = Docs.method(typeName, name)
    if not m then return nil end
    local overloads = {}
    for _, sig in ipairs(m.sigs) do
        if sig.unparsed then return nil end
        local specs, varargs = {}, false
        for _, p in ipairs(sig.params) do
            if p == "..." then varargs = true; break end
            specs[#specs + 1] = Docs.spec(p)
        end
        overloads[#overloads + 1] = { specs = specs, varargs = varargs }
    end
    return function(path, args, n)
        for _, o in ipairs(overloads) do
            local required = 0
            for i, s in ipairs(o.specs) do if string.sub(s, -1) ~= "?" then required = i end end
            local ok = n >= required and (o.varargs or n <= #o.specs)
            if ok then
                for i, s in ipairs(o.specs) do
                    if not Core.typeOk(args[i], s) then ok = false; break end
                end
            end
            if ok then return end
        end
        local shown = {}
        for i, o in ipairs(overloads) do shown[i] = "(" .. table.concat(o.specs, ", ") .. (o.varargs and ", ..." or "") .. ")" end
        local got = {}
        for i = 1, n do got[i] = Core.typeName(args[i]) end
        error(string.format("sol: no matching function call takes this number of arguments and the specified types " ..
            "(rs3testkit: %s documented as %s, got (%s))", path, table.concat(shown, " or "), table.concat(got, ", ")), 3)
    end
end

---------------------------------------------------------------------------
-- Namespaces
---------------------------------------------------------------------------
-- Docs.namespace("Player", { GetRunEnergy = function() ... end }, extras)
-- Every documented "." function of the type is known; ones without an impl
-- raise "documented but not mocked". `extras` are plain values (enums,
-- sub-tables) added as they are.
function Docs.namespace(name, impls, extras)
    local info = Data.types[name]
    local documented, members = {}, {}
    if info then
        for mname, m in pairs(info.methods) do
            if m.sep == "." then documented[#documented + 1] = mname end
        end
    end
    for mname, fn in pairs(impls or {}) do
        members[mname] = Core.static(nil, fn, Docs.checker(name, mname) or function() end)
    end
    for k, v in pairs(extras or {}) do members[k] = v end
    return Core.namespace(name, { documented = documented, members = members })
end

---------------------------------------------------------------------------
-- Classes
---------------------------------------------------------------------------
-- Default value for a property of a scalar doc type. Object-typed
-- properties have no default: reading one the kit never set is an error.
local function scalarDefault(docType)
    local s = Docs.spec(docType)
    s = string.gsub(s, "%?$", "")
    if s == "number" then return 0 end
    if s == "boolean" then return false end
    if s == "string" then return "" end
    return nil
end

-- Void "visual" methods: calling them can only change how something is
-- drawn, which the kit cannot see, so by default they are recorded (in
-- kit.ui.calls) rather than raising. Methods that return something are
-- never given a fake answer.
local RECORDABLE = { "^Set", "^AlignTo$", "^MoveTo", "^UpdateLayout$", "^Reset", "^Restart" }
local function recordable(name, m)
    for _, sig in ipairs(m.sigs) do
        if sig.returns and sig.returns ~= "" then return false end
    end
    for _, pat in ipairs(RECORDABLE) do
        if string.find(name, pat) then return true end
    end
    return false
end
Docs.recordedCalls = setmetatable({}, { __mode = "k" })   -- proxy -> { {name, args}, ... }

-- Docs.class("ui.Text", {
--     impls = { SetPos = function(self, x, y) ... end },   -- method behaviour
--     defaults = { clickthrough = true },                   -- property defaults
--     props = { extraProp = { type = "number" } },          -- kit-only/undocumented props
--     overrides = { rotation = { reject = "..." } },        -- per-property changes
--     recordSetters = true,                                 -- see RECORDABLE
--     strict = true,       -- no 0/""/false defaults: unset properties raise
--     native = "jag::ui::Text",
-- })
-- Defines the class for Core (with its documented parent) and returns a
-- namespace holding its "." functions (constructors such as new).
function Docs.class(name, opts)
    opts = opts or {}
    local info = Data.types[name] or { methods = {}, props = {} }
    local props = {}
    for pname, p in pairs(info.props) do
        local spec = Docs.spec(p.type)
        local default = opts.defaults and opts.defaults[pname]
        if default == nil and not opts.strict then default = scalarDefault(p.type) end
        local prop = { type = spec, readonly = p.ro, default = default }
        -- Documented as "name?" (may be nil): unset reads nil, as in the client.
        if default == nil and not p.optional then
            -- A property the kit has no value for: game data the fixture did
            -- not supply, or an object type the kit does not model.
            prop.read = function(self)
                Core.missing(name .. "." .. pname, true, opts.missingHint or
                    "(The kit has no value for this property; set one in a fixture or mock it.)")
            end
        end
        props[pname] = prop
    end
    for pname, p in pairs(opts.props or {}) do props[pname] = p end
    for pname, o in pairs(opts.overrides or {}) do
        props[pname] = props[pname] or {}
        for k, v in pairs(o) do props[pname][k] = v end
        -- A computed property: a stored default would hide the reader.
        if o.read and o.default == nil then props[pname].default = nil end
    end

    local methods, documented = {}, {}
    for mname, m in pairs(info.methods) do
        if m.sep == ":" then
            local impl = opts.impls and opts.impls[mname]
            if impl then
                methods[mname] = { impl = impl, check = Docs.checker(name, mname) }
            elseif opts.recordSetters and recordable(mname, m) then
                methods[mname] = {
                    check = Docs.checker(name, mname),
                    impl = function(self, ...)
                        local log = Docs.recordedCalls[self] or {}
                        Docs.recordedCalls[self] = log
                        log[#log + 1] = { name = mname, args = table.pack(...) }
                    end,
                }
            else
                documented[#documented + 1] = mname
            end
        end
    end
    for mname, impl in pairs(opts.impls or {}) do
        if not methods[mname] and not (info.methods[mname] and info.methods[mname].sep == ".") then
            methods[mname] = { impl = impl, check = Docs.checker(name, mname) }
        end
    end
    -- Parent methods the parent's own definition recorded are inherited
    -- through Core's class chain; documented ones without impls stay missing.
    Core.class(name, {
        parent = opts.parent or info.parent,
        native = opts.native,
        tostring = opts.tostring,
        props = props,
        methods = methods,
        documented = documented,
    })

    local statics = {}
    for mname, m in pairs(info.methods) do
        if m.sep == "." and opts.statics and opts.statics[mname] then
            statics[mname] = opts.statics[mname]
        end
    end
    for mname, fn in pairs(opts.statics or {}) do statics[mname] = fn end
    local documentedStatics = {}
    for mname, m in pairs(info.methods) do if m.sep == "." then documentedStatics[#documentedStatics + 1] = mname end end
    local members = {}
    for mname, fn in pairs(statics) do
        members[mname] = Core.static(nil, fn, Docs.checker(name, mname) or function() end)
    end
    for k, v in pairs(opts.extras or {}) do members[k] = v end
    return Core.namespace(name, { documented = documentedStatics, members = members })
end

---------------------------------------------------------------------------
-- Enums
---------------------------------------------------------------------------
-- Real values come from the docs where published, else from a live client
-- (passed as `observed`), else they are numbered by the kit in doc order
-- and marked as such in Docs.kitAssigned.
Docs.kitAssigned = {}

function Docs.enum(name, observed, opts)
    local e = Data.enums[name]
    local members = {}
    if e then
        for k, v in pairs(e.values) do members[k] = v end
    end
    for k, v in pairs(observed or {}) do members[k] = v end
    if e then
        -- Unknown values: the member's position in the doc list (0-based),
        -- which matches every live value seen so far, else the next free number.
        local used = {}
        for _, v in pairs(members) do used[v] = true end
        local nextValue = 0
        for _, v in pairs(members) do if v >= nextValue then nextValue = v + 1 end end
        for i, n in ipairs(e.names) do
            if members[n] == nil then
                local v = i - 1
                if used[v] then v = nextValue; nextValue = nextValue + 1 end
                members[n] = v
                used[v] = true
                Docs.kitAssigned[name .. "." .. n] = true
            end
        end
    end
    return Core.enum(name, members, opts)
end

return Docs
