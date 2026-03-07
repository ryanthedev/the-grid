# Phase 2 Discovery: Enrichment + History

## Go Enricher Architecture

### Types (enrichers/types.go)
- **Enrichment struct**: SSH (*SSHInfo), Tmux (*TmuxInfo), Chrome (*ChromeInfo)
- **Enricher interface**: `Supports(bundleID) bool`, `Enrich(pid, windowTitle) *Enrichment`
- **Result struct**: Display-ready: Title, Subtitle, StableIDSuffix
- **Format()**: Converts Enrichment to Result with combo handling (SSH+Tmux, SSH-only, Tmux-only, Chrome-only)

### Registry (enrichers/registry.go)
- Manages three enrichers: SSH, Tmux, Chrome
- `Enrich(bundleID, pid, windowTitle)` — iterates, checks Supports(), merges
- `RefreshCaches()` — calls RefreshClients() on tmux
- `Cleanup()` — prunes/saves tmux cache

## Process Tree (process/children.go)
- `GetDescendantPIDs(parentPID, maxDepth) -> ([]int, error)`
- Single `ps -eo pid,ppid` builds parent→children map (cached, sync.Once)
- Depth-first traversal in-memory
- Tmux uses depth 4, SSH uses depth 6

## TmuxEnricher (enrichers/tmux.go)
**Subprocess calls:**
- `tmux list-clients -F "#{client_pid}|#{session_name}|#{window_name}|#{window_index}|#{pane_index}|#{pane_current_command}"`
- `tmux list-windows -t {session} -F "#{window_name}"`

**Flow:** window PID → GetDescendantPIDs(pid, 4) → find tmux client PID → match to client info → Result

**Cache:** `~/.local/state/thegrid/tmux-cache.json` — windowPID → clientPID mapping with timestamps

**Stable ID suffix:** `sessionName:windowName`

## SSHEnricher (enrichers/ssh.go)
**Subprocess calls:**
- `ps -ax -o pid=,comm=` — build SSH process cache (once)
- `ps -o args= -p {sshPID}` — get SSH command line

**Flow:** window PID → GetDescendantPIDs(pid, 6) → find ssh process → parse args → SSHInfo

**SSH arg parsing:** handles `-l`, positional args, `user@host`, OpenSSH flags (-p, -i, -o, -F, -J, -D, -L, -R, -W, -b, -c, -e, -m, -S, -w)

**Stable ID suffix:** `user@host`

## ChromeEnricher (enrichers/chrome.go)
**Reads:** `~/Library/Application Support/Google/Chrome/Local State`

**Flow:** window title regex `- (?:Google Chrome|Brave|Chromium|Microsoft Edge) - (.+)$` → profile name → Local State JSON → email/directory

**Supported bundleIDs:** `com.google.Chrome` only (per Supports())

**Stable ID suffix:** `chrome:profileName`

## Picker History (state/picker_history.go)

**File:** `~/.local/state/thegrid/picker-history.json`

**Schema:**
```json
{"version": 1, "previous": "lastID", "frequency": {"id": count}, "lastPicked": {"id": unixTimestamp}}
```

**Key methods:**
- `RecordSelection(stableID)` — updates previous, increments frequency, sets lastPicked
- `FrecencyScore(id) float64` — `frequency * (1.0 / (1.0 + hoursSince / 24.0))`
- `Prune()` — LRU eviction, max 100 entries
- `Save()` — atomic write (temp + rename)

**Source boost multipliers:**
| Source | Boost | ID prefix |
|--------|-------|-----------|
| Windows | 10.0 | (default, tmux:) |
| Apps | 1.0 | app: |
| Chrome profiles | 1.0 | chrome: |
| Actions | 1.5 | action: |
| Zoxide | 0.5 | zoxide: |

**Sort:** `finalScore = max(frecency, 1.0) * sourceBoost`, stable sort descending

## Stable Window ID Generation (main.go:2454-2483)

| Type | Format |
|------|--------|
| Tmux | `tmux:{session}:{window}` |
| SSH | `ssh:{user}@{host}` |
| SSH+Tmux | `ssh:{user}@{host}/{session}:{window}` |
| Bundle+title | `{bundleID}:{normalizedTitle}:{hash4}` |
| Bundle no title | `{bundleID}:untitled:{wid}` |
| Unknown | `unknown:{wid}` |

**normalizeTitle:** lowercase → replace `[^a-z0-9]+` with `-` → collapse → trim → truncate 30
**hash4:** first 4 hex chars of SHA256

## Files to Port to Swift

| Go Source | Swift Target | Key Logic |
|-----------|-------------|-----------|
| `process/children.go` | `Picker/Enrichment/ProcessTree.swift` | `ps -eo pid,ppid` + BFS |
| `enrichers/tmux.go` | `Picker/Enrichment/TmuxEnricher.swift` | tmux list-clients, cache |
| `enrichers/ssh.go` | `Picker/Enrichment/SSHEnricher.swift` | ps + SSH arg parsing |
| `enrichers/chrome.go` | `Picker/Enrichment/ChromeEnricher.swift` | Local State JSON |
| `enrichers/registry.go` | `Picker/Enrichment/WindowEnricher.swift` | Orchestrates all three |
| `state/picker_history.go` | `Picker/PickerHistory.swift` | Frecency + file persistence |
| `main.go:stableWindowID` | `Picker/WindowSource.swift` (modify) | ID generation |
