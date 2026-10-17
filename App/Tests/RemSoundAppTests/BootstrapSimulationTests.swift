import Foundation
import XCTest
import RemSoundJam
import RemSoundSim
import RemSoundRuntime
@testable import RemSoundApp

final class BootstrapSimulationTests: XCTestCase {
    func recording() -> String {
        var r=NetworkRecording();r.facts=[.init("machine","private imported name")]
        r.streams=[.init(index:0,from:"10.0.0.1:1",streamId:7,lane:"Mixed",format:"fixture",codec:1,frameSamples:120)]
        r.packets=(0..<400).map{.init(ms:Double($0)*2.5,stream:0,sequence:UInt32($0),bytes:60)};return r.text()
    }
    func options(_ extra:[String]=[]) throws -> LaunchOptions {
        try LaunchOptions.parse(["--simulate","replay","--recording","/owned/recording.txt","--seconds","0.25"]+extra)
    }
    func testActualOfflineCallerProducesStampedBoundedJSONWithoutPublication() throws {
        var reads=0
        let out=try XCTUnwrap(BootstrapSimulation.output(for:options(),read:{url in reads += 1;XCTAssertEqual(url.path,"/owned/recording.txt");return self.recording()},publish:{_,_ in XCTFail("unsolicited publication");return .published}))
        XCTAssertEqual(reads,1);XCTAssertEqual(out.exitCode,0);XCTAssertNil(out.notice)
        let report=try JSONDecoder().decode(ReplaySimulation.Report.self,from:Data(out.text.utf8))
        XCTAssertEqual(report.schema,1);XCTAssertEqual(report.seed,1);XCTAssertEqual(report.places,400)
        XCTAssertFalse(report.startedUTC.isEmpty);XCTAssertLessThan(out.text.utf8.count,16*1024)
        XCTAssertFalse(out.text.contains("private imported name"));XCTAssertFalse(report.unverified.isEmpty)
    }
    func testActualEarlyCallerSelectsNativeOpusWithoutRuntimeOrPublication() throws {
        let text=recording().replacingOccurrences(of:"codec 1 frame",with:"codec 2 frame")
        let out=try XCTUnwrap(BootstrapSimulation.output(for:options(),read:{_ in text},publish:{_,_ in XCTFail("unexpected publication");return .published}))
        let report=try JSONDecoder().decode(ReplaySimulation.Report.self,from:Data(out.text.utf8))
        XCTAssertTrue(report.nativeCodec);XCTAssertGreaterThan(report.nativeDecodedFrames,0)
        XCTAssertEqual(report.scope,"offline-native-Opus-and-Mac-receive")
        XCTAssertEqual(out.exitCode,0);XCTAssertFalse(out.text.contains("private imported name"))
    }
    func testEarlyCallerIncludesFixedComparisonRowsAndKeepsRecordedDescriptor() throws {
        let out=try XCTUnwrap(BootstrapSimulation.output(for:options(),read:{_ in self.recording()}))
        let json=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(out.text.utf8)) as? [String:Any])
        let rows=json["comparisons"] as? [[String:Any]] ?? []
        XCTAssertEqual(rows.count,18)
        XCTAssertEqual(json["recordedCodec"] as? Int,1)
        XCTAssertEqual(json["recordedFrameSamples"] as? Int,120)
        XCTAssertTrue(rows.allSatisfy { ($0["nativeDecodedFrames"] as? Int ?? 0)>0 })
        XCTAssertEqual(out.exitCode,0)
    }
    func testActualEarlyCallerSelectsNativeCustom64AndFixedReferenceTargets() throws {
        var value = NetworkRecording()
        value.streams = [.init(index: 0, from: "10.0.0.9:1", streamId: 7, lane: "Mixed", format: "private custom", codec: 3, frameSamples: 64)]
        value.packets = (0..<120).map { .init(ms: Double($0 * 64) / 48 + 5, stream: 0, sequence: UInt32($0), bytes: 60) }
        let out = try XCTUnwrap(BootstrapSimulation.output(for: options(), read: { _ in value.text() }, publish: { _, _ in XCTFail("unexpected publication"); return .published }))
        let report = try JSONDecoder().decode(ReplaySimulation.Report.self, from: Data(out.text.utf8))
        XCTAssertEqual(out.exitCode, 0)
        XCTAssertTrue(report.nativeCodec)
        XCTAssertEqual(report.recordedCodec, 3)
        XCTAssertEqual(report.recordedFrameSamples, 64)
        XCTAssertGreaterThan(report.nativeDecodedFrames, 0)
        XCTAssertEqual(report.comparisons.count, 18)
        XCTAssertTrue(report.comparisons.prefix(6).allSatisfy { $0.codec == "custom-opus-celt" && $0.packetFrames == 64 })
        XCTAssertFalse(out.text.contains("private custom"))
    }
    func testHelpAndForeignScopesRefuseBeforeInputOrPublication() throws {
        XCTAssertNil(try BootstrapSimulation.output(for:options(["--help"]),read:{_ in XCTFail("help input");return self.recording()}))
        var value=try options();value.headless=true
        XCTAssertThrowsError(try BootstrapSimulation.output(for:value,read:{_ in XCTFail("foreign input");return self.recording()}))
        value=try options();value.report = .selfCheck
        XCTAssertThrowsError(try BootstrapSimulation.output(for:value,read:{_ in XCTFail("report input");return self.recording()}))
    }
    func testPublicationOwnsOneReceiptAndUncertainResultRemainsJSON() throws {
        for receipt in [DiagnosticReportPublication.published,.cleanupUncertain,.locationUncertain] {
            var writes=0
            let out=try XCTUnwrap(BootstrapSimulation.output(for:options(["--out","/owned/report"]),read:{_ in self.recording()},publish:{text,url in
                writes += 1;XCTAssertEqual(url.path,"/owned/report/simulation-replay.json");XCTAssertFalse(text.contains("private imported name"));return receipt
            }))
            XCTAssertEqual(writes,1);XCTAssertEqual(out.exitCode,receipt == .published ? 0:1)
            XCTAssertNoThrow(try JSONDecoder().decode(ReplaySimulation.Report.self,from:Data(out.text.utf8)))
            XCTAssertEqual(out.notice == nil,receipt == .published)
        }
    }
    func testProviderFailureNeverEchoesRawImportedValuesOrPublishes() throws {
        let error=NSError(domain:"fixture",code:1,userInfo:[NSLocalizedDescriptionKey:"private secret text"])
        XCTAssertThrowsError(try BootstrapSimulation.output(for:options(),read:{_ in throw error},publish:{_,_ in XCTFail("failure publication");return .published})) { caught in
            XCTAssertFalse(caught.localizedDescription.contains("private secret text"))
        }
    }
}
