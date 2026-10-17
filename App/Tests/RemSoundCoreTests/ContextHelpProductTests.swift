import XCTest
@_spi(NativeProductChecks) @testable import RemSoundCore

final class ContextHelpProductTests: XCTestCase {
    func testNoNativeScopeMeansNoFactoryOrAssertions() {
        let report = ProductTestPack.run(pack: .feature, only: ProductTestPack.contextHelpAll)
        XCTAssertEqual(report.steps.first?.status, "UNVERIFIED")
        XCTAssertEqual(report.steps.first?.assertions, 0)
        XCTAssertEqual(report.exitCode, 1)
    }
    func testActualMainReceiptCannotPromoteMissingDialogsMenusOrPlugin() {
        let report = ProductTestPack.run(pack: .feature, only: ProductTestPack.contextHelpAll,
            nativeProfileLogging: { XCTFail("Unselected logging"); return nil },
            nativeContextHelp: { (42, []) })
        XCTAssertEqual(report.steps.first?.assertions, 42)
        XCTAssertEqual(report.steps.first?.status, "UNVERIFIED")
        XCTAssertEqual(report.steps.first?.failures, ["help.native.unverified-dialog-menu-plugin-coverage"])
        XCTAssertEqual(report.exitCode, 1)
    }
    func testActualFailureRemainsFailureAndInvalidReceiptRefuses() {
        let failed = ProductTestPack.checkContextHelp(native: { (3, ["help.native.unkeyed-main-control"]) })
        XCTAssertEqual(failed.status, "FAIL")
        for receipt in [(0, [String]()), (8193, []), (1, ["private/path"]), (1, ["help.native.secret\nvalue"])] {
            XCTAssertEqual(ProductTestPack.checkContextHelp(native: { receipt }).failures, ["help.native.invalid-receipt"])
        }
    }
    func testUnselectedNativeHelpCallbackNeverRuns() {
        let report = ProductTestPack.run(pack: .feature, only: ProductTestPack.pcm24,
            nativeProfileLogging: { nil }, nativeContextHelp: { XCTFail("Unselected help"); return nil })
        XCTAssertEqual(report.steps.first?.name, ProductTestPack.pcm24)
        XCTAssertEqual(report.exitCode, 0)
    }
}
