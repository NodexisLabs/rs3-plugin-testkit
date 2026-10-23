"""Self-tests for the kit: the mock must fail loudly where the client would,
and pass where the client would.

Each case writes a tiny plugin and a spec into a temp folder and runs it
through a fresh Session. Run: python -m unittest discover -s tests
"""

from __future__ import annotations

import json
import tempfile
import textwrap
import unittest
from pathlib import Path

from rs3testkit.host import KitError, Session


def make_plugin(root: Path, main: str, manifest: dict | None = None, name: str = "plugin",
                files: dict[str, str] | None = None) -> Path:
    d = root / name
    d.mkdir(parents=True, exist_ok=True)
    m = {"name": name.title(), "version": "1.0.0", "contactEmailAddress": "dev@nodexis.test", "dependencies": {}}
    m.update(manifest or {})
    (d / "plugin.json").write_text(json.dumps(m), encoding="utf-8")
    (d / "main.lua").write_text(textwrap.dedent(main), encoding="utf-8")
    for rel, text in (files or {}).items():
        p = d / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(textwrap.dedent(text), encoding="utf-8")
    return d


class KitCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def run_spec(self, main: str, spec: str, manifest: dict | None = None, files=None, plugin_dir=None):
        d = plugin_dir or make_plugin(self.root, main, manifest, files=files)
        spec_path = self.root / "case_spec.lua"
        spec_path.write_text(textwrap.dedent(spec), encoding="utf-8")
        return Session(d).run_spec(spec_path)

    def assertPasses(self, results):
        failed = [r for r in results if not r["ok"]]
        self.assertFalse(failed, "\n".join(f"{r['name']}: {r['error']}" for r in failed))

    def assertFailsWith(self, results, needle):
        failed = [r for r in results if not r["ok"]]
        self.assertTrue(failed, "expected a failing test")
        self.assertIn(needle, failed[0]["error"])


class FailsLoud(KitCase):
    def test_undocumented_function(self):
        r = self.run_spec("", """
            kit.start()
            test("x", function() Player.GetLevel(SkillType.MINING) end)
        """)
        self.assertFailsWith(r, "Player.GetLevel is not part of the documented plugin API")

    def test_documented_but_not_mocked(self):
        r = self.run_spec("", """
            kit.start()
            test("x", function() World.GetGroundHeight(0, 1, 1) end)
        """)
        self.assertFailsWith(r, "World.GetGroundHeight is in the documented API but the kit does not mock it yet")

    def test_colon_on_static_function(self):
        r = self.run_spec("", """
            kit.start()
            test("x", function() Player:GetRunEnergy() end)
        """)
        self.assertFailsWith(r, "call it with '.', not ':'")

    def test_dot_on_method(self):
        r = self.run_spec("", """
            kit.start()
            test("x", function() PersistentDB.GetInt("k") end)
        """)
        self.assertFailsWith(r, "call it with ':', not '.'")

    def test_wrong_argument_types(self):
        r = self.run_spec("""
            local layer = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
            local t = ui.Text.new(layer)
            t:SetPos("left", 10)
        """, """
            test("x", function() kit.start() end)
        """)
        self.assertFailsWith(r, "no matching function call")

    def test_undefined_global_is_nil_and_reported(self):
        r = self.run_spec("""
            count = (count or 0) + 1      -- the usual idiom works, as in the client
            local x = myTypo.value        -- fails as Lua does, and the lint names it
        """, """
            test("x", function() kit.start() end)
        """)
        self.assertFailsWith(r, "attempt to index a nil value (global 'myTypo')")
        lints = " ".join(r[0]["warnings"])
        self.assertIn("read global 'myTypo', which is not defined", lints)
        self.assertIn("read global 'count'", lints)

    def test_removed_stdlib(self):
        r = self.run_spec("local clock = os and os.clock", 'test("x", function() kit.start() end)')
        self.assertTrue(r[0]["ok"])
        self.assertIn("global 'os', which is not available in the plugin sandbox", " ".join(r[0]["warnings"]))

    def test_strict_globals_option(self):
        r = self.run_spec("local t = os.time()", """
            kit.sandbox.strictGlobals = true
            test("x", function() kit.start() end)
        """)
        self.assertFailsWith(r, "global 'os' is not available in the plugin sandbox")

    def test_sprite_quantity_argument(self):
        r = self.run_spec("""
            local layer = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
            local s = ui.Sprite.new(layer)
            s:SetAssociatedObject(995, 1000)
        """, 'test("x", function() kit.start() end)')
        self.assertFailsWith(r, "rejects the quantity argument")

    def test_model_rotation(self):
        r = self.run_spec("""
            local layer = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
            local m = ui.Model.new(layer)
            m.rotation = Vector3.new(0, 512, 0)
        """, 'test("x", function() kit.start() end)')
        self.assertFailsWith(r, "Vector3T<int>")

    def test_readonly_and_unknown_properties(self):
        r = self.run_spec("""
            local layer = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
            text = ui.Text.new(layer)
        """, """
            kit.start()
            local t = kit.env().text
            test("readonly", function() t.width = 5 end)
            test("typo", function() t.contnet = "hi" end)
            test("type", function() t.content = 42 end)
        """)
        self.assertEqual([x["ok"] for x in r], [False, False, False])
        self.assertIn("read-only", r[0]["error"])
        self.assertIn("has no property 'contnet'", r[1]["error"])
        self.assertIn("expected string", r[2]["error"])

    def test_unknown_enum_member(self):
        r = self.run_spec("local a = ui.AlignMode.LEFT", 'test("x", function() kit.start() end)')
        self.assertFailsWith(r, "ui.AlignMode.LEFT")

    def test_event_handler_error_names_the_handler(self):
        r = self.run_spec("""
            Event.Logic.Subscribe("ticker", function(e) error("boom") end)
        """, """
            kit.start()
            test("x", function() kit.tick() end)
        """)
        self.assertFailsWith(r, "Event.Logic handler 'ticker'")

    def test_event_payload_typo(self):
        r = self.run_spec("""
            Event.SkillTransmit.Subscribe("s", function(e) local x = e.newXp end)
        """, """
            kit.start()
            test("x", function() kit.player.gainXP("MINING", 10) end)
        """)
        self.assertFailsWith(r, "newXp")

    def test_entity_draw_must_return_boolean(self):
        r = self.run_spec("""
            Event.EntityDraw.Subscribe("d", function(e) end)
        """, """
            kit.start()
            test("x", function() kit.events.fire("EntityDraw", { entityType = EntityType.NPC }) end)
        """)
        self.assertFailsWith(r, "must return true")

    def test_minimenu_add_outside_events(self):
        r = self.run_spec("""
            Event.MiniMenuEntrySelected.Subscribe("s", function(e) saved = e end)
            Event.MiniMenuOpened.Subscribe("o", function(e) e.miniMenu:Add("Late", function() end) end)
        """, """
            kit.start()
            test("x", function() kit.menu.open({ kit.menu.entry{ npc = 1, name = "Man", verb = "Talk-to" } }) end)
        """)
        self.assertFailsWith(r, "only available during Event.MiniMenuEntryAdded")

    def test_missing_module(self):
        r = self.run_spec('local v = require("views")', 'test("x", function() kit.start() end)')
        self.assertFailsWith(r, "module 'views' not found")

    def test_unset_config_property(self):
        r = self.run_spec("", """
            kit.config.npc(81, { name = "Cow" })
            kit.start()
            test("x", function() local g = config.NPC.FromID(81).gridSize end)
        """)
        self.assertFailsWith(r, "NPCType.gridSize")

    def test_unknown_config_id(self):
        r = self.run_spec("", """
            kit.start()
            test("x", function() config.NPC.FromID(81) end)
        """)
        self.assertFailsWith(r, "config.NPC.FromID(81): the spec defined no such config")

    def test_player_unavailable(self):
        r = self.run_spec("", """
            kit.player.set{ available = false }
            kit.start()
            test("x", function() Player.GetRunEnergy() end)
        """)
        self.assertFailsWith(r, "Player.IsAvailable() is false")

    def test_removed_entity(self):
        r = self.run_spec("", """
            kit.start()
            local n = kit.world.addNpc{ id = 1, name = "Man" }
            kit.world.remove(n)
            test("valid", function() expect(n.isValid).toBe(false) end)
            test("read", function() local x = n.displayName end)
        """)
        self.assertTrue(r[0]["ok"])
        self.assertIn("check isValid first", r[1]["error"])


class Http(KitCase):
    MAIN = """
        Event.Logic.Subscribe("poll", function(e)
            if e.logicTick % 50 ~= 0 then return end
            HTTPRequest.new(Plugin.urls.api, "/prices"):Get(function(req)
                last = { ok = req.successful, body = req.data, code = req.responseCode }
            end)
        end)
    """
    MANIFEST = {"optionalPermissions": ["httpAccess"], "urls": {"api": "https://api.example.test"}}

    def test_needs_permission(self):
        r = self.run_spec(self.MAIN, """
            kit.start()
            test("x", function() kit.tick(60) end)
        """, self.MANIFEST)
        self.assertFailsWith(r, "needs the httpAccess permission")

    def test_route_delivered_on_next_tick_and_counted(self):
        r = self.run_spec(self.MAIN, """
            kit.start()
            kit.permissions.grant("httpAccess")
            kit.http.respond("GET", "https://api.example.test/prices", { status = 200, body = "42" })
            test("x", function()
                kit.events.setLogicTick(49)
                kit.tick()          -- tick 50 sends
                expect(kit.env().last).toBeNil()
                kit.tick()          -- delivered at the start of the next tick
                expect(kit.env().last.body).toBe("42")
                expect(kit.http.count("GET https://api.example.test/prices")).toBe(1)
            end)
        """, self.MANIFEST)
        self.assertPasses(r)

    def test_unrouted_request_fails(self):
        r = self.run_spec(self.MAIN, """
            kit.start()
            kit.permissions.grant("httpAccess")
            test("x", function() kit.tick(52) end)
        """, self.MANIFEST)
        self.assertFailsWith(r, "no kit.http.respond route")

    def test_base_url_must_be_declared(self):
        r = self.run_spec("""
            HTTPRequest.new("https://evil.example.test", "/x")
        """, 'kit.permissions.grant("httpAccess"); test("x", function() kit.start() end)', self.MANIFEST)
        self.assertFailsWith(r, "is not one of the plugin's manifest")


class Lint(KitCase):
    def test_clickthrough_and_invisible_model_and_tags(self):
        r = self.run_spec("""
            local layer = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
            local box = ui.GroupBox.new(layer)
            local t = ui.Text.new(box)
            t.content = "<- Back"
            local m = ui.Model.new(box)
            m:SetModel(ui.ModelType.NPC_MODEL, 81)
        """, """
            test("x", function() kit.start() end)
        """)
        codes = " ".join(r[0]["warnings"])
        self.assertIn("clickthrough", codes)
        self.assertIn("model-invisible", codes)
        self.assertIn("text-tag", codes)


class Loading(KitCase):
    def test_dependency_exposed_under_its_key(self):
        make_plugin(self.root, "return { answer = 42 }", name="lib")
        d = make_plugin(self.root, "result = Lib.answer", {"dependencies": {"Lib": "lib"}}, name="app")
        r = self.run_spec("", """
            kit.start()
            test("x", function() expect(kit.env().result).toBe(42) end)
        """, plugin_dir=d)
        self.assertPasses(r)

    def test_missing_dependency_is_a_setup_error(self):
        d = make_plugin(self.root, "", {"dependencies": {"Lib": "nowhere"}}, name="app")
        with self.assertRaises(KitError):
            Session(d)

    def test_missing_optional_dependency_reads_nil(self):
        d = make_plugin(self.root, "present = (Graphs ~= nil)", {"optionalDependencies": {"Graphs": "graph-lib"}}, name="app")
        r = self.run_spec("", """
            kit.start()
            test("x", function() expect(kit.env().present).toBe(false) end)
        """, plugin_dir=d)
        self.assertPasses(r)

    def test_persistent_db_round_trip_and_type_lint(self):
        r = self.run_spec("""
            PersistentDB:SetInt("n", 3)
            PersistentDB:SetStructuredData("t", { a = 1 })
            n = PersistentDB:GetInt("n")
            wrong = PersistentDB:GetString("n")
        """, """
            kit.start()
            test("x", function()
                expect(kit.env().n).toBe(3)
                expect(kit.env().wrong).toBeNil()
                expect(kit.db.get("t")).toEqual({ a = 1 })
            end)
        """)
        self.assertPasses(r)
        self.assertIn("db-type", " ".join(r[0]["warnings"]) + " ".join(
            w for x in r for w in x["warnings"]))

    def test_resources_table(self):
        d = make_plugin(self.root, "img = Plugin.resources.images.icon", name="res")
        (d / "resources" / "images").mkdir(parents=True)
        (d / "resources" / "images" / "icon.png").write_bytes(b"\x89PNG")
        r = self.run_spec("", """
            kit.start()
            test("x", function() expect(kit.env().img.path).toContain("icon.png") end)
        """, plugin_dir=d)
        self.assertPasses(r)


class FixturesWork(KitCase):
    """Every documented fixture runs once, end to end."""

    def test_game_state_fixtures(self):
        r = self.run_spec("""
            Event.GrandExchangeOfferUpdated.Subscribe("ge", function(e) geSlot = e.slot; gePrice = e.listing.price end)
            Event.InventoryUpdated.Subscribe("inv", function(e) invSlots = e.slotsUpdated end)
            Event.ChatMessage.Subscribe("chat", function(e) lastChat = e.chatMessage end)
            Event.KeyDown.Subscribe("key", function(e) lastKey = e.gameKey end)
            Event.Draw.Subscribe("draw", function(e) frames = (frames or 0) + 1 end)
            Event.ServerLogic.Subscribe("server", function() serverTicks = (serverTicks or 0) + 1 end)
        """, """
            kit.start()
            test("player and world", function()
                kit.player.set{ levels = { ATTACK = 99 }, boosted = { ATTACK = 110 }, runEnergy = 55 }
                expect(Player.GetLevelGameplay(SkillType.ATTACK)).toBe(110)
                expect(Player.GetXPUncapped(SkillType.ATTACK)).toBe(13034431)
                expect(Player.GetRunEnergy()).toBe(55)
                expect(Player.GetTrackingID()).toBeNil()      -- no trackingAccess
                kit.player.set{ capped = { ATTACK = 60 } }
                expect(Player.GetLevelCapped(SkillType.ATTACK)).toBe(60)
                kit.player.moveTo{ x = 3200, z = 3200 }
                local me = Player.GetEntity()
                expect(me.coordGrid.x).toBe(3200)
                kit.world.addNpc{ id = 81, name = "Cow", coord = { x = 3203, z = 3201 } }
                kit.world.addNpc{ id = 2, name = "Man", coord = { x = 3300, z = 3300 } }
                expect(#NPCList.ByDistance(me.coordGrid, 5)).toBe(1)
                expect(#NPCList.ByName("c*")).toBe(1)
                expect(#NPCList.Filter{ name = "man", configID = 2 }).toBe(1)
                expect(tostring(me.coordGrid)).toBe("0,50,50,0,0")
                expect(CoordGrid.new(me.coordGrid:ToPacked()).x).toBe(3200)
            end)
            test("inventories and the GE", function()
                kit.inventory.set(93, { { 995, 1000 }, false, { 1511, 1 } })
                local inv = Inventory.Find(93)
                expect(inv:GetTotal(995)).toBe(1000)
                expect(inv.freeSlotCount).toBe(26)
                kit.inventory.setSlot(93, 2, 1511, 1)
                expect(kit.env().invSlots).toEqual({ 2 })
                kit.ge.setOffer(1, { type = "SELL", item = 536, price = 2100, itemCount = 50 })
                expect(kit.env().gePrice).toBe(2100)
                expect(GrandExchange.GetOffer(2).stage).toBe(GrandExchangeOfferStage.EMPTY)
                expect(GrandExchange.GetOffer(9)).toBeNil()
            end)
            test("time, input, chat and audio", function()
                kit.seconds(1.2)
                expect(kit.env().serverTicks >= 1).toBeTruthy()
                kit.draw(3)
                expect(kit.env().frames).toBe(3)
                kit.keyboard.press("A")
                expect(kit.env().lastKey).toBe(GameKey.A)
                kit.chat.receive{ text = "hi" }
                expect(kit.env().lastChat).toBeNil()      -- no chatAccess
                kit.mouse.set(10, 20)
                expect(Mouse.GetX()).toBe(10)
                local s = audio.Play(1234)
                expect(s.isPlaying).toBe(true)
                expect(#kit.audio.played()).toBe(1)
            end)
            test("kit.mock fills a gap", function()
                kit.mock("World.GetGroundHeight", function() return 128, true end)
                local h, ok = World.GetGroundHeight(0, 512, 512)
                expect(h).toBe(128)
            end)
        """)
        self.assertPasses(r)

    def test_chat_with_permission(self):
        r = self.run_spec("""
            Event.ChatMessage.Subscribe("chat", function(e) lastChat = e.chatMessage end)
            Chat.AddMessage("posted")
        """, """
            kit.start()
            test("x", function()
                kit.tick()
                expect(kit.env().lastChat).toBe("posted")
            end)
        """, {"requiredPermissions": ["chatAccess"]})
        self.assertPasses(r)


class ProteusFeedback(KitCase):
    """Gaps found moving Proteus onto the kit (2026-10-21)."""

    def test_structured_data_with_strings(self):
        r = self.run_spec("""
            ok = PersistentDB:SetStructuredData("layout", { mode = "open", windows = { { title = "Tree" } } })
        """, """
            kit.start()
            test("x", function()
                expect(kit.env().ok).toBe(true)
                expect(kit.db.get("layout").windows[1].title).toBe("Tree")
            end)
        """)
        self.assertPasses(r)

    def test_hold_and_hover_drive_polling_code(self):
        r = self.run_spec("""
            local top = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
            handle = ui.GroupBox.new(top)
            handle.clickthrough = false
            handle:Subscribe(ui.Hook.ONRELEASE, function() released = true end)
            Event.Logic.Subscribe("drag", function()
                if handle.isClicked then lastX = Mouse.GetX() end
                hovering = handle.isMouseOver
            end)
        """, """
            kit.start()
            test("x", function()
                local h = kit.env().handle
                kit.mouse.set(10, 10)
                kit.ui.hover(h)
                kit.ui.hold(h)
                kit.mouse.set(60, 10)
                kit.tick()
                expect(kit.env().lastX).toBe(60)
                expect(kit.env().hovering).toBe(true)
                kit.ui.hold(h, false)
                expect(kit.env().released).toBe(true)
                expect(h.isClicked).toBe(false)
            end)
        """)
        self.assertPasses(r)

    def test_mock_on_an_object_points_at_mockMethod(self):
        r = self.run_spec("", """
            kit.start()
            test("x", function() kit.mock("PersistentDB.GetInt", function() return 1 end) end)
        """)
        self.assertFailsWith(r, 'kit.mockMethod("PersistentDB", "GetInt", fn)')

    def test_fonts_by_name_and_measuring(self):
        r = self.run_spec("""
            local font = config.Font.MUSEO_SANS_13PT_REGULAR
            fontName = font.configName
            width = font:GetStringWidth("Hello")
        """, """
            kit.fonts.measureWith(function(font, text) return #text * 7 end)
            kit.start()
            test("x", function()
                expect(kit.env().fontName).toBe("MUSEO_SANS_13PT_REGULAR")
                expect(kit.env().width).toBe(35)
            end)
        """)
        self.assertPasses(r)

    def test_measuring_without_a_rule_fails_loudly(self):
        r = self.run_spec("""
            local w = config.Font.MUSEO_SANS_13PT_REGULAR:GetStringWidth("Hi")
        """, 'test("x", function() kit.start() end)')
        self.assertFailsWith(r, "kit.fonts.measureWith")


class LiveClientFindings(KitCase):
    """Behaviour measured in the beta client on 2026-10-21."""

    def test_component_hidden_by_its_own_press_stays_clicked(self):
        r = self.run_spec("""
            local top = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
            box = ui.GroupBox.new(top)
            box.clickthrough = false
            close = ui.Button.new(box)
            close.clickthrough = false
            close.label = "X"
            close:Subscribe(ui.Hook.ONBUTTONPRESSED, function() box.hidden = true end)
        """, """
            kit.start()
            test("x", function()
                kit.ui.press("X")
                local close = kit.env().close
                expect(close.isClicked).toBe(true)          -- the release never arrives
                kit.ui.hold(close, false)
                expect(close.isClicked).toBe(true)
            end)
        """)
        self.assertPasses(r)
        self.assertIn("sticky-isClicked", " ".join(r[0]["warnings"]))

    def test_drag_hooks_never_fire_live(self):
        r = self.run_spec("""
            local top = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
            bar = ui.GroupBox.new(top)
            bar.clickthrough = false
            bar.dragConfig.deadZone = 5
            bar.dragConfig.renderBehaviour = ui.DragRenderBehaviour.INVISIBLE
            bar:Subscribe(ui.Hook.ONDRAG, function() end)
        """, """
            kit.start()
            test("config fields", function() expect(kit.env().bar.dragConfig.deadZone).toBe(5) end)
            test("drag refused", function() kit.ui.drag(kit.env().bar, 0, 0, 40, 0) end)
        """)
        self.assertTrue(r[0]["ok"], r[0]["error"])
        self.assertIn("drag-hook-dead", " ".join(r[0]["warnings"]))
        self.assertIn("never fires ONDRAG", r[1]["error"])


POINTER_UI = """
    local top = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
    win = ui.GroupBox.new(top)          -- a window at (100, 100), 200 x 150
    win.clickthrough = false
    win:SetPos(100, 100); win:SetSize(200, 150)
    title = ui.Text.new(win)            -- its title bar, 200 x 20
    title.clickthrough = false
    title:SetPos(0, 0); title:SetSize(200, 20)
    released = 0
    title:Subscribe(ui.Hook.ONRELEASE, function() released = released + 1 end)
    other = ui.GroupBox.new(top)        -- a second window, off to the right
    other.clickthrough = false
    other:SetPos(400, 100); other:SetSize(100, 100)
    overhang = ui.Text.new(win)         -- sticks out past the window's right edge
    overhang.clickthrough = false
    overhang:SetPos(150, 50); overhang:SetSize(200, 20)
    Event.Logic.Subscribe("drag", function()
        if title.isClicked then lastX = Mouse.GetX() end
    end)
"""


class Pointer(KitCase):
    """kit.pointer: the client's press rules as measured live."""

    def test_press_hits_the_topmost_and_release_fires(self):
        r = self.run_spec(POINTER_UI, """
            kit.start()
            test("x", function()
                local env = kit.env()
                expect(kit.pointer.topmost(150, 105)).toBe(env.title)
                expect(kit.pointer.topmost(150, 150)).toBe(env.win)
                expect(kit.pointer.topmost(5, 5)).toBeNil()
                expect(kit.pointer.press(150, 105)).toBe(env.title)
                kit.pointer.move(160, 108); kit.tick()
                expect(env.lastX).toBe(160)
                local r = kit.pointer.release()
                expect(r.released).toBe(true)
                expect(env.released).toBe(1)
                expect(env.title.isClicked).toBe(false)
            end)
        """)
        self.assertPasses(r)

    def test_children_only_take_the_cursor_inside_their_ancestors(self):
        r = self.run_spec(POINTER_UI, """
            kit.start()
            test("x", function()
                -- (320, 155) is on the overhang text but outside its window
                expect(kit.pointer.topmost(320, 155)).toBeNil()
                expect(kit.pointer.topmost(280, 155)).toBe(kit.env().overhang)
            end)
        """)
        self.assertPasses(r)

    def test_press_dropped_when_cursor_leaves_or_another_takes_it(self):
        r = self.run_spec(POINTER_UI, """
            kit.start()
            test("x", function()
                local env = kit.env()
                kit.pointer.press(150, 105)
                kit.pointer.move(450, 150)           -- over the other window
                local r = kit.pointer.release()
                expect(r.released).toBe(false)
                expect(r.dropped).toContain("took the cursor")
                expect(env.released).toBe(0)        -- no release for a dropped press
                expect(env.title.isClicked).toBe(false)
            end)
        """)
        self.assertPasses(r)

    def test_press_dropped_when_window_moves_to_front(self):
        r = self.run_spec(POINTER_UI + """
            Event.Draw.Subscribe("front", function() if title.isClicked then win:MoveToFront() end end)
        """, """
            kit.start()
            test("x", function()
                kit.pointer.press(150, 105)
                kit.draw()
                local r = kit.pointer.release()
                expect(r.dropped).toContain("reordered")
                expect(kit.ui.reorders(kit.env().win)).toBe(1)
                expect(kit.ui.calls(kit.env().win)[1].name).toBe("MoveToFront")
            end)
        """)
        self.assertPasses(r)

    def test_hidden_while_pressed_stays_clicked(self):
        r = self.run_spec(POINTER_UI + """
            title:Subscribe(ui.Hook.ONCLICK, function() win.hidden = true end)
        """, """
            kit.start()
            test("x", function()
                kit.pointer.press(150, 105)
                local r = kit.pointer.release()
                expect(r.sticky).toBe(true)
                expect(kit.env().title.isClicked).toBe(true)
            end)
        """)
        self.assertPasses(r)

    def test_component_type_values(self):
        r = self.run_spec("""
            local top = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
            layerType = ui.Layer.new(top).type
            boxType = ui.GroupBox.new(top).type
        """, """
            kit.start()
            test("x", function()
                expect(kit.env().layerType).toBe(20)
                expect(kit.env().boxType).toBe(24)
                expect(ui.ComponentType.BUTTON).toBe(9)
                expect(ui.ComponentType.FromID(19)).toBeNil()
            end)
        """)
        self.assertPasses(r)


class LintFalsePositives(KitCase):
    def test_container_layer_may_let_clicks_through(self):
        r = self.run_spec("""
            local top = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
            local root = ui.Layer.new(top)          -- full-screen container, clickthrough stays true
            local box = ui.GroupBox.new(root)
            box.clickthrough = false
        """, 'test("x", function() kit.start() end)')
        self.assertNotIn("clickthrough", " ".join(r[0]["warnings"]))


class StubIds(KitCase):
    """--ids reads id tables from a local clone of runescape-api-stubs."""

    def make_stubs(self) -> Path:
        csvs = self.root / "stubs" / "csvs"
        csvs.mkdir(parents=True)
        (csvs / "Font.csv").write_text("494,MUSEO_SANS_13PT_REGULAR,\n495,MUSEO_SANS_13PT_BOLD,\n", encoding="utf-8")
        (csvs / "NPC.csv").write_text("81,COW,\n11240,GOBLIN_LUMBRIDGE,\n", encoding="utf-8")
        (csvs / "VarPlayer.csv").write_text("-60917,SAFES_REWARD,INTEGER,7894,0x2000000,\n", encoding="utf-8")
        return self.root / "stubs"

    def test_lookups_come_from_the_clone(self):
        d = make_plugin(self.root, """
            font = id.Font.MUSEO_SANS_13PT_BOLD
            cow = id.NPC.COW
            name = id.NPC.FromID(11240)
            varp = id.VarPlayer.SAFES_REWARD
        """)
        spec = self.root / "ids_spec.lua"
        spec.write_text(textwrap.dedent("""
            kit.start()
            test("real numbers", function()
                local env = kit.env()
                expect(env.font).toBe(495)
                expect(env.cow).toBe(81)
                expect(env.name).toBe("GOBLIN_LUMBRIDGE")
                expect(env.varp).toBe(-60917)
                expect(kit.ids.source()).toContain("runescape-api-stubs")
            end)
            test("unknown names still fail loudly", function()
                expect(function() return id.NPC.NOT_A_REAL_NPC end).toError("not in the stub id tables either")
            end)
        """), encoding="utf-8")
        r = Session(d, ids=self.make_stubs()).run_spec(spec)
        self.assertPasses(r)

    def test_without_the_clone_the_error_points_at_it(self):
        r = self.run_spec("local cow = id.NPC.COW", 'test("x", function() kit.start() end)')
        self.assertFailsWith(r, "run with --ids <clone of runescape-api-stubs>")

    def test_bad_path_is_a_setup_error(self):
        d = make_plugin(self.root, "")
        with self.assertRaises(KitError):
            Session(d, ids=self.root / "nowhere")


class Activation(KitCase):
    def test_records_plugin_lines_and_calls_per_test(self):
        d = make_plugin(self.root, """
            local function greet(name)
                return "hi " .. name
            end
            Event.Logic.Subscribe("t", function(e) last = greet("tick") end)
        """)
        spec = self.root / "a_spec.lua"
        spec.write_text('kit.start()\ntest("ticks", function() kit.tick() end)\n', encoding="utf-8")
        s = Session(d)
        s.start_activation()
        self.assertTrue(s.run_spec(spec)[0]["ok"])
        events = s.activation_events()
        self.assertTrue(events)
        self.assertTrue(all(e["file"] == "main.lua" for e in events))     # kit and spec code excluded
        calls = [e for e in events if e["kind"] == "call" and e["test"] == "ticks"]
        self.assertIn("greet", [e["fn"] for e in calls])
        self.assertIn(3, [e["line"] for e in events if e["kind"] == "line" and e["test"] == "ticks"])


if __name__ == "__main__":
    unittest.main()
