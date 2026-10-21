-- Offline tests for the XP Counter example plugin.
-- Run from the repo root:  rs3test run examples/xp-counter/plugin examples/xp-counter/spec

kit.player.set{ levels = { MINING = 50, WOODCUTTING = 30 } }
kit.start()

test("starts with an empty window", function()
    expect(kit.ui.texts()).toEqual({ "No XP gained yet" })
end)

test("counts XP from skill updates", function()
    kit.player.gainXP("MINING", 35)
    kit.player.gainXP("MINING", 35)
    kit.player.gainXP("WOODCUTTING", 25)
    expect(kit.ui.texts()).toEqual({ "XP gained this session", "Mining: 70 xp", "Woodcutting: 25 xp" })
end)

test("the player's level follows the XP curve", function()
    expect(Player.GetLevelUncapped(SkillType.MINING)).toBe(50)
    -- Level 60 starts at 273,742 XP.
    kit.player.gainXP("MINING", 273742 - Player.GetXPUncapped(SkillType.MINING))
    expect(Player.GetLevelUncapped(SkillType.MINING)).toBe(60)
end)

test("totals are saved for the next session", function()
    local saved = kit.db.get("gained")
    expect(saved[SkillType.WOODCUTTING]).toBe(25)
end)

test("Reset clears the totals", function()
    kit.ui.press("Reset")
    expect(kit.ui.texts()).toEqual({ "No XP gained yet" })
    expect(kit.db.get("gained")).toEqual({})
end)

test("the window does not let clicks through to the game", function()
    for _, w in ipairs(kit.warnings()) do
        expect(w.code).notToContain("clickthrough")
    end
end)

test("calling a typo'd API fails loudly", function()
    expect(function() return Player.GetLevel(SkillType.MINING) end).toError("not part of the documented plugin API")
end)
