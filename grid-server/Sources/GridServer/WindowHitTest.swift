//
// WindowHitTest.swift
// GridServer
//
// Which window would a click at a point actually reach? A window screenshot
// shows a window even when another one covers it, so an agent can see a
// button it cannot click: the event goes to whatever is on top.
//

import CoreGraphics
import Foundation

struct WindowHitTest {
    struct Entry: Equatable {
        let windowID: UInt32
        let pid: pid_t
        let ownerName: String
        let layer: Int
        let alpha: Double
        let bounds: CGRect
    }

    /// On-screen windows, front to back, in global top-left points.
    static func onScreenWindows() -> [Entry] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else {
                return nil
            }
            return Entry(windowID: number, pid: pid,
                         ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
                         layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                         alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                         bounds: bounds)
        }
    }

    /// The frontmost window a click at `point` would reach. Layers below zero
    /// (the grid's border overlays, the desktop) and invisible windows never
    /// take a click.
    static func top(at point: CGPoint, in windows: [Entry]) -> Entry? {
        // The cursor itself is a Window Server window at the very front.
        windows.first { $0.layer >= 0 && $0.alpha > 0 && $0.ownerName != "Window Server" && $0.bounds.contains(point) }
    }

    /// Why a click at `point` would not reach the app that owns the target
    /// window, or nil when it would. The owning app is what is compared, not
    /// the window: its own menus, popovers and sheets are separate windows and
    /// are legitimate targets.
    static func obstruction(at point: CGPoint, targetPid: pid_t, windowID: UInt32, in windows: [Entry]) -> String? {
        guard let top = top(at: point, in: windows) else {
            return "no window is under (\(point.x.rounded()), \(point.y.rounded()))"
        }
        guard top.pid != targetPid else { return nil }
        return "(\(point.x.rounded()), \(point.y.rounded())) is covered by \(top.ownerName) (window \(top.windowID)), not window \(windowID); nothing was clicked"
    }
}
