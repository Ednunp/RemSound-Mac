import Foundation
import RemSoundRuntime
import XCTest
@testable import RemSoundApp

final class BootstrapPluginStatusTests: XCTestCase {
    private func root() throws -> URL {
        URL(fileURLWithPath:try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])).appendingPathComponent(UUID().uuidString)
    }
    func testUnrelatedReportsNeverInspectPluginLocations() throws {
        for report:LaunchReport? in [nil,.version,.profiles,.namedPeers,.devices,.diagnostics,.selfCheck,.resourceCycle] {
            var options=try LaunchOptions.parse([]);options.report=report
            XCTAssertNil(try BootstrapPluginStatus.output(for:options,inspect:{_ in XCTFail("unrequested plugin inspection");throw RuntimeConfigurationError.invalidSettings}))
        }
    }
    func testReadOnlyMissingStatusIsStampedBoundedAndNeverConstructsSettings() throws {
        let root=try root();var options=try LaunchOptions.parse([]);options.configurationDirectory=root
        // The parser is tested separately; use the new report value once available.
        options.report = .pluginStatus
        var calls=0
        let result=try XCTUnwrap(BootstrapPluginStatus.output(for:options,inspect:{scope in
            calls += 1;XCTAssertEqual(scope,root)
            return try RuntimeConfiguration.pluginStatusForListing(root:scope)
        }))
        XCTAssertEqual(calls,1);XCTAssertEqual(result.exitCode,0)
        let report=try JSONDecoder().decode(PluginInstallationStatus.self,from:Data(result.text.utf8))
        XCTAssertEqual(report.items.count,3);XCTAssertTrue(report.items.allSatisfy{$0.state == .missing})
        XCTAssertTrue(report.metadataOnly);XCTAssertNotNil(ISO8601DateFormatter().date(from:report.generatedUTC))
        XCTAssertLessThan(result.text.utf8.count,4096);XCTAssertTrue(result.text.hasSuffix("\n"))
        XCTAssertFalse(result.text.contains(root.path));XCTAssertFalse(FileManager.default.fileExists(atPath:root.path))
    }
    func testReaderFailureIsNotFabricatedEmptySuccess() throws {
        var options=try LaunchOptions.parse([]);options.report = .pluginStatus
        XCTAssertThrowsError(try BootstrapPluginStatus.output(for:options,inspect:{_ in throw RuntimeConfigurationError.invalidSettings}))
    }
    func testIncompleteObservedBundleHasStructuredFailureExit() throws {
        let root=try root();defer {try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let contents=root.appendingPathComponent("Library/Audio/Plug-Ins/Components/RemSound.component/Contents")
        try FileManager.default.createDirectory(at:contents,withIntermediateDirectories:true)
        let info=["CFBundleIdentifier":"org.remsound.plugin","CFBundleExecutable":"RemSound","CFBundleShortVersionString":"1.2.3"]
        try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:contents.appendingPathComponent("Info.plist"))
        let options=try LaunchOptions.parse(["--plugin-status","--config-dir",root.path])
        let result=try XCTUnwrap(BootstrapPluginStatus.output(for:options))
        XCTAssertEqual(result.exitCode,1)
        let report=try JSONDecoder().decode(PluginInstallationStatus.self,from:Data(result.text.utf8))
        XCTAssertEqual(report.items[0].state,.incomplete)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("settings.plist").path))
    }
}
