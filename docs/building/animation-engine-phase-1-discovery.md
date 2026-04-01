# Discovery: Animation Engine Phase 1

## Current State

### Existing Animations (12 total, all in NotificationAnimations.swift)

1. **TypewriterText** (View) - Reveals text one character at a time. Used for: not currently used in item view.
2. **MatrixText** (View) - Random glyphs resolve to actual text over ~0.8s. Used in: titleView during arrival phase.
3. **MarqueeText** (View) - Horizontal scroll for overflow text. Used for: not currently used in item view.
4. **WaveText** (View) - Characters ripple with vertical offsets. Used in: titleView when unread + normal phase.
5. **ProgressBarView** (View) - ASCII `[########..]` drain bar. Used in: warning phase below body text.
6. **ShakeModifier** (ViewModifier) - Horizontal jitter from tick. Used in: warning phase on entire item row.
7. **BreathingModifier** (ViewModifier) - Opacity pulse 0.3-1.0. Used in: unread spinner in priorityEdge.
8. **SlideInModifier** (ViewModifier) - Spring slide-up on appear. Used in: arrival (isArrival check).
9. **GrowModifier** (ViewModifier) - Extra vertical padding. Used in: warning phase on item row.
10. **InvertModifier** (ViewModifier) - Swap fg/bg colors. Defined but NOT used in item view currently.
11. **BorderStrobeModifier** (ViewModifier) - Left edge color alternation. Used in: warning phase on item row.
12. **FadeToGhostModifier** (ViewModifier) - Opacity fade in last 3s. Used in: always active (checks secondsRemaining).
13. **SpriteView** (View) - Braille spinner/countdown frames. Used in: priorityEdge (unread spinner + warning countdown).

Note: SpriteView is in NotificationPanelViews.swift, not NotificationAnimations.swift.

### Current Hardcoded Conditionals in NotificationItemView

Location: `NotificationPanelViews.swift` lines 200-342

**Phase-based conditionals:**
- `phase == .warning` on line 263: Show countdown timer instead of relative time
- `phase == .warning` on line 277: Body text uses textPrimary instead of textSecondary
- `phase == .warning` on line 282-289: Show ProgressBarView
- `.grow(isActive: phase == .warning)` on line 296: Extra padding
- `phase == .warning` on line 302: Pulsing urgent overlay opacity
- `.borderStrobe(isActive: phase == .warning, ...)` on line 312-316
- `.shake(isActive: phase == .warning, tick: tick)` on line 318
- `phase == .warning` on line 338-339: Start warningPulse
- `phase == .warning` on lines 400-406: Countdown spinner in priorityEdge

**Arrival-based conditionals:**
- `isArrival` on line 359: MatrixText title
- `.slideIn(isActive: isArrival)` on line 322
- `isArrival` on line 325: Flash overlay

**Read-state conditionals:**
- `!notification.isRead` on line 367: WaveText title
- `!notification.isRead` on lines 407-414: Braille spinner with breathing

### Config System (NotifyConfig.swift)

- YAML config loaded from `$XDG_CONFIG_HOME/thegrid/notify.yaml`
- Uses Yams library for YAML parsing
- Config has: pipePath, pipeSourceLabel, maxCount, themeColors, scripts
- No animation config exists yet
- `loadNotifyConfig()` is a free function, returns NotifyConfig struct
- No hot-reload mechanism currently - config loaded once at startup in AppDelegate

### Notification JSON Input (NotificationFileWatcher)

- Per-line JSON with fields: id, title, body, priority, action, detail_cmd, ttl, warn_before
- No `animations` field exists yet
- Adding one requires: extending NotificationLineDescriptor, passing through to GridNotification

### GridNotification Model

- Has: source, ttl, warnBefore, groupCount, isRead, isPinned, lifecyclePhase(), secondsRemaining()
- LifecyclePhase is enum: .normal, .warning, .expired
- No animation-related fields exist yet
- Adding per-notification animations field requires extending the Codable model

### File Watcher Pattern (NotificationFileWatcher)

- Uses DispatchSource for file watching (readSource + fsSource)
- The fsSource watches for `.write`, `.delete`, `.rename` events
- This same pattern can be reused for config hot-reload

### ViewModel

- `NotificationPanelViewModel` has `lifecycleTick: UInt` that increments every second
- Views observe tick to update warning animations
- Theme is set at init, no hot-reload support

## Key Design Observations

1. **Two kinds of animations**: "View-replacement" animations (MatrixText, WaveText, TypewriterText replace the Text view entirely) vs "modifier" animations (ShakeModifier, GrowModifier wrap existing content).

2. **Animations are phase-specific**: Each animation activates in specific phases (arrival, normal-unread, warning, ghost). The protocol needs phase context.

3. **Some animations need notification data**: ProgressBarView needs warningProgress. FadeToGhost needs secondsRemaining. Shake needs tick. Breathing needs isActive.

4. **SpriteView is positional**: The braille spinner goes in priorityEdge, not as a modifier on the whole row. This is a content-replacement, not a ViewModifier.

5. **Flash overlay is inline state**: The flash on arrival uses @State flashOpacity inside NotificationItemView. Not a separate animation component.

6. **Warning pulse overlay is inline state**: warningPulse is @State, uses SwiftUI's repeatForever animation.

## Assumption Verification

**SwiftUI can compose 5+ ViewModifiers dynamically (MEDIUM confidence):**
Current code already chains 6 modifiers: `.grow()`, `.background()`, `.overlay()` (warning pulse), `.overlay()` (flash), `.borderStrobe()`, `.shake()`, `.fadeToGhost()`, `.slideIn()`. That's 8 modifiers. This works fine because the type-checker resolves them at compile time. The concern is about DYNAMIC composition where the number/type of modifiers varies at runtime. Using `reduce` with AnyView or a dynamic modifier list would require type erasure. However, we can use a fixed chain of modifiers where each one checks `isActive` internally (which is what the current code already does). This pattern scales fine.

**Verdict: Assumption HOLDS.** Keep the fixed-chain-with-isActive pattern. Each AnimationEffect produces a ViewModifier that checks whether it should be active based on phase/config. The chain is always the same length; effects just no-op when inactive.

## Gaps to Fill

1. **AnimationEffect protocol** - Does not exist. Need to define it with phase context and notification data.
2. **AnimationRegistry** - Does not exist. Need string name -> effect mapping.
3. **Animation YAML config** - Does not exist in notify.yaml. Need per-source animation presets.
4. **Per-notification JSON overrides** - No `animations` field on GridNotification or NotificationLineDescriptor.
5. **Hot-reload** - No file watcher on notify.yaml. Need DispatchSource on config file.
6. **AnimatedNotificationView** - Does not exist. Need wrapper that replaces hardcoded conditionals.
7. **Config watcher integration** - AppDelegate loads config once; needs to support reload callback.

## Files to Modify

- `NotificationAnimations.swift` - Add protocol, registry, migrate existing animations
- `NotificationPanelViews.swift` - Replace hardcoded conditionals with AnimatedNotificationView
- `NotifyConfig.swift` - Add animation preset config, hot-reload
- `Notification.swift` - Add animations override field to GridNotification
- `NotificationFileWatcher.swift` - Parse animations field from JSON input
- `AppDelegate.swift` - Wire up config hot-reload
- `NotificationPanelViewModel.swift` - Add animation config to view model

## Files to Create

- `AnimationEngine.swift` - AnimationEffect protocol, AnimationRegistry, AnimationContext, AnimatedNotificationView
- `AnimationConfig.swift` - YAML config model, hot-reload watcher
