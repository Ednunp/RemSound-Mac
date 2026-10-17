import XCTest
@_spi(NativeProductChecks) @testable import RemSoundCore

final class ControlSpecificationsProductTests: XCTestCase {
    func testNoNativeObservationCannotBecomePass() {
        let report = ProductTestPack.run(pack: .feature, only: ProductTestPack.controlSpecifications)
        XCTAssertEqual(report.steps.count, 1); XCTAssertEqual(report.steps.first?.status, "UNVERIFIED")
        XCTAssertEqual(report.steps.first?.assertions, 0); XCTAssertEqual(report.exitCode, 1)
    }
    func testBoundedNativeFailuresAndMalformedReceiptsCannotBecomePass() {
        for value in [(3, ["controls.native.unowned-live-control"]), (0, []), (4097, []), (2, ["private/path"])] {
            let report = ProductTestPack.run(pack: .feature, only: ProductTestPack.controlSpecifications,
                nativeProfileLogging: { XCTFail("unrelated logging fixture"); return nil }, nativeControlSpecifications: { value })
            XCTAssertEqual(report.steps.first?.status, "FAIL"); XCTAssertEqual(report.exitCode, 1)
        }
    }
}
