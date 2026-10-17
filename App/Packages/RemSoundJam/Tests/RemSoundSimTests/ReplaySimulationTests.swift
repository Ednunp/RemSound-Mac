import Foundation
import XCTest
import RemSoundJam
@testable import RemSoundSim

final class ReplaySimulationTests: XCTestCase {
    func recording() -> NetworkRecording {
        var r=NetworkRecording();r.facts=[.init("machine","secret machine"),.init("password","secret test text"),.init("buffer ms","20")]
        r.streams=[.init(index:0,from:"10.0.0.1:1",streamId:7,lane:"Mixed",format:"secret format",codec:1,frameSamples:120)]
        r.packets=(0..<400).map { .init(ms:Double($0)*2.5,stream:0,sequence:UInt32($0),bytes:60) };return r
    }
    func testActualReplayModelIsDeterministicAndReportContainsNoImportedNames() throws {
        let text=recording().text(), date=Date(timeIntervalSince1970:0)
        let one=try ReplaySimulation.run(text,seconds:0.25,oneWayMs:5,date:date)
        XCTAssertEqual(one,try ReplaySimulation.run(text,seconds:0.25,oneWayMs:5,date:date))
        XCTAssertEqual(one.stream,0);XCTAssertEqual(one.places,400);XCTAssertEqual(one.packetFrames,120)
        XCTAssertEqual(one.oneWayMs,5);XCTAssertEqual(one.seed,1);XCTAssertGreaterThan(one.packetsSent,0)
        XCTAssertEqual(one.lost,0);XCTAssertEqual(one.doubled,0)
        let json=String(decoding:try JSONEncoder().encode(one),as:UTF8.self)
        XCTAssertFalse(json.contains("secret"));XCTAssertFalse(json.contains("10.0.0.1"))
        XCTAssertTrue(one.unverified.contains(where:{$0.contains("codec")}))
    }
    func testHandMadeLossDuplicateAndChosenStreamUseExistingReplayFates() throws {
        var r=recording();r.packets.remove(at:200);r.packets.append(.init(ms:750.5,stream:0,sequence:300,bytes:60));r.packets.sort{$0.ms<$1.ms}
        let report=try ReplaySimulation.run(r.text(),stream:0,seconds:1)
        XCTAssertEqual(report.lost,1);XCTAssertEqual(report.doubled,1)
        XCTAssertThrowsError(try ReplaySimulation.run(r.text(),stream:1,seconds:1))
    }
    func testUntrustedClockSpanAndGeometryRefuseWithoutSimulationFallback() {
        var r=recording();r.facts.append(.init("receive card frames","nan"))
        XCTAssertThrowsError(try ReplaySimulation.run(r.text(),seconds:1))
        XCTAssertThrowsError(try ReplaySimulation.run("not a recording",seconds:1))
        XCTAssertThrowsError(try ReplaySimulation.run(recording().text(),seconds:.nan))
        XCTAssertThrowsError(try ReplaySimulation.run(recording().text(),seconds:61))
        XCTAssertThrowsError(try ReplaySimulation.run(recording().text(),oneWayMs:.infinity))
    }
    func testTextBoundsPrecedeRecordingParserAllocations() {
        XCTAssertThrowsError(try ReplaySimulation.validateRecordingText(String(repeating:"x",count:4097)))
        XCTAssertThrowsError(try ReplaySimulation.validateRecordingText(String(repeating:"\n",count:(1<<18)+323)))
        XCTAssertNoThrow(try ReplaySimulation.validateRecordingText(recording().text()))
    }
}
