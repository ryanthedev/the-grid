//
// PermissionChecker.swift
// GridServer
//
// Checks for required macOS permissions
//

import Foundation
import ApplicationServices
import Logging

class PermissionChecker {
    private static let logger = Logger(label: "com.grid.PermissionChecker")

    static func checkAccessibilityPermission() -> Bool {
        let trusted = AXIsProcessTrusted()

        if trusted {
            logger.debug("Accessibility permission granted")
        } else {
            logger.warning("Accessibility permission NOT granted - add grid-server to System Settings > Privacy & Security > Accessibility")
        }

        return trusted
    }

    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)

        if !trusted {
            logger.notice("Accessibility permission dialog should appear...")
            logger.notice("Please grant permission and restart the application")
        }
    }
}
