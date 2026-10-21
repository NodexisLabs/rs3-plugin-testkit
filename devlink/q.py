import sys, json, subprocess
out = subprocess.run([sys.executable, "-I", "server.py", "cmd", sys.argv[1]], capture_output=True, text=True).stdout
try:
    d = json.loads(out); print(json.dumps(d.get("error") or d.get("value"))[:3000])
except Exception:
    print("RAW:", out[:500])
