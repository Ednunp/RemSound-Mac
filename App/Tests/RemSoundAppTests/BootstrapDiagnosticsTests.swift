import Foundation
import RemSoundCore
import RemSoundRuntime
import XCTest
@testable import RemSoundApp

final class BootstrapDiagnosticsTests: XCTestCase {
    private let meta=DiagnosticRuntimeMetadata(settings:.present,settingsBytes:42,logFiles:1,logBytes:12,logsComplete:true)
    private let profiles=ProfileDiagnosticInventory(readable:1,readOnly:0,unreadable:0,deferred:0,complete:true)
    func testUnrelatedModesConsultNoProviderOrPublisher() throws {
        for args in [[],["--version"],["--profiles"],["--devices"],["--close","--config-dir","/private/client-only"]] {
            XCTAssertNil(try BootstrapDiagnostics.result(for:LaunchOptions.parse(args),metadata:{_ in XCTFail("Unexpected metadata");throw DiagnosticReportError.invalidScope},profiles:{_ in XCTFail("Unexpected profiles");return self.profiles},defaultProfiles:{XCTFail("Unexpected default path");return URL(fileURLWithPath:"/private/unused")},devices:{XCTFail("Unexpected device");return .init(inputs:[],outputs:[])},publish:{_,_ in XCTFail("Unexpected publication");return .published}))
        }
    }
    func testIsolatedReportRefusesDeviceAndDefaultProfileFactoriesBeforeConstruction() throws {
        let options=try LaunchOptions.parse(["--diag","--config-dir","/private/missing-diagnostic-root"])
        let result=try BootstrapDiagnostics.result(for:options,metadata:{_ in self.meta},profiles:{url in XCTAssertEqual(url.path,"/private/missing-diagnostic-root/Profiles");return self.profiles},defaultProfiles:{XCTFail("Normal profile fallback");return URL(fileURLWithPath:"/private/unused")},devices:{XCTFail("Isolated native device factory");return .init(inputs:[],outputs:[])},version:{"test"})
        guard case .standardOutput(let text)=result else { return XCTFail("Missing stdout report") }
        XCTAssertTrue(text.contains("Settings metadata: present"));XCTAssertTrue(text.contains("values not read"))
        XCTAssertTrue(text.contains("Devices: not collected"));XCTAssertFalse(text.contains("missing-diagnostic-root"))
    }
    func testInvalidScopeStopsBeforeAllLaterFactories() throws {
        let options=try LaunchOptions.parse(["--diag"])
        XCTAssertThrowsError(try BootstrapDiagnostics.result(for:options,metadata:{_ in throw DiagnosticReportError.invalidScope},profiles:{_ in XCTFail("Late profile factory");return self.profiles},devices:{XCTFail("Late device factory");return .init(inputs:[],outputs:[])},publish:{_,_ in XCTFail("Late publish");return .published}))
    }
    func testNormalInjectedInventoryAndCollectionFailuresHaveNoPrivateEcho() throws {
        let options=try LaunchOptions.parse(["--diag"])
        let result=try BootstrapDiagnostics.result(for:options,metadata:{_ in self.meta},profiles:{_ in throw ProfileDiagnosticError.unavailable},defaultProfiles:{URL(fileURLWithPath:"/private/injected")},devices:{throw DeviceReportOutput.Failure.invalid},version:{"test"})
        guard case .standardOutput(let text)=result else { return XCTFail("Missing report") }
        XCTAssertTrue(text.contains("Profiles: unavailable"));XCTAssertTrue(text.contains("Devices: unavailable"))
        XCTAssertFalse(text.contains("/private/injected"))
    }
    func testPublicationReceiptsAreTruthfulAndErrorsDoNotBecomeStdoutSuccess() throws {
        let options=try LaunchOptions.parse(["--diag","/private/report.txt","--config-dir","/private/missing-diagnostic-root"])
        for receipt in [DiagnosticReportPublication.published,.cleanupUncertain,.locationUncertain] {
            let result=try BootstrapDiagnostics.result(for:options,metadata:{_ in self.meta},profiles:{_ in self.profiles},publish:{text,url in XCTAssertTrue(text.hasPrefix("RemSound diagnostics"));XCTAssertEqual(url.path,"/private/report.txt");return receipt})
            XCTAssertEqual(result,receipt == .published ? .saved : .publicationUncertain)
        }
        XCTAssertThrowsError(try BootstrapDiagnostics.result(for:options,metadata:{_ in self.meta},profiles:{_ in self.profiles},publish:{_,_ in throw DiagnosticReportError.invalidDestination}))
    }
    func testMetadataBoundsAndUnknownBitDepthAreExplicit() throws {
        XCTAssertThrowsError(try PassiveDiagnosticReport.output(version:"test",system:"test",architecture:"arm64",profiles:nil,devices:nil,metadata:.init(settings:.present,settingsBytes:-1,logFiles:0,logBytes:0,logsComplete:true)))
        let device=AudioDeviceReportItem(uid:"private",name:"private",isDefault:false,formats:[.init(sampleRate:48000,channels:2,bitsPerChannel:0,encoding:"private")])
        let text=try PassiveDiagnosticReport.output(version:"test",system:"test",architecture:"arm64",profiles:nil,devices:.init(inputs:[device],outputs:[]),metadata:meta)
        XCTAssertTrue(text.contains("bit depth unavailable"));XCTAssertFalse(text.contains("0-bit"))
    }
}
