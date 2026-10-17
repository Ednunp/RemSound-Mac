import XCTest
@testable import RemSoundRuntime

final class ProductPackLaunchTests: XCTestCase {
    func testExplicitPacksAndExactNamedSelectionAreParsedInEitherOrder() throws {
        XCTAssertNoThrow(try LaunchOptions.parse(["--selftest","--pack","full"]))
        XCTAssertNoThrow(try LaunchOptions.parse(["--pack","feature","--only","named step","--selftest"]))
    }
    func testUnknownRepeatedUnattachedAndMixedScopesRefuse() {
        for args in [["--pack","full"],["--selftest","--pack"],["--selftest","--pack","other"],["--selftest","--pack","full","--pack","feature"],["--selftest","--only","wire"],["--selftest","--pack","full","--only",""],["--selftest","--pack","full","--only","a","--only","b"],["--version","--pack","full"],["--perftest","--pack","full"]] {
            XCTAssertThrowsError(try LaunchOptions.parse(args))
        }
    }
}
