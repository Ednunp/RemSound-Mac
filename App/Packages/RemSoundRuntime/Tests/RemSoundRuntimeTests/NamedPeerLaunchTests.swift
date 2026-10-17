import XCTest
@testable import RemSoundRuntime

final class NamedPeerLaunchTests: XCTestCase {
    func testBothNamedHistoryAliasesArePureReports() throws {
        for flag in ["--named-peers","--list-named-peers","--NAMED-PEERS"] {
            XCTAssertNoThrow(try LaunchOptions.parse([flag,"--config-dir","/owned/history"]))
        }
    }
    func testHistoryReportRefusesLiveAndOtherReportScopes() {
        for flag in ["--named-peers","--list-named-peers"] {
            for other in [["--profile","Studio"],["--version"],["--headless"],["--control","stop"],["--log","on"],["--seconds","1"],["--pack","full"]] {
                XCTAssertThrowsError(try LaunchOptions.parse([flag,"--config-dir","/owned/history"]+other))
            }
        }
    }
}
