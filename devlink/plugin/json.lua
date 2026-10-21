-- Minimal JSON encoder for devlink. Encodes tables, strings, numbers and
-- booleans; anything else (userdata, functions) becomes its tostring() text.
-- Depth and size are capped so a huge or cyclic table cannot stall the client.

local json = {}

local MAX_DEPTH = 6
local MAX_ITEMS = 300

local escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function encodeString(s)
    return '"' .. string.gsub(s, '[%c"\\]', function(c)
        return escapes[c] or string.format("\\u%04x", string.byte(c))
    end) .. '"'
end

local function isArray(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
        n = n + 1
    end
    return n == #t
end

local encode

local function encodeTable(t, depth, seen)
    if seen[t] then return '"<cycle>"' end
    if depth > MAX_DEPTH then return '"<max depth>"' end
    seen[t] = true
    local parts, count = {}, 0
    if isArray(t) then
        for _, v in ipairs(t) do
            count = count + 1
            if count > MAX_ITEMS then parts[#parts + 1] = '"<truncated>"' break end
            parts[#parts + 1] = encode(v, depth + 1, seen)
        end
        seen[t] = nil
        return "[" .. table.concat(parts, ",") .. "]"
    end
    for k, v in pairs(t) do
        count = count + 1
        if count > MAX_ITEMS then parts[#parts + 1] = '"<truncated>":true' break end
        parts[#parts + 1] = encodeString(tostring(k)) .. ":" .. encode(v, depth + 1, seen)
    end
    seen[t] = nil
    return "{" .. table.concat(parts, ",") .. "}"
end

encode = function(value, depth, seen)
    local kind = type(value)
    if kind == "nil" then return "null" end
    if kind == "boolean" then return tostring(value) end
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return encodeString(tostring(value))
        end
        return math.type(value) == "integer" and tostring(value) or string.format("%.10g", value)
    end
    if kind == "string" then return encodeString(value) end
    if kind == "table" then return encodeTable(value, depth, seen) end
    return encodeString(kind .. ":" .. tostring(value))
end

function json.encode(value)
    return encode(value, 1, {})
end

return json
