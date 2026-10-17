import XCTest
@testable import RemSoundCore

final class AudioConfigurationCoverageProductTests: XCTestCase {
    func testActualNativeSoftwareOutputBranchesPreserveKnownStereoAndRetire() {
        let result = ProductTestPack.checkNativeOutputFanout()
        XCTAssertGreaterThan(result.assertions, 60); XCTAssertTrue(result.failures.isEmpty, result.failures.joined(separator: ","))
    }
    func testMissingSourcePermissionStaysUnverifiedBeforeFanout() {
        let result = ProductTestPack.checkAudioConfigurations(native: nil)
        XCTAssertEqual(result.assertions, 0); XCTAssertEqual(result.status, "UNVERIFIED")
    }
    func testSourceRefusalReturnsBeforeAnyNativeOutputAssertions() {
        let result = ProductTestPack.checkAudioConfigurations(native: { (1, ["audio-axis.native.isolated-source-refused"]) })
        XCTAssertEqual(result.assertions, 1); XCTAssertEqual(result.status, "FAIL")
    }
    func testMalformedAndPendingReceiptsAreNotPass() {
        XCTAssertEqual(ProductTestPack.checkAudioConfigurations(native: { (2, ["/private/path"]) }).status, "FAIL")
        XCTAssertEqual(ProductTestPack.checkAudioConfigurations(native: { (2, ["audio-axis.native.unverified-example"]) }).status, "UNVERIFIED")
    }
}
