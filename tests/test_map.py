"""Behaviour map (rs3test map) self-tests.

Run: python -m unittest discover -s tests
"""

from __future__ import annotations

import io
import json
import tempfile
import textwrap
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

from rs3testkit.behaviour import END, START, MapError, render, select, splice
from rs3testkit.cli import main
from rs3testkit.host import Session

PLUGIN = """
    local Shop = require("shop")

    local function priceOf(item) local p = Shop.price(item); return p end

    local function onSkill(e)
        for _ = 1, 3 do priceOf("logs") end
        total = (total or 0) + 1
    end

    Event.SkillTransmit.Subscribe("tracker", onSkill)
"""
SHOP = """
    local Shop = {}
    function Shop.price(item) return #item end
    return Shop
"""
SPEC = """
    kit.start()
    scenario("Gaining XP prices the logs", function()
        kit.player.gainXP("WOODCUTTING", 25)
    end)
    test("the total is kept", function()
        expect(kit.env().total).toBe(1)
    end)
"""


class MapCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.plugin = self.root / "plugin"
        self.plugin.mkdir()
        (self.plugin / "plugin.json").write_text(json.dumps(
            {"name": "Tracker", "version": "1.2.0", "contactEmailAddress": "dev@nodexis.test", "dependencies": {}}))
        (self.plugin / "main.lua").write_text(textwrap.dedent(PLUGIN), encoding="utf-8")
        (self.plugin / "shop.lua").write_text(textwrap.dedent(SHOP), encoding="utf-8")
        self.spec = self.root / "tracker_spec.lua"
        self.spec.write_text(textwrap.dedent(SPEC), encoding="utf-8")

    def tearDown(self):
        self._tmp.cleanup()

    def record(self, spec_text=None):
        if spec_text is not None:
            self.spec.write_text(textwrap.dedent(spec_text), encoding="utf-8")
        s = Session(self.plugin)
        s.start_map()
        results = s.run_spec(self.spec)
        return results, s.map_result()

    def cli(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            try:
                code = main(list(argv))
            except SystemExit as e:
                code = e.code
        return code, out.getvalue(), err.getvalue()

    def test_tree_has_only_plugin_frames_merged_by_function(self):
        results, trees = self.record()
        scenario = next(t for t in trees if t["name"] == "Gaining XP prices the logs")
        entry = scenario["root"]["children"]
        self.assertEqual(len(entry), 1)
        self.assertEqual(entry[0]["role"], 'Event.SkillTransmit handler "tracker"')
        self.assertEqual(entry[0]["name"], "onSkill")
        price = entry[0]["children"][0]
        self.assertEqual((price["name"], price["count"]), ("priceOf", 3))       # loop merged
        shop = price["children"][0]
        self.assertEqual((shop["file"], shop["name"], shop["count"]), ("shop.lua", "Shop.price", 3))

    def test_scenario_marks_what_is_mapped(self):
        results, trees = self.record()
        picked = select(results, trees, None, include_load=True)
        self.assertEqual([p["name"] for p in picked], ["Loading the plugin", "Gaining XP prices the logs"])

    def test_scenario_that_runs_no_plugin_code_fails(self):
        results, trees = self.record("""
            kit.start()
            scenario("Only reads state", function() expect(Player.GetRunEnergy()).toBe(100) end)
        """)
        with self.assertRaisesRegex(MapError, "ran no plugin code"):
            select(results, trees, None, include_load=False)

    def test_failed_scenario_is_not_mapped(self):
        results, trees = self.record("""
            kit.start()
            scenario("Broken", function() kit.player.gainXP("WOODCUTTING", 1); expect(1).toBe(2) end)
        """)
        with self.assertRaisesRegex(MapError, "a scenario failed"):
            select(results, trees, None, include_load=False)

    def test_only_selects_by_name(self):
        results, trees = self.record()
        picked = select(results, trees, ["prices"], include_load=False)
        self.assertEqual([p["name"] for p in picked], ["Gaining XP prices the logs"])
        with self.assertRaisesRegex(MapError, "matched no test"):
            select(results, trees, ["nothing like this"], include_load=False)

    def test_markdown_folds_chains_and_counts(self):
        results, trees = self.record()
        md = render(select(results, trees, None, include_load=False), "Tracker", "1.2.0", "rs3test map plugin")
        self.assertIn(START, md)
        self.assertIn(END, md)
        self.assertIn('**Event.SkillTransmit handler "tracker"**: `onSkill` (main.lua:6) → '
                      '`priceOf` (main.lua:4) ×3 → `Shop.price` (shop.lua:3) ×3', md)
        self.assertIn("Tracker 1.2.0", md)
        self.assertNotIn("kit.lua", md)
        self.assertNotIn("events.lua", md)

    def test_cli_updates_readme_between_markers(self):
        readme = self.root / "README.md"
        readme.write_text(f"# Tracker\n\nIntro.\n\n{START}\nold\n{END}\n\nMore.\n", encoding="utf-8")
        code, out, err = self.cli("map", str(self.plugin), str(self.spec), "--readme", str(readme))
        self.assertEqual(code, 0, err)
        text = readme.read_text(encoding="utf-8")
        self.assertIn("Intro.", text)
        self.assertIn("More.", text)
        self.assertNotIn("old", text)
        self.assertIn("### Gaining XP prices the logs", text)

    def test_cli_refuses_readme_without_markers(self):
        readme = self.root / "README.md"
        readme.write_text("# Tracker\n", encoding="utf-8")
        code, out, err = self.cli("map", str(self.plugin), str(self.spec), "--readme", str(readme))
        self.assertEqual(code, 1)
        self.assertIn("no behaviour map markers", err)

    def test_splice_keeps_surrounding_text(self):
        text = splice(f"a\n{START}\nx\n{END}\nb\n", f"{START}\nnew\n{END}\n", "README.md")
        self.assertEqual(text, f"a\n{START}\nnew\n{END}\nb\n")


if __name__ == "__main__":
    unittest.main()
