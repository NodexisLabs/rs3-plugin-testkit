# RS3 Plugin Test Kit

Offline tests for RuneScape 3 Lua plugins (the official plugin API, docs at
<https://developer.runescape.com/rs/>). Your plugin's real `main.lua` runs in
Lua 5.4, outside the game, against a mock of the plugin API. Specs drive it
with ticks, events, right-click menus and button presses, then check what it
did.

Dev tools like Dev Toolbox, Var Watch and Debug Menu all run inside the
client. This kit runs on your machine or in CI, without a client and with no
network.

```
check plugins/advanced-examine
  WARNING placeholder-contact: contactEmailAddress "dev-only@example.invalid" is a placeholder [plugin.json]
  advanced-examine: ESCALATE (0 error(s), 1 warning(s))

spec/advanced-examine/window_spec.lua
  PASS examining a Lumbridge goblin shows its wiki page
  PASS the header shows the clicked NPC's model, scaled by its grid size
  PASS clicking a drop opens that item
  ...
11 passed, 0 failed, 1 spec file(s), 0.1 s
HTTP: 0 simulated request(s) by the plugin; 0 real network requests (the kit has no network code)
```

## What it gives you

- **A strict mock of the plugin API.** It covers Player, Inventory,
  GrandExchange, World with the NPC/Player/Loc/ground-item entities and their
  lists, MiniMenu, Event, PersistentDB, HTTPRequest, Plugin, Mouse, Keyboard,
  Camera, Chat, audio, CoordGrid/CoordFine, Vector2/3/4, the `ui` components,
  the `id.*` tables and `config.*`. Every name, parameter type and property is
  checked against a table generated from the official docs
  ([`rs3testkit/lua/api_docs.lua`](rs3testkit/lua/api_docs.lua)).
- **A manifest validator** (`rs3test check`) for `plugin.json`, `main.lua` and
  `resources/`. It encodes the rules the client actually enforces, which differ
  from the docs in places (see below).
- **A test runner** (`rs3test run`) for Lua spec files, with fixtures for
  scripting game state, events and ticks, and a JUnit report for CI.
- **A GitHub Actions template**
  ([`templates/github-actions/rs3-plugin-tests.yml`](templates/github-actions/rs3-plugin-tests.yml)).

## Fails loud

The kit's job is to stop, with a clear message, where the client would fail
or where a plugin would quietly do the wrong thing. A spec fails when the
plugin:

| Does this | The kit says |
|---|---|
| calls a function that isn't in the docs (`Player.GetLevel`) | `not part of the documented plugin API (typo, or an undocumented member?)` |
| calls a documented function the kit has no behaviour for | `in the documented API but the kit does not mock it yet` |
| uses `:` on a static function or `.` on a method | `call it with '.', not ':'` |
| passes the wrong number or types of arguments | sol2's own `no matching function call`, plus the documented overloads |
| writes a read-only or misspelt property (`text.contnet`) | `has no property 'contnet'. Known properties: ...` |
| reads an enum member that doesn't exist (`ui.AlignMode.LEFT`) | an error (the client returns `nil`, which hides the bug) |
| reads a payload field that isn't documented (`e.newXp`) | the field and event named |
| raises inside an event handler, hook or HTTP callback | the event, handler name and plugin named |
| sends an HTTP request without `httpAccess`, to an undeclared base URL, or with no route set up in the spec | an error before any reply is faked |
| reads game data the spec never supplied (`config.NPC.FromID(81).gridSize`) | which fixture to add; the kit never makes up game data |

Reading a global that doesn't exist gives `nil`, as in the client, because
plugins rely on it (`count = (count or 0) + 1`, `if os then`). The kit
reports each one as an `undefined-global` lint with the file and line, so
`myTypo` and a removed library such as `os` still show up in the run. Set
`kit.sandbox.strictGlobals = true` in a spec to make them errors.

A "documented but not mocked" error is honest about a gap in the kit. Mock the
function in your spec with `kit.mock("World.GetGroundHeight", fn)`, or add it
to `rs3testkit/lua/mock/`.

Void visual methods (`SetHeaderLayout`, `AlignTo`, `SetAspectRatio`, ...)
can only change how something is drawn, which a stand-in can't see. The kit
records those calls (`kit.ui.calls(component)`) instead of raising. Methods
that return a value never get a made-up answer.

### Behaviour from a live client

These were found by running plugins in the beta client (October 2026). The
kit reproduces them so you find them offline:

- The client requires `"dependencies": {}` as a JSON object. The documented
  `requiredDependencies` / `optionalDependencies` arrays fail with
  `unexpected json Array, expected a json Object`.
- `clickthrough` defaults to true, so clicks on your window also walk the
  player until you set it to false. The kit reports this as a lint.
- `ui.Sprite:SetAssociatedObject(id, quantity)` fails even though the docs
  list a quantity. Set `associatedObjectQuantity` instead.
- `ui.Model` starts with `viewDistance` 100 and `modelWidth`/`modelHeight` 0,
  which draws nothing. The kit reports a visible model at size 0 as a lint.
- `ui.Model.rotation` needs an integer `Vector3`, and Lua can't make one.
- `"<"` in text starts a tag and isn't drawn. The kit reports this as a lint.
- Enum members live in the metatable, so `pairs(ui.AlignMode)` lists only
  `FromID`. The exception is `ui.Hook`, which is a plain table.
- `MiniMenuEntryAdded` payloads carry `miniMenu` (not in the docs), which
  plugins use to call `:Add`.
- `id.*` tables iterate as number → name, and `tostring(coordGrid)` gives
  `level,mapSquareX,mapSquareZ,localX,localZ`.

## Install

You need Python 3.10+ and [lupa](https://pypi.org/project/lupa/), which
provides Lua 5.4 for Python.

```bash
python -m pip install -e .
```

On Windows, a very long install path can make lupa fail with a DLL error. If
that happens, install it to a short path (`pip install --target C:\lp lupa`)
and add that path to `PYTHONPATH`.

## Quick start

Keep specs **outside** the plugin folder, so they never ship to the Hub:

```
my-plugin/
  plugin/          plugin.json, main.lua, resources/   <- what you upload
  spec/            *_spec.lua                          <- tests
```

```lua
-- spec/xp_spec.lua
kit.player.set{ levels = { MINING = 50 } }
kit.start()                                 -- runs plugin/main.lua (and its dependencies)

test("counts XP from skill updates", function()
    kit.player.gainXP("MINING", 35)         -- fires Event.SkillTransmit
    expect(kit.ui.texts()).toContain("Mining: 35 xp")
end)

test("Reset clears the totals", function()
    kit.ui.press("Reset")
    expect(kit.db.get("gained")).toEqual({})
end)
```

```bash
rs3test check plugin
```

```bash
rs3test run plugin spec
```

[`examples/xp-counter`](examples/xp-counter) is a complete small plugin with
its spec.

Tests in a file run in order and share one sandbox, so a file can play out a
scenario (open a window, page through it, go back). Each file gets a fresh
sandbox.

## Spec API

Globals in a spec: `kit`, `test(name, fn)`, `expect(value)`, the game API
exactly as the plugin sees it (`Player`, `ui`, `SkillType`, ...), and the full
host Lua library.

**expect**: `toBe`, `toEqual` (deep), `toBeTruthy`, `toBeFalsy`, `toBeNil`,
`toBeCloseTo(x, eps)`, `toContain` (substring or list element),
`notToContain`, `toHaveLength`, `toError("substring")`.

**Running the plugin**

| Call | Does |
|---|---|
| `kit.start()` | runs `main.lua` (dependencies first) and returns what it returned |
| `kit.env()` | the plugin's globals; a name it never set reads `nil` here |
| `kit.require("views")` | one of the plugin's own modules |
| `kit.mock("Ns.fn", fn)` / `kit.mockMethod("ui.Canvas", "AddLine", fn)` | fill a gap in the mock |

**Time and events**

| Call | Does |
|---|---|
| `kit.tick(n)` | `n` logic ticks (50/s); `ServerLogic` every 30th; delivers HTTP replies and chat |
| `kit.seconds(s)` | `kit.tick(s * 50)` |
| `kit.draw(n, dt)` | `Event.Draw` |
| `kit.events.fire(name, fields)` | any documented event, with a strict payload |
| `kit.events.subscribers(name)` | who is subscribed, in call order |

**Game state** (no game data is invented, so give what the plugin reads)

| Call | Does |
|---|---|
| `kit.player.set{ levels =, xp =, boosted =, capped =, runEnergy =, coord =, available = }` | player state; a level sets its XP and XP sets its level |
| `kit.player.gainXP(skill, n)` | adds XP, fires `SkillTransmit` |
| `kit.player.setRunEnergy(n)` / `setWeight(n)` | fire `RunEnergyTransmit` / `RunWeightTransmit` |
| `kit.config.npc(id, {...})`, `.obj`, `.loc`, `.inv`, `.define(kind, id, {...})` | configs for `config.X.FromID`; fields must be documented properties |
| `kit.world.addNpc{ id =, name =, coord = }`, `addPlayer`, `addLoc`, `addGroundItems` | entities for `NPCList`, `PlayerList`, ...; `fire = true` sends the Added event |
| `kit.world.remove(entity)` | `isValid` becomes false; any other read raises |
| `kit.inventory.set(93, { {995, 1000}, false, {1511, 1} })` | an `Inv` (93 = backpack, 95 = bank) |
| `kit.inventory.setSlot(id, slot, obj, n)` / `remove(id)` | `InventoryUpdated` / `InventoryRemoved` |
| `kit.ge.setOffer(slot, { type =, item =, price =, itemCount = })` | fires `GrandExchangeOfferUpdated` |
| `kit.ids.add("NPC", "GOBLIN", 11240)` | a name for an `id.*` table |

**Menus and UI**

| Call | Does |
|---|---|
| `kit.menu.entry{ npc = e, verb =, subject = }` (or `loc = id`, `obj = id`) | a game menu entry |
| `kit.menu.open{ entries }` | runs `MiniMenuEntryAdded` → `MiniMenuReady` → `MiniMenuOpened` |
| `handle:select("Label")` | runs a plugin entry's function, fires `EntrySelected` and `Closed` |
| `kit.ui.texts()` | visible `ui.Text` contents, in creation order (hidden parents count) |
| `kit.ui.button(label[, prefix])`, `kit.ui.press(label)` | press a visible, enabled button |
| `kit.ui.click(component or "text")`, `kit.ui.drag(c, x1, y1, x2, y2)` | `ONCLICK`, `ONDRAG` / `ONDRAGCOMPLETE` |
| `kit.ui.find(fn)`, `kit.ui.all()`, `kit.ui.count()`, `kit.ui.dump()` | look around the tree |
| `kit.ui.canvas(c)` | elements drawn on a `ui.Canvas` |

**Saved settings, network, permissions, console**

| Call | Does |
|---|---|
| `kit.db.set(k, v)`, `kit.db.get(k)`, `kit.db.all()`, `kit.db.failWrites(true)` | PersistentDB, one store per plugin |
| `kit.http.respond("GET", url, { status =, body = } \| fn)` | a reply (url may end in `*`) |
| `kit.http.count("GET url")`, `kit.http.requests()` | what the plugin sent |
| `kit.permissions.grant("httpAccess")` / `revoke` | `requiredPermissions` start granted, optional ones revoked |
| `kit.chat.receive{ text =, type =, sender = }`, `kit.chat.messages()` | chat in and out (needs `chatAccess`) |
| `kit.console.lines()`, `kit.console.expectNo("ERROR")` | the plugin's `print` output |
| `kit.warnings()`, `kit.trace(n)`, `kit.calls("Player.GetEntity")` | lint findings and every API call the plugin made |

## Manifest rules (`rs3test check`)

| Rule | Level |
|---|---|
| `plugin.json` is a JSON object in UTF-8 | error |
| `name`, `version`, `dependencies` are present; name and version are non-empty strings | error |
| `dependencies` is a dictionary: valid Lua name → plugin name (string) or remote id (integer) | error |
| `requiredDependencies` / `optionalDependencies` as arrays | error (the client rejects them) |
| `requiredPermissions` / `optionalPermissions` are arrays of names | error |
| files in `resources/` are `.png` or `.ogg` only | error |
| `urls` are http(s) base URLs with no link shorteners | error |
| `main.lua` exists | error |
| unknown permission, unknown field, placeholder contact email, plain http, `httpAccess` without `urls`, files over 5 MB | warning (`--release` makes the placeholder email an error) |

The result is a disposition: **ACCEPT** (clean), **ESCALATE** (loads, but a
person should look at the warnings) or **REJECT** (the client will refuse
it). `-v` prints the trace of every check that ran.

## Usage estimate

**The kit makes zero network requests.** It has no network code, and CI
checks that the package imports no socket or HTTP library.

- **Per run:** 0 requests to RuneScape, the RuneScape Wiki, mod.io or anything
  else. A plugin's `HTTPRequest` calls are answered from the spec's
  `kit.http.respond` routes. They are counted per endpoint, and every run
  prints a one-line total (`HTTP: N simulated request(s) ...; top: ...`), so
  you can see how many calls a feature would make before it reaches players.
- **Per day / per month:** 0, however often it runs.
- **CI:** each run downloads the GitHub actions, Python and the kit with
  lupa, the same as any Python job. It makes no metered or rate-limited API
  calls.
- **Refreshing the API table:** `tools/extract_api.py` reads a local
  Markdown copy of the docs and makes 0 requests. Building that copy took
  about 95 page loads, once, on 2026-10-20.

## What it can't tell you

The kit runs the plugin's code and checks its API use. It can't show how the
client draws things: fonts, real sizes, styles, models and sprites. It can't
show timing in the client or how the plugin interacts with other plugins.
Check those in the beta client before you submit. Behaviour that is neither
documented nor seen live is marked in the code and in error messages. For
example, the `id.Font` numbers are assigned by the kit, so never hard-code
them.

## Updating from the docs

`rs3testkit/lua/api_docs.lua` is generated. When the docs change, make a fresh
compacted copy (one `# PAGE <url>` section per page, keeping the signature
lines, property lists and enum lines), then run:

```bash
python tools/extract_api.py path/to/signatures.md
```

Review the diff of `api_docs.lua` like any other code change.
`rs3testkit/lua/ids_observed.lua` holds the stylesheet and font names seen in
a live client.

## Running the kit's own tests

```bash
python -m unittest discover -s tests
```

## License

MIT for the code (see [LICENSE](LICENSE)). API names and types in
`api_docs.lua` describe Jagex's public plugin API and come from its docs.
RuneScape is a trademark of Jagex Ltd. This project is not affiliated with
Jagex.
