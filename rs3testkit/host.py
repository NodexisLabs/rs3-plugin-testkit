"""Python side of the kit: finds a plugin and its dependencies, starts a Lua 5.4
runtime (through lupa) with the mock API, and runs spec files in it.

Each spec file gets a fresh runtime, so files never see each other's state.

    from rs3testkit import Session
    s = Session("plugins/advanced-examine")
    results = s.run_spec("spec/window_spec.lua")

Nothing here opens a network connection: HTTP requests a plugin makes go to
the kit's mock (kit.http), which records them and answers from fixtures.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

try:
    import lupa.lua54 as lupa
except ImportError as e:  # fail loudly with the fix, not a bare ImportError
    raise SystemExit(
        "rs3testkit needs lupa (Lua 5.4 for Python): pip install lupa\n"
        "On Windows, a very long install path can fail with a DLL error; "
        "install to a short path (pip install --target C:\\lp lupa) and add it to PYTHONPATH."
    ) from e

from .stubs import open_stubs

LUA_DIR = Path(__file__).resolve().parent / "lua"


class KitError(Exception):
    """A setup problem (missing plugin, unresolvable dependency)."""


@dataclass
class PluginInfo:
    name: str
    dir: Path
    manifest: dict
    key: str | None = None            # dependency key it is exposed under
    deps: list["PluginInfo"] = field(default_factory=list)
    optional_missing: list[str] = field(default_factory=list)   # optional dependency keys not found
    resources: dict = field(default_factory=dict)


def resource_tree(plugin_dir: Path) -> dict:
    """resources/ as nested dicts keyed like Plugin.resources: folders are
    sub-tables and files are keyed by name without extension (the docs'
    example: resources/images/menu/background.png -> images.menu.background).
    Two files that differ only by extension would share a key, which the docs
    leave undefined, so that is an error."""
    root = plugin_dir / "resources"
    tree: dict = {}
    if not root.is_dir():
        return tree
    for f in sorted(root.rglob("*")):
        if not f.is_file():
            continue
        parts = f.relative_to(root).parts
        node = tree
        for folder in parts[:-1]:
            node = node.setdefault(folder, {})
        key = Path(parts[-1]).stem
        if key in node:
            raise KitError(f"{f}: another resource in {f.parent} is also keyed '{key}' "
                           "(Plugin.resources keys drop the extension); rename one")
        node[key] = f.as_posix()
    return tree


def read_manifest(plugin_dir: Path) -> dict:
    path = plugin_dir / "plugin.json"
    if not path.is_file():
        raise KitError(f"no plugin.json in {plugin_dir}")
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except json.JSONDecodeError as e:
        raise KitError(f"{path}: not valid JSON ({e}); run `rs3test check` for details") from e


def _find_dependency(value, key: str, owner: Path, dep_paths: dict[str, Path], search: list[Path]) -> Path:
    """Where a dependency lives: an explicit --dep mapping (by key or value),
    else a sibling folder named after it, else a folder whose manifest name
    matches it."""
    for k in (str(value), key):
        if k in dep_paths:
            return dep_paths[k]
    if isinstance(value, int):
        raise KitError(f"{owner.name}: dependency {key} is remote id {value}; "
                       f"point the kit at a local copy with --dep {key}=<folder>")
    roots = search + [owner.parent]
    for root in roots:
        candidate = root / value
        if (candidate / "plugin.json").is_file():
            return candidate
    for root in roots:
        if not root.is_dir():
            continue
        for candidate in root.iterdir():
            if (candidate / "plugin.json").is_file():
                try:
                    if read_manifest(candidate).get("name") == value:
                        return candidate
                except KitError:
                    continue
    looked = ", ".join(str(r) for r in roots)
    raise KitError(f"{owner.name}: dependency {key} = {value!r} not found (looked in {looked}); "
                   f"use --dep {key}=<folder>")


def resolve(plugin_dir: str | Path, dep_paths: dict[str, Path] | None = None,
            search: list[Path] | None = None, _seen: tuple = ()) -> PluginInfo:
    plugin_dir = Path(plugin_dir).resolve()
    dep_paths = {k: Path(v).resolve() for k, v in (dep_paths or {}).items()}
    search = [Path(s).resolve() for s in (search or [])]
    if plugin_dir in _seen:
        raise KitError("dependency cycle: " + " -> ".join(p.name for p in _seen + (plugin_dir,)))
    manifest = read_manifest(plugin_dir)
    info = PluginInfo(name=str(manifest.get("name") or plugin_dir.name), dir=plugin_dir, manifest=manifest,
                      resources=resource_tree(plugin_dir))
    deps = manifest.get("dependencies", {})
    if not isinstance(deps, dict):
        raise KitError(f"{plugin_dir / 'plugin.json'}: dependencies must be a dictionary; run `rs3test check`")
    for key, value in deps.items():
        path = _find_dependency(value, key, plugin_dir, dep_paths, search)
        dep = resolve(path, dep_paths, search, _seen + (plugin_dir,))
        dep.key = key
        info.deps.append(dep)
    # Optional dependencies (dictionary form only): loaded when found, else the
    # global is nil, as in the client when the optional plugin is absent.
    optional = manifest.get("optionalDependencies", {})
    if isinstance(optional, dict):
        for key, value in optional.items():
            try:
                path = _find_dependency(value, key, plugin_dir, dep_paths, search)
            except KitError:
                info.optional_missing.append(key)
                continue
            dep = resolve(path, dep_paths, search, _seen + (plugin_dir,))
            dep.key = key
            info.deps.append(dep)
    return info


class Session:
    """One Lua runtime with the mock API and one plugin (plus dependencies)."""

    def __init__(self, plugin_dir: str | Path, dep_paths: dict | None = None,
                 search: list | None = None, echo: bool = False, ids: str | Path | None = None):
        """`ids`: a local clone of runescape-api-stubs for the full id.*
        tables (default: $RS3_API_STUBS; none means the kit's seed tables)."""
        self.plugin = resolve(plugin_dir, dep_paths, search)
        self.lua = lupa.LuaRuntime(unpack_returned_tuples=True)
        g = self.lua.globals()
        g.package.path = f"{LUA_DIR.as_posix()}/?.lua;{LUA_DIR.as_posix()}/mock/?.lua"
        try:
            self.stubs = open_stubs(ids)
        except FileNotFoundError as e:
            raise KitError(str(e)) from e
        if self.stubs:
            bridge = self.lua.table_from({
                "active": True,
                "revision": self.stubs.revision,
                "number": self.stubs.number,
                "name": self.stubs.name,
            })
            bridge.kinds = self.lua.table_from(self.stubs.kinds)
            g.package.loaded["stubsbridge"] = bridge
        self.kit = self.lua.eval('(require("kit"))')
        self.kit._setWriter(lambda line: print(line, flush=True))
        self.kit._setup(self._to_lua(self.plugin), echo)

    def _to_lua(self, info: PluginInfo):
        t = self.lua.table_from({
            "name": info.name,
            "dir": info.dir.as_posix(),
            "key": info.key,
        })
        t.manifest = self._json_to_lua(info.manifest)
        t.deps = self.lua.table_from([self._to_lua(d) for d in info.deps])
        t.optionalMissing = self.lua.table_from(info.optional_missing)
        t.resources = self._json_to_lua(info.resources)
        return t

    def _json_to_lua(self, value):
        """JSON -> Lua tables. JSON objects carry an __object marker so the
        kit can tell {} from [] (both are empty tables in Lua)."""
        if isinstance(value, dict):
            t = self.lua.table_from({k: self._json_to_lua(v) for k, v in value.items()})
            self.lua.eval("function(t) setmetatable(t, { __jsonObject = true }) end")(t)
            return t
        if isinstance(value, list):
            return self.lua.table_from([self._json_to_lua(v) for v in value])
        return value

    def start_map(self) -> None:
        """Record a call tree per test for the behaviour map (rs3test map)."""
        self.kit._mapStart()

    def map_result(self) -> list[dict]:
        """[{name, calls, root}] where root/children are {name, file, plugin,
        line, count, children}, in the order scenarios first ran."""
        def node(t):
            kids = t.children
            return {"name": t.name, "role": t.role, "file": t.file, "plugin": t.plugin,
                    "line": int(t.line) if t.line is not None else None,
                    "count": int(t.count or 0),
                    "children": [node(kids[i]) for i in range(1, len(kids) + 1)]}
        res = self.kit._mapResult()
        return [{"name": res[i].name, "calls": int(res[i].calls), "root": node(res[i].root)}
                for i in range(1, len(res) + 1)]

    def start_activation(self) -> None:
        """Record which plugin lines/functions run (kit.activation)."""
        self.kit.activation.start()

    def activation_events(self) -> list[dict]:
        ev = self.kit.activation.events()
        return [{"kind": e.kind, "plugin": e.plugin, "file": e.file,
                 "line": int(e.line) if e.line is not None else None,
                 "fn": e.fn, "test": e.test} for e in (ev[i] for i in range(1, len(ev) + 1))]

    def run_spec(self, spec_path: str | Path) -> list[dict]:
        spec_path = Path(spec_path).resolve()
        results = self.kit._runSpec(spec_path.as_posix(), spec_path.name)
        out = []
        for i in range(1, len(results) + 1):
            r = results[i]
            warnings = [r.warnings[j] for j in range(1, len(r.warnings) + 1)] if r.warnings else []
            out.append({"file": r.file, "name": r.name, "ok": bool(r.ok), "error": r.error,
                        "ms": float(r.ms), "warnings": warnings, "scenario": bool(r.scenario)})
        return out

    def summary(self) -> dict:
        s = self.kit._summary()
        endpoints = {}
        if s.http.byEndpoint:
            for k, v in s.http.byEndpoint.items():
                endpoints[k] = int(v)
        return {"httpRequests": int(s.http.total), "httpByEndpoint": endpoints,
                "consoleLines": int(s.consoleLines)}
