# Discovery: iMessage Notifications Phase 2 - iMessage Watcher Script

## Assumption Verification

| Assumption | Result | Evidence |
|-----------|--------|----------|
| chat.db is readable with Full Disk Access | CONFIRMED | `sqlite3 ~/Library/Messages/chat.db "SELECT COUNT(*) FROM message"` returns 84804 |
| attributedBody can be decoded with Python stdlib (plistlib) | PARTIALLY WRONG | attributedBody is a **typedstream** (NSArchiver), NOT an NSKeyedArchiver plist. `plistlib.loads()` fails with "Invalid file". However, the text can be extracted by parsing the typedstream binary format directly with stdlib bytes manipulation. See extraction method below. |
| ROWID is monotonically increasing | CONFIRMED | `SELECT ROWID FROM message ORDER BY ROWID DESC LIMIT 5` returns 85011,85010,85009,85008,85007 — strictly decreasing |
| Shell command can read chat.db while Messages.app is running | CONFIRMED | Queries succeed while Messages is open |

**No UPDATE_PLAN needed** — attributedBody requires a different decode method than plistlib, but stdlib bytes parsing works reliably.

## Current State

### chat.db Schema (relevant tables)

**message** table key columns:
- `ROWID` — auto-increment primary key, monotonically increasing
- `text` — plain text body (NULL on macOS 13+ for many messages, attributedBody used instead)
- `attributedBody` — BLOB, typedstream-encoded NSAttributedString
- `handle_id` — FK to handle.ROWID (the sender/recipient)
- `is_from_me` — 0 = received, 1 = sent
- `date` — nanoseconds since 2001-01-01 (Apple Core Data epoch)
- `item_type` — 0 = normal message (filter out non-zero for reactions/system messages)

**handle** table:
- `ROWID` — PK
- `id` — the identifier string (phone number like "+15551234567" or email)
- `service` — "iMessage", "SMS", "RCS"

**chat_message_join** — maps chat_id to message_id (for group chats)

### attributedBody Extraction

The attributedBody blob is a typedstream (NSArchiver format), starting with `\x04\x0bstreamtyped`.

Text is stored as a length-prefixed UTF-8 C string after a `+` (0x2b) marker byte:
- If byte after `+` is < 0x80: it IS the length directly (1 byte)
- If byte after `+` is >= 0x80: `(byte - 0x80 + 1)` = count of following little-endian length bytes
  - Example: `0x81` -> 2 following bytes -> read 2 bytes LE for length
  - Example: `0x82` -> 3 following bytes -> read 3 bytes LE for length

The longest decoded string from any `+` marker in the blob is the message text.

Verified: short message (10 bytes) and long message (1557 UTF-8 bytes) both decode correctly.

### Date Format

The `date` column stores nanoseconds since 2001-01-01 00:00:00 UTC (Apple Core Data epoch). Convert to Unix timestamp:
```
unix_ts = (date / 1e9) + 978307200
```
Where 978307200 = seconds between Unix epoch (1970-01-01) and Apple epoch (2001-01-01).

### Pipe Format (from Phase 1)

The GridNotify pipe accepts JSON lines. The watcher writes:
```json
{"id": "imsg-+15551234567", "title": "Contact Name", "body": "message text", "ttl": 300, "warn_before": 60}
```

The `id` field triggers upsert behavior (Phase 1): if a notification with the same ID exists, body is updated, TTL is reset, groupCount increments. If not, a new notification is created.

### Filesystem Paths

- **Pipe**: `~/.local/state/thegrid/notify.pipe` (already exists as named FIFO)
- **Config**: `~/.config/thegrid/imessage-watch.yaml` (new, whitelist config)
- **State**: `~/.local/state/thegrid/imessage-last-rowid` (new, persisted ROWID)
- **Log**: `~/.local/state/thegrid/imessage-watcher.json` (new, JSONL log)
- **chat.db**: `~/Library/Messages/chat.db` (system, read-only)

### Python Environment

- System Python: 3.14.3
- All needed stdlib modules available: sqlite3, json, os, time, plistlib (not used), struct, pathlib, sys, signal

### Existing Config Pattern

notify.yaml uses simple `key: value` YAML. The imessage-watch.yaml config is similarly simple — can be parsed with a minimal YAML parser (list items are `- value` lines, scalars are `key: value`).

## Gaps to Fill

1. New script: `grid-notify/scripts/imessage-watch.py`
2. New config file format: `~/.config/thegrid/imessage-watch.yaml`
3. Simple YAML parser (no PyYAML dependency) for config reading
4. attributedBody typedstream decoder for message text extraction
5. SQLite polling loop with ROWID-based deduplication
6. ROWID state persistence across restarts
7. JSONL logger matching project schema
8. Named pipe writer (open, write JSON line, close)
9. `--history` flag for Phase 3 detail window support
10. Contact name resolution (use handle.id as display name since we can't access Contacts.framework from Python)
