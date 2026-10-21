-- ui: a stand-in for the client's interface components.
--
-- Components are built from the documented classes (properties, methods,
-- parents), so a misspelt property, a wrong argument or a write to a
-- read-only property fails here as it would in the client. The kit records
-- what each component holds and fires its hooks; it cannot show how the
-- client draws it (fonts, sizes, styles). That still needs the client.
--
-- The plugin layer, ui.Interfaces:GetComponent(id.Component.
-- TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP), is a 1278 x 1360 ui.Layer (the size
-- seen in a live client).
--
-- Behaviour seen in a live client and kept here:
--   * clickthrough defaults to true: clicks on a component also reach the
--     game world (and walk the player) until it is set to false.
--   * ui.Sprite:SetAssociatedObject(id, quantity) fails with sol's "no
--     matching function call" (quantity is a Uint64); set
--     associatedObjectQuantity instead.
--   * ui.Model starts with viewDistance 100 and modelWidth/Height 0, which
--     draws nothing until they are set.
--   * ui.Model.rotation needs an integer Vector3 that Lua cannot construct.
--   * "<" in text starts a tag and is not drawn.
--
-- Spec helpers (kit.ui):
--   kit.ui.texts()                 visible Text contents, in creation order
--   kit.ui.button("Next")          the visible button with that label
--   kit.ui.press("Next")           press a visible, enabled button
--   kit.ui.click(c or "text")      click a component (ONCLICK)
--   kit.ui.drag(c, x1, y1, x2, y2) drag start/complete
--   kit.ui.find(fn) / kit.ui.all() components
--   kit.ui.dump()                  the component tree as text

local Core = require("core")
local Docs = require("docs")
local Ids = require("ids")
local Vector = require("vector")

local M = {}

local all = {}                       -- every component, in creation order
local info = setmetatable({}, { __mode = "k" })   -- component -> { kind, parent, children, hooks }
local root                           -- the plugin layer
local statics = {}                   -- combined id -> component (kit.ui.addStatic)
local HookName = Ids.hookNames

local COMPONENT_TYPES = {
    ["ui.Line"] = "LINE", ["ui.Rectangle"] = "RECTANGLE", ["ui.Text"] = "LABEL", ["ui.Sprite"] = "SPRITE",
    ["ui.Model"] = "MODEL", ["ui.ModelGroup"] = "MODEL_GROUP", ["ui.RadialProgressOverlay"] = "RADIAL_PROGRESS_OVERLAY",
    ["ui.Canvas"] = "CANVAS", ["ui.Button"] = "BUTTON", ["ui.Check"] = "CHECK", ["ui.List"] = "LIST",
    ["ui.InputField"] = "INPUTFIELD", ["ui.Slider"] = "SLIDER", ["ui.ComboField"] = "COMBO",
    ["ui.Carousel"] = "CAROUSEL", ["ui.PagedCarousel"] = "PAGED_CAROUSEL", ["ui.RadioGroup"] = "RADIO_GROUP",
    ["ui.Layer"] = "LAYER", ["ui.Panel"] = "PANEL", ["ui.Grid"] = "GRID", ["ui.PagedLayer"] = "PAGED_LAYER",
    ["ui.GroupBox"] = "GROUP_BOX",
}

local enums   -- ui enums, set in install

---------------------------------------------------------------------------
-- Tree helpers
---------------------------------------------------------------------------
local function isShown(c)
    while c do
        if Core.destroyed[c] then return false end
        if Core.getRaw(c, "hidden") then return false end
        c = info[c] and info[c].parent
    end
    return true
end

local function destroy(c, why)
    local i = info[c]
    for _, child in ipairs(i.children) do destroy(child, why) end
    i.children = {}
    Core.destroyed[c] = why
end

local function detach(c)
    local parent = info[c].parent
    if parent then
        local siblings = info[parent].children
        for k, v in ipairs(siblings) do
            if v == c then table.remove(siblings, k); break end
        end
    end
end

-- Runs every listener of `hook` on `c` in subscription order. A listener
-- returning true stops the rest (as documented).
local function fireHook(c, hook, ...)
    local entries = info[c].hooks[hook]
    if not entries then return false end
    local list = {}
    for i, e in ipairs(entries) do list[i] = e end
    for _, e in ipairs(list) do
        local ok, result = xpcall(e.fn, debug.traceback, c, ...)
        if not ok then
            error(string.format("ui hook %s on %s raised:\n%s", HookName[hook] or tostring(hook),
                Core.classOf(c), tostring(result)), 0)
        end
        if result == true then break end
    end
    return true
end

---------------------------------------------------------------------------
-- Classes
---------------------------------------------------------------------------
local function subscribe(self, hook, a, b)
    local id, fn = "", a
    if b ~= nil then id, fn = a, b end
    local hooks = info[self].hooks
    hooks[hook] = hooks[hook] or {}
    for _, e in ipairs(hooks[hook]) do
        if e.id == id then e.fn = fn; return end
    end
    table.insert(hooks[hook], { id = id, fn = fn })
end

local function unsubscribe(self, hook, id)
    id = id or ""
    local list = info[self].hooks[hook] or {}
    for k, e in ipairs(list) do
        if e.id == id then table.remove(list, k); return end
    end
end

local function setPos(self, x, y)
    Core.setRaw(self, "x", x)
    Core.setRaw(self, "y", y)
end

local function setSize(self, w, h)
    Core.setRaw(self, "width", w)
    Core.setRaw(self, "height", h)
end

local componentImpls = {
    SetPos = setPos,
    SetX = function(self, x) Core.setRaw(self, "x", x) end,
    SetY = function(self, y) Core.setRaw(self, "y", y) end,
    SetSize = setSize,
    SetWidth = function(self, w) Core.setRaw(self, "width", w) end,
    SetHeight = function(self, h) Core.setRaw(self, "height", h) end,
    Subscribe = subscribe,
    Unsubscribe = unsubscribe,
    UnsubscribeAll = function(self, hook) info[self].hooks[hook] = {} end,
    Destroy = function(self)
        if self == root then error("rs3testkit: plugins cannot destroy the plugin layer (it belongs to the client)", 2) end
        detach(self)
        destroy(self, "Destroy()")
    end,
    MoveToFront = function(self)
        detach(self)
        table.insert(info[info[self].parent].children, self)
    end,
    MoveToBack = function(self)
        detach(self)
        table.insert(info[info[self].parent].children, 1, self)
    end,
}

local componentDefaults = {
    hidden = false, enabled = true, clickthrough = true, alpha = 1.0,
    rgb = 0xFFFFFF, rgba = 0xFFFFFFFF, stylesheetID = -1,
    isSafeAreaRelative = false,
    colour = function() return Vector.v4(1, 1, 1, 1) end,
}

local componentOverrides = {
    visible = { read = function(self) return not Core.getRaw(self, "hidden") end },
    visibleGlobal = { read = function(self) return isShown(self) end },
    parent = { read = function(self) return info[self].parent end },
    parentStatic = { read = function() return root end },
    type = { read = function(self) return enums.ComponentType[COMPONENT_TYPES[Core.classOf(self)] or "LAYER"] end },
    interfaceID = { read = function() return -1 end },
    categoryID = { read = function(self) return info[self].categoryID or 0 end },
    dynamicID = { read = function(self) return info[self].dynamicID or -1 end },
    xyLocal = { read = function(self) return Vector.v2(Core.getRaw(self, "x"), Core.getRaw(self, "y")) end },
    xyGlobal = { read = function(self)
        local x, y = 0, 0
        local c = self
        while c do x = x + (Core.getRaw(c, "x") or 0); y = y + (Core.getRaw(c, "y") or 0); c = info[c].parent end
        return Vector.v2(x, y)
    end },
    isMouseOver = { read = function() return false end },
    isClicked = { read = function() return false end },
}

local collectionImpls = {
    GetChild = function(self, a, b)
        for _, c in ipairs(info[self].children) do
            if b == nil and info[c].staticID == a then return c end
            if b ~= nil and info[c].categoryID == a and info[c].dynamicID == b then return c end
        end
        return nil
    end,
    Delete = function(self, cat, dyn)
        for _, c in ipairs(info[self].children) do
            if info[c].categoryID == cat and info[c].dynamicID == dyn then
                detach(c); destroy(c, "Delete()")
                return true
            end
        end
        return false
    end,
    DeleteAll = function(self)
        local kids = info[self].children
        info[self].children = {}
        for _, c in ipairs(kids) do destroy(c, "DeleteAll()") end
    end,
    IterateDynamicComponents = function(self, fn)
        local kids = {}
        for i, c in ipairs(info[self].children) do kids[i] = c end
        for _, c in ipairs(kids) do
            if fn(c, isShown(c)) == true then break end
        end
    end,
}

local function iconSetter(self, objectID, quantity)
    Core.setRaw(self, "associatedObjectID", objectID)
    if quantity ~= nil then Core.setRaw(self, "associatedObjectQuantity", quantity) end
end

local function defineClasses()
    Docs.class("ui.Component", {
        impls = componentImpls, defaults = componentDefaults, overrides = componentOverrides,
        recordSetters = true, native = "jag::ui::Component",
    })
    Docs.class("ui.ComponentCollection", {
        impls = collectionImpls, recordSetters = true,
        defaults = { scrollable = false },
    })
    local namespaces = {}
    local function component(name, opts)
        opts = opts or {}
        opts.recordSetters = true
        opts.native = opts.native or ("jag::ui::" .. string.sub(name, 4))
        opts.statics = opts.statics or {}
        opts.statics.new = function(parent, categoryID, dynamicID)
            return M.create(name, parent, categoryID, dynamicID)
        end
        namespaces[string.sub(name, 4)] = Docs.class(name, opts)
    end

    component("ui.Layer")
    component("ui.GroupBox")
    component("ui.Panel")
    component("ui.Grid")
    component("ui.PagedLayer")
    component("ui.PagedCarousel")
    component("ui.ModelGroup")
    component("ui.Text", {
        impls = { SetAssociatedObject = iconSetter },
        defaults = { associatedObjectID = -1, maxLines = 1 },
    })
    component("ui.Sprite", {
        impls = {
            SetAssociatedObject = function(self, objectID, quantity)
                if quantity ~= nil then
                    error("sol: no matching function call takes this number of arguments and the specified types " ..
                        "(rs3testkit: in the live client ui.Sprite:SetAssociatedObject rejects the quantity argument " ..
                        "even though the docs list it; set sprite.associatedObjectQuantity instead)", 2)
                end
                iconSetter(self, objectID)
            end,
        },
        defaults = { associatedObjectID = -1, associatedObjectQuantity = 0, spriteID = -1 },
    })
    component("ui.Model", {
        impls = {
            SetModel = function(self, modelType, id1, id2)
                Core.setRaw(self, "modelType", modelType)
                Core.setRaw(self, "modelID1", id1)
                Core.setRaw(self, "modelID2", id2 or -1)
            end,
            SetAssociatedObject = iconSetter,
        },
        defaults = { viewDistance = 100, modelWidth = 0, modelHeight = 0, animID = -1,
                     modelType = 0, modelID1 = -1, modelID2 = -1, associatedObjectID = -1,
                     screenOffset = function() return Vector.v3(0, 0, 0) end,
                     worldOffset = function() return Vector.v3(0, 0, 0) end },
        overrides = {
            rotation = { reject = "sol: bad argument into 'void(const jag::math::Vector3T<int>&)' (rs3testkit: " ..
                "ui.Model.rotation needs an integer Vector3, which the plugin sandbox cannot construct; " ..
                "models cannot be rotated from Lua as of 2026-10-21)" },
        },
    })
    component("ui.Button", {
        impls = { SetAssociatedObject = iconSetter },
        defaults = { associatedObjectID = -1 },
    })
    component("ui.Canvas", {
        impls = {
            Clear = function(self) info[self].elements = {}; Core.setRaw(self, "numElements", 0) end,
            Undo = function(self)
                table.remove(info[self].elements)
                Core.setRaw(self, "numElements", #info[self].elements)
            end,
        },
    })
    -- Canvas Add* calls are kept as drawable elements for specs to inspect.
    for _, add in ipairs({ "AddLine", "AddOutline", "AddRectangle", "AddGradientH", "AddGradientV",
                           "AddSprite", "AddText", "AddTriangle" }) do
        Core.setMethod("ui.Canvas", add, function(self, ...)
            local els = info[self].elements
            els[#els + 1] = { kind = add, args = table.pack(...) }
            Core.setRaw(self, "numElements", #els)
        end)
    end
    for _, name in ipairs({ "ui.Line", "ui.Rectangle", "ui.RadialProgressOverlay", "ui.Check", "ui.Slider",
                            "ui.InputField", "ui.List", "ui.ComboField", "ui.Carousel", "ui.RadioGroup" }) do
        component(name)
    end

    -- Plain value types.
    local function valueType(name, fields)
        local defaults = {}
        for _, f in ipairs(fields) do defaults[f] = 0 end
        namespaces[string.sub(name, 4)] = Docs.class(name, {
            defaults = defaults,
            statics = {
                new = function(...)
                    local n, init = select("#", ...), {}
                    local first = (select(1, ...))
                    if n == 1 and Core.isA(first, name) then
                        for _, f in ipairs(fields) do init[f] = Core.getRaw(first, f) end
                    elseif n == 1 and name == "ui.Margin" then
                        for _, f in ipairs(fields) do init[f] = first end
                    else
                        for i, f in ipairs(fields) do init[f] = select(i, ...) or 0 end
                    end
                    return Core.new(name, init)
                end,
            },
        })
    end
    valueType("ui.Pos", { "x", "y", "xParentPc", "yParentPc", "xSelfPc", "ySelfPc" })
    valueType("ui.Size", { "width", "height", "widthParentPc", "heightParentPc" })
    valueType("ui.Margin", { "left", "top", "right", "bottom" })
    return namespaces
end

-- Creates a component the way ui.<Kind>.new does.
function M.create(className, parent, categoryID, dynamicID)
    if not Core.isA(parent, "ui.ComponentCollection") then
        error("rs3testkit: " .. className .. ".new(parent): parent must be a layout component " ..
            "(ui.Layer, ui.GroupBox, ui.Panel, ...), got " .. Core.typeName(parent), 3)
    end
    if Core.destroyed[parent] then
        error("rs3testkit: " .. className .. ".new(parent): parent was destroyed (" .. Core.destroyed[parent] .. ")", 3)
    end
    local pinfo = info[parent]
    if categoryID ~= nil and dynamicID ~= nil then
        for _, c in ipairs(pinfo.children) do
            if info[c].categoryID == categoryID and info[c].dynamicID == dynamicID then
                error("rs3testkit: " .. className .. ".new: parent already has a component with category " ..
                    categoryID .. " / dynamic " .. dynamicID, 3)
            end
        end
    end
    pinfo.nextDynamic = (pinfo.nextDynamic or -1) + 1
    local c = Core.new(className)
    info[c] = { parent = parent, children = {}, hooks = {}, elements = {},
                categoryID = categoryID or pinfo.categoryID or 0, dynamicID = dynamicID or pinfo.nextDynamic }
    table.insert(pinfo.children, c)
    all[#all + 1] = c
    return c
end

---------------------------------------------------------------------------
-- Interfaces
---------------------------------------------------------------------------
local function interfacesObject()
    Docs.class("ui.Interfaces", {
        impls = {
            GetComponent = function(_, combined, a, b)
                local c = statics[combined]
                if c and a == nil then return c end
                Core.warn("ui-component-missing", "ui.Interfaces:GetComponent(" .. tostring(combined) ..
                    (a and (", " .. tostring(a) .. ", " .. tostring(b)) or "") .. ") returned nil: the kit has only " ..
                    "the plugin layer; add others with kit.ui.addStatic(id, component)")
                return nil
            end,
            GetInterface = function(_, interfaceID)
                Core.warn("ui-interface-missing", "ui.Interfaces:GetInterface(" .. tostring(interfaceID) ..
                    ") returned nil: the kit does not model the client's built-in interfaces")
                return nil
            end,
        },
    })
    return Core.new("ui.Interfaces")
end

local function newRoot()
    local layer = Core.new("ui.Layer", { width = 1278, height = 1360 })
    info[layer] = { parent = nil, children = {}, hooks = {}, elements = {}, categoryID = 0, staticID = 0 }
    return layer
end

---------------------------------------------------------------------------
-- Lint: client behaviour a stand-in cannot show, checked after each test
---------------------------------------------------------------------------
local function eatenTags(s)
    -- Remove tags the client understands; any "<" left would be eaten as a tag.
    local rest = string.gsub(s, "<[/]?[%a]+=?[%w#_]*>", "")
    return string.find(rest, "<", 1, true) ~= nil
end

local function lint()
    for _, c in ipairs(all) do
        if isShown(c) then
            local cls = Core.classOf(c)
            if cls == "ui.Model" and Core.getRaw(c, "modelType") ~= 0 and
                ((Core.getRaw(c, "modelWidth") or 0) == 0 or (Core.getRaw(c, "modelHeight") or 0) == 0) then
                Core.warn("model-invisible", "a visible ui.Model has modelWidth/modelHeight 0, which draws nothing in the client")
            end
            -- A bare ui.Layer is an invisible container (often full screen):
            -- it must let clicks through, so only visible components count.
            if info[c].parent == root and cls ~= "ui.Layer" and Core.getRaw(c, "clickthrough") ~= false then
                Core.warn("clickthrough", "a visible " .. cls .. " on the plugin layer has clickthrough = true: " ..
                    "clicks on it also reach the game world (and walk the player)")
            end
            local hooks = info[c].hooks
            if (hooks[0] and #hooks[0] > 0 or hooks[49] and #hooks[49] > 0) and Core.getRaw(c, "clickthrough") ~= false then
                Core.warn("clickthrough", "a clickable " .. cls .. " has clickthrough = true: clicks also reach the game world")
            end
            local text = (cls == "ui.Text" and Core.getRaw(c, "content")) or (cls == "ui.Button" and Core.getRaw(c, "label"))
            if type(text) == "string" and eatenTags(text) then
                Core.warn("text-tag", string.format("%q contains '<', which the client reads as the start of a tag and does not draw", text))
            end
        end
    end
end

---------------------------------------------------------------------------
-- Install
---------------------------------------------------------------------------
function M.install(api, kit)
    local ids = Ids.enums()
    enums = ids.ui
    local namespaces = defineClasses()
    root = newRoot()
    statics[kit.ids.PLUGIN_LAYER] = root

    local members = {}
    for k, v in pairs(namespaces) do members[k] = v end
    for k, v in pairs(ids.ui) do members[k] = v end
    members.Interfaces = interfacesObject()
    api.ui = Core.namespace("ui", { members = members })

    kit.ui = {}
    kit.ui._lintAfterTest = lint

    function kit.ui.root() return root end
    function kit.ui.isShown(c) return isShown(c) end
    function kit.ui.all()
        local out = {}
        for _, c in ipairs(all) do if not Core.destroyed[c] then out[#out + 1] = c end end
        return out
    end
    function kit.ui.count() return #kit.ui.all() end
    function kit.ui.find(pred)
        for _, c in ipairs(all) do
            if not Core.destroyed[c] and pred(c, Core.classOf(c)) then return c end
        end
    end
    function kit.ui.findAll(pred)
        local out = {}
        for _, c in ipairs(all) do
            if not Core.destroyed[c] and pred(c, Core.classOf(c)) then out[#out + 1] = c end
        end
        return out
    end
    function kit.ui.kind(c) return Core.classOf(c) end
    function kit.ui.parent(c) return info[c].parent end
    function kit.ui.children(c) return info[c].children end
    function kit.ui.get(c, prop) return Core.getRaw(c, prop) end

    -- Contents of every visible, non-empty ui.Text, in creation order.
    function kit.ui.texts()
        local out = {}
        for _, c in ipairs(all) do
            if Core.classOf(c) == "ui.Text" and isShown(c) then
                local s = Core.getRaw(c, "content")
                if s and s ~= "" then out[#out + 1] = s end
            end
        end
        return out
    end

    -- Strips client text tags such as <col=ffff00>.
    function kit.ui.plain(s) return (string.gsub(s or "", "<[^>]*>", "")) end

    -- The visible button whose label is `label` (or starts with it when
    -- prefix = true). nil if none.
    function kit.ui.button(label, prefix)
        for _, c in ipairs(all) do
            if Core.classOf(c) == "ui.Button" and isShown(c) then
                local l = Core.getRaw(c, "label") or ""
                if l == label or (prefix and string.sub(l, 1, #label) == label) then return c end
            end
        end
    end

    -- The visible Text with this content; one with an ONCLICK listener wins
    -- (a row's name over a heading that says the same thing).
    local function shownTextNamed(content)
        local first
        for _, c in ipairs(all) do
            if Core.classOf(c) == "ui.Text" and isShown(c) and Core.getRaw(c, "content") == content then
                local clicks = info[c].hooks[0]
                if clicks and #clicks > 0 then return c end
                first = first or c
            end
        end
        return first
    end

    local function usable(c, what)
        if c == nil then error("kit.ui." .. what .. ": no such visible component", 3) end
        if not isShown(c) then error("kit.ui." .. what .. ": the " .. Core.classOf(c) .. " is hidden; a player cannot reach it", 3) end
        if Core.getRaw(c, "enabled") == false then error("kit.ui." .. what .. ": the " .. Core.classOf(c) .. " is disabled", 3) end
    end

    -- Presses a button (by label, prefix match, or component).
    function kit.ui.press(target)
        local c = type(target) == "string" and (kit.ui.button(target) or kit.ui.button(target, true)) or target
        if c == nil then error("kit.ui.press: no visible button labelled " .. tostring(target), 2) end
        usable(c, "press")
        local old = Core.getRaw(c, "isToggled") and 1 or 0
        local new = 1
        if Core.getRaw(c, "canToggle") then
            new = 1 - old
            Core.setRaw(c, "isToggled", new == 1)
        end
        if not fireHook(c, 49, new, old) then   -- ONBUTTONPRESSED
            Core.warn("press-no-listener", "pressed " .. Core.classOf(c) .. " '" .. tostring(Core.getRaw(c, "label")) ..
                "' but it has no ONBUTTONPRESSED listener")
        end
    end

    -- Clicks a component (ONCLICK), or the visible Text with that content.
    function kit.ui.click(target, x, y)
        local c = type(target) == "string" and shownTextNamed(target) or target
        if c == nil then error("kit.ui.click: no visible text " .. tostring(target), 2) end
        usable(c, "click")
        if not fireHook(c, 0, x or 0, y or 0) then
            error("kit.ui.click: the " .. Core.classOf(c) .. " has no ONCLICK listener (nothing would happen)", 2)
        end
    end

    -- Drags a component from (x1, y1) to (x2, y2): ONDRAG then ONDRAGCOMPLETE.
    function kit.ui.drag(c, x1, y1, x2, y2)
        usable(c, "drag")
        fireHook(c, 7, x1, y1)
        fireHook(c, 8, nil, x2, y2)
    end

    -- Fires any hook by name with the documented arguments after self.
    function kit.ui.fire(c, hookName, ...)
        return fireHook(c, enums.Hook[hookName], ...)
    end

    -- Recorded calls of void visual methods (SetHeaderLayout, AlignTo, ...).
    function kit.ui.calls(c)
        return Docs.recordedCalls[c] or {}
    end

    -- Elements drawn on a ui.Canvas: { { kind = "AddLine", args = {...} }, ... }
    function kit.ui.canvas(c) return info[c].elements end

    -- Registers a component as a static one ui.Interfaces:GetComponent finds.
    function kit.ui.addStatic(combinedID, className)
        local c = Core.new(className or "ui.Layer", { width = 1278, height = 1360 })
        info[c] = { parent = nil, children = {}, hooks = {}, elements = {}, categoryID = 0, staticID = combinedID }
        statics[combinedID] = c
        return c
    end

    -- The tree as indented text, for debugging a failing spec.
    function kit.ui.dump(c, depth)
        c, depth = c or root, depth or 0
        local cls = Core.classOf(c)
        local line = string.rep("  ", depth) .. cls
        local extra = Core.getRaw(c, "content") or Core.getRaw(c, "label")
        if extra and extra ~= "" then line = line .. " " .. string.format("%q", extra) end
        if Core.getRaw(c, "hidden") then line = line .. " (hidden)" end
        local lines = { line }
        for _, child in ipairs(info[c].children) do lines[#lines + 1] = kit.ui.dump(child, depth + 1) end
        return table.concat(lines, "\n")
    end
end

return M
