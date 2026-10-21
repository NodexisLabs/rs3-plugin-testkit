-- devlink: dev-only troubleshooting bridge. NEVER submit this plugin.
--
-- Sends read-only game state to a local server (devlink/server.py on
-- 127.0.0.1:8765) and answers read-only commands it polls from there.
-- It cannot act in the game: the plugin API has no way to send input, and
-- every command below only reads.
--
-- Commands (sent with `python server.py cmd "<command>"`):
--   help                     list commands
--   ping                     round-trip check
--   state                    game state, world, ping, run energy, mouse
--   npcs [pattern]           nearby NPCs (wildcards * ?), max 60
--   inv <INV_NAME|id>        an inventory's contents (bank only after it was opened)
--   menu                     entries of the last opened right-click menu
--   dump <path>              members of a global, e.g. "config.NPC" or "Inventory"
--   eval <lua>               evaluate a Lua expression or statement (if load exists)
--   watch <event> [off]      stream an event: menuselect, gamestate, inventory, npcadded
--
-- Other dev plugins can log here too: list "devlink" in optionalDependencies
-- and call devlink.log(tag, data).

local json = require("json")

-- The server's key, written into devlink_key.lua by `rs3-dev.ps1 deploy` (never committed).
-- It returns a table: this client's require gave nil for a module returning a bare string.
local hasKey, keyModule = pcall(require, "devlink_key")
local KEY = hasKey and type(keyModule) == "table" and keyModule.key or nil
if type(KEY) ~= "string" or KEY == "" then
    print("[devlink] no usable devlink_key.lua (" .. tostring(keyModule) .. "): run  rs3-dev.ps1 deploy  then  prf  and  prl devlink")
    hasKey, KEY = false, nil
end
-- Every path carries the key so the server can tell this plugin from other programs.
local function keyed(path) return "/k/" .. KEY .. path end
local lastRefusedTick = -1e9

local POLL_TICKS = 50      -- poll for commands once a second (50 logic ticks/s)
local FLUSH_TICKS = 25     -- send buffered events twice a second
local MAX_NPCS = 60

local outbox = {}          -- encoded JSON lines waiting to be sent
local logSending, pollSending = false, false
local lastGameState = nil
local lastMenu = {}
local lastTick = 0
local lastPollErrorTick = 0
local pollOk = false
local lastHttp = nil       -- permission state last reported to the console

local function hasPermission()
    return Plugin.HasPermission(PluginPermissions.httpAccess)
end
local function hasHttp()
    return hasKey and hasPermission()
end

-- 401 means the key in key.lua differs from the server's: say so, every 30 s at most.
local function refused(request)
    if request.responseCode ~= 401 then return false end
    if lastTick - lastRefusedTick >= 1500 then
        lastRefusedTick = lastTick
        print("[devlink] key mismatch with the server: run  rs3-dev.ps1 deploy  then  prl devlink")
    end
    return true
end

-- Queues one event for the server; also echoes to the console.
local function send(kind, data)
    local event = { kind = kind, tick = lastTick, data = data }
    local ok, line = pcall(json.encode, event)
    if not ok then line = json.encode({ kind = "error", data = "encode failed: " .. tostring(line) }) end
    outbox[#outbox + 1] = line
end

local function flush()
    if logSending or #outbox == 0 or not hasHttp() then return end
    local body = table.concat(outbox, "\n")
    outbox = {}
    logSending = true
    HTTPRequest.new(Plugin.urls.devlink, keyed("/log")):Post(body, function(request)
        logSending = false
        if refused(request) then return end
        if not request.successful then
            print("[devlink] log POST failed: " .. tostring(request.errorInfo or request.responseCode))
        end
    end)
end

---------------------------------------------------------------------------
-- Describing game objects
---------------------------------------------------------------------------
-- Members of a table or of a userdata whose metatable exposes an __index table.
local function membersOf(value)
    if type(value) == "table" then return value end
    if type(value) == "userdata" then
        local ok, mt = pcall(getmetatable, value)
        if ok and type(mt) == "table" and type(mt.__index) == "table" then return mt.__index end
    end
    return nil
end

local function describeNpc(npc)
    local ok, result = pcall(function()
        return { uid = npc.uid, id = npc.config and npc.config.id, name = npc.displayName,
                 configName = npc.config and npc.config.configName, coord = tostring(npc.coordGrid) }
    end)
    return ok and result or { error = tostring(result) }
end

local function describeEntry(entry)
    local ok, result = pcall(function()
        local d = { verb = entry.verbText, subject = entry.subjectText,
                    actionType = entry.actionType, entryType = entry.actionEntryType,
                    verbType = entry.actionVerbType }
        if entry.npcData then d.npc = describeNpc(entry.npcData.entity) end
        if entry.locData then d.loc = { id = entry.locData.config.id, name = entry.locData.config.configName } end
        if entry.objData then d.obj = { id = entry.objData.config.id, name = entry.objData.config.configName } end
        return d
    end)
    return ok and result or { error = tostring(result) }
end

-- Resolves "a.b.c" starting from _G.
local function resolve(path)
    local value = _G
    for part in string.gmatch(path, "[^%.]+") do
        if value == nil then return nil end
        value = value[part]
    end
    return value
end

---------------------------------------------------------------------------
-- Commands (all read-only)
---------------------------------------------------------------------------
local commands = {}

function commands.help()
    local names = {}
    for name in pairs(commands) do names[#names + 1] = name end
    table.sort(names)
    return names
end

function commands.ping() return "pong" end

function commands.state()
    return {
        gameState = lastGameState,
        playerAvailable = Player.IsAvailable(),
        runEnergy = Player.IsAvailable() and Player.GetRunEnergy() or nil,
        worldAvailable = World.IsAvailable(),
        members = World.IsAvailable() and World.IsMembers() or nil,
        ping = World.GetPing(),
        mouse = Mouse.IsAvailable() and { Mouse.GetX(), Mouse.GetY() } or nil,
        logicTick = lastTick,
    }
end

function commands.npcs(pattern)
    local list = (pattern and pattern ~= "") and NPCList.ByName(pattern) or NPCList.All()
    local result = { count = #list, npcs = {} }
    for i = 1, math.min(#list, MAX_NPCS) do result.npcs[i] = describeNpc(list[i]) end
    return result
end

function commands.inv(arg)
    local key = tonumber(arg) or (config.Inv and config.Inv[arg])
    if key == nil then error("unknown inventory: " .. tostring(arg)) end
    local inv = Inventory.Find(key)
    if inv == nil then return "no such inventory loaded (the bank needs opening first)" end
    local members = membersOf(inv)
    local fields = {}
    if members then for k in pairs(members) do fields[#fields + 1] = tostring(k) end end
    table.sort(fields)
    -- The Inv API shape is not documented yet: report its members so the
    -- next step can call the right ones with eval.
    return { inv = tostring(inv), members = fields }
end

function commands.menu() return lastMenu end

function commands.dump(path)
    local value = resolve(path or "")
    local members = membersOf(value)
    if members == nil then return { type = type(value), value = tostring(value) } end
    local result = {}
    for k, v in pairs(members) do result[tostring(k)] = type(v) end
    return { type = type(value), members = result }
end

function commands.eval(code)
    if type(load) ~= "function" then error("load() is not available in this sandbox") end
    local chunk, err = load("return " .. code, "eval", "t", _G)
    if not chunk then chunk, err = load(code, "eval", "t", _G) end
    if not chunk then error(err) end
    local packed = table.pack(chunk())
    for i = 1, packed.n do
        local v = packed[i]
        if type(v) == "userdata" then
            local members = membersOf(v)
            local fields = {}
            if members then for k in pairs(members) do fields[#fields + 1] = tostring(k) end end
            table.sort(fields)
            packed[i] = { userdata = tostring(v), members = fields }
        end
    end
    packed.n = nil
    return packed
end

---------------------------------------------------------------------------
-- Watches: events streamed to the server while switched on
---------------------------------------------------------------------------
local watchers = {
    menuselect = { event = "MiniMenuEntrySelected",
                   summarise = function(e) return describeEntry(e.entry) end },
    gamestate = { event = "GameStateChanged", summarise = function(e) return e end },
    inventory = { event = "InventoryUpdated", summarise = function(e) return e end },
    npcadded = { event = "NPCEntityAdded", summarise = function(e) return describeNpc(e.npcEntity) end },
}

local function setWatch(name, on)
    local w = watchers[name]
    if not w then error("unknown watch: " .. tostring(name)) end
    if on then
        Event[w.event].Subscribe("devlink_watch", function(e)
            local ok, data = pcall(w.summarise, e)
            send("watch:" .. name, ok and data or { error = tostring(data) })
        end)
    else
        Event[w.event].Unsubscribe("devlink_watch")
    end
    return name .. (on and " on" or " off")
end

function commands.watch(arg)
    local name, state = string.match(arg or "", "^(%S+)%s*(%S*)$")
    return setWatch(name, state ~= "off")
end

---------------------------------------------------------------------------
-- Command polling
---------------------------------------------------------------------------
local function runCommand(id, text)
    local name, arg = string.match(text, "^(%S+)%s*(.*)$")
    local handler = commands[name or ""]
    local ok, value
    if handler then
        ok, value = pcall(handler, arg)
    else
        ok, value = false, "unknown command: " .. tostring(name) .. " (try help)"
    end
    local event = { kind = "result", id = id, cmd = text, ok = ok, tick = lastTick }
    if ok then event.value = value else event.error = tostring(value) end
    local encoded, line = pcall(json.encode, event)
    outbox[#outbox + 1] = encoded and line or json.encode({ kind = "result", id = id, ok = false,
                                                           error = "encode failed: " .. tostring(line) })
end

local function poll()
    if pollSending or not hasHttp() then return end
    pollSending = true
    HTTPRequest.new(Plugin.urls.devlink, keyed("/poll")):Get(function(request)
        pollSending = false
        if refused(request) then return end
        if not request.successful then
            -- Report the first failure and then every 30 s, with the client's reason.
            if lastTick - lastPollErrorTick >= 1500 or lastPollErrorTick == 0 then
                lastPollErrorTick = lastTick
                print(string.format("[devlink] poll failed: url=%s timedOut=%s code=%s errorCode=%s info=%s",
                    tostring(request.url), tostring(request.timedOut), tostring(request.responseCode),
                    tostring(request.errorCode), tostring(request.errorInfo)))
            end
            return
        end
        if not pollOk then
            pollOk = true
            print("[devlink] connected to " .. tostring(Plugin.urls.devlink))
        end
        for id, text in string.gmatch(request.data, "(%d+)\t([^\n]*)") do
            runCommand(tonumber(id), text)
        end
    end)
end

---------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------
Event.Logic.Subscribe("devlink", function(e)
    lastTick = e.logicTick
    -- Say so whenever the httpAccess permission flips, however it changed.
    local http = hasPermission()
    if http ~= lastHttp then
        lastHttp = http
        print("[devlink] httpAccess " .. (http and "granted" or "not granted") ..
              " (urls.devlink=" .. tostring(Plugin.urls.devlink) .. ")")
    end
    if lastTick % POLL_TICKS == 0 then poll() end
    if lastTick % FLUSH_TICKS == 0 then flush() end
end)

Event.GameStateChanged.Subscribe("devlink", function(e)
    lastGameState = e
    send("gamestate", e)
end)

Event.MiniMenuOpened.Subscribe("devlink", function(e)
    local entries = {}
    local ok = pcall(function()
        for i, entry in ipairs(e.miniMenu.entries) do entries[i] = describeEntry(entry) end
    end)
    if ok then lastMenu = entries end
end)

-- httpAccess is optional so the plugin can load before it is granted; it
-- starts sending as soon as the permission arrives.
local function announce()
    if not hasKey then
        print("[devlink] loaded without its key, so nothing is sent: run  rs3-dev.ps1 deploy  then  prf  and  prl devlink")
    elseif hasHttp() then
        print("[devlink] up; sending to " .. tostring(Plugin.urls.devlink))
    else
        print("[devlink] loaded, waiting for httpAccess: run  ppe devlink httpAccess")
    end
end
Event.OptionalPermissionChanged.Subscribe("devlink", function() announce() end)
announce()
send("hello", { plugin = "devlink", http = hasHttp() })
setWatch("menuselect", true)

-- Library interface for other dev plugins (optionalDependencies: ["devlink"]).
return {
    log = function(tag, data) send("log:" .. tostring(tag), data) end,
}
