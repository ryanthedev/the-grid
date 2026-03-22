# Plan: Notification Panel

**Created:** 2026-03-22
**Status:** ready
**Complexity:** complex

---

## Context

Build a persistent, cell-assignable notification panel for theGrid that aggregates notifications from multiple sources (RPC/CLI, internal events, file/pipe watchers), renders them with SwiftUI in a custom-themed window matching theGrid's border aesthetic, supports full vim-style management (navigate, dismiss, filter, pin, priority, bulk ops), and allows actionable notifications that can trigger commands like focusing a specific window.

## Constraints

- Cell-assignable window (lives in the grid like any app window, not a floating overlay)
- SwiftUI rendering via NSHostingView
- Persisted to disk (survives server restarts)
- Custom themed (matching border color scheme, configurable via YAML)
- Vim motions for full management (j/k navigate, d/x dismiss, / filter, pin, priority, bulk ops)
- Actionable notifications (carry commands -- focus window, run shell command, etc.)
- Three notification sources: RPC/CLI, internal events, file/pipe watchers
- Must integrate with existing EventRouter, GridCommandRouter, GridConfig, GridState

## Chosen Approach

**Real NSWindow managed by theGrid**

The grid server owns the notification window directly as a standard NSWindow with NSHostingView. The reconciler treats it like any other window for cell assignment. Feedback loops are prevented by blacklisting the notification window in the event observer. SwiftUI renders natively, vim keybindings go through the standard AppKit responder chain, and notification actions execute directly in-process with no IPC overhead.

**Fallback:** If feedback loops prove unmanageable, extract to a separate helper process (Approach B) -- the notification model and SwiftUI views transfer directly since they have no direct coupling to server internals.

## Rejected Approaches

- **Separate helper process:** Clean separation avoids feedback loops, but adds IPC complexity, two-process management, and latency for notification delivery and action execution. Not worth the overhead given the blacklist approach should work.
- **SkyLight overlay window:** Breaks cell-assignable requirement entirely. SkyLight windows don't participate in the normal window system (no AX element, no standard focus). Rendering SwiftUI into CGContext is extremely awkward. Not viable for interactive content.

---

## Implementation Phases

### Phase 1: Notification data model and persistence
**Model:** sonnet
**Skills:** `code-foundations:aposd-designing-deep-modules`

**Goal:** Define the notification data model, storage actor, and persistence layer so all subsequent phases have a stable foundation to build on.

**Scope:**
- IN: `Notification` struct (id, source, title, body, priority, timestamp, read/pinned/dismissed state, optional action), `NotificationStore` actor (CRUD, filtering, bulk ops), JSON persistence to state dir
- OUT: UI rendering, event integration, command routing, config

**Constraints:**
- Must be an actor for thread safety (consistent with StateManager/GridState pattern)
- Persistence to `~/.local/state/thegrid/notifications.json` with debounced writes (same pattern as GridState)

**Approach notes:**
- Use Codable structs, not classes -- user chose persistence across restarts
- Three action types: focus window (by ID), run shell command, open URL -- exact representation left to implementation

**File hints:**
- `grid-server/Sources/GridServer/Grid/GridState.swift` -- persistence pattern to follow
- `grid-server/Sources/GridServer/` -- new `Notifications/` directory

**Depends on:** None | **Unlocks:** Phase 2, Phase 4

**Done when:**
- [ ] `Notification` model defined with all fields (id, source, title, body, priority, timestamp, read, pinned, dismissed, action)
- [ ] Unit tests confirm add/remove/update/filter/bulk-dismiss/pin/unpin/priority-reorder all behave correctly with assertions on returned state
- [ ] Notifications persist to disk and load on server start
- [ ] Unit tests validate CRUD and persistence round-trip

**Difficulty:** MEDIUM
**Uncertainty:** None -- straightforward data modeling following existing patterns

---

### Phase 2: NSWindow, SwiftUI views, and vim keybindings
**Model:** opus
**Skills:** `code-foundations:aposd-designing-deep-modules`, `code-foundations:cc-routine-and-class-design`, `design-for-ai:design`, `design-for-ai:color`

**Goal:** Create the notification panel window with SwiftUI content and vim-style keyboard navigation, so the panel can render and be interacted with independently of grid integration.

**Scope:**
- IN: `NotificationPanel` (NSWindow subclass with NSHostingView), `NotificationPanelManager` (singleton, lifecycle), SwiftUI views (notification list, items, status bar), vim keybinding responder (navigate, dismiss, act, filter, pin, priority change, bulk ops), custom theme rendering matching border color scheme, stub config struct for theme colors (to be replaced by YAML parsing in Phase 5)
- OUT: Cell assignment, event-driven notifications, RPC commands, config loading

**Constraints:**
- Window must be a standard NSWindow (not NSPanel) so it appears in CGWindowListCopyWindowInfo and can be cell-assigned
- Vim keybindings handled via `keyDown` override in an NSHostingView subclass or a custom NSView wrapper
- Theme colors must be configurable (read from a passed-in config, not hardcoded)

**File hints:**
- `grid-server/Sources/GridServer/Picker/PickerWindow.swift` -- window creation pattern
- `grid-server/Sources/GridServer/Picker/PickerViews.swift` -- SwiftUI view patterns
- `grid-server/Sources/GridServer/Borders/SimpleBorderConfig.swift` -- color/theme config pattern

**Depends on:** Phase 1 | **Unlocks:** Phase 3

**Done when:**
- [ ] NSWindow with NSHostingView renders a scrollable notification list
- [ ] j/k navigates, d/x dismisses, Enter executes action, / enters filter mode, p toggles pin, +/- changes priority, V enters visual select for bulk operations
- [ ] Visual theme matches border color scheme (background, text, highlight colors from config)
- [ ] Window appears in the system window list (verifiable via CGWindowListCopyWindowInfo)
- [ ] Panel can be shown/hidden programmatically

**Difficulty:** HIGH
**Uncertainty:** Vim keybinding interception within NSHostingView -- may need a custom NSView wrapper to capture keyDown before SwiftUI consumes it

---

### Phase 3: Grid integration (cell assignment, reconciler, commands)
**Model:** opus
**Skills:** `code-foundations:cc-integration-practices`

**Goal:** Wire the notification panel into the grid system so it's cell-assignable, controllable via BFD hotkeys and CLI commands, and doesn't cause reconciler feedback loops.

**Scope:**
- IN: Blacklist notification window in event observer/reconciler (prevent feedback loops), register `@notify` command domain in GridCommandRouter, add RPC handlers in MessageHandler (`grid.notify.show`, `grid.notify.push`, etc.), add CLI subcommands, add BFD hotkey examples to config
- OUT: File/pipe watchers, internal event subscriptions, config YAML parsing

**Constraints:**
- Must blacklist the notification window by its window ID in ApplicationObserver/reconciler to prevent feedback loops (see Decision Log for rationale)
- Must use reconciler suppression tokens (`beginAction/endAction`) when showing/hiding the panel
- Must register commands via existing GridCommandRouter and MessageHandler patterns (not ad-hoc)

**File hints:**
- `grid-server/Sources/GridServer/Grid/GridCommandRouter.swift` -- command registration
- `grid-server/Sources/GridServer/StateManager.swift` -- blacklist pattern
- `grid-server/Sources/GridServer/EventRouter.swift` -- event handler registration
- `grid-server/Sources/GridServer/main.swift` -- wiring

**Depends on:** Phase 2 | **Unlocks:** Phase 5

**Done when:**
- [ ] Notification window is blacklisted in event observer (no feedback loops)
- [ ] `@notify show/hide/toggle` commands work from BFD hotkeys
- [ ] `thegrid notify push "title" --body "text" --action "focus:123"` pushes a notification via CLI
- [ ] `thegrid notify list/dismiss/clear` CLI commands work
- [ ] Panel can be assigned to a grid cell and tiled alongside other windows

**Difficulty:** HIGH
**Uncertainty:** Feedback loop prevention -- blacklisting by window ID vs. window title vs. process-level filtering. May need experimentation.

---

### Phase 4: Notification sources (events, file/pipe watcher)
**Model:** sonnet
**Skills:** `code-foundations:cc-integration-practices`

**Goal:** Connect the remaining notification sources -- internal grid events and file/pipe watchers -- so the panel receives notifications from all three configured sources.

**Scope:**
- IN: `StateEventHandler` implementation that generates notifications from configurable events (e.g., window created, focus changed), file/pipe watcher that reads lines and creates notifications, source configuration in YAML
- OUT: UI changes, command changes

**Constraints:**
- Event-to-notification mapping must be configurable (user decides which events generate notifications)
- File watcher must handle file rotation and pipe EOF gracefully
- Must register event handlers via existing EventRouter protocol

**File hints:**
- `grid-server/Sources/GridServer/EventRouter.swift` -- StateEventHandler protocol
- `grid-server/Sources/GridServer/Grid/GridConfig.swift` -- config parsing pattern

**Depends on:** Phase 1 | **Unlocks:** Phase 5

**Done when:**
- [ ] Configurable internal events generate notifications (e.g., `windowCreated` -> notification)
- [ ] File watcher reads lines from a configured path and creates notifications
- [ ] Named pipe watcher works for streaming notification input
- [ ] Source types are distinguishable in the notification list (icon or label)

**Difficulty:** MEDIUM
**Uncertainty:** Named pipe handling on macOS -- EOF behavior when writer disconnects, re-opening semantics

---

### Phase 5: Configuration and polish
**Model:** sonnet

**Goal:** Add YAML configuration for the notification system and ensure all pieces work together end-to-end.

**Scope:**
- IN: `notifications:` config section in YAML (theme colors, default sources, event filters, file watch paths, max notifications, auto-dismiss rules), config hot-reload, end-to-end integration testing
- OUT: Nothing -- this is the final phase

**Constraints:**
- Config must follow existing XDG resolution and deep-merge patterns
- Hot-reload must update the panel appearance without restart

**File hints:**
- `grid-server/Sources/GridServer/Grid/GridConfig.swift` -- config loading pattern, extend with notifications section

**Depends on:** Phase 3, Phase 4 | **Unlocks:** None

**Done when:**
- [ ] `notifications:` YAML section parsed and applied
- [ ] Theme colors configurable and hot-reloaded
- [ ] Event filter list configurable
- [ ] File/pipe watch paths configurable
- [ ] End-to-end: CLI push -> notification appears -> vim navigate -> Enter executes action -> window focuses

**Difficulty:** MEDIUM
**Uncertainty:** None -- follows established config patterns

---

## Test Coverage

**Level:** Backend only

## Test Plan

- [ ] Unit: NotificationStore CRUD, persistence round-trip, filtering, bulk operations
- [ ] Unit: Notification model encoding/decoding
- [ ] Manual: Panel renders in grid cell, vim keybindings work, CLI push arrives, action execution focuses correct window
- [ ] Manual: Config hot-reload changes theme colors without restart

---

## Assumptions

| Assumption | Confidence | Verify Before Phase | Fallback If Wrong |
|-----------|-----------|--------------------|--------------------|
| NSWindow owned by server process can be cell-assigned by reconciler | HIGH | Phase 3 | Extract to separate helper process |
| Vim keybindings can be intercepted before SwiftUI in NSHostingView | MED | Phase 2 | Wrap NSHostingView in custom NSView that handles keyDown first |
| Blacklisting notification window prevents feedback loops | MED | Phase 3 | Use window title prefix for identification; if still looping, extract to separate process |
| Named pipes on macOS handle writer disconnect/reconnect gracefully | MED | Phase 4 | Fall back to file watching with polling |

## Decision Log

| Decision | Alternatives Considered | Rationale | Phase |
|----------|------------------------|-----------|-------|
| Real NSWindow (not NSPanel) | NSPanel, SkyLight overlay | Must be cell-assignable; NSPanel is floating-only; SkyLight can't host SwiftUI | 2 |
| SwiftUI via NSHostingView | AppKit views, CoreGraphics | User chose SwiftUI; declarative list rendering is natural fit; easy theme binding | 2 |
| Actor-based NotificationStore | Class with locks, @MainActor | Consistent with GridState/StateManager pattern; natural async interface | 1 |
| Blacklist by window ID | Blacklist by PID, window title | Window ID is most precise; PID would block all server windows; title could collide | 3 |
| Persisted JSON (not SQLite) | SQLite, CoreData | Consistent with GridState pattern; notifications are simple list, not relational | 1 |

---

## Notes

- The picker pattern (PickerManager, PickerWindow, PickerState, PickerViews) is the closest architectural analog. The notification panel follows the same manager/window/state/views decomposition but as a cell-assignable window instead of a floating panel.
- The "Claude is waiting for input" use case (from PR #53 / claude-waiting-indicator plan) is a key motivator. The notification panel provides the display surface for that feature.
- Feedback loop prevention is the highest-risk technical challenge. If the server's own window generates AX events that the server then processes, it could cause infinite recursion. The blacklist approach should work but needs careful testing.

---

## Execution Log

_To be filled during /code-foundations:building_
