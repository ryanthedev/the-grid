import AppKit
import CoreGraphics
import Foundation
import IOKit

/// Helper class for enriching display information from NSScreen and CGDisplay APIs
class DisplayInfoHelper {

    /// Enriches a display with comprehensive information from NSScreen and CGDisplay
    static func enrichDisplayInfo(uuid: String, screenIndex: Int, currentSpaceID: UInt64, spaces: [UInt64]) -> DisplayState {
        var display = DisplayState(uuid: uuid, currentSpaceID: currentSpaceID, spaces: spaces)

        // Get NSScreen by index (following AeroSpace pattern)
        let screens = NSScreen.screens
        guard screenIndex >= 0 && screenIndex < screens.count else {
            // If index is out of bounds, return basic info
            return display
        }
        let screen = screens[screenIndex]

        // Extract CGDirectDisplayID
        let displayID = getCGDisplayID(from: screen)
        display.displayID = displayID

        // Extract NSScreen properties and convert to Quartz coordinates
        // NSScreen uses Cocoa coords (Y=0 at bottom, increases upward)
        // Windows use Quartz coords (Y=0 at top of MAIN display, increases downward)
        // Formula: quartz_y = main_screen_height - (cocoa_y + rect_height)
        let mainScreenHeight = NSScreen.main?.frame.height ?? screen.frame.height

        // Convert frame from Cocoa to Quartz
        let frameQuartzY = mainScreenHeight - (screen.frame.origin.y + screen.frame.height)
        display.frame = CGRect(
            x: screen.frame.origin.x,
            y: frameQuartzY,
            width: screen.frame.width,
            height: screen.frame.height
        )

        // Convert visibleFrame from Cocoa to Quartz
        let visibleQuartzY = mainScreenHeight - (screen.visibleFrame.origin.y + screen.visibleFrame.height)
        display.visibleFrame = CGRect(
            x: screen.visibleFrame.origin.x,
            y: visibleQuartzY,
            width: screen.visibleFrame.width,
            height: screen.visibleFrame.height
        )

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
