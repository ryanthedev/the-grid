# Discovery: iMessage Notifications Phase 1 - Upsert + Grouping

## Current State

### NotificationStore (actor)
- **File:** `grid-notify/Sources/GridNotify/NotificationStore.swift`
- Storage: `byID: [String: GridNotification]` dict + `orderedIDs: [String]` array
- `add()` is idempotent: if ID exists, returns existing without mutation
- No upsert capability — same ID is silently ignored
- Debounced persistence via `markDirty()` -> `persistNow()` (atomic rename)
- All state mutations go through actor isolation (already atomic)

### GridNotification (struct)
- **File:** `grid-notify/Sources/GridNotify/Notification.swift`
- `id: String` (let, defaults to UUID().uuidString)
- `source: String` (let), `title: String` (let), `body: String` (var)
- `timestamp: Date` (let) — set at creation, never changes
- `ttl: TimeInterval` (var), `warnBefore: TimeInterval` (var)
- `lifecyclePhase(at:)` computes phase from `timestamp + ttl`
- No `groupCount` or equivalent field exists
- `timestamp` is immutable (`let`) — TTL reset needs a different approach

### NotificationFileWatcher
- **File:** `grid-notify/Sources/GridNotify/NotificationFileWatcher.swift`
- `NotificationLineDescriptor` (private struct): `title`, `body?`, `priority?`, `action?`, `ttl?`, `warn_before?`
- No `id` field in the descriptor — every parsed line creates a new UUID
- `processLine()` creates a `GridNotification` with default UUID, calls `store.add()`
- Need to add `id` field to descriptor and route to upsert when present

### NotificationPanelViews
- **File:** `grid-notify/Sources/GridNotify/NotificationPanelViews.swift`
- `NotificationItemView` renders title via `titleView` computed property
- Title display has three modes: MatrixText (arrival), WaveText (unread), plain Text (read)
- No group count display anywhere — need to add "(N)" suffix when groupCount > 1

### NotificationPanelViewModel
- **File:** `grid-notify/Sources/GridNotify/NotificationPanelViewModel.swift`
- `processLifecycle()` checks `notification.lifecyclePhase()` for expiry
- TTL lifecycle is based on `timestamp` — if timestamp is immutable, TTL reset must use a separate field

### Existing Tests
- **File:** `grid-notify/Tests/GridNotifyTests/NotificationStoreTests.swift`
- 5 passing tests: add+get, dismiss, persist+reload, pin sort, filter search
- All use `NotificationStore(storePath:)` test initializer with temp paths

## Key Design Observations

### TTL Reset Challenge
`timestamp` is a `let` property. The TTL lifecycle computes `age = now - timestamp` and checks `age >= ttl`. To "reset TTL" on upsert, two options:
1. Make `timestamp` mutable (var) and update it on upsert — changes the semantic of timestamp
2. Add a separate `ttlResetDate: Date` field that overrides timestamp for lifecycle calculation

Option 2 is cleaner: the original timestamp stays as "first created", while `ttlResetDate` tracks when TTL was last refreshed. The `lifecyclePhase()` and `secondsRemaining()` methods use `ttlResetDate` instead of `timestamp` when it's set.

### Upsert Atomicity
Since `NotificationStore` is an actor, a single `upsert()` method that checks existence and updates in-place is naturally atomic — no concurrent access can interleave.

### Backward Compatibility
If `id` is absent from pipe JSON, the watcher generates a UUID as before. Only payloads with explicit `id` get upsert behavior.

## Gaps to Fill
1. Add `groupCount: Int` field to `GridNotification` (default 1)
2. Add `ttlResetDate: Date?` field to `GridNotification` for TTL refresh
3. Add `upsert()` method to `NotificationStore`
4. Add `id` field to `NotificationLineDescriptor`
5. Route `processLine()` to upsert vs add based on presence of `id`
6. Show group count in `NotificationItemView` title row
7. Add 3-5 unit tests for upsert behavior
