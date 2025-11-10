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
            logger.info("✓ Accessibility permission granted")
        } else {
            logger.warning("✗ Accessibility permission NOT granted")
            logger.warning("To grant permission:")
            logger.warning("1. Open System Settings → Privacy & Security → Accessibility")
            logger.warning("2. Add 'grid-server' or 'Terminal' to the allowed apps")
            logger.warning("3. Restart the application")
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
