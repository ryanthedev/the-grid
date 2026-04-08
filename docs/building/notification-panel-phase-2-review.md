# Review: Phase 2 - NSWindow, SwiftUI views, and vim keybindings

## Verdict: FAIL

## Spec Match

- [x] NotificationPanelTheme.swift -- all 12 color properties + windowBackgroundNSColor + `static let default` + `init(from dictionary:)` + `parseHex` + `parseHexToNSColor`. Matches pseudocode exactly.
- [x] NotificationPanelViewModel.swift -- NotificationPanelMode enum (3 cases), NotificationPanelAction enum (4 cases), @MainActor class with all @Published properties (notifications, selectedIndex, mode, filterText, visualSelectionStart, statusText), theme property, store reference, all navigation/action/visual-select/filter/key-handling methods. Matches pseudocode.
- [x] NotificationPanelWindow.swift -- NSWindow subclass, init with viewModel, setupWindow (titled+closable+resizable+fullSizeContentView, hidden title, transparent titlebar, background color, title "Grid Notifications", isReleasedWhenClosed), setupContent (NSHostingView), canBecomeKey/canBecomeMain, keyDown override. Matches pseudocode.
- [x] NotificationPanelViews.swift -- NotificationPanelContentView, NotificationHeaderView (unread badge), NotificationFilterBar, NotificationListView (ScrollViewReader, LazyVStack, onChange scroll), NotificationItemView (priority indicator, pin symbol, title, source, body, timestamp, action hint, background selection), NotificationEmptyView, NotificationStatusBar (mode indicator), berkeleyMono font helper. Matches pseudocode.
- [x] NotificationPanelManager.swift -- Singleton with shared, private window/viewModel/isVisible, storedTheme, configure/show/hide/toggle, windowNumber/panelWindow accessors, dispatchPrecondition, lazy window creation. Matches pseudocode.
- [ ] **MISSING: @FocusState in NotificationFilterBar** -- Pseudocode specifies `@FocusState private var isFilterFocused: Bool` with `.focused($isFilterFocused)` on the TextField and `.onAppear { isFilterFocused = true }`. The implementation omits this entirely. Without it, the filter text field is not automatically focused when the user presses `/`, breaking the filter workflow.
- [x] No unplanned additions (berkeleyMono helper is a reasonable extraction of the pseudocode's inline font pattern)
- [x] Test coverage verified -- plan specifies "Backend only" tests, Phase 2 is UI with manual testing only. No unit tests required.

**Notes on minor deviations (acceptable):**
- Pseudocode `import Combine` omitted from ViewModel -- correct, Combine is not used anywhere.
- Pseudocode `refreshNotifications()` creates Task slightly differently (Task wraps whole body vs. filter built outside Task) -- semantically equivalent since buildFilter only reads @MainActor state.
- Pseudocode has `dismissSelected() -> Bool`, `togglePinSelected() -> Bool` returning Bool; implementation returns Void. The return values were never used by callers in the pseudocode either, so this is acceptable.
- Pseudocode has `ensureVisible(_ index:)` method; implementation uses SwiftUI ScrollViewReader `.onChange` instead. Pseudocode design notes acknowledge this as the intended approach. Acceptable.
- Manager uses `@MainActor` class annotation instead of runtime `dispatchPrecondition` alone. The implementation includes BOTH `@MainActor` AND `dispatchPrecondition` -- belt-and-suspenders, which is stricter than pseudocode. Good.

## Dead Code

- No unused imports found. `import AppKit` in ViewModel is used for `NSEvent.ModifierFlags`. `import SwiftUI` + `import AppKit` in Theme is used for `Color` and `NSColor`.
- No TODO/FIXME/print/debugPrint/dump statements found.
- No commented-out code blocks found (only documentation comments per codebase style).
- No unreachable code after early returns.

**None found.**

## Correctness Verification

| Dimension | Status | Evidence |
|-----------|--------|----------|
| Requirements | FAIL | Missing @FocusState for filter text field auto-focus. Plan requires "/ enters filter mode" -- without auto-focus, user must click the text field after pressing /, breaking the vim-style flow. |
| Concurrency | PASS | ViewModel is @MainActor; all @Published state accessed only from main thread. Store interactions use Task+await properly. Manager is @MainActor with dispatchPrecondition belt-and-suspenders. No shared mutable state across isolation boundaries. |
| Error Handling | PASS | Store calls are fire-and-forget mutations where the store handles persistence errors internally. parseHex returns nil on invalid input (checked via guard). Screen fallback: `NSScreen.main ?? NSScreen.screens.first!` -- the force-unwrap on screens.first is acceptable since macOS always has at least one screen object. |
| Resource Mgmt | PASS | Window is created lazily, isReleasedWhenClosed=false for reuse across show/hide. No file handles, sockets, or connections acquired. Tasks are short-lived fire-and-forget mutations. |
| Boundaries | PASS | selectedIndex clamped to `max(0, results.count - 1)` after refresh. selectNext/selectPrevious guard on isEmpty. currentNotification guards on valid index range. visualSelectedRange handles start > end via min/max. relativeTime handles negative intervals (returns "now"). Empty notifications array shows empty view. |
| Security | N/A | No untrusted external input in Phase 2. All data comes from the in-process NotificationStore. Hex parsing is safe (returns nil on bad input). |

## Defensive Programming

**Checked items:**
- No empty catch blocks -- no try/catch in Phase 2 files at all (store handles errors internally).
- No swallowed exceptions -- Task failures would be unstructured task failures but there are no throwing calls inside the Tasks (store methods don't throw).
- External input validation -- parseHex validates hex string format (prefix stripping, length check, UInt64 parse). Returns nil on invalid input rather than crashing.
- Assertions with side effects -- no assertions used; N/A.
- Broad exception types -- no catch blocks; N/A.

**One defensive concern (non-critical):**
- `bulkDismissVisualSelection()` and `bulkPinVisualSelection()` call `exitVisualSelect()` synchronously AFTER firing a Task that does the actual mutations. The `exitVisualSelect()` calls `updateStatusText()` which reads `notifications` before the Task has run. This means the status text briefly shows stale data. This is cosmetic, not a correctness issue -- the next `refreshNotifications()` inside the Task will fix it. Noting but not flagging.

**Critical violation: None.**

## Issues (FAIL)

1. **Missing @FocusState auto-focus for filter TextField**
   - File: `/Users/r/repos/theGrid/.claude/worktrees/notification-panel/grid-server/Sources/GridServer/Notifications/NotificationPanelViews.swift:69-103`
   - Pseudocode specifies:
     ```
     @FocusState private var isFilterFocused: Bool
     ...
     .focused($isFilterFocused)
     .onAppear { isFilterFocused = true }
     ```
   - Implementation omits all three lines. Without them, pressing `/` shows the filter bar but the text field is not focused. The user must click the text field with the mouse to start typing, which completely breaks the vim-style keyboard-only workflow that is the core UX requirement of Phase 2.
   - Fix: Add `@FocusState private var isFilterFocused: Bool` property to `NotificationFilterBar`, add `.focused($isFilterFocused)` modifier to the TextField, and add `.onAppear { isFilterFocused = true }` to the HStack or TextField to auto-focus when filter mode is entered.
