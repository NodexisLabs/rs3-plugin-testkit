-- HTTPRequest: simulated. The kit never opens a network connection.
--
-- A plugin's requests are answered from routes the spec sets up, delivered
-- on the next kit.tick() (requests are asynchronous in the client), and
-- counted per endpoint so a spec can check how many calls a feature makes:
--
--   kit.http.respond("GET", "https://api.example.com/prices", { status = 200, body = "{...}" })
--   kit.http.respond("POST", "https://api.example.com/log", function(req) return { status = 204 } end)
--   kit.tick()                                   -- deliver replies
--   expect(kit.http.count("GET https://api.example.com/prices")).toBe(1)
--
-- Rules enforced (from the docs):
--   * the plugin needs the httpAccess permission to create a request;
--   * the base URL must be one of the plugin's manifest "urls" (Plugin.urls);
--   * calling Get/Post/AddHeader on a request that is already active errors.
-- A request with no matching route fails the test when it is delivered, so a
-- missing fixture cannot silently take the plugin's failure path. To test the
-- failure path, route it explicitly: kit.http.respond("GET", url, { fail = "timeout" }).

local Core = require("core")
local Docs = require("docs")
local Behaviour = require("behaviour")
local Perms = require("perms")

local M = {}

local routes = {}          -- { method, url (exact or ending in *), reply }
local pending = {}         -- requests waiting for the next tick
local log = {}             -- every request: { method, url, body, headers, plugin }
local byEndpoint = {}      -- "GET url" -> count

local function matches(pattern, url)
    if string.sub(pattern, -1) == "*" then
        return string.sub(url, 1, #pattern - 1) == string.sub(pattern, 1, -2)
    end
    return pattern == url
end

local function findRoute(method, url)
    for i = #routes, 1, -1 do        -- later routes win
        local r = routes[i]
        if (r.method == method or r.method == "*") and matches(r.url, url) then return r end
    end
end

local function finish(req, reply)
    local set = function(k, v) Core.setRaw(req, k, v) end
    set("finished", true)
    if reply.fail then
        set("failed", true)
        set("timedOut", reply.fail == "timeout")
        set("errorInfo", tostring(reply.fail))
        set("errorCode", reply.errorCode or 0)
        set("successful", false)
    else
        local status = reply.status or 200
        set("responseCode", status)
        set("data", reply.body or "")
        set("header", reply.header or "")
        set("downloadedBytes", #(reply.body or ""))
        set("downloadTotalBytes", #(reply.body or ""))
        set("progress", 1.0)
        set("successful", status >= 200 and status < 300)
        set("failed", not (status >= 200 and status < 300))
        if not (status >= 200 and status < 300) then set("errorCode", status) end
    end
end

-- Delivers every pending request (called at the start of each tick).
local function deliver()
    local batch = pending
    pending = {}
    for _, p in ipairs(batch) do
        local req = p.req
        if not Core.getRaw(req, "cancelled") then
            local route = findRoute(p.method, p.url)
            if route == nil then
                error("rs3testkit: the plugin sent " .. p.method .. " " .. p.url .. " and no kit.http.respond route " ..
                    "matches it. Add one (use { fail = \"...\" } to test the failure path).", 0)
            end
            local reply = route.reply
            if type(reply) == "function" then
                reply = reply({ method = p.method, url = p.url, body = p.body, headers = p.headers })
                if type(reply) ~= "table" then error("rs3testkit: kit.http.respond handler must return a reply table", 0) end
            end
            finish(req, reply)
            Core.setRaw(req, "_active", false)
            if p.onDone then
                local ok, err = xpcall(p.onDone, debug.traceback, req)
                if not ok then error("HTTPRequest completion callback for " .. p.url .. " raised:\n" .. tostring(err), 0) end
            end
        end
    end
end

local function send(self, method, body, onDone, onProgress)
    if Core.getRaw(self, "_active") then
        error("rs3testkit: HTTPRequest:" .. (method == "GET" and "Get" or "Post") ..
            " called on a request that is still active (the docs say this errors)", 3)
    end
    local url = Core.getRaw(self, "url")
    Core.setRaw(self, "_active", true)
    local headers = Core.getRaw(self, "_headers")
    log[#log + 1] = { method = method, url = url, body = body, headers = headers, plugin = Core.getRaw(self, "_plugin") }
    local key = method .. " " .. url
    byEndpoint[key] = (byEndpoint[key] or 0) + 1
    if onDone then Behaviour.label(onDone, function() return "HTTP " .. method .. " " .. url .. " reply" end) end
    pending[#pending + 1] = { req = self, method = method, url = url, body = body, headers = headers, onDone = onDone }
end

local function defineClass()
    Docs.class("HTTPRequest", {
        native = "jag::plugin::HTTPRequest",
        props = { _active = {}, _headers = {}, _plugin = {} },
        defaults = { progress = 0.0 },
        impls = {
            Get = function(self, onDone, onProgress) send(self, "GET", nil, onDone, onProgress) end,
            Post = function(self, data, onDone, onProgress) send(self, "POST", data, onDone, onProgress) end,
            Cancel = function(self)
                Core.setRaw(self, "cancelled", true)
                Core.setRaw(self, "finished", true)
                Core.setRaw(self, "_active", false)
            end,
            AddHeader = function(self, k, v)
                if Core.getRaw(self, "_active") then
                    error("rs3testkit: HTTPRequest:AddHeader called on an active request (the docs say this errors)", 2)
                end
                Core.getRaw(self, "_headers")[k] = v
            end,
        },
    })
end

-- HTTPRequest namespace for one plugin (its permission and base URLs).
local function namespaceFor(desc)
    local urls = {}
    for _, u in pairs((desc.manifest or {}).urls or {}) do urls[u] = true end
    return Core.namespace("HTTPRequest", {
        documented = { "new" },
        members = {
            new = Core.static(nil, function(baseURL, path)
                if not Perms.has(desc.name, "httpAccess") then
                    error("rs3testkit: HTTPRequest.new needs the httpAccess permission, which plugin '" .. desc.name ..
                        "' does not have (declare it in plugin.json; grant optional ones with kit.permissions.grant)", 2)
                end
                if not urls[baseURL] then
                    error("rs3testkit: HTTPRequest.new: base URL " .. tostring(baseURL) .. " is not one of the plugin's " ..
                        "manifest \"urls\" (use Plugin.urls.<name>)", 2)
                end
                local url = baseURL .. (path or "")
                return Core.new("HTTPRequest", { url = url, _active = false, _headers = {}, _plugin = desc.name })
            end, Docs.checker("HTTPRequest", "new")),
        },
    })
end

function M.install(api, kit)
    defineClass()
    table.insert(kit._tickHooks, deliver)

    kit.http = {}
    -- Sets the reply for METHOD url (url may end in * to match a prefix).
    -- reply = { status = 200, body = "", header = "" } | { fail = "reason" } | function(req) -> reply
    function kit.http.respond(method, url, reply)
        method = string.upper(method)
        if method ~= "GET" and method ~= "POST" and method ~= "*" then error("kit.http.respond: method must be GET, POST or *", 2) end
        if type(reply) ~= "table" and type(reply) ~= "function" then error("kit.http.respond: reply must be a table or function", 2) end
        routes[#routes + 1] = { method = method, url = url, reply = reply }
    end
    -- Delivers pending replies now, without advancing the tick.
    kit.http.flush = deliver
    function kit.http.requests() return log end
    function kit.http.pending() return #pending end
    function kit.http.count(key)
        if key == nil then return #log end
        return byEndpoint[key] or 0
    end
    function kit.http._usage()
        return { total = #log, byEndpoint = byEndpoint }
    end
end

function M.perPlugin(desc, ownApi)
    ownApi.HTTPRequest = namespaceFor(desc)
end

return M
