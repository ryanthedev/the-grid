# Pseudocode: Phase 3 - Verify border sync and build

## Files to Create/Modify
- None. All code changes were completed in Phases 1 and 2.

## Pseudocode

No code changes needed. This phase is build + deploy + manual test.

### Build and deploy
```
Build the server (make run)
Verify server starts cleanly (check thegrid-server.json for srv.start)
```

### Manual test sequence
```
1. Apply layouts on both displays
2. Move window cross-display (ctrl-shift-L or ctrl-shift-H with -e -m flags)
3. Verify:
   a. Window lands in correct cell on target display
   b. Mouse cursor warps to target cell center
   c. Border highlights the moved window on target display
   d. Source display border updates to remaining focused window (not stale)
   e. No border flicker during the move
4. Rapid repeat: move window back and forth 3-4 times quickly
5. Verify no stale focus or border desync after rapid moves
```

## Design Notes
All border sync, suppression, and cooldown logic verified in discovery. The implementation correctly handles:
- SimpleBorderManager's single-display limitation (last setCellAssignments wins)
- Delayed OS appActivated events (blocked by 1-second cooldown)
- Stale metadata spaceID (resolved via findSpaceContaining from GridState)

## PRE-GATE Status
- [x] Discovery complete
- [x] Pseudocode complete (minimal - verification only)
- [x] Design reviewed (all five items verified)
- [x] Ready for implementation (build + test only)
