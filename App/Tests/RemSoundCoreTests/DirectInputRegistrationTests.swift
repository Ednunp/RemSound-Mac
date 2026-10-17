import AudioSupport
import AudioToolbox
import CoreAudio
import Foundation
import XCTest
@testable import RemSoundCore

private final class FakeDirectInputIO {
    var registerStatus: OSStatus = noErr, startStatus: OSStatus = noErr
    var stopStatus: OSStatus = noErr, destroyStatus: OSStatus = noErr
    var omitProc = false
    var block: AudioDeviceIOBlock?
    var registerCalls = 0, startCalls = 0, stopCalls = 0, destroyCalls = 0
    var io: DirectInputIO {
        DirectInputIO(register: { [self] _, block, result in
            registerCalls += 1
            guard registerStatus == noErr else { return registerStatus }
            self.block = block
            if !omitProc { result.pointee = { _, _, _, _, _, _, _ in noErr } }
            return noErr
        }, start: { [self] _, _ in startCalls += 1; return startStatus },
        stop: { [self] _, _ in stopCalls += 1; return stopStatus },
        destroy: { [self] _, _ in destroyCalls += 1; return destroyStatus })
    }
    func invoke(_ values: [Float], channels: UInt32 = 1) {
        guard let block else { return }
        values.withUnsafeBufferPointer { data in
            var list = AudioBufferList(mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: channels,
                    mDataByteSize: UInt32(data.count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(mutating: data.baseAddress)))
            var timestamp = AudioTimeStamp()
            timestamp.mHostTime = rs_callback_begin()
            timestamp.mFlags = .hostTimeValid
            withUnsafePointer(to: &list) { input in
                withUnsafePointer(to: &timestamp) { time in
                    var output = AudioBufferList()
                    withUnsafeMutablePointer(to: &output) { block(time, input, time, $0, time) }
                }
            }
        }
    }
}

final class DirectInputRegistrationTests: XCTestCase {
    private func make(_ fake: FakeDirectInputIO, channels: UInt32 = 1,
        pairs: [Int] = [0], wake: OpaquePointer? = nil) throws -> (DirectInputRegistration, StereoRing) {
        let ring = StereoRing()
        let context = try DirectInputCallback(samples: ring, channels: channels, pairs: pairs, wake: wake)
        return (DirectInputRegistration(device: 123, context: context, io: fake.io), ring)
    }
    func testRegistrationFailureRetiresWithoutStartingOrDestroyingUnknownID() throws {
        let fake = FakeDirectInputIO(); fake.registerStatus = -1
        let (registration, ring) = try make(fake)
        XCTAssertThrowsError(try registration.start())
        XCTAssertTrue(registration.pollRetirement())
        XCTAssertEqual(fake.startCalls, 0); XCTAssertEqual(fake.stopCalls, 0)
        XCTAssertEqual(fake.destroyCalls, 0); XCTAssertEqual(ring.available, 0)
    }
    func testMissingRegistrationIDRetiresTheRetainedBlock() throws {
        let fake = FakeDirectInputIO(); fake.omitProc = true
        let (registration, ring) = try make(fake)
        XCTAssertThrowsError(try registration.start())
        XCTAssertTrue(registration.pollRetirement())
        fake.invoke([1, 2]); XCTAssertEqual(ring.available, 0)
        XCTAssertEqual(fake.startCalls, 0)
    }
    func testStartFailureChecksUnregisterAndRejectsLateCallback() throws {
        let fake = FakeDirectInputIO(); fake.startStatus = -2
        let (registration, ring) = try make(fake)
        XCTAssertThrowsError(try registration.start())
        XCTAssertEqual(fake.stopCalls, 1); XCTAssertEqual(fake.destroyCalls, 1)
        XCTAssertTrue(registration.pollRetirement())
        fake.invoke([1]); XCTAssertEqual(ring.available, 0)
    }
    func testStopFailureStillAllowsSuccessfulUnregisterBarrier() throws {
        let fake = FakeDirectInputIO(); fake.stopStatus = -3
        let (registration, ring) = try make(fake)
        try registration.start()
        fake.invoke([0.25, -0.5])
        XCTAssertEqual(ring.read(2), [0.25, 0.25, -0.5, -0.5])
        XCTAssertTrue(registration.retire(now: 0))
        XCTAssertEqual(registration.stopStatus, -3); XCTAssertEqual(registration.destroyStatus, noErr)
        fake.invoke([1]); XCTAssertEqual(ring.available, 0)
        XCTAssertTrue(registration.retire(now: 1)); XCTAssertEqual(fake.stopCalls, 1)
    }
    func testDestroyFailureRetainsCallbackAndRetriesOffCallbackAtBoundedRate() throws {
        let fake = FakeDirectInputIO(); fake.destroyStatus = -4
        let (registration, ring) = try make(fake)
        try registration.start()
        XCTAssertFalse(registration.retire(now: 0))
        for _ in 0..<1000 { XCTAssertFalse(registration.pollRetirement(now: 0.001)) }
        XCTAssertEqual(fake.destroyCalls, 1)
        fake.invoke([1, 2]); XCTAssertEqual(ring.available, 0)
        fake.destroyStatus = noErr
        XCTAssertTrue(registration.pollRetirement(now: 0.011))
        XCTAssertEqual(fake.destroyCalls, 2); XCTAssertEqual(fake.stopCalls, 1)
    }
    func testEnteredCallbackMustLeaveBeforeProducerCanBeConfirmed() throws {
        let fake = FakeDirectInputIO()
        let (registration, _) = try make(fake)
        try registration.start()
        XCTAssertEqual(rs_capture_lease_enter(registration.context.lease), 1)
        XCTAssertFalse(registration.retire(now: 0))
        XCTAssertEqual(fake.destroyCalls, 1)
        rs_capture_lease_leave(registration.context.lease)
        XCTAssertTrue(registration.pollRetirement(now: 1))
        XCTAssertEqual(fake.destroyCalls, 1)
    }
    func testLateNativeBlockOwnsContextAndSkipsFreedWakeAndReplacementRing() throws {
        let fake = FakeDirectInputIO()
        let wake = try XCTUnwrap(rs_capture_wake_create())
        XCTAssertEqual(rs_capture_wake_configure(wake, 2), 1)
        var registration: DirectInputRegistration?
        var ring: StereoRing?
        (registration, ring) = try make(fake, wake: wake)
        weak var retainedRing = ring
        try XCTUnwrap(registration).start()
        fake.invoke([0.2, 0.4])
        XCTAssertEqual(rs_capture_wake_snapshot(wake).published, 1)
        XCTAssertTrue(try XCTUnwrap(registration).retire(now: 0))
        XCTAssertEqual(rs_capture_wake_destroy(wake), 1)
        registration = nil; ring = nil
        XCTAssertNotNil(retainedRing)
        let nextFake = FakeDirectInputIO()
        let (next, nextRing) = try make(nextFake)
        try next.start()
        for _ in 0..<10000 { fake.invoke([1]) }
        XCTAssertEqual(retainedRing?.writtenFrames, 2); XCTAssertEqual(nextRing.available, 0)
        nextFake.invoke([0.75]); XCTAssertEqual(nextRing.read(1), [0.75, 0.75])
        XCTAssertTrue(next.retire(now: 1))
        fake.block = nil
        XCTAssertNil(retainedRing)
    }
    func testPermanentUnregisterFailureDoesNotBecomeAFalseConfirmation() throws {
        let fake = FakeDirectInputIO(); fake.destroyStatus = -4
        let (registration, ring) = try make(fake)
        try registration.start()
        XCTAssertFalse(registration.retire(now: 0))
        for n in 1...500 { XCTAssertFalse(registration.pollRetirement(now: Double(n))) }
        XCTAssertEqual(fake.destroyCalls, 100); XCTAssertTrue(registration.retirementExhausted)
        XCTAssertThrowsError(try registration.start())
        XCTAssertEqual(fake.registerCalls, 1)
        fake.invoke([1]); XCTAssertEqual(ring.available, 0)
        // Fake has no native registration to leak; clearing its block is test cleanup.
        fake.block = nil
    }
    func testMultichannelSelectedPairsAreImmutableAndSummed() throws {
        let fake = FakeDirectInputIO()
        let (registration, ring) = try make(fake, channels: 6, pairs: [0, 2])
        try registration.start()
        fake.invoke([0.1, 0.2, 9, 9, 0.3, 0.4], channels: 6)
        let audio = ring.read(1)
        XCTAssertEqual(audio[0], 0.4, accuracy: 0.0001)
        XCTAssertEqual(audio[1], 0.6, accuracy: 0.0001)
        fake.invoke([9], channels: 1); XCTAssertEqual(ring.available, 0)
        XCTAssertTrue(registration.retire(now: 0))
    }
    func testInvalidChannelChoicesNeverRegister() throws {
        let fake = FakeDirectInputIO()
        XCTAssertThrowsError(try make(fake, channels: 0))
        XCTAssertThrowsError(try make(fake, channels: 1, pairs: []))
        XCTAssertThrowsError(try make(fake, channels: 4, pairs: [2]))
        XCTAssertThrowsError(try make(fake, channels: 2, pairs: [-1]))
        XCTAssertEqual(fake.registerCalls, 0)
    }
}
