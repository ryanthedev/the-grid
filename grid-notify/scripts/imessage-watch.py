#!/usr/bin/env python3
"""iMessage watcher for GridNotify.

Polls ~/Library/Messages/chat.db for new messages from whitelisted contacts
and writes notifications to the GridNotify named pipe.

Usage:
    python3 imessage-watch.py                   # Start polling loop
    python3 imessage-watch.py --history +1...   # Print conversation history as JSON

Requires Full Disk Access for the terminal/process running this script.
Config: ~/.config/thegrid/imessage-watch.yaml
"""

import json
import os
import signal
import sqlite3
import sys
import time


# Seconds between Unix epoch (1970-01-01) and Apple Core Data epoch (2001-01-01)
APPLE_EPOCH_OFFSET = 978307200

CONFIG_PATH = os.path.expanduser("~/.config/thegrid/imessage-watch.yaml")
ROWID_PATH = os.path.expanduser("~/.local/state/thegrid/imessage-last-rowid")
LOG_PATH = os.path.expanduser("~/.local/state/thegrid/imessage-watcher.json")
CHAT_DB_PATH = os.path.expanduser("~/Library/Messages/chat.db")

DEFAULTS = {
    "contacts": [],
    "pipe_path": "~/.local/state/thegrid/notify.pipe",
    "poll_interval": 2,
    "ttl": 300,
    "warn_before": 60,
}


# ---------------------------------------------------------------------------
# JSONL Logger (Section 6)
# ---------------------------------------------------------------------------

def log(ev, msg=None, data=None):
    """Append a JSONL log entry matching the project schema."""
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
        # Last resort if log file is unwritable
        print(f"log write failed: {line}", file=sys.stderr)


# ---------------------------------------------------------------------------
# Minimal YAML Parser (Section 1)
# ---------------------------------------------------------------------------

def _try_numeric(s):
    """Convert string to int or float if possible, else return as-is."""
    try:
        return int(s)
    except ValueError:
        pass
    try:
        return float(s)
    except ValueError:
        pass
    return s


def parse_yaml(path):
    """Parse a simple YAML file (scalars and lists only, no nesting)."""
    result = {}
    current_key = None

    with open(path, "r") as f:
        for raw_line in f:
            stripped = raw_line.strip()

            if stripped == "" or stripped.startswith("#"):
                continue

            # List item under current key
            if stripped.startswith("- "):
                value = stripped[2:].strip()
                # Strip surrounding quotes if present
                if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
                    value = value[1:-1]
                if current_key is not None and isinstance(result.get(current_key), list):
                    result[current_key].append(value)
                continue

            # Key: value pair
            if ":" in stripped:
                key, _, value = stripped.partition(":")
                key = key.strip()
                value = value.strip()

                if value == "":
                    # Key with no inline value starts a list
                    result[key] = []
                    current_key = key
                else:
                    # Strip surrounding quotes
                    if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
                        value = value[1:-1]
                    result[key] = _try_numeric(value)
                    current_key = key

    return result


# ---------------------------------------------------------------------------
# Config Loading (Section 2)
# ---------------------------------------------------------------------------

def load_config():
    """Load and merge config from YAML file over defaults."""
    config = dict(DEFAULTS)

    if not os.path.exists(CONFIG_PATH):
        log("imsg.config.missing", msg="no config file, using defaults")
        return config

    try:
        parsed = parse_yaml(CONFIG_PATH)
    except Exception as e:
        log("imsg.config.err", msg=f"failed to parse config: {e}")
        return config

    for key in parsed:
        config[key] = parsed[key]

    # Expand ~ in pipe_path
    config["pipe_path"] = os.path.expanduser(config["pipe_path"])

    if not config["contacts"]:
        log("imsg.config.warn", msg="no contacts in whitelist")

    log("imsg.config.loaded", data={
        "contacts_count": len(config["contacts"]),
        "poll_interval": config["poll_interval"],
        "ttl": config["ttl"],
    })

    return config


# ---------------------------------------------------------------------------
# ROWID State Persistence (Section 3)
# ---------------------------------------------------------------------------

def load_last_rowid():
    """Load the last processed ROWID from state file."""
    if not os.path.exists(ROWID_PATH):
        return 0

    try:
        with open(ROWID_PATH, "r") as f:
            content = f.read().strip()
        return int(content)
    except (ValueError, OSError):
        log("imsg.rowid.err", msg="corrupt rowid file, starting from 0")
        return 0


def save_last_rowid(rowid):
    """Persist the last processed ROWID atomically."""
    tmp_path = ROWID_PATH + ".tmp"
    with open(tmp_path, "w") as f:
        f.write(str(rowid))
    os.replace(tmp_path, ROWID_PATH)


# ---------------------------------------------------------------------------
# attributedBody Decoder (Section 4)
# ---------------------------------------------------------------------------

def decode_attributed_body(blob):
    """Extract plain text from an NSAttributedString typedstream blob.

    The blob is a typedstream (NSArchiver format), not NSKeyedArchiver.
    Text is stored as a length-prefixed UTF-8 string after a 0x2b ('+') marker.

    Length encoding after the marker byte:
      - byte < 0x80: length = byte directly
      - byte >= 0x80: (byte - 0x80 + 1) following bytes encode the length (LE)

    Returns the longest valid UTF-8 string found, which is the message body.
    """
    if blob is None:
        return None

    best = None
    i = 0
    blob_len = len(blob)

    while i < blob_len - 1:
        if blob[i] != 0x2B:
            i += 1
            continue

        # Skip the '+' marker
        i += 1
        first = blob[i]
        i += 1

        if first >= 0x80:
            # Multi-byte length encoding
            num_length_bytes = (first - 0x80) + 1
            if i + num_length_bytes > blob_len:
                continue
            length = int.from_bytes(blob[i:i + num_length_bytes], "little")
            i += num_length_bytes
        else:
            length = first

        if length <= 0 or i + length > blob_len:
            continue

        try:
            candidate = blob[i:i + length].decode("utf-8")
            if best is None or len(candidate) > len(best):
                best = candidate
        except UnicodeDecodeError:
            pass

        i += length

    return best


def get_message_text(text_col, attributed_body_col):
    """Get message text, preferring the text column over attributedBody."""
    if text_col is not None:
        return text_col
    return decode_attributed_body(attributed_body_col)


# ---------------------------------------------------------------------------
# Database Connection (Section 8)
# ---------------------------------------------------------------------------

def connect_db():
    """Connect to chat.db in read-only mode."""
    uri = f"file:{CHAT_DB_PATH}?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    return conn


# ---------------------------------------------------------------------------
# SQLite Polling (Section 4)
# ---------------------------------------------------------------------------

def poll_new_messages(db, last_rowid, whitelist):
    """Query chat.db for new messages from whitelisted contacts.

    Only returns incoming messages (is_from_me=0) of normal type (item_type=0)
    with ROWID greater than last_rowid.
    """
    if not whitelist:
        return []

    placeholders = ",".join("?" for _ in whitelist)
    query = f"""
        SELECT m.ROWID, m.text, m.attributedBody, h.id, m.date
        FROM message m
        JOIN handle h ON m.handle_id = h.ROWID
        WHERE m.ROWID > ?
          AND m.is_from_me = 0
          AND m.item_type = 0
          AND h.id IN ({placeholders})
        ORDER BY m.ROWID ASC
    """

    params = [last_rowid] + list(whitelist)
    cursor = db.execute(query, params)
    results = []

    for rowid, text, ab, handle_id, date in cursor:
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


# ---------------------------------------------------------------------------
# Notification Formatting + Pipe Writer (Section 5)
# ---------------------------------------------------------------------------

def format_notification(msg, config):
    """Build a JSON notification payload for the GridNotify pipe."""
    handle = msg["handle_id"]
    # Absolute path to this script for detail_cmd
    script_path = os.path.abspath(__file__)
    notification = {
        "id": f"imsg-{handle}",
        "title": handle,
        "body": msg["body"],
        "ttl": config["ttl"],
        "warn_before": config["warn_before"],
        "detail_cmd": f"python3 {script_path} --history {handle}",
    }
    return json.dumps(notification, ensure_ascii=False)


def write_to_pipe(pipe_path, json_line):
    """Write a single JSON line to the named pipe."""
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


# ---------------------------------------------------------------------------
# Conversation History (Section 7)
# ---------------------------------------------------------------------------

def fetch_history(handle_id, limit=10):
    """Fetch the last N messages for a given handle (both directions)."""
    db = connect_db()
    cursor = db.execute(
        """
        SELECT m.ROWID, m.text, m.attributedBody, m.is_from_me, m.date
        FROM message m
        JOIN handle h ON m.handle_id = h.ROWID
        WHERE h.id = ?
          AND m.item_type = 0
        ORDER BY m.ROWID DESC
        LIMIT ?
        """,
        (handle_id, limit),
    )

    messages = []
    for rowid, text, ab, is_from_me, date in cursor:
        body = get_message_text(text, ab)
        if body is None:
            body = ""

        # Convert Apple nanosecond timestamp to Unix timestamp
        unix_ts = int(date / 1e9) + APPLE_EPOCH_OFFSET

        messages.append({
            "body": body,
            "is_from_me": bool(is_from_me),
            "timestamp": unix_ts,
        })

    db.close()

    # Reverse to chronological order (query was DESC for LIMIT)
    messages.reverse()
    return messages


def handle_history_flag(args):
    """Process --history <handle_id> [--limit N] and exit."""
    if not args:
        print("Usage: imessage-watch.py --history <handle_id> [--limit N]", file=sys.stderr)
        sys.exit(1)

    handle_id = args[0]
    limit = 10

    if "--limit" in args:
        idx = args.index("--limit")
        if idx + 1 < len(args):
            try:
                limit = int(args[idx + 1])
            except ValueError:
                pass

    history = fetch_history(handle_id, limit)
    print(json.dumps(history, ensure_ascii=False))
    sys.exit(0)


# ---------------------------------------------------------------------------
# Main Loop (Section 8)
# ---------------------------------------------------------------------------

def main():
    args = sys.argv[1:]

    # Handle --history flag (exits after printing)
    if "--history" in args:
        idx = args.index("--history")
        handle_history_flag(args[idx + 1:])

    # Load config
    config = load_config()
    if not config["contacts"]:
        log("imsg.exit", msg="no contacts configured, nothing to watch")
        print(
            "No contacts configured in ~/.config/thegrid/imessage-watch.yaml",
            file=sys.stderr,
        )
        sys.exit(1)

    # Load persisted ROWID
    last_rowid = load_last_rowid()
    log("imsg.start", data={
        "last_rowid": last_rowid,
        "contacts": len(config["contacts"]),
        "poll_interval": config["poll_interval"],
    })

    # Graceful shutdown on SIGINT/SIGTERM
    running = [True]

    def on_signal(sig, frame):
        running[0] = False

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    # Main polling loop
    db = None
    while running[0]:
        try:
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

                # Update ROWID after each successful write
                last_rowid = msg["rowid"]
                save_last_rowid(last_rowid)

        except sqlite3.DatabaseError as e:
            # DB locked or corrupted -- close and retry next cycle
            log("imsg.db.err", msg=str(e))
            if db is not None:
                try:
                    db.close()
                except Exception:
                    pass
                db = None

        except Exception as e:
            log("imsg.err", msg=str(e))

        # Sleep for the poll interval
        try:
            time.sleep(config["poll_interval"])
        except (KeyboardInterrupt, SystemExit):
            break

    # Cleanup
    if db is not None:
        try:
            db.close()
        except Exception:
            pass
    log("imsg.stop")


if __name__ == "__main__":
    main()
