//
// MessageHandler+Menu.swift
// GridServer
//
// menu.* RPC methods: an app's menu bar as a flat index of commands, and
// running one of them by path. Titles are user data (Open Recent, Recent
// Folders): only counts are logged.
//

import AppKit
import Foundation

extension MessageHandler {

    func registerMenuHandlers() {
        // menu.snapshot -- { app | windowId, [text], [enabled], [limit] } -> { app, pid, count, scanned, outline, [truncated] }
        register(method: "menu.snapshot") { request, completion in
            let params = request.params
            var limits = MenuAutomation.Limits()
            if let limit = Self.int(params, "limit"), limit > 0 { limits.limit = min(limit, 5000) }
            let text = Self.string(params, "text")
            let enabled = params?["enabled"]?.value as? Bool
            Task {
                switch await Self.menuTarget(params) {
                case .failure(let refusal):
                    completion(Response(id: request.id, error: ErrorInfo(code: refusal.code, message: refusal.reason)))
                case .success(let target):
                    Self.onUIQueue(request, completion) {
                        try MenuAutomation.snapshot(pid: target.pid, app: target.name, text: text, enabled: enabled, limits: limits)
                    }
                }
            }
        }

        // menu.invoke -- { app | windowId, path } -> press the command the path names; brings the app forward first
        register(method: "menu.invoke") { request, completion in
            let params = request.params
            guard let path = Self.string(params, "path"), !MenuPath.parse(path).isEmpty else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "\(MenuError.emptyPath)")))
                return
            }
            Task {
                let target: MenuTarget
                switch await Self.menuTarget(params) {
                case .failure(let refusal):
                    completion(Response(id: request.id, error: ErrorInfo(code: refusal.code, message: refusal.reason)))
                    return
                case .success(let found): target = found
                }
                // A named window is the one the command must act on: make it the key window first.
                if let wid = target.windowID, case .failure(let refusal) = await Self.focusAndVerify(wid) {
                    JSONLogger.shared.log("ui.err", msg: refusal.reason, data: ["method": request.method, "id": request.id])
                    completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: refusal.reason)))
                    return
                }
                Self.onUIQueue(request, completion) {
                    try MenuAutomation.invoke(pid: target.pid, app: target.name, path: path, activate: target.windowID == nil)
                }
            }
        }
    }

    struct MenuTarget {
        let pid: pid_t
        let name: String
        let windowID: UInt32?
    }

    struct MenuRefusal: Error {
        let code: Int
        let reason: String
    }

    /// The app a menu call is aimed at: the owner of `windowId`, else the running app called `app`.
    private static func menuTarget(_ params: [String: AnyCodable]?) async -> Result<MenuTarget, MenuRefusal> {
        let target: MenuTarget
        if params?["windowId"] != nil {
            guard let wid = windowID(params), let window = await StateManager.shared.getState().windows[String(wid)] else {
                return .failure(MenuRefusal(code: -32001, reason: "Window not found: \(string(params, "windowId") ?? "windowId")"))
            }
            target = MenuTarget(pid: window.pid, name: MenuAutomation.plainName(window.appName) ?? "pid \(window.pid)", windowID: wid)
        } else if let name = string(params, "app") {
            guard let app = MenuAutomation.runningApp(named: name) else {
                return .failure(MenuRefusal(code: -32001, reason: "no running app is called '\(name)'; window.find or dump lists app names"))
            }
            target = MenuTarget(pid: app.processIdentifier, name: MenuAutomation.plainName(app.localizedName) ?? name, windowID: nil)
        } else {
            return .failure(MenuRefusal(code: -32602, reason: "app or windowId is required"))
        }
        // AX against our own pid runs in-place and trips AppKit's main-thread assertion.
        guard target.pid != ProcessInfo.processInfo.processIdentifier else {
            return .failure(MenuRefusal(code: -32000, reason: "that is the grid server itself; its menus cannot be read"))
        }
        return .success(target)
    }
}
