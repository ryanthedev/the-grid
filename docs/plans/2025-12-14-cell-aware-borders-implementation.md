# Cell-Aware Borders Implementation Plan

> **Refined:** 2025-12-15 - Added Phase 4 (IPC Protocol), dynamic corner radius, event coalescing
> **Updated:** 2025-12-15 - ALL TASKS COMPLETED. Border system is fully integrated.
> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add cell-aware window borders to grid-server with three-tier focus coloring (active window → active cell → inactive).

**Architecture:** Borders are rendered as transparent overlay windows using SkyLight APIs. BorderManager maintains a map of target windows to border overlays and updates them in response to AX events from ApplicationObserver. Color resolution uses hybrid config: per-cell overrides → palette → global defaults.

**Key additions:**
- CLI pushes cell assignments to server via `borders.setCellAssignments` message
- CLI sends config to server via `borders.configure` message
- Dynamic corner radius detection via `SLSWindowIteratorGetCornerRadii`
- Event coalescing (20ms debounce) for smooth window drags
- Transaction batching for atomic multi-border focus updates

**Tech Stack:** Swift, SkyLight (private framework), Core Graphics, existing grid-server infrastructure.

---

## Implementation Status

| Task | Description | Status |
|------|-------------|--------|
| 1 | SkyLight Window APIs in MacOSAPIs.swift | ✅ DONE |
| 1b | Dynamic corner radius API | ✅ DONE |
| 2 | BorderConfig.swift | ✅ DONE |
| 3 | BorderRenderer.swift | ✅ DONE |
| 4 | BorderWindow.swift | ✅ DONE |
| 5 | BorderManager.swift | ✅ DONE |
| 6 | IPC handlers in MessageHandler.swift | ✅ DONE |
| 7 | CLI client borders.go | ✅ DONE |
| 8 | BorderEvents.swift | ✅ DONE |
| 9 | StateManager integration | ✅ DONE |
| 10 | main.swift initialization | ✅ DONE |
| 11 | Add Borders to root Config struct | ✅ DONE |
| 12 | CLI sends border config on startup | ✅ DONE |
| 13 | CLI sends cell assignments after layout apply | ✅ DONE |

**What works now:**
- Server starts and creates borders for all windows
- Borders respond to focus changes, window moves/resizes, minimize/restore
- Server accepts `borders.configure` and `borders.setCellAssignments` IPC messages
- Go client has `SendBorderConfig()` and `SendCellAssignments()` functions
- CLI reads `borders:` section from config.yaml
- CLI sends border config and cell assignments on every layout apply
- Three-tier focus coloring: active window → active cell → inactive

---

## Phase 1: SkyLight Window Creation APIs

### Task 1: Add SkyLight Window APIs to MacOSAPIs.swift

**Files:**
- Modify: `grid-server/Sources/GridServer/MacOSAPIs.swift`

**Step 1: Add type definitions for window creation**

Add after line 48 (after existing typedefs):

```swift
// Window creation and manipulation
typealias SLSNewWindow_t = @convention(c) (Int32, Int32, CGFloat, CGFloat, UnsafePointer<CGRect>, UnsafeMutablePointer<UInt32>) -> CGError
typealias SLSReleaseWindow_t = @convention(c) (Int32, UInt32) -> CGError
typealias SLSSetWindowTags_t = @convention(c) (Int32, UInt32, UnsafeMutablePointer<UInt64>, Int32) -> CGError
typealias SLSClearWindowTags_t = @convention(c) (Int32, UInt32, UnsafeMutablePointer<UInt64>, Int32) -> CGError
typealias SLSSetWindowShape_t = @convention(c) (Int32, UInt32, CGFloat, CGFloat, UnsafePointer<CGRect>) -> CGError
typealias SLSSetWindowOpacity_t = @convention(c) (Int32, UInt32, Bool) -> CGError
typealias SLSSetWindowAlpha_t = @convention(c) (Int32, UInt32, Float) -> CGError
typealias SLSOrderWindow_t = @convention(c) (Int32, UInt32, Int32, UInt32) -> CGError
typealias SLSSetWindowLevel_t = @convention(c) (Int32, UInt32, Int32) -> CGError
typealias SLSMoveWindow_t = @convention(c) (Int32, UInt32, UnsafePointer<CGPoint>) -> CGError
typealias SLWindowContextCreate_t = @convention(c) (Int32, UInt32, UnsafeMutableRawPointer?) -> CGContext?
typealias SLSFlushWindowContentRegion_t = @convention(c) (Int32, UInt32, UnsafeRawPointer?) -> CGError

// Transaction API for atomic updates
typealias SLSTransactionCreate_t = @convention(c) (Int32) -> CFTypeRef?
typealias SLSTransactionCommit_t = @convention(c) (CFTypeRef, Int32) -> CGError
typealias SLSTransactionOrderWindow_t = @convention(c) (CFTypeRef, UInt32, Int32, UInt32) -> Void
typealias SLSTransactionSetWindowLevel_t = @convention(c) (CFTypeRef, UInt32, Int32) -> Void
```

**Step 2: Load the symbols**

Add after line 90 (after existing symbol loads):

```swift
// Window creation APIs
private let _SLSNewWindow: SLSNewWindow_t? = loadSymbol("SLSNewWindow")
private let _SLSReleaseWindow: SLSReleaseWindow_t? = loadSymbol("SLSReleaseWindow")
private let _SLSSetWindowTags: SLSSetWindowTags_t? = loadSymbol("SLSSetWindowTags")
private let _SLSClearWindowTags: SLSClearWindowTags_t? = loadSymbol("SLSClearWindowTags")
private let _SLSSetWindowShape: SLSSetWindowShape_t? = loadSymbol("SLSSetWindowShape")
private let _SLSSetWindowOpacity: SLSSetWindowOpacity_t? = loadSymbol("SLSSetWindowOpacity")
private let _SLSSetWindowAlpha: SLSSetWindowAlpha_t? = loadSymbol("SLSSetWindowAlpha")
private let _SLSOrderWindow: SLSOrderWindow_t? = loadSymbol("SLSOrderWindow")
private let _SLSSetWindowLevel: SLSSetWindowLevel_t? = loadSymbol("SLSSetWindowLevel")
private let _SLSMoveWindow: SLSMoveWindow_t? = loadSymbol("SLSMoveWindow")
private let _SLWindowContextCreate: SLWindowContextCreate_t? = loadSymbol("SLWindowContextCreate")
private let _SLSFlushWindowContentRegion: SLSFlushWindowContentRegion_t? = loadSymbol("SLSFlushWindowContentRegion")
private let _SLSTransactionCreate: SLSTransactionCreate_t? = loadSymbol("SLSTransactionCreate")
private let _SLSTransactionCommit: SLSTransactionCommit_t? = loadSymbol("SLSTransactionCommit")
private let _SLSTransactionOrderWindow: SLSTransactionOrderWindow_t? = loadSymbol("SLSTransactionOrderWindow")
private let _SLSTransactionSetWindowLevel: SLSTransactionSetWindowLevel_t? = loadSymbol("SLSTransactionSetWindowLevel")
```

**Step 3: Add wrapper functions**

Add after line 210 (after existing wrappers):

```swift
// MARK: - Window Creation API Wrappers

func SLSNewWindow(_ cid: Int32, _ backing: Int32, _ x: CGFloat, _ y: CGFloat, _ region: UnsafePointer<CGRect>, _ wid: UnsafeMutablePointer<UInt32>) -> CGError {
    return _SLSNewWindow?(cid, backing, x, y, region, wid) ?? .failure
}

func SLSReleaseWindow(_ cid: Int32, _ wid: UInt32) -> CGError {
    return _SLSReleaseWindow?(cid, wid) ?? .failure
}

func SLSSetWindowTags(_ cid: Int32, _ wid: UInt32, _ tags: UnsafeMutablePointer<UInt64>, _ tagSize: Int32) -> CGError {
    return _SLSSetWindowTags?(cid, wid, tags, tagSize) ?? .failure
}

func SLSClearWindowTags(_ cid: Int32, _ wid: UInt32, _ tags: UnsafeMutablePointer<UInt64>, _ tagSize: Int32) -> CGError {
    return _SLSClearWindowTags?(cid, wid, tags, tagSize) ?? .failure
}

func SLSSetWindowShape(_ cid: Int32, _ wid: UInt32, _ x: CGFloat, _ y: CGFloat, _ region: UnsafePointer<CGRect>) -> CGError {
    return _SLSSetWindowShape?(cid, wid, x, y, region) ?? .failure
}

func SLSSetWindowOpacity(_ cid: Int32, _ wid: UInt32, _ opaque: Bool) -> CGError {
    return _SLSSetWindowOpacity?(cid, wid, opaque) ?? .failure
}

func SLSSetWindowAlpha(_ cid: Int32, _ wid: UInt32, _ alpha: Float) -> CGError {
    return _SLSSetWindowAlpha?(cid, wid, alpha) ?? .failure
}

func SLSOrderWindow(_ cid: Int32, _ wid: UInt32, _ order: Int32, _ relativeWid: UInt32) -> CGError {
    return _SLSOrderWindow?(cid, wid, order, relativeWid) ?? .failure
}

func SLSSetWindowLevel(_ cid: Int32, _ wid: UInt32, _ level: Int32) -> CGError {
    return _SLSSetWindowLevel?(cid, wid, level) ?? .failure
}

func SLSMoveWindow(_ cid: Int32, _ wid: UInt32, _ point: UnsafePointer<CGPoint>) -> CGError {
    return _SLSMoveWindow?(cid, wid, point) ?? .failure
}

func SLWindowContextCreate(_ cid: Int32, _ wid: UInt32, _ options: UnsafeMutableRawPointer?) -> CGContext? {
    return _SLWindowContextCreate?(cid, wid, options)
}

func SLSFlushWindowContentRegion(_ cid: Int32, _ wid: UInt32, _ region: UnsafeRawPointer?) -> CGError {
    return _SLSFlushWindowContentRegion?(cid, wid, region) ?? .failure
}

func SLSTransactionCreate(_ cid: Int32) -> CFTypeRef? {
    return _SLSTransactionCreate?(cid)
}

func SLSTransactionCommit(_ transaction: CFTypeRef, _ sync: Int32) -> CGError {
    return _SLSTransactionCommit?(transaction, sync) ?? .failure
}

func SLSTransactionOrderWindow(_ transaction: CFTypeRef, _ wid: UInt32, _ order: Int32, _ relativeWid: UInt32) {
    _SLSTransactionOrderWindow?(transaction, wid, order, relativeWid)
}

func SLSTransactionSetWindowLevel(_ transaction: CFTypeRef, _ wid: UInt32, _ level: Int32) {
    _SLSTransactionSetWindowLevel?(transaction, wid, level)
}

// MARK: - Window Tag Constants

/// Window tag bits (from JankyBorders)
struct WindowTags {
    static let sticky: UInt64 = (1 << 11)           // Visible on all spaces
    static let floating: UInt64 = (1 << 1) | (1 << 9)  // Floating window
    static let noShadow: UInt64 = (1 << 3)          // No shadow
}
```

**Step 4: Build and verify**

Run: `cd /Users/r/repos/theGrid/grid-server && swift build 2>&1 | head -20`
Expected: Build succeeds with no errors related to MacOSAPIs.swift

**Step 5: Commit**

```bash
git add grid-server/Sources/GridServer/MacOSAPIs.swift
git commit -m "feat(borders): add SkyLight window creation APIs"
```

---

### Task 1b: Add SLSWindowIteratorGetCornerRadii for Dynamic Radius

**Files:**
- Modify: `grid-server/Sources/GridServer/MacOSAPIs.swift`

**Step 1: Add type definition**

Add after the window creation typedefs:

```swift
// Corner radius detection
typealias SLSWindowIteratorGetCornerRadii_t = @convention(c) (UInt32, UnsafeMutablePointer<(CGFloat, CGFloat, CGFloat, CGFloat)>) -> CGError
```

**Step 2: Load the symbol**

```swift
private let _SLSWindowIteratorGetCornerRadii: SLSWindowIteratorGetCornerRadii_t? = loadSymbol("SLSWindowIteratorGetCornerRadii")
```

**Step 3: Add wrapper function**

```swift
/// Get corner radii for a window (topLeft, topRight, bottomRight, bottomLeft)
func SLSWindowIteratorGetCornerRadii(_ wid: UInt32, _ radii: UnsafeMutablePointer<(CGFloat, CGFloat, CGFloat, CGFloat)>) -> CGError {
    return _SLSWindowIteratorGetCornerRadii?(wid, radii) ?? .failure
}
```

**Step 4: Build and verify**

Run: `cd /Users/r/repos/theGrid/grid-server && swift build 2>&1 | head -20`
Expected: Build succeeds

---

## Phase 2: Border Configuration

### Task 2: Add Border Config Types

**Files:**
- Create: `grid-server/Sources/GridServer/Borders/BorderConfig.swift`

**Step 1: Create the Borders directory**

Run: `mkdir -p /Users/r/repos/theGrid/grid-server/Sources/GridServer/Borders`

**Step 2: Create BorderConfig.swift**

```swift
//
// BorderConfig.swift
// GridServer
//
// Configuration for cell-aware window borders
//

import Foundation
import CoreGraphics
import Logging

/// Border visual style
enum BorderStyleType: String, Codable {
    case round = "round"
    case square = "square"
    case uniform = "uniform"
}

/// Focus tier for color resolution
enum FocusTier {
    case activeWindow   // The focused window
    case activeCell     // Other windows in focused cell
    case inactive       // Windows in other cells
}

/// Per-cell border style overrides
struct CellBorderStyle {
    var activeCellColor: CGColor?
    var inactiveColor: CGColor?
    var style: BorderStyleType?
}

/// Border configuration
class BorderConfig {
    private let logger = Logger(label: "com.grid.BorderConfig")

    // General settings
    var enabled: Bool = true
    var width: CGFloat = 5.0
    var style: BorderStyleType = .round
    var cornerRadius: CGFloat = 8.0
    var padding: CGFloat = 2.0
    var hidpiEnabled: Bool = true

    // Three-tier focus colors (defaults)
    var activeWindowColor: CGColor = CGColor(red: 0.88, green: 0.42, blue: 0.46, alpha: 1.0) // #e06c75
    var activeCellColor: CGColor = CGColor(red: 0.38, green: 0.69, blue: 0.94, alpha: 1.0)   // #61afef
    var inactiveColor: CGColor = CGColor(red: 0.36, green: 0.39, blue: 0.44, alpha: 1.0)    // #5c6370

    // Palette for auto-assignment
    var palette: [CGColor] = []

    // Per-cell overrides
    var cellOverrides: [String: CellBorderStyle] = [:]

    // App filtering
    var whitelist: Set<String> = []
    var blacklist: Set<String> = []

    // Palette assignment tracking
    private var paletteAssignments: [String: Int] = [:]
    private var nextPaletteIndex: Int = 0

    // MARK: - Color Resolution

    /// Get the effective color for a window based on its focus tier and cell
    func resolveColor(tier: FocusTier, cellID: String?) -> CGColor {
        switch tier {
        case .activeWindow:
            return activeWindowColor

        case .activeCell:
            guard let cellID = cellID else { return activeCellColor }

            // 1. Per-cell override
            if let override = cellOverrides[cellID]?.activeCellColor {
                return override
            }
            // 2. Palette
            if !palette.isEmpty {
                return palette[getPaletteIndex(for: cellID)]
            }
            // 3. Global default
            return activeCellColor

        case .inactive:
            guard let cellID = cellID else { return inactiveColor }

            // 1. Per-cell override
            if let override = cellOverrides[cellID]?.inactiveColor {
                return override
            }
            // 2. Dimmed palette color
            if !palette.isEmpty {
                let baseColor = palette[getPaletteIndex(for: cellID)]
                return dimColor(baseColor, by: 0.5)
            }
            // 3. Global default
            return inactiveColor
        }
    }

    /// Check if borders should be shown for an app
    func shouldShowBorder(bundleID: String?) -> Bool {
        guard let bundleID = bundleID else { return true }

        // Blacklist takes priority
        if blacklist.contains(bundleID) {
            return false
        }

        // If whitelist is set, only show for whitelisted apps
        if !whitelist.isEmpty {
            return whitelist.contains(bundleID)
        }

        return true
    }

    // MARK: - Private Helpers

    private func getPaletteIndex(for cellID: String) -> Int {
        if let existing = paletteAssignments[cellID] {
            return existing
        }
        let index = nextPaletteIndex % palette.count
        paletteAssignments[cellID] = index
        nextPaletteIndex += 1
        return index
    }

    private func dimColor(_ color: CGColor, by factor: CGFloat) -> CGColor {
        guard let components = color.components, components.count >= 3 else {
            return color
        }

        let r = components[0] * factor
        let g = components[1] * factor
        let b = components[2] * factor
        let a = components.count >= 4 ? components[3] : 1.0

        return CGColor(red: r, green: g, blue: b, alpha: a)
    }

    // MARK: - Parsing

    /// Parse color from hex string (0xAARRGGBB or 0xRRGGBB)
    static func parseColor(_ hex: String) -> CGColor? {
        var hexString = hex
        if hexString.hasPrefix("0x") {
            hexString = String(hexString.dropFirst(2))
        }

        guard let value = UInt32(hexString, radix: 16) else {
            return nil
        }

        let a, r, g, b: CGFloat
        if hexString.count == 8 {
            // 0xAARRGGBB
            a = CGFloat((value >> 24) & 0xFF) / 255.0
            r = CGFloat((value >> 16) & 0xFF) / 255.0
            g = CGFloat((value >> 8) & 0xFF) / 255.0
            b = CGFloat(value & 0xFF) / 255.0
        } else {
            // 0xRRGGBB (assume full opacity)
            a = 1.0
            r = CGFloat((value >> 16) & 0xFF) / 255.0
            g = CGFloat((value >> 8) & 0xFF) / 255.0
            b = CGFloat(value & 0xFF) / 255.0
        }

        return CGColor(red: r, green: g, blue: b, alpha: a)
    }

    /// Load configuration from dictionary (parsed from YAML/JSON)
    static func load(from dict: [String: Any]) -> BorderConfig {
        let config = BorderConfig()

        if let enabled = dict["enabled"] as? Bool {
            config.enabled = enabled
        }
        if let width = dict["width"] as? Double {
            config.width = CGFloat(width)
        }
        if let styleStr = dict["style"] as? String, let style = BorderStyleType(rawValue: styleStr) {
            config.style = style
        }
        if let radius = dict["corner_radius"] as? Double {
            config.cornerRadius = CGFloat(radius)
        }
        if let padding = dict["padding"] as? Double {
            config.padding = CGFloat(padding)
        }
        if let hidpi = dict["hidpi"] as? Bool {
            config.hidpiEnabled = hidpi
        }

        // Colors
        if let colorHex = dict["active_window_color"] as? String, let color = parseColor(colorHex) {
            config.activeWindowColor = color
        }
        if let colorHex = dict["active_cell_color"] as? String, let color = parseColor(colorHex) {
            config.activeCellColor = color
        }
        if let colorHex = dict["inactive_color"] as? String, let color = parseColor(colorHex) {
            config.inactiveColor = color
        }

        // Palette
        if let paletteArray = dict["palette"] as? [String] {
            config.palette = paletteArray.compactMap { parseColor($0) }
        }

        // Blacklist/whitelist
        if let blacklistArray = dict["blacklist"] as? [String] {
            config.blacklist = Set(blacklistArray)
        }
        if let whitelistArray = dict["whitelist"] as? [String] {
            config.whitelist = Set(whitelistArray)
        }

        return config
    }
}
```

**Step 3: Build and verify**

Run: `cd /Users/r/repos/theGrid/grid-server && swift build 2>&1 | head -20`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add grid-server/Sources/GridServer/Borders/BorderConfig.swift
git commit -m "feat(borders): add BorderConfig for color resolution"
```

---

## Phase 3: Border Rendering

### Task 3: Create BorderRenderer for Core Graphics Drawing

**Files:**
- Create: `grid-server/Sources/GridServer/Borders/BorderRenderer.swift`

**Step 1: Create BorderRenderer.swift**

```swift
//
// BorderRenderer.swift
// GridServer
//
// Core Graphics drawing for window borders
//

import Foundation
import CoreGraphics

/// Border rendering style parameters
struct BorderStyle {
    var color: CGColor
    var width: CGFloat
    var cornerRadius: CGFloat
    var styleType: BorderStyleType
}

/// Stateless border renderer using Core Graphics
enum BorderRenderer {

    /// Draw a border in the given context
    static func draw(in context: CGContext, bounds: CGRect, style: BorderStyle) {
        // Clear the context first
        context.clear(bounds)

        // Calculate the stroke rect (inset by half stroke width since stroke is centered)
        let strokeInset = style.width / 2
        let strokeRect = bounds.insetBy(dx: strokeInset, dy: strokeInset)

        // Create path based on style
        let path: CGPath
        switch style.styleType {
        case .round:
            path = CGPath(
                roundedRect: strokeRect,
                cornerWidth: style.cornerRadius,
                cornerHeight: style.cornerRadius,
                transform: nil
            )
        case .square:
            path = CGPath(rect: strokeRect, transform: nil)
        case .uniform:
            // Uniform uses rounded corners that are proportional to border width
            let uniformRadius = style.width * 1.5
            path = CGPath(
                roundedRect: strokeRect,
                cornerWidth: uniformRadius,
                cornerHeight: uniformRadius,
                transform: nil
            )
        }

        // Set stroke properties
        context.setStrokeColor(style.color)
        context.setLineWidth(style.width)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // Draw the border
        context.addPath(path)
        context.strokePath()
    }

    /// Draw a border with glow effect
    static func drawWithGlow(
        in context: CGContext,
        bounds: CGRect,
        style: BorderStyle,
        glowColor: CGColor,
        glowRadius: CGFloat
    ) {
        // Set shadow for glow effect
        context.setShadow(
            offset: .zero,
            blur: glowRadius,
            color: glowColor
        )

        // Draw the border (shadow will be applied automatically)
        draw(in: context, bounds: bounds, style: style)

        // Reset shadow
        context.setShadow(offset: .zero, blur: 0, color: nil)
    }

    /// Draw a gradient border (future feature)
    static func drawGradient(
        in context: CGContext,
        bounds: CGRect,
        colors: [CGColor],
        angle: CGFloat,
        width: CGFloat,
        cornerRadius: CGFloat
    ) {
        guard colors.count >= 2 else {
            // Fall back to solid color if not enough colors
            if let color = colors.first {
                let style = BorderStyle(
                    color: color,
                    width: width,
                    cornerRadius: cornerRadius,
                    styleType: .round
                )
                draw(in: context, bounds: bounds, style: style)
            }
            return
        }

        // Create gradient
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: colors as CFArray,
            locations: nil
        ) else { return }

        // Calculate gradient points based on angle
        let radians = angle * .pi / 180
        let dx = cos(radians)
        let dy = sin(radians)

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = max(bounds.width, bounds.height) / 2

        let startPoint = CGPoint(
            x: center.x - dx * radius,
            y: center.y - dy * radius
        )
        let endPoint = CGPoint(
            x: center.x + dx * radius,
            y: center.y + dy * radius
        )

        // Create border path for clipping
        let strokeInset = width / 2
        let outerRect = bounds.insetBy(dx: strokeInset, dy: strokeInset)
        let innerRect = bounds.insetBy(dx: width + strokeInset, dy: width + strokeInset)

        let outerPath = CGPath(
            roundedRect: outerRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        let innerPath = CGPath(
            roundedRect: innerRect,
            cornerWidth: max(0, cornerRadius - width),
            cornerHeight: max(0, cornerRadius - width),
            transform: nil
        )

        // Clip to border area (outer - inner)
        context.saveGState()
        context.addPath(outerPath)
        context.addPath(innerPath)
        context.clip(using: .evenOdd)

        // Draw gradient
        context.drawLinearGradient(
            gradient,
            start: startPoint,
            end: endPoint,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )

        context.restoreGState()
    }
}
```

**Step 2: Build and verify**

Run: `cd /Users/r/repos/theGrid/grid-server && swift build 2>&1 | head -20`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add grid-server/Sources/GridServer/Borders/BorderRenderer.swift
git commit -m "feat(borders): add BorderRenderer for Core Graphics drawing"
```

---

## Phase 4: Border Window

### Task 4: Create BorderWindow for SkyLight Overlay

**Files:**
- Create: `grid-server/Sources/GridServer/Borders/BorderWindow.swift`

**Step 1: Create BorderWindow.swift**

```swift
//
// BorderWindow.swift
// GridServer
//
// SkyLight overlay window for rendering a single border
//

import Foundation
import CoreGraphics
import Logging

/// A single border overlay window that tracks a target window
class BorderWindow {
    private let logger = Logger(label: "com.grid.BorderWindow")
    private let connectionID: Int32

    /// Our overlay window ID
    private(set) var windowID: UInt32 = 0

    /// Target window we're drawing around
    let targetWindowID: UInt32

    /// Drawing context
    private var context: CGContext?

    /// Current bounds of the border
    private var currentBounds: CGRect = .zero

    /// Current style
    private var currentStyle: BorderStyle?

    /// Whether the border is currently visible
    private(set) var isVisible: Bool = false

    /// Border padding (space between window edge and border)
    var padding: CGFloat = 2.0

    // MARK: - Event Coalescing (20ms debounce for smooth window drags)
    private var updateTimer: DispatchSourceTimer?
    private let coalesceDelay: TimeInterval = 0.02 // 20ms like JankyBorders
    private var pendingFrame: CGRect?
    private var pendingStyle: BorderStyle?

    init(connectionID: Int32, targetWindowID: UInt32) {
        self.connectionID = connectionID
        self.targetWindowID = targetWindowID
    }

    deinit {
        destroy()
    }

    // MARK: - Lifecycle

    /// Create the overlay window
    func create() -> Bool {
        guard windowID == 0 else {
            logger.warning("Border window already created", metadata: ["targetID": "\(targetWindowID)"])
            return true
        }

        // Get target window bounds to size our overlay
        var targetBounds = CGRect.zero
        guard SLSGetWindowBounds(connectionID, targetWindowID, &targetBounds) == .success else {
            logger.error("Failed to get target window bounds", metadata: ["targetID": "\(targetWindowID)"])
            return false
        }

        // Create region for window (initially at 0,0 - we'll position it later)
        var region = CGRect(origin: .zero, size: targetBounds.size)

        // Create the window
        // Backing store = 2 (buffered), initial position offscreen
        var newWindowID: UInt32 = 0
        let result = SLSNewWindow(
            connectionID,
            2,  // kCGBackingStoreBuffered
            -9999,
            -9999,
            &region,
            &newWindowID
        )

        guard result == .success, newWindowID != 0 else {
            logger.error("SLSNewWindow failed", metadata: [
                "error": "\(result.rawValue)",
                "targetID": "\(targetWindowID)"
            ])
            return false
        }

        self.windowID = newWindowID

        // Set window tags: floating, no shadow
        var tags: UInt64 = WindowTags.floating | WindowTags.noShadow
        _ = SLSSetWindowTags(connectionID, windowID, &tags, 64)

        // Make window transparent
        _ = SLSSetWindowOpacity(connectionID, windowID, false)
        _ = SLSSetWindowAlpha(connectionID, windowID, 0.0)

        // Set window level below normal windows
        _ = SLSSetWindowLevel(connectionID, windowID, -1)

        // Create drawing context
        context = SLWindowContextCreate(connectionID, windowID, nil)

        if context == nil {
            logger.warning("Failed to create drawing context", metadata: ["windowID": "\(windowID)"])
        }

        logger.debug("Border window created", metadata: [
            "windowID": "\(windowID)",
            "targetID": "\(targetWindowID)"
        ])

        return true
    }

    /// Destroy the overlay window
    func destroy() {
        guard windowID != 0 else { return }

        context = nil
        _ = SLSReleaseWindow(connectionID, windowID)

        logger.debug("Border window destroyed", metadata: ["windowID": "\(windowID)"])

        windowID = 0
        isVisible = false
    }

    // MARK: - Visibility

    /// Show the border
    func show() {
        guard windowID != 0 else { return }

        _ = SLSSetWindowAlpha(connectionID, windowID, 1.0)
        _ = SLSOrderWindow(connectionID, windowID, -1, targetWindowID)  // Below target

        isVisible = true
    }

    /// Hide the border
    func hide() {
        guard windowID != 0 else { return }

        _ = SLSSetWindowAlpha(connectionID, windowID, 0.0)
        _ = SLSOrderWindow(connectionID, windowID, 0, 0)  // Remove from ordering

        isVisible = false
    }

    // MARK: - Update

    /// Update border position and size to match target window
    func updatePosition(targetFrame: CGRect, borderWidth: CGFloat) {
        guard windowID != 0 else { return }

        // Calculate border bounds (larger than target by width + padding on each side)
        let expansion = borderWidth + padding
        let borderBounds = targetFrame.insetBy(dx: -expansion, dy: -expansion)

        // Move the window
        var origin = borderBounds.origin
        _ = SLSMoveWindow(connectionID, windowID, &origin)

        // Update shape if size changed
        if borderBounds.size != currentBounds.size {
            var region = CGRect(origin: .zero, size: borderBounds.size)
            _ = SLSSetWindowShape(connectionID, windowID, 0, 0, &region)

            // Recreate context for new size
            context = SLWindowContextCreate(connectionID, windowID, nil)
        }

        currentBounds = borderBounds

        // Re-order to stay below target
        if isVisible {
            _ = SLSOrderWindow(connectionID, windowID, -1, targetWindowID)
        }
    }

    /// Redraw the border with the given style
    func redraw(style: BorderStyle) {
        guard windowID != 0, let context = context else { return }
        guard currentBounds.size.width > 0 && currentBounds.size.height > 0 else { return }

        // Draw into our bounds (0,0 to size)
        let drawBounds = CGRect(origin: .zero, size: currentBounds.size)

        BorderRenderer.draw(in: context, bounds: drawBounds, style: style)

        // Flush to screen
        _ = SLSFlushWindowContentRegion(connectionID, windowID, nil)

        currentStyle = style
    }

    /// Update position and redraw in one call
    func update(targetFrame: CGRect, style: BorderStyle) {
        updatePosition(targetFrame: targetFrame, borderWidth: style.width)
        redraw(style: style)
    }

    // MARK: - Coalesced Updates

    /// Schedule an update with debouncing (use this during window drags)
    func scheduleUpdate(frame: CGRect, style: BorderStyle) {
        pendingFrame = frame
        pendingStyle = style

        updateTimer?.cancel()
        updateTimer = DispatchSource.makeTimerSource(queue: .main)
        updateTimer?.schedule(deadline: .now() + coalesceDelay)
        updateTimer?.setEventHandler { [weak self] in
            guard let self = self,
                  let frame = self.pendingFrame,
                  let style = self.pendingStyle else { return }
            self.update(targetFrame: frame, style: style)
            self.pendingFrame = nil
            self.pendingStyle = nil
        }
        updateTimer?.resume()
    }

    /// Get dynamic corner radius from target window
    func getTargetCornerRadius(fallback: CGFloat) -> CGFloat {
        var radii: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        if SLSWindowIteratorGetCornerRadii(targetWindowID, &radii) == .success {
            return radii.0  // Top-left corner radius
        }
        return fallback
    }
}
```

**Step 2: Build and verify**

Run: `cd /Users/r/repos/theGrid/grid-server && swift build 2>&1 | head -20`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add grid-server/Sources/GridServer/Borders/BorderWindow.swift
git commit -m "feat(borders): add BorderWindow SkyLight overlay with event coalescing"
```

---

## Phase 5: Border Manager

### Task 5: Create BorderManager to Orchestrate Borders

**Files:**
- Create: `grid-server/Sources/GridServer/Borders/BorderManager.swift`

**Step 1: Create BorderManager.swift**

```swift
//
// BorderManager.swift
// GridServer
//
// Orchestrates border lifecycle and focus updates
//

import Foundation
import CoreGraphics
import Logging

/// Manages all window borders and focus state
class BorderManager {
    private let logger = Logger(label: "com.grid.BorderManager")
    private let connectionID: Int32

    /// Active borders by target window ID
    private var borders: [UInt32: BorderWindow] = [:]

    /// Configuration
    var config: BorderConfig

    /// Current focus state
    private var focusedWindowID: UInt32?
    private var focusedCellID: String?

    /// Cell assignments from CLI (windowID → cellID)
    private var cellAssignments: [UInt32: String] = [:]

    /// Callback to get bundle ID for a window
    var getBundleIDForWindow: ((UInt32) -> String?)?

    init(connectionID: Int32, config: BorderConfig = BorderConfig()) {
        self.connectionID = connectionID
        self.config = config
    }

    // MARK: - Cell Assignment Management (from CLI via IPC)

    /// Set cell assignments received from CLI
    func setCellAssignments(_ assignments: [UInt32: String]) {
        cellAssignments = assignments
        logger.debug("Cell assignments updated", metadata: ["count": "\(assignments.count)"])
    }

    /// Set per-cell style override
    func setCellOverride(cellID: String, config: [String: Any]) {
        var override = CellBorderStyle()
        if let colorHex = config["activeCellColor"] as? String {
            override.activeCellColor = BorderConfig.parseColor(colorHex)
        }
        if let colorHex = config["inactiveColor"] as? String {
            override.inactiveColor = BorderConfig.parseColor(colorHex)
        }
        if let styleStr = config["style"] as? String, let style = BorderStyleType(rawValue: styleStr) {
            override.style = style
        }
        self.config.cellOverrides[cellID] = override
    }

    /// Get cell assignment for a window
    func getCellAssignment(for windowID: UInt32) -> String? {
        return cellAssignments[windowID]
    }

    /// Get all windows in a cell
    func getWindowsInCell(_ cellID: String) -> [UInt32] {
        return cellAssignments.filter { $0.value == cellID }.map { $0.key }
    }

    /// Refresh all borders (after config or cell assignment change)
    func refreshAllBorders() {
        for windowID in borders.keys {
            updateBorder(for: windowID)
        }
    }

    // MARK: - Border Lifecycle

    /// Create a border for a window
    func createBorder(for windowID: UInt32) {
        guard config.enabled else { return }
        guard borders[windowID] == nil else { return }

        // Check blacklist/whitelist
        if let bundleID = getBundleIDForWindow?(windowID) {
            if !config.shouldShowBorder(bundleID: bundleID) {
                logger.debug("Skipping border for blacklisted app", metadata: [
                    "windowID": "\(windowID)",
                    "bundleID": "\(bundleID)"
                ])
                return
            }
        }

        let border = BorderWindow(connectionID: connectionID, targetWindowID: windowID)

        guard border.create() else {
            logger.error("Failed to create border", metadata: ["windowID": "\(windowID)"])
            return
        }

        borders[windowID] = border

        // Initial draw
        updateBorder(for: windowID)
        border.show()

        logger.debug("Border created", metadata: ["windowID": "\(windowID)"])
    }

    /// Destroy a border for a window
    func destroyBorder(for windowID: UInt32) {
        guard let border = borders.removeValue(forKey: windowID) else { return }

        border.destroy()

        logger.debug("Border destroyed", metadata: ["windowID": "\(windowID)"])
    }

    /// Destroy all borders
    func destroyAllBorders() {
        for (windowID, border) in borders {
            border.destroy()
            logger.debug("Border destroyed", metadata: ["windowID": "\(windowID)"])
        }
        borders.removeAll()
    }

    // MARK: - Updates

    /// Update border position for a window
    func updatePosition(for windowID: UInt32, frame: CGRect) {
        guard let border = borders[windowID] else { return }

        let style = resolveStyle(for: windowID)
        border.update(targetFrame: frame, style: style)
    }

    /// Update border color for a window (e.g., focus changed)
    func updateBorder(for windowID: UInt32) {
        guard let border = borders[windowID] else { return }

        // Get current frame from SkyLight
        var frame = CGRect.zero
        guard SLSGetWindowBounds(connectionID, windowID, &frame) == .success else {
            logger.warning("Failed to get window bounds", metadata: ["windowID": "\(windowID)"])
            return
        }

        let style = resolveStyle(for: windowID)
        border.update(targetFrame: frame, style: style)
    }

    // MARK: - Focus Management

    /// Handle focus change (with transaction batching for performance)
    func updateFocus(newFocusedWindow: UInt32) {
        let oldFocusedWindow = focusedWindowID
        let oldFocusedCell = focusedCellID

        focusedWindowID = newFocusedWindow
        focusedCellID = cellAssignments[newFocusedWindow]

        logger.debug("Focus changed", metadata: [
            "oldWindow": "\(oldFocusedWindow?.description ?? "nil")",
            "newWindow": "\(newFocusedWindow)",
            "oldCell": "\(oldFocusedCell ?? "nil")",
            "newCell": "\(focusedCellID ?? "nil")"
        ])

        // Compute affected windows
        var affectedWindows: Set<UInt32> = []

        // Old focused window
        if let old = oldFocusedWindow {
            affectedWindows.insert(old)
        }

        // Old cell windows (if cell changed)
        if oldFocusedCell != focusedCellID, let oldCell = oldFocusedCell {
            let cellWindows = getWindowsInCell(oldCell)
            affectedWindows.formUnion(cellWindows)
        }

        // New cell windows
        if let newCell = focusedCellID {
            let cellWindows = getWindowsInCell(newCell)
            affectedWindows.formUnion(cellWindows)
        }

        // New focused window
        affectedWindows.insert(newFocusedWindow)

        // Use transaction for atomic batch update (performance optimization)
        if let transaction = SLSTransactionCreate(connectionID) {
            for windowID in affectedWindows {
                if let border = borders[windowID] {
                    SLSTransactionOrderWindow(transaction, border.windowID, -1, windowID)
                }
            }
            _ = SLSTransactionCommit(transaction, 1)
        }

        // Repaint affected borders
        for windowID in affectedWindows {
            updateBorder(for: windowID)
        }
    }

    // MARK: - Visibility

    /// Show border for a window
    func showBorder(for windowID: UInt32) {
        borders[windowID]?.show()
    }

    /// Hide border for a window
    func hideBorder(for windowID: UInt32) {
        borders[windowID]?.hide()
    }

    /// Show all borders
    func showAllBorders() {
        for border in borders.values {
            border.show()
        }
    }

    /// Hide all borders
    func hideAllBorders() {
        for border in borders.values {
            border.hide()
        }
    }

    // MARK: - Private Helpers

    /// Get focus tier for a window
    private func getFocusTier(for windowID: UInt32) -> FocusTier {
        if windowID == focusedWindowID {
            return .activeWindow
        }

        let cellID = cellAssignments[windowID]
        if cellID != nil && cellID == focusedCellID {
            return .activeCell
        }

        return .inactive
    }

    /// Resolve the complete style for a window
    private func resolveStyle(for windowID: UInt32) -> BorderStyle {
        let tier = getFocusTier(for: windowID)
        let cellID = cellAssignments[windowID]
        let color = config.resolveColor(tier: tier, cellID: cellID)

        // Get dynamic corner radius from target window
        var cornerRadius = config.cornerRadius
        if let border = borders[windowID] {
            cornerRadius = border.getTargetCornerRadius(fallback: config.cornerRadius)
        }

        // Check for per-cell style override
        var styleType = config.style
        if let cellID = cellID, let override = config.cellOverrides[cellID]?.style {
            styleType = override
        }

        return BorderStyle(
            color: color,
            width: config.width,
            cornerRadius: cornerRadius,
            styleType: styleType
        )
    }
}
```

**Step 2: Build and verify**

Run: `cd /Users/r/repos/theGrid/grid-server && swift build 2>&1 | head -20`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add grid-server/Sources/GridServer/Borders/BorderManager.swift
git commit -m "feat(borders): add BorderManager for orchestration"
```

---

## Phase 6: IPC Protocol (NEW)

### Task 6: Add Border Message Handlers to MessageHandler.swift

**Files:**
- Modify: `grid-server/Sources/GridServer/MessageHandler.swift`

**Step 1: Read MessageHandler.swift to understand the pattern**

Find the existing message handler switch/dispatch pattern.

**Step 2: Add handler for borders.configure**

```swift
// In the message dispatch switch
case "borders.configure":
    handleBordersConfig(message: message, client: client)

// New handler function
private func handleBordersConfig(message: [String: Any], client: ClientConnection) {
    guard let config = message["config"] as? [String: Any] else {
        sendError(to: client, error: "Missing config")
        return
    }

    let borderConfig = BorderConfig.load(from: config)
    borderManager?.config = borderConfig

    // Refresh all borders with new config
    borderManager?.refreshAllBorders()

    sendSuccess(to: client)
    logger.info("Border config updated")
}
```

**Step 3: Add handler for borders.setCellAssignments**

```swift
case "borders.setCellAssignments":
    handleBordersSetCellAssignments(message: message, client: client)

// New handler function
private func handleBordersSetCellAssignments(message: [String: Any], client: ClientConnection) {
    guard let assignments = message["assignments"] as? [String: String] else {
        sendError(to: client, error: "Missing assignments")
        return
    }

    // Store assignments: windowID (string) → cellID
    var cellAssignments: [UInt32: String] = [:]
    for (widStr, cellID) in assignments {
        if let wid = UInt32(widStr) {
            cellAssignments[wid] = cellID
        }
    }
    borderManager?.setCellAssignments(cellAssignments)

    // Store per-cell overrides if provided
    if let cells = message["cells"] as? [String: [String: Any]] {
        for (cellID, cellConfig) in cells {
            borderManager?.setCellOverride(cellID: cellID, config: cellConfig)
        }
    }

    // Refresh borders with new cell awareness
    borderManager?.refreshAllBorders()

    sendSuccess(to: client)
    logger.info("Cell assignments updated", metadata: ["count": "\(cellAssignments.count)"])
}
```

**Step 4: Build and verify**

Run: `cd /Users/r/repos/theGrid/grid-server && swift build 2>&1 | head -20`
Expected: Build succeeds

**Step 5: Commit**

```bash
git add grid-server/Sources/GridServer/MessageHandler.swift
git commit -m "feat(borders): add IPC handlers for borders.configure and borders.setCellAssignments"
```

---

### Task 7: Create CLI Border Client (Go)

**Files:**
- Create: `grid-cli/internal/client/borders.go`

**Step 1: Create borders.go**

```go
package client

import (
    "encoding/json"
    "fmt"

    "github.com/yourusername/thegrid/grid-cli/internal/config"
)

// SendBorderConfig sends border configuration to the server
func (c *Client) SendBorderConfig(cfg *config.BorderConfig) error {
    if cfg == nil || !cfg.GetEnabled() {
        return nil
    }

    msg := map[string]interface{}{
        "type": "borders.configure",
        "config": map[string]interface{}{
            "enabled":           cfg.GetEnabled(),
            "width":             cfg.GetWidth(),
            "style":             cfg.GetStyle(),
            "cornerRadius":      cfg.GetCornerRadius(),
            "padding":           cfg.GetPadding(),
            "hidpi":             cfg.GetHiDPI(),
            "activeWindowColor": cfg.ActiveWindowColor,
            "activeCellColor":   cfg.ActiveCellColor,
            "inactiveColor":     cfg.InactiveColor,
            "palette":           cfg.Palette,
            "blacklist":         cfg.Blacklist,
            "whitelist":         cfg.Whitelist,
        },
    }

    return c.SendMessage(msg)
}

// CellAssignment represents a window-to-cell mapping
type CellAssignment struct {
    WindowID uint32
    CellID   string
}

// CellOverride represents per-cell border config
type CellOverride struct {
    ActiveCellColor string `json:"activeCellColor,omitempty"`
    InactiveColor   string `json:"inactiveColor,omitempty"`
    Style           string `json:"style,omitempty"`
}

// SendCellAssignments sends window-to-cell mappings to the server
func (c *Client) SendCellAssignments(assignments []CellAssignment, overrides map[string]CellOverride) error {
    assignmentMap := make(map[string]string)
    for _, a := range assignments {
        assignmentMap[fmt.Sprintf("%d", a.WindowID)] = a.CellID
    }

    msg := map[string]interface{}{
        "type":        "borders.setCellAssignments",
        "assignments": assignmentMap,
        "cells":       overrides,
    }

    return c.SendMessage(msg)
}
```

**Step 2: Build and verify**

Run: `cd /Users/r/repos/theGrid/grid-cli && go build ./...`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add grid-cli/internal/client/borders.go
git commit -m "feat(borders): add CLI client for border IPC messages"
```

---

## Phase 7: Event Integration

### Task 8: Create BorderEvents to Hook into StateManager

**Files:**
- Create: `grid-server/Sources/GridServer/Borders/BorderEvents.swift`

**Step 1: Create BorderEvents.swift**

```swift
//
// BorderEvents.swift
// GridServer
//
// Routes StateManager events to BorderManager
//

import Foundation
import CoreGraphics
import Logging

/// Routes window events from StateManager to BorderManager
class BorderEvents {
    private let logger = Logger(label: "com.grid.BorderEvents")
    private weak var borderManager: BorderManager?
    private weak var stateManager: StateManager?

    init() {}

    /// Connect to managers
    func setup(borderManager: BorderManager, stateManager: StateManager) {
        self.borderManager = borderManager
        self.stateManager = stateManager

        // Set up callbacks for BorderManager to query state
        borderManager.getCellForWindow = { [weak self] windowID in
            self?.getCellForWindow(windowID)
        }

        borderManager.getWindowsInCell = { [weak self] cellID in
            self?.getWindowsInCell(cellID) ?? []
        }

        borderManager.getBundleIDForWindow = { [weak self] windowID in
            self?.getBundleIDForWindow(windowID)
        }

        logger.info("BorderEvents connected to managers")
    }

    // MARK: - Event Handlers (called by StateManager)

    func handleWindowCreated(_ windowID: UInt32) {
        borderManager?.createBorder(for: windowID)
    }

    func handleWindowDestroyed(_ windowID: UInt32) {
        borderManager?.destroyBorder(for: windowID)
    }

    func handleWindowMoved(_ windowID: UInt32, frame: CGRect) {
        borderManager?.updatePosition(for: windowID, frame: frame)
    }

    func handleWindowResized(_ windowID: UInt32, frame: CGRect) {
        borderManager?.updatePosition(for: windowID, frame: frame)
    }

    func handleWindowFocused(_ windowID: UInt32) {
        borderManager?.updateFocus(newFocusedWindow: windowID)
    }

    func handleWindowMinimized(_ windowID: UInt32) {
        borderManager?.hideBorder(for: windowID)
    }

    func handleWindowDeminimized(_ windowID: UInt32) {
        borderManager?.showBorder(for: windowID)
        borderManager?.updateBorder(for: windowID)
    }

    func handleAppHidden(bundleID: String) {
        // Hide borders for all windows of this app
        guard let state = stateManager?.getState() else { return }

        for (widStr, window) in state.windows {
            if window.bundleID == bundleID, let wid = UInt32(widStr) {
                borderManager?.hideBorder(for: wid)
            }
        }
    }

    func handleAppUnhidden(bundleID: String) {
        // Show borders for all windows of this app
        guard let state = stateManager?.getState() else { return }

        for (widStr, window) in state.windows {
            if window.bundleID == bundleID, let wid = UInt32(widStr) {
                borderManager?.showBorder(for: wid)
                borderManager?.updateBorder(for: wid)
            }
        }
    }

    func handleSpaceChanged() {
        // Refresh all borders for current space visibility
        // Windows not on current space will have their borders hidden by the system
        guard let borderManager = borderManager else { return }

        // Refresh all existing borders
        for windowID in getAllTrackedWindows() {
            borderManager.updateBorder(for: windowID)
        }
    }

    // MARK: - State Queries

    private func getCellForWindow(_ windowID: UInt32) -> String? {
        // Get cell assignment from BorderManager (received via IPC)
        return borderManager?.getCellAssignment(for: windowID)
    }

    private func getWindowsInCell(_ cellID: String) -> [UInt32] {
        // Get all windows in this cell from BorderManager
        return borderManager?.getWindowsInCell(cellID) ?? []
    }

    private func getBundleIDForWindow(_ windowID: UInt32) -> String? {
        guard let state = stateManager?.getState() else { return nil }
        return state.windows[String(windowID)]?.bundleID
    }

    private func getAllTrackedWindows() -> [UInt32] {
        guard let state = stateManager?.getState() else { return [] }
        return state.windows.keys.compactMap { UInt32($0) }
    }
}
```

**Step 2: Build and verify**

Run: `cd /Users/r/repos/theGrid/grid-server && swift build 2>&1 | head -20`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add grid-server/Sources/GridServer/Borders/BorderEvents.swift
git commit -m "feat(borders): add BorderEvents for event routing"
```

---

## Phase 8: Integration

### Task 9: Integrate BorderManager into GridServer

**Files:**
- Modify: `grid-server/Sources/GridServer/StateManager.swift`

**Step 1: Read StateManager to understand its structure**

First, read the file to understand where to add border event calls.

**Step 2: Add BorderEvents property and initialization**

Add to StateManager class (after other properties):

```swift
/// Border event handler
var borderEvents: BorderEvents?
```

**Step 3: Add border event calls to existing handlers**

In each relevant handler method, add a call to borderEvents:

```swift
// In handleWindowCreated:
borderEvents?.handleWindowCreated(windowID)

// In handleWindowDestroyed:
borderEvents?.handleWindowDestroyed(windowID)

// In handleWindowMoved:
borderEvents?.handleWindowMoved(windowID, frame: frame)

// In handleWindowResized:
borderEvents?.handleWindowResized(windowID, frame: frame)

// In handleWindowFocused:
borderEvents?.handleWindowFocused(windowID)

// In handleWindowMinimized:
borderEvents?.handleWindowMinimized(windowID)

// In handleWindowDeminimized:
borderEvents?.handleWindowDeminimized(windowID)
```

**Step 4: Build and verify**

Run: `cd /Users/r/repos/theGrid/grid-server && swift build 2>&1 | head -20`
Expected: Build succeeds

**Step 5: Commit**

```bash
git add grid-server/Sources/GridServer/StateManager.swift
git commit -m "feat(borders): integrate BorderEvents into StateManager"
```

---

### Task 10: Initialize BorderManager in GridServer Entry Point

**Files:**
- Modify: `grid-server/Sources/GridServer/GridServer.swift`

**Step 1: Read GridServer.swift to understand initialization**

**Step 2: Add BorderManager initialization**

Add after StateManager and other component initialization:

```swift
// Initialize border system
let borderConfig = BorderConfig()
// TODO: Load config from file
let borderManager = BorderManager(connectionID: connectionID, config: borderConfig)
let borderEvents = BorderEvents()
borderEvents.setup(borderManager: borderManager, stateManager: stateManager)
stateManager.borderEvents = borderEvents

logger.info("Border system initialized")
```

**Step 3: Create borders for existing windows**

After initial window scan:

```swift
// Create borders for existing windows
for (widStr, _) in stateManager.getState().windows {
    if let windowID = UInt32(widStr) {
        borderManager.createBorder(for: windowID)
    }
}
```

**Step 4: Build and verify**

Run: `cd /Users/r/repos/theGrid/grid-server && swift build 2>&1 | head -20`
Expected: Build succeeds

**Step 5: Test manually**

Run: `cd /Users/r/repos/theGrid/grid-server && .build/debug/grid-server`
Expected: Server starts, borders appear around windows

**Step 6: Commit**

```bash
git add grid-server/Sources/GridServer/GridServer.swift
git commit -m "feat(borders): initialize border system in GridServer"
```

---

## Phase 9: CLI Config Schema

### Task 11: Add Border Config to CLI Types

**Files:**
- Modify: `grid-cli/internal/config/types.go`

**Step 1: Add BorderConfig struct**

```go
// BorderConfig defines window border appearance
type BorderConfig struct {
    Enabled           *bool    `yaml:"enabled,omitempty"`
    Width             *float64 `yaml:"width,omitempty"`
    Style             *string  `yaml:"style,omitempty"`              // round, square, uniform
    CornerRadius      *float64 `yaml:"corner_radius,omitempty"`
    Padding           *float64 `yaml:"padding,omitempty"`
    HiDPI             *bool    `yaml:"hidpi,omitempty"`
    ActiveWindowColor *string  `yaml:"active_window_color,omitempty"` // 0xAARRGGBB
    ActiveCellColor   *string  `yaml:"active_cell_color,omitempty"`
    InactiveColor     *string  `yaml:"inactive_color,omitempty"`
    Palette           []string `yaml:"palette,omitempty"`
    Whitelist         []string `yaml:"whitelist,omitempty"`
    Blacklist         []string `yaml:"blacklist,omitempty"`
}
```

**Step 2: Add to Config struct**

```go
type Config struct {
    // ... existing fields
    Borders *BorderConfig `yaml:"borders,omitempty"`
}
```

**Step 3: Add CellBorderConfig to layout types**

In `grid-cli/internal/types/layout_types.go`:

```go
// CellBorderConfig defines per-cell border overrides
type CellBorderConfig struct {
    ActiveCellColor *string `yaml:"active_cell_color,omitempty"`
    InactiveColor   *string `yaml:"inactive_color,omitempty"`
    Style           *string `yaml:"style,omitempty"`
}

// Add to Cell struct
type Cell struct {
    // ... existing fields
    Border *CellBorderConfig `yaml:"border,omitempty"`
}
```

**Step 4: Build and verify**

Run: `cd /Users/r/repos/theGrid/grid-cli && go build ./...`
Expected: Build succeeds

**Step 5: Commit**

```bash
git add grid-cli/internal/config/types.go grid-cli/internal/types/layout_types.go
git commit -m "feat(borders): add border config schema to CLI"
```

---

## Future Tasks (Phase 2+)

These are documented for future implementation:

1. **Config loading from YAML** - Parse ~/.config/thegrid/config.yaml borders section
2. **Live config reload** - Add `borders.reload` message handler
3. **Cell state sync** - Server receives cell assignments from CLI
4. **Gradient support** - Enable gradient borders in BorderRenderer
5. **Glow effects** - Enable glow in BorderRenderer
6. **Fade animations** - CVDisplayLink-based color transitions
7. **HiDPI scaling** - Proper retina rendering

---

## Testing

After each phase, verify:

1. `swift build` succeeds in grid-server
2. `go build ./...` succeeds in grid-cli
3. Server starts without crashes
4. Borders appear around windows
5. Borders follow window moves/resizes
6. Focus changes update border colors

Manual test commands:
```bash
# Build and run server
cd /Users/r/repos/theGrid/grid-server && swift build && .build/debug/grid-server

# In another terminal, move windows and observe borders
```
