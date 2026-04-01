# Discovery: Phase 4 - Progress + Terminal Aesthetic Animations

## Files Found

| File | Exists | Role |
|------|--------|------|
| `grid-notify/Sources/GridNotify/AnimationEngine.swift` | YES | Protocol, registry, phase computation, 24 effects registered |
| `grid-notify/Sources/GridNotify/NotificationAnimations.swift` | YES | Phase 1 effect Views/ViewModifiers (shake, breathing, slide_in, grow, etc.) |
| `grid-notify/Sources/GridNotify/TextSpatialAnimations.swift` | YES | Phase 2 effects (glitch, redact, typing_indicator, scanline, bounce, accordion, tilt, parallax) |
| `grid-notify/Sources/GridNotify/ColorMoodAnimations.swift` | YES | Phase 3 effects (gradient_sweep, heatmap, neon_flicker, chromatic_aberration) |
| `grid-notify/Sources/GridNotify/ProgressTerminalAnimations.swift` | NO | Target: Phase 4 effects (8 new effects) |
| `grid-notify/Sources/GridNotify/NotificationPanelViews.swift` | YES | Item view that wires effects; needs Phase 4 integration |
| `grid-notify/Sources/GridNotify/AnimationConfig.swift` | YES | Config system, YAML loading, hot-reload watcher |
| `grid-notify/Sources/GridNotify/Notification.swift` | YES | GridNotification model with lifecyclePhase(), secondsRemaining() |
| `grid-notify/Sources/GridNotify/NotificationPanelViewModel.swift` | YES | ViewModel with lifecycleTick, animationConfig published properties |
| `grid-notify/Sources/GridNotify/NotificationPanelTheme.swift` | YES | Theme colors (accent, urgent, textPrimary, border, etc.) |

## Current State

### Registry (AnimationEngine.swift)
- 24 effects registered in `registerBuiltins()`: 12 Phase 1 + 8 Phase 2 + 4 Phase 3
- All effects conform to `AnimationEffect` protocol (just `static var name: String`)
- Views/ViewModifiers are separate from registry entries (lightweight structs vs actual SwiftUI views)

### Pattern Established
Each animation file follows the same structure:
1. Private spacing/type scale enums (mirrors NotificationPanelViews)
2. Private `berkeleyMono()` font helper
3. SwiftUI View or ViewModifier implementations
4. View extension convenience methods
5. Lightweight `AnimationEffect` conforming structs at bottom
6. Registration in `registerBuiltins()` in AnimationEngine.swift

### Wiring in NotificationPanelViews.swift
Effects are wired into `NotificationItemView` via:
- `isActive("effect_name")` checks against current animation phase
- ViewModifier chaining (`.bounce()`, `.tilt()`, etc.)
- `@ViewBuilder` titleView switches for text effects (glitch, redact, chromatic_aberration, etc.)
- Overlay approaches for visual effects (gradient_sweep, heatmap, neon_flicker)
- State-based animations (flashOpacity, warningPulse)

### Available Context in NotificationItemView
- `notification`: full GridNotification model (title, body, source, ttl, warnBefore, priority, isRead, isPinned, groupCount, timestamp)
- `isSelected`: Bool
- `tick`: UInt (increments every second)
- `animationConfig`: AnimationConfig
- `phase`: LifecyclePhase (.normal, .warning, .expired)
- `animPhase`: AnimationPhase (.arrival, .idle, .warning, .ghost)
- `isArrival`: Bool (< 2s old)
- `remaining`: TimeInterval? (seconds to expiry)
- `warningProgress`: Double (0.0-1.0 fraction)
- `notificationAge`: TimeInterval

### NotificationListView
- Uses `ScrollViewReader` + flipped scroll (bottom-up)
- No session-level state currently -- boot sequence will need a `@State` flag here

## Gaps to Fill

1. **ProgressTerminalAnimations.swift** -- new file with 8 effects
2. **AnimationEngine.swift** -- register 8 new effects in `registerBuiltins()`
3. **NotificationPanelViews.swift** -- wire in 8 new effects:
   - Hourglass sprite: in priorityEdge (alongside spinner)
   - Pie countdown: in time display area or as overlay
   - Heartbeat: ViewModifier on item row
   - Dissolve: text replacement before dismiss
   - Cursor blink: append blinking block to unread titles
   - Boot sequence: @State flag in NotificationListView or NotificationPanelContentView
   - Stack trace: overlay/replacement text during warning
   - ASCII border: overlay on selected row

## Edge Cases
- Boot sequence must fire only once per session (not per notification, not per panel show/hide)
- Dissolve must not interfere with other text effects (runs in ghost phase)
- Hourglass sprite needs TTL progress (0.0-1.0) to pick frame
- Cursor blink only on unread titles
- ASCII border only on selected notification
- Stack trace only during warning phase
