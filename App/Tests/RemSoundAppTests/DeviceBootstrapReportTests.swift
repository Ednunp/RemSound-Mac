import Foundation
import XCTest
import RemSoundCore
import RemSoundRuntime
@testable import RemSoundApp

final class DeviceBootstrapReportTests:XCTestCase {
    private func options(_ root:URL? = nil) throws -> LaunchOptions {
        var o=try LaunchOptions.parse(["--devices"]);o.configurationDirectory=root;return o
    }
    private func snapshot(name:String="Fixture input",uid:String="fixture-input") -> AudioDeviceReportSnapshot {
        .init(inputs:[.init(uid:uid,name:name,isDefault:true,formats:[AudioDeviceReportFormat(sampleRate:48000,channels:2,bitsPerChannel:32,encoding:"float PCM")])],outputs:[])
    }
    func testHelpListsEachStartupAndDeviceFlagOnce() {
        let lines=BootstrapReports.helpText.split(separator:"\n")
        for prefix in ["--profile NAME:","--connect IPv4[:port]:","--minimized (","--devices ("] {
            XCTAssertEqual(lines.filter{$0.hasPrefix(prefix)}.count,1,prefix)
        }
    }
    func testDeviceAliasesAndMixedModesAreUnambiguous() throws {
        for flag in ["--devices","--list-devices","--DEVICES"] { XCTAssertEqual(try LaunchOptions.parse([flag]).report,.devices) }
        for args in [["--devices","--version"],["--devices","--devices"],["--devices","--tray"],
            ["--devices","--profile","Studio"],["--devices","--headless","--config-dir","/isolated"],
            ["--devices","--control","status","--config-dir","/isolated"]] { XCTAssertThrowsError(try LaunchOptions.parse(args)) }
    }
    func testIsolatedDefaultRefusesBeforeDeviceProviderAndCreatesNothing() throws {
        let base=URL(fileURLWithPath:ProcessInfo.processInfo.environment["REMSOUND_TEST_ROOT"]!)
        let root=base.appendingPathComponent("device-report-"+UUID().uuidString);var calls=0
        XCTAssertThrowsError(try BootstrapReports.output(for:options(root),nativeDevices:{calls += 1;return self.snapshot()}))
        XCTAssertEqual(calls,0);XCTAssertFalse(FileManager.default.fileExists(atPath:root.path))
    }
    func testInjectedSnapshotProducesReadableDirectionsDefaultsUIDAndFormat() throws {
        var native=0
        let text=try BootstrapReports.output(for:options(),devices:{self.snapshot()},nativeDevices:{native += 1;return self.snapshot()})
        XCTAssertEqual(native,0)
        XCTAssertEqual(text,"Core Audio devices (current stream formats):\nInputs:\n  Fixture input [default]\n    UID: fixture-input\n    Stream 1: 48000 Hz, 2 channels, 32-bit float PCM\nOutputs:\n  (none)\n")
    }
    func testNormalReportUsesNativeProviderExactlyOnceWithoutStorageProviders() throws {
        var native=0,storage=0
        let text=try BootstrapReports.output(for:options(),profileTitles:{_ in storage += 1;return []},defaultProfiles:{storage += 1;return URL(fileURLWithPath:"/unrequested")},nativeDevices:{native += 1;return self.snapshot()})
        XCTAssertNotNil(text);XCTAssertEqual(native,1);XCTAssertEqual(storage,0)
    }
    func testNamesUIDsAndEncodingCannotInjectTerminalOrMultilineOutput() throws {
        let text=try XCTUnwrap(BootstrapReports.output(for:options(),devices:{self.snapshot(name:"Input\u{1b}[31m\nInjected",uid:"uid\u{2028}second")}))
        XCTAssertFalse(text.contains("\u{1b}"));XCTAssertFalse(text.contains("\nInjected"));XCTAssertFalse(text.contains("\u{2028}"))
        XCTAssertTrue(text.contains("UID:"))
    }
    func testUnavailableFormatsAndEmptyDirectionsAreExplicit() throws {
        let s=AudioDeviceReportSnapshot(inputs:[],outputs:[.init(uid:"output",name:"Output",isDefault:false,formats:[nil])])
        let text=try XCTUnwrap(BootstrapReports.output(for:options(),devices:{s}))
        XCTAssertTrue(text.contains("Inputs:\n  (none)"));XCTAssertTrue(text.contains("Stream 1: format unavailable"))
        XCTAssertFalse(text.contains("[default]"))
    }
    func testInvalidNumericFieldsAndExcessiveSnapshotsRefusePartialOutput() throws {
        let bad=AudioDeviceReportSnapshot(inputs:[.init(uid:"i",name:"Input",isDefault:false,formats:[AudioDeviceReportFormat(sampleRate:.nan,channels:2,bitsPerChannel:32,encoding:"float")])],outputs:[])
        XCTAssertThrowsError(try BootstrapReports.output(for:options(),devices:{bad}))
        let row=snapshot().inputs[0]
        XCTAssertThrowsError(try BootstrapReports.output(for:options(),devices:{.init(inputs:Array(repeating:row,count:1025),outputs:[])}))
    }
    func testUIDRepresentationPreservesEscapedIdentityAndDoesNotSilentlyTruncate() throws {
        let text=try XCTUnwrap(BootstrapReports.output(for:options(),devices:{self.snapshot(uid:"uid\u{2028}second")}))
        XCTAssertTrue(text.contains("UID: \"uid\\u2028second\""))
        let long=try XCTUnwrap(BootstrapReports.output(for:options(),devices:{self.snapshot(uid:String(repeating:"a",count:257))}))
        XCTAssertTrue(long.contains("UID: (omitted: longer than 256 characters)"))
    }
    func testDirectionsSortByNameThenExactUIDWithoutChangingDefaults() throws {
        let a=AudioDeviceReportItem(uid:"z",name:"Zulu",isDefault:true,formats:[])
        let b=AudioDeviceReportItem(uid:"b",name:"Alpha",isDefault:false,formats:[])
        let c=AudioDeviceReportItem(uid:"a",name:"Alpha",isDefault:false,formats:[])
        let text=try XCTUnwrap(BootstrapReports.output(for:options(),devices:{.init(inputs:[a,b,c],outputs:[])}))
        XCTAssertLessThan(try XCTUnwrap(text.range(of:"UID: a")?.lowerBound),try XCTUnwrap(text.range(of:"UID: b")?.lowerBound))
        XCTAssertLessThan(try XCTUnwrap(text.range(of:"UID: b")?.lowerBound),try XCTUnwrap(text.range(of:"UID: z")?.lowerBound))
        XCTAssertTrue(text.contains("Zulu [default]"))
    }
    func testOutputByteBudgetRefusesBeforeReturningAnOversizedReport() throws {
        let f=AudioDeviceReportFormat(sampleRate:48000,channels:2,bitsPerChannel:32,encoding:String(repeating:"e",count:64))
        let row=AudioDeviceReportItem(uid:"i",name:"Input",isDefault:false,formats:Array(repeating:f,count:256))
        XCTAssertThrowsError(try BootstrapReports.output(for:options(),devices:{.init(inputs:Array(repeating:row,count:1024),outputs:[])}))
    }
    func testOtherReportsAndOrdinaryLaunchNeverReachDeviceProviders() throws {
        var calls=0
        let device:()->AudioDeviceReportSnapshot={calls += 1;return self.snapshot()}
        XCTAssertNil(try BootstrapReports.output(for:LaunchOptions.parse([]),devices:device,nativeDevices:device))
        XCTAssertEqual(try BootstrapReports.output(for:LaunchOptions.parse(["--version"]),version:{"test"},devices:device,nativeDevices:device),"RemSound test\n")
        XCTAssertEqual(calls,0)
    }
}
