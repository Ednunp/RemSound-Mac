import Foundation
import XCTest
@testable import RemSoundJam

final class ServerVersionTests: XCTestCase {
    func testOfflineFloorAndNewerTestBuilds() {
        XCTAssertEqual(ServerVersionCheck.builtWith, "server-v2.17")
        XCTAssertEqual(ServerVersionCheck.newest("server-v2.10"), "server-v2.17")
        XCTAssertEqual(ServerVersionCheck.newest("server-v2.18"), "server-v2.18")
        XCTAssertTrue(ServerVersionCheck.isOutOfDate("server-v2.16", latestReleased: nil))
        XCTAssertFalse(ServerVersionCheck.isOutOfDate("server-v2.18-test", latestReleased: "server-v2.17"))
        XCTAssertTrue(ServerVersionCheck.isOutOfDate("server-v2.13.3-metronome-test", latestReleased: "server-v2.17"))
    }
    func testUnknownVersionsAlwaysNeedJudgment() {
        for value: String? in [nil, "", "hello", "v2.17", " server-v2.17", "server-v", "server-v1.2.3.4", "server-v2147483648"] {
            XCTAssertTrue(ServerVersionCheck.isOutOfDate(value, latestReleased: nil), "\(value ?? "nil")")
        }
        XCTAssertFalse(ServerVersionCheck.isOutOfDate("SERVER-V2.17", latestReleased: nil))
        XCTAssertFalse(ServerVersionCheck.isOutOfDate("server-v2.17.0-rc", latestReleased: nil))
    }
    func testPlainTagsAndNumericComparison() {
        for tag in ["server-v2", "server-v2.17", "server-v2.17.1", "SERVER-V2.17"] { XCTAssertTrue(ServerVersionCheck.isPlainReleaseTag(tag)) }
        for tag in ["server-v", "server-v2.18-test", "v2.18", "server-v1.2.3.4", "server-v2147483648"] { XCTAssertFalse(ServerVersionCheck.isPlainReleaseTag(tag)) }
        XCTAssertTrue(ServerVersionCheck.isOutOfDate("server-v2.9", latestReleased: "server-v2.10"))
        XCTAssertTrue(ServerVersionCheck.isOutOfDate("server-v2.17", latestReleased: "server-v2.17.1"))
    }
    func testReleaseFamiliesDraftPrereleaseAndTestTagsFiltered() {
        let list = Data("[{\"tag_name\":\"v99\",\"draft\":false,\"prerelease\":false},{\"tag_name\":\"server-v2.17\",\"draft\":false,\"prerelease\":false},{\"tag_name\":\"server-v2.18.1\",\"draft\":false,\"prerelease\":false},{\"tag_name\":\"server-v2.40\",\"draft\":true,\"prerelease\":false},{\"tag_name\":\"server-v2.30\",\"draft\":false,\"prerelease\":true},{\"tag_name\":\"server-v2.20-test\",\"draft\":false,\"prerelease\":false}]".utf8)
        XCTAssertEqual(ServerVersionCheck.newestRelease(in: list), "server-v2.18.1")
        XCTAssertNil(ServerVersionCheck.newestRelease(in: Data("{}".utf8)))
        XCTAssertNil(ServerVersionCheck.newestRelease(in: Data("[{\"tag_name\":\"server-v2.99\"}]".utf8)), "missing release flags fail closed")
    }
    func testVisitURLUsesOnlyAPlainTag() {
        XCTAssertEqual(ServerVersionCheck.latestCodeURL("server-v2.18").absoluteString, "https://github.com/Ednunp/RemSound/releases/tag/server-v2.18")
        for tag: String? in [nil, "server-v2.18-test", "server-v2.18/../../evil"] {
            XCTAssertEqual(ServerVersionCheck.latestCodeURL(tag).absoluteString, "https://github.com/Ednunp/RemSound/releases")
        }
    }
    func testOneInflightFetchAndOneHourCacheBoundary() {
        var now = 0.0, asks = 0
        var reply: ((String?) -> Void)?
        let cache = ServerReleaseCache(clock: { now }, fetch: { asks += 1; reply = $0 })
        var results: [String?] = []
        cache.latest { results.append($0) }; cache.latest { results.append($0) }
        XCTAssertEqual(asks, 1); XCTAssertTrue(results.isEmpty)
        reply?("server-v2.18"); XCTAssertEqual(results.count, 2)
        now = 3599.999; cache.latest { results.append($0) }; XCTAssertEqual(asks, 1)
        now = 3600; cache.latest { results.append($0) }; XCTAssertEqual(asks, 2)
    }
    func testFailedFetchNotCachedAndDuplicateReceiptIgnored() {
        var asks = 0
        var receipts: [(String?) -> Void] = []
        let cache = ServerReleaseCache(clock: { 0 }, fetch: { asks += 1; receipts.append($0) })
        var values: [String?] = []
        cache.latest { values.append($0) }; receipts.first?(nil)
        cache.latest { values.append($0) }; XCTAssertEqual(asks, 2)
        receipts.first?("server-v2.99"); XCTAssertEqual(values.count, 1)
        receipts.last?("server-v2.18"); XCTAssertEqual(values.compactMap { $0 }, ["server-v2.18"])
        cache.latest { values.append($0) }; XCTAssertEqual(asks, 2)
        XCTAssertEqual(values.last!, "server-v2.18")
    }
    func testSynchronousFetchAndInvalidTagRemainTruthful() {
        var asks = 0
        let cache = ServerReleaseCache(clock: { 0 }, fetch: { completion in asks += 1; completion("server-v2.18-test") })
        var results: [String?] = []
        cache.latest { results.append($0) }; cache.latest { results.append($0) }
        XCTAssertEqual(asks, 2); XCTAssertEqual(results.count, 2); XCTAssertTrue(results.allSatisfy { $0 == nil })
    }
}
