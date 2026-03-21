# Plan: Reconciler & Border System Overhaul

**Created:** 2026-03-21
**Status:** in-progress
**Started:** 2026-03-21 04:45
**Current Phase:** 1
**Complexity:** complex

---

## Context

The theGrid window manager has compounding state corruption and visual instability caused by race conditions between OS focus events and grid commands, no proactive window liveness validation (leading to zombie windows), windows duplicated across multiple spaces, and border pool over-provisioning with rebuild spam. The reconciler/border interaction model needs a full overhaul: fenced command model, auto-pruning state validator, and border-per-cell allocation.

## Constraints

- Grid state is source of truth; OS events update state only when no command is in flight
- Tabbed cells need exactly 1 border (the visible window), not N
- Auto-manage space state -- prune spaces that no longer exist
- No ghost windows, no flicker, no snap-back on moves
- Must survive sleep/wake, display disconnect, app crashes without manual intervention
- Must remain compatible with existing BFD hotkey config and CLI commands
- All actions logged via `jlog` following existing JSONL conventions

## Chosen Approach

**B: Fenced Command Model + State Validator**

Eliminates timing-based race conditions structurally. Commands acquire fences that block OS event processing for specific windows until the command's effects have fully settled (including border sync). A periodic StateValidator auto-prunes zombies and deduplicates cross-space windows. Border allocation switches from per-window pool to per-cell model, dramatically reducing churn.

**Fallback:** If fencing proves too complex, fall back to Approach A (increase cooldown to 3s + periodic validation) as an intermediate step.

## Rejected Approaches

- **A: Patch & Harden:** Fixes symptoms individually but doesn't address structural issues. Time-based cooldowns will always have edge cases. New bugs will emerge from same root causes.
- **C: Event Sequencer:** Full serialized queue is the cleanest architecture but requires massive rewrite. GridState is already an actor providing serialization -- adding another layer is redundant. Risk of introducing latency.

---

## Implementation Phases

### Phase 1: State Validator -- Prune Zombies and Deduplicate
**Model:** sonnet
**Skills:** `code-foundations:cc-defensive-programming`

**Goal:** Add a StateValidator that periodically and on-demand validates all tracked windows exist, removes zombies, deduplicates windows across spaces, and prunes dead spaces. Clean state is the foundation for all other fixes.

**Scope:**
- IN: Window liveness checking via SLSGetWindowBounds or CGWindowList, removing dead windows from GridState, deduplicating windows across spaces (keep most recent), pruning spaces not in current displays, periodic timer (~30s) and on-wake trigger
- OUT: Reconciler changes, border changes, focus tracking changes

**Constraints:**
- Must not block main thread -- run validation async
- Must use existing `removeWindow`/`removeWindowFromAllSpaces` APIs on GridState actor
- Log all pruning actions with `ev: "validate.*"` prefix

**Approach notes:**
- For deduplication: keep window in space matching current display's active space. If ambiguous, keep most recently updated space.
- For space pruning: if a space ID no longer exists in wmState, remove it from GridState.

**File hints:**
- `grid-server/Sources/GridServer/Grid/` -- new StateValidator, GridState modifications
- `grid-server/Sources/GridServer/Grid/GridReconciler.swift` -- call validator on wake

**Depends on:** None | **Unlocks:** Phase 2, Phase 3

**Done when:**
- [ ] StateValidator runs on wake and every ~30s
- [ ] Dead windows (failed SLSGetWindowBounds) removed from all spaces
- [ ] Windows appearing in multiple spaces are deduplicated
- [ ] Spaces not present in wmState are pruned
- [ ] All actions logged with `validate.*` event prefix
- [ ] After sleep/wake, no previously-moved window reappears in its old position

**Difficulty:** MEDIUM
**Uncertainty:** SLSGetWindowBounds may return success for minimized windows -- need to distinguish dead vs minimized

---

### Phase 2: Command Fencing -- Replace Time-Based Cooldown
**Model:** opus
**Skills:** `code-foundations:aposd-simplifying-complexity`, `code-foundations:cc-defensive-programming`

**Goal:** Replace the 1-second move cooldown and suppression depth with a scoped fencing model. Commands acquire fences that block OS event processing for specific windows until effects settle (including border sync). Eliminates timing-based races where delayed OS events undo moves.

**Scope:**
- IN: Fence acquisition/release in GridReconciler, fence checking in `handleFocusChanged`, fence-aware border sync (sync completes before fence releases), replacing `beginMove`/`endMove`/`moveCooldownSeconds` with fence-based blocking, replacing detached `Task{}` border sync with awaited sync, making `findSpaceContaining` deterministic
- OUT: Border allocation model (Phase 4), state validation (Phase 1)

**Constraints:**
- Fences must have safety timeout (5s) to prevent deadlocks
- OS focus events for windows NOT covered by any fence must pass through normally
- `findSpaceContaining` must search spaces in defined order, prefer space matching current display
- Must remain compatible with existing BFD hotkey config and CLI commands

**Approach notes:**
- Fence model: `(windowIDs: Set<UInt32>, expiresAt: CFAbsoluteTime)` -- OS focus events for fenced windows are dropped until fence releases or expires
- Grid-authoritative: fences err on blocking OS events rather than letting stale ones through
- Remove `suppressionDepth`, `moveCooldownSeconds`, `moveTargetWindowID`, `moveEndTime` -- all replaced by fences

**File hints:**
- `grid-server/Sources/GridServer/Grid/GridReconciler.swift` -- fence storage, checking, lifecycle
- `grid-server/Sources/GridServer/Grid/GridWindowMove.swift` -- fence acquisition in moves
- `grid-server/Sources/GridServer/Grid/GridState.swift` -- deterministic `findSpaceContaining`

**Depends on:** Phase 1 | **Unlocks:** Phase 3, Phase 4

**Done when:**
- [ ] Move commands acquire fences blocking OS focus events for moved windows
- [ ] Fences release after border sync completes (not time-based)
- [ ] Fences have safety timeout (5s)
- [ ] `findSpaceContaining` returns deterministic results
- [ ] Same-display move border sync is awaited, not fire-and-forget
- [ ] No `moveCooldownSeconds` or `suppressionDepth` remains

**Difficulty:** HIGH
**Uncertainty:** Fence granularity -- per-window may be too fine, per-cell may be too coarse

---

### Phase 3: Focus Tracking Hardening
**Model:** sonnet
**Skills:** `code-foundations:aposd-maintaining-design-quality`

**Goal:** Fix `lastFocusedWid` corruption so switching cells always restores the correct window. Ensure reconciler's `handleFocusChanged` cannot overwrite move-set focus when fences are active.

**Scope:**
- IN: Guard `setFocus` calls against fenced windows, validate `lastFocusedWid` still exists in cell before restoring, handle case where `lastFocusedWid` moved to another cell/space
- OUT: Border changes, state validation

**Constraints:**
- `focusCellByID` must always produce a visible, valid window -- never focus a zombie or off-screen window

**File hints:**
- `grid-server/Sources/GridServer/Grid/GridFocus.swift` -- `focusCellByID`, window validation
- `grid-server/Sources/GridServer/Grid/GridReconciler.swift` -- fence-aware `handleFocusChanged`
- `grid-server/Sources/GridServer/Grid/GridState.swift` -- `setFocus` guards

**Depends on:** Phase 2 | **Unlocks:** Phase 5

**Done when:**
- [ ] `focusCellByID` validates `lastFocusedWid` exists in cell before using it
- [ ] Moving a window and immediately switching focus does not snap the window back
- [ ] Switching cells restores correct window consistently
- [ ] Moving a window and switching back to source cell doesn't surface a phantom

**Difficulty:** MEDIUM
**Uncertainty:** If Phase 2 changes fence granularity to per-cell, `setFocus` guard logic must adapt accordingly

---

### Phase 4: Border-Per-Cell Model -- Eliminate Pool Churn
**Model:** opus
**Skills:** `code-foundations:aposd-designing-deep-modules`, `code-foundations:aposd-simplifying-complexity`

**Goal:** Redesign border allocation from per-window to per-cell. Tabbed cells get 1 border (around visible window). Eliminates pool of 10, constant evictions, and rebuild storms. Consolidate rebuild triggers to fire once per user action.

**Scope:**
- IN: Border allocation (1 active border per cell in tabbed mode, N for split mode), replacing pool-based with cell-based allocation, deduplicating rebuild triggers (coalesce `atomic-positionRefresh` spam), border retarget to follow focused window within cell (not destroy/recreate), adapting the awaited sync call site from Phase 2 to the per-cell path
- OUT: Reconciler/fencing logic (Phase 2), state validation (Phase 1)

**Constraints:**
- Must handle layout changes (tabbed to split and back)
- Must handle display disconnect gracefully
- Border style (active vs inactive) still tracks per-cell focus

**Approach notes:**
- Tabbed cells: 1 border for visible window. Border retargets when user cycles tabs.
- Split cells: each visible window gets its own border, allocated per-cell not from global pool.

**File hints:**
- `grid-server/Sources/GridServer/Borders/SimpleBorderManager.swift` -- allocation model, rebuild logic
- `grid-server/Sources/GridServer/Borders/BorderWindow.swift` -- retarget behavior

**Depends on:** Phase 2 | **Unlocks:** Phase 5

**Done when:**
- [ ] Tabbed cells have exactly 1 border (around visible window)
- [ ] Border retargets within cell without destroy/recreate cycle
- [ ] No more `bdr.pool.evict` with `wid:0`
- [ ] `atomic-positionRefresh` rebuilds coalesced (max 1 per user action)
- [ ] Display disconnect releases cell borders cleanly

**Difficulty:** HIGH
**Uncertainty:** Split mode border allocation -- how many borders per cell when not tabbed?

---

### Phase 5: Resilience -- Sleep/Wake, Display Changes, Crash Recovery
**Model:** sonnet
**Skills:** `code-foundations:cc-defensive-programming`

**Goal:** Make the system auto-heal after disruptive events. Sleep/wake triggers full state validation + border rebuild. Display changes trigger space migration + border reallocation. App crashes caught by periodic validator.

**Scope:**
- IN: Enhanced wake handler (validate state + reapply layouts), display disconnect handler (release borders, prune state), display reconnect (detect new spaces, apply defaults), Ghostty window creation burst handling (debounce/filter zero-size windows)
- OUT: Core reconciler/fencing (Phase 2), border model (Phase 4)

**Constraints:**
- Wake validation must complete before user commands are processed
- Ghostty zero-size window bursts (9-14 in <1s) must not cause event storms

**File hints:**
- `grid-server/Sources/GridServer/Grid/GridReconciler.swift` -- wake handler, display disconnect
- `grid-server/Sources/GridServer/Grid/GridState.swift` -- space migration
- `grid-server/Sources/GridServer/Grid/GridApply.swift` -- post-wake layout reapply

**Depends on:** Phase 3, Phase 4 | **Unlocks:** None

**Done when:**
- [ ] User commands issued immediately after wake are blocked until state validation completes
- [ ] Display disconnect cleans up borders and state for that display
- [ ] Ghostty window creation bursts don't cause event storms
- [ ] State survives app crashes (validator catches orphaned windows within 30s)
- [ ] No manual intervention needed after any disruptive event

**Difficulty:** MEDIUM
**Uncertainty:** Wake timing -- macOS may fire events before our wake handler runs

---

## Test Coverage

**Level:** Minimal validation

## Test Plan

- [ ] Unit: StateValidator deduplication logic (window in multiple spaces resolves correctly)
- [ ] Unit: StateValidator pruning (dead window IDs removed, live ones kept)
- [ ] Unit: Fence lifecycle (acquire, check, release, timeout expiry)
- [ ] Unit: `findSpaceContaining` determinism (returns consistent results with duplicates)
- [ ] Manual: Move window cross-display, verify no snap-back after 1-3 seconds

---

## Assumptions

| Assumption | Confidence | Verify Before Phase | Fallback If Wrong |
|-----------|-----------|--------------------|--------------------|
| SLSGetWindowBounds returns failure for destroyed windows | HIGH | Phase 1 | Use CGWindowListCopyWindowInfo as backup |
| Minimized windows return success from SLSGetWindowBounds | MED | Phase 1 | Check isMinimized flag in wmState before pruning |
| Per-window fencing is sufficient granularity | MED | Phase 2 | Expand to per-cell fencing |
| Ghostty zero-size windows can be filtered by frame size | HIGH | Phase 5 | Filter by subrole or title pattern |

## Decision Log

| Decision | Alternatives Considered | Rationale | Phase |
|----------|------------------------|-----------|-------|
| Fenced command model over time-based cooldown | 1s cooldown (current), 3s cooldown, event queue | Time-based always has edge cases; fences block by scope | 2 |
| Grid-authoritative state | OS-authoritative, hybrid | User prioritized accuracy over flexibility | 2 |
| 1 border per tabbed cell | N borders per cell, global pool | User confirmed only visible window needs border | 4 |
| Per-cell border allocation | Global pool (current), per-display pool | Eliminates pool churn; cell is natural allocation unit | 4 |
| Auto-manage spaces | Manual cleanup, keep all | User chose auto-manage; reduces stale state accumulation | 1 |

---

## Notes

- Window 162 is a persistent zombie that has been failing AX operations since at least ts:1774037331. Phase 1 validator will catch this.
- Windows 190, 97, 1041, 16907, 37361 are duplicated across spaces. Phase 1 deduplication handles this.
- Ghostty creates 9-14 ephemeral windows per launch (zero-size AXStandardWindow). 95 of 106 Ghostty windows created are never destroyed. Phase 5 addresses this.
- Border pool evictions are 100% dead borders (wid:0). Phase 4 eliminates this class of issue entirely.
- `atomic-positionRefresh` accounts for 69% of all border rebuilds (754/1090). Phase 4 coalesces these.

---

## Execution Log

### Phase 1: State Validator
- [x] PRE-GATE: Discovery + pseudocode complete
- [x] IMPLEMENT: Code written, build passes
- [x] POST-GATE: Verification passed (retry 1: fixed weak->strong reference for StateValidator lifetime)
- [x] CHECKPOINT: Committed
Pipeline: full
Model: sonnet (plan override)
Commit: c1fcc56
Summary: Added StateValidator actor with periodic (~30s) and on-wake validation. Three passes: prune dead windows via SLSGetWindowBounds, deduplicate cross-space windows, prune dead spaces. Wired into GridReconciler with strong reference.
