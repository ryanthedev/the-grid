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
            JSONLogger.shared.log("ax.permission.granted", data: [:])
        } else {
            JSONLogger.shared.log("ax.permission.denied", data: ["msg": "add grid-server to System Settings > Privacy & Security > Accessibility"])
        }

        return trusted
    }

    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)

        if !trusted {
            JSONLogger.shared.log("ax.permission.request", data: ["msg": "dialog should appear - grant permission and restart"])
        }
    }
}
