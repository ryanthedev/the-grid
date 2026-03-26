# Plan: Notification Panel RPC + Double-Fire Fix

**Created:** 2026-03-25
**Status:** ready
**Complexity:** simple

---

## Context

The notification panel tiles and focuses correctly after the activation policy toggle approach (commit 005cd9d), but three gaps remain: (1) CLI commands fail because grid.notify.* RPC methods aren't registered in MessageHandler, (2) BFD double-fires Alt+N because two keydown events at elapsed=0ms both pass the rate limit check, and (3) the toggle handler manually assigns the panel to a cell which will conflict with the reconciler auto-discovering it.

## Constraints

- Follow the existing `register(method:) + dispatchAndRespond` pattern in MessageHandler
- The `trackSelf()`/`untrackSelf()` calls must stay paired with activation policy switches
- No changes to BFD config schema or reconciler logic
- Own-process AX guards in GridApply and GridFocus must remain

---

## Implementation Phases

### Phase 1: Register grid.notify.* RPC methods in MessageHandler
**Model:** sonnet

**Goal:** Wire all notification CLI subcommands through RPC so `thegrid notify *` works from the CLI.

**Scope:**
- IN: Register RPC methods for show, hide, toggle, push, list, dismiss, clear, count, assign, unassign, install-hook. Use the `dispatchAndRespond` pattern.
- OUT: No new CLI commands, no new notification features.

**File hints:**
- `grid-server/Sources/GridServer/MessageHandler.swift` — add registrations in `registerBuiltInHandlers()`
- `grid-server/Sources/GridCLI/NotifyCommand.swift` — reference for RPC method names and params

**Done when:**
- [ ] All grid.notify.* methods registered in registerBuiltInHandlers()
- [ ] `thegrid notify toggle` succeeds from CLI
- [ ] `thegrid notify push "test" --body "hello"` succeeds from CLI
- [ ] `thegrid notify list` returns JSON from CLI

---

### Phase 2: Fix BFD double-fire and simplify toggle handler
**Model:** sonnet

**Goal:** Prevent same-event double-firing and let the reconciler handle cell assignment instead of manual assignment in the toggle handler.

**Scope:**
- IN: Enforce 100ms minimum gap for `repeat: false` hotkeys in BFDKeyHandler. Remove assignNotifyPanel/unassignNotifyPanel/leastPopulatedCell from GridCommandRouter. Move trackSelf/untrackSelf into NotificationPanelManager.show()/hide() so they're always paired with the policy switch.
- OUT: No changes to BFD config schema, no changes to reconciler auto-assignment logic.

**Constraints:**
- `trackSelf()` must be called after `setActivationPolicy(.regular)` but before the window is shown
- `untrackSelf()` must be called after the window is hidden but before `setActivationPolicy(.accessory)`

**Approach notes:**
- User chose 100ms minimum gap over fixing `<` to `<=` — provides margin against OS event batching
- User chose reconciler-handles-assignment over manual control — consistent with how all other windows work

**File hints:**
- `grid-server/Sources/GridServer/BFD/BFDKeyHandler.swift` — rate limit check in `shouldExecute()`
- `grid-server/Sources/GridServer/Grid/GridCommandRouter.swift` — simplify show/hide/toggle handlers
- `grid-server/Sources/GridServer/Notifications/NotificationPanelManager.swift` — move trackSelf/untrackSelf here
- `grid-server/Sources/GridServer/StateManager.swift` — trackSelf/untrackSelf (already exists)

**Done when:**
- [ ] Alt+N never toggles twice from a single press
- [ ] Notification panel auto-tiles via reconciler (no manual assignNotifyPanel)
- [ ] Show/hide/toggle handlers just call show()/hide() — no cell assignment logic
- [ ] trackSelf/untrackSelf are in NotificationPanelManager, not GridCommandRouter

---

## Test Coverage

**Level:** None — manual verification via Alt+N toggle and CLI commands

## Test Plan

- [ ] Manual: `thegrid notify toggle` from CLI shows/hides panel
- [ ] Manual: `thegrid notify push "test"` sends notification
- [ ] Manual: Alt+N single press toggles once (check logs for single action.start/end pair)
- [ ] Manual: Panel auto-tiles into least populated cell without manual assignment
- [ ] Manual: Focus left/right works with panel visible, no crashes

---

## Notes

- The own-process AX guard (NSWindow.setFrame on MainActor instead of AX) in GridApply and GridFocus must remain — AppKit crashes on AX calls to own-process windows from background threads
- When reconciler handles assignment, the panel will go to the least populated cell (same as any new window)
- The `assignNotifyPanel` function and `leastPopulatedCell` helper can be deleted entirely

---

## Execution Log

_To be filled during /code-foundations:building_
