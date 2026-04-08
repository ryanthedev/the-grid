# Discovery: Phase 2 - Install-hook command

## Files Found

### Phase 1 output (prerequisite — confirmed complete)
- `grid-server/Sources/GridServer/Picker/Enrichment/ProcessTree.swift` — `getAncestors(of:maxDepth:)` implemented, `parent` map populated during build
- `grid-server/Sources/GridCLI/WindowCommand.swift` — `WindowFind` subcommand implemented, outputs bare window ID or exits non-zero

### Phase 2 target
- `grid-server/Sources/GridCLI/NotifyCommand.swift` — exists, 10 subcommands registered. No `install-hook` subcommand yet.
- `~/.claude/settings.json` — exists with substantial content (permissions, hooks, plugins). Contains `hooks` object with `PreToolUse`, `PostToolUse`, `UserPromptSubmit` keys. No `Notification` key yet.
- `~/.local/share/thegrid/hooks/` — directory does NOT exist yet (XDG data home `~/.local/share/thegrid/` missing entirely)
- `~/.local/bin/thegrid` — binary exists at this path (confirmed in PATH)

### Supporting files confirmed
- `grid-server/Sources/GridCLI/GridCLI.swift` — `NotifyCommand.self` is already registered; no change needed
- `grid-server/Package.swift` — `GridCLI` target uses only `ArgumentParser`; Foundation is available implicitly via Swift stdlib on macOS

## Current State

### NotifyCommand.swift
10 subcommands: `show`, `hide`, `toggle`, `push`, `list`, `dismiss`, `clear`, `count`, `assign`, `unassign`. `NotifyInstallHook` does not exist. `push` subcommand accepts `title` (Argument), `--body`, `--priority`, `--source`, `--action` (Options) and calls `grid.notify.push`.

### ~/.claude/settings.json
Large file (~100 lines). JSON with `$schema`, `env`, `permissions`, `hooks`, `enabledPlugins`, `alwaysThinkingEnabled`, etc. The `hooks` key maps to an object where each key is an event type name. The `Notification` key is absent — adding it means merging a new top-level key into the existing `hooks` object.

### Claude Code hook event structure (confirmed via docs)
- Event type: `Notification`, matcher value: `idle_prompt`
- The hook fires when Claude finishes a task and is waiting for user input
- Hook receives stdin JSON: `{ "session_id", "transcript_path", "cwd", "hook_event_name", "message", "title", "notification_type" }`
- `cwd` is the project directory at the time Claude went idle

### Hook script target path
- `~/.local/share/thegrid/hooks/claude-waiting.sh`
- Directory `~/.local/share/thegrid/hooks/` must be created if absent

### Process chain for PID walking
Claude Code hook runs as: `terminal app -> login shell -> tmux server -> tmux client -> shell -> claude -> hook script`
- `$$` in bash = hook script's own PID
- Walking up with `ps -o ppid=` iteratively reaches the terminal app PID
- `thegrid window find --pid <PID>` was built in Phase 1 for exactly this

### tmux metadata
- `tmux display-message -p '#S:#W'` outputs `session:window` when inside tmux
- Falls back gracefully if not in tmux (tmux will error; script checks `$TMUX` var)

### JSON read/write pattern in CLI
`LayoutCommand.swift` demonstrates reading a file via `FileManager`, parsing with `JSONSerialization`, modifying, and writing back. The same approach works for settings.json.

## Gaps

1. `NotifyCommand.swift` needs `NotifyInstallHook` subcommand added to `subcommands` list and implemented
2. `~/.local/share/thegrid/hooks/` directory must be created by the install command
3. `~/.claude/settings.json` merge logic: read existing JSON (or start with `{}`), add/merge `Notification` key into `hooks` object, write back

## Prerequisites

- [x] Phase 1 complete: `thegrid window find --pid <PID>` works
- [x] `thegrid notify push` CLI command exists with `--body`, `--action`, `--source` options
- [x] `~/.local/bin/thegrid` binary path known
- [x] `ArgumentParser` available in `GridCLI` target
- [x] `Foundation` available (FileManager, JSONSerialization, ProcessInfo)
- [x] Claude Code hook event type and JSON structure confirmed (`Notification` / `idle_prompt`)
- [x] `~/.claude/settings.json` structure known (merge target)
- [x] `tmux display-message` available for session:window metadata
- [x] Script target path confirmed: `~/.local/share/thegrid/hooks/claude-waiting.sh`

## Recommendation

BUILD — all prerequisites met. Work is entirely additive:
1. Add `NotifyInstallHook` struct to `NotifyCommand.swift`
2. Hook script template embedded as a Swift string literal in the command
3. Swift command creates the directory, writes the script, sets +x, reads/merges/writes settings.json
