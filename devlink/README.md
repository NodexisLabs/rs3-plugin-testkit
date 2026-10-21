# devlink

The live half of the kit. The rest of the kit runs your plugin offline against a mock; devlink
connects a session on your PC to the real beta client, so you can see what the game is actually
doing while you test. It is a dev-only plugin: **never submit it to the Plugin Hub.**

- `plugin/` goes in `dev_plugins/devlink`. It polls the local server once a second for commands,
  answers them, and sends back results and watched events.
- `server.py` listens on `127.0.0.1:8765` only. Everything the plugin sends is logged to
  `logs/devlink-<date>.jsonl`.
- `rs-shot.ps1` captures only the client's window (or just the console) to `shots/`, and refuses if
  another window covers it, so no other app ends up in the image. It never moves or focuses windows.

It cannot act in the game: the plugin API has no way to send input, and the commands only read.
The kit's offline parts still have no network code; devlink is kept in this folder on its own.

## Commands

`help`, `ping`, `state`, `npcs [pattern]`, `inv <name|id>` (bank only after it was opened),
`menu`, `dump <path>`, `eval <lua>`, `watch <menuselect|gamestate|inventory|npcadded> [off]`.

```
python server.py                 # run the server
python server.py cmd "npcs cow*" # send a command and print the answer
python q.py state                # same, value only
python server.py tail 30         # last 30 log lines
```

Other dev plugins can log through it: add `"optionalDependencies": {"devlink": "devlink"}` to the
dev copy of their manifest and call `devlink.log(tag, data)`.

## The key

Every request to the server needs its key, so other programs on the PC (another agent session,
say) can't send commands by accident. The key is made on first use and kept in `key.txt`
(git-ignored), across restarts.

- `python server.py key` prints it; `python server.py new-key` replaces it.
- The deployed plugin needs a copy, as `dev_plugins/devlink/devlink_key.lua` containing
  `return { key = "<key>" }`. Write it with your deploy step; never commit it.
- Clients send it as a path prefix (`/k/<key>/poll`) or an `X-Devlink-Key` header. A wrong or
  missing key gets a 401, and `/status` counts refusals.

## Setting it up in the beta client

1. Copy `plugin/` to `dev_plugins/devlink` and write `devlink_key.lua` next to it.
2. Start `python server.py`.
3. In the console: `prf`, `pon devlink`, then `plugins_permissions_enable devlink httpAccess`.

Client behaviour found while building it (October 2026):

- `require` returned `nil` for a module that returns a bare string; return a table.
- A file added to a plugin folder is only seen after `prf`; `prl` alone doesn't pick it up.
- `prl` turns an optional permission off again. `plugins_permissions_enable` alone didn't restore
  it; `ppr devlink` first, then `plugins_permissions_enable devlink httpAccess`, did.
- Event subscriptions made from inside an `eval` never fired.
