-- XP Counter: an example plugin for the RS3 plugin test kit.
--
-- Counts the XP gained in each skill this session and shows the totals in a
-- small window. The totals are saved in PersistentDB so they survive a
-- relog; the Reset button clears them.
--
-- See ../spec/xp_counter_spec.lua for the tests that drive it offline.

local WINDOW_X, WINDOW_Y = 20, 200
local ROWS = 5

local gained = {}             -- skill id -> XP gained
local layer, box, title, rows, resetButton

-- Skill names by id, from the SkillType enum.
local function skillName(id)
    local name = SkillType.FromID(id) or tostring(id)
    return name:sub(1, 1) .. name:sub(2):lower()
end

local function save()
    local ok = PersistentDB:SetStructuredData("gained", gained)
    if not ok then print("[XP Counter] could not save totals") end
end

local function load()
    local saved = PersistentDB:GetStructuredData("gained")
    if saved then gained = saved end
end

-- Skills sorted by XP gained, largest first.
local function ranked()
    local list = {}
    for id, xp in pairs(gained) do list[#list + 1] = { id = id, xp = xp } end
    table.sort(list, function(a, b) return a.xp > b.xp end)
    return list
end

local function render()
    local list = ranked()
    title.content = (#list == 0) and "No XP gained yet" or "XP gained this session"
    for i = 1, ROWS do
        local row = list[i]
        rows[i].hidden = row == nil
        if row then rows[i].content = string.format("%s: %d xp", skillName(row.id), row.xp) end
    end
end

local function build()
    layer = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
    box = ui.GroupBox.new(layer)
    box.clickthrough = false
    box:SetPos(WINDOW_X, WINDOW_Y)
    box:SetSize(220, 40 + ROWS * 20 + 32)

    title = ui.Text.new(box)
    title.clickthrough = false
    title.font = id.Font.MUSEO_SANS_13PT_BOLD
    title:SetPos(10, 8)
    title:SetSize(200, 20)

    rows = {}
    for i = 1, ROWS do
        local t = ui.Text.new(box)
        t.clickthrough = false
        t.font = id.Font.MUSEO_SANS_11PT_REGULAR
        t:SetPos(10, 30 + (i - 1) * 20)
        t:SetSize(200, 20)
        rows[i] = t
    end

    resetButton = ui.Button.new(box)
    resetButton.clickthrough = false
    resetButton.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
    resetButton.label = "Reset"
    resetButton:SetPos(10, 40 + ROWS * 20)
    resetButton:SetSize(80, 24)
    resetButton:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
        gained = {}
        save()
        render()
    end)
end

Event.SkillTransmit.Subscribe("xpCounter", function(e)
    local delta = e.newXP - e.oldXP
    if delta <= 0 then return end
    gained[e.skill] = (gained[e.skill] or 0) + delta
    save()
    render()
end)

load()
build()
render()
