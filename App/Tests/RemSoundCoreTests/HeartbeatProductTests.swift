import Foundation
import XCTest
@testable import RemSoundCore

final class HeartbeatProductTests: XCTestCase {
    func testExactNamedHeartbeatRunsActualEchoHealthAndVisibleCaller() throws {
        let report=ProductTestPack.run(pack:.feature,only:"Heartbeat wire round-trip + ping→pong echo",budget:8)
        let step=try XCTUnwrap(report.steps.first)
        XCTAssertEqual(step.status,"PASS",step.failures.joined(separator:", "))
        XCTAssertGreaterThanOrEqual(step.assertions,25)
        XCTAssertEqual(report.exitCode,0)
    }
    func testHealthUsesMonotonicWindowsAndStableSummariesWithoutChangingDiagnosticRange() {
        var timing=HeartbeatTiming()
        timing.sent(tickMs:10_000,selected:["peer"])
        XCTAssertEqual(timing.health(for:"peer",nowTickMs:11_000).status,"ping pending")
        XCTAssertEqual(timing.health(for:"peer",nowTickMs:20_000).status,"ping unreachable 10.0 s")
        XCTAssertTrue(timing.receivedPong(from:"peer",echoTickMs:10_000,nowTickMs:10_024))
        XCTAssertEqual(timing.health(for:"peer",nowTickMs:12_024).state,.healthy)
        XCTAssertEqual(timing.health(for:"peer",nowTickMs:12_025).state,.stale)
        XCTAssertEqual(timing.health(for:"peer",nowTickMs:15_024).state,.stale)
        XCTAssertEqual(timing.health(for:"peer",nowTickMs:15_025).state,.unreachable)
        XCTAssertEqual(timing.health(for:"peer",nowTickMs:13_024).status,timing.health(for:"peer",nowTickMs:13_900).status)
        XCTAssertNil(timing.health(for:"peer",nowTickMs:13_024).currentRTT)
        XCTAssertEqual(timing.range(selected:["peer"],nowTickMs:13_024),24...24)
        timing.forget("peer")
        XCTAssertEqual(timing.health(for:"peer",nowTickMs:20_000).state,.pending)
        XCTAssertNil(timing.range(selected:["peer"],nowTickMs:20_000))
    }
    func testStaleHeartbeatNeverSuppliesCurrentReceiveLatencyTotal() {
        var timing=HeartbeatTiming();timing.sent(tickMs:1000,selected:["peer"])
        XCTAssertTrue(timing.receivedPong(from:"peer",echoTickMs:1000,nowTickMs:1024))
        let health=timing.health(for:"peer",nowTickMs:4024)
        let format=StreamFormat.opus(Data(repeating:1,count:8),frames:120).capturing(milliseconds:3)
        let summary=PeerLatencyReport.Summary(inputs:[.init(stream:"current",format:format,queuedFrames:0)],outputs:[5],rttMs:health.currentRTT,heartbeat:health)
        XCTAssertTrue(summary.status.contains("ping stale 3.0 s"))
        XCTAssertTrue(summary.status.contains("round trip not measured"))
        XCTAssertNil(summary.maximumCompleteMs)
        XCTAssertFalse(summary.status.contains("total latency about"))
    }
}
