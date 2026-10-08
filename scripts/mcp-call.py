#!/usr/bin/env python3
# Usage: scripts/mcp-call.py tool '{"json":"args"}' -- one tools/call against a fresh `thegrid mcp serve`.
import json, subprocess, sys, base64
tool, args = sys.argv[1], json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
frames = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": tool, "arguments": args}},
]
out = subprocess.run(["thegrid", "mcp", "serve"], input="\n".join(json.dumps(f) for f in frames) + "\n",
                     capture_output=True, text=True, timeout=60).stdout
for line in out.splitlines():
    frame = json.loads(line)
    if frame.get("id") != 2:
        continue
    result = frame.get("result", frame)
    if result.get("isError"):
        print("ISERROR")
    for c in result.get("content", []):
        if c["type"] == "image":
            raw = base64.b64decode(c["data"])
            path = f"shot.{'jpg' if 'jpeg' in c['mimeType'] else 'png'}"
            open(path, "wb").write(raw)
            print(f"<image {c['mimeType']} {len(raw)} bytes -> {path}>")
        else:
            print(c["text"])
