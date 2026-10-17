import Foundation
import XCTest

final class IsolatedTestDirectoryTests: XCTestCase {
    func testMissingRootRefusesInsteadOfUsingSystemTemporaryDirectory() {
        XCTAssertThrowsError(try IsolatedTestDirectory.root(environment: [:]))
        XCTAssertThrowsError(try IsolatedTestDirectory.root(environment: ["REMSOUND_TEST_ROOT": ""]))
    }

    func testRelativeHomeAndFilesystemRootsAreRejected() {
        for path in ["relative-test-data", "/", NSHomeDirectory()] {
            XCTAssertThrowsError(try IsolatedTestDirectory.root(environment: ["REMSOUND_TEST_ROOT": path]))
        }
    }

    func testFixtureFilesStayInsideExplicitRoot() throws {
        let root = try IsolatedTestDirectory.root()
        let directory = try IsolatedTestDirectory.make("fixture-boundary")
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(directory.deletingLastPathComponent().standardizedFileURL.path, root.path)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let file = directory.appendingPathComponent("synthetic-profile.json")
        try Data("synthetic fixture".utf8).write(to: file)
        XCTAssertEqual(try String(contentsOf: file), "synthetic fixture")
    }

    func testRedirectedRootAndTraversalNamesAreRejected() throws {
        let directory = try IsolatedTestDirectory.make("root-guard")
        defer { try? FileManager.default.removeItem(at: directory) }
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        XCTAssertThrowsError(try IsolatedTestDirectory.root(environment: ["REMSOUND_TEST_ROOT": alias.path]))
        for name in ["", "../escape", "escape/subdir", ".", "..", "escape\\subdir"] {
            XCTAssertThrowsError(try IsolatedTestDirectory.make(name))
        }
    }
}

