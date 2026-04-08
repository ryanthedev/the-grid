# Pseudocode: Phase 2 - Install-hook command

## Files to Create/Modify

- `grid-server/Sources/GridCLI/NotifyCommand.swift` — add `NotifyInstallHook` subcommand

## Design

### Design: How the Swift command delivers the hook script content

The CLI needs to embed the hook script text and write it to disk.

**Approaches considered:**

1. **Inline Swift string literal** — the script text is a raw Swift string (`#"""..."""#`) inside `NotifyInstallHook.run()`. No external file dependency. Single source of truth lives in the Swift file.

2. **Separate `.sh` file bundled in the Swift package** — added as a resource via `Package.swift`. The command reads it from `Bundle.module`. Requires Package.swift change, adds resource loading complexity.

3. **Fetch the script from a URL** — download latest version from a GitHub URL at install time. Requires network at install time, adds failure modes, unnecessary for a local tool.

**Comparison:**

| Criterion | A: inline string | B: bundled resource | C: remote fetch |
|-----------|-----------------|--------------------|----|
| Interface simplicity | Simple — self-contained | Moderate — Bundle.module | Complex — network |
| Caller ease of use | Works offline | Works offline | Requires network |
| Hidden information | Script text inside CLI binary | Script text in separate file | Remote dependency |
| Maintenance | Edit one file | Edit two files | Edit remote resource |

**Choice: A (inline Swift string literal)**
Rationale: The script is small (~40 lines), tightly coupled to the CLI's own capabilities (`thegrid window find`, `thegrid notify push`), and has no reason to be separately versioned. Inlining it keeps the CLI self-contained and offline-capable. Approach B adds Package.swift complexity with no benefit at this scale.

---

### Design: How to merge into ~/.claude/settings.json

The command must add a `Notification` hook entry without destroying existing content.

**Approaches considered:**

1. **Read → decode → mutate in-place → write** — parse existing JSON as `[String: Any]`, navigate into `hooks` dict, append to `Notification` array if it exists or create it, serialize and write back. Preserves all existing content.

2. **Write a new file if absent, refuse if present** — only write settings.json if it does not exist, print a message telling the user to merge manually otherwise. Safe but requires user action on any existing file.

3. **Always overwrite with a minimal template** — write only the Notification hook, ignoring existing content. Destructive.

**Comparison:**

| Criterion | A: read-merge-write | B: refuse if exists | C: overwrite |
|-----------|--------------------|--------------------|-------------|
| Interface simplicity | Moderate — JSON traversal | Simple to implement | Simple to implement |
| Caller ease of use | Single command does everything | User must manually merge | Destroys permissions/other hooks |
| Information hiding | Hidden merge complexity | Hidden nothing | Destroys hidden user config |
| Correctness | Always correct | Correct but incomplete UX | Incorrect |

**Choice: A (read-merge-write)**
Rationale: The user's `settings.json` contains important content (permissions allow-list, other hooks). Destroying or refusing to touch it is not acceptable. The merge logic is straightforward: `[String: Any]` → `hooks` dict → `Notification` array → append entry. The existing `LayoutCommand.swift` establishes this JSON read/write pattern in the codebase already.

**Idempotency constraint:** If a `Notification`/`idle_prompt`/`claude-waiting.sh` entry already exists, do not add a duplicate. Check before appending.

---

## Pseudocode

### `NotifyCommand.swift` — add `NotifyInstallHook`

```
Add NotifyInstallHook.self to NotifyCommand.configuration.subcommands list

New struct NotifyInstallHook: ParsableCommand:
    configuration:
        commandName = "install-hook"
        abstract = "Install Claude Code idle notification hook"

    @OptionGroup var globals: GlobalOptions

    // No additional options needed — all paths are derived from XDG conventions

    func run() throws:
        // --- Step 1: Resolve paths ---
        homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        // XDG_DATA_HOME default is ~/.local/share
        dataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"] ?? "\(homeDir)/.local/share"
        hooksDir = "\(dataHome)/thegrid/hooks"
        scriptPath = "\(hooksDir)/claude-waiting.sh"

        claudeConfigDir = "\(homeDir)/.claude"
        settingsPath = "\(claudeConfigDir)/settings.json"

        // Resolve thegrid binary path (use PATH lookup, fall back to ~/.local/bin/thegrid)
        thegridBin = resolveThegridBin()
        // resolveThegridBin: try `which thegrid` via Process, else use hardcoded ~/.local/bin/thegrid

        // --- Step 2: Write hook script ---
        Create directory at hooksDir (including intermediates) if not exists
            FileManager.default.createDirectory(atPath: hooksDir, withIntermediateDirectories: true)

        scriptContent = buildHookScript(thegridBin: thegridBin)

        Write scriptContent to scriptPath (UTF-8)

        Make scriptPath executable:
            FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

        // --- Step 3: Merge settings.json ---
        mergeSettingsJSON(settingsPath: settingsPath, scriptPath: scriptPath)

        Print "Installed hook script: \(scriptPath)"
        Print "Updated: \(settingsPath)"
        Print "Claude Code will notify theGrid when idle."


private func resolveThegridBin() -> String:
    // Run `which thegrid` as a subprocess
    Try to run Process: /usr/bin/which thegrid, capture stdout
    If output is non-empty, return trimmed output

    // Fall back to known install path
    Return "\(homeDir)/.local/bin/thegrid"


private func buildHookScript(thegridBin: String) -> String:
    Return the raw string:

    #!/bin/bash
    # Claude Code idle notification hook for theGrid
    # Installed by: thegrid notify install-hook
    # Fires on Notification/idle_prompt event (Claude finished, waiting for input)

    set -euo pipefail

    THEGRID="\(thegridBin)"

    # Read the hook event JSON from stdin (Claude Code passes it here)
    INPUT=$(cat)

    # Extract cwd from the hook event JSON
    CWD=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('cwd',''))" 2>/dev/null || true)

    # Get project directory basename
    if [ -n "$CWD" ]; then
        PROJECT=$(basename "$CWD")
    else
        PROJECT="unknown"
    fi

    # Get tmux session:window if inside tmux
    TMUX_INFO=""
    if [ -n "${TMUX:-}" ]; then
        TMUX_INFO=$(tmux display-message -p '#S:#W' 2>/dev/null || true)
    fi

    # Build notification body
    if [ -n "$TMUX_INFO" ]; then
        BODY="$TMUX_INFO  $PROJECT"
    else
        BODY="$PROJECT"
    fi

    # Walk parent PID chain to find the terminal window
    # The chain: hook -> claude -> shell -> tmux-client -> shell -> terminal app
    # thegrid window find --pid walks ancestors automatically (server-side)
    SELF_PID=$$
    WID=$("$THEGRID" window find --pid "$SELF_PID" 2>/dev/null || true)

    # Build action: focus the terminal window if found, else no action
    if [ -n "$WID" ]; then
        ACTION="focus:$WID"
    else
        ACTION=""
    fi

    # Push notification to theGrid panel
    NOTIFY_ARGS=("Claude" --body "$BODY" --source "claude-code")
    if [ -n "$ACTION" ]; then
        NOTIFY_ARGS+=(--action "$ACTION")
    fi

    "$THEGRID" notify push "${NOTIFY_ARGS[@]}" 2>/dev/null || true

    exit 0


private func mergeSettingsJSON(settingsPath: String, scriptPath: String) throws:
    // Read existing file or start with empty object
    If file exists at settingsPath:
        data = try Data(contentsOf: settingsPath)
        root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        If root is nil:
            root = [:]   // malformed JSON — start fresh (don't crash)
    Else:
        // Create ~/.claude directory if needed
        Create directory at claudeConfigDir if not exists
        root = [:]

    // Navigate to hooks dict
    var hooks = root["hooks"] as? [String: Any] ?? [:]

    // Navigate to Notification array
    var notificationHooks = hooks["Notification"] as? [[String: Any]] ?? []

    // Check for existing claude-waiting.sh entry (idempotency)
    alreadyInstalled = notificationHooks.contains where:
        entry["hooks"] as? [[String: Any]]? contains hook where hook["command"] contains "claude-waiting.sh"

    If NOT alreadyInstalled:
        newEntry = [
            "matcher": "idle_prompt",
            "hooks": [
                [
                    "type": "command",
                    "command": scriptPath
                ]
            ]
        ]
        Append newEntry to notificationHooks

    // Write back
    hooks["Notification"] = notificationHooks
    root["hooks"] = hooks

    serialized = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    Write serialized to settingsPath
```

---

## Design Notes

### Why `$$` in the hook script works for PID walking
When bash executes `SELF_PID=$$`, `$$` expands to the PID of the current shell process running the script. `thegrid window find --pid` walks ancestors server-side (Phase 1), so the server walks up from that PID through claude → shell → tmux-client → terminal app, matching the first ancestor PID that owns a window. This eliminates all PID-walking logic from the hook script itself.

### Why python3 for JSON parsing in the hook script
The hook receives JSON on stdin. `python3 -c "import sys,json; ..."` is universally available on macOS and doesn't require `jq`. The `|| true` guard means a failure to parse cwd is non-fatal — the notification still fires with just the project name or "unknown".

### Why `|| true` on every thegrid call in the hook
The hook must exit 0 regardless of whether theGrid is running. Claude Code may interpret a non-zero hook exit as a problem. Defensive use of `|| true` ensures the hook never blocks Claude's idle state.

### Idempotency in mergeSettingsJSON
The check looks for any entry in the `Notification` array whose embedded `command` contains `"claude-waiting.sh"`. This survives minor path differences (e.g., symlinks) while preventing duplicate entries on repeated `install-hook` runs.

### Why sortedKeys in JSON serialization
The existing `settings.json` has no guaranteed key order, but `sortedKeys` produces stable, diff-friendly output. This matches the pattern used in `GridCLI.swift` `printResult`.

### resolveThegridBin uses subprocess `which`
Rather than hardcoding `~/.local/bin/thegrid`, the script embeds the actual resolved path at install time. This means the hook script continues to work even if the user's `$PATH` changes. The fallback to `~/.local/bin/thegrid` handles the case where `which` is unavailable or thegrid is not yet in PATH during install.

### TMUX_INFO format
`tmux display-message -p '#S:#W'` outputs `session-name:window-name`. Combined with the project directory basename, the notification body becomes e.g., `main:0  notification-panel` — enough context to identify which Claude session sent the notification.

---

## PRE-GATE Status

- [x] Discovery complete
- [x] Pseudocode complete
- [x] Design reviewed (aposd-designing-deep-modules: 2 alternatives compared for script delivery, 3 for settings merge)
- [ ] Ready for implementation
