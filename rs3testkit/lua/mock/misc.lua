-- Plugin, input devices, camera, chat, audio, core globals, and the
-- documented namespaces the kit does not mock yet.
--
-- Fixtures:
--   kit.permissions.grant("httpAccess") / revoke(...)
--   kit.mouse.set(x, y)                 Mouse.GetX/GetY/GetPosition
--   kit.keyboard.hold{ "SHIFT", "A" }   Keyboard.Is*Down / GetGameKeysDown
--   kit.keyboard.press("A")             fires KeyDown, KeyTyped, KeyUp
--   kit.camera.set{ position = {x, y, z}, focus = {x, y, z} }
--   kit.chat.receive{ text = "...", type = "PUBLIC", sender = "Zezima" }
--   kit.chat.messages()                 what the plugin posted with Chat.AddMessage
--   kit.audio.played()                  sounds the plugin started
--   kit.console.commands()              ExecuteConsoleCommand calls
--   kit.deps.setEnabled(key, on)        optional dependency toggled

local Core = require("core")
local Docs = require("docs")
local Events = require("events")
local Perms = require("perms")
local Sandbox = require("sandbox")
local Vector = require("vector")

local M = {}

local rootDesc            -- the plugin under test
local permEnum            -- PluginPermissions (enum value <-> name)

local function permName(p)
    if type(p) == "string" then return p end
    local name = permEnum and permEnum.FromID(p)
    if name == nil then error("rs3testkit: unknown PluginPermissions value " .. tostring(p), 3) end
    return name
end

---------------------------------------------------------------------------
-- Plugin (one object per plugin)
---------------------------------------------------------------------------
local resourceEnum

local function defineResources()
    Docs.class("PluginResource", {
        native = "jag::plugin::PluginResource",
        props = {
            path = { type = "string", readonly = true },
            loaded = { type = "boolean", readonly = true, default = false },
            inUse = { type = "boolean", readonly = true, default = false },
            kind = { type = "string", readonly = true },
        },
        impls = {
            Load = function(self)
                Core.setRaw(self, "loaded", true)
                return resourceEnum.success
            end,
            Unload = function(self) Core.setRaw(self, "loaded", false) end,
        },
    })
end

-- desc.resources is a nested table of file paths built by the host from the
-- plugin's resources/ folder (keys are file names without the extension).
local function resourceTree(node)
    local out = {}
    for k, v in pairs(node or {}) do
        if type(v) == "table" then
            out[k] = resourceTree(v)
        else
            local kind = string.match(v, "%.(%w+)$")
            out[k] = Core.new("PluginResource", { path = v, kind = kind == "ogg" and "audio" or "image" })
        end
    end
    return out
end

local function pluginFor(desc)
    local urls = {}
    for k, v in pairs((desc.manifest or {}).urls or {}) do urls[k] = v end
    local urlTable = setmetatable({}, {
        __index = function(_, k)
            if urls[k] then return urls[k] end
            error("rs3testkit: Plugin.urls." .. tostring(k) .. " is not declared in plugin.json \"urls\"", 2)
        end,
        __newindex = function() error("rs3testkit: Plugin.urls is read-only", 2) end,
        __pairs = function() return next, urls, nil end,
    })
    return Core.namespace("Plugin", {
        members = {
            HasPermission = Core.static(nil, function(p)
                local name = permName(p)
                if not Perms.isDeclared(desc.name, name) then
                    Core.warn("permission-undeclared", "plugin '" .. desc.name .. "' checks permission " .. name ..
                        " but does not request it in plugin.json, so it can never be granted")
                end
                return Perms.has(desc.name, name)
            end, Docs.checker("Plugin", "HasPermission")),
            urls = urlTable,
            resources = resourceTree(desc.resources),
        },
    })
end

---------------------------------------------------------------------------
-- formatStr: the fmtlib subset the kit understands
---------------------------------------------------------------------------
local function formatStr(fmt, ...)
    local args = table.pack(...)
    local auto = 0
    local function fmtOne(spec, v)
        if spec == "" then
            if type(v) == "number" and math.type(v) == "float" and v == math.floor(v) then return tostring(v) end
            if type(v) == "table" or type(v) == "function" or type(v) == "userdata" then return type(v) end
            return tostring(v)
        end
        local prec = string.match(spec, "^%.(%d+)f$")
        if prec then return string.format("%." .. prec .. "f", v) end
        if spec == "d" then return string.format("%d", v) end
        error("rs3testkit: formatStr option {:" .. spec .. "} is not mocked (only {}, {N}, {:.Nf}, {:d})", 4)
    end
    local out = string.gsub(fmt, "{(%d*):?([^}]*)}", function(index, spec)
        local i
        if index ~= "" then i = tonumber(index) + 1 else auto = auto + 1; i = auto end
        if i > args.n then error("rs3testkit: formatStr: no argument for {" .. index .. "}", 4) end
        return fmtOne(spec, args[i])
    end)
    return (string.gsub(out, "{{", "{"):gsub("}}", "}"))
end

---------------------------------------------------------------------------
-- Install
---------------------------------------------------------------------------
function M.install(api, kit)
    permEnum = api.PluginPermissions
    resourceEnum = api.PluginResourceLoadResult
    defineResources()

    -- Core globals.
    api.formatStr = formatStr
    local commands = {}
    api.ExecuteConsoleCommand = Core.static({ "string" }, function(cmd) commands[#commands + 1] = cmd end)
    kit.console.commands = function() return commands end
    api.log = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        Sandbox.console[#Sandbox.console + 1] = { plugin = "log", text = table.concat(parts, " ") }
    end

    -- Permissions.
    kit.permissions = {}
    local function toggle(name, on, plugin)
        local who = plugin or rootDesc.name
        local was = Perms.has(who, name)
        Perms.set(who, name, on)
        if Perms.isOptional(who, name) and was ~= on then
            Events.fire("OptionalPermissionChanged", { permissionName = name, enabled = on },
                nil, function(p) return p == who end)
        end
    end
    function kit.permissions.grant(name, plugin) toggle(name, true, plugin) end
    function kit.permissions.revoke(name, plugin) toggle(name, false, plugin) end
    function kit.permissions.has(name, plugin) return Perms.has(plugin or rootDesc.name, name) end

    -- Mouse.
    local mouse = { available = true, x = 0, y = 0 }
    api.Mouse = Docs.namespace("Mouse", {
        IsAvailable = function() return mouse.available end,
        GetX = function() return mouse.available and mouse.x or nil end,
        GetY = function() return mouse.available and mouse.y or nil end,
        GetPosition = function() return mouse.available and Vector.v2(mouse.x, mouse.y) or nil end,
    })
    kit.mouse = {}
    function kit.mouse.set(x, y) mouse.x, mouse.y = x, y end
    function kit.mouse.setAvailable(on) mouse.available = on end

    -- Keyboard.
    local keys = { available = true, blocked = false, down = {} }
    local GameKey = api.GameKey
    local function keyValue(k) return type(k) == "string" and GameKey[k] or k end
    local function down(name) return not keys.blocked and keys.down[GameKey[name]] == true end
    api.Keyboard = Docs.namespace("Keyboard", {
        IsAvailable = function() return keys.available end,
        IsBlocked = function() return keys.blocked end,
        IsShiftDown = function() return down("SHIFT") end,
        IsControlDown = function() return down("CONTROL") end,
        IsAltDown = function() return down("ALT") end,
        IsMetaDown = function() return not keys.blocked and keys.meta == true end,
        IsGameKeyDown = function(k) return not keys.blocked and keys.down[k] == true end,
        GetGameKeysDown = function()
            local out = {}
            if keys.blocked then return out end
            for k in pairs(keys.down) do out[#out + 1] = k end
            table.sort(out)
            return out
        end,
    })
    kit.keyboard = {}
    function kit.keyboard.hold(list)
        keys.down = {}
        for _, k in ipairs(list or {}) do
            if k == "META" then keys.meta = true else keys.down[keyValue(k)] = true end
        end
    end
    function kit.keyboard.block(on) keys.blocked = on end
    -- Fires KeyDown, KeyTyped (with `char`, default the key's letter) and KeyUp.
    function kit.keyboard.press(k, char, modifiers)
        local gk = keyValue(k)
        local name = type(k) == "string" and k or GameKey.FromID(k)
        local sys = api.SystemKey[name] or 0
        local stamp = Events.logicTick() * 20
        Events.fire("KeyDown", { isRepeat = false, gameKey = gk, systemKey = sys, modifiers = modifiers or 0, timestamp = stamp })
        Events.fire("KeyTyped", { char = char or (#name == 1 and string.byte(string.lower(name)) or 0), modifiers = modifiers or 0, timestamp = stamp })
        Events.fire("KeyUp", { gameKey = gk, systemKey = sys, modifiers = modifiers or 0, timestamp = stamp + 80 })
    end

    -- Camera.
    local camera = { available = true, position = { 0, 0, 0 }, focus = { 0, 0, 0 } }
    api.Camera = Docs.namespace("Camera", {
        IsAvailable = function() return camera.available end,
        GetPosition = function() local p = camera.available and camera.position or { 0, 0, 0 }; return Vector.v3(p[1], p[2], p[3]) end,
        GetFocusPosition = function() local p = camera.available and camera.focus or { 0, 0, 0 }; return Vector.v3(p[1], p[2], p[3]) end,
    })
    kit.camera = {}
    function kit.camera.set(t)
        if t.available ~= nil then camera.available = t.available end
        camera.position = t.position or camera.position
        camera.focus = t.focus or camera.focus
    end

    -- Chat: needs chatAccess; AddMessage is delivered as Event.ChatMessage
    -- (type PLUGIN) on the next logic tick, as documented.
    local posted, queued = {}, {}
    local function chatFilter(p) return Perms.has(p, "chatAccess") end
    table.insert(kit._tickHooks, function()
        local batch = queued
        queued = {}
        for _, m in ipairs(batch) do
            Events.fire("ChatMessage", m, nil, chatFilter)
        end
    end)
    -- Chat for one plugin (the permission is checked per plugin).
    M.chatFor = function(desc)
        return Docs.namespace("Chat", {
            AddMessage = function(message)
                if not Perms.has(desc.name, "chatAccess") then
                    error("rs3testkit: Chat.AddMessage needs the chatAccess permission, which plugin '" .. desc.name ..
                        "' does not have", 2)
                end
                posted[#posted + 1] = message
                queued[#queued + 1] = { chatMessage = message, senderNameUnfiltered = "", senderNameFiltered = "",
                    senderNameSimple = "", chatType = api.ChatType.PLUGIN, timestamp = 1792800000 }
            end,
        })
    end
    kit.chat = {}
    function kit.chat.messages() return posted end
    -- A message from the server: fired now, to plugins with chatAccess.
    function kit.chat.receive(t)
        local chatType = t.type or "PUBLIC"
        if type(chatType) == "string" then chatType = api.ChatType[chatType] end
        local sender = t.sender or ""
        return Events.fire("ChatMessage", {
            chatMessage = t.text or "", senderNameUnfiltered = sender, senderNameFiltered = sender,
            senderNameSimple = sender, chatType = chatType, timestamp = t.timestamp or 1792800000,
        }, nil, chatFilter)
    end

    -- Audio: sounds are recorded, not played.
    local played = {}
    Docs.class("audio.SoundInstance", {
        props = { isPlaying = { type = "boolean", default = false }, isPaused = { type = "boolean", default = false },
                  id = { type = "number", readonly = true }, _source = {}, _params = {} },
        impls = {
            Start = function(self) Core.setRaw(self, "isPlaying", true); Core.setRaw(self, "isPaused", false) end,
            Stop = function(self) Core.setRaw(self, "isPlaying", false) end,
            Pause = function(self) Core.setRaw(self, "isPaused", true) end,
            Resume = function(self) Core.setRaw(self, "isPaused", false) end,
        },
    })
    local nextSound = 0
    local audioNs = Docs.namespace("audio", {
        Play = function(source, params)
            nextSound = nextSound + 1
            local delayed = type(params) == "table" and (params.delayTick or 0) > 0
            local s = Core.new("audio.SoundInstance", { id = nextSound, isPlaying = not delayed, _source = source, _params = params })
            played[#played + 1] = { sound = s, source = source, params = params, tick = Events.logicTick() }
            return s
        end,
        Stop = function(id)
            for _, p in ipairs(played) do
                if Core.getRaw(p.sound, "id") == id then Core.setRaw(p.sound, "isPlaying", false) end
            end
        end,
        StopSoundsUsingResource = function(source)
            for _, p in ipairs(played) do
                if p.source == source then Core.setRaw(p.sound, "isPlaying", false) end
            end
        end,
    }, require("ids").enums().audio)
    api.audio = audioNs
    kit.audio = {}
    function kit.audio.played() return played end

    -- Optional dependencies switching on and off.
    kit.deps = {}
    function kit.deps.setEnabled(key, on)
        local env = rootDesc.env
        Events.fire("OptionalDependencyChanged", { pluginIdentifier = key, enabled = on }, nil,
            function(p) return p == rootDesc.name end)
        local ok, fn = pcall(function() return rawget(env, "PluginDependencyUpdate") end)
        if ok and type(fn) == "function" then
            fn({ pluginIdentifier = key, enabled = on })
        end
    end

    -- Documented namespaces with no kit behaviour yet: every documented
    -- member raises "documented but not mocked".
    for _, name in ipairs({ "ScreenConvert", "ShapeList", "Rect", "AABB", "Quaternion", "Matrix33" }) do
        api[name] = Docs.namespace(name, {})
    end
    api.game = Core.namespace("game", { documented = { "options" } })
end

function M.perPlugin(desc, ownApi)
    rootDesc = desc
    ownApi.Plugin = pluginFor(desc)
    ownApi.Chat = M.chatFor(desc)
end

return M
