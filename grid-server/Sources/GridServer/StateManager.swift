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

actor StateManager: StateEventHandler, StateProvider {
    // MARK: - Shared Instance
    // Thread-safe lazy initialization - actor ensures all access is serialized
    private static let _shared = StateManager()
    static var shared: StateManager { _shared }

    // MARK: - Properties

    private var state: WindowManagerState
    private let connectionID: Int32

    // AX Observers (one per application)
    private var applicationObservers: [pid_t: ApplicationObserver] = [:]
    // #33: pids whose observer is being created on the MainActor but not yet
    // installed. Reserving the slot synchronously (actor-isolated) closes the
    // TOCTOU window where a second createObserver for the same pid passes the
    // nil guard and installs a duplicate live AXObserver.
    private var observerCreationInFlight: Set<pid_t> = []

    // Workspace observer (system-level events)
    private var workspaceObserver: WorkspaceObserver?

    // Polling timer for periodic state refresh
    private var pollTimer: DispatchSourceTimer?

    // Border event handler
    private var borderEvents: BorderEvents?

    // Window blacklist (runtime Set for O(1) lookup)
    private var windowBlacklist: Set<String> = []

    // CLI focus tracking: windowID -> timestamp when CLI focused it
    // Used to distinguish CLI-initiated focus from external (click) focus
    private var cliFocusTimestamps: [UInt32: Date] = [:]

    // #17: highest focus-event sequence applied so far. Stamped in-order at the
    // notification-capture site; a strictly-older stamped event is rejected here
    // so a reordered stale focus cannot invert a newer one.
    private var lastFocusSeq: UInt64 = 0

    // How long to consider a focus as "CLI-initiated" (prevents loop)
    private let cliFocusWindow: TimeInterval = 0.5

    // FIX 2 / DW-D4: removal tombstone. A wid removed from state (poll-prune or
    // handleWindowDestroyed) is stamped here. The poll-apply "window absent from
    // state" branch logs warn.poll.readd ONLY when the wid is still tombstoned
    // within the grace window — a genuine #60 resurrection (the off-actor
    // snapshot predated the removal). Without this gate the branch fired for
    // EVERY poll-discovered window StateManager doesn't track (~126/poll).
    // Actor-isolated — safe (no new shared concurrency state).
    private var removalTombstone: [UInt32: CFAbsoluteTime] = [:]

    // Resurrection grace. Just over one 3.0s poll interval so a snapshot taken
    // before a removal can still resurrect within one poll, but a legitimate
    // later rediscovery (different window, reused id) does not false-positive.
    private let resurrectionGraceSeconds: CFAbsoluteTime = 3.5

    // CLI path (used for ResizeManager)
    private var cliPath: String = "thegrid"

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

        Task {
            JSONLogger.shared.log("state.init", data: ["cid": self.connectionID])
        }
    }

    // MARK: - Public Interface

    func start(gridConfig: GridConfig? = nil) async {
        // Load config from GridConfig (replaces ServerConfig)
        if let cfg = gridConfig {
            // Read values from MainActor-isolated config
            let blacklist = await MainActor.run { cfg.windowBlacklist }
            windowBlacklist = Set(blacklist)
            JSONLogger.shared.log("srv.cfg.loaded", data: [
                "blacklist_count": windowBlacklist.count
            ])
        }

        // Resolve CLI path (transitional: removed when border sync moves in-process)
        let resolvedCliPath = StateManager.resolveCliPath("thegrid")
        cliPath = resolvedCliPath
        ResizeManager.shared.cliPath = resolvedCliPath

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

    /// Override activeSpaceID — used after cross-display moves where the OS
    /// hasn't yet updated which display/space is active.
    func overrideActiveSpace(_ spaceID: UInt64) {
        state.metadata.activeSpaceID = spaceID
    }

    // _test_setState: overwrite the entire state snapshot.
    // Used only in tests to inject a controlled WindowManagerState without
    // triggering real AX/SkyLight queries.
    func _test_setState(_ s: WindowManagerState) {
        state = s
    }

    // FIX 2 / DW-D4 test seams: drive the actor-isolated removal tombstone +
    // resurrection predicate deterministically, off the AX/SLS poll boundary.

    func _test_resetTombstone() {
        removalTombstone = [:]
    }

    func _test_noteRemoval(_ windowID: UInt32, at time: CFAbsoluteTime) {
        removalTombstone[windowID] = time
    }

    func _test_isResurrection(wid: UInt32, now: CFAbsoluteTime) -> Bool {
        GraceWindowPolicy.isResurrection(
            removedAt: removalTombstone[wid],
            now: now,
            graceSeconds: resurrectionGraceSeconds
        )
    }

    func _test_pruneTombstone(now: CFAbsoluteTime) {
        removalTombstone = removalTombstone.filter { _, removedAt in
            GraceWindowPolicy.isResurrection(
                removedAt: removedAt,
                now: now,
                graceSeconds: resurrectionGraceSeconds
            )
        }
    }

    var _test_tombstoneCount: Int { removalTombstone.count }

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
            await removeObserver(for: pid)
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
                await handleWindowFocused(windowID, seq: state.seq)
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

        case .systemWillSleep, .screenLocked, .screenUnlocked:
            // Handled by GridReconciler (validator pause/resume).
            // StateManager itself does not need to react to sleep/lock state.
            break

        case .displayReconfigured(_):
            await handleDisplayConfigurationChanged()

        case .spaceCreated(let spaceID, let displayUUID):
            await handleSpaceCreated(spaceID, displayUUID: displayUUID)

        case .spaceDestroyed(let spaceID):
            await handleSpaceDestroyed(spaceID)

        case .spaceIDReassigned:
            // Handled by GridReconciler (GridState migration + orphan reset)
            break

        case .spaceActivated:
            // Handled by GridReconciler (border resync for the active space).
            break

        case .displayGeometryChanged:
            // Handled by GridReconciler (debounced layout reapply).
            break

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
        let appElement = makeAppElement(pid: pid)

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

        // #63s instrumentation (suspected — trace only, NO behavioral change).
        // enrichDisplayInfo joins SLS managed-display order to NSScreen.screens
        // by array index; with 2+ displays the orders can diverge and attach
        // the wrong frame/scale to a UUID. Record the join so UAT can confirm
        // or drop the finding before any UUID-matching fix is attempted.
        let screenCount = NSScreen.screens.count
        for (index, displayUUID) in displayUUIDs.enumerated() {
            jlog("dsp.refresh.join", data: [
                "index": index,
                "uuid": displayUUID,
                "slsCount": displayUUIDs.count,
                "screenCount": screenCount,
            ])
        }

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
        var title: String?
        var hasCloseButton: Bool = false
        var hasFullscreenButton: Bool = false
        var hasMinimizeButton: Bool = false
        var hasZoomButton: Bool = false
        var isModal: Bool = false
    }

    /// Get AX properties for a window (role, subrole, buttons, modal status)
    /// Used for client-side floating/popup detection
    /// Pure decision for the single-AX-window fallback in getAXProperties.
    ///
    /// Returns true (promote the queried window using the sole AX window's
    /// properties) only when that sole window's CG ID is unresolvable, zero, or
    /// equals the queried ID. A resolvable ID that differs means the queried
    /// window is a distinct phantom and must NOT inherit the real window's
    /// tileable role. Extracted as a static pure helper so the branches can be
    /// unit-tested without driving real AX queries.
    static func shouldUseSoleWindowFallback(
        resolved: AXError,
        soleWindowID: UInt32,
        queriedID: UInt32
    ) -> Bool {
        return resolved != .success || soleWindowID == 0 || soleWindowID == queriedID
    }

    private func getAXProperties(pid: pid_t, windowID: UInt32) -> AXWindowProperties {
        let appElement = makeAppElement(pid: pid)

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

        // Fallback: a single AX window whose own CGWindowID is UNRESOLVABLE is
        // ambiguous — assume the queried ID refers to it. This handles apps like
        // Ghostty where SkyLight reports phantom window IDs but AX exposes one
        // real window that does not resolve back to a concrete CG window ID.
        //
        // But when that single AX window DOES resolve to a concrete ID different
        // from the queried one, the queried window is a distinct phantom (e.g. the
        // transient helper windows AnycubicSlicerNext spawns at launch). Promoting
        // it would hand the phantom the real window's tileable role, letting it
        // pollute a cell until the validator prunes it as ax_orphan — the source
        // of the resize churn and focus storms. Reject it instead.
        if windows.count == 1 {
            var soleWindowID: UInt32 = 0
            let resolved = _AXUIElementGetWindow(windows[0], &soleWindowID)
            if StateManager.shouldUseSoleWindowFallback(
                resolved: resolved,
                soleWindowID: soleWindowID,
                queriedID: windowID
            ) {
                return extractAXProperties(from: windows[0])
            }
        }

        return AXWindowProperties()
    }

    /// Re-query a single window's AX properties and update its cached WindowState.
    ///
    /// #41 Chrome torn-tab grace rescue: the fullscreen-button AX query can race
    /// an app's window creation and cache `hasFullscreenButton == false`, which
    /// classifyWindow reads as a floating PIP. classifyWindow is only re-run from
    /// the reconciler's grace sweep, which previously re-classified the STALE
    /// snapshot. Refreshing AX here lets the sweep classify live state so a
    /// slow-button window tiles without a manual reopen.
    ///
    /// Returns the refreshed WindowState, or nil when the window is no longer
    /// tracked (the grace sweep then drops it).
    func refreshWindowAXProperties(_ windowID: UInt32) async -> WindowState? {
        guard var window = state.windows[String(windowID)] else {
            return nil
        }
        let axProps = getAXProperties(pid: window.pid, windowID: windowID)
        window.role = axProps.role
        window.subrole = axProps.subrole
        window.parent = axProps.parent
        window.hasCloseButton = axProps.hasCloseButton
        window.hasFullscreenButton = axProps.hasFullscreenButton
        window.hasMinimizeButton = axProps.hasMinimizeButton
        window.hasZoomButton = axProps.hasZoomButton
        window.isModal = axProps.isModal
        if let axTitle = axProps.title, !axTitle.isEmpty {
            window.axTitle = axTitle
        }
        state.windows[String(windowID)] = window
        return window
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

        // Get title from AX API
        // This provides tab/document-specific titles for apps like Chrome
        var titleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &titleValue) == .success {
            props.title = titleValue as? String
        }

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

        // Primary: ask SkyLight which space the window's display is showing.
        //
        // This used to read window.spaces first. That was only safe while every
        // window was unconditionally re-pinned to its display's current space —
        // with parked windows now keeping their real space, a focus event on
        // one would have redefined activeSpaceID for the whole reconciler.
        // The window is being focused, so its display's current space is the
        // active one by definition.
        if let displayUUID = SLSCopyManagedDisplayForWindow(connectionID, windowID) {
            let querySpaceID = SLSManagedDisplayGetCurrentSpace(connectionID, displayUUID)
            if querySpaceID != 0 {
                spaceID = querySpaceID
            }
        }
        // Fallback: the window's own space assignment
        if spaceID == nil,
           let window = state.windows[windowKey],
           let firstSpace = window.spaces.first {
            spaceID = UInt64(firstSpace)
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
        let previousDisplay = window.displayUUID
        window.displayUUID = computeDisplayUUID(for: window)
        // A frame change within a single display cannot change space
        // membership. Re-deriving on every frame event is what re-pinned
        // windows parked on an inactive space, and it is the hot path (drags
        // fire continuously), so only a genuine display crossing gets a fresh
        // space query. Anything skipped here is corrected by
        // updateWindowFromPoll, which re-queries SkyLight every poll tick.
        if window.displayUUID != previousDisplay {
            deriveSpaceFromDisplay(for: &window, originalSpaces: querySLSSpaces(for: windowID))
        }
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
        // NOTE: this used to exempt sticky windows (which belong on all spaces)
        // from derivation, via an MSS stickiness query. That query always
        // returned nil because MSS never completed a handshake, so the
        // exemption never fired and the branch was dead. Removed with MSS.
        // If sticky-window support is wanted again it needs a SkyLight-based
        // implementation (window tags), not a scripting addition.
        //
        // The decision itself lives in SpaceDerivationPolicy (pure, unit
        // tested). This wrapper owns only the state write and the log surface.
        //
        // IMPORTANT: `originalSpaces` must be a *freshly reported* SkyLight
        // list, never a previously derived value. Feeding the derived value
        // back in makes the override self-confirming and re-pins every parked
        // window to whatever space is current on its display.
        let decision = SpaceDerivationPolicy.derive(
            displayUUID: window.displayUUID,
            originalSpaces: originalSpaces,
            isOnScreen: !window.isHidden && !window.isMinimized,
            displays: state.displays
        )

        window.spaces = decision.spaces

        switch decision.warning {
        case .override(let from, let to):
            jlog("warn.space.derive_override", data: [
                "wid": window.id,
                "from": from.map { String($0) },
                "to": String(to),
                "app": window.appName ?? "unknown",
            ])

        case .membershipUnknown(let displayUUID):
            jlog("warn.space.display_membership_unknown", data: [
                "wid": window.id,
                "display": displayUUID,
                "app": window.appName ?? "unknown",
            ])

        case .bothFailed:
            // Only warn for real windows, not:
            // - Menu bar items (small height, no display)
            // - Off-screen helper windows (Chrome phantom windows, system panels)
            // - Any window where geometric display lookup failed (Finder/zoom
            //   helpers, system overlays — center isn't on any display, so
            //   there's nothing actionable to do regardless of macOS spaces)
            let isMenuBarItem = window.frame.size.height <= 30 && window.displayUUID == nil
            let isOffScreen = isWindowGeometricallyOffScreen(window.frame)
            let hasNoDisplay = window.displayUUID == nil
            if !isMenuBarItem && !isOffScreen && !hasNoDisplay {
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

        case nil:
            break
        }
    }

    /// Fresh SkyLight space query for a single window.
    ///
    /// Returns an empty array on failure or on an empty result — both mean "we
    /// do not know", which `SpaceDerivationPolicy` treats as "fall back to
    /// geometry". Synchronous C call with no suspension point, so it adds no
    /// interleaving to this actor.
    private func querySLSSpaces(for windowID: UInt32) -> [UInt64] {
        let windowArray = createWindowIDArray([windowID])
        guard let spacesArray = SLSCopySpacesForWindows(connectionID, 0x7, windowArray) else {
            return []
        }
        let spaceNumbers: [NSNumber] = cfArrayToSwiftArray(spacesArray)
        return spaceNumbers.map { $0.uint64Value }
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

        // Build z-order map from on-screen windows
        var zOrderMap: [UInt32: Int32] = [:]
        let onScreenOptions: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        if let onScreenList = CGWindowListCopyWindowInfo(onScreenOptions, kCGNullWindowID) as? [[String: Any]] {
            for (index, windowInfo) in onScreenList.enumerated() {
                if let windowID = windowInfo[kCGWindowNumber as String] as? UInt32 {
                    zOrderMap[windowID] = Int32(index)
                }
            }
            jlog("zorder.map", data: ["count": zOrderMap.count])
        } else {
            jlog("warn.zorder", msg: "failed to get on-screen window list")
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

                // Store AX title separately (richer: includes browser + profile suffix)
                if let axTitle = axProps.title, !axTitle.isEmpty {
                    windowState.axTitle = axTitle
                }
            }

            // Extract isHidden from kCGWindowIsOnscreen (phantom windows lack this key)
            if let isOnScreen = windowInfo["kCGWindowIsOnscreen"] as? Int {
                windowState.isHidden = (isOnScreen != 1)
            } else {
                windowState.isHidden = true
            }

            // Get spaces for this window via the SkyLight API.
            //
            // This used to check MSS for stickiness first and short-circuit to
            // "on all user spaces". That check is gone with MSS: it required SIP
            // to be partially disabled, never completed a handshake in practice,
            // and so always returned nil — the sticky branch was dead code and
            // every window already took the SkyLight path below.
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

            // Compute displayUUID geometrically and derive space from display
            let originalSpaces = windowState.spaces
            windowState.displayUUID = computeDisplayUUID(for: windowState)
            deriveSpaceFromDisplay(for: &windowState, originalSpaces: originalSpaces)

            // Populate zOrder from map (or leave as Int32.max if not on screen)
            windowState.zOrder = zOrderMap[windowID] ?? Int32.max

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
        createObserver(pid: app.processIdentifier, appName: app.localizedName, attempt: 0)
    }

    // #40: a freshly launched app's AX server may not be up when the launch
    // notification fires; observe() returns false (kAXErrorCannotComplete) and
    // the app then runs entirely unobserved. Retry with bounded backoff before
    // giving up so the launch race does not permanently drop AX events.
    private func createObserver(pid: pid_t, appName: String?, attempt: Int) {
        // #33: don't create duplicate observers. Reject if one is already
        // installed OR a creation for this pid is already in flight on the
        // MainActor (the TOCTOU the original nil-only guard missed).
        guard ObserverSlotPolicy.canCreate(
            installed: applicationObservers[pid] != nil,
            inFlight: observerCreationInFlight.contains(pid)) else { return }

        // Reserve the slot synchronously (we are on the actor) BEFORE spawning
        // the MainActor Task, so a second call in the async window is rejected.
        observerCreationInFlight.insert(pid)

        let observer = ApplicationObserver(pid: pid, appName: appName)

        // Observer setup requires main thread for run loop integration.
        // Fire-and-forget Task: observer added to state after MainActor work completes.
        Task { @MainActor in
            if observer.observe(stateManager: self) {
                await self.addApplicationObserver(observer, for: pid)
                return
            }
            await self.scheduleObserverRetry(pid: pid, appName: appName, attempt: attempt)
        }
    }

    private func scheduleObserverRetry(pid: pid_t, appName: String?, attempt: Int) {
        // Clear the in-flight reservation: this attempt failed, so a retry (or a
        // fresh createObserver) for this pid must be allowed to proceed (#33).
        observerCreationInFlight.remove(pid)
        guard let delay = ObserverRetryPolicy.nextDelay(attempt: attempt) else {
            jlog("ax.observer.create.failed", data: [
                "pid": pid,
                "app": appName ?? "unknown",
                "attempt": attempt,
                "op": "register_notifs",
                "giveUp": true,
            ])
            return
        }
        jlog("ax.observer.create.failed", data: [
            "pid": pid,
            "app": appName ?? "unknown",
            "attempt": attempt,
            "op": "register_notifs",
            "retryIn": delay,
        ])
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self?.createObserver(pid: pid, appName: appName, attempt: attempt + 1)
        }
    }

    /// Add an application observer (called from createObserver after MainActor setup)
    private func addApplicationObserver(_ observer: ApplicationObserver, for pid: pid_t) async {
        // #33: if a prior observer somehow occupies this slot, stop it before
        // overwriting — otherwise its run-loop source + unretained refcon stay
        // installed and a later AX callback dereferences a dangling pointer.
        if let displaced = applicationObservers[pid] {
            await MainActor.run {
                displaced.stopObserving()
            }
            jlog("ax.observer.stop", data: ["pid": pid, "reason": "replaced"])
        }
        applicationObservers[pid] = observer
        observerCreationInFlight.remove(pid)
    }

    /// Remove an AX observer for a specific application
    /// IMPORTANT: Must stop observer BEFORE removing from dictionary to prevent race condition
    /// where AX callback fires on a deallocated observer
    private func removeObserver(for pid: pid_t) async {
        guard let observer = applicationObservers[pid] else { return }

        // #44: stop observing FIRST to prevent a callback firing on a removed
        // observer. Use `await MainActor.run` — NOT DispatchQueue.main.sync,
        // which blocks the actor's cooperative-pool thread (forward-progress
        // violation: every command/event awaiting StateManager queues behind a
        // busy main thread). This mirrors rebuildAXObservers.
        await MainActor.run {
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
            // Perform heavy CGWindowList call outside actor to avoid blocking
            let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
            guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
                return
            }
            Task {
                await self?.applyPollResults(windowList)
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

    /// Apply pre-fetched CGWindowList results to state (called on actor)
    private func applyPollResults(_ windowList: [[String: Any]]) {
        let pollTimestamp = Date()
        let pollNow = CFAbsoluteTimeGetCurrent()

        // FIX 2 / DW-D4: drop expired removal tombstones each poll so the map
        // stays bounded and stale entries can't false-positive a resurrection.
        removalTombstone = removalTombstone.filter { _, removedAt in
            GraceWindowPolicy.isResurrection(
                removedAt: removedAt,
                now: pollNow,
                graceSeconds: resurrectionGraceSeconds
            )
        }

        var seenWindowIDs = Set<UInt32>()
        var newWindowIDs: [(UInt32, pid_t)] = []

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
                let pid = windowInfo[kCGWindowOwnerPID as String] as? pid_t ?? 0
                // FIX 2 / DW-D4 (#60): a window absent from state may be a
                // genuine resurrection — a wid removed between the off-actor
                // snapshot and this apply, which the stale snapshot then re-adds.
                // Log warn.poll.readd ONLY for that case (wid still tombstoned
                // within grace). The common case — a window the poll discovered
                // that StateManager simply never tracked — is not a resurrection
                // and must not be logged (it flooded ~126 lines/poll).
                if GraceWindowPolicy.isResurrection(
                    removedAt: removalTombstone[windowID],
                    now: pollNow,
                    graceSeconds: resurrectionGraceSeconds
                ) {
                    jlog("warn.poll.readd", data: ["wid": Int(windowID), "pid": Int(pid)])
                }
                addWindowFromPoll(windowID: windowID, windowInfo: windowInfo, timestamp: pollTimestamp)
                // Track for windowCreated event routing (only if actually added)
                if state.windows[String(windowID)] != nil {
                    newWindowIDs.append((windowID, pid))
                }
            }
        }

        // Route creation events for newly discovered windows so GridReconciler
        // can handle pending launch targets (AX observer may miss early windows)
        if !newWindowIDs.isEmpty {
            Task {
                for (windowID, pid) in newWindowIDs {
                    await EventRouter.shared.route(
                        .windowCreated(windowID: windowID, pid: pid),
                        from: .poll
                    )
                }
            }
        }

        // Remove windows no longer in CGWindowList and notify via EventRouter
        var destroyedWindowIDs: [UInt32] = []
        for windowKey in state.windows.keys {
            if let windowID = UInt32(windowKey), !seenWindowIDs.contains(windowID) {
                let pid = state.windows[windowKey]?.pid
                if state.metadata.focusedWindowID == windowID {
                    state.metadata.focusedWindowID = nil
                }
                state.windows.removeValue(forKey: windowKey)
                // FIX 2 / DW-D4: tombstone the poll-pruned wid so a stale
                // snapshot re-adding it within grace is recognized as a #60
                // resurrection.
                removalTombstone[windowID] = pollNow
                if let pid = pid {
                    state.applications[String(pid)]?.windows.removeAll { $0 == windowID }
                }
                for spaceKey in state.spaces.keys {
                    state.spaces[spaceKey]?.windows.removeAll { $0 == windowID }
                }
                destroyedWindowIDs.append(windowID)
            }
        }

        // Route destroy events so GridReconciler cleans up cell assignments and borders
        if !destroyedWindowIDs.isEmpty {
            Task {
                for windowID in destroyedWindowIDs {
                    await EventRouter.shared.route(
                        .windowDestroyed(windowID: windowID),
                        from: .poll
                    )
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

        // Update title (CGWindowList page title)
        if let name = windowInfo[kCGWindowName as String] as? String {
            window.title = name
        }

        // #61s CONFIRMED and instrumentation dropped (DW-4.9). The trace here
        // fired 3.7M times over 8 days — 96% of all log lines — and confirmed
        // the hypothesis: a window with a real role but a transient "AXUnknown"
        // subrole (cached at creation during app startup) is never re-queried,
        // because the role!=nil guard below skips it, so isTileable rejects the
        // stale subrole forever. 245 windows with real dimensions were bailed as
        // not_tileable on that basis.
        //
        // The requery is NOT added here. getAXProperties costs ~11 blocking IPC
        // messages per window and this runs synchronously on the StateManager
        // actor every poll, so a per-window requery is an actor-stall vector.
        // It also would not be purely additive: isTileable accepts a nil/empty
        // subrole, so resolving one to AXDialog/AXSheet drops a window that
        // tiles correctly today. A fix needs per-pid batching (as
        // StateValidator.pruneAXOrphanedWindows already does), a subrole-only
        // write, and AXError surfaced so transient failures don't burn a retry
        // budget. Tracked separately.

        // Re-query AX properties when role is nil (phantom windows that
        // started with no AX data may now have real properties).
        if window.role == nil {
            let axProps = getAXProperties(pid: window.pid, windowID: windowID)
            if let role = axProps.role {
                window.role = role
                window.subrole = axProps.subrole
                window.parent = axProps.parent
                window.hasCloseButton = axProps.hasCloseButton
                window.hasFullscreenButton = axProps.hasFullscreenButton
                window.hasMinimizeButton = axProps.hasMinimizeButton
                window.hasZoomButton = axProps.hasZoomButton
                window.isModal = axProps.isModal
            }
        }

        // Recompute displayUUID and derive space from display.
        //
        // This is the universal correction path: it runs for every tracked
        // window on every poll tick with a *fresh* SkyLight query, so anything
        // the frame-event fast paths skip, and any window whose space changed
        // without a display change (Mission Control drag, `move --space`,
        // programmatic SLSMoveWindowsToManagedSpace), converges here within one
        // tick. It must never be handed window.spaces — that is the derived
        // value, and feeding it back is what made the override self-confirming.
        window.displayUUID = computeDisplayUUID(for: window)
        deriveSpaceFromDisplay(for: &window, originalSpaces: querySLSSpaces(for: windowID))

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

        // Store AX title separately (richer: includes browser + profile suffix)
        if let axTitle = axProps.title, !axTitle.isEmpty {
            window.axTitle = axTitle
        }

        // Compute displayUUID geometrically and derive space from display.
        //
        // A freshly constructed WindowState has `spaces == []`, so this path
        // used to hand the policy nothing and always land the window on its
        // display's *current* space — which put every window created on an
        // inactive space into the active space's grid. Ask SkyLight instead.
        // If the window is too new for SkyLight to know it yet the result is
        // empty and we fall back to geometry, and the poll corrects it.
        window.displayUUID = computeDisplayUUID(for: window)
        deriveSpaceFromDisplay(for: &window, originalSpaces: querySLSSpaces(for: windowID))

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

        // Store AX title separately (richer: includes browser + profile suffix)
        if let axTitle = axProps.title, !axTitle.isEmpty {
            window.axTitle = axTitle
        }

        // Compute displayUUID geometrically and derive space from display.
        //
        // A freshly constructed WindowState has `spaces == []`, so this path
        // used to hand the policy nothing and always land the window on its
        // display's *current* space — which put every window created on an
        // inactive space into the active space's grid. Ask SkyLight instead.
        // If the window is too new for SkyLight to know it yet the result is
        // empty and we fall back to geometry, and the poll corrects it.
        window.displayUUID = computeDisplayUUID(for: window)
        deriveSpaceFromDisplay(for: &window, originalSpaces: querySLSSpaces(for: windowID))

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

        // FIX 2 / DW-D4: tombstone the destroyed wid so a poll whose snapshot
        // predated this removal, re-adding the wid within grace, is recognized
        // as a #60 resurrection (and only then logs warn.poll.readd).
        removalTombstone[windowID] = CFAbsoluteTimeGetCurrent()

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
        // Only a display crossing can change space membership here — see
        // setWindowFrame for why the same-display case is skipped.
        let previousDisplay = window.displayUUID
        window.displayUUID = computeDisplayUUID(for: window)
        if window.displayUUID != previousDisplay {
            deriveSpaceFromDisplay(for: &window, originalSpaces: querySLSSpaces(for: windowID))
        }
        window.lastUpdated = Date()
        state.windows[String(windowID)] = window
        state.metadata.update()
        // EventRouter handles logging and BorderEvents notification
    }

    private func handleWindowResized(_ windowID: UInt32, frame: CGRect) {
        guard var window = state.windows[String(windowID)] else { return }
        window.frame = frame
        // Only a display crossing can change space membership here — see
        // setWindowFrame for why the same-display case is skipped.
        let previousDisplay = window.displayUUID
        window.displayUUID = computeDisplayUUID(for: window)
        if window.displayUUID != previousDisplay {
            deriveSpaceFromDisplay(for: &window, originalSpaces: querySLSSpaces(for: windowID))
        }
        window.lastUpdated = Date()
        state.windows[String(windowID)] = window
        state.metadata.update()
        // EventRouter handles logging and BorderEvents notification
    }

    private func handleWindowFocused(_ windowID: UInt32, seq: UInt64 = 0) async {
        // #17: drop a stale (reordered-older) focus event. An unstamped event
        // (seq == 0, e.g. internal/test path) always applies. Once a stamped
        // event applies, a strictly-older stamped event is rejected so a focus
        // that lost the executor race cannot overwrite a newer one.
        if seq != 0 {
            guard FocusSequenceGate.shouldApply(incomingSeq: seq, lastAppliedSeq: lastFocusSeq) else {
                JSONLogger.shared.log("focus.seq.reject", data: [
                    "wid": windowID, "seq": seq, "lastSeq": lastFocusSeq,
                ])
                return
            }
            lastFocusSeq = seq
        }

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

        // Border sync is handled by GridReconciler via EventRouter focusChanged events

        if let stateSpan = stateSpan {
            await stateSpan.end()
        }
    }

    // Legacy CLI invocation methods removed — GridReconciler handles
    // border sync and layout refresh via EventRouter events.

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
        // AX title notifications carry the full title (e.g., with profile
        // suffix), but Chrome emits transient empty titles mid-load. An empty
        // title is never worth persisting over a known-good one — skip the
        // write so the profile-bearing axTitle survives.
        guard ChromeTitlePolicy.shouldOverwriteAXTitle(existing: window.axTitle, incoming: title) else {
            return
        }
        window.axTitle = title
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

        // 2. Capture old space IDs, refresh, and diff for created/destroyed
        let oldSpaceKeys = Set(state.spaces.keys)
        refreshSpaces()
        refreshDisplayCurrentSpaces()
        await diffAndRouteSpaceEvents(oldSpaceKeys: oldSpaceKeys)

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

                // #2: only a TRUE macOS reassignment (old space ID no longer
                // exists in the refreshed OS space set) migrates GridState. A
                // plain desktop switch leaves the old ID present and routes a
                // dedicated spaceActivated event — no migration, no data loss.
                let refreshedSpaceIDs = Set(state.spaces.keys)
                let routing = SpaceMigrationPolicy.classifySpaceChange(
                    oldSpaceID: String(oldSpaceID),
                    newSpaceID: String(display.currentSpaceID),
                    refreshedSpaceIDs: refreshedSpaceIDs
                )

                switch routing {
                case .reassigned:
                    // Migrate GridState and reset AX orphan counts before the
                    // validator prunes windows only transiently invisible
                    // during the space ID shuffle.
                    await EventRouter.shared.route(
                        .spaceIDReassigned(
                            oldSpaceID: String(oldSpaceID),
                            newSpaceID: String(display.currentSpaceID),
                            displayUUID: display.uuid
                        ),
                        from: .workspaceObserver
                    )
                case .activated:
                    await EventRouter.shared.route(
                        .spaceActivated(
                            spaceID: String(display.currentSpaceID),
                            displayUUID: display.uuid
                        ),
                        from: .workspaceObserver
                    )
                }

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

        state.metadata.update()

        // Layout refresh handled by GridReconciler via EventRouter space change events
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

        // #59s (suspected): instrument-only. If the last-focused window has since
        // left this space, restoring it would AX-raise it and yank the user back
        // to the window's CURRENT space. Log the skip signal so UAT can confirm
        // or drop the finding; behavior is intentionally unchanged for now.
        if shouldSkipRestore(windowSpaces: window.spaces, spaceID: spaceID) {
            Task {
                JSONLogger.shared.log("win.focus.restore.skip", data: [
                    "sid": spaceID,
                    "wid": windowID,
                    "winSpaces": window.spaces.map { Int($0) },
                    "app": window.appName ?? "unknown",
                ])
            }
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

    /// Diffs old vs current space keys and routes spaceCreated/spaceDestroyed events.
    private func diffAndRouteSpaceEvents(oldSpaceKeys: Set<String>) async {
        let newSpaceKeys = Set(state.spaces.keys)
        let createdSpaces = newSpaceKeys.subtracting(oldSpaceKeys)
        let destroyedSpaces = oldSpaceKeys.subtracting(newSpaceKeys)

        for spaceKey in createdSpaces {
            if let spaceID = UInt64(spaceKey),
               let space = state.spaces[spaceKey] {
                await EventRouter.shared.route(
                    .spaceCreated(spaceID: spaceID, displayUUID: space.displayUUID),
                    from: .workspaceObserver
                )
            }
        }

        for spaceKey in destroyedSpaces {
            if let spaceID = UInt64(spaceKey) {
                await EventRouter.shared.route(
                    .spaceDestroyed(spaceID: spaceID),
                    from: .workspaceObserver
                )
            }
        }
    }

    // Capture each display's geometry (frame + visibleFrame) keyed by UUID.
    // Used to diff geometry-only reconfigurations (#25) where the UUID set is
    // unchanged but resolution / scaling / Dock geometry moved.
    private func captureDisplayGeometry() -> [String: DisplayGeometryPolicy.Geometry] {
        var geo: [String: DisplayGeometryPolicy.Geometry] = [:]
        for display in state.displays {
            geo[display.uuid] = DisplayGeometryPolicy.Geometry(
                frame: display.frame,
                visibleFrame: display.visibleFrame
            )
        }
        return geo
    }

    private func handleDisplayConfigurationChanged() async {
        // Capture old display UUIDs + geometry before refresh
        let oldDisplayUUIDs = Set(state.displays.map { $0.uuid })
        let oldGeometry = captureDisplayGeometry()
        let oldSpaceKeys = Set(state.spaces.keys)

        // Debug: log state before refresh
        JSONLogger.shared.log("dbg.dsp.reconfig.start", data: [
            "oldCount": oldDisplayUUIDs.count,
            "oldUUIDs": Array(oldDisplayUUIDs)
        ])

        refreshDisplays()
        refreshSpaces()

        // Detect disconnected/connected displays
        let newDisplayUUIDs = Set(state.displays.map { $0.uuid })
        let disconnectedDisplays = oldDisplayUUIDs.subtracting(newDisplayUUIDs)
        let connectedDisplays = newDisplayUUIDs.subtracting(oldDisplayUUIDs)

        // Debug: log diff after refresh
        JSONLogger.shared.log("dbg.dsp.reconfig.diff", data: [
            "newCount": newDisplayUUIDs.count,
            "newUUIDs": Array(newDisplayUUIDs),
            "disconnected": Array(disconnectedDisplays),
            "connected": Array(connectedDisplays)
        ])

        for displayUUID in connectedDisplays {
            await EventRouter.shared.route(
                .displayConnected(displayUUID: displayUUID),
                from: .workspaceObserver
            )
        }

        for displayUUID in disconnectedDisplays {
            await EventRouter.shared.route(
                .displayDisconnected(displayUUID: displayUUID),
                from: .workspaceObserver
            )
        }

        // #25/#62s: geometry-only reconfiguration. Displays present in BOTH
        // snapshots whose frame/visibleFrame changed produce no connect/
        // disconnect event, so without this diff the reconciler never reapplies
        // layouts after a resolution/scaling/Dock change.
        let newGeometry = captureDisplayGeometry()
        let geometryChanged = DisplayGeometryPolicy.changedDisplays(
            old: oldGeometry, new: newGeometry)
        for displayUUID in geometryChanged {
            // #62s instrumentation (load-bearing — also drives the #25 fix).
            JSONLogger.shared.log("dsp.geometry.change", data: [
                "display": displayUUID,
                "oldFrame": String(describing: oldGeometry[displayUUID]?.frame),
                "newFrame": String(describing: newGeometry[displayUUID]?.frame),
            ])
            await EventRouter.shared.route(
                .displayGeometryChanged(displayUUID: displayUUID),
                from: .workspaceObserver
            )
        }

        await diffAndRouteSpaceEvents(oldSpaceKeys: oldSpaceKeys)

        state.metadata.update()
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
        await removeObserver(for: pid)

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
        let appElement = makeAppElement(pid: pid)

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
        JSONLogger.shared.log("dbg.wake.start", data: [
            "displayCount": state.displays.count,
            "displayUUIDs": state.displays.map { $0.uuid }
        ])

        // Let macOS stabilize displays, spaces, and accessibility subsystem.
        // Without this delay, SkyLight/AX queries return stale or incomplete data.
        // BFD uses a similar 1s delay for event tap recovery.
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        await refreshCompleteState()

        // Rebuild AX observers — existing observers may have stale connections
        // after sleep, causing role queries to return AXApplication instead of AXWindow
        await rebuildAXObservers()

        JSONLogger.shared.log("dbg.wake.complete", data: [
            "displayCount": state.displays.count,
            "displayUUIDs": state.displays.map { $0.uuid }
        ])
    }

    /// Stop all AX observers and re-create them with fresh connections.
    /// Called after wake to ensure role/attribute queries return correct data.
    private func rebuildAXObservers() async {
        let oldCount = applicationObservers.count

        // Stop all existing observers on the main thread (required for RunLoop cleanup)
        for (_, observer) in applicationObservers {
            await MainActor.run {
                observer.stopObserving()
            }
        }
        applicationObservers.removeAll()

        // Re-create observers for all running applications
        observeExistingApplications()

        JSONLogger.shared.log("ax.observer.rebuild", data: [
            "old": oldCount,
            "new": applicationObservers.count
        ])
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

    // MARK: - CLI Path Resolution (transitional, removed when CLI invocation moves in-process)

    private static func resolveCliPath(_ name: String) -> String {
        if name.hasPrefix("/") { return name }
        let searchPaths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            NSHomeDirectory() + "/.local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        let fm = FileManager.default
        for candidate in searchPaths {
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return name
    }
}

