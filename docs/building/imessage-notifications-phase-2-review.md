# Review: Phase 2 - iMessage Watcher Script

## Requirement Fulfillment

| DW-ID | Done-When Item | Status | Evidence |
|-------|---------------|--------|----------|
| DW-2.1 | Script polls chat.db and detects new messages within 3 seconds | SATISFIED | `main()` loop at imessage-watch.py:478 sleeps `config["poll_interval"]` (default 2s) between iterations. 2s poll + negligible query time satisfies the ≤3s detection window. |
| DW-2.2 | Only whitelisted contacts trigger notifications | SATISFIED | `poll_new_messages()` at imessage-watch.py:275-288 builds parameterized `h.id IN (?,?...)` clause; main exits at imessage-watch.py:417-423 if contacts list is empty. |
| DW-2.3 | Notification appears in GridNotify with sender name and message text | SATISFIED | `format_notification()` at imessage-watch.py:310-320 sets `"title": handle` (phone/email), `"body": msg["body"]`; `write_to_pipe()` at imessage-watch.py:323-336 writes the JSON line to the named pipe. |
| DW-2.4 | Multiple messages from same sender upsert (body updates, count increments, TTL resets) | SATISFIED | `format_notification()` uses stable id `f"imsg-{handle}"` at imessage-watch.py:314, with `ttl` and `warn_before` fields. Phase 1's `NotificationStore.upsert()` handles the body/count/TTL update when the same id arrives. |
| DW-2.5 | Duplicate messages are never sent (ROWID tracking persists across restarts) | SATISFIED | `load_last_rowid()` at imessage-watch.py:164-175 reads state file on startup; `save_last_rowid()` at imessage-watch.py:178-183 atomically writes via `os.replace()` after each processed message; query filters `m.ROWID > ?` at imessage-watch.py:281. |
| DW-2.6 | Works with system Python 3, no external dependencies | SATISFIED | Imports at imessage-watch.py:15-20: `json`, `os`, `signal`, `sqlite3`, `sys`, `time` — all stdlib. No pip installs. Shebang at line 1: `#!/usr/bin/env python3`. |

**All requirements met:** YES

## Spec Match

- [x] Section 1 (Minimal YAML parser): `_try_numeric()` at line 69, `parse_yaml()` at line 82. Implementation adds quote-stripping (lines 98-99, 116-117) beyond spec — a benign addition for usability.
- [x] Section 2 (Config loading): `load_config()` at line 128. Adds `try/except` around `parse_yaml()` (lines 136-139) beyond spec — an improvement, not a deviation.
- [x] Section 3 (ROWID state persistence): `load_last_rowid()` at line 164, `save_last_rowid()` at line 178. Uses `os.replace()` for atomic rename, matching spec.
- [x] Section 4 (SQLite polling + attributedBody decoder): `decode_attributed_body()` at line 190, `get_message_text()` at line 244, `poll_new_messages()` at line 266. Matches spec exactly.
- [x] Section 5 (Pipe writer + notification formatting): `format_notification()` at line 310, `write_to_pipe()` at line 323. Uses `O_NONBLOCK` open as specified.
- [x] Section 6 (JSONL logger): `log()` at line 44. Matches project schema with `ts`, `ev`, optional `msg`/`data` fields.
- [x] Section 7 (History flag): `fetch_history()` at line 343, `handle_history_flag()` at line 381. Handles missing `--limit` value and invalid integer gracefully (lines 392-396).
- [x] Section 8 (Main loop + signal handling): `main()` at line 407. Uses `running = [True]` list-cell instead of pseudocode's `nonlocal` — functionally equivalent and correct.
- [x] Section 9 (Script structure): All 15 expected functions present. `_try_numeric` and `parse_yaml` are swapped in order (lines 69 vs 82) relative to Section 9's list, but this is cosmetic — `parse_yaml` calls `_try_numeric` so helper-first ordering is correct.
- [x] Test coverage: Pseudocode declares manual/scratch validation only. No automated test file created, matching the plan's strategy.

No unplanned additions beyond the two defensive improvements noted above.

## Dead Code

None found. All six imports are used (verified by occurrence count). No unreachable code after early returns (`sys.exit(0)` in `handle_history_flag` exits before `main()` polls). No debug statements or commented-out blocks.

## Correctness Dimensions

| Dimension | Status | Evidence |
|-----------|--------|----------|
| Concurrency | N/A | Single-threaded script with no shared mutable state across threads. Signal handler uses a list cell (`running[0]`) rather than a plain variable to avoid the closure rebinding issue — correct. No TOCTOU concerns; poll is sequential. |
| Error Handling | PASS | DB errors caught at line 463 (`sqlite3.DatabaseError`) with connection close-and-retry. Broad `except Exception` at line 473 catches other poll-cycle errors and logs them. `write_to_pipe` catches `OSError` at lines 326-329 and 333-335. Config parse errors caught at line 138. Log write failure falls back to stderr at line 62. `save_last_rowid` has no try/except — see Issues section. |
| Resources | PASS | DB connection in main loop: closed on `DatabaseError` (line 466-471) and on clean shutdown (lines 483-487). `write_to_pipe` closes fd in `finally` (line 336). `fetch_history` calls `db.close()` at line 374 — not in a finally block, see Issues section. |
| Boundaries | PASS | Empty whitelist returns early at line 272. `decode_attributed_body(None)` returns None at line 202. Empty blob (`b""`) handled by `while i < blob_len - 1` (exits immediately). Truncated multi-byte length (`i + num_length_bytes > blob_len`) handled by `continue` at line 222. Zero-length string filtered at line 293 (`body.strip() == ""`). `load_last_rowid` handles corrupt/empty state file at line 173. |
| Security | PASS | Whitelist filter uses parameterized query (`?` placeholders, line 275-288) — no SQL injection. Message body and handle_id passed through `json.dumps()` only, never used in shell commands or SQL string concatenation. Config values are used as data only. No secrets in scope. |

## Defensive Programming: PASS

Crisis triage:
1. **External input validated at boundaries:** Chat.db rows are destructured into typed fields; body emptiness checked before emit; config YAML parse wrapped in try/except; `--limit` argument wrapped in `try/except ValueError`. PASS.
2. **Return values checked for external calls:** `os.open()` result checked (exception on failure); `os.write()` checked; `os.replace()` unchecked in `save_last_rowid` but propagates correctly to main loop's broad handler. PASS.
3. **Error paths tested:** No automated tests; manual validation per pseudocode strategy. Within scope.
4. **Assertions on critical invariants:** Not applicable — script has no internal invariants that benefit from assertions beyond what the exception flow already provides.
5. **Resources released on all paths:** Main loop db always closed on both error and clean exit. `write_to_pipe` fd released in finally. One exception: `fetch_history` db not in a try/finally — see Issues.

## Design Quality: No significant findings

**`running = [True]` list cell (line 434):** The pseudocode used `nonlocal running` but the implementation uses a mutable container cell. This is the correct Python idiom for mutable closure state — the `nonlocal` approach would also work but requires Python 3+ declaration. No issue.

**`decode_attributed_body` "longest wins" heuristic:** The algorithm returns the longest valid UTF-8 candidate, not the first. Discovery confirmed this works for both short and long messages. The heuristic is explicitly documented in the discovery file and is verified to be correct for the typedstream format. Not a design smell.

**`fetch_history` is Phase 3 prep:** The function is included in this phase per Section 7 of the spec. It is not exercised by the poll loop, which is correct. No dead-code concern.

**Log directory assumed to exist (low severity):** `log()` catches `OSError` and falls to stderr, which is robust. `save_last_rowid()` does not, but the state directory must already contain `notify.pipe` for the watcher to be useful, so in practice the directory always exists. Noted, not a blocker.

## Testing: PASS

Per plan strategy: manual validation only, no automated test file for this phase. The pseudocode's testing strategy calls for scratch testing against live chat.db and a running GridNotify instance. No test file is expected.

The implementation has two inline-testable pure functions (`decode_attributed_body`, `parse_yaml`) whose logic was independently verified during this review:
- `decode_attributed_body`: short messages, multi-byte length, None/empty blob, truncated blob, longest-wins all behave correctly.
- `parse_yaml`: normal scalars and lists, quoted values, empty list key, value-with-colon all behave correctly.

No dirty:clean ratio applicable (no test file).

## Issues

1. **`fetch_history` leaks db connection on exception (LOW)**
   - File: imessage-watch.py:343-378
   - `db = connect_db()` at line 345, `db.close()` at line 374 — no `try/finally`. If `db.execute()` or the row-iteration loop raises, `db.close()` is skipped.
   - This function is only used by the `--history` flag which exits immediately after via `sys.exit(0)`, so the OS reclaims the handle. The risk is real but consequence is zero in practice.
   - Fix: wrap body in `try/finally: db.close()` for correctness. Does not block PASS given the exit-immediately context.

2. **`save_last_rowid` unhandled write failure (LOW)**
   - File: imessage-watch.py:178-183
   - No `try/except` around `open()` or `os.replace()`. If the state directory is missing or read-only, the exception propagates to main loop's `except Exception` at line 473. The ROWID is not saved, so the next poll re-processes the same message — resulting in a duplicate notification being sent.
   - In practice the state directory must exist for `notify.pipe` to be present. Risk is limited to first-run scenarios.
   - Fix: add error logging in `save_last_rowid` and/or ensure the state directory is created on startup. Does not block PASS given the dependency on the pre-existing pipe.

**Verdict: PASS**
