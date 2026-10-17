import XCTest
@testable import RemSoundCore

final class NamedPeerProductPackTests: XCTestCase {
    func testNamedSettingsCheckExecutesActualStoreRoundtripButKeepsMissingSettingsUnverified() throws {
        let report=ProductTestPack.run(pack:.feature,only:"v5 settings and shaping round-trip",budget:8)
        let step=try XCTUnwrap(report.steps.first)
        XCTAssertEqual(step.assertions,21)
        XCTAssertEqual(step.status,"UNVERIFIED");XCTAssertEqual(report.exitCode,1)
    }
}
