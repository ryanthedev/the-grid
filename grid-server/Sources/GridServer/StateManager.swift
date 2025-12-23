//
// StateManager.swift
// GridServer
//
// Manages window manager state with event-driven updates
//

import Foundation
import CoreGraphics
import AppKit

// Private AX API for getting window ID from AXUIElement
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<UInt32>) -> AXError

class StateManager {
    // MARK: - Singleton

    static let shared = StateManager()

    // MARK: - Properties

    private var state: WindowManagerState
    private let connectionID: Int32
    private let queue = DispatchQueue(label: "com.grid.StateManager", qos: .userInitiated)

    // AX Observers (one per application)
    private var applicationObservers: [pid_t: ApplicationObserver] = [:]

    // Workspace observer (system-level events)
    private var workspaceObserver: WorkspaceObserver?

    // MSS client for window manipulation and sticky detection
    private let mssClient: MSSClient

    // Polling timer for periodic state refresh
    private var pollTimer: DispatchSourceTimer?

    // Border event handler
    var borderEvents: BorderEvents?

    // MARK: - Initialization

    private init() {
        self.connectionID = SLSMainConnectionID()
        self.state = WindowManagerState()
        self.state.metadata.connectionID = self.connectionID
        self.mssClient = MSSClient()

        Task {
            await JSONLogger.shared.log("state.init", data: ["cid": self.connectionID])
        }
    }

    // MARK: - Public Interface

    func start() {
        executeOnQueue {
            // Build initial state
            await self.refreshCompleteState()

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

    private func refreshCompleteState() async {
        jlog("state.refresh")

        // Refresh in order: displays -> spaces -> applications -> windows
        refreshDisplays()
        refreshSpaces()
        refreshApplications()
        refreshWindows()

        // Initialize activeDisplayUUID from active space (needed before any focus events)
        updateActiveDisplayFromSpaces()

        // Query the currently focused window so CLI has correct focus state
        await initializeFocusState()

        state.metadata.update()
    }

    /// Query the currently focused window on startup and set initial focus state.
    /// This ensures focusedWindowID is set before any CLI commands run.
    /// Note: Uses slightly different semantics than applyWindowFocus - logs a combined
    /// startup event and derives space from display rather than window.spaces.
    private func initializeFocusState() async {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return
        }

        let pid = frontApp.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var focusedWindowRef: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowRef
        )

        guard result == .success,
              let windowElement = focusedWindowRef else {
            return
        }

        var windowID: UInt32 = 0
        let axResult = _AXUIElementGetWindow(windowElement as! AXUIElement, &windowID)

        guard axResult == .success, windowID != 0 else {
            return
        }

        // Set focused window and display (using helper, no change logging for init)
        state.metadata.focusedWindowID = windowID
        let displayStr = await updateActiveDisplay(for: windowID, logChanges: false)

        // Get space from display's current space (init uses display space, not window.spaces)
        var spaceID: UInt64 = 0
        if let displayUUID = displayStr as CFString? {
            spaceID = SLSManagedDisplayGetCurrentSpace(connectionID, displayUUID)
            if spaceID != 0 {
                state.metadata.activeSpaceID = spaceID
            }
        }

        // Log combined startup focus event
        await JSONLogger.shared.log("win.focus", data: [
            "wid": windowID,
            "app": frontApp.localizedName ?? "unknown",
            "sid": spaceID,
            "display": displayStr ?? "unknown",
            "init": true
        ])
    }

    private func refreshApplications() {
        let runningApps = NSWorkspace.shared.runningApplications
        var applications: [String: ApplicationState] = [:]

        for app in runningApps {
            // Only track regular apps (skip system services, etc.)
            guard app.activationPolicy == .regular else { continue }

            let appState = ApplicationState(from: app)
            applications[String(app.processIdentifier)] = appState
        }

        state.applications = applications
        jlog("app.refresh", data: ["count": applications.count])
    }

    private func refreshDisplays() {
        guard let displaysArray = SLSCopyManagedDisplays(connectionID) else {
            jlog("warn.dsp", msg: "failed to get displays")
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

        state.displays = displays
        jlog("dsp.refresh", data: ["count": displays.count])
    }

    /// Refresh currentSpaceID for all displays without doing a full display refresh
    /// This is called on space change to get fresh space IDs
    private func refreshDisplayCurrentSpaces() {
        for i in 0..<state.displays.count {
            let uuid = state.displays[i].uuid
            let newSpaceID = SLSManagedDisplayGetCurrentSpace(connectionID, uuid as CFString)
            state.displays[i].currentSpaceID = newSpaceID
        }
    }

    private func refreshSpaces() {
        guard let spacesArray = SLSCopyManagedDisplaySpaces(connectionID) else {
            jlog("warn.spc", msg: "failed to get spaces")
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

                // Preserve lastFocusedWindowID from existing space if it exists
                let spaceKey = String(spaceID)
                if let existingSpace = state.spaces[spaceKey] {
                    spaceState.lastFocusedWindowID = existingSpace.lastFocusedWindowID
                }

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

        state.spaces = spaces
        jlog("spc.refresh", data: ["count": spaces.count])
    }

    /// Get the current space for a window using fallback mechanism
    /// Returns 0 if unable to determine the space
    private func getCurrentSpaceForWindow(_ windowID: UInt32) -> UInt64 {
        // Get the display UUID for this window
        guard let displayUUID = SLSCopyManagedDisplayForWindow(connectionID, windowID) else {
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
            return AXWindowProperties()
        }

        // Find the matching window element by direct ID match
        for windowElement in windows {
            var cgWindowID: UInt32 = 0
            let result = _AXUIElementGetWindow(windowElement, &cgWindowID)

            if result == .success && cgWindowID == windowID {
                return extractAXProperties(from: windowElement)
            }
        }

        // Fallback: If only one AX window exists, use it (handles apps like Ghostty
        // where SkyLight reports multiple phantom window IDs but AX only sees one real window)
        if windows.count == 1 {
            Task {
                await JSONLogger.shared.log("ax.single", data: ["wid": windowID, "pid": pid])
            }
            return extractAXProperties(from: windows[0])
        }

        return AXWindowProperties()
    }

    /// Extract AX properties from a window element
    private func extractAXProperties(from windowElement: AXUIElement) -> AXWindowProperties {
        var props = AXWindowProperties()

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

        return props
    }

    // MARK: - Queue Helpers

    /// Execute an async operation on the state queue with span propagation
    private func executeOnQueue(_ operation: @escaping () async -> Void) {
        let span = CurrentSpan.current
        queue.async { [span] in
            Task {
                await CurrentSpan.$current.withValue(span) {
                    await operation()
                }
            }
        }
    }

    // MARK: - Focus State Helpers

    /// Determine active display from window's geometric position with API fallback
    /// Returns display UUID if found, nil otherwise
    @discardableResult
    private func updateActiveDisplay(for windowID: UInt32, logChanges: Bool = true) async -> String? {
        let windowKey = String(windowID)
        var displayStr: String?
        var method = "geometric"

        if let window = state.windows[windowKey],
           !window.isMinimized,
           let display = displayForWindowFrame(window.frame) {
            displayStr = display.uuid
        } else if let displayUUID = SLSCopyManagedDisplayForWindow(connectionID, windowID) {
            displayStr = displayUUID as String
            method = "fallback"
        }

        if let displayStr = displayStr {
            if logChanges && state.metadata.activeDisplayUUID != displayStr {
                await JSONLogger.shared.log("dsp.change", data: [
                    "display": displayStr,
                    "wid": windowID,
                    "method": method
                ])
            }
            state.metadata.activeDisplayUUID = displayStr
        }

        return displayStr
    }

    /// Update active space from window's space assignment with API fallback
    /// Also tracks lastFocusedWindowID for the space
    private func updateActiveSpace(for windowID: UInt32, trackLastFocused: Bool = true) async {
        let windowKey = String(windowID)
        var spaceID: UInt64?

        // Primary: use window's space assignment
        if let window = state.windows[windowKey],
           let firstSpace = window.spaces.first {
            spaceID = UInt64(firstSpace)
        }
        // Fallback: query display's current space
        else if let displayUUID = SLSCopyManagedDisplayForWindow(connectionID, windowID) {
            let querySpaceID = SLSManagedDisplayGetCurrentSpace(connectionID, displayUUID)
            if querySpaceID != 0 {
                spaceID = querySpaceID
            }
        }

        if let spaceID = spaceID {
            state.metadata.activeSpaceID = spaceID
            if trackLastFocused {
                let spaceKey = String(spaceID)
                state.spaces[spaceKey]?.lastFocusedWindowID = windowID
            }
        }
    }

    /// Core focus update logic shared by event handlers
    /// Updates: focusedWindowID, activeDisplayUUID, activeSpaceID, lastFocusedWindowID
    /// Notifies border system
    private func applyWindowFocus(_ windowID: UInt32) async {
        state.metadata.focusedWindowID = windowID
        await updateActiveDisplay(for: windowID, logChanges: true)
        await updateActiveSpace(for: windowID, trackLastFocused: true)
        state.metadata.update()
        borderEvents?.handleWindowFocused(windowID)
    }

    /// Update a window's properties with automatic lastUpdated and metadata refresh
    private func updateWindow(
        _ windowID: UInt32,
        logEvent: String? = nil,
        logData: [String: Any] = [:],
        mutation: (inout WindowState) -> Void
    ) async {
        let key = String(windowID)
        guard var window = state.windows[key] else { return }

        mutation(&window)
        window.lastUpdated = Date()
        state.windows[key] = window
        state.metadata.update()

        if let event = logEvent {
            var data: [String: Any] = ["wid": windowID]
            data.merge(logData) { _, new in new }
            await JSONLogger.shared.log(event, data: data)
        }
    }

    /// Public method to update window spaces (for WindowManipulator)
    func updateWindowSpacesPublic(_ windowID: UInt32) {
        executeOnQueue {
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
            } else {
                // API returned empty - mark as unknown
                window.spaces = []
                state.windows[String(windowID)] = window
            }
        } else {
            // API call failed - mark as unknown
            window.spaces = []
            state.windows[String(windowID)] = window
        }
    }

    /// Find the display that geometrically contains the given point
    private func displayContainingPoint(_ point: CGPoint) -> DisplayState? {
        for display in state.displays {
            guard let frame = display.frame else { continue }
            let minX = frame.origin.x
            let maxX = frame.origin.x + frame.size.width
            let minY = frame.origin.y
            let maxY = frame.origin.y + frame.size.height

            if point.x >= minX && point.x < maxX &&
               point.y >= minY && point.y < maxY {
                return display
            }
        }
        return nil
    }

    /// Find the display that contains the center of the given window frame
    private func displayForWindowFrame(_ frame: CGRect) -> DisplayState? {
        let centerX = frame.origin.x + frame.size.width / 2
        let centerY = frame.origin.y + frame.size.height / 2
        return displayContainingPoint(CGPoint(x: centerX, y: centerY))
    }

    /// Re-query AX properties for windows on the active space whose role is nil
    /// Called after space change when AX may now be accessible for previously inaccessible windows
    private func refreshAXPropertiesForActiveSpace() {
        guard let activeSpaceID = state.metadata.activeSpaceID else { return }

        for (windowKey, window) in state.windows {
            // Only refresh if role is nil AND window is on active space
            guard window.role == nil,
                  window.spaces.contains(activeSpaceID) else { continue }

            let axProps = getAXProperties(pid: window.pid, windowID: window.id)

            // Only update if we got a valid role
            if let role = axProps.role {
                var updatedWindow = window
                updatedWindow.role = role
                updatedWindow.subrole = axProps.subrole
                updatedWindow.parent = axProps.parent
                updatedWindow.hasCloseButton = axProps.hasCloseButton
                updatedWindow.hasFullscreenButton = axProps.hasFullscreenButton
                updatedWindow.hasMinimizeButton = axProps.hasMinimizeButton
                updatedWindow.hasZoomButton = axProps.hasZoomButton
                updatedWindow.isModal = axProps.isModal
                state.windows[windowKey] = updatedWindow
            }
        }
    }

    private func refreshWindows() {
        // Use public CGWindowListCopyWindowInfo API instead of private SkyLight API
        // This is safer and won't crash, though it provides slightly different data
        // Use .optionAll to get windows from all spaces, not just the active space
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            jlog("warn.win", msg: "failed to get window list")
            return
        }

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
            } else {
                // 2. Not sticky - try to get spaces using SkyLight API with properly typed CFArray
                let windowArray = createWindowIDArray([windowID])
                if let spacesArray = SLSCopySpacesForWindows(connectionID, 0x7, windowArray) {
                    // Result is flat array of space IDs (CFNumbers)
                    let spaceNumbers: [NSNumber] = cfArrayToSwiftArray(spacesArray)
                    if !spaceNumbers.isEmpty {
                        // Success - we know the actual spaces
                        windowState.spaces = spaceNumbers.map { $0.uint64Value }
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

        state.windows = windows
        jlog("win.refresh", data: ["count": windows.count])
    }

    // MARK: - Observer Management

    /// Create AX observers for all running applications
    private func observeExistingApplications() {
        let runningApps = NSWorkspace.shared.runningApplications

        for app in runningApps {
            // Skip system apps and apps without windows
            guard app.activationPolicy == .regular else { continue }

            createObserver(for: app)
        }

        jlog("ax.observer.create", data: ["count": applicationObservers.count])
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

        jlog("ax.observer.stop", data: ["pid": pid])
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
        jlog("state.poll", data: ["interval": interval])
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
    }

    // MARK: - AX Event Handlers (Per-Window Events)

    func handleWindowCreated(_ windowID: UInt32, pid: pid_t) {
        executeOnQueue {
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

            // Log window created event
            let appName = window.appName ?? "unknown"
            let frame = window.frame
            await JSONLogger.shared.log("win.create", data: [
                "wid": windowID,
                "pid": pid,
                "app": appName,
                "frame": [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]
            ])

            // Notify border system with bundleID to avoid re-entrant queue access
            let bundleID = self.state.applications[pidKey]?.bundleIdentifier
            self.borderEvents?.handleWindowCreated(windowID, bundleID: bundleID)
        }
    }

    func handleWindowDestroyed(_ windowID: UInt32) {
        executeOnQueue {
            // Log window destroyed event
            await JSONLogger.shared.log("win.destroy", data: ["wid": windowID])

            // Get PID before removing window
            let pid = self.state.windows[String(windowID)]?.pid

            // Clear focus if destroyed window was focused
            if self.state.metadata.focusedWindowID == windowID {
                self.state.metadata.focusedWindowID = nil
                self.state.metadata.activeDisplayUUID = nil
                // Try to recover activeDisplayUUID from current active space
                self.updateActiveDisplayFromSpaces()
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

            // Notify border system
            self.borderEvents?.handleWindowDestroyed(windowID)
        }
    }

    func handleWindowMoved(_ windowID: UInt32, frame: CGRect) {
        executeOnQueue {
            guard var window = self.state.windows[String(windowID)] else { return }
            window.frame = frame
            window.lastUpdated = Date()
            self.state.windows[String(windowID)] = window

            // Re-query space assignment after move
            self.updateWindowSpaces(windowID)

            self.state.metadata.update()

            // Log window moved event
            await JSONLogger.shared.log("win.move", data: [
                "wid": windowID,
                "frame": [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]
            ])

            // Notify border system
            self.borderEvents?.handleWindowMoved(windowID, frame: frame)
        }
    }

    func handleWindowResized(_ windowID: UInt32, frame: CGRect) {
        executeOnQueue {
            await self.updateWindow(windowID) { $0.frame = frame }

            // Notify border system
            self.borderEvents?.handleWindowResized(windowID, frame: frame)
        }
    }

    func handleWindowFocused(_ windowID: UInt32) {
        executeOnQueue {
            let stateSpan = await CurrentSpan.current?.startChild("state", data: ["wid": Int(windowID)])

            // Store previous focused window for event logging
            let previousWindowID = self.state.metadata.focusedWindowID

            // Apply focus using shared helper
            await self.applyWindowFocus(windowID)

            // Log focus event
            let appName = self.state.windows[String(windowID)]?.appName ?? "unknown"
            await JSONLogger.shared.log("win.focus", data: [
                "wid": windowID,
                "app": appName,
                "prev": previousWindowID ?? 0
            ])

            if let stateSpan = stateSpan {
                await stateSpan.end()
            }
        }
    }

    func handleWindowMinimized(_ windowID: UInt32) {
        executeOnQueue {
            await self.updateWindow(windowID, logEvent: "win.min") {
                $0.isMinimized = true
                $0.isOrderedIn = false
            }
            // Note: Border system handles this via focus change events
        }
    }

    func handleWindowDeminimized(_ windowID: UInt32) {
        executeOnQueue {
            await self.updateWindow(windowID, logEvent: "win.unmin") {
                $0.isMinimized = false
                $0.isOrderedIn = true
            }
            // Note: Border system handles this via focus change events
        }
    }

    func handleWindowTitleChanged(_ windowID: UInt32, title: String) {
        executeOnQueue {
            await self.updateWindow(windowID) { $0.title = title }
        }
    }

    // MARK: - NSWorkspace Event Handlers (System Events)

    func handleSpaceChanged() {
        executeOnQueue {
            // 1. Store OLD currentSpaceID for each display BEFORE refreshing
            var oldSpaceIDs: [String: UInt64] = [:]
            for display in self.state.displays {
                oldSpaceIDs[display.uuid] = display.currentSpaceID
            }

            // 2. Refresh spaces and update currentSpaceID for each display
            self.refreshSpaces()
            self.refreshDisplayCurrentSpaces()

            // 3. Find which display's space changed - that's the active one
            var foundChangedDisplay = false
            var newSpaceID: UInt64? = nil
            for display in self.state.displays {
                if let oldSpaceID = oldSpaceIDs[display.uuid],
                   display.currentSpaceID != oldSpaceID {
                    // This display's space changed!
                    self.state.metadata.activeDisplayUUID = display.uuid
                    self.state.metadata.activeSpaceID = display.currentSpaceID
                    newSpaceID = display.currentSpaceID
                    foundChangedDisplay = true

                    // Log space change event
                    await JSONLogger.shared.log("spc.change", data: [
                        "sid": display.currentSpaceID,
                        "from": oldSpaceID
                    ])
                    break
                }
            }

            // Fallback: if no change detected, use the old method
            if !foundChangedDisplay {
                self.updateActiveDisplayFromSpaces()
            }

            // Re-query space assignments for all visible windows
            for windowKey in self.state.windows.keys {
                if let windowID = UInt32(windowKey),
                   let window = self.state.windows[windowKey],
                   window.isOrderedIn && !window.isMinimized {
                    self.updateWindowSpaces(windowID)
                }
            }

            // Re-query AX properties for windows on the new active space
            // This populates role/subrole for windows that weren't accessible before
            self.refreshAXPropertiesForActiveSpace()

            // Auto-focus the new space's last focused window
            if let spaceID = newSpaceID {
                self.restoreFocusForSpace(spaceID)
            }

            // Note: Border system handles space changes via cell assignments from CLI

            self.state.metadata.update()
        }
    }

    /// Update activeDisplayUUID and activeSpaceID based on which display has the focused/active space
    private func updateActiveDisplayFromSpaces() {
        // Find the display that has the currently active space
        for display in state.displays {
            let spaceKey = String(display.currentSpaceID)
            if let space = state.spaces[spaceKey], space.isActive {
                let oldUUID = state.metadata.activeDisplayUUID
                state.metadata.activeDisplayUUID = display.uuid
                state.metadata.activeSpaceID = display.currentSpaceID  // Fix: also set activeSpaceID
                if oldUUID != display.uuid {
                    Task {
                        await JSONLogger.shared.log("dsp.update", data: [
                            "display": display.uuid,
                            "sid": display.currentSpaceID,
                            "prev": oldUUID ?? "nil"
                        ])
                    }
                }
                return
            }
        }
        Task {
            await JSONLogger.shared.log("warn.dsp", msg: "no active space found")
        }
    }

    /// Restore focus to the last focused window on a space (if it still exists)
    private func restoreFocusForSpace(_ spaceID: UInt64) {
        let spaceKey = String(spaceID)
        guard let space = state.spaces[spaceKey],
              let windowID = space.lastFocusedWindowID else {
            Task {
                await JSONLogger.shared.log("dbg.focus", msg: "no last focused window", data: ["sid": spaceID])
            }
            return
        }

        // Check if window still exists in our state
        guard let window = state.windows[String(windowID)],
              window.isOrderedIn && !window.isMinimized else {
            Task {
                await JSONLogger.shared.log("dbg.focus", msg: "window unavailable", data: [
                    "sid": spaceID,
                    "wid": windowID
                ])
            }
            return
        }

        Task {
            await JSONLogger.shared.log("win.focus.restore", data: [
                "sid": spaceID,
                "wid": windowID,
                "app": window.appName ?? "unknown"
            ])
        }

        // Focus the window using WindowManipulator
        let manipulator = WindowManipulator(connectionID: connectionID)
        let success = manipulator.focusWindow(pid: window.pid, windowID: windowID)

        if !success {
            Task {
                await JSONLogger.shared.log("warn.focus", msg: "restore failed", data: ["wid": windowID])
            }
        }
    }

    func handleDisplayConfigurationChanged() {
        executeOnQueue {
            // Capture old display UUIDs before refresh
            let oldDisplayUUIDs = Set(self.state.displays.map { $0.uuid })

            self.refreshDisplays()
            self.refreshSpaces()

            // Detect disconnected displays
            let newDisplayUUIDs = Set(self.state.displays.map { $0.uuid })
            let disconnectedDisplays = oldDisplayUUIDs.subtracting(newDisplayUUIDs)

            // Notify border system of disconnects
            for displayUUID in disconnectedDisplays {
                self.borderEvents?.handleDisplayDisconnected(displayUUID: displayUUID)
            }

            self.state.metadata.update()

            await JSONLogger.shared.log("dsp.config", data: [
                "removed": disconnectedDisplays.count,
                "total": newDisplayUUIDs.count
            ])
        }
    }

    func handleApplicationLaunched(_ app: NSRunningApplication) {
        executeOnQueue {
            guard app.activationPolicy == .regular else { return }

            // Create ApplicationState
            let appState = ApplicationState(from: app)
            let pidKey = String(app.processIdentifier)
            self.state.applications[pidKey] = appState

            await JSONLogger.shared.log("app.launch", data: [
                "pid": app.processIdentifier,
                "app": app.localizedName ?? "unknown",
                "bundle": app.bundleIdentifier ?? "unknown"
            ])

            // Create AX observer
            self.createObserver(for: app)

            self.state.metadata.update()
        }
    }

    func handleApplicationTerminated(_ app: NSRunningApplication) {
        executeOnQueue {
            let pid = app.processIdentifier
            let pidKey = String(pid)

            // Clear focus if any window from terminated app was focused
            if let focusedID = self.state.metadata.focusedWindowID,
               let focusedWindow = self.state.windows[String(focusedID)],
               focusedWindow.pid == pid {
                await JSONLogger.shared.log("dbg.focus", msg: "clearing focus (app terminated)", data: ["pid": pid])
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
        executeOnQueue {
            let pid = app.processIdentifier
            let pidKey = String(pid)

            // Update all apps to mark which one is active
            for (key, var appState) in self.state.applications {
                appState.isActive = (key == pidKey)
                self.state.applications[key] = appState
            }

            // Query the app's focused window and update focusedWindowID
            // This is needed because not all apps send kAXFocusedWindowChangedNotification reliably
            await self.updateFocusedWindowForApp(pid: pid)

            self.state.metadata.update()
        }
    }

    /// Query an app's focused window via AX API and update focusedWindowID
    /// This provides a fallback when AX notifications don't fire reliably
    private func updateFocusedWindowForApp(pid: pid_t) async {
        let appElement = AXUIElementCreateApplication(pid)

        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        )

        guard result == .success,
              let windowElement = focusedWindow else {
            await JSONLogger.shared.log("dbg.ax", msg: "could not get focused window", data: ["pid": pid])
            return
        }

        // Get CGWindowID from AX element
        var windowID: UInt32 = 0
        let windowResult = _AXUIElementGetWindow(windowElement as! AXUIElement, &windowID)

        guard windowResult == .success, windowID != 0 else {
            await JSONLogger.shared.log("dbg.ax", msg: "could not get window ID", data: ["pid": pid])
            return
        }

        await JSONLogger.shared.log("win.focus.app", data: ["wid": windowID, "pid": pid])
        await applyWindowFocus(windowID)
    }

    func handleApplicationHidden(_ app: NSRunningApplication) {
        executeOnQueue {
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
        executeOnQueue {
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
        executeOnQueue {
            await JSONLogger.shared.log("state.wake")
            await self.refreshCompleteState()
        }
    }

    // MARK: - Mouse Position Helpers

    /// Get current mouse position in global screen coordinates (query-based, not event-driven)
    func getCurrentMousePosition() -> CGPoint {
        guard let event = CGEvent(source: nil) else {
            jlog("warn.mouse", msg: "failed to get position")
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
            jlog("warn.dsp", msg: "failed to get display list", data: ["err": error.rawValue])
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

