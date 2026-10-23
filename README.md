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

### Mouse presses (`kit.pointer`)

`kit.pointer` plays a mouse against the components on the plugin layer, by
the rules measured in the beta client (October 2026):

- A press goes to the topmost shown component under the cursor that is not
  `clickthrough`, and a component only takes the cursor inside all of its
  ancestors' bounds. `ONCLICK` fires when the button goes down.
- A held press ends with **no release** when another component becomes
  topmost under the cursor, or when the pressed component or an ancestor is
  reordered (`MoveToFront` / `MoveToBack`), for example by another plugin
  bringing its window forward.
- A component hidden while pressed never gets its release: `isClicked`
  stays true for good.
- `ONDRAG` and `ONDRAGCOMPLETE` never fire, on any component or
  `dragConfig`. So `kit.ui.drag` refuses to fake them, and subscribing to
  them raises a lint. Dragging has to poll the press and `Mouse.GetX/GetY`.

The rules are applied after every move and every `kit.tick` / `kit.draw`
frame:

```lua
local target = kit.pointer.press(150, 105)   -- a window's title bar
kit.pointer.move(260, 140); kit.tick()       -- the plugin polls isClicked + Mouse
local r = kit.pointer.release()              -- { released, dropped = reason, sticky }
```

The model came from Proteus's live tests.

### Behaviour from a live client

These were found by running plugins in the beta client (October 2026). The
kit reproduces them so you find them offline:

- The client requires `"dependencies": {}` as a JSON object. The documented
  `requiredDependencies` / `optionalDependencies` arrays fail with
  `unexpected json Array, expected a json Object`.
- `clickthrough` defaults to true, so clicks on your window also walk the
  player until you set it to false. The kit reports this as a lint.
- No component ever receives `ONDRAG` / `ONDRAGCOMPLETE`, and a component
  hidden by its own press reads `isClicked == true` forever (see Mouse
  presses above).
- `ui.ComponentType` skips 19: `LAYER` is 20 up to `GROUP_BOX` 24.
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

Globals in a spec: `kit`, `test(name, fn)`, `scenario(name, fn)` (a test that is a feature, for the behaviour map), `expect(value)`, the game API
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
| `kit.ids.add("NPC", "GOBLIN", 11240)` | a name for an `id.*` table (or use `--ids`, below) |
| `kit.fonts.measureWith(function(font, text) ... end)` | the rule `FontType:GetStringWidth` uses (the kit has no font metrics); `config.Font.NAME` exists for every `id.Font` name |

**Menus and UI**

| Call | Does |
|---|---|
| `kit.menu.entry{ npc = e, verb =, subject = }` (or `loc = id`, `obj = id`) | a game menu entry |
| `kit.menu.open{ entries }` | runs `MiniMenuEntryAdded` → `MiniMenuReady` → `MiniMenuOpened` |
| `handle:select("Label")` | runs a plugin entry's function, fires `EntrySelected` and `Closed` |
| `kit.ui.texts()` | visible `ui.Text` contents, in creation order (hidden parents count) |
| `kit.ui.button(label[, prefix])`, `kit.ui.press(label)` | press a visible, enabled button |
| `kit.ui.click(component or "text")` | `ONCLICK` on that component |
| `kit.pointer.press(x, y)`, `.move(x, y)`, `.release()`, `.click(x, y)` | a real mouse: hit-tests the layer and applies the client's press rules (below) |
| `kit.ui.hold(c[, false])`, `kit.ui.hover(c[, false])`, `kit.ui.drop(c)`, `kit.mouse.set(x, y)` | set `isClicked` / `isMouseOver` on one component directly (`drop` ends a press with no release) |
| `kit.ui.reorders(c)`, `kit.ui.calls(c)` | how often `MoveToFront`/`MoveToBack` moved it; the void visual calls it received |
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

## Full id tables (`--ids`)

On its own, the kit knows only the id names seen in a live client: all
stylesheets, the font names and the plugin layer. For everything else
(`id.NPC`, `id.Obj`, `id.Component`, `id.VarPlayer`, `id.Sprite`, real font
numbers, ...), point it at a local clone of the community
[LuaLS stubs](https://github.com/FriendlyDevelopment/runescape-api-stubs):

```bash
git clone --depth 1 https://github.com/FriendlyDevelopment/runescape-api-stubs
```

```bash
rs3test run plugin spec --ids ../runescape-api-stubs
```

Setting `RS3_API_STUBS` to the clone's path does the same. The kit reads the
clone's `csvs/` folder: each table is parsed the first time a spec looks a
name up in it, and stays loaded for the rest of the run. The run summary
says which commit the ids came from (`id tables: runescape-api-stubs @
39f563a`). A name in neither the kit nor the stubs still fails loudly.

The stubs repo has no licence, so the kit doesn't copy its files and you
need your own clone. In a plugin's CI, clone it in a step before
`rs3test run`. The same clone gives your editor autocomplete; its README
explains how.

## Code activation

`rs3test run ... --activation run.jsonl` records every line, call and return
that runs inside the plugin's own files, including its dependencies but not
the kit or the spec. Each event is tagged with the test that was running:

```json
{"spec": "window_spec.lua", "test": "clicking a drop opens that item", "kind": "call", "plugin": "Advanced Examine", "file": "views.lua", "line": 88, "fn": "quantityText"}
```

This shows which code a behaviour touches, for the developer or for a
reviewer. In a spec, `kit.activation.start(sink)` streams the same events to
a function as they happen, which is the hook point for a live code view.
`{ lines = false }` limits it to calls and returns. The log stops at 200,000
events per file and says so in a lint; raise the cap with
`kit.activation.setLimit(n)`. It runs on Lua's `debug.sethook`, so it works
only offline: the client sandbox is not known to provide `debug` (unverified).

## Behaviour map (`rs3test map`)

A Markdown section for a plugin's README, saying which of the plugin's
functions run for each feature. It's for readers who don't want to read the
whole codebase: players, other developers, and Jagex reviewers ("clicking a
drop runs `open` → `Views.item` → `Lookup.dropsOfItem` ..."). It is
regenerated from real test runs, so it can't drift from the code.

Mark the tests that are features with `scenario` instead of `test`:

```lua
scenario("Right-click a goblin and choose Advanced Examine", function()
    kit.menu.open({ kit.menu.entry{ npc = goblin, verb = "Examine" } }):select("Advanced Examine")
end)
```

Then put two marker lines in the README where the map goes:

```
<!-- behaviour-map:start -->
<!-- behaviour-map:end -->
```

```bash
rs3test map plugin spec --readme README.md
```

- Each line is one of the plugin's own functions, with the file and line it is
  defined at, nested under the function that called it. The game API, the
  kit and the spec are left out.
- Entry points say what triggered them: `Event.SkillTransmit handler
  "tracker"`, `ONBUTTONPRESSED on the Back button`, `menu entry "Advanced
  Examine" chosen`, `HTTP GET ... reply`.
- Repeats are merged, so a loop is one line with `×600`. A function that
  calls only one other is written `a` → `b`. `--depth` (default 4) and
  `--width` (default 8) keep it short and say how much they left out.
- If a file has no `scenario`, every test is mapped, or pick tests with
  `--only REGEX`.
- It fails rather than writing a map when a scenario fails, when one runs
  none of the plugin's code (an assertion-only test marked as a feature), or
  when the README has no markers.
- Tail calls: a function that ends with `return f(x)` hands its place to `f`,
  so `f` appears beside it rather than under it. That's how Lua runs it.

[`examples/behaviour-map-advanced-examine.md`](examples/behaviour-map-advanced-examine.md)
is the map for Advanced Examine's window tests.

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
example, without `--ids` the `id.Font` numbers are assigned by the kit, so
never hard-code them.

For checking in the beta client, [`devlink/`](devlink/README.md) is a dev-only
plugin plus a local server that lets a session on your PC read game state, run
read-only commands and watch events in the live client. It is kept apart from
the kit: the kit itself still has no network code.

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
