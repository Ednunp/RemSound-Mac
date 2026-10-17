import CryptoKit
import Foundation
import XCTest
@testable import RemSoundCore

final class WebListenerPageTests: XCTestCase {
    private let expectedDigest = "bcb2b5e4b449953c495247eda673fd0f8194ea84c7c594fc0bae3e04c98c2a7a"
    private func root() throws -> URL {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])
        let url = URL(fileURLWithPath: base).appendingPathComponent("page-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); addTeardownBlock { try FileManager.default.removeItem(at: url) }; return url
    }
    private func app(_ root: URL) throws -> (Bundle, URL) {
        let url = root.appendingPathComponent("Fixture.app"), resources = url.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: String] = ["CFBundleIdentifier":"test.web.page", "CFBundlePackageType":"APPL", "CFBundleVersion":"1"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        return (try XCTUnwrap(Bundle(url: url)), resources.appendingPathComponent("web-listener.html"))
    }
    func testSwiftPackageLoadsByteExactSharedPrimaryPage() throws {
        let data = try XCTUnwrap(WebListenerPage.load()); XCTAssertEqual(data.count, 44218)
        XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), expectedDigest)
    }
    func testPackagedApplicationUsesOnlyItsOwnRequiredPage() throws {
        let data = try XCTUnwrap(WebListenerPage.load()), (bundle, file) = try app(root())
        try data.write(to: file); XCTAssertEqual(WebListenerPage.load(bundle: bundle), data)
    }
    func testMissingPackagedPageNeverFallsBackToBuildWorkspace() throws {
        let (bundle, _) = try app(root()); XCTAssertNil(WebListenerPage.load(bundle: bundle))
    }
    func testSameSizeTamperedPackagedPageFailsClosed() throws {
        var data = try XCTUnwrap(WebListenerPage.load()); data[0] ^= 1
        let (bundle, file) = try app(root()); try data.write(to: file); XCTAssertNil(WebListenerPage.load(bundle: bundle))
    }
    func testEmptyOversizedAndNonregularFilesNeverReturnPage() throws {
        let root = try root(), file = root.appendingPathComponent("page")
        try Data().write(to: file); XCTAssertNil(WebListenerPage.read(file))
        try Data(repeating: 0, count: WebAdmission.maximumPageBytes + 1).write(to: file); XCTAssertNil(WebListenerPage.read(file))
        XCTAssertNil(WebListenerPage.read(root))
    }
    func testSymlinkDoesNotReadEvenAnExactPage() throws {
        let root = try root(), file = root.appendingPathComponent("page"), link = root.appendingPathComponent("link")
        try XCTUnwrap(WebListenerPage.load()).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file); XCTAssertNil(WebListenerPage.read(link))
    }
    func testChangedFileAfterReadIsDeferredRatherThanPublishingEarlierBytes() throws {
        let data = try XCTUnwrap(WebListenerPage.load()), file = try root().appendingPathComponent("page")
        try data.write(to: file)
        XCTAssertNil(WebListenerPage.read(file, afterRead: { try? Data([0]).write(to: file) }))
    }
    func testNamedPathReplacementAfterReadDefersOpenedOldPage() throws {
        let data=try XCTUnwrap(WebListenerPage.load()),root=try root(),file=root.appendingPathComponent("page"),moved=root.appendingPathComponent("old")
        try data.write(to:file)
        XCTAssertNil(WebListenerPage.read(file,afterRead:{
            try? FileManager.default.moveItem(at:file,to:moved)
            try? data.write(to:file)
        }))
        XCTAssertEqual(try Data(contentsOf:file),data);XCTAssertEqual(try Data(contentsOf:moved),data)
    }

}
