"""Manifest validator self-tests: each client rule, pass and fail.

Run: python -m unittest discover -s tests
"""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from rs3testkit.manifest import validate

GOOD = {"name": "Good", "version": "1.0.0", "contactEmailAddress": "dev@nodexis.test", "dependencies": {}}


class Manifest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        (self.dir / "main.lua").write_text("-- empty\n", encoding="utf-8")

    def tearDown(self):
        self._tmp.cleanup()

    def check(self, manifest, raw: str | None = None, release=False):
        (self.dir / "plugin.json").write_text(raw if raw is not None else json.dumps(manifest), encoding="utf-8")
        report, trace = validate(self.dir, release=release)
        return report, trace

    def codes(self, report, level="error"):
        return [f.code for f in report.findings if f.level == level]

    def test_good_manifest_is_accepted(self):
        report, trace = self.check(GOOD)
        self.assertEqual(report.disposition, "ACCEPT", [str(f) for f in report.findings])
        self.assertTrue(any("dependencies" in t for t in trace))

    def test_required_fields(self):
        for field in ("name", "version", "dependencies"):
            m = dict(GOOD)
            del m[field]
            report, _ = self.check(m)
            self.assertIn("missing-field", self.codes(report), field)
            self.assertEqual(report.disposition, "REJECT")

    def test_dependencies_must_be_a_dictionary(self):
        report, _ = self.check({**GOOD, "dependencies": []})
        self.assertIn("dependencies-not-object", self.codes(report))
        self.assertIn("unexpected json Array, expected a json Object", str(report.findings[0]))

    def test_dependency_values_are_names_or_ids(self):
        report, _ = self.check({**GOOD, "dependencies": {"Lib": "lib", "Remote": 12345}})
        self.assertEqual(self.codes(report), [])
        report, _ = self.check({**GOOD, "dependencies": {"Lib": ["lib"]}})
        self.assertIn("dependency-value", self.codes(report))
        report, _ = self.check({**GOOD, "dependencies": {"2!Lib": "lib"}})
        self.assertIn("dependency-key", self.codes(report))

    def test_documented_dependency_arrays_are_rejected(self):
        report, _ = self.check({**GOOD, "requiredDependencies": [], "optionalDependencies": []})
        self.assertEqual(self.codes(report).count("documented-dependency-array"), 2)

    def test_permissions_are_arrays(self):
        report, _ = self.check({**GOOD, "requiredPermissions": "httpAccess"})
        self.assertIn("permissions-not-array", self.codes(report))
        report, _ = self.check({**GOOD, "optionalPermissions": ["httpAccess"], "urls": {"api": "https://api.example.test"}})
        self.assertEqual(self.codes(report), [])

    def test_resources_png_and_ogg_only(self):
        res = self.dir / "resources" / "sounds"
        res.mkdir(parents=True)
        (res / "ding.ogg").write_bytes(b"OggS")
        (self.dir / "resources" / "icon.png").write_bytes(b"\x89PNG")
        report, _ = self.check(GOOD)
        self.assertEqual(self.codes(report), [])
        (res / "ding.wav").write_bytes(b"RIFF")
        report, _ = self.check(GOOD)
        self.assertIn("resource-type", self.codes(report))

    def test_url_rules(self):
        report, _ = self.check({**GOOD, "optionalPermissions": ["httpAccess"], "urls": {"x": "https://bit.ly/abc"}})
        self.assertIn("url-shortener", self.codes(report))
        report, _ = self.check({**GOOD, "optionalPermissions": ["httpAccess"], "urls": {"x": "ftp://host"}})
        self.assertIn("url-format", self.codes(report))
        report, _ = self.check({**GOOD, "optionalPermissions": ["httpAccess"]})
        self.assertIn("http-without-urls", self.codes(report, "warning"))

    def test_not_json_and_not_object(self):
        report, _ = self.check(None, raw="{ name: 1 }")
        self.assertIn("manifest-json", self.codes(report))
        report, _ = self.check(None, raw="[]")
        self.assertIn("manifest-not-object", self.codes(report))

    def test_placeholder_email_blocks_release_only(self):
        m = {**GOOD, "contactEmailAddress": "dev-only@example.invalid"}
        report, _ = self.check(m)
        self.assertEqual(report.disposition, "ESCALATE")
        report, _ = self.check(m, release=True)
        self.assertEqual(report.disposition, "REJECT")

    def test_main_lua_required(self):
        (self.dir / "main.lua").unlink()
        report, _ = self.check(GOOD)
        self.assertIn("main-missing", self.codes(report))


if __name__ == "__main__":
    unittest.main()
