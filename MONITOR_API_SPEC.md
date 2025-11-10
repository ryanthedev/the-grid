# AeroSpace Monitor Name Retrieval API Specification

**Version:** 1.0
**Date:** 2025-11-10
**Purpose:** Technical specification for monitor name retrieval, identification, and duplicate handling in AeroSpace

---

## Executive Summary

AeroSpace retrieves monitor names using **AppKit's NSScreen API** exclusively, specifically the `localizedName` property. The system does **NOT handle duplicate monitor names** and relies on spatial positioning (screen coordinates) as the primary identifier for monitors.

**Key Points:**
- Uses `NSScreen.localizedName` for display names
- Identifies monitors by screen position (`CGPoint`)
- No CoreGraphics or private APIs used for monitor identification
- No duplicate name detection or uniquification
- Names are immutable after initial capture

---

## 1. Low-Level macOS APIs Used

### Primary API: AppKit NSScreen

| Property | Type | Purpose |
|----------|------|---------|
| `NSScreen.localizedName` | `String` | User-facing display name |
| `NSScreen.screens` | `[NSScreen]` | Array of all connected displays |
| `NSScreen.isMainScreen` | `Bool` | Identifies main display |
| `NSScreen.frame` | `NSRect` | Screen position and dimensions |
| `NSScreen.visibleFrame` | `NSRect` | Visible area (minus menu bar/dock) |

**Framework:** `AppKit.framework`
**Access Pattern:** Direct property access, no caching
**Thread Safety:** Must access on `@MainActor`

### What AeroSpace Does NOT Use

- ❌ `CGDisplayCreateUUIDFromDisplayID` (CoreGraphics)
- ❌ `CGDisplayIOServicePort` (CoreGraphics)
- ❌ `IODisplayCreateInfoDictionary` (IOKit)
- ❌ Display serial numbers or hardware UUIDs
- ❌ Any private APIs for monitor identification

---

## 2. Core Implementation

### 2.1 Monitor Protocol Definition

**File:** `Sources/AppBundle/model/Monitor.swift` (Lines 18-27)

```swift
protocol Monitor: AeroAny {
    var monitorAppKitNsScreenScreensId: Int { get }  // 1-based index in NSScreen.screens
    var name: String { get }                          // From localizedName
    var rect: Rect { get }                           // Normalized screen frame
    var visibleRect: Rect { get }                    // Visible area (minus menu bar/dock)
    var width: CGFloat { get }
    var height: CGFloat { get }
    var isMain: Bool { get }                         // Main monitor flag
}
```

**Properties:**
- `monitorAppKitNsScreenScreensId`: 1-based enumeration index in `NSScreen.screens`
- `name`: Captured from `NSScreen.localizedName` at initialization
- `rect`: Screen bounds in normalized coordinates
- `visibleRect`: Available space excluding menu bar and dock
- `isMain`: Whether this is the main display (has menu bar)

### 2.2 LazyMonitor Implementation

**File:** `Sources/AppBundle/model/Monitor.swift` (Lines 29-55)

```swift
final class LazyMonitor: Monitor {
    let monitorAppKitNsScreenScreensId: Int
    let name: String        // ← Captured at initialization
    let rect: Rect
    let visibleRect: Rect
    let isMain: Bool

    init(monitorAppKitNsScreenScreensId: Int, isMain: Bool, _ screen: NSScreen) {
        self.monitorAppKitNsScreenScreensId = monitorAppKitNsScreenScreensId
        self.isMain = isMain
        self.rect = screen.frame.toRect()
        self.visibleRect = screen.visibleFrame.toRect()
        self.name = screen.localizedName  // ← LINE 41: Only place name is retrieved
    }
}
```

**Critical Details:**
- Name is captured **once** at initialization
- Name is **immutable** for the lifetime of the object
- No refresh mechanism for name updates
- Position and size also captured at initialization

### 2.3 Global Accessor Functions

**File:** `Sources/AppBundle/model/Monitor.swift` (Lines 97-111)

#### Get Main Monitor
```swift
var mainMonitor: Monitor {
    if isUnitTest { return testMonitor }
    let elem = NSScreen.screens.withIndex.singleOrNil(where: \.value.isMainScreen).orDie()
    return LazyMonitor(monitorAppKitNsScreenScreensId: elem.index + 1, isMain: true, elem.value)
}
```

#### Get All Monitors
```swift
var monitors: [Monitor] {
    isUnitTest
        ? [testMonitor]
        : NSScreen.screens.enumerated().map {
            $0.element.toMonitor(monitorAppKitNsScreenScreensId: $0.offset + 1)
          }
}
```

**Behavior:**
- **No caching** - queries `NSScreen.screens` on every call
- Returns fresh `LazyMonitor` objects each time
- 1-based indexing (`$0.offset + 1`)

#### Get Sorted Monitors
```swift
var sortedMonitors: [Monitor] {
    monitors.sortedBy([\.rect.minX, \.rect.minY])  // Left-to-right, top-to-bottom
}
```

**Sort Order:**
1. Primary: `rect.minX` (left to right)
2. Secondary: `rect.minY` (top to bottom)

### 2.4 Extension Methods

**File:** `Sources/AppBundle/model/Monitor.swift` (Lines 57-72)

```swift
extension NSScreen {
    func toMonitor(monitorAppKitNsScreenScreensId: Int) -> Monitor {
        MonitorImpl(
            monitorAppKitNsScreenScreensId: monitorAppKitNsScreenScreensId,
            name: localizedName,  // ← Uses localizedName here too
            rect: frame.toRect(),
            visibleRect: visibleFrame.toRect(),
            isMain: isMainScreen
        )
    }
}
```

---

## 3. Monitor Identification Strategy

### 3.1 Primary Identifier: Screen Position (`CGPoint`)

AeroSpace uses **spatial coordinates** (`rect.topLeftCorner`) as the true identity of monitors throughout the codebase.

**File:** `Sources/AppBundle/model/MonitorEx.swift` (Lines 16-20)

```swift
var monitorId: Int? {
    let sorted = sortedMonitors
    let origin = self.rect.topLeftCorner  // ← Position-based identity
    return sorted.firstIndex { $0.rect.topLeftCorner == origin }
}
```

**Note:** This returns 0-based index with TODO comment at line 14: `/// todo make 1-based`

### 3.2 Workspace-Monitor Binding

**File:** `Sources/AppBundle/tree/Workspace.swift`

```swift
@MainActor private var screenPointToVisibleWorkspace: [CGPoint: Workspace] = [:]
@MainActor private var visibleWorkspaceToScreenPoint: [Workspace: CGPoint] = [:]
```

**Key Points:**
- Workspaces bound to monitors by `CGPoint` position
- Survives monitor reconnection via position matching
- Uses nearest-neighbor matching when monitors reconfigure

### 3.3 Monitor Identity Hierarchy

| Priority | Identifier | Type | Uniqueness | Use Case |
|----------|-----------|------|------------|----------|
| 1 | `rect.topLeftCorner` | `CGPoint` | Unique per position | Internal tracking |
| 2 | `monitorId` | `Int` (0-based) | Unique after sort | Internal ID |
| 3 | `monitorAppKitNsScreenScreensId` | `Int` (1-based) | Unique in NSScreen array | Integration (sketchybar) |
| 4 | `name` | `String` | ⚠️ NOT unique | User-facing display |

---

## 4. Duplicate Name Handling

### 4.1 Critical Finding: NO Deduplication Logic

**AeroSpace does NOT handle duplicate monitor names in any way.**

### 4.2 Pattern Matching Behavior

**File:** `Sources/AppBundle/model/MonitorDescriptionEx.swift` (Lines 4-14)

```swift
func resolveMonitor(sortedMonitors: [Monitor]) -> Monitor? {
    return switch self {
        case .sequenceNumber(let number):
            sortedMonitors.getOrNil(atIndex: number - 1)
        case .main:
            mainMonitor
        case .pattern(_, let regex):
            sortedMonitors.first { monitor in monitor.name.contains(regex.val) }
            // ↑ Returns FIRST match only - no ambiguity checking
        case .secondary:
            sortedMonitors.takeIf { $0.count == 2 }?
                .first { $0.rect.topLeftCorner != mainMonitor.rect.topLeftCorner }
    }
}
```

**Behavior with Duplicate Names:**
- Returns **first match** in sorted order (leftmost/topmost)
- **No warnings** or error messages
- **No ambiguity detection**
- **Silent selection** of first matching monitor

### 4.3 Impact Scenarios

#### Scenario 1: Two monitors with identical names
```
Monitor 1: "Dell U2720Q" at position (0, 0)
Monitor 2: "Dell U2720Q" at position (2560, 0)

Pattern: "Dell U2720Q"
Result: Always selects Monitor 1 (leftmost)
```

#### Scenario 2: Multiple matches with regex
```
Monitor 1: "LG UltraWide" at position (0, 0)
Monitor 2: "LG Monitor" at position (3440, 0)

Pattern: "LG"
Result: Always selects Monitor 1 (first match)
```

### 4.4 Workarounds for Users

1. **Use sequence numbers**: `move-node-to-monitor 1` or `move-node-to-monitor 2`
2. **Use directional commands**: `focus left`, `focus right`
3. **Use main/secondary**: Only works with exactly 2 monitors
4. **Use more specific patterns**: If one monitor is "Dell U2720Q" and another is "Dell U2720Q (1)"

---

## 5. Monitor Matching Mechanisms

### 5.1 MonitorDescription Enum

**File:** `Sources/Common/model/MonitorDescription.swift` (Lines 1-20)

```swift
public enum MonitorDescription: Equatable, Sendable {
    case sequenceNumber(Int)        // e.g., "1", "2", "3"
    case main                       // The main display
    case secondary                  // Non-main (only valid when exactly 2 monitors)
    case pattern(String, SendableRegex<AnyRegexOutput>)  // Regex on name
}
```

### 5.2 Parsing Logic

**File:** `Sources/Common/model/MonitorDescription.swift` (Lines 37-43)

```swift
public static func parse(raw: String) throws -> MonitorDescription {
    return switch raw {
        case "main": .main
        case "secondary": .secondary
        case let raw where raw.allChars.allSatisfy(\.isNumber):
            .sequenceNumber(raw.parseInt() ?? -1)
        default:
            let regex = try Regex(raw, as: AnyRegexOutput.self)
                .ignoresCase()  // ← Case-insensitive matching
            return .pattern(raw, SendableRegex(regex))
    }
}
```

**Parsing Rules:**
1. Exact match "main" → `main` monitor
2. Exact match "secondary" → `secondary` monitor (2-monitor setups only)
3. All numeric characters → sequence number (1-based)
4. Everything else → regex pattern (case-insensitive)

### 5.3 Resolution Examples

```swift
// Sequence number
"1" → .sequenceNumber(1) → sortedMonitors[0]
"2" → .sequenceNumber(2) → sortedMonitors[1]

// Special identifiers
"main" → .main → mainMonitor
"secondary" → .secondary → non-main monitor (if exactly 2 exist)

// Pattern matching
"Dell" → .pattern("Dell", regex) → First monitor with "dell" in name (case-insensitive)
"U2720Q" → .pattern("U2720Q", regex) → First monitor matching "u2720q"
".*LG.*" → .pattern(".*LG.*", regex) → First monitor containing "LG"
```

---

## 6. Caching and Refresh Behavior

### 6.1 No Caching Strategy

**Every access** to `monitors` or `sortedMonitors` queries `NSScreen.screens` fresh:

```swift
var monitors: [Monitor] {
    // Called every time, no @State or static cache
    NSScreen.screens.enumerated().map { ... }
}
```

**Implications:**
- Monitor list always current with system state
- Performance impact minimal (NSScreen is fast)
- Hot-plug events automatically detected on next access

### 6.2 Name Refresh Limitation

**Monitor names are NOT refreshed after capture:**

```swift
final class LazyMonitor: Monitor {
    let name: String  // ← Immutable, captured at init
}
```

**Scenario:**
1. User connects "Samsung Monitor"
2. AeroSpace creates `LazyMonitor` with `name = "Samsung Monitor"`
3. User renames monitor in System Settings
4. AeroSpace still shows "Samsung Monitor" until restart

### 6.3 Monitor Configuration Changes

**File:** `Sources/AppBundle/tree/Workspace.swift` (Lines 140-143)

```swift
@MainActor
func gcMonitors() {
    if screenPointToVisibleWorkspace.count != monitors.count {
        rearrangeWorkspacesOnMonitors()  // Handles connect/disconnect
    }
}
```

**File:** `Sources/AppBundle/tree/Workspace.swift` (Lines 169-195)

```swift
private func rearrangeWorkspacesOnMonitors() {
    let monitorTopLeftPoints: [CGPoint] = sortedMonitors.map(\.rect.topLeftCorner)

    // Create mapping from old positions to new positions
    var oldPointToNewPoint: [CGPoint: CGPoint] = [:]
    for oldPoint in screenPointToVisibleWorkspace.keys {
        let newPoint = monitorTopLeftPoints
            .min(by: { euclidDistance(oldPoint, $0) < euclidDistance(oldPoint, $1) })
        oldPointToNewPoint[oldPoint] = newPoint
    }

    // Remap workspaces to new monitor positions
    // ...
}
```

**Algorithm:**
1. Detect monitor count change
2. Find nearest new position for each old position (euclidean distance)
3. Remap workspaces to new monitor positions
4. Maintains workspace-monitor associations across reconnects

---

## 7. Command Integration

### 7.1 List Monitors Command

**File:** `Sources/AppBundle/command/impl/ListMonitorsCommand.swift`

```swift
struct ListMonitorsCommand: Command {
    let args: ListMonitorsCmdArgs

    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        var result = sortedMonitors
        if let focused = args.focused.val {
            result = result.filter { $0.rect.topLeftCorner == focused.rect.topLeftCorner }
        }
        if let mouse = args.mouse.val {
            result = result.filter { $0.rect.topLeftCorner == mouse.rect.topLeftCorner }
        }
        let list = result.map { AeroObj.monitor($0) }
        return io.out(list: list, printWhenOneElement: !args.focused.val && !args.mouse.val)
    }
}
```

### 7.2 Output Format Variables

**File:** `Sources/AppBundle/command/format.swift` (Lines 133-139)

```swift
case (.monitor(let m), .monitor(let f)):
    return switch f {
        case .monitorId:
            .success(m.monitorId.map { .int($0 + 1) } ?? .string("NULL-MONITOR-ID"))
        case .monitorAppKitNsScreenScreensId:
            .success(.int(m.monitorAppKitNsScreenScreensId))
        case .monitorName:
            .success(.string(m.name))  // ← Direct output, no deduplication
        case .monitorIsMain:
            .success(.bool(m.isMain))
    }
}
```

**Available format variables** (from `docs/aerospace-list-monitors.adoc`):

| Variable | Type | Description | Unique? |
|----------|------|-------------|---------|
| `%{monitor-id}` | Int | 1-based sequential (sorted by position) | Yes |
| `%{monitor-appkit-nsscreen-screens-id}` | Int | 1-based index in NSScreen.screens | Yes |
| `%{monitor-name}` | String | Raw `localizedName` string | ⚠️ No |
| `%{monitor-is-main}` | Bool | Main display flag | No |

### 7.3 Usage Examples

```bash
# List all monitors with names
aerospace list-monitors --format '%{monitor-id}: %{monitor-name}'

# Output:
# 1: Dell U2720Q
# 2: LG UltraWide
# 3: Dell U2720Q

# List all monitors with all properties
aerospace list-monitors --format '%{monitor-id} %{monitor-appkit-nsscreen-screens-id} %{monitor-name} %{monitor-is-main}'

# Move window to monitor by sequence number (recommended with duplicates)
aerospace move-node-to-monitor 2

# Move window to monitor by name pattern (may be ambiguous)
aerospace move-node-to-monitor "LG"
```

---

## 8. API Call Flow Diagram

```
┌─────────────────────────────────────┐
│  User Command / Config Keybinding   │
└──────────────┬──────────────────────┘
               │
               ▼
┌──────────────────────────────────────┐
│  MonitorDescription.parse(raw)       │
│  - "1" → sequenceNumber(1)           │
│  - "main" → main                     │
│  - "Dell" → pattern("Dell", regex)   │
└──────────────┬───────────────────────┘
               │
               ▼
┌──────────────────────────────────────┐
│  resolveMonitor(sortedMonitors)      │
│  - Match pattern against names       │
│  - Return first match (if pattern)   │
└──────────────┬───────────────────────┘
               │
               ▼
┌──────────────────────────────────────┐
│  sortedMonitors (computed property)  │
│  - Sort by [minX, minY]              │
└──────────────┬───────────────────────┘
               │
               ▼
┌──────────────────────────────────────┐
│  monitors (computed property)        │
│  - NO CACHE - queries every time     │
└──────────────┬───────────────────────┘
               │
               ▼
┌──────────────────────────────────────┐
│  NSScreen.screens (AppKit)           │
│  - System-level display list         │
└──────────────┬───────────────────────┘
               │
               ▼
┌──────────────────────────────────────┐
│  NSScreen.localizedName (per screen) │
│  - Retrieve user-facing name         │
└──────────────┬───────────────────────┘
               │
               ▼
┌──────────────────────────────────────┐
│  LazyMonitor.init()                  │
│  - Capture name (immutable)          │
│  - Capture position & bounds         │
└──────────────┬───────────────────────┘
               │
               ▼
┌──────────────────────────────────────┐
│  Monitor object                      │
│  - Immutable name                    │
│  - Used for window operations        │
└──────────────────────────────────────┘
```

---

## 9. Known Limitations & Edge Cases

### 9.1 Duplicate Monitor Names

**Problem:** Two or more monitors with identical `localizedName` values

**Impact:**
- Pattern matching always selects first (leftmost/topmost)
- Users cannot target second monitor by name
- No error message or warning

**Workarounds:**
1. Use sequence numbers: `move-node-to-monitor 1`
2. Use directional commands: `focus right`
3. Use position-based commands
4. Users must memorize physical layout

**Affected Commands:**
- `move-node-to-monitor <pattern>`
- `workspace --monitor <pattern>`
- Any command accepting monitor description with pattern

### 9.2 Monitor Name Refresh

**Problem:** Monitor names not updated after initial capture

**Scenario:**
1. Monitor connected with name "Samsung S27"
2. User renames in System Settings to "Left Monitor"
3. AeroSpace still shows "Samsung S27"

**Workarounds:**
- Restart AeroSpace
- Reload configuration (may not help if monitors already initialized)

**Root Cause:** `LazyMonitor.name` is immutable, captured once at initialization

### 9.3 Monitor Detection Timing

**Problem:** Monitor configuration changes during operation

**Handled Cases:**
- Hot-plug (connect/disconnect): ✅ Detected via `gcMonitors()`
- Resolution change: ✅ New `Monitor` objects created
- Position change: ✅ Workspaces remapped by nearest neighbor

**Edge Cases:**
- Rapid connect/disconnect cycles may confuse workspace mapping
- Monitors at identical positions (impossible in practice)

### 9.4 Secondary Monitor Limitation

**Problem:** `secondary` descriptor only works with exactly 2 monitors

**File:** `Sources/AppBundle/model/MonitorDescriptionEx.swift` (Lines 12-13)

```swift
case .secondary:
    sortedMonitors.takeIf { $0.count == 2 }?  // ← Must be exactly 2
        .first { $0.rect.topLeftCorner != mainMonitor.rect.topLeftCorner }
```

**Behavior with != 2 monitors:**
- Returns `nil` (command fails)
- No error message explaining why

### 9.5 monitorId 0-based vs 1-based Confusion

**Inconsistency:** Internal representation is 0-based, user-facing is 1-based

**File:** `Sources/AppBundle/model/MonitorEx.swift` (Line 14)
```swift
/// todo make 1-based
```

**File:** `Sources/AppBundle/command/format.swift` (Line 135)
```swift
case .monitorId: .success(m.monitorId.map { .int($0 + 1) } ?? .string("NULL-MONITOR-ID"))
```

**Impact:**
- Internal code must remember to add 1 for display
- Potential for off-by-one errors

---

## 10. Testing & Development

### 10.1 Unit Test Support

**File:** `Sources/AppBundle/model/Monitor.swift` (Lines 74-95)

```swift
private let testMonitor = MonitorImpl(
    monitorAppKitNsScreenScreensId: 1,
    name: "test-monitor-name",
    rect: Rect(
        topLeftX: 0,
        topLeftY: 0,
        width: 1920,
        height: 1080
    ),
    visibleRect: Rect(
        topLeftX: 0,
        topLeftY: 25,  // Menu bar
        width: 1920,
        height: 1055
    ),
    isMain: true
)

@TaskLocal static var isUnitTest = false
```

**Usage in tests:**
```swift
Monitor.$isUnitTest.withValue(true) {
    // Test code using testMonitor
}
```

### 10.2 Debug Commands

**Command:** `aerospace debug-windows`

**Output includes monitor information:**
- Monitor names
- Monitor positions
- Window-to-monitor associations

### 10.3 Development Tools

**Accessibility Inspector.app:**
- Cannot inspect monitor names (not Accessibility API)
- Use System Settings → Displays

**Multiple Monitor Emulation:**
- DeskPad (recommended in CLAUDE.md)
- BetterDisplay 2
- Hardware: Connect physical displays

---

## 11. Recommendations for Other Agents

### 11.1 When Implementing Monitor Features

**DO:**
- ✅ Use `rect.topLeftCorner` as primary identifier
- ✅ Query `sortedMonitors` for stable ordering
- ✅ Use sequence numbers in examples/docs
- ✅ Document that names may not be unique
- ✅ Test with duplicate monitor names
- ✅ Handle `nil` returns from `resolveMonitor`

**DON'T:**
- ❌ Assume monitor names are unique
- ❌ Cache monitor names long-term
- ❌ Use `monitorId` directly (add 1 for display)
- ❌ Rely on `monitorAppKitNsScreenScreensId` for sorting
- ❌ Use CoreGraphics APIs without understanding implications

### 11.2 For Duplicate Name Handling

If implementing deduplication:

1. **Detection:**
   ```swift
   let monitors = sortedMonitors
   let names = monitors.map(\.name)
   let duplicates = names.duplicates()  // Implement this
   ```

2. **Uniquification strategies:**
   - Append position: "Dell U2720Q (Left)", "Dell U2720Q (Right)"
   - Append sequence: "Dell U2720Q (1)", "Dell U2720Q (2)"
   - Append screen ID: "Dell U2720Q [#1]", "Dell U2720Q [#2]"

3. **Warning users:**
   ```swift
   if duplicates.isNotEmpty {
       io.err("Warning: Multiple monitors have the same name: \(duplicates)")
       io.err("Consider using sequence numbers (1, 2) instead of names")
   }
   ```

### 11.3 For Name Refresh

If implementing name refresh:

1. **Monitor name changes in NSScreen:**
   - Subscribe to NSApplication.didChangeScreenParametersNotification
   - Compare old and new monitor names
   - Update cached references

2. **Refresh LazyMonitor:**
   - Make `name` a computed property (breaks immutability)
   - Or create new `LazyMonitor` objects on refresh
   - Update all references in workspace mappings

### 11.4 For Monitor Configuration Changes

**Existing logic handles:**
- Monitor connect/disconnect
- Position changes
- Count changes

**May need enhancement for:**
- Name changes during operation
- Resolution changes affecting visible area
- Rotation changes

### 11.5 Code Integration Points

**To add monitor features, touch these files:**

1. **Monitor.swift**: Core protocol and implementation
2. **MonitorEx.swift**: Add computed properties
3. **MonitorDescription.swift**: Add new match types
4. **MonitorDescriptionEx.swift**: Add resolution logic
5. **ListMonitorsCommand.swift**: Add output formats
6. **format.swift**: Add format variables

**To handle monitor events:**

1. **Workspace.swift**: Monitor-workspace binding
2. **GlobalObserver.swift**: System event observation (if needed)
3. **server.swift**: If CLI integration needed

---

## 12. Complete File Reference

### Core Implementation
- `Sources/AppBundle/model/Monitor.swift` (Lines 1-112)
  - Monitor protocol definition (18-27)
  - LazyMonitor class (29-55)
  - NSScreen extension (57-72)
  - Global accessors (97-111)

### Extensions & Utilities
- `Sources/AppBundle/model/MonitorEx.swift` (Lines 1-31)
  - monitorId computation (16-20)
  - Monitor list filtering

### Monitor Description & Matching
- `Sources/Common/model/MonitorDescription.swift` (Lines 1-57)
  - MonitorDescription enum (1-20)
  - parse() method (37-43)

- `Sources/AppBundle/model/MonitorDescriptionEx.swift` (Lines 1-14)
  - resolveMonitor() method (4-14)

### Commands
- `Sources/AppBundle/command/impl/ListMonitorsCommand.swift`
  - list-monitors command implementation

- `Sources/AppBundle/command/format.swift` (Lines 133-139)
  - Monitor output formatting

### Workspace Integration
- `Sources/AppBundle/tree/Workspace.swift`
  - gcMonitors() (140-143)
  - rearrangeWorkspacesOnMonitors() (169-195)
  - screenPointToVisibleWorkspace mapping

### Documentation
- `docs/aerospace-list-monitors.adoc`
  - User-facing documentation
  - Format variable reference

---

## 13. API Summary Table

| Aspect | Implementation | File Reference |
|--------|---------------|----------------|
| **Primary API** | `NSScreen.localizedName` | Monitor.swift:41 |
| **Framework** | AppKit (no CoreGraphics) | - |
| **Identifier** | `CGPoint` position | MonitorEx.swift:18 |
| **Storage** | Immutable `String` | Monitor.swift:32 |
| **Caching** | None - queries NSScreen each access | Monitor.swift:100-103 |
| **Duplicate Handling** | ❌ None - returns first match | MonitorDescriptionEx.swift:10 |
| **Name Refresh** | ❌ No - captured at init only | Monitor.swift:41 |
| **Match Types** | sequence, main, secondary, pattern | MonitorDescription.swift:1-20 |
| **Pattern Type** | Case-insensitive regex | MonitorDescription.swift:39-42 |
| **Sort Order** | Left-to-right, top-to-bottom | Monitor.swift:107 |
| **Hot-plug Support** | ✅ Yes - via position remapping | Workspace.swift:169-195 |

---

## 14. Glossary

| Term | Definition |
|------|------------|
| **Monitor** | Physical display connected to the Mac |
| **localizedName** | User-facing display name from NSScreen |
| **monitorId** | 0-based sequential index after sorting (displayed as 1-based) |
| **monitorAppKitNsScreenScreensId** | 1-based index in NSScreen.screens array |
| **sortedMonitors** | Monitors sorted by position (left-to-right, top-to-bottom) |
| **mainMonitor** | Display with menu bar (NSScreen.isMainScreen) |
| **secondary** | Non-main monitor (only valid with exactly 2 monitors) |
| **pattern** | Regex matching against monitor name |
| **rect.topLeftCorner** | Primary internal identifier (CGPoint position) |
| **LazyMonitor** | Concrete implementation capturing NSScreen state |
| **MonitorDescription** | Enum representing user-specified monitor selector |

---

## 15. Conclusion

AeroSpace's monitor name retrieval is straightforward but limited:

**Strengths:**
- Simple AppKit integration
- No private APIs or SIP requirements
- Stable position-based identification
- Hot-plug support via position remapping

**Limitations:**
- No duplicate name handling
- No name refresh after initialization
- Names not guaranteed unique
- Pattern matching ambiguity not detected

**For other agents:**
- Treat monitor names as **non-unique identifiers**
- Use position (`rect.topLeftCorner`) as **source of truth**
- Provide sequence number fallback for users
- Document duplicate name limitations clearly

---

**End of Specification**
