//
// WorkspaceObserver.swift
// GridServer
//
// Observes system-level events via NSWorkspace notifications
//

import Foundation
import AppKit

/// Manages NSWorkspace notifications for system-level events
class WorkspaceObserver {
    weak var stateManager: StateManager?

    init() {}

    /// Start observing workspace notifications
    func observe(stateManager: StateManager) {
        self.stateManager = stateManager

        let nc = NSWorkspace.shared.notificationCenter

        // Space and display changes
        nc.addObserver(
            self,
            selector: #selector(spaceChanged(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        // Application lifecycle
        nc.addObserver(
            self,
            selector: #selector(applicationLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )

        nc.addObserver(
            self,
            selector: #selector(applicationTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        nc.addObserver(
            self,
            selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        // Application visibility
        nc.addObserver(
            self,
            selector: #selector(applicationHidden(_:)),
            name: NSWorkspace.didHideApplicationNotification,
            object: nil
        )

        nc.addObserver(
            self,
            selector: #selector(applicationUnhidden(_:)),
            name: NSWorkspace.didUnhideApplicationNotification,
            object: nil
        )

        // System events
        nc.addObserver(
            self,
            selector: #selector(systemWoke(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        nc.addObserver(
            self,
            selector: #selector(screenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        Task {
            await JSONLogger.shared.log("ws.register", data: [:])
        }
    }

    /// Stop observing
    func stopObserving() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        Task {
            await JSONLogger.shared.log("ws.stop", data: [:])
        }
    }

    // MARK: - Space/Display Event Handlers

    @objc private func spaceChanged(_ notification: Notification) {
        Task {
            await JSONLogger.shared.log("ws.space", data: [:])
            let focusState = FocusState(
                spaceID: 0,
                displayUUID: "",
                trigger: .spaceSwitched
            )
            await EventRouter.shared.route(.focusChanged(focusState), from: .workspaceObserver)
        }
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        Task {
            await JSONLogger.shared.log("ws.screen", data: [:])
            await EventRouter.shared.route(.displayReconfigured(displayUUID: ""), from: .workspaceObserver)
        }
    }

    // MARK: - Application Lifecycle Handlers

    @objc private func applicationLaunched(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        Task {
            await JSONLogger.shared.log("app.launch", data: [
                "app": app.localizedName ?? "?",
                "pid": app.processIdentifier
            ])
            await EventRouter.shared.route(.appLaunched(app: app), from: .workspaceObserver)
        }
    }

    @objc private func applicationTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        Task {
            await JSONLogger.shared.log("app.term", data: [
                "app": app.localizedName ?? "?",
                "pid": app.processIdentifier
            ])
            await EventRouter.shared.route(.appTerminated(app: app), from: .workspaceObserver)
        }
    }

    @objc private func applicationActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        Task {
            let focusState = FocusState(
                spaceID: 0,
                displayUUID: "",
                trigger: .appActivated
            )
            await EventRouter.shared.route(.focusChanged(focusState), from: .workspaceObserver)
        }
    }

    // MARK: - Application Visibility Handlers

    @objc private func applicationHidden(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        Task {
            await JSONLogger.shared.log("app.hide", data: [
                "app": app.localizedName ?? "?",
                "pid": app.processIdentifier
            ])
            await EventRouter.shared.route(.appHidden(app: app), from: .workspaceObserver)
        }
    }

    @objc private func applicationUnhidden(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        Task {
            await JSONLogger.shared.log("app.unhide", data: [
                "app": app.localizedName ?? "?",
                "pid": app.processIdentifier
            ])
            await EventRouter.shared.route(.appUnhidden(app: app), from: .workspaceObserver)
        }
    }

    // MARK: - System Event Handlers

    @objc private func systemWoke(_ notification: Notification) {
        Task {
            await JSONLogger.shared.log("ws.wake", data: [:])
            await EventRouter.shared.route(.systemWoke, from: .workspaceObserver)
        }
    }
}
