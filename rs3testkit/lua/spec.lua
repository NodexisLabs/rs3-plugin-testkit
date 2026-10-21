-- spec.lua: the small test framework spec files use.
--
-- A spec file registers tests with test(name, fn) and checks values with
-- expect(value). Tests in one file run in the order they were written and
-- share the same sandbox, so a file can be a scenario (open a window, page,
-- go back). Every file gets a fresh sandbox.
--
--   test("shows the goblin's drops", function()
--       kit.menu.examineNpc(11240, "Goblin")
--       expect(kit.ui.texts()).toContain("42 drops")
--   end)
--
-- A test fails when anything inside it raises an error: a failed expect, a
-- plain assert, an error in the plugin, or a call to an API function the kit
-- does not mock yet.

local Spec = {}

local tests = {}          -- { name, fn, file } in registration order
local currentFile = "?"

function Spec.setFile(name) currentFile = name end

function Spec.test(name, fn)
    if type(name) ~= "string" then error("test(name, fn): name must be a string", 2) end
    if type(fn) ~= "function" then error("test(" .. name .. "): fn must be a function", 2) end
    tests[#tests + 1] = { name = name, fn = fn, file = currentFile }
end

---------------------------------------------------------------------------
-- Readable values for failure messages
---------------------------------------------------------------------------
local function show(value, depth)
    depth = depth or 0
    if type(value) == "string" then return string.format("%q", value) end
    if type(value) ~= "table" or depth > 2 then return tostring(value) end
    local parts, n = {}, 0
    for k, v in pairs(value) do
        n = n + 1
        if n > 12 then parts[#parts + 1] = "..."; break end
        local key = (type(k) == "number") and "" or (tostring(k) .. " = ")
        parts[#parts + 1] = key .. show(v, depth + 1)
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
end
Spec.show = show

local function deepEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do if not deepEqual(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

---------------------------------------------------------------------------
-- expect(value).toX(...)
---------------------------------------------------------------------------
-- Level 3 points the error at the line in the spec that called expect.
local function fail(message) error(message, 3) end

function Spec.expect(actual)
    local e = {}

    function e.toBe(expected)
        if actual ~= expected then
            fail("expected " .. show(expected) .. ", got " .. show(actual))
        end
    end

    function e.toEqual(expected)
        if not deepEqual(actual, expected) then
            fail("expected (deep) " .. show(expected) .. ", got " .. show(actual))
        end
    end

    function e.toBeTruthy()
        if not actual then fail("expected a truthy value, got " .. show(actual)) end
    end

    function e.toBeFalsy()
        if actual then fail("expected a falsy value, got " .. show(actual)) end
    end

    function e.toBeNil()
        if actual ~= nil then fail("expected nil, got " .. show(actual)) end
    end

    function e.toBeCloseTo(expected, tolerance)
        tolerance = tolerance or 1e-9
        if type(actual) ~= "number" or math.abs(actual - expected) > tolerance then
            fail("expected " .. tostring(expected) .. " +/- " .. tostring(tolerance) .. ", got " .. show(actual))
        end
    end

    -- Strings: plain substring. Lists: an element equal (deep) to `item`.
    function e.toContain(item)
        if type(actual) == "string" then
            if not string.find(actual, item, 1, true) then
                fail("expected " .. show(actual) .. " to contain " .. show(item))
            end
            return
        end
        if type(actual) ~= "table" then fail("toContain needs a string or list, got " .. show(actual)) end
        for _, v in ipairs(actual) do
            if deepEqual(v, item) then return end
        end
        fail("expected list to contain " .. show(item) .. "; list is " .. show(actual))
    end

    function e.notToContain(item)
        if type(actual) == "string" then
            if string.find(actual, item, 1, true) then
                fail("expected " .. show(actual) .. " not to contain " .. show(item))
            end
            return
        end
        for _, v in ipairs(actual) do
            if deepEqual(v, item) then fail("expected list not to contain " .. show(item)) end
        end
    end

    function e.toHaveLength(n)
        local len = (type(actual) == "string" or type(actual) == "table") and #actual or nil
        if len ~= n then fail("expected length " .. tostring(n) .. ", got " .. tostring(len)) end
    end

    -- actual must be a function that raises an error matching `pattern`
    -- (a plain substring, not a Lua pattern).
    function e.toError(pattern)
        if type(actual) ~= "function" then fail("toError needs a function, got " .. show(actual)) end
        local ok, err = pcall(actual)
        if ok then fail("expected an error" .. (pattern and (" containing " .. show(pattern)) or "") .. ", but it ran") end
        if pattern and not string.find(tostring(err), pattern, 1, true) then
            fail("expected an error containing " .. show(pattern) .. ", got " .. show(tostring(err)))
        end
    end

    return e
end

---------------------------------------------------------------------------
-- Running
---------------------------------------------------------------------------
-- Runs every registered test. `after` is called after each test (the kit
-- uses it to collect lint warnings). Returns a list of result tables:
--   { file, name, ok, error, ms }
function Spec.run(after)
    local results = {}
    for _, t in ipairs(tests) do
        local start = os.clock()
        local ok, err = xpcall(t.fn, function(message)
            return debug.traceback(tostring(message), 2)
        end)
        local result = { file = t.file, name = t.name, ok = ok, error = (not ok) and err or nil,
                         ms = (os.clock() - start) * 1000 }
        if after then after(result) end
        results[#results + 1] = result
    end
    tests = {}
    return results
end

return Spec
