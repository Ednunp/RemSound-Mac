import XCTest
@testable import RemSoundCore

final class UpdateCatalogTests: XCTestCase {
    private func releases(_ items: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: items)
    }

    private func release(_ version: String, draft: Bool = false, prerelease: Bool = false,
        assetName: String? = nil, downloadURL: String? = nil) -> [String: Any] {
        let tag = "v\(version)"
        let name = assetName ?? "RemSound-Mac-\(tag).zip"
        return [
            "tag_name": tag, "html_url": "https://github.com/OnjLouis/RemSound-Mac/releases/tag/\(tag)",
            "draft": draft, "prerelease": prerelease,
            "assets": [["name": name, "browser_download_url": downloadURL
                ?? "https://github.com/OnjLouis/RemSound-Mac/releases/download/\(tag)/\(name)"]],
        ]
    }

    func testSelectsNewestExactReleaseForThisMacPort() throws {
        let data = try releases([
            release("0.1.39"), release("0.2.0"), release("0.8.0", draft: true),
            release("0.9.0", prerelease: true), release("0.3.0", assetName: "RemSound-Windows.zip"),
        ])
        let selected = try UpdateCatalog.newest(in: data, newerThan: "0.1.38")
        XCTAssertEqual(selected?.version, "0.2.0")
        XCTAssertEqual(selected?.assetName, "RemSound-Mac-v0.2.0.zip")
        XCTAssertNil(try UpdateCatalog.newest(in: data, newerThan: "0.2.0"))
    }

    func testRejectsForeignAssetURLAndMalformedVersions() throws {
        let foreign = try releases([release("0.2.0",
            downloadURL: "https://example.com/RemSound-Mac-v0.2.0.zip")])
        XCTAssertNil(try UpdateCatalog.newest(in: foreign, newerThan: "0.1.38"))
        let malformed = try releases([release("0.2.0-beta")])
        XCTAssertNil(try UpdateCatalog.newest(in: malformed, newerThan: "0.1.38"))
    }
}
