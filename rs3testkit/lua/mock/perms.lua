-- Plugin permissions (httpAccess, chatAccess, trackingAccess), per plugin.
--
-- In the client a player grants permissions; in the kit a spec does:
--   kit.permissions.grant("httpAccess")     for the plugin under test
--   kit.permissions.revoke("chatAccess")
-- By default a plugin has the permissions in its manifest's
-- requiredPermissions (and a "permissions" list, if any); optionalPermissions
-- start revoked, as they are until the player approves them. Granting or
-- revoking an optional permission fires Event.OptionalPermissionChanged.

local M = {}

local granted = {}      -- plugin name -> { permission -> true }
local optional = {}     -- plugin name -> { permission -> true }
local declared = {}     -- plugin name -> { permission -> true } (any list)

function M.has(pluginName, permission)
    return (granted[pluginName] or {})[permission] == true
end

function M.isOptional(pluginName, permission)
    return (optional[pluginName] or {})[permission] == true
end

function M.isDeclared(pluginName, permission)
    return (declared[pluginName] or {})[permission] == true
end

function M.set(pluginName, permission, on)
    granted[pluginName] = granted[pluginName] or {}
    granted[pluginName][permission] = on or nil
end

function M.perPlugin(desc)
    granted[desc.name], optional[desc.name], declared[desc.name] = {}, {}, {}
    local m = desc.manifest or {}
    for _, field in ipairs({ "requiredPermissions", "permissions" }) do
        for _, p in ipairs(m[field] or {}) do
            granted[desc.name][p] = true
            declared[desc.name][p] = true
        end
    end
    for _, p in ipairs(m.optionalPermissions or {}) do
        optional[desc.name][p] = true
        declared[desc.name][p] = true
    end
end

function M.install() end

return M
