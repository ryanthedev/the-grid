# Discovery: Animation Engine Phase 2 - Text + Spatial Animations

## Current State

Phase 1 is complete. The animation engine has:

### AnimationEffect Protocol (`AnimationEngine.swift`)
- `protocol AnimationEffect` with `static var name: String` requirement
- Each effect is a lightweight struct conforming to the protocol
- Effects serve as registry entries; actual View/ViewModifier implementations are separate
- `AnimationRegistry` singleton maps string names to effect instances
- `registerBuiltins()` registers all 12 Phase 1 effects
- `isAnimationActive()` checks config for whether a named effect should run for a given phase

### AnimationConfig (`AnimationConfig.swift`)
- `AnimationPreset` holds per-phase animation name lists (arrival/idle/warning/ghost)
- `AnimationConfig` resolves active animations: per-notification override > source preset > default preset
- YAML loader parses `animations:` section from `notify.yaml`
- `AnimationConfigWatcher` hot-reloads on file change
- `builtinDefault` defines default animation lists per phase

### Existing Animations (`NotificationAnimations.swift`)
- 12 effects: shake, breathing, slide_in, grow, border_strobe, fade_to_ghost, matrix_title, wave_title, progress_bar, warning_pulse, arrival_flash, spinner
- Implemented as SwiftUI Views (`MatrixText`, `WaveText`, `TypewriterText`, `MarqueeText`, `ProgressBarView`, `SpriteView`) and ViewModifiers (`ShakeModifier`, `BreathingModifier`, `SlideInModifier`, `GrowModifier`, `InvertModifier`, `BorderStrobeModifier`, `FadeToGhostModifier`)
- Helper spacing/font enums duplicated from panel views

### View Layer (`NotificationPanelViews.swift`)
- `NotificationItemView` uses `isActive("name")` to check if effects should run
- Effects are wired inline: `.shake()`, `.grow()`, `.borderStrobe()`, `.fadeToGhost()`, `.slideIn()`
- Title view branch: `MatrixText` during arrival, `WaveText` when unread, plain `Text` otherwise
- `@State` for flash opacity and warning pulse
- Theme provides colors: accent (cyan #00BFFF), urgent (coral #B85C4A), grays

### Theme (`NotificationPanelTheme.swift`)
- Monochromatic grays + cyan accent + coral urgent
- All text uses `berkeleyMono()` font helper

## What Needs to Be Built

8 new effects, each needing:
1. A SwiftUI View or ViewModifier implementation
2. An `AnimationEffect` struct for registry
3. Registration in `registerBuiltins()`
4. Wiring into `NotificationItemView.body`

### Text Effects
- **Glitch** (DW-2.1): Randomly replace characters briefly. Similar to MatrixText but ongoing, not resolving.
- **Redact** (DW-2.2): Reveal text from block characters. Inverse of dissolve -- start as blocks, resolve to real text.
- **Typing indicator** (DW-2.3): Show "..." bubbles before real content appears.
- **Scanline** (DW-2.4): Horizontal sweep across the notification row (overlay effect, not text replacement).

### Spatial Effects
- **Bounce** (DW-2.5): Spring bounce on arrival. Similar to slide_in but vertical bounce.
- **Accordion** (DW-2.6): Expand row from zero to full height on arrival.
- **Tilt** (DW-2.7): Subtle 3D rotation on selection. Uses `rotation3DEffect`.
- **Parallax** (DW-2.8): Title/body move at different scroll speeds. Offset-based, triggered by scroll position.

## Gaps and Concerns

- **Parallax needs scroll offset**: Current `NotificationListView` uses `ScrollViewReader` but doesn't expose scroll offset. May need `GeometryReader` or `PreferenceKey` to track offset. Simplification: use the tick counter to simulate subtle continuous parallax rather than actual scroll-tracking.
- **Glitch needs timer**: Ongoing random character replacement needs a timer. Pattern exists in `WaveText` and `MatrixText`.
- **Typing indicator replaces body content temporarily**: Needs a state transition from "..." to actual body. Could use `onAppear` with delay.
- **Scanline is a purely visual overlay**: Not text manipulation. Horizontal bright line sweeping across. Use `Rectangle` overlay with animated offset.
- **Tilt on selection**: Selection state is passed as `isSelected: Bool`. Effect activates when selected.
- **Accordion on arrival**: `clipped()` + animated `scaleEffect(y:)` from 0 to 1, or animated `frame(height:)`.

## Files to Modify
- **New**: `grid-notify/Sources/GridNotify/TextSpatialAnimations.swift` -- all 8 effects
- **Modify**: `grid-notify/Sources/GridNotify/AnimationEngine.swift` -- register 8 new effects in `registerBuiltins()`
- **Modify**: `grid-notify/Sources/GridNotify/NotificationPanelViews.swift` -- wire new effects into `NotificationItemView`
- **Modify**: `grid-notify/Tests/GridNotifyTests/AnimationEngineTests.swift` -- update registry count test

## Patterns to Follow
- Effect struct: `struct FooEffect: AnimationEffect { static let name = "foo" }`
- ViewModifier pattern: `struct FooModifier: ViewModifier { let isActive: Bool; ... }`
- View extension: `extension View { func foo(isActive: Bool) -> some View { ... } }`
- Timer-based animation: `@State private var timer: Timer?` with `onAppear`/`onDisappear`
- Config check: `isActive("foo")` in item view
