-- Event: the client's events, and the fixtures that fire them.
--
--   Event.Logic.Subscribe("myTick", function(e) ... end)   -- plugin side
--   kit.tick(5)                                            -- spec side
--   kit.events.fire("SkillTransmit", { skill = SkillType.MINING, ... })
--
-- Behaviour follows the docs: handlers run in subscription order; reusing a
-- reference name in the same plugin and event replaces the handler; the same
-- name in another plugin does not. EntityDraw handlers must return a boolean.
--
-- Payloads are strict: reading a field that is not in the documented payload
-- (a typo) or that the spec did not provide raises an error, and so does
-- writing a read-only field. A handler that raises fails the test, with the
-- event and handler named.
--
-- Not from the docs: the MiniMenuEntryAdded payload also carries `miniMenu`
-- (the docs list only `entry`, but plugins call event.miniMenu:Add there and
-- it works in the live client).

local Core = require("core")
local Docs = require("docs")
local Behaviour = require("behaviour")

local M = {}

local subscribers = {}     -- event name -> ordered list of { plugin, ref, fn }
local logicTick = 1000
local dispatching = {}     -- event name -> depth (for nested fires)

local EXTRA_FIELDS = {
    MiniMenuEntryAdded = { miniMenu = { type = "MiniMenu", ro = true } },
}
local SERVER_TICK = 30      -- 0.6 s at 50 logic ticks per second

-- A payload proxy over `values` for event `name`.
local function payload(name, values)
    local fields = {}
    for k, v in pairs(Docs.data.events[name] or {}) do fields[k] = v end
    for k, v in pairs(EXTRA_FIELDS[name] or {}) do fields[k] = v end
    local store = {}
    for k, v in pairs(values or {}) do
        if not fields[k] then
            error("rs3testkit: kit.events.fire(\"" .. name .. "\"): '" .. tostring(k) ..
                "' is not a documented field of this event's payload", 3)
        end
        store[k] = v
    end
    return setmetatable({}, {
        __index = function(_, k)
            if store[k] ~= nil then return store[k] end
            if fields[k] then
                error("rs3testkit: Event." .. name .. " payload field '" .. tostring(k) ..
                    "' was not provided by the test (pass it to kit.events.fire)", 2)
            end
            Core.missing("Event." .. name .. " payload field '" .. tostring(k) .. "'", false)
        end,
        __newindex = function(_, k, v)
            local f = fields[k]
            if not f then Core.missing("Event." .. name .. " payload field '" .. tostring(k) .. "'", false) end
            if f.ro then error("rs3testkit: Event." .. name .. " payload field '" .. k .. "' is read-only", 2) end
            store[k] = v
        end,
        __pairs = function() return next, store, nil end,
        __kitPayload = store,
    })
end

-- Calls every subscriber of `name` with `values` as the payload. Returns the
-- payload (so writable fields changed by handlers can be read) and, for
-- EntityDraw, whether drawing continues.
-- `only(pluginName)`, if given, limits delivery to the plugins it accepts
-- (ChatMessage goes only to plugins with chatAccess, for example).
local function fire(name, values, level, only)
    if not Docs.data.events[name] then
        error("rs3testkit: there is no documented event named " .. tostring(name), (level or 1) + 1)
    end
    local list = {}
    for i, s in ipairs(subscribers[name] or {}) do list[i] = s end
    local p = next(Docs.data.events[name]) ~= nil and payload(name, values) or nil
    if p == nil and EXTRA_FIELDS[name] then p = payload(name, values) end
    local keepDrawing = true
    dispatching[name] = (dispatching[name] or 0) + 1
    for _, s in ipairs(list) do
        if only and not only(s.plugin) then goto continue end
        do
        local ok, result = xpcall(s.fn, debug.traceback, p)
        if not ok then
            dispatching[name] = dispatching[name] - 1
            error("Event." .. name .. " handler '" .. s.ref .. "' (plugin " .. s.plugin .. ") raised:\n" ..
                tostring(result), 0)
        end
        if name == "EntityDraw" then
            if type(result) ~= "boolean" then
                dispatching[name] = dispatching[name] - 1
                error("rs3testkit: Event.EntityDraw handler '" .. s.ref .. "' returned " .. type(result) ..
                    "; it must return true (keep drawing) or false", 0)
            end
            keepDrawing = keepDrawing and result
        end
        end
        ::continue::
    end
    dispatching[name] = dispatching[name] - 1
    return p, keepDrawing
end
M.fire = fire

function M.isDispatching(name) return (dispatching[name] or 0) > 0 end
function M.logicTick() return logicTick end

-- The Event table one plugin sees: subscriptions are keyed by plugin.
local function eventTableFor(pluginName)
    local members = {}
    for name in pairs(Docs.data.events) do
        local ns = Core.namespace("Event." .. name, {
            members = {
                Subscribe = Core.static({ "string", "function" }, function(ref, fn)
                    Behaviour.label(fn, function() return "Event." .. name .. " handler \"" .. ref .. "\"" end)
                    local list = subscribers[name] or {}
                    subscribers[name] = list
                    for _, s in ipairs(list) do
                        if s.plugin == pluginName and s.ref == ref then
                            s.fn = fn   -- same plugin + name: replace, keep position
                            return
                        end
                    end
                    list[#list + 1] = { plugin = pluginName, ref = ref, fn = fn }
                end),
                Unsubscribe = Core.static({ "string" }, function(ref)
                    local list = subscribers[name] or {}
                    for i, s in ipairs(list) do
                        if s.plugin == pluginName and s.ref == ref then
                            table.remove(list, i)
                            return
                        end
                    end
                end),
            },
        })
        members[name] = ns
    end
    return Core.namespace("Event", { members = members })
end

function M.install(api, kit)
    kit.events = {}

    -- Fires a documented event with the given payload fields.
    function kit.events.fire(name, values, only)
        return fire(name, values, 2, only)
    end

    -- { "plugin:ref", ... } subscribed to an event, in call order.
    function kit.events.subscribers(name)
        local out = {}
        for _, s in ipairs(subscribers[name] or {}) do out[#out + 1] = s.plugin .. ":" .. s.ref end
        return out
    end

    function kit.events.isSubscribed(name, ref)
        for _, s in ipairs(subscribers[name] or {}) do
            if ref == nil or s.ref == ref then return true end
        end
        return false
    end

    -- Advances the client `n` logic ticks (50 per second). Each tick fires
    -- Event.Logic; every 30th also fires ServerLogic (one 0.6 s server tick).
    -- Queued work (HTTP replies, chat messages) is delivered at the start of
    -- the tick, as the client does on its next logic update.
    function kit.tick(n)
        n = n or 1
        for _ = 1, n do
            logicTick = logicTick + 1
            for _, hook in ipairs(kit._tickHooks) do hook(logicTick) end
            fire("Logic", { logicTick = logicTick })
            if logicTick % SERVER_TICK == 0 then fire("ServerLogic") end
            for _, hook in ipairs(kit._frameHooks) do hook() end
        end
    end
    kit._tickHooks = {}
    kit._frameHooks = {}      -- run after every Logic and Draw (kit.pointer)

    -- Advances by game time: kit.seconds(1.2) = 60 logic ticks.
    function kit.seconds(s) kit.tick(math.floor(s * 50 + 0.5)) end

    -- Fires Event.Draw `n` times with the given frame time (default 1/60 s).
    function kit.draw(n, dt)
        for _ = 1, (n or 1) do
            fire("Draw", { timeDeltaSecs = dt or (1 / 60) })
            for _, hook in ipairs(kit._frameHooks) do hook() end
        end
    end

    function kit.events.setLogicTick(t) logicTick = t end
end

function M.perPlugin(desc, ownApi)
    ownApi.Event = eventTableFor(desc.name)
end

return M
