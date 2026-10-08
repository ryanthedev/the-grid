//
// SpaceControl.swift
// GridServer
//
// Spaces as the window server reports them right now, and the rules for the
// two calls that change them. The rules are pure functions so they can be
// tested without a window server; both fail closed: what cannot be read is refused.
//

import CoreGraphics
import Foundation

/// When a space switch or a window pull is allowed.
///
/// A fullscreen space is somebody's video, presentation or fullscreen app.
/// Switching its display away takes that off screen, and windows cannot be
/// moved onto or off such a space, so both calls refuse by default.
enum SpacePolicy {
    enum Decision: Equatable {
        case proceed
        /// Nothing to do: the space is already current / the window is already there.
        case alreadyDone
        case refuse(String)
    }

    /// - Parameters:
    ///   - targetType: type of the space to switch to; nil when no display lists that space.
    ///   - displayCurrentType: type of the space its display shows now; nil when that could not be read.
    ///   - leaveFullscreen: the caller's explicit override for a display that is showing a fullscreen space.
    static func switchDecision(targetType: SpaceType?, targetIsCurrent: Bool, displayCurrentType: SpaceType?, leaveFullscreen: Bool) -> Decision {
        guard let targetType else { return .refuse("no display has that space; space.list shows the space ids") }
        guard targetType == .user else {
            return .refuse("that is a \(targetType.description) space; only user spaces can be switched to (to reach a fullscreen app, focus its window)")
        }
        if targetIsCurrent { return .alreadyDone }
        guard let displayCurrentType else { return .refuse("could not read what that display is showing now, so nothing was switched") }
        switch displayCurrentType {
        case .user:
            return .proceed
        case .fullscreen:
            guard leaveFullscreen else {
                return .refuse("that display is showing a fullscreen space (a video, a presentation or a fullscreen app) and switching would take it off screen; nothing was switched. Pass leaveFullscreen=true only when the user asked for exactly that")
            }
            return .proceed
        case .system:
            return .refuse("that display is showing a system space; nothing was switched")
        }
    }

    /// - Parameters:
    ///   - windowSpaces: every space the window is on, with its type (nil = unreadable).
    ///   - target: the active display's current space; nil when it could not be read.
    static func pullDecision(windowSpaces: [(id: UInt64, type: SpaceType?)], target: (id: UInt64, type: SpaceType?)?) -> Decision {
        guard !windowSpaces.isEmpty else {
            return .refuse("the window server lists no space for that window (it may be minimized: window.unminimize), so nothing was moved")
        }
        for space in windowSpaces {
            guard let type = space.type else { return .refuse("could not read the type of space \(space.id), which the window is on; nothing was moved") }
            guard type == .user else {
                return .refuse("that window is on a \(type.description) space (\(space.id)); windows are never pulled off one. Nothing was moved")
            }
        }
        guard let target, let targetType = target.type else { return .refuse("could not read the active display's current space; nothing was moved") }
        guard targetType == .user else {
            return .refuse("the active display is showing a \(targetType.description) space (\(target.id)); windows are never pulled onto one. Focus a window on the display you want first. Nothing was moved")
        }
        if windowSpaces.contains(where: { $0.id == target.id }) { return .alreadyDone }
        return .proceed
    }
}

/// Live reads from SkyLight. The server's cached state trails a space change,
/// and these answers gate calls that must not be wrong.
enum SpaceControl {
    struct Display {
        let uuid: String
        let current: UInt64
        let spaces: [(id: UInt64, type: SpaceType?)]
    }

    static func displays(_ cid: Int32) -> [Display] {
        guard let array = SLSCopyManagedDisplaySpaces(cid) as? [NSDictionary] else { return [] }
        return array.compactMap { info in
            guard let uuid = info["Display Identifier"] as? String, let spaces = info["Spaces"] as? [NSDictionary] else { return nil }
            let ids = spaces.compactMap { extractSpaceID(from: $0) }
            return Display(uuid: uuid, current: SLSManagedDisplayGetCurrentSpace(cid, uuid as CFString),
                           spaces: ids.map { ($0, type(of: $0, cid)) })
        }
    }

    /// nil for a type this code does not know: callers refuse rather than guess.
    static func type(of space: UInt64, _ cid: Int32) -> SpaceType? {
        SpaceType(rawValue: SLSSpaceGetType(cid, space))
    }

    static func spaces(of window: UInt32, _ cid: Int32) -> [UInt64] {
        guard let array = SLSCopySpacesForWindows(cid, 0x7, [NSNumber(value: window)] as CFArray) as? [NSNumber] else { return [] }
        return array.map(\.uint64Value)
    }
}
