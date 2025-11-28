//
// StateManager.swift
// GridServer
//
// Manages window manager state with event-driven updates
//

import Foundation
import CoreGraphics
import AppKit
import Logging

// Private AX API for getting window ID from AXUIElement
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<UInt32>) -> AXError

class StateManager {
    // MARK: - Singleton

    static let shared = StateManager()

    // MARK: - Properties

    private var state: WindowManagerState
    private let connectionID: Int32
    private let logger = Logger(label: "com.grid.StateManager")
    private let queue = DispatchQueue(label: "com.grid.StateManager", qos: .userInitiated)

    // AX Observers (one per application)
    private var applicationObservers: [pid_t: ApplicationObserver] = [:]

    // Workspace observer (system-level events)
    private var workspaceObserver: WorkspaceObserver?

    // MSS client for window manipulation and sticky detection
    private let mssClient: MSSClient

    // Polling timer for periodic state refresh
    private var pollTimer: DispatchSourceTimer?

    // MARK: - Initialization

    private init() {
        self.connectionID = SLSMainConnectionID()
        self.state = WindowManagerState()
        self.state.metadata.connectionID = self.connectionID
        self.mssClient = MSSClient(logger: Logger(label: "com.grid.StateManager.MSS"))

        logger.info("StateManager initialized with connection ID: \(self.connectionID)")
    }

    // MARK: - Public Interface

    func start() {
        logger.info("Starting StateManager...")

        queue.async {
            // Build initial state
            self.refreshCompleteState()

            // Set up workspace observer (must be on main thread)
            DispatchQueue.main.async {
                let workspace = WorkspaceObserver()
                workspace.observe(stateManager: self)
                self.workspaceObserver = workspace
            }

            // Create AX observers for existing applications
            self.observeExistingApplications()

            // Start periodic polling to catch windows that events miss
            self.startPolling(interval: 3.0)

            self.logger.info("StateManager started successfully")
        }
    }

    func getState() -> WindowManagerState {
        return queue.sync {
            return state
        }
    }

    func getStateJSON() throws -> Data {
        let state = getState()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(state)
    }

    func getStateDictionary() throws -> WindowManagerState {
        // Return the Codable state directly instead of converting to dictionary
        // This preserves type information (UInt64, UInt32, etc.) without
        // JSONSerialization's type coercion that converts 0/1 to false/true
        return getState()
    }

    // MARK: - State Refresh

    private func refreshCompleteState() {
        logger.info("Refreshing complete state...")

        // Refresh in order: displays -> spaces -> applications -> windows
        refreshDisplays()
        refreshSpaces()
        refreshApplications()
        refreshWindows()

        state.metadata.update()
        logger.info("Complete state refresh finished")
    }

    private func refreshApplications() {
        let beforeCount = state.applications.count
        logger.debug("Refreshing applications...", metadata: ["current": "\(beforeCount)"])

        let runningApps = NSWorkspace.shared.runningApplications
        var applications: [String: ApplicationState] = [:]

        for app in runningApps {
            // Only track regular apps (skip system services, etc.)
            guard app.activationPolicy == .regular else { continue }

            let appState = ApplicationState(from: app)
            applications[String(app.processIdentifier)] = appState
        }

        let afterCount = applications.count
        let change = afterCount - beforeCount
        let changeStr = change > 0 ? "+\(change)" : "\(change)"

        state.applications = applications
        logger.info("Applications refreshed", metadata: [
            "count": "\(afterCount)",
            "change": change != 0 ? "\(changeStr)" : "no change"
        ])
    }

    private func refreshDisplays() {
        let beforeCount = state.displays.count
        logger.debug("Refreshing displays...", metadata: ["current": "\(beforeCount)"])

        guard let displaysArray = SLSCopyManagedDisplays(connectionID) else {
            logger.warning("Failed to get managed displays")
            return
        }

        let displayUUIDs: [String] = cfArrayToSwiftArray(displaysArray)

        var displays: [DisplayState] = []
        for (index, displayUUID) in displayUUIDs.enumerated() {
            let currentSpaceID = SLSManagedDisplayGetCurrentSpace(connectionID, displayUUID as CFString)

            // Enrich display with comprehensive information from NSScreen/CGDisplay
            let display = DisplayInfoHelper.enrichDisplayInfo(
                uuid: displayUUID,
                screenIndex: index,
                currentSpaceID: currentSpaceID,
                spaces: []  // Will be populated in refreshSpaces
            )
            displays.append(display)
        }

        let afterCount = displays.count
        let change = afterCount - beforeCount
        let changeStr = change > 0 ? "+\(change)" : "\(change)"

        state.displays = displays
        logger.info("Displays refreshed", metadata: [
            "count": "\(afterCount)",
            "change": change != 0 ? "\(changeStr)" : "no change"
        ])
    }

    private func refreshSpaces() {
        let beforeCount = state.spaces.count
        logger.debug("Refreshing spaces...", metadata: ["current": "\(beforeCount)"])

        guard let spacesArray = SLSCopyManagedDisplaySpaces(connectionID) else {
            logger.warning("Failed to get managed display spaces")
            return
        }

        var spaces: [String: SpaceState] = [:]
        var displaySpaces: [String: [UInt64]] = [:]  // Track spaces per display

        // Parse the spaces array
        let displayInfos: [NSDictionary] = cfArrayToSwiftArray(spacesArray)

        for displayInfo in displayInfos {
            guard let displayUUID = displayInfo["Display Identifier"] as? String,
                  let spacesForDisplay = displayInfo["Spaces"] as? [NSDictionary] else {
                continue
            }

            var spaceIDs: [UInt64] = []

            for spaceDict in spacesForDisplay {
                guard let spaceID = extractSpaceID(from: spaceDict) else {
                    continue
                }

                spaceIDs.append(spaceID)

                let uuid = spaceDict["uuid"] as? String ?? ""
                let typeValue = (spaceDict["type"] as? NSNumber)?.int32Value ?? 0
                let spaceType = SpaceType(rawValue: typeValue) ?? .user

                var spaceState = SpaceState(
                    id: spaceID,
                    uuid: uuid,
                    type: spaceType.description,
                    displayUUID: displayUUID
                )

                // Check if this is the active space for its display
                if let display = state.displays.first(where: { $0.uuid == displayUUID }) {
                    spaceState.isActive = (spaceID == display.currentSpaceID)
                }

                spaces[String(spaceID)] = spaceState
            }

            displaySpaces[displayUUID] = spaceIDs
        }

        // Update display space lists
        for i in 0..<state.displays.count {
            if let spaceIDs = displaySpaces[state.displays[i].uuid] {
                state.displays[i].spaces = spaceIDs
            }
        }

        let afterCount = spaces.count
        let change = afterCount - beforeCount
        let changeStr = change > 0 ? "+\(change)" : "\(change)"

        state.spaces = spaces
        logger.info("Spaces refreshed", metadata: [
            "count": "\(afterCount)",
            "displays": "\(state.displays.count)",
            "change": change != 0 ? "\(changeStr)" : "no change"
        ])

        // Log all discovered spaces for debugging
        let spaceDetails = spaces.values.map { space in
            "ID:\(space.id) type:\(space.type) active:\(space.isActive)"
        }.joined(separator: " | ")
        logger.info("🔍 DEBUG: All discovered spaces", metadata: [
            "spaceIDs": "\(spaces.keys.sorted().joined(separator: ", "))",
            "details": "\(spaceDetails)"
        ])
    }

    /// Get the current space for a window using fallback mechanism
    /// Returns 0 if unable to determine the space
    private func getCurrentSpaceForWindow(_ windowID: UInt32) -> UInt64 {
        // Get the display UUID for this window
        guard let displayUUID = SLSCopyManagedDisplayForWindow(connectionID, windowID) else {
            logger.debug("Failed to get display for window \(windowID)")
            return 0
        }

        // Get the current space on that display
        let spaceID = SLSManagedDisplayGetCurrentSpace(connectionID, displayUUID)
        return spaceID
    }

    /// Get all user space IDs from current state
    /// Returns array of all user space IDs (excludes fullscreen spaces)
    private func getAllUserSpaceIDs() -> [UInt64] {
        return state.spaces.values
            .filter { $0.type == "user" }
            .map { $0.id }
    }

    /// Result of AX property collection for a window
    struct AXWindowProperties {
        var role: String?
        var subrole: String?
        var parent: UInt32?
        var hasCloseButton: Bool = false
        var hasFullscreenButton: Bool = false
        var hasMinimizeButton: Bool = false
        var hasZoomButton: Bool = false
        var isModal: Bool = false
    }

    /// Get AX properties for a window (role, subrole, buttons, modal status)
    /// Used for client-side floating/popup detection
    private func getAXProperties(pid: pid_t, windowID: UInt32) -> AXWindowProperties {
        var props = AXWindowProperties()
        let appElement = AXUIElementCreateApplication(pid)

        // Get windows for this application
        var windowsValue: CFTypeRef?
        let windowsResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsValue
        )

        guard windowsResult == .success,
              let windows = windowsValue as? [AXUIElement] else {
            logger.debug("🔍 AX: Failed to get windows for pid \(pid), windowID \(windowID), error: \(windowsResult.rawValue)")
            return props
        }

        logger.debug("🔍 AX: pid \(pid) has \(windows.count) AX windows, looking for CGWindow \(windowID)")

        // Find the matching window element
        for windowElement in windows {
            var cgWindowID: UInt32 = 0
            let result = _AXUIElementGetWindow(windowElement, &cgWindowID)

            if result == .success && cgWindowID == windowID {
                // Get role
                var roleValue: CFTypeRef?
                AXUIElementCopyAttributeValue(windowElement, kAXRoleAttribute as CFString, &roleValue)
                props.role = roleValue as? String

                // Get subrole
                var subroleValue: CFTypeRef?
                AXUIElementCopyAttributeValue(windowElement, kAXSubroleAttribute as CFString, &subroleValue)
                props.subrole = subroleValue as? String

                // Get parent window (if any)
                var parentValue: CFTypeRef?
                AXUIElementCopyAttributeValue(windowElement, kAXParentAttribute as CFString, &parentValue)
                if let parentElement = parentValue {
                    var parentCGID: UInt32 = 0
                    if _AXUIElementGetWindow(parentElement as! AXUIElement, &parentCGID) == .success {
                        props.parent = parentCGID
                    }
                }

                // Get button presence (for floating/popup detection)
                var closeBtn: CFTypeRef?
                if AXUIElementCopyAttributeValue(windowElement, kAXCloseButtonAttribute as CFString, &closeBtn) == .success {
                    props.hasCloseButton = closeBtn != nil
                }

                var fullscreenBtn: CFTypeRef?
                if AXUIElementCopyAttributeValue(windowElement, kAXFullScreenButtonAttribute as CFString, &fullscreenBtn) == .success {
                    props.hasFullscreenButton = fullscreenBtn != nil
                }

                var minimizeBtn: CFTypeRef?
                if AXUIElementCopyAttributeValue(windowElement, kAXMinimizeButtonAttribute as CFString, &minimizeBtn) == .success {
                    props.hasMinimizeButton = minimizeBtn != nil
                }

                var zoomBtn: CFTypeRef?
                if AXUIElementCopyAttributeValue(windowElement, kAXZoomButtonAttribute as CFString, &zoomBtn) == .success {
                    props.hasZoomButton = zoomBtn != nil
                }

                // Get modal status
                var modalValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(windowElement, kAXModalAttribute as CFString, &modalValue) == .success {
                    props.isModal = (modalValue as? Bool) ?? false
                }

                logger.debug("🔍 AX: Matched windowID \(windowID): role=\(props.role ?? "nil"), subrole=\(props.subrole ?? "nil"), buttons=[\(props.hasCloseButton ? "close" : "")|\(props.hasFullscreenButton ? "fs" : "")|\(props.hasMinimizeButton ? "min" : "")|\(props.hasZoomButton ? "zoom" : "")], modal=\(props.isModal)")
                return props
            }
        }

        logger.debug("🔍 AX: No AX window matched CGWindow \(windowID) in pid \(pid) (checked \(windows.count) windows)")
        return props
    }

    /// Public method to update window spaces (for WindowManipulator)
    func updateWindowSpacesPublic(_ windowID: UInt32) {
        queue.async {
            self.updateWindowSpaces(windowID)
        }
    }

    /// Re-query and update space assignment for a specific window
    /// Called after window moves or space changes to get fresh space data
    private func updateWindowSpaces(_ windowID: UInt32) {
        guard var window = state.windows[String(windowID)] else { return }

        // Query spaces using SkyLight API with properly typed CFArray
        let windowArray = createWindowIDArray([windowID])
        if let spacesArray = SLSCopySpacesForWindows(connectionID, 0x7, windowArray) {
            // Result is flat array of space IDs (CFNumbers)
            let spaceNumbers: [NSNumber] = cfArrayToSwiftArray(spacesArray)
            if !spaceNumbers.isEmpty {
                // Success - update with actual spaces
                window.spaces = spaceNumbers.map { $0.uint64Value }
                state.windows[String(windowID)] = window
                logger.trace("Updated window space assignment", metadata: [
                    "windowID": "\(windowID)",
                    "spaces": "\(spaceNumbers.map { $0.uint64Value })"
                ])
            } else {
                // API returned empty - mark as unknown
                window.spaces = []
                state.windows[String(windowID)] = window
                logger.trace("Window spaces unknown after re-query", metadata: [
                    "windowID": "\(windowID)"
                ])
            }
        } else {
            // API call failed - mark as unknown
            window.spaces = []
            state.windows[String(windowID)] = window
            logger.trace("SLSCopySpacesForWindows failed during re-query", metadata: [
                "windowID": "\(windowID)"
            ])
        }
    }

    private func refreshWindows() {
        let beforeCount = state.windows.count
        logger.debug("Refreshing windows...", metadata: ["current": "\(beforeCount)"])

        // Use public CGWindowListCopyWindowInfo API instead of private SkyLight API
        // This is safer and won't crash, though it provides slightly different data
        // Use .optionAll to get windows from all spaces, not just the active space
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            logger.warning("Failed to get window list")
            return
        }

        logger.debug("Found \(windowList.count) windows from CGWindowList (all spaces)")
        logger.info("🔍 DEBUG: Starting window enumeration", metadata: [
            "totalWindows": "\(windowList.count)",
            "knownSpaces": "\(state.spaces.keys.sorted().joined(separator: ", "))"
        ])

        var windows: [String: WindowState] = [:]

        // Process each window from CGWindowList
        for windowInfo in windowList {
            // Extract window properties from CGWindow dictionary
            guard let windowID = windowInfo[kCGWindowNumber as String] as? UInt32 else {
                continue
            }

            var windowState = WindowState(id: windowID)

            // Get window bounds from CGWindow data
            if let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat] {
                let x = boundsDict["X"] ?? 0
                let y = boundsDict["Y"] ?? 0
                let width = boundsDict["Width"] ?? 0
                let height = boundsDict["Height"] ?? 0
                windowState.frame = CGRect(x: x, y: y, width: width, height: height)
            }

            // Get window level
            if let level = windowInfo[kCGWindowLayer as String] as? Int32 {
                windowState.level = level
            }

            // Get window alpha
            if let alpha = windowInfo[kCGWindowAlpha as String] as? Float {
                windowState.alpha = alpha
            }

            // Get window owner PID
            if let pid = windowInfo[kCGWindowOwnerPID as String] as? pid_t {
                windowState.pid = pid

                // Get app name from PID
                windowState.appName = getAppNameForPID(pid)

                // Get window name/title if available
                if let name = windowInfo[kCGWindowName as String] as? String {
                    windowState.title = name
                } else if let ownerName = windowInfo[kCGWindowOwnerName as String] as? String {
                    windowState.title = ownerName
                }

                // Get AX properties for client-side filtering
                let axProps = getAXProperties(pid: pid, windowID: windowID)
                windowState.role = axProps.role
                windowState.subrole = axProps.subrole
                windowState.parent = axProps.parent
                windowState.hasCloseButton = axProps.hasCloseButton
                windowState.hasFullscreenButton = axProps.hasFullscreenButton
                windowState.hasMinimizeButton = axProps.hasMinimizeButton
                windowState.hasZoomButton = axProps.hasZoomButton
                windowState.isModal = axProps.isModal
            }

            // Window is on-screen if it's in the list (we filtered for on-screen only)
            windowState.isOrderedIn = true

            // Get spaces for this window - check sticky first, then use SkyLight API
            // 1. Check if window is sticky (visible on all spaces) using MSS
            if let isSticky = mssClient.isWindowSticky(windowID), isSticky {
                // Sticky windows are on all user spaces
                windowState.spaces = getAllUserSpaceIDs()
                logger.info("🔍 DEBUG: Window is sticky (on all spaces)", metadata: [
                    "windowID": "\(windowID)",
                    "appName": "\(windowState.appName ?? "unknown")",
                    "title": "\(String(windowState.title?.prefix(30) ?? "untitled"))",
                    "spaces": "\(windowState.spaces)",
                    "method": "MSS sticky detection"
                ])
            } else {
                // 2. Not sticky - try to get spaces using SkyLight API with properly typed CFArray
                let windowArray = createWindowIDArray([windowID])
                if let spacesArray = SLSCopySpacesForWindows(connectionID, 0x7, windowArray) {
                    // Result is flat array of space IDs (CFNumbers)
                    let spaceNumbers: [NSNumber] = cfArrayToSwiftArray(spacesArray)
                    if !spaceNumbers.isEmpty {
                        // Success - we know the actual spaces
                        windowState.spaces = spaceNumbers.map { $0.uint64Value }
                        logger.info("🔍 DEBUG: Window space assignment", metadata: [
                            "windowID": "\(windowID)",
                            "appName": "\(windowState.appName ?? "unknown")",
                            "title": "\(String(windowState.title?.prefix(30) ?? "untitled"))",
                            "spaces": "\(spaceNumbers.map { $0.uint64Value })",
                            "method": "SLSCopySpacesForWindows"
                        ])
                    } else {
                        // API returned empty - we don't know which spaces this window is on
                        // Leave as empty array, will be updated via events when we get definitive info
                        windowState.spaces = []
                    }
                } else {
                    // API call failed - we don't know which spaces this window is on
                    // Leave as empty array, will be updated via events when we get definitive info
                    windowState.spaces = []
                }
            }

            // Store window state
            windows[String(windowID)] = windowState
        }

        // Update space window lists and application window lists
        for (_, window) in windows {
            // Add window to app's window list
            let pidKey = String(window.pid)
            if state.applications[pidKey] != nil {
                if !state.applications[pidKey]!.windows.contains(window.id) {
                    state.applications[pidKey]!.windows.append(window.id)
                }
            }

            // Add window to space's window list
            for spaceID in window.spaces {
                let spaceKey = String(spaceID)
                if state.spaces[spaceKey] != nil {
                    if !state.spaces[spaceKey]!.windows.contains(window.id) {
                        state.spaces[spaceKey]!.windows.append(window.id)
                    }
                }
            }
        }

        let afterCount = windows.count
        let change = afterCount - beforeCount
        let changeStr = change > 0 ? "+\(change)" : "\(change)"

        state.windows = windows
        logger.info("Windows refreshed", metadata: [
            "count": "\(afterCount)",
            "change": change != 0 ? "\(changeStr)" : "no change"
        ])

        // Log space distribution for debugging
        var spaceDistribution: [String: Int] = [:]
        for (_, window) in windows {
            for spaceID in window.spaces {
                let key = String(spaceID)
                spaceDistribution[key, default: 0] += 1
            }
        }
        let distributionMetadata: Logger.Metadata = spaceDistribution.sorted { $0.key < $1.key }
            .reduce(into: [:]) { result, pair in
                result["space_\(pair.key)"] = Logger.MetadataValue(stringLiteral: "\(pair.value)")
            }
        logger.info("🔍 DEBUG: Window distribution across spaces", metadata: distributionMetadata)
    }

    // MARK: - Observer Management

    /// Create AX observers for all running applications
    private func observeExistingApplications() {
        let runningApps = NSWorkspace.shared.runningApplications

        logger.info("Creating AX observers for existing applications", metadata: [
            "count": "\(runningApps.count)"
        ])

        for app in runningApps {
            // Skip system apps and apps without windows
            guard app.activationPolicy == .regular else { continue }

            createObserver(for: app)
        }

        logger.info("AX observers created", metadata: [
            "count": "\(applicationObservers.count)"
        ])
    }

    /// Create an AX observer for a specific application
    private func createObserver(for app: NSRunningApplication) {
        let pid = app.processIdentifier

        // Don't create duplicate observers
        guard applicationObservers[pid] == nil else { return }

        let observer = ApplicationObserver(pid: pid, appName: app.localizedName)

        // Must be on main thread for run loop
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            if observer.observe(stateManager: self) {
                self.queue.async {
                    self.applicationObservers[pid] = observer
                }
            }
        }
    }

    /// Remove an AX observer for a specific application
    private func removeObserver(for pid: pid_t) {
        guard let observer = applicationObservers[pid] else { return }

        DispatchQueue.main.async {
            observer.stopObserving()
        }

        applicationObservers.removeValue(forKey: pid)

        logger.debug("AX observer removed", metadata: ["pid": "\(pid)"])
    }

    // MARK: - Polling

    /// Start periodic window state polling
    func startPolling(interval: TimeInterval = 3.0) {
        stopPolling()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.pollWindowState()
        }
        timer.resume()
        pollTimer = timer
        logger.info("Started window polling", metadata: ["interval": "\(interval)s"])
    }

    /// Stop periodic window state polling
    func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    /// Poll window state from CGWindowList
    private func pollWindowState() {
        let pollTimestamp = Date()

        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return
        }

        var seenWindowIDs = Set<UInt32>()

        for windowInfo in windowList {
            guard let windowID = windowInfo[kCGWindowNumber as String] as? UInt32 else { continue }
            seenWindowIDs.insert(windowID)

            if let existing = state.windows[String(windowID)] {
                // Window exists - only update if our data is newer
                if existing.lastUpdated < pollTimestamp {
                    updateWindowFromPoll(windowID: windowID, windowInfo: windowInfo, timestamp: pollTimestamp)
                }
                // else: skip - event data is fresher
            } else {
                // New window discovered by poll
                addWindowFromPoll(windowID: windowID, windowInfo: windowInfo, timestamp: pollTimestamp)
            }
        }

        // Remove windows no longer in CGWindowList
        for windowKey in state.windows.keys {
            if let windowID = UInt32(windowKey), !seenWindowIDs.contains(windowID) {
                logger.info("📡 Poll: removing stale window", metadata: ["windowID": "\(windowID)"])
                // Inline removal logic (don't call handleWindowDestroyed to avoid log confusion)
                let pid = state.windows[windowKey]?.pid
                if state.metadata.focusedWindowID == windowID {
                    state.metadata.focusedWindowID = nil
                }
                state.windows.removeValue(forKey: windowKey)
                if let pid = pid {
                    state.applications[String(pid)]?.windows.removeAll { $0 == windowID }
                }
                for spaceKey in state.spaces.keys {
                    state.spaces[spaceKey]?.windows.removeAll { $0 == windowID }
                }
            }
        }

        state.metadata.update()
    }

    /// Update existing window from poll data
    private func updateWindowFromPoll(windowID: UInt32, windowInfo: [String: Any], timestamp: Date) {
        guard var window = state.windows[String(windowID)] else { return }

        // Update frame
        if let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat] {
            window.frame = CGRect(
                x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0
            )
        }

        // Update title
        if let name = windowInfo[kCGWindowName as String] as? String {
            window.title = name
        }

        window.lastUpdated = timestamp
        state.windows[String(windowID)] = window

        // Refresh space assignment
        updateWindowSpaces(windowID)
    }

    /// Add new window discovered by poll
    private func addWindowFromPoll(windowID: UInt32, windowInfo: [String: Any], timestamp: Date) {
        var window = WindowState(id: windowID)

        if let pid = windowInfo[kCGWindowOwnerPID as String] as? pid_t {
            window.pid = pid
            window.appName = getAppNameForPID(pid)

            // Add to app's window list
            let pidKey = String(pid)
            if state.applications[pidKey] != nil {
                if !state.applications[pidKey]!.windows.contains(windowID) {
                    state.applications[pidKey]!.windows.append(windowID)
                }
            }
        }

        if let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat] {
            window.frame = CGRect(
                x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0
            )
        }

        if let name = windowInfo[kCGWindowName as String] as? String {
            window.title = name
        } else if let ownerName = windowInfo[kCGWindowOwnerName as String] as? String {
            window.title = ownerName
        }

        window.isOrderedIn = true
        window.lastUpdated = timestamp

        // Get AX properties
        let axProps = getAXProperties(pid: window.pid, windowID: windowID)
        window.role = axProps.role
        window.subrole = axProps.subrole
        window.parent = axProps.parent
        window.hasCloseButton = axProps.hasCloseButton
        window.hasFullscreenButton = axProps.hasFullscreenButton
        window.hasMinimizeButton = axProps.hasMinimizeButton
        window.hasZoomButton = axProps.hasZoomButton
        window.isModal = axProps.isModal

        state.windows[String(windowID)] = window
        updateWindowSpaces(windowID)

        logger.info("📡 Poll discovered window", metadata: [
            "windowID": "\(windowID)",
            "app": "\(window.appName ?? "unknown")"
        ])
    }

    // MARK: - AX Event Handlers (Per-Window Events)

    func handleWindowCreated(_ windowID: UInt32, pid: pid_t) {
        queue.async {
            self.logger.info("🪟 Window created", metadata: [
                "windowID": "\(windowID)",
                "pid": "\(pid)"
            ])

            // Create new window state
            var window = WindowState(id: windowID)
            window.pid = pid
            window.appName = getAppNameForPID(pid)
            window.isOrderedIn = true

            // Query window properties from CGWindowList
            let options: CGWindowListOption = [.optionIncludingWindow]
            if let windowList = CGWindowListCopyWindowInfo(options, windowID) as? [[String: Any]],
               let windowInfo = windowList.first {
                // Get frame
                if let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat] {
                    window.frame = CGRect(
                        x: boundsDict["X"] ?? 0,
                        y: boundsDict["Y"] ?? 0,
                        width: boundsDict["Width"] ?? 0,
                        height: boundsDict["Height"] ?? 0
                    )
                }
                // Get title
                if let name = windowInfo[kCGWindowName as String] as? String {
                    window.title = name
                } else if let ownerName = windowInfo[kCGWindowOwnerName as String] as? String {
                    window.title = ownerName
                }
            }

            // Get AX properties
            let axProps = self.getAXProperties(pid: pid, windowID: windowID)
            window.role = axProps.role
            window.subrole = axProps.subrole
            window.parent = axProps.parent
            window.hasCloseButton = axProps.hasCloseButton
            window.hasFullscreenButton = axProps.hasFullscreenButton
            window.hasMinimizeButton = axProps.hasMinimizeButton
            window.hasZoomButton = axProps.hasZoomButton
            window.isModal = axProps.isModal

            self.state.windows[String(windowID)] = window

            // Query space assignment
            self.updateWindowSpaces(windowID)

            // Add window to app's window list
            let pidKey = String(pid)
            if self.state.applications[pidKey] != nil {
                if !self.state.applications[pidKey]!.windows.contains(windowID) {
                    self.state.applications[pidKey]!.windows.append(windowID)
                }
            }

            self.state.metadata.update()
        }
    }

    func handleWindowDestroyed(_ windowID: UInt32) {
        queue.async {
            self.logger.info("💀 Window destroyed", metadata: ["windowID": "\(windowID)"])

            // Get PID before removing window
            let pid = self.state.windows[String(windowID)]?.pid

            // Clear focus if destroyed window was focused
            if self.state.metadata.focusedWindowID == windowID {
                self.logger.debug("Clearing focus (focused window destroyed)")
                self.state.metadata.focusedWindowID = nil
                // Note: activeDisplayUUID remains until new window is focused
            }

            // Remove from state
            self.state.windows.removeValue(forKey: String(windowID))

            // Remove from app's window list
            if let pid = pid {
                let pidKey = String(pid)
                self.state.applications[pidKey]?.windows.removeAll { $0 == windowID }
            }

            // Remove from space window lists
            for spaceKey in self.state.spaces.keys {
                self.state.spaces[spaceKey]?.windows.removeAll { $0 == windowID }
            }

            self.state.metadata.update()
        }
    }

    func handleWindowMoved(_ windowID: UInt32, frame: CGRect) {
        queue.async {
            self.logger.debug("→ Window moved", metadata: [
                "windowID": "\(windowID)",
                "frame": "(\(frame.origin.x),\(frame.origin.y) \(frame.size.width)x\(frame.size.height))"
            ])

            guard var window = self.state.windows[String(windowID)] else { return }
            window.frame = frame
            window.lastUpdated = Date()
            self.state.windows[String(windowID)] = window

            // Re-query space assignment after move
            self.updateWindowSpaces(windowID)

            self.state.metadata.update()
        }
    }

    func handleWindowResized(_ windowID: UInt32, frame: CGRect) {
        queue.async {
            self.logger.debug("↔️ Window resized", metadata: [
                "windowID": "\(windowID)",
                "frame": "(\(frame.origin.x),\(frame.origin.y) \(frame.size.width)x\(frame.size.height))"
            ])

            guard var window = self.state.windows[String(windowID)] else { return }
            window.frame = frame
            window.lastUpdated = Date()
            self.state.windows[String(windowID)] = window
            self.state.metadata.update()
        }
    }

    func handleWindowFocused(_ windowID: UInt32) {
        queue.async {
            self.logger.info("🎯 Window focused", metadata: ["windowID": "\(windowID)"])

            // Store focused window ID
            self.state.metadata.focusedWindowID = windowID

            // Determine active display from focused window
            if let displayUUID = SLSCopyManagedDisplayForWindow(self.connectionID, windowID) {
                let displayStr = displayUUID as String

                // Only log if display changed
                if self.state.metadata.activeDisplayUUID != displayStr {
                    self.logger.info("🖥️  Active display changed", metadata: [
                        "displayUUID": "\(displayStr)",
                        "windowID": "\(windowID)"
                    ])
                }

                self.state.metadata.activeDisplayUUID = displayStr
            }

            self.state.metadata.update()
        }
    }

    func handleWindowMinimized(_ windowID: UInt32) {
        queue.async {
            self.logger.debug("⬇️ Window minimized", metadata: ["windowID": "\(windowID)"])

            guard var window = self.state.windows[String(windowID)] else { return }
            window.isMinimized = true
            window.isOrderedIn = false
            window.lastUpdated = Date()
            self.state.windows[String(windowID)] = window
            self.state.metadata.update()
        }
    }

    func handleWindowDeminimized(_ windowID: UInt32) {
        queue.async {
            self.logger.debug("⬆️ Window deminimized", metadata: ["windowID": "\(windowID)"])

            guard var window = self.state.windows[String(windowID)] else { return }
            window.isMinimized = false
            window.isOrderedIn = true
            window.lastUpdated = Date()
            self.state.windows[String(windowID)] = window
            self.state.metadata.update()
        }
    }

    func handleWindowTitleChanged(_ windowID: UInt32, title: String) {
        queue.async {
            self.logger.debug("📝 Window title changed", metadata: [
                "windowID": "\(windowID)",
                "title": "\(title)"
            ])

            guard var window = self.state.windows[String(windowID)] else { return }
            window.title = title
            window.lastUpdated = Date()
            self.state.windows[String(windowID)] = window
            self.state.metadata.update()
        }
    }

    // MARK: - NSWorkspace Event Handlers (System Events)

    func handleSpaceChanged() {
        queue.async {
            self.logger.info("Space changed - refreshing spaces and window assignments")
            self.refreshSpaces()

            // Re-query space assignments for all visible windows
            for windowKey in self.state.windows.keys {
                if let windowID = UInt32(windowKey),
                   let window = self.state.windows[windowKey],
                   window.isOrderedIn && !window.isMinimized {
                    self.updateWindowSpaces(windowID)
                }
            }

            self.state.metadata.update()
        }
    }

    func handleDisplayConfigurationChanged() {
        queue.async {
            self.logger.info("Display configuration changed - full refresh")
            self.refreshDisplays()
            self.refreshSpaces()
            self.state.metadata.update()
        }
    }

    func handleApplicationLaunched(_ app: NSRunningApplication) {
        queue.async {
            guard app.activationPolicy == .regular else { return }

            // Create ApplicationState
            let appState = ApplicationState(from: app)
            let pidKey = String(app.processIdentifier)
            self.state.applications[pidKey] = appState

            self.logger.info("📱 Application launched and tracked", metadata: [
                "pid": "\(app.processIdentifier)",
                "app": "\(app.localizedName ?? "unknown")",
                "bundleID": "\(app.bundleIdentifier ?? "unknown")"
            ])

            // Create AX observer
            self.createObserver(for: app)

            self.state.metadata.update()
        }
    }

    func handleApplicationTerminated(_ app: NSRunningApplication) {
        queue.async {
            let pid = app.processIdentifier
            let pidKey = String(pid)

            // Clear focus if any window from terminated app was focused
            if let focusedID = self.state.metadata.focusedWindowID,
               let focusedWindow = self.state.windows[String(focusedID)],
               focusedWindow.pid == pid {
                self.logger.debug("Clearing focus (app terminated)", metadata: ["pid": "\(pid)"])
                self.state.metadata.focusedWindowID = nil
            }

            // Remove application state
            self.state.applications.removeValue(forKey: pidKey)

            // Remove observer
            self.removeObserver(for: pid)

            // Remove all windows for this PID
            self.state.windows = self.state.windows.filter { $0.value.pid != pid }

            self.state.metadata.update()
        }
    }

    func handleApplicationActivated(_ app: NSRunningApplication) {
        queue.async {
            let pid = app.processIdentifier
            let pidKey = String(pid)

            // Update all apps to mark which one is active
            for (key, var appState) in self.state.applications {
                appState.isActive = (key == pidKey)
                self.state.applications[key] = appState
            }

            self.state.metadata.update()
        }
    }

    func handleApplicationHidden(_ app: NSRunningApplication) {
        queue.async {
            let pid = app.processIdentifier
            let pidKey = String(pid)

            // Update app state
            if self.state.applications[pidKey] != nil {
                self.state.applications[pidKey]!.isHidden = true
            }

            // Mark all windows for this app as not ordered in
            for (key, var window) in self.state.windows where window.pid == pid {
                window.isOrderedIn = false
                self.state.windows[key] = window
            }

            self.state.metadata.update()
        }
    }

    func handleApplicationUnhidden(_ app: NSRunningApplication) {
        queue.async {
            let pid = app.processIdentifier
            let pidKey = String(pid)

            // Update app state
            if self.state.applications[pidKey] != nil {
                self.state.applications[pidKey]!.isHidden = false
            }

            // Mark all windows for this app as ordered in and re-query their spaces
            for (key, var window) in self.state.windows where window.pid == pid {
                window.isOrderedIn = true
                self.state.windows[key] = window

                // Re-query space assignment (may have changed while hidden)
                self.updateWindowSpaces(window.id)
            }

            self.state.metadata.update()
        }
    }

    func handleSystemWoke() {
        queue.async {
            self.logger.info("System woke - full state refresh")
            self.refreshCompleteState()
        }
    }

    // MARK: - Mouse Position Helpers

    /// Get current mouse position in global screen coordinates (query-based, not event-driven)
    func getCurrentMousePosition() -> CGPoint {
        guard let event = CGEvent(source: nil) else {
            logger.warning("Failed to create CGEvent for mouse position query")
            return .zero
        }
        return event.location
    }

    /// Determine which display contains a given point
    func getDisplayUUIDAtPoint(_ point: CGPoint) -> String? {
        // Get all online displays
        var displayCount: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)

        let error = CGGetOnlineDisplayList(32, &displays, &displayCount)
        guard error == .success else {
            logger.warning("Failed to get display list", metadata: ["error": "\(error.rawValue)"])
            return nil
        }

        // Check each display's bounds
        for i in 0..<Int(displayCount) {
            let displayID = displays[i]
            let bounds = CGDisplayBounds(displayID)

            if bounds.contains(point) {
                // Try to match with our display UUIDs
                // For simple case, convert displayID to string and match
                // In reality, we'd need to map CGDirectDisplayID to UUID

                // For now, return the first display's UUID from our state
                // that we can identify (this is a simplified implementation)
                if let firstDisplay = state.displays.first {
                    return firstDisplay.uuid
                }
            }
        }

        return nil
    }

    /// Get the display UUID where the mouse cursor is currently located
    func getDisplayAtMousePosition() -> String? {
        let mousePos = getCurrentMousePosition()
        return getDisplayUUIDAtPoint(mousePos)
    }
}

