import AudioSupport
import CryptoKit
import Darwin
import XCTest
@testable import RemSoundCore

final class SendWorkDiagnosticsTests: XCTestCase {
    func testIntervalsPreserveEachStepWorstCallAndResetWithoutHistory() {
        var diagnostics = SendWorkDiagnostics()
        diagnostics.note(.encode, began: 10, ended: 110)
        diagnostics.note(.encode, began: 10, ended: 60)
        diagnostics.note(.nonce, began: 100, ended: 175)
        diagnostics.note(.udp, began: 50, ended: 40) // Invalid clock ordering is not an observation.
        let report = diagnostics.take()
        XCTAssertEqual(report.map(\.phase), [.encode, .nonce])
        XCTAssertEqual(report.map(\.calls), [2, 1])
        XCTAssertEqual(report.map(\.maximumNs), [100, 75])
        XCTAssertTrue(diagnostics.take().isEmpty)
        diagnostics.note(.encode, began: 30, ended: 50)
        XCTAssertEqual(diagnostics.take().first?.maximumNs, 20)
    }

    func testLongChurnKeepsOnlyPhaseCountsAndMaximaAndDisabledPathDoesNotSample() {
        var diagnostics = SendWorkDiagnostics()
        for _ in 0..<100_000 { diagnostics.note(.frame, began: 1, ended: 11) }
        let report = diagnostics.take()
        XCTAssertEqual(report.count, 1)
        XCTAssertEqual(report.first?.calls, 100_000)
        XCTAssertEqual(report.first?.maximumNs, 10)
        diagnostics.enabled = false
        XCTAssertEqual(diagnostics.begin(), 0)
        diagnostics.note(.encode, began: 1, ended: 200)
        XCTAssertTrue(diagnostics.take().isEmpty)
        diagnostics.enabled = true
        diagnostics.note(.encode, began: 0, ended: 100)
        XCTAssertTrue(diagnostics.take().isEmpty, "Zero is the disabled/not-started marker")
    }

    func testWakeAgeIsSeparateFromSendWorkAndReportsMissingStepsAsUnmeasured() {
        var diagnostics = SendWorkDiagnostics()
        diagnostics.noteWake(firstNs: 25_000_000, latestNs: 1_000_000)
        diagnostics.noteWake(firstNs: 2_000_000, latestNs: 500_000)
        let report = diagnostics.take()
        XCTAssertEqual(report.map(\.phase), [.wakeFirst, .wakeLatest])
        XCTAssertEqual(report.map(\.maximumNs), [25_000_000, 1_000_000])
        XCTAssertEqual(report.map(\.calls), [2, 2])
        let line = SendWorkDiagnostics.describe(report)
        XCTAssertTrue(line.contains("encode unmeasured"))
        XCTAssertTrue(line.contains("wake first-signal-to-consume 2 calls, wall max 25.000000 ms"))
        XCTAssertTrue(line.contains("inclusive"))
        XCTAssertTrue(line.contains("not hardware or network latency"))
    }

    func testMeasuredSealingKeepsRandomNonceWireLayoutAuthenticationAndKeyOwnership() throws {
        let firstKey = try Credentials(password: "isolated timing first key")
        let secondKey = try Credentials(password: "isolated timing second key")
        let plain = Data([1,2,3,4,5,6,7])
        var diagnostics = SendWorkDiagnostics()
        let first = try firstKey.sealAudio(plain, diagnostics: &diagnostics)
        let second = try firstKey.sealAudio(plain, diagnostics: &diagnostics)
        XCTAssertEqual(first.count, plain.count + 28)
        XCTAssertNotEqual(first.prefix(12), second.prefix(12))
        XCTAssertEqual(try firstKey.open(first), plain)
        XCTAssertEqual(try firstKey.open(second), plain)
        XCTAssertThrowsError(try secondKey.open(first))
        var damaged = first; damaged[12] ^= 1
        XCTAssertThrowsError(try firstKey.open(damaged))
        let report = diagnostics.take()
        XCTAssertEqual(report.map(\.phase), [.nonce, .seal, .encryptedLayout])
        XCTAssertEqual(report.map(\.calls), [2,2,2])
        diagnostics.enabled = false
        XCTAssertEqual(try firstKey.open(firstKey.sealAudio(plain, diagnostics: &diagnostics)), plain)
        XCTAssertTrue(diagnostics.take().isEmpty)
        let changed = try secondKey.sealAudio(plain, diagnostics: &diagnostics)
        XCTAssertEqual(try secondKey.open(changed), plain)
        XCTAssertThrowsError(try firstKey.open(changed))
    }

    func testNativeAgeKeepsFirstPublicationAcrossCoalescedSignalsAndRearms() throws {
        let wake = try XCTUnwrap(rs_capture_wake_create())
        defer { XCTAssertEqual(rs_capture_wake_destroy(wake), 1) }
        XCTAssertEqual(rs_capture_wake_snapshot(wake).timing_available, 1)
        XCTAssertEqual(rs_capture_wake_snapshot(wake).consumed, 0)
        XCTAssertEqual(rs_capture_wake_configure(wake, 64), 1)
        XCTAssertEqual(rs_capture_wake_signal(wake, 32), 0)
        XCTAssertEqual(rs_capture_wake_signal(wake, 64), 1)
        Thread.sleep(forTimeInterval: 0.020)
        for _ in 0..<100 { XCTAssertEqual(rs_capture_wake_signal(wake, 64), 0) }
        XCTAssertEqual(rs_capture_wake_consume(wake), 1)
        let first = rs_capture_wake_snapshot(wake)
        XCTAssertEqual(first.consumed, 1)
        XCTAssertGreaterThan(first.first_delay_ns, first.latest_delay_ns + 15_000_000)
        XCTAssertEqual(rs_capture_wake_consume(wake), 0)
        XCTAssertEqual(rs_capture_wake_snapshot(wake).consumed, 1)
        XCTAssertEqual(rs_capture_wake_signal(wake, 64), 1)
        XCTAssertEqual(rs_capture_wake_consume(wake), 1)
        let next = rs_capture_wake_snapshot(wake)
        XCTAssertEqual(next.consumed, 2)
        XCTAssertEqual(next.first_delay_ns, next.latest_delay_ns)
        XCTAssertEqual(rs_capture_wake_close(wake), 1)
        XCTAssertEqual(rs_capture_wake_signal(wake, 64), 0)
        XCTAssertEqual(rs_capture_wake_snapshot(wake).consumed, 2)
    }

    func testObservationPrecedesReadyOnTheSerialOwner() throws {
        let owner = DispatchQueue(label: "observed capture wake fixture")
        let ready = expectation(description: "observed ready"), closed = expectation(description: "observed closed")
        var events: [String] = []
        let attachment = try owner.sync { try XCTUnwrap(CaptureWakeAttachment(owner: owner, ready: {
            dispatchPrecondition(condition: .onQueue(owner))
            XCTAssertEqual(events, ["observed"])
            events.append("ready"); ready.fulfill()
        }, observed: { figures in
            dispatchPrecondition(condition: .onQueue(owner))
            XCTAssertEqual(figures.timing_available, 1)
            XCTAssertEqual(figures.consumed, 1)
            XCTAssertGreaterThanOrEqual(figures.first_delay_ns, figures.latest_delay_ns)
            events.append("observed")
        }, finished: { XCTAssertTrue($0); closed.fulfill() })) }
        let raw = try owner.sync { try XCTUnwrap(attachment.producer) }
        owner.sync { attachment.configure(packetFrames: 64, sending: true, hasDestination: true, pushDriven: true, sourceCount: 1) }
        XCTAssertEqual(rs_capture_wake_signal(raw, 64), 1)
        wait(for: [ready], timeout: 2)
        owner.sync { attachment.retire(producersStopped: true) }
        wait(for: [closed], timeout: 2)
        XCTAssertEqual(owner.sync { events }, ["observed", "ready"])
        XCTAssertTrue(owner.sync { attachment.disposed })
    }

    func testRetiredQueuedWakeDoesNotObserveOrRunReady() throws {
        let owner = DispatchQueue(label: "retired observation fixture")
        let closed = expectation(description: "retired observation closed")
        var events = 0
        let attachment = try owner.sync { try XCTUnwrap(CaptureWakeAttachment(owner: owner,
            ready: { events += 1 }, observed: { _ in events += 1 },
            finished: { XCTAssertTrue($0); closed.fulfill() })) }
        let raw = try owner.sync { try XCTUnwrap(attachment.producer) }
        owner.sync {
            attachment.configure(packetFrames: 64, sending: true, hasDestination: true, pushDriven: true, sourceCount: 1)
            XCTAssertEqual(rs_capture_wake_signal(raw, 64), 1)
            attachment.retire(producersStopped: true)
        }
        wait(for: [closed], timeout: 2)
        XCTAssertEqual(owner.sync { events }, 0)
        XCTAssertTrue(owner.sync { attachment.disposed })
    }
}
