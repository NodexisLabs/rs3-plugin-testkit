-- id.* tables and the API's enums.
--
-- id tables map game config names to numbers (id.StyleSheet.BUTTON_DEFAULT
-- is 96). The real tables are large game data. The kit carries the
-- stylesheets and font names seen in a live client (ids_observed.lua), and
-- with `--ids <clone of runescape-api-stubs>` it reads every table from that
-- clone (stubs.py). Anything still unknown raises an error that tells the
-- spec how to add it:
--
--   kit.ids.add("NPC", "GOBLIN", 11240)
--
-- Enums: values come from the docs where published, from a live client
-- where seen (ui.Hook, ui.AlignMode, ui.ModelType), otherwise the kit
-- numbers them in doc order (Docs.kitAssigned lists those).

local Core = require("core")
local Docs = require("docs")
local Observed = require("ids_observed")

local M = {}

-- id.Component entries are interface__component names. The plugin layer's
-- number is the one in the community stub tables (csvs/Component.csv).
local COMPONENTS = {
    TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP = 96797554,
}

-- The full id tables, when the host found a local clone of the LuaLS stubs
-- (--ids or RS3_API_STUBS). The host puts the bridge in package.loaded
-- before loading the kit: { active = true, number = fn, name = fn, kinds = {...} }.
local okBridge, Stubs = pcall(require, "stubsbridge")
if not okBridge then Stubs = { active = false } end
M.stubs = Stubs

local function fontTable()
    local entries = {}
    for i, name in ipairs(Observed.FontNames) do entries[name] = 1000 + i end
    return entries
end

-- Live values (2026-10-20). ui.Hook is a plain table in the client (pairs
-- lists it); the others keep members in the metatable.
local HOOKS = {
    ONBUTTONPRESSED = 49, ONCAMERAUPDATETRANSMIT = 33, ONCAMFINISHED = 41, ONCHATTRANSMIT = 23,
    ONCLANCHANNELTRANSMIT = 27, ONCLANSETTINGSTRANSMIT = 26, ONCLANTRANSMIT = 25, ONCLICK = 0,
    ONCLICKREPEAT = 1, ONCONTENTCHANGED = 50, ONCUTSCENEFINISHED = 53, ONDIALOGABORT = 39, ONDRAG = 7,
    ONDRAGCOMPLETE = 8, ONFRIENDTRANSMIT = 24, ONGAMEPADAXIS = 13, ONGAMEPADBUTTON = 11,
    ONGAMEPADBUTTONHELD = 12, ONGAMEPADTRIGGER = 14, ONHOLD = 3, ONINVTRANSMIT = 18, ONKEY = 10,
    ONMISCTRANSMIT = 29, ONMOUSELEAVE = 6, ONMOUSEOVER = 4, ONMOUSEREPEAT = 5, ONOP = 37, ONOPT = 38,
    ONPINCHCOMPLETE = 48, ONPINCHHORIZONTAL = 47, ONPINCHVERTICAL = 46, ONPLAYERGROUPTRANSMIT = 31,
    ONPLAYERGROUPVARPTRANSMIT = 32, ONPLUGINSEARCHEVENT = 55, ONPLUGINSTATUSEVENT = 56,
    ONRELATIONSHIPSETTRANSMIT = 28, ONRELEASE = 2, ONRESIZE = 42, ONSCROLLWHEEL = 9,
    ONSELECTIONCHANGED = 51, ONSTATTRANSMIT = 19, ONSTOCKTRANSMIT = 30, ONSUBCHANGE = 40,
    ONSWIPECOMPLETE = 45, ONSWIPEHORIZONTAL = 44, ONSWIPEVERTICAL = 43, ONTARGETENTER = 15,
    ONTARGETLEAVE = 16, ONTIMER = 36, ONUIANIMFINISHED = 54, ONVARCLANTRANSMIT = 22,
    ONVARCSTRTRANSMIT = 21, ONVARCTRANSMIT = 20, ONVARPTRANSMIT = 17,
}
local OBSERVED_ENUMS = {
    ["ui.AlignMode"] = { TOPLEFT = 0, CENTRE = 1, BOTTOMRIGHT = 2, JUSTIFY = 3 },
    ["ui.ModelType"] = { OBJECT = 4, NPC_MODEL = 6 },
    -- ui.ComponentType.FromID(0..30) in the beta client, 2026-10-21: 0-18 in
    -- doc order, 19 unused, then LAYER 20 .. GROUP_BOX 24.
    ["ui.ComponentType"] = { LINE = 0, RECTANGLE = 1, LABEL = 2, SPRITE = 3, MODEL = 4, MODEL_GROUP = 5,
        RADIAL_PROGRESS_OVERLAY = 6, CUTSCENE_LAYER = 7, CANVAS = 8, BUTTON = 9, CHECK = 10, LIST = 11,
        INPUTFIELD = 12, SLIDER = 13, COMBO = 14, PAGED_LAYER_HEADER = 15, CAROUSEL = 16,
        PAGED_CAROUSEL = 17, RADIO_GROUP = 18, LAYER = 20, PANEL = 21, GRID = 22, PAGED_LAYER = 23,
        GROUP_BOX = 24 },
}

M.hookNames = {}
for name, value in pairs(HOOKS) do M.hookNames[value] = name end

-- Builds every documented enum; returns { globals = {...}, ui = {...}, audio = {...} }.
function M.enums()
    local out = { globals = {}, ui = {}, audio = {} }
    for name in pairs(Docs.data.enums) do
        local enum = Docs.enum(name, OBSERVED_ENUMS[name])
        local ns, short = string.match(name, "^(%w+)%.(%w+)$")
        if ns == "ui" then out.ui[short] = enum
        elseif ns == "audio" then out.audio[short] = enum
        elseif ns == nil then out.globals[name] = enum
        end
    end
    out.ui.Hook = Core.enum("ui.Hook", HOOKS, { listed = true })
    return out
end

function M.install(api, kit)
    local tables = {
        Component = Core.idTable("id.Component", COMPONENTS, Stubs),
        StyleSheet = Core.idTable("id.StyleSheet", Observed.StyleSheet, Stubs),
        -- Real font numbers come only from the stubs; without them the kit
        -- numbers the live font names itself.
        Font = Core.idTable("id.Font", Stubs.active and {} or fontTable(), Stubs),
    }
    -- Game config id tables: empty until a spec adds names or the stubs
    -- supply them.
    local kinds = { "NPC", "Obj", "Loc", "Seq", "Model", "Material", "Category", "Inv", "Var",
                    "DBTable", "DBRow", "Enum", "Struct", "Param", "Quest", "SpotAnim",
                    "Cursor", "MapElement", "Achievement", "BaseAnimSet", "Headbar", "Hitmark",
                    "Interface", "Music", "Sound", "Sprite", "VarClient", "VarPlayer", "VarPlayerGroup" }
    for _, k in ipairs(Stubs.kinds or {}) do kinds[#kinds + 1] = k end
    for _, kind in ipairs(kinds) do
        tables[kind] = tables[kind] or Core.idTable("id." .. kind, {}, Stubs)
    end
    api.id = Core.namespace("id", { members = tables })

    kit.ids = {}
    -- Adds a name -> number entry to an id table (id.<kind>.<name>).
    function kit.ids.add(kind, name, number)
        local t = tables[kind]
        if not t then error("kit.ids.add: no id table " .. tostring(kind), 2) end
        if type(name) ~= "string" or math.type(number) ~= "integer" then
            error("kit.ids.add(kind, name, number): name must be a string and number an integer", 2)
        end
        Core.idAdd(t, name, number)
    end
    -- The number of the plugin layer component.
    kit.ids.PLUGIN_LAYER = COMPONENTS.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP
    -- Whether the full stub id tables are loaded, and from which commit.
    function kit.ids.source()
        return Stubs.active and ("runescape-api-stubs @ " .. tostring(Stubs.revision)) or "kit seed tables only"
    end
end

return M
