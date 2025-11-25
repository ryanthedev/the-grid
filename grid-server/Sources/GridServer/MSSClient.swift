//
//  MSSClient.swift
//  GridServer
//
//  Swift wrapper for the MSS (macOS Scripting Addition) library
//  Provides access to window and space manipulation via SkyLight APIs
//

import Foundation
import Logging
import mss

/// Client for communicating with the MSS scripting addition payload
class MSSClient {
    private var ctx: OpaquePointer?
    private let queue = DispatchQueue(label: "com.grid.mss")
    private let logger: Logger

    /// Initialize MSS client with optional custom socket path
    /// - Parameters:
    ///   - logger: Logger instance for debugging
    ///   - socketPath: Optional custom socket path (defaults to MSS default)
    init(logger: Logger, socketPath: String? = nil) {
        self.logger = logger

        queue.sync {
            // Create MSS context
            if let path = socketPath {
                self.ctx = mss_create(path)
            } else {
                self.ctx = mss_create(nil) // Use default path: /tmp/mss_<username>.socket
            }

            guard ctx != nil else {
                logger.error("❌ Failed to create MSS context")
                return
            }

            logger.info("✓ MSS client initialized")
        }
    }

    deinit {
        if let ctx = ctx {
            mss_destroy(ctx)
            logger.info("MSS client destroyed")
        }
    }

    // MARK: - Availability & Status

    /// Check if MSS payload is loaded and available
    /// - Returns: true if MSS is ready to use
    func isAvailable() -> Bool {
        return queue.sync {
            guard let ctx = ctx else {
                logger.debug("MSS context not initialized")
                return false
            }

            var capabilities: UInt32 = 0
            var version: UnsafePointer<CChar>?

            let result = mss_handshake(ctx, &capabilities, &version)

            if result == 0 {  // MSS_SUCCESS = 0
                let versionString = version != nil ? String(cString: version!) : "unknown"
                logger.info("✓ MSS available", metadata: [
                    "version": "\(versionString)",
                    "capabilities": "0x\(String(capabilities, radix: 16))"
                ])
                return true
            } else {
                logger.debug("MSS handshake failed", metadata: [
                    "error_code": "\(result)"
                ])
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
                logger.error("❌ MSS context not available")
                return false
            }

            logger.info("Moving window to space via MSS", metadata: [
                "windowID": "\(windowID)",
                "spaceID": "\(spaceID)"
            ])

            let result = mss_window_move_to_space(ctx, windowID, spaceID)

            if result {
                logger.info("✓ Window moved successfully")
            } else {
                logger.error("✗ Window move failed")
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
            logger.debug("Setting window opacity", metadata: [
                "windowID": "\(windowID)",
                "opacity": "\(clampedOpacity)"
            ])

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
            logger.debug("Fading window opacity", metadata: [
                "windowID": "\(windowID)",
                "opacity": "\(clampedOpacity)",
                "duration": "\(duration)s"
            ])

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
    func setWindowLayer(windowID: UInt32, layer: mss_window_layer) -> Bool {
        return queue.sync {
            guard let ctx = ctx else { return false }

            let layerName = layer == MSS_LAYER_ABOVE ? "above" :
                           layer == MSS_LAYER_BELOW ? "below" : "normal"
            logger.debug("Setting window layer", metadata: [
                "windowID": "\(windowID)",
                "layer": "\(layerName)"
            ])

            return mss_window_set_layer(ctx, windowID, layer)
        }
    }

    /// Get current window layer
    /// - Parameter windowID: The window ID
    /// - Returns: Window layer or nil if query failed
    func getWindowLayer(_ windowID: UInt32) -> mss_window_layer? {
        var result: mss_window_layer? = nil
        queue.sync {
            guard let ctx = ctx else { return }

            var layer: mss_window_layer = MSS_LAYER_NORMAL
            let success = mss_window_get_layer(ctx, windowID, &layer)

            if success {
                result = layer
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

            logger.debug("Setting window sticky state", metadata: [
                "windowID": "\(windowID)",
                "sticky": "\(sticky)"
            ])

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

            logger.debug("Focusing window via MSS", metadata: ["windowID": "\(windowID)"])
            return mss_window_focus(ctx, windowID)
        }
    }

    /// Order a window to the front of the z-stack
    /// - Parameter windowID: The window ID
    /// - Returns: true if successful
    func orderWindowToFront(_ windowID: UInt32) -> Bool {
        return queue.sync {
            guard let ctx = ctx else { return false }

            logger.debug("Ordering window to front via MSS", metadata: ["windowID": "\(windowID)"])
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

            logger.debug("Ordering \(windowIDs.count) windows to front via MSS")
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

            logger.debug("Setting window shadow", metadata: [
                "windowID": "\(windowID)",
                "shadow": "\(shadow)"
            ])

            return mss_window_set_shadow(ctx, windowID, shadow)
        }
    }

    /// Minimize window
    /// - Parameter windowID: The window ID
    /// - Returns: true if successful
    func minimizeWindow(_ windowID: UInt32) -> Bool {
        return queue.sync {
            guard let ctx = ctx else { return false }

            logger.debug("Minimizing window", metadata: ["windowID": "\(windowID)"])
            return mss_window_minimize(ctx, windowID)
        }
    }

    /// Unminimize (restore) window
    /// - Parameter windowID: The window ID
    /// - Returns: true if successful
    func unminimizeWindow(_ windowID: UInt32) -> Bool {
        return queue.sync {
            guard let ctx = ctx else { return false }

            logger.debug("Unminimizing window", metadata: ["windowID": "\(windowID)"])
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

            logger.info("Creating space", metadata: [
                "displaySpaceID": "\(displaySpaceID)"
            ])

            return mss_space_create(ctx, displaySpaceID)
        }
    }

    /// Destroy (delete) a space
    /// - Parameter spaceID: The space ID to destroy
    /// - Returns: true if successful
    func destroySpace(_ spaceID: UInt64) -> Bool {
        return queue.sync {
            guard let ctx = ctx else { return false }

            logger.info("Destroying space", metadata: [
                "spaceID": "\(spaceID)"
            ])

            return mss_space_destroy(ctx, spaceID)
        }
    }

    /// Focus (switch to) a space
    /// - Parameter spaceID: The space ID to focus
    /// - Returns: true if successful
    func focusSpace(_ spaceID: UInt64) -> Bool {
        return queue.sync {
            guard let ctx = ctx else { return false }

            logger.info("Focusing space", metadata: [
                "spaceID": "\(spaceID)"
            ])

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

            logger.info("Moving space to different display", metadata: [
                "sourceSpaceID": "\(sourceSpaceID)",
                "destSpaceID": "\(destSpaceID)"
            ])

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

            logger.info("Moving \(windowIDs.count) windows to space", metadata: [
                "count": "\(windowIDs.count)",
                "spaceID": "\(spaceID)"
            ])

            // Convert to C array
            var wids = windowIDs
            let result = mss_window_list_move_to_space(ctx, &wids, Int32(windowIDs.count), spaceID)

            if result {
                logger.info("✓ Batch window move successful")
            } else {
                logger.error("✗ Batch window move failed")
            }

            return result
        }
    }
}

// MARK: - Helper Extensions

extension mss_window_layer: CustomStringConvertible {
    public var description: String {
        switch self {
        case MSS_LAYER_BELOW:
            return "below"
        case MSS_LAYER_NORMAL:
            return "normal"
        case MSS_LAYER_ABOVE:
            return "above"
        default:
            return "unknown"
        }
    }
}
