-- sandbox.lua: loads plugins the way the client does, each in its own globals.
--
-- In the client every plugin has its own root folder. `require("views")`
-- loads views.lua from that root, and a dependency listed in plugin.json
-- ("dependencies": { "ExamineData": "examine-data" }) is visible to the
-- dependent plugin as a global named by its key (ExamineData), holding
-- whatever the dependency's main.lua returned.
--
-- The kit gives each plugin an environment table: its own globals, which
-- fall back to the shared game API (Player, ui, Event, ...) and the Lua
-- functions the sandbox keeps. Reading a global that exists nowhere gives
-- nil, as in the client, and is reported as an "undefined-global" lint so a
-- typo shows up in the run (kit.sandbox.strictGlobals = true makes it raise).

local Core = require("core")

local Sandbox = {}

-- Lua globals a plugin can use. The client's exact list is not published in
-- full; `os` and `io` are removed here (a live check found no os.clock), and
-- `load` is kept (it exists in the live client).
Sandbox.LUA_GLOBALS = {
    "assert", "error", "getmetatable", "ipairs", "load", "next", "pairs", "pcall",
    "rawequal", "rawget", "rawlen", "rawset", "select", "setmetatable", "tonumber",
    "tostring", "type", "xpcall", "_VERSION",
    "string", "table", "math", "utf8", "coroutine",
}

-- Globals that exist in standard Lua but not in the plugin sandbox. Reading
-- one gets a specific message rather than the generic undefined-global one.
Sandbox.REMOVED = {
    io = true, os = true, debug = true, dofile = true, loadfile = true,
    package = true, require = false, collectgarbage = true,
}

local hostLoadfile = loadfile
local hostOpen = io.open

Sandbox.strictGlobals = false     -- true: reading an undefined global raises
Sandbox.console = {}        -- every line any plugin printed: { plugin, text }
Sandbox.echo = false        -- also write plugin prints to the runner's output
Sandbox.write = print       -- replaced by the host so output stays in order
Sandbox.api = {}            -- shared game API globals, filled by the mocks

local function fileExists(path)
    local f = hostOpen(path, "rb")
    if f then f:close(); return true end
    return false
end

-- Builds the globals table one plugin sees.
local function makeEnv(plugin)
    local env = {}
    local base = {}
    for _, name in ipairs(Sandbox.LUA_GLOBALS) do base[name] = _G[name] end

    base.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        local line = table.concat(parts, "\t")
        Sandbox.console[#Sandbox.console + 1] = { plugin = plugin.name, text = line }
        if Sandbox.echo then Sandbox.write("    [" .. plugin.name .. "] " .. line) end
    end

    -- load() compiles into this plugin's globals unless told otherwise.
    base.load = function(chunk, name, mode, chunkEnv)
        if mode ~= nil and mode ~= "t" then
            return nil, "rs3testkit: only text chunks can be loaded in the sandbox"
        end
        return load(chunk, name, "t", chunkEnv or env)
    end

    base.require = function(name)
        return plugin.require(name)
    end

    base._G = env

    setmetatable(env, {
        __index = function(_, key)
            local v = base[key]
            if v ~= nil then return v end
            v = plugin.depGlobals[key]
            if v ~= nil then return v end
            v = plugin.ownApi[key]          -- per-plugin API objects (PersistentDB, Plugin)
            if v ~= nil then return v end
            v = Sandbox.api[key]
            if v ~= nil then return v end
            if plugin.optionalNil[key] then return nil end
            -- In the client an unset global is nil, and plugins rely on that
            -- (`count = (count or 0) + 1`, `if os then`). The kit returns nil
            -- too, and reports the name, so a typo still shows up in the run.
            local what = Sandbox.REMOVED[key] and "is not available in the plugin sandbox" or "is not defined"
            if Sandbox.strictGlobals then
                error("rs3testkit: global '" .. tostring(key) .. "' " .. what ..
                    " (strict mode: kit.sandbox.strictGlobals = true)", 2)
            end
            local info = debug.getinfo(2, "Sl")
            local where = info and ((string.match(info.short_src, "[^/\\]+$") or info.short_src) .. ":" .. tostring(info.currentline)) or "?"
            Core.warn("undefined-global", "plugin '" .. plugin.name .. "' read global '" .. tostring(key) ..
                "', which " .. what .. " (nil), at " .. where)
            return nil
        end,
    })
    return env
end

-- plugin = { name, dir, key (dependency key or nil), manifest }
-- Adds plugin.env, plugin.require and plugin.loaded.
function Sandbox.prepare(plugin)
    plugin.depGlobals = plugin.depGlobals or {}
    plugin.ownApi = plugin.ownApi or {}
    -- Optional dependencies that are not installed read as nil, without the
    -- strict-globals error (plugins test them with `if Name then`).
    plugin.optionalNil = {}
    for _, key in ipairs(plugin.optionalMissing or {}) do plugin.optionalNil[key] = true end
    plugin.loaded = {}
    plugin.loading = {}
    plugin.env = makeEnv(plugin)

    -- Modules resolve inside the plugin root only. "a.b" and "a/b" both mean
    -- a/b.lua. A module is run once; later requires return the same value.
    function plugin.require(name)
        if type(name) ~= "string" then error("require: module name must be a string", 2) end
        local rel = string.gsub(name, "%.", "/")
        local cached = plugin.loaded[rel]
        if cached ~= nil then return cached end
        if plugin.loading[rel] then
            error("rs3testkit: require loop: '" .. name .. "' is required again while it is still loading", 2)
        end
        local path = plugin.dir .. "/" .. rel .. ".lua"
        if not fileExists(path) then
            error("module '" .. name .. "' not found in plugin '" .. plugin.name .. "' (looked for " .. path .. ")", 2)
        end
        local fn, err = hostLoadfile(path, "t", plugin.env)
        if not fn then error(err, 2) end
        plugin.loading[rel] = true
        local ok, result = pcall(fn, name)
        plugin.loading[rel] = nil
        if not ok then error(result, 0) end
        if result == nil then result = true end
        plugin.loaded[rel] = result
        return result
    end

    return plugin
end

-- Runs a plugin's main.lua and returns what it returned.
function Sandbox.runMain(plugin)
    local path = plugin.dir .. "/main.lua"
    if not fileExists(path) then
        error("rs3testkit: plugin '" .. plugin.name .. "' has no main.lua in " .. plugin.dir, 0)
    end
    local fn, err = hostLoadfile(path, "t", plugin.env)
    if not fn then error(err, 0) end
    local result = fn()
    plugin.loaded["main"] = result == nil and true or result
    return result
end

return Sandbox
