"""Validate a plugin folder (plugin.json, main.lua, resources/) against the rules
the RS3 client enforces.

Several rules come from the client itself, not the docs, because the docs
were wrong in places at launch (October 2026):

* `dependencies` is required and must be a JSON object (a dictionary) mapping
  a global name to a plugin name (string) or a remote id (integer). An empty
  plugin still needs `"dependencies": {}`. The documented
  `requiredDependencies` / `optionalDependencies` arrays make the client fail
  with "unexpected json Array, expected a json Object".
* `name`, `version` and `dependencies` are the required fields (from the
  client's own error strings).
* Permission lists are arrays of names.
* Files in `resources/` may only be .png or .ogg.

`validate()` returns `(report, trace)`: the report holds the findings and a
disposition (REJECT = the client will refuse it, ESCALATE = loads but a human
should look, ACCEPT = clean); the trace lists every check that ran and what it
saw, so a pass can be audited, not just a failure.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path

REQUIRED_FIELDS = ("name", "version", "dependencies")

# Fields the kit knows about. Anything else is reported as a warning, not an
# error: the client may accept fields the kit has not seen.
KNOWN_FIELDS = {
    "name", "version", "dependencies", "contactEmailAddress", "description", "author",
    "requiredPermissions", "optionalPermissions", "permissions", "urls",
    "requiredDependencies", "optionalDependencies",
}
PERMISSION_FIELDS = ("requiredPermissions", "optionalPermissions", "permissions")
KNOWN_PERMISSIONS = {"chatAccess", "httpAccess"}
RESOURCE_EXTENSIONS = {".png", ".ogg"}

# Link shorteners are banned for declared URLs (plugin rules).
SHORTENERS = {
    "bit.ly", "tinyurl.com", "t.co", "goo.gl", "ow.ly", "is.gd", "buff.ly", "cutt.ly",
    "rb.gy", "shorturl.at", "tiny.cc", "rebrand.ly", "t.ly", "s.id", "v.gd",
}
PLACEHOLDER_EMAIL = re.compile(r"@(example\.(com|org|net|invalid)|.*\.invalid)$", re.I)
LARGE_FILE_BYTES = 5 * 1024 * 1024   # no published limit; large files are reported to break Hub installs


@dataclass
class Finding:
    level: str          # "error" or "warning"
    code: str
    message: str
    where: str = "plugin.json"

    def __str__(self) -> str:
        return f"{self.level.upper():7} {self.code}: {self.message} [{self.where}]"


@dataclass
class Report:
    plugin_dir: Path
    manifest: dict | None = None
    findings: list[Finding] = field(default_factory=list)

    @property
    def errors(self) -> list[Finding]:
        return [f for f in self.findings if f.level == "error"]

    @property
    def warnings(self) -> list[Finding]:
        return [f for f in self.findings if f.level == "warning"]

    @property
    def disposition(self) -> str:
        if self.errors:
            return "REJECT"
        if self.warnings:
            return "ESCALATE"
        return "ACCEPT"

    @property
    def ok(self) -> bool:
        return not self.errors


def _json_type(value) -> str:
    """Name a JSON value the way the client's parser does in its errors."""
    if isinstance(value, dict):
        return "Object"
    if isinstance(value, list):
        return "Array"
    if isinstance(value, bool):
        return "Boolean"
    if isinstance(value, (int, float)):
        return "Number"
    if value is None:
        return "Null"
    return "String"


def validate(plugin_dir: str | Path, release: bool = False) -> tuple[Report, list[str]]:
    """Check one plugin folder. `release=True` turns release-only warnings
    (placeholder contact email) into errors."""
    plugin_dir = Path(plugin_dir)
    report = Report(plugin_dir)
    trace: list[str] = []

    def error(code, message, where="plugin.json"):
        report.findings.append(Finding("error", code, message, where))
        trace.append(f"FAIL {code}: {message}")

    def warn(code, message, where="plugin.json"):
        report.findings.append(Finding("warning", code, message, where))
        trace.append(f"WARN {code}: {message}")

    def passed(check, detail=""):
        trace.append(f"ok   {check}" + (f" ({detail})" if detail else ""))

    # --- plugin.json parses as a JSON object -----------------------------
    path = plugin_dir / "plugin.json"
    if not path.is_file():
        error("manifest-missing", f"no plugin.json in {plugin_dir}")
        return report, trace
    raw = path.read_bytes()
    if raw.startswith(b"\xef\xbb\xbf"):
        warn("manifest-bom", "plugin.json starts with a UTF-8 byte-order mark; client behaviour is unverified, save it without one")
        raw = raw[3:]
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as e:
        error("manifest-encoding", f"plugin.json is not UTF-8: {e}")
        return report, trace

    duplicates: list[str] = []

    def pairs_hook(pairs):
        seen = {}
        for k, v in pairs:
            if k in seen:
                duplicates.append(k)
            seen[k] = v
        return seen

    try:
        manifest = json.loads(text, object_pairs_hook=pairs_hook)
    except json.JSONDecodeError as e:
        error("manifest-json", f"not valid JSON: {e.msg} at line {e.lineno} column {e.colno}")
        return report, trace
    passed("plugin.json is valid JSON")
    for k in duplicates:
        warn("duplicate-key", f'key "{k}" appears more than once; only the last one counts in most parsers')

    if not isinstance(manifest, dict):
        error("manifest-not-object", f"unexpected json {_json_type(manifest)}, expected a json Object (top level)")
        return report, trace
    report.manifest = manifest

    # --- required fields --------------------------------------------------
    for name in REQUIRED_FIELDS:
        if name not in manifest:
            hint = ""
            if name == "dependencies":
                hint = ' (required even with none: "dependencies": {})'
            error("missing-field", f'required field "{name}" is missing{hint}')
    for name in ("name", "version"):
        if name in manifest:
            value = manifest[name]
            if not isinstance(value, str):
                error("bad-type", f'"{name}": unexpected json {_json_type(value)}, expected a json String')
            elif not value.strip():
                error("empty-field", f'"{name}" is empty')
            else:
                passed(f'"{name}" is a non-empty string', value)
    version = manifest.get("version")
    if isinstance(version, str) and version.strip() and not re.fullmatch(r"\d+(\.\d+){0,3}([-+][0-9A-Za-z.-]+)?", version):
        warn("version-format", f'version "{version}" is not numeric like 1.0.0; check the Hub accepts it')

    # --- dependencies: a dictionary of name -> plugin name or remote id ----
    if "dependencies" in manifest:
        deps = manifest["dependencies"]
        if not isinstance(deps, dict):
            error("dependencies-not-object",
                  f'"dependencies": unexpected json {_json_type(deps)}, expected a json Object. '
                  'Write it as a dictionary, e.g. {"ExamineData": "examine-data"} or {}')
        else:
            for key, value in deps.items():
                if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
                    error("dependency-key",
                          f'dependency key "{key}" is not a valid Lua name; it becomes the global the dependency is exposed as')
                if isinstance(value, bool) or not isinstance(value, (str, int)):
                    error("dependency-value",
                          f'dependency "{key}": unexpected json {_json_type(value)}, expected a plugin name (String) or a remote id (Integer)')
                elif isinstance(value, str) and not value.strip():
                    error("dependency-value", f'dependency "{key}" has an empty plugin name')
            passed('"dependencies" is an object', f"{len(deps)} entr{'y' if len(deps) == 1 else 'ies'}")

    for name in ("requiredDependencies", "optionalDependencies"):
        if name in manifest:
            value = manifest[name]
            if not isinstance(value, dict):
                error("documented-dependency-array",
                      f'"{name}": unexpected json {_json_type(value)}, expected a json Object. '
                      'The docs show this as an array, but the client rejects that; list dependencies '
                      'in "dependencies" as a dictionary instead')
            else:
                warn("documented-dependency-field",
                     f'"{name}" is not a field the client was seen to read; use "dependencies"')

    # --- permissions are arrays of names ----------------------------------
    permissions: set[str] = set()
    for name in PERMISSION_FIELDS:
        if name not in manifest:
            continue
        value = manifest[name]
        if not isinstance(value, list):
            error("permissions-not-array", f'"{name}": unexpected json {_json_type(value)}, expected a json Array of permission names')
            continue
        for p in value:
            if not isinstance(p, str):
                error("permission-type", f'"{name}" entry {p!r}: expected a permission name (String)')
            elif p not in KNOWN_PERMISSIONS:
                warn("unknown-permission", f'"{name}" lists "{p}", which the kit does not know (known: {", ".join(sorted(KNOWN_PERMISSIONS))})')
            else:
                permissions.add(p)
        passed(f'"{name}" is an array', ", ".join(str(p) for p in value) or "empty")

    # --- urls: base URLs a plugin with httpAccess may call -----------------
    if "urls" in manifest:
        urls = manifest["urls"]
        if not isinstance(urls, dict):
            error("urls-not-object", f'"urls": unexpected json {_json_type(urls)}, expected a json Object of name -> base URL')
        else:
            for key, url in urls.items():
                if not isinstance(url, str):
                    error("url-type", f'url "{key}": expected a String')
                    continue
                m = re.match(r"^(https?)://([^/:]+)", url)
                if not m:
                    error("url-format", f'url "{key}" = "{url}" is not an http(s) URL')
                    continue
                host = m.group(2).lower()
                if host in SHORTENERS or any(host.endswith("." + s) for s in SHORTENERS):
                    error("url-shortener", f'url "{key}" uses the link shortener {host}; shorteners are not allowed')
                if m.group(1) == "http" and host not in ("127.0.0.1", "localhost"):
                    warn("url-plain-http", f'url "{key}" uses plain http to {host}')
                if host in ("127.0.0.1", "localhost"):
                    warn("url-localhost", f'url "{key}" points at {host}: fine for a dev tool, never for a Hub release')
            passed('"urls" is an object', f"{len(urls)} url(s)")
            if urls and "httpAccess" not in permissions:
                warn("urls-without-http", '"urls" is set but no permission list asks for httpAccess')
    if "httpAccess" in permissions and not manifest.get("urls"):
        warn("http-without-urls", "httpAccess is requested but no base URLs are declared in \"urls\"")

    # --- contact email ------------------------------------------------------
    email = manifest.get("contactEmailAddress")
    if email is None:
        warn("no-contact", "no contactEmailAddress; Jagex needs a way to reach the developer")
    elif not isinstance(email, str) or "@" not in email:
        error("contact-format", f"contactEmailAddress {email!r} is not an email address")
    elif PLACEHOLDER_EMAIL.search(email):
        (error if release else warn)("placeholder-contact", f'contactEmailAddress "{email}" is a placeholder')

    for key in manifest:
        if key not in KNOWN_FIELDS:
            warn("unknown-field", f'field "{key}" is not one the kit knows; check the client reads it')

    # --- files ----------------------------------------------------------------
    if (plugin_dir / "main.lua").is_file():
        passed("main.lua exists")
    else:
        error("main-missing", "no main.lua next to plugin.json", "main.lua")

    resources = plugin_dir / "resources"
    if resources.is_dir():
        count = 0
        for f in sorted(resources.rglob("*")):
            if f.is_file():
                count += 1
                if f.suffix.lower() not in RESOURCE_EXTENSIONS:
                    error("resource-type", f"{f.relative_to(plugin_dir).as_posix()}: resources may only be .png or .ogg",
                          f.relative_to(plugin_dir).as_posix())
        passed("resources/ holds only .png/.ogg", f"{count} file(s) checked")

    total = 0
    for f in plugin_dir.rglob("*"):
        if f.is_file() and ".git" not in f.parts:
            size = f.stat().st_size
            total += size
            if size > LARGE_FILE_BYTES:
                warn("large-file", f"{f.relative_to(plugin_dir).as_posix()} is {size / 1048576:.1f} MB; "
                     "large files are reported to break Hub installs (no published limit)",
                     f.relative_to(plugin_dir).as_posix())
    trace.append(f"info total plugin size {total / 1048576:.2f} MB")

    trace.append(f"disposition {report.disposition}")
    return report, trace
