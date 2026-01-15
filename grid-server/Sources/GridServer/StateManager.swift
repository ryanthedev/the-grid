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

actor StateManager: StateEventHandler {
    // MARK: - Shared Instance
    // Thread-safe lazy initialization - actor ensures all access is serialized
    private static let _shared = StateManager()
    static var shared: StateManager { _shared }

    // MARK: - Properties

    private var state: WindowManagerState
    private let connectionID: Int32

    // AX Observers (one per application)
    private var applicationObservers: [pid_t: ApplicationObserver] = [:]

    // Workspace observer (system-level events)
    private var workspaceObserver: WorkspaceObserver?

    // MSS client for window manipulation and sticky detection
    private let mssClient: MSSClient

    // Polling timer for periodic state refresh
    private var pollTimer: DispatchSourceTimer?

    // Border event handler
    private var borderEvents: BorderEvents?

    // Window blacklist (runtime Set for O(1) lookup)
    private var windowBlacklist: Set<String> = []

    // CLI focus tracking: windowID -> timestamp when CLI focused it
    // Used to distinguish CLI-initiated focus from external (click) focus
    private var cliFocusTimestamps: [UInt32: Date] = [:]

    // How long to consider a focus as "CLI-initiated" (prevents loop)
    private let cliFocusWindow: TimeInterval = 0.5

    // CLI path for invoking border sync on external focus
    private var cliPath: String = "thegrid"

    // Debug: sequence counter for CLI invocations to track ordering
    private var cliInvokeSequence: Int = 0

    func setBorderEvents(_ events: BorderEvents) {
        self.borderEvents = events
    }

    /// Check if a window was recently focused via CLI (within cliFocusWindow)
    /// Used to distinguish CLI-initiated focus from external (click) focus
    /// Also cleans up stale entries to prevent memory leaks
    private func wasRecentlyCliFocused(_ windowID: UInt32) -> Bool {
        let now = Date()

        // Aggressive cleanup: remove entries older than 5 seconds (10x the window)
        // Also cap dictionary size to prevent unbounded growth
        let maxAge: TimeInterval = 5.0
        let maxEntries = 100
        let cutoff = now.addingTimeInterval(-maxAge)
        cliFocusTimestamps = cliFocusTimestamps.filter { $0.value > cutoff }

        // If still too many entries, keep only most recent
        if cliFocusTimestamps.count > maxEntries {
            let sorted = cliFocusTimestamps.sorted { $0.value > $1.value }
            let trimmed = sorted.prefix(maxEntries).map { ($0.key, $0.value) }
            cliFocusTimestamps = Dictionary(uniqueKeysWithValues: trimmed)
        }

        guard let timestamp = cliFocusTimestamps[windowID] else {
            return false
        }
        return now.timeIntervalSince(timestamp) < cliFocusWindow
    }

    // MARK: - Initialization

    private init() {
        self.connectionID = SLSMainConnectionID()
        self.state = WindowManagerState()
        self.state.metadata.connectionID = self.connectionID
        self.mssClient = MSSClient()

        Task {
            JSONLogger.shared.log("state.init", data: ["cid": self.connectionID])
        }
    }

    // MARK: - Public Interface

    func start() async {
        // Load server config for window blacklist and CLI path FIRST (before state refresh)
        do {
            let config = try await ServerConfig.load()
            windowBlacklist = Set(config.windowBlacklist)
            cliPath = config.cliPath
            JSONLogger.shared.log("srv.cfg.loaded", data: [
                "blacklist_count": windowBlacklist.count,
                "cli_path": cliPath
            ])
        } catch {
            JSONLogger.shared.log("srv.cfg.error", msg: "failed to load server config", data: ["error": "\(error)"])
        }

        // Build initial state (now uses blacklist filtering)
        await refreshCompleteState()

        // Register with EventRouter (must complete before observers start)
        await EventRouter.shared.register(self)

        // Set up workspace observer (must be on main thread)
        let workspace = await MainActor.run {
            let ws = WorkspaceObserver()
            ws.observe(stateManager: self)
            return ws
        }
        self.workspaceObserver = workspace

        // Create AX observers for existing applications
        observeExistingApplications()

        // Start periodic polling to catch windows that events miss
        startPolling(interval: 3.0)
    }

    func getState() -> WindowManagerState {
        return state
    }

    /// Graceful shutdown - cleanup all observers and timers
    /// MUST be called before server termination to prevent resource leaks
    func shutdown() async {
        jlog("state.shutdown.start")

        // Stop polling timer
        stopPolling()

        // Stop workspace observer (removes NSNotificationCenter registrations)
        // Use nonisolated(unsafe) to allow sending to MainActor for cleanup
        if let ws = workspaceObserver {
            let wsRef = ws
            await MainActor.run { @Sendable in
                wsRef.stopObserving()
            }
        }
        workspaceObserver = nil

        // Stop all application observers synchronously to prevent race conditions
        let pids = Array(applicationObservers.keys)
        for pid in pids {
            removeObserver(for: pid)
        }

        // Clear accumulated state dictionaries
        cliFocusTimestamps.removeAll()

        jlog("state.shutdown.done", data: ["observers_stopped": pids.count])
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

    // MARK: - StateEventHandler Protocol

    func handle(_ event: StateEvent, context: EventContext) async throws {
        switch event {
        case .windowCreated(let windowID, let pid):
            await handleWindowCreated(windowID, pid: pid)

        case .windowDestroyed(let windowID):
            await handleWindowDestroyed(windowID)

        case .windowMoved(let windowID, let frame):
            handleWindowMoved(windowID, frame: frame)

        case .windowResized(let windowID, let frame):
            handleWindowResized(windowID, frame: frame)

        case .windowMinimized(let windowID):
            await handleWindowMinimized(windowID)

        case .windowDeminimized(let windowID):
            await handleWindowDeminimized(windowID)

        case .windowTitleChanged(let windowID, let title):
            handleWindowTitleChanged(windowID, title: title)

        case .windowSpaceAssignmentChanged(let windowID, let spaces):
            await handleWindowSpaceAssignmentChanged(windowID, spaces: spaces)

        case .focusChanged(let state):
            if let windowID = state.windowID {
                await handleWindowFocused(windowID)
            }
            switch state.trigger {
            case .spaceSwitched:
                await handleSpaceChanged()
            case .appActivated:
                break
            default:
                break
            }

        case .appLaunched(let app):
            await handleApplicationLaunched(app)

        case .appTerminated(let app):
            await handleApplicationTerminated(app)

        case .appHidden(let app):
            await handleApplicationHidden(app)

        case .appUnhidden(let app):
            await handleApplicationUnhidden(app)

        case .systemWoke:
            await handleSystemWoke()

        case .displayReconfigured(_):
            await handleDisplayConfigurationChanged()

        case .spaceCreated(let spaceID, let displayUUID):
            await handleSpaceCreated(spaceID, displayUUID: displayUUID)

        case .spaceDestroyed(let spaceID):
            await handleSpaceDestroyed(spaceID)

        case .displayConnected(let displayUUID):
            await handleDisplayConnected(displayUUID)

        case .displayDisconnected(let displayUUID):
            await handleDisplayDisconnected(displayUUID)

        case .commandFocusWindow(_, _):
            // Handled by MessageHandler directly
            break

        case .commandMoveWindow(_, _, _):
            // Handled by MessageHandler directly
            break

        case .commandResizeWindow(_, _, _):
            // Handled by MessageHandler directly
            break

        case .commandMinimizeWindow(_, _):
            // Handled by MessageHandler directly
            break

        case .commandCloseWindow(_, _):
            // Handled by MessageHandler directly
            break

        case .commandMoveWindowToSpace(_, _, _):
            // Handled by MessageHandler directly
            break
        }
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
        let displayStr = updateActiveDisplay(for: windowID, logChanges: false)

        // Get space from display's current space (init uses display space, not window.spaces)
        var spaceID: UInt64 = 0
        if let displayUUID = displayStr as CFString? {
            spaceID = SLSManagedDisplayGetCurrentSpace(connectionID, displayUUID)
            if spaceID != 0 {
                state.metadata.activeSpaceID = spaceID
            }
        }

        // Log combined startup focus event
        JSONLogger.shared.log("win.focus", data: [
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
                JSONLogger.shared.log("ax.single", data: ["wid": windowID, "pid": pid])
            }
            return extractAXProperties(from: windows[0])
        }

        return AXWindowProperties()
    }

    /// Check if a window from the given PID should be tracked
    /// Returns false if:
    /// 1. The app is not tracked (non-.regular activation policy)
    /// 2. The app is in the user's window blacklist (only applies to .regular apps)
    private func shouldTrackWindow(pid: pid_t) -> Bool {
        let pidKey = String(pid)
        guard let app = state.applications[pidKey] else {
            // App not tracked (non-.regular activation policy)
            return false
        }

        // Fast path: no blacklist configured
        if windowBlacklist.isEmpty {
            return true
        }

        // Check blacklist by bundle ID or app name
        if let bundleID = app.bundleIdentifier, windowBlacklist.contains(bundleID) {
            return false
        }
        if let name = app.localizedName, windowBlacklist.contains(name) {
            return false
        }

        return true
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

    // MARK: - Focus State Helpers

    /// Determine active display from window's geometric position with API fallback
    /// Returns display UUID if found, nil otherwise
    @discardableResult
    private func updateActiveDisplay(for windowID: UInt32, logChanges: Bool = true) -> String? {
        let windowKey = String(windowID)
        var displayStr: String?
        var method = "geometric"
        let window = state.windows[windowKey]

        if let window = window,
           !window.isMinimized,
           let display = displayForWindowFrame(window.frame) {
            displayStr = display.uuid
        } else if let displayUUID = SLSCopyManagedDisplayForWindow(connectionID, windowID) {
            displayStr = displayUUID as String
            method = "fallback"
        }

        if let displayStr = displayStr {
            if logChanges && state.metadata.activeDisplayUUID != displayStr {
                JSONLogger.shared.log("dsp.change", data: [
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
    private func updateActiveSpace(for windowID: UInt32, trackLastFocused: Bool = true) {
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
    /// Synchronous to prevent actor reentrancy during focus updates
    private func applyWindowFocus(_ windowID: UInt32) async {
        state.metadata.focusedWindowID = windowID
        updateActiveDisplay(for: windowID, logChanges: true)
        updateActiveSpace(for: windowID, trackLastFocused: true)
        state.metadata.update()
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
            JSONLogger.shared.log(event, data: data)
        }
    }

    /// Public method to update window spaces (for WindowManipulator)
    func updateWindowSpacesPublic(_ windowID: UInt32) {
        updateWindowSpaces(windowID)
    }

    /// Mark a window as about to be focused by CLI (call BEFORE focusWindow)
    /// This prevents the border sync loop when AX observer fires
    func markCLIFocusIntent(_ windowID: UInt32) {
        cliFocusTimestamps[windowID] = Date()
    }

    /// Public method to set focused window (for MessageHandler focus commands)
    /// This updates state immediately rather than waiting for AX callback which may not fire
    /// Note: Does NOT emit focusChanged event - observers will handle that when they fire
    func setFocusedWindow(_ windowID: UInt32) {
        // Clean up old timestamps (older than cliFocusWindow)
        let cutoff = Date().addingTimeInterval(-cliFocusWindow * 2)
        cliFocusTimestamps = cliFocusTimestamps.filter { $0.value > cutoff }

        state.metadata.focusedWindowID = windowID

        // Update active display
        let windowKey = String(windowID)
        if let window = state.windows[windowKey],
           !window.isMinimized,
           let display = displayForWindowFrame(window.frame) {
            state.metadata.activeDisplayUUID = display.uuid
        } else if let displayUUID = SLSCopyManagedDisplayForWindow(connectionID, windowID) {
            state.metadata.activeDisplayUUID = displayUUID as String
        }

        // Update active space
        if let window = state.windows[windowKey],
           let firstSpace = window.spaces.first {
            state.metadata.activeSpaceID = UInt64(firstSpace)
            let spaceKey = String(firstSpace)
            state.spaces[spaceKey]?.lastFocusedWindowID = windowID
        } else if let displayUUID = SLSCopyManagedDisplayForWindow(connectionID, windowID) {
            let querySpaceID = SLSManagedDisplayGetCurrentSpace(connectionID, displayUUID)
            if querySpaceID != 0 {
                state.metadata.activeSpaceID = querySpaceID
                let spaceKey = String(querySpaceID)
                state.spaces[spaceKey]?.lastFocusedWindowID = windowID
            }
        }

        state.metadata.update()
    }

    /// Public method to update window frame (for MessageHandler move/resize commands)
    /// This updates state immediately rather than waiting for AX callback which may not fire
    func setWindowFrame(_ windowID: UInt32, frame: CGRect) {
        guard var window = state.windows[String(windowID)] else { return }
        window.frame = frame
        let originalSpaces = window.spaces
        window.displayUUID = computeDisplayUUID(for: window)
        deriveSpaceFromDisplay(for: &window, originalSpaces: originalSpaces)
        window.lastUpdated = Date()
        state.windows[String(windowID)] = window
        state.metadata.update()
    }

    /// Public method to set window minimized state (for MessageHandler minimize commands)
    /// This updates state immediately rather than waiting for AX callback which may not fire
    func setWindowMinimized(_ windowID: UInt32, minimized: Bool) {
        let key = String(windowID)
        guard var window = state.windows[key] else { return }
        window.isMinimized = minimized
        window.isHidden = minimized
        window.lastUpdated = Date()
        state.windows[key] = window
        state.metadata.update()
    }

    /// Re-query and update space assignment for a specific window
    /// Uses geometric derivation from displayUUID, with macOS API as fallback
    private func updateWindowSpaces(_ windowID: UInt32) {
        guard var window = state.windows[String(windowID)] else { return }

        // Query spaces using SkyLight API as fallback data
        var apiSpaces: [UInt64] = []
        let windowArray = createWindowIDArray([windowID])
        if let spacesArray = SLSCopySpacesForWindows(connectionID, 0x7, windowArray) {
            let spaceNumbers: [NSNumber] = cfArrayToSwiftArray(spacesArray)
            apiSpaces = spaceNumbers.map { $0.uint64Value }
        }

        // Use geometric derivation, falling back to API-reported spaces
        let originalSpaces = apiSpaces.isEmpty ? window.spaces : apiSpaces
        deriveSpaceFromDisplay(for: &window, originalSpaces: originalSpaces)
        state.windows[String(windowID)] = window
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

    /// Check if a window is clearly off-screen (way outside all display bounds)
    /// Used to suppress warnings for Chrome's phantom/helper windows positioned off-screen
    private func isWindowGeometricallyOffScreen(_ frame: CGRect) -> Bool {
        guard !state.displays.isEmpty else { return false }

        // Compute combined display bounding box
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude

        for display in state.displays {
            guard let displayFrame = display.frame else { continue }
            minX = min(minX, displayFrame.origin.x)
            minY = min(minY, displayFrame.origin.y)
            maxX = max(maxX, displayFrame.origin.x + displayFrame.size.width)
            maxY = max(maxY, displayFrame.origin.y + displayFrame.size.height)
        }

        // If no display frames available, can't determine off-screen status
        guard minX != .greatestFiniteMagnitude else { return false }

        // Check if window center is way outside combined bounds
        let offScreenMargin: CGFloat = 200
        let centerX = frame.origin.x + frame.size.width / 2
        let centerY = frame.origin.y + frame.size.height / 2

        return centerX < minX - offScreenMargin || centerX > maxX + offScreenMargin ||
               centerY < minY - offScreenMargin || centerY > maxY + offScreenMargin
    }

    /// Compute displayUUID for a window based on its frame
    /// For non-minimized windows, uses geometric detection (center point)
    /// For minimized windows, retains existing displayUUID (doesn't recompute)
    private func computeDisplayUUID(for window: WindowState) -> String? {
        if window.isMinimized {
            return window.displayUUID
        }
        return displayForWindowFrame(window.frame)?.uuid
    }

    /// Derive window's space from its geometric displayUUID
    /// Falls back to original macOS-reported spaces if geometric detection fails
    /// IMPORTANT: Must be called AFTER computeDisplayUUID() sets window.displayUUID
    private func deriveSpaceFromDisplay(for window: inout WindowState, originalSpaces: [UInt64]) {
        // Don't derive for sticky windows - they should be on all spaces
        if let isSticky = mssClient.isWindowSticky(window.id), isSticky {
            window.spaces = getAllUserSpaceIDs()
            return
        }

        if let displayUUID = window.displayUUID,
           let display = state.displays.first(where: { $0.uuid == displayUUID }),
           display.currentSpaceID != 0 {
            window.spaces = [display.currentSpaceID]
        } else {
            // Fallback: keep original macOS-reported spaces
            window.spaces = originalSpaces
            // Only warn for real windows, not:
            // - Menu bar items (small height, no display)
            // - Off-screen helper windows (Chrome phantom windows, system panels)
            let isMenuBarItem = window.frame.size.height <= 30 && window.displayUUID == nil
            let isOffScreen = isWindowGeometricallyOffScreen(window.frame)
            if originalSpaces.isEmpty && !isMenuBarItem && !isOffScreen {
                jlog("warn.spaces", msg: "both geometric and macOS space detection failed", data: [
                    "wid": window.id,
                    "app": window.appName ?? "unknown",
                    "title": window.title ?? "untitled",
                    "displayUUID": window.displayUUID ?? "nil",
                    "isMinimized": window.isMinimized,
                    "frameX": window.frame.origin.x,
                    "frameY": window.frame.origin.y,
                    "frameW": window.frame.size.width,
                    "frameH": window.frame.size.height,
                    "availableDisplays": state.displays.map { $0.uuid }
                ])
            }
        }
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
                // Skip windows from untracked/blacklisted apps
                guard shouldTrackWindow(pid: pid) else {
                    continue
                }

                windowState.pid = pid

                // Get app name from PID
                windowState.appName = getAppNameForPID(pid)

                // Get window name/title if available (don't fall back to ownerName - phantom windows have empty titles)
                if let name = windowInfo[kCGWindowName as String] as? String, !name.isEmpty {
                    windowState.title = name
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

            // Extract isHidden from kCGWindowIsOnscreen (phantom windows lack this key)
            if let isOnScreen = windowInfo["kCGWindowIsOnscreen"] as? Int {
                windowState.isHidden = (isOnScreen != 1)
            } else {
                windowState.isHidden = true
            }

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

            // Compute displayUUID geometrically and derive space from display
            let originalSpaces = windowState.spaces
            windowState.displayUUID = computeDisplayUUID(for: windowState)
            deriveSpaceFromDisplay(for: &windowState, originalSpaces: originalSpaces)

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
    ///
    /// Note: Observer registration happens asynchronously. This method returns
    /// immediately while the observer is set up on the main thread in a detached Task.
    /// The observer will be added to applicationObservers once MainActor setup completes.
    private func createObserver(for app: NSRunningApplication) {
        let pid = app.processIdentifier

        // Don't create duplicate observers
        guard applicationObservers[pid] == nil else { return }

        let observer = ApplicationObserver(pid: pid, appName: app.localizedName)

        // Observer setup requires main thread for run loop integration.
        // Fire-and-forget Task: observer added to state after MainActor work completes.
        Task { @MainActor in
            if observer.observe(stateManager: self) {
                await self.addApplicationObserver(observer, for: pid)
            }
        }
    }

    /// Add an application observer (called from createObserver after MainActor setup)
    private func addApplicationObserver(_ observer: ApplicationObserver, for pid: pid_t) {
        applicationObservers[pid] = observer
    }

    /// Remove an AX observer for a specific application
    /// IMPORTANT: Must stop observer BEFORE removing from dictionary to prevent race condition
    /// where AX callback fires on a deallocated observer
    private func removeObserver(for pid: pid_t) {
        guard let observer = applicationObservers[pid] else { return }

        // Stop observing FIRST (synchronously on main thread) to prevent race condition
        // where AX notification arrives after dictionary removal but before stopObserving
        DispatchQueue.main.sync {
            observer.stopObserving()
        }

        // Now safe to remove - no more callbacks can arrive
        applicationObservers.removeValue(forKey: pid)

        jlog("ax.observer.stop", data: ["pid": pid])
    }

    // MARK: - Polling

    /// Start periodic window state polling
    func startPolling(interval: TimeInterval = 3.0) {
        stopPolling()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            Task {
                await self?.pollWindowState()
            }
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

        // Recompute displayUUID and derive space from display
        let originalSpaces = window.spaces
        window.displayUUID = computeDisplayUUID(for: window)
        deriveSpaceFromDisplay(for: &window, originalSpaces: originalSpaces)

        window.lastUpdated = timestamp
        state.windows[String(windowID)] = window
    }

    /// Add new window discovered by poll
    private func addWindowFromPoll(windowID: UInt32, windowInfo: [String: Any], timestamp: Date) {
        var window = WindowState(id: windowID)

        if let pid = windowInfo[kCGWindowOwnerPID as String] as? pid_t {
            // Skip windows from untracked/blacklisted apps
            guard shouldTrackWindow(pid: pid) else {
                return
            }

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

        // Get title (don't fall back to ownerName - phantom windows have empty titles)
        if let name = windowInfo[kCGWindowName as String] as? String, !name.isEmpty {
            window.title = name
        }

        // Extract isHidden from kCGWindowIsOnscreen
        if let isOnScreen = windowInfo["kCGWindowIsOnscreen"] as? Int {
            window.isHidden = (isOnScreen != 1)
        } else {
            window.isHidden = true
        }
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

        // Compute displayUUID geometrically and derive space from display
        let originalSpaces = window.spaces
        window.displayUUID = computeDisplayUUID(for: window)
        deriveSpaceFromDisplay(for: &window, originalSpaces: originalSpaces)

        state.windows[String(windowID)] = window
    }

    // MARK: - AX Event Handlers (Per-Window Events)

    private func handleWindowCreated(_ windowID: UInt32, pid: pid_t) async {
        // Skip windows from untracked/blacklisted apps
        guard shouldTrackWindow(pid: pid) else {
            return
        }

        // Create new window state
        var window = WindowState(id: windowID)
        window.pid = pid
        window.appName = getAppNameForPID(pid)

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
            // Get title (don't fall back to ownerName - phantom windows have empty titles)
            if let name = windowInfo[kCGWindowName as String] as? String, !name.isEmpty {
                window.title = name
            }
            // Extract isHidden from kCGWindowIsOnscreen
            if let isOnScreen = windowInfo["kCGWindowIsOnscreen"] as? Int {
                window.isHidden = (isOnScreen != 1)
            } else {
                window.isHidden = true
            }
        }

        // Get AX properties
        let axProps = getAXProperties(pid: pid, windowID: windowID)
        window.role = axProps.role
        window.subrole = axProps.subrole
        window.parent = axProps.parent
        window.hasCloseButton = axProps.hasCloseButton
        window.hasFullscreenButton = axProps.hasFullscreenButton
        window.hasMinimizeButton = axProps.hasMinimizeButton
        window.hasZoomButton = axProps.hasZoomButton
        window.isModal = axProps.isModal

        // Compute displayUUID geometrically and derive space from display
        let originalSpaces = window.spaces
        window.displayUUID = computeDisplayUUID(for: window)
        deriveSpaceFromDisplay(for: &window, originalSpaces: originalSpaces)

        state.windows[String(windowID)] = window

        // Add window to app's window list
        let pidKey = String(pid)
        if state.applications[pidKey] != nil {
            if !state.applications[pidKey]!.windows.contains(windowID) {
                state.applications[pidKey]!.windows.append(windowID)
            }
        }

        state.metadata.update()

        JSONLogger.shared.log("win.created", data: [
            "wid": windowID,
            "app": window.appName ?? "unknown",
            "title": window.title ?? "",
            "role": window.role ?? "nil",
            "subrole": window.subrole ?? "nil",
            "display": window.displayUUID ?? "nil"
        ])
    }

    private func handleWindowDestroyed(_ windowID: UInt32) async {
        // Get window info before removing
        let window = state.windows[String(windowID)]
        let pid = window?.pid

        // Clear focus if destroyed window was focused
        if state.metadata.focusedWindowID == windowID {
            state.metadata.focusedWindowID = nil
            state.metadata.activeDisplayUUID = nil
            // Try to recover activeDisplayUUID from current active space
            updateActiveDisplayFromSpaces()
        }

        // Remove from state
        state.windows.removeValue(forKey: String(windowID))

        // Remove from app's window list
        if let pid = pid {
            let pidKey = String(pid)
            state.applications[pidKey]?.windows.removeAll { $0 == windowID }
        }

        // Remove from space window lists
        for spaceKey in state.spaces.keys {
            state.spaces[spaceKey]?.windows.removeAll { $0 == windowID }
        }

        state.metadata.update()

        JSONLogger.shared.log("win.destroyed", data: [
            "wid": windowID,
            "app": window?.appName ?? "unknown",
            "wasFocused": state.metadata.focusedWindowID == nil && pid != nil
        ])
    }

    private func handleWindowMoved(_ windowID: UInt32, frame: CGRect) {
        guard var window = state.windows[String(windowID)] else { return }
        window.frame = frame
        // Recompute displayUUID and derive space from display
        let originalSpaces = window.spaces
        window.displayUUID = computeDisplayUUID(for: window)
        deriveSpaceFromDisplay(for: &window, originalSpaces: originalSpaces)
        window.lastUpdated = Date()
        state.windows[String(windowID)] = window
        state.metadata.update()
        // EventRouter handles logging and BorderEvents notification
    }

    private func handleWindowResized(_ windowID: UInt32, frame: CGRect) {
        guard var window = state.windows[String(windowID)] else { return }
        window.frame = frame
        // Recompute displayUUID and derive space from display
        let originalSpaces = window.spaces
        window.displayUUID = computeDisplayUUID(for: window)
        deriveSpaceFromDisplay(for: &window, originalSpaces: originalSpaces)
        window.lastUpdated = Date()
        state.windows[String(windowID)] = window
        state.metadata.update()
        // EventRouter handles logging and BorderEvents notification
    }

    private func handleWindowFocused(_ windowID: UInt32) async {
        let stateSpan = await CurrentSpan.current?.startChild("state", data: ["wid": Int(windowID)])

        // Capture previous state BEFORE applyWindowFocus overwrites metadata
        let prevFocused = state.metadata.focusedWindowID
        let prevDisplay = state.metadata.activeDisplayUUID
        let prevSpace = state.metadata.activeSpaceID
        let prevWindow = prevFocused.flatMap { state.windows[String($0)] }

        let window = state.windows[String(windowID)]

        // Apply focus using shared helper
        await applyWindowFocus(windowID)

        var logData: [String: Any] = [
            "wid": windowID,
            "app": window?.appName ?? "unknown",
            "title": window?.title ?? "",
            "display": state.metadata.activeDisplayUUID ?? "nil",
            "sid": state.metadata.activeSpaceID ?? 0
        ]

        if let prevWid = prevFocused {
            logData["prev"] = [
                "wid": prevWid,
                "app": prevWindow?.appName ?? "unknown",
                "title": prevWindow?.title ?? "",
                "display": prevDisplay as Any,
                "sid": prevSpace as Any
            ] as [String: Any]
        }

        JSONLogger.shared.log("win.focus", data: logData)

        // Check if this was a CLI-initiated focus (skip CLI invocation to prevent loop)
        if wasRecentlyCliFocused(windowID) {
            JSONLogger.shared.log("win.focus.cli", data: ["wid": windowID, "skip": true])
        } else {
            // External focus (click, etc.) - invoke CLI to sync borders
            invokeCLIForBorderSync(windowID: windowID)
        }

        if let stateSpan = stateSpan {
            await stateSpan.end()
        }
    }

    /// Invoke CLI to sync borders for external focus changes
    /// Fire-and-forget: spawns process asynchronously, logs result, no retries
    private func invokeCLIForBorderSync(windowID: UInt32) {
        let path = cliPath
        let seq = cliInvokeSequence
        cliInvokeSequence += 1
        let spawnTime = Date()

        // Log when process is SPAWNED (not just when it completes)
        JSONLogger.shared.log("cli.invoke.spawn", data: [
            "wid": windowID,
            "seq": seq,
            "path": path
        ])

        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [path, "event", "focus", String(windowID)]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()

                let status = process.terminationStatus
                let durationMs = Int(Date().timeIntervalSince(spawnTime) * 1000)
                if status == 0 {
                    JSONLogger.shared.log("cli.invoke.ok", data: [
                        "wid": windowID,
                        "seq": seq,
                        "dur_ms": durationMs
                    ])
                } else {
                    JSONLogger.shared.log("cli.invoke.err", data: [
                        "wid": windowID,
                        "seq": seq,
                        "dur_ms": durationMs,
                        "status": status,
                        "path": path
                    ])
                }
            } catch {
                JSONLogger.shared.log("cli.invoke.err", data: [
                    "wid": windowID,
                    "seq": seq,
                    "path": path,
                    "error": "\(error)"
                ])
            }
        }
    }

    private func handleWindowMinimized(_ windowID: UInt32) async {
        let window = state.windows[String(windowID)]
        await updateWindow(windowID, logEvent: nil) {
            $0.isMinimized = true
            $0.isHidden = true
        }
        JSONLogger.shared.log("win.minimized", data: [
            "wid": windowID,
            "app": window?.appName ?? "unknown"
        ])
    }

    private func handleWindowDeminimized(_ windowID: UInt32) async {
        let window = state.windows[String(windowID)]
        await updateWindow(windowID, logEvent: nil) {
            $0.isMinimized = false
            $0.isHidden = false
        }
        JSONLogger.shared.log("win.deminimized", data: [
            "wid": windowID,
            "app": window?.appName ?? "unknown"
        ])
    }

    private func handleWindowTitleChanged(_ windowID: UInt32, title: String) {
        let key = String(windowID)
        guard var window = state.windows[key] else { return }
        window.title = title
        window.lastUpdated = Date()
        state.windows[key] = window
        state.metadata.update()
    }

    private func handleWindowSpaceAssignmentChanged(_ windowID: UInt32, spaces: [UInt64]) async {
        let windowKey = String(windowID)
        guard var window = state.windows[windowKey] else { return }

        let oldSpaces = window.spaces
        window.spaces = spaces
        window.lastUpdated = Date()
        state.windows[windowKey] = window

        JSONLogger.shared.log("win.spaces", data: [
            "wid": windowID,
            "old": oldSpaces,
            "new": spaces,
            "app": window.appName ?? "unknown"
        ])
    }

    private func handleSpaceCreated(_ spaceID: UInt64, displayUUID: String) async {
        JSONLogger.shared.log("spc.created", data: [
            "sid": spaceID,
            "display": displayUUID
        ])
        refreshSpaces()
        state.metadata.update()
    }

    private func handleSpaceDestroyed(_ spaceID: UInt64) async {
        JSONLogger.shared.log("spc.destroyed", data: ["sid": spaceID])

        // Remove from state
        state.spaces.removeValue(forKey: String(spaceID))

        // Clear activeSpaceID if it was the destroyed space
        if state.metadata.activeSpaceID == spaceID {
            updateActiveDisplayFromSpaces()
        }

        state.metadata.update()
    }

    private func handleDisplayConnected(_ displayUUID: String) async {
        JSONLogger.shared.log("dsp.connected", data: ["uuid": displayUUID])
        refreshDisplays()
        refreshSpaces()
        state.metadata.update()
    }

    private func handleDisplayDisconnected(_ displayUUID: String) async {
        JSONLogger.shared.log("dsp.disconnected", data: ["uuid": displayUUID])

        // Clear activeDisplayUUID if it was the disconnected display
        if state.metadata.activeDisplayUUID == displayUUID {
            state.metadata.activeDisplayUUID = nil
            updateActiveDisplayFromSpaces()
        }

        refreshDisplays()
        refreshSpaces()
        state.metadata.update()
    }

    // MARK: - NSWorkspace Event Handlers (System Events)

    private func handleSpaceChanged() async {
        // 1. Store OLD currentSpaceID for each display BEFORE refreshing
        var oldSpaceIDs: [String: UInt64] = [:]
        for display in state.displays {
            oldSpaceIDs[display.uuid] = display.currentSpaceID
        }

        // 2. Refresh spaces and update currentSpaceID for each display
        refreshSpaces()
        refreshDisplayCurrentSpaces()

        // 3. Find which display's space changed - that's the active one
        var foundChangedDisplay = false
        var newSpaceID: UInt64? = nil
        for display in state.displays {
            if let oldSpaceID = oldSpaceIDs[display.uuid],
               display.currentSpaceID != oldSpaceID {
                // This display's space changed!
                state.metadata.activeDisplayUUID = display.uuid
                state.metadata.activeSpaceID = display.currentSpaceID
                newSpaceID = display.currentSpaceID
                foundChangedDisplay = true

                JSONLogger.shared.log("spc.changed", data: [
                    "oldSid": oldSpaceID,
                    "newSid": display.currentSpaceID,
                    "display": display.uuid
                ])
                break
            }
        }

        // Fallback: if no change detected, use the old method
        if !foundChangedDisplay {
            updateActiveDisplayFromSpaces()
        }

        // Re-query space assignments for all visible windows
        for windowKey in state.windows.keys {
            if let windowID = UInt32(windowKey),
               let window = state.windows[windowKey],
               !window.isHidden && !window.isMinimized {
                updateWindowSpaces(windowID)
            }
        }

        // Re-query AX properties for windows on the new active space
        // This populates role/subrole for windows that weren't accessible before
        refreshAXPropertiesForActiveSpace()

        // Auto-focus the new space's last focused window
        if let spaceID = newSpaceID {
            restoreFocusForSpace(spaceID)
        }

        // Note: Border system handles space changes via cell assignments from CLI

        state.metadata.update()
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
                        JSONLogger.shared.log("dsp.update", data: [
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
            JSONLogger.shared.log("warn.dsp", msg: "no active space found")
        }
    }

    /// Restore focus to the last focused window on a space (if it still exists)
    private func restoreFocusForSpace(_ spaceID: UInt64) {
        let spaceKey = String(spaceID)
        guard let space = state.spaces[spaceKey],
              let windowID = space.lastFocusedWindowID else {
return
        }

        // Check if window still exists in our state
        guard let window = state.windows[String(windowID)],
              !window.isHidden && !window.isMinimized else {
return
        }

        Task {
            JSONLogger.shared.log("win.focus.restore", data: [
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
                JSONLogger.shared.log("warn.focus", msg: "restore failed", data: ["wid": windowID])
            }
        }
    }

    private func handleDisplayConfigurationChanged() async {
        // Capture old display UUIDs before refresh
        let oldDisplayUUIDs = Set(state.displays.map { $0.uuid })

        refreshDisplays()
        refreshSpaces()

        // Detect disconnected displays and emit events
        let newDisplayUUIDs = Set(state.displays.map { $0.uuid })
        let disconnectedDisplays = oldDisplayUUIDs.subtracting(newDisplayUUIDs)

        for displayUUID in disconnectedDisplays {
            await EventRouter.shared.route(
                .displayDisconnected(displayUUID: displayUUID),
                from: .workspaceObserver
            )
        }

        state.metadata.update()

        // EventRouter handles logging for individual disconnects
    }

    private func handleApplicationLaunched(_ app: NSRunningApplication) async {
        guard app.activationPolicy == .regular else { return }

        // Create ApplicationState
        let appState = ApplicationState(from: app)
        let pidKey = String(app.processIdentifier)
        state.applications[pidKey] = appState

        // EventRouter handles logging

        // Create AX observer
        createObserver(for: app)

        state.metadata.update()
    }

    private func handleApplicationTerminated(_ app: NSRunningApplication) async {
        let pid = app.processIdentifier
        let pidKey = String(pid)

        // Clear focus if any window from terminated app was focused
        if let focusedID = state.metadata.focusedWindowID,
           let focusedWindow = state.windows[String(focusedID)],
           focusedWindow.pid == pid {
            state.metadata.focusedWindowID = nil
        }

        // Remove application state
        state.applications.removeValue(forKey: pidKey)

        // Remove observer
        removeObserver(for: pid)

        // Remove all windows for this PID
        state.windows = state.windows.filter { $0.value.pid != pid }

        state.metadata.update()
    }

    private func handleApplicationActivated(_ app: NSRunningApplication) async {
        let pid = app.processIdentifier
        let pidKey = String(pid)

        // Update all apps to mark which one is active
        for (key, var appState) in state.applications {
            appState.isActive = (key == pidKey)
            state.applications[key] = appState
        }

        // Query the app's focused window and update focusedWindowID
        // This is needed because not all apps send kAXFocusedWindowChangedNotification reliably
        await updateFocusedWindowForApp(pid: pid)

        state.metadata.update()
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
return
        }

        // Get CGWindowID from AX element
        var windowID: UInt32 = 0
        let windowResult = _AXUIElementGetWindow(windowElement as! AXUIElement, &windowID)

        guard windowResult == .success, windowID != 0 else {
return
        }

        JSONLogger.shared.log("win.focus.app", data: ["wid": windowID, "pid": pid])
        await applyWindowFocus(windowID)
    }

    private func handleApplicationHidden(_ app: NSRunningApplication) async {
        let pid = app.processIdentifier
        let pidKey = String(pid)

        // Update app state
        if state.applications[pidKey] != nil {
            state.applications[pidKey]!.isHidden = true
        }

        // Mark all windows for this app as hidden
        for (key, var window) in state.windows where window.pid == pid {
            window.isHidden = true
            state.windows[key] = window
        }

        state.metadata.update()
    }

    private func handleApplicationUnhidden(_ app: NSRunningApplication) async {
        let pid = app.processIdentifier
        let pidKey = String(pid)

        // Update app state
        if state.applications[pidKey] != nil {
            state.applications[pidKey]!.isHidden = false
        }

        // Mark all windows for this app as visible and re-query their spaces
        for (key, var window) in state.windows where window.pid == pid {
            window.isHidden = false
            state.windows[key] = window

            // Re-query space assignment (may have changed while hidden)
            updateWindowSpaces(window.id)
        }

        state.metadata.update()
    }

    private func handleSystemWoke() async {
        JSONLogger.shared.log("state.wake")
        await refreshCompleteState()
    }

    // MARK: - Mouse Position Helpers

    /// Get current mouse position in global screen coordinates (query-based, not event-driven)
    /// Note: Wrapped in autoreleasepool to prevent CGEvent leaks in async contexts
    func getCurrentMousePosition() -> CGPoint {
        return autoreleasepool {
            guard let event = CGEvent(source: nil) else {
                jlog("warn.mouse", msg: "failed to get position")
                return .zero
            }
            return event.location
        }
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

