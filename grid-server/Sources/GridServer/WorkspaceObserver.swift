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
            await EventLog.shared.log("ws.register", [:])
        }
    }

    /// Stop observing
    func stopObserving() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        Task {
            await EventLog.shared.log("ws.stop", [:])
        }
    }

    // MARK: - Space/Display Event Handlers

    @objc private func spaceChanged(_ notification: Notification) {
        Task {
            await EventLog.shared.log("ws.space", [:])
        }
        stateManager?.handleSpaceChanged()
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        Task {
            await EventLog.shared.log("ws.screen", [:])
        }
        stateManager?.handleDisplayConfigurationChanged()
    }

    // MARK: - Application Lifecycle Handlers

    @objc private func applicationLaunched(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        Task {
            await EventLog.shared.log("app.launch", [
                "app": app.localizedName ?? "?",
                "pid": app.processIdentifier
            ])
        }

        stateManager?.handleApplicationLaunched(app)
    }

    @objc private func applicationTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        Task {
            await EventLog.shared.log("app.term", [
                "app": app.localizedName ?? "?",
                "pid": app.processIdentifier
            ])
        }

        stateManager?.handleApplicationTerminated(app)
    }

    @objc private func applicationActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        stateManager?.handleApplicationActivated(app)
    }

    // MARK: - Application Visibility Handlers

    @objc private func applicationHidden(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        Task {
            await EventLog.shared.log("app.hide", [
                "app": app.localizedName ?? "?",
                "pid": app.processIdentifier
            ])
        }

        stateManager?.handleApplicationHidden(app)
    }

    @objc private func applicationUnhidden(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        Task {
            await EventLog.shared.log("app.unhide", [
                "app": app.localizedName ?? "?",
                "pid": app.processIdentifier
            ])
        }

        stateManager?.handleApplicationUnhidden(app)
    }

    // MARK: - System Event Handlers

    @objc private func systemWoke(_ notification: Notification) {
        Task {
            await EventLog.shared.log("ws.wake", [:])
        }
        stateManager?.handleSystemWoke()
    }
}
