# Pseudocode: iMessage Notifications Phase 1 - Upsert + Grouping

## DW Coverage
- DW-1.1: Sections 1, 2, 3 (pipe id field -> upsert in store)
- DW-1.2: Section 1 (upsert replaces body, resets TTL via ttlResetDate, increments groupCount)
- DW-1.3: Section 4 (title row shows "(N)" when groupCount > 1)
- DW-1.4: Sections 2, 3 (absent id -> UUID, calls add() not upsert())

---

## Section 1: GridNotification model + NotificationStore.upsert()
**Files:** Notification.swift, NotificationStore.swift
**DW:** 1.1, 1.2

### Notification.swift changes

Add two fields to GridNotification:

```
// Number of times this notification has been upserted. Starts at 1.
var groupCount: Int = 1

// When set, TTL lifecycle uses this date instead of timestamp.
// Reset on each upsert to refresh the countdown.
var ttlResetDate: Date? = nil
```

Update lifecyclePhase(at:) and secondsRemaining(at:):
```
// Use ttlResetDate if set, otherwise fall back to timestamp
let baseDate = ttlResetDate ?? timestamp

lifecyclePhase:
  guard ttl > 0 else return .normal
  let age = now.timeIntervalSince(baseDate)  // <-- changed from timestamp
  if age >= ttl return .expired
  if warnBefore > 0 && age >= (ttl - warnBefore) return .warning
  return .normal

secondsRemaining:
  guard ttl > 0 else return nil
  let baseDate = ttlResetDate ?? timestamp
  return max(0, ttl - now.timeIntervalSince(baseDate))  // <-- changed from timestamp
```

Init: add groupCount and ttlResetDate parameters with defaults (1 and nil).

### NotificationStore.swift changes

Add upsert method:
```
// Upserts a notification by id.
// If id exists in byID: update body, ttl, warnBefore, action, priority;
//   set ttlResetDate = now; increment groupCount; clear isDismissed + isRead.
// If id does not exist: insert as new (like add()).
// Returns the resulting notification.
func upsert(_ notification: GridNotification) -> GridNotification:
  if var existing = byID[notification.id]:
    // Update mutable fields from the incoming notification
    existing.body = notification.body
    existing.ttl = notification.ttl
    existing.warnBefore = notification.warnBefore
    existing.action = notification.action
    existing.priority = notification.priority
    // Reset TTL countdown
    existing.ttlResetDate = Date()
    // Bump group count
    existing.groupCount += 1
    // Un-dismiss and un-read so it surfaces again
    existing.isDismissed = false
    existing.isRead = false
    // Write back
    byID[notification.id] = existing
    markDirty()
    return existing
  else:
    // New notification — delegate to add()
    return add(notification)
```

---

## Section 2: NotificationLineDescriptor id field
**File:** NotificationFileWatcher.swift
**DW:** 1.1, 1.4

Add optional `id` field to NotificationLineDescriptor:
```
struct NotificationLineDescriptor: Codable {
    let id: String?       // <-- NEW: explicit notification ID for upsert
    let title: String
    let body: String?
    let priority: String?
    let action: [String: String]?
    let ttl: TimeInterval?
    let warn_before: TimeInterval?
}
```

---

## Section 3: processLine() routing to upsert vs add
**File:** NotificationFileWatcher.swift
**DW:** 1.1, 1.4

In processLine(), after parsing the descriptor:
```
// If descriptor has an explicit id, use it; otherwise generate UUID
let notificationID = desc.id ?? UUID().uuidString

let notification = GridNotification(
    id: notificationID,
    source: config.sourceLabel,
    title: desc.title,
    body: desc.body ?? "",
    priority: ...,
    action: action,
    ttl: desc.ttl ?? 0,
    warnBefore: desc.warn_before ?? 0
)

// If explicit id was provided, use upsert (updates existing or inserts new).
// If no explicit id, use add (always inserts with generated UUID).
if desc.id != nil:
    Task { await store.upsert(notification); MainActor callback }
else:
    Task { await store.add(notification); MainActor callback }
```

---

## Section 4: Group count display in NotificationItemView
**File:** NotificationPanelViews.swift
**DW:** 1.3

In the title row of NotificationItemView, after the title text, show group count when > 1:

Modify the three title display branches (MatrixText, WaveText, plain Text) to append " (N)" to the title string when groupCount > 1.

```
// Computed property for display title
private var displayTitle: String {
    if notification.groupCount > 1 {
        return "\(notification.title) (\(notification.groupCount))"
    }
    return notification.title
}
```

Replace `notification.title` with `displayTitle` in:
- MatrixText text parameter
- WaveText text parameter
- Text() content

---

## Section 5: Tests
**File:** Tests/GridNotifyTests/NotificationStoreTests.swift

Test 1: testUpsertUpdatesExisting
```
store.add(notification with id "upsert-1", title "Sarah", body "hello", ttl 60)
store.upsert(notification with id "upsert-1", title "Sarah", body "hey there", ttl 60)
get(id: "upsert-1")
assert body == "hey there"
assert groupCount == 2
assert count() == 1  (not 2)
```

Test 2: testUpsertResetsTTL
```
store.add(notification with id "ttl-1", title "Sarah", body "hi", ttl 60)
// sleep briefly or just check ttlResetDate is set after upsert
store.upsert(notification with id "ttl-1", title "Sarah", body "hello again", ttl 60)
get(id: "ttl-1")
assert ttlResetDate != nil
```

Test 3: testUpsertInsertsWhenNew
```
store.upsert(notification with id "new-1", title "Alice", body "first")
get(id: "new-1")
assert title == "Alice"
assert groupCount == 1
assert count() == 1
```

Test 4: testUpsertClearsDismissed
```
store.add(notification with id "dismiss-1", title "Bob", body "hey")
store.dismiss(id: "dismiss-1")
assert active count == 0
store.upsert(notification with id "dismiss-1", title "Bob", body "still here")
assert active count == 1
get(id: "dismiss-1") -> isDismissed == false
```

Test 5: testNoIdUsesAddNotUpsert (backward compat)
```
// This is an integration-level test — but since processLine is private,
// we test the store behavior: add() with same content but different UUIDs
// creates separate entries.
store.add(notification with id UUID1, title "test", body "a")
store.add(notification with id UUID2, title "test", body "b")
assert count() == 2
```
