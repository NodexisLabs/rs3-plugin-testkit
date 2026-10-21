"""rs3test: command line for the RS3 plugin test kit.

    rs3test check plugins/my-plugin            validate plugin.json, main.lua, resources/
    rs3test check plugins/my-plugin --release  also fail on release blockers (placeholder email)
    rs3test run plugins/my-plugin spec/        check, then run every *_spec.lua under spec/

Exit code 0 means everything passed; 1 means a check or a test failed;
2 means the kit could not start (bad arguments, missing plugin or dependency).
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from xml.sax.saxutils import escape

from . import manifest as manifest_mod


def _print_report(report, trace, verbose: bool) -> None:
    for f in report.findings:
        print("  " + str(f))
    if verbose:
        for line in trace:
            print("    trace: " + line)
    print(f"  {report.plugin_dir.name}: {report.disposition} "
          f"({len(report.errors)} error(s), {len(report.warnings)} warning(s))")


def cmd_check(args) -> int:
    worst = 0
    for d in args.plugins:
        print(f"check {d}")
        report, trace = manifest_mod.validate(d, release=args.release)
        _print_report(report, trace, args.verbose)
        if not report.ok:
            worst = 1
    return worst


def _spec_files(paths: list[str]) -> list[Path]:
    files: list[Path] = []
    for p in paths:
        path = Path(p)
        if path.is_dir():
            files.extend(sorted(path.rglob("*_spec.lua")))
        elif path.is_file():
            files.append(path)
        else:
            raise SystemExit(f"rs3test: no spec file or folder {p}")
    if not files:
        raise SystemExit(f"rs3test: no *_spec.lua files in {', '.join(paths)}")
    return files


def _parse_deps(items: list[str]) -> dict[str, str]:
    deps = {}
    for item in items or []:
        if "=" not in item:
            raise SystemExit(f"rs3test: --dep needs KEY=FOLDER, got {item!r}")
        k, v = item.split("=", 1)
        deps[k] = v
    return deps


def _write_junit(path: Path, results: list[dict], seconds: float) -> None:
    failures = sum(1 for r in results if not r["ok"])
    lines = [f'<?xml version="1.0" encoding="UTF-8"?>',
             f'<testsuite name="rs3test" tests="{len(results)}" failures="{failures}" time="{seconds:.3f}">']
    for r in results:
        name = escape(r["name"], {'"': "&quot;"})
        cls = escape(r["file"], {'"': "&quot;"})
        lines.append(f'  <testcase classname="{cls}" name="{name}" time="{r["ms"] / 1000:.3f}">')
        if not r["ok"]:
            first = (r["error"] or "").splitlines()[0] if r["error"] else "failed"
            lines.append(f'    <failure message="{escape(first, {chr(34): "&quot;"})}">{escape(r["error"] or "")}</failure>')
        lines.append("  </testcase>")
    lines.append("</testsuite>")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def cmd_run(args) -> int:
    from .host import KitError, Session   # imported here so `check` works without lupa

    plugin_dir = Path(args.plugin)
    if not args.no_check:
        print(f"check {plugin_dir}")
        report, trace = manifest_mod.validate(plugin_dir)
        _print_report(report, trace, args.verbose)
        if not report.ok:
            print("rs3test: plugin.json/files would be rejected by the client; fix them first (or --no-check)")
            return 1

    specs = _spec_files(args.specs)
    inside = [s for s in specs if plugin_dir.resolve() in s.resolve().parents]
    for s in inside:
        print(f"  WARNING spec-in-plugin: {s} is inside the plugin folder and would ship to the Hub")

    deps = _parse_deps(args.dep)
    all_results: list[dict] = []
    http_total = 0
    http_endpoints: dict[str, int] = {}
    started = time.perf_counter()
    activation_out = open(args.activation, "w", encoding="utf-8") if args.activation else None
    id_source = "kit seed tables only"
    for spec in specs:
        print(f"\n{spec}")
        try:
            session = Session(plugin_dir, deps, args.search, echo=args.echo, ids=args.ids)
            id_source = session.kit.ids.source()
            if activation_out:
                session.start_activation()
            results = session.run_spec(spec)
            if activation_out:
                for e in session.activation_events():
                    activation_out.write(json.dumps({"spec": spec.name, **e}) + "\n")
        except KitError as e:
            print(f"rs3test: {e}")
            return 2
        except Exception as e:  # a Lua error while loading the spec file itself
            print(f"  FAIL (spec did not load) {e}")
            all_results.append({"file": spec.name, "name": "(load)", "ok": False, "error": str(e),
                                "ms": 0.0, "warnings": []})
            continue
        for r in results:
            mark = "PASS" if r["ok"] else "FAIL"
            print(f"  {mark} {r['name']}" + (f"  ({r['ms']:.0f} ms)" if r["ms"] >= 50 else ""))
            if not r["ok"]:
                for line in (r["error"] or "").splitlines():
                    print("       " + line)
            for w in r["warnings"]:
                print(f"       lint {w}")
        all_results.extend(results)
        s = session.summary()
        http_total += s["httpRequests"]
        for k, v in s["httpByEndpoint"].items():
            http_endpoints[k] = http_endpoints.get(k, 0) + v

    if activation_out:
        activation_out.close()
        print(f"Activation log: {args.activation} (plugin lines/calls per test, JSON lines)")
    seconds = time.perf_counter() - started
    failed = [r for r in all_results if not r["ok"]]
    print(f"\n{len(all_results) - len(failed)} passed, {len(failed)} failed, {len(specs)} spec file(s), {seconds:.1f} s")
    top = ", ".join(f"{k} {v}" for k, v in sorted(http_endpoints.items(), key=lambda kv: -kv[1])[:3])
    print(f"HTTP: {http_total} simulated request(s) by the plugin" + (f"; top: {top}" if top else "") +
          "; 0 real network requests (the kit has no network code)")
    print(f"id tables: {id_source}")
    if args.junit:
        _write_junit(Path(args.junit), all_results, seconds)
        print(f"JUnit report: {args.junit}")
    return 1 if failed else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="rs3test", description="Offline test kit for RuneScape 3 Lua plugins")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("check", help="validate plugin folders against the client's manifest rules")
    p.add_argument("plugins", nargs="+")
    p.add_argument("--release", action="store_true", help="treat release blockers as errors")
    p.add_argument("-v", "--verbose", action="store_true", help="print every check that ran")
    p.set_defaults(func=cmd_check)

    p = sub.add_parser("run", help="check a plugin, then run spec files against the mock API")
    p.add_argument("plugin")
    p.add_argument("specs", nargs="*", default=["spec"], help="spec files or folders (default: spec/)")
    p.add_argument("--dep", action="append", metavar="KEY=FOLDER", help="where a dependency lives")
    p.add_argument("--search", action="append", default=[], metavar="FOLDER",
                   help="folder to look in for dependencies (the plugin's parent is always searched)")
    p.add_argument("--echo", action="store_true", help="show the plugin's print() output")
    p.add_argument("--junit", metavar="FILE", help="write a JUnit XML report (for CI)")
    p.add_argument("--no-check", action="store_true", help="skip the manifest check")
    p.add_argument("--ids", metavar="FOLDER",
                   help="local clone of runescape-api-stubs for the full id.* tables (default: $RS3_API_STUBS)")
    p.add_argument("--activation", metavar="FILE",
                   help="write every plugin line/call/return that ran, per test, as JSON lines")
    p.add_argument("-v", "--verbose", action="store_true")
    p.set_defaults(func=cmd_run)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
