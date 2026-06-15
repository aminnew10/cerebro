import sys, json, time, urllib.request

# Tiny control helper for the headless `opencode serve` a paired child runs
# under. Subcommands:
#   health <base_url>          -- exit 0 once the server answers, else 1
#   create <base_url> <title>  -- create a session, print its id

op = sys.argv[1] if len(sys.argv) > 1 else ""

if op == "health":
    url = sys.argv[2].rstrip("/")
    for _ in range(80):
        try:
            urllib.request.urlopen(url + "/global/health", timeout=2)
            sys.exit(0)
        except Exception:
            time.sleep(0.2)
    sys.exit(1)

elif op == "create":
    url = sys.argv[2].rstrip("/")
    title = sys.argv[3] if len(sys.argv) > 3 else ""
    data = json.dumps({"title": title}).encode("utf-8")
    req = urllib.request.Request(url + "/session", data=data,
                                 headers={"content-type": "application/json"},
                                 method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            sid = json.load(r).get("id", "")
    except Exception:
        sys.exit(1)
    if not sid:
        sys.exit(1)
    print(sid)

else:
    sys.exit(2)
