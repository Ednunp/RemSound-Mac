import AudioSupport
import Foundation
import XCTest

final class CaptureLeaseTests: XCTestCase {
    func testRetirementClosesEntryBeforeAnEnteredCallbackLeaves() throws {
        let lease = try XCTUnwrap(rs_capture_lease_create())
        XCTAssertEqual(rs_capture_lease_enter(lease), 1)
        XCTAssertEqual(rs_capture_lease_retire(lease), 0)
        XCTAssertEqual(rs_capture_lease_enter(lease), 0)
        XCTAssertEqual(rs_capture_lease_destroy(lease), 0)
        rs_capture_lease_leave(lease)
        XCTAssertEqual(rs_capture_lease_idle(lease), 1)
        XCTAssertEqual(rs_capture_lease_retire(lease), 1)
        XCTAssertEqual(rs_capture_lease_enter(lease), 0)
        XCTAssertEqual(rs_capture_lease_destroy(lease), 1)
    }
    func testAnOpenIdleLeaseIsNotRetired() throws {
        let lease = try XCTUnwrap(rs_capture_lease_create())
        XCTAssertEqual(rs_capture_lease_idle(lease), 0)
        XCTAssertEqual(rs_capture_lease_destroy(lease), 1)
    }
    func testOverlappingCallbackIsRejectedForTheSingleProducerRing() throws {
        let lease = try XCTUnwrap(rs_capture_lease_create())
        XCTAssertEqual(rs_capture_lease_enter(lease), 1)
        XCTAssertEqual(rs_capture_lease_enter(lease), 0)
        rs_capture_lease_leave(lease)
        XCTAssertEqual(rs_capture_lease_enter(lease), 1)
        rs_capture_lease_leave(lease)
        XCTAssertEqual(rs_capture_lease_destroy(lease), 1)
    }
    func testConcurrentRetirementRetainsMemoryUntilProducerJoins() throws {
        for _ in 0..<100 {
            let lease = try XCTUnwrap(rs_capture_lease_create())
            let done = expectation(description: "producer joined")
            Thread.detachNewThread {
                for _ in 0..<10_000 {
                    if rs_capture_lease_enter(lease) == 1 { rs_capture_lease_leave(lease) }
                }
                done.fulfill()
            }
            _ = rs_capture_lease_retire(lease)
            let completed = XCTWaiter.wait(for: [done], timeout: 5)
            XCTAssertEqual(completed, .completed)
            guard completed == .completed else { return } // retain on unexpected timeout
            XCTAssertEqual(rs_capture_lease_idle(lease), 1)
            XCTAssertEqual(rs_capture_lease_enter(lease), 0)
            XCTAssertEqual(rs_capture_lease_destroy(lease), 1)
        }
    }
}
