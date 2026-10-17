import Foundation
import XCTest
@testable import RemSoundCore

final class SessionShutdownTests: XCTestCase {
    func testShutdownCompletionWaitsForActiveAndAlreadyFinishingRecordings() throws {
        let testRoot = ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory
        let root = testRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = try UDP(port: 0, loopback: true)
        let session = Session(testPeerPort: peer.boundPort)
        defer { session.shutdown() }
        let started = expectation(description: "hardware-free session started")
        session.onChange = { view in
            guard view.running else { return }
            session.onChange = nil
            started.fulfill()
        }
        session.start(password: "isolated shutdown", peerAddress: "", send: false,
            receive: false, plugins: false, name: "Test")
        wait(for: [started], timeout: 3)
        let first = root.appendingPathComponent("first.opus")
        let second = root.appendingPathComponent("second.opus")
        session.startRecording(url: first, source: .both, format: .opus192)
        session.stopRecording()
        session.startRecording(url: second, source: .both, format: .opus192)
        let finished = expectation(description: "both shutdown callbacks wait for all writers")
        finished.expectedFulfillmentCount = 2
        var latest: SessionView?
        session.onChange = { latest = $0 }
        for _ in 0..<2 {
            session.shutdown {
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(latest?.running, false)
                XCTAssertEqual(latest?.recording, false)
                XCTAssertEqual(latest?.recordingFinishing, false)
                for file in [first, second] {
                    do { try self.assertFinalizedOpus(file) }
                    catch { XCTFail("Recording unavailable at shutdown completion: \(error)") }
                }
                finished.fulfill()
            }
        }
        wait(for: [finished], timeout: 5)
    }

    func testIdleShutdownCompletesWithoutBlockingMainQueue() throws {
        let peer = try UDP(port: 0, loopback: true)
        let session = Session(testPeerPort: peer.boundPort)
        let finished = expectation(description: "idle shutdown completion")
        session.shutdown {
            XCTAssertTrue(Thread.isMainThread)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 3)
    }

    private func assertFinalizedOpus(_ url: URL) throws {
        let bytes = [UInt8](try Data(contentsOf: url))
        var offset = 0, lastFlags: UInt8 = 0
        while offset < bytes.count {
            guard offset + 27 <= bytes.count,
                Array(bytes[offset..<offset + 4]) == Array("OggS".utf8) else {
                XCTFail("Invalid or unfinished Ogg page"); return
            }
            lastFlags = bytes[offset + 5]
            let segments = Int(bytes[offset + 26])
            guard offset + 27 + segments <= bytes.count else {
                XCTFail("Unfinished Ogg segment table"); return
            }
            let bodySize = bytes[(offset + 27)..<(offset + 27 + segments)].reduce(0) { $0 + Int($1) }
            offset += 27 + segments + bodySize
        }
        XCTAssertEqual(offset, bytes.count)
        XCTAssertGreaterThan(bytes.count, 0)
        XCTAssertNotEqual(lastFlags & 4, 0, "Shutdown must wait for the end-of-stream page")
    }
}
