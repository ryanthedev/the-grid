//
// StateModels.swift
// GridServer
//
// Data structures for window manager state
//

import Foundation
import CoreGraphics
import AppKit

// MARK: - Root State

struct WindowManagerState: Codable {
    var displays: [DisplayState]
    var spaces: [String: SpaceState]  // Keyed by space ID (as string for JSON compatibility)
    var windows: [String: WindowState]  // Keyed by window ID (as string for JSON compatibility)
    var applications: [String: ApplicationState]  // Keyed by PID (as string for JSON compatibility)
    var metadata: StateMetadata

    init() {
        self.displays = []
        self.spaces = [:]
        self.windows = [:]
        self.applications = [:]
        self.metadata = StateMetadata()
    }
}

// MARK: - Display State

struct DisplayState: Codable {
    // Existing fields (from SkyLight private API)
    let uuid: String
    var currentSpaceID: UInt64
    var spaces: [UInt64]  // Space IDs on this display

    // Core display properties (from NSScreen/CGDisplay)
    var displayID: UInt32?              // CGDirectDisplayID for API mapping
    var name: String?                   // User-facing name (e.g., "Built-in Retina Display")
    var frame: CGRect?                  // Full screen bounds in global coordinates
    var visibleFrame: CGRect?           // Screen area excluding menu bar/dock
    var backingScaleFactor: CGFloat?    // Retina scale factor (1.0, 2.0, etc.)
    var isMain: Bool?                   // True if primary display
    var pixelWidth: Int?                // Native pixel width
    var pixelHeight: Int?               // Native pixel height

    // Enhanced properties (optional)
    var colorSpace: String?             // Display color space name
    var refreshRate: Double?            // Refresh rate in Hz
    var physicalWidthMM: Double?        // Physical width in millimeters
    var physicalHeightMM: Double?       // Physical height in millimeters
    var isBuiltin: Bool?                // True for laptop displays

    enum CodingKeys: String, CodingKey {
        case uuid
        case currentSpaceID
        case spaces
        case displayID
        case name
        case frame
        case visibleFrame
        case backingScaleFactor
        case isMain
        case pixelWidth
        case pixelHeight
        case colorSpace
        case refreshRate
        case physicalWidthMM
        case physicalHeightMM
        case isBuiltin
    }
}

// MARK: - Space State

struct SpaceState: Codable {
    let id: UInt64
    let uuid: String
    let type: String  // "user", "fullscreen", "system"
    let displayUUID: String
    var windows: [UInt32]  // Window IDs on this space
    var isActive: Bool
    var metadata: [String: String]  // Custom metadata (string-only for JSON simplicity)

    init(id: UInt64, uuid: String, type: String, displayUUID: String) {
        self.id = id
        self.uuid = uuid
        self.type = type
        self.displayUUID = displayUUID
        self.windows = []
        self.isActive = false
        self.metadata = [:]
    }
}

// MARK: - Application State

struct ApplicationState: Codable {
    let pid: pid_t
    var bundleIdentifier: String?
    var bundleURL: String?
    var executableURL: String?
    var localizedName: String?
    var launchDate: Date?
    var activationPolicy: String
    var isHidden: Bool
    var isActive: Bool
    var isFinishedLaunching: Bool
    var executableArchitecture: String
    var windows: [UInt32]
    var metadata: [String: String]

    init(from app: NSRunningApplication) {
        self.pid = app.processIdentifier
        self.bundleIdentifier = app.bundleIdentifier
        self.bundleURL = app.bundleURL?.path
        self.executableURL = app.executableURL?.path
        self.localizedName = app.localizedName
        self.launchDate = app.launchDate

        // Map activation policy enum to string
        switch app.activationPolicy {
        case .regular:
            self.activationPolicy = "regular"
        case .accessory:
            self.activationPolicy = "accessory"
        case .prohibited:
            self.activationPolicy = "prohibited"
        @unknown default:
            self.activationPolicy = "unknown"
        }

        self.isHidden = app.isHidden
        self.isActive = app.isActive
        self.isFinishedLaunching = app.isFinishedLaunching

        // Determine architecture
        self.executableArchitecture = Self.architectureString(app.executableArchitecture)

        self.windows = []
        self.metadata = [:]
    }

    private static func architectureString(_ arch: Int) -> String {
        // CPU architecture constants
        let cpu_type_i386: Int = 7
        let cpu_type_arm64: Int = 0x0100000c

        if arch == cpu_type_i386 {
            return "intel"
        } else if arch == cpu_type_arm64 {
            return "arm64"
        } else if arch == (cpu_type_i386 | cpu_type_arm64) {
            return "universal"
        } else {
            return "unknown(\(arch))"
        }
    }
}

// MARK: - Window State

struct WindowState: Codable {
    let id: UInt32
    var frame: CGRect
    var level: Int32
    var subLevel: Int32
    var pid: pid_t
    var appName: String?
    var title: String?
    var isOrderedIn: Bool
    var isMinimized: Bool
    var spaces: [UInt64]  // Space IDs this window is on
    var alpha: Float
    var hasTransform: Bool
    var metadata: [String: String]  // Custom metadata

    // Properties for client-side filtering (from AX API)
    var role: String?       // AX role (e.g., "AXWindow", "AXButton")
    var subrole: String?    // AX subrole (e.g., "AXStandardWindow", "AXDialog")
    var parent: UInt32?     // Parent window ID (nil if root window)

    // Window button presence (for floating/popup detection)
    var hasCloseButton: Bool
    var hasFullscreenButton: Bool
    var hasMinimizeButton: Bool
    var hasZoomButton: Bool
    var isModal: Bool

    // Timestamp for conflict resolution between events and polling
    var lastUpdated: Date

    enum CodingKeys: String, CodingKey {
        case id
        case frame
        case level
        case subLevel
        case pid
        case appName
        case title
        case isOrderedIn
        case isMinimized
        case spaces
        case alpha
        case hasTransform
        case metadata
        case role
        case subrole
        case parent
        case hasCloseButton
        case hasFullscreenButton
        case hasMinimizeButton
        case hasZoomButton
        case isModal
        case lastUpdated
    }

    init(id: UInt32) {
        self.id = id
        self.frame = .zero
        self.level = 0
        self.subLevel = 0
        self.pid = 0
        self.appName = nil
        self.title = nil
        self.isOrderedIn = false
        self.isMinimized = false
        self.spaces = []
        self.alpha = 1.0
        self.hasTransform = false
        self.metadata = [:]
        self.role = nil
        self.subrole = nil
        self.parent = nil
        self.hasCloseButton = false
        self.hasFullscreenButton = false
        self.hasMinimizeButton = false
        self.hasZoomButton = false
        self.isModal = false
        self.lastUpdated = Date()
    }
}

// MARK: - State Metadata

struct StateMetadata: Codable {
    var lastUpdate: Date
    var version: String
    var connectionID: Int32
    var focusedWindowID: UInt32?  // Currently focused window (global)
    var activeDisplayUUID: String?  // Display containing focused window

    init() {
        self.lastUpdate = Date()
        self.version = "1.0.0"
        self.connectionID = 0
        self.focusedWindowID = nil
        self.activeDisplayUUID = nil
    }

    mutating func update() {
        self.lastUpdate = Date()
    }
}
