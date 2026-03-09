# Phase 1 Discovery: Picker UI in Server + Window Source

## Existing Picker Code (GridPicker/main.swift — 1,969 lines)

### Types to Port
| Type | Kind | Lines | Notes |
|------|------|-------|-------|
| `PickerItem` | struct (Codable) | 40-144 | id, title, subtitle, preview, icon, searchable, metadata, priority |
| `IconRenderer` | class | 146-386 | Static cache, bundle:/emoji/file/data/SVG rendering |
| `MatchResult` | struct | 390-398 | item + score + matchedIndices |
| `FuzzyMatcher` | enum | 403-598 | Weighted field scoring, smart case, separator normalization |
| `PickerState` | class | 602-781 | Observable state, query/filter/selection/scroll |
| `ListItemView` | class (NSView) | 785-948 | Card-based item rendering with match highlighting |
| `ListView` | class (NSView) | 952-1026 | Container for visible items, variable height |
| `PickerConfig` | struct | 1030-1078 | CLI arg parsing (not needed in server) |
| `PickerResult` | enum | 1107-1176 | submitted/selected/cancelled + JSON output |
| `Colors` | struct | 1198-1215 | Ghostty-inspired dark theme constants |
| `Fonts` | enum | 1219-1227 | BerkeleyMono Nerd Font fallback to system mono |
| `PickerWindow` | class (NSWindow) | 1231-1556 | Borderless floating window, text field, key handling |
| `NSLabel` | class (NSTextField) | 1560-1572 | Simple non-editable label helper |
| `BackgroundView` | class (NSView) | 1576-1601 | Rounded rect bg with border stroke |
| `SocketListener` | class | 1606-1752 | Unix socket daemon (NOT needed) |
| `AppDelegate` | class | 1781-1886 | NSApp lifecycle (NOT needed) |

### What to Skip
- SocketListener, PID file management, daemon mode — replaced by PickerManager
- AppDelegate — server already has its own lifecycle
- PickerConfig CLI parsing — config comes from server
- stdin reading — no stdin in server process

## Server Integration Points

### BFD Hotkey Flow
```
BFDKeyHandler.handleEvent() → matches hotkey
  → onHotkeyTriggered?(spec, def)
    → BFDManager.init sets: keyHandler.onHotkeyTriggered = { self.executor.executeAsync(hotkey:command:) }
      → BFDExecutor.executeAsync() runs shell command on global queue
```

**For @pick:** Intercept in BFDManager.onHotkeyTriggered callback. If command starts with `@`, route directly instead of going through BFDExecutor.

### SimpleBorderManager Pattern (Template)
- Main-thread-only class (uses `dispatchPrecondition(condition: .onQueue(.main))`)
- NOT an actor — uses DispatchQueue.main.async for thread safety
- Owns NSWindow instances (BorderWindow)
- Reentrancy guard pattern: `guard !isUpdating else { return }`

### Server Startup (main.swift)
```swift
NSApplication.shared.setActivationPolicy(.prohibited)  // line 92
let connectionID = SLSMainConnectionID()
let simpleBorderManager = SimpleBorderManager(connectionID: connectionID)
let bfdManager = BFDManager()
```

### Activation Policy
- Server runs as `.prohibited` (no Dock icon, no menu bar)
- Picker needs `.regular` while visible (to receive key events)
- Must switch back to `.prohibited` after hide

## StateManager Window Data

### Access Pattern
```swift
let state = await StateManager.shared.getState()
// state.windows: [String: WindowState] — keyed by windowID string
```

### WindowState Properties
- `id: UInt32` — CGWindowID
- `pid: pid_t`
- `title: String`
- `appName: String`
- `bundleID: String?`
- `frame: CGRect?`
- `isHidden: Bool`
- `displayUUID: String?`
- `zOrder: Int?`

### Cell Assignments
Cell assignments live in SimpleBorderManager (IPC from CLI), not StateManager.
For Phase 1, WindowSource should show ALL windows (not just cell-assigned), filtered by visibility.

## WindowManipulator Focus

```swift
// Direct focus (synchronous)
func focusWindow(pid: pid_t, windowID: UInt32) -> Bool

// Context-based (async, updates state)
func focusWindow(context: ManipulationContext) async -> Bool
```

Uses yabai-style PSN + event synthesis + AXRaise for reliable same-app window focus.

## Naming Conflicts

| Name | Conflict? | Resolution |
|------|-----------|------------|
| Colors | YES (GridTerminal) | Rename to `PickerColors` |
| BackgroundView | YES (GridTerminal) | Rename to `PickerBackgroundView` |
| Fonts | Potential | Rename to `PickerFonts` |
| NSLabel | None in GridServer | Keep as-is |
| ListView | None | Rename to `PickerListView` for clarity |
| All others | None | Keep as-is |

## Key Architecture Decisions

1. **PickerManager** — singleton class on main thread (not actor), follows SimpleBorderManager pattern
2. **PickerWindow** — created once, reused across show/hide cycles (reset state on each show)
3. **PickerState** — new `appendItems()` method for async streaming (dedup by ID, re-filter, preserve selection)
4. **WindowSource** — reads directly from StateManager (no RPC), returns PickerItems with `bundle:{bundleID}` icons
5. **BFD @pick** — intercepted in BFDManager before reaching BFDExecutor
6. **Activation policy** — `.regular` on show, `.prohibited` on hide, with grace period for windowDidResignKey
