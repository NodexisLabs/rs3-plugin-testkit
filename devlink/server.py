"""devlink: local bridge between the RS3 beta client and a troubleshooting session.

The devlink plugin (dev_plugins/devlink) talks to this server on 127.0.0.1 only:
  POST /log     plugin -> server: newline-delimited JSON events and command results
  GET  /poll    plugin -> server: pending commands, one "id<TAB>command" per line
And the operator side:
  POST /cmd     enqueue a command (body = command text); returns its id
  GET  /result?id=N   the result for command N, once the plugin has answered
  GET  /status  plugin last-seen time and counts

Every request needs the server's key, so other programs on this PC (another agent
session, say) cannot send commands by accident. The key is made once and kept in
key.txt next to this file; rs3-dev.ps1 deploy copies it into the plugin. Clients send
it as a path prefix (/k/<key>/poll, what the plugin uses) or an X-Devlink-Key header.

Everything the plugin sends is appended to logs/devlink-<date>.jsonl.
The game API offers no way to send input. The plugin's commands only read,
except eval, which runs any Lua it is sent inside the plugin's sandbox; that is
why every request needs the key.

    python server.py                 # serve on 127.0.0.1:8765
    python server.py cmd "npcs"      # send a command and print the answer
    python server.py tail 30         # last 30 log lines
    python server.py key             # print the key (made on first use)
    python server.py new-key         # replace the key; deploy devlink again after
"""

import hmac
import json
import secrets
import sys
import threading
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOST, PORT = "127.0.0.1", 8765
LOG_DIR = Path(__file__).resolve().parent / "logs"
KEY_FILE = Path(__file__).resolve().parent / "key.txt"
REFUSED = ("devlink: missing or wrong key. This server belongs to the user's RS3 plugin "
           "troubleshooting; ask them before sending it anything.")


def load_key(renew=False):
    """The server key: kept across restarts, made only when missing or on request."""
    if renew or not KEY_FILE.exists():
        KEY_FILE.write_text(secrets.token_urlsafe(24), encoding="utf-8")
    key = KEY_FILE.read_text(encoding="utf-8").strip()
    if not key:
        raise SystemExit(f"{KEY_FILE} is empty; run: python server.py new-key")
    return key

_lock = threading.Lock()
_queue = []            # [(id, command)] waiting for the plugin
_results = {}          # id -> result event
_next_id = 1
_stats = {"lastPoll": None, "events": 0, "polls": 0, "refused": 0, "lastRefused": None}


def _log_path():
    LOG_DIR.mkdir(exist_ok=True)
    return LOG_DIR / f"devlink-{datetime.now().strftime('%Y-%m-%d')}.jsonl"


def _now():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):   # keep the console quiet; the jsonl is the record
        pass

    def _reply(self, code, body, ctype="text/plain"):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _authorized_path(self):
        """The request path with the key prefix removed, or None (after replying 401)."""
        url = urllib.parse.urlparse(self.path)
        path, given = url.path, self.headers.get("X-Devlink-Key", "")
        if path.startswith("/k/"):
            given, _, rest = path[3:].partition("/")
            path = "/" + rest
        if not hmac.compare_digest(given.encode(), self.server.key.encode()):
            # Count refusals (path only, never the key given) so a mismatch is visible in /status.
            with _lock:
                _stats["refused"] += 1
                _stats["lastRefused"] = f"{_now()} {self.command} {path} key={'yes' if given else 'none'}"
            self._reply(401, REFUSED)
            return None, url
        return path, url

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length).decode("utf-8", errors="replace")

    def do_POST(self):
        global _next_id
        path, _ = self._authorized_path()
        if path is None:
            return
        if path == "/log":
            lines = [l for l in self._body().splitlines() if l.strip()]
            with _lock, _log_path().open("a", encoding="utf-8") as f:
                for line in lines:
                    try:
                        event = json.loads(line)
                    except json.JSONDecodeError:
                        # Keep malformed lines visibly instead of dropping them.
                        event = {"kind": "unparsed", "raw": line}
                    event["recv"] = _now()
                    f.write(json.dumps(event) + "\n")
                    _stats["events"] += 1
                    if event.get("kind") == "result" and "id" in event:
                        _results[int(event["id"])] = event
            self._reply(200, "ok")
        elif path == "/cmd":
            command = self._body().strip()
            if not command or "\t" in command or "\n" in command:
                self._reply(400, "command must be one line with no tabs")
                return
            with _lock:
                cid = _next_id
                _next_id += 1
                _queue.append((cid, command))
            self._reply(200, str(cid))
        else:
            self._reply(404, "unknown path")

    def do_GET(self):
        path, url = self._authorized_path()
        if path is None:
            return
        if path == "/poll":
            with _lock:
                pending = list(_queue)
                _queue.clear()
                _stats["lastPoll"] = _now()
                _stats["polls"] += 1
            self._reply(200, "".join(f"{cid}\t{cmd}\n" for cid, cmd in pending))
        elif path == "/result":
            cid = int(urllib.parse.parse_qs(url.query).get("id", ["0"])[0])
            with _lock:
                result = _results.get(cid)
            if result is None:
                self._reply(404, "pending")
            else:
                self._reply(200, json.dumps(result), "application/json")
        elif path == "/status":
            with _lock:
                self._reply(200, json.dumps({**_stats, "queued": len(_queue)}), "application/json")
        else:
            self._reply(404, "unknown path")


class ExclusiveServer(ThreadingHTTPServer):
    # Windows lets several sockets share a port when SO_REUSEADDR is set, which
    # silently splits requests between stale and new servers. Refuse instead.
    allow_reuse_address = False


def serve():
    server = ExclusiveServer((HOST, PORT), Handler)
    server.key = load_key()
    print(f"devlink listening on http://{HOST}:{PORT}  log: {_log_path()}")
    server.serve_forever()


def send_command(command, timeout_s=15):
    base = f"http://{HOST}:{PORT}/k/{load_key()}"
    req = urllib.request.Request(base + "/cmd", data=command.encode("utf-8"), method="POST")
    cid = urllib.request.urlopen(req, timeout=5).read().decode()
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            body = urllib.request.urlopen(f"{base}/result?id={cid}", timeout=5).read().decode()
            print(json.dumps(json.loads(body), indent=2))
            return 0
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise
        time.sleep(0.5)
    status = urllib.request.urlopen(base + "/status", timeout=5).read().decode()
    print(f"no answer to command {cid} within {timeout_s}s. server status: {status}")
    return 1


def tail(n):
    files = sorted(LOG_DIR.glob("devlink-*.jsonl"))
    if not files:
        print("no devlink logs yet")
        return
    for line in files[-1].read_text(encoding="utf-8").splitlines()[-n:]:
        print(line)


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "cmd":
        sys.exit(send_command(" ".join(sys.argv[2:])))
    elif len(sys.argv) >= 2 and sys.argv[1] in ("key", "new-key"):
        print(load_key(renew=sys.argv[1] == "new-key"))
    elif len(sys.argv) >= 2 and sys.argv[1] == "tail":
        tail(int(sys.argv[2]) if len(sys.argv) > 2 else 30)
    else:
        serve()
