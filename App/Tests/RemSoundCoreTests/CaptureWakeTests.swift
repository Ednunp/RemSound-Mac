import AudioSupport
import Darwin
import XCTest

final class CaptureWakeTests: XCTestCase {
    private func withWake(_ body: (OpaquePointer) throws -> Void) throws {
        let wake = try XCTUnwrap(rs_capture_wake_create())
        defer { XCTAssertEqual(rs_capture_wake_destroy(wake), 1) }
        try body(wake)
    }

    func testDisabledAndIncompleteFramesDoNotWakeTheConsumer() throws {
        try withWake { wake in
            XCTAssertEqual(rs_capture_wake_signal(wake, 64), 0)
            XCTAssertEqual(rs_capture_wake_configure(wake, 64), 1)
            XCTAssertEqual(rs_capture_wake_signal(wake, 32), 0)
            XCTAssertEqual(rs_capture_wake_consume(wake), 0)
            XCTAssertEqual(rs_capture_wake_snapshot(wake).attempts, 0)
            XCTAssertEqual(rs_capture_wake_signal(wake, 64), 1)
            XCTAssertEqual(rs_capture_wake_consume(wake), 1)
            XCTAssertEqual(rs_capture_wake_consume(wake), 0)
        }
    }

    func testRepeatedSignalsCoalesceIntoOnePendingByteAndRearm() throws {
        try withWake { wake in
            XCTAssertEqual(rs_capture_wake_configure(wake, 64), 1)
            for _ in 0..<10000 { _ = rs_capture_wake_signal(wake, 64) }
            let snapshot = rs_capture_wake_snapshot(wake)
            XCTAssertEqual(snapshot.attempts, 10000)
            XCTAssertEqual(snapshot.published, 1)
            XCTAssertEqual(snapshot.coalesced, 9999)
            XCTAssertEqual(snapshot.errors, 0)
            XCTAssertEqual(rs_capture_wake_consume(wake), 1)
            XCTAssertEqual(rs_capture_wake_consume(wake), 0)
            XCTAssertEqual(rs_capture_wake_signal(wake, 64), 1)
            XCTAssertEqual(rs_capture_wake_consume(wake), 1)
            XCTAssertEqual(rs_capture_wake_snapshot(wake).published, 2)
        }
    }

    func testChangingPacketThresholdAndDisablingDoNotLeaveSendingEnabled() throws {
        try withWake { wake in
            XCTAssertEqual(rs_capture_wake_configure(wake, 120), 1)
            XCTAssertEqual(rs_capture_wake_signal(wake, 64), 0)
            XCTAssertEqual(rs_capture_wake_signal(wake, 120), 1)
            XCTAssertEqual(rs_capture_wake_configure(wake, 0), 1)
            XCTAssertEqual(rs_capture_wake_consume(wake), 1, "An already queued wake may finish")
            for _ in 0..<10000 { XCTAssertEqual(rs_capture_wake_signal(wake, 120), 0) }
            XCTAssertEqual(rs_capture_wake_consume(wake), 0)
            XCTAssertEqual(rs_capture_wake_snapshot(wake).published, 1)
            XCTAssertEqual(rs_capture_wake_configure(wake, 64), 1)
            XCTAssertEqual(rs_capture_wake_signal(wake, 64), 1)
            XCTAssertEqual(rs_capture_wake_consume(wake), 1)
        }
    }

    func testRetiredContextRejectsLateSignalsAndCannotBeReenabled() throws {
        try withWake { wake in
            let descriptor = rs_capture_wake_read_fd(wake)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            XCTAssertEqual(rs_capture_wake_configure(wake, 64), 1)
            XCTAssertEqual(rs_capture_wake_signal(wake, 64), 1)
            XCTAssertEqual(rs_capture_wake_close(wake), 1)
            XCTAssertEqual(rs_capture_wake_close(wake), 1)
            let status = fcntl(descriptor, F_GETFD), error = errno
            XCTAssertEqual(status, -1)
            XCTAssertEqual(error, EBADF)
            XCTAssertEqual(rs_capture_wake_read_fd(wake), -1)
            XCTAssertEqual(rs_capture_wake_configure(wake, 64), 0)
            for _ in 0..<10000 { XCTAssertEqual(rs_capture_wake_signal(wake, 64), 0) }
            XCTAssertEqual(rs_capture_wake_consume(wake), 0)
            XCTAssertEqual(rs_capture_wake_snapshot(wake).published, 1)
            XCTAssertEqual(rs_capture_wake_snapshot(wake).errors, 0)
        }
    }

    func testCreateSignalCloseDestroyChurnClosesEveryOwnedDescriptor() throws {
        for _ in 0..<500 {
            try withWake { wake in
                let descriptor = rs_capture_wake_read_fd(wake)
                XCTAssertEqual(rs_capture_wake_configure(wake, 64), 1)
                XCTAssertEqual(rs_capture_wake_signal(wake, 64), 1)
                XCTAssertEqual(rs_capture_wake_close(wake), 1)
                let status = fcntl(descriptor, F_GETFD), error = errno
                XCTAssertEqual(status, -1)
                XCTAssertEqual(error, EBADF)
            }
        }
    }

    func testClosingDuringProducerActivityPreventsDescriptorReuseWrites() throws {
        let wake = try XCTUnwrap(rs_capture_wake_create())
        var producerFinished = false
        defer {
            // A failed timeout must not free memory still owned by the producer.
            if producerFinished { XCTAssertEqual(rs_capture_wake_destroy(wake), 1) }
        }
        XCTAssertEqual(rs_capture_wake_configure(wake, 64), 1)
        let entered = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let producer = Thread {
            entered.signal()
            for _ in 0..<100000 { _ = rs_capture_wake_signal(wake, 64) }
            finished.signal()
        }
        producer.start()
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        let end = ProcessInfo.processInfo.systemUptime + 1
        while rs_capture_wake_snapshot(wake).published == 0, ProcessInfo.processInfo.systemUptime < end {
            Thread.sleep(forTimeInterval: 0.0001)
        }
        while rs_capture_wake_close(wake) == 0, ProcessInfo.processInfo.systemUptime < end {
            Thread.sleep(forTimeInterval: 0.0001)
        }
        XCTAssertEqual(rs_capture_wake_read_fd(wake), -1)
        producerFinished = finished.wait(timeout: .now() + 3) == .success
        XCTAssertTrue(producerFinished,
            "Producer ownership ends before destroying context memory")
        guard producerFinished else { return }
        XCTAssertGreaterThan(rs_capture_wake_snapshot(wake).published, 0)
        XCTAssertEqual(rs_capture_wake_snapshot(wake).errors, 0)
    }
}
