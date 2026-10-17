import XCTest
@testable import RemSoundCore

final class UpdateArchiveTests: XCTestCase {
    private let version = "1.2.3"
    private var entries: [String] {
        ["RemSound.app", "Plugins/AU/RemSound.component", "Plugins/VST3/RemSound.vst3",
            "Plugins/CLAP/RemSound.clap"].map { "RemSound-Mac-v1.2.3/\($0)/Contents/Info.plist" }
    }
    private func details(sizes: [String] = ["10", "20", "30", "40"], mode: String = "-rw-r--r--") -> String {
        zip(entries, sizes).map { "\(mode) 3.0 unx \($1) bx 10 defN 26-Oct-06 12:00 \($0)" }
            .joined(separator: "\n")
    }
    func testAcceptsBoundedCompletePayloadAndParentDirectories() throws {
        let names = entries + ["RemSound-Mac-v1.2.3/", "RemSound-Mac-v1.2.3/Plugins/"]
        let attributes = details() + "\ndrwxr-xr-x 3.0 unx 0 bx 0 stor 26-Oct-06 12:00 RemSound-Mac-v1.2.3/"
            + "\ndrwxr-xr-x 3.0 unx 0 bx 0 stor 26-Oct-06 12:00 RemSound-Mac-v1.2.3/Plugins/"
        try UpdateArchive.validate(listing: names.joined(separator: "\n"), details: attributes, version: version)
    }
    func testOnlyAcceptsBoundedWindowReleaseCompressionMethods() throws {
        let listing = entries.joined(separator: "\n")
        for method in ["stor", "defN", "defF", "defS", "defX"] {
            try UpdateArchive.validate(listing: listing,
                details: details().replacingOccurrences(of: "defN", with: method), version: version)
        }
        for method in ["lzma", "bzip2", "xz", "ppmd", "unknown"] {
            XCTAssertThrowsError(try UpdateArchive.validate(listing: listing,
                details: details().replacingOccurrences(of: "defN", with: method), version: version), method)
        }
        XCTAssertThrowsError(try UpdateArchive.validate(listing: listing,
            details: entries.map { _ in "-rw-r--r-- 3.0 unx 10" }.joined(separator: "\n"), version: version))
    }
    func testRejectsDeclaredExpansionBeforeExtraction() {
        XCTAssertThrowsError(try UpdateArchive.validate(listing: entries.joined(separator: "\n"),
            details: details(sizes: ["999999999", "2", "0", "0"]), version: version))
        for size in ["-1", "9223372036854775807", "9223372036854775808", "unknown"] {
            XCTAssertThrowsError(try UpdateArchive.validate(listing: entries.joined(separator: "\n"),
                details: details(sizes: [size, "20", "30", "40"]), version: version))
        }
    }
    func testRejectsAmbiguousOrUnsupportedEntryMetadata() {
        for mode in ["lrwxr-xr-x", "?rw-r--r--", "brw-r--r--"] {
            XCTAssertThrowsError(try UpdateArchive.validate(listing: entries.joined(separator: "\n"),
                details: details(mode: mode), version: version))
        }
        XCTAssertThrowsError(try UpdateArchive.validate(listing: entries.joined(separator: "\n"),
            details: details(sizes: ["10", "20", "30"]), version: version))
        XCTAssertThrowsError(try UpdateArchive.validate(listing: entries.joined(separator: "\n"),
            details: details() + "\n" + details(), version: version))
    }
    func testRejectsTraversalUnexpectedPathsAndDuplicateNames() {
        for bad in ["/etc/hosts", "RemSound-Mac-v1.2.3/RemSound.app/../extra", "RemSound-Mac-v1.2.3/notes.txt",
            "RemSound-Mac-v1.2.3/RemSound.app/Contents\\bad", entries[0]] {
            XCTAssertThrowsError(try UpdateArchive.validate(listing: (entries + [bad]).joined(separator: "\n"),
                details: details(), version: version))
        }
    }
    func testRejectsUnsafeVersionsAndIncompletePayloads() {
        for bad in ["../1.2.3", "1.2.3/extra", "1.2", "1.2.3\n", "1.-2.3", "", "1.2.999999999999999999999"] {
            XCTAssertThrowsError(try UpdateArchive.payloadName(for: bad))
        }
        XCTAssertEqual(try UpdateArchive.payloadName(for: version), "RemSound-Mac-v1.2.3")
        XCTAssertThrowsError(try UpdateArchive.validate(listing: entries.dropLast().joined(separator: "\n"),
            details: details(sizes: ["10", "20", "30"]), version: version))
    }
    func testRejectsExcessiveEntryCountAndPathLengthBeforeExtraction() {
        let tooMany = entries + (0..<UpdateArchive.maximumEntries).map {
            "RemSound-Mac-v1.2.3/RemSound.app/Contents/extra\($0)"
        }
        XCTAssertThrowsError(try UpdateArchive.validate(listing: tooMany.joined(separator: "\n"),
            details: details(), version: version))
        let longPath = "RemSound-Mac-v1.2.3/RemSound.app/Contents/" + String(repeating: "a", count: UpdateArchive.maximumPathBytes)
        XCTAssertThrowsError(try UpdateArchive.validate(listing: (entries + [longPath]).joined(separator: "\n"),
            details: details(), version: version))
    }

}
