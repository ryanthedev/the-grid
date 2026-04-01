# Phase 3 Discovery: Color + Mood Animations

## Current State

Phase 1 established the animation engine: `AnimationEffect` protocol, `AnimationRegistry`, `AnimationConfig` (YAML presets + per-notification overrides), `AnimationConfigWatcher` (hot-reload). Phase 2 added 8 text+spatial effects. Total: 20 registered effects.

## Files Involved

| File | Role |
|------|------|
| `grid-notify/Sources/GridNotify/AnimationEngine.swift` | Protocol, registry, phase computation, `isAnimationActive()` |
| `grid-notify/Sources/GridNotify/AnimationConfig.swift` | YAML config, presets, hot-reload watcher |
| `grid-notify/Sources/GridNotify/NotificationAnimations.swift` | Phase 1 ViewModifiers + effect structs |
| `grid-notify/Sources/GridNotify/TextSpatialAnimations.swift` | Phase 2 ViewModifiers + effect structs |
| `grid-notify/Sources/GridNotify/NotificationPanelViews.swift` | `NotificationItemView` — wires modifiers to body |
| `grid-notify/Sources/GridNotify/NotificationPanelTheme.swift` | Theme colors: accent (#00BFFF), urgent (#B85C4A), background (#121212), surface (#1A1A1A) |
| `grid-notify/Sources/GridNotify/Notification.swift` | `GridNotification` model, `secondsRemaining()`, `animationOverride` |

## New File

- `grid-notify/Sources/GridNotify/ColorMoodAnimations.swift` — all 4 color/mood ViewModifiers + effect structs

## Pattern from Phase 2

Each effect follows this structure:
1. **ViewModifier or View** — the actual SwiftUI implementation with `@State`, timers, etc.
2. **View extension** — convenience `.modifier(...)` call
3. **Effect struct** — lightweight `struct FooEffect: AnimationEffect { static let name = "foo" }`
4. **Registration** — added to `registerBuiltins()` in `AnimationEngine.swift`
5. **View wiring** — applied in `NotificationItemView.body` with `isActive("foo")` checks

## Theme Colors Available

- `theme.accent` — #00BFFF (cyan)
- `theme.accentDim` — #006B8F
- `theme.urgent` — #B85C4A (muted coral)
- `theme.background` — #121212
- `theme.surface` — #1A1A1A
- `theme.border` — #252525
- `theme.textPrimary` — #BFBFBF
- `theme.textSecondary` — #949494
- `theme.textTertiary` — #7A7A7A

## AnimationContext Available

The `NotificationItemView` already has:
- `animPhase` — computed `AnimationPhase` (.arrival, .idle, .warning, .ghost)
- `isArrival` — true for first 2s
- `phase` — `LifecyclePhase` (.normal, .warning, .expired)
- `remaining` — seconds until expiry (nil if permanent)
- `warningProgress` — 0.0..1.0 fraction remaining in warning window
- `tick` — `UInt` that increments each second (from ViewModel)
- `isActive(_:)` — checks animation config for named effect
- `notification.timestamp` — creation time
- `notification.priority` — .low/.normal/.high/.urgent

## DW Items to Implement

- DW-3.1: Gradient sweep — accent color wash left-to-right on arrival
- DW-3.2: Heatmap — background color shifts based on notification age
- DW-3.3: Neon flicker — randomly dims/brightens border for urgent notifications
- DW-3.4: Chromatic aberration — RGB split offset on title text during warning
- DW-3.5: All 4 registered, respond to YAML preset + per-notification override

## Gaps

- No `ColorMoodAnimations.swift` file yet — needs to be created
- `registerBuiltins()` needs 4 new registrations
- `NotificationItemView.body` needs 4 new modifier/view applications
