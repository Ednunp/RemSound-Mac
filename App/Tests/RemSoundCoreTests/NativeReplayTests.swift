import Foundation
import XCTest
import RemSoundJam
@_spi(NativeReplay) import RemSoundSim
@testable import RemSoundCore

final class NativeReplayTests: XCTestCase {
    private func comparisonRecording(codec: Int = 1, frames: Int = 64) -> String {
        var r = NetworkRecording()
        r.streams = [.init(index: 0, from: "10.0.0.9:1", streamId: 7, lane: "private lane", format: "private descriptor", codec: codec, frameSamples: frames)]
        r.facts = [.init("buffer ms", "15")]
        r.packets = (0..<80).filter { $0 != 20 }.map { .init(ms: Double($0)*2.5+5, stream: 0, sequence: UInt32($0), bytes: 60) }
        r.packets.append(.init(ms: 155.5, stream: 0, sequence: 60, bytes: 60))
        r.packets.sort { $0.ms < $1.ms }
        return r.text()
    }
    func testFixedNativeTargetsPreservePCMRecordedDescriptorAndRescaleActualFates() throws {
        let text = comparisonRecording(), date = Date(timeIntervalSince1970: 0)
        let report = try NativeReplaySimulation.compare(text, seconds: 0.25, oneWayMs: 5, date: date)
        XCTAssertEqual(report.recordedCodec, 1)
        XCTAssertEqual(report.recordedFrameSamples, 64)
        XCTAssertEqual(report.packetFrames, 120)
        XCTAssertEqual(report.bufferMs, 15)
        XCTAssertFalse(report.nativeCodec)
        XCTAssertTrue(report.unverified.contains("recorded codec uses pure receive model"))
        XCTAssertEqual(report.comparisons.count, 18)
        for (i, row) in report.comparisons.enumerated() {
            XCTAssertEqual(row.packetFrames, i < 6 ? 64 : (i < 12 ? 120 : 480))
            XCTAssertEqual(row.bufferMs, [5,8,10,15,20,30][i%6])
            XCTAssertEqual(row.packetsLost, i < 6 ? 2 : 1)
            XCTAssertEqual(row.packetsSent, i < 6 ? 187 : (i < 12 ? 100 : 25))
            XCTAssertGreaterThan(row.nativeDecodedFrames, 0)
            XCTAssertEqual(row.seed, 1)
            XCTAssertEqual(row.seconds, 0.25)
        }
        XCTAssertEqual(report, try NativeReplaySimulation.compare(text, seconds: 0.25, oneWayMs: 5, date: date))
        let data = try JSONEncoder().encode(report)
        XCTAssertLessThan(data.count, 16384)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private descriptor"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("10.0.0.9"))
    }
    func testAsRecordedRunKeepsNoImplicitSweepAndComparisonDoesNotReclassifyIt() throws {
        let text = comparisonRecording(codec: 2, frames: 120), date = Date(timeIntervalSince1970: 0)
        let baseline = try NativeReplaySimulation.run(text, seconds: 0.25, date: date)
        let compared = try NativeReplaySimulation.compare(text, seconds: 0.25, date: date)
        XCTAssertTrue(baseline.comparisons.isEmpty)
        XCTAssertTrue(compared.nativeCodec)
        XCTAssertEqual(compared.nativeDecodedFrames, baseline.nativeDecodedFrames)
        XCTAssertEqual(compared.recordedFrameSamples, baseline.recordedFrameSamples)
        XCTAssertEqual(compared.lost, baseline.lost)
        XCTAssertEqual(compared.doubled, baseline.doubled)
        XCTAssertTrue(compared.unverified.contains("complete reference sweeps and other codec modes"))
        XCTAssertTrue(compared.unverified.contains("recorded-driver and physical output acceptance"))
    }
    func testComparisonCannotHideInvalidRecordedNativeGeometryOrInputBounds() throws {
        XCTAssertThrowsError(try NativeReplaySimulation.compare(comparisonRecording(codec: 2, frames: 121), seconds: 0.25))
        XCTAssertThrowsError(try NativeReplaySimulation.compare(comparisonRecording(), seconds: .infinity))
        XCTAssertThrowsError(try NativeReplaySimulation.compare("not a recording", seconds: 0.25))
    }

    func recording(frames:Int=120,codec:Int=2,missing:Set<Int>=[20],doubled:Bool=true) -> String {
        var r=NetworkRecording();r.facts=[.init("machine","private replay name"),.init("buffer ms","2")]
        r.streams=[.init(index:0,from:"10.0.0.1:1",streamId:7,lane:"Mixed",format:"private format",codec:codec,frameSamples:frames)]
        r.packets=(0..<80).filter { !missing.contains($0) }.map { .init(ms:Double($0*frames)/48+5,stream:0,sequence:UInt32($0),bytes:60) }
        if doubled { r.packets.append(.init(ms:Double(60*frames)/48+5.5,stream:0,sequence:60,bytes:60)) }
        r.packets.sort { $0.ms<$1.ms };return r.text()
    }
    func testActualNativeReplayIsDeterministicAndRepairsSingleLossButCountsBurstGap() throws {
        let date=Date(timeIntervalSince1970:0)
        let one=try NativeReplaySimulation.run(recording(),seconds:0.2,date:date)
        XCTAssertEqual(one,try NativeReplaySimulation.run(recording(),seconds:0.2,date:date))
        XCTAssertTrue(one.nativeCodec);XCTAssertGreaterThan(one.nativeDecodedFrames,0)
        XCTAssertEqual(one.concealed,1);XCTAssertEqual(one.gapsNotRepaired,0)
        XCTAssertEqual(one.lost,1);XCTAssertEqual(one.doubled,1);XCTAssertGreaterThan(one.lateDropped,0)
        let burst=try NativeReplaySimulation.run(recording(missing:[20,21,22]),seconds:0.2,date:date)
        XCTAssertEqual(burst.lost,3);XCTAssertEqual(burst.concealed,0);XCTAssertEqual(burst.gapsNotRepaired,1)
        let json=String(decoding:try JSONEncoder().encode(one),as:UTF8.self)
        XCTAssertFalse(json.contains("private"));XCTAssertFalse(json.contains("10.0.0.1"))
        XCTAssertTrue(one.unverified.contains(where:{$0.contains("comparison")}))
    }
    func testFixedGenuineFECReachesActualSimulatedOutputAndRetiresEveryRun() throws {
        for _ in 0..<8 {
            let result=try ProductTestPack.nativeReplayFEC()
            XCTAssertTrue(result.genuine);XCTAssertEqual(result.repaired,1)
            XCTAssertEqual(result.unrepaired,0);XCTAssertTrue(result.exactSamples);XCTAssertTrue(result.deterministic)
        }
    }
    func testPureModelRemainsLabelledAndNativeGeometryNeverFallsBack() throws {
        let model=try NativeReplaySimulation.run(recording(codec:1),seconds:0.2)
        XCTAssertFalse(model.nativeCodec);XCTAssertEqual(model.nativeDecodedFrames,0)
        XCTAssertTrue(model.unverified.contains(where:{$0.contains("codec")}))
        XCTAssertThrowsError(try NativeReplaySimulation.run(recording(frames:121),seconds:0.2))
        XCTAssertThrowsError(try NativeReplaySimulation.run("not a recording",seconds:0.2))
        var scenario=MacScenario("refused encoder");scenario.seconds=0.05;scenario.packetFrames=120
        scenario.sendCard=SimCard(frames:120)
        XCTAssertThrowsError(try NativeReplaySimulation.runNative(scenario,frames:120,channels:2,encode:{_ in nil}))
        XCTAssertThrowsError(try NativeReplaySimulation.runNative(scenario,frames:120,channels:2,encode:{_ in Data([0xff])}))
    }
    func testNativeRecorderSaysOpusAndCountsWholeAuthenticatedWirePackets() throws {
        let sender=try XCTUnwrap(OpusSender(bitrate:128000))
        let plain=try XCTUnwrap(sender.encode([Float](repeating:0.1,count:240)))
        var scenario=MacScenario("native recorder");scenario.seconds=0.1;scenario.packetFrames=120
        scenario.sendCard=SimCard(frames:120);scenario.recordNetwork=true
        let result=try NativeReplaySimulation.runNative(scenario,frames:120,channels:2,encode:{ _ in plain })
        let recording=try XCTUnwrap(result.recording)
        XCTAssertEqual(recording.streams.count,1)
        XCTAssertEqual(recording.streams.first?.codec,2)
        XCTAssertEqual(recording.streams.first?.format,"Opus")
        XCTAssertEqual(recording.streams.first?.frameSamples,120)
        XCTAssertFalse(recording.packets.isEmpty)
        XCTAssertTrue(recording.packets.allSatisfy { $0.bytes==plain.count+28+Wire.headerSize })
        XCTAssertEqual(try NetworkRecording.read(recording.text()).text(),recording.text())
    }
    func testStreamDecoderUsesOwnedVirtualClockWithoutChangingProcessTime() throws {
        let before=ProcessInfo.processInfo.systemUptime,key=try Credentials(password:"synthetic virtual decoder")
        var now=0.0
        let decoder=StreamDecoder(.opus(key.fingerprint,frames:120),jitterMs:2,clock:{now})
        let sender=try XCTUnwrap(OpusSender(bitrate:128000))
        let plain=try XCTUnwrap(sender.encode([Float](repeating:0.1,count:240)))
        for sequence:UInt32 in [1,2] {
            now=Double(sequence)*0.0025
            let packet=try XCTUnwrap(Wire.parse(Wire.packet(.audio,sequence:sequence,payload:try key.seal(plain))))
            XCTAssertTrue(decoder.accept(packet,credentials:key));_=decoder.read(120)
        }
        XCTAssertGreaterThan(ProcessInfo.processInfo.systemUptime,before)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-before,1)
        XCTAssertEqual(decoder.takeLogFigures().maxGapMs,2.5,accuracy:0.0001)
    }
}
