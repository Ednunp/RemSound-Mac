import Foundation
import XCTest
import RemSoundCore

final class AudioProductPackTests: XCTestCase {
    private let pcm="24-bit PCM pack/unpack (sign, clamp, 1-LSB accuracy)"
    private let ring="Audio ring buffer integrity (wrap, drop-oldest, underrun fill)"
    func testNamedPCMExecutesActualCodecChecksAndPassesFocusedScopeOnly() throws {
        let report=ProductTestPack.run(pack:.feature,only:pcm)
        let step=try XCTUnwrap(report.steps.first)
        XCTAssertEqual(step.status,"PASS");XCTAssertEqual(step.assertions,23)
        XCTAssertTrue(step.failures.isEmpty);XCTAssertEqual(report.exitCode,0)
    }
    func testActualCaptureAndPlayoutRolesCompleteNamedRingCheck() throws {
        let report=ProductTestPack.run(pack:.full,only:ring)
        let step=try XCTUnwrap(report.steps.first)
        XCTAssertEqual(step.status,"PASS");XCTAssertGreaterThan(step.assertions,40)
        XCTAssertTrue(step.failures.isEmpty)
        XCTAssertEqual(report.exitCode,0)
    }
    func testFullInventoryRetainsAllOtherUnimplementedSteps() {
        let report=ProductTestPack.run(pack:.full,budget:8)
        XCTAssertEqual(report.catalogSteps,545)
        XCTAssertFalse(report.steps.isEmpty)
        XCTAssertEqual(report.steps.map(\.name),Array(ProductTestPack.names.prefix(report.steps.count)))
        XCTAssertFalse(report.steps.contains { $0.status == "FAIL" })
        if report.termination == "completed" {
            XCTAssertEqual(report.steps.count,545)
            XCTAssertEqual(report.steps.filter { $0.status == "PASS" }.count,7)
            XCTAssertEqual(report.steps.filter { $0.status == "UNVERIFIED" }.count,538)
        } else { XCTAssertEqual(report.termination,"deadline") }
        XCTAssertEqual(report.exitCode,1)
    }
}
