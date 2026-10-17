import Foundation
import RemSoundRuntime
import XCTest
@_spi(NativeProductChecks) @testable import RemSoundCore

final class ProfileLoggingTests: XCTestCase {
    private func config() throws -> RuntimeConfiguration {
        let root=try IsolatedTestDirectory.root().appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        return try RuntimeConfiguration(options:LaunchOptions.parse(["--config-dir",root.path]))
    }
    private func profile() -> ConnectionProfile {
        .init(title:"Logging fixture",displayName:"Mac",manualPeerAddress:"",selectedPeerAddresses:[],sendInput:false,receiveAudio:false,allowPlugins:false,reconnectOnOpen:false)
    }
    func testProfileExplicitFalseTrueAndAbsentSurviveActualStore() throws {
        let c=try config(),store=ProfileStore(directory:c.profilesDirectory)
        let template=profile()
        for value:Bool? in [nil,false,true] {
            let raw=try JSONEncoder().encode(template)
            var object=try XCTUnwrap(JSONSerialization.jsonObject(with:raw) as? [String:Any])
            object["enableLogs"]=value
            let loaded=try JSONDecoder().decode(ConnectionProfile.self,from:JSONSerialization.data(withJSONObject:object))
            try store.save(loaded)
            let reread=try JSONSerialization.jsonObject(with:JSONEncoder().encode(store.load(id:loaded.id))) as! [String:Any]
            XCTAssertEqual(reread["enableLogs"] as? Bool,value)
        }
    }
    func testExplicitChoiceUpdatesActualSessionLoggerImmediatelyAndComputer() throws {
        let c=try config(),session=Session(configuration:c),file=c.logsDirectory.appendingPathComponent("Latest.log")
        XCTAssertTrue(session.applyDiagnosticLogging(profileChoice:false))
        session.note("suppressed first");XCTAssertFalse(session.diagnosticLoggingEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
        XCTAssertFalse(DiagnosticLoggingPreferences.enabled(in:c.settings))
        XCTAssertTrue(session.applyDiagnosticLogging(profileChoice:true))
        session.note("enabled actual logger");XCTAssertTrue(session.diagnosticLoggingEnabled)
        let on=try Data(contentsOf:file);XCTAssertTrue(String(decoding:on,as:UTF8.self).contains("enabled actual logger"))
        XCTAssertTrue(DiagnosticLoggingPreferences.enabled(in:c.settings))
        XCTAssertTrue(session.applyDiagnosticLogging(profileChoice:false))
        session.note("suppressed later");XCTAssertFalse(session.diagnosticLoggingEnabled)
        XCTAssertEqual(try Data(contentsOf:file),on)
        XCTAssertEqual(session.testPorts.audio,0)
    }
    func testAbsentInheritsWithoutWritingAndRetiredProfileKeyDoesNotReturn() throws {
        let c=try config(),session=Session(configuration:c)
        for value in [false,true] {
            XCTAssertTrue(DiagnosticLoggingPreferences.setEnabled(value,in:c.settings))
            let before=try Data(contentsOf:c.root!.appendingPathComponent("settings.plist"))
            XCTAssertTrue(session.applyDiagnosticLogging(profileChoice:nil))
            XCTAssertEqual(session.diagnosticLoggingEnabled,value)
            XCTAssertEqual(try Data(contentsOf:c.root!.appendingPathComponent("settings.plist")),before)
        }
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(profile())) as! [String:Any]
        object.removeValue(forKey:"enableLogs");object["LoggingEnabled"]=true
        let decoded=try JSONDecoder().decode(ConnectionProfile.self,from:JSONSerialization.data(withJSONObject:object))
        let saved=try JSONSerialization.jsonObject(with:JSONEncoder().encode(decoded)) as! [String:Any]
        XCTAssertNil(saved["enableLogs"])
    }
    func testFailedComputerSaveKeepsPriorLoggerGate() throws {
        let c=try config(),session=Session(configuration:c)
        XCTAssertTrue(DiagnosticLoggingPreferences.setEnabled(false,in:c.settings))
        XCTAssertTrue(session.applyDiagnosticLogging(profileChoice:false))
        let settings=c.root!.appendingPathComponent("settings.plist")
        try FileManager.default.removeItem(at:settings);try FileManager.default.createDirectory(at:settings,withIntermediateDirectories:false)
        XCTAssertFalse(session.applyDiagnosticLogging(profileChoice:true))
        XCTAssertFalse(session.diagnosticLoggingEnabled)
        XCTAssertFalse(DiagnosticLoggingPreferences.enabled(in:c.settings))
    }
    func testNamedProductLoggingSliceUsesActualPolicyAndKeepsMissingAcceptanceUnverified() {
        let name="LOGS PER PROFILE: each profile logs by its own choice, this computer's setting following; never chosen follows the computer; new profiles off"
        let report=ProductTestPack.run(pack:.feature,only:name)
        XCTAssertEqual(report.steps.count,1)
        XCTAssertGreaterThanOrEqual(report.steps.first?.assertions ?? 0,16)
        XCTAssertEqual(report.steps.first?.status,"UNVERIFIED")
        XCTAssertEqual(report.exitCode,1)
    }
    func testNativeValueReceiptCannotClaimZeroAssertionsOrLeakArbitraryFailures() {
        let name="LOGS PER PROFILE: each profile logs by its own choice, this computer's setting following; never chosen follows the computer; new profiles off"
        for receipt in [(assertions:0,failures:[String]()),(assertions:1,failures:["untrusted path"]),(assertions:1,failures:["logs.native.control\nvalue"]),(assertions:129,failures:[String]())] {
            let report=ProductTestPack.run(pack:.feature,only:name,budget:8,nativeProfileLogging:{receipt})
            XCTAssertEqual(report.steps.first?.status,"FAIL")
            XCTAssertEqual(report.steps.first?.assertions,21)
            XCTAssertEqual(report.steps.first?.failures,["logs.native.invalid-receipt"])
            XCTAssertEqual(report.exitCode,1)
        }
    }
    func testNativeFailedReceiptRemainsFailedAndRetainsOnlyCompletedAssertions() {
        let name="LOGS PER PROFILE: each profile logs by its own choice, this computer's setting following; never chosen follows the computer; new profiles off"
        let report=ProductTestPack.run(pack:.feature,only:name,budget:8,nativeProfileLogging:{(2,["logs.native.fixture-failed"])})
        XCTAssertEqual(report.steps.first?.assertions,23)
        XCTAssertEqual(report.steps.first?.status,"FAIL")
        XCTAssertEqual(report.steps.first?.failures,["logs.native.fixture-failed"])
        XCTAssertEqual(report.exitCode,1)
    }
    func testMalformedProfileLoggingChoiceRefusesInsteadOfBecomingInheritance() throws {
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(profile())) as! [String:Any]
        object["enableLogs"]="yes"
        XCTAssertThrowsError(try JSONDecoder().decode(ConnectionProfile.self,from:JSONSerialization.data(withJSONObject:object)))
    }

    func testOffClosesActualDetailedLoggerAndDoesNotReopenIt() throws {
        let c=try config(),session=Session(configuration:c)
        XCTAssertTrue(session.applyDiagnosticLogging(profileChoice:true))
        session.openDetailedLog()
        let files=try FileManager.default.contentsOfDirectory(at:c.logsDirectory,includingPropertiesForKeys:nil)
        let detailed=try XCTUnwrap(files.first{$0.lastPathComponent.hasPrefix("RemSound-Mac-")})
        XCTAssertTrue(session.applyDiagnosticLogging(profileChoice:false))
        let before=try Data(contentsOf:detailed)
        session.note("must not reach detailed logger");XCTAssertFalse(session.diagnosticLoggingEnabled)
        session.openDetailedLog()
        XCTAssertEqual(try Data(contentsOf:detailed),before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at:c.logsDirectory,includingPropertiesForKeys:nil),files)
    }

}
