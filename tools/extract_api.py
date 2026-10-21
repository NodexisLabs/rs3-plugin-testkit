"""Build rs3testkit/lua/api_docs.lua from a compacted copy of the official
plugin API docs (https://developer.runescape.com/rs/).

The kit's mock is checked against this table: which functions, methods,
properties, enums and event payloads are documented, and with which
parameter types. A plugin that calls something documented but not yet mocked
gets "documented but not mocked"; something not in the table at all gets
"not part of the documented API".

Input: a Markdown file with one section per doc page, each starting with
"# PAGE <url>", holding the pages' signature lines (in backticks), property
lists ("- name: Type (ro) - text"), enum lines ("Enum: A=0, B=1") and event
payload lists. Run:

    python tools/extract_api.py <signatures.md>

It reads only that file (no network) and prints what it found per type, so a
docs update can be reviewed as a diff of api_docs.lua.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "rs3testkit" / "lua" / "api_docs.lua"

SECTION_WORDS = {
    "Overview", "Methods", "Properties", "Functions", "Enumerations", "Constructors", "Constructor",
    "Types", "Requirements", "Usage", "Key Codes", "Supported events", "Event payloads",
    "Explicit Data Types", "Image Layout", "Limitations", "Associated Enumerations",
    "MiniMenu Functions", "MiniMenu Methods", "Plugin Resources", "Handling Events",
    "Positioning and Layout", "Restricted Components", "Accessing the MiniMenu", "Actions and Ops",
    "Verbs and Subjects", "Sorting", "Recommend Built-in Styles", "Index", "Get/Post",
}
# "Visual Properties" etc. on the Component page belong to the page's type.
PROPERTY_GROUPS = {"Visual", "State", "Interface"}
# Signature owners as written in the docs -> the type name the kit uses.
OWNER_ALIASES = {
    "Component": "ui.Component", "ComponentCollection": "ui.ComponentCollection",
    "NPC": "NPCType", "Loc": "LocType", "Obj": "ObjType", "Cursor": "CursorType",
    "PluginResource<T>": "PluginResource", "ui.function StyleSheets": "ui.StyleSheets",
}
HEADING = re.compile(r"^(#{2,6}) (.+?)\s*$")
SIG = re.compile(r"^`(?:function\s+)?([A-Za-z_][\w.<> ]*?)([.:])([A-Za-z_]\w*)\s*\((.*)$")
PROP = re.compile(r"^- ([A-Za-z_]\w*)(\?)?: (.+?)(?: \((ro|rw)\))?(?: - .*)?$")
ENUM_PAIR = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)=(-?\d+)")
ENUM_VALUE_LINE = re.compile(r"^- ([A-Z_][A-Z0-9_]*): (\d+) - ")
ENUM_NAME_LINE = re.compile(r"^- ([A-Za-z_][A-Za-z0-9_]*): ")
TYPE_NAME = re.compile(r"^[A-Za-z_][\w.]*$")


def norm_owner(name: str) -> str:
    name = name.strip()
    return OWNER_ALIASES.get(name, name)


def parse_params(text: str) -> list[str] | None:
    """'x : Int, y : Int?, ...' -> ['Int', 'Int?', '...']; None when unparseable."""
    text = text.strip()
    if not text:
        return []
    params = []
    depth = 0
    cur = ""
    for ch in text:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            params.append(cur)
            cur = ""
        else:
            cur += ch
    params.append(cur)
    out = []
    for p in params:
        p = p.strip()
        if not p:
            continue
        if p in ("...", "args : ..."):
            out.append("...")
            continue
        m = re.match(r"^([A-Za-z_]\w*)(\?)?\s*:\s*(.+)$", p)
        if not m:
            return None
        typ = m.group(3).strip()
        if m.group(2) and not typ.endswith("?"):
            typ += "?"
        if typ.startswith("function"):
            typ = "function" + ("?" if typ.startswith("function?") else "")
        out.append(typ)
    return out


def extract(src: str) -> dict:
    types: dict[str, dict] = {}
    enums: dict[str, dict] = {}
    events: dict[str, dict] = {}
    page = ""
    stack: list[tuple[int, str]] = []       # (level, heading text)
    lines = src.splitlines()
    i = 0
    in_events = False
    all_ro = False

    def owner_for(level: int) -> str | None:
        """Nearest enclosing heading that names a type."""
        for lvl, text in reversed(stack):
            if lvl >= level:
                continue
            word = text.replace(" Properties", "")
            if text.endswith(" Properties") and word not in PROPERTY_GROUPS and TYPE_NAME.match(word):
                return word
            if text in SECTION_WORDS or text.endswith(" Properties"):
                continue
            if TYPE_NAME.match(text) and (text[0].isupper() or text.startswith(("ui.", "audio.", "game."))):
                return text
        return None

    def typ(name: str) -> dict:
        return types.setdefault(name, {"page": page, "methods": {}, "props": {}})

    context = None   # "props", "enums", "event" or None
    context_level = 0
    current_enum = None
    current_event = None
    while i < len(lines):
        line = lines[i]
        if line.startswith("# PAGE "):
            page = line.split()[2]
            stack = []
            in_events = page.endswith("core/events.html")
            context = None
            i += 1
            continue
        h = HEADING.match(line)
        if h:
            level, text = len(h.group(1)), h.group(2)
            while stack and stack[-1][0] >= level:
                stack.pop()
            stack.append((level, text))
            all_ro = False
            current_enum = None
            current_event = None
            # A heading ends the previous list unless it is a sub-heading of an
            # Enumerations section (each enum has its own heading).
            if not (context == "enums" and level > context_level):
                context = None
            if text == "Properties" or text.endswith(" Properties"):
                context = "props"
            elif text == "Enumerations":
                context, context_level = "enums", level
            elif in_events and level == 4 and any(t == "Supported events" for _, t in stack):
                context = "event"
                current_event = text
                events.setdefault(text, {})
            elif context == "enums" and TYPE_NAME.match(text):
                current_enum = text
            m = re.match(r"^(\S+) Properties$", text)
            if m and m.group(1) not in PROPERTY_GROUPS:
                typ(norm_owner(m.group(1)))
            i += 1
            continue

        if "All properties are read-only" in line:
            all_ro = True

        s = SIG.match(line)
        if s:
            # Signatures can span several backtick lines; join until the "(" closes.
            body = s.group(4)

            def open_parens(text):
                return 1 + text.count("(") - text.count(")")

            while open_parens(body) > 0 and i + 1 < len(lines) and lines[i + 1].startswith("`"):
                i += 1
                body = body.rstrip("`") + " " + lines[i].strip("`")
            body = body.rstrip("`").strip()
            depth, end = 1, None
            for k, ch in enumerate(body):
                if ch == "(":
                    depth += 1
                elif ch == ")":
                    depth -= 1
                    if depth == 0:
                        end = k
                        break
            params_text = body[:end] if end is not None else body
            ret = ""
            if end is not None:
                rest = body[end + 1:].strip()
                if rest.startswith("->"):
                    ret = rest[2:].strip()
            owner = norm_owner(s.group(1))
            if "<option name>" not in owner:
                entry = typ(owner)["methods"].setdefault(s.group(3), {"sep": s.group(2), "sigs": []})
                params = parse_params(params_text)
                entry["sigs"].append({"params": params, "returns": ret})
            i += 1
            continue

        if context == "enums":
            pairs = ENUM_PAIR.findall(line) if line.startswith("Enum:") else []
            name = current_enum or owner_for(99)
            if pairs and name:
                enums.setdefault(name, {"values": {}, "names": []})["values"].update({k: int(v) for k, v in pairs})
            else:
                mv = ENUM_VALUE_LINE.match(line)
                mn = ENUM_NAME_LINE.match(line)
                if mv and name:
                    enums.setdefault(name, {"values": {}, "names": []})["values"][mv.group(1)] = int(mv.group(2))
                elif mn and name:
                    e = enums.setdefault(name, {"values": {}, "names": []})
                    if mn.group(1) not in e["names"]:
                        e["names"].append(mn.group(1))
        elif context == "event" and current_event:
            mp = PROP.match(line)
            if mp:
                events[current_event][mp.group(1)] = {"type": mp.group(3).strip(), "ro": mp.group(4) != "rw"}
        elif context == "props":
            mp = PROP.match(line)
            if mp:
                level = stack[-1][0] if stack else 2
                heading = stack[-1][1] if stack else ""
                m = re.match(r"^(\S+) Properties$", heading)
                if m and m.group(1) not in PROPERTY_GROUPS:
                    owner = norm_owner(m.group(1))
                else:
                    owner = owner_for(level)
                if owner:
                    t = mp.group(3).strip()
                    optional = bool(mp.group(2)) or t.endswith("?")
                    if not re.match(r"^[\[\]{}A-Za-z_][\w.<>\[\]{} ,?|/-]*$", t) or " " in t.strip("[] ").replace(" ,", ","):
                        t = "?" if len(t.split()) > 3 else t
                    ro = mp.group(4) == "ro" or all_ro
                    typ(norm_owner(owner))["props"][mp.group(1)] = {"type": t, "ro": ro, "optional": optional}
        i += 1

    # Inheritance from "ui.Component -> ui.Text" overview lines.
    for line in lines:
        chain = [part.strip() for part in line.strip().split(" -> ")]
        if len(chain) > 1 and all(TYPE_NAME.match(c) for c in chain):
            for parent, child in zip(chain, chain[1:]):
                if child in types:
                    types[child]["parent"] = norm_owner(parent)
    return {"types": types, "enums": enums, "events": events}


def lua_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def to_lua(data: dict) -> str:
    out = [
        "-- GENERATED by tools/extract_api.py from the official plugin API docs",
        "-- (https://developer.runescape.com/rs/, fetched 2026-10-20). Do not edit by hand:",
        "-- re-run the extractor and review the diff. Names and parameter types only.",
        "return {",
        "    types = {",
    ]
    for name in sorted(data["types"]):
        t = data["types"][name]
        out.append(f"        [{lua_str(name)}] = {{")
        out.append(f"            page = {lua_str(t['page'])},")
        if t.get("parent"):
            out.append(f"            parent = {lua_str(t['parent'])},")
        out.append("            methods = {")
        for mname in sorted(t["methods"]):
            m = t["methods"][mname]
            sigs = []
            for sig in m["sigs"]:
                if sig["params"] is None:
                    sigs.append("{ unparsed = true }")
                else:
                    ps = ", ".join(lua_str(p) for p in sig["params"])
                    sigs.append(f"{{ params = {{ {ps} }}, returns = {lua_str(sig['returns'])} }}")
            out.append(f"                {mname} = {{ sep = {lua_str(m['sep'])}, sigs = {{ {', '.join(sigs)} }} }},")
        out.append("            },")
        out.append("            props = {")
        for pname in sorted(t["props"]):
            p = t["props"][pname]
            opt = ", optional = true" if p.get("optional") else ""
            out.append(f"                {pname} = {{ type = {lua_str(p['type'])}, ro = {'true' if p['ro'] else 'false'}{opt} }},")
        out.append("            },")
        out.append("        },")
    out.append("    },")
    out.append("    enums = {")
    for name in sorted(data["enums"]):
        e = data["enums"][name]
        vals = ", ".join(f"{k} = {v}" for k, v in e["values"].items())
        names = ", ".join(lua_str(n) for n in e["names"] if n not in e["values"])
        out.append(f"        [{lua_str(name)}] = {{ values = {{ {vals} }}, names = {{ {names} }} }},")
    out.append("    },")
    out.append("    events = {")
    for name in sorted(data["events"]):
        fields = ", ".join(f"{k} = {{ type = {lua_str(v['type'])}, ro = {'true' if v['ro'] else 'false'} }}"
                           for k, v in data["events"][name].items())
        out.append(f"        {name} = {{ {fields} }},")
    out.append("    },")
    out.append("}")
    return "\n".join(out) + "\n"


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    data = extract(Path(sys.argv[1]).read_text(encoding="utf-8"))
    OUT.write_text(to_lua(data), encoding="utf-8", newline="\n")
    for name in sorted(data["types"]):
        t = data["types"][name]
        print(f"{name:32} {len(t['methods']):3} methods {len(t['props']):3} props  parent={t.get('parent', '')}")
    print(f"{len(data['enums'])} enums, {len(data['events'])} events -> {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
