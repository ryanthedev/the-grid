# Plan: Modular Terminal Enricher System

**Created:** 2026-01-23
**Status:** complete

## Context

The launcher shows window information, but terminal windows (Ghostty) often display unhelpful titles like "t ." when running SSH or tmux. Need to:
1. Detect SSH sessions and show `user@host` with context
2. Show tmux pane commands (e.g., `[nvim | zsh | htop]`)
3. Build extensible system for future enrichers (Chrome profiles, etc.)

## Constraints

- Ghostty-only for SSH detection (for now)
- Best-effort from local process info (no remote SSH queries)
- SSH takes priority over tmux in display
- Must not add significant latency to launcher

## Chosen Approach

**Modular Enricher System (Approach B)**

Create enricher interface with implementations for SSH and tmux. Each enricher:
- Targets specific bundle IDs
- Returns optional enrichment data
- Runs independently, results combined by priority

Rationale: Extensible for future enrichers (Chrome profiles, docker, kubectl), clean separation of concerns.

## Display Format

| Scenario | Title | Subtitle |
|----------|-------|----------|
| Plain Ghostty | window title | `Ghostty` |
| Local tmux | `thegrid` | `thegrid:nvim [nvim \| zsh]` |
| SSH only | `root@prod-server` | `~/app: tail -f logs` |
| SSH + remote tmux | `root@prod-server` | `deploy:build [npm \| zsh]` |

## Implementation Checklist

### Phase 1: Enricher Interface & Types

- [ ] Create `grid-cli/internal/enrichers/types.go` with core types
- [ ] Define `Enricher` interface: `Enrich(pid int, bundleID string) *Enrichment`
- [ ] Define `Enrichment` struct with SSH/Tmux/combined fields
- [ ] Define `SSHInfo` struct: `User`, `Host`, `RemoteCwd`, `RemoteCommand`
- [ ] Define `TmuxInfo` struct: `SessionName`, `WindowName`, `PaneCommands []string`

**Files:** `grid-cli/internal/enrichers/types.go`

**Details:**
```go
type Enrichment struct {
    SSH   *SSHInfo
    Tmux  *TmuxInfo
}

type SSHInfo struct {
    User          string
    Host          string
    RemoteCwd     string   // best-effort from window title
    RemoteCommand string   // best-effort
}

type TmuxInfo struct {
    SessionName  string
    WindowName   string
    PaneCommands []string  // all panes, not just current
}
```

### Phase 2: SSH Enricher

- [ ] Create `grid-cli/internal/enrichers/ssh.go`
- [ ] Implement `SSHEnricher` struct
- [ ] Walk process tree looking for `ssh` process (command name)
- [ ] Parse SSH args to extract user@host (handle `ssh host`, `ssh user@host`, `ssh -l user host`)
- [ ] Extract remote context from window title if available (terminals often set title via escape codes)
- [ ] Add tests for SSH arg parsing

**Files:** `grid-cli/internal/enrichers/ssh.go`, `grid-cli/internal/enrichers/ssh_test.go`

**Details:**
- Use existing `process.GetDescendantPIDs()` to find SSH process
- Run `ps -o args= -p <pid>` to get full command line
- Parse patterns:
  - `ssh user@host` → user, host
  - `ssh -l user host` → user, host
  - `ssh host` → current user, host
  - `ssh -J jump user@host` → user, host (ignore jump)

### Phase 3: Tmux Enricher Enhancement

- [ ] Create `grid-cli/internal/enrichers/tmux.go`
- [ ] Move/refactor logic from `grid-cli/internal/tmux/clients.go`
- [ ] Add `GetPaneCommands(sessionName, windowName string) []string` function
- [ ] Query: `tmux list-panes -t session:window -F '#{pane_current_command}'`
- [ ] Update `TmuxInfo` to include all pane commands
- [ ] Add tests

**Files:** `grid-cli/internal/enrichers/tmux.go`, `grid-cli/internal/tmux/panes.go`

**Details:**
- Keep existing `tmux.GetClients()` for client PID lookup
- Add new `tmux.GetPaneCommands()` for pane enumeration
- Cache pane info alongside client info to avoid repeated queries

### Phase 4: Enricher Registry & Combiner

- [ ] Create `grid-cli/internal/enrichers/registry.go`
- [ ] Implement `Registry` that holds all enrichers
- [ ] Implement `Enrich(pid, bundleID, windowTitle)` that runs applicable enrichers
- [ ] Combine results with priority: SSH info as primary, tmux as context
- [ ] Format output strings for title/subtitle

**Files:** `grid-cli/internal/enrichers/registry.go`

**Details:**
```go
func (r *Registry) Enrich(pid int, bundleID, windowTitle string) *Result {
    result := &Result{}

    for _, e := range r.enrichers {
        if e.Supports(bundleID) {
            enrichment := e.Enrich(pid, windowTitle)
            result.Merge(enrichment)
        }
    }

    return result.Format()
}
```

### Phase 5: Integration

- [ ] Update `grid-cli/cmd/grid/main.go` to use enricher registry
- [ ] Replace inline `enrichWithTmux()` with registry call
- [ ] Update `windowsToPickerItems()` to use new enrichment results
- [ ] Update subtitle formatting to include pane commands
- [ ] Update stable ID generation for SSH windows

**Files:** `grid-cli/cmd/grid/main.go`

**Details:**
- Create registry once at start of `windowsToPickerItems()`
- For each terminal window, call `registry.Enrich()`
- Map enrichment result to title/subtitle:
  - If SSH: title = `user@host`
  - If SSH+Tmux: subtitle = `session:window [cmd | cmd]`
  - If Tmux only: title = session, subtitle = `session:window [cmd | cmd]`
- Stable ID for SSH: `ssh:{user}@{host}:{session}` or `ssh:{user}@{host}`

### Phase 6: Testing & Validation

- [ ] Unit tests for SSH arg parsing (various formats)
- [ ] Unit tests for pane command formatting
- [ ] Manual test: SSH into remote machine, verify title shows user@host
- [ ] Manual test: SSH + tmux, verify subtitle shows remote session
- [ ] Manual test: Local tmux with multiple panes, verify pane commands shown

**Files:** Various `*_test.go` files

## Test Plan

- [ ] Unit: SSH arg parsing handles `user@host`, `-l user host`, `host` formats
- [ ] Unit: Pane command formatting produces `[nvim | zsh | htop]`
- [ ] Unit: Priority combiner correctly chooses SSH over tmux for title
- [ ] Integration: Manual verification with real SSH/tmux sessions

## Notes

- Chrome profile enricher deferred to future work (needs investigation)
- Future enrichers to consider: docker exec, kubectl exec, mosh
- If SSH detection causes latency issues, can add caching similar to tmux cache
- Window title parsing for remote cwd is best-effort (depends on remote shell config)

## Execution Log

### Phase 1: Enricher Interface & Types ✅
- Created `grid-cli/internal/enrichers/types.go`
- Core types: `Enrichment`, `SSHInfo`, `TmuxInfo`, `Enricher` interface, `Result`
- Format() implements all three display scenarios
- Tests: 7 passing (HasSSH, Merge, Format variations, PaneCommands)
- Commit: 075b12b

### Phase 2: SSH Enricher ✅
- Created `grid-cli/internal/enrichers/ssh.go`
- SSHEnricher implementing Enricher interface
- Walks process tree, parses SSH args (user@host, -l, -J formats)
- Extracts window title context (cwd, command)
- Tests: 14 passing (parseSSHArgs, extractTitleContext)
- Commit: d512888

### Phase 3: Tmux Enricher Enhancement ✅
- Created `grid-cli/internal/enrichers/tmux.go`
- Added `GetPaneCommands` to tmux/clients.go
- TmuxEnricher with cache, process tree search
- Tests: 3 passing (Supports, buildEnrichment, Enrich_NoTmux)
- Commit: ae9e02b

### Phase 4: Enricher Registry & Combiner ✅
- Created `grid-cli/internal/enrichers/registry.go`
- Registry orchestrates SSH + Tmux enrichers
- Enrich() with Merge() and Format() flow
- Cache lifecycle management (RefreshCaches, Cleanup, ClientPIDs)
- Tests: 3 passing
- Commit: b6e173f

### Phase 5: Integration ✅
- Updated `grid-cli/cmd/grid/main.go` with enricher registry
- Removed ad-hoc tmuxEnrichment, enrichWithTmux()
- Updated stableWindowID() for SSH/Tmux prefixes
- All tests pass (cmd/grid, enrichers, tmux)
- Net: +46/-80 lines (cleaner code)
- Commit: 8f2267f

### Phase 6: Testing & Validation ✅
- All unit tests pass (16 packages)
- Binary builds successfully
- Manual testing deferred to user acceptance
