import AppKit
import CoreGraphics
import Foundation
import IOKit
import Logging

/// Indicates whether CGDisplayBounds returned usable data or whether the hand-rolled
/// Cocoa→Quartz flip should be used as a fallback.
enum FrameSource: Equatable {
    case success
    case fallback
}

/// Helper class for enriching display information from NSScreen and CGDisplay APIs
class DisplayInfoHelper {
    private static let logger = Logger(label: "com.grid.DisplayInfo")

    // selectFrameSource: decide whether CGDisplayBounds result is usable.
    // Returns .success when bounds has non-zero area; .fallback for .zero or
    // zero-size rects (observed on disconnected/transitioning displays).
    static func selectFrameSource(bounds: CGRect) -> FrameSource {
        if bounds.width > 0 && bounds.height > 0 {
            return .success
        }
        return .fallback
    }

    // computeFrameQuartz: return the Quartz-coordinate frame for a display.
    // Success path: returns CGDisplayBounds output verbatim.
    // Fallback path: applies the hand-rolled Cocoa→Quartz flip using mainScreenHeight.
    static func computeFrameQuartz(bounds: CGRect, cocoaFrame: CGRect, mainScreenHeight: CGFloat) -> CGRect {
        switch selectFrameSource(bounds: bounds) {
        case .success:
            return bounds
        case .fallback:
            let quartzY = mainScreenHeight - (cocoaFrame.origin.y + cocoaFrame.height)
            return CGRect(x: cocoaFrame.origin.x, y: quartzY, width: cocoaFrame.width, height: cocoaFrame.height)
        }
    }

    // computeVisibleFrame: derive the visible-frame inset from Cocoa screen coordinates
    // (no pivot needed — both inputs share the same coord system) and apply to quartzFrame.
    //
    // Inset deltas are coordinate-system-agnostic scalars:
    //   topInset    = cocoaScreen.maxY - cocoaVisibleScreen.maxY  (menu bar)
    //   bottomInset = cocoaVisibleScreen.minY - cocoaScreen.minY  (dock on bottom)
    //   leftInset   = cocoaVisibleScreen.minX - cocoaScreen.minX  (dock on left)
    //   rightInset  = cocoaScreen.maxX - cocoaVisibleScreen.maxX  (dock on right)
    //
    // In Quartz coords, y increases downward, so the menu-bar topInset shifts y
    // downward (larger y) and reduces height.
    static func computeVisibleFrame(quartzFrame: CGRect, cocoaScreen: CGRect, cocoaVisibleScreen: CGRect) -> CGRect {
        let topInset    = cocoaScreen.maxY - cocoaVisibleScreen.maxY
        let bottomInset = cocoaVisibleScreen.minY - cocoaScreen.minY
        let leftInset   = cocoaVisibleScreen.minX - cocoaScreen.minX
        let rightInset  = cocoaScreen.maxX - cocoaVisibleScreen.maxX
        return CGRect(
            x: quartzFrame.origin.x + leftInset,
            y: quartzFrame.origin.y + topInset,
            width: quartzFrame.width - leftInset - rightInset,
            height: quartzFrame.height - topInset - bottomInset
        )
    }

    /// Enriches a display with comprehensive information from NSScreen and CGDisplay
    static func enrichDisplayInfo(uuid: String, screenIndex: Int, slsUUIDs: Set<String> = [], currentSpaceID: UInt64, spaces: [UInt64]) -> DisplayState {
        var display = DisplayState(uuid: uuid, currentSpaceID: currentSpaceID, spaces: spaces)

        // Find the NSScreen with this UUID. SkyLight and NSScreen list displays
        // in different orders (two stacked externals came back swapped on two
        // machines), so pairing by index gave each external the other's frame.
        // Index is only a fallback for a UUID no screen reports.
        let screens = NSScreen.screens
        let screenUUIDs = screens.map { getCGDisplayID(from: $0).flatMap(displayUUID(for:)) }
        guard let matched = matchScreenIndex(uuid: uuid, screenUUIDs: screenUUIDs, fallbackIndex: screenIndex, claimedUUIDs: slsUUIDs) else {
            // If index is out of bounds, return basic info
            return display
        }
        if screenUUIDs[matched]?.caseInsensitiveCompare(uuid) != .orderedSame {
            jlog("warn.dsp.screen_fallback", data: ["uuid": uuid, "index": matched])
        }
        let screen = screens[matched]

        // Extract CGDirectDisplayID
        let displayID = getCGDisplayID(from: screen)
        display.displayID = displayID

        // Compute frame in Quartz coordinates.
        // Primary path: use CGDisplayBounds which returns Quartz coords directly,
        // eliminating the NSScreen.main pivot entirely.
        // Fallback path: hand-rolled flip, used only when CGDisplayBounds returns
        // a zero-sized rect (disconnected/transitioning display edge case).
        if let id = displayID {
            let bounds = CGDisplayBounds(id)
            if selectFrameSource(bounds: bounds) == .fallback {
                jlog("warn.dsp.cgbounds_empty", data: ["uuid": uuid, "displayID": id])
            }
            // mainScreenHeight only used in the fallback branch of computeFrameQuartz
            let mainScreenHeight = NSScreen.main?.frame.height ?? screen.frame.height
            display.frame = computeFrameQuartz(bounds: bounds, cocoaFrame: screen.frame, mainScreenHeight: mainScreenHeight)
        } else {
            // No displayID — fall back to hand-rolled flip
            let mainScreenHeight = NSScreen.main?.frame.height ?? screen.frame.height
            let frameQuartzY = mainScreenHeight - (screen.frame.origin.y + screen.frame.height)
            display.frame = CGRect(
                x: screen.frame.origin.x,
                y: frameQuartzY,
                width: screen.frame.width,
                height: screen.frame.height
            )
        }

        // Compute visibleFrame using pivot-free inset derivation.
        // The Cocoa inset deltas (screen.frame vs screen.visibleFrame) are
        // coordinate-system-agnostic and apply directly to the Quartz frame.
        if let quartzFrame = display.frame {
            display.visibleFrame = computeVisibleFrame(
                quartzFrame: quartzFrame,
                cocoaScreen: screen.frame,
                cocoaVisibleScreen: screen.visibleFrame
            )
        }

        display.backingScaleFactor = screen.backingScaleFactor

        // Check if main display
        display.isMain = (screen == NSScreen.main)

        // Get display name - prefer IOKit hardware name, fallback to NSScreen
        // IOKit returns base model name without macOS's automatic numbering (e.g., "C49HG9x" not "C49HG9x (2)")
        if let displayID = displayID,
           let hardwareName = getHardwareDisplayName(displayID: displayID) {
            display.name = hardwareName
        } else if #available(macOS 10.15, *) {
            display.name = screen.localizedName
        } else {
            display.name = "Display"
        }

        // Calculate logical dimensions (user-selected "Looks like" resolution)
        display.pixelWidth = Int(screen.frame.width)
        display.pixelHeight = Int(screen.frame.height)

        // Get color space
        display.colorSpace = screen.colorSpace?.localizedName

        // Extract CGDisplay properties if we have a displayID
        if let displayID = displayID {
            enrichWithCGDisplayInfo(&display, displayID: displayID)
        }

        return display
    }

    /// Index of the screen whose UUID matches (case-insensitive). Otherwise
    /// falls back to a screen no other listed display claims (`claimedUUIDs`),
    /// preferring `fallbackIndex`: handing out a claimed screen would give two
    /// displays one frame. A UUID no screen has (e.g. one shared space list
    /// when "Displays have separate Spaces" is off) still gets a screen.
    static func matchScreenIndex(uuid: String, screenUUIDs: [String?], fallbackIndex: Int, claimedUUIDs: Set<String> = []) -> Int? {
        if let i = screenUUIDs.firstIndex(where: { $0?.caseInsensitiveCompare(uuid) == .orderedSame }) {
            return i
        }
        let claimed = Set(claimedUUIDs.map { $0.uppercased() })
        let unclaimed = screenUUIDs.indices.filter { i in
            guard let screenUUID = screenUUIDs[i] else { return true }
            return !claimed.contains(screenUUID.uppercased())
        }
        // Prefer the display's own position, else the first free screen.
        return unclaimed.contains(fallbackIndex) ? fallbackIndex : unclaimed.first
    }

    /// The display UUID string SkyLight uses for a CGDirectDisplayID.
    private static func displayUUID(for displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// Extracts the CGDirectDisplayID from an NSScreen
    private static func getCGDisplayID(from screen: NSScreen) -> UInt32? {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else {
            return nil
        }
        return displayID
    }

    /// Enriches display information with CGDisplay API properties
    private static func enrichWithCGDisplayInfo(_ display: inout DisplayState, displayID: CGDirectDisplayID) {
        // Get refresh rate from display mode
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            let refreshRate = mode.refreshRate
            if refreshRate > 0 {
                display.refreshRate = refreshRate
            }
        }

        // Get physical size in millimeters
        let size = CGDisplayScreenSize(displayID)
        if size.width > 0 && size.height > 0 {
            display.physicalWidthMM = Double(size.width)
            display.physicalHeightMM = Double(size.height)
        }

        // Check if built-in (laptop) display
        display.isBuiltin = CGDisplayIsBuiltin(displayID) != 0
    }

    /// Gets the hardware display name using IOKit (deprecated but functional)
    /// Returns the base model name without macOS's automatic numbering
    private static func getHardwareDisplayName(displayID: CGDirectDisplayID) -> String? {
        // CGDisplayIOServicePort is deprecated in macOS 10.9+ and unavailable in modern Swift
        // The compiler won't allow using it even with availability checks
        // Instead, we return nil here and rely on NSScreen.localizedName
        // Our duplicate detection in StateManager will handle adding (1), (2) numbering
        //
        // Future enhancement: Could use IOKit APIs through dynamic loading if needed
        return nil
    }

    /// Gets all available displays with their information
    static func getAllDisplayInfo() -> [(CGDirectDisplayID, NSScreen)] {
        return NSScreen.screens.compactMap { screen in
            guard let displayID = getCGDisplayID(from: screen) else {
                return nil
            }
            return (displayID, screen)
        }
    }
}

/// Extension to NSScreen for easier CGDirectDisplayID access
extension NSScreen {
    var displayID: CGDirectDisplayID? {
        return deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }
}
