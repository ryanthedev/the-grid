//
// PermissionChecker.swift
// GridServer
//
// Checks for required macOS permissions
//

import Foundation
import ApplicationServices

class PermissionChecker {
    static func checkAccessibilityPermission() -> Bool {
        let trusted = AXIsProcessTrusted()

        if trusted {
            Task { await EventLog.shared.log("ax.permission.granted", [:]) }
        } else {
            Task { await EventLog.shared.log("ax.permission.denied", ["msg": "add grid-server to System Settings > Privacy & Security > Accessibility"]) }
        }

        return trusted
    }

    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)

        if !trusted {
            Task { await EventLog.shared.log("ax.permission.request", ["msg": "dialog should appear - grant permission and restart"]) }
        }
    }
}
