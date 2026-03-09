# Plan: Enrich window descriptions in `layout edit`

**Created:** 2026-02-28
**Status:** complete

## Context

`layout edit` currently shows `AppName — Title` which is uninformative for terminal windows (e.g., `Ghostty — 👻`). The picker already has a rich enricher system that detects tmux sessions, SSH connections, and Chrome profiles. We just need to wire it into the edit buffer.

## Constraints

- Reuse existing `enrichers.Registry` — no new enrichment logic
- Single-line format: `67842  Ghostty — thegrid (thegrid:zsh [zsh | nvim | logs])`
- Enricher adds ~50ms for process tree + tmux queries — acceptable for interactive command

## Chosen Approach

Wire the enricher pipeline into `layoutEditCmd` in main.go, passing enriched title/subtitle to the edit package's `WindowEntry`.

## Implementation Checklist

### Phase 1: Add subtitle to WindowEntry and format

- [ ] Add `Subtitle string` field to `WindowEntry` in `grid-cli/internal/edit/edit.go`
- [ ] Update `FormatWindowLine` in `grid-cli/internal/edit/format.go` to accept a 4th `subtitle string` parameter and append ` (subtitle)` when non-empty

**Files:** `grid-cli/internal/edit/edit.go`, `grid-cli/internal/edit/format.go`

**Details:**
```
FormatWindowLine(67842, "Ghostty", "thegrid", "thegrid:zsh [zsh | nvim | logs]")
→ "67842  Ghostty — thegrid (thegrid:zsh [zsh | nvim | logs])"
```

### Phase 2: Run enrichers in layoutEditCmd

- [ ] In `layoutEditCmd.RunE` (main.go), after `Reconcile.Sync` (~line 1579) and before building `CellInfo`:
  1. `registry := enrichers.NewRegistry()` + `registry.RefreshCaches()` + `process.RefreshProcessTree()`
  2. `defer registry.Cleanup()`
- [ ] Enrich windows in **both** code paths that build `WindowEntry`:
  - `--all` mode loop (~lines 1607-1614)
  - Focused-cell mode loop (~lines 1627-1634)
  3. In each loop, call `registry.Enrich(w.BundleID, w.PID, w.Title)`
  4. If result is non-nil: use `result.Title` as title (or fall back to `w.Title`), `result.Subtitle` as subtitle

**Files:** `grid-cli/cmd/grid/main.go`

**Existing functions to reuse:**
- `enrichers.NewRegistry()` — `grid-cli/internal/enrichers/registry.go:12`
- `registry.Enrich(bundleID, pid, windowTitle)` — `registry.go:25`
- `registry.RefreshCaches()` — `registry.go:50`
- `registry.Cleanup()` — `registry.go:57`
- `process.RefreshProcessTree()` — `grid-cli/internal/process/children.go`
- `WindowInfo.PID`, `WindowInfo.BundleID` — `grid-cli/internal/server/snapshot.go:40`

## Test Coverage

**Level:** Per-phase (update existing tests)

## Test Plan

- [ ] Update `TestFormatAndParseWindowLine` to verify subtitle rendering
- [ ] Manual: `EDITOR=cat thegrid layout edit --all` shows enriched tmux info

## Notes

- `ParseWindowLine` is unaffected — it only reads the leading uint32 ID
- Import `enrichers` package is already available as it's used in the picker flow
- The enricher import alias should follow the pattern: `"github.com/ryanthedev/grid-cli/internal/enrichers"` (no alias needed, already imported without one in main.go)
