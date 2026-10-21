-- Vector2 / Vector3 / Vector4: the float vectors the sandbox exposes.
--
-- Constructors follow the docs: new() is all zeros, new(v) sets every
-- component to v, new(x, y[, z[, w]]) sets each one.
--
-- The client also has integer vectors (Vector3T<int>, e.g. ui.Model.rotation),
-- but the sandbox gives plugins no way to make one, so properties that need
-- them cannot be set from Lua. ui.lua models that gap.

local Core = require("core")
local Docs = require("docs")

local M = {}

local FIELDS = {
    Vector2 = { "x", "y" },
    Vector3 = { "x", "y", "z" },
    Vector4 = { "x", "y", "z", "w" },
}

local function define(name)
    local fields = FIELDS[name]
    local defaults = {}
    for _, f in ipairs(fields) do defaults[f] = 0 end
    local overrides = {}
    if name == "Vector2" then
        -- u/v are documented aliases of x/y.
        overrides.u = { read = function(self) return Core.getRaw(self, "x") end,
                        onSet = function(self, v) Core.setRaw(self, "x", v) end }
        overrides.v = { read = function(self) return Core.getRaw(self, "y") end,
                        onSet = function(self, v) Core.setRaw(self, "y", v) end }
    end
    return Docs.class(name, {
        native = "jag::math::" .. name .. "T<float>",
        defaults = defaults,
        overrides = overrides,
        statics = {
            new = function(...)
                local n = select("#", ...)
                local init = {}
                for i, f in ipairs(fields) do
                    if n == 0 then init[f] = 0
                    elseif n == 1 then init[f] = (select(1, ...))
                    else init[f] = select(i, ...) or 0 end
                end
                return Core.new(name, init)
            end,
        },
    })
end

function M.install(api)
    api.Vector2 = define("Vector2")
    api.Vector3 = define("Vector3")
    api.Vector4 = define("Vector4")
end

-- Plain Lua helper for the other mocks.
function M.v3(x, y, z) return Core.new("Vector3", { x = x or 0, y = y or 0, z = z or 0 }) end
function M.v2(x, y) return Core.new("Vector2", { x = x or 0, y = y or 0 }) end
function M.v4(x, y, z, w) return Core.new("Vector4", { x = x or 0, y = y or 0, z = z or 0, w = w or 0 }) end

return M
