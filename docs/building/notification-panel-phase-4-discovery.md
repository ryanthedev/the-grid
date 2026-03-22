# Discovery: Phase 4 - Notification sources (events, file/pipe watcher)

## Files Found

### Plan hint files
- `grid-server/Sources/GridServer/EventRouter.swift` -- EXISTS. `StateEventHandler` protocol defined at line 143. `EventRouter.shared` actor with `register()`/`unregister()`. Pattern is: conform to `StateEventHandler`, call `await EventRouter.shared.register(self)` in init (inside a Task).
- `grid-server/Sources/GridServer/Grid/GridConfig.swift` -- EXISTS. Config parsing pattern: add new section to `load()`, parse from the merged `[String: Any]` dictionary, follow existing `parseSettings`/`parseLayouts` helper pattern.

### Existing notification files (all from prior phases)
- `grid-server/Sources/GridServer/Notifications/Notification.swift` -- `GridNotification` struct with `source: String` field (comment: "rpc", "internal", "file", "pipe"). Already rendering source label in `NotificationItemView`.
- `grid-server/Sources/GridServer/Notifications/NotificationStore.swift` -- Complete CRUD actor. `add(_ notification:)` is the entry point for all new notifications.
- `grid-server/Sources/GridServer/Notifications/NotificationPanelManager.swift` -- Lifecycle manager (show/hide/toggle), exposes `currentViewModel` for refresh.
- `grid-server/Sources/GridServer/Notifications/NotificationPanelViews.swift` -- `NotificationItemView` already renders `notification.source` as a text tag in the title row (line 172).

### Reference implementations for StateEventHandler pattern
- `grid-server/Sources/GridServer/Grid/GridRecorder.swift` -- `FocusTracker: StateEventHandler`. Simple pattern: class with `init()` that calls `await EventRouter.shared.register(self)` inside a Task, implements `handle(_:context:)` with a guard for the events it cares about.
- `grid-server/Sources/GridServer/Grid/GridReconciler.swift` -- Larger handler, same pattern.
- `grid-server/Sources/GridServer/Borders/BorderEvents.swift` -- Minimal handler, shows bare-minimum conformance.

### main.swift
- `grid-server/Sources/GridServer/main.swift` -- Wiring point. Pattern is to instantiate objects and optionally register them. No notification-source wiring yet.

## Current State

Phase 1 (data model), Phase 2 (UI), and Phase 3 (RPC/CLI commands) are complete. The notification system works via the RPC source only.

**What exists relevant to Phase 4:**
- `GridNotification.source` field exists and is already displayed in the UI as a text label
- `NotificationStore.shared.add()` is the integration point for all three source types
- `StateEventHandler` protocol is established with multiple reference implementations
- `EventRouter.shared` is the broadcast hub -- any class conforming to `StateEventHandler` can subscribe
- `GridConfig` has the pattern for parsing new YAML sections

**What does NOT exist yet (needs to be built):**
- `NotificationEventHandler` -- class conforming to `StateEventHandler` that maps grid events to notifications
- `NotificationFileWatcher` -- reads lines from a file or named pipe, creates notifications
- Configuration structs for the notification sources (event filter list, file/pipe paths)
- No `notifications:` YAML section exists in `GridConfig` yet (that is planned for Phase 5, but Phase 4 needs a minimal config structure to make sources configurable without hardcoding)

## Gaps vs Plan

### Gap 1: Config ownership boundary between Phase 4 and Phase 5
The plan says Phase 4 includes "source configuration in YAML" but Phase 5 is "the notifications: YAML config section". The plan is ambiguous about which phase owns the YAML config struct.

**Resolution:** Phase 4 will define the minimal config structs needed by its two sources (event filter list, file/pipe paths) as Swift structs with hardcoded defaults. Phase 5 will wire them to YAML parsing. This follows the existing pattern -- Phase 2 introduced `NotificationPanelTheme` as a stub struct before Phase 5 wires it to YAML.

### Gap 2: Named pipe EOF behavior
The plan flags this as MED confidence uncertainty. The POSIX behavior is well-understood:
- Reader gets empty `Data` (EOF) when the last writer closes the pipe
- Reader must close and reopen the fd to wait for the next writer
- `open(path, O_RDONLY)` on a named pipe blocks until a new writer appears (desired behavior)
- Using `DispatchSource.makeReadSource` is the right approach: fire handler on readability, detect empty data as EOF, reschedule reopen

**This is not a plan-invalidating assumption.** The behavior is predictable; the implementation just needs to handle it explicitly. The fallback (file polling) is not needed -- named pipe reopening works correctly on macOS.

### Gap 3: Event-to-notification mapping granularity
The plan says "user decides which events generate notifications". The `StateEvent` enum has 20+ cases. The config needs to specify which events to subscribe to. The design decision is: use string event names as keys (matching `StateEvent.logInfo` event codes like "ev.win.create") vs. using an explicit allowlist enum.

**Resolution:** Use string keys matching the `logInfo` event name (e.g., `"ev.win.create"`, `"ev.focus"`) with user-configurable title templates. This is more flexible and aligns with how events are already named for logging.

## Prerequisites

- [x] `StateEventHandler` protocol exists and is ready to use
- [x] `EventRouter.shared.register()` works and is used by other handlers
- [x] `NotificationStore.shared.add()` is the stable integration point
- [x] `GridNotification.source` field exists and is displayed in the UI
- [x] Reference implementations of `StateEventHandler` available (`FocusTracker`, `GridReconciler`, `BorderEvents`)
- [x] Phase 3 complete and passing (51 tests pass)

## Assumption Verification

**"Named pipes on macOS handle writer disconnect/reconnect gracefully" (Confidence: MED)**

Status: **CONFIRMED with implementation note**

On macOS (Darwin), when the last writer process closes a named pipe:
- The reader's `read()` call returns 0 bytes (EOF signal)
- The pipe fd is still valid; the reader can detect EOF (empty Data) and re-open
- `open(path, O_RDONLY)` on the pipe path will **block** until a new writer opens it
- This is the desired behavior: the watcher naturally waits for the next writer session

The implementation must explicitly handle the EOF case by: (1) detecting empty `Data` from the read source, (2) canceling the current source, (3) reopening the path in a background Task (which will block until a new writer appears), (4) creating a new `DispatchSource.makeReadSource` on the new fd.

This is not a graceful failure -- it requires explicit code. But it is well-understood, reliable POSIX behavior. The fallback (file polling) is unnecessary.

**Recommendation: BUILD** -- no plan assumptions are invalidated.

## Recommendation

BUILD

What actually needs to be done:
1. Create `NotificationEventHandler.swift` -- a class conforming to `StateEventHandler` that consults a configurable event filter map and calls `NotificationStore.shared.add()` for matching events
2. Create `NotificationFileWatcher.swift` -- a class that opens a file or named pipe path, reads newline-delimited JSON notification objects, creates `GridNotification` instances, handles EOF/rotation
3. Define minimal config structs (`NotificationEventConfig`, `NotificationWatcherConfig`) with hardcoded defaults in a new `NotificationSourceConfig.swift` (Phase 5 will wire to YAML)
4. Wire both in `main.swift` after `NotificationStore.shared.load()`
