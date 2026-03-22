# Discovery: Phase 3 - Grid integration (cell assignment, reconciler, commands)

## Files Found

### Phase 1 & 2 outputs (prerequisites)
- `grid-server/Sources/GridServer/Notifications/Notification.swift` -- GridNotification model, actions, filter, persistence data
- `grid-server/Sources/GridServer/Notifications/NotificationStore.swift` -- Actor with CRUD, filtering, bulk ops
- `grid-server/Sources/GridServer/Notifications/NotificationPanelTheme.swift` -- Theme config
- `grid-server/Sources/GridServer/Notifications/NotificationPanelViewModel.swift` -- @MainActor ViewModel with vim key handling
- `grid-server/Sources/GridServer/Notifications/NotificationPanelManager.swift` -- Singleton lifecycle manager
- `grid-server/Sources/GridServer/Notifications/NotificationPanelWindow.swift` -- NSWindow subclass
- `grid-server/Sources/GridServer/Notifications/NotificationPanelViews.swift` -- SwiftUI views

### Integration targets (files to modify)
- `grid-server/Sources/GridServer/Grid/GridCommandRouter.swift` -- Add `notify` domain
- `grid-server/Sources/GridServer/MessageHandler.swift` -- Add RPC handlers for notify.*
- `grid-server/Sources/GridServer/main.swift` -- Wire NotificationPanelManager, load NotificationStore
- `grid-server/Sources/GridServer/StateManager.swift` -- Window ID blacklisting (needs new API)

### CLI (files to create)
- `grid-server/Sources/GridCLI/NotifyCommand.swift` -- NEW: CLI subcommand
- `grid-server/Sources/GridCLI/GridCLI.swift` -- Modify: register NotifyCommand

### Reference patterns
- `grid-server/Sources/GridServer/Grid/GridReconciler.swift` -- Suppression tokens, event handling
- `grid-server/Sources/GridServer/Picker/PickerManager.swift` -- Similar lifecycle pattern
- `grid-server/Sources/GridServer/Picker/ActionExecutor.swift` -- Action execution pattern
- `grid-server/Sources/GridServer/Grid/GridAssignment.swift` -- isTileable, classifyWindow
- `grid-server/Sources/GridServer/EventRouter.swift` -- Event types and handler protocol

## Current State

### Phase 1 & 2: Complete
- Notification model, store, persistence, views, window, vim keys all built.
- NotificationPanelManager exposes `windowNumber` and `panelWindow` specifically for Phase 3 blacklisting/cell assignment.
- NotificationPanelWindow has title "Grid Notifications" for identification.
- ViewModel `handleKeyDown` returns `NotificationPanelAction` -- `.executeAction` is logged but not wired to ActionExecutor yet.

### Integration Points Already Prepared
- `NotificationPanelManager.windowNumber` -- ready for blacklist registration
- `NotificationPanelManager.panelWindow` -- ready for cell assignment
- `NotificationPanelWindow.title = "Grid Notifications"` -- comment says "Phase 3 blacklisting"
- `NotificationPanelAction.executeAction` -- ready to wire to real action execution

## Gaps

### Gap 1: Blacklisting mechanism mismatch (CRITICAL)
The plan says "blacklist notification window by its window ID in ApplicationObserver/reconciler."
**Reality:** The existing blacklist in StateManager operates by **app bundle ID / app name**, not window ID. It filters at the `shouldTrackWindow(pid:)` level.

However, this is actually a **non-issue** for a different reason: the server process uses `.accessory` activation policy. StateManager only tracks `.regular` apps. The server's own windows (borders, picker, notification panel) are **never tracked by StateManager** and therefore never appear in the reconciler's event stream via `windowCreated` events.

The real concern is: when the notification panel calls `NSApp.activate(ignoringOtherApps: true)`, does this change the activation policy? Looking at the picker, it does the same thing (line 126 of PickerManager.swift) and works fine without blacklisting.

**Conclusion:** The notification window naturally avoids feedback loops because:
1. Server is `.accessory` -- not tracked by StateManager
2. No AX observer is created for the server's own PID
3. The window won't appear in `state.windows` so the reconciler never sees windowCreated/focusChanged events for it

A window-ID-based blacklist is **unnecessary** for preventing feedback loops. It may be needed for a different purpose: preventing the reconciler from trying to tile the notification window if it somehow enters the window list (e.g., via CGWindowListCopyWindowInfo during polling). Let me check the poll path.

### Gap 2: Cell assignment requires manual placement, not automatic tiling
The plan says "Panel can be assigned to a grid cell and tiled alongside other windows." Since the notification window is owned by the server process (.accessory), it won't be auto-discovered by StateManager's polling (which filters `.regular` apps). Cell assignment must be **explicit**: the command handler must manually insert the window into GridState's cell assignments and position it using WindowManipulator.

This means the notification panel is **not** automatically cell-assignable like a third-party app window. It needs a dedicated command that:
1. Gets the notification window's CGWindowID
2. Manually adds it to GridState for a specific cell
3. Calls GridApply to position it

This is actually fine -- it matches the "controlled by BFD hotkeys" approach. But it means the "cell assignment" done-when item needs clarification: it's command-driven, not automatic reconciler behavior.

### Gap 3: No existing `@notify` domain in GridCommandRouter
The command router handles: focus, layout, cell, window, resize, mouse, pick, state, record, terminal, nudge. No notify domain exists yet. This is expected (it's what we're building).

### Gap 4: No notify.* RPC methods in MessageHandler
Also expected -- we need to add them.

### Gap 5: CLI subcommand doesn't exist yet
`grid-server/Sources/GridCLI/NotifyCommand.swift` needs to be created. GridCLI is a separate target (no GridServer dependency), communicates purely via RPC.

## Assumption Verification

### Assumption 1: "NSWindow owned by server process can be cell-assigned by reconciler"
**Status: PARTIALLY WRONG**
The reconciler **won't automatically discover** the notification window because:
- Server is `.accessory` -- not tracked as an app
- No AX observer on server's own PID
- `isTileable()` requires `window.role == "AXWindow"` which requires AX data the server's own windows won't have

However, we can **manually** assign the window to a cell by directly updating GridState and using WindowManipulator to position it. This is how it should work -- we don't want automatic tiling of the notification panel.

**Impact: LOW** -- The intent was always to assign via command, not auto-tile. The plan language was misleading but the outcome is correct.

### Assumption 2: "Blacklisting notification window prevents feedback loops"
**Status: UNNECESSARY**
The server's `.accessory` activation policy already prevents feedback loops. The notification window is invisible to StateManager and the reconciler. No blacklisting needed for loop prevention.

However, we should add a **safety check** in the polling path: if the poll happens to enumerate the server's own windows (CGWindowListCopyWindowInfo returns all windows), the PID-based `shouldTrackWindow` check already filters them out because the server's PID is not in `state.applications`.

**Impact: NONE** -- No extra blacklisting work needed.

## Prerequisites
- [x] Phase 1 complete: notification model, store, persistence
- [x] Phase 2 complete: window, views, vim keys, manager
- [x] GridCommandRouter pattern understood
- [x] MessageHandler RPC registration pattern understood
- [x] CLI subcommand pattern understood
- [x] Reconciler suppression token pattern understood
- [x] Activation policy implications understood

## Recommendation
**BUILD** with these adjustments:
1. **Skip window ID blacklisting** -- not needed due to `.accessory` activation policy. Add a simple PID check as safety net in the show/hide path instead of a complex blacklist mechanism.
2. **Cell assignment via explicit command** -- implement `@notify assign <cellID>` that manually inserts the notification window ID into GridState. Do NOT expect automatic reconciler tiling.
3. **Use reconciler suppression tokens** for show/hide as planned (prevents spurious border syncs during panel transitions).
4. **Wire action execution** from NotificationPanelAction to real action dispatch (focusWindow via WindowManipulator, runShellCommand via Process, openURL via NSWorkspace).
