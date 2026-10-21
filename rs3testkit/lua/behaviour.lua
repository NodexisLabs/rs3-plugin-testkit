-- behaviour.lua: which plugin functions each scenario runs, as a call tree.
--
-- A call-only debug hook looks at the real Lua stack every time a function
-- in a plugin file is called, keeps only the frames that belong to the
-- plugin's own files (the kit, the mock API and the spec are left out), and
-- adds that path to the current scenario's tree. Paths are merged by
-- function, so a loop that calls `rowColour` 600 times is one node with a
-- count of 600, and the tree stays the size of the code, not of the run.
-- Reading the stack (instead of pairing call and return events) keeps the
-- tree right when an error is caught by pcall or a function tail-calls.
--
-- Used by `rs3test map` (cli.py), which renders the trees as Markdown.

local Behaviour = {}

-- What the kit knows about a function the plugin handed it: the event,
-- hook or menu entry it was registered for. fn -> function() return text end
-- (computed when the map first meets the function, so a button's label is
-- read after the plugin has set it).
local labels = setmetatable({}, { __mode = "k" })
function Behaviour.label(fn, describe)
    if type(fn) == "function" then labels[fn] = describe end
end

-- While the kit is calling a plugin function for a specific reason (one
-- component's hook, when the same handler serves several components), that
-- reason wins over the registration label. A stack, for nested dispatches.
-- The text is read once when the dispatch starts: a handler that changes
-- its own button's label or row text must not split into two lines.
local dispatch = {}
function Behaviour.enter(fn, describe)
    dispatch[#dispatch + 1] = { fn = fn, text = describe() }
end
function Behaviour.leave() dispatch[#dispatch] = nil end

-- Registration labels are read once, the first time the map meets them.
local labelText = setmetatable({}, { __mode = "k" })
local function roleOf(fn)
    for i = #dispatch, 1, -1 do
        if dispatch[i].fn == fn then return dispatch[i].text end
    end
    local describe = labels[fn]
    if not describe then return nil end
    local text = labelText[fn]
    if text == nil then
        text = describe()
        labelText[fn] = text
    end
    return text
end

-- Name of a function from the line that defines it, for locals called
-- through pcall or a table (where debug info has no name):
--   local function onEntryAdded(event)  /  function Window.show(view)
--   local render = function()           /  M.open = function(link)
local sourceLines = {}
local function nameFromSource(path, line)
    if line == nil or line <= 0 then return nil end
    local lines = sourceLines[path]
    if lines == nil then
        lines = {}
        local f = io.open(path, "r")
        if f then
            for l in f:lines() do lines[#lines + 1] = l end
            f:close()
        end
        sourceLines[path] = lines
    end
    local text = lines[line]
    if not text then return nil end
    return string.match(text, "function%s+([%w_%.:]+)%s*%(")
        or string.match(text, "([%w_%.]+)%s*=%s*function%s*%(")
end

local scenarios = {}        -- name -> { name, root, calls }
local order = {}            -- scenario names in first-seen order
local current = nil         -- scenario name, or nil (loading, outside tests)
local running = false

local function scenario(name)
    local s = scenarios[name]
    if not s then
        s = { name = name, root = { children = {}, index = {} }, calls = 0 }
        scenarios[name] = s
        order[#order + 1] = name
    end
    return s
end

-- Starts mapping. `plugins` is a list of { prefix = "@<dir>/", plugin = name }.
function Behaviour.start(plugins, loadName)
    if running then error("rs3testkit: behaviour mapping is already running", 2) end
    running = true
    local known = {}
    local function where(source)
        local w = known[source]
        if w ~= nil then return w end
        w = false
        for _, p in ipairs(plugins) do
            if string.sub(source, 1, #p.prefix) == p.prefix then
                w = { file = string.sub(source, #p.prefix + 1), plugin = p.plugin }
                break
            end
        end
        known[source] = w
        return w
    end
    debug.sethook(function()
        local top = debug.getinfo(2, "S")
        if not top or not where(top.source) then return end
        -- The plugin frames on the stack, outermost first.
        local path = {}
        local level = 2
        while true do
            local info = debug.getinfo(level, "Snf")
            if not info then break end
            local w = where(info.source)
            if w then
                local role = roleOf(info.func)
                local key = info.source .. ":" .. info.linedefined
                if role then
                    -- Same handler, different reason (two buttons): separate lines.
                    key = key .. "|" .. role
                end
                table.insert(path, 1, {
                    key = key, role = role,
                    name = (info.what == "main") and "(top level)" or info.name,
                    file = w.file, plugin = w.plugin, line = info.linedefined,
                    path = string.sub(info.source, 2),
                })
            end
            level = level + 1
        end
        local s = scenario(current or loadName)
        s.calls = s.calls + 1
        local node = s.root
        for i, f in ipairs(path) do
            local child = node.index[f.key]
            if not child then
                local role = f.role
                -- The defining line names a function the way the code does
                -- (Shop.price); debug info knows only the last field (price).
                local name = f.name
                if name ~= "(top level)" then name = nameFromSource(f.path, f.line) or name end
                child = { name = name, role = role,
                          file = f.file, plugin = f.plugin, line = f.line,
                          count = 0, children = {}, index = {} }
                node.index[f.key] = child
                node.children[#node.children + 1] = child
            elseif child.name == nil and f.name then
                child.name = f.name       -- a later call site may know its name
            end
            if i == #path then child.count = child.count + 1 end
            node = child
        end
    end, "c")
end

function Behaviour.stop()
    debug.sethook()
    running = false
end

-- Called by the spec runner around each test.
function Behaviour.setScenario(name) current = name end

-- { { name, calls, root }, ... } in first-seen order. Trees drop their
-- lookup indexes so they cross to Python as plain tables.
function Behaviour.result()
    local function strip(node)
        local out = { name = node.name, role = node.role, file = node.file, plugin = node.plugin,
                      line = node.line, count = node.count, children = {} }
        for i, c in ipairs(node.children) do out.children[i] = strip(c) end
        return out
    end
    local out = {}
    for _, name in ipairs(order) do
        local s = scenarios[name]
        out[#out + 1] = { name = name, calls = s.calls, root = strip(s.root) }
    end
    return out
end

return Behaviour
