//
//  MSSClient.swift
//  GridServer
//
//  Swift wrapper for the MSS (macOS Scripting Addition) library
//  Provides access to window and space manipulation via SkyLight APIs
//

import Foundation
import mss

// MARK: - WindowLayer

/// Swift-native wrapper for mss_window_layer C enum
enum WindowLayer: String, CustomStringConvertible {
    case below
    case normal
    case above

    var description: String { rawValue }

    /// Convert to C enum value for MSS calls
    var mssValue: mss_window_layer {
        switch self {
        case .below: return MSS_LAYER_BELOW
        case .normal: return MSS_LAYER_NORMAL
        case .above: return MSS_LAYER_ABOVE
        }
    }

    /// Initialize from C enum value
    init?(mssValue: mss_window_layer) {
        switch mssValue {
        case MSS_LAYER_BELOW: self = .below
        case MSS_LAYER_NORMAL: self = .normal
        case MSS_LAYER_ABOVE: self = .above
        default: return nil
        }
    }

    /// Initialize from string
    init?(string: String) {
        self.init(rawValue: string.lowercased())
    }
}

/// Client for communicating with the MSS scripting addition payload
class MSSClient {
    private var ctx: OpaquePointer?
    private let queue = DispatchQueue(label: "com.grid.mss")

    /// Initialize MSS client with optional custom socket path
    /// - Parameters:
    ///   - socketPath: Optional custom socket path (defaults to MSS default)
    init(socketPath: String? = nil) {
        queue.sync {
            // Create MSS context
            if let path = socketPath {
                self.ctx = mss_create(path)
            } else {
                self.ctx = mss_create(nil) // Use default path: /tmp/mss_<username>.socket
            }

            guard ctx != nil else {
                Task { JSONLogger.shared.log("err.mss", data: ["op": "init"]) }
                return
            }

            Task { JSONLogger.shared.log("mss.init", data: [:]) }
        }
    }

    deinit {
        if let ctx = ctx {
            mss_destroy(ctx)
        }
    }

    // MARK: - Availability & Status

    /// Check if MSS payload is loaded and available
    /// - Returns: true if MSS is ready to use
    func isAvailable() -> Bool {
        return queue.sync {
            guard let ctx = ctx else {
                return false
            }

            var capabilities: UInt32 = 0
            var version: UnsafePointer<CChar>?

            let result = mss_handshake(ctx, &capabilities, &version)

            if result == 0 {  // MSS_SUCCESS = 0
                return true
            } else {
                Task { JSONLogger.shared.log("mss.fail", data: ["op": "handshake", "err": result]) }
                return false
            }
        }
    }

    /// Get MSS version and capabilities
    /// - Returns: Tuple of (version, capabilities) or nil if unavailable
    func getInfo() -> (version: String, capabilities: UInt32)? {
        return queue.sync {
            guard let ctx = ctx else { return nil }

            var capabilities: UInt32 = 0
            var version: UnsafePointer<CChar>?

            let result = mss_handshake(ctx, &capabilities, &version)

            if result == 0, let versionPtr = version {  // MSS_SUCCESS = 0
                return (String(cString: versionPtr), capabilities)
            }

            return nil
        }
    }

    // MARK: - Window Operations

    /// Move window to a specific space
    /// - Parameters:
    ///   - windowID: The window ID (CGWindowID)
    ///   - spaceID: The destination space ID (CGSSpaceID)
    /// - Returns: true if successful
    func moveWindowToSpace(windowID: UInt32, spaceID: UInt64) -> Bool {
        return queue.sync {
            guard let ctx = ctx else {
                Task { JSONLogger.shared.log("err.mss", data: ["op": "no_ctx"]) }
                return false
            }

            let result = mss_window_move_to_space(ctx, windowID, spaceID)

            if !result {
                Task { JSONLogger.shared.log("mss.fail", data: ["op": "move", "wid": windowID, "sid": spaceID]) }
            }

            return result
        }
    }

    /// Set window opacity (instant change)
    /// - Parameters:
    ///   - windowID: The window ID
    ///   - opacity: Opacity value (0.0 = fully transparent, 1.0 = fully opaque)
    /// - Returns: true if successful
    func setWindowOpacity(windowID: UInt32, opacity: Float) -> Bool {
        return queue.sync {
            guard let ctx = ctx else { return false }

            let clampedOpacity = max(0.0, min(1.0, opacity))
            return mss_window_set_opacity(ctx, windowID, clampedOpacity)
        }
    }

    /// Fade window opacity over time (animated)
    /// - Parameters:
    ///   - windowID: The window ID
    ///   - opacity: Target opacity value (0.0-1.0)
    ///   - duration: Animation duration in seconds
    /// - Returns: true if successful
    func fadeWindowOpacity(windowID: UInt32, opacity: Float, duration: Float) -> Bool {
        return queue.sync {
            guard let ctx = ctx else { return false }

            let clampedOpacity = max(0.0, min(1.0, opacity))
            return mss_window_fade_opacity(ctx, windowID, clampedOpacity, duration)
        }
    }

    /// Get current window opacity
    /// - Parameter windowID: The window ID
    /// - Returns: Opacity value (0.0-1.0) or nil if query failed
    func getWindowOpacity(_ windowID: UInt32) -> Float? {
        var result: Float? = nil
        queue.sync {
            guard let ctx = ctx else { return }

            var opacity: Float = 0
            let success = mss_window_get_opacity(ctx, windowID, &opacity)

            if success {
                result = opacity
            }
        }
        return result
    }

    /// Set window layer (controls stacking order)
    /// - Parameters:
    ///   - windowID: The window ID
    ///   - layer: The desired layer (below, normal, above)
    /// - Returns: true if successful
    func setWindowLayer(windowID: UInt32, layer: WindowLayer) -> Bool {
        return queue.sync {
            guard let ctx = ctx else { return false }

            return mss_window_set_layer(ctx, windowID, layer.mssValue)
        }
    }

    /// Get current window layer
    /// - Parameter windowID: The window ID
    /// - Returns: Window layer or nil if query failed
    func getWindowLayer(_ windowID: UInt32) -> WindowLayer? {
        var result: WindowLayer? = nil
        queue.sync {
            guard let ctx = ctx else { return }

            var layer: mss_window_layer = MSS_LAYER_NORMAL
            let success = mss_window_get_layer(ctx, windowID, &layer)

            if success {
                result = WindowLayer(mssValue: layer)
            }
        }
        return result
    }

    /// Set window sticky state (visible on all spaces)
    /// - Parameters:
    ///   - windowID: The window ID
    ///   - sticky: true to make window visible on all spaces
    /// - Returns: true if successful
    func setWindowSticky(windowID: UInt32, sticky: Bool) -> Bool {
        return queue.sync {
            guard let ctx = ctx else { return false }

            return mss_window_set_sticky(ctx, windowID, sticky)
        }
    }

    /// Check if window is sticky (visible on all spaces)
    /// - Parameter windowID: The window ID
    /// - Returns: true if sticky, false if not, nil if query failed
    func isWindowSticky(_ windowID: UInt32) -> Bool? {
        var result: Bool? = nil
        queue.sync {
            guard let ctx = ctx else { return }

            var sticky: Bool = false
            let success = mss_window_is_sticky(ctx, windowID, &sticky)

            if success {
                result = sticky
            }
        }
        return result
    }

    /// Focus a window (bring to front and give focus)
    /// - Parameter windowID: The window ID
    /// - Returns: true if successful
    func focusWindow(_ windowID: UInt32) -> Bool {
        return queue.sync {
            guard let ctx = ctx else { return false }

            Task { JSONLogger.shared.log("mss.focus", data: ["wid": windowID]) }
            return mss_window_focus(ctx, windowID)
        }
    }

    /// Order a window to the front of the z-stack
    /// - Parameter windowID: The window ID
    /// - Returns: true if successful
    func orderWindowToFront(_ windowID: UInt32) -> Bool {
        return queue.sync {
            guard let ctx = ctx else { return false }

            var wid = windowID
            return mss_window_order_in(ctx, &wid, 1)
        }
    }

    /// Order multiple windows to the front of the z-stack
    /// - Parameter windowIDs: Array of window IDs
    /// - Returns: true if successful
    func orderWindowsToFront(_ windowIDs: [UInt32]) -> Bool {
        return queue.sync {
            guard let ctx = ctx, !windowIDs.isEmpty else { return false }

            var wids = windowIDs
            return mss_window_order_in(ctx, &wids, Int32(windowIDs.count))
        }
    }

    /// Set window shadow visibility
    /// - Parameters:
    ///   - windowID: The window ID
    ///   - shadow: true to enable shadow, false to disable
    /// - Returns: true if successful
    func setWindowShadow(windowID: UInt32, shadow: Bool) -> Bool {
        return queue.sync {
            guard let ctx = ctx else { return false }

            jlog("mss.shadow", data: ["wid": windowID, "shadow": shadow])

            return mss_window_set_shadow(ctx, windowID, shadow)
        }
    }

    /// Minimize window
    /// - Parameter windowID: The window ID
    /// - Returns: true if successful
    func minimizeWindow(_ windowID: UInt32) -> Bool {
        return queue.sync {
            guard let ctx = ctx else { return false }

            jlog("mss.minimize", data: ["wid": windowID])
            return mss_window_minimize(ctx, windowID)
        }
    }

    /// Unminimize (restore) window
    /// - Parameter windowID: The window ID
    /// - Returns: true if successful
    func unminimizeWindow(_ windowID: UInt32) -> Bool {
        return queue.sync {
            guard let ctx = ctx else { return false }

            jlog("mss.unminimize", data: ["wid": windowID])
            return mss_window_unminimize(ctx, windowID)
        }
    }

    /// Check if window is minimized
    /// - Parameter windowID: The window ID
    /// - Returns: true if minimized, false if not, nil if query failed
    func isWindowMinimized(_ windowID: UInt32) -> Bool? {
        var result: Bool? = nil
        queue.sync {
            guard let ctx = ctx else { return }

            var minimized: Bool = false
            let success = mss_window_is_minimized(ctx, windowID, &minimized)

            if success {
                result = minimized
            }
        }
        return result
    }

    // MARK: - Space Operations

    /// Create a new space on the same display as the given space
    /// - Parameter displaySpaceID: ID of a space on the target display
    /// - Returns: true if successful
    func createSpace(on displaySpaceID: UInt64) -> Bool {
        return queue.sync {
            guard let ctx = ctx else { return false }

            jlog("spc.create", data: ["sid": displaySpaceID])

            return mss_space_create(ctx, displaySpaceID)
        }
    }

    /// Destroy (delete) a space
    /// - Parameter spaceID: The space ID to destroy
    /// - Returns: true if successful
    func destroySpace(_ spaceID: UInt64) -> Bool {
        return queue.sync {
            guard let ctx = ctx else { return false }

            jlog("spc.destroy", data: ["sid": spaceID])

            return mss_space_destroy(ctx, spaceID)
        }
    }

    /// Focus (switch to) a space
    /// - Parameter spaceID: The space ID to focus
    /// - Returns: true if successful
    func focusSpace(_ spaceID: UInt64) -> Bool {
        return queue.sync {
            guard let ctx = ctx else { return false }

            jlog("spc.focus", data: ["sid": spaceID])

            return mss_space_focus(ctx, spaceID)
        }
    }

    /// Move a space to another display
    /// - Parameters:
    ///   - sourceSpaceID: The space to move
    ///   - destSpaceID: A space on the destination display
    ///   - previousSpaceID: Previous space on source display to focus after move
    ///   - focus: Whether to focus the moved space on destination display
    /// - Returns: true if successful
    func moveSpace(_ sourceSpaceID: UInt64, toDisplay destSpaceID: UInt64, previousSpace: UInt64 = 0, focus: Bool = false) -> Bool {
        return queue.sync {
            guard let ctx = ctx else { return false }

            jlog("spc.move", data: ["src_sid": sourceSpaceID, "dst_sid": destSpaceID])

            return mss_space_move(ctx, sourceSpaceID, destSpaceID, previousSpace, focus)
        }
    }

    // MARK: - Display Operations

    /// Get the number of displays
    /// - Returns: Number of displays or nil if query failed
    func getDisplayCount() -> UInt32? {
        var result: UInt32? = nil
        queue.sync {
            guard let ctx = ctx else { return }

            var count: UInt32 = 0
            let success = mss_display_get_count(ctx, &count)

            if success == 0 {  // MSS_SUCCESS = 0
                result = count
            }
        }
        return result
    }

    // MARK: - Batch Operations

    /// Move multiple windows to a space at once
    /// - Parameters:
    ///   - windowIDs: Array of window IDs to move
    ///   - spaceID: Destination space ID
    /// - Returns: true if all successful
    func moveWindowsToSpace(windowIDs: [UInt32], spaceID: UInt64) -> Bool {
        return queue.sync {
            guard let ctx = ctx, !windowIDs.isEmpty else { return false }

            var wids = windowIDs
            let result = mss_window_list_move_to_space(ctx, &wids, Int32(windowIDs.count), spaceID)

            if !result {
                jlog("err.mss.batch_move", data: ["count": windowIDs.count, "sid": spaceID])
            }

            return result
        }
    }
}
