# Pseudocode: Animation Engine Phase 2 - Text + Spatial Animations

## File 1: TextSpatialAnimations.swift (NEW)

All 8 new effects: Views, ViewModifiers, and AnimationEffect structs.

### Private helpers

```
// Re-declare spacing/font helpers matching NotificationAnimations.swift pattern
private enum TSSpace { xs=4, sm=6, md=8 }
private enum TSTypeSize { body=16, meta=12 }
private func berkeleyMono(size, weight) -> Font { same pattern as existing }
```

### DW-2.1: GlitchText (View)

```
// Randomly replaces characters with glitch glyphs on an interval.
// Unlike MatrixText which resolves, glitch is ongoing while active.

struct GlitchText: View
  inputs: text, font, color, intensity (Double 0-1, fraction of chars to glitch per tick)
  @State displayChars: [Character]  // current displayed characters
  @State timer: Timer?

  body:
    Text(String(displayChars))
      .font(font)
      .foregroundColor(color)
      .onAppear { startGlitch() }
      .onDisappear { timer?.invalidate() }

  startGlitch():
    displayChars = Array(text)
    // Glitch pool: box-drawing, block elements for terminal aesthetic
    glyphPool = "!@#$%^&*<>{}[]|/\\~`" + Unicode block chars
    interval = 0.08  // ~12fps
    timer = Timer.scheduledTimer(interval, repeats: true):
      for each index in text:
        if random() < intensity:
          displayChars[index] = glyphPool.randomElement()
        else:
          displayChars[index] = text[index]  // restore original
```

### DW-2.2: RedactText (View)

```
// Text starts as block characters (full blocks), then reveals char by char.
// Similar to MatrixText but starts from blocks, not random glyphs.
// Runs once on appear, then shows final text.

struct RedactText: View
  inputs: text, font, color, duration (TimeInterval)
  @State displayChars: [Character]
  @State revealed: [Bool]
  @State timer: Timer?

  body:
    Text(String(displayChars))
      .font(font)
      .foregroundColor(color)
      .onAppear { startReveal() }
      .onDisappear { timer?.invalidate() }

  startReveal():
    chars = Array(text)
    if chars.isEmpty: return
    // Start all as full block character U+2588
    displayChars = Array(repeating: "\u{2588}", count: chars.count)
    revealed = Array(repeating: false, count: chars.count)
    // Each char reveals at staggered random time within duration
    revealTimes = chars.indices.map { i in
      Double.random(in: Double(i)/Double(chars.count) * duration ... duration)
    }
    startTime = Date()
    interval = 0.04  // ~25fps
    timer = Timer.scheduledTimer(interval, repeats: true):
      elapsed = now - startTime
      allDone = true
      for i in chars.indices:
        if revealed[i]: continue
        if elapsed >= revealTimes[i]:
          displayChars[i] = chars[i]
          revealed[i] = true
        else:
          allDone = false
      if allDone: timer.invalidate()
```

### DW-2.3: TypingIndicatorView (View)

```
// Shows animated "..." dots that cycle, then transitions to real content.
// The dots phase lasts ~1.5s, then content fades in.

struct TypingIndicatorView: View
  inputs: content (the real View to show after), theme
  @State showContent: Bool = false
  @State dotCount: Int = 1
  @State dotTimer: Timer?

  body:
    if showContent:
      content
        .transition(.opacity)
    else:
      // Show cycling dots
      Text(String(repeating: ".", count: dotCount))
        .font(berkeleyMono(size: TSTypeSize.body))
        .foregroundColor(theme.textTertiary)
        .onAppear { startDots() }

  startDots():
    // Cycle dots 1..3 repeatedly
    dotTimer = Timer.scheduledTimer(0.3, repeats: true):
      dotCount = (dotCount % 3) + 1

    // After 1.5s, show real content
    DispatchQueue.main.asyncAfter(1.5):
      dotTimer?.invalidate()
      withAnimation(.easeIn(duration: 0.2)):
        showContent = true
```

Note: TypingIndicator is simpler as a wrapper that takes a body string and theme, rather than a generic View wrapper. This avoids SwiftUI type-checker complexity.

```
// Simplified: just replaces body text
struct TypingIndicatorText: View
  inputs: text, font, color, theme
  @State showText: Bool = false
  @State dotCount: Int = 1
  @State dotTimer: Timer?

  body:
    if showText:
      Text(text)
        .font(font)
        .foregroundColor(color)
    else:
      Text(String(repeating: ".", count: dotCount))
        .font(font)
        .foregroundColor(theme.textTertiary)
        .onAppear:
          dotTimer = Timer.scheduledTimer(0.3, repeats: true):
            dotCount = (dotCount % 3) + 1
          DispatchQueue.main.asyncAfter(1.5):
            dotTimer?.invalidate()
            dotTimer = nil
            withAnimation(.easeIn(duration: 0.2)):
              showText = true
        .onDisappear:
          dotTimer?.invalidate()
```

### DW-2.4: ScanlineModifier (ViewModifier)

```
// Horizontal bright line sweeps across the notification row.
// A thin horizontal Rectangle overlay that moves top-to-bottom.
// Repeats while active.

struct ScanlineModifier: ViewModifier
  inputs: isActive (Bool)
  @State yOffset: CGFloat = -1  // normalized 0..1
  @State timer: Timer?

  body(content):
    content
      .overlay:
        if isActive:
          GeometryReader { geo in
            Rectangle()
              .fill(LinearGradient(
                colors: [.clear, accent.opacity(0.15), accent.opacity(0.3), accent.opacity(0.15), .clear],
                startPoint: .top, endPoint: .bottom
              ))
              .frame(height: 3)
              .offset(y: yOffset * geo.size.height)
          }
          .allowsHitTesting(false)
      .onAppear:
        if isActive: startScanline()
      .onChange(of: isActive):
        if isActive: startScanline()
        else: stopScanline()
      .onDisappear:
        timer?.invalidate()

  startScanline():
    yOffset = 0
    // Sweep takes 2 seconds
    let interval = 1.0 / 30.0
    let increment = interval / 2.0  // 2s full sweep
    timer = Timer.scheduledTimer(interval, repeats: true):
      yOffset += increment
      if yOffset > 1.0: yOffset = 0  // loop

  stopScanline():
    timer?.invalidate()
    timer = nil

extension View:
  func scanline(isActive: Bool, accentColor: Color) -> some View
```

Revised: scanline should accept accentColor from theme rather than hardcoding.

### DW-2.5: BounceModifier (ViewModifier)

```
// Spring bounce on arrival. Starts scaled down, bounces to full size.
// Uses spring animation with low damping for visible bounce.

struct BounceModifier: ViewModifier
  inputs: isActive (Bool)
  @State scale: CGFloat = 0.8

  body(content):
    content
      .scaleEffect(isActive && scale < 1.0 ? scale : 1.0)
      .onAppear:
        if isActive:
          scale = 0.8
          withAnimation(.spring(response: 0.4, dampingFraction: 0.5)):
            scale = 1.0

extension View:
  func bounce(isActive: Bool) -> some View
```

### DW-2.6: AccordionModifier (ViewModifier)

```
// Expands row from zero height to full height on arrival.
// Uses clipping + scaleEffect on Y axis.

struct AccordionModifier: ViewModifier
  inputs: isActive (Bool)
  @State expanded: Bool = false

  body(content):
    content
      .scaleEffect(y: isActive && !expanded ? 0.01 : 1.0, anchor: .top)
      .clipped()
      .opacity(isActive && !expanded ? 0 : 1)
      .onAppear:
        if isActive:
          withAnimation(.spring(response: 0.5, dampingFraction: 0.75)):
            expanded = true
        else:
          expanded = true

extension View:
  func accordion(isActive: Bool) -> some View
```

### DW-2.7: TiltModifier (ViewModifier)

```
// Subtle 3D rotation when selected. Tilts slightly on X axis.
// Animates in when selected, back to flat when deselected.

struct TiltModifier: ViewModifier
  inputs: isActive (Bool)
  // Small tilt angle in degrees
  private let tiltDegrees: Double = 2.0

  body(content):
    content
      .rotation3DEffect(
        .degrees(isActive ? tiltDegrees : 0),
        axis: (x: 1, y: 0, z: 0),
        perspective: 0.5
      )
      .animation(.easeInOut(duration: 0.25), value: isActive)

extension View:
  func tilt(isActive: Bool) -> some View
```

### DW-2.8: ParallaxModifier (ViewModifier)

```
// Title and body move at different vertical offsets based on tick.
// Creates subtle depth illusion. Title moves faster than body.
// Uses sin(tick) for smooth oscillation.

struct ParallaxModifier: ViewModifier
  inputs: isActive (Bool), tick (UInt), layer (Int: 0=title, 1=body)
  // Title offset amplitude: 1.5px, body: 0.5px
  private let amplitudes: [CGFloat] = [1.5, 0.5]

  body(content):
    let amplitude = layer < amplitudes.count ? amplitudes[layer] : 0
    content
      .offset(y: isActive ? amplitude * CGFloat(sin(Double(tick) * 0.3)) : 0)

extension View:
  func parallax(isActive: Bool, tick: UInt, layer: Int) -> some View
```

### AnimationEffect Structs

```
struct GlitchEffect: AnimationEffect { static let name = "glitch" }
struct RedactEffect: AnimationEffect { static let name = "redact" }
struct TypingIndicatorEffect: AnimationEffect { static let name = "typing_indicator" }
struct ScanlineEffect: AnimationEffect { static let name = "scanline" }
struct BounceEffect: AnimationEffect { static let name = "bounce" }
struct AccordionEffect: AnimationEffect { static let name = "accordion" }
struct TiltEffect: AnimationEffect { static let name = "tilt" }
struct ParallaxEffect: AnimationEffect { static let name = "parallax" }
```

## File 2: AnimationEngine.swift (MODIFY)

### registerBuiltins() -- add 8 new effects

```
func registerBuiltins():
  // ... existing 12 ...
  register(GlitchEffect())
  register(RedactEffect())
  register(TypingIndicatorEffect())
  register(ScanlineEffect())
  register(BounceEffect())
  register(AccordionEffect())
  register(TiltEffect())
  register(ParallaxEffect())
```

## File 3: NotificationPanelViews.swift (MODIFY)

### NotificationItemView.body -- wire new effects

Add to the modifier chain on the main HStack:

```
// After existing modifiers (.grow, .background, overlays, .borderStrobe, .shake, .fadeToGhost, .slideIn):

// Bounce on arrival
.bounce(isActive: isActive("bounce") && isArrival)

// Accordion on arrival
.accordion(isActive: isActive("accordion") && isArrival)

// Tilt on selection
.tilt(isActive: isActive("tilt") && isSelected)

// Scanline during idle/warning
.scanline(isActive: isActive("scanline"), accentColor: theme.accent)
```

### titleView -- add glitch and redact branches

```
// Existing branches: matrix_title during arrival, wave_title when unread
// Add: glitch during warning, redact during arrival (before matrix check)

@ViewBuilder
private var titleView: some View
  let titleColor = notification.isRead ? theme.textSecondary : theme.textPrimary
  if isActive("redact") && isArrival:
    RedactText(text: displayTitle, font: berkeleyMono(body), color: titleColor, duration: 1.0)
      .lineLimit(1)
  else if isActive("glitch") && (phase == .warning):
    GlitchText(text: displayTitle, font: berkeleyMono(body), color: titleColor, intensity: 0.15)
      .lineLimit(1)
  else if isActive("matrix_title") && isArrival:
    // existing MatrixText
  else if isActive("wave_title") && !notification.isRead:
    // existing WaveText
  else:
    // existing plain Text
```

### body text -- add typing indicator and parallax

```
// Body text section: add typing indicator wrapping
if !notification.body.isEmpty:
  let bodyColor = ...
  if isActive("typing_indicator") && isArrival:
    TypingIndicatorText(text: notification.body, font: ..., color: bodyColor, theme: theme)
      .lineLimit(2)
  else:
    Text(notification.body)
      .font(...)
      .foregroundColor(bodyColor)
      .lineLimit(2)
      // Parallax on body layer
      .parallax(isActive: isActive("parallax"), tick: tick, layer: 1)

// Title view gets parallax layer 0
titleView
  .parallax(isActive: isActive("parallax"), tick: tick, layer: 0)
```

## File 4: AnimationEngineTests.swift (MODIFY)

### Update registry count test

```
func testRegistryListsAllBuiltinNames():
  // Change expected count from 12 to 20
  XCTAssertEqual(names.count, 20)
  // Add assertions for new names
  XCTAssertTrue(names.contains("glitch"))
  XCTAssertTrue(names.contains("redact"))
  XCTAssertTrue(names.contains("typing_indicator"))
  XCTAssertTrue(names.contains("scanline"))
  XCTAssertTrue(names.contains("bounce"))
  XCTAssertTrue(names.contains("accordion"))
  XCTAssertTrue(names.contains("tilt"))
  XCTAssertTrue(names.contains("parallax"))
```

## DW Coverage Map

| DW ID | Effect | Where Implemented | Where Wired |
|-------|--------|-------------------|-------------|
| DW-2.1 | Glitch | GlitchText in TextSpatialAnimations.swift | titleView branch in NotificationPanelViews.swift |
| DW-2.2 | Redact | RedactText in TextSpatialAnimations.swift | titleView branch in NotificationPanelViews.swift |
| DW-2.3 | Typing indicator | TypingIndicatorText in TextSpatialAnimations.swift | body section in NotificationPanelViews.swift |
| DW-2.4 | Scanline | ScanlineModifier in TextSpatialAnimations.swift | modifier chain in NotificationPanelViews.swift |
| DW-2.5 | Bounce | BounceModifier in TextSpatialAnimations.swift | modifier chain in NotificationPanelViews.swift |
| DW-2.6 | Accordion | AccordionModifier in TextSpatialAnimations.swift | modifier chain in NotificationPanelViews.swift |
| DW-2.7 | Tilt | TiltModifier in TextSpatialAnimations.swift | modifier chain in NotificationPanelViews.swift |
| DW-2.8 | Parallax | ParallaxModifier in TextSpatialAnimations.swift | title + body in NotificationPanelViews.swift |
| DW-2.9 | All registered | AnimationEngine.swift registerBuiltins() | YAML/JSON override via existing config system |
