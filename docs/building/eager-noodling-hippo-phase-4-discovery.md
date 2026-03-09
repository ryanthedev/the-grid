# Discovery: Phase 4 - Makefile & Cleanup

## Files Found

| File | Exists | Current State |
|------|--------|---------------|
| `Makefile` | Yes | Line 1: `.PHONY` includes `terminal` and `terminal-universal`. Line 203: `dev: server terminal viewer`. No actual `terminal:` or `terminal-universal:` target definitions exist in the file (targets were deleted previously but references remain). |
| `grid-server/Sources/GridServer/main.swift` | Yes | Lines 45-50: `pkill -9 -f grid-terminal` cleanup block still present. This kills the old SwiftTerm-based GridTerminal binary on server startup -- vestigial dead code. |
| `grid-server/Package.swift` | Yes | Lines 16-18: `grid-terminal` product. Lines 60-64: `GridTerminal` executable target depending on SwiftTerm. Line 34: SwiftTerm package dependency (only used by GridTerminal). |
| `grid-server/Sources/GridTerminal/` | Yes | Contains `main.swift` (SwiftTerm-based terminal app, ~600 lines). Entire directory is dead code. |

## Current State

The old SwiftTerm-based GridTerminal has been fully replaced by GridTerminalManager (Phases 1-3 of this plan). GridTerminal is no longer built, invoked, or referenced by any live code. The remaining references are:

1. **Makefile line 1:** `.PHONY` lists `terminal` and `terminal-universal` (no corresponding targets exist)
2. **Makefile line 203:** `dev` depends on `terminal` (which has no target -- make silently ignores this since `terminal` has no recipe and no prerequisites)
3. **main.swift lines 45-50:** Kills stale `grid-terminal` processes on startup (harmless but dead)
4. **Package.swift:** GridTerminal product, target, and SwiftTerm dependency
5. **GridTerminal/ directory:** The entire SwiftTerm terminal source

## Additional Finding: SwiftTerm Package Dependency

The SwiftTerm package dependency (`swift-term` on line 34 of Package.swift) is ONLY used by the GridTerminal target. Removing GridTerminal means we should also remove the SwiftTerm package dependency to avoid fetching an unused dependency.

## Gaps

| Plan Item | Reality | Impact |
|-----------|---------|--------|
| Plan says "Remove `terminal` and `terminal-universal` from `.PHONY` line 1" | Confirmed present at line 1 | None |
| Plan says "Remove `terminal` from `dev` dependencies in Makefile line 203" | Line 203 reads `dev: server terminal viewer` | None |
| Plan says "Remove `pkill -9 -f grid-terminal` cleanup from main.swift:46-49" | Actually lines 45-50 (includes comment on line 45) | Minor line number correction |
| Plan says "Remove GridTerminal executable target from Package.swift" | Present at lines 60-64 | None |
| Plan says "Remove grid-server/Sources/GridTerminal/ directory" | Exists with main.swift | None |
| Plan does NOT mention removing SwiftTerm package dependency | SwiftTerm is only used by GridTerminal | Should also remove from Package.swift line 34 |
| Plan does NOT mention removing `grid-terminal` product from Package.swift | Product definition at lines 16-18 | Should also remove |

## Prerequisites
- [x] Phases 1-3 complete (GridTerminalManager wired in, CLI subcommand working)
- [x] All files to edit exist
- [x] GridTerminal directory exists for deletion
- [x] No live code references GridTerminal (only Package.swift, Makefile, and startup cleanup)

## Recommendation
BUILD -- All items are straightforward deletions/edits. Two additional items identified beyond the plan: remove SwiftTerm package dependency and remove `grid-terminal` product definition from Package.swift.
