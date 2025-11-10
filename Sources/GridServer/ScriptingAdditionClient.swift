//
// ScriptingAdditionClient.swift
// GridServer
//
// Client for communicating with Grid Scripting Addition via Unix domain socket
//

import Foundation
import Logging

/// Client for communicating with the Grid Scripting Addition
class ScriptingAdditionClient {
    private let logger: Logger
    private let socketPath: String

    // Opcodes matching the SA implementation
    private enum Opcode: UInt8 {
        case handshake = 0x01
        case windowToSpace = 0x13
        case windowListToSpace = 0x12
    }

    init(logger: Logger) {
        self.logger = logger

        // Construct socket path: /tmp/grid-sa_<username>.socket
        let username = NSUserName()
        self.socketPath = "/tmp/grid-sa_\(username).socket"

        logger.debug("ScriptingAdditionClient initialized", metadata: [
            "socketPath": "\(socketPath)"
        ])
    }

    // MARK: - Availability Check

    /// Check if the scripting addition is available
    func isAvailable() -> Bool {
        // Check if socket file exists
        let fileExists = FileManager.default.fileExists(atPath: socketPath)

        if !fileExists {
            logger.debug("SA not available: socket file doesn't exist", metadata: [
                "socketPath": "\(socketPath)"
            ])
            return false
        }

        // Try to connect to verify it's actually listening
        let canConnect = tryHandshake()

        if canConnect {
            logger.debug("SA is available and responding")
        } else {
            logger.debug("SA socket exists but not responding")
        }

        return canConnect
    }

    /// Try a handshake with the SA to verify it's working
    private func tryHandshake() -> Bool {
        do {
            let fd = try connectToSocket()
            defer { close(fd) }

            // Send handshake opcode
            var opcode = Opcode.handshake.rawValue
            let sendResult = send(fd, &opcode, 1, 0)
            guard sendResult == 1 else {
                logger.debug("Handshake send failed")
                return false
            }

            // Read response
            var response: UInt8 = 0
            let recvResult = recv(fd, &response, 1, 0)

            let success = recvResult == 1 && response == 1
            logger.debug("Handshake result", metadata: [
                "success": "\(success)",
                "response": "\(response)"
            ])

            return success
        } catch {
            logger.debug("Handshake failed", metadata: [
                "error": "\(error)"
            ])
            return false
        }
    }

    // MARK: - Socket Communication

    /// Connect to the SA socket
    private func connectToSocket() throws -> Int32 {
        // Create Unix domain socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ScriptingAdditionError.socketCreationFailed
        }

        // Prepare socket address
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // Copy socket path to sun_path
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            socketPath.withCString { cstr in
                let len = min(strlen(cstr), ptr.count - 1)
                ptr.copyBytes(from: UnsafeRawBufferPointer(start: cstr, count: len))
            }
        }

        // Connect
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard connectResult == 0 else {
            close(fd)
            throw ScriptingAdditionError.connectionFailed
        }

        return fd
    }

    // MARK: - Window Movement

    /// Move a single window to a space using the scripting addition
    func moveWindowToSpace(windowID: UInt32, spaceID: UInt64) -> Bool {
        logger.info("🎯 Moving window via SA", metadata: [
            "windowID": "\(windowID)",
            "spaceID": "\(spaceID)"
        ])

        do {
            let fd = try connectToSocket()
            defer { close(fd) }

            // Build payload: opcode + space_id + window_id
            var payload = Data()
            payload.append(Opcode.windowToSpace.rawValue)

            // Append space ID (8 bytes, little-endian)
            var sid = spaceID.littleEndian
            payload.append(Data(bytes: &sid, count: 8))

            // Append window ID (4 bytes, little-endian)
            var wid = windowID.littleEndian
            payload.append(Data(bytes: &wid, count: 4))

            logger.debug("Sending SA request", metadata: [
                "opcode": "0x\(String(Opcode.windowToSpace.rawValue, radix: 16))",
                "payloadSize": "\(payload.count)"
            ])

            // Send payload
            let sendResult = payload.withUnsafeBytes { bufferPtr in
                send(fd, bufferPtr.baseAddress, payload.count, 0)
            }

            guard sendResult >= 0 else {
                logger.error("SA send failed", metadata: [
                    "error": "\(errno)"
                ])
                return false
            }

            // Wait for response
            var response: UInt8 = 0
            let recvResult = recv(fd, &response, 1, 0)

            let success = recvResult > 0 && response == 1

            logger.info(success ? "✓ SA move completed" : "❌ SA move failed", metadata: [
                "response": "\(response)",
                "windowID": "\(windowID)",
                "spaceID": "\(spaceID)"
            ])

            return success

        } catch {
            logger.error("SA communication error", metadata: [
                "error": "\(error)"
            ])
            return false
        }
    }

    /// Move multiple windows to a space using the scripting addition
    func moveWindowsToSpace(windowIDs: [UInt32], spaceID: UInt64) -> Bool {
        logger.info("🎯 Moving windows via SA", metadata: [
            "windowCount": "\(windowIDs.count)",
            "spaceID": "\(spaceID)"
        ])

        do {
            let fd = try connectToSocket()
            defer { close(fd) }

            // Build payload: opcode + space_id + count + window_ids[]
            var payload = Data()
            payload.append(Opcode.windowListToSpace.rawValue)

            // Append space ID (8 bytes)
            var sid = spaceID.littleEndian
            payload.append(Data(bytes: &sid, count: 8))

            // Append window count (4 bytes)
            var count = Int32(windowIDs.count).littleEndian
            payload.append(Data(bytes: &count, count: 4))

            // Append window IDs
            for var wid in windowIDs.map({ $0.littleEndian }) {
                payload.append(Data(bytes: &wid, count: 4))
            }

            logger.debug("Sending SA batch request", metadata: [
                "opcode": "0x\(String(Opcode.windowListToSpace.rawValue, radix: 16))",
                "payloadSize": "\(payload.count)"
            ])

            // Send payload
            let sendResult = payload.withUnsafeBytes { bufferPtr in
                send(fd, bufferPtr.baseAddress, payload.count, 0)
            }

            guard sendResult >= 0 else {
                logger.error("SA batch send failed")
                return false
            }

            // Wait for response
            var response: UInt8 = 0
            let recvResult = recv(fd, &response, 1, 0)

            let success = recvResult > 0 && response == 1

            logger.info(success ? "✓ SA batch move completed" : "❌ SA batch move failed", metadata: [
                "windowCount": "\(windowIDs.count)"
            ])

            return success

        } catch {
            logger.error("SA batch communication error", metadata: [
                "error": "\(error)"
            ])
            return false
        }
    }
}

// MARK: - Errors

enum ScriptingAdditionError: Error {
    case socketCreationFailed
    case connectionFailed
    case sendFailed
    case receiveFailed
    case invalidResponse
}
