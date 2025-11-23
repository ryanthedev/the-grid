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

class StateManager {
    // MARK: - Singleton

    static let shared = StateManager()

    // MARK: - Properties

    private var state: WindowManagerState
    private let connectionID: Int32
    private let logger = Logger(label: "com.grid.StateManager")
    private let queue = DispatchQueue(label: "com.grid.StateManager", qos: .userInitiated)
    private var eventContexts: [EventContext] = []  // Keep contexts alive (SkyLight - currently unused)

    // AX Observers (one per application)
    private var applicationObservers: [pid_t: ApplicationObserver] = [:]

    // Workspace observer (system-level events)
    private var workspaceObserver: WorkspaceObserver?

    // MSS client for window manipulation and sticky detection
    private let mssClient: MSSClient

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

            // Register for window server events (SkyLight - currently not working)
            // self.registerEventHandlers()

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
                // 2. Not sticky - try to get spaces using SkyLight API
                let windowArray = [windowID as CFNumber] as CFArray
                if let spacesArray = SLSCopySpacesForWindows(connectionID, 0x7, windowArray) {
                    // Result is array of arrays (one per window)
                    let spaceArrays: [[NSNumber]] = cfArrayToSwiftArray(spacesArray)
                    if let firstArray = spaceArrays.first, !firstArray.isEmpty {
                        // Success - we know the actual spaces
                        windowState.spaces = firstArray.map { $0.uint64Value }
                        logger.info("🔍 DEBUG: Window space assignment", metadata: [
                            "windowID": "\(windowID)",
                            "appName": "\(windowState.appName ?? "unknown")",
                            "title": "\(String(windowState.title?.prefix(30) ?? "untitled"))",
                            "spaces": "\(firstArray.map { $0.uint64Value })",
                            "method": "SLSCopySpacesForWindows"
                        ])
                    } else {
                        // API returned empty - we don't know which spaces this window is on
                        // Set to empty array instead of guessing
                        windowState.spaces = []
                        logger.warning("⚠️ DEBUG: Unable to determine window spaces", metadata: [
                            "windowID": "\(windowID)",
                            "appName": "\(windowState.appName ?? "unknown")",
                            "title": "\(String(windowState.title?.prefix(30) ?? "untitled"))",
                            "reason": "SLSCopySpacesForWindows returned empty",
                            "result": "spaces set to [] (unknown)"
                        ])
                    }
                } else {
                    // API call failed entirely - we don't know which spaces this window is on
                    windowState.spaces = []
                    logger.error("❌ DEBUG: SLSCopySpacesForWindows API failed", metadata: [
                        "windowID": "\(windowID)",
                        "appName": "\(windowState.appName ?? "unknown")",
                        "title": "\(String(windowState.title?.prefix(30) ?? "untitled"))",
                        "result": "spaces set to [] (unknown)"
                    ])
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

    // MARK: - Event Handling

    private func registerEventHandlers() {
        logger.info("Registering event handlers...")

        // Register for window ordered events
        registerEvent(.windowOrdered)

        // Register for window destroyed events
        registerEvent(.windowDestroyed)

        // Register for space created events
        registerEvent(.spaceCreated)

        // Register for space destroyed events
        registerEvent(.spaceDestroyed)

        logger.info("Event handlers registered successfully", metadata: [
            "count": "\(eventContexts.count)"
        ])
    }

    private func registerEvent(_ eventType: SLSEventType) {
        // Create a unique context for this event type
        let eventContext = EventContext(manager: self, eventType: eventType)
        eventContexts.append(eventContext)  // Keep it alive

        let context = Unmanaged.passRetained(eventContext).toOpaque()

        let error = SLSRegisterConnectionNotifyProc(
            connectionID,
            eventCallbackFunction,
            eventType.rawValue,
            context
        )

        if error.isSuccess {
            logger.info("✓ Registered event handler", metadata: [
                "event": "\(eventCodeToName(eventType.rawValue))",
                "code": "\(eventType.rawValue)"
            ])
        } else {
            logger.error("✗ Failed to register event handler", metadata: [
                "event": "\(eventCodeToName(eventType.rawValue))",
                "code": "\(eventType.rawValue)",
                "error": "\(error)"
            ])
        }
    }

    func handleEvent(eventCode: UInt32, data: Int32) {
        queue.async {
            self.handleEventInternal(eventCode: eventCode, data: data)
        }
    }

    private func handleEventInternal(eventCode: UInt32, data: Int32) {
        let eventName = eventCodeToName(eventCode)
        logger.info("📡 Event received", metadata: [
            "event": "\(eventName)",
            "code": "\(eventCode)",
            "data": "\(data)"
        ])

        // Determine event type from code
        let isWindowEvent = (eventCode == SLSEventType.windowOrdered.rawValue ||
                            eventCode == SLSEventType.windowDestroyed.rawValue)
        let isSpaceEvent = (eventCode == SLSEventType.spaceCreated.rawValue ||
                           eventCode == SLSEventType.spaceDestroyed.rawValue)

        if isWindowEvent {
            logger.debug("→ Triggering window state refresh...")
            refreshWindows()
        } else if isSpaceEvent {
            logger.debug("→ Triggering space state refresh...")
            refreshSpaces()
            refreshWindows()  // Also refresh windows since they may have moved
        } else {
            logger.warning("⚠️  Unknown event type, ignoring")
            return
        }

        state.metadata.update()
        logger.debug("✓ State updated", metadata: [
            "timestamp": "\(state.metadata.lastUpdate)"
        ])
    }

    // Helper to translate event codes to readable names
    private func eventCodeToName(_ code: UInt32) -> String {
        switch code {
        case SLSEventType.windowOrdered.rawValue:
            return "windowOrdered"
        case SLSEventType.windowDestroyed.rawValue:
            return "windowDestroyed"
        case SLSEventType.spaceCreated.rawValue:
            return "spaceCreated"
        case SLSEventType.spaceDestroyed.rawValue:
            return "spaceDestroyed"
        case SLSEventType.missionControlEnter.rawValue:
            return "missionControlEnter"
        case SLSEventType.missionControlExit.rawValue:
            return "missionControlExit"
        default:
            return "unknown(\(code))"
        }
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

            // TODO: Query initial window properties via AX
            // For now, just add it to state
            self.state.windows[String(windowID)] = window

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
            self.state.windows[String(windowID)] = window
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
            self.state.windows[String(windowID)] = window
            self.state.metadata.update()
        }
    }

    // MARK: - NSWorkspace Event Handlers (System Events)

    func handleSpaceChanged() {
        queue.async {
            self.logger.info("Space changed - refreshing spaces")
            self.refreshSpaces()
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

            // Mark all windows for this app as ordered in
            for (key, var window) in self.state.windows where window.pid == pid {
                window.isOrderedIn = true
                self.state.windows[key] = window
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

// MARK: - Event Context

// Context structure to pass both StateManager and event type to callback
private class EventContext {
    weak var manager: StateManager?
    let eventType: SLSEventType

    init(manager: StateManager, eventType: SLSEventType) {
        self.manager = manager
        self.eventType = eventType
    }
}

// MARK: - Global Event Callback

private func eventCallbackFunction(cid: Int32, data: Int32, ctx: UnsafeMutableRawPointer?) -> Void {
    // Add logging at the very start to prove callback is invoked
    print("[DEBUG] 🔔 Event callback invoked | cid=\(cid) data=\(data)")

    guard let ctx = ctx else {
        print("[ERROR] ⚠️  Event callback context is nil!")
        return
    }

    let context = Unmanaged<EventContext>.fromOpaque(ctx).takeUnretainedValue()

    guard let manager = context.manager else {
        print("[ERROR] ⚠️  StateManager is nil in context!")
        return
    }

    let eventCode = context.eventType.rawValue
    print("[DEBUG] → Queuing event to dispatch queue | event=\(eventCode) data=\(data)")

    manager.handleEvent(eventCode: eventCode, data: data)
}
