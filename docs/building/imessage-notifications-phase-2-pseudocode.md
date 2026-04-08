# Pseudocode: iMessage Notifications Phase 2 - iMessage Watcher Script

## DW Coverage
- DW-2.1: Sections 3, 4 (SQLite polling loop with 2s interval, ROWID tracking)
- DW-2.2: Sections 2, 4 (whitelist config loading, filter in poll query)
- DW-2.3: Sections 4, 5, 6 (message text extraction, title from handle, pipe write)
- DW-2.4: Sections 5 (stable id "imsg-<handle_id>" for upsert, ttl/warn_before fields)
- DW-2.5: Sections 3, 4 (ROWID persistence to file, only query ROWID > last_seen)
- DW-2.6: All sections (stdlib only, no pip dependencies)

---

## Section 1: Minimal YAML Parser
**File:** grid-notify/scripts/imessage-watch.py (module-level function)
**DW:** 2.2, 2.6

Parse a simple YAML file supporting only the subset we need:
- Scalar values: `key: value`
- List items: `  - value` (under a key)
- Comments: lines starting with `#`
- Empty lines ignored

```
function parse_yaml(path: str) -> dict:
    result = {}
    current_key = None

    for line in read_lines(path):
        stripped = line.strip()
        if stripped == "" or stripped.startswith("#"):
            continue

        if stripped.startswith("- "):
            // List item under current_key
            value = stripped[2:].strip()
            if current_key and isinstance(result[current_key], list):
                result[current_key].append(value)
            continue

        if ":" in stripped:
            key, _, value = stripped.partition(":")
            key = key.strip()
            value = value.strip()
            if value == "":
                // Key with no inline value -> start a list
                result[key] = []
                current_key = key
            else:
                // Scalar value
                // Try numeric conversion
                result[key] = try_numeric(value)
                current_key = key

    return result

function try_numeric(s: str):
    try int(s), else try float(s), else return s
```

---

## Section 2: Config Loading
**File:** grid-notify/scripts/imessage-watch.py (module-level function)
**DW:** 2.2

```
CONFIG_PATH = ~/.config/thegrid/imessage-watch.yaml

DEFAULTS = {
    "contacts": [],
    "pipe_path": "~/.local/state/thegrid/notify.pipe",
    "poll_interval": 2,
    "ttl": 300,
    "warn_before": 60,
}

function load_config() -> dict:
    config = copy(DEFAULTS)

    if not exists(CONFIG_PATH):
        log("imsg.config.missing", msg="no config file, using defaults")
        return config

    parsed = parse_yaml(CONFIG_PATH)
    // Merge parsed over defaults
    for key in parsed:
        config[key] = parsed[key]

    // Expand ~ in pipe_path
    config["pipe_path"] = expanduser(config["pipe_path"])

    // Validate contacts is a non-empty list
    if not config["contacts"]:
        log("imsg.config.warn", msg="no contacts in whitelist")

    log("imsg.config.loaded", data={
        "contacts_count": len(config["contacts"]),
        "poll_interval": config["poll_interval"],
        "ttl": config["ttl"]
    })

    return config
```

---

## Section 3: ROWID State Persistence
**File:** grid-notify/scripts/imessage-watch.py (module-level functions)
**DW:** 2.5

```
ROWID_PATH = ~/.local/state/thegrid/imessage-last-rowid

function load_last_rowid() -> int:
    if not exists(ROWID_PATH):
        return 0
    try:
        content = read_file(ROWID_PATH).strip()
        return int(content)
    except:
        log("imsg.rowid.err", msg="corrupt rowid file, starting from 0")
        return 0

function save_last_rowid(rowid: int):
    // Write to temp file then rename for atomicity
    tmp_path = ROWID_PATH + ".tmp"
    write_file(tmp_path, str(rowid))
    rename(tmp_path, ROWID_PATH)
```

---

## Section 4: SQLite Polling + Message Extraction
**File:** grid-notify/scripts/imessage-watch.py
**DW:** 2.1, 2.2, 2.3, 2.5

### attributedBody Decoder

```
function decode_attributed_body(blob: bytes) -> str or None:
    // The blob is a typedstream (NSArchiver format).
    // Text is stored as a length-prefixed UTF-8 string after a '+' (0x2b) marker.
    //
    // Length encoding after 0x2b:
    //   byte < 0x80: length = byte (direct, 1 byte)
    //   byte >= 0x80: (byte - 0x80 + 1) following bytes encode length in LE
    //
    // We scan for all '+' markers and return the longest valid UTF-8 string.

    if blob is None:
        return None

    best = None
    i = 0
    while i < len(blob) - 1:
        if blob[i] != 0x2b:
            i += 1
            continue

        i += 1  // skip the '+' marker
        first = blob[i]
        i += 1

        if first >= 0x80:
            // Multi-byte length
            num_length_bytes = (first - 0x80) + 1
            if i + num_length_bytes > len(blob):
                continue
            length = int.from_bytes(blob[i:i+num_length_bytes], "little")
            i += num_length_bytes
        else:
            length = first

        if length <= 0 or i + length > len(blob):
            continue

        try:
            candidate = blob[i:i+length].decode("utf-8")
            if best is None or len(candidate) > len(best):
                best = candidate
        except UnicodeDecodeError:
            pass

        i += length

    return best
```

### Message Text Extraction

```
function get_message_text(text_col, attributed_body_col) -> str or None:
    // Prefer text column when non-NULL
    if text_col is not None:
        return text_col

    // Fall back to attributedBody decode
    return decode_attributed_body(attributed_body_col)
```

### Poll Query

```
CHAT_DB = ~/Library/Messages/chat.db

function poll_new_messages(db_conn, last_rowid: int, whitelist: list[str]) -> list[dict]:
    // Query for new messages from whitelisted contacts.
    // Only incoming messages (is_from_me=0), normal type (item_type=0).
    // ROWID > last_rowid for deduplication.
    //
    // We join handle to get the contact identifier for whitelist filtering.
    // We use placeholder binding for the whitelist to avoid SQL injection.

    if not whitelist:
        return []

    placeholders = ",".join("?" for _ in whitelist)
    query = f"""
        SELECT m.ROWID, m.text, m.attributedBody, h.id as handle_id, m.date
        FROM message m
        JOIN handle h ON m.handle_id = h.ROWID
        WHERE m.ROWID > ?
          AND m.is_from_me = 0
          AND m.item_type = 0
          AND h.id IN ({placeholders})
        ORDER BY m.ROWID ASC
    """

    params = [last_rowid] + whitelist
    cursor = db_conn.execute(query, params)
    results = []

    for row in cursor:
        rowid, text, ab, handle_id, date = row
        body = get_message_text(text, ab)
        if body is None or body.strip() == "":
            continue

        results.append({
            "rowid": rowid,
            "handle_id": handle_id,
            "body": body,
            "date": date,
        })

    return results
```

---

## Section 5: Pipe Writer + Notification Formatting
**File:** grid-notify/scripts/imessage-watch.py
**DW:** 2.3, 2.4

```
function format_notification(msg: dict, config: dict) -> str:
    // Build the JSON notification payload for the GridNotify pipe.
    // Uses stable id "imsg-<handle_id>" for upsert grouping.
    // Title is the handle_id (phone number or email).
    // Body is the message text.

    handle = msg["handle_id"]
    notification = {
        "id": f"imsg-{handle}",
        "title": handle,
        "body": msg["body"],
        "ttl": config["ttl"],
        "warn_before": config["warn_before"],
    }
    return json.dumps(notification, ensure_ascii=False)

function write_to_pipe(pipe_path: str, json_line: str):
    // Open pipe, write one line, close.
    // Open in write mode (non-blocking would hang if no reader).
    // Use a timeout approach: open blocking but catch errors.

    try:
        fd = os.open(pipe_path, os.O_WRONLY | os.O_NONBLOCK)
    except OSError as e:
        log("imsg.pipe.err", msg="cannot open pipe", data={"err": str(e)})
        return

    try:
        os.write(fd, (json_line + "\n").encode("utf-8"))
    except OSError as e:
        log("imsg.pipe.write.err", msg="pipe write failed", data={"err": str(e)})
    finally:
        os.close(fd)
```

---

## Section 6: JSONL Logger
**File:** grid-notify/scripts/imessage-watch.py (module-level)
**DW:** 2.6

```
LOG_PATH = ~/.local/state/thegrid/imessage-watcher.json

function log(ev: str, msg: str = None, data: dict = None):
    entry = {
        "ts": int(time.time()),
        "ev": ev,
    }
    if msg is not None:
        entry["msg"] = msg
    if data is not None:
        entry["data"] = data

    line = json.dumps(entry, ensure_ascii=False)

    try:
        with open(LOG_PATH, "a") as f:
            f.write(line + "\n")
    except OSError:
        // Can't log the logging failure; write to stderr as last resort
        print(f"log write failed: {line}", file=sys.stderr)
```

---

## Section 7: History Flag (for Phase 3)
**File:** grid-notify/scripts/imessage-watch.py
**DW:** (Phase 3 prep, not scored in Phase 2 DW items)

```
APPLE_EPOCH_OFFSET = 978307200  // seconds between Unix epoch and 2001-01-01

function fetch_history(handle_id: str, limit: int = 10) -> list[dict]:
    // Query last N messages (both directions) for a given handle.
    // Returns JSON-serializable list with sender direction and timestamps.

    db = connect_db()
    cursor = db.execute("""
        SELECT m.ROWID, m.text, m.attributedBody, m.is_from_me, m.date
        FROM message m
        JOIN handle h ON m.handle_id = h.ROWID
        WHERE h.id = ?
          AND m.item_type = 0
        ORDER BY m.ROWID DESC
        LIMIT ?
    """, (handle_id, limit))

    messages = []
    for row in cursor:
        rowid, text, ab, is_from_me, date = row
        body = get_message_text(text, ab)
        if body is None:
            body = ""

        // Convert Apple date (nanoseconds since 2001-01-01) to Unix timestamp
        unix_ts = int(date / 1e9) + APPLE_EPOCH_OFFSET

        messages.append({
            "body": body,
            "is_from_me": bool(is_from_me),
            "timestamp": unix_ts,
        })

    db.close()

    // Reverse to chronological order (query was DESC)
    messages.reverse()
    return messages

function handle_history_flag(args):
    // --history <handle_id> [--limit N]
    handle_id = args[0]
    limit = 10
    if "--limit" in args:
        idx = args.index("--limit")
        if idx + 1 < len(args):
            limit = int(args[idx + 1])

    history = fetch_history(handle_id, limit)
    print(json.dumps(history, ensure_ascii=False))
    sys.exit(0)
```

---

## Section 8: Main Loop + Signal Handling
**File:** grid-notify/scripts/imessage-watch.py
**DW:** 2.1, 2.5

```
function connect_db() -> sqlite3.Connection:
    // Connect to chat.db in read-only mode with WAL journal
    db_path = expanduser("~/Library/Messages/chat.db")
    uri = f"file:{db_path}?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    return conn

function main():
    // Parse args
    args = sys.argv[1:]

    if "--history" in args:
        idx = args.index("--history")
        handle_history_flag(args[idx+1:])
        // exits

    // Load config
    config = load_config()
    if not config["contacts"]:
        log("imsg.exit", msg="no contacts configured, nothing to watch")
        print("No contacts configured in ~/.config/thegrid/imessage-watch.yaml", file=sys.stderr)
        sys.exit(1)

    // Load persisted ROWID
    last_rowid = load_last_rowid()
    log("imsg.start", data={
        "last_rowid": last_rowid,
        "contacts": len(config["contacts"]),
        "poll_interval": config["poll_interval"],
    })

    // Set up signal handler for graceful shutdown
    running = True
    def on_signal(sig, frame):
        nonlocal running
        running = False
    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    // Main polling loop
    db = None
    while running:
        try:
            // Open/reopen db connection if needed
            if db is None:
                db = connect_db()

            messages = poll_new_messages(db, last_rowid, config["contacts"])

            for msg in messages:
                json_line = format_notification(msg, config)
                write_to_pipe(config["pipe_path"], json_line)
                log("imsg.notify", data={
                    "handle": msg["handle_id"],
                    "rowid": msg["rowid"],
                })

                // Update last_rowid after each successful notification
                last_rowid = msg["rowid"]
                save_last_rowid(last_rowid)

        except sqlite3.DatabaseError as e:
            // DB locked or corrupted — close and retry next cycle
            log("imsg.db.err", msg=str(e))
            if db:
                try:
                    db.close()
                except:
                    pass
                db = None

        except Exception as e:
            log("imsg.err", msg=str(e))

        // Sleep for poll interval (interruptible by signal)
        try:
            time.sleep(config["poll_interval"])
        except (KeyboardInterrupt, SystemExit):
            break

    // Cleanup
    if db:
        db.close()
    log("imsg.stop")

if __name__ == "__main__":
    main()
```

---

## Section 9: Script Structure (file layout)
**File:** grid-notify/scripts/imessage-watch.py

```
#!/usr/bin/env python3
"""iMessage watcher for GridNotify.

Polls ~/Library/Messages/chat.db for new messages from whitelisted contacts
and writes notifications to the GridNotify named pipe.

Usage:
    python3 imessage-watch.py                 # Start polling loop
    python3 imessage-watch.py --history +1... # Print conversation history as JSON

Requires Full Disk Access for the terminal/process running this script.
Config: ~/.config/thegrid/imessage-watch.yaml
"""

// Imports: sys, os, time, json, sqlite3, signal, pathlib (all stdlib)

// Constants
APPLE_EPOCH_OFFSET = 978307200
CONFIG_PATH = expanduser("~/.config/thegrid/imessage-watch.yaml")
ROWID_PATH = expanduser("~/.local/state/thegrid/imessage-last-rowid")
LOG_PATH = expanduser("~/.local/state/thegrid/imessage-watcher.json")
CHAT_DB_PATH = expanduser("~/Library/Messages/chat.db")
DEFAULTS = { ... }

// Functions in order:
// 1. log()               -- Section 6
// 2. parse_yaml()        -- Section 1
// 3. try_numeric()       -- Section 1
// 4. load_config()       -- Section 2
// 5. load_last_rowid()   -- Section 3
// 6. save_last_rowid()   -- Section 3
// 7. decode_attributed_body() -- Section 4
// 8. get_message_text()  -- Section 4
// 9. connect_db()        -- Section 8
// 10. poll_new_messages() -- Section 4
// 11. format_notification() -- Section 5
// 12. write_to_pipe()    -- Section 5
// 13. fetch_history()    -- Section 7
// 14. handle_history_flag() -- Section 7
// 15. main()             -- Section 8

if __name__ == "__main__":
    main()
```

---

## Testing Strategy

Since this is a Python script with no test framework, validation is manual + a scratch test:
1. Run the script manually with a test config
2. Send an iMessage from a whitelisted contact
3. Verify notification appears in GridNotify within 3 seconds
4. Send multiple messages, verify upsert behavior
5. Kill and restart script, verify no duplicate notifications
6. Test `--history` flag outputs valid JSON

For automated validation during development, we can:
- Test `decode_attributed_body()` against known blobs from scratch.sh
- Test `parse_yaml()` with inline test data
- Test `format_notification()` produces valid JSON with correct id format
