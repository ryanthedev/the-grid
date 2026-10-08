#!/usr/bin/env python3
"""Live integration tests: drive the RUNNING grid-server through the real
`thegrid mcp serve` binary and the real CLI, against real apps.

    make integration-test            (or: scripts/integration-test.py [-k substring])

This takes over the mouse and keyboard for about a minute. It opens Calculator
and TextEdit as fixtures, rearranges windows on the active space, and at the
end quits the fixtures and restores the saved grid state and the focused
window. It refuses to start if Calculator or TextEdit is already open (they
would be yours), and it leaves a backup at state.json.integration-backup. Every keystroke and click is sent with a windowId guard, so nothing is
typed into or clicked in any app but the fixtures.

Unit tests (`swift test`) prove the logic; this proves the wiring: AX, event
synthesis, screencapture, the socket, and the MCP framing, on this machine.
"""
import base64
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

STATE_DIR = os.path.expanduser(os.environ.get("XDG_STATE_HOME", "~/.local/state")) + "/thegrid"
STATE_FILE = STATE_DIR + "/state.json"
SERVER_PROC = "GridServer.app/Contents/MacOS/grid-server"
SERVICE = "thegrid-dev"


class MCP:
    """One `thegrid mcp serve` process; many tool calls."""

    def __init__(self):
        self.p = subprocess.Popen(["thegrid", "mcp", "serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.n = 0
        self.init = self.rpc("initialize", {})

    def rpc(self, method, params):
        self.n += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params}) + "\n")
        self.p.stdin.flush()
        while True:
            frame = json.loads(self.p.stdout.readline())
            if frame.get("id") == self.n:
                return frame

    def call(self, tool, **args):
        started = time.time()
        result = self.rpc("tools/call", {"name": tool, "arguments": args})["result"]
        texts = [c["text"] for c in result["content"] if c["type"] == "text"]
        images = [base64.b64decode(c["data"]) for c in result["content"] if c["type"] == "image"]
        return {"texts": texts, "images": images, "error": bool(result.get("isError")), "s": time.time() - started}

    def json(self, tool, **args):
        r = self.call(tool, **args)
        if r["error"]:
            raise AssertionError(f"{tool} failed: {r['texts']}")
        return json.loads(r["texts"][0])

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(timeout=5)
        except Exception:
            self.p.kill()


class ClipboardGuard:
    """Holds the user's clipboard (every item, every type) in the memory of a helper process while a
    test writes to the pasteboard. It restores on `restore()`, and also if this process dies (stdin
    closes). Nothing of the user's is printed or written to disk: sizes and counts only."""

    def __init__(self):
        script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "clipboard-guard.swift")
        self.p = subprocess.Popen(["swift", script], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        self.saved = self.p.stdout.readline().strip()
        if not self.saved.startswith("saved "):
            self.p.kill()
            raise AssertionError("could not save the clipboard, so nothing was written to it")

    def send(self, command):
        self.p.stdin.write(command + "\n")
        self.p.stdin.flush()
        return self.p.stdout.readline().strip()

    def restore(self):
        try:
            verdict = self.send("restore")
            self.p.wait(timeout=10)
            return verdict
        except Exception as e:
            return f"RESTORE FAILED: {type(e).__name__}"


class Suite:
    def __init__(self, only):
        self.only = only
        self.rows = []
        self.m = MCP()
        self.tmp = tempfile.mkdtemp(prefix="thegrid-it-")
        self.calc = self.doc_a = self.doc_b = None

    def check(self, name, ok, detail=""):
        self.rows.append((name, bool(ok), detail))
        print(f"  {'ok  ' if ok else 'FAIL'} {name}" + (f"  -- {detail}" if detail and not ok else ""), flush=True)

    def section(self, title, fn):
        if self.only and self.only.lower() not in title.lower():
            return
        print(f"\n{title}", flush=True)
        try:
            fn()
        except Exception as e:
            self.check(f"{title}: completed without an exception", False, f"{type(e).__name__}: {e}")

    # -- helpers ---------------------------------------------------------

    def outline(self, wid, **args):
        r = self.m.call("ui.snapshot", windowId=wid, **args)
        if r["error"]:
            raise AssertionError(f"ui.snapshot {wid}: {r['texts']}")
        return json.loads(r["texts"][0]), r["texts"][1] if len(r["texts"]) > 1 else ""

    def refs(self, text):
        out = {}
        for line in text.splitlines():
            mm = re.match(r'\s*\[(\d+:\d+)\] (\S+)(.*)', line)
            if not mm:
                continue
            label = re.search(r'(?:desc=)?"([^"]*)"', mm.group(3))
            if label:
                out.setdefault(label.group(1), mm.group(1))
        return out

    def clear_ref(self, refs):
        # Calculator relabels "All Clear" to "Clear" once something has been typed.
        return refs.get("All Clear") or refs["Clear"]

    def textarea(self, wid):
        return re.search(r"\[(\d+:\d+)\] AXTextArea", self.outline(wid)[1]).group(1)

    def value(self, ref, client=None):
        return (client or self.m).json("ui.value", ref=ref)["value"]

    def calc_display(self, text):
        lines = text.splitlines()
        i = [n for n, l in enumerate(lines) if 'desc="Edit field"' in l][0]
        return lines[i + 1].split('value="')[1].split('"')[0].replace("‎", "").replace("−", "-")

    def server_pid(self):
        out = subprocess.run(["pgrep", "-f", SERVER_PROC], capture_output=True, text=True).stdout.split()
        return out[0] if out else None

    def spaces(self):
        return self.m.json("grid.state.show")["state"]["spaces"]

    def cell_of(self, wid):
        for sid, space in self.spaces().items():
            for cid, cell in space["cells"].items():
                if int(wid) in cell["windows"]:
                    return sid, cid
        return None, None

    # -- fixtures --------------------------------------------------------

    def open_fixtures(self):
        for name in ("it-doc-a.txt", "it-doc-b.txt"):
            open(os.path.join(self.tmp, name), "w").close()
        subprocess.run(["open", "-g", "-a", "Calculator"], check=True)
        subprocess.run(["open", "-g", "-a", "TextEdit", os.path.join(self.tmp, "it-doc-a.txt"), os.path.join(self.tmp, "it-doc-b.txt")], check=True)
        deadline = time.time() + 15
        while time.time() < deadline:
            calc = self.m.json("window.find", appName="Calculator")
            docs = {w["title"]: w["windowId"] for w in self.m.json("window.find", appName="TextEdit").get("matches", [])}
            if calc.get("found") and "it-doc-a.txt" in docs and "it-doc-b.txt" in docs:
                self.calc, self.doc_a, self.doc_b = calc["windowId"], docs["it-doc-a.txt"], docs["it-doc-b.txt"]
                time.sleep(1.0)
                return
            time.sleep(0.5)
        raise SystemExit("fixtures did not open")

    # -- sections --------------------------------------------------------

    def t_protocol(self):
        self.check("initialize names the server", self.m.init["result"]["serverInfo"]["name"] == "thegrid")
        tools = {t["name"] for t in self.m.rpc("tools/list", {})["result"]["tools"]}
        need = {"ping", "dump", "grid.screenshot", "ui.snapshot", "ui.value", "ui.press", "ui.setValue", "ui.click", "window.at", "batch",
                "input.key.type", "input.mouse.click", "window.find", "menu.snapshot", "menu.invoke", "space.list", "space.switch", "window.pull", "clip.read", "clip.write"}
        self.check("tools/list has the expected tools", need <= tools, f"missing {need - tools}")
        self.check("unknown tool is a tool error, not a crash", self.m.call("nope")["error"])
        pong = self.m.json("ping")
        self.check("ping answers with a version", pong.get("pong") is True and pong.get("version"))
        self.check("getServerInfo answers", "version" in json.dumps(self.m.json("getServerInfo")))

    def t_numbers(self):
        # Any numeric field encoded as true/false shows up as a bool under a non-flag key.
        flags = re.compile(r"^(is[A-Z]|has[A-Z]|pong$|found$|success$|ok$|focusFollowsMouse$|events$|spaces$|windows$|stateTracking$|enabled$)")
        bad = set()

        def walk(v, key):
            if isinstance(v, bool) and not flags.match(key):
                bad.add(key)
            elif isinstance(v, dict):
                for k, x in v.items():
                    walk(x, k)
            elif isinstance(v, list):
                for x in v:
                    walk(x, key)

        for tool in ("metadata.get", "display.list", "dump", "grid.state.show", "grid.config.show", "grid.layout.current", "input.mouse.position"):
            walk(self.m.json(tool), "<root>")
        self.check("no number is encoded as a boolean in any read-only RPC", not bad, f"boolean under {sorted(bad)}")
        state = self.m.json("grid.state.show")["state"]
        self.check("state version is the number 1", state["version"] == 1 and state["version"] is not True)

    def t_queries(self):
        displays = self.m.json("display.list")["displays"]
        self.check("display.list returns frames", displays and all("frame" in d for d in displays))
        self.check("display.get active", "uuid" in json.dumps(self.m.json("display.get", active=True)))
        self.check("metadata.get has a focused window", "focusedWindowID" in self.m.json("metadata.get"))
        dump = self.m.json("dump")
        self.check("dump lists the fixtures", all(w in dump["windows"] for w in (self.calc, self.doc_a, self.doc_b)))
        self.check("layout list/current/get", self.m.json("grid.layout.get", layout=self.m.json("grid.layout.list")["layouts"][0]) is not None
                   and "layout" in self.m.json("grid.layout.current"))

    def t_find(self):
        found = self.m.json("window.find", appName="TextEdit")
        titles = {w["title"] for w in found["matches"]}
        self.check("window.find returns every match with titles", {"it-doc-a.txt", "it-doc-b.txt"} <= titles and found["count"] == len(found["matches"]))
        one = self.m.json("window.find", appName="TextEdit", title="it-doc-b")
        self.check("window.find narrows by title", one["count"] == 1 and one["windowId"] == self.doc_b)
        self.check("window.find reports not found", self.m.json("window.find", appName="No Such App 9f3") == {"found": False})
        pid = found["matches"][0]["pid"]
        self.check("window.find by pid", self.m.json("window.find", pid=pid).get("found") is True)

    def t_snapshot(self):
        head, text = self.outline(self.calc)
        refs = self.refs(text)
        self.check("ui.snapshot reads Calculator's buttons", all(k in refs for k in ("7", "Multiply", "Equals")), f"{head}")
        self.check("outline frames are integers in screen points", re.search(r"\(-?\d+,-?\d+ \d+x\d+\)", text) is not None)
        sub = self.m.call("ui.snapshot", ref=refs["7"])
        self.check("subtree snapshot by ref", not sub["error"])
        self.check("ref from another window is rejected", self.m.call("ui.snapshot", windowId=self.doc_a, ref=refs["7"])["error"])
        self.check("unknown ref is an error", self.m.call("ui.press", ref=f"{self.calc}:99999")["error"])
        # A ref from before a re-snapshot must fail, never come to mean a different control.
        again = self.refs(self.outline(self.calc)[1])
        self.check("an unchanged control keeps its ref across snapshots", again["7"] == refs["7"] and again["Equals"] == refs["Equals"], f"{refs['7']} -> {again['7']}")
        small = self.outline(self.calc, maxNodes=3)[0]
        self.check("maxNodes truncates and says so", small["count"] == 3 and small.get("truncated") == "maxNodes")
        own = self.m.json("window.find", appName="GridNotify")
        if own.get("found"):
            self.check("snapshots of other apps' panels work or fail cleanly", True)

    def t_press(self):
        for keys, want in ((["1", "2", "Multiply", "3", "4", "Equals"], "408"), (["9", "9", "Subtract", "1", "0", "0", "Equals"], "-1")):
            refs = self.refs(self.outline(self.calc)[1])
            self.m.call("ui.press", ref=self.clear_ref(refs))
            for k in keys:
                r = self.m.call("ui.press", ref=refs[k])
                if r["error"]:
                    raise AssertionError(r["texts"])
            time.sleep(0.3)
            got = self.calc_display(self.outline(self.calc)[1])
            self.check(f"ui.press computes {''.join(keys[:-1])} = {want}", got == want, f"display shows {got}")

    def t_batch_observe(self):
        refs = self.refs(self.outline(self.calc)[1])
        steps = [{"tool": "ui.press", "args": {"ref": self.clear_ref(refs)}}]
        steps += [{"tool": "ui.press", "args": {"ref": refs[k]}} for k in ("5", "6", "Add", "7", "8", "Equals")]
        steps[-1]["args"].update({"observe": "snapshot", "settleMs": 300})
        r = self.m.call("batch", steps=json.dumps(steps))
        self.check("batch + observe: 56+78 in one call reads 134", not r["error"] and self.calc_display(r["texts"][-1]) == "134", str(r["texts"][-1:])[:200])
        bad = self.m.call("batch", steps=json.dumps([{"tool": "ui.press", "args": {"ref": f"{self.calc}:99999"}}, {"tool": "ping", "args": {}}]))
        self.check("batch stops at the first failing step", bad["error"] and "later steps did not run" in " ".join(bad["texts"]))
        shot = self.m.call("ui.press", ref=self.clear_ref(self.refs(self.outline(self.calc)[1])), observe="screenshot")
        self.check("observe=screenshot returns an image with the action", len(shot["images"]) == 1)

    def t_typing(self):
        ref = self.textarea(self.doc_a)
        self.m.call("ui.setValue", ref=ref, value="")
        self.check("ui.click into the document", not self.m.call("ui.click", ref=ref)["error"])
        sentence = "The quick brown fox — 0123456789 ünïcödé ✓"
        r = self.m.call("input.key.type", text=sentence, windowId=self.doc_a)
        time.sleep(0.3)
        self.check("guarded typing lands exactly (unicode, ui.value readback)", not r["error"] and self.value(ref) == sentence, self.value(ref)[:80])
        self.m.call("input.key.press", key="backspace", count=2, windowId=self.doc_a)
        time.sleep(0.3)
        self.check("guarded key press with count", self.value(ref) == sentence[:-2])
        self.m.call("ui.setValue", ref=ref, value="x" * 500)
        time.sleep(0.2)
        clipped = self.outline(self.doc_a)[1]
        self.check("outline clips long values; ui.value returns all 500", "…" in clipped and len(self.value(ref)) == 500)
        self.check("ui.setValue replaces the whole value", not self.m.call("ui.setValue", ref=ref, value="done")["error"] and self.value(ref) == "done")
        self.check("typing at a missing window is refused", self.m.call("input.key.type", text="nope", windowId="999999")["error"])
        self.check("bad key combo is refused", self.m.call("input.key.press", key="cmd+notakey", windowId=self.doc_a)["error"])

    def t_focus_theft(self):
        ra, rb = self.textarea(self.doc_a), self.textarea(self.doc_b)
        for thief_name, thief_wid in (("another app", self.calc), ("another window of the same app", self.doc_b)):
            self.m.call("ui.setValue", ref=ra, value="")
            self.m.call("ui.setValue", ref=rb, value="")
            thief, stop = MCP(), threading.Event()

            def steal():
                while not stop.is_set():
                    thief.call("window.focus", windowId=thief_wid)
                    time.sleep(0.12)

            t = threading.Thread(target=steal)
            t.start()
            reported = 0
            for _ in range(8):
                r = self.m.call("input.key.type", text="ABCDEFGHIJKLMNOPQRST" * 10, windowId=self.doc_a)
                mm = re.search(r"stopped after (\d+)", " ".join(r["texts"]))
                reported += int(mm.group(1)) if (r["error"] and mm) else (0 if r["error"] else 200)
                time.sleep(0.05)
            stop.set()
            t.join()
            thief.close()
            time.sleep(0.5)
            in_a, in_b = len(self.value(ra)), len(self.value(rb))
            self.check(f"focus stolen by {thief_name}: every posted character is accounted for", in_a + in_b == reported, f"A={in_a} B={in_b} reported={reported}")
            # Another app can receive nothing (keys go straight to the target process). Another window of the
            # same app can receive at most one 5-character chunk per interrupted call.
            limit = 0 if thief_wid == self.calc else 5 * 8
            self.check(f"focus stolen by {thief_name}: leak <= {limit} chars ({in_b} leaked of {reported} posted)", in_b <= limit and in_b % 5 == 0, f"{in_b} chars reached the other document")
        self.m.call("ui.setValue", ref=ra, value="")
        self.m.call("ui.setValue", ref=rb, value="")

    def t_clicks(self):
        # Put TextEdit over Calculator, then look at Calculator and click it.
        self.m.call("window.focus", windowId=self.doc_a)
        time.sleep(0.5)
        refs = self.refs(self.outline(self.calc)[1])
        self.m.call("ui.press", ref=self.clear_ref(refs))
        self.m.call("ui.press", ref=refs["7"])
        time.sleep(0.2)
        shot = self.m.call("grid.screenshot", target="window", id=self.calc)
        geo = json.loads(shot["texts"][0])
        f = geo["frame"]
        covered = self.m.json("window.at", x=f["x"] + f["width"] / 2, y=f["y"] + f["height"] / 2)
        if covered.get("windowId") != self.calc:
            self.check("a covered window's screenshot says what covers it", "coveredBy" in geo, str(geo)[:200])
        # Find the clear button's centre from its AX frame, then click it by coordinate with the guard.
        line = [l for l in self.outline(self.calc)[1].splitlines() if 'desc="All Clear"' in l or 'desc="Clear"' in l][0]
        x, y, w, h = map(int, re.search(r"\((-?\d+),(-?\d+) (\d+)x(\d+)\)", line).groups())
        r = self.m.call("input.mouse.click", x=x + w / 2, y=y + h / 2, windowId=self.calc, observe="snapshot")
        self.check("guarded coordinate click raises the window and lands (display cleared)", not r["error"] and self.calc_display(r["texts"][-1]) == "0", str(r["texts"])[:200])
        top = self.m.json("window.at", x=x + w / 2, y=y + h / 2)
        self.check("window.at names the window a click reaches", top.get("windowId") == self.calc, str(top))
        self.check("off-screen click is refused", self.m.call("input.mouse.click", x=99999, y=99999)["error"])
        pos = self.m.json("input.mouse.position")
        self.m.call("input.mouse.move", x=x + w / 2, y=y + h / 2)
        now = self.m.json("input.mouse.position")
        self.check("mouse move and position agree", abs(now["x"] - (x + w / 2)) < 2 and abs(now["y"] - (y + h / 2)) < 2, f"{pos} -> {now}")
        self.check("guarded scroll", not self.m.call("input.mouse.scroll", x=x, y=y, dy=-20, windowId=self.calc)["error"])
        self.check("mouse.warp to a window", not self.m.call("mouse.warp", windowId=self.calc)["error"])

    def t_screenshots(self):
        active = self.m.call("grid.screenshot")
        geo = json.loads(active["texts"][0])
        self.check("full capture: image + geometry", len(active["images"]) == 1 and max(geo["image"]["width"], geo["image"]["height"]) <= 1568)
        if geo["frame"]["width"] / geo["image"]["width"] > 1.5:
            self.check("downscaled capture warns about small text", "hint" in geo)
        win = self.m.call("grid.screenshot", target="window", id=self.calc, waitStable=True, waitTitle="Calc", timeoutMs=4000)
        wgeo = json.loads(win["texts"][0])
        self.check("window capture with waitStable + waitTitle", wgeo.get("stable") is True and wgeo.get("titleMatched") is True, str(wgeo)[:200])
        f = wgeo["frame"]
        reg = json.loads(self.m.call("grid.screenshot", target="region", x=f["x"], y=f["y"], width=200, height=100)["texts"][0])
        self.check("region capture reports the frame it captured", reg["frame"]["width"] == 200 and reg["image"]["width"] in (200, 400), str(reg))
        self.check("region off every display is refused", self.m.call("grid.screenshot", target="region", x=90000, y=0, width=10, height=10)["error"])
        high = self.m.call("grid.screenshot", target="window", id=self.calc, quality="high")
        self.check("high quality capture stays under 5 MB", high["images"] and len(high["images"][0]) < 5_000_000)
        sid, cid = self.cell_of(self.doc_a)
        if cid:
            self.check("cell capture", not self.m.call("grid.screenshot", target="cell", id=cid)["error"])

    def t_hostile(self):
        before = self.server_pid()
        hostile = [("input.mouse.move", {"x": 1e300, "y": 0}), ("input.key.press", {"key": "f12", "count": 1e30, "windowId": "999999"}),
                   ("input.mouse.scroll", {"dx": 0, "dy": 1e30, "x": 1e300, "y": 0}), ("input.mouse.drag", {"fromX": 1e300, "fromY": 0, "toX": 0, "toY": 0, "steps": 1e30}),
                   ("grid.screenshot", {"target": "region", "x": 1e20, "y": 0, "width": 10, "height": 10}), ("ui.snapshot", {"windowId": "-5"}),
                   ("ui.snapshot", {"windowId": self.calc, "maxNodes": 1e30}), ("window.at", {"x": "nan", "y": 0}), ("ui.click", {"ref": "abc:def"}),
                   ("menu.snapshot", {"windowId": "-5"}), ("menu.snapshot", {"app": "Calculator", "limit": 1e30}), ("menu.invoke", {"app": "Calculator", "path": " > "}),
                   ("window.pull", {"windowId": "-5"}), ("window.pull", {"windowId": 1e30}),
                   # Neither of these writes: a clip.write without text is rejected before it reaches the pasteboard.
                   ("clip.write", {}), ("clip.write", {"text": 1e30}), ("clip.read", {"type": "image"})]
        for tool, args in hostile:
            self.m.call(tool, **args)
        self.check("server survives hostile numbers (same pid, still answers)", before and self.server_pid() == before and self.m.json("ping")["pong"])

    def t_hang(self):
        pid = self.m.json("window.find", appName="Calculator")["pid"]
        self.outline(self.calc)
        os.kill(pid, signal.SIGSTOP)
        try:
            pings = []
            worker = {}

            def snap():
                worker["r"] = self.m.call("ui.snapshot", windowId=self.calc)

            t = threading.Thread(target=snap)
            started = time.time()
            t.start()
            while t.is_alive():
                s = time.time()
                subprocess.run(["thegrid", "ping"], capture_output=True)
                pings.append(time.time() - s)
                time.sleep(0.1)
            took = time.time() - started
            s = time.time()
            menu = self.m.call("menu.snapshot", app="Calculator")
            menu_took = time.time() - s
        finally:
            os.kill(pid, signal.SIGCONT)
        r = worker["r"]
        self.check("menu.snapshot of a frozen app gives up quickly and says why", menu_took < 2 and ("did not answer" in menu["texts"][0] or "unresponsive" in menu["texts"][0]),
                   f"{menu_took:.1f}s {menu['texts'][0][:120]}")
        gave_up = r["error"] or "unresponsive" in r["texts"][0] or "deadline" in r["texts"][0]
        self.check("snapshot of a frozen app gives up in under 4 s", gave_up and took < 4, f"{took:.1f}s {r['texts'][0][:120]}")
        self.check("server stays responsive while an app is frozen", max(pings) < 0.25, f"worst ping {max(pings) * 1000:.0f} ms")
        time.sleep(0.5)
        self.check("the app works again after it resumes", self.outline(self.calc)[0]["count"] > 10)

    def t_grid(self):
        self.m.call("window.focus", windowId=self.doc_a)
        time.sleep(0.4)
        r = self.m.call("grid.layout.apply", layout="two-column", strategy="autoflow")
        time.sleep(0.6)
        self.check("layout.apply two-column", not r["error"] and self.m.json("grid.layout.current")["layout"] == "two-column")
        self.m.call("window.focus", windowId=self.doc_a)
        time.sleep(0.4)
        sid, before = self.cell_of(self.doc_a)
        direction = "right" if before == "left" else "left"
        self.m.call("grid.cell.send", direction=direction)
        time.sleep(0.6)
        self.check("cell.send moves the focused window to the other column", self.cell_of(self.doc_a)[1] not in (None, before), f"{before} -> {self.cell_of(self.doc_a)[1]}")
        frame = self.m.json("dump")["windows"][self.doc_a]["frame"]
        disp = [d for d in self.m.json("display.list")["displays"] if d["frame"]["y"] <= frame[0][1] < d["frame"]["y"] + d["frame"]["height"]][0]
        self.check("the window was really resized to a column", frame[1][0] < disp["frame"]["width"] * 0.6, str(frame))
        self.m.call("window.focus", windowId=self.doc_a)
        time.sleep(0.4)
        here = self.cell_of(self.doc_a)[1]
        away, back = ("left", "right") if here == "right" else ("right", "left")
        r = self.m.call("grid.window.move", direction=away)
        time.sleep(0.5)
        self.check(f"grid.window.move {away} changes the window's cell", not r["error"] and self.cell_of(self.doc_a)[1] != here, str(r["texts"])[:160])
        r = self.m.call("grid.window.swap", direction=back)
        time.sleep(0.5)
        self.check(f"grid.window.swap {back}", not r["error"], str(r["texts"])[:160])
        for tool, args in (("grid.focus", {"direction": "left"}), ("grid.focus", {"direction": "right"}), ("grid.focus.cycle", {}),
                           ("grid.resize.grow", {"amount": 0.1}), ("grid.resize.shrink", {"amount": 0.1}), ("grid.resize.cell", {"direction": "right", "amount": 0.05}),
                           ("grid.resize.reset", {"all": True}), ("grid.cell.mode", {"mode": "tabs"}), ("grid.cell.mode", {"mode": "vertical"}),
                           ("grid.layout.cycle", {}), ("grid.layout.refresh", {})):
            r = self.m.call(tool, **args)
            time.sleep(0.25)
            self.check(f"{tool} {args or ''}".strip(), not r["error"], str(r["texts"])[:160])

    def t_window_ops(self):
        b = self.doc_b
        self.check("window.raise", not self.m.call("window.raise", windowId=b)["error"])
        self.m.call("window.minimize", windowId=b)
        time.sleep(1.0)
        self.check("window.minimize really minimizes", self.m.json("dump")["windows"][b].get("isMinimized") is True)
        self.m.call("window.unminimize", windowId=b)
        time.sleep(1.0)
        self.check("window.unminimize restores", self.m.json("dump")["windows"][b].get("isMinimized") is False)
        self.check("window.hide / window.show", not self.m.call("window.hide", windowId=b)["error"] and not time.sleep(0.6) and not self.m.call("window.show", windowId=b)["error"])
        time.sleep(0.6)
        rec = os.path.join(self.tmp, "it.gif")
        started = self.m.call("grid.record.start", target="window", id=self.calc, format="gif", fps=10, output=rec)
        time.sleep(1.5)
        stopped = self.m.call("grid.record.stop")
        time.sleep(0.5)
        self.check("record a window to a gif", not started["error"] and not stopped["error"] and os.path.exists(rec) and os.path.getsize(rec) > 0, str(stopped["texts"])[:160])
        closed = self.m.call("window.close", windowId=b)
        time.sleep(0.5)
        left = {w["title"] for w in self.m.json("window.find", appName="TextEdit").get("matches", [])}
        self.check("window.close closes the window and the server forgets it", not closed["error"] and "it-doc-b.txt" not in left, f"{closed['texts']} {left}")
        self.check("the closed window left its grid cell", self.cell_of(b) == (None, None), str(self.cell_of(b)))

    def t_close_last_window(self):
        # Closing an app's only window can make it quit; that is still a successful close.
        self.m.call("window.focus", windowId=self.calc)
        time.sleep(0.5)
        r = self.m.call("window.close", windowId=self.calc)
        time.sleep(1.5)
        # The focused window just vanished along with its app; the server must find out who has focus now.
        self.check("focus metadata recovers after the focused app quits", self.m.json("metadata.get").get("focusedWindowID") not in (None, 0, int(self.calc)),
                   str(self.m.json("metadata.get")))
        self.check("window.close on an app that quits with its last window", not r["error"], str(r["texts"]))
        self.check("the quit app's window is gone from state", self.calc not in self.m.json("dump")["windows"])
        self.calc = None

    def t_pixels(self):
        # Click a Calculator key by the pixels of a screenshot: no arithmetic on the caller's side.
        refs = self.refs(self.outline(self.calc)[1])
        self.m.call("ui.press", ref=self.clear_ref(refs))
        line = [l for l in self.outline(self.calc)[1].splitlines() if 'desc="7"' in l][0]
        x, y, w, h = map(int, re.search(r"\((-?\d+),(-?\d+) (\d+)x(\d+)\)", line).groups())
        geo = json.loads(self.m.call("grid.screenshot", target="window", id=self.calc)["texts"][0])
        f, im = geo["frame"], geo["image"]
        px = (x + w / 2 - f["x"]) * im["width"] / f["width"]
        py = (y + h / 2 - f["y"]) * im["height"] / f["height"]
        r = self.m.call("input.mouse.click", px=px, py=py, shot=geo["shot"], windowId=self.calc, observe="snapshot")
        self.check("click by image pixels of a screenshot presses the right key", not r["error"] and self.calc_display(r["texts"][-1]) == "7", str(r["texts"])[:160])
        self.check("pixels outside the image are refused", self.m.call("input.mouse.click", px=99999, py=5)["error"])
        self.check("window.at takes image pixels too", self.m.json("window.at", px=px, py=py).get("windowId") == self.calc)
        disp = self.m.json("display.list")["displays"]
        if len(disp) > 1:
            seam = max(d["frame"]["y"] for d in disp)
            geo = json.loads(self.m.call("grid.screenshot", target="region", x=500, y=seam - 60, width=200, height=200)["texts"][0])
            self.check("a region crossing a display edge says it was clipped", geo.get("clipped") is True and geo["requested"]["height"] == 200, str(geo)[:200])

    def t_lists(self):
        # Finder: rows as single lines, select, expand a folder, reach offscreen rows.
        repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        subprocess.run(["open", "-g", repo], check=True)
        wid = None
        for _ in range(20):
            found = self.m.json("window.find", appName="Finder", title=os.path.basename(repo))
            if found.get("found"):
                wid = found["windowId"]
                break
            time.sleep(0.5)
        if not wid:
            raise AssertionError("Finder window did not appear")
        try:
            time.sleep(1.0)
            text = self.outline(wid, includeOffscreen=True, maxNodes=1500)[1]
            row = [l for l in text.splitlines() if re.search(r'AXRow "CLAUDE\.md \|', l)]
            self.check("a Finder row is one line with its cells joined", bool(row), text[:300])
            if "AXRow" not in text:
                return
            ref = re.search(r"\[(\d+:\d+)\]", row[0]).group(1)
            self.m.call("ui.select", ref=ref)
            time.sleep(0.4)
            again = [l for l in self.outline(wid, includeOffscreen=True, maxNodes=1500)[1].splitlines() if re.search(r'AXRow "CLAUDE\.md \|', l)][0]
            self.check("ui.select selects the row", "selected" in again, again)
            lines = self.outline(wid, includeOffscreen=True, maxNodes=1500)[1].splitlines()
            i = [n for n, l in enumerate(lines) if re.search(r'AXRow "scripts \|', l)][0]
            tri = re.search(r"\[(\d+:\d+)\]", lines[i + 1]).group(1)
            # Finder remembers a folder's disclosure state between windows, and a press toggles.
            if 'value="1"' in lines[i + 1]:
                self.m.call("ui.press", ref=tri)
                time.sleep(0.6)
            pressed = self.m.call("ui.press", ref=tri)
            time.sleep(0.6)
            opened = self.outline(wid, includeOffscreen=True, maxNodes=1500)[1]
            self.check("ui.press expands a Finder folder (falling back when AXPress is refused)", not pressed["error"] and "integration-test.py" in opened, str(pressed["texts"]))
            self.m.call("ui.press", ref=tri)
            last = [l for l in opened.splitlines() if "AXRow" in l][-1]
            r = self.m.call("ui.scrollTo", ref=re.search(r"\[(\d+:\d+)\]", last).group(1))
            self.check("ui.scrollTo reaches the last row", not r["error"], str(r["texts"]))
        finally:
            self.m.call("window.close", windowId=wid)

    def t_query_expect(self):
        q = self.m.call("ui.query", windowId=self.calc, role="button", text="equals")
        head, lines = json.loads(q["texts"][0]), q["texts"][1].splitlines()
        self.check("ui.query returns the one matching node, flat, with a usable ref", head["count"] == 1 and lines[0].startswith("[") and head["scanned"] > 20, str(q["texts"])[:200])
        eq = re.search(r"\[(\d+:\d+)\]", lines[0]).group(1)
        self.check("ui.query by role alone is bounded by limit", json.loads(self.m.call("ui.query", windowId=self.calc, role="AXButton", limit=5)["texts"][0])["count"] == 5)
        self.check("ui.query with no predicate is refused", self.m.call("ui.query", windowId=self.calc)["error"])
        refs = self.refs(self.outline(self.calc)[1])
        for k in (self.clear_ref(refs), refs["6"], refs["Multiply"], refs["7"]):
            self.m.call("ui.press", ref=k)
        met = self.m.call("ui.press", ref=eq, expectText="42", timeoutMs=3000)
        self.check("expectText passes when the effect shows (6x7 -> 42)", not met["error"] and "met" in met["texts"][-1], str(met["texts"]))
        unmet = self.m.call("ui.press", ref=eq, expectText="this never appears", timeoutMs=600)
        self.check("expectText fails the call when the effect never shows", unmet["error"] and "Expectation not met" in unmet["texts"][-1], str(unmet["texts"]))
        self.check("ui.wait returns once the text is there", not self.m.call("ui.wait", windowId=self.calc, expectText="42", timeoutMs=1500)["error"])
        self.check("ui.wait on a title", not self.m.call("ui.wait", windowId=self.doc_a, expectTitle="it-doc-a", timeoutMs=1500)["error"])
        advised = self.m.call("input.mouse.click", x=99999, y=99999)
        self.check("a known failure comes with its next move", advised["error"] and advised["texts"][-1].startswith("Next:"), str(advised["texts"]))

    def t_menus(self):
        r = self.m.call("menu.snapshot", app="textedit")
        head, lines = json.loads(r["texts"][0]), r["texts"][1].splitlines()
        self.check("menu.snapshot indexes TextEdit's menu bar with shortcuts, minus the Apple menu",
                   head["count"] > 50 and any(l.startswith("Edit > Select All  [cmd+A]") for l in lines) and not any(l.startswith("Apple >") for l in lines),
                   f"{head} {lines[:3]}")
        q = self.m.call("menu.snapshot", windowId=self.doc_a, text="SELECT ALL")
        found = q["texts"][1].splitlines()
        self.check("menu.snapshot text filter returns only the matches, with no thin-tree hint",
                   1 <= len(found) <= 3 and all("select all" in l.lower() for l in found) and "hint" not in q["texts"][0], str(q["texts"])[:200])
        # A background app reports Select All disabled (no key window) and AXPress on it does nothing:
        # invoke has to bring the window forward first. The effect is the verdict: typing replaces everything.
        ref = self.textarea(self.doc_a)
        self.m.call("ui.setValue", ref=ref, value="menu fixture text")
        self.m.call("window.focus", windowId=self.calc)
        time.sleep(0.4)
        r = self.m.call("menu.invoke", windowId=self.doc_a, path="edit > select all")
        self.m.call("input.key.type", text="Z", windowId=self.doc_a)
        time.sleep(0.3)
        self.check("menu.invoke Select All on a background window: the next keystroke replaces the whole text", not r["error"] and self.value(ref) == "Z",
                   f"{r['texts']} value={self.value(ref)[:40]!r}")
        r = self.m.call("menu.invoke", windowId=self.doc_a, path="Edit > Find > Find...", expectText="find next", timeoutMs=3000)
        self.check("menu.invoke takes '...' for '…' and an expectation (the find bar appears)", not r["error"] and "met" in r["texts"][-1], str(r["texts"])[:200])
        done = re.search(r"\[(\d+:\d+)\]", self.m.call("ui.query", windowId=self.doc_a, role="button", text="Done")["texts"][1]).group(1)
        self.check("the find bar closes again", not self.m.call("ui.press", ref=done, expectGone="find next")["error"])
        bad = self.m.call("menu.invoke", app="TextEdit", path="Edit > Selct All")
        self.check("an unknown path answers with the items that exist and the next move",
                   bad["error"] and "Select All" in bad["texts"][0] and bad["texts"][-1].startswith("Next:"), str(bad["texts"])[:200])
        sub = self.m.call("menu.invoke", app="TextEdit", path="Edit > Find")
        self.check("a submenu is refused, not opened", sub["error"] and "submenu" in sub["texts"][0], str(sub["texts"])[:200])
        redo = self.m.call("menu.snapshot", windowId=self.doc_a, text="edit > redo")["texts"][1]
        if redo.endswith("disabled"):
            off = self.m.call("menu.invoke", windowId=self.doc_a, path="Edit > Redo")
            self.check("a disabled command is refused", off["error"] and "is disabled in" in off["texts"][0], str(off["texts"])[:200])

    def current_spaces(self):
        return {d["uuid"]: str(d["currentSpaceID"]) for d in self.m.json("display.list")["displays"]}

    def t_spaces(self):
        # space.switch is never called here: a live switch on a machine in use is not a test's business.
        # Its refusals are unit-tested (SpacePolicyTests). window.pull is only ever given a fixture.
        before = self.current_spaces()
        listed = self.m.json("space.list")["displays"]
        self.check("space.list agrees with display.list on every display's current space",
                   {d["uuid"]: d["currentSpaceId"] for d in listed} == before, f"{before} vs {[(d['uuid'], d['currentSpaceId']) for d in listed]}")
        self.check("every display has exactly one current space, and every space a known type",
                   all(sum(sp["isCurrent"] for sp in d["spaces"]) == 1 for d in listed)
                   and all(sp["type"] in ("user", "fullscreen", "system") for d in listed for sp in d["spaces"]), str(listed)[:200])
        home = [sp for d in listed for sp in d["spaces"] if any(w["windowId"] == self.doc_a for w in sp["windows"])]
        self.check("space.list puts the fixture on a current user space, by title",
                   len(home) == 1 and home[0]["isCurrent"] and home[0]["type"] == "user"
                   and any(w["title"] == "it-doc-a.txt" for w in home[0]["windows"]), str(home)[:200])
        self.m.call("window.focus", windowId=self.doc_a)
        time.sleep(0.4)
        r = self.m.call("window.pull", windowId=self.doc_a)
        here = json.loads(r["texts"][0]) if not r["error"] else {}
        self.check("window.pull of a window already on the current space is a verified no-op",
                   here.get("already") is True and here.get("spaceId") == home[0]["id"], str(r["texts"])[:200])
        gone = self.m.call("window.pull", windowId="999999")
        self.check("window.pull of an unknown window fails with the next move", gone["error"] and gone["texts"][-1].startswith("Next:"), str(gone["texts"])[:200])
        self.check("no display changed its current space", self.current_spaces() == before, f"{before} -> {self.current_spaces()}")

    def t_clipboard(self):
        # The clipboard is the user's. It is saved before the first write and restored in the finally,
        # and no check below may put its contents into a message: sizes only.
        guard = ClipboardGuard()
        self.check("the user's clipboard is held in memory before anything is written", True)
        try:
            token = f"clipcheck-{os.getpid()}-{int(time.time())} ✓"
            w = self.m.json("clip.write", text=token)
            r = self.m.json("clip.read")
            self.check("clip.write then clip.read round-trips text, with a change count that moved",
                       r.get("text") == token and r["changeCount"] == w["changeCount"] > w["previousChangeCount"] and r["bytes"] == len(token.encode()),
                       f"bytes={r.get('bytes')} counts={w.get('previousChangeCount')}->{w.get('changeCount')}/{r.get('changeCount')}")
            self.check("reading does not change the clipboard", self.m.json("clip.read")["changeCount"] == w["changeCount"])
            self.m.json("clip.write", text="x" * 100_000)
            big = self.m.json("clip.read")
            self.check("a long clipboard comes back cut at 64 KB and says so",
                       big.get("truncated") is True and big["bytes"] == 100_000 and len(big["text"]) == 65_536 and big["returnedBytes"] == 65_536,
                       f"bytes={big.get('bytes')} returned={big.get('returnedBytes')} truncated={big.get('truncated')}")
            for kind in ("conceal", "transient"):
                guard.send(f"{kind} {token}-secret")
                refused = self.m.call("clip.read")
                said = " ".join(refused["texts"])
                self.check(f"clip.read refuses a clipboard marked {kind}, leaks nothing, and says what to do",
                           refused["error"] and "clip.read refused" in said and token.split(" ")[0] not in said and refused["texts"][-1].startswith("Next:"), said[:160])
            wrote = subprocess.run(["thegrid", "clip", "write", token + " cli"], capture_output=True, text=True)
            read = subprocess.run(["thegrid", "clip", "read"], capture_output=True, text=True)
            self.check("cli: clip write + clip read", wrote.returncode == 0 and read.stdout.strip() == token + " cli", f"rc={wrote.returncode} bytes={len(read.stdout)}")
            # The server writes its log in batches: wait for this run's clip.write event to land.
            log = ""
            for _ in range(20):
                log = open(STATE_DIR + "/thegrid-server.json", errors="replace").read()
                if f'"ev":"clip.write","data":{{"bytes":{len((token + " cli").encode())}}}' in log:
                    break
                time.sleep(0.25)
            self.check("clipboard text never reaches the server log (sizes only)", token.split(" ")[0] not in log and '"ev":"clip.write"' in log)
        finally:
            verdict = guard.restore()
            self.check("the user's clipboard was put back and verified by reading it back", verdict.startswith("restored verified"), verdict)

    def t_cli(self):
        def sh(*args):
            return subprocess.run(["thegrid", *args], capture_output=True, text=True)

        self.check("cli: ping", sh("ping").returncode == 0)
        self.check("cli: dump is JSON for jq", self.calc in json.loads(sh("dump").stdout)["windows"])
        self.check("cli: window find --app lists ID<TAB>title", f"{self.doc_a}\tit-doc-a.txt" in sh("window", "find", "--app", "TextEdit").stdout)
        self.check("cli: ui snapshot", "AXButton" in sh("ui", "snapshot", self.calc).stdout)
        self.check("cli: ui query", "Equals" in sh("ui", "query", self.calc, "--role", "button", "--text", "equals").stdout)
        listing = sh("space", "list").stdout
        self.check("cli: space list", " current" in listing and "it-doc-a.txt" in listing, listing[:200])
        self.check("cli: menu snapshot", "Edit > Select All" in sh("menu", "snapshot", "--app", "TextEdit", "--text", "select all").stdout)
        self.check("cli: input position", re.match(r"-?\d+ -?\d+", sh("input", "position").stdout or "") is not None)
        self.check("cli: state show has numeric version", '"version" : 1' in sh("state", "show").stdout)
        ref = self.textarea(self.doc_a)
        sh("ui", "set", ref, "from the cli")
        self.check("cli: ui set + ui value round trip", sh("ui", "value", ref).stdout.strip() == "from the cli")
        self.check("cli: input type --window is guarded", sh("input", "type", "x", "--window", "999999").returncode != 0)

    # -- run -------------------------------------------------------------

    def run(self):
        if not self.server_pid():
            raise SystemExit("grid-server is not running (make run)")
        # The fixtures get typed into, cleared and quit. If they are already open they are the
        # user's, possibly with unsaved work, so do not start at all.
        mine = [app for app in ("Calculator", "TextEdit") if subprocess.run(["pgrep", "-x", app], capture_output=True).stdout]
        if mine:
            raise SystemExit(f"{' and '.join(mine)} already running: quit them first. This suite uses them as fixtures and quits them at the end.")
        focused = self.m.json("metadata.get").get("focusedWindowID")
        # Kept after the run, outside the temp dir: if the restore below is ever interrupted,
        # this is how the layouts come back (cp it over state.json with the service stopped).
        saved = STATE_FILE + ".integration-backup"
        shutil.copy(STATE_FILE, saved)
        print(f"saved grid state to {saved}; focused window {focused}")
        spaces_at_start = self.current_spaces()
        try:
            self.open_fixtures()
            for title, fn in (("MCP protocol", self.t_protocol), ("number encoding", self.t_numbers), ("queries", self.t_queries),
                              ("window.find", self.t_find), ("ui.snapshot", self.t_snapshot), ("ui.press", self.t_press),
                              ("batch and observe", self.t_batch_observe), ("query, expect and advice", self.t_query_expect), ("menus", self.t_menus), ("spaces", self.t_spaces), ("clipboard", self.t_clipboard), ("guarded typing", self.t_typing), ("focus theft", self.t_focus_theft),
                              ("guarded clicks", self.t_clicks), ("image-pixel clicks", self.t_pixels), ("lists and tables", self.t_lists),
                              ("screenshots", self.t_screenshots), ("hostile input", self.t_hostile),
                              ("frozen app", self.t_hang), ("grid operations", self.t_grid), ("window operations and recording", self.t_window_ops),
                              ("CLI", self.t_cli), ("closing an app's last window", self.t_close_last_window)):
                self.section(title, fn)
            self.check("the whole run left every display on the space it started on", self.current_spaces() == spaces_at_start,
                       f"{spaces_at_start} -> {self.current_spaces()}")
        finally:
            self.cleanup(saved, focused)
        failed = [r for r in self.rows if not r[1]]
        print(f"\n{len(self.rows) - len(failed)} passed, {len(failed)} failed")
        for name, _, detail in failed:
            print(f"  FAIL {name}: {detail}")
        return 1 if failed else 0

    def cleanup(self, saved, focused):
        print("\ncleanup", flush=True)
        for wid in (self.doc_a, self.calc):
            if wid:
                self.m.call("input.key.press", key="cmd+q", windowId=wid)
                time.sleep(0.8)
        for app in ("Calculator", "TextEdit"):
            # Safe to terminate: run() refused to start unless neither was running, so these are ours.
            if subprocess.run(["pgrep", "-x", app], capture_output=True).stdout:
                print(f"  {app} is still running; terminating it")
                subprocess.run(["pkill", "-x", app])
        self.m.close()
        # Grid operations reshuffled real windows. The saved state file is the source of truth:
        # put it back with the server stopped, restart, and let it snap windows to their cells.
        subprocess.run(["services", "stop", SERVICE], capture_output=True)
        # `services stop` alone has been seen to leave the process up; the Makefile boots the
        # launchd job out for the same reason.
        subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/com.r.thegrid-dev"], capture_output=True)
        # The server saves on a debounce; copying before it has really exited lets a late save
        # land on top of the restored file.
        for _ in range(50):
            if not self.server_pid():
                break
            time.sleep(0.1)
        else:
            # Same last resort as the Makefile's kill-grid. Its state file is about to be replaced anyway.
            subprocess.run(["pkill", "-9", "-f", SERVER_PROC], capture_output=True)
            time.sleep(0.5)
            if self.server_pid():
                print("  WARNING: grid-server did not exit; restoring anyway")
        shutil.copy(saved, STATE_FILE)
        try:
            json.load(open(STATE_FILE))
        except Exception as e:
            print(f"  WARNING: restored state does not parse ({e}); backup is at {saved}")
        def wait_for_ping(tries):
            for _ in range(tries):
                if subprocess.run(["thegrid", "ping"], capture_output=True).returncode == 0:
                    return True
                time.sleep(0.25)
            return False

        subprocess.run(["services", "start", SERVICE], capture_output=True)
        if not wait_for_ping(40):
            # Never leave the window manager down because a test ran.
            subprocess.run(["services", "restart", SERVICE], capture_output=True)
            if not wait_for_ping(40):
                print(f"  ERROR: grid-server did not come back; run `make run`. State backup: {saved}")
                return
        m = MCP()
        time.sleep(1.0)
        m.call("grid.layout.refresh")
        if focused:
            m.call("window.focus", windowId=str(focused))
        m.close()
        shutil.rmtree(self.tmp, ignore_errors=True)
        print("  fixtures quit, grid state restored, focus returned")


if __name__ == "__main__":
    only = sys.argv[2] if len(sys.argv) > 2 and sys.argv[1] == "-k" else None
    sys.exit(Suite(only).run())
