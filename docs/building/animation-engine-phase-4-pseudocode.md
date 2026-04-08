# Pseudocode: Phase 4 - Progress + Terminal Aesthetic Animations

## Files to Create/Modify

1. **`ProgressTerminalAnimations.swift`** -- New file: 8 effects (4 progress + 4 terminal)
2. **`AnimationEngine.swift`** -- Add 8 registrations to `registerBuiltins()`
3. **`NotificationPanelViews.swift`** -- Wire 8 effects into views

---

## ProgressTerminalAnimations.swift

### Structure (mirrors TextSpatialAnimations.swift, ColorMoodAnimations.swift)

```
import SwiftUI

// Private spacing/type scale enums (same values as other animation files)
private enum PTSpace { xs=4, sm=6, md=8 }
private enum PTTypeSize { body=16, meta=12 }
private func berkeleyMono(size, weight) -> Font { same pattern }
```

### DW-4.1: HourglassSprite

Cycles through hourglass Unicode frames based on TTL progress (0.0 = full, 1.0 = empty).
Used in the priority edge area as an alternative to the braille spinner.

```
struct HourglassSpriteView: View
  let progress: Double    // 0.0 (full TTL) to 1.0 (expired)
  let color: Color

  // 8 hourglass animation frames from full to empty
  private static let frames = ["⏳", "⌛"]
  // More granular: use block elements to show draining
  // Actually use Unicode hourglass variants + clock faces for 8-frame cycle
  private static let progressFrames = [
    "\u{23F3}",  // hourglass flowing
    "\u{231B}",  // hourglass done
  ]
  // Better: use braille patterns that suggest draining sand
  private static let sandFrames = [
    "⣾", "⣷", "⣯", "⣟", "⡿", "⢿", "⣻", "⣽"
  ]

  // Select frame based on progress:
  //   frameIndex = Int(progress * (frames.count - 1)), clamped 0..frames.count-1
  //   When progress is 0.0 -> frame 0 (full), 1.0 -> last frame (empty)

  @State private var animFrame: Int = 0
  @State private var timer: Timer?

  body:
    Text(currentFrame)
      .font(berkeleyMono(size: PTTypeSize.body, weight: .bold))
      .foregroundColor(color)
      .onAppear { startAnimation() }
      .onDisappear { timer?.invalidate() }

  // Timer cycles through frames at ~4fps (0.25s interval)
  // Progress biases which subset of frames to use
  startAnimation:
    timer = Timer(interval: 0.25, repeats: true)
      animFrame = (animFrame + 1) % sandFrames.count
```

### DW-4.2: PieCountdownView

Shows shrinking Unicode pie chart based on remaining time fraction.
Displayed inline near the countdown timer during warning phase.

```
struct PieCountdownView: View
  let progress: Double    // 1.0 = full pie, 0.0 = empty
  let color: Color

  // Unicode pie/circle characters representing fill levels
  // Use clock face characters for 12 positions, or circle segments
  private static let pieFrames = [
    "○",       // 0% - empty
    "◔",       // 25%
    "◑",       // 50%
    "◕",       // 75%
    "●",       // 100% - full
  ]

  body:
    // Map progress 0.0..1.0 to frame index
    let idx = Int(progress * Double(pieFrames.count - 1))
    let clamped = max(0, min(pieFrames.count - 1, idx))
    Text(pieFrames[clamped])
      .font(berkeleyMono(size: PTTypeSize.meta, weight: .bold))
      .foregroundColor(color)
```

### DW-4.3: HeartbeatModifier

Scales the row up 2% then back down periodically. Creates a "pulse" like a heartbeat.
Active during idle phase for unread notifications. Uses a repeating spring animation.

```
struct HeartbeatModifier: ViewModifier
  let isActive: Bool

  @State private var beating: Bool = false

  body(content):
    content
      .scaleEffect(isActive && beating ? 1.02 : 1.0)
      .animation(
        isActive ? .spring(response: 0.15, dampingFraction: 0.3)
                    .repeatForever(autoreverses: true) : .default,
        value: beating
      )
      .onAppear {
        if isActive { beating = true }
      }
      .onChange(of: isActive) { active in
        beating = active
      }

extension View:
  func heartbeat(isActive: Bool) -> some View
    modifier(HeartbeatModifier(isActive: isActive))
```

### DW-4.4: DissolveModifier

Individual characters randomly become invisible before dismiss (ghost phase).
Wraps the entire row content, overlaying a dissolving text mask.

```
struct DissolveModifier: ViewModifier
  let isActive: Bool
  // Fraction dissolved (0.0 = fully visible, 1.0 = fully dissolved)
  // Driven by ghost phase progress (secondsRemaining maps to fraction)
  let dissolveFraction: Double

  @State private var mask: [Bool] = []
  @State private var timer: Timer?

  body(content):
    content
      .opacity(isActive ? max(0, 1.0 - dissolveFraction * 0.7) : 1.0)
      .overlay {
        if isActive {
          // Random pixel-noise overlay that increases with dissolveFraction
          GeometryReader { geo in
            Canvas { context, size in
              // Draw random transparent "holes" based on dissolveFraction
              let holeCount = Int(dissolveFraction * 50)
              for _ in 0..<holeCount {
                let x = CGFloat.random(in: 0...size.width)
                let y = CGFloat.random(in: 0...size.height)
                let rect = CGRect(x: x, y: y, width: 3, height: 3)
                context.fill(Path(rect), with: .color(.black.opacity(0.8)))
              }
            }
          }
          .allowsHitTesting(false)
        }
      }
      .onAppear {
        if isActive { startDissolve() }
      }
      .onChange(of: isActive) { active in
        if active { startDissolve() }
        else { stopDissolve() }
      }
      .onDisappear { timer?.invalidate() }

  startDissolve:
    // No timer needed -- driven by dissolveFraction from outside
    // The view re-renders as dissolveFraction changes
    pass

  stopDissolve:
    timer?.invalidate()

extension View:
  func dissolve(isActive: Bool, fraction: Double) -> some View
    modifier(DissolveModifier(isActive: isActive, dissolveFraction: fraction))
```

### DW-4.5: CursorBlinkModifier

Appends a blinking block cursor at the end of unread notification titles.
Terminal aesthetic: mimics a text terminal prompt cursor.

```
struct CursorBlinkText: View
  let text: String
  let font: Font
  let color: Color

  @State private var cursorVisible: Bool = true
  @State private var timer: Timer?

  body:
    HStack(spacing: 0) {
      Text(text)
        .font(font)
        .foregroundColor(color)
      // Block cursor character, blinks at ~2Hz
      Text(cursorVisible ? "\u{2588}" : " ")
        .font(font)
        .foregroundColor(color.opacity(0.7))
    }
    .onAppear { startBlink() }
    .onDisappear { timer?.invalidate() }

  startBlink:
    // Toggle every 0.5s (1Hz blink rate, standard terminal)
    timer = Timer(interval: 0.5, repeats: true)
      cursorVisible.toggle()
```

### DW-4.6: BootSequenceView

Plays a terminal boot sequence when the notification panel first appears in a session.
Not persisted across launches. Uses @State in the list container.
Shows 4-5 lines of terminal boot text, then fades out to reveal real content.

```
struct BootSequenceOverlay: View
  @Binding var hasBooted: Bool
  let theme: NotificationPanelTheme

  @State private var visibleLines: Int = 0
  @State private var fadeOut: Bool = false
  @State private var timer: Timer?

  private static let bootLines = [
    "[grid-notify] v1.0.0",
    "loading notification engine...",
    "registering 32 animation effects...",
    "watching ~/.config/thegrid/notify.yaml",
    "ready.",
  ]

  body:
    if !hasBooted {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(0..<visibleLines, id: \.self) { i in
          Text(bootLines[i])
            .font(berkeleyMono(size: PTTypeSize.meta))
            .foregroundColor(i == visibleLines - 1 ? theme.accent : theme.textTertiary)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(PTSpace.md)
      .background(theme.background)
      .opacity(fadeOut ? 0 : 1)
      .onAppear { startBoot() }
      .onDisappear { timer?.invalidate() }
    }

  startBoot:
    // Show one line every 0.3s
    timer = Timer(interval: 0.3, repeats: true)
      if visibleLines < bootLines.count:
        visibleLines += 1
      else:
        timer?.invalidate()
        // Pause 0.5s then fade out
        DispatchQueue.main.asyncAfter(0.5):
          withAnimation(.easeOut(duration: 0.3)):
            fadeOut = true
          DispatchQueue.main.asyncAfter(0.3):
            hasBooted = true
```

### DW-4.7: StackTraceText

During warning phase, formats the notification text like a terminal error with line numbers.
Overlays the normal title/body with error-formatted text.

```
struct StackTraceText: View
  let title: String
  let body: String
  let font: Font
  let theme: NotificationPanelTheme

  body:
    VStack(alignment: .leading, spacing: 2) {
      // Error header line
      Text("ERROR: \(title)")
        .font(font.bold())
        .foregroundColor(theme.urgent)
      // Body lines with line numbers
      ForEach(bodyLines.enumerated(), id: \.offset) { idx, line in
        HStack(spacing: PTSpace.xs) {
          Text(String(format: "%3d", idx + 1))
            .font(berkeleyMono(size: PTTypeSize.meta))
            .foregroundColor(theme.textTertiary)
          Text("| \(line)")
            .font(font)
            .foregroundColor(theme.textSecondary)
        }
      }
    }

  private var bodyLines: [String]
    // Split body into lines. If single line, split on sentence boundaries.
    if body.isEmpty: return []
    let lines = body.components(separatedBy: "\n")
    if lines.count == 1:
      // Break long single line into ~40 char chunks
      return stride(0, body.count, 40).map { chunk substring }
    return lines
```

### DW-4.8: ASCIIBorderModifier

Draws box-drawing characters around the selected notification row.
Uses Unicode box-drawing: top-left corner, horizontal bar, top-right corner,
vertical bars on sides, bottom-left corner, horizontal bar, bottom-right corner.

```
struct ASCIIBorderModifier: ViewModifier
  let isActive: Bool
  let borderColor: Color

  // Box-drawing characters
  // top:    ┌───────┐
  // sides:  │       │
  // bottom: └───────┘

  body(content):
    content
      .overlay {
        if isActive {
          GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            // Top border
            HStack(spacing: 0) {
              Text("┌")
              Text(String(repeating: "─", count: charWidth(w)))
              Text("┐")
            }
            .font(berkeleyMono(size: PTTypeSize.meta))
            .foregroundColor(borderColor)
            .position(x: w/2, y: 0)

            // Bottom border
            HStack(spacing: 0) {
              Text("└")
              Text(String(repeating: "─", count: charWidth(w)))
              Text("┘")
            }
            .font(berkeleyMono(size: PTTypeSize.meta))
            .foregroundColor(borderColor)
            .position(x: w/2, y: h)

            // Left/right vertical bars
            VStack(spacing: 0) {
              ForEach(0..<charHeight(h), id: \.self) { _ in
                Text("│")
              }
            }
            .font(berkeleyMono(size: PTTypeSize.meta))
            .foregroundColor(borderColor)
            .position(x: 0, y: h/2)

            VStack(spacing: 0) {
              ForEach(0..<charHeight(h), id: \.self) { _ in
                Text("│")
              }
            }
            .font(berkeleyMono(size: PTTypeSize.meta))
            .foregroundColor(borderColor)
            .position(x: w, y: h/2)
          }
          .allowsHitTesting(false)
        }
      }
      .animation(.easeInOut(duration: 0.15), value: isActive)

  // Approximate number of characters that fit in width
  charWidth(width: CGFloat) -> Int:
    max(1, Int(width / 7))  // ~7px per monospace char at meta size

  // Approximate number of lines that fit in height
  charHeight(height: CGFloat) -> Int:
    max(1, Int(height / 14))  // ~14px per line at meta size

extension View:
  func asciiBorder(isActive: Bool, borderColor: Color) -> some View
    modifier(ASCIIBorderModifier(isActive: isActive, borderColor: borderColor))
```

### AnimationEffect Structs

```
struct HourglassSpriteEffect: AnimationEffect { static let name = "hourglass_sprite" }
struct PieCountdownEffect: AnimationEffect { static let name = "pie_countdown" }
struct HeartbeatEffect: AnimationEffect { static let name = "heartbeat" }
struct DissolveEffect: AnimationEffect { static let name = "dissolve" }
struct CursorBlinkEffect: AnimationEffect { static let name = "cursor_blink" }
struct BootSequenceEffect: AnimationEffect { static let name = "boot_sequence" }
struct StackTraceEffect: AnimationEffect { static let name = "stack_trace" }
struct ASCIIBorderEffect: AnimationEffect { static let name = "ascii_border" }
```

---

## AnimationEngine.swift

### Change: Add Phase 4 registrations to registerBuiltins()

```
// After Phase 3 comment block, add:

// Phase 4: progress + terminal animations
register(HourglassSpriteEffect())
register(PieCountdownEffect())
register(HeartbeatEffect())
register(DissolveEffect())
register(CursorBlinkEffect())
register(BootSequenceEffect())
register(StackTraceEffect())
register(ASCIIBorderEffect())
```

Update comment: "Register all built-in effects (Phase 1 + Phase 2 + Phase 3 + Phase 4)."

---

## NotificationPanelViews.swift

### Change 1: Boot sequence in NotificationListView

Add @State var hasBooted = false to NotificationListView.
Overlay BootSequenceOverlay when boot_sequence is active and !hasBooted.

```
struct NotificationListView: View
  @ObservedObject var viewModel: NotificationPanelViewModel
  @State private var hasBooted: Bool = false

  body:
    ZStack {
      // Existing ScrollViewReader content
      ScrollViewReader { ... existing ... }

      // Boot sequence overlay (plays once per session)
      if !hasBooted {
        BootSequenceOverlay(
          hasBooted: $hasBooted,
          theme: viewModel.theme
        )
      }
    }
```

### Change 2: Wire effects into NotificationItemView

#### Hourglass sprite in priorityEdge
Add case: if hourglass_sprite is active and notification has TTL with time remaining,
show HourglassSpriteView instead of spinner/symbol.

```
// In priorityEdge @ViewBuilder, add before spinner cases:
if isActive("hourglass_sprite") && notification.ttl > 0, let r = remaining {
  let progress = 1.0 - (r / notification.ttl)
  HourglassSpriteView(progress: progress, color: theme.accent)
} else if isActive("spinner") && phase == .warning {
  // existing spinner code
}
```

#### Pie countdown next to time display
In the title row HStack, after the countdown text, add pie indicator when active:

```
// In title row HStack, after countdown/time display:
if isActive("pie_countdown") && phase == .warning, let r = remaining {
  PieCountdownView(
    progress: r / notification.warnBefore,
    color: theme.urgent
  )
}
```

#### Heartbeat on item row
Chain .heartbeat() modifier on the row content:

```
// After .neonFlicker() modifier chain:
.heartbeat(isActive: isActive("heartbeat") && !notification.isRead && animPhase == .idle)
```

#### Dissolve in ghost phase
Chain .dissolve() modifier. Compute dissolve fraction from secondsRemaining:

```
// Dissolve fraction: 1.0 when 0s remaining, 0.0 when 3s remaining
let dissolveFrac: Double = {
  guard let r = remaining, r < 3.0 else { return 0 }
  return 1.0 - (r / 3.0)
}()
.dissolve(isActive: isActive("dissolve") && animPhase == .ghost, fraction: dissolveFrac)
```

#### Cursor blink on unread titles
In titleView @ViewBuilder, add cursor_blink case for unread notifications in idle phase:

```
// Before the static Text fallback at end of titleView:
} else if isActive("cursor_blink") && !notification.isRead {
  CursorBlinkText(
    text: displayTitle,
    font: berkeleyMono(size: TypeSize.body),
    color: titleColor
  )
  .lineLimit(1)
  .parallax(isActive: isActive("parallax"), tick: tick, layer: 0)
}
```

#### Stack trace during warning
In titleView or as body replacement, add stack_trace case:

```
// In body section, add stack_trace override:
if isActive("stack_trace") && phase == .warning {
  StackTraceText(
    title: notification.title,
    body: notification.body,
    font: berkeleyMono(size: TypeSize.meta),
    theme: theme
  )
} else if !notification.body.isEmpty {
  // existing body rendering
}
```

#### ASCII border on selected row
Chain .asciiBorder() modifier:

```
// After .heartbeat() modifier:
.asciiBorder(isActive: isActive("ascii_border") && isSelected, borderColor: theme.accent)
```

---

## DW Coverage Matrix

| DW | Effect | File | Location |
|----|--------|------|----------|
| DW-4.1 | hourglass_sprite | ProgressTerminalAnimations + PanelViews priorityEdge | New View + priorityEdge case |
| DW-4.2 | pie_countdown | ProgressTerminalAnimations + PanelViews title row | New View + inline in HStack |
| DW-4.3 | heartbeat | ProgressTerminalAnimations + PanelViews modifier chain | New ViewModifier + .heartbeat() |
| DW-4.4 | dissolve | ProgressTerminalAnimations + PanelViews modifier chain | New ViewModifier + .dissolve() |
| DW-4.5 | cursor_blink | ProgressTerminalAnimations + PanelViews titleView | New View + titleView case |
| DW-4.6 | boot_sequence | ProgressTerminalAnimations + PanelViews list | New View + ZStack overlay |
| DW-4.7 | stack_trace | ProgressTerminalAnimations + PanelViews body | New View + body section |
| DW-4.8 | ascii_border | ProgressTerminalAnimations + PanelViews modifier chain | New ViewModifier + .asciiBorder() |
| DW-4.9 | All 8 registered | AnimationEngine.swift registerBuiltins() | 8 register() calls |
