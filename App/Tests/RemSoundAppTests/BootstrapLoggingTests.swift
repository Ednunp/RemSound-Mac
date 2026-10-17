import Foundation
import RemSoundRuntime
import XCTest
@testable import RemSoundApp

@MainActor final class BootstrapLoggingTests: XCTestCase {
    private func store() throws -> (SettingsStore, URL) {
        let root=URL(fileURLWithPath:try XCTUnwrap(ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"])).appendingPathComponent(UUID().uuidString)
        let store=try RuntimeConfiguration.settingsForStandaloneCommand(root:root)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        return (store,root)
    }
    func testUnrelatedLaunchAndReportsNeverConstructSettingsFactory() throws {
        for args in [[], ["--version"], ["--profiles"], ["--devices"], ["--close","--config-dir","/private/client-only"]] {
            let options=try LaunchOptions.parse(args)
            XCTAssertNil(try BootstrapLogging.output(for:options,store:{ XCTFail("Unexpected settings access");throw RuntimeConfigurationError.invalidSettings }))
        }
    }
    func testBootstrapCommitsBeforeClaimingSuccessAndPreservesOtherSettings() throws {
        let (store,root)=try store();store.set("kept",forKey:"other")
        let options=try LaunchOptions.parse(["--log","off"])
        let output=try XCTUnwrap(BootstrapLogging.output(for:options,store:{store}))
        XCTAssertTrue(output.contains("OFF"));XCTAssertTrue(output.contains("next launch"))
        XCTAssertFalse(DiagnosticLoggingPreferences.enabled(in:store));XCTAssertEqual(store.string(forKey:"other"),"kept")
        let file=root.appendingPathComponent("settings.plist")
        try FileManager.default.removeItem(at:file);try FileManager.default.createDirectory(at:file,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        XCTAssertThrowsError(try BootstrapLogging.output(for:LaunchOptions.parse(["--log","on"]),store:{store}))
        XCTAssertFalse(DiagnosticLoggingPreferences.enabled(in:store))
    }
    func testStoreErrorsPropagateAndHelpHasOneActualFlag() throws {
        XCTAssertThrowsError(try BootstrapLogging.output(for:LaunchOptions.parse(["--log","on"]),store:{throw RuntimeConfigurationError.unsafeConfigurationDirectory}))
        XCTAssertEqual(BootstrapReports.helpText.components(separatedBy:"--log on|off:").count-1,1)
    }
    func testDisabledResponsivenessNeverWritesOrSendsDiagnosticSink() throws {
        let (_,root)=try store(), file=root.appendingPathComponent("Responsiveness.log")
        var lines:[String]=[]
        let monitor=UIResponsivenessMonitor(logURL:file,sink:{lines.append($0)},enabled:false)
        monitor.start();let id=monitor.begin(.showWindow);monitor.handlerReturned(id);monitor.finish(id);monitor.stop()
        XCTAssertTrue(lines.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
    }
    func testResponsivenessLoggingChoiceRevokesQueuedWritesAndCanReenableWithoutAnotherOwner() throws {
        let (_,root)=try store(), file=root.appendingPathComponent("Responsiveness.log")
        var lines=[String]()
        let monitor=UIResponsivenessMonitor(logURL:file,sink:{lines.append($0)},enabled:true)
        monitor.start()
        let first=monitor.begin(.showWindow);monitor.handlerReturned(first);monitor.finish(first)
        monitor.setEnabled(false)
        let count=lines.count
        let off=monitor.begin(.showWindow);monitor.handlerReturned(off);monitor.finish(off)
        monitor.setEnabled(false)
        XCTAssertEqual(lines.count,count)
        monitor.setEnabled(true)
        let last=monitor.begin(.showWindow);monitor.handlerReturned(last);monitor.finish(last)
        monitor.stop()
        XCTAssertGreaterThan(lines.count,count)
        monitor.setEnabled(true)
        let ended=monitor.begin(.showWindow);monitor.handlerReturned(ended);monitor.finish(ended);monitor.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
    }

}
