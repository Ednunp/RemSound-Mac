import AudioSupport
import CoreAudio
import Darwin
import XCTest
@testable import RemSoundCore

final class CaptureResourceCleanupTests: XCTestCase {
    func testDetachedCleanupRetainsFailedRegistrationUntilConsumerAndNativeBarriersFinish() throws {
        let owner = DispatchQueue(label: "detached capture cleanup test")
        let disposed = expectation(description: "notification consumer disposed")
        let retirements = CaptureRetirements()
        var status: OSStatus = -4
        var nativeBlock: AudioDeviceIOBlock?
        var wake: CaptureWakeAttachment? = try owner.sync {
            try XCTUnwrap(CaptureWakeAttachment(owner: owner, ready: {}, finished: { _ in disposed.fulfill() }))
        }
        weak var retainedWake = wake
        let descriptor = try owner.sync { rs_capture_wake_read_fd(try XCTUnwrap(wake?.producer)) }
        var callback: DirectInputCallback? = try owner.sync {
            try DirectInputCallback(samples: StereoRing(), channels: 1, pairs: [0], wake: wake?.producer)
        }
        weak var retainedCallback = callback
        var registration: DirectInputRegistration? = DirectInputRegistration(device: 123,
            context: try XCTUnwrap(callback), io: DirectInputIO(register: { _, block, out in
                nativeBlock = block; out.pointee = { _, _, _, _, _, _, _ in noErr }; return noErr
            }, start: { _, _ in noErr }, stop: { _, _ in noErr }, destroy: { _, _ in status }))
        try owner.sync { try registration?.start(); _ = retirements.retire(try XCTUnwrap(registration)) }
        var cleanup: CaptureResourceCleanup? = CaptureResourceCleanup(owner: owner, audio: nil,
            retirements: retirements, wakes: [try XCTUnwrap(wake)], remainingPolls: CaptureCleanupPolicy.maximumPolls)
        weak var retainedCleanup = cleanup
        owner.sync { cleanup?.start(); cleanup = nil; registration = nil; callback = nil; wake = nil }
        XCTAssertNotNil(retainedCleanup)
        XCTAssertNotNil(retainedWake)
        XCTAssertNotNil(retainedCallback)
        owner.sync { status = noErr }
        wait(for: [disposed], timeout: 2)
        owner.sync {} // Let the poll that triggered disposal finish releasing its resource owner.
        XCTAssertNil(retainedCleanup)
        XCTAssertNil(retainedWake)
        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
        XCTAssertNotNil(retainedCallback, "The copied native block retains the closed callback context")
        nativeBlock = nil
        XCTAssertNil(retainedCallback)
    }

    func testDetachedCleanupWithoutCaptureReleasesImmediately() {
        let owner = DispatchQueue(label: "empty detached cleanup test")
        var cleanup: CaptureResourceCleanup? = CaptureResourceCleanup(owner: owner, audio: nil,
            retirements: CaptureRetirements(), wakes: [], remainingPolls: CaptureCleanupPolicy.maximumPolls)
        weak var retained = cleanup
        owner.sync { cleanup?.start(); cleanup = nil }
        XCTAssertNil(retained)
    }
}
