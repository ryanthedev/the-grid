//
// MessageHandler+Space.swift
// GridServer
//
// space.list, space.switch and window.pull: see which space a window is on,
// go to it, or bring it here. SkyLight's mutating calls return nothing and the
// window server may ignore them, so both actions read the result back and
// fail when it did not happen. SpacePolicy decides what is refused.
//

import CoreGraphics
import Foundation

extension MessageHandler {

    func registerSpaceHandlers() {
        // space.list -- {} -> { activeDisplayUUID, displays: [{ uuid, name, frame, isActive, currentSpaceId, spaces: [{ id, index, type, isCurrent, windows }] }] }
        register(method: "space.list") { request, completion in
            Task {
                let state = await StateManager.shared.getState()
                let cid = state.metadata.connectionID
                let displays: [[String: Any]] = SpaceControl.displays(cid).map { display in
                    let known = state.displays.first { $0.uuid == display.uuid }
                    let spaces: [[String: Any]] = display.spaces.enumerated().map { index, space in
                        // Windows on a hidden space have no AX role (AX cannot see them), so judge by level and size.
                        let windows = state.windows.values
                            .filter { $0.spaces.contains(space.id) && $0.level == 0 && $0.frame.width >= 100 && $0.frame.height >= 100 && $0.appName != nil }
                            .sorted { $0.id < $1.id }
                            .map { ["windowId": String($0.id), "appName": MenuAutomation.plainName($0.appName) ?? "", "title": $0.title ?? "",
                                    "isMinimized": $0.isMinimized] as [String: Any] }
                        return ["id": String(space.id), "index": index + 1, "type": space.type?.description ?? "unknown",
                                "isCurrent": space.id == display.current, "windows": windows]
                    }
                    var out: [String: Any] = ["uuid": display.uuid, "isActive": display.uuid == state.metadata.activeDisplayUUID,
                                              "currentSpaceId": String(display.current), "spaces": spaces]
                    if let name = known?.name { out["name"] = name }
                    if let f = known?.frame { out["frame"] = ["x": f.minX, "y": f.minY, "width": f.width, "height": f.height] }
                    return out
                }
                completion(Response(id: request.id, result: AnyCodable(["activeDisplayUUID": state.metadata.activeDisplayUUID ?? "", "displays": displays])))
            }
        }

        // space.switch -- { spaceId, [leaveFullscreen] } -> { spaceId, displayUUID, previousSpaceId, verified }
        register(method: "space.switch") { request, completion in
            let params = request.params
            guard let target = Self.number(params, "spaceId").flatMap({ UInt64(exactly: $0) }) else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "spaceId is required (a number from space.list)")))
                return
            }
            let leaveFullscreen = params?["leaveFullscreen"]?.value as? Bool ?? false
            Task {
                let cid = await StateManager.shared.getState().metadata.connectionID
                let display = SpaceControl.displays(cid).first { $0.spaces.contains { $0.id == target } }
                let decision = SpacePolicy.switchDecision(
                    targetType: display?.spaces.first { $0.id == target }?.type,
                    targetIsCurrent: display?.current == target,
                    displayCurrentType: display.flatMap { SpaceControl.type(of: $0.current, cid) },
                    leaveFullscreen: leaveFullscreen)
                guard let display, decision != .alreadyDone else {
                    if case .refuse(let why) = decision { return Self.refuseSpace(request, completion, "space.switch refused: \(why)") }
                    completion(Response(id: request.id, result: AnyCodable(["spaceId": String(target), "already": true, "verified": true])))
                    return
                }
                if case .refuse(let why) = decision { return Self.refuseSpace(request, completion, "space.switch refused: \(why)") }

                let previous = display.current
                JSONLogger.shared.log("spc.switch", data: ["sid": target, "from": previous, "leaveFullscreen": leaveFullscreen])
                guard SLSManagedDisplaySetCurrentSpace(cid, display.uuid as CFString, target) else {
                    return Self.refuseSpace(request, completion, "this macOS has no SLSManagedDisplaySetCurrentSpace; the space was not switched")
                }
                // The call returns nothing: read the display's current space back until it says so.
                var verified = false
                for _ in 0..<30 where !verified {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    verified = SLSManagedDisplayGetCurrentSpace(cid, display.uuid as CFString) == target
                }
                guard verified else {
                    return Self.refuseSpace(request, completion, "space \(target) did not become current (the display still shows \(SLSManagedDisplayGetCurrentSpace(cid, display.uuid as CFString))): the window server ignored the switch")
                }
                // Only once the record has flipped: bring the new space's windows in and the old one's out.
                SLSShowSpaces(cid, [NSNumber(value: target)] as CFArray)
                SLSHideSpaces(cid, [NSNumber(value: previous)] as CFArray)
                completion(Response(id: request.id, result: AnyCodable([
                    "spaceId": String(target), "displayUUID": display.uuid, "previousSpaceId": String(previous), "verified": true,
                ])))
            }
        }

        // window.pull -- { windowId } -> bring the window to the active display's current space
        register(method: "window.pull") { request, completion in
            guard let wid = Self.windowID(request.params) else {
                completion(Response(id: request.id, error: ErrorInfo(code: -32602, message: "windowId is required")))
                return
            }
            Task {
                let state = await StateManager.shared.getState()
                guard let window = state.windows[String(wid)] else {
                    completion(Response(id: request.id, error: ErrorInfo(code: -32001, message: "Window not found: \(wid)")))
                    return
                }
                guard window.pid != ProcessInfo.processInfo.processIdentifier else {
                    return Self.refuseSpace(request, completion, "window.pull refused: window \(wid) belongs to the grid server")
                }
                let cid = state.metadata.connectionID
                let from = SpaceControl.spaces(of: wid, cid)
                let active = SpaceControl.displays(cid).first { $0.uuid == state.metadata.activeDisplayUUID }
                let target = active.map { (id: $0.current, type: SpaceControl.type(of: $0.current, cid)) }
                let decision = SpacePolicy.pullDecision(windowSpaces: from.map { ($0, SpaceControl.type(of: $0, cid)) }, target: target)
                guard let target, decision == .proceed else {
                    if case .refuse(let why) = decision { return Self.refuseSpace(request, completion, "window.pull refused: \(why)") }
                    completion(Response(id: request.id, result: AnyCodable([
                        "windowId": String(wid), "spaceId": String(target?.id ?? 0), "already": true, "verified": true,
                    ])))
                    return
                }

                JSONLogger.shared.log("spc.pull", data: ["wid": wid, "sid": target.id, "from": from.first ?? 0])
                await EventRouter.shared.route(
                    .commandMoveWindowToSpace(windowID: wid, spaceID: target.id, requestID: UUID().uuidString),
                    from: .manual(reason: "cli")
                )
                _ = WindowManipulator(connectionID: cid).moveWindowToSpace(windowID: wid, spaceID: target.id)
                // The move is asynchronous and only shows once this task yields; its return value says nothing.
                var verified = false
                for _ in 0..<40 where !verified {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    verified = SpaceControl.spaces(of: wid, cid).contains(target.id)
                }
                guard verified else {
                    let still = SpaceControl.spaces(of: wid, cid).map(String.init).joined(separator: ", ")
                    return Self.refuseSpace(request, completion, "window \(wid) was not pulled: it is still on space \(still). The window server ignored the move (recent macOS does, for a window on a space that is not visible)")
                }
                completion(Response(id: request.id, result: AnyCodable([
                    "windowId": String(wid), "spaceId": String(target.id), "from": from.map(String.init), "verified": true,
                ])))
            }
        }
    }

    private static func refuseSpace(_ request: Request, _ completion: @escaping (Response) -> Void, _ reason: String) {
        JSONLogger.shared.log("err.space", msg: reason, data: ["method": request.method, "id": request.id])
        completion(Response(id: request.id, error: ErrorInfo(code: -32000, message: reason)))
    }
}
