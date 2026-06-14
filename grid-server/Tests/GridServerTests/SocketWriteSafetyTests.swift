import XCTest
import Foundation
@testable import GridServer

/// DW-7.1 / DW-7.2: socket write safety against a hung-up peer, exercised on a
/// real socketpair so the SO_NOSIGPIPE + EPIPE path is genuinely tested.
final class SocketWriteSafetyTests: XCTestCase {

    // DW-7.1 (#1): writing to a closed peer with SO_NOSIGPIPE returns EPIPE
    // (FullWrite -> .disconnected) instead of raising SIGPIPE and killing us.
    func test_DW_7_1_write_to_closed_peer_returns_disconnected_not_signal() throws {
        var fds = [Int32](repeating: 0, count: 2)
        let rc = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        XCTAssertEqual(rc, 0, "socketpair must succeed")
        let writer = fds[0]
        let reader = fds[1]

        // Apply the same option the accept path applies.
        SocketServer.setNoSigPipe(writer)

        // Close the reader so the writer's peer is gone.
        close(reader)

        // Write enough to overflow the send buffer and force send() to actually
        // hit the dead peer. With SO_NOSIGPIPE this returns -1/EPIPE; without it
        // the process would have been killed by SIGPIPE.
        let payload = [UInt8](repeating: 0x41, count: 1 << 20)
        let result = FullWrite.writeAll(payload) { ptr, len in
            let n = send(writer, ptr, len, 0)
            return (n, errno)
        }
        close(writer)

        XCTAssertEqual(result, .disconnected,
                       "a dead peer must surface as .disconnected (EPIPE), not crash the process")
    }

    // DW-7.2 (#46): a full small frame to a live peer is delivered intact.
    func test_DW_7_2_full_frame_delivered_to_live_peer() throws {
        var fds = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let writer = fds[0]
        let reader = fds[1]
        defer { close(writer); close(reader) }
        SocketServer.setNoSigPipe(writer)

        let frame = Array("{\"id\":\"1\"}\n".utf8)
        let result = FullWrite.writeAll(frame) { ptr, len in
            (send(writer, ptr, len, 0), errno)
        }
        XCTAssertEqual(result, .ok)

        var buf = [UInt8](repeating: 0, count: 64)
        let n = recv(reader, &buf, buf.count, 0)
        XCTAssertEqual(Int(n), frame.count)
        XCTAssertEqual(Array(buf[0..<Int(n)]), frame, "frame must arrive byte-for-byte")
    }
}
