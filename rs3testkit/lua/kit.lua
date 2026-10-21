-- kit.lua: what spec files see as the global `kit`.
--
-- The kit owns a fake game. Specs arrange it (player levels, inventories,
-- NPCs around the player, saved settings), start the plugin, then drive it
-- (ticks, events, right-click menus, button presses) and read what it did
-- (components on screen, console lines, HTTP requests, saved settings).
--
--   kit.player.set{ levels = { MINING = 50 } }
--   kit.start()                          -- runs main.lua (and dependencies)
--   kit.tick(3)                          -- three logic ticks
--   local menu = kit.menu.open{ kit.menu.npcEntry{ id = 11240, name = "Goblin" } }
--   menu:select("Advanced Examine")
--   expect(kit.ui.texts()).toContain("42 drops")
--
-- Each part lives in mock/*.lua; this file wires them together and runs
-- spec files.

local Core = require("core")
local Sandbox = require("sandbox")
local Spec = require("spec")

local kit = {}

kit.core = Core
kit.sandbox = Sandbox
kit.show = Spec.show

kit.console = {}     -- filled below and by mock/misc.lua

-- Game state and API mocks. Each module adds its globals to Sandbox.api and
-- its fixtures to kit.
local modules = { "vector", "ids", "perms", "events", "game", "ui", "persistentdb", "http", "misc" }
for _, name in ipairs(modules) do
    local m = require(name)
    m.install(Sandbox.api, kit)
end

---------------------------------------------------------------------------
-- Plugins
---------------------------------------------------------------------------
local root          -- the plugin under test (descriptor from the host)
local started = false
local loadOrder = {}

local function prepareTree(desc)
    for i = 1, #desc.deps do prepareTree(desc.deps[i]) end
    Sandbox.prepare(desc)
    for _, m in ipairs(modules) do
        local mod = require(m)
        if mod.perPlugin then mod.perPlugin(desc, desc.ownApi, kit) end
    end
end

-- Runs dependencies first (depth first), then the plugin. A dependency's
-- main.lua return value becomes a global, named by its key, in the plugin
-- that depends on it.
local function startTree(desc, done)
    for i = 1, #desc.deps do
        local dep = desc.deps[i]
        if done[dep.dir] == nil then
            startTree(dep, done)
        end
        local value = done[dep.dir]
        if value == true then
            Core.warn("dependency-returns-nothing", "dependency '" .. dep.name .. "' main.lua returned nothing; " ..
                "'" .. dep.key .. "' will be true in " .. desc.name)
        end
        desc.depGlobals[dep.key] = value
    end
    local result = Sandbox.runMain(desc)
    if result == nil then result = true end
    done[desc.dir] = result
    loadOrder[#loadOrder + 1] = desc.name
    return result
end

-- Called by the host before any spec code runs.
function kit._setup(desc, echo)
    root = desc
    Sandbox.echo = echo and true or false
    prepareTree(root)
end

-- Starts the plugin under test: runs its dependencies' and its own main.lua.
-- Returns what main.lua returned. Arrange fixtures before calling it if the
-- plugin reads game state at load time.
function kit.start()
    if started then error("kit.start(): the plugin is already running in this spec file", 2) end
    started = true
    local done = {}
    return startTree(root, done)
end

function kit.started() return started end

-- The plugin's own globals (what its code defined without `local`), as a
-- plain view: a name the plugin never set reads nil here, without the
-- strict-globals error the plugin itself would get.
local function globalsView(env)
    return setmetatable({}, {
        __index = function(_, k) return rawget(env, k) end,
        __newindex = function(_, k, v) rawset(env, k, v) end,
        __pairs = function() return next, env, nil end,
    })
end

function kit.env(name)
    if name == nil then return globalsView(root.env) end
    local function find(d)
        if d.name == name or d.key == name then return d end
        for i = 1, #d.deps do local f = find(d.deps[i]); if f then return f end end
    end
    local d = find(root)
    if not d then error("kit.env: no plugin or dependency named " .. tostring(name), 2) end
    return globalsView(d.env)
end

-- The plugin's own modules, as `require` inside it would load them.
function kit.require(name) return root.require(name) end

function kit.manifest() return root.manifest end
function kit.pluginName() return root.name end
function kit.loadOrder() return loadOrder end

-- Replace a function in a game API namespace for this spec file, e.g.
--   kit.mock("Player.GetRunEnergy", function() return 42 end)
function kit.mock(path, value)
    local ns, name = string.match(path, "^(.*)%.([^%.]+)$")
    if not ns then error("kit.mock: path must look like Namespace.member", 2) end
    local target = Sandbox.api
    for part in string.gmatch(ns, "[^%.]+") do
        target = target[part]
        if target == nil then error("kit.mock: no API namespace " .. ns, 2) end
    end
    if not Core.namespaceStore(target) then
        error("kit.mock: " .. ns .. " is not a mock namespace (use kit.mockMethod for classes)", 2)
    end
    Core.setMember(target, name, value)
end

-- Add or replace a method on an API class, e.g.
--   kit.mockMethod("ui.Canvas", "AddLine", function(self, ...) end)
kit.mockMethod = Core.setMethod

---------------------------------------------------------------------------
-- Console, lint and trace
---------------------------------------------------------------------------

-- Every line printed by any plugin, as strings ("[plugin] text" if all = true).
function kit.console.lines(all)
    local out = {}
    for _, l in ipairs(Sandbox.console) do
        out[#out + 1] = all and ("[" .. l.plugin .. "] " .. l.text) or l.text
    end
    return out
end

function kit.console.clear() Sandbox.console = {} end

-- Fails if any console line contains `needle` (default "ERROR"): plugins
-- that catch their own errors and print them would otherwise pass silently.
function kit.console.expectNo(needle)
    needle = needle or "ERROR"
    for _, l in ipairs(Sandbox.console) do
        if string.find(l.text, needle, 1, true) then
            error("console has a line containing " .. string.format("%q", needle) .. ": " .. l.text, 2)
        end
    end
end

function kit.warnings() return Core.warnings end

-- The last `n` API calls the plugin made (all if n is nil).
function kit.trace(n)
    local t = Core.trace
    if n == nil or n >= #t then return t end
    local out = {}
    for i = #t - n + 1, #t do out[#out + 1] = t[i] end
    return out
end

function kit.calls(api)
    local n = 0
    for _, c in ipairs(Core.trace) do if c.api == api then n = n + 1 end end
    return n
end

---------------------------------------------------------------------------
-- Running a spec file (called by the host)
---------------------------------------------------------------------------
-- Output from specs and echoed plugin prints goes through the host (Python),
-- so it stays in order with the runner's own lines.
kit._write = function(line) print(line) end
function kit._setWriter(fn) kit._write = fn; Sandbox.write = fn end

local function specEnv()
    local env = { kit = kit, test = Spec.test, expect = Spec.expect }
    env.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        kit._write(table.concat(parts, "\t"))
    end
    -- Specs see the game API as the plugin under test does (its own
    -- PersistentDB, Plugin, Event, ...), then the full host Lua library.
    return setmetatable(env, { __index = function(_, k)
        local v = root.ownApi[k]
        if v ~= nil then return v end
        v = Sandbox.api[k]
        if v ~= nil then return v end
        return _G[k]
    end })
end

function kit._runSpec(path, displayName)
    Spec.setFile(displayName)
    local fn, err = loadfile(path, "t", specEnv())
    if not fn then error(err, 0) end
    fn()
    local seen = 0
    return Spec.run(function(result)
        -- Lints that only make sense once a test has finished (UI state).
        if kit.ui and kit.ui._lintAfterTest then kit.ui._lintAfterTest() end
        -- Lint warnings raised while this test ran belong to it.
        local mine = {}
        for i = seen + 1, #Core.warnings do
            local w = Core.warnings[i]
            mine[#mine + 1] = w.code .. ": " .. w.message
        end
        seen = #Core.warnings
        result.warnings = mine
    end)
end

function kit._summary()
    return {
        http = kit.http._usage(),
        consoleLines = #Sandbox.console,
    }
end

return kit
