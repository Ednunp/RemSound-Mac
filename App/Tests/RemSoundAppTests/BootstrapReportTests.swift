import Foundation
import RemSoundCore
import RemSoundRuntime
import XCTest
@testable import RemSoundApp

final class BootstrapReportTests: XCTestCase {
    private func options(_ report: LaunchReport, root: URL? = nil) throws -> LaunchOptions {
        var options = try LaunchOptions.parse([]); options.report = report; options.configurationDirectory = root; return options
    }
    private func root() throws -> URL {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"]!)
        let root = base.appendingPathComponent("report-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    func testVersionReturnsExactTextWithoutAnyStorageProvider() throws {
        var storage = 0, versions = 0
        let text = try BootstrapReports.output(for: options(.version), version: { versions += 1; return "0.1.57" },
            profileTitles: { _ in storage += 1; return ["Wrong"] }, defaultProfiles: { storage += 1; return URL(fileURLWithPath:"/unrequested") })
        XCTAssertEqual(text, "RemSound 0.1.57\n"); XCTAssertEqual(versions, 1); XCTAssertEqual(storage, 0)
    }
    func testOrdinaryLaunchIsUnchangedAndDoesNotInvokeReportProviders() throws {
        var calls = 0
        XCTAssertNil(try BootstrapReports.output(for: LaunchOptions.parse([]), version: { calls += 1; return "unused" },
            profileTitles: { _ in calls += 1; return [] }, defaultProfiles: { calls += 1; return URL(fileURLWithPath:"/unused") }))
        XCTAssertEqual(calls, 0)
    }
    func testProfileReportUsesActualDefaultStoreLocationAndSortedTitles() throws {
        let directory = try root(); var calls = 0
        let text = try BootstrapReports.output(for: options(.profiles), profileTitles: { url in XCTAssertEqual(url,directory); calls += 1; return ["zeta", "Alpha"] }, defaultProfiles: { directory })
        XCTAssertEqual(text, "Saved profiles (2):\n  Alpha\n  zeta\n"); XCTAssertEqual(calls,1)
    }
    func testExplicitMissingRootNeverFallsBackOrCreatesDirectories() throws {
        let directory = try root(); var fallback = 0
        let text = try BootstrapReports.output(for: options(.profiles, root: directory), profileTitles: { url in
            XCTAssertEqual(url,directory.appendingPathComponent("Profiles",isDirectory:true)); return []
        },defaultProfiles: { fallback += 1; return URL(fileURLWithPath:"/wrong") })
        XCTAssertEqual(text, "No saved profiles.\n"); XCTAssertEqual(fallback,0); XCTAssertFalse(FileManager.default.fileExists(atPath:directory.path))
    }
    func testActualProfilesAreReadWithoutSettingsMigrationOrByteChanges() throws {
        let directory = try root(), profiles = directory.appendingPathComponent("Profiles")
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let store = ProfileStore(directory:profiles), p = ConnectionProfile(title:"Studio",displayName:"Secret name",manualPeerAddress:"203.0.113.7",selectedPeerAddresses:[],sendInput:false,receiveAudio:false,allowPlugins:false,reconnectOnOpen:false)
        try store.save(p)
        let settings = directory.appendingPathComponent("settings.plist"); try Data("unreadable settings preserved".utf8).write(to:settings)
        let file = profiles.appendingPathComponent(p.id.uuidString+".json"), before = try Data(contentsOf:file), attributes = try FileManager.default.attributesOfItem(atPath:file.path)
        XCTAssertEqual(try BootstrapReports.output(for:options(.profiles,root:directory)), "Saved profiles (1):\n  Studio\n")
        XCTAssertEqual(try Data(contentsOf:file),before); XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:file.path)[.modificationDate] as? Date,attributes[.modificationDate] as? Date)
        XCTAssertEqual(try Data(contentsOf:settings),Data("unreadable settings preserved".utf8)); XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent("Logs").path))
    }
    func testTitlesCannotInjectTerminalOrMultilineOutput() throws {
        let text = try BootstrapReports.output(for:options(.profiles),profileTitles:{ _ in ["one\nline\t\u{1b}payload\u{202e}\u{2028}next",String(repeating:"x",count:200)] },defaultProfiles:{ URL(fileURLWithPath:"/unused") })
        let output = try XCTUnwrap(text); XCTAssertFalse(output.contains("\u{1b}")); XCTAssertFalse(output.contains("\u{202e}")); XCTAssertFalse(output.contains("\u{2028}"))
        XCTAssertEqual(output.components(separatedBy:"\n").count,4)
        XCTAssertTrue(output.contains("one line payload next")); XCTAssertFalse(output.contains(String(repeating:"x",count:81)))
    }
    func testSymlinkRootOrProfilesRefusesWithoutFallback() throws {
        let directory = try root(); try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let target = directory.appendingPathComponent("target"), link = directory.appendingPathComponent("link")
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]); try FileManager.default.createSymbolicLink(at:link,withDestinationURL:target)
        var calls = 0
        XCTAssertThrowsError(try BootstrapReports.output(for: options(.profiles,root:link),profileTitles:{ _ in calls += 1;return [] }))
        try FileManager.default.createSymbolicLink(at:directory.appendingPathComponent("Profiles"),withDestinationURL:target)
        XCTAssertThrowsError(try BootstrapReports.output(for: options(.profiles,root:directory),profileTitles:{ _ in calls += 1;return [] })); XCTAssertEqual(calls,0)
    }
    func testMalformedProfileIsPreservedAndSecretsAreNotListed() throws {
        let directory = try root(), profiles = directory.appendingPathComponent("Profiles")
        try FileManager.default.createDirectory(at:profiles,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]); try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
        let broken = profiles.appendingPathComponent(UUID().uuidString+".json"), bytes = Data("password-marker-malformed".utf8); try bytes.write(to:broken)
        XCTAssertEqual(try BootstrapReports.output(for:options(.profiles,root:directory)), "No saved profiles.\n"); XCTAssertEqual(try Data(contentsOf:broken),bytes)
    }
    func testProviderFailureIsNotReportedAsAnEmptySuccess() throws {
        struct Failed: Error {}
        XCTAssertThrowsError(try BootstrapReports.output(for: options(.profiles),profileTitles:{ _ in throw Failed() }))
    }
    func testPublicLocationRefusesNonFileRootsBeforeProvider() throws {
        var calls = 0
        XCTAssertThrowsError(try BootstrapReports.output(for: options(.profiles,root:URL(string:"https://example.invalid/not-a-local-profile-root")!),
            profileTitles:{ _ in calls += 1; return [] },defaultProfiles:{ calls += 1; return URL(fileURLWithPath:"/unused") }))
        XCTAssertEqual(calls,0)
    }
    func testOversizedProfileCountFailsWithoutPartialSuccess() throws {
        XCTAssertThrowsError(try BootstrapReports.output(for: options(.profiles),profileTitles:{ _ in Array(repeating:"Studio",count:4097) }))
    }
}
