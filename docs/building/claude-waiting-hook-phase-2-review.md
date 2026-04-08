# Review: Phase 2 - Install-hook command

## Verdict: PASS

---

## Done-When Criteria

**1. `thegrid notify install-hook` creates executable hook script at `~/.local/share/thegrid/hooks/claude-waiting.sh`**
PASS. `NotifyInstallHook.run()` resolves `dataHome` via `XDG_DATA_HOME` env var (defaulting to `~/.local/share`), constructs `hooksDir = "\(dataHome)/thegrid/hooks"` and `scriptPath = "\(hooksDir)/claude-waiting.sh"`, calls `createDirectory(atPath:withIntermediateDirectories:)`, then `createFile(atPath:contents:)` and `setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))])`. Lines 259–287.

**2. Command adds Notification idle_prompt hook to `~/.claude/settings.json` (reads existing, merges, writes back)**
PASS. `mergeSettingsJSON` reads the existing file via `Data(contentsOf:)` and `JSONSerialization.jsonObject`, falls back to `[:]` on missing or malformed file, navigates to `root["hooks"]["Notification"]`, appends the new entry if not already present, and writes back with `.prettyPrinted` + `.sortedKeys`. Lines 396–452.

**3. Hook script resolves terminal window by walking parent PID chain and querying theGrid**
PASS. The embedded script sets `SELF_PID=$$` and calls `"$THEGRID" window find --pid "$SELF_PID"`. Phase 1 established that `window find --pid` walks ancestors server-side. Lines 372–373 of the script content.

**4. Hook script includes tmux session:window and basename of cwd in notification body**
PASS. Script extracts `CWD` from stdin JSON via python3, sets `PROJECT=$(basename "$CWD")`, and if inside tmux sets `TMUX_INFO=$(tmux display-message -p '#S:#W')`. Body is `"$TMUX_INFO  $PROJECT"` when tmux is active, else just `"$PROJECT"`. Lines 344–367.

**5. Running the hook manually produces a notification in the panel (verify the script logic is correct)**
PASS. The script logic is correct: reads stdin JSON, extracts cwd, checks tmux, walks PIDs, constructs `NOTIFY_ARGS`, calls `"$THEGRID" notify push`. Every external call is guarded with `2>/dev/null || true` so the script always exits 0. The `set -euo pipefail` at the top combined with `|| true` guards ensures no silent failures from unset variables (the `${TMUX:-}` expansion guards against the `set -u` flag). The `NOTIFY_ARGS` array construction and expansion is valid bash.

**6. Build passes**
PASS. `swift build` completes cleanly with `Build complete! (2.50s)`.

---

## Spec Match

- [x] All pseudocode sections implemented
- [x] No unplanned additions
- [x] Test coverage matches plan (Level: None — manual verification only)

Section-by-section mapping:

| Pseudocode section | Implementation | Status |
|---|---|---|
| `NotifyInstallHook` added to subcommands list | Line 20 of NotifyCommand.swift | Match |
| Step 1: Resolve paths (XDG_DATA_HOME, hooksDir, scriptPath, claudeConfigDir, settingsPath) | Lines 252–267 | Match |
| `resolveThegridBin()` via `/usr/bin/which`, fallback to `~/.local/bin/thegrid` | Lines 304–326 | Match |
| Step 2: createDirectory, buildHookScript, createFile, setAttributes 0o755 | Lines 271–287 | Match |
| Step 3: mergeSettingsJSON call | Lines 291–295 | Match |
| Print confirmation messages | Lines 297–299 | Match |
| `buildHookScript()` — full shell script with all sections | Lines 332–392 | Match |
| `mergeSettingsJSON()` — read-or-empty, hooks dict, Notification array, idempotency check, write back | Lines 396–452 | Match |
| Idempotency: check `command.contains("claude-waiting.sh")` before appending | Lines 423–429 | Match |
| JSON write with `.prettyPrinted, .sortedKeys` | Lines 447–450 | Match |

One minor deviation from pseudocode: the pseudocode sketches `mergeSettingsJSON` as taking `(settingsPath:, scriptPath:)`, but the implementation also passes `claudeConfigDir` as a parameter (for the `createDirectory` call when settings.json doesn't exist). This is correct — the pseudocode omitted this parameter for brevity; the implementation is more complete, not a deviation.

---

## Dead Code

None found.

- All imports (`ArgumentParser`, `Foundation`) are used.
- No unreachable code paths after early returns.
- No debug statements or commented-out blocks.
- The `@OptionGroup var globals: GlobalOptions` is declared but `globals` is never used inside `NotifyInstallHook.run()`. This matches every other subcommand in the file that has it for structural consistency with the ArgumentParser pattern; it is not dead code in the meaningful sense (it's part of the command's interface contract).

---

## Correctness Verification

| Dimension | Status | Evidence |
|-----------|--------|----------|
| Requirements | PASS | All 6 done-when criteria verified above with file:line evidence |
| Concurrency | N/A | No shared mutable state; command is a one-shot CLI invocation |
| Error Handling | PASS | See analysis below |
| Resource Mgmt | PASS | No open handles; `Data(contentsOf:)` and `serialized.write(to:)` are non-streaming; `Process` in `resolveThegridBin` runs synchronously and terminates before return |
| Boundaries | PASS | See analysis below |
| Security | PASS | See analysis below |

### Error Handling

- `createDirectory` — `throws`, propagated via `try`. Correct.
- `scriptContent.data(using: .utf8)` — guarded with `guard ... else { throw ValidationError(...) }` at line 278. This cannot actually fail (UTF-8 can encode any Swift String), but the guard is still correct defensive practice.
- `FileManager.default.createFile(atPath:contents:attributes:)` at line 281 — returns `Bool` but the return value is **discarded**. If the write fails (e.g., permission denied), the command silently continues, sets permissions, and then tries to merge settings. The subsequent `setAttributes` call would also fail if the file doesn't exist, which would throw and surface the error. So the failure path does eventually surface, but with a confusing error message (`setAttributes` failure rather than "failed to write script"). This is a minor quality issue, not a correctness failure — the command will not silently succeed in this case.
- `mergeSettingsJSON` — all throws propagated. `try? JSONSerialization` uses `try?` (via `(try? ...) ?? [:]`) which is correct: malformed JSON is treated as empty rather than crashing. Intentional per pseudocode line "If root is nil: root = [:] // malformed JSON — start fresh".
- `resolveThegridBin` — `catch` block at line 321 correctly falls through to the default path. Not empty; comment explains the intent.
- Shell script: all external calls guarded with `2>/dev/null || true`. The `set -euo pipefail` + `|| true` pattern correctly prevents the hook from ever returning non-zero to Claude.

### Boundaries

- Empty `XDG_DATA_HOME` env var: handled by `??` fallback. Correct.
- Missing `~/.claude/settings.json`: handled — `createDirectory` creates it, `root = [:]` starts fresh. Correct.
- Malformed `settings.json`: `(try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]` — silently resets to empty. This matches pseudocode intent and is acceptable behavior.
- Empty `hooks` or `Notification` keys in existing settings.json: `?? [:]` and `?? []` defaults handle these. Correct.
- Re-running `install-hook` (idempotency): checked via `command.contains("claude-waiting.sh")`. Correct.
- Hook script with empty `$CWD`: `PROJECT` falls back to `"unknown"`. Correct.
- Hook script outside tmux (`$TMUX` unset): `TMUX_INFO` stays `""`, body is just `PROJECT`. Correct.
- `python3` unavailable or JSON parse failure: `2>/dev/null || true` makes `CWD` empty, falls back to `"unknown"`. Correct.

### Security

- The `thegridBin` path resolved at install time is embedded in the script via Swift string interpolation. The resolved value comes from `/usr/bin/which thegrid` stdout (trimmed) or the hardcoded fallback. No user-controlled input enters this path.
- The `scriptPath` written to disk is derived from `XDG_DATA_HOME` env var. On macOS, env vars are user-controlled, so a malicious `XDG_DATA_HOME` could redirect the script to an arbitrary path. This is an acceptable risk: this is a local developer tool running as the user themselves.
- No secrets logged or exposed.
- Shell script does not eval any user-provided content; all user data (cwd) is passed through JSON parsing and used in a controlled way.

---

## Defensive Programming

Checked against the cc-defensive-programming crisis invariants:

| Check | Status | Evidence |
|-------|--------|----------|
| No executable code in assertions | PASS | No assertions present |
| No empty catch blocks | PASS | Line 321 catch block has comment and fall-through logic |
| External input validated at entry | PASS | stdin JSON in hook script parsed with `|| true` guard; settings.json parsed with `try?` fallback |
| Assertions for bugs only | N/A | No assertions used |

No violations. Pattern is consistent with the rest of `NotifyCommand.swift` (error propagation via `throws`, `try client.call`, `defer { client.disconnect() }`).

---

## Issues

None blocking. One observation:

`FileManager.default.createFile(atPath:contents:attributes:nil)` at line 281 discards its `Bool` return value. If the file cannot be written (e.g. disk full, permission denied on the hooks directory despite the preceding `createDirectory` succeeding), the command proceeds without error until `setAttributes` throws. The error message will reference `setAttributes` rather than the write failure. Not a correctness failure since an error is still surfaced; no fix required for PASS.
