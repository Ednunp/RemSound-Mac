import Foundation
import XCTest
@testable import RemSoundCore

final class PluginInstallProductTests: XCTestCase {
    func testNamedPluginInstallSliceExercisesActualTransactionAndKeepsMissingRemovalUnverified() {
        let name="Plugin install/remove is per-user and exact (other plugins untouched)"
        let result=ProductTestPack.run(pack:.feature,only:name,budget:8)
        XCTAssertEqual(result.steps.count,1)
        XCTAssertEqual(result.steps.first?.assertions,30)
        XCTAssertEqual(result.steps.first?.status,"UNVERIFIED")
        XCTAssertEqual(result.exitCode,1)
    }
}
