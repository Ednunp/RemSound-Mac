import AudioSupport
import Darwin
import XCTest
@testable import RemSoundCore

final class CaptureWakeAttachmentTests: XCTestCase {
    private static var failedLifetimeKeepers = [CaptureWakeAttachment]()
    func testEligibilityKeepsInactiveAndPacedSourcesOnTheTimer() throws {
        let owner = DispatchQueue(label: "wake eligibility fixture")
        let closed = expectation(description: "closed")
        let attachment = try owner.sync { try XCTUnwrap(CaptureWakeAttachment(owner: owner, ready: {}, finished: {
            XCTAssertTrue($0); closed.fulfill()
        })) }
        let raw = try owner.sync { try XCTUnwrap(attachment.producer) }
        owner.sync {
            for (sending, destination, push, count) in [(false, true, true, 1), (true, false, true, 1),
                                                       (true, true, false, 1), (true, true, true, 2)] {
                attachment.configure(packetFrames: 64, sending: sending, hasDestination: destination,
                    pushDriven: push, sourceCount: count)
                XCTAssertEqual(rs_capture_wake_signal(raw, 64), 0)
            }
            XCTAssertEqual(attachment.snapshot().attempts, 0)
            attachment.retire(producersStopped: true)
        }
        wait(for: [closed], timeout: 2)
        XCTAssertTrue(owner.sync { attachment.disposed })
    }

    func testCompletedPacketRunsOnTheOwnerAndPacketSizeChanges() throws {
        let owner = DispatchQueue(label: "wake threshold fixture")
        let ready = expectation(description: "complete packet"), closed = expectation(description: "closed")
        let attachment = try owner.sync { try XCTUnwrap(CaptureWakeAttachment(owner: owner, ready: {
            dispatchPrecondition(condition: .onQueue(owner)); ready.fulfill()
        }, finished: { XCTAssertTrue($0); closed.fulfill() })) }
        let raw = try owner.sync { try XCTUnwrap(attachment.producer) }
        owner.sync {
            attachment.configure(packetFrames: 120, sending: true, hasDestination: true, pushDriven: true, sourceCount: 1)
            XCTAssertEqual(rs_capture_wake_signal(raw, 64), 0)
            attachment.configure(packetFrames: 64, sending: true, hasDestination: true, pushDriven: true, sourceCount: 1)
        }
        XCTAssertEqual(rs_capture_wake_signal(raw, 32), 0)
        XCTAssertEqual(rs_capture_wake_signal(raw, 64), 1)
        wait(for: [ready], timeout: 2)
        owner.sync { attachment.retire(producersStopped: true) }
        wait(for: [closed], timeout: 2)
        XCTAssertEqual(owner.sync { attachment.snapshot().published }, 1)
    }

    func testQueuedEventIsRejectedWhenRetiredOnTheSameOwner() throws {
        let owner = DispatchQueue(label: "wake stale event fixture")
        let closed = expectation(description: "closed")
        var readyCount = 0
        let attachment = try owner.sync { try XCTUnwrap(CaptureWakeAttachment(owner: owner,
            ready: { readyCount += 1 }, finished: { XCTAssertTrue($0); closed.fulfill() })) }
        let raw = try owner.sync { try XCTUnwrap(attachment.producer) }
        let descriptor = rs_capture_wake_read_fd(raw)
        owner.sync {
            attachment.configure(packetFrames: 64, sending: true, hasDestination: true, pushDriven: true, sourceCount: 1)
            XCTAssertEqual(rs_capture_wake_signal(raw, 64), 1)
            attachment.retire(producersStopped: true)
        }
        wait(for: [closed], timeout: 2)
        XCTAssertEqual(owner.sync { readyCount }, 0)
        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    func testFailedProviderStopRetainsContextAndRejectsLateSignals() throws {
        let owner = DispatchQueue(label: "wake stop failure fixture")
        let closed = expectation(description: "closed")
        let attachment = try owner.sync { try XCTUnwrap(CaptureWakeAttachment(owner: owner, ready: {},
            finished: { XCTAssertTrue($0); closed.fulfill() })) }
        let raw = try owner.sync { try XCTUnwrap(attachment.producer) }
        let descriptor = rs_capture_wake_read_fd(raw)
        owner.sync {
            attachment.configure(packetFrames: 64, sending: true, hasDestination: true, pushDriven: true, sourceCount: 1)
            attachment.retire(producersStopped: false)
        }
        owner.sync {} // Consumer cancellation may run; provider ownership still has not ended.
        let disposed = owner.sync { attachment.disposed }
        XCTAssertFalse(disposed)
        guard !disposed else { return } // A planted fault must not use a freed raw context.
        XCTAssertGreaterThanOrEqual(fcntl(descriptor, F_GETFD), 0)
        for _ in 0..<10000 { XCTAssertEqual(rs_capture_wake_signal(raw, 64), 0) }
        owner.sync {
            attachment.configure(packetFrames: 64, sending: true, hasDestination: true, pushDriven: true, sourceCount: 1)
            XCTAssertEqual(rs_capture_wake_signal(raw, 64), 0)
            attachment.retire(producersStopped: true)
        }
        wait(for: [closed], timeout: 2)
        XCTAssertTrue(owner.sync { attachment.disposed })
    }

    func testNoNotificationStillAllowsTheIndependentTimerFallback() throws {
        // Eligibility disables signals, but does not own or cancel Session's timer.
        let owner = DispatchQueue(label: "wake fallback fixture")
        let ticked = expectation(description: "fallback timer"), closed = expectation(description: "closed")
        let timer = DispatchSource.makeTimerSource(queue: owner)
        timer.schedule(deadline: .now() + .milliseconds(20))
        timer.setEventHandler { ticked.fulfill() }
        timer.resume()
        let attachment = try owner.sync { try XCTUnwrap(CaptureWakeAttachment(owner: owner, ready: {},
            finished: { XCTAssertTrue($0); closed.fulfill() })) }
        owner.sync { attachment.retire(producersStopped: true) }
        wait(for: [closed, ticked], timeout: 2)
        timer.cancel()
    }

    func testRetirementAndRecreationChurnClosesEveryOwnedDescriptor() throws {
        let owner = DispatchQueue(label: "wake churn fixture")
        for _ in 0..<250 {
            let ended = DispatchSemaphore(value: 0)
            let attachment = try owner.sync { try XCTUnwrap(CaptureWakeAttachment(owner: owner, ready: {},
                finished: { XCTAssertTrue($0); ended.signal() })) }
            let descriptor = try owner.sync { rs_capture_wake_read_fd(try XCTUnwrap(attachment.producer)) }
            owner.sync { attachment.retire(producersStopped: true) }
            XCTAssertEqual(ended.wait(timeout: .now() + 2), .success)
            XCTAssertTrue(owner.sync { attachment.disposed })
            XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
            XCTAssertEqual(errno, EBADF)
        }
    }

    func testIndependentProducerCanFinishAfterRetirementBeforeMemoryIsFreed() throws {
        let owner = DispatchQueue(label: "wake producer lifetime fixture")
        let closed = expectation(description: "closed")
        let attachment = try owner.sync { try XCTUnwrap(CaptureWakeAttachment(owner: owner, ready: {},
            finished: { XCTAssertTrue($0); closed.fulfill() })) }
        let raw = try owner.sync { try XCTUnwrap(attachment.producer) }
        let descriptor = rs_capture_wake_read_fd(raw)
        owner.sync { attachment.configure(packetFrames: 64, sending: true, hasDestination: true,
            pushDriven: true, sourceCount: 1) }
        let entered = DispatchSemaphore(value: 0), ended = DispatchSemaphore(value: 0)
        let thread = Thread {
            entered.signal()
            for _ in 0..<100000 { _ = rs_capture_wake_signal(raw, 64) }
            ended.signal()
        }
        thread.start()
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        owner.sync { attachment.retire(producersStopped: false) }
        XCTAssertGreaterThanOrEqual(fcntl(descriptor, F_GETFD), 0)
        let joined = ended.wait(timeout: .now() + 3) == .success
        XCTAssertTrue(joined)
        guard joined else {
            // Preserve ownership on a failed timeout, never free a producer's context.
            Self.failedLifetimeKeepers.append(attachment)
            return
        }
        owner.sync { attachment.retire(producersStopped: true) }
        wait(for: [closed], timeout: 2)
        XCTAssertEqual(owner.sync { attachment.snapshot().errors }, 0)
        XCTAssertTrue(owner.sync { attachment.disposed })
    }

    func testRepeatedRetirementCompletesExactlyOnce() throws {
        let owner = DispatchQueue(label: "wake repeated retirement fixture")
        let closed = expectation(description: "closed")
        var completionCount = 0
        let attachment = try owner.sync { try XCTUnwrap(CaptureWakeAttachment(owner: owner, ready: {}, finished: {
            XCTAssertTrue($0); completionCount += 1; closed.fulfill()
        })) }
        owner.sync { for _ in 0..<1000 { attachment.retire(producersStopped: true) } }
        wait(for: [closed], timeout: 2)
        owner.sync { for _ in 0..<1000 { attachment.retire(producersStopped: true) } }
        XCTAssertEqual(owner.sync { completionCount }, 1)
    }
}
