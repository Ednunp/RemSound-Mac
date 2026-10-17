import Darwin
import XCTest
@testable import RemSoundCore

final class UpdateExtractionTests: XCTestCase {
    private let version = "1.2.3"
    private let names = UpdateArchive.bundleNames.map { "RemSound-Mac-v1.2.3/\($0)/Contents/Info.plist" }

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "zip", subdirectory: "Fixtures/Updates"))
    }

    private func workspace(_ body: (URL) throws -> Void) throws {
        guard let path = ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"] else {
            throw XCTSkip("Set REMSOUND_TEST_ROOT to an isolated test directory.")
        }
        let root = URL(fileURLWithPath: path).appendingPathComponent("update-extraction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    func testExtractsCompletePayloadAndZIP64PreservingExecutables() throws {
        try workspace { root in
            for name in ["good", "parents", "zip64", "zip64-local-placeholder", "descriptor-valid", "executable"] {
                let output = root.appendingPathComponent(name)
                try UpdateArchive.extract(zip: fixture(name), to: output, version: version)
                for path in names {
                    XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(path)), Data("1234567890".utf8))
                }
                let mode = try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? NSNumber
                XCTAssertEqual(mode?.intValue, 0o700)
                if name == "executable" {
                    let executable = output.appendingPathComponent("RemSound-Mac-v1.2.3/RemSound.app/Contents/MacOS/RemSound")
                    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
                }
            }
        }
    }

    func testRejectsHostileArchivesAndRemovesOnlyItsPartialRoot() throws {
        try workspace { root in
            let sentinel = root.appendingPathComponent("external-profile.json")
            try Data("keep this profile".utf8).write(to: sentinel)
            for name in ["traversal", "absolute", "backslash", "foreign", "duplicate", "case-alias",
                "directory-alias", "symlink", "special", "fifo-normalized", "unicode", "incomplete",
                "long-path", "directory-data", "truncated", "crc", "encrypted", "zip64-truncated",
                "zip64-forged", "tar-hardlink", "forged-size", "central-count-small"] {
                let output = root.appendingPathComponent(name)
                XCTAssertThrowsError(try UpdateArchive.extract(zip: fixture(name), to: output, version: version), name)
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), name)
                XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep this profile".utf8), name)
            }
        }
    }

    func testRejectsOtherCompressionMethodsBeforeCreatingRoot() throws {
        try workspace { root in
            for name in ["compression-bzip2", "compression-lzma"] {
                let output = root.appendingPathComponent(name)
                XCTAssertThrowsError(try UpdateArchive.extract(zip: fixture(name), to: output, version: version)) { error in
                    XCTAssertTrue(error.localizedDescription.contains("unsupported entry metadata"), error.localizedDescription)
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            }
        }
    }
    func testRejectsUnsupportedLocalCompressionDespiteStoredCentralMetadata() throws {
        try workspace { root in
            let output = root.appendingPathComponent("local-lzma")
            XCTAssertThrowsError(try UpdateArchive.extract(zip: fixture("compression-local-lzma"), to: output, version: version)) { error in
                XCTAssertTrue(error.localizedDescription.contains("unsupported compression"), error.localizedDescription)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }
    func testByteAndCreatedDirectoryBudgetsCleanPartialRoots() throws {
        try workspace { root in
            for (name, limits) in [("budget", UpdateArchive.ExtractionLimits(maximumBytes: 80)),
                ("good", UpdateArchive.ExtractionLimits(maximumEntries: 4))] {
                let output = root.appendingPathComponent(name)
                XCTAssertThrowsError(try UpdateArchive.extract(zip: fixture(name), to: output,
                    version: version, timeout: 10, limits: limits))
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            }
        }
    }

    func testExpiredAndShortDeadlineLeaveNoPartialPayload() throws {
        try workspace { root in
            for (name, seconds) in [("good", 0.0), ("during-deadline", 0.01)] {
                let output = root.appendingPathComponent(name)
                XCTAssertThrowsError(try UpdateArchive.extract(zip: fixture(name), to: output,
                    version: version, timeout: seconds))
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            }
        }
    }

    func testExistingDirectoryAndSymlinkAreNeverDeletedOrWritten() throws {
        try workspace { root in
            let existing = root.appendingPathComponent("existing")
            try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
            let sentinel = existing.appendingPathComponent("recording.wav")
            try Data("keep recording".utf8).write(to: sentinel)
            let alias = root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: existing)
            for output in [existing, alias] {
                XCTAssertThrowsError(try UpdateArchive.extract(zip: fixture("good"), to: output, version: version))
                XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep recording".utf8))
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: existing.path), ["recording.wav"])
            }
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), existing.path)
        }
    }
}
