import AudioSupport
import AudioToolbox
import CoreAudio
import Foundation
import XCTest
@testable import RemSoundCore

final class CaptureRetirementsTests: XCTestCase {
    private func registration(destroy: @escaping () -> OSStatus) throws -> DirectInputRegistration {
        let context = try DirectInputCallback(samples: StereoRing(), channels: 1, pairs: [0], wake: nil)
        let io = DirectInputIO(register: { _, _, out in
            out.pointee = { _, _, _, _, _, _, _ in noErr }; return noErr
        }, start: { _, _ in noErr }, stop: { _, _ in noErr }, destroy: { _, _ in destroy() })
        let result = DirectInputRegistration(device: 123, context: context, io: io)
        try result.start()
        return result
    }
    func testCollectionRetainsFailedRegistrationExactlyOnceUntilItUnregisters() throws {
        var status: OSStatus = -4
        let pending = CaptureRetirements()
        var capture: DirectInputRegistration? = try registration { status }
        weak var retained = capture
        XCTAssertFalse(pending.retire(try XCTUnwrap(capture), now: 0))
        XCTAssertFalse(pending.retire(try XCTUnwrap(capture), now: 0))
        capture = nil
        XCTAssertNotNil(retained); XCTAssertEqual(pending.count, 1)
        XCTAssertFalse(pending.poll(now: 0.005))
        status = noErr
        XCTAssertTrue(pending.poll(now: 0.011))
        XCTAssertEqual(pending.count, 0); XCTAssertNil(retained)
    }
    func testCollectionRetainsSuccessfulUnregisterWithAnEnteredCallback() throws {
        let pending = CaptureRetirements()
        let capture = try registration { noErr }
        XCTAssertEqual(rs_capture_lease_enter(capture.context.lease), 1)
        XCTAssertFalse(pending.retire(capture, now: 0))
        XCTAssertFalse(pending.poll(now: 1)); XCTAssertEqual(pending.count, 1)
        rs_capture_lease_leave(capture.context.lease)
        XCTAssertTrue(pending.poll(now: 2))
    }
    func testExhaustedFailureIsRetainedAndNeverPretendsToComplete() throws {
        let pending = CaptureRetirements()
        let capture = try registration { -4 }
        XCTAssertFalse(pending.retire(capture, now: 0))
        for n in 1...200 { XCTAssertFalse(pending.poll(now: Double(n))) }
        XCTAssertTrue(pending.exhausted); XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(capture.destroyAttempts, 100)
    }
}
