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


if __name__ == "__main__":
    unittest.main()
